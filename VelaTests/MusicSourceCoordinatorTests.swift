import XCTest
import CoreGraphics
@testable import Vela

/// Scripted stand-in for a player.
private actor FakeSource: MusicSource {
    nonisolated let kind: MusicSourceKind
    nonisolated let capabilities: SourceCapabilities = .full
    var available: Bool
    var snapshotToReturn: PlaybackSnapshot
    var error: MusicSourceError?
    var commands: [String] = []

    init(kind: MusicSourceKind, available: Bool, snapshot: PlaybackSnapshot) {
        self.kind = kind
        self.available = available
        self.snapshotToReturn = snapshot
    }

    func set(available: Bool) { self.available = available }
    func set(snapshot: PlaybackSnapshot) { snapshotToReturn = snapshot }
    func set(error: MusicSourceError?) { self.error = error }

    func isAvailable() async -> Bool { available }
    func snapshot() async throws -> PlaybackSnapshot {
        if let error { throw error }
        return snapshotToReturn
    }
    func artwork(for track: TrackInfo) async throws -> CGImage? { nil }
    func play() async throws { commands.append("play") }
    func pause() async throws { commands.append("pause") }
    func togglePlayPause() async throws { commands.append("toggle") }
    func next() async throws { commands.append("next") }
    func previous() async throws { commands.append("previous") }
    func seek(to position: TimeInterval) async throws { commands.append("seek:\(Int(position))") }
}

final class MusicSourceCoordinatorTests: XCTestCase {
    private func track(_ id: String, _ source: MusicSourceKind) -> TrackInfo {
        TrackInfo(id: id, title: id, artist: "A", album: "B", duration: 100, source: source, artworkURL: nil)
    }

    func testNoPlayerRunning() async {
        let spotify = FakeSource(kind: .spotify, available: false, snapshot: .empty)
        let coordinator = MusicSourceCoordinator(sources: [spotify])
        let event = await coordinator.pollOnce()
        XCTAssertEqual(event.status, .noPlayerRunning)
        XCTAssertNil(event.sourceKind)
    }

    func testPicksPlayingSourceWhenSeveralRun() async {
        let now = Date()
        let spotify = FakeSource(kind: .spotify, available: true,
                                 snapshot: PlaybackSnapshot(track: track("s1", .spotify), state: .paused, position: 5, observedAt: now))
        let music = FakeSource(kind: .appleMusic, available: true,
                               snapshot: PlaybackSnapshot(track: track("m1", .appleMusic), state: .playing, position: 9, observedAt: now))
        let coordinator = MusicSourceCoordinator(sources: [spotify, music])
        let event = await coordinator.pollOnce()
        XCTAssertEqual(event.sourceKind, .appleMusic)
        XCTAssertEqual(event.snapshot.track?.id, "m1")
        XCTAssertEqual(event.status, .active(.appleMusic))
    }

    func testSwitchesSourceWhenPlayerQuitsAndTracksChange() async {
        let now = Date()
        let spotify = FakeSource(kind: .spotify, available: true,
                                 snapshot: PlaybackSnapshot(track: track("s1", .spotify), state: .playing, position: 1, observedAt: now))
        let music = FakeSource(kind: .appleMusic, available: false,
                               snapshot: PlaybackSnapshot(track: track("m1", .appleMusic), state: .playing, position: 2, observedAt: now))
        let coordinator = MusicSourceCoordinator(sources: [spotify, music])

        var event = await coordinator.pollOnce()
        XCTAssertEqual(event.sourceKind, .spotify)
        XCTAssertEqual(event.snapshot.track?.identityKey, "spotify:s1")

        // Track changes inside Spotify.
        await spotify.set(snapshot: PlaybackSnapshot(track: track("s2", .spotify), state: .playing, position: 0, observedAt: now))
        event = await coordinator.pollOnce()
        XCTAssertEqual(event.snapshot.track?.identityKey, "spotify:s2")

        // Spotify quits, Music starts.
        await spotify.set(available: false)
        await music.set(available: true)
        event = await coordinator.pollOnce()
        XCTAssertEqual(event.sourceKind, .appleMusic)
        XCTAssertEqual(event.snapshot.track?.identityKey, "appleMusic:m1")

        // Everything quits.
        await music.set(available: false)
        event = await coordinator.pollOnce()
        XCTAssertEqual(event.status, .noPlayerRunning)
    }

    func testPreferredSourceWinsAndReportsUnavailable() async {
        let now = Date()
        let spotify = FakeSource(kind: .spotify, available: true,
                                 snapshot: PlaybackSnapshot(track: track("s1", .spotify), state: .playing, position: 1, observedAt: now))
        let music = FakeSource(kind: .appleMusic, available: true,
                               snapshot: PlaybackSnapshot(track: track("m1", .appleMusic), state: .paused, position: 2, observedAt: now))
        let coordinator = MusicSourceCoordinator(sources: [spotify, music], preferred: .appleMusic)
        var event = await coordinator.pollOnce()
        XCTAssertEqual(event.sourceKind, .appleMusic)

        await music.set(available: false)
        event = await coordinator.pollOnce()
        XCTAssertEqual(event.status, .preferredUnavailable(.appleMusic))

        await coordinator.setPreferred(nil)
        event = await coordinator.pollOnce()
        XCTAssertEqual(event.sourceKind, .spotify)
    }

    func testPermissionDeniedIsSurfaced() async {
        let spotify = FakeSource(kind: .spotify, available: true, snapshot: .empty)
        await spotify.set(error: .permissionDenied)
        let coordinator = MusicSourceCoordinator(sources: [spotify])
        let event = await coordinator.pollOnce()
        XCTAssertEqual(event.status, .permissionDenied(.spotify))
    }

    func testCommandsGoToActiveSource() async throws {
        let now = Date()
        let spotify = FakeSource(kind: .spotify, available: true,
                                 snapshot: PlaybackSnapshot(track: track("s1", .spotify), state: .playing, position: 1, observedAt: now))
        let coordinator = MusicSourceCoordinator(sources: [spotify])
        _ = await coordinator.pollOnce()
        try await coordinator.perform { try await $0.next() }
        try await coordinator.perform { try await $0.seek(to: 42) }
        let commands = await spotify.commands
        XCTAssertEqual(commands, ["next", "seek:42"])
    }

    func testDemoSourceTimelineAndTransport() async throws {
        let demo = DemoMusicSource()
        let first = try await demo.snapshot()
        XCTAssertEqual(first.track?.id, DemoCatalog.tracks[0].id)
        XCTAssertEqual(first.state, .playing)

        try await demo.seek(to: 60)
        let seeked = try await demo.snapshot()
        XCTAssertEqual(seeked.position, 60, accuracy: 0.5)

        try await demo.pause()
        let paused = try await demo.snapshot()
        XCTAssertEqual(paused.state, .paused)

        try await demo.next()
        let next = try await demo.snapshot()
        XCTAssertEqual(next.track?.id, DemoCatalog.tracks[1].id)
        XCTAssertEqual(next.position, 0, accuracy: 0.5)

        try await demo.previous()   // near the start → previous track
        let prev = try await demo.snapshot()
        XCTAssertEqual(prev.track?.id, DemoCatalog.tracks[0].id)

        let artwork = try await demo.artwork(for: prev.track!)
        XCTAssertNotNil(artwork)
    }
}

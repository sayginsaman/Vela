import Foundation
import CoreGraphics

/// A fully simulated player: real-time playback timeline, seeking, skipping and procedural art.
actor DemoMusicSource: MusicSource {
    nonisolated let kind: MusicSourceKind = .demo
    nonisolated let capabilities: SourceCapabilities = .full

    private var index: Int
    private var anchorPosition: TimeInterval = 0
    private var anchorDate = Date()
    private var playing = true
    private var artworkCache: [String: CGImage] = [:]
    private let tracks: [DemoTrack]
    private var enabled: Bool

    init(tracks: [DemoTrack] = DemoCatalog.tracks, startIndex: Int = 0, enabled: Bool = true) {
        self.tracks = tracks
        self.enabled = enabled
        self.index = min(max(0, startIndex), max(0, tracks.count - 1))
    }

    var currentTrack: DemoTrack { tracks[index] }

    private func currentPosition(at date: Date = Date()) -> TimeInterval {
        let elapsed = playing ? date.timeIntervalSince(anchorDate) : 0
        return anchorPosition + elapsed
    }

    private func advanceIfFinished(now: Date) {
        let position = currentPosition(at: now)
        if position >= currentTrack.duration {
            index = (index + 1) % tracks.count
            anchorPosition = 0
            anchorDate = now
        }
    }

    /// Demo Mode is opt-in: the coordinator only sees this source while it is enabled.
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value {
            anchorPosition = 0
            anchorDate = Date()
            playing = true
        }
    }

    func isAvailable() async -> Bool { enabled }

    func snapshot() async throws -> PlaybackSnapshot {
        let now = Date()
        advanceIfFinished(now: now)
        return PlaybackSnapshot(track: currentTrack.trackInfo,
                                state: playing ? .playing : .paused,
                                position: min(currentPosition(at: now), currentTrack.duration),
                                observedAt: now)
    }

    func artwork(for track: TrackInfo) async throws -> CGImage? {
        if let cached = artworkCache[track.id] { return cached }
        guard let demo = DemoCatalog.track(withID: track.id) ?? tracks.first(where: { $0.id == track.id }) else { return nil }
        let image = DemoArtwork.render(for: demo)
        if let image { artworkCache[track.id] = image }
        return image
    }

    func play() async throws {
        guard !playing else { return }
        anchorDate = Date()
        playing = true
    }

    func pause() async throws {
        guard playing else { return }
        anchorPosition = currentPosition()
        anchorDate = Date()
        playing = false
    }

    func togglePlayPause() async throws {
        if playing { try await pause() } else { try await play() }
    }

    func next() async throws {
        index = (index + 1) % tracks.count
        anchorPosition = 0
        anchorDate = Date()
    }

    func previous() async throws {
        // Like most players: restart the song unless we are near its beginning.
        if currentPosition() > 3 {
            anchorPosition = 0
        } else {
            index = (index - 1 + tracks.count) % tracks.count
            anchorPosition = 0
        }
        anchorDate = Date()
    }

    func seek(to position: TimeInterval) async throws {
        anchorPosition = min(max(0, position), currentTrack.duration)
        anchorDate = Date()
    }
}

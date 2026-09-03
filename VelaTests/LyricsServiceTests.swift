import XCTest
@testable import Vela

private struct StubProvider: LyricsProvider {
    let name: String
    let isRemote: Bool
    let result: LyricsLookup
    let error: Error?
    init(name: String, remote: Bool = true, result: LyricsLookup = .notFound, error: Error? = nil) {
        self.name = name; isRemote = remote; self.result = result; self.error = error
    }
    func lyrics(for query: LyricsQuery) async throws -> LyricsLookup {
        if let error { throw error }
        return result
    }
}

final class LyricsServiceTests: XCTestCase {
    private func makeService(remote: [LyricsProvider], online: Bool = true) -> LyricsService {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vela-svc-\(UUID().uuidString)")
        return LyricsService(cache: LyricsCache(directory: dir.appendingPathComponent("cache")),
                             localStore: LocalLyricsStore(directory: dir.appendingPathComponent("local")),
                             bundled: [DemoLyricsProvider()], remote: remote, isOnline: { online })
    }

    private let track = TrackInfo(id: "x", title: "Song", artist: "Artist", album: "Album", duration: 200, source: .spotify, artworkURL: nil)

    func testDemoTracksUseBundledLyrics() async {
        let service = makeService(remote: [StubProvider(name: "never", error: LyricsProviderError.network("no"))])
        let wordSynced = DemoCatalog.track(withID: "demo-concrete-halo")!
        let outcome = await service.resolve(track: wordSynced.trackInfo)
        guard case .found(let doc) = outcome else { return XCTFail("expected demo lyrics, got \(outcome)") }
        XCTAssertEqual(doc.quality, .wordSynced)
        XCTAssertEqual(doc.provenance, "demo")

        let instrumental = await service.resolve(track: DemoCatalog.track(withID: "demo-glasswater")!.trackInfo)
        XCTAssertEqual(instrumental, .instrumental)

        // Every demo track with lyrics resolves offline.
        for track in DemoCatalog.tracks where !track.isInstrumental {
            guard case .found = await service.resolve(track: track.trackInfo) else { return XCTFail("missing lyrics for \(track.title)") }
        }
    }

    func testRemoteFailureNeverThrowsAndReportsFailure() async {
        let service = makeService(remote: [StubProvider(name: "lrclib", error: LyricsProviderError.network("offline"))])
        let outcome = await service.resolve(track: track)
        guard case .failed = outcome else { return XCTFail("expected failure, got \(outcome)") }
    }

    func testOfflineSkipsRemote() async {
        let service = makeService(remote: [StubProvider(name: "lrclib", result: .found(LRCParser.parse("[00:01.00]Hi")!))], online: false)
        let outcome = await service.resolve(track: track); XCTAssertEqual(outcome, .offline)
    }

    func testRemoteHitIsCached() async {
        let doc = LRCParser.parse("[00:01.00]Hi")!
        let hit = StubProvider(name: "lrclib", result: .found(doc))
        let service = makeService(remote: [hit])
        guard case .found = await service.resolve(track: track) else { return XCTFail() }
        let cached = await service.cache.lookup(LyricsQuery(track: track))
        guard case .found(let stored)? = cached else { return XCTFail("expected cache") }
        XCTAssertEqual(stored.lines.first?.text, "Hi")
    }

    func testImportedFileWinsOverEverything() async throws {
        let service = makeService(remote: [StubProvider(name: "lrclib", result: .found(LRCParser.parse("[00:01.00]Remote")!))])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).lrc")
        try "[00:05.00]Imported line".write(to: file, atomically: true, encoding: .utf8)
        let imported = try await service.importLyrics(from: file, for: track)
        XCTAssertEqual(imported.provenance, "local")
        guard case .found(let doc) = await service.resolve(track: track) else { return XCTFail() }
        XCTAssertEqual(doc.lines.first?.text, "Imported line")
    }
}

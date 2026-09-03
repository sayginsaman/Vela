import XCTest
@testable import Vela

final class LyricsCacheTests: XCTestCase {
    func testKeyNormalisesCaseWhitespaceAndDuration() {
        let a = LyricsQuery(title: "Low Tide Signal", artist: "Marrow & Vale", album: "Harbor Lights", duration: 152.2)
        let b = LyricsQuery(title: "  low tide   signal ", artist: "MARROW & VALE", album: "harbor lights", duration: 152.9)
        XCTAssertEqual(LyricsCache.key(for: a), LyricsCache.key(for: b))
        XCTAssertEqual(LyricsCache.key(for: a).count, 32)
    }

    func testKeyDistinguishesDifferentTracks() {
        let a = LyricsQuery(title: "Song", artist: "Artist", album: "", duration: 100)
        let b = LyricsQuery(title: "Song", artist: "Artist", album: "", duration: 130)
        let c = LyricsQuery(title: "Song 2", artist: "Artist", album: "", duration: 100)
        XCTAssertNotEqual(LyricsCache.key(for: a), LyricsCache.key(for: b))
        XCTAssertNotEqual(LyricsCache.key(for: a), LyricsCache.key(for: c))
    }

    func testStoreAndLookupRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vela-cache-\(UUID().uuidString)")
        let cache = LyricsCache(directory: dir)
        let query = LyricsQuery(title: "A", artist: "B", album: "C", duration: 120)
        let miss = await cache.lookup(query); XCTAssertNil(miss)

        let doc = LRCParser.parse("[00:01.00]Hello\n[00:02.00]World")!
        await cache.store(.found(doc), for: query)
        guard case .found(let cached)? = await cache.lookup(query) else { return XCTFail("expected hit") }
        XCTAssertEqual(cached.lines.map(\.text), ["Hello", "World"])
        XCTAssertEqual(cached.provenance, "cache")

        // Survives a fresh actor reading the same directory.
        let reopened = LyricsCache(directory: dir)
        guard case .found? = await reopened.lookup(query) else { return XCTFail("expected disk hit") }

        await cache.store(.instrumental, for: query)
        let instrumental = await cache.lookup(query); XCTAssertEqual(instrumental, .instrumental)
        await cache.remove(query)
        let miss2 = await cache.lookup(query); XCTAssertNil(miss2)
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissIsCachedThenForgotten() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vela-cache-\(UUID().uuidString)")
        let cache = LyricsCache(directory: dir)
        let query = LyricsQuery(title: "Missing", artist: "Nobody", album: "", duration: 90)
        await cache.store(.notFound, for: query)
        let notFound = await cache.lookup(query); XCTAssertEqual(notFound, .notFound)
        await cache.clear()
        let miss3 = await cache.lookup(query); XCTAssertNil(miss3)
        try? FileManager.default.removeItem(at: dir)
    }
}

import XCTest
@testable import Vela

private struct StubAMLLSource: AMLLDataSource {
    var indexData: Data
    var files: [String: Data]
    var indexError: Error?

    func index() async throws -> Data {
        if let indexError { throw indexError }
        return indexData
    }

    func lyrics(file: String) async throws -> Data {
        guard let data = files[file] else { throw LyricsProviderError.badResponse(404) }
        return data
    }
}

final class AMLLProviderTests: XCTestCase {
    private let indexJSONL = """
    {"metadata":[["musicName",["I Really Want to Stay At Your House"]],["artists",["Rosa Walton"]],["artists",["Hallie Coggins"]],["spotifyId",["7mykoq6R3BArsSpNDjFQTm"]],["ncmMusicId",["1496089152"]]],"rawLyricFile":"stay.ttml"}
    {"metadata":[["musicName",["Low Tide Signal"]],["artists",["Marrow & Vale"]]],"rawLyricFile":"tide.ttml"}
    {"not":"a record"}
    """

    private let ttml = #"""
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div xmlns="">
    <p begin="00:01.000" end="00:02.000"><span begin="00:01.000" end="00:01.400">Hold</span> <span begin="00:01.400" end="00:02.000">on</span></p>
    </div></body></tt>
    """#

    private func source() -> StubAMLLSource {
        StubAMLLSource(indexData: Data(indexJSONL.utf8), files: ["stay.ttml": Data(ttml.utf8), "tide.ttml": Data(ttml.utf8)])
    }

    // MARK: Index

    func testIndexParsing() {
        let entries = AMLLCatalogue.parse(Data(indexJSONL.utf8))
        XCTAssertEqual(entries.count, 2, "the malformed record is skipped")
        XCTAssertEqual(entries.bySpotifyID["7mykoq6R3BArsSpNDjFQTm"], "stay.ttml")
        // Every artist on a record is indexed, so either one matches.
        XCTAssertEqual(entries.byTitleArtist[AMLLCatalogue.key(title: "I Really Want to Stay At Your House", artist: "Rosa Walton")], "stay.ttml")
        XCTAssertEqual(entries.byTitleArtist[AMLLCatalogue.key(title: "I Really Want to Stay At Your House", artist: "Hallie Coggins")], "stay.ttml")
    }

    func testKeyIgnoresCasePunctuationAndAccents() {
        let canonical = AMLLCatalogue.key(title: "Low Tide Signal", artist: "Marrow & Vale")
        XCTAssertEqual(AMLLCatalogue.key(title: "  low   tide signal ", artist: "marrow and vale ".replacingOccurrences(of: "and", with: "&")), canonical)
        XCTAssertEqual(AMLLCatalogue.key(title: "Lów Tíde Signal!", artist: "Marrow & Vale"), canonical)
        XCTAssertNotEqual(AMLLCatalogue.key(title: "Low Tide Signal", artist: "Someone Else"), canonical)
    }

    func testSpotifyTrackIDExtraction() {
        XCTAssertEqual(LyricsQuery.spotifyTrackID(fromURI: "spotify:track:4kjI1gwQZRKNDkw1nI475M"), "4kjI1gwQZRKNDkw1nI475M")
        XCTAssertEqual(LyricsQuery.spotifyTrackID(fromURI: "4kjI1gwQZRKNDkw1nI475M"), "4kjI1gwQZRKNDkw1nI475M")
        XCTAssertNil(LyricsQuery.spotifyTrackID(fromURI: "spotify:local:::x:1"))
        let track = TrackInfo(id: "spotify:track:7mykoq6R3BArsSpNDjFQTm", title: "T", artist: "A", album: "B",
                              duration: 100, source: .spotify, artworkURL: nil)
        XCTAssertEqual(LyricsQuery(track: track).spotifyTrackID, "7mykoq6R3BArsSpNDjFQTm")
        let appleTrack = TrackInfo(id: "ABCD1234", title: "T", artist: "A", album: "B",
                                   duration: 100, source: .appleMusic, artworkURL: nil)
        XCTAssertNil(LyricsQuery(track: appleTrack).spotifyTrackID, "only Spotify ids are Spotify ids")
    }

    // MARK: Provider

    func testFindsBySpotifyIDEvenWhenTitleDiffers() async throws {
        let provider = AMLLProvider(source: source())
        let query = LyricsQuery(title: "Whatever The Player Calls It", artist: "Rosa Walton",
                                spotifyTrackID: "7mykoq6R3BArsSpNDjFQTm")
        guard case .found(let doc) = try await provider.lyrics(for: query) else { return XCTFail("expected a hit") }
        XCTAssertEqual(doc.quality, .wordSynced)
        XCTAssertEqual(doc.provenance, "amll")
        XCTAssertEqual(doc.lines.first?.words.map(\.text), ["Hold", "on"])
    }

    func testFindsByTitleAndArtistWhenThereIsNoSpotifyID() async throws {
        let provider = AMLLProvider(source: source())
        let query = LyricsQuery(title: "low tide signal", artist: "Marrow & Vale")
        guard case .found = try await provider.lyrics(for: query) else { return XCTFail("expected a hit") }
    }

    func testMissesQuietly() async throws {
        let provider = AMLLProvider(source: source())
        let unknown = LyricsQuery(title: "Concrete Halo", artist: "Juno Ash")
        let missing = try await provider.lyrics(for: unknown)
        XCTAssertEqual(missing, .notFound)
        // Right title, wrong artist: never serve someone else's song.
        let wrongArtist = LyricsQuery(title: "Low Tide Signal", artist: "A Different Band")
        let mismatched = try await provider.lyrics(for: wrongArtist)
        XCTAssertEqual(mismatched, .notFound)
    }

    func testIndexIsFetchedOnceAndFailuresPropagate() async throws {
        var failing = source()
        failing.indexError = LyricsProviderError.network("offline")
        let provider = AMLLProvider(source: failing)
        do {
            _ = try await provider.lyrics(for: LyricsQuery(title: "Low Tide Signal", artist: "Marrow & Vale"))
            XCTFail("expected the index failure to surface")
        } catch {}
    }
}

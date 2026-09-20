import XCTest
@testable import Vela

final class MusixmatchProviderTests: XCTestCase {
    /// Shape documented by Musixmatch: per line a start `ts`, an end `te`, and chunks `l`
    /// each carrying an offset `o` from `ts`. Spaces are their own chunks.
    private let richsync = """
    [{"ts":10.0,"te":12.0,"x":"Hold the line","l":[
      {"c":"Hold","o":0.0},{"c":" ","o":0.5},{"c":"the","o":0.6},{"c":" ","o":0.9},{"c":"line","o":1.0}]},
     {"ts":13.0,"te":14.5,"x":"Again","l":[{"c":"A","o":0.0},{"c":"gain","o":0.3}]}]
    """

    func testParsesWordTimingsAndJoinsSplitWords() throws {
        let doc = try XCTUnwrap(MusixmatchProvider.parseRichsync(richsync))
        XCTAssertEqual(doc.quality, .wordSynced)
        XCTAssertEqual(doc.provenance, "musixmatch")
        XCTAssertEqual(doc.lines.count, 2)

        let first = doc.lines[0]
        XCTAssertEqual(first.words.map(\.text), ["Hold", "the", "line"])
        XCTAssertEqual(first.words[0].start, 10.0, accuracy: 0.0001)
        XCTAssertEqual(first.words[0].end, 10.5, accuracy: 0.0001, "a space closes the word before it")
        XCTAssertEqual(first.words[1].start, 10.6, accuracy: 0.0001)
        XCTAssertEqual(first.words[2].start, 11.0, accuracy: 0.0001)
        XCTAssertEqual(first.words[2].end, 12.0, accuracy: 0.0001, "the last word runs to the line end")
        XCTAssertFalse(first.words.contains { $0.isEstimated })
        XCTAssertEqual(first.text, "Hold the line")

        // Chunks with no space between them are one word.
        XCTAssertEqual(doc.lines[1].words.map(\.text), ["Again"])
        XCTAssertEqual(doc.lines[1].words[0].start, 13.0, accuracy: 0.0001)
    }

    func testParsedDocumentDrivesTheTimeline() throws {
        let doc = try XCTUnwrap(MusixmatchProvider.parseRichsync(richsync))
        var timeline = LyricTimeline(document: doc)
        let position = timeline.locate(at: 10.7)
        XCTAssertEqual(position.lineIndex, 0)
        XCTAssertEqual(position.wordIndex, 1)
    }

    func testRejectsRubbish() {
        XCTAssertNil(MusixmatchProvider.parseRichsync(""))
        XCTAssertNil(MusixmatchProvider.parseRichsync("not json"))
        XCTAssertNil(MusixmatchProvider.parseRichsync("[]"))
        XCTAssertNil(MusixmatchProvider.parseRichsync("[{\"ts\":1.0,\"te\":2.0,\"l\":[]}]"), "no words, no line")
    }

    func testReadsTheApiStatusCode() {
        let payload = Data("{\"message\":{\"header\":{\"status_code\":401},\"body\":{}}}".utf8)
        XCTAssertEqual(MusixmatchProvider.statusCode(in: payload), 401)
        XCTAssertNil(MusixmatchProvider.statusCode(in: Data("{}".utf8)))
    }

    func testWithoutAKeyTheProviderIsInertAndNeverCallsOut() async throws {
        let provider = MusixmatchProvider(key: { nil })
        XCTAssertFalse(provider.isConfigured)
        let result = try await provider.lyrics(for: LyricsQuery(title: "Anything", artist: "Anyone"))
        XCTAssertEqual(result, .notFound)
    }
}

final class KeychainStoreTests: XCTestCase {
    private let account = "test.vela.\(UUID().uuidString)"

    override func tearDown() {
        KeychainStore.remove(account: account)
        super.tearDown()
    }

    func testRoundTrip() throws {
        guard KeychainStore.set("secret-value-1234", account: account) else {
            throw XCTSkip("the keychain is not writable in this environment")
        }
        XCTAssertEqual(KeychainStore.get(account: account), "secret-value-1234")
        // Overwrites rather than duplicating.
        XCTAssertTrue(KeychainStore.set("second-value-5678", account: account))
        XCTAssertEqual(KeychainStore.get(account: account), "second-value-5678")
        // Whitespace is trimmed, and an empty value removes the entry.
        XCTAssertTrue(KeychainStore.set("  padded  ", account: account))
        XCTAssertEqual(KeychainStore.get(account: account), "padded")
        XCTAssertTrue(KeychainStore.set("", account: account))
        XCTAssertNil(KeychainStore.get(account: account))
    }

    func testRedactionKeepsOnlyTheTail() {
        XCTAssertEqual(KeychainStore.redacted("abcdefghij"), "••••••ghij")
        XCTAssertEqual(KeychainStore.redacted("abc"), "••••")
        XCTAssertEqual(KeychainStore.redacted(nil), "")
    }
}

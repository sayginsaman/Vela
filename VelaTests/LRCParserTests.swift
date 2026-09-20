import XCTest
@testable import Vela

final class LRCParserTests: XCTestCase {
    func testParsesTimestampVariants() {
        XCTAssertEqual(LRCParser.seconds(from: "00:12.50"), 12.5)
        XCTAssertEqual(LRCParser.seconds(from: "01:02.345")!, 62.345, accuracy: 0.0001)
        XCTAssertEqual(LRCParser.seconds(from: "02:03"), 123)
        XCTAssertEqual(LRCParser.seconds(from: "1:00:01.5"), 3601.5)
        XCTAssertEqual(LRCParser.seconds(from: "00:12,5"), 12.5)
        XCTAssertNil(LRCParser.seconds(from: "ti:Song"))
        XCTAssertNil(LRCParser.seconds(from: "abc"))
    }

    func testParsesLineSyncedDocument() throws {
        let text = """
        [ti:Test]
        [ar:Someone]
        [00:01.00]First line here
        [00:04.50]Second line, longer
        [00:08.00]
        [00:10.00]Third
        """
        let doc = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(doc.quality, .lineSynced)
        XCTAssertEqual(doc.lines.count, 4)
        XCTAssertEqual(doc.lines[0].start, 1.0)
        // The line lasts as long as it would take to sing, not until the next line starts.
        XCTAssertGreaterThan(doc.lines[0].end, 1.0)
        XCTAssertLessThan(doc.lines[0].end, 4.5)
        XCTAssertEqual(doc.lines[1].text, "Second line, longer")
        XCTAssertTrue(doc.lines[2].isEmpty)
        XCTAssertEqual(doc.sungLines.count, 3)
        // Words estimated across the line.
        XCTAssertEqual(doc.lines[0].words.count, 3)
        XCTAssertTrue(doc.lines[0].words.allSatisfy(\.isEstimated))
        XCTAssertEqual(doc.lines[0].words.first?.start, 1.0)
        XCTAssertLessThanOrEqual(doc.lines[0].words.last!.end, doc.lines[0].end)
    }

    func testMultipleTimestampsPerLineAndSorting() throws {
        let text = "[00:20.00][00:05.00]Chorus\n[00:10.00]Verse"
        let doc = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(doc.lines.map(\.start), [5, 10, 20])
        XCTAssertEqual(doc.lines.map(\.text), ["Chorus", "Verse", "Chorus"])
    }

    func testOffsetTagShiftsTimes() throws {
        let text = "[offset:500]\n[00:10.00]Line"
        let doc = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(doc.lines[0].start, 9.5, accuracy: 0.0001)
    }

    func testEnhancedWordTimingsAreUsedVerbatim() throws {
        let text = """
        [00:10.00] <00:10.00>Salt <00:10.40>on <00:10.60>the <00:11.00>wire
        [00:12.00] <00:12.00>Second <00:12.80>line
        """
        let doc = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(doc.quality, .wordSynced)
        let words = doc.lines[0].words
        XCTAssertEqual(words.map(\.text), ["Salt", "on", "the", "wire"])
        XCTAssertEqual(words.map(\.start), [10.0, 10.4, 10.6, 11.0])
        XCTAssertEqual(words[0].end, 10.4)
        XCTAssertEqual(words[3].end, 12.0)   // last word ends where next line starts
        XCTAssertFalse(words.contains { $0.isEstimated })
        XCTAssertEqual(doc.lines[0].text, "Salt on the wire")
    }

    func testMixedDocumentIsWordSyncedOnlyWhereTagsExist() throws {
        let text = """
        [00:01.00] <00:01.00>Tagged <00:01.50>words
        [00:03.00]Untagged line
        """
        let doc = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(doc.quality, .wordSynced)
        XCTAssertFalse(doc.lines[0].words[0].isEstimated)
        XCTAssertTrue(doc.lines[1].words[0].isEstimated)
    }

    func testPlainTextBecomesUnsyncedDocument() {
        let doc = LRCParser.plain("One\n\n\nTwo\nThree\n")
        XCTAssertEqual(doc.quality, .unsynced)
        XCTAssertFalse(doc.isSynced)
        XCTAssertEqual(doc.lines.map(\.text), ["One", "", "Two", "Three"])
    }

    func testNoTimestampsReturnsNil() {
        XCTAssertNil(LRCParser.parse("Just some words\nno timing at all"))
    }

    func testUnicodeAndEmojiSurvive() throws {
        let text = "[00:01.00]Gökyüzü açıldı, şehir sessiz ✨\n[00:03.00]שלום עולם"
        let doc = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(doc.lines[0].words.map(\.text), ["Gökyüzü", "açıldı,", "şehir", "sessiz", "✨"])
        XCTAssertFalse(doc.lines[0].isRightToLeft)
        XCTAssertTrue(doc.lines[1].isRightToLeft)
    }
}

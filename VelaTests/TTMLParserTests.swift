import XCTest
@testable import Vela

final class TTMLParserTests: XCTestCase {
    /// Mirrors the real AMLL shape: syllables inside words, whitespace between words, a span
    /// holding two words, and a background-vocal group.
    private let fixture = #"""
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:amll="http://www.example.com/ns/amll">
    <head><metadata xmlns=""><amll:meta key="spotifyId" value="7mykoq6R3BArsSpNDjFQTm"/></metadata></head>
    <body dur="00:20.000"><div xmlns="" begin="00:01.176" end="00:07.000">
    <p begin="00:01.176" end="00:03.000" ttm:agent="v1"><span begin="00:01.176" end="00:01.408">I</span> <span begin="00:01.408" end="00:01.649">coul</span><span begin="00:01.649" end="00:01.883">dn't</span> <span begin="00:01.883" end="00:02.158">wait</span> <span begin="00:02.158" end="00:02.654">but a</span></p>
    <p begin="00:05.000" end="00:07.000" ttm:agent="v1"><span begin="00:05.000" end="00:05.500">Second</span> <span begin="00:05.500" end="00:06.000">line</span><span ttm:role="x-bg"><span begin="00:05.600" end="00:05.900">(ooh)</span></span></p>
    </div></body></tt>
    """#

    func testParsesClockValues() {
        XCTAssertEqual(TTMLParser.seconds(from: "00:01.176")!, 1.176, accuracy: 0.0001)
        XCTAssertEqual(TTMLParser.seconds(from: "1:02:03.5")!, 3723.5, accuracy: 0.0001)
        XCTAssertEqual(TTMLParser.seconds(from: "12.5s")!, 12.5, accuracy: 0.0001)
        XCTAssertEqual(TTMLParser.seconds(from: "750ms")!, 0.75, accuracy: 0.0001)
        XCTAssertEqual(TTMLParser.seconds(from: "42")!, 42, accuracy: 0.0001)
        XCTAssertNil(TTMLParser.seconds(from: nil))
        XCTAssertNil(TTMLParser.seconds(from: ""))
        XCTAssertNil(TTMLParser.seconds(from: "later"))
    }

    func testMergesSyllablesIntoWordsAndSkipsBackingVocals() throws {
        let doc = try XCTUnwrap(TTMLParser.parse(Data(fixture.utf8), provenance: "amll"))
        XCTAssertEqual(doc.quality, .wordSynced)
        XCTAssertEqual(doc.provenance, "amll")
        XCTAssertEqual(doc.lines.count, 2)

        let first = doc.lines[0]
        XCTAssertEqual(first.words.map(\.text), ["I", "couldn't", "wait", "but a"])
        // The merged word spans both of its syllables.
        let couldnt = first.words[1]
        XCTAssertEqual(couldnt.start, 1.408, accuracy: 0.0001)
        XCTAssertEqual(couldnt.end, 1.883, accuracy: 0.0001)
        XCTAssertFalse(first.words.contains { $0.isEstimated })
        XCTAssertEqual(first.text, "I couldn't wait but a")
        XCTAssertEqual(first.start, 1.176, accuracy: 0.0001)

        // Background vocals are dropped rather than duplicated on screen.
        XCTAssertEqual(doc.lines[1].words.map(\.text), ["Second", "line"])
    }

    func testWordsAreOrderedAndInsideTheirLine() throws {
        let doc = try XCTUnwrap(TTMLParser.parse(Data(fixture.utf8)))
        for line in doc.lines {
            XCTAssertEqual(line.words.map(\.start), line.words.map(\.start).sorted())
            for word in line.words {
                XCTAssertGreaterThanOrEqual(word.start, line.start - 0.0001)
                XCTAssertLessThanOrEqual(word.end, line.end + 0.0001)
                XCTAssertLessThanOrEqual(word.start, word.end)
            }
        }
        // The document drives the timeline exactly like any other word-synced source.
        var timeline = LyricTimeline(document: doc)
        let position = timeline.locate(at: 1.5)
        XCTAssertEqual(position.lineIndex, 0)
        XCTAssertEqual(position.wordIndex, 1, "mid-word on \"couldn't\"")
    }

    func testRejectsRubbish() {
        XCTAssertNil(TTMLParser.parse(Data("not xml at all".utf8)))
        XCTAssertNil(TTMLParser.parse(Data("<tt><body></body></tt>".utf8)), "no lines means no document")
    }
}

import XCTest
@testable import Vela

final class WordStackTests: XCTestCase {
    private func box() -> LyricTimelineBox {
        let text = """
        [00:10.00] <00:10.00>Salt <00:10.50>on <00:11.00>the <00:11.50>wire
        [00:12.00] <00:12.00>Second <00:12.50>line
        [00:30.00] <00:30.00>After <00:30.50>a <00:31.00>break
        """
        return LyricTimelineBox(document: LRCParser.parse(text)!)
    }

    func testFlatIndexingCoversEveryWordInOrder() {
        let b = box()
        XCTAssertEqual(b.flatWords.map(\.word.text), ["Salt", "on", "the", "wire", "Second", "line", "After", "a", "break"])
        XCTAssertEqual(b.flatIndex(sungLine: 1, word: 1), 5)
        XCTAssertEqual(b.firstFlatIndex(ofSungLine: 2), 6)
        XCTAssertNil(b.flatIndex(sungLine: 3, word: 0))
        XCTAssertNil(b.flatIndex(sungLine: 0, word: 9))
    }

    func testAnchorFollowsTheSungWordAndBreaks() {
        let b = box()
        let sung = WordStackLayout.anchor(position: b.locate(at: 11.1), box: b)
        XCTAssertEqual(sung.index, 2)
        XCTAssertTrue(sung.isCurrent)

        let before = WordStackLayout.anchor(position: b.locate(at: 2), box: b)
        XCTAssertEqual(before.index, 0)
        XCTAssertFalse(before.isCurrent)

        // Long gap after the second line: centre the first word of the next line, not current.
        var doc = b.document
        doc.lines[1].end = 14
        doc.lines[1].words = WordTimingEstimator.estimateWords(for: "Second line", start: 12, end: 14)
        let gapped = LyricTimelineBox(document: doc)
        let inBreak = WordStackLayout.anchor(position: gapped.locate(at: 20), box: gapped)
        XCTAssertEqual(inBreak.index, 6)
        XCTAssertFalse(inBreak.isCurrent)
    }

    func testSizeFactorGrowsWithDurationAndIsCapped() {
        XCTAssertEqual(WordStackLayout.sizeFactor(duration: 0.4, median: 0.4), 1, accuracy: 0.0001)
        XCTAssertGreaterThan(WordStackLayout.sizeFactor(duration: 1.2, median: 0.4), 1.4)
        XCTAssertEqual(WordStackLayout.sizeFactor(duration: 10, median: 0.4), 1.6)
        XCTAssertEqual(WordStackLayout.sizeFactor(duration: 0.05, median: 0.4), 0.82)
        XCTAssertEqual(WordStackLayout.medianDuration(of: []), 0.4)
    }

    func testIconLookupNormalisesWords() {
        XCTAssertEqual(WordIconMap.symbol(for: "Heart,"), "heart.fill")
        XCTAssertEqual(WordIconMap.symbol(for: "CARS"), "car.fill")
        XCTAssertEqual(WordIconMap.symbol(for: "calling"), "phone.fill")
        XCTAssertEqual(WordIconMap.symbol(for: "lanterns"), "lamp.floor.fill")
        XCTAssertNil(WordIconMap.symbol(for: "the"))
        XCTAssertNil(WordIconMap.symbol(for: "…"))
    }
}

import XCTest
@testable import Vela

final class WordTimingEstimatorTests: XCTestCase {
    func testWordsCoverLineSpanMonotonically() {
        let words = WordTimingEstimator.estimateWords(for: "Every window down the harbor", start: 10, end: 14)
        XCTAssertEqual(words.count, 5)
        XCTAssertEqual(words.first?.start, 10)
        XCTAssertLessThanOrEqual(words.last!.end, 14)
        XCTAssertGreaterThan(words.last!.end, 13.0) // most of the line is used; a breath is left
        for pair in zip(words, words.dropFirst()) {
            XCTAssertEqual(pair.0.end, pair.1.start, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(pair.0.start, pair.0.end)
        }
        XCTAssertTrue(words.allSatisfy(\.isEstimated))
    }

    func testLongerWordsGetMoreTime() {
        let words = WordTimingEstimator.estimateWords(for: "a extraordinary", start: 0, end: 2)
        XCTAssertLessThan(words[0].duration, words[1].duration)
    }

    func testPunctuationAddsPause() {
        let plain = WordTimingEstimator.estimateWords(for: "wait here now", start: 0, end: 3)
        let paused = WordTimingEstimator.estimateWords(for: "wait, here now", start: 0, end: 3)
        XCTAssertGreaterThan(paused[0].duration, plain[0].duration)
    }

    func testShortLineHasNoBreath() {
        let words = WordTimingEstimator.estimateWords(for: "Stay", start: 5, end: 6)
        XCTAssertEqual(words.last!.end, 6, accuracy: 0.0001)
    }

    func testEmptyLineYieldsNoWords() {
        XCTAssertTrue(WordTimingEstimator.estimateWords(for: "   ", start: 0, end: 1).isEmpty)
    }

    func testIDsAreSequentialFromFirstID() {
        let words = WordTimingEstimator.estimateWords(for: "one two three", start: 0, end: 1, firstID: 40)
        XCTAssertEqual(words.map(\.id), [40, 41, 42])
    }
}

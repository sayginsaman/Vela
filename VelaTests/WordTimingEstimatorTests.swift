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

    // MARK: Singing-rate model

    func testSyllableCounting() {
        XCTAssertEqual(WordTimingEstimator.syllableCount(in: "wire"), 1)
        XCTAssertEqual(WordTimingEstimator.syllableCount(in: "humming"), 2)
        XCTAssertEqual(WordTimingEstimator.syllableCount(in: "I"), 1)
        XCTAssertEqual(WordTimingEstimator.syllableCount(in: "concrete"), 2)
        XCTAssertEqual(WordTimingEstimator.syllableCount(in: "Gökyüzü"), 3)
        XCTAssertEqual(WordTimingEstimator.syllableCount(in: "✨"), 0, "no letters, no syllables")
        XCTAssertEqual(WordTimingEstimator.syllableCount(inLine: "Salt on the wire"), 4)
    }

    func testRateEstimateNeedsEnoughSamplesAndIsClamped() {
        XCTAssertEqual(WordTimingEstimator.estimateRate(syllablesPerGap: [5, 6]), WordTimingEstimator.defaultRate)
        // Continuously sung lines cluster at the true rate; padded lines sit below it.
        let rate = WordTimingEstimator.estimateRate(syllablesPerGap: [0.4, 0.6, 4.0, 4.1, 4.2, 4.3])
        XCTAssertEqual(rate, 4.2, accuracy: 0.3)
        XCTAssertEqual(WordTimingEstimator.estimateRate(syllablesPerGap: [40, 50, 60, 70]), WordTimingEstimator.rateRange.upperBound)
        XCTAssertEqual(WordTimingEstimator.estimateRate(syllablesPerGap: [0.1, 0.2, 0.3, 0.4]), WordTimingEstimator.rateRange.lowerBound)
    }

    func testSungSpanNeverStretchesAcrossAGapAndNeverOverrunsIt() {
        let line = "It says your name in every wave"
        // A long instrumental follows: the line takes its natural length, not the whole gap.
        let long = WordTimingEstimator.sungSpan(of: line, gap: 18, rate: 4.0)
        XCTAssertLessThan(long, 4)
        XCTAssertGreaterThan(long, 1.5)
        // A tight gap wins over the natural length, so lines never overlap.
        let tight = WordTimingEstimator.sungSpan(of: line, gap: 1.2, rate: 4.0)
        XCTAssertEqual(tight, 1.2, accuracy: 0.0001)
        // No following line: the natural length applies.
        XCTAssertEqual(WordTimingEstimator.sungSpan(of: line, gap: nil, rate: 4.0),
                       WordTimingEstimator.naturalDuration(of: line, rate: 4.0), accuracy: 0.0001)
        // Faster singing means shorter lines.
        XCTAssertLessThan(WordTimingEstimator.sungSpan(of: line, gap: 18, rate: 8),
                          WordTimingEstimator.sungSpan(of: line, gap: 18, rate: 3))
    }

    func testLineSyncedLyricsDoNotDriftLateAcrossAnInstrumental() throws {
        // Four sung lines, then an eighteen-second instrumental before the next section.
        let text = """
        [00:10.00]Salt on the wire a slow light humming
        [00:14.00]Every window down the harbor still coming on
        [00:18.00]I keep the radio low so the tide can talk
        [00:22.00]It says your name in every wave
        [00:40.00]After the break
        """
        let doc = try XCTUnwrap(LRCParser.parse(text))
        let beforeInstrumental = doc.lines[3]
        XCTAssertLessThan(beforeInstrumental.end - beforeInstrumental.start, 5,
                          "a two-second line must not be stretched over an eighteen-second gap")
        XCTAssertLessThanOrEqual(beforeInstrumental.words.last!.end, beforeInstrumental.end)
        // Every line still ends before the next one begins, and words stay inside their line.
        for (index, line) in doc.lines.enumerated() {
            XCTAssertLessThanOrEqual(line.end, index + 1 < doc.lines.count ? doc.lines[index + 1].start : .greatestFiniteMagnitude)
            for word in line.words {
                XCTAssertGreaterThanOrEqual(word.start, line.start)
                XCTAssertLessThanOrEqual(word.end, line.end + 0.0001)
            }
        }
        // The gap is now visible to the timeline as an instrumental break.
        var timeline = LyricTimeline(document: doc)
        XCTAssertTrue(timeline.locate(at: 32).isInBreak)
    }

    func testRealWordTimingsAreNotCapped() throws {
        // Enhanced LRC carries true timings; a long final word must keep its full length.
        let text = """
        [00:10.00] <00:10.00>Swish
        [00:20.00] <00:20.00>Next
        """
        let doc = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(doc.quality, .wordSynced)
        XCTAssertEqual(doc.lines[0].end, 20, "word-synced lines run to the next line")
        XCTAssertEqual(doc.lines[0].words[0].end, 20)
    }

    func testIDsAreSequentialFromFirstID() {
        let words = WordTimingEstimator.estimateWords(for: "one two three", start: 0, end: 1, firstID: 40)
        XCTAssertEqual(words.map(\.id), [40, 41, 42])
    }
}

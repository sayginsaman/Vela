import XCTest
@testable import Vela

final class LyricTimelineTests: XCTestCase {
    private func document() -> LyricDocument {
        let text = """
        [00:10.00] <00:10.00>Salt <00:10.50>on <00:11.00>the <00:11.50>wire
        [00:12.00] <00:12.00>Second <00:12.50>line <00:13.00>here
        [00:14.00] <00:14.00>Third <00:14.50>one
        [00:30.00] <00:30.00>After <00:30.50>a <00:31.00>long <00:31.50>break
        """
        return LRCParser.parse(text)!
    }

    func testBeforeFirstLine() {
        var timeline = LyricTimeline(document: document())
        let position = timeline.locate(at: 2)
        XCTAssertNil(position.lineIndex)
        XCTAssertNil(position.wordIndex)
        XCTAssertTrue(position.isInBreak)          // 8 seconds until the first line
        XCTAssertEqual(position.timeUntilNextLine!, 8, accuracy: 0.0001)
        XCTAssertFalse(timeline.locate(at: 9).isInBreak)
    }

    func testActiveWordProgressesWithinLine() {
        var timeline = LyricTimeline(document: document())
        let a = timeline.locate(at: 10.25)
        XCTAssertEqual(a.lineIndex, 0)
        XCTAssertEqual(a.wordIndex, 0)
        XCTAssertEqual(a.wordProgress, 0.5, accuracy: 0.0001)

        let b = timeline.locate(at: 11.1)
        XCTAssertEqual(b.wordIndex, 2)
        XCTAssertEqual(b.wordProgress, 0.2, accuracy: 0.0001)

        let c = timeline.locate(at: 11.9)
        XCTAssertEqual(c.wordIndex, 3)
        XCTAssertEqual(c.wordProgress, 0.8, accuracy: 0.0001)
    }

    func testSequentialPlaybackAdvancesLines() {
        var timeline = LyricTimeline(document: document())
        var lines: [Int?] = []
        var t = 9.5
        while t < 15 {
            lines.append(timeline.locate(at: t).lineIndex)
            t += 0.25
        }
        XCTAssertEqual(lines.first!, nil)
        XCTAssertTrue(lines.contains(0) && lines.contains(1) && lines.contains(2))
        // Never moves backwards while time moves forward.
        let concrete = lines.compactMap { $0 }
        XCTAssertEqual(concrete, concrete.sorted())
    }

    func testSeekForwardFarAhead() {
        var timeline = LyricTimeline(document: document())
        _ = timeline.locate(at: 10.1)
        let position = timeline.locate(at: 31.2)
        XCTAssertEqual(position.lineIndex, 3)
        XCTAssertEqual(position.wordIndex, 2)
        XCTAssertEqual(position.wordProgress, 0.4, accuracy: 0.0001)
    }

    func testSeekBackward() {
        var timeline = LyricTimeline(document: document())
        _ = timeline.locate(at: 31)
        let position = timeline.locate(at: 12.6)
        XCTAssertEqual(position.lineIndex, 1)
        XCTAssertEqual(position.wordIndex, 1)
        // And again inside the same line further back.
        let earlier = timeline.locate(at: 12.1)
        XCTAssertEqual(earlier.wordIndex, 0)
    }

    func testInstrumentalBreakBetweenLines() {
        var timeline = LyricTimeline(document: document())
        // Third line ends at 30 (next line's start) — its words fill up to 30 because the
        // parser extends the last word to the next line. Progress reaches 1 near the end.
        let late = timeline.locate(at: 29)
        XCTAssertEqual(late.lineIndex, 2)
        XCTAssertFalse(late.isInBreak)
        XCTAssertEqual(late.timeUntilNextLine!, 1, accuracy: 0.0001)
    }

    func testBreakDetectionWithExplicitLineEnd() {
        // Line-synced files: the line ends when the next starts, so a gap can only be seen when
        // the last word ends early. Build one by hand.
        var doc = document()
        doc.lines[2].end = 16
        doc.lines[2].words = WordTimingEstimator.estimateWords(for: "Third one", start: 14, end: 16)
        var timeline = LyricTimeline(document: doc)
        let position = timeline.locate(at: 20)
        XCTAssertEqual(position.lineIndex, 2)
        XCTAssertNil(position.wordIndex)
        XCTAssertTrue(position.isInBreak)
        XCTAssertEqual(position.timeUntilNextLine!, 10, accuracy: 0.0001)
    }

    func testEmptyDocument() {
        var timeline = LyricTimeline(document: .empty)
        XCTAssertTrue(timeline.isEmpty)
        XCTAssertEqual(timeline.locate(at: 5), .none)
    }

    func testTimingOffsetShiftsLookup() {
        var timeline = LyricTimeline(document: document())
        let playbackPosition = 9.7
        XCTAssertNil(timeline.locate(at: playbackPosition + 0).lineIndex)
        // Positive offset looks further ahead in the song, so lyrics appear earlier.
        XCTAssertEqual(timeline.locate(at: playbackPosition + 0.5).lineIndex, 0)
        // Negative offset delays them.
        XCTAssertEqual(timeline.locate(at: 12.2 - 0.5).lineIndex, 0)
        XCTAssertEqual(timeline.locate(at: 12.2 + 0).lineIndex, 1)
    }
}

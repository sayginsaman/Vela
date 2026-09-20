import XCTest
@testable import Vela

final class WordAlignerTests: XCTestCase {
    /// Eight words estimated evenly across ten seconds, the usual line-synced starting point.
    private func estimated() -> [TimedWord] {
        let text = ["Salt", "on", "the", "wire", "a", "slow", "light", "humming"]
        return text.enumerated().map { index, word in
            TimedWord(id: index, text: word, start: Double(index) * 1.25,
                      end: Double(index) * 1.25 + 1.25, isEstimated: true)
        }
    }

    func testSimilarity() {
        XCTAssertEqual(WordAligner.similarity("wire", "wire"), 1)
        XCTAssertEqual(WordAligner.similarity("humming", "huming"), 6.0 / 7.0, accuracy: 0.0001)
        XCTAssertEqual(WordAligner.similarity("salt", "pepper"), 0, accuracy: 0.2)
        XCTAssertEqual(WordAligner.similarity("", ""), 1)
        XCTAssertEqual(WordAligner.similarity("a", ""), 0)
    }

    func testNormalisation() {
        XCTAssertEqual(WordAligner.normalise("Don't!"), "dont")
        XCTAssertEqual(WordAligner.normalise("Gökyüzü,"), "gokyuzu")
        XCTAssertEqual(WordAligner.normalise("✨"), "")
    }

    func testAnchorsMatchDespiteMisrecognition() {
        let lyrics = estimated()
        // The recogniser got three words right, one nearly right, and invented one.
        let heard = [
            HeardWord(text: "salt", start: 0.2, end: 0.6),
            HeardWord(text: "wired", start: 3.1, end: 3.6),
            HeardWord(text: "banana", start: 5.0, end: 5.4),
            HeardWord(text: "humming", start: 8.4, end: 9.2),
        ]
        let pairs = WordAligner.anchors(lyrics: lyrics, heard: heard)
        XCTAssertEqual(pairs.map(\.lyric), [0, 3, 7])
        XCTAssertEqual(pairs.map(\.heard), [0, 1, 3])
    }

    func testAnchorsIgnoreWordsFarFromTheirEstimate() {
        let lyrics = estimated()
        // The right word, but forty seconds away: a different chorus, not this one.
        let heard = [HeardWord(text: "humming", start: 48, end: 48.5)]
        XCTAssertTrue(WordAligner.anchors(lyrics: lyrics, heard: heard).isEmpty)
        XCTAssertFalse(WordAligner.anchors(lyrics: lyrics, heard: heard, tolerance: 60).isEmpty)
    }

    func testAlignPinsHeardWordsAndSharesOutTheRest() {
        let lyrics = estimated()
        let heard = [
            HeardWord(text: "salt", start: 1.0, end: 1.4),
            HeardWord(text: "humming", start: 9.0, end: 9.8),
        ]
        let result = WordAligner.align(lyrics: lyrics, heard: heard)
        XCTAssertEqual(result.anchorCount, 2)
        XCTAssertEqual(result.anchoredFraction, 0.25, accuracy: 0.0001)

        // Anchors land exactly where they were heard and are no longer marked estimated.
        XCTAssertEqual(result.words[0].start, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.words[0].end, 1.4, accuracy: 0.0001)
        XCTAssertFalse(result.words[0].isEstimated)
        XCTAssertEqual(result.words[7].start, 9.0, accuracy: 0.0001)
        XCTAssertFalse(result.words[7].isEstimated)

        // Everything between is inside the anchored span, in order, and still flagged estimated.
        for index in 1..<7 {
            XCTAssertGreaterThanOrEqual(result.words[index].start, 1.4 - 0.0001)
            XCTAssertLessThanOrEqual(result.words[index].end, 9.0 + 0.0001)
            XCTAssertTrue(result.words[index].isEstimated)
        }
        XCTAssertEqual(result.words.map(\.start), result.words.map(\.start).sorted())
    }

    func testLongerWordsGetMoreOfTheGap() {
        // "a" (1 syllable) and "extraordinary" (5) share the span between two anchors.
        let text = ["start", "a", "extraordinary", "finish"]
        let lyrics = text.enumerated().map { index, word in
            TimedWord(id: index, text: word, start: Double(index) * 2, end: Double(index) * 2 + 2, isEstimated: true)
        }
        let heard = [HeardWord(text: "start", start: 0, end: 0.5),
                     HeardWord(text: "finish", start: 6, end: 6.5)]
        let result = WordAligner.align(lyrics: lyrics, heard: heard)
        XCTAssertEqual(result.anchorCount, 2)
        let short = result.words[1].end - result.words[1].start
        let long = result.words[2].end - result.words[2].start
        XCTAssertGreaterThan(long, short * 2, "five syllables should take far longer than one")
        XCTAssertEqual(short + long, 6.0 - 0.5, accuracy: 0.0001, "the pair fills the gap exactly")
    }

    func testNothingRecognisedLeavesTheLyricsAlone() {
        let lyrics = estimated()
        let result = WordAligner.align(lyrics: lyrics, heard: [HeardWord(text: "zzzz", start: 2, end: 2.4)])
        XCTAssertEqual(result.anchorCount, 0)
        XCTAssertEqual(result.words, lyrics)
        XCTAssertEqual(WordAligner.align(lyrics: [], heard: []), .none)
    }

    func testOutOfOrderRecognitionNeverProducesBackwardsTimings() {
        let lyrics = estimated()
        let heard = [
            HeardWord(text: "salt", start: 5.0, end: 5.4),
            HeardWord(text: "on", start: 1.0, end: 1.2),   // impossible: earlier than the one before
            HeardWord(text: "humming", start: 9.0, end: 9.4),
        ]
        let result = WordAligner.align(lyrics: lyrics, heard: heard)
        XCTAssertEqual(result.words.map(\.start), result.words.map(\.start).sorted())
        for pair in zip(result.words, result.words.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.start, pair.1.start)
        }
    }

    func testApplyRebuildsLinesAndLabelsHonestly() throws {
        let document = try XCTUnwrap(LRCParser.parse("[00:00.00]Salt on the wire\n[00:05.00]a slow light humming"))
        let words = WordAligner.words(in: document)
        XCTAssertEqual(words.count, 8)

        // Mostly heard: the document may call itself word-synced.
        let confident = AlignmentResult(words: words, anchoredFraction: 0.8, anchorCount: 6)
        XCTAssertEqual(WordAligner.apply(confident, to: document).quality, .wordSynced)
        // Barely heard: it stays an estimate, and says so.
        let thin = AlignmentResult(words: words, anchoredFraction: 0.2, anchorCount: 2)
        let applied = WordAligner.apply(thin, to: document)
        XCTAssertEqual(applied.quality, .estimated)
        XCTAssertTrue(applied.provenance.hasSuffix("+aligned"))
        XCTAssertEqual(applied.lines.count, document.lines.count)
        XCTAssertEqual(applied.lines[0].words.count, 4)
    }
}

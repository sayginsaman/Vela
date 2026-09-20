import Foundation

/// A word the recogniser heard, in song time.
struct HeardWord: Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    /// Recogniser confidence, 0…1. Zero means "unknown", which is common and not disqualifying.
    var confidence: Double = 0
}

/// The outcome of aligning what was heard against the lyrics we already have.
struct AlignmentResult: Equatable, Sendable {
    var words: [TimedWord]
    /// Fraction of lyric words that were pinned to something actually heard, 0…1.
    var anchoredFraction: Double
    var anchorCount: Int

    static let none = AlignmentResult(words: [], anchoredFraction: 0, anchorCount: 0)
}

/// Aligns recognised speech against known lyrics to recover real word timings.
///
/// Recognition of sung audio is poor on its own, but we are not trying to read the words: we
/// already have them. Every word the recogniser gets right becomes a timing anchor, and the words
/// between anchors are redistributed by syllable weight. A song where only a third of the words
/// come back still gets a far better timeline than one estimated from line stamps alone.
///
/// Everything here is pure and deterministic, so it can be tested without audio or a microphone.
enum WordAligner {
    /// A heard word is only considered against lyric words within this much of its current
    /// estimate, which keeps repeated choruses from stealing each other's anchors.
    static let defaultTolerance: TimeInterval = 10
    /// Below this similarity two words are not the same word.
    static let matchThreshold = 0.72

    // MARK: Normalisation

    static func normalise(_ word: String) -> String {
        word.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// 1 for identical, 0 for nothing in common. Levenshtein distance over the longer length.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return a == b ? 1 : 0 }
        if a == b { return 1 }
        let lhs = Array(a), rhs = Array(b)
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        let distance = Double(previous[rhs.count])
        return max(0, 1 - distance / Double(max(lhs.count, rhs.count)))
    }

    // MARK: Alignment

    /// Pairs of (index into `lyrics`, index into `heard`) that the two sequences agree on.
    /// A banded Needleman-Wunsch: gaps are free at both ends, because what was heard usually
    /// covers only part of the song.
    static func anchors(lyrics: [TimedWord], heard: [HeardWord],
                        tolerance: TimeInterval = defaultTolerance) -> [(lyric: Int, heard: Int)] {
        guard !lyrics.isEmpty, !heard.isEmpty else { return [] }
        let lyricKeys = lyrics.map { normalise($0.text) }
        let heardKeys = heard.map { normalise($0.text) }

        let rows = lyrics.count, columns = heard.count
        // Most lyric words are never recognised, so passing one over is essentially free; a tiny
        // cost only breaks ties towards fewer skips. A *heard* word that matches nothing is a
        // recogniser error and has to cost something, otherwise the path drifts.
        let skipLyric = -0.001
        let skipHeard = -0.5
        var score = [[Double]](repeating: [Double](repeating: 0, count: columns + 1), count: rows + 1)
        // 0 = diagonal, 1 = up (skip a lyric word), 2 = left (skip a heard word)
        var back = [[UInt8]](repeating: [UInt8](repeating: 0, count: columns + 1), count: rows + 1)
        for i in 1...rows { score[i][0] = 0; back[i][0] = 1 }
        for j in 1...columns { score[0][j] = 0; back[0][j] = 2 }

        for i in 1...rows {
            for j in 1...columns {
                // Out of time range is simply not a candidate pairing.
                let plausible = abs(heard[j - 1].start - lyrics[i - 1].start) <= tolerance
                let similarity = plausible ? similarity(lyricKeys[i - 1], heardKeys[j - 1]) : 0
                let matchScore = similarity >= matchThreshold ? similarity : skipHeard
                let diagonal = score[i - 1][j - 1] + matchScore
                let up = score[i - 1][j] + skipLyric
                let left = score[i][j - 1] + skipHeard
                if diagonal >= up && diagonal >= left {
                    score[i][j] = diagonal; back[i][j] = 0
                } else if up >= left {
                    score[i][j] = up; back[i][j] = 1
                } else {
                    score[i][j] = left; back[i][j] = 2
                }
            }
        }

        var pairs: [(lyric: Int, heard: Int)] = []
        var i = rows, j = columns
        while i > 0 && j > 0 {
            switch back[i][j] {
            case 0:
                let plausible = abs(heard[j - 1].start - lyrics[i - 1].start) <= tolerance
                if plausible, similarity(lyricKeys[i - 1], heardKeys[j - 1]) >= matchThreshold {
                    pairs.append((i - 1, j - 1))
                }
                i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        return pairs.reversed()
    }

    /// Applies what was heard to the lyric words, redistributing everything in between.
    static func align(lyrics: [TimedWord], heard: [HeardWord],
                      tolerance: TimeInterval = defaultTolerance) -> AlignmentResult {
        guard !lyrics.isEmpty else { return .none }
        let pairs = anchors(lyrics: lyrics, heard: heard, tolerance: tolerance)
        guard !pairs.isEmpty else { return AlignmentResult(words: lyrics, anchoredFraction: 0, anchorCount: 0) }

        var words = lyrics
        // Pin the anchors, keeping both sequences moving forwards.
        var anchored: [Int: (start: TimeInterval, end: TimeInterval)] = [:]
        var lastTime = -Double.greatestFiniteMagnitude
        var ordered: [Int] = []
        for pair in pairs {
            let word = heard[pair.heard]
            guard word.start > lastTime else { continue }
            anchored[pair.lyric] = (word.start, max(word.start, word.end))
            ordered.append(pair.lyric)
            lastTime = word.start
        }
        guard !ordered.isEmpty else { return AlignmentResult(words: lyrics, anchoredFraction: 0, anchorCount: 0) }

        for index in ordered {
            guard let time = anchored[index] else { continue }
            words[index].start = time.start
            words[index].end = time.end
            words[index].isEstimated = false
        }

        // Between two anchors, share the span out by syllable weight.
        for (position, anchor) in ordered.enumerated() where position + 1 < ordered.count {
            let next = ordered[position + 1]
            guard next > anchor + 1 else { continue }
            distribute(&words, from: anchor, to: next)
        }
        // Before the first and after the last anchor, shift by the same correction so the run-in
        // and run-out stay consistent with what was actually heard.
        if let first = ordered.first {
            let delta = words[first].start - lyrics[first].start
            for index in 0..<first {
                words[index].start += delta
                words[index].end += delta
            }
        }
        if let last = ordered.last, last + 1 < words.count {
            let delta = words[last].start - lyrics[last].start
            for index in (last + 1)..<words.count {
                words[index].start += delta
                words[index].end += delta
            }
        }
        enforceMonotonic(&words)
        return AlignmentResult(words: words,
                               anchoredFraction: Double(ordered.count) / Double(lyrics.count),
                               anchorCount: ordered.count)
    }

    /// Spreads the words strictly between two anchors across the time they leave free.
    private static func distribute(_ words: inout [TimedWord], from anchor: Int, to next: Int) {
        let start = words[anchor].end
        let finish = words[next].start
        let span = finish - start
        let middle = (anchor + 1)..<next
        guard span > 0 else {
            for index in middle { words[index].start = start; words[index].end = start }
            return
        }
        let weights = middle.map { Double(max(1, WordTimingEstimator.syllableCount(in: words[$0].text))) }
        let total = weights.reduce(0, +)
        var cursor = start
        for (offset, index) in middle.enumerated() {
            let share = total > 0 ? weights[offset] / total : 1 / Double(middle.count)
            let end = cursor + span * share
            words[index].start = cursor
            words[index].end = end
            words[index].isEstimated = true
            cursor = end
        }
    }

    /// Timings must never go backwards, whatever the recogniser reported.
    static func enforceMonotonic(_ words: inout [TimedWord]) {
        var previousEnd = -Double.greatestFiniteMagnitude
        for index in words.indices {
            words[index].start = max(words[index].start, previousEnd)
            words[index].end = max(words[index].end, words[index].start)
            previousEnd = words[index].start
        }
    }

    // MARK: Documents

    /// Rebuilds a document with aligned words, keeping the line structure intact.
    static func apply(_ result: AlignmentResult, to document: LyricDocument) -> LyricDocument {
        guard !result.words.isEmpty else { return document }
        var byID: [Int: TimedWord] = [:]
        for word in result.words { byID[word.id] = word }
        var lines = document.lines
        for lineIndex in lines.indices {
            var words = lines[lineIndex].words
            for wordIndex in words.indices {
                if let aligned = byID[words[wordIndex].id] { words[wordIndex] = aligned }
            }
            guard let first = words.first, let last = words.last else { continue }
            lines[lineIndex].words = words
            lines[lineIndex].start = min(lines[lineIndex].start, first.start)
            lines[lineIndex].end = max(first.start, last.end)
        }
        var copy = document
        copy.lines = lines
        // Honest labelling: only call it word-synced when most of it really was heard.
        copy.quality = result.anchoredFraction >= 0.5 ? .wordSynced : .estimated
        copy.provenance = document.provenance + "+aligned"
        return copy
    }

    /// Every word in a document, in order, for feeding back into `align`.
    static func words(in document: LyricDocument) -> [TimedWord] {
        document.lines.flatMap(\.words)
    }
}

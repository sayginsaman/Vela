import Foundation

/// Efficient playhead lookup over a lyric document.
///
/// The timeline remembers the last located line and word so that consecutive lookups during
/// playback are O(1). Seeks in either direction fall back to binary search over line start times.
/// It is a value type; the owning view model keeps it in a `final class` box so per-frame lookups
/// don't trigger SwiftUI invalidation.
struct LyricTimeline: Sendable {
    let document: LyricDocument
    /// Only non-empty lines take part in lookup; `lineIndices` maps back to `document.lines`.
    private let lines: [LyricLine]
    private let lineIndices: [Int]
    private let starts: [TimeInterval]

    /// Gaps longer than this count as an instrumental break.
    static let breakThreshold: TimeInterval = 5.0

    private var lastLine: Int = 0
    private var lastWord: Int = 0

    init(document: LyricDocument) {
        self.document = document
        var kept: [LyricLine] = []
        var indices: [Int] = []
        for (index, line) in document.lines.enumerated() where !line.isEmpty {
            kept.append(line)
            indices.append(index)
        }
        lines = kept
        lineIndices = indices
        starts = kept.map(\.start)
    }

    var isEmpty: Bool { lines.isEmpty }
    var lineCount: Int { lines.count }

    /// Document-order lines with content (the ones the scene shows).
    var sungLines: [LyricLine] { lines }

    /// Locates the playhead. `time` is the effective lyric time (playback position + user offset).
    mutating func locate(at time: TimeInterval) -> LyricPosition {
        guard !lines.isEmpty else { return .none }

        let lineIndex = lineIndex(for: time)
        guard let lineIndex else {
            // Before the first line.
            let untilNext = starts[0] - time
            return LyricPosition(lineIndex: nil, wordIndex: nil, wordProgress: 0,
                                 isInBreak: untilNext > Self.breakThreshold, timeUntilNextLine: untilNext)
        }
        let line = lines[lineIndex]
        let nextStart: TimeInterval? = lineIndex + 1 < lines.count ? starts[lineIndex + 1] : nil
        let untilNext = nextStart.map { $0 - time }

        // Past the end of the line but before the next one.
        if time >= line.end, let untilNext, untilNext > Self.breakThreshold {
            lastLine = lineIndex
            lastWord = max(0, line.words.count - 1)
            return LyricPosition(lineIndex: lineIndices[lineIndex], wordIndex: nil, wordProgress: 1,
                                 isInBreak: true, timeUntilNextLine: untilNext)
        }

        let wordIndex = wordIndex(in: line, lineIndex: lineIndex, at: time)
        let progress: Double
        if let wordIndex {
            progress = line.words[wordIndex].progress(at: time)
        } else {
            progress = time >= line.end ? 1 : 0
        }
        lastLine = lineIndex
        lastWord = wordIndex ?? lastWord
        return LyricPosition(lineIndex: lineIndices[lineIndex], wordIndex: wordIndex, wordProgress: progress,
                             isInBreak: false, timeUntilNextLine: untilNext)
    }

    /// Index into `lines` of the most recently started line, or `nil` before the first one.
    private mutating func lineIndex(for time: TimeInterval) -> Int? {
        guard time >= starts[0] else { return nil }
        // Fast path: still inside the last line or the next one.
        if lastLine < lines.count, time >= starts[lastLine] {
            if lastLine + 1 >= lines.count || time < starts[lastLine + 1] { return lastLine }
            if lastLine + 2 >= lines.count || time < starts[lastLine + 2] { lastLine += 1; return lastLine }
        }
        // Binary search: last index with start <= time.
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= time { low = mid } else { high = mid - 1 }
        }
        lastLine = low
        lastWord = 0
        return low
    }

    private mutating func wordIndex(in line: LyricLine, lineIndex: Int, at time: TimeInterval) -> Int? {
        let words = line.words
        guard !words.isEmpty else { return nil }
        if time < words[0].start { return nil }
        if time >= words[words.count - 1].start { return words.count - 1 }
        var probe = (lineIndex == lastLine) ? min(lastWord, words.count - 1) : 0
        if time < words[probe].start { probe = 0 }
        // Sequential scan is cheap; lines are short.
        while probe + 1 < words.count, time >= words[probe + 1].start { probe += 1 }
        return probe
    }
}

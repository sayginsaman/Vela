import Foundation

/// How trustworthy the timestamps in a document are.
enum TimingQuality: String, Codable, Sendable, Comparable {
    /// Every word carries a real timestamp (enhanced LRC / word-level provider).
    case wordSynced
    /// Lines carry real timestamps; word timings were estimated by Vela.
    case lineSynced
    /// Both line and word timings are estimates.
    case estimated
    /// Plain text only; no timing information at all.
    case unsynced

    private var rank: Int {
        switch self {
        case .wordSynced: return 3
        case .lineSynced: return 2
        case .estimated: return 1
        case .unsynced: return 0
        }
    }

    static func < (lhs: TimingQuality, rhs: TimingQuality) -> Bool { lhs.rank < rhs.rank }
}

struct TimedWord: Hashable, Codable, Sendable, Identifiable {
    var id: Int
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    /// `true` when the timestamps were estimated rather than provided.
    var isEstimated: Bool

    var duration: TimeInterval { max(0, end - start) }

    func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return time >= start ? 1 : 0 }
        return min(1, max(0, (time - start) / duration))
    }
}

struct LyricLine: Hashable, Codable, Sendable, Identifiable {
    var id: Int
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var words: [TimedWord]

    var duration: TimeInterval { max(0, end - start) }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Heuristic: a line is right-to-left if its first strong character is Hebrew/Arabic-script.
    var isRightToLeft: Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            case 0x0041...0x024F, 0x0370...0x052F, 0x3040...0x30FF, 0x4E00...0x9FFF:
                return false
            default:
                continue
            }
        }
        return false
    }
}

struct LyricDocument: Hashable, Codable, Sendable {
    var lines: [LyricLine]
    var quality: TimingQuality
    /// Provider-declared instrumental flag.
    var isInstrumental: Bool
    /// Free-form provenance for diagnostics ("lrclib", "local", "demo", "cache").
    var provenance: String

    static let empty = LyricDocument(lines: [], quality: .unsynced, isInstrumental: false, provenance: "none")

    var isSynced: Bool { quality != .unsynced && !lines.isEmpty }

    /// Non-empty lines in playback order.
    var sungLines: [LyricLine] { lines.filter { !$0.isEmpty } }

    /// Plain text of the whole document, one line per entry.
    var plainLines: [String] { lines.map(\.text) }
}

/// Where the playhead sits inside a document.
struct LyricPosition: Hashable, Sendable {
    /// Index of the line the playhead is inside, or the most recently started line.
    var lineIndex: Int?
    /// Index of the active word inside `lineIndex`.
    var wordIndex: Int?
    /// Fill fraction (0...1) of the active word.
    var wordProgress: Double
    /// `true` while between lines and the gap is long enough to count as an instrumental break.
    var isInBreak: Bool
    /// Seconds until the next line starts, when known.
    var timeUntilNextLine: TimeInterval?

    static let none = LyricPosition(lineIndex: nil, wordIndex: nil, wordProgress: 0, isInBreak: false, timeUntilNextLine: nil)
}

import Foundation

/// Parses standard LRC (`[mm:ss.xx]`) and enhanced LRC (`<mm:ss.xx>` word tags).
///
/// The parser is intentionally forgiving: it accepts 1–3 fractional digits, missing fractions,
/// multiple timestamps per line, metadata tags, and a global `[offset:]` tag.
enum LRCParser {
    struct ParsedLine {
        var start: TimeInterval
        var text: String
        var words: [(text: String, start: TimeInterval)]?
    }

    /// Parses LRC text. Returns `nil` when the text contains no timestamps at all.
    static func parse(_ text: String) -> LyricDocument? {
        var offset: TimeInterval = 0
        var parsed: [ParsedLine] = []
        var sawWordTags = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let meta = metadata(in: line) {
                if meta.key == "offset", let ms = Double(meta.value.trimmingCharacters(in: .whitespaces)) {
                    // LRC offset is in milliseconds; positive means lyrics should appear earlier.
                    offset = ms / 1000
                }
                continue
            }
            let (timestamps, remainder) = leadingTimestamps(in: line)
            guard !timestamps.isEmpty else { continue }
            let (plain, words) = wordTags(in: remainder)
            if words != nil { sawWordTags = true }
            for stamp in timestamps {
                parsed.append(ParsedLine(start: stamp, text: plain, words: words))
            }
        }

        guard !parsed.isEmpty else { return nil }
        parsed.sort { $0.start < $1.start }

        var lines: [LyricLine] = []
        var wordID = 0
        for (index, item) in parsed.enumerated() {
            let start = max(0, item.start - offset)
            let nextStart = index + 1 < parsed.count ? max(0, parsed[index + 1].start - offset) : nil
            let end = nextStart ?? (start + WordTimingEstimator.estimatedLineDuration(for: item.text))
            let clampedEnd = max(start, end)
            var words: [TimedWord] = []
            if let tagged = item.words, !tagged.isEmpty {
                for (i, tag) in tagged.enumerated() {
                    let wordStart = max(start, tag.start - offset)
                    let wordEnd: TimeInterval
                    if i + 1 < tagged.count {
                        wordEnd = max(wordStart, tagged[i + 1].start - offset)
                    } else {
                        wordEnd = max(wordStart, clampedEnd)
                    }
                    words.append(TimedWord(id: wordID, text: tag.text, start: wordStart, end: wordEnd, isEstimated: false))
                    wordID += 1
                }
            } else {
                words = WordTimingEstimator.estimateWords(for: item.text, start: start, end: clampedEnd, firstID: wordID)
                wordID += words.count
            }
            lines.append(LyricLine(id: index, text: item.text, start: start, end: clampedEnd, words: words))
        }

        let quality: TimingQuality = sawWordTags ? .wordSynced : .lineSynced
        return LyricDocument(lines: lines, quality: quality, isInstrumental: false, provenance: "lrc")
    }

    /// Builds an unsynced document from plain text.
    static func plain(_ text: String, provenance: String = "plain") -> LyricDocument {
        let rawLines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var lines: [LyricLine] = []
        var wordID = 0
        for (index, text) in rawLines.enumerated() {
            let words = text.split(separator: " ").map { piece -> TimedWord in
                defer { wordID += 1 }
                return TimedWord(id: wordID, text: String(piece), start: 0, end: 0, isEstimated: true)
            }
            lines.append(LyricLine(id: index, text: text, start: 0, end: 0, words: words))
        }
        // Collapse runs of blank lines so paragraph spacing stays tidy.
        var collapsed: [LyricLine] = []
        for line in lines {
            if line.isEmpty, collapsed.last?.isEmpty == true { continue }
            collapsed.append(line)
        }
        while collapsed.first?.isEmpty == true { collapsed.removeFirst() }
        while collapsed.last?.isEmpty == true { collapsed.removeLast() }
        for i in collapsed.indices { collapsed[i].id = i }
        return LyricDocument(lines: collapsed, quality: .unsynced, isInstrumental: false, provenance: provenance)
    }

    // MARK: - Pieces

    /// Parses `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx`, and `h:mm:ss.xx` into seconds.
    static func seconds(from stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            let value: Double
            if index == parts.count - 1 {
                // seconds, may carry a fraction with '.' or ','
                let normalized = part.replacingOccurrences(of: ",", with: ".")
                guard let v = Double(normalized), v >= 0 else { return nil }
                value = v
            } else {
                guard let v = Double(part), v >= 0 else { return nil }
                value = v
            }
            total = total * 60 + value
        }
        return total
    }

    static func metadata(in line: String) -> (key: String, value: String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let inner = line[line.index(after: line.startIndex)..<close]
        guard let colon = inner.firstIndex(of: ":") else { return nil }
        let key = inner[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        // A timestamp looks like "00:12.30" — its key is numeric, so it is not metadata.
        guard !key.isEmpty, Double(key) == nil else { return nil }
        let value = String(inner[inner.index(after: colon)...])
        return (key, value)
    }

    static func leadingTimestamps(in line: String) -> ([TimeInterval], String) {
        var stamps: [TimeInterval] = []
        var rest = Substring(line)
        while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let inner = String(rest[rest.index(after: rest.startIndex)..<close])
            guard let seconds = seconds(from: inner) else { break }
            stamps.append(seconds)
            rest = rest[rest.index(after: close)...]
            while rest.first == " " { rest = rest.dropFirst() }
        }
        return (stamps, String(rest).trimmingCharacters(in: .whitespaces))
    }

    /// Splits `<mm:ss.xx>word <mm:ss.xx>word` into words. Returns `nil` when there are no tags.
    static func wordTags(in text: String) -> (String, [(text: String, start: TimeInterval)]?) {
        guard text.contains("<") else { return (text, nil) }
        var words: [(String, TimeInterval)] = []
        var plain = ""
        var current = ""
        var currentStart: TimeInterval?
        var index = text.startIndex
        var sawTag = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if let start = currentStart, !trimmed.isEmpty {
                for piece in trimmed.split(separator: " ") {
                    words.append((String(piece), start))
                }
            }
            current = ""
        }

        while index < text.endIndex {
            let ch = text[index]
            if ch == "<", let close = text[index...].firstIndex(of: ">") {
                let inner = String(text[text.index(after: index)..<close])
                if let stamp = seconds(from: inner) {
                    sawTag = true
                    flush()
                    currentStart = stamp
                    index = text.index(after: close)
                    continue
                }
            }
            current.append(ch)
            plain.append(ch)
            index = text.index(after: index)
        }
        flush()
        guard sawTag else { return (text, nil) }
        let cleaned = plain.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        return (cleaned, words.map { (text: $0.0, start: $0.1) })
    }
}

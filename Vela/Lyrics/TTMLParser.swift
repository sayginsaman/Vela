import Foundation

/// Parses Apple-Music-style TTML lyrics into a `LyricDocument`.
///
/// Each `<p>` is a line and each `<span>` carries a timestamped syllable. Word boundaries are
/// expressed as literal whitespace *between* spans, so `<span>no</span><span>thing</span>` is one
/// word and `<span>with</span> <span>no</span>` is two. Syllables are merged back into words
/// because Vela's model, and the word stack in particular, works a word at a time.
///
/// Background vocals (`ttm:role="x-bg"`) are skipped: they overlap the lead line and would
/// duplicate words on screen.
enum TTMLParser {
    static func parse(_ data: Data, provenance: String = "ttml") -> LyricDocument? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), !delegate.lines.isEmpty else { return nil }
        let lines = delegate.lines.sorted { $0.start < $1.start }
        var renumbered: [LyricLine] = []
        for (index, line) in lines.enumerated() {
            var copy = line
            copy.id = index
            renumbered.append(copy)
        }
        return LyricDocument(lines: renumbered, quality: .wordSynced, isInstrumental: false, provenance: provenance)
    }

    /// TTML clock values: `00:01.176`, `1:02:03.5`, `12.5s`, `750ms` or bare seconds.
    static func seconds(from value: String?) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasSuffix("ms") { return Double(raw.dropLast(2)).map { $0 / 1000 } }
        if raw.hasSuffix("s") { return Double(raw.dropLast()) }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part.replacingOccurrences(of: ",", with: ".")), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    // MARK: - SAX delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        private struct Frame {
            var begin: TimeInterval?
            var end: TimeInterval?
            var text = ""
            var isBackground: Bool
            /// A span holding other spans is a container, never a syllable itself.
            var hasChildSpan = false
        }
        private struct Syllable {
            var text: String
            var begin: TimeInterval
            var end: TimeInterval
            var startsWord: Bool
        }

        private(set) var lines: [LyricLine] = []
        private var wordID = 0
        private var inParagraph = false
        private var paragraphBegin: TimeInterval = 0
        private var paragraphEnd: TimeInterval?
        private var syllables: [Syllable] = []
        private var stack: [Frame] = []
        private var pendingBreak = true

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch element {
            case "p":
                inParagraph = true
                paragraphBegin = TTMLParser.seconds(from: attributes["begin"]) ?? 0
                paragraphEnd = TTMLParser.seconds(from: attributes["end"])
                syllables.removeAll(keepingCapacity: true)
                stack.removeAll(keepingCapacity: true)
                pendingBreak = true
            case "span":
                guard inParagraph else { return }
                if !stack.isEmpty { stack[stack.count - 1].hasChildSpan = true }
                let background = attributes["ttm:role"] == "x-bg" || stack.last?.isBackground == true
                stack.append(Frame(begin: TTMLParser.seconds(from: attributes["begin"]),
                                   end: TTMLParser.seconds(from: attributes["end"]),
                                   isBackground: background))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inParagraph else { return }
            if let last = stack.last, !last.hasChildSpan {
                stack[stack.count - 1].text += string
            } else if string.contains(where: { $0.isWhitespace }) {
                // Whitespace between sibling spans is what separates one word from the next.
                pendingBreak = true
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            switch element {
            case "span":
                guard inParagraph, let frame = stack.popLast() else { return }
                guard !frame.isBackground, !frame.hasChildSpan,
                      let begin = frame.begin, let end = frame.end,
                      !frame.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                syllables.append(Syllable(text: frame.text, begin: begin, end: max(begin, end), startsWord: pendingBreak))
                pendingBreak = false
            case "p":
                finishLine()
                inParagraph = false
            default:
                break
            }
        }

        private func finishLine() {
            var words: [TimedWord] = []
            for syllable in syllables {
                if words.isEmpty || syllable.startsWord {
                    words.append(TimedWord(id: wordID, text: syllable.text, start: syllable.begin,
                                           end: syllable.end, isEstimated: false))
                    wordID += 1
                } else {
                    var last = words.removeLast()
                    last.text += syllable.text
                    last.end = max(last.end, syllable.end)
                    words.append(last)
                }
            }
            words = words.compactMap { word in
                var copy = word
                copy.text = copy.text.trimmingCharacters(in: .whitespaces)
                return copy.text.isEmpty ? nil : copy
            }
            guard !words.isEmpty else { return }
            let start = min(paragraphBegin, words[0].start)
            let end = max(paragraphEnd ?? 0, words[words.count - 1].end)
            lines.append(LyricLine(id: lines.count, text: words.map(\.text).joined(separator: " "),
                                   start: start, end: max(start, end), words: words))
        }
    }
}

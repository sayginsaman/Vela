import Foundation

/// Distributes a line's time span across its words when only line timing is available.
///
/// Weights follow character count (a long word takes longer to sing), with extra weight for
/// trailing punctuation that usually implies a pause. A short tail of the line is left unsung so
/// consecutive lines read as phrases instead of a continuous fill.
enum WordTimingEstimator {
    /// Fraction of a line reserved as a breath at the end (only for lines longer than 1.5s).
    static let breathFraction = 0.08
    static let maximumBreath: TimeInterval = 0.6

    static func estimateWords(for text: String, start: TimeInterval, end: TimeInterval, firstID: Int = 0) -> [TimedWord] {
        let pieces = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !pieces.isEmpty else { return [] }
        let span = max(0, end - start)
        let breath = span > 1.5 ? min(maximumBreath, span * breathFraction) : 0
        let usable = max(0, span - breath)

        let weights = pieces.map(weight(for:))
        let total = weights.reduce(0, +)
        var cursor = start
        var words: [TimedWord] = []
        for (index, piece) in pieces.enumerated() {
            let share = total > 0 ? weights[index] / total : 1 / Double(pieces.count)
            let duration = usable * share
            let wordEnd = index == pieces.count - 1 ? start + usable : cursor + duration
            words.append(TimedWord(id: firstID + index, text: piece, start: cursor, end: max(cursor, wordEnd), isEstimated: true))
            cursor = wordEnd
        }
        return words
    }

    /// Relative singing weight of a word.
    static func weight(for word: String) -> Double {
        var letters = 0.0
        var punctuationPause = 0.0
        for scalar in word.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                letters += 1
            } else if scalar.properties.isEmoji && scalar.value > 0x2000 {
                letters += 2
            } else if ",;:".unicodeScalars.contains(scalar) {
                punctuationPause += 1.2
            } else if ".!?…".unicodeScalars.contains(scalar) {
                punctuationPause += 2.0
            }
        }
        // Even a one-letter word gets a floor so "I" or "a" is visible.
        return max(1.6, letters) + punctuationPause
    }

    /// Rough duration for a line whose end is unknown (last line of a file).
    static func estimatedLineDuration(for text: String) -> TimeInterval {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return min(8, max(2.0, Double(letters) * 0.11))
    }
}

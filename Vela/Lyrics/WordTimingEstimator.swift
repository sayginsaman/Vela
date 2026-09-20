import Foundation

/// Distributes a line's time span across its words when only line timing is available.
///
/// Line-synced lyrics say when a line *starts*, never when it ends. Spreading the words across
/// the whole gap to the next line makes them drift steadily late — and catastrophically so when
/// an instrumental follows, where a two-second line would be stretched over twenty. So each line
/// is given the time it would plausibly take to sing, derived from its syllable count and a
/// singing rate estimated from the song itself, and the remainder of the gap is left silent.
///
/// Within that span, words are weighted by length, with extra weight for trailing punctuation
/// that usually implies a pause, and a short breath is left at the end of longer lines.
enum WordTimingEstimator {
    /// Fraction of a line reserved as a breath at the end (only for lines longer than 1.5s).
    static let breathFraction = 0.08
    static let maximumBreath: TimeInterval = 0.6
    /// Held notes and drawn-out phrasing get a little room beyond the plain syllable estimate.
    static let naturalSlack = 1.2
    /// No line is given less than this, however few syllables it has.
    static let minimumLineDuration: TimeInterval = 0.7

    // MARK: Singing rate

    /// Syllables per second. The default suits mid-tempo pop; the range spans a slow ballad to
    /// a dense rap verse.
    static let defaultRate: Double = 3.6
    static let rateRange: ClosedRange<Double> = 2.0...9.5

    /// Syllables in a word, counted as vowel groups. Latin, Turkish and accented vowels count;
    /// a word with no letters at all (an emoji, say) counts as none.
    static func syllableCount(in word: String) -> Int {
        let vowels = Set("aeiouyàáâãäåæèéêëìíîïòóôõöøùúûüÿıİşğçñ")
        var count = 0
        var previousWasVowel = false
        var hasLetter = false
        for character in word.lowercased() {
            guard character.isLetter else { previousWasVowel = false; continue }
            hasLetter = true
            let isVowel = vowels.contains(character)
            if isVowel && !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }
        guard hasLetter else { return 0 }
        // English silent 'e': "wire" is one syllable, not two.
        if count > 1, word.lowercased().hasSuffix("e") { count -= 1 }
        return max(1, count)
    }

    static func syllableCount(inLine line: String) -> Int {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + syllableCount(in: String($1)) }
    }

    /// Estimates how fast this song is sung, in syllables per second, from its line timings.
    ///
    /// Lines that run straight into the next one are sung continuously, so their syllables-per-gap
    /// is close to the true rate. Lines followed by a pause have an artificially low ratio. Taking
    /// a high percentile therefore picks out the continuously sung lines without having to know in
    /// advance which ones they are.
    static func estimateRate(syllablesPerGap ratios: [Double]) -> Double {
        let usable = ratios.filter { $0.isFinite && $0 > 0 }.sorted()
        guard usable.count >= 3 else { return defaultRate }
        let index = min(usable.count - 1, Int((Double(usable.count - 1) * 0.75).rounded()))
        let rate = usable[index]
        return min(rateRange.upperBound, max(rateRange.lowerBound, rate))
    }

    /// How long this line would plausibly take to sing, ignoring whatever follows it.
    static func naturalDuration(of text: String, rate: Double) -> TimeInterval {
        let syllables = syllableCount(inLine: text)
        guard syllables > 0 else { return minimumLineDuration }
        return max(minimumLineDuration, Double(syllables) / max(0.5, rate) * naturalSlack)
    }

    /// The span a line actually occupies: its natural sung length, never spilling past the next
    /// line. `gap` is `nil` for the last line of a document.
    static func sungSpan(of text: String, gap: TimeInterval?, rate: Double) -> TimeInterval {
        let natural = naturalDuration(of: text, rate: rate)
        guard let gap else { return natural }
        return min(max(0, gap), natural)
    }

    // MARK: Words within a line

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
}

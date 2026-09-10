import SwiftUI

enum LineRole: Equatable {
    case past
    case current
    case upcoming
}

/// A single lyric line laid out word by word.
struct LyricLineView: View {
    let line: LyricLine
    let role: LineRole
    let activeWordIndex: Int?
    let wordProgress: Double
    let typography: LyricTypography
    let maxWidth: CGFloat

    private func state(for index: Int) -> WordState {
        switch role {
        case .past: return .completed
        case .upcoming: return .upcoming
        case .current:
            guard let activeWordIndex else { return .upcoming }
            if index < activeWordIndex { return .completed }
            if index == activeWordIndex { return .active(progress: wordProgress) }
            return .upcoming
        }
    }

    var body: some View {
        let words = line.isRightToLeft ? Array(line.words.reversed()) : line.words
        FlowLayout(spacing: typography.fontSize * 0.24, lineSpacing: typography.fontSize * 0.1) {
            ForEach(words) { word in
                let index = line.words.firstIndex(where: { $0.id == word.id }) ?? 0
                let wordState = state(for: index)
                // Only the word being sung receives per-frame beat values.
                let wordTypography: LyricTypography = {
                    if case .active = wordState { return typography }
                    return typography.still
                }()
                LyricWordView(text: word.text, state: wordState, typography: wordTypography, isCurrentLine: role == .current)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .frame(maxWidth: maxWidth)
        // A soft drop shadow lifts the sung line off bright artwork.
        .shadow(color: .black.opacity(role == .current && !typography.reduceEffects ? 0.32 : 0), radius: 16, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(role == .current ? "Current line: \(line.text)" : line.text)
    }
}

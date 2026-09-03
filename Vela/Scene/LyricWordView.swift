import SwiftUI

enum WordState: Equatable {
    case upcoming
    case active(progress: Double)
    case completed
}

/// Rendering context shared by every word in the stage.
struct LyricTypography: Equatable {
    var fontSize: CGFloat
    var style: LyricStyle
    var palette: Palette
    var reduceEffects: Bool
    var reduceMotion: Bool
    var increaseContrast: Bool

    func font(current: Bool) -> Font {
        .system(size: fontSize, weight: current ? .bold : .semibold, design: .default)
    }

    var upcomingOpacity: Double { increaseContrast ? 0.62 : 0.36 }
    var completedOpacity: Double { increaseContrast ? 1.0 : 0.9 }
    var primaryColor: Color { increaseContrast ? .white : palette.primary.swiftUIColor }
}

/// One word. Base text in the primary colour with a highlight layer that sweeps across as the
/// word is sung. Bloom and scale depend on the chosen lyric style.
struct LyricWordView: View {
    let text: String
    let state: WordState
    let typography: LyricTypography
    let isCurrentLine: Bool

    private var isActive: Bool { if case .active = state { return true } else { return false } }

    private var fill: Double {
        switch state {
        case .upcoming: return 0
        case .active(let progress): return progress
        case .completed: return 1
        }
    }

    private var baseOpacity: Double {
        switch state {
        case .upcoming: return typography.upcomingOpacity
        case .active: return typography.completedOpacity
        case .completed: return typography.completedOpacity
        }
    }

    private var highlightOpacity: Double {
        switch state {
        case .upcoming: return 0
        case .active: return 1
        case .completed:
            switch typography.style {
            case .focus: return 0.32
            case .drift: return 0.28
            case .bloom: return 0.5
            }
        }
    }

    private var bloomRadius: CGFloat {
        guard !typography.reduceEffects, isActive else { return 0 }
        switch typography.style {
        case .focus: return typography.fontSize * 0.22
        case .drift: return typography.fontSize * 0.25
        case .bloom: return typography.fontSize * 0.5
        }
    }

    private var bloomOpacity: Double {
        guard !typography.reduceEffects, isActive else { return 0 }
        switch typography.style {
        case .focus: return 0.5
        case .drift: return 0.5
        case .bloom: return 0.95
        }
    }

    private var scale: CGFloat {
        guard isActive, !typography.reduceMotion else { return 1 }
        switch typography.style {
        case .focus: return 1.035
        case .drift: return 1.03
        case .bloom: return 1.11
        }
    }

    var body: some View {
        let base = Text(text)
            .font(typography.font(current: isCurrentLine))
            .kerning(-typography.fontSize * 0.018)
        ZStack(alignment: .leading) {
            base.foregroundStyle(typography.primaryColor.opacity(baseOpacity))
            if highlightOpacity > 0 {
                base.foregroundStyle(typography.palette.highlight.swiftUIColor)
                    .mask(alignment: .leading) {
                        GeometryReader { proxy in
                            Rectangle().frame(width: proxy.size.width * fill)
                        }
                    }
                    .shadow(color: typography.palette.highlight.swiftUIColor.opacity(bloomOpacity), radius: bloomRadius)
                    .opacity(highlightOpacity)
            }
        }
        .fixedSize()
        .scaleEffect(scale)
        .animation(typography.reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.72), value: isActive)
        .animation(.easeOut(duration: 0.45), value: highlightOpacity)
        .accessibilityHidden(true)
    }
}

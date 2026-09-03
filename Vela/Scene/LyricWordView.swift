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
    /// Profile-driven motion (springs, scale, bloom, depth).
    var motion: LyricMotionStyle = .neutral
    /// Decaying beat pulse 0…1, quantised so it only invalidates the current line.
    var beatImpulse: Double = 0
    var beatCount: Int = 0

    /// A copy without per-frame values, for lines that are not being sung.
    var still: LyricTypography {
        var copy = self
        copy.beatImpulse = 0
        copy.beatCount = 0
        return copy
    }

    /// One weight for every role so a line never re-wraps when it becomes current; the current
    /// line is distinguished by colour, scale and bloom instead.
    func font(current: Bool) -> Font {
        .system(size: fontSize, weight: .bold, design: .default)
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

    private var bloomFactor: Double { 0.4 + 1.1 * typography.motion.activeWordBloom }

    private var bloomRadius: CGFloat {
        guard !typography.reduceEffects, isActive else { return 0 }
        let base: CGFloat
        switch typography.style {
        case .focus: base = typography.fontSize * 0.22
        case .drift: base = typography.fontSize * 0.25
        case .bloom: base = typography.fontSize * 0.5
        }
        return base * CGFloat(bloomFactor) * CGFloat(1 + 0.35 * typography.beatImpulse)
    }

    private var bloomOpacity: Double {
        guard !typography.reduceEffects, isActive else { return 0 }
        let base: Double
        switch typography.style {
        case .focus: base = 0.5
        case .drift: base = 0.5
        case .bloom: base = 0.95
        }
        return min(1, base * bloomFactor)
    }

    /// Base scale from the style and profile, plus a capped beat pulse so consecutive beats
    /// never grow the word beyond a fixed ceiling.
    private var scale: CGFloat {
        guard isActive else { return 1 }
        let styleScale: Double
        switch typography.style {
        case .focus: styleScale = 1.035
        case .drift: styleScale = 1.03
        case .bloom: styleScale = 1.11
        }
        let profileScale = typography.motion.activeWordScale
        let combined = 1 + (styleScale - 1) * 0.5 + (profileScale - 1)
        if typography.reduceMotion { return CGFloat(1 + (combined - 1) * 0.25) }
        let pulse = 0.05 * typography.beatImpulse * (typography.motion.activeWordScale - 1) / 0.05
        return CGFloat(min(1.16, combined + min(0.04, pulse)))
    }

    /// Short directional movement on beats (rap / trap), zero under Reduce Motion.
    private var punch: CGSize {
        guard isActive, typography.motion.wordPunch > 0.01, !typography.reduceMotion else { return .zero }
        let amount = typography.motion.wordPunch * typography.beatImpulse
        let direction: CGFloat = typography.beatCount.isMultiple(of: 2) ? 1 : -1
        return CGSize(width: amount * 0.35 * direction, height: -amount)
    }

    private var kerning: CGFloat {
        let base = -typography.fontSize * 0.018
        guard isActive else { return base }
        return base + CGFloat(typography.motion.trackingShift) * (0.6 + 0.4 * typography.beatImpulse)
    }

    var body: some View {
        let base = Text(text)
            .font(typography.font(current: isCurrentLine))
            .kerning(kerning)
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
        .offset(punch)
        .animation(typography.motion.wordAnimation, value: isActive)
        .animation(.easeOut(duration: 0.45), value: highlightOpacity)
        .accessibilityHidden(true)
    }
}

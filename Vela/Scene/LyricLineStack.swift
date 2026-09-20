import SwiftUI

/// Vertically arranged lines centred on the anchor line, with spring motion between lines.
/// Neighbouring lines are styled by their distance from the anchor according to the lyric style.
struct LyricLineStack: View {
    let lines: [LyricLine]
    /// Index into `lines` of the line at the centre.
    let anchor: Int
    let anchorIsCurrent: Bool
    let activeWordIndex: Int?
    let wordProgress: Double
    let typography: LyricTypography
    let showBreathing: Bool
    let breathCountdown: TimeInterval?
    /// Slow vertical float applied by calm profiles (points).
    var floatOffset: CGFloat = 0

    @State private var heights: [Int: CGFloat] = [:]

    private var before: Int { typography.style == .drift ? 2 : 1 }
    private var after: Int { typography.style == .drift ? 3 : 2 }
    private var spacing: CGFloat { typography.fontSize * (typography.style == .drift ? 0.55 : 0.7) }

    private func height(of index: Int) -> CGFloat {
        heights[lines[index].id] ?? typography.fontSize * 1.3
    }

    private func offset(for index: Int) -> CGFloat {
        if index == anchor { return 0 }
        var value = height(of: anchor) / 2 + spacing
        if index < anchor {
            for k in (index + 1)..<anchor { value += height(of: k) + spacing }
            return -(value + height(of: index) / 2)
        } else {
            for k in (anchor + 1)..<index { value += height(of: k) + spacing }
            return value + height(of: index) / 2
        }
    }

    private func role(for index: Int) -> LineRole {
        if index < anchor { return .past }
        if index == anchor { return anchorIsCurrent ? .current : .upcoming }
        return .upcoming
    }

    var body: some View {
        GeometryReader { proxy in
            let visible = max(0, anchor - before)...min(lines.count - 1, anchor + after)
            ZStack(alignment: typography.alignment.stackAlignment) {
                ForEach(visible, id: \.self) { index in
                    let distance = index - anchor
                    LyricLineView(line: lines[index], role: role(for: index),
                                  activeWordIndex: index == anchor ? activeWordIndex : nil,
                                  wordProgress: wordProgress, typography: index == anchor ? typography : typography.still,
                                  maxWidth: proxy.size.width * 0.84)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[lines[index].id] = $0 }
                        .modifier(NeighbourStyle(distance: distance, typography: typography.still))
                        .offset(y: offset(for: index) + floatOffset)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: typography.reduceMotion ? 0 : 36 * CGFloat(0.6 + typography.motion.tempo * 0.4))),
                                                removal: .opacity.combined(with: .offset(y: typography.reduceMotion ? 0 : -36 * CGFloat(0.6 + typography.motion.tempo * 0.4)))))
                        .id(lines[index].id)
                }
                if showBreathing {
                    BreathingIndicator(countdown: breathCountdown, color: typography.palette.highlight.swiftUIColor,
                                       reduceMotion: typography.reduceMotion, size: typography.fontSize * 0.28)
                        .offset(y: -(height(of: anchor) / 2 + spacing + typography.fontSize * 0.6))
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(typography.motion.lineAnimation, value: anchor)
            .animation(.easeInOut(duration: 0.3), value: showBreathing)
        }
        .clipped()
    }
}

/// Depth/opacity treatment for lines around the anchor.
///
/// The line is flattened with `compositingGroup()` before blurring and opacity is applied last,
/// so the blur never rasterises half-transparent word layers into a visible rectangle.
private struct NeighbourStyle: ViewModifier {
    let distance: Int
    let typography: LyricTypography

    private var d: Double { Double(abs(distance)) }

    private var opacity: Double {
        guard distance != 0 else { return 1 }
        switch typography.style {
        case .focus, .stack: return max(0.16, 0.5 - 0.16 * d)
        case .bloom: return max(0.14, 0.42 - 0.14 * d)
        case .drift: return max(0.12, 0.55 - 0.16 * d)
        }
    }

    private var blur: CGFloat {
        guard distance != 0, !typography.reduceEffects else { return 0 }
        switch typography.style {
        case .focus, .stack: return CGFloat(d) * 0.9
        case .bloom: return CGFloat(d) * 1.4
        case .drift: return CGFloat(d) * 1.1
        }
    }

    private var depth: Double { typography.motion.lineDepth }

    private var scale: CGFloat {
        guard distance != 0 else { return 1 }
        switch typography.style {
        case .focus, .stack: return CGFloat(0.94 - 0.06 * depth)
        case .bloom: return CGFloat(0.9 - 0.06 * depth)
        case .drift: return 1 - CGFloat(0.05 + 0.05 * depth) * CGFloat(d)
        }
    }

    /// Perspective tilt of neighbouring lines: always on in Drift, profile-driven elsewhere.
    private var tilt: Double {
        guard !typography.reduceMotion else { return 0 }
        switch typography.style {
        case .drift: return Double(-distance) * (9 + 9 * depth)
        case .focus, .bloom, .stack: return depth > 0.4 ? Double(-distance) * (depth - 0.4) * 14 : 0
        }
    }

    func body(content: Content) -> some View {
        content
            .compositingGroup()
            .blur(radius: blur)
            .opacity(opacity)
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
    }
}

/// Animated ellipsis for instrumental passages; fills in as the next line approaches.
struct BreathingIndicator: View {
    let countdown: TimeInterval?
    let color: Color
    let reduceMotion: Bool
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion && countdown == nil)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let arcProgress: Double? = countdown.flatMap { $0 < 4.5 ? 1 - $0 / 4.5 : nil }
            ZStack {
                // A thin arc fills in over the last seconds before the next line lands.
                if let arcProgress {
                    Circle().stroke(color.opacity(0.16), lineWidth: 1.5)
                    Circle().trim(from: 0, to: arcProgress)
                        .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: arcProgress)
                }
                dots(t: t)
            }
            .frame(width: size * 6.2, height: size * 6.2)
        }
        .accessibilityLabel("Instrumental")
    }

    private func dots(t: Double) -> some View {
            HStack(spacing: size * 0.9) {
                ForEach(0..<3, id: \.self) { index in
                    let pulse = reduceMotion ? 0.6 : 0.42 + 0.58 * (0.5 + 0.5 * sin(t * 2.0 - Double(index) * 0.95))
                    let lit: Bool = {
                        guard let countdown, countdown < 3.2 else { return false }
                        return countdown < 3.2 - Double(index) * 1.0
                    }()
                    Circle()
                        .fill(color.opacity(lit ? 1 : pulse * 0.75))
                        .frame(width: size, height: size)
                        .scaleEffect(lit ? 1.2 : (reduceMotion ? 1 : 0.85 + 0.25 * pulse))
                        .shadow(color: color.opacity(lit ? 0.8 : 0), radius: size * 0.6)
                        .animation(.easeOut(duration: 0.25), value: lit)
                }
            }
    }
}

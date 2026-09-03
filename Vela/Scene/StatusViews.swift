import SwiftUI

/// A centred message for states without lyrics (nothing playing, permission problems, …).
struct StatusStageView: View {
    let symbol: String
    let title: String
    let message: String
    var actions: [StageAction] = []
    let palette: Palette

    struct StageAction: Identifiable {
        var id: String { title }
        var title: String
        var prominent: Bool = false
        var handler: () -> Void
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(palette.highlight.swiftUIColor.opacity(0.9))
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(palette.primary.swiftUIColor)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(palette.primary.swiftUIColor.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            if !actions.isEmpty {
                HStack(spacing: 12) {
                    ForEach(actions) { action in
                        Button(action.title, action: action.handler)
                            .buttonStyle(PillButtonStyle(prominent: action.prominent, tint: palette.highlight.swiftUIColor))
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .accessibilityElement(children: .contain)
    }
}

/// Track title/artist hero used when lyrics are loading or unavailable.
struct TrackHeroView<Accessory: View>: View {
    let track: TrackInfo
    let caption: String
    let palette: Palette
    var actions: [StatusStageView.StageAction] = []
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 14) {
            accessory()
                .padding(.bottom, 10)
            Text(track.title)
                .font(.system(size: 44, weight: .bold))
                .kerning(-0.8)
                .foregroundStyle(palette.primary.swiftUIColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(track.artist)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(palette.primary.swiftUIColor.opacity(0.7))
                .multilineTextAlignment(.center)
            Text(caption)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.highlight.swiftUIColor.opacity(0.85))
                .padding(.top, 6)
            if !actions.isEmpty {
                HStack(spacing: 12) {
                    ForEach(actions) { action in
                        Button(action.title, action: action.handler)
                            .buttonStyle(PillButtonStyle(prominent: action.prominent, tint: palette.highlight.swiftUIColor))
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(40)
        .frame(maxWidth: 720)
    }
}

/// Subtle pulsing dot used while lyrics are being fetched.
struct PulsingDot: View {
    let color: Color
    let reduceMotion: Bool
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .opacity(on || reduceMotion ? 1 : 0.35)
            .scaleEffect(on && !reduceMotion ? 1.25 : 1)
            .shadow(color: color.opacity(0.7), radius: on ? 10 : 2)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
            .accessibilityLabel("Loading")
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
            .background(
                Capsule().fill(prominent ? tint : Color.white.opacity(configuration.isPressed ? 0.22 : 0.12))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0 : 0.14)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// Icon-only control used in the now-playing bar.
struct GlyphButtonStyle: ButtonStyle {
    var size: CGFloat = 34
    var emphasized = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(Color.white.opacity(emphasized ? 1 : 0.88))
            .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : (emphasized ? 0.1 : 0))))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

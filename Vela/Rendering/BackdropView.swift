import SwiftUI

/// Album-art backdrop: pre-blurred artwork, slightly enlarged, darkened, with slow gradient
/// drift derived from the palette and a fine grain on top.
struct BackdropView: View {
    let backdrop: CGImage?
    let palette: Palette
    let reduceEffects: Bool
    let reduceMotion: Bool

    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                palette.background.swiftUIColor
                if let backdrop {
                    Image(decorative: backdrop, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(1.12)
                        .clipped()
                        .transition(.opacity)
                }
                // Darken enough for lyric contrast while keeping tint.
                LinearGradient(colors: [Color.black.opacity(0.42), Color.black.opacity(0.62), Color.black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
                if !reduceEffects {
                    driftingGradient(size: proxy.size)
                        .blendMode(.screen)
                }
                if !reduceEffects, let grain = GrainTexture.image {
                    Image(decorative: grain, scale: 1)
                        .resizable(resizingMode: .tile)
                        .opacity(0.055)
                        .blendMode(.overlay)
                }
            }
            .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 1.4), value: palette)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 48).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }

    /// Three soft discs of palette colour that wander slowly. Each disc lives in its own square
    /// frame sized to its diameter, so the gradient reaches full transparency before the frame
    /// edge and no rectangle is ever visible, whatever the offset.
    private func driftingGradient(size: CGSize) -> some View {
        let a = palette.glow.swiftUIColor.opacity(0.30)
        let b = palette.highlight.swiftUIColor.opacity(0.22)
        let c = (palette.gradient.count > 2 ? palette.gradient[2] : palette.glow).swiftUIColor.opacity(0.18)
        let radius = max(size.width, size.height) * 0.62
        let angle = phase * 2 * .pi
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return ZStack {
            disc(color: a, radius: radius)
                .position(x: center.x + cos(angle) * size.width * 0.35, y: center.y + sin(angle) * size.height * 0.3)
            disc(color: b, radius: radius * 0.8)
                .position(x: center.x + cos(angle * 0.7 + 2.1) * size.width * 0.4, y: center.y + sin(angle * 0.7 + 2.1) * size.height * 0.35)
            disc(color: c, radius: radius * 0.9)
                .position(x: center.x + cos(angle * 0.5 + 4.2) * size.width * 0.3, y: center.y + sin(angle * 0.5 + 4.2) * size.height * 0.4)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func disc(color: Color, radius: CGFloat) -> some View {
        RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: radius)
            .frame(width: radius * 2, height: radius * 2)
    }
}

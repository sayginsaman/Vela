import SwiftUI
import MetalKit

/// The ambient light around the display edges. Uses Metal when available and falls back to a
/// SwiftUI `Canvas` otherwise. Both read the same `AudioLevelStore`.
struct EdgeGlowView: View {
    let parameters: GlowParameters
    let audio: AudioLevelStore

    var body: some View {
        if MTLCreateSystemDefaultDevice() != nil {
            EdgeGlowMetalView(parameters: parameters, audio: audio)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            EdgeGlowCanvasView(parameters: parameters, audio: audio)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct EdgeGlowMetalView: NSViewRepresentable {
    let parameters: GlowParameters
    let audio: AudioLevelStore

    final class Coordinator {
        var renderer: EdgeGlowRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = GlowMTKView()
        view.wantsLayer = true
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        (view.layer as? CAMetalLayer)?.isOpaque = false
        view.layer?.isOpaque = false
        if let renderer = EdgeGlowRenderer(audio: audio) {
            view.device = renderer.device
            view.delegate = renderer
            renderer.update(parameters: parameters)
            context.coordinator.renderer = renderer
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.update(parameters: parameters)
    }
}

/// Pauses rendering while the window is hidden or occluded so the GPU idles.
final class GlowMTKView: MTKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { isPaused = true; return }
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        occlusionChanged()
    }

    @objc private func occlusionChanged() {
        isPaused = !(window?.occlusionState.contains(.visible) ?? false)
    }

    override var isOpaque: Bool { false }
}

/// Fallback used when no Metal device exists (e.g. some virtual machines).
struct EdgeGlowCanvasView: View {
    let parameters: GlowParameters
    let audio: AudioLevelStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let (bands, live) = audio.read()
            let breath = 0.5 + 0.5 * sin(t * 0.85)
            let bass = live ? Double(bands.bass) : breath * 0.5
            let level = live ? Double(bands.level) : 0.4 + 0.3 * breath
            Canvas { canvas, size in
                let inset = parameters.thickness * 0.5
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                let path = Path(roundedRect: rect, cornerRadius: max(parameters.cornerRadius, inset))
                let colors = parameters.gradient.map(\.swiftUIColor) + [parameters.gradient.first?.swiftUIColor ?? .white]
                let angle = Angle(radians: parameters.reduceMotion ? 0 : t * 0.1)
                let gradient = GraphicsContext.Shading.conicGradient(Gradient(colors: colors), center: CGPoint(x: size.width / 2, y: size.height / 2), angle: angle)
                canvas.opacity = parameters.intensity * (0.45 + 0.55 * level)
                canvas.stroke(path, with: gradient, lineWidth: parameters.thickness * (1 + 0.8 * bass))
            }
            .blur(radius: 22 * parameters.spread)
        }
    }
}

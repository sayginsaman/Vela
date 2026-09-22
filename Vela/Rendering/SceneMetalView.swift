import SwiftUI
import MetalKit

/// The reactive background + edge light, drawn by `SceneRenderer`. Falls back to a lightweight
/// SwiftUI rendering when no Metal device exists.
struct ReactiveSceneView: View {
    let director: VisualDirector
    let features: FeatureStore
    let artworkSoft: CGImage?
    let artworkSharp: CGImage?
    var artworkCover: CGImage? = nil
    let artworkGeneration: Int
    let geometry: SceneGeometry

    var body: some View {
        if MTLCreateSystemDefaultDevice() != nil {
            SceneMetalView(director: director, features: features, artworkSoft: artworkSoft, artworkSharp: artworkSharp,
                           artworkCover: artworkCover, artworkGeneration: artworkGeneration, geometry: geometry)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            SceneCanvasView(director: director, features: features, artwork: artworkSoft, geometry: geometry)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct SceneMetalView: NSViewRepresentable {
    let director: VisualDirector
    let features: FeatureStore
    let artworkSoft: CGImage?
    let artworkSharp: CGImage?
    let artworkCover: CGImage?
    let artworkGeneration: Int
    let geometry: SceneGeometry

    final class Coordinator {
        var renderer: SceneRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = SceneMTKView()
        view.wantsLayer = true
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        if let renderer = SceneRenderer(director: director, features: features) {
            view.device = renderer.device
            view.delegate = renderer
            renderer.update(geometry: geometry)
            renderer.setArtwork(soft: artworkSoft, sharp: artworkSharp, cover: artworkCover, generation: artworkGeneration)
            context.coordinator.renderer = renderer
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.update(geometry: geometry)
        renderer.setArtwork(soft: artworkSoft, sharp: artworkSharp, cover: artworkCover, generation: artworkGeneration)
    }
}

/// Pauses rendering while the window is hidden, minimised or occluded so the GPU idles.
final class SceneMTKView: MTKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { isPaused = true; return }
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didMiniaturizeNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didDeminiaturizeNotification, object: window)
        occlusionChanged()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// `VELA_ALWAYS_RENDER=1` keeps drawing while occluded (used for automated visual checks).
    private static let alwaysRender = ProcessInfo.processInfo.environment["VELA_ALWAYS_RENDER"] == "1"

    @objc private func occlusionChanged() {
        guard !Self.alwaysRender else { isPaused = false; return }
        let visible = window?.occlusionState.contains(.visible) ?? false
        isPaused = !visible || (window?.isMiniaturized ?? false)
    }
}

/// Non-Metal fallback: blurred artwork, palette discs and an edge stroke driven by the director.
struct SceneCanvasView: View {
    let director: VisualDirector
    let features: FeatureStore
    let artwork: CGImage?
    let geometry: SceneGeometry

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let now = ProcessInfo.processInfo.systemUptime
            let (snapshot, live) = features.read()
            let state = director.tick(now: now, features: snapshot, isLive: live)
            ZStack {
                state.palette.background.swiftUIColor
                if let artwork {
                    Image(decorative: artwork, scale: 1).resizable().scaledToFill()
                        .scaleEffect(1.12 + state.expansion * 0.07)
                        .opacity(0.65 * state.lightIntensity)
                }
                Canvas { canvas, size in
                    let aspect = size.width / size.height
                    for blob in state.blobs {
                        let color = (blob.colorIndex < state.palette.gradient.count + 4 && blob.colorIndex >= 4
                                     ? state.palette.gradient[(blob.colorIndex - 4) % max(1, state.palette.gradient.count)]
                                     : state.palette.glow).swiftUIColor
                        let center = CGPoint(x: blob.x * size.width, y: blob.y * size.height)
                        let radius = blob.radius * size.height * max(1, aspect) * 0.9
                        let shading = GraphicsContext.Shading.radialGradient(Gradient(colors: [color.opacity(0.45 * blob.intensity), .clear]), center: center, startRadius: 0, endRadius: radius)
                        canvas.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: shading)
                    }
                    let inset = state.edgeThickness * 0.5
                    let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                    let path = Path(roundedRect: rect, cornerRadius: max(geometry.cornerRadius, inset))
                    let colors = state.palette.gradient.map(\.swiftUIColor) + [state.palette.gradient.first?.swiftUIColor ?? .white]
                    let gradient = GraphicsContext.Shading.conicGradient(Gradient(colors: colors), center: CGPoint(x: size.width / 2, y: size.height / 2), angle: Angle(radians: state.edgeTravelPhase * 2 * .pi))
                    canvas.opacity = state.edgeIntensity * (0.45 + 0.55 * Double(state.bands.level))
                    canvas.stroke(path, with: gradient, lineWidth: state.edgeThickness * (1 + 0.8 * Double(state.bands.bass)))
                }
                .blur(radius: 18 * state.edgeSpread)
            }
        }
    }
}

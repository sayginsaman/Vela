import Foundation
import Metal
import MetalKit
import simd
import os

/// Static parameters for the edge glow; audio comes from `AudioLevelStore` per frame.
struct GlowParameters: Equatable, Sendable {
    var gradient: [RGBColor]
    var thickness: Double        // points
    var intensity: Double
    var spread: Double
    var reactiveMotion: Bool
    var reduceMotion: Bool
    var cornerRadius: Double     // points
    var notchRect: CGRect        // points, top-left origin in view space; .zero when none
    var breathing: Bool          // no live audio → breathe

    static let placeholder = GlowParameters(gradient: Palette.fallback.gradient, thickness: 60, intensity: 0.9, spread: 1,
                                            reactiveMotion: true, reduceMotion: false, cornerRadius: 0, notchRect: .zero, breathing: true)
}

/// Mirror of the Metal `GlowUniforms` struct. Field order and padding are load-bearing.
struct GlowUniforms {
    var resolution: SIMD2<Float> = .zero
    var time: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var level: Float = 0
    var thickness: Float = 60
    var intensity: Float = 1
    var spread: Float = 1
    var cornerRadius: Float = 0
    var motion: Float = 1
    var reduceMotion: Float = 0
    var breathing: Float = 0
    var colorCount: Float = 4
    var pad0: Float = 0
    var notch: SIMD4<Float> = .zero
    var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero)
}

/// Draws the glow as one full-screen triangle with an SDF-based fragment shader.
final class EdgeGlowRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let audio: AudioLevelStore

    private let parameterLock = OSAllocatedUnfairLock(initialState: GlowParameters.placeholder)
    private var currentColors: [SIMD4<Float>] = Palette.fallback.gradient.map(\.simd)
    private var smoothedBands = AudioBands.silent
    private var startTime = CACurrentMediaTimeCompat()
    private var lastFrame = CACurrentMediaTimeCompat()
    private var uniforms = GlowUniforms()

    init?(audio: AudioLevelStore) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: EdgeGlowShaderSource.source, options: nil),
              let vertex = library.makeFunction(name: "glowVertex"),
              let fragment = library.makeFunction(name: "glowFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        self.audio = audio
        super.init()
    }

    func update(parameters: GlowParameters) {
        parameterLock.withLock { $0 = parameters }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTimeCompat()
        let dt = Float(min(0.1, now - lastFrame))
        lastFrame = now
        let parameters = parameterLock.withLock { $0 }
        let scale = Float(view.window?.backingScaleFactor ?? 2)

        // Audio: interpolate toward the latest published bands for frame-rate independence.
        let (bands, live) = audio.read()
        let follow = 1 - exp(-dt * 18)
        smoothedBands = smoothedBands.mixed(toward: live ? bands : .silent, amount: follow)

        // Palette crossfade.
        let target = parameters.gradient.map(\.simd)
        if currentColors.count != target.count { currentColors = Array(repeating: currentColors.first ?? .zero, count: target.count) }
        let colorFollow = 1 - exp(-dt * 1.6)
        for i in currentColors.indices { currentColors[i] += (target[i] - currentColors[i]) * colorFollow }

        uniforms.resolution = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        uniforms.time = Float(now - startTime)
        uniforms.bass = smoothedBands.bass
        uniforms.mid = smoothedBands.mid
        uniforms.high = smoothedBands.high
        uniforms.level = smoothedBands.level
        uniforms.thickness = Float(parameters.thickness) * scale
        uniforms.intensity = Float(parameters.intensity)
        uniforms.spread = Float(parameters.spread)
        uniforms.cornerRadius = Float(parameters.cornerRadius) * scale
        uniforms.motion = parameters.reactiveMotion ? 1 : 0
        uniforms.reduceMotion = parameters.reduceMotion ? 1 : 0
        uniforms.breathing = (parameters.breathing || !live) ? 1 : 0
        uniforms.colorCount = Float(min(6, max(2, currentColors.count)))
        let n = parameters.notchRect
        uniforms.notch = n.width > 0 ? SIMD4(Float(n.minX) * scale, Float(n.minY) * scale, Float(n.width) * scale, Float(n.height) * scale) : .zero
        var padded = currentColors
        while padded.count < 6 { padded.append(padded.last ?? .zero) }
        uniforms.colors = (padded[0], padded[1], padded[2], padded[3], padded[4], padded[5])

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlowUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

import Foundation
import Metal
import MetalKit
import simd
import os

/// Mirror of the Metal `SceneUniforms` struct. Only `float4` members, so layout is trivial.
struct SceneUniforms {
    var resolutionTime: SIMD4<Float> = .zero
    var bands: SIMD4<Float> = .zero
    var impulses: SIMD4<Float> = .zero
    var rhythm: SIMD4<Float> = .zero
    var background: SIMD4<Float> = .zero
    var tone: SIMD4<Float> = .zero
    var motion: SIMD4<Float> = .zero
    var style: SIMD4<Float> = .zero
    var camera: SIMD4<Float> = SIMD4(0, 0, 1, 1)
    var edge: SIMD4<Float> = .zero
    var edge2: SIMD4<Float> = .zero
    var flags: SIMD4<Float> = .zero
    var notch: SIMD4<Float> = .zero
    var palette: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var blobs: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero)
    var blobIntensity: (SIMD4<Float>, SIMD4<Float>) = (.zero, .zero)
    var particles: SIMD4<Float> = .zero
    var particles2: SIMD4<Float> = .zero
    /// ledStrip weight, coverArt weight, LED strip width (px), pad.
    var look: SIMD4<Float> = .zero
}

/// Window-geometry inputs that only the view hierarchy knows.
struct SceneGeometry: Equatable {
    var cornerRadius: Double = 0
    var notchRect: CGRect = .zero
}

/// Draws the whole reactive scene: backdrop, gradient field, accents, edge light and particles.
/// Runs `VisualDirector.tick` once per frame so every value the shader sees is smoothed.
final class SceneRenderer: NSObject, MTKViewDelegate {
    static let maximumParticles = 160

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let scenePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureLoader: MTKTextureLoader
    private let placeholder: MTLTexture
    private let director: VisualDirector
    private let features: FeatureStore

    private let geometryLock = OSAllocatedUnfairLock(initialState: SceneGeometry())
    private struct Artwork { var soft: MTLTexture?; var sharp: MTLTexture?; var cover: MTLTexture? }
    private let artworkLock = OSAllocatedUnfairLock(initialState: (previous: Artwork(), current: Artwork(), fadeStart: -10.0, generation: 0))

    private var uniforms = SceneUniforms()
    private var lastFrame = CACurrentMediaTimeCompat()
    private let startTime = CACurrentMediaTimeCompat()

    init?(director: VisualDirector, features: FeatureStore) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: SceneShaderSource.source, options: nil),
              let sceneVertex = library.makeFunction(name: "sceneVertex"),
              let sceneFragment = library.makeFunction(name: "sceneFragment"),
              let particleVertex = library.makeFunction(name: "particleVertex"),
              let particleFragment = library.makeFunction(name: "particleFragment") else { return nil }

        let sceneDescriptor = MTLRenderPipelineDescriptor()
        sceneDescriptor.vertexFunction = sceneVertex
        sceneDescriptor.fragmentFunction = sceneFragment
        sceneDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let scenePipeline = try? device.makeRenderPipelineState(descriptor: sceneDescriptor) else { return nil }

        let particleDescriptor = MTLRenderPipelineDescriptor()
        particleDescriptor.vertexFunction = particleVertex
        particleDescriptor.fragmentFunction = particleFragment
        particleDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        particleDescriptor.colorAttachments[0].isBlendingEnabled = true
        particleDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        particleDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        particleDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        particleDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let particlePipeline = try? device.makeRenderPipelineState(descriptor: particleDescriptor) else { return nil }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }

        let placeholderDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        placeholderDescriptor.usage = .shaderRead
        guard let placeholder = device.makeTexture(descriptor: placeholderDescriptor) else { return nil }
        var black = [UInt8](repeating: 0, count: 16)
        placeholder.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &black, bytesPerRow: 8)

        self.device = device
        commandQueue = queue
        self.scenePipeline = scenePipeline
        self.particlePipeline = particlePipeline
        self.sampler = sampler
        textureLoader = MTKTextureLoader(device: device)
        self.placeholder = placeholder
        self.director = director
        self.features = features
        super.init()
    }

    // MARK: Inputs

    func update(geometry: SceneGeometry) {
        geometryLock.withLock { $0 = geometry }
    }

    /// Installs new artwork textures and starts a crossfade from the previous ones.
    /// `generation` lets the caller avoid re-uploading unchanged images.
    func setArtwork(soft: CGImage?, sharp: CGImage?, cover: CGImage? = nil, generation: Int) {
        let alreadyApplied = artworkLock.withLock { $0.generation == generation }
        guard !alreadyApplied else { return }
        let softTexture = soft.flatMap(makeTexture)
        let sharpTexture = sharp.flatMap(makeTexture)
        let coverTexture = cover.flatMap(makeTexture)
        artworkLock.withLock { state in
            state.previous = state.current
            state.current = Artwork(soft: softTexture, sharp: sharpTexture ?? softTexture, cover: coverTexture ?? sharpTexture ?? softTexture)
            state.fadeStart = CACurrentMediaTimeCompat()
            state.generation = generation
        }
    }

    private func makeTexture(_ image: CGImage) -> MTLTexture? {
        try? textureLoader.newTexture(cgImage: image, options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue])
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTimeCompat()
        let dt = Float(min(0.1, now - lastFrame))
        lastFrame = now
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        let (snapshot, isLive) = features.read()
        let state = director.tick(now: now, features: snapshot, isLive: isLive)
        let geometry = geometryLock.withLock { $0 }
        let artwork = artworkLock.withLock { $0 }
        let fade = Float(min(1, max(0, (now - artwork.fadeStart) / 1.4)))
        let eased = fade * fade * (3 - 2 * fade)

        var u = uniforms
        u.resolutionTime = SIMD4(Float(view.drawableSize.width), Float(view.drawableSize.height), Float(now - startTime), dt)
        u.bands = SIMD4(state.bands.bass, state.bands.mid, state.bands.high, state.bands.level)
        u.impulses = SIMD4(Float(state.onset), Float(state.beat), Float(state.snare), Float(state.hat))
        u.rhythm = SIMD4(Float(state.kick), Float(state.beatPhase), Float(state.bpmConfidence), Float(state.edgeTravelPhase))
        u.background = SIMD4(Float(state.expansion), Float(state.distortion), Float(state.blurMix), Float(state.bloom))
        u.tone = SIMD4(Float(state.vignette), Float(state.grain), Float(state.depth), Float(state.lightIntensity))
        u.motion = SIMD4(Float(state.preset.gradientSpeed), Float(state.preset.orbit), Float(state.preset.liquid), Float(state.preset.compress))
        u.style = SIMD4(Float(state.preset.slices), Float(state.preset.streaks), Float(state.preset.ring), Float(state.particleMirror))
        u.camera = SIMD4(Float(state.cameraX), Float(state.cameraY), Float(state.cameraZoom), eased)
        // Thickness is capped relative to the short side so the halo never floods small or huge windows.
        let shortSide = Float(min(view.drawableSize.width, view.drawableSize.height))
        let thicknessPixels = min(Float(state.edgeThickness) * scale, shortSide * 0.075)
        u.edge = SIMD4(thicknessPixels, Float(state.edgeIntensity), Float(state.edgeSpread), Float(geometry.cornerRadius) * scale)
        u.edge2 = SIMD4(Float(state.preset.edgeTravel), Float(state.breathing), state.reduceMotion ? 1 : 0, Float(min(4, max(2, state.palette.gradient.count))))
        u.flags = SIMD4(artwork.previous.soft == nil ? 0 : 1, artwork.current.soft == nil ? 0 : 1, Float(state.energy), Float(state.lyric.beatCount % 1024))
        let n = geometry.notchRect
        u.notch = n.width > 0 ? SIMD4(Float(n.minX) * scale, Float(n.minY) * scale, Float(n.width) * scale, Float(n.height) * scale) : .zero

        let pal = state.palette
        var stops = pal.gradient.map(\.simd)
        while stops.count < 4 { stops.append(stops.last ?? pal.glow.simd) }
        u.palette = (pal.background.simd, pal.primary.simd, pal.highlight.simd, pal.glow.simd, stops[0], stops[1], stops[2], stops[3])
        var blobs = state.blobs.map { SIMD4(Float($0.x), Float($0.y), Float($0.radius), Float(min(7, $0.colorIndex))) }
        var intensities = state.blobs.map { Float($0.intensity) }
        while blobs.count < 6 { blobs.append(.zero); intensities.append(0) }
        u.blobs = (blobs[0], blobs[1], blobs[2], blobs[3], blobs[4], blobs[5])
        u.blobIntensity = (SIMD4(intensities[0], intensities[1], intensities[2], intensities[3]), SIMD4(intensities[4], intensities[5], 0, 0))
        let particleCount = Int(Double(Self.maximumParticles) * min(1, max(0, state.particleDensity)))
        u.particles = SIMD4(Float(particleCount), (3.5 + 2.5 * Float(state.energy)) * scale, Float(state.particleSpeed), Float(state.particleLifetime))
        u.particles2 = SIMD4(Float(state.particleStreak), Float(state.particleMirror), Float(state.particleDensity), 0)
        // An LED strip is a few points wide, not tens: it keeps the glow's thickness setting as a
        // multiplier but starts from a hairline, and stays crisp on any window size.
        let stripPoints = min(10, max(1.5, 4.5 * Float(state.edgeThickness) / 64))
        u.look = SIMD4(Float(state.preset.ledStrip), Float(state.preset.coverArt), stripPoints * scale, 0)
        uniforms = u

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(scenePipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        encoder.setFragmentTexture(artwork.previous.soft ?? placeholder, index: 0)
        encoder.setFragmentTexture(artwork.previous.sharp ?? artwork.previous.soft ?? placeholder, index: 1)
        encoder.setFragmentTexture(artwork.current.soft ?? placeholder, index: 2)
        encoder.setFragmentTexture(artwork.current.sharp ?? artwork.current.soft ?? placeholder, index: 3)
        encoder.setFragmentTexture(artwork.previous.cover ?? artwork.previous.soft ?? placeholder, index: 4)
        encoder.setFragmentTexture(artwork.current.cover ?? artwork.current.soft ?? placeholder, index: 5)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if particleCount > 0 {
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particleCount)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

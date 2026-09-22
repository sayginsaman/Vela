import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Produces the two derived assets the scene needs from raw artwork: a colour palette and a
/// pre-blurred, darkened backdrop. Doing the blur once here keeps the per-frame cost at zero.
enum ArtworkProcessor {
    struct Output: Sendable {
        var palette: Palette
        /// Heavily blurred backdrop (the calm state).
        var backdrop: CGImage?
        /// Lightly blurred backdrop the renderer mixes in as loudness rises.
        var backdropSharp: CGImage?
        /// The artwork itself, squared but otherwise untouched, for the Cover Art look.
        var cover: CGImage? = nil
    }

    static func process(_ image: CGImage?) async -> Output {
        await Task.detached(priority: .userInitiated) {
            let palette = PaletteExtractor.palette(from: image)
            let backdrop = image.flatMap { makeBackdrop(from: $0, blurRadius: 22) }
            let sharp = image.flatMap { makeBackdrop(from: $0, size: 320, blurRadius: 7) }
            let cover = image.flatMap { makeCover(from: $0) }
            return Output(palette: palette, backdrop: backdrop, backdropSharp: sharp, cover: cover)
        }.value
    }

    /// The cover as a square texture: aspect-filled, capped so a huge source does not cost a huge
    /// texture, never upscaled, and with no blur or colour treatment. The backdrops above are
    /// deliberately soft and dark; this one has to hold up full screen.
    static let maximumCoverSize = 1400

    static func makeCover(from image: CGImage, maxSize: Int = maximumCoverSize) -> CGImage? {
        let side = max(1, min(maxSize, max(image.width, image.height)))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let scale = max(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    static func makeBackdrop(from image: CGImage, size: Int = 220, blurRadius: Float = 22) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // Aspect-fill into the square.
        let scale = max(CGFloat(size) / CGFloat(image.width), CGFloat(size) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }

        let input = CIImage(cgImage: small)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = blurRadius
        guard let blurred = blur.outputImage?.cropped(to: input.extent) else { return nil }
        let controls = CIFilter.colorControls()
        controls.inputImage = blurred
        controls.saturation = 1.15
        controls.brightness = -0.08
        controls.contrast = 1.05
        guard let output = controls.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(output, from: input.extent)
    }
}

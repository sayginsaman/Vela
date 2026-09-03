import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Produces the two derived assets the scene needs from raw artwork: a colour palette and a
/// pre-blurred, darkened backdrop. Doing the blur once here keeps the per-frame cost at zero.
enum ArtworkProcessor {
    struct Output: Sendable {
        var palette: Palette
        var backdrop: CGImage?
    }

    static func process(_ image: CGImage?) async -> Output {
        await Task.detached(priority: .userInitiated) {
            let palette = PaletteExtractor.palette(from: image)
            let backdrop = image.flatMap { makeBackdrop(from: $0) }
            return Output(palette: palette, backdrop: backdrop)
        }.value
    }

    static func makeBackdrop(from image: CGImage, size: Int = 220) -> CGImage? {
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
        blur.radius = 22
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

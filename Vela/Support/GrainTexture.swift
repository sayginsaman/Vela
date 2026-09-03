import Foundation
import CoreGraphics

/// A small tileable monochrome noise texture used as film grain over gradients.
enum GrainTexture {
    static let image: CGImage? = make(size: 160, seed: 99)

    static func make(size: Int, seed: UInt64) -> CGImage? {
        var rng = SeededGenerator(seed: seed)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var i = 0
        while i < pixels.count {
            let value = UInt8.random(in: 96...160, using: &rng)
            pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 255
            i += 4
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

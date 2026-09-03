import Foundation
import CoreGraphics
import ImageIO

/// Extracts prominent colours from artwork using a coarse histogram in RGB space.
///
/// The image is drawn into a tiny bitmap (32×32) so the whole pass is a few thousand pixels,
/// then binned at 4 bits per channel. Bins are scored by count × saturation so that a vivid
/// accent beats a large muddy area, and near-duplicates are merged.
enum PaletteExtractor {
    static let sampleSize = 32

    static func palette(from image: CGImage?) -> Palette {
        guard let image, let colours = prominentColors(in: image), !colours.isEmpty else {
            return Palette.fallback
        }
        return PaletteCorrector.makePalette(candidates: colours)
    }

    /// Prominent colours ordered by score. `nil` when the bitmap could not be created.
    static func prominentColors(in image: CGImage, maximum: Int = 8) -> [RGBColor]? {
        let size = sampleSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        struct Bin { var count = 0; var r = 0.0; var g = 0.0; var b = 0.0 }
        var bins: [Int: Bin] = [:]
        var index = 0
        while index < pixels.count {
            let a = Double(pixels[index + 3]) / 255
            if a > 0.2 {
                let r = Double(pixels[index]) / 255, g = Double(pixels[index + 1]) / 255, b = Double(pixels[index + 2]) / 255
                let key = (Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15)
                var bin = bins[key] ?? Bin()
                bin.count += 1; bin.r += r; bin.g += g; bin.b += b
                bins[key] = bin
            }
            index += 4
        }
        guard !bins.isEmpty else { return nil }

        let total = Double(size * size)
        var scored: [(color: RGBColor, score: Double, weight: Double)] = bins.values.map { bin in
            let c = RGBColor(r: bin.r / Double(bin.count), g: bin.g / Double(bin.count), b: bin.b / Double(bin.count))
            let share = Double(bin.count) / total
            let vividness = 0.35 + c.saturation * 0.9 + c.brightness * 0.25
            return (c, share * vividness, share)
        }
        scored.sort { $0.score > $1.score }

        // Merge near-duplicates, keep the dominant-by-area colour first.
        var merged: [(color: RGBColor, score: Double, weight: Double)] = []
        for item in scored {
            if let existing = merged.firstIndex(where: { $0.color.distance(to: item.color) < 0.10 }) {
                merged[existing].weight += item.weight
                merged[existing].score += item.score * 0.5
            } else {
                merged.append(item)
            }
            if merged.count >= maximum * 2 { break }
        }
        merged.sort { $0.score > $1.score }
        // The very first entry is the colour with the largest coverage; the rest are by vividness.
        var result = Array(merged.prefix(maximum)).map(\.color)
        if let dominant = merged.max(by: { $0.weight < $1.weight })?.color {
            result.removeAll { $0 == dominant }
            result.insert(dominant, at: 0)
        }
        return result
    }
}

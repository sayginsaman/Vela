import Foundation
import CoreGraphics

/// Procedurally drawn album covers for the demo catalogue: layered soft discs, a horizon band
/// and a fine grain, seeded per track so each cover is stable between launches.
enum DemoArtwork {
    static func render(for track: DemoTrack, size: Int = 640) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rng = SeededGenerator(seed: track.artworkSeed)
        let s = CGFloat(size)
        let hues = track.hues

        // Base wash.
        let base = RGBColor(hue: hues[0], saturation: 0.55, brightness: 0.22)
        ctx.setFillColor(base.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        // Large vertical gradient.
        let top = RGBColor(hue: hues[0], saturation: 0.6, brightness: 0.35)
        let bottom = RGBColor(hue: hues[1], saturation: 0.7, brightness: 0.12)
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
        }

        // Soft discs.
        for i in 0..<7 {
            let hue = hues[i % hues.count] + Double.random(in: -0.04...0.04, using: &rng)
            let color = RGBColor(hue: hue, saturation: Double.random(in: 0.5...0.9, using: &rng), brightness: Double.random(in: 0.55...0.95, using: &rng))
            let radius = CGFloat.random(in: s * 0.12...s * 0.42, using: &rng)
            let center = CGPoint(x: CGFloat.random(in: 0...s, using: &rng), y: CGFloat.random(in: s * 0.2...s, using: &rng))
            let inner = color.cgColor
            let outer = CGColor(srgbRed: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: 0)
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: [inner, outer] as CFArray, locations: [0, 1]) {
                ctx.saveGState()
                ctx.setBlendMode(i % 2 == 0 ? .screen : .normal)
                ctx.setAlpha(CGFloat.random(in: 0.45...0.85, using: &rng))
                ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
                ctx.restoreGState()
            }
        }

        // Horizon band.
        let bandY = CGFloat.random(in: s * 0.28...s * 0.45, using: &rng)
        let band = RGBColor(hue: hues[2], saturation: 0.5, brightness: 0.9)
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        ctx.setAlpha(0.35)
        ctx.setFillColor(band.cgColor)
        ctx.fill(CGRect(x: 0, y: bandY, width: s, height: s * 0.012))
        ctx.restoreGState()

        // Subtle dark vignette.
        let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        let dark = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: [clear, dark] as CFArray, locations: [0.55, 1]) {
            let c = CGPoint(x: s / 2, y: s / 2)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.75, options: [])
        }

        // Grain.
        ctx.setBlendMode(.overlay)
        for _ in 0..<(size * 6) {
            let x = CGFloat.random(in: 0...s, using: &rng), y = CGFloat.random(in: 0...s, using: &rng)
            let v = CGFloat.random(in: 0...1, using: &rng)
            ctx.setFillColor(CGColor(gray: v, alpha: 0.12))
            ctx.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
        }
        return ctx.makeImage()
    }
}

/// Deterministic xorshift generator so demo assets look the same on every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

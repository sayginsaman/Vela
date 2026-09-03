import Foundation
import CoreGraphics
import SwiftUI

/// A plain, Sendable sRGB color used by the palette pipeline and the renderers.
struct RGBColor: Hashable, Codable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = min(1, max(0, r)); self.g = min(1, max(0, g)); self.b = min(1, max(0, b))
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(h) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        self.init(r: r1 + m, g: g1 + m, b: b1 + m)
    }

    static let black = RGBColor(r: 0, g: 0, b: 0)
    static let white = RGBColor(r: 1, g: 1, b: 1)

    // MARK: HSB

    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0.00001 {
            if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxC > 0 ? delta / maxC : 0
        return (hue, saturation, maxC)
    }

    var hue: Double { hsb.hue }
    var saturation: Double { hsb.saturation }
    var brightness: Double { hsb.brightness }

    // MARK: Luminance and contrast (WCAG)

    private static func linear(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    var relativeLuminance: Double {
        0.2126 * Self.linear(r) + 0.7152 * Self.linear(g) + 0.0722 * Self.linear(b)
    }

    func contrastRatio(against other: RGBColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        let (light, dark) = a > b ? (a, b) : (b, a)
        return (light + 0.05) / (dark + 0.05)
    }

    /// Perceptual-ish distance in RGB, 0...1.
    func distance(to other: RGBColor) -> Double {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return sqrt((dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11))
    }

    /// Smallest angular hue difference in 0...0.5.
    func hueDistance(to other: RGBColor) -> Double {
        let d = abs(hue - other.hue)
        return min(d, 1 - d)
    }

    func mixed(with other: RGBColor, amount: Double) -> RGBColor {
        let t = min(1, max(0, amount))
        return RGBColor(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    func withBrightness(_ value: Double) -> RGBColor {
        let c = hsb
        return RGBColor(hue: c.hue, saturation: c.saturation, brightness: value)
    }

    func withSaturation(_ value: Double) -> RGBColor {
        let c = hsb
        return RGBColor(hue: c.hue, saturation: value, brightness: c.brightness)
    }

    func rotatingHue(by amount: Double) -> RGBColor {
        let c = hsb
        return RGBColor(hue: c.hue + amount, saturation: c.saturation, brightness: c.brightness)
    }

    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var simd: SIMD4<Float> { SIMD4(Float(r), Float(g), Float(b), 1) }
}

import Foundation

/// The colours the scene is built from. Every field is guaranteed readable by `PaletteCorrector`.
struct Palette: Hashable, Codable, Sendable {
    /// Deep colour behind everything.
    var background: RGBColor
    /// Colour of lyric text that is not currently being sung.
    var primary: RGBColor
    /// Colour of the active word.
    var highlight: RGBColor
    /// Second edge-glow colour, distinct in hue from `highlight`.
    var glow: RGBColor
    /// Ordered gradient stops for the edge light (3–6 entries).
    var gradient: [RGBColor]

    /// Used when there is no artwork, or the artwork is too dull to extract from.
    static let fallback = Palette(
        background: RGBColor(r: 0.045, g: 0.05, b: 0.085),
        primary: RGBColor(r: 0.93, g: 0.93, b: 0.96),
        highlight: RGBColor(r: 0.98, g: 0.78, b: 0.52),
        glow: RGBColor(r: 0.42, g: 0.56, b: 0.98),
        gradient: [
            RGBColor(r: 0.98, g: 0.78, b: 0.52),
            RGBColor(r: 0.86, g: 0.42, b: 0.62),
            RGBColor(r: 0.42, g: 0.56, b: 0.98),
            RGBColor(r: 0.30, g: 0.86, b: 0.82),
        ]
    )

    func mixed(with other: Palette, amount: Double) -> Palette {
        let count = max(gradient.count, other.gradient.count)
        var stops: [RGBColor] = []
        for i in 0..<count {
            let a = gradient[i % max(1, gradient.count)]
            let b = other.gradient[i % max(1, other.gradient.count)]
            stops.append(a.mixed(with: b, amount: amount))
        }
        return Palette(background: background.mixed(with: other.background, amount: amount),
                       primary: primary.mixed(with: other.primary, amount: amount),
                       highlight: highlight.mixed(with: other.highlight, amount: amount),
                       glow: glow.mixed(with: other.glow, amount: amount),
                       gradient: stops)
    }
}

/// Enforces readability rules on a raw palette.
enum PaletteCorrector {
    static let backgroundMaxLuminance = 0.09
    static let primaryContrast = 7.0
    static let highlightContrast = 4.5
    static let minimumHueSeparation = 0.09

    /// Returns `color` adjusted so its contrast ratio against `background` is at least `minimum`.
    /// Brightness is raised first (keeping hue), then saturation is reduced if still short.
    static func ensureContrast(_ color: RGBColor, against background: RGBColor, minimum: Double) -> RGBColor {
        if color.contrastRatio(against: background) >= minimum { return color }
        var candidate = color
        var brightness = color.brightness
        var iterations = 0
        while candidate.contrastRatio(against: background) < minimum, brightness < 1, iterations < 40 {
            brightness = min(1, brightness + 0.05)
            candidate = color.withBrightness(brightness)
            iterations += 1
        }
        var saturation = candidate.saturation
        iterations = 0
        while candidate.contrastRatio(against: background) < minimum, saturation > 0, iterations < 40 {
            saturation = max(0, saturation - 0.08)
            candidate = candidate.withSaturation(saturation)
            iterations += 1
        }
        return candidate
    }

    static func darkenedBackground(from color: RGBColor) -> RGBColor {
        var candidate = color
        var brightness = color.brightness
        // Keep some saturation so backgrounds feel tinted rather than grey.
        candidate = candidate.withSaturation(min(0.75, max(0.25, color.saturation)))
        var iterations = 0
        while candidate.relativeLuminance > backgroundMaxLuminance, iterations < 60 {
            brightness = max(0, brightness - 0.03)
            candidate = candidate.withBrightness(brightness)
            iterations += 1
        }
        if candidate.brightness < 0.08 { candidate = candidate.withBrightness(0.08) }
        return candidate
    }

    /// Two colours are "too similar" when both hue and overall distance are small.
    static func isTooSimilar(_ a: RGBColor, _ b: RGBColor) -> Bool {
        a.distance(to: b) < 0.12 || (a.hueDistance(to: b) < minimumHueSeparation && abs(a.saturation - b.saturation) < 0.2 && a.saturation > 0.15)
    }

    /// Muddy colours are dark and desaturated at once.
    static func isMuddy(_ c: RGBColor) -> Bool {
        (c.saturation < 0.18 && c.brightness < 0.55) || c.brightness < 0.18
    }

    /// Builds a corrected palette from candidate colours ordered by prominence.
    static func makePalette(candidates: [RGBColor]) -> Palette {
        let usable = candidates.filter { !isMuddy($0) }
        let base = candidates.first ?? Palette.fallback.background
        let background = darkenedBackground(from: base)

        // Highlight: most vivid candidate that is not the background's own colour.
        let vivid = usable.sorted { ($0.saturation * 0.7 + $0.brightness * 0.3) > ($1.saturation * 0.7 + $1.brightness * 0.3) }
        var highlight = vivid.first ?? Palette.fallback.highlight
        if highlight.brightness < 0.6 { highlight = highlight.withBrightness(0.72) }
        if highlight.saturation < 0.35 { highlight = highlight.withSaturation(0.55) }
        highlight = ensureContrast(highlight, against: background, minimum: highlightContrast)

        // Glow: next distinct hue; otherwise rotate the highlight.
        var glow = vivid.dropFirst().first(where: { !isTooSimilar($0, highlight) && $0.hueDistance(to: highlight) >= minimumHueSeparation })
            ?? highlight.rotatingHue(by: 0.14)
        if glow.brightness < 0.5 { glow = glow.withBrightness(0.7) }
        glow = ensureContrast(glow, against: background, minimum: 3.0)

        // Primary text: near-white tinted by the artwork.
        let tint = highlight.withSaturation(0.10).withBrightness(0.95)
        let primary = ensureContrast(tint, against: background, minimum: primaryContrast)

        var stops: [RGBColor] = [highlight, glow]
        for c in vivid.dropFirst() where stops.count < 5 {
            if stops.allSatisfy({ !isTooSimilar($0, c) }) {
                var adjusted = c
                if adjusted.brightness < 0.55 { adjusted = adjusted.withBrightness(0.68) }
                stops.append(ensureContrast(adjusted, against: background, minimum: 2.5))
            }
        }
        if stops.count < 3 { stops.append(highlight.rotatingHue(by: -0.12).withBrightness(0.8)) }
        if stops.count < 4 { stops.append(glow.rotatingHue(by: 0.1).withBrightness(0.75)) }

        return Palette(background: background, primary: primary, highlight: highlight, glow: glow, gradient: stops)
    }
}

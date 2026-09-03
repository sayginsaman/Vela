import Foundation

/// Transforms an artwork palette according to a profile's colour treatment, then re-enforces the
/// readability rules. The artwork stays the identity; the profile only bends it.
enum PaletteStyler {
    static func apply(_ preset: VisualProfilePreset, to palette: Palette) -> Palette {
        let background = style(palette.background, preset: preset, role: .background)
        let corrected = PaletteCorrector.darkenedBackground(from: background)
        var highlight = style(palette.highlight, preset: preset, role: .accent)
        highlight = emphasise(highlight, by: preset.highlightEmphasis)
        highlight = PaletteCorrector.ensureContrast(highlight, against: corrected, minimum: PaletteCorrector.highlightContrast)
        var glow = style(palette.glow, preset: preset, role: .accent)
        glow = PaletteCorrector.ensureContrast(glow, against: corrected, minimum: 3)
        let primary = PaletteCorrector.ensureContrast(style(palette.primary, preset: preset, role: .text), against: corrected, minimum: PaletteCorrector.primaryContrast)
        let stops = palette.gradient.map { stop -> RGBColor in
            PaletteCorrector.ensureContrast(style(stop, preset: preset, role: .accent), against: corrected, minimum: 2.5)
        }
        return Palette(background: corrected, primary: primary, highlight: highlight, glow: glow, gradient: stops.isEmpty ? [highlight, glow] : stops)
    }

    private enum Role { case background, accent, text }

    private static func style(_ color: RGBColor, preset: VisualProfilePreset, role: Role) -> RGBColor {
        var (h, s, b) = color.hsb
        switch role {
        case .background:
            s = min(1, s * preset.paletteSaturation)
            // Higher contrast pushes the background darker; lower contrast lifts it slightly.
            b = min(1, max(0, b * (1 - (preset.paletteContrast - 1) * 0.6)))
        case .accent:
            s = min(1, s * preset.paletteSaturation)
            b = min(1, max(0, b * preset.paletteBrightness * (1 + (preset.paletteContrast - 1) * 0.3)))
        case .text:
            s = min(1, s * min(1, preset.paletteSaturation))
            b = min(1, max(0, b * preset.paletteBrightness))
        }
        var result = RGBColor(hue: h, saturation: s, brightness: b)
        result = warmed(result, by: preset.paletteWarmth)
        _ = h
        return result
    }

    /// Positive warmth mixes toward amber, negative toward cool blue.
    static func warmed(_ color: RGBColor, by warmth: Double) -> RGBColor {
        guard abs(warmth) > 0.001 else { return color }
        let tint = warmth > 0 ? RGBColor(r: 1.0, g: 0.82, b: 0.58) : RGBColor(r: 0.6, g: 0.8, b: 1.0)
        let amount = min(0.35, abs(warmth) * 1.2)
        // Preserve brightness so warming never dims the colour.
        let mixed = color.mixed(with: tint, amount: amount)
        return mixed.withBrightness(color.brightness)
    }

    private static func emphasise(_ color: RGBColor, by factor: Double) -> RGBColor {
        let (h, s, b) = color.hsb
        return RGBColor(hue: h, saturation: min(1, s * (0.9 + 0.1 * factor)), brightness: min(1, b * (0.85 + 0.15 * factor)))
    }
}

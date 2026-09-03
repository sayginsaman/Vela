import XCTest
import CoreGraphics
@testable import Vela

final class PaletteTests: XCTestCase {
    func testContrastCorrectionRaisesMuddyForeground() {
        let background = RGBColor(r: 0.05, g: 0.05, b: 0.08)
        let muddy = RGBColor(r: 0.20, g: 0.18, b: 0.16)
        XCTAssertLessThan(muddy.contrastRatio(against: background), 4.5)
        let fixed = PaletteCorrector.ensureContrast(muddy, against: background, minimum: 4.5)
        XCTAssertGreaterThanOrEqual(fixed.contrastRatio(against: background), 4.5)
        // Hue is preserved (warm) while brightness increases.
        XCTAssertEqual(fixed.hue, muddy.hue, accuracy: 0.05)
    }

    func testContrastCorrectionLeavesGoodColorsAlone() {
        let background = RGBColor.black
        let good = RGBColor(r: 0.95, g: 0.8, b: 0.5)
        XCTAssertEqual(PaletteCorrector.ensureContrast(good, against: background, minimum: 4.5), good)
    }

    func testBackgroundIsDarkenedBelowLuminanceCap() {
        let bright = RGBColor(r: 0.9, g: 0.6, b: 0.2)
        let background = PaletteCorrector.darkenedBackground(from: bright)
        XCTAssertLessThanOrEqual(background.relativeLuminance, PaletteCorrector.backgroundMaxLuminance + 0.001)
        XCTAssertGreaterThan(background.saturation, 0.2)
    }

    func testMakePaletteRejectsNearIdenticalColors() {
        let base = RGBColor(r: 0.2, g: 0.4, b: 0.9)
        let similar = RGBColor(r: 0.22, g: 0.42, b: 0.88)
        let palette = PaletteCorrector.makePalette(candidates: [base, similar, similar])
        XCTAssertGreaterThanOrEqual(palette.glow.hueDistance(to: palette.highlight), PaletteCorrector.minimumHueSeparation - 0.001)
        XCTAssertGreaterThanOrEqual(palette.primary.contrastRatio(against: palette.background), PaletteCorrector.primaryContrast)
        XCTAssertGreaterThanOrEqual(palette.highlight.contrastRatio(against: palette.background), PaletteCorrector.highlightContrast)
        XCTAssertGreaterThanOrEqual(palette.gradient.count, 3)
    }

    func testFallbackPaletteWhenArtworkMissing() {
        XCTAssertEqual(PaletteExtractor.palette(from: nil), Palette.fallback)
        XCTAssertGreaterThanOrEqual(Palette.fallback.primary.contrastRatio(against: Palette.fallback.background), 7)
    }

    func testExtractionFromSyntheticArtwork() throws {
        let size = 64
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.6, alpha: 1))   // dominant blue
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.55, blue: 0.1, alpha: 1))  // orange accent
        ctx.fill(CGRect(x: 0, y: 0, width: size / 3, height: size / 3))
        let image = try XCTUnwrap(ctx.makeImage())

        let colors = try XCTUnwrap(PaletteExtractor.prominentColors(in: image))
        XCTAssertGreaterThanOrEqual(colors.count, 2)
        // Dominant (by area) first.
        XCTAssertEqual(colors[0].hue, RGBColor(r: 0.1, g: 0.2, b: 0.6).hue, accuracy: 0.03)
        let palette = PaletteExtractor.palette(from: image)
        // Highlight picks the vivid orange accent.
        XCTAssertEqual(palette.highlight.hue, RGBColor(r: 1, g: 0.55, b: 0.1).hue, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(palette.highlight.contrastRatio(against: palette.background), 4.5)
        XCTAssertLessThanOrEqual(palette.background.relativeLuminance, 0.1)
    }

    func testPaletteMixing() {
        let a = Palette.fallback
        var b = Palette.fallback
        b.highlight = RGBColor(r: 0, g: 0, b: 0)
        let mid = a.mixed(with: b, amount: 0.5)
        XCTAssertEqual(mid.highlight.r, a.highlight.r / 2, accuracy: 0.0001)
    }
}

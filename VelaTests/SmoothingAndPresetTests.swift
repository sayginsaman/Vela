import XCTest
@testable import Vela

final class SmoothingAndPresetTests: XCTestCase {
    func testAttackIsFasterThanRelease() {
        var smoother = AttackReleaseSmoother(attack: 0.05, release: 0.5)
        smoother.update(1, dt: 0.05)
        let afterAttack = smoother.value
        XCTAssertGreaterThan(afterAttack, 0.6)
        smoother.reset(1)
        smoother.update(0, dt: 0.05)
        XCTAssertGreaterThan(smoother.value, 0.85, "release must be slow")
        // Converges eventually.
        for _ in 0..<200 { smoother.update(0, dt: 0.05) }
        XCTAssertLessThan(smoother.value, 0.001)
    }

    func testSmootherIsFrameRateIndependent() {
        var fast = AttackReleaseSmoother(attack: 0.2, release: 0.2)
        var slow = AttackReleaseSmoother(attack: 0.2, release: 0.2)
        for _ in 0..<60 { fast.update(1, dt: 1.0 / 60) }
        for _ in 0..<30 { slow.update(1, dt: 1.0 / 30) }
        XCTAssertEqual(fast.value, slow.value, accuracy: 0.02)
    }

    func testNormalizerAdaptsToLevel() {
        var quiet = RunningNormalizer()
        var loud = RunningNormalizer()
        var q: Float = 0, l: Float = 0
        for _ in 0..<300 { q = quiet.normalize(0.01); l = loud.normalize(0.5) }
        XCTAssertEqual(q, l, accuracy: 0.05, "steady signals normalise to the same level regardless of gain")
        XCTAssertGreaterThan(q, 0.9)
        // A transient above the ceiling saturates, then the ceiling adapts.
        let peak = quiet.normalize(0.05)
        XCTAssertEqual(peak, 1, accuracy: 0.0001)
    }

    func testImpulseDecays() {
        var impulse = Impulse(decayRate: 10)
        impulse.hit(1)
        impulse.advance(dt: 0.1)
        XCTAssertEqual(impulse.value, exp(-1), accuracy: 0.001)
        impulse.hit(0.2)
        XCTAssertEqual(impulse.value, exp(-1), accuracy: 0.001, "a weaker hit never lowers the value")
    }

    func testPresetInterpolationMidpoint() {
        let a = VisualProfilePreset.rapTrap
        let b = VisualProfilePreset.rnbAmbient
        let mid = a.interpolated(to: b, amount: 0.5)
        for path in VisualProfilePreset.fields {
            XCTAssertEqual(mid[keyPath: path], (a[keyPath: path] + b[keyPath: path]) / 2, accuracy: 0.0001)
        }
        XCTAssertEqual(a.interpolated(to: b, amount: 0), a)
        XCTAssertEqual(a.interpolated(to: b, amount: 1), b)
        XCTAssertEqual(a.interpolated(to: b, amount: 2), b, "amount is clamped")
        XCTAssertEqual(a.interpolated(to: b, amount: -1), a, "amount is clamped")
    }

    func testReduceMotionRemovesSpatialImpulsesButKeepsColourReactions() {
        for profile in VisualProfile.allCases {
            let base = VisualProfilePreset.preset(for: profile)
            let reduced = base.applyingReduceMotion(1)
            XCTAssertEqual(reduced.cameraMotion, 0, "\(profile)")
            XCTAssertEqual(reduced.wordPunch, 0, "\(profile)")
            XCTAssertEqual(reduced.particleStreak, 0, "\(profile)")
            XCTAssertLessThanOrEqual(reduced.activeWordScale, 1 + (base.activeWordScale - 1) * 0.25, "\(profile)")
            XCTAssertLessThan(reduced.beatImpulse, base.beatImpulse * 0.2 + 0.0001, "\(profile)")
            XCTAssertLessThanOrEqual(reduced.particleSpeed, base.particleSpeed * 0.31, "\(profile)")
            XCTAssertGreaterThan(reduced.springResponse, base.springResponse, "\(profile) slower springs")
            // Colour and opacity reactions survive.
            XCTAssertEqual(reduced.bassResponse, base.bassResponse, "\(profile)")
            XCTAssertEqual(reduced.bloom, base.bloom, "\(profile)")
            XCTAssertEqual(reduced.paletteSaturation, base.paletteSaturation, "\(profile)")
        }
        XCTAssertEqual(VisualProfilePreset.pop.applyingReduceMotion(0), VisualProfilePreset.pop)
    }

    func testIntensitySlidersScaleTheRightFields() {
        let base = VisualProfilePreset.electronicDance
        let quiet = base.applyingIntensities(reactive: 0.5, background: 1, edge: 1, lyric: 1, particles: true)
        XCTAssertEqual(quiet.bassResponse, base.bassResponse * 0.5, accuracy: 0.0001)
        XCTAssertEqual(quiet.gradientSpeed, base.gradientSpeed)
        let noParticles = base.applyingIntensities(reactive: 1, background: 1, edge: 1, lyric: 1, particles: false)
        XCTAssertEqual(noParticles.particleDensity, 0)
        let stillLyrics = base.applyingIntensities(reactive: 1, background: 1, edge: 1, lyric: 0, particles: true)
        XCTAssertEqual(stillLyrics.activeWordScale, 1, accuracy: 0.0001)
    }

    func testStyledPalettesStayReadable() {
        let palettes = [Palette.fallback,
                        PaletteCorrector.makePalette(candidates: [RGBColor(r: 0.9, g: 0.3, b: 0.2), RGBColor(r: 0.2, g: 0.5, b: 0.9), RGBColor(r: 0.95, g: 0.9, b: 0.3)]),
                        PaletteCorrector.makePalette(candidates: [RGBColor(r: 0.2, g: 0.2, b: 0.25)])]
        for palette in palettes {
            for profile in VisualProfile.allCases {
                let styled = PaletteStyler.apply(VisualProfilePreset.preset(for: profile), to: palette)
                XCTAssertGreaterThanOrEqual(styled.primary.contrastRatio(against: styled.background), PaletteCorrector.primaryContrast, "\(profile)")
                XCTAssertGreaterThanOrEqual(styled.highlight.contrastRatio(against: styled.background), PaletteCorrector.highlightContrast, "\(profile)")
                XCTAssertLessThanOrEqual(styled.background.relativeLuminance, PaletteCorrector.backgroundMaxLuminance + 0.001, "\(profile)")
                // Hue identity is preserved: the highlight stays near the artwork's highlight hue.
                XCTAssertLessThan(styled.highlight.hueDistance(to: palette.highlight), 0.12, "\(profile)")
            }
        }
    }

    func testWarmthPreservesBrightness() {
        let color = RGBColor(r: 0.3, g: 0.5, b: 0.9)
        let warm = PaletteStyler.warmed(color, by: 0.15)
        XCTAssertEqual(warm.brightness, color.brightness, accuracy: 0.001)
        XCTAssertGreaterThan(warm.r, color.r)
    }
}

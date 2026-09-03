import XCTest
@testable import Vela

final class VisualDirectorTests: XCTestCase {
    private func run(_ director: VisualDirector, from start: Double, seconds: Double, features: MusicFeatureSnapshot = .silent, live: Bool = false) -> ReactiveVisualState {
        var state = ReactiveVisualState.initial
        var t = start
        while t < start + seconds {
            state = director.tick(now: t, features: features, isLive: live)
            t += 1.0 / 60
        }
        return state
    }

    func testPaletteConvergesToStyledArtworkPalette() {
        let director = VisualDirector()
        var inputs = VisualDirector.Inputs()
        inputs.profile = .pop
        let artwork = PaletteCorrector.makePalette(candidates: [RGBColor(r: 0.1, g: 0.3, b: 0.9), RGBColor(r: 0.9, g: 0.5, b: 0.1)])
        inputs.palette = artwork
        director.update(inputs: inputs)
        let state = run(director, from: 0, seconds: 8)
        let expected = PaletteStyler.apply(state.preset, to: artwork)
        XCTAssertLessThan(state.palette.highlight.distance(to: expected.highlight), 0.02)
        XCTAssertLessThan(state.palette.background.distance(to: expected.background), 0.02)

        // Switching artwork moves the palette smoothly, not instantly.
        let other = PaletteCorrector.makePalette(candidates: [RGBColor(r: 0.9, g: 0.1, b: 0.2)])
        inputs.palette = other
        director.update(inputs: inputs)
        let early = run(director, from: 8, seconds: 0.2)
        let late = run(director, from: 8.2, seconds: 8)
        let target = PaletteStyler.apply(late.preset, to: other)
        XCTAssertGreaterThan(early.palette.highlight.distance(to: target.highlight), late.palette.highlight.distance(to: target.highlight))
        XCTAssertLessThan(late.palette.highlight.distance(to: target.highlight), 0.02)
    }

    func testProfileCrossfadesInsteadOfSwitching() {
        let director = VisualDirector()
        var inputs = VisualDirector.Inputs()
        inputs.profile = .rnbAmbient
        director.update(inputs: inputs)
        let calm = run(director, from: 0, seconds: 5)
        XCTAssertEqual(calm.preset.tempo, VisualProfilePreset.rnbAmbient.tempo, accuracy: 0.01)

        inputs.profile = .rapTrap
        director.update(inputs: inputs)
        let mid = run(director, from: 5, seconds: 0.6)
        XCTAssertGreaterThan(mid.preset.tempo, VisualProfilePreset.rnbAmbient.tempo + 0.05)
        XCTAssertLessThan(mid.preset.tempo, VisualProfilePreset.rapTrap.tempo - 0.05, "still blending")
        let done = run(director, from: 5.6, seconds: 3)
        XCTAssertEqual(done.preset.tempo, VisualProfilePreset.rapTrap.tempo, accuracy: 0.01)
    }

    func testBreathesWhenNothingIsLiveAndReactsWhenItIs() {
        let director = VisualDirector()
        var inputs = VisualDirector.Inputs()
        inputs.profile = .pop
        inputs.isPlaying = false
        director.update(inputs: inputs)
        let idle = run(director, from: 0, seconds: 4)
        XCTAssertGreaterThan(idle.breathing, 0.9)
        XCTAssertGreaterThan(Double(idle.bands.bass), 0.05, "breathing keeps the light alive")

        inputs.isPlaying = true
        director.update(inputs: inputs)
        var loud = MusicFeatureSnapshot.silent
        loud.bands = AudioBands(bass: 0.9, mid: 0.6, high: 0.5, level: 0.8)
        loud.lowImpulse = 1
        let live = run(director, from: 4, seconds: 4, features: loud, live: true)
        XCTAssertLessThan(live.breathing, 0.1)
        XCTAssertGreaterThan(live.expansion, 0.3)
        XCTAssertGreaterThan(Double(live.bands.bass), 0.7)
    }

    func testReduceMotionRemovesCameraAndPunches() {
        let director = VisualDirector()
        var inputs = VisualDirector.Inputs()
        inputs.profile = .rockMetal
        inputs.reduceMotion = true
        inputs.isPlaying = true
        director.update(inputs: inputs)
        var hits = MusicFeatureSnapshot.silent
        hits.bands = AudioBands(bass: 0.8, mid: 0.8, high: 0.6, level: 0.8)
        hits.midImpulse = 1
        hits.lowImpulse = 1
        let state = run(director, from: 0, seconds: 3, features: hits, live: true)
        XCTAssertEqual(state.preset.cameraMotion, 0)
        XCTAssertEqual(state.preset.wordPunch, 0)
        XCTAssertEqual(state.cameraX, 0, accuracy: 0.0001)
        XCTAssertEqual(state.cameraZoom, 1, accuracy: 0.001)
        XCTAssertTrue(state.lyric.style.reduceMotion)
        // Colour and loudness reactions remain.
        XCTAssertGreaterThan(state.bloom, 0.3)
    }

    func testPreviewOverridesProfileThenEnds() {
        let director = VisualDirector()
        var inputs = VisualDirector.Inputs()
        inputs.profile = .acousticClassical
        director.update(inputs: inputs)
        let start = ProcessInfo.processInfo.systemUptime
        _ = run(director, from: start, seconds: 4)
        director.startPreview(profile: .electronicDance, duration: 1.5)
        XCTAssertTrue(director.isPreviewing)
        let expectation = expectation(description: "preview ends")
        director.onPreviewEnded = { expectation.fulfill() }
        let during = run(director, from: ProcessInfo.processInfo.systemUptime, seconds: 0.5)
        XCTAssertEqual(director.previewProfile, .electronicDance)
        XCTAssertGreaterThan(during.preset.ring, 0.1, "electronic personality is blending in")
        // Advance wall-clock-relative time past the preview duration.
        _ = run(director, from: ProcessInfo.processInfo.systemUptime + 2, seconds: 0.1)
        wait(for: [expectation], timeout: 1)
        XCTAssertFalse(director.isPreviewing)
    }
}

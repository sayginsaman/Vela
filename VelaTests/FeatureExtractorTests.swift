import XCTest
@testable import Vela

final class FeatureExtractorTests: XCTestCase {
    /// A click train at a known tempo with a sustained bed.
    private func click(bpm: Double, at t: Double) -> FrameDescriptor {
        let beat = t * bpm / 60
        let phase = beat - floor(beat)
        let hit = exp(-phase * 12)
        return FrameDescriptor(time: t, bass: Float(0.3 + 0.8 * hit), mid: Float(0.2 + 0.3 * hit), high: Float(0.1 + 0.4 * hit),
                               level: Float(0.2 + 0.5 * hit), centroid: 0.5, flux: Float(0.02 + hit * 0.8))
    }

    func testEstimatesTempoAndOnsetsFromClickTrain() {
        var extractor = FeatureExtractor()
        let rate = FeatureExtractor.gridRate
        var snapshot = MusicFeatureSnapshot.silent
        for i in 0..<Int(rate * 12) { snapshot = extractor.ingest(click(bpm: 120, at: Double(i) / rate)) }
        XCTAssertEqual(Double(snapshot.bpm), 120, accuracy: 3)
        XCTAssertGreaterThan(snapshot.bpmConfidence, 0.5)
        XCTAssertGreaterThan(snapshot.rhythmicRegularity, 0.6)
        XCTAssertEqual(Double(snapshot.onsetDensity), 2, accuracy: 0.6)
        XCTAssertGreaterThan(snapshot.transientStrength, 0.3)
        XCTAssertGreaterThan(snapshot.bassToMid, 0.5, "bass-heavy click train")
    }

    func testBeatImpulseFiresOnceAroundEachBeat() {
        var extractor = FeatureExtractor()
        let rate = FeatureExtractor.gridRate
        var fires = 0
        var previous: Float = 0
        for i in 0..<Int(rate * 20) {
            let s = extractor.ingest(click(bpm: 100, at: Double(i) / rate))
            if s.beatImpulse > previous + 0.3 { fires += 1 }
            previous = s.beatImpulse
        }
        // Tempo needs a few seconds to settle; afterwards roughly 100/60 beats per second.
        XCTAssertGreaterThan(fires, 12)
        XCTAssertLessThan(fires, 36)
    }

    func testSilenceHasNoRhythm() {
        var extractor = FeatureExtractor()
        var s = MusicFeatureSnapshot.silent
        for i in 0..<600 {
            s = extractor.ingest(FrameDescriptor(time: Double(i) / 50, bass: 0.001, mid: 0.001, high: 0.001, level: 0.001, centroid: 0.4, flux: 0))
        }
        XCTAssertEqual(s.onsetDensity, 0)
        XCTAssertLessThan(s.bpmConfidence, 0.3)
    }

    func testResetClearsRhythmHistory() {
        var extractor = FeatureExtractor()
        let rate = FeatureExtractor.gridRate
        for i in 0..<Int(rate * 12) { _ = extractor.ingest(click(bpm: 120, at: Double(i) / rate)) }
        XCTAssertGreaterThan(extractor.snapshot.bpm, 0)
        extractor.reset()
        XCTAssertEqual(extractor.snapshot, .silent)
    }

    func testDynamicRangeReflectsLevelVariation() {
        var flat = FeatureExtractor()
        var dynamic = FeatureExtractor()
        var f = MusicFeatureSnapshot.silent, d = MusicFeatureSnapshot.silent
        for i in 0..<600 {
            let t = Double(i) / 50
            f = flat.ingest(FrameDescriptor(time: t, bass: 0.3, mid: 0.3, high: 0.2, level: 0.4, centroid: 0.5, flux: 0.01))
            let swell = Float(0.5 + 0.5 * sin(t * 1.5))
            d = dynamic.ingest(FrameDescriptor(time: t, bass: 0.3 * swell, mid: 0.3 * swell, high: 0.2 * swell, level: 0.05 + 0.6 * swell, centroid: 0.5, flux: 0.01))
        }
        XCTAssertLessThan(f.dynamicRange, 0.15)
        XCTAssertGreaterThan(d.dynamicRange, 0.5)
    }
}

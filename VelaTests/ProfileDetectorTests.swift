import XCTest
@testable import Vela

final class ProfileDetectorTests: XCTestCase {
    private func feed(_ detector: ProfileDetector, _ profile: VisualProfile, seconds: Double, from start: Double = 0, step: Double = 0.25) -> Double {
        var t = start
        while t < start + seconds {
            detector.ingest(SyntheticFeatures.make(profile), at: t)
            t += step
        }
        return t
    }

    func testWaitsForInitialWindowThenLocks() {
        let detector = ProfileDetector()
        detector.reset(trackID: "a", genre: nil)
        XCTAssertFalse(detector.detection.isSettled)
        var t = feed(detector, .electronicDance, seconds: 4)
        XCTAssertFalse(detector.detection.isSettled, "must not decide inside the initial window")
        t = feed(detector, .electronicDance, seconds: 5, from: t)
        XCTAssertTrue(detector.detection.isSettled)
        XCTAssertEqual(detector.detection.profile, .electronicDance)
        XCTAssertEqual(detector.detection.source, .audio)
        XCTAssertGreaterThanOrEqual(detector.detection.confidence, ProfileClassifier.lockConfidence)
    }

    func testLowConfidenceFallsBackToPop() {
        let detector = ProfileDetector()
        detector.reset(trackID: "a", genre: nil)
        var t = 0.0
        while t < 10 { detector.ingest(SyntheticFeatures.muddled, at: t); t += 0.25 }
        XCTAssertTrue(detector.detection.isSettled)
        XCTAssertEqual(detector.detection.profile, .pop)
        XCTAssertEqual(detector.detection.source, .fallback)
    }

    func testStableAgainstBriefContradictions() {
        let detector = ProfileDetector()
        detector.reset(trackID: "a", genre: nil)
        var t = feed(detector, .rapTrap, seconds: 10)
        XCTAssertEqual(detector.detection.profile, .rapTrap)
        var changes = 0
        // Alternate every 2 seconds for a minute: the lock must hold.
        for cycle in 0..<15 {
            let profile: VisualProfile = cycle.isMultiple(of: 2) ? .rockMetal : .rapTrap
            var step = t
            while step < t + 2 {
                if detector.ingest(SyntheticFeatures.make(profile), at: step) != nil { changes += 1 }
                step += 0.25
            }
            t += 2
        }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(detector.detection.profile, .rapTrap)
    }

    func testSustainedSubstantialChangeSwitches() {
        let detector = ProfileDetector()
        detector.reset(trackID: "a", genre: nil)
        var t = feed(detector, .acousticClassical, seconds: 10)
        XCTAssertEqual(detector.detection.profile, .acousticClassical)
        // The song turns into an EDM drop for 40 seconds: a sustained, confident contradiction.
        t = feed(detector, .electronicDance, seconds: 40, from: t)
        XCTAssertEqual(detector.detection.profile, .electronicDance)
    }

    func testTrackChangeResets() {
        let detector = ProfileDetector()
        detector.reset(trackID: "a", genre: nil)
        _ = feed(detector, .rockMetal, seconds: 10)
        XCTAssertEqual(detector.detection.profile, .rockMetal)
        detector.reset(trackID: "b", genre: nil)
        XCTAssertEqual(detector.detection, .pending)
        XCTAssertEqual(detector.trackID, "b")
        XCTAssertEqual(detector.audioEstimate, .neutral)
        _ = feed(detector, .rnbAmbient, seconds: 10)
        XCTAssertEqual(detector.detection.profile, .rnbAmbient)
    }

    func testManualSelectionOverridesDetection() {
        let detection = ProfileDetection(profile: .rockMetal, confidence: 0.9, source: .audio, isSettled: true)
        XCTAssertEqual(ProfileResolver.resolve(selection: .auto, detection: detection), .rockMetal)
        XCTAssertEqual(ProfileResolver.resolve(selection: .rnbAmbient, detection: detection), .rnbAmbient)
        XCTAssertEqual(ProfileResolver.resolve(selection: .auto, detection: .pending), .pop)
    }
}

import XCTest
@testable import Vela

final class ProfileClassifierTests: XCTestCase {
    func testMembershipFalloff() {
        XCTAssertEqual(ProfileClassifier.membership(0.5, in: 0.4...0.6, soft: 0.1), 1)
        XCTAssertEqual(ProfileClassifier.membership(0.65, in: 0.4...0.6, soft: 0.1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ProfileClassifier.membership(0.8, in: 0.4...0.6, soft: 0.1), 0)
        XCTAssertEqual(ProfileClassifier.membership(0.35, in: 0.4...0.6, soft: 0.1), 0.5, accuracy: 0.0001)
    }

    func testSyntheticFeaturesClassifyToTheirProfile() {
        for profile in VisualProfile.genreProfiles {
            let result = ProfileClassifier.classify(SyntheticFeatures.make(profile))
            XCTAssertEqual(result.best, profile, "expected \(profile), scores: \(result.scores)")
            XCTAssertGreaterThanOrEqual(result.confidence, ProfileClassifier.lockConfidence, "confidence for \(profile)")
        }
    }

    func testMuddledFeaturesAreNotConfident() {
        let result = ProfileClassifier.classify(SyntheticFeatures.muddled)
        XCTAssertLessThan(result.confidence, ProfileClassifier.lockConfidence)
    }

    func testClassificationIsDeterministic() {
        let a = ProfileClassifier.classify(SyntheticFeatures.make(.rockMetal))
        let b = ProfileClassifier.classify(SyntheticFeatures.make(.rockMetal))
        XCTAssertEqual(a, b)
    }

    /// End-to-end: every demo fixture, run through the real extractor, must classify as itself.
    func testFixturesClassifyThroughTheExtractor() {
        for profile in VisualProfile.genreProfiles {
            let fixture = ProfileFixture(profile: profile)
            var extractor = FeatureExtractor()
            var snapshot = MusicFeatureSnapshot.silent
            let rate = FeatureExtractor.gridRate
            for i in 0..<Int(rate * 16) {
                snapshot = extractor.ingest(fixture.descriptor(at: Double(i) / rate))
            }
            let result = ProfileClassifier.classify(snapshot)
            XCTAssertEqual(result.best, profile, "fixture \(profile) → \(result.best) conf \(result.confidence) features \(snapshot)")
            XCTAssertGreaterThanOrEqual(result.confidence, ProfileClassifier.lockConfidence, "fixture \(profile) confidence")
        }
    }
}

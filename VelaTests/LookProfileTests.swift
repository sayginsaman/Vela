import CoreGraphics
import XCTest
@testable import Vela

/// LED Strip and Cover Art are looks the user picks, not personalities the music implies. These
/// tests pin down both halves of that: they render with their own weights, and detection can never
/// land on them.
final class LookProfileTests: XCTestCase {
    // MARK: Catalogue

    func testEveryProfileIsEitherAGenreOrALook() {
        let grouped = Set(VisualProfile.genreProfiles + VisualProfile.lookProfiles)
        XCTAssertEqual(grouped, Set(VisualProfile.allCases), "A new profile must be placed in one group.")
        XCTAssertTrue(Set(VisualProfile.genreProfiles).isDisjoint(with: VisualProfile.lookProfiles))
        XCTAssertEqual(VisualProfile.genreProfiles.count, 9)
    }

    func testPickerGroupsCoverEverySelectionOnce() {
        let grouped = VisualProfileSelection.musicSelections + VisualProfileSelection.lookSelections
        XCTAssertEqual(grouped.first, .auto)
        XCTAssertEqual(Set(grouped), Set(VisualProfileSelection.allCases))
        XCTAssertEqual(grouped.count, VisualProfileSelection.allCases.count, "No selection appears twice.")
        XCTAssertEqual(VisualProfileSelection.lookSelections.compactMap(\.profile), VisualProfile.lookProfiles)
    }

    func testLooksHaveNamesAndSurviveASave() throws {
        XCTAssertEqual(VisualProfile.ledStrip.displayName, "LED Strip")
        XCTAssertEqual(VisualProfile.coverArt.displayName, "Cover Art")
        var settings = VelaSettings()
        settings.visualProfile = .coverArt
        let loaded = try JSONDecoder().decode(VelaSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.visualProfile, .coverArt)
        XCTAssertEqual(loaded.visualProfile.profile, .coverArt)
    }

    // MARK: Detection never chooses a look

    func testClassifierOnlyScoresGenreProfiles() {
        let inputs = VisualProfile.genreProfiles.map(SyntheticFeatures.make) + [SyntheticFeatures.muddled, MusicFeatureSnapshot()]
        for features in inputs {
            let result = ProfileClassifier.classify(features)
            XCTAssertTrue(Set(result.scores.keys).isSubset(of: VisualProfile.genreProfiles))
            XCTAssertTrue(result.best.isGenreProfile, "Classifier chose \(result.best).")
        }
    }

    func testDetectorSettlesOnAGenreWhenPlayingALooksPreviewMusic() {
        // The looks borrow the Pop pattern for previews; detection must read that as Pop.
        let detector = ProfileDetector()
        let fixture = ProfileFixture(profile: .coverArt)
        var extractor = FeatureExtractor()
        let rate = FeatureExtractor.gridRate
        for i in 0..<Int(rate * 20) {
            let time = Double(i) / rate
            detector.ingest(extractor.ingest(fixture.descriptor(at: time)), at: time)
        }
        XCTAssertTrue(detector.detection.profile.isGenreProfile, "Detected \(detector.detection.profile).")
        XCTAssertTrue(detector.audioEstimate.best.isGenreProfile)
    }

    func testGenreNamesNeverMapToALook() {
        for genre in ["LED", "led strip", "Cover", "cover art", "Soundtrack", "Pop", "Hip-Hop/Rap", "K-Pop"] {
            if let profile = GenreNormalizer.profile(for: genre) {
                XCTAssertTrue(profile.isGenreProfile, "\(genre) mapped to \(profile).")
            }
        }
    }

    // MARK: Presets

    func testLookWeights() {
        let led = VisualProfilePreset.preset(for: .ledStrip)
        XCTAssertEqual(led.ledStrip, 1)
        XCTAssertEqual(led.coverArt, 0, "LED Strip keeps the ambient backdrop.")
        let cover = VisualProfilePreset.preset(for: .coverArt)
        XCTAssertEqual(cover.ledStrip, 1, "Cover Art is framed by the same strip.")
        XCTAssertEqual(cover.coverArt, 1)
        for profile in VisualProfile.genreProfiles {
            let preset = VisualProfilePreset.preset(for: profile)
            XCTAssertEqual(preset.ledStrip, 0, "\(profile)")
            XCTAssertEqual(preset.coverArt, 0, "\(profile)")
            XCTAssertFalse(profile.usesLEDStrip)
        }
        XCTAssertTrue(VisualProfile.ledStrip.usesLEDStrip)
        XCTAssertTrue(VisualProfile.coverArt.usesLEDStrip)
    }

    func testLooksCrossfadeRatherThanSnap() {
        let halfway = VisualProfilePreset.pop.interpolated(to: .coverArt, amount: 0.5)
        XCTAssertEqual(halfway.ledStrip, 0.5, accuracy: 0.0001)
        XCTAssertEqual(halfway.coverArt, 0.5, accuracy: 0.0001)
        XCTAssertTrue(VisualProfilePreset.fields.contains(\.ledStrip))
        XCTAssertTrue(VisualProfilePreset.fields.contains(\.coverArt))
    }

    func testCoverArtKeepsTheArtworkClean() {
        let cover = VisualProfilePreset.coverArt
        XCTAssertEqual(cover.particleDensity, 0)
        XCTAssertEqual(cover.gradientDistortion, 0)
        XCTAssertEqual(cover.ring + cover.slices + cover.streaks, 0)
        XCTAssertEqual(cover.edgeTravel, 0, "An LED strip does not travel.")
        XCTAssertEqual(VisualProfilePreset.ledStrip.edgeTravel, 0)
    }

    func testUserIntensitiesDoNotSwitchALookOff() {
        let muted = VisualProfilePreset.coverArt.applyingIntensities(reactive: 0, background: 0, edge: 0, lyric: 0, particles: false)
            .applyingReduceMotion(1)
        XCTAssertEqual(muted.coverArt, 1, "Sliders tone the look down; they never turn the cover back into the wash.")
        XCTAssertEqual(muted.ledStrip, 1)
    }

    // MARK: Cover texture

    private func image(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testCoverIsSquareAndNeverUpscaled() throws {
        let small = try XCTUnwrap(ArtworkProcessor.makeCover(from: image(width: 640, height: 480)))
        XCTAssertEqual(small.width, 640)
        XCTAssertEqual(small.height, 640, "Aspect-filled into a square the size of the long side.")
    }

    func testCoverIsCappedForHugeArtwork() throws {
        let huge = try XCTUnwrap(ArtworkProcessor.makeCover(from: image(width: 3000, height: 3000)))
        XCTAssertEqual(huge.width, ArtworkProcessor.maximumCoverSize)
        XCTAssertEqual(huge.height, ArtworkProcessor.maximumCoverSize)
    }

    func testCoverKeepsTheArtworksColour() throws {
        // The backdrops are blurred and darkened; the cover must come through untouched.
        let cover = try XCTUnwrap(ArtworkProcessor.makeCover(from: image(width: 64, height: 64)))
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cover, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Double(pixel[0]) / 255, 0.9, accuracy: 0.06)
        XCTAssertEqual(Double(pixel[1]) / 255, 0.2, accuracy: 0.06)
        XCTAssertEqual(Double(pixel[2]) / 255, 0.5, accuracy: 0.06)
    }

    func testProcessingProducesACover() async {
        let output = await ArtworkProcessor.process(image(width: 400, height: 400))
        XCTAssertNotNil(output.cover)
        let empty = await ArtworkProcessor.process(nil)
        XCTAssertNil(empty.cover)
    }
}

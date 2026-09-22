import CoreGraphics
import XCTest
@testable import Vela

/// Cover Art is a look the user picks, not a personality the music implies, and the LED strip is
/// every profile's edge. These tests pin down both: the look renders with its own weight and is
/// never detected, and the strip is on by default and moves with the music.
final class LookProfileTests: XCTestCase {
    // MARK: Catalogue

    func testEveryProfileIsEitherAGenreOrALook() {
        let grouped = Set(VisualProfile.genreProfiles + VisualProfile.lookProfiles)
        XCTAssertEqual(grouped, Set(VisualProfile.allCases), "A new profile must be placed in one group.")
        XCTAssertTrue(Set(VisualProfile.genreProfiles).isDisjoint(with: VisualProfile.lookProfiles))
        XCTAssertEqual(VisualProfile.genreProfiles.count, 9)
        XCTAssertEqual(VisualProfile.lookProfiles, [.coverArt], "The LED strip is every profile's edge, not a profile.")
    }

    func testPickerGroupsCoverEverySelectionOnce() {
        let grouped = VisualProfileSelection.musicSelections + VisualProfileSelection.lookSelections
        XCTAssertEqual(grouped.first, .auto)
        XCTAssertEqual(Set(grouped), Set(VisualProfileSelection.allCases))
        XCTAssertEqual(grouped.count, VisualProfileSelection.allCases.count, "No selection appears twice.")
        XCTAssertEqual(VisualProfileSelection.lookSelections.compactMap(\.profile), VisualProfile.lookProfiles)
    }

    func testCoverArtSurvivesASave() throws {
        XCTAssertEqual(VisualProfile.coverArt.displayName, "Cover Art")
        var settings = VelaSettings()
        settings.visualProfile = .coverArt
        let loaded = try JSONDecoder().decode(VelaSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.visualProfile, .coverArt)
    }

    /// 2.3 shipped LED Strip as a profile. A saved selection of it must fall back to Auto, and
    /// must not make the decoder throw: a throw would reset every other setting too.
    func testRetiredLEDStripSelectionFallsBackToAutoAndKeepsTheRest() throws {
        var settings = VelaSettings()
        settings.lyricSize = 1.3
        settings.sceneLayout = .split
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json["visualProfile"] = "ledStrip"
        json.removeValue(forKey: "edgeLightStyle")
        let loaded = try JSONDecoder().decode(VelaSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.visualProfile, .auto)
        XCTAssertEqual(loaded.lyricSize, 1.3, "The rest of the settings must survive the migration.")
        XCTAssertEqual(loaded.sceneLayout, .split)
        XCTAssertEqual(loaded.edgeLightStyle, .ledStrip, "Everyone gets the LED strip by default, including upgraders.")
    }

    func testUnknownEdgeStyleFallsBackToTheStrip() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(VelaSettings())) as? [String: Any])
        json["edgeLightStyle"] = "neon"
        json["lyricSize"] = 1.2
        let loaded = try JSONDecoder().decode(VelaSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.edgeLightStyle, .ledStrip)
        XCTAssertEqual(loaded.lyricSize, 1.2)
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
        // Cover Art borrows the Pop pattern for previews; detection must read that as a genre.
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

    // MARK: Cover Art

    func testCoverArtNeverSplits() {
        XCTAssertFalse(StageLayout.wantsSplit(.split, hasTrack: true, profile: .coverArt),
                       "The panel would show the cover a second time beside the lyrics.")
        XCTAssertTrue(StageLayout.wantsSplit(.split, hasTrack: true, profile: .rapTrap))
        XCTAssertFalse(StageLayout.wantsSplit(.split, hasTrack: false, profile: .rapTrap))
        XCTAssertFalse(StageLayout.wantsSplit(.centered, hasTrack: true, profile: .rapTrap))
        for profile in VisualProfile.genreProfiles { XCTAssertTrue(profile.allowsSplitLayout) }
    }

    func testCoverArtCentresTheLyricsAcrossTheWindow() {
        let size = CGSize(width: 1600, height: 900)
        let layout = StageLayout(size: size, split: StageLayout.wantsSplit(.split, hasTrack: true, profile: .coverArt))
        XCTAssertFalse(layout.isSplit)
        XCTAssertEqual(layout.alignment, .center)
        XCTAssertEqual(layout.lyricWidth, size.width, "The lyric column spans the window, so centred words sit in its middle.")
        XCTAssertEqual(layout.leadingInset, 0)
    }

    func testCoverWeight() {
        XCTAssertEqual(VisualProfilePreset.preset(for: .coverArt).coverArt, 1)
        for profile in VisualProfile.genreProfiles {
            XCTAssertEqual(VisualProfilePreset.preset(for: profile).coverArt, 0, "\(profile)")
        }
    }

    func testCoverArtCrossfadesRatherThanSnaps() {
        let halfway = VisualProfilePreset.pop.interpolated(to: .coverArt, amount: 0.5)
        XCTAssertEqual(halfway.coverArt, 0.5, accuracy: 0.0001)
        XCTAssertTrue(VisualProfilePreset.fields.contains(\.coverArt))
    }

    func testCoverArtKeepsTheArtworkClean() {
        let cover = VisualProfilePreset.coverArt
        XCTAssertEqual(cover.particleDensity, 0)
        XCTAssertEqual(cover.gradientDistortion, 0)
        XCTAssertEqual(cover.ring + cover.slices + cover.streaks, 0)
    }

    func testUserIntensitiesDoNotSwitchTheCoverOff() {
        let muted = VisualProfilePreset.coverArt.applyingIntensities(reactive: 0, background: 0, edge: 0, lyric: 0, particles: false)
            .applyingReduceMotion(1)
        XCTAssertEqual(muted.coverArt, 1, "Sliders tone the look down; they never turn the cover back into the wash.")
    }

    // MARK: LED strip, every profile

    func testLEDStripIsTheDefaultEdge() {
        XCTAssertEqual(VelaSettings().edgeLightStyle, .ledStrip)
        XCTAssertTrue(VisualDirector.Inputs().ledStrip)
    }

    /// Runs the director for a while and returns how far the strip's running light travelled
    /// over the last `measure` seconds, unwrapping the 0…1 phase.
    private func chaseDistance(profile: VisualProfile, loud: Bool, reduceMotion: Bool = false, ledStrip: Bool = true,
                               seconds: Double = 8, measure: Double = 4) -> (distance: Double, mix: Double) {
        let director = VisualDirector()
        var inputs = VisualDirector.Inputs()
        inputs.profile = profile
        inputs.isPlaying = true
        inputs.reduceMotion = reduceMotion
        inputs.ledStrip = ledStrip
        director.update(inputs: inputs)
        let fps = 60.0
        var previous: Double?
        var travelled = 0.0
        var state = ReactiveVisualState.initial
        for frame in 0..<Int(seconds * fps) {
            let now = 1000 + Double(frame) / fps
            var f = MusicFeatureSnapshot()
            if loud {
                // Four-on-the-floor at 120 BPM: a kick every half second on top of a loud mix.
                let beatPhase = (Double(frame) / fps * 2).truncatingRemainder(dividingBy: 1)
                let hit = Float(exp(-beatPhase * 10))
                f.bands = AudioBands(bass: 0.4 + 0.5 * hit, mid: 0.5, high: 0.4, level: 0.8)
                f.lowImpulse = hit
                f.beatImpulse = hit
                f.beatPhase = Float(beatPhase)
                f.bpm = 120
                f.bpmConfidence = 0.9
                f.averageLoudness = 0.8
            }
            state = director.tick(now: now, features: f, isLive: loud)
            if Double(frame) >= (seconds - measure) * fps, let previous {
                travelled += (state.ledPhase - previous + 1).truncatingRemainder(dividingBy: 1)
            }
            previous = state.ledPhase
        }
        return (travelled, state.ledStrip)
    }

    func testTheStripsLightRunsWithTheMusic() {
        let quiet = chaseDistance(profile: .pop, loud: false)
        let loud = chaseDistance(profile: .pop, loud: true)
        XCTAssertGreaterThan(quiet.distance, 0, "Even at rest the light drifts, so the strip never looks frozen.")
        XCTAssertGreaterThan(loud.distance, quiet.distance * 3, "Kicks and loudness must drive the light visibly faster.")
    }

    func testTheStripKeepsEachProfilesCharacter() {
        let electronic = chaseDistance(profile: .electronicDance, loud: true)
        let acoustic = chaseDistance(profile: .acousticClassical, loud: true)
        XCTAssertGreaterThan(electronic.distance, acoustic.distance, "Electronic runs its light harder than Acoustic.")
    }

    func testReduceMotionCalmsTheRunningLight() {
        let normal = chaseDistance(profile: .pop, loud: true)
        let reduced = chaseDistance(profile: .pop, loud: true, reduceMotion: true)
        XCTAssertLessThan(reduced.distance, normal.distance * 0.25)
    }

    func testChoosingGlowFadesTheStripOut() {
        XCTAssertEqual(chaseDistance(profile: .pop, loud: false, ledStrip: true).mix, 1, accuracy: 0.01)
        XCTAssertEqual(chaseDistance(profile: .pop, loud: false, ledStrip: false).mix, 0, accuracy: 0.01)
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

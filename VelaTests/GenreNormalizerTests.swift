import XCTest
@testable import Vela

final class GenreNormalizerTests: XCTestCase {
    func testMapsCommonGenreStrings() {
        let cases: [(String, VisualProfile?)] = [
            ("Hip-Hop/Rap", .rapTrap), ("Trap", .rapTrap), ("UK Drill", .rapTrap), ("hip hop", .rapTrap),
            ("Rock", .rockMetal), ("Heavy Metal", .rockMetal), ("Pop Punk", .pop), ("Alternative Rock", .rockMetal),
            ("Grunge", .rockMetal), ("Punk", .rockMetal),
            ("Alternative", .indieAlternative), ("Indie", .indieAlternative), ("Indie Rock", .indieAlternative),
            ("Dream Pop", .indieAlternative), ("Shoegaze", .indieAlternative),
            ("Jazz", .jazzBlues), ("Blues", .jazzBlues), ("Smooth Jazz", .jazzBlues), ("Bossa Nova", .jazzBlues),
            ("Latin", .latinAfrobeats), ("Reggaeton", .latinAfrobeats), ("Afrobeats", .latinAfrobeats),
            ("Latin Pop", .latinAfrobeats), ("Dancehall", .latinAfrobeats), ("Salsa", .latinAfrobeats),
            ("Electronic", .electronicDance), ("EDM", .electronicDance), ("Deep House", .electronicDance),
            ("Techno", .electronicDance), ("Trance", .electronicDance), ("Synthwave", .electronicDance),
            ("Drum & Bass", .electronicDance),
            ("Pop", .pop), ("Dance Pop", .pop), ("dance-pop", .pop), ("Indie Pop", .pop), ("K-Pop", .pop), ("Synth-Pop", .pop),
            ("R&B/Soul", .rnbAmbient), ("Soul", .rnbAmbient), ("Lo-Fi", .rnbAmbient), ("Ambient", .rnbAmbient),
            ("Chill", .rnbAmbient), ("Neo-Soul", .rnbAmbient),
            ("Acoustic", .acousticClassical), ("Classical", .acousticClassical), ("Piano", .acousticClassical),
            ("Folk", .acousticClassical), ("Orchestral", .acousticClassical), ("Singer/Songwriter", .acousticClassical),
            ("Indie Folk", .acousticClassical),
            ("", nil), ("Podcast", nil), ("Unknown Genre", nil),
        ]
        for (genre, expected) in cases {
            XCTAssertEqual(GenreNormalizer.profile(for: genre), expected, "genre \(genre)")
        }
        XCTAssertNil(GenreNormalizer.profile(for: nil))
    }

    func testPhrasesBeatTokens() {
        // "dance" alone is electronic, but "dance pop" is pop.
        XCTAssertEqual(GenreNormalizer.profile(for: "Dance"), .electronicDance)
        XCTAssertEqual(GenreNormalizer.profile(for: "Dance Pop"), .pop)
        XCTAssertEqual(GenreNormalizer.profile(for: "Alternative Rock"), .rockMetal)
        XCTAssertEqual(GenreNormalizer.profile(for: "Indie Rock"), .indieAlternative)
        XCTAssertEqual(GenreNormalizer.profile(for: "Indie Pop"), .pop)
    }

    func testDetectorLocksFromGenreImmediately() {
        let detector = ProfileDetector()
        detector.reset(trackID: "t1", genre: "Alternative Rock")
        XCTAssertEqual(detector.detection.profile, .rockMetal)
        XCTAssertEqual(detector.detection.source, .genre)
        XCTAssertTrue(detector.detection.isSettled)
        // Audio evidence never overrides genre metadata.
        for i in 0..<200 {
            detector.ingest(SyntheticFeatures.make(.electronicDance), at: Double(i) * 0.25)
        }
        XCTAssertEqual(detector.detection.profile, .rockMetal)
        XCTAssertEqual(detector.audioEstimate.best, .electronicDance)
    }
}

/// Hand-built feature vectors sitting in the middle of each profile's ranges.
enum SyntheticFeatures {
    static func make(_ profile: VisualProfile) -> MusicFeatureSnapshot {
        var f = MusicFeatureSnapshot()
        switch profile {
        case .rapTrap:
            f.bpm = 140; f.bpmConfidence = 0.7; f.bassToMid = 0.78; f.spectralCentroid = 0.28; f.highEnergy = 0.5
            f.transientStrength = 0.8; f.rhythmicRegularity = 0.65; f.onsetDensity = 3; f.averageLoudness = 0.5
            f.dynamicRange = 0.6; f.spectralFlux = 0.3
        case .rockMetal:
            f.bpm = 150; f.bpmConfidence = 0.65; f.bassToMid = 0.28; f.spectralCentroid = 0.7; f.highEnergy = 0.85
            f.transientStrength = 0.85; f.rhythmicRegularity = 0.55; f.onsetDensity = 5; f.averageLoudness = 0.85
            f.dynamicRange = 0.15; f.spectralFlux = 0.7
        case .electronicDance:
            f.bpm = 128; f.bpmConfidence = 0.9; f.bassToMid = 0.62; f.spectralCentroid = 0.55; f.highEnergy = 0.78
            f.transientStrength = 0.7; f.rhythmicRegularity = 0.9; f.onsetDensity = 5; f.averageLoudness = 0.8
            f.dynamicRange = 0.15; f.spectralFlux = 0.45
        case .pop:
            f.bpm = 112; f.bpmConfidence = 0.7; f.bassToMid = 0.45; f.spectralCentroid = 0.5; f.highEnergy = 0.42
            f.transientStrength = 0.6; f.rhythmicRegularity = 0.75; f.onsetDensity = 2.2; f.averageLoudness = 0.7
            f.dynamicRange = 0.32; f.spectralFlux = 0.25
        case .rnbAmbient:
            f.bpm = 82; f.bpmConfidence = 0.3; f.bassToMid = 0.68; f.spectralCentroid = 0.22; f.highEnergy = 0.15
            f.transientStrength = 0.2; f.rhythmicRegularity = 0.5; f.onsetDensity = 1.0; f.averageLoudness = 0.7
            f.dynamicRange = 0.25; f.spectralFlux = 0.1
        case .acousticClassical:
            f.bpm = 72; f.bpmConfidence = 0.3; f.bassToMid = 0.1; f.spectralCentroid = 0.48; f.highEnergy = 0.15
            f.transientStrength = 0.25; f.rhythmicRegularity = 0.5; f.onsetDensity = 2.0; f.averageLoudness = 0.4
            f.dynamicRange = 0.8; f.spectralFlux = 0.1
        case .jazzBlues:
            f.bpm = 118; f.bpmConfidence = 0.4; f.bassToMid = 0.45; f.spectralCentroid = 0.47; f.highEnergy = 0.35
            f.transientStrength = 0.48; f.rhythmicRegularity = 0.45; f.onsetDensity = 3.5; f.averageLoudness = 0.5
            f.dynamicRange = 0.6; f.spectralFlux = 0.28
        case .latinAfrobeats:
            f.bpm = 96; f.bpmConfidence = 0.75; f.bassToMid = 0.68; f.spectralCentroid = 0.56; f.highEnergy = 0.65
            f.transientStrength = 0.7; f.rhythmicRegularity = 0.72; f.onsetDensity = 6; f.averageLoudness = 0.75
            f.dynamicRange = 0.28; f.spectralFlux = 0.48
        case .indieAlternative:
            f.bpm = 124; f.bpmConfidence = 0.6; f.bassToMid = 0.4; f.spectralCentroid = 0.58; f.highEnergy = 0.48
            f.transientStrength = 0.46; f.rhythmicRegularity = 0.62; f.onsetDensity = 3.5; f.averageLoudness = 0.56
            f.dynamicRange = 0.4; f.spectralFlux = 0.39
        }
        f.bands = AudioBands(bass: f.bassToMid, mid: 0.5, high: f.highEnergy, level: f.averageLoudness)
        return f
    }

    /// Contradictory evidence (huge dynamics, hard attacks, almost no onsets, no rhythm): no profile fits.
    static var muddled: MusicFeatureSnapshot {
        var f = MusicFeatureSnapshot()
        f.bpm = 200; f.bpmConfidence = 0.15; f.bassToMid = 0.5; f.spectralCentroid = 0.5; f.highEnergy = 0.5
        f.transientStrength = 0.95; f.rhythmicRegularity = 0.1; f.onsetDensity = 0.3; f.averageLoudness = 0.15
        f.dynamicRange = 0.95; f.spectralFlux = 0.5
        return f
    }
}

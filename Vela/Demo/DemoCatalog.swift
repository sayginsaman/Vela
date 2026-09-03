import Foundation

/// The songs Demo Mode plays. Everything here is original material written for Vela.
struct DemoTrack: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var bpm: Double
    /// Bundle resource holding the lyrics (`.lrc` or `.txt`). `nil` for instrumentals.
    var lyricsResource: (name: String, ext: String)?
    var isInstrumental: Bool
    /// Artwork hues (0...1) used by `DemoArtwork`.
    var hues: [Double]
    var artworkSeed: UInt64
    /// Genre metadata the demo player reports, exercising the metadata path of Auto detection.
    var genre: String?
    /// Audio fixture that drives the ambient light and the heuristic classifier.
    var fixtureProfile: VisualProfile

    static func == (lhs: DemoTrack, rhs: DemoTrack) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var trackInfo: TrackInfo {
        TrackInfo(id: id, title: title, artist: artist, album: album, duration: duration, source: .demo, artworkURL: nil, genre: genre)
    }

    var fixture: ProfileFixture { ProfileFixture(profile: fixtureProfile, bpm: bpm) }
}

enum DemoCatalog {
    static let tracks: [DemoTrack] = [
        DemoTrack(id: "demo-concrete-halo", title: "Concrete Halo", artist: "Juno Ash", album: "Night Shift",
                  duration: 88, bpm: 140, lyricsResource: ("concrete-halo", "lrc"), isInstrumental: false,
                  hues: [0.72, 0.95, 0.12], artworkSeed: 53, genre: "Hip-Hop/Rap", fixtureProfile: .rapTrap),
        DemoTrack(id: "demo-wirecutter", title: "Wirecutter", artist: "The Hollow Kites", album: "Static Bloom",
                  duration: 76, bpm: 152, lyricsResource: ("wirecutter", "lrc"), isInstrumental: false,
                  hues: [0.02, 0.09, 0.58], artworkSeed: 61, genre: "Alternative Rock", fixtureProfile: .rockMetal),
        DemoTrack(id: "demo-signal-bloom", title: "Signal Bloom", artist: "Kessler Fields", album: "Nightgrid",
                  duration: 92, bpm: 128, lyricsResource: ("signal-bloom", "lrc"), isInstrumental: false,
                  hues: [0.52, 0.85, 0.47], artworkSeed: 67, genre: "Electronic", fixtureProfile: .electronicDance),
        DemoTrack(id: "demo-paper-lanterns", title: "Paper Lanterns", artist: "Ilse Norrland", album: "Small Hours",
                  duration: 156, bpm: 112, lyricsResource: ("paper-lanterns", "lrc"), isInstrumental: false,
                  hues: [0.05, 0.11, 0.93], artworkSeed: 23, genre: "Pop", fixtureProfile: .pop),
        DemoTrack(id: "demo-low-tide-signal", title: "Low Tide Signal", artist: "Marrow & Vale", album: "Harbor Lights",
                  duration: 152, bpm: 84, lyricsResource: ("low-tide-signal", "lrc"), isInstrumental: false,
                  hues: [0.58, 0.07, 0.83], artworkSeed: 11, genre: "R&B/Soul", fixtureProfile: .rnbAmbient),
        DemoTrack(id: "demo-kitchen-light", title: "Kitchen Light", artist: "Ilse Norrland", album: "Small Hours",
                  duration: 104, bpm: 72, lyricsResource: ("kitchen-light", "lrc"), isInstrumental: false,
                  hues: [0.10, 0.14, 0.08], artworkSeed: 71, genre: "Acoustic", fixtureProfile: .acousticClassical),
        DemoTrack(id: "demo-night-coast", title: "Night Coast", artist: "Marrow & Vale", album: "Harbor Lights",
                  duration: 122, bpm: 76, lyricsResource: ("night-coast", "txt"), isInstrumental: false,
                  hues: [0.48, 0.62, 0.35], artworkSeed: 37, genre: "Folk", fixtureProfile: .acousticClassical),
        DemoTrack(id: "demo-glasswater", title: "Glasswater (Interlude)", artist: "Ilse Norrland", album: "Small Hours",
                  duration: 74, bpm: 70, lyricsResource: nil, isInstrumental: true,
                  hues: [0.70, 0.78, 0.55], artworkSeed: 41, genre: "Ambient", fixtureProfile: .rnbAmbient),
    ]

    /// One representative track per profile, in profile order (used by "next fixture").
    static var profileFixtures: [DemoTrack] {
        VisualProfile.allCases.compactMap { profile in tracks.first { $0.fixtureProfile == profile } }
    }

    static func track(withID id: String) -> DemoTrack? { tracks.first { $0.id == id } }

    static func lyricsText(for track: DemoTrack) -> String? {
        guard let resource = track.lyricsResource else { return nil }
        guard let url = Bundle.main.url(forResource: resource.name, withExtension: resource.ext, subdirectory: nil)
            ?? Bundle.main.url(forResource: resource.name, withExtension: resource.ext, subdirectory: "Demo") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Serves the bundled demo lyrics for demo tracks.
struct DemoLyricsProvider: LyricsProvider {
    let name = "Demo"
    let isRemote = false

    func lyrics(for query: LyricsQuery) async throws -> LyricsLookup {
        guard query.trackIdentity.hasPrefix("demo:") else { return .notFound }
        let id = String(query.trackIdentity.dropFirst("demo:".count))
        guard let track = DemoCatalog.track(withID: id) else { return .notFound }
        if track.isInstrumental { return .instrumental }
        guard let text = DemoCatalog.lyricsText(for: track) else { return .notFound }
        if var doc = LRCParser.parse(text) {
            doc.provenance = "demo"
            return .found(doc)
        }
        return .found(LRCParser.plain(text, provenance: "demo"))
    }
}

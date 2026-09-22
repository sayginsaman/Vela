import Foundation

/// The looks Vela can render. Nine are musical personalities that Auto chooses between from the
/// genre and the audio; the rest are looks the user picks by hand. `Auto` is expressed by
/// `VisualProfileSelection`.
enum VisualProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case rapTrap
    case rockMetal
    case electronicDance
    case pop
    case rnbAmbient
    case acousticClassical
    case jazzBlues
    case latinAfrobeats
    case indieAlternative
    /// The album cover, full screen and sharp, with the lyrics over it and an LED strip around it.
    case coverArt

    /// The personalities detection chooses between. The hand-picked looks are never detected: no
    /// genre or sound implies "LED strip".
    static let genreProfiles: [VisualProfile] = [
        .rapTrap, .rockMetal, .electronicDance, .pop, .rnbAmbient, .acousticClassical, .jazzBlues,
        .latinAfrobeats, .indieAlternative,
    ]

    /// Looks chosen by hand rather than by the music.
    static let lookProfiles: [VisualProfile] = [.coverArt]

    var isGenreProfile: Bool { Self.genreProfiles.contains(self) }

    /// Cover Art shows the lyrics alone over the cover, so it never uses the split layout: the
    /// panel would put the same artwork a second time beside the words.
    var allowsSplitLayout: Bool { self != .coverArt }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rapTrap: return "Rap / Trap"
        case .rockMetal: return "Rock / Metal"
        case .electronicDance: return "Electronic / Dance"
        case .pop: return "Pop"
        case .rnbAmbient: return "R&B / Ambient"
        case .acousticClassical: return "Acoustic / Classical"
        case .jazzBlues: return "Jazz / Blues"
        case .latinAfrobeats: return "Latin / Afrobeats"
        case .indieAlternative: return "Indie / Alternative"
        case .coverArt: return "Cover Art"
        }
    }

    var summary: String {
        switch self {
        case .rapTrap: return "Bass-driven punches, tight bloom, decisive lyric hits."
        case .rockMetal: return "Turbulent flow, directional streaks, drum impacts."
        case .electronicDance: return "Beat-locked pulses, orbiting colour, travelling edge light."
        case .pop: return "Glossy blooms and balanced, upbeat motion."
        case .rnbAmbient: return "Liquid gradients, slow waves, floating lyrics."
        case .acousticClassical: return "Soft luminance, minimal light, phrase-driven motion."
        case .jazzBlues: return "Smoky amber light, serif lyrics, swing rather than pulse."
        case .latinAfrobeats: return "Tropical colour, syncopated punches, percussive sparkle."
        case .indieAlternative: return "Hazy film grain, muted colour, unhurried drift."
        case .coverArt: return "The album cover fills the screen, and the lyrics ride on top of it, centred."
        }
    }

    /// Neutral profile used when detection is not confident.
    static let fallback: VisualProfile = .pop
}

/// What the user chose in Settings: automatic detection or a locked profile.
enum VisualProfileSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case rapTrap, rockMetal, electronicDance, pop, rnbAmbient, acousticClassical, jazzBlues, latinAfrobeats, indieAlternative
    case coverArt

    var id: String { rawValue }

    /// Unknown values fall back to Auto instead of failing, so a selection that no longer exists
    /// (LED Strip was a profile in 2.3 before becoming every profile's edge) cannot take the
    /// rest of the saved settings down with it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VisualProfileSelection(rawValue: raw) ?? .auto
    }

    /// Auto followed by the nine personalities, for the first group of a picker.
    static var musicSelections: [VisualProfileSelection] {
        [.auto] + VisualProfile.genreProfiles.map(VisualProfileSelection.init(profile:))
    }

    /// The hand-picked looks, for the second group of a picker.
    static var lookSelections: [VisualProfileSelection] {
        VisualProfile.lookProfiles.map(VisualProfileSelection.init(profile:))
    }

    init(profile: VisualProfile?) {
        guard let profile, let selection = VisualProfileSelection(rawValue: profile.rawValue) else { self = .auto; return }
        self = selection
    }

    /// The locked profile, or `nil` for Auto.
    var profile: VisualProfile? { VisualProfile(rawValue: rawValue) }

    var displayName: String { profile?.displayName ?? "Auto" }
}

/// Maps loose genre strings from players onto visual profiles.
enum GenreNormalizer {
    /// Multi-word phrases are matched before single tokens so "dance pop" is pop, not electronic.
    private static let phrases: [(String, VisualProfile)] = [
        ("dance-pop", .pop), ("dance pop", .pop), ("indie pop", .pop), ("indie-pop", .pop), ("synth-pop", .pop),
        ("synth pop", .pop), ("synthpop", .pop), ("electropop", .pop), ("electro-pop", .pop), ("k-pop", .pop),
        ("kpop", .pop), ("j-pop", .pop), ("jpop", .pop), ("pop rock", .pop), ("pop-rock", .pop), ("art pop", .pop),
        ("hip-hop", .rapTrap), ("hip hop", .rapTrap), ("hiphop", .rapTrap), ("trap", .rapTrap), ("drill", .rapTrap),
        ("grime", .rapTrap), ("phonk", .rapTrap),
        ("neo-soul", .rnbAmbient), ("neo soul", .rnbAmbient), ("lo-fi", .rnbAmbient), ("lofi", .rnbAmbient),
        ("trip-hop", .rnbAmbient), ("trip hop", .rnbAmbient), ("chillout", .rnbAmbient), ("chill-out", .rnbAmbient),
        ("downtempo", .rnbAmbient), ("r&b", .rnbAmbient), ("rnb", .rnbAmbient), ("r'n'b", .rnbAmbient),
        ("drum and bass", .electronicDance), ("drum & bass", .electronicDance), ("dnb", .electronicDance),
        ("synthwave", .electronicDance), ("future bass", .electronicDance), ("big room", .electronicDance),
        ("singer/songwriter", .acousticClassical), ("singer-songwriter", .acousticClassical),
        ("singer songwriter", .acousticClassical), ("post-rock", .rockMetal), ("post rock", .rockMetal),
        ("nu metal", .rockMetal), ("nu-metal", .rockMetal), ("alternative rock", .rockMetal), ("alt-rock", .rockMetal),
        ("alt rock", .rockMetal), ("indie folk", .acousticClassical), ("indie-folk", .acousticClassical),
        ("indie rock", .indieAlternative), ("indie-rock", .indieAlternative), ("dream pop", .indieAlternative),
        ("dream-pop", .indieAlternative), ("art rock", .indieAlternative),
        ("big band", .jazzBlues), ("bossa nova", .jazzBlues), ("smooth jazz", .jazzBlues), ("acid jazz", .jazzBlues),
        ("latin pop", .latinAfrobeats), ("latin-pop", .latinAfrobeats), ("latin urban", .latinAfrobeats),
        ("afro beats", .latinAfrobeats), ("afro-beats", .latinAfrobeats), ("afro house", .latinAfrobeats),
    ]

    private static let tokens: [String: VisualProfile] = [
        "rap": .rapTrap,
        "rock": .rockMetal, "metal": .rockMetal, "punk": .rockMetal, "grunge": .rockMetal,
        "hardcore": .rockMetal, "emo": .rockMetal, "metalcore": .rockMetal,
        "jazz": .jazzBlues, "blues": .jazzBlues, "swing": .jazzBlues, "bebop": .jazzBlues, "bossa": .jazzBlues,
        "latin": .latinAfrobeats, "reggaeton": .latinAfrobeats, "afrobeats": .latinAfrobeats, "afrobeat": .latinAfrobeats,
        "salsa": .latinAfrobeats, "bachata": .latinAfrobeats, "cumbia": .latinAfrobeats, "dancehall": .latinAfrobeats,
        "amapiano": .latinAfrobeats, "dembow": .latinAfrobeats, "samba": .latinAfrobeats, "merengue": .latinAfrobeats,
        "tropical": .latinAfrobeats, "urbano": .latinAfrobeats,
        "indie": .indieAlternative, "alternative": .indieAlternative, "alt": .indieAlternative, "shoegaze": .indieAlternative,
        "lo-fi rock": .indieAlternative,
        "electronic": .electronicDance, "electronica": .electronicDance, "edm": .electronicDance, "house": .electronicDance,
        "techno": .electronicDance, "trance": .electronicDance, "dubstep": .electronicDance, "dance": .electronicDance,
        "garage": .electronicDance, "breakbeat": .electronicDance, "idm": .electronicDance, "electro": .electronicDance,
        "hardstyle": .electronicDance,
        "pop": .pop, "disco": .pop,
        "soul": .rnbAmbient, "ambient": .rnbAmbient, "chill": .rnbAmbient, "reggae": .rnbAmbient, "funk": .rnbAmbient,
        "acoustic": .acousticClassical, "classical": .acousticClassical, "piano": .acousticClassical, "folk": .acousticClassical,
        "orchestral": .acousticClassical, "orchestra": .acousticClassical, "instrumental": .acousticClassical,
        "baroque": .acousticClassical, "opera": .acousticClassical, "bluegrass": .acousticClassical,
        "country": .acousticClassical, "soundtrack": .acousticClassical, "score": .acousticClassical, "chamber": .acousticClassical,
        "symphony": .acousticClassical,
    ]

    static func profile(for genre: String?) -> VisualProfile? {
        guard let genre else { return nil }
        let lowered = genre.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return nil }
        for (phrase, profile) in phrases where lowered.contains(phrase) {
            return profile
        }
        let separators = CharacterSet(charactersIn: " /,;&|-_()")
        let parts = lowered.components(separatedBy: separators).filter { !$0.isEmpty }
        for part in parts {
            if let profile = tokens[part] { return profile }
        }
        // Compound words such as "poprock" or "altrock".
        for part in parts {
            for (token, profile) in tokens where part.hasSuffix(token) || part.hasPrefix(token) {
                if token.count >= 3 { return profile }
            }
        }
        return nil
    }
}

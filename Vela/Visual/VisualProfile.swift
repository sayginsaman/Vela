import Foundation

/// The musical personalities Vela can render. `Auto` is expressed by `VisualProfileSelection`.
enum VisualProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case rapTrap
    case rockMetal
    case electronicDance
    case pop
    case rnbAmbient
    case acousticClassical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rapTrap: return "Rap / Trap"
        case .rockMetal: return "Rock / Metal"
        case .electronicDance: return "Electronic / Dance"
        case .pop: return "Pop"
        case .rnbAmbient: return "R&B / Ambient"
        case .acousticClassical: return "Acoustic / Classical"
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
        }
    }

    /// Neutral profile used when detection is not confident.
    static let fallback: VisualProfile = .pop
}

/// What the user chose in Settings: automatic detection or a locked profile.
enum VisualProfileSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case rapTrap, rockMetal, electronicDance, pop, rnbAmbient, acousticClassical

    var id: String { rawValue }

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
        ("indie rock", .rockMetal), ("indie-rock", .rockMetal), ("nu metal", .rockMetal), ("nu-metal", .rockMetal),
    ]

    private static let tokens: [String: VisualProfile] = [
        "rap": .rapTrap,
        "rock": .rockMetal, "metal": .rockMetal, "punk": .rockMetal, "alternative": .rockMetal, "grunge": .rockMetal,
        "hardcore": .rockMetal, "emo": .rockMetal, "shoegaze": .rockMetal, "metalcore": .rockMetal,
        "electronic": .electronicDance, "electronica": .electronicDance, "edm": .electronicDance, "house": .electronicDance,
        "techno": .electronicDance, "trance": .electronicDance, "dubstep": .electronicDance, "dance": .electronicDance,
        "garage": .electronicDance, "breakbeat": .electronicDance, "idm": .electronicDance, "electro": .electronicDance,
        "hardstyle": .electronicDance,
        "pop": .pop, "disco": .pop,
        "soul": .rnbAmbient, "ambient": .rnbAmbient, "chill": .rnbAmbient, "reggae": .rnbAmbient, "funk": .rnbAmbient,
        "acoustic": .acousticClassical, "classical": .acousticClassical, "piano": .acousticClassical, "folk": .acousticClassical,
        "orchestral": .acousticClassical, "orchestra": .acousticClassical, "instrumental": .acousticClassical,
        "baroque": .acousticClassical, "opera": .acousticClassical, "jazz": .acousticClassical, "bluegrass": .acousticClassical,
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

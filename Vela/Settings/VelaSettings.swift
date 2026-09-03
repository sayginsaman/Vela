import Foundation

enum LyricStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case focus, drift, bloom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .focus: return "Focus"
        case .drift: return "Drift"
        case .bloom: return "Bloom"
        }
    }
    var summary: String {
        switch self {
        case .focus: return "Centered line with precise word highlighting."
        case .drift: return "Nearby lines drift through subtle depth."
        case .bloom: return "Words expand and glow as they are sung."
        }
    }
}

enum PaletteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, manual
    var id: String { rawValue }
    var displayName: String { self == .automatic ? "From artwork" : "Manual" }
}

enum PreferredSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, spotify, appleMusic, demo
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        case .demo: return "Demo"
        }
    }
    var kind: MusicSourceKind? {
        switch self {
        case .automatic: return nil
        case .spotify: return .spotify
        case .appleMusic: return .appleMusic
        case .demo: return .demo
        }
    }
}

/// Everything the user can change. Persisted as one JSON blob by `SettingsStore`.
struct VelaSettings: Codable, Equatable, Sendable {
    var paletteMode: PaletteMode = .automatic
    var manualHighlight: RGBColor = Palette.fallback.highlight
    var manualGlow: RGBColor = Palette.fallback.glow
    var manualBackground: RGBColor = Palette.fallback.background

    /// Multiplier on the base lyric size (0.7...1.6).
    var lyricSize: Double = 1.0
    var lyricStyle: LyricStyle = .focus

    var glowThickness: Double = 1.0     // 0.3...2.0
    var glowIntensity: Double = 0.9     // 0...1.5
    var glowSpread: Double = 1.0        // 0.5...2.5
    var reactiveMotion: Bool = true
    var reduceEffects: Bool = false

    /// Seconds added to the playback position when looking up lyrics (-5...5).
    var lyricsOffset: Double = 0

    var preferredSource: PreferredSource = .automatic
    /// `NSScreen` device description "NSScreenNumber" as a string; `nil` = the window's screen.
    var selectedDisplayID: String?
    var launchAtLogin: Bool = false
    var onboardingComplete: Bool = false

    // Visual profile
    var visualProfile: VisualProfileSelection = .auto
    var reactiveIntensity: Double = 1.0      // 0...1.5
    var backgroundReaction: Double = 1.0     // 0...1.5
    var edgeReaction: Double = 1.0           // 0...1.5
    var lyricMotionIntensity: Double = 1.0   // 0...1.5
    var particlesEnabled: Bool = true
    var reduceIntenseMotion: Bool = false

    static let reactionRange: ClosedRange<Double> = 0...1.5

    init() {}

    /// Missing keys fall back to defaults so settings written by older versions keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = VelaSettings()
        paletteMode = try c.decodeIfPresent(PaletteMode.self, forKey: .paletteMode) ?? base.paletteMode
        manualHighlight = try c.decodeIfPresent(RGBColor.self, forKey: .manualHighlight) ?? base.manualHighlight
        manualGlow = try c.decodeIfPresent(RGBColor.self, forKey: .manualGlow) ?? base.manualGlow
        manualBackground = try c.decodeIfPresent(RGBColor.self, forKey: .manualBackground) ?? base.manualBackground
        lyricSize = try c.decodeIfPresent(Double.self, forKey: .lyricSize) ?? base.lyricSize
        lyricStyle = try c.decodeIfPresent(LyricStyle.self, forKey: .lyricStyle) ?? base.lyricStyle
        glowThickness = try c.decodeIfPresent(Double.self, forKey: .glowThickness) ?? base.glowThickness
        glowIntensity = try c.decodeIfPresent(Double.self, forKey: .glowIntensity) ?? base.glowIntensity
        glowSpread = try c.decodeIfPresent(Double.self, forKey: .glowSpread) ?? base.glowSpread
        reactiveMotion = try c.decodeIfPresent(Bool.self, forKey: .reactiveMotion) ?? base.reactiveMotion
        reduceEffects = try c.decodeIfPresent(Bool.self, forKey: .reduceEffects) ?? base.reduceEffects
        lyricsOffset = try c.decodeIfPresent(Double.self, forKey: .lyricsOffset) ?? base.lyricsOffset
        preferredSource = try c.decodeIfPresent(PreferredSource.self, forKey: .preferredSource) ?? base.preferredSource
        selectedDisplayID = try c.decodeIfPresent(String.self, forKey: .selectedDisplayID)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? base.launchAtLogin
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? base.onboardingComplete
        visualProfile = try c.decodeIfPresent(VisualProfileSelection.self, forKey: .visualProfile) ?? base.visualProfile
        reactiveIntensity = try c.decodeIfPresent(Double.self, forKey: .reactiveIntensity) ?? base.reactiveIntensity
        backgroundReaction = try c.decodeIfPresent(Double.self, forKey: .backgroundReaction) ?? base.backgroundReaction
        edgeReaction = try c.decodeIfPresent(Double.self, forKey: .edgeReaction) ?? base.edgeReaction
        lyricMotionIntensity = try c.decodeIfPresent(Double.self, forKey: .lyricMotionIntensity) ?? base.lyricMotionIntensity
        particlesEnabled = try c.decodeIfPresent(Bool.self, forKey: .particlesEnabled) ?? base.particlesEnabled
        reduceIntenseMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceIntenseMotion) ?? base.reduceIntenseMotion
    }

    static let lyricSizeRange: ClosedRange<Double> = 0.7...1.6
    static let glowThicknessRange: ClosedRange<Double> = 0.3...2.0
    static let glowIntensityRange: ClosedRange<Double> = 0...1.5
    static let glowSpreadRange: ClosedRange<Double> = 0.5...2.5
    static let offsetRange: ClosedRange<Double> = -5...5

    /// Clamps every numeric field into its valid range.
    func normalized() -> VelaSettings {
        var copy = self
        copy.lyricSize = min(max(lyricSize, Self.lyricSizeRange.lowerBound), Self.lyricSizeRange.upperBound)
        copy.glowThickness = min(max(glowThickness, Self.glowThicknessRange.lowerBound), Self.glowThicknessRange.upperBound)
        copy.glowIntensity = min(max(glowIntensity, Self.glowIntensityRange.lowerBound), Self.glowIntensityRange.upperBound)
        copy.glowSpread = min(max(glowSpread, Self.glowSpreadRange.lowerBound), Self.glowSpreadRange.upperBound)
        copy.lyricsOffset = min(max(lyricsOffset, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        copy.reactiveIntensity = min(max(reactiveIntensity, Self.reactionRange.lowerBound), Self.reactionRange.upperBound)
        copy.backgroundReaction = min(max(backgroundReaction, Self.reactionRange.lowerBound), Self.reactionRange.upperBound)
        copy.edgeReaction = min(max(edgeReaction, Self.reactionRange.lowerBound), Self.reactionRange.upperBound)
        copy.lyricMotionIntensity = min(max(lyricMotionIntensity, Self.reactionRange.lowerBound), Self.reactionRange.upperBound)
        return copy
    }
}

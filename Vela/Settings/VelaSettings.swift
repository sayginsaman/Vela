import CoreGraphics
import Foundation

enum LyricStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case stack, focus, drift, bloom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .stack: return "Stack"
        case .focus: return "Focus"
        case .drift: return "Drift"
        case .bloom: return "Bloom"
        }
    }
    var summary: String {
        switch self {
        case .stack: return "One word at a time, flowing down the screen at the pace of the song."
        case .focus: return "Centered line with precise word highlighting."
        case .drift: return "Nearby lines drift through subtle depth."
        case .bloom: return "Words expand and glow as they are sung."
        }
    }
}

/// How the fullscreen scene is composed. Independent of the lyric style, so any style can run
/// in either layout.
enum SceneLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Lyrics alone in the middle of the screen.
    case centered
    /// Now-playing panel on the left, lyrics on the right.
    case split

    var id: String { rawValue }
    var displayName: String { self == .centered ? "Centered" : "Split" }
    var summary: String {
        switch self {
        case .centered: return "Lyrics alone, centred on the screen."
        case .split: return "Artwork and track details on the left, lyrics on the right."
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
/// How far an element has been nudged from its natural place, and how much it has been resized.
/// Offsets are fractions of the stage so a window resize keeps the composition proportional.
struct SceneArrangement: Codable, Equatable, Sendable {
    var scale: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0

    static let scaleRange: ClosedRange<Double> = 0.6...1.5
    static let offsetRange: ClosedRange<Double> = -0.4...0.4

    static let identity = SceneArrangement()
    var isIdentity: Bool { self == .identity }

    func clamped() -> SceneArrangement {
        SceneArrangement(scale: min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound),
                         offsetX: min(max(offsetX, Self.offsetRange.lowerBound), Self.offsetRange.upperBound),
                         offsetY: min(max(offsetY, Self.offsetRange.lowerBound), Self.offsetRange.upperBound))
    }

    /// The point offset for a stage of this size.
    func translation(in size: CGSize) -> CGSize {
        CGSize(width: offsetX * size.width, height: offsetY * size.height)
    }
}

/// How the screen edge is lit. The LED strip is the default for every profile; the diffuse glow
/// from earlier versions stays available.
enum EdgeLightStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case ledStrip, glow
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ledStrip: return "LED strip"
        case .glow: return "Glow"
        }
    }

    var summary: String {
        switch self {
        case .ledStrip: return "A crisp strip along every edge that swells with the bass, flashes on the kick and runs with the music."
        case .glow: return "A soft, wide glow that drifts around the edge."
        }
    }
}

struct VelaSettings: Codable, Equatable, Sendable {
    var paletteMode: PaletteMode = .automatic
    var manualHighlight: RGBColor = Palette.fallback.highlight
    var manualGlow: RGBColor = Palette.fallback.glow
    var manualBackground: RGBColor = Palette.fallback.background

    /// Multiplier on the base lyric size (0.7...1.6).
    var lyricSize: Double = 1.0
    var lyricStyle: LyricStyle = .stack
    var sceneLayout: SceneLayout = .centered
    /// Matched symbols beside words in the Stack style.
    var wordIcons: Bool = true
    /// Set once the Stack style has been offered as the default (older settings pre-date it).
    var stackStyleIntroduced: Bool = true

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
    /// Shift lyrics earlier by the output device's reported latency (Bluetooth adds a lot).
    var compensateOutputLatency: Bool = true
    /// Listen to the song and pin lyric words to what is actually sung.
    var localAlignment: Bool = false
    /// Where the lyric column sits and how big it is.
    var lyricArrangement = SceneArrangement()
    /// Where the now-playing panel sits and how big it is, in the split layout.
    var panelArrangement = SceneArrangement()
    /// How the screen edge is lit.
    var edgeLightStyle: EdgeLightStyle = .ledStrip

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
        sceneLayout = try c.decodeIfPresent(SceneLayout.self, forKey: .sceneLayout) ?? base.sceneLayout
        wordIcons = try c.decodeIfPresent(Bool.self, forKey: .wordIcons) ?? base.wordIcons
        stackStyleIntroduced = try c.decodeIfPresent(Bool.self, forKey: .stackStyleIntroduced) ?? false
        if !stackStyleIntroduced {
            // Settings saved before the Stack style existed: adopt it once, as new installs do.
            lyricStyle = .stack
            stackStyleIntroduced = true
        }
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
        compensateOutputLatency = try c.decodeIfPresent(Bool.self, forKey: .compensateOutputLatency) ?? base.compensateOutputLatency
        localAlignment = try c.decodeIfPresent(Bool.self, forKey: .localAlignment) ?? base.localAlignment
        lyricArrangement = try c.decodeIfPresent(SceneArrangement.self, forKey: .lyricArrangement) ?? base.lyricArrangement
        panelArrangement = try c.decodeIfPresent(SceneArrangement.self, forKey: .panelArrangement) ?? base.panelArrangement
        edgeLightStyle = (try? c.decodeIfPresent(EdgeLightStyle.self, forKey: .edgeLightStyle)) ?? base.edgeLightStyle
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
        copy.lyricArrangement = lyricArrangement.clamped()
        copy.panelArrangement = panelArrangement.clamped()
        copy.reactiveIntensity = min(max(reactiveIntensity, Self.reactionRange.lowerBound), Self.reactionRange.upperBound)
        copy.backgroundReaction = min(max(backgroundReaction, Self.reactionRange.lowerBound), Self.reactionRange.upperBound)
        copy.edgeReaction = min(max(edgeReaction, Self.reactionRange.lowerBound), Self.reactionRange.upperBound)
        copy.lyricMotionIntensity = min(max(lyricMotionIntensity, Self.reactionRange.lowerBound), Self.reactionRange.upperBound)
        return copy
    }
}

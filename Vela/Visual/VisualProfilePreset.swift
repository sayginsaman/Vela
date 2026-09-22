import Foundation

/// Typeface family used for lyrics; categorical, so it switches at the end of a crossfade.
enum LyricTypeface: String, Sendable, Equatable {
    case sans, serif, rounded
}

/// Declarative description of how a profile moves and glows. Every numeric field can be
/// interpolated for crossfades and transformed for accessibility.
struct VisualProfilePreset: Equatable, Sendable {
    var typeface: LyricTypeface = .sans

    // Lyric motion
    var tempo: Double
    var springResponse: Double
    var springDamping: Double
    var transitionDuration: Double
    var activeWordScale: Double
    var activeWordBloom: Double
    var wordPunch: Double          // points of directional movement on beats
    var trackingShift: Double      // kerning change on the active word (points)
    var lineDepth: Double          // 0…1 depth treatment of neighbouring lines

    // Background
    var gradientSpeed: Double
    var gradientDistortion: Double
    var orbit: Double
    var liquid: Double
    var compress: Double
    var bloom: Double
    var vignette: Double
    var grain: Double
    var blurReaction: Double
    var cameraMotion: Double
    var slices: Double
    var streaks: Double
    var ring: Double

    // Edge light
    var edgeThickness: Double
    var glowSpread: Double
    var edgeTravel: Double

    // Audio response
    var beatImpulse: Double
    var bassResponse: Double
    var midResponse: Double
    var highResponse: Double
    var onsetResponse: Double
    var idleBreathing: Double

    // Particles
    var particleDensity: Double
    var particleLifetime: Double
    var particleSpeed: Double
    var particleStreak: Double
    var particleMirror: Double

    // Palette treatment
    var paletteSaturation: Double
    var paletteContrast: Double
    var paletteWarmth: Double
    var paletteBrightness: Double
    var highlightEmphasis: Double

    /// Seconds a crossfade *into* this profile takes.
    var crossfadeDuration: Double

    // Looks. Weights rather than switches, so a crossfade blends one look into the other.
    /// 0 = the diffuse travelling glow, 1 = a crisp LED strip hugging the edge.
    var ledStrip: Double = 0
    /// 0 = the darkened, blurred ambient backdrop, 1 = the album cover full screen and sharp.
    var coverArt: Double = 0

    // MARK: Presets

    static func preset(for profile: VisualProfile) -> VisualProfilePreset {
        switch profile {
        case .rapTrap: return .rapTrap
        case .rockMetal: return .rockMetal
        case .electronicDance: return .electronicDance
        case .pop: return .pop
        case .rnbAmbient: return .rnbAmbient
        case .acousticClassical: return .acousticClassical
        case .jazzBlues: return .jazzBlues
        case .latinAfrobeats: return .latinAfrobeats
        case .indieAlternative: return .indieAlternative
        case .ledStrip: return .ledStrip
        case .coverArt: return .coverArt
        }
    }

    /// The ambient backdrop with the edge drawn as an LED strip: one steady, saturated line in the
    /// album's accent colour, a tight bloom, and a faint wash of the same colour spilling inward.
    /// The strip never travels or widens; the music only moves its brightness.
    static let ledStrip: VisualProfilePreset = {
        var p = VisualProfilePreset(
            tempo: 1.0, springResponse: 0.45, springDamping: 0.82, transitionDuration: 0.4,
            activeWordScale: 1.05, activeWordBloom: 0.7, wordPunch: 2, trackingShift: 0, lineDepth: 0.3,
            gradientSpeed: 0.7, gradientDistortion: 0.2, orbit: 0.3, liquid: 0.4, compress: 0.3, bloom: 0.6,
            vignette: 0.55, grain: 0.03, blurReaction: 0.35, cameraMotion: 0, slices: 0, streaks: 0, ring: 0,
            edgeThickness: 1.0, glowSpread: 1.0, edgeTravel: 0,
            beatImpulse: 0.7, bassResponse: 0.7, midResponse: 0.6, highResponse: 0.5, onsetResponse: 0.6, idleBreathing: 0.8,
            particleDensity: 0.2, particleLifetime: 4.0, particleSpeed: 0.5, particleStreak: 0, particleMirror: 0,
            paletteSaturation: 1.3, paletteContrast: 1.1, paletteWarmth: 0, paletteBrightness: 1.05, highlightEmphasis: 1.25,
            crossfadeDuration: 1.5)
        p.ledStrip = 1
        return p
    }()

    /// The album cover as the whole background, sharp and bright, framed by the same LED strip.
    /// Everything that would muddy the artwork (gradient light, rings, particles, distortion) is off.
    static let coverArt: VisualProfilePreset = {
        var p = VisualProfilePreset(
            tempo: 1.0, springResponse: 0.45, springDamping: 0.82, transitionDuration: 0.4,
            activeWordScale: 1.05, activeWordBloom: 0.5, wordPunch: 2, trackingShift: 0, lineDepth: 0.2,
            gradientSpeed: 0.3, gradientDistortion: 0, orbit: 0, liquid: 0, compress: 0.2, bloom: 0.3,
            vignette: 0.3, grain: 0.02, blurReaction: 0, cameraMotion: 0, slices: 0, streaks: 0, ring: 0,
            edgeThickness: 1.0, glowSpread: 1.0, edgeTravel: 0,
            beatImpulse: 0.6, bassResponse: 0.6, midResponse: 0.5, highResponse: 0.4, onsetResponse: 0.5, idleBreathing: 0.8,
            particleDensity: 0, particleLifetime: 4.0, particleSpeed: 0.5, particleStreak: 0, particleMirror: 0,
            paletteSaturation: 1.3, paletteContrast: 1.1, paletteWarmth: 0, paletteBrightness: 1.05, highlightEmphasis: 1.25,
            crossfadeDuration: 1.5)
        p.ledStrip = 1
        p.coverArt = 1
        return p
    }()

    static let jazzBlues: VisualProfilePreset = {
        var p = VisualProfilePreset(
            tempo: 0.8, springResponse: 0.7, springDamping: 0.9, transitionDuration: 0.7,
            activeWordScale: 1.03, activeWordBloom: 0.4, wordPunch: 0, trackingShift: 0.4, lineDepth: 0.4,
            gradientSpeed: 0.4, gradientDistortion: 0.2, orbit: 0.15, liquid: 0.8, compress: 0.25, bloom: 0.4,
            vignette: 0.55, grain: 0.09, blurReaction: 0.3, cameraMotion: 0, slices: 0, streaks: 0, ring: 0,
            edgeThickness: 0.8, glowSpread: 1.3, edgeTravel: 0.05,
            beatImpulse: 0.3, bassResponse: 0.4, midResponse: 0.6, highResponse: 0.4, onsetResponse: 0.5, idleBreathing: 0.7,
            particleDensity: 0.2, particleLifetime: 6.0, particleSpeed: 0.3, particleStreak: 0, particleMirror: 0,
            paletteSaturation: 0.85, paletteContrast: 0.95, paletteWarmth: 0.1, paletteBrightness: 0.98, highlightEmphasis: 0.95,
            crossfadeDuration: 2.5)
        p.typeface = .serif
        return p
    }()

    static let latinAfrobeats = VisualProfilePreset(
        tempo: 1.1, springResponse: 0.4, springDamping: 0.75, transitionDuration: 0.4,
        activeWordScale: 1.06, activeWordBloom: 0.7, wordPunch: 4, trackingShift: 0, lineDepth: 0.3,
        gradientSpeed: 1.0, gradientDistortion: 0.3, orbit: 0.5, liquid: 0.5, compress: 0.6, bloom: 0.75,
        vignette: 0.4, grain: 0.05, blurReaction: 0.5, cameraMotion: 0.15, slices: 0.4, streaks: 0, ring: 0.4,
        edgeThickness: 1.05, glowSpread: 1.0, edgeTravel: 0.5,
        beatImpulse: 0.85, bassResponse: 0.8, midResponse: 0.7, highResponse: 0.7, onsetResponse: 0.8, idleBreathing: 1.0,
        particleDensity: 0.5, particleLifetime: 2.5, particleSpeed: 1.0, particleStreak: 0, particleMirror: 0.3,
        paletteSaturation: 1.3, paletteContrast: 1.05, paletteWarmth: 0.08, paletteBrightness: 1.05, highlightEmphasis: 1.15,
        crossfadeDuration: 1.8)

    static let indieAlternative = VisualProfilePreset(
        tempo: 0.9, springResponse: 0.6, springDamping: 0.85, transitionDuration: 0.6,
        activeWordScale: 1.04, activeWordBloom: 0.4, wordPunch: 0, trackingShift: 0, lineDepth: 0.45,
        gradientSpeed: 0.6, gradientDistortion: 0.3, orbit: 0.2, liquid: 0.7, compress: 0.3, bloom: 0.45,
        vignette: 0.55, grain: 0.12, blurReaction: 0.35, cameraMotion: 0.05, slices: 0, streaks: 0.2, ring: 0,
        edgeThickness: 0.9, glowSpread: 1.2, edgeTravel: 0.1,
        beatImpulse: 0.45, bassResponse: 0.5, midResponse: 0.7, highResponse: 0.45, onsetResponse: 0.6, idleBreathing: 0.8,
        particleDensity: 0.3, particleLifetime: 5.0, particleSpeed: 0.4, particleStreak: 0, particleMirror: 0,
        paletteSaturation: 0.8, paletteContrast: 0.9, paletteWarmth: 0.04, paletteBrightness: 1.0, highlightEmphasis: 0.95,
        crossfadeDuration: 2.2)

    static let rapTrap = VisualProfilePreset(
        tempo: 1.25, springResponse: 0.42, springDamping: 0.78, transitionDuration: 0.35,
        activeWordScale: 1.07, activeWordBloom: 0.55, wordPunch: 6, trackingShift: 0, lineDepth: 0.35,
        gradientSpeed: 0.9, gradientDistortion: 0.35, orbit: 0.2, liquid: 0.3, compress: 1.0, bloom: 0.5,
        vignette: 0.6, grain: 0.06, blurReaction: 0.4, cameraMotion: 0.3, slices: 1.0, streaks: 0, ring: 0.1,
        edgeThickness: 1.15, glowSpread: 1.0, edgeTravel: 0.15,
        beatImpulse: 1.0, bassResponse: 1.0, midResponse: 0.4, highResponse: 0.7, onsetResponse: 0.9, idleBreathing: 1.0,
        particleDensity: 0.25, particleLifetime: 2.5, particleSpeed: 0.8, particleStreak: 0.1, particleMirror: 0,
        paletteSaturation: 1.05, paletteContrast: 1.2, paletteWarmth: 0, paletteBrightness: 0.9, highlightEmphasis: 1.2,
        crossfadeDuration: 1.5)

    static let rockMetal = VisualProfilePreset(
        tempo: 1.2, springResponse: 0.5, springDamping: 0.7, transitionDuration: 0.45,
        activeWordScale: 1.05, activeWordBloom: 0.6, wordPunch: 3, trackingShift: 1.2, lineDepth: 0.5,
        gradientSpeed: 1.2, gradientDistortion: 0.6, orbit: 0.3, liquid: 0.7, compress: 0.4, bloom: 0.55,
        vignette: 0.45, grain: 0.1, blurReaction: 0.5, cameraMotion: 1.0, slices: 0, streaks: 1.0, ring: 0,
        edgeThickness: 1.1, glowSpread: 1.15, edgeTravel: 0.1,
        beatImpulse: 0.8, bassResponse: 0.7, midResponse: 0.9, highResponse: 0.6, onsetResponse: 1.0, idleBreathing: 1.1,
        particleDensity: 0.35, particleLifetime: 1.6, particleSpeed: 1.6, particleStreak: 1.0, particleMirror: 0,
        paletteSaturation: 1.1, paletteContrast: 1.25, paletteWarmth: 0.12, paletteBrightness: 1.0, highlightEmphasis: 1.1,
        crossfadeDuration: 1.5)

    static let electronicDance = VisualProfilePreset(
        tempo: 1.15, springResponse: 0.36, springDamping: 0.9, transitionDuration: 0.3,
        activeWordScale: 1.04, activeWordBloom: 0.9, wordPunch: 0, trackingShift: 0, lineDepth: 0.25,
        gradientSpeed: 1.0, gradientDistortion: 0.3, orbit: 1.0, liquid: 0.2, compress: 0.5, bloom: 1.0,
        vignette: 0.4, grain: 0.04, blurReaction: 0.6, cameraMotion: 0.2, slices: 0.2, streaks: 0.1, ring: 1.0,
        edgeThickness: 1.0, glowSpread: 0.9, edgeTravel: 1.0,
        beatImpulse: 0.9, bassResponse: 0.8, midResponse: 0.6, highResponse: 0.8, onsetResponse: 0.7, idleBreathing: 1.0,
        particleDensity: 0.7, particleLifetime: 3.0, particleSpeed: 1.0, particleStreak: 0.2, particleMirror: 1.0,
        paletteSaturation: 1.25, paletteContrast: 1.1, paletteWarmth: -0.05, paletteBrightness: 1.05, highlightEmphasis: 1.2,
        crossfadeDuration: 1.5)

    static let pop = VisualProfilePreset(
        tempo: 1.0, springResponse: 0.5, springDamping: 0.82, transitionDuration: 0.45,
        activeWordScale: 1.05, activeWordBloom: 0.6, wordPunch: 2, trackingShift: 0, lineDepth: 0.3,
        gradientSpeed: 0.8, gradientDistortion: 0.2, orbit: 0.4, liquid: 0.4, compress: 0.3, bloom: 0.7,
        vignette: 0.35, grain: 0.05, blurReaction: 0.4, cameraMotion: 0.1, slices: 0.1, streaks: 0, ring: 0.3,
        edgeThickness: 1.0, glowSpread: 1.0, edgeTravel: 0.3,
        beatImpulse: 0.6, bassResponse: 0.6, midResponse: 0.6, highResponse: 0.5, onsetResponse: 0.6, idleBreathing: 0.9,
        particleDensity: 0.45, particleLifetime: 3.5, particleSpeed: 0.7, particleStreak: 0, particleMirror: 0.2,
        paletteSaturation: 1.15, paletteContrast: 1.0, paletteWarmth: 0.05, paletteBrightness: 1.05, highlightEmphasis: 1.0,
        crossfadeDuration: 2.0)

    static let rnbAmbient = VisualProfilePreset(
        tempo: 0.7, springResponse: 0.8, springDamping: 0.95, transitionDuration: 0.9,
        activeWordScale: 1.03, activeWordBloom: 0.45, wordPunch: 0, trackingShift: 0, lineDepth: 0.55,
        gradientSpeed: 0.35, gradientDistortion: 0.25, orbit: 0.15, liquid: 1.0, compress: 0.6, bloom: 0.55,
        vignette: 0.5, grain: 0.05, blurReaction: 0.2, cameraMotion: 0, slices: 0, streaks: 0, ring: 0.1,
        edgeThickness: 0.85, glowSpread: 1.4, edgeTravel: 0.05,
        beatImpulse: 0.25, bassResponse: 0.55, midResponse: 0.45, highResponse: 0.25, onsetResponse: 0.3, idleBreathing: 0.6,
        particleDensity: 0.15, particleLifetime: 7.0, particleSpeed: 0.3, particleStreak: 0, particleMirror: 0,
        paletteSaturation: 0.9, paletteContrast: 0.85, paletteWarmth: 0.05, paletteBrightness: 0.95, highlightEmphasis: 0.9,
        crossfadeDuration: 3.5)

    static let acousticClassical: VisualProfilePreset = {
        var p = acousticClassicalBase
        p.typeface = .serif
        return p
    }()

    private static let acousticClassicalBase = VisualProfilePreset(
        tempo: 0.6, springResponse: 0.9, springDamping: 0.96, transitionDuration: 1.0,
        activeWordScale: 1.02, activeWordBloom: 0.25, wordPunch: 0, trackingShift: 0, lineDepth: 0.2,
        gradientSpeed: 0.25, gradientDistortion: 0.08, orbit: 0.1, liquid: 0.5, compress: 0.15, bloom: 0.3,
        vignette: 0.45, grain: 0.08, blurReaction: 0.25, cameraMotion: 0, slices: 0, streaks: 0, ring: 0,
        edgeThickness: 0.6, glowSpread: 1.2, edgeTravel: 0,
        beatImpulse: 0.15, bassResponse: 0.25, midResponse: 0.5, highResponse: 0.35, onsetResponse: 0.45, idleBreathing: 0.5,
        particleDensity: 0.2, particleLifetime: 6.0, particleSpeed: 0.25, particleStreak: 0, particleMirror: 0,
        paletteSaturation: 0.8, paletteContrast: 0.9, paletteWarmth: 0.06, paletteBrightness: 1.0, highlightEmphasis: 0.85,
        crossfadeDuration: 3.0)

    // MARK: Transformations

    /// Every numeric field, so interpolation and tests never fall out of sync with the struct.
    static let fields: [WritableKeyPath<VisualProfilePreset, Double>] = [
        \.tempo, \.springResponse, \.springDamping, \.transitionDuration, \.activeWordScale, \.activeWordBloom,
        \.wordPunch, \.trackingShift, \.lineDepth, \.gradientSpeed, \.gradientDistortion, \.orbit, \.liquid, \.compress,
        \.bloom, \.vignette, \.grain, \.blurReaction, \.cameraMotion, \.slices, \.streaks, \.ring, \.edgeThickness,
        \.glowSpread, \.edgeTravel, \.beatImpulse, \.bassResponse, \.midResponse, \.highResponse, \.onsetResponse,
        \.idleBreathing, \.particleDensity, \.particleLifetime, \.particleSpeed, \.particleStreak, \.particleMirror,
        \.paletteSaturation, \.paletteContrast, \.paletteWarmth, \.paletteBrightness, \.highlightEmphasis, \.crossfadeDuration,
        \.ledStrip, \.coverArt,
    ]

    func interpolated(to other: VisualProfilePreset, amount: Double) -> VisualProfilePreset {
        let t = min(1, max(0, amount))
        if t <= 0 { return self }
        if t >= 1 { return other }
        var result = self
        for path in Self.fields {
            result[keyPath: path] = self[keyPath: path] + (other[keyPath: path] - self[keyPath: path]) * t
        }
        result.typeface = t >= 0.5 ? other.typeface : typeface
        return result
    }

    /// `level` 1 = system Reduce Motion (or "reduce intense motion"): removes camera movement and
    /// rapid spatial impulses, slows particles, keeps colour and opacity reactions.
    func applyingReduceMotion(_ level: Double) -> VisualProfilePreset {
        let k = min(1, max(0, level))
        guard k > 0 else { return self }
        var p = self
        p.cameraMotion *= (1 - k)
        p.wordPunch *= (1 - k)
        p.trackingShift *= (1 - k)
        p.beatImpulse *= (1 - 0.85 * k)
        p.activeWordScale = 1 + (activeWordScale - 1) * (1 - 0.8 * k)
        p.lineDepth *= (1 - 0.7 * k)
        p.gradientDistortion *= (1 - 0.8 * k)
        p.gradientSpeed *= (1 - 0.6 * k)
        p.orbit *= (1 - 0.7 * k)
        p.compress *= (1 - 0.7 * k)
        p.particleSpeed *= (1 - 0.7 * k)
        p.particleStreak *= (1 - k)
        p.slices *= (1 - k)
        p.streaks *= (1 - k)
        p.ring *= (1 - 0.6 * k)
        p.springResponse += 0.35 * k
        p.springDamping = min(1, springDamping + 0.2 * k)
        p.transitionDuration = max(transitionDuration, 0.6 * k + transitionDuration * (1 - k) + transitionDuration * k)
        p.tempo *= (1 - 0.35 * k)
        return p
    }

    /// Applies the user's intensity sliders. Values around 1 are neutral.
    func applyingIntensities(reactive: Double, background: Double, edge: Double, lyric: Double, particles: Bool) -> VisualProfilePreset {
        var p = self
        let r = max(0, reactive)
        p.beatImpulse *= r
        p.bassResponse *= r
        p.midResponse *= r
        p.highResponse *= r
        p.onsetResponse *= r
        let b = max(0, background)
        p.gradientSpeed *= b
        p.gradientDistortion *= b
        p.compress *= b
        p.bloom *= b
        p.slices *= b
        p.streaks *= b
        p.ring *= b
        p.cameraMotion *= b
        let e = max(0, edge)
        p.edgeThickness *= e
        p.edgeTravel *= e
        let l = max(0, lyric)
        p.activeWordScale = 1 + (activeWordScale - 1) * l
        p.wordPunch *= l
        p.trackingShift *= l
        p.activeWordBloom *= l
        p.lineDepth *= l
        if !particles { p.particleDensity = 0 }
        return p
    }
}

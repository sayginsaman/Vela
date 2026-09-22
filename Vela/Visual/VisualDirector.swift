import Foundation
import SwiftUI
import os

/// Lyric-facing subset of the visual state: springs and impulses, never raw audio.
struct LyricMotionStyle: Equatable, Sendable {
    var springResponse: Double
    var springDamping: Double
    var transitionDuration: Double
    var activeWordScale: Double
    var activeWordBloom: Double
    var wordPunch: Double
    var trackingShift: Double
    var lineDepth: Double
    var tempo: Double
    var reduceMotion: Bool
    var typeface: LyricTypeface = .sans

    static let neutral = LyricMotionStyle(springResponse: 0.55, springDamping: 0.85, transitionDuration: 0.45,
                                          activeWordScale: 1.04, activeWordBloom: 0.55, wordPunch: 0, trackingShift: 0,
                                          lineDepth: 0.3, tempo: 1, reduceMotion: false)

    init(springResponse: Double, springDamping: Double, transitionDuration: Double, activeWordScale: Double,
         activeWordBloom: Double, wordPunch: Double, trackingShift: Double, lineDepth: Double, tempo: Double, reduceMotion: Bool,
         typeface: LyricTypeface = .sans) {
        self.springResponse = springResponse; self.springDamping = springDamping; self.transitionDuration = transitionDuration
        self.activeWordScale = activeWordScale; self.activeWordBloom = activeWordBloom; self.wordPunch = wordPunch
        self.trackingShift = trackingShift; self.lineDepth = lineDepth; self.tempo = tempo; self.reduceMotion = reduceMotion
        self.typeface = typeface
    }

    init(preset: VisualProfilePreset, reduceMotion: Bool) {
        self.init(springResponse: preset.springResponse, springDamping: preset.springDamping,
                  transitionDuration: preset.transitionDuration, activeWordScale: preset.activeWordScale,
                  activeWordBloom: preset.activeWordBloom, wordPunch: preset.wordPunch, trackingShift: preset.trackingShift,
                  lineDepth: preset.lineDepth, tempo: preset.tempo, reduceMotion: reduceMotion, typeface: preset.typeface)
    }

    var lineAnimation: Animation {
        reduceMotion ? .easeInOut(duration: max(0.3, transitionDuration)) : .spring(response: springResponse, dampingFraction: springDamping)
    }

    var wordAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: max(0.22, springResponse * 0.7), dampingFraction: max(0.6, springDamping - 0.1))
    }
}

struct LyricMotionSnapshot: Equatable, Sendable {
    var style: LyricMotionStyle = .neutral
    /// 0…1 decaying beat pulse, already scaled by the profile's beat response.
    var beatImpulse: Double = 0
    /// Smoothed loudness 0…1.
    var energy: Double = 0
    /// Increments on every beat; lets views pick a deterministic punch direction.
    var beatCount: Int = 0
}

struct BlobState: Equatable, Sendable {
    var x: Double
    var y: Double
    var radius: Double
    var colorIndex: Int
    var intensity: Double
}

/// One smoothed frame of everything the renderers need. Produced by `VisualDirector.tick`.
struct ReactiveVisualState: Equatable, Sendable {
    var time: Double = 0
    var preset: VisualProfilePreset = .pop
    var palette: Palette = .fallback
    var bands: AudioBands = .silent
    var onset: Double = 0
    var beat: Double = 0
    var kick: Double = 0
    var snare: Double = 0
    var hat: Double = 0
    var beatPhase: Double = 0
    var bpm: Double = 0
    var bpmConfidence: Double = 0
    var energy: Double = 0
    var expansion: Double = 0
    var distortion: Double = 0
    var blurMix: Double = 0
    var bloom: Double = 0
    var lightIntensity: Double = 0.8
    var vignette: Double = 0.4
    var grain: Double = 0.05
    var depth: Double = 0.3
    var cameraX: Double = 0
    var cameraY: Double = 0
    var cameraZoom: Double = 1
    var edgeThickness: Double = 64
    var edgeIntensity: Double = 0.9
    var edgeSpread: Double = 1
    var edgeTravelPhase: Double = 0
    var breathing: Double = 1
    var blobs: [BlobState] = []
    var particleDensity: Double = 0
    var particleLifetime: Double = 3
    var particleSpeed: Double = 1
    var particleStreak: Double = 0
    var particleMirror: Double = 0
    /// 0 = diffuse glow, 1 = LED strip; eased when the setting changes.
    var ledStrip: Double = 1
    /// 0…1 position of the running light along the LED strip, advanced by the music.
    var ledPhase: Double = 0
    var lyric = LyricMotionSnapshot()
    var isPlaying = false
    var reduceMotion = false

    static let initial = ReactiveVisualState()
}

/// Combines the selected profile, live audio features, palette, accessibility preferences and
/// user intensity settings into one smoothed `ReactiveVisualState`.
///
/// `update(inputs:)` is called from the main actor whenever something discrete changes;
/// `tick(now:features:isLive:)` runs once per rendered frame on the render thread. Nothing here
/// allocates per frame apart from the small blob array.
final class VisualDirector: @unchecked Sendable {
    struct Inputs: Equatable, Sendable {
        var profile: VisualProfile = .pop
        var palette: Palette = .fallback
        var reactive: Double = 1
        var background: Double = 1
        var edge: Double = 1
        var lyric: Double = 1
        var particlesEnabled = true
        var reduceMotion = false
        var reduceIntenseMotion = false
        var reduceEffects = false
        var glowThickness: Double = 1
        var glowIntensity: Double = 0.9
        var glowSpread: Double = 1
        var reactiveMotion = true
        /// Draw the edge as an LED strip (the default) rather than the diffuse glow.
        var ledStrip = true
        var isPlaying = false
        var trackGeneration = 0
    }

    private struct Preview {
        var profile: VisualProfile
        var fixture: ProfileFixture
        var extractor: FeatureExtractor
        var start: Double
        var duration: Double
    }

    private let lock = OSAllocatedUnfairLock(initialState: Inputs())
    private let stateLock = OSAllocatedUnfairLock(initialState: ReactiveVisualState.initial)
    private let previewLock = OSAllocatedUnfairLock<Preview?>(initialState: nil)
    /// Called on an arbitrary thread when a preview finishes on its own.
    var onPreviewEnded: (@Sendable () -> Void)?

    // Render-thread state
    private var inputs = Inputs()
    private var appliedGeneration = -1
    private var fromPreset: VisualProfilePreset = .pop
    private var toPreset: VisualProfilePreset = .pop
    private var toProfile: VisualProfile = .pop
    private var blendStart: Double = -10
    private var currentPalette: Palette = .fallback
    private var lastTime: Double?
    private var orbitAngle = 0.0
    private var liquidPhase = 0.0
    private var travelPhase = 0.0
    private var ledPhase = 0.0
    private var ledMix = AttackReleaseSmoother(attack: 0.6, release: 0.6, initial: 1)
    private var beatCount = 0
    private var lastBeatPhase = 0.0

    private var bass = AttackReleaseSmoother(attack: 0.035, release: 0.22)
    private var mid = AttackReleaseSmoother(attack: 0.05, release: 0.25)
    private var high = AttackReleaseSmoother(attack: 0.025, release: 0.16)
    private var level = AttackReleaseSmoother(attack: 0.08, release: 0.5)
    private var energy = AttackReleaseSmoother(attack: 0.4, release: 1.2)
    private var onset = AttackReleaseSmoother(attack: 0.012, release: 0.14)
    private var beat = AttackReleaseSmoother(attack: 0.012, release: 0.18)
    private var kick = AttackReleaseSmoother(attack: 0.012, release: 0.16)
    private var snare = AttackReleaseSmoother(attack: 0.012, release: 0.14)
    private var hat = AttackReleaseSmoother(attack: 0.01, release: 0.09)
    private var expansion = AttackReleaseSmoother(attack: 0.05, release: 0.35)
    private var distortion = AttackReleaseSmoother(attack: 0.1, release: 0.4)
    private var breathing = AttackReleaseSmoother(attack: 1.5, release: 0.8, initial: 1)
    private var cameraX = AttackReleaseSmoother(attack: 0.03, release: 0.25)
    private var cameraY = AttackReleaseSmoother(attack: 0.03, release: 0.25)
    private var cameraZoom = AttackReleaseSmoother(attack: 0.03, release: 0.3, initial: 1)
    private var cameraTargetX = 0.0
    private var cameraTargetY = 0.0

    // MARK: Main-thread API

    func update(inputs newInputs: Inputs) {
        lock.withLock { $0 = newInputs }
    }

    var lastState: ReactiveVisualState { stateLock.withLock { $0 } }

    func lyricSnapshot() -> LyricMotionSnapshot { stateLock.withLock { $0.lyric } }

    var isPreviewing: Bool { previewLock.withLock { $0 != nil } }
    var previewProfile: VisualProfile? { previewLock.withLock { $0?.profile } }

    /// Runs a deterministic simulation of `profile` for `duration` seconds without touching
    /// playback. The live profile and audio resume afterwards.
    func startPreview(profile: VisualProfile, duration: Double = 10) {
        previewLock.withLock {
            $0 = Preview(profile: profile, fixture: ProfileFixture(profile: profile), extractor: FeatureExtractor(),
                         start: ProcessInfo.processInfo.systemUptime, duration: duration)
        }
    }

    func stopPreview() {
        previewLock.withLock { $0 = nil }
    }

    // MARK: Render-thread API

    /// Produces the next frame's state. `features` come from `FeatureStore`.
    @discardableResult
    func tick(now: Double, features liveFeatures: MusicFeatureSnapshot, isLive liveFlag: Bool) -> ReactiveVisualState {
        inputs = lock.withLock { $0 }
        let dt = min(0.1, max(0.0001, lastTime.map { now - $0 } ?? (1.0 / 60)))
        lastTime = now

        // Preview overrides profile and audio.
        var features = liveFeatures
        var isLive = liveFlag
        var profile = inputs.profile
        var isPlaying = inputs.isPlaying
        var previewEnded = false
        previewLock.withLock { preview in
            guard var p = preview else { return }
            let elapsed = now - p.start
            if elapsed > p.duration {
                preview = nil
                previewEnded = true
                return
            }
            features = p.extractor.ingest(p.fixture.descriptor(at: elapsed, playing: true))
            p.extractor = p.extractor
            preview = p
            isLive = true
            profile = p.profile
            isPlaying = true
        }
        if previewEnded { onPreviewEnded?() }

        // Track changes reset rhythm-derived state.
        if inputs.trackGeneration != appliedGeneration {
            appliedGeneration = inputs.trackGeneration
            beatCount = 0
            lastBeatPhase = 0
            cameraTargetX = 0; cameraTargetY = 0
        }

        // Profile crossfade.
        if profile != toProfile {
            fromPreset = currentPreset(at: now)
            toProfile = profile
            toPreset = VisualProfilePreset.preset(for: profile)
            blendStart = now
        }
        let reduceLevel: Double = inputs.reduceMotion ? 1 : (inputs.reduceIntenseMotion ? 0.65 : 0)
        let basePreset = currentPreset(at: now)
        let preset = basePreset
            .applyingIntensities(reactive: inputs.reactive * (inputs.reactiveMotion ? 1 : 0.35),
                                 background: inputs.background, edge: inputs.edge, lyric: inputs.lyric,
                                 particles: inputs.particlesEnabled && !inputs.reduceEffects)
            .applyingReduceMotion(reduceLevel)

        // Palette: profile-styled target, interpolated over time.
        let targetPalette = PaletteStyler.apply(preset, to: inputs.palette)
        currentPalette = currentPalette.mixed(with: targetPalette, amount: 1 - exp(-dt / 1.1))

        // Breathing when nothing is live or playback is paused.
        let wantsBreathing = !(isLive && isPlaying)
        breathing.update(wantsBreathing ? 1 : 0, dt: dt)
        let breathAmount = breathing.value
        let breathT = now * 0.55 * preset.idleBreathing
        let breath = 0.5 + 0.5 * sin(breathT)

        // Smoothed audio, blended toward a breathing pattern.
        let liveBands = features.bands
        let bassTarget = Double(liveBands.bass) * (1 - breathAmount) + (0.22 + 0.16 * breath) * breathAmount
        let midTarget = Double(liveBands.mid) * (1 - breathAmount) + (0.2 + 0.1 * sin(breathT * 0.7 + 1)) * breathAmount
        let highTarget = Double(liveBands.high) * (1 - breathAmount) + (0.08 + 0.05 * sin(breathT * 1.3)) * breathAmount
        let levelTarget = Double(liveBands.level) * (1 - breathAmount) + (0.3 + 0.12 * breath) * breathAmount
        bass.update(bassTarget, dt: dt); mid.update(midTarget, dt: dt); high.update(highTarget, dt: dt); level.update(levelTarget, dt: dt)
        energy.update(levelTarget * 0.7 + Double(features.averageLoudness) * 0.3 * (1 - breathAmount), dt: dt)

        let live = 1 - breathAmount
        onset.update(Double(features.onsetImpulse) * preset.onsetResponse * live, dt: dt)
        beat.update(Double(features.beatImpulse) * preset.beatImpulse * live, dt: dt)
        kick.update(Double(features.lowImpulse) * preset.bassResponse * live, dt: dt)
        snare.update(Double(features.midImpulse) * preset.midResponse * live, dt: dt)
        hat.update(Double(features.highImpulse) * preset.highResponse * live, dt: dt)

        // Beat counting for deterministic per-beat variation.
        let phase = Double(features.beatPhase)
        if phase < lastBeatPhase - 0.5, features.bpmConfidence > 0.4, live > 0.5 { beatCount &+= 1 }
        lastBeatPhase = phase

        // Derived background quantities.
        expansion.update(min(1, bass.value * preset.bassResponse * 0.9 + kick.value * 0.5), dt: dt)
        distortion.update(preset.gradientDistortion * (0.3 + 0.7 * mid.value * preset.midResponse + 0.5 * onset.value), dt: dt)
        let blurMix = min(1, preset.blurReaction * (0.4 + 0.6 * energy.value))
        let bloom = min(1.5, preset.bloom * (0.45 + 0.55 * level.value) + beat.value * 0.35 * preset.beatImpulse)
        let lightIntensity = (0.72 + 0.28 * energy.value) * (1 - 0.18 * breathAmount)

        // Camera impulses (rock): tiny, direction chosen per beat, smoothed.
        if preset.cameraMotion > 0.01, snare.value > 0.55 || kick.value > 0.7 {
            let seed = Double((beatCount &* 7919) % 360) / 360 * 2 * .pi
            cameraTargetX = cos(seed) * 0.006 * preset.cameraMotion * max(snare.value, kick.value)
            cameraTargetY = sin(seed) * 0.004 * preset.cameraMotion * max(snare.value, kick.value)
        } else {
            cameraTargetX *= 0.9; cameraTargetY *= 0.9
        }
        cameraX.update(cameraTargetX, dt: dt)
        cameraY.update(cameraTargetY, dt: dt)
        // Zoom is spatial motion: fully removed under Reduce Motion (the artwork still breathes in the shader).
        cameraZoom.update(1 + (0.02 * preset.cameraMotion * max(kick.value, snare.value) + 0.012 * expansion.value * preset.compress) * (1 - reduceLevel), dt: dt)

        // Gradient control-point motion.
        let tempo = preset.tempo
        orbitAngle += dt * preset.gradientSpeed * tempo * (0.06 + 0.5 * preset.orbit) * (0.6 + 0.4 * mid.value)
        liquidPhase += dt * preset.gradientSpeed * tempo * (0.15 + 0.6 * preset.liquid)
        let bpmRate = features.bpmConfidence > 0.4 && features.bpm > 0 && live > 0.5 ? Double(features.bpm) / 60 : 0.5
        travelPhase += dt * (0.02 + preset.edgeTravel * bpmRate * 0.25)
        // The LED strip's running light: a slow drift at rest, faster as the music gets louder,
        // and a surge on every kick, so the light visibly rides the bass. Integrated here rather
        // than derived from time in the shader, so a change in speed never makes it jump.
        let chaseRate = (0.03 + 0.12 * energy.value + 0.5 * kick.value + 0.2 * beat.value)
            * (0.7 + 0.6 * preset.edgeTravel) * (0.6 + 0.4 * tempo) * (1 - 0.85 * reduceLevel)
        ledPhase = (ledPhase + dt * chaseRate).truncatingRemainder(dividingBy: 1)
        ledMix.update(inputs.ledStrip ? 1 : 0, dt: dt)

        var blobs: [BlobState] = []
        blobs.reserveCapacity(6)
        let stopCount = max(2, currentPalette.gradient.count)
        for i in 0..<6 {
            let base = Double(i) / 6 * 2 * .pi
            let angle = base + orbitAngle * (i.isMultiple(of: 2) ? 1 : -0.7)
            let ring = 0.34 * (1 - preset.compress * expansion.value * 0.3)
            let drift = 0.09 * preset.liquid
            let x = 0.5 + cos(angle) * ring + sin(liquidPhase * (0.7 + Double(i) * 0.13) + Double(i)) * drift
            let y = 0.5 + sin(angle) * ring * 0.85 + cos(liquidPhase * (0.5 + Double(i) * 0.11) + Double(i) * 1.7) * drift
            let radius = 0.26 + 0.06 * Double(i % 3) + 0.14 * expansion.value * (0.5 + 0.5 * preset.compress)
            let intensity = (0.45 + 0.55 * energy.value) * (0.85 + 0.15 * sin(now * 0.8 + Double(i)))
            blobs.append(BlobState(x: x, y: y, radius: radius, colorIndex: 4 + (i % stopCount), intensity: intensity))
        }

        // Edge light.
        let edgeThickness = 64 * inputs.glowThickness * preset.edgeThickness
        let edgeIntensity = inputs.glowIntensity * (inputs.reduceEffects ? 0.65 : 1) * (0.9 + 0.1 * preset.bloom)
        let edgeSpread = inputs.glowSpread * preset.glowSpread

        var state = ReactiveVisualState()
        state.time = now
        state.preset = preset
        state.palette = currentPalette
        state.bands = AudioBands(bass: Float(bass.value), mid: Float(mid.value), high: Float(high.value), level: Float(level.value))
        state.onset = onset.value
        state.beat = beat.value
        state.kick = kick.value
        state.snare = snare.value
        state.hat = hat.value
        state.beatPhase = phase
        state.bpm = Double(features.bpm)
        state.bpmConfidence = Double(features.bpmConfidence) * live
        state.energy = energy.value
        state.expansion = expansion.value
        state.distortion = distortion.value
        state.blurMix = blurMix
        state.bloom = bloom
        state.lightIntensity = lightIntensity
        state.vignette = preset.vignette
        state.grain = inputs.reduceEffects ? 0 : preset.grain
        state.depth = preset.lineDepth
        state.cameraX = cameraX.value
        state.cameraY = cameraY.value
        state.cameraZoom = cameraZoom.value
        state.edgeThickness = edgeThickness
        state.edgeIntensity = edgeIntensity
        state.edgeSpread = edgeSpread
        state.edgeTravelPhase = travelPhase
        state.breathing = breathAmount
        state.blobs = blobs
        state.particleDensity = preset.particleDensity * (0.5 + 0.5 * energy.value) * (1 - 0.6 * breathAmount)
        state.particleLifetime = preset.particleLifetime
        state.particleSpeed = preset.particleSpeed * tempo
        state.particleStreak = preset.particleStreak
        state.particleMirror = preset.particleMirror
        state.ledStrip = ledMix.value
        state.ledPhase = ledPhase
        state.isPlaying = isPlaying
        state.reduceMotion = inputs.reduceMotion
        state.lyric = LyricMotionSnapshot(style: LyricMotionStyle(preset: preset, reduceMotion: inputs.reduceMotion),
                                          beatImpulse: min(1, max(beat.value, kick.value * 0.8)),
                                          energy: energy.value, beatCount: beatCount)
        stateLock.withLock { $0 = state }
        return state
    }

    private func currentPreset(at now: Double) -> VisualProfilePreset {
        let duration = max(0.05, toPreset.crossfadeDuration)
        let t = min(1, max(0, (now - blendStart) / duration))
        let eased = t * t * (3 - 2 * t)
        return fromPreset.interpolated(to: toPreset, amount: eased)
    }
}

/// Decides which profile is in force from the user's selection and the detector's result.
enum ProfileResolver {
    static func resolve(selection: VisualProfileSelection, detection: ProfileDetection) -> VisualProfile {
        if let locked = selection.profile { return locked }
        return detection.isSettled ? detection.profile : detection.profile
    }
}

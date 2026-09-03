import Foundation

/// Deterministic "music" for each profile: kick/snare/hat patterns, sustained energy, section
/// dynamics and spectral character, produced as `FrameDescriptor`s so the same
/// `FeatureExtractor` and classifier run on demo material as on captured audio.
struct ProfileFixture: Sendable, Equatable {
    var profile: VisualProfile
    var bpm: Double

    init(profile: VisualProfile, bpm: Double? = nil) {
        self.profile = profile
        self.bpm = bpm ?? ProfileFixture.defaultBPM(for: profile)
    }

    static func defaultBPM(for profile: VisualProfile) -> Double {
        switch profile {
        case .rapTrap: return 140
        case .rockMetal: return 152
        case .electronicDance: return 128
        case .pop: return 112
        case .rnbAmbient: return 84
        case .acousticClassical: return 72
        }
    }

    /// Descriptor for a playback position. `playing == false` yields near-silence.
    func descriptor(at position: TimeInterval, playing: Bool = true) -> FrameDescriptor {
        guard playing else {
            return FrameDescriptor(time: position, bass: 0.004, mid: 0.004, high: 0.002, level: 0.004, centroid: 0.4, flux: 0)
        }
        let beat = position * bpm / 60
        let bar = beat / 4
        let beatIndex = Int(floor(beat).truncatingRemainder(dividingBy: 4))
        let beatPhase = beat - floor(beat)
        let eighth = (beat * 2) - floor(beat * 2)
        let sixteenth = (beat * 4) - floor(beat * 4)
        let sixteenthIndex = Int(floor(beat * 4).truncatingRemainder(dividingBy: 16))
        let intro = min(1, position / 4)

        var bass = 0.0, mid = 0.0, high = 0.0, centroid = 0.45, transient = 0.0

        switch profile {
        case .rapTrap:
            // Half-time: long 808 on 1, snare on 3, rolling 16th hats with stutters, sparse mids.
            let phrase = 0.75 + 0.25 * (sin(bar / 8 * .pi) * 0.5 + 0.5)
            let kick = beatIndex == 0 ? exp(-beatPhase * 1.4) : (beatIndex == 2 ? exp(-beatPhase * 5) * 0.4 : 0)
            let snare = beatIndex == 2 ? exp(-beatPhase * 12) : 0
            let roll = (sixteenthIndex >= 12) ? 1.6 : 1.0
            let hat = exp(-sixteenth * 14) * 0.7 * roll
            bass = 0.1 + 0.9 * kick
            mid = 0.08 + 0.45 * snare + 0.05 * kick
            high = 0.04 + 0.6 * hat + 0.3 * snare
            centroid = 0.28 + 0.1 * snare
            transient = kick * 0.9 + snare + hat * 0.5
            bass *= phrase; mid *= phrase; high *= phrase
        case .rockMetal:
            // Driving 8th-note kicks, big snares on 2 and 4, dense distorted guitars, fills every 4 bars.
            let fill = Int(bar).isMultiple(of: 4) && beatIndex == 3 ? exp(-sixteenth * 10) : 0
            let kick = exp(-eighth * 9)
            let snare = (beatIndex == 1 || beatIndex == 3) ? exp(-beatPhase * 10) : 0
            let guitar = 0.6 + 0.2 * sin(position * 3.1) * sin(position * 0.7) + 0.1 * sin(bar * 1.3)
            let grit = 0.5 + 0.5 * sin(position * 47.0) * sin(position * 31.0)
            bass = 0.22 + 0.5 * kick + 0.1 * snare
            mid = 0.5 + 0.4 * guitar + 0.55 * snare + 0.3 * fill
            high = 0.42 + 0.35 * snare + 0.2 * kick + 0.25 * guitar + 0.3 * fill
            centroid = 0.64 + 0.08 * snare
            transient = kick * 0.9 + snare * 1.2 + fill + 0.35 * grit * guitar
        case .electronicDance:
            // Four-on-the-floor with a sub layer and sidechain pumping; 16-bar build then 16-bar drop.
            let section = Int(bar / 16).isMultiple(of: 2) ? 0.0 : 1.0
            let build = section == 0 ? min(1, (bar.truncatingRemainder(dividingBy: 16)) / 16) : 1
            let kick = exp(-beatPhase * 5)
            let pump = 1 - 0.55 * exp(-beatPhase * 4)
            let offHat = exp(-abs(eighth - 0.5) * 14) * 0.9
            let clap = (beatIndex == 1 || beatIndex == 3) ? exp(-beatPhase * 10) : 0
            let riser = section == 0 ? 0.4 * build : 0
            bass = (0.42 * pump + 0.9 * kick) * (0.6 + 0.4 * section)
            mid = (0.28 * pump + 0.25 * clap + 0.1 * kick) * (0.7 + 0.3 * section) + riser * 0.2
            high = (0.12 + 0.6 * offHat + 0.3 * clap) * (0.85 + 0.15 * section) + riser * 0.3
            centroid = 0.5 + 0.12 * riser + 0.05 * clap
            transient = kick * (0.7 + 0.3 * section) + clap * 0.9 + offHat * 0.55
        case .pop:
            // Kick 1 & 3 with a bass synth, snare 2 & 4, 8th hats, chorus every other 8 bars.
            let chorus = Int(bar / 8).isMultiple(of: 2) ? 0.0 : 1.0
            let energy = 0.7 + 0.3 * chorus
            let kick = (beatIndex == 0 || beatIndex == 2) ? exp(-beatPhase * 6) : 0
            let snare = (beatIndex == 1 || beatIndex == 3) ? exp(-beatPhase * 9) : 0
            let hat = exp(-eighth * 16) * 0.7
            let synth = 0.4 + 0.15 * sin(position * 1.7)
            let bassline = 0.25 + 0.1 * sin(beat * .pi)
            bass = (bassline + 0.6 * kick) * energy
            mid = (0.32 + 0.3 * synth + 0.4 * snare) * energy
            high = (0.1 + 0.4 * hat + 0.3 * snare) * energy
            centroid = 0.5 + 0.05 * chorus
            transient = kick * 0.75 + snare * 0.9 + hat * 0.4
        case .rnbAmbient:
            // Soft kick, brushed snare, long pads, slow bass swells, very few sharp attacks.
            let kick = beatIndex == 0 ? exp(-beatPhase * 2.5) : (beatIndex == 2 ? exp(-beatPhase * 3.5) * 0.5 : 0)
            let snare = beatIndex == 2 ? exp(-beatPhase * 4) * 0.4 : 0
            let pad = 0.4 + 0.2 * sin(position * 0.45) + 0.1 * sin(position * 0.9 + 1)
            let swell = 0.5 + 0.5 * sin(bar / 4 * .pi)
            bass = 0.45 + 0.35 * kick + 0.25 * swell
            mid = 0.25 + 0.22 * pad + 0.18 * snare
            high = 0.03 + 0.05 * pad + 0.08 * snare
            centroid = 0.24 + 0.04 * snare
            transient = kick * 0.22 + snare * 0.25
        case .acousticClassical:
            // Gentle strums with accents and rubato, phrase swells every 2 bars, wide dynamics, no sub bass.
            let phrase = 0.25 + 0.75 * pow(sin(bar / 2 * .pi) * 0.5 + 0.5, 1.6)
            let rubato = 0.06 * sin(position * 0.9)
            let e = (beat * 2 + rubato) - floor(beat * 2 + rubato)
            let accent = (beatIndex == 0 || beatIndex == 2) ? 1.0 : 0.6
            let strum = exp(-e * 6) * 0.42 * accent * (0.8 + 0.2 * sin(position * 2.3))
            let melody = 0.35 + 0.2 * sin(position * 1.3) + 0.1 * sin(position * 2.9 + 0.5)
            bass = (0.06 + 0.1 * strum) * phrase
            mid = (0.28 + 0.35 * melody + 0.25 * strum) * phrase
            high = (0.02 + 0.06 * strum + 0.03 * melody) * phrase
            centroid = 0.46 + 0.05 * melody
            transient = strum * 0.45 * phrase
        }

        bass *= intro; mid *= intro; high *= intro
        let level = min(1, bass * 0.5 + mid * 0.38 + high * 0.12)
        let flux = Float(max(0, transient) * 0.6 + 0.02)
        return FrameDescriptor(time: position, bass: Float(bass), mid: Float(mid), high: Float(high),
                               level: Float(level), centroid: Float(centroid), flux: flux)
    }
}

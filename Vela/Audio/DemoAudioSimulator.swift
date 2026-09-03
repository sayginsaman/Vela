import Foundation

/// Deterministic "music" for Demo Mode: a kick pattern, hats and a slow energy arc derived from
/// the playback position and tempo, so the glow reacts exactly like it would to real audio.
struct DemoAudioSimulator: Sendable {
    var bpm: Double

    func bands(at position: TimeInterval, playing: Bool) -> AudioBands {
        guard playing else { return AudioBands(bass: 0.05, mid: 0.04, high: 0.02, level: 0.05) }
        let beat = position * bpm / 60
        let bar = beat / 4
        // Song energy: quiet intro, verses, louder choruses on 8-bar phrases, breakdown mid-song.
        let phrase = sin(bar / 8 * .pi) * 0.5 + 0.5
        let intro = min(1, position / 10)
        let energy = Float((0.45 + 0.55 * phrase) * intro)

        // Kick on every beat with an accent on 1 and 3; exponential decay.
        let beatPhase = beat - floor(beat)
        let beatIndex = Int(floor(beat)) % 4
        let accent: Double = (beatIndex == 0 || beatIndex == 2) ? 1.0 : 0.72
        let kick = exp(-beatPhase * 7) * accent
        // Snare-ish body on 2 and 4.
        let snare = (beatIndex == 1 || beatIndex == 3) ? exp(-beatPhase * 9) * 0.6 : 0
        // Hats on eighth notes.
        let eighth = (beat * 2) - floor(beat * 2)
        let hat = exp(-eighth * 12) * 0.7
        // Sustained pad following a slow LFO.
        let pad = 0.35 + 0.15 * sin(position * 0.6) + 0.1 * sin(position * 1.9)

        let bass = Float(min(1, kick * 0.95 + pad * 0.25)) * energy
        let mid = Float(min(1, pad * 0.8 + snare * 0.5 + kick * 0.15)) * energy
        let high = Float(min(1, hat * 0.85 + snare * 0.3)) * energy
        let level = Float(min(1, Double(bass) * 0.5 + Double(mid) * 0.35 + Double(high) * 0.15 + 0.15)) * max(0.3, energy)
        return AudioBands(bass: bass, mid: mid, high: high, level: level)
    }
}

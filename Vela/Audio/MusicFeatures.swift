import Foundation
import os

/// One analysis frame straight from the FFT (or a demo fixture). Raw energies are not normalised.
struct FrameDescriptor: Sendable, Equatable {
    var time: TimeInterval
    var bass: Float
    var mid: Float
    var high: Float
    var level: Float
    /// Spectral centroid, 0…1 (log-mapped frequency position of the energy mass).
    var centroid: Float
    /// Positive spectral change since the previous frame.
    var flux: Float
}

/// Everything the visual system and the classifier know about the music right now.
/// Values are normalised (0…1 unless noted) and already smoothed for UI consumption.
struct MusicFeatureSnapshot: Sendable, Equatable {
    var time: TimeInterval = 0
    var bands: AudioBands = .silent
    var onsetImpulse: Float = 0
    var beatImpulse: Float = 0
    var lowImpulse: Float = 0
    var midImpulse: Float = 0
    var highImpulse: Float = 0
    var beatPhase: Float = 0
    var bpm: Float = 0
    var bpmConfidence: Float = 0
    /// 0 = all mids, 0.5 = balanced, 1 = all bass.
    var bassToMid: Float = 0.5
    var highEnergy: Float = 0
    var spectralCentroid: Float = 0.5
    var spectralFlux: Float = 0
    /// Onsets per second over the recent window.
    var onsetDensity: Float = 0
    var transientStrength: Float = 0
    var dynamicRange: Float = 0
    var averageLoudness: Float = 0
    var rhythmicRegularity: Float = 0

    static let silent = MusicFeatureSnapshot()
}

/// Lock-protected mailbox between the audio thread and the render thread.
final class FeatureStore: @unchecked Sendable {
    private struct State {
        var snapshot: MusicFeatureSnapshot = .silent
        var updatedAt: TimeInterval = 0
        var isLive = false
        var generation = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func publish(_ snapshot: MusicFeatureSnapshot) {
        lock.withLock { state in
            state.snapshot = snapshot
            state.updatedAt = ProcessInfo.processInfo.systemUptime
            state.isLive = true
        }
    }

    func markInactive() {
        lock.withLock { state in
            state.isLive = false
            state.snapshot = .silent
        }
    }

    /// Asks the producer to forget its rhythm history (track change).
    func requestReset() {
        lock.withLock { $0.generation &+= 1 }
    }

    var resetGeneration: Int { lock.withLock { $0.generation } }

    /// Latest snapshot; `isLive` is false when nothing has been published for half a second.
    func read() -> (snapshot: MusicFeatureSnapshot, isLive: Bool) {
        lock.withLock { state in
            let stale = ProcessInfo.processInfo.systemUptime - state.updatedAt > 0.5
            return (stale ? .silent : state.snapshot, state.isLive && !stale)
        }
    }
}

// MARK: - Smoothing primitives

/// First-order smoother with separate attack and release time constants (seconds).
struct AttackReleaseSmoother: Sendable, Equatable {
    var attack: Double
    var release: Double
    var value: Double

    init(attack: Double, release: Double, initial: Double = 0) {
        self.attack = attack
        self.release = release
        value = initial
    }

    @discardableResult
    mutating func update(_ target: Double, dt: Double) -> Double {
        guard dt > 0 else { return value }
        let tau = target > value ? attack : release
        let k = tau <= 0 ? 1 : 1 - exp(-dt / tau)
        value += (target - value) * k
        return value
    }

    mutating func reset(_ newValue: Double) { value = newValue }
}

/// Adaptive gain: tracks a slowly decaying ceiling so quiet and loud material both use 0…1.
struct RunningNormalizer: Sendable, Equatable {
    var ceiling: Float
    var floor: Float
    var rise: Float
    var decay: Float

    init(initialCeiling: Float = 0.02, floor: Float = 0.0005, rise: Float = 0.3, decay: Float = 0.995) {
        ceiling = initialCeiling
        self.floor = floor
        self.rise = rise
        self.decay = decay
    }

    mutating func normalize(_ value: Float) -> Float {
        if value > ceiling {
            ceiling += (value - ceiling) * rise
        } else {
            ceiling = max(floor, ceiling * decay)
        }
        let normalised = min(1, value / max(ceiling, floor))
        return pow(max(0, normalised), 0.8)
    }
}

/// A decaying impulse: jumps to `max(current, hit)` and decays exponentially.
struct Impulse: Sendable, Equatable {
    var value: Float = 0
    var decayRate: Float   // per second

    init(decayRate: Float) { self.decayRate = decayRate }

    mutating func hit(_ strength: Float) { value = max(value, min(1, strength)) }

    mutating func advance(dt: Float) {
        value *= exp(-decayRate * max(0, dt))
        if value < 0.001 { value = 0 }
    }
}

import Foundation

/// The profile Auto mode has settled on, and why.
struct ProfileDetection: Equatable, Sendable {
    enum Source: String, Sendable { case genre, audio, fallback, pending }

    var profile: VisualProfile
    var confidence: Double
    var source: Source
    /// `false` while the initial classification window is still being collected.
    var isSettled: Bool

    static let pending = ProfileDetection(profile: .fallback, confidence: 0, source: .pending, isSettled: false)
}

/// Stateful, hysteresis-protected wrapper around `ProfileClassifier`.
///
/// Per track: collects an initial window of feature samples, then locks a profile once the
/// smoothed scores are confident enough, otherwise falls back to Pop. Locked profiles only change
/// when the initial confidence was low and a clearly better candidate persists, or when the
/// music changes substantially (a very confident, sustained contradiction). Genre metadata, when
/// present, decides immediately and is never overridden by audio analysis.
final class ProfileDetector {
    struct Configuration: Sendable {
        var initialWindow: TimeInterval = 8
        var minimumSamples = 12
        var lockConfidence = ProfileClassifier.lockConfidence
        var highConfidence = 0.72
        var reevaluateInterval: TimeInterval = 20
        var switchMargin = 0.15
        var substantialConfidence = 0.8
        var substantialMargin = 0.3
        var substantialDuration: TimeInterval = 10
        var smoothing = 0.15
    }

    let configuration: Configuration
    private(set) var detection: ProfileDetection = .pending
    /// What the audio heuristic currently believes, for diagnostics (also while genre decides).
    private(set) var audioEstimate: ProfileScores = .neutral
    private(set) var trackID: String?

    private var smoothedScores: [VisualProfile: Double] = [:]
    private var samples = 0
    private var windowStart: TimeInterval?
    private var lockTime: TimeInterval?
    private var initialConfidence = 0.0
    private var contradictionStart: TimeInterval?
    private var genreLocked = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Starts a fresh classification for a track. Genre metadata decides immediately.
    func reset(trackID: String?, genre: String?) {
        self.trackID = trackID
        smoothedScores = [:]
        samples = 0
        windowStart = nil
        lockTime = nil
        initialConfidence = 0
        contradictionStart = nil
        audioEstimate = .neutral
        if let profile = GenreNormalizer.profile(for: genre) {
            genreLocked = true
            detection = ProfileDetection(profile: profile, confidence: 0.95, source: .genre, isSettled: true)
        } else {
            genreLocked = false
            detection = .pending
        }
    }

    /// Feeds one (downsampled) feature snapshot. Returns the new detection when it changed.
    @discardableResult
    func ingest(_ features: MusicFeatureSnapshot, at time: TimeInterval) -> ProfileDetection? {
        let instant = ProfileClassifier.classify(features)
        let alpha = smoothedScores.isEmpty ? 1 : configuration.smoothing
        for profile in VisualProfile.genreProfiles {
            let value = instant.scores[profile] ?? 0
            smoothedScores[profile] = (smoothedScores[profile] ?? 0) + (value - (smoothedScores[profile] ?? 0)) * alpha
        }
        samples += 1
        if windowStart == nil { windowStart = time }
        audioEstimate = ProfileClassifier.summarize(smoothedScores)
        guard !genreLocked else { return nil }

        let previous = detection
        let elapsed = time - (windowStart ?? time)

        if lockTime == nil {
            guard samples >= configuration.minimumSamples, elapsed >= configuration.initialWindow else { return nil }
            lockTime = time
            initialConfidence = audioEstimate.confidence
            if audioEstimate.confidence >= configuration.lockConfidence {
                detection = ProfileDetection(profile: audioEstimate.best, confidence: audioEstimate.confidence, source: .audio, isSettled: true)
            } else {
                detection = ProfileDetection(profile: .fallback, confidence: audioEstimate.confidence, source: .fallback, isSettled: true)
            }
            return detection == previous ? nil : detection
        }

        // Locked: decide whether re-evaluation is allowed.
        let candidate = audioEstimate
        let currentScore = smoothedScores[detection.profile] ?? 0
        let margin = (candidate.scores[candidate.best] ?? 0) - currentScore
        guard candidate.best != detection.profile else { contradictionStart = nil; return nil }

        let sinceLock = time - (lockTime ?? time)
        if initialConfidence < configuration.highConfidence {
            // Low initial confidence: periodic re-evaluation with a margin requirement.
            if sinceLock >= configuration.reevaluateInterval, candidate.confidence >= configuration.lockConfidence, margin >= configuration.switchMargin {
                lockTime = time
                initialConfidence = candidate.confidence
                detection = ProfileDetection(profile: candidate.best, confidence: candidate.confidence, source: .audio, isSettled: true)
                return detection
            }
            return nil
        }
        // High initial confidence: only a sustained, very confident contradiction switches.
        if candidate.confidence >= configuration.substantialConfidence, margin >= configuration.substantialMargin {
            if contradictionStart == nil { contradictionStart = time }
            if time - (contradictionStart ?? time) >= configuration.substantialDuration {
                lockTime = time
                initialConfidence = candidate.confidence
                contradictionStart = nil
                detection = ProfileDetection(profile: candidate.best, confidence: candidate.confidence, source: .audio, isSettled: true)
                return detection
            }
        } else {
            contradictionStart = nil
        }
        return nil
    }
}

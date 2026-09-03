import Foundation

/// Scores for every profile plus the winner and a confidence in it.
struct ProfileScores: Equatable, Sendable {
    var scores: [VisualProfile: Double]
    var best: VisualProfile
    var confidence: Double
    var runnerUp: VisualProfile?

    static let neutral = ProfileScores(scores: [:], best: .fallback, confidence: 0, runnerUp: nil)
}

/// Deterministic heuristic that maps musical features to a visual profile.
///
/// Each profile is described by a handful of feature ranges with weights. A feature contributes
/// 1 inside its range, falling off linearly over `soft` outside it. The profile score is the
/// weighted mean; confidence combines the best score with its margin over the runner-up.
enum ProfileClassifier {
    struct Criterion {
        var feature: KeyPath<MusicFeatureSnapshot, Float>
        var ranges: [ClosedRange<Double>]
        var soft: Double
        var weight: Double

        init(_ feature: KeyPath<MusicFeatureSnapshot, Float>, _ ranges: ClosedRange<Double>..., soft: Double, weight: Double) {
            self.feature = feature
            self.ranges = ranges
            self.soft = soft
            self.weight = weight
        }
    }

    static let lockConfidence = 0.5

    static let criteria: [VisualProfile: [Criterion]] = [
        .rapTrap: [
            Criterion(\.bpm, 64...104, 128...176, soft: 12, weight: 0.8),
            Criterion(\.bassToMid, 0.62...1, soft: 0.15, weight: 1.4),
            Criterion(\.spectralCentroid, 0.12...0.42, soft: 0.12, weight: 1.0),
            Criterion(\.highEnergy, 0.25...0.75, soft: 0.15, weight: 0.6),
            Criterion(\.transientStrength, 0.5...1, soft: 0.2, weight: 1.0),
            Criterion(\.rhythmicRegularity, 0.4...0.85, soft: 0.2, weight: 0.5),
            Criterion(\.onsetDensity, 1.5...5, soft: 1.0, weight: 0.8),
            Criterion(\.averageLoudness, 0.3...0.7, soft: 0.2, weight: 0.6),
            Criterion(\.dynamicRange, 0.3...0.9, soft: 0.2, weight: 0.6),
            Criterion(\.spectralFlux, 0.12...0.45, soft: 0.15, weight: 0.5),
        ],
        .rockMetal: [
            Criterion(\.bpm, 100...190, 50...95, soft: 12, weight: 0.5),
            Criterion(\.bassToMid, 0.1...0.45, soft: 0.15, weight: 1.0),
            Criterion(\.spectralCentroid, 0.55...0.9, soft: 0.12, weight: 1.3),
            Criterion(\.spectralFlux, 0.4...1, soft: 0.15, weight: 1.2),
            Criterion(\.transientStrength, 0.5...1, soft: 0.2, weight: 0.9),
            Criterion(\.averageLoudness, 0.6...1, soft: 0.2, weight: 0.9),
            Criterion(\.dynamicRange, 0...0.3, soft: 0.15, weight: 0.8),
            Criterion(\.highEnergy, 0.6...1, soft: 0.2, weight: 0.8),
            Criterion(\.onsetDensity, 3...8, soft: 1.2, weight: 0.7),
            Criterion(\.rhythmicRegularity, 0.3...0.8, soft: 0.2, weight: 0.3),
        ],
        .electronicDance: [
            Criterion(\.bpm, 118...142, 59...71, soft: 8, weight: 1.0),
            Criterion(\.rhythmicRegularity, 0.62...1, soft: 0.15, weight: 1.2),
            Criterion(\.bpmConfidence, 0.6...1, soft: 0.2, weight: 0.9),
            Criterion(\.bassToMid, 0.5...0.72, soft: 0.12, weight: 1.0),
            Criterion(\.spectralCentroid, 0.4...0.7, soft: 0.12, weight: 0.7),
            Criterion(\.onsetDensity, 3.2...7, soft: 1.0, weight: 1.0),
            Criterion(\.averageLoudness, 0.55...0.95, soft: 0.2, weight: 0.6),
            Criterion(\.dynamicRange, 0...0.3, soft: 0.15, weight: 0.8),
            Criterion(\.highEnergy, 0.6...0.95, soft: 0.15, weight: 0.9),
            Criterion(\.transientStrength, 0.45...0.95, soft: 0.2, weight: 0.5),
            Criterion(\.spectralFlux, 0.3...0.6, soft: 0.15, weight: 0.6),
        ],
        .pop: [
            Criterion(\.bpm, 92...132, 46...66, soft: 12, weight: 0.8),
            Criterion(\.bassToMid, 0.3...0.58, soft: 0.12, weight: 1.0),
            Criterion(\.spectralCentroid, 0.38...0.62, soft: 0.12, weight: 0.9),
            Criterion(\.rhythmicRegularity, 0.55...0.95, soft: 0.2, weight: 0.6),
            Criterion(\.averageLoudness, 0.5...0.9, soft: 0.2, weight: 0.7),
            Criterion(\.transientStrength, 0.4...0.9, soft: 0.2, weight: 0.6),
            Criterion(\.dynamicRange, 0.15...0.5, soft: 0.15, weight: 0.7),
            Criterion(\.onsetDensity, 1.2...3.2, soft: 1.0, weight: 0.9),
            Criterion(\.spectralFlux, 0.12...0.35, soft: 0.15, weight: 0.7),
            Criterion(\.highEnergy, 0.25...0.55, soft: 0.15, weight: 0.7),
        ],
        .rnbAmbient: [
            Criterion(\.bpm, 58...102, soft: 12, weight: 0.6),
            Criterion(\.bassToMid, 0.5...0.85, soft: 0.15, weight: 0.9),
            Criterion(\.spectralCentroid, 0.05...0.36, soft: 0.1, weight: 1.2),
            Criterion(\.spectralFlux, 0...0.2, soft: 0.12, weight: 1.2),
            Criterion(\.transientStrength, 0...0.4, soft: 0.15, weight: 1.0),
            Criterion(\.onsetDensity, 0...2.2, soft: 0.8, weight: 1.0),
            Criterion(\.averageLoudness, 0.3...0.95, soft: 0.2, weight: 0.3),
            Criterion(\.highEnergy, 0...0.32, soft: 0.12, weight: 0.9),
            Criterion(\.dynamicRange, 0...0.5, soft: 0.2, weight: 0.6),
        ],
        .acousticClassical: [
            Criterion(\.bassToMid, 0...0.35, soft: 0.12, weight: 1.3),
            Criterion(\.spectralCentroid, 0.35...0.62, soft: 0.12, weight: 0.7),
            Criterion(\.spectralFlux, 0...0.25, soft: 0.12, weight: 0.9),
            Criterion(\.transientStrength, 0...0.5, soft: 0.2, weight: 0.7),
            Criterion(\.onsetDensity, 0...3.5, soft: 1.0, weight: 0.6),
            Criterion(\.dynamicRange, 0.45...1, soft: 0.2, weight: 1.3),
            Criterion(\.averageLoudness, 0...0.65, soft: 0.2, weight: 0.8),
            Criterion(\.highEnergy, 0...0.35, soft: 0.12, weight: 0.7),
            Criterion(\.bpmConfidence, 0...0.6, soft: 0.25, weight: 0.3),
            Criterion(\.rhythmicRegularity, 0...0.85, soft: 0.15, weight: 0.3),
        ],
    ]

    /// Membership in `range` with a linear falloff of width `soft` on either side.
    static func membership(_ value: Double, in range: ClosedRange<Double>, soft: Double) -> Double {
        if range.contains(value) { return 1 }
        let distance = value < range.lowerBound ? range.lowerBound - value : value - range.upperBound
        guard soft > 0 else { return 0 }
        return max(0, 1 - distance / soft)
    }

    static func score(_ features: MusicFeatureSnapshot, for profile: VisualProfile) -> Double {
        guard let list = criteria[profile] else { return 0 }
        var total = 0.0
        var weights = 0.0
        for c in list {
            let value = Double(features[keyPath: c.feature])
            let m = c.ranges.map { membership(value, in: $0, soft: c.soft) }.max() ?? 0
            total += m * c.weight
            weights += c.weight
        }
        return weights > 0 ? total / weights : 0
    }

    static func classify(_ features: MusicFeatureSnapshot) -> ProfileScores {
        var scores: [VisualProfile: Double] = [:]
        for profile in VisualProfile.allCases { scores[profile] = score(features, for: profile) }
        return summarize(scores)
    }

    /// Winner and confidence from a score vector (shared with the detector's smoothed scores).
    static func summarize(_ scores: [VisualProfile: Double]) -> ProfileScores {
        let ordered = scores.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.rawValue < rhs.key.rawValue
        }
        guard let best = ordered.first else { return .neutral }
        let second = ordered.dropFirst().first
        let margin = best.value - (second?.value ?? 0)
        let confidence = best.value * (0.45 + 0.55 * min(1, max(0, margin / 0.18)))
        return ProfileScores(scores: scores, best: best.key, confidence: min(1, max(0, confidence)), runnerUp: second?.key)
    }
}

import Foundation

/// Interpolates the playback position between polls so the UI can run at display rate.
///
/// The clock keeps the last reported position and its wall-clock timestamp. While playing,
/// the current position is extrapolated linearly. Small disagreements between the extrapolated
/// position and a fresh report are absorbed instead of snapping, which hides polling jitter.
struct PlaybackClock: Sendable, Equatable {
    private(set) var anchorPosition: TimeInterval = 0
    private(set) var anchorDate: Date = .distantPast
    private(set) var isRunning: Bool = false
    private(set) var duration: TimeInterval?

    /// Reports above this threshold are treated as seeks and applied immediately.
    static let snapThreshold: TimeInterval = 0.45

    init() {}

    init(position: TimeInterval, at date: Date, running: Bool, duration: TimeInterval? = nil) {
        anchorPosition = max(0, position)
        anchorDate = date
        isRunning = running
        self.duration = duration
    }

    mutating func apply(snapshot: PlaybackSnapshot, now: Date = Date()) {
        duration = snapshot.track?.duration
        let running = snapshot.isPlaying
        let predicted = position(at: snapshot.observedAt)
        let reported = max(0, snapshot.position)
        let drift = abs(predicted - reported)
        if running == isRunning, drift < Self.snapThreshold, anchorDate != .distantPast {
            // Nudge halfway toward the reported value; avoids visible stutters on every poll.
            let corrected = predicted + (reported - predicted) * 0.5
            anchorPosition = corrected
            anchorDate = snapshot.observedAt
        } else {
            anchorPosition = reported
            anchorDate = snapshot.observedAt
        }
        isRunning = running
    }

    /// Applies a local seek immediately (before the player confirms it).
    mutating func seek(to position: TimeInterval, at date: Date = Date()) {
        anchorPosition = max(0, position)
        anchorDate = date
    }

    mutating func setRunning(_ running: Bool, at date: Date = Date()) {
        anchorPosition = position(at: date)
        anchorDate = date
        isRunning = running
    }

    func position(at date: Date) -> TimeInterval {
        guard anchorDate != .distantPast else { return 0 }
        var value = anchorPosition
        if isRunning {
            value += date.timeIntervalSince(anchorDate)
        }
        if let duration, duration > 0 {
            value = min(value, duration)
        }
        return max(0, value)
    }
}

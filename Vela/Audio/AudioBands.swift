import Foundation
import os

/// Normalised audio features consumed by the renderers. All values are 0...1.
struct AudioBands: Sendable, Equatable {
    var bass: Float
    var mid: Float
    var high: Float
    var level: Float

    static let silent = AudioBands(bass: 0, mid: 0, high: 0, level: 0)

    func mixed(toward other: AudioBands, amount: Float) -> AudioBands {
        let t = min(1, max(0, amount))
        return AudioBands(bass: bass + (other.bass - bass) * t,
                          mid: mid + (other.mid - mid) * t,
                          high: high + (other.high - high) * t,
                          level: level + (other.level - level) * t)
    }
}

/// Lock-protected mailbox between the audio thread and the render thread.
final class AudioLevelStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var bands: AudioBands = .silent
        var updatedAt: TimeInterval = 0
        var isLive = false
    }

    func publish(_ bands: AudioBands) {
        lock.withLock { state in
            state.bands = bands
            state.updatedAt = CACurrentMediaTimeCompat()
            state.isLive = true
        }
    }

    func markInactive() {
        lock.withLock { state in
            state.isLive = false
            state.bands = .silent
        }
    }

    /// Latest bands; `isLive` is false when no producer has published for half a second.
    func read() -> (bands: AudioBands, isLive: Bool) {
        lock.withLock { state in
            let stale = CACurrentMediaTimeCompat() - state.updatedAt > 0.5
            return (stale ? .silent : state.bands, state.isLive && !stale)
        }
    }
}

@inline(__always)
func CACurrentMediaTimeCompat() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}

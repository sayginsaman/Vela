import Foundation

/// Normalised band levels consumed by the renderers. All values are 0...1.
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

@inline(__always)
func CACurrentMediaTimeCompat() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}

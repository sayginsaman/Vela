import Foundation

enum TimeFormatting {
    /// `m:ss` or `h:mm:ss`.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    static func remaining(_ seconds: TimeInterval) -> String { "-" + clock(seconds) }

    static func offset(_ seconds: Double) -> String {
        if abs(seconds) < 0.05 { return "0.0 s" }
        return String(format: "%+.1f s", seconds)
    }
}

extension Double {
    func rounded(toNearest step: Double) -> Double {
        guard step > 0 else { return self }
        return (self / step).rounded() * step
    }
}

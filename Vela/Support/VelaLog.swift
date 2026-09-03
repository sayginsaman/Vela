import Foundation
import os

/// Unified-logging categories. Read with:
/// `log show --predicate 'subsystem == "app.vela"' --last 5m`
enum VelaLog {
    static let subsystem = "app.vela"
    static let sources = Logger(subsystem: subsystem, category: "sources")
    static let lyrics = Logger(subsystem: subsystem, category: "lyrics")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let app = Logger(subsystem: subsystem, category: "app")
}

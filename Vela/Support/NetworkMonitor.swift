import Foundation
import Network
import os

/// Tracks whether any network path is available so remote lyric lookups can be skipped offline.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let state = OSAllocatedUnfairLock(initialState: true)
    private let queue = DispatchQueue(label: "app.vela.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.state.withLock { $0 = path.status == .satisfied }
        }
        monitor.start(queue: queue)
    }

    var isOnline: Bool { state.withLock { $0 } }
}

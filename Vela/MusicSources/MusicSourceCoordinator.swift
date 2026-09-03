import Foundation
import AppKit

/// Which player the coordinator is currently talking to and why.
enum SourceStatus: Equatable, Sendable {
    /// No supported player is running.
    case noPlayerRunning
    /// A player is running but automation permission was refused.
    case permissionDenied(MusicSourceKind)
    /// The player was reached but is stopped / has nothing loaded.
    case idle(MusicSourceKind)
    /// Reading playback from the player.
    case active(MusicSourceKind)
    /// The preferred player is not installed / not running.
    case preferredUnavailable(MusicSourceKind)
    case error(MusicSourceKind, String)
}

struct CoordinatorEvent: Sendable, Equatable {
    var snapshot: PlaybackSnapshot
    var status: SourceStatus
    var sourceKind: MusicSourceKind?
}

/// Detects the active player, polls it at an adaptive rate and forwards transport commands.
///
/// Polling cadence: about once a second while playing, slower while paused, and very slow when no
/// player is running. Distributed notifications from Spotify and Music wake the loop immediately.
actor MusicSourceCoordinator {
    struct Intervals: Sendable {
        var playing: TimeInterval = 1.0
        var paused: TimeInterval = 2.5
        var idle: TimeInterval = 4.0
        var none: TimeInterval = 5.0
    }

    private let sources: [MusicSource]
    private(set) var preferred: MusicSourceKind?
    private(set) var activeKind: MusicSourceKind?
    private var lastEvent: CoordinatorEvent?
    private var loop: Task<Void, Never>?
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var wakePending = false
    private var sleepGeneration = 0
    private let intervals: Intervals
    private var continuation: AsyncStream<CoordinatorEvent>.Continuation?
    private var observers: [Any] = []

    let events: AsyncStream<CoordinatorEvent>

    init(sources: [MusicSource], preferred: MusicSourceKind? = nil, intervals: Intervals = Intervals()) {
        self.sources = sources
        self.preferred = preferred
        self.intervals = intervals
        var cont: AsyncStream<CoordinatorEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { cont = $0 }
        continuation = cont
    }

    deinit {
        loop?.cancel()
        continuation?.finish()
    }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        installNotificationObservers()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let event = await self.pollOnce()
                let delay = await self.delay(after: event)
                await self.sleepOrWake(delay)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers.removeAll()
    }

    func setPreferred(_ kind: MusicSourceKind?) {
        preferred = kind
        wake()
    }

    /// Ask the loop to poll now (e.g. after a command or a player notification).
    func wake() {
        if let cont = wakeContinuation {
            wakeContinuation = nil
            cont.resume()
        } else {
            wakePending = true
        }
    }

    private func sleepOrWake(_ delay: TimeInterval) async {
        if wakePending { wakePending = false; return }
        sleepGeneration &+= 1
        let generation = sleepGeneration
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wakeContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                await self?.timerFired(generation: generation)
            }
        }
    }

    /// Only the timer belonging to the current sleep may wake the loop; earlier ones are stale.
    private func timerFired(generation: Int) {
        guard generation == sleepGeneration, wakeContinuation != nil else { return }
        wake()
    }

    private func delay(after event: CoordinatorEvent) -> TimeInterval {
        switch event.status {
        case .active:
            return event.snapshot.state == .playing ? intervals.playing : intervals.paused
        case .idle: return intervals.idle
        default: return intervals.none
        }
    }

    // MARK: Polling

    private func source(for kind: MusicSourceKind) -> MusicSource? {
        sources.first { $0.kind == kind }
    }

    /// Resolves the source to poll. Preferred wins when available; otherwise the playing one;
    /// otherwise the previously active one; otherwise the first running player.
    func resolveSource() async -> (MusicSource?, SourceStatus?) {
        if let preferred {
            if let source = source(for: preferred), await source.isAvailable() {
                return (source, nil)
            }
            return (nil, .preferredUnavailable(preferred))
        }
        var available: [MusicSource] = []
        for source in sources where await source.isAvailable() {
            available.append(source)
        }
        guard !available.isEmpty else { return (nil, .noPlayerRunning) }
        if available.count == 1 { return (available[0], nil) }

        // Several players running: prefer the one that is actually playing.
        var idle: [MusicSource] = []
        for source in available {
            if let snap = try? await source.snapshot(), snap.isPlaying { return (source, nil) }
            idle.append(source)
        }
        if let activeKind, let current = idle.first(where: { $0.kind == activeKind }) { return (current, nil) }
        return (idle.first, nil)
    }

    @discardableResult
    func pollOnce() async -> CoordinatorEvent {
        let (source, failure) = await resolveSource()
        let event: CoordinatorEvent
        if let source {
            do {
                let snapshot = try await source.snapshot()
                let status: SourceStatus = snapshot.track == nil ? .idle(source.kind) : .active(source.kind)
                event = CoordinatorEvent(snapshot: snapshot, status: status, sourceKind: source.kind)
            } catch MusicSourceError.permissionDenied {
                VelaLog.sources.error("\(source.kind.rawValue, privacy: .public): automation permission denied")
                event = CoordinatorEvent(snapshot: .empty, status: .permissionDenied(source.kind), sourceKind: source.kind)
            } catch MusicSourceError.notRunning {
                event = CoordinatorEvent(snapshot: .empty, status: .noPlayerRunning, sourceKind: nil)
            } catch {
                VelaLog.sources.error("\(source.kind.rawValue, privacy: .public) poll failed: \(String(describing: error), privacy: .public)")
                event = CoordinatorEvent(snapshot: .empty, status: .error(source.kind, Self.describe(error)), sourceKind: source.kind)
            }
        } else {
            event = CoordinatorEvent(snapshot: .empty, status: failure ?? .noPlayerRunning, sourceKind: nil)
        }
        activeKind = event.sourceKind
        lastEvent = event
        continuation?.yield(event)
        return event
    }

    static func describe(_ error: Error) -> String {
        if case MusicSourceError.scriptFailed(let message) = error { return message }
        return error.localizedDescription
    }

    // MARK: Commands

    private func activeSource() -> MusicSource? {
        guard let activeKind else { return nil }
        return source(for: activeKind)
    }

    var activeCapabilities: SourceCapabilities {
        activeSource()?.capabilities ?? .none
    }

    func perform(_ action: (MusicSource) async throws -> Void) async throws {
        guard let source = activeSource() else { throw MusicSourceError.notRunning }
        try await action(source)
        wake()
    }

    func artwork(for track: TrackInfo) async throws -> CGImage? {
        guard let source = source(for: track.source) else { return nil }
        return try await source.artwork(for: track)
    }

    // MARK: Player notifications

    private func installNotificationObservers() {
        let center = DistributedNotificationCenter.default()
        let names = ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"]
        for name in names {
            let observer = center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
                Task { await self?.wake() }
            }
            observers.append(observer)
        }
    }
}

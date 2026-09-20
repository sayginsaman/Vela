import Foundation
import AppKit
import ImageIO

/// Shared behaviour for players controlled through AppleScript (Spotify, Apple Music).
///
/// Subclasses only describe the script text and how to parse the response; process checks,
/// separators and image decoding live here.
class ScriptedPlayerSource: MusicSource, @unchecked Sendable {
    let kind: MusicSourceKind
    let capabilities: SourceCapabilities = .full
    let bundleIdentifier: String
    let appName: String
    let runner: AppleScriptRunner

    /// Field separator inside script results. Defined *outside* the `tell` block in every script:
    /// Spotify's dictionary redefines `id`, which breaks `character id 31` when parsed inside it.
    static let separator = "\u{1F}"

    init(kind: MusicSourceKind, bundleIdentifier: String, appName: String, runner: AppleScriptRunner = .shared) {
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.runner = runner
    }

    func isAvailable() async -> Bool {
        NSRunningApplication.isRunning(bundleIdentifier: bundleIdentifier)
    }

    // MARK: Overridable

    var snapshotScript: String { "" }
    func parseSnapshot(_ fields: [String], observedAt: Date) -> PlaybackSnapshot { .empty }

    // MARK: MusicSource

    func snapshot() async throws -> PlaybackSnapshot {
        guard await isAvailable() else { throw MusicSourceError.notRunning }
        let result = try await runner.run(snapshotScript)
        // Measured against Spotify: the player evaluates `player position` when it services the
        // Apple Event, i.e. at the very end of the round trip (best-fit sample point 100%,
        // residual sd 1.2 ms over 30 samples with a ~180 ms round trip). Stamping it any earlier
        // makes the clock lag by that fraction of the round trip and every lyric arrives late.
        let observedAt = Date()
        guard case .text(let text) = result else { throw MusicSourceError.scriptFailed("No response") }
        let fields = text.components(separatedBy: Self.separator)
        let snapshot = parseSnapshot(fields, observedAt: observedAt)
        VelaLog.sources.debug("\(self.kind.rawValue, privacy: .public) state=\(fields.first ?? "-", privacy: .public) parsed=\(snapshot.state.rawValue, privacy: .public) pos=\(snapshot.position, privacy: .public)")
        return snapshot
    }

    func artwork(for track: TrackInfo) async throws -> CGImage? { nil }

    func play() async throws { try await command("play") }
    func pause() async throws { try await command("pause") }
    func togglePlayPause() async throws { try await command("playpause") }
    func next() async throws { try await command("next track") }
    func previous() async throws { try await command("previous track") }
    func seek(to position: TimeInterval) async throws {
        let value = String(format: "%.2f", max(0, position))
        try await command("set player position to \(value)")
    }

    func command(_ statement: String) async throws {
        guard await isAvailable() else { throw MusicSourceError.notRunning }
        _ = try await runner.run("tell application \"\(appName)\"\n\(statement)\nend tell")
    }

    // MARK: Helpers

    static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if cleaned == "missing value" { return nil }
        return Double(cleaned)
    }

    static func playbackState(_ text: String?) -> PlaybackState {
        switch text?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "playing": return .playing
        case "paused": return .paused
        default: return .stopped
        }
    }

    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}

// MARK: - Spotify

/// Spotify desktop app via its public AppleScript dictionary.
final class SpotifySource: ScriptedPlayerSource, @unchecked Sendable {
    private let session: URLSession
    private var artworkCache: (url: URL, image: CGImage)?
    private let cacheLock = NSLock()

    init(runner: AppleScriptRunner = .shared) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config)
        super.init(kind: .spotify, bundleIdentifier: "com.spotify.client", appName: "Spotify", runner: runner)
    }

    override var snapshotScript: String {
        """
        set sep to (character id 31)
        tell application "Spotify"
            set playerState to (player state as string)
            set pos to player position
            try
                set t to current track
                return playerState & sep & pos & sep & (id of t) & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (duration of t) & sep & (artwork url of t)
            on error
                return playerState & sep & pos
            end try
        end tell
        """
    }

    override func parseSnapshot(_ fields: [String], observedAt: Date) -> PlaybackSnapshot {
        let state = Self.playbackState(fields.first)
        let position = Self.number(fields.count > 1 ? fields[1] : nil) ?? 0
        guard fields.count >= 7, state != .stopped else {
            return PlaybackSnapshot(track: nil, state: state, position: position, observedAt: observedAt)
        }
        let durationMs = Self.number(fields[6])
        let track = TrackInfo(id: fields[2], title: fields[3], artist: fields[4], album: fields[5],
                              duration: durationMs.map { $0 / 1000 }, source: .spotify,
                              artworkURL: fields.count > 7 ? URL(string: fields[7]) : nil)
        return PlaybackSnapshot(track: track, state: state, position: position, observedAt: observedAt)
    }

    override func artwork(for track: TrackInfo) async throws -> CGImage? {
        guard let url = track.artworkURL else { return nil }
        cacheLock.lock()
        if let cached = artworkCache, cached.url == url { cacheLock.unlock(); return cached.image }
        cacheLock.unlock()
        let (data, _) = try await session.data(from: url)
        guard let image = Self.image(from: data) else { return nil }
        cacheLock.lock(); artworkCache = (url, image); cacheLock.unlock()
        return image
    }
}

// MARK: - Apple Music

/// Music.app via its public AppleScript dictionary.
final class AppleMusicSource: ScriptedPlayerSource, @unchecked Sendable {
    private var artworkCache: (trackID: String, image: CGImage?)?
    private let cacheLock = NSLock()

    init(runner: AppleScriptRunner = .shared) {
        super.init(kind: .appleMusic, bundleIdentifier: "com.apple.Music", appName: "Music", runner: runner)
    }

    override var snapshotScript: String {
        """
        set sep to (character id 31)
        tell application "Music"
            set playerState to (player state as string)
            try
                set t to current track
                set pos to player position
                return playerState & sep & pos & sep & (persistent ID of t) & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (duration of t) & sep & (genre of t)
            on error
                return playerState & sep & "0"
            end try
        end tell
        """
    }

    override func parseSnapshot(_ fields: [String], observedAt: Date) -> PlaybackSnapshot {
        let state = Self.playbackState(fields.first)
        let position = Self.number(fields.count > 1 ? fields[1] : nil) ?? 0
        guard fields.count >= 7, state != .stopped else {
            return PlaybackSnapshot(track: nil, state: state, position: position, observedAt: observedAt)
        }
        let genre = fields.count > 7 ? fields[7].trimmingCharacters(in: .whitespaces) : ""
        let track = TrackInfo(id: fields[2], title: fields[3], artist: fields[4], album: fields[5],
                              duration: Self.number(fields[6]), source: .appleMusic, artworkURL: nil,
                              genre: genre.isEmpty ? nil : genre)
        return PlaybackSnapshot(track: track, state: state, position: position, observedAt: observedAt)
    }

    override func artwork(for track: TrackInfo) async throws -> CGImage? {
        cacheLock.lock()
        if let cached = artworkCache, cached.trackID == track.id { cacheLock.unlock(); return cached.image }
        cacheLock.unlock()
        guard await isAvailable() else { throw MusicSourceError.notRunning }
        let script = """
        tell application "Music"
            try
                return data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        """
        let result = try await runner.run(script)
        var image: CGImage?
        if case .data(let data) = result { image = Self.image(from: data) }
        cacheLock.lock(); artworkCache = (track.id, image); cacheLock.unlock()
        return image
    }
}

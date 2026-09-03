import Foundation

/// Which player a piece of playback information came from.
enum MusicSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case spotify
    case appleMusic
    case demo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        case .demo: return "Demo"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        case .demo: return nil
        }
    }
}

/// Immutable description of a track as reported by a music source.
struct TrackInfo: Hashable, Codable, Sendable {
    /// Identifier that is stable for the lifetime of the player process (URI, persistent ID, demo id).
    var id: String
    var title: String
    var artist: String
    var album: String
    /// Total length in seconds. `nil` when the player does not report it.
    var duration: TimeInterval?
    var source: MusicSourceKind
    /// Remote artwork location, when the player only offers a URL.
    var artworkURL: URL?
    /// Genre string as reported by the player, when it exposes one (Apple Music does; Spotify does not).
    var genre: String? = nil

    /// Key used to decide whether two snapshots describe the same song.
    var identityKey: String { "\(source.rawValue):\(id)" }
}

enum PlaybackState: String, Codable, Sendable {
    case playing
    case paused
    case stopped
}

/// A point-in-time observation of the player. Positions are interpolated from `observedAt`.
struct PlaybackSnapshot: Hashable, Sendable {
    var track: TrackInfo?
    var state: PlaybackState
    /// Playback position in seconds at `observedAt`.
    var position: TimeInterval
    var observedAt: Date

    static let empty = PlaybackSnapshot(track: nil, state: .stopped, position: 0, observedAt: .distantPast)

    var isPlaying: Bool { state == .playing && track != nil }
}

/// Transport capabilities that differ between sources.
struct SourceCapabilities: Hashable, Sendable {
    var canSeek: Bool
    var canSkip: Bool
    static let full = SourceCapabilities(canSeek: true, canSkip: true)
    static let none = SourceCapabilities(canSeek: false, canSkip: false)
}

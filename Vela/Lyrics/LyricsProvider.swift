import Foundation

/// What a provider needs to find lyrics for a track.
struct LyricsQuery: Hashable, Sendable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    /// Source-specific identity so demo tracks can be matched by id.
    var trackIdentity: String

    init(track: TrackInfo) {
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration
        trackIdentity = track.identityKey
    }

    init(title: String, artist: String, album: String = "", duration: TimeInterval? = nil, trackIdentity: String = "") {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration; self.trackIdentity = trackIdentity
    }
}

enum LyricsLookup: Sendable, Equatable {
    case found(LyricDocument)
    /// The provider is authoritative that the track is instrumental.
    case instrumental
    case notFound
}

enum LyricsProviderError: Error, Sendable {
    case network(String)
    case badResponse(Int)
    case decoding
    case cancelled
}

/// A place lyrics can come from. Providers are consulted in order by `LyricsService`.
protocol LyricsProvider: Sendable {
    var name: String { get }
    /// `true` when the provider talks to the network (so it is skipped while offline).
    var isRemote: Bool { get }
    func lyrics(for query: LyricsQuery) async throws -> LyricsLookup
}

import Foundation

/// What a provider needs to find lyrics for a track.
struct LyricsQuery: Hashable, Sendable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    /// Source-specific identity so demo tracks can be matched by id.
    var trackIdentity: String
    /// Spotify's own track id, when the track came from Spotify. Catalogues keyed by it can be
    /// matched exactly instead of by title and artist.
    var spotifyTrackID: String?

    init(track: TrackInfo) {
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration
        trackIdentity = track.identityKey
        spotifyTrackID = track.source == .spotify ? Self.spotifyTrackID(fromURI: track.id) : nil
    }

    init(title: String, artist: String, album: String = "", duration: TimeInterval? = nil,
         trackIdentity: String = "", spotifyTrackID: String? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration
        self.trackIdentity = trackIdentity; self.spotifyTrackID = spotifyTrackID
    }

    /// `spotify:track:4kjI1gwQZRKNDkw1nI475M` and a bare id both yield the id.
    static func spotifyTrackID(fromURI uri: String) -> String? {
        let candidate = uri.split(separator: ":").last.map(String.init) ?? uri
        let valid = candidate.count >= 16 && candidate.allSatisfy { $0.isLetter || $0.isNumber }
        return valid ? candidate : nil
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

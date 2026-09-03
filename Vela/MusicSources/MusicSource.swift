import Foundation
import CoreGraphics

enum MusicSourceError: Error, Sendable, Equatable {
    /// The player application is not running; nothing was sent to it.
    case notRunning
    /// macOS Automation permission was denied for this player.
    case permissionDenied
    /// The player refused or failed the request.
    case scriptFailed(String)
    case unsupported
}

/// A player Vela can read from and control. Implementations must never block the main thread
/// and must never launch the player application as a side effect.
protocol MusicSource: Sendable {
    var kind: MusicSourceKind { get }
    var capabilities: SourceCapabilities { get }

    /// Cheap process check — no inter-application messaging.
    func isAvailable() async -> Bool
    /// Current playback state. Throws `MusicSourceError` when the player cannot be reached.
    func snapshot() async throws -> PlaybackSnapshot
    /// Artwork for a track, or `nil` when the player has none.
    func artwork(for track: TrackInfo) async throws -> CGImage?

    func play() async throws
    func pause() async throws
    func togglePlayPause() async throws
    func next() async throws
    func previous() async throws
    func seek(to position: TimeInterval) async throws
}

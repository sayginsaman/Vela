import XCTest
@testable import Vela

final class PlaybackClockTests: XCTestCase {
    private let track = TrackInfo(id: "t", title: "T", artist: "A", album: "B", duration: 100, source: .demo, artworkURL: nil)

    func testExtrapolatesWhilePlaying() {
        var clock = PlaybackClock()
        let start = Date(timeIntervalSince1970: 1000)
        clock.apply(snapshot: PlaybackSnapshot(track: track, state: .playing, position: 10, observedAt: start), now: start)
        XCTAssertEqual(clock.position(at: start.addingTimeInterval(2.5)), 12.5, accuracy: 0.0001)
    }

    func testHoldsWhilePaused() {
        var clock = PlaybackClock()
        let start = Date(timeIntervalSince1970: 1000)
        clock.apply(snapshot: PlaybackSnapshot(track: track, state: .paused, position: 10, observedAt: start), now: start)
        XCTAssertEqual(clock.position(at: start.addingTimeInterval(5)), 10)
    }

    func testSmallDriftIsAbsorbedLargeJumpSnaps() {
        var clock = PlaybackClock()
        let start = Date(timeIntervalSince1970: 1000)
        clock.apply(snapshot: PlaybackSnapshot(track: track, state: .playing, position: 10, observedAt: start), now: start)
        // Report 0.2 s behind the extrapolation: absorbed halfway.
        let later = start.addingTimeInterval(1)
        clock.apply(snapshot: PlaybackSnapshot(track: track, state: .playing, position: 10.8, observedAt: later), now: later)
        XCTAssertEqual(clock.position(at: later), 10.9, accuracy: 0.0001)
        // Seek far ahead: snaps.
        let seek = later.addingTimeInterval(1)
        clock.apply(snapshot: PlaybackSnapshot(track: track, state: .playing, position: 50, observedAt: seek), now: seek)
        XCTAssertEqual(clock.position(at: seek), 50, accuracy: 0.0001)
    }

    func testClampsToDuration() {
        var clock = PlaybackClock()
        let start = Date(timeIntervalSince1970: 1000)
        clock.apply(snapshot: PlaybackSnapshot(track: track, state: .playing, position: 99, observedAt: start), now: start)
        XCTAssertEqual(clock.position(at: start.addingTimeInterval(10)), 100)
    }

    func testLocalSeek() {
        var clock = PlaybackClock()
        let start = Date(timeIntervalSince1970: 1000)
        clock.apply(snapshot: PlaybackSnapshot(track: track, state: .playing, position: 10, observedAt: start), now: start)
        clock.seek(to: 40, at: start.addingTimeInterval(1))
        XCTAssertEqual(clock.position(at: start.addingTimeInterval(2)), 41, accuracy: 0.0001)
    }
}

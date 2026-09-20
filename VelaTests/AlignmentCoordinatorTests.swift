import XCTest
@testable import Vela

/// A recogniser that never touches audio: the test decides what was "heard" and when.
private final class FakeRecogniser: SpeechRecognising, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([HeardWord]) -> Void)?
    private(set) var begins: [TimeInterval] = []
    private(set) var ends = 0
    private(set) var resets = 0
    private(set) var sampleCount = 0
    var failure: Error?

    func setWordsHandler(_ handler: @escaping @Sendable ([HeardWord]) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func begin(at songTime: TimeInterval) throws {
        if let failure { throw failure }
        lock.withLock { begins.append(songTime) }
    }

    func reset() { lock.withLock { resets += 1 } }
    func end() { lock.withLock { ends += 1 } }
    func append(samples: [Float], sampleRate: Double) { lock.withLock { sampleCount += samples.count } }

    /// Delivers words as the real recogniser would, from an arbitrary queue.
    func emit(_ words: [HeardWord]) {
        let handler = lock.withLock { self.handler }
        handler?(words)
    }
}

@MainActor
final class AlignmentCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaAlignmentTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinator(_ recogniser: FakeRecogniser) -> AlignmentCoordinator {
        AlignmentCoordinator(recogniser: recogniser, store: AlignmentStore(directory: directory))
    }

    /// Eight words spread evenly across ten seconds: a line-synced document before alignment.
    private func document(provenance: String = "lrclib") -> LyricDocument {
        let text = ["Salt", "on", "the", "wire", "a", "slow", "light", "humming"]
        let words = text.enumerated().map { index, word in
            TimedWord(id: index, text: word, start: Double(index) * 1.25,
                      end: Double(index) * 1.25 + 1.25, isEstimated: true)
        }
        let line = LyricLine(id: 0, text: text.joined(separator: " "), start: 0, end: 10, words: words)
        return LyricDocument(lines: [line], quality: .lineSynced, isInstrumental: false, provenance: provenance)
    }

    private var query: LyricsQuery { LyricsQuery(title: "Wire", artist: "Test", album: "Alignment") }

    /// The words the recogniser would produce if the singer were half a second late throughout.
    private func heardLate() -> [HeardWord] {
        [HeardWord(text: "salt", start: 0.7, end: 1.2),
         HeardWord(text: "wire", start: 4.3, end: 4.8),
         HeardWord(text: "humming", start: 9.2, end: 9.9)]
    }

    func testDisabledStaysOff() async {
        let recogniser = FakeRecogniser()
        let coordinator = makeCoordinator(recogniser)
        let stored = await coordinator.begin(query: query, document: document(), enabled: false, songTime: 0)
        XCTAssertNil(stored)
        XCTAssertEqual(coordinator.status, .off)
        coordinator.startListening(songTime: 0)
        XCTAssertTrue(recogniser.begins.isEmpty, "Nothing should listen while the feature is off.")
    }

    func testListeningRefinesAndReportsProgress() async {
        let recogniser = FakeRecogniser()
        let coordinator = makeCoordinator(recogniser)
        var refined: LyricDocument?
        coordinator.onRefinedDocument = { refined = $0 }

        _ = await coordinator.begin(query: query, document: document(), enabled: true, songTime: 0)
        coordinator.startListening(songTime: 0)
        XCTAssertEqual(recogniser.begins, [0])

        recogniser.emit(heardLate())
        await Task.yield()
        await coordinator.alignNow()

        let result = try? XCTUnwrap(refined)
        XCTAssertNotNil(result, "Three good anchors should produce a refined document.")
        let first = try? XCTUnwrap(result?.lines.first?.words.first)
        XCTAssertEqual(first?.start ?? 0, 0.7, accuracy: 0.001, "The first word should land where it was heard.")
        XCTAssertTrue(result?.provenance.contains("aligned") ?? false)
        if case .listening(let anchored) = coordinator.status {
            XCTAssertGreaterThan(anchored, 0)
        } else {
            XCTFail("Expected a listening status, got \(coordinator.status).")
        }
    }

    func testAlignmentIsRememberedForTheNextPlay() async {
        let recogniser = FakeRecogniser()
        let first = makeCoordinator(recogniser)
        _ = await first.begin(query: query, document: document(), enabled: true, songTime: 0)
        first.startListening(songTime: 0)
        recogniser.emit(heardLate())
        await Task.yield()
        await first.alignNow()
        first.stop()
        XCTAssertEqual(recogniser.ends, 1)

        // Give the detached persistence task a moment to write.
        try? await Task.sleep(for: .milliseconds(200))

        let second = makeCoordinator(FakeRecogniser())
        let stored = await second.begin(query: query, document: document(), enabled: true, songTime: 0)
        let remembered = try? XCTUnwrap(stored)
        XCTAssertNotNil(remembered, "A second play should start from the stored alignment.")
        XCTAssertEqual(remembered?.lines.first?.words.first?.start ?? 0, 0.7, accuracy: 0.001)
    }

    func testSeekReanchorsTheRecogniser() async {
        let recogniser = FakeRecogniser()
        let coordinator = makeCoordinator(recogniser)
        _ = await coordinator.begin(query: query, document: document(), enabled: true, songTime: 0)
        coordinator.startListening(songTime: 0)
        coordinator.playbackJumped(to: 42)
        XCTAssertEqual(recogniser.begins, [0, 42], "A seek restarts the session at the new position.")
        XCTAssertEqual(recogniser.ends, 1)
    }

    func testStartingTwiceOnlyOpensOneSession() async {
        let recogniser = FakeRecogniser()
        let coordinator = makeCoordinator(recogniser)
        _ = await coordinator.begin(query: query, document: document(), enabled: true, songTime: 0)
        coordinator.startListening(songTime: 0)
        coordinator.startListening(songTime: 1)
        coordinator.startListening(songTime: 2)
        XCTAssertEqual(recogniser.begins, [0])
    }

    func testRecogniserFailureIsReportedNotCrashed() async {
        let recogniser = FakeRecogniser()
        recogniser.failure = SpeechRecogniserError.notAuthorised
        let coordinator = makeCoordinator(recogniser)
        _ = await coordinator.begin(query: query, document: document(), enabled: true, songTime: 0)
        coordinator.startListening(songTime: 0)
        XCTAssertEqual(coordinator.status, .unavailable("Speech recognition access has not been granted."))
    }

    func testSampleSinkReachesTheRecogniserWithoutTheMainActor() async {
        let recogniser = FakeRecogniser()
        let coordinator = makeCoordinator(recogniser)
        let sink = coordinator.sampleSink()
        await Task.detached { sink([0, 0, 0, 0], 48_000) }.value
        XCTAssertEqual(recogniser.sampleCount, 4)
    }

    func testStoreKeepsTheBetterAlignment() async {
        let store = AlignmentStore(directory: directory)
        var good = document(provenance: "good")
        good.lines[0].words[0].start = 1
        var poor = document(provenance: "poor")
        poor.lines[0].words[0].start = 2

        await store.store(good, anchoredFraction: 0.8, for: query)
        await store.store(poor, anchoredFraction: 0.3, for: query)
        let kept = await store.entry(for: query)
        XCTAssertEqual(kept?.document.provenance, "good", "A worse listen must not overwrite a better one.")

        await store.clear()
        let cleared = await store.entry(for: query)
        XCTAssertNil(cleared)
    }
}

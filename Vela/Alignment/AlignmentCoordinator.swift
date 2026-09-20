import Foundation
import Observation
import Speech

/// Runs local forced alignment: listens to the song through the existing system-audio capture,
/// and pins lyric words to the moments they are actually sung.
///
/// What this can and cannot do is worth being precise about. Recognition only ever describes audio
/// that has already played, so it cannot improve the word being sung right now. What it *can* do is
/// two things that matter: every anchor shifts the words that follow, which corrects drift for the
/// rest of the song, and the finished alignment is kept on disk so the next play of that track
/// starts with real timings instead of estimates.
@MainActor
@Observable
final class AlignmentCoordinator {
    enum Status: Equatable {
        case off
        case unavailable(String)
        case idle
        case listening(anchored: Double)

        var summary: String {
            switch self {
            case .off: return "Off."
            case .unavailable(let reason): return reason
            case .idle: return "Waiting for a song with lyrics to refine."
            case .listening(let anchored):
                return anchored <= 0
                    ? "Listening… nothing pinned yet."
                    : String(format: "Listening… %.0f%% of words pinned to the audio.", anchored * 100)
            }
        }
    }

    private(set) var status: Status = .off
    /// Called with a refined document whenever alignment improves on what is on screen.
    var onRefinedDocument: ((LyricDocument) -> Void)?

    @ObservationIgnored nonisolated let recogniser: any SpeechRecognising
    @ObservationIgnored private let store: AlignmentStore
    @ObservationIgnored private var query: LyricsQuery?
    @ObservationIgnored private var baseline: LyricDocument?
    @ObservationIgnored private var best: (document: LyricDocument, anchored: Double)?
    @ObservationIgnored private var heard: [HeardWord] = []
    @ObservationIgnored private var heardIsDirty = false
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var aligning = false

    /// Improvement needed before replacing what is already on screen, so the view is not
    /// rebuilt for a fraction of a percent.
    static let improvementThreshold = 0.02

    init(recogniser: SpeechRecognising = AppleSpeechRecogniser(), store: AlignmentStore = AlignmentStore()) {
        self.recogniser = recogniser
        self.store = store
        self.recogniser.setWordsHandler { [weak self] words in
            Task { @MainActor [weak self] in self?.received(words) }
        }
    }

    // MARK: Permission

    static var authorisationStatus: SFSpeechRecognizerAuthorizationStatus { AppleSpeechRecogniser.authorisationStatus }

    static func requestAuthorisation() async -> SFSpeechRecognizerAuthorizationStatus {
        await AppleSpeechRecogniser.requestAuthorisation()
    }

    // MARK: Lifecycle

    /// Prepares alignment for a track. Returns a stored alignment when one exists, so the caller
    /// can show real timings from the first second of a replay.
    func begin(query: LyricsQuery?, document: LyricDocument?, enabled: Bool, songTime: TimeInterval) async -> LyricDocument? {
        stop()
        self.query = query
        baseline = document
        heard = []
        best = nil
        isEnabled = enabled
        guard enabled else { status = .off; return nil }
        guard let query, let document, !document.lines.isEmpty else { status = .idle; return nil }

        // A previous listen may already have solved this track.
        var stored: LyricDocument?
        if let entry = await store.entry(for: query) {
            best = (entry.document, entry.anchoredFraction)
            baseline = entry.document
            stored = entry.document
            status = .listening(anchored: entry.anchoredFraction)
        }
        // Nothing to gain on lyrics that already carry real per-word timing.
        guard document.quality != .wordSynced || stored != nil else { status = .idle; return stored }
        return stored
    }

    /// Starts listening. Safe to call repeatedly; only the first call does anything.
    func startListening(songTime: TimeInterval) {
        guard isEnabled, !isRunning, baseline != nil, query != nil else { return }
        do {
            recogniser.reset()
            try recogniser.begin(at: songTime)
            isRunning = true
            if case .listening = status {} else { status = .listening(anchored: best?.anchored ?? 0) }
            startTicker()
        } catch {
            status = .unavailable(Self.describe(error))
        }
    }

    /// The song jumped, so the recogniser has to be re-anchored. What was already heard stays.
    func playbackJumped(to songTime: TimeInterval) {
        guard isRunning else { return }
        recogniser.end()
        try? recogniser.begin(at: songTime)
    }

    func stop() {
        isEnabled = false
        ticker?.cancel(); ticker = nil
        if isRunning { recogniser.end() }
        isRunning = false
        persistBest()
    }

    /// The audio callback runs many times a second, so it must not hop to the main actor. The
    /// recogniser is thread-safe and ignores samples when no session is open.
    nonisolated func sampleSink() -> @Sendable ([Float], Double) -> Void {
        let recogniser = self.recogniser
        return { samples, rate in recogniser.append(samples: samples, sampleRate: rate) }
    }

    // MARK: Alignment

    private func received(_ words: [HeardWord]) {
        heard = words
        heardIsDirty = true
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                await self.alignIfNeeded()
            }
        }
    }

    /// Runs one alignment pass immediately instead of waiting for the ticker. Used by tests.
    func alignNow() async { await alignIfNeeded() }

    private func alignIfNeeded() async {
        guard heardIsDirty, !aligning, let baseline else { return }
        heardIsDirty = false
        aligning = true
        defer { aligning = false }
        let words = WordAligner.words(in: baseline)
        let snapshot = heard
        guard !words.isEmpty, !snapshot.isEmpty else { return }
        let result = await Task.detached(priority: .utility) {
            WordAligner.align(lyrics: words, heard: snapshot)
        }.value
        guard result.anchorCount > 0 else { return }
        status = .listening(anchored: result.anchoredFraction)
        guard result.anchoredFraction > (best?.anchored ?? 0) + Self.improvementThreshold else { return }
        let refined = WordAligner.apply(result, to: baseline)
        best = (refined, result.anchoredFraction)
        onRefinedDocument?(refined)
    }

    private func persistBest() {
        guard let query, let best, best.anchored > 0 else { return }
        let document = best.document
        let fraction = best.anchored
        Task { [store] in await store.store(document, anchoredFraction: fraction, for: query) }
    }

    func clearStoredAlignments() {
        Task { [store] in await store.clear() }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SpeechRecogniserError.notAuthorised: return "Speech recognition access has not been granted."
        case SpeechRecogniserError.onDeviceUnavailable: return "This Mac has no on-device model for the language, so Vela will not listen."
        case SpeechRecogniserError.unavailable: return "Speech recognition is unavailable right now."
        default: return error.localizedDescription
        }
    }
}

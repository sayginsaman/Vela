import SwiftUI
import Observation
import Speech
import AppKit
import UniformTypeIdentifiers

enum LyricsUnavailableReason: Equatable, Sendable {
    case notFound
    case offline
    case failed(String)
}

/// Reference wrapper around `LyricTimeline` so per-frame lookups can advance the cursor without
/// invalidating SwiftUI state.
final class LyricTimelineBox: @unchecked Sendable {
    private var timeline: LyricTimeline
    private let lock = NSLock()
    let document: LyricDocument
    let sungLines: [LyricLine]
    private let sungIndexByLineID: [Int: Int]
    /// Every sung word in order, for the word-stack presentation.
    let flatWords: [FlatWord]
    private let flatStart: [Int]
    /// Typical word length, used to size held words relative to quick ones.
    let medianWordDuration: TimeInterval

    init(document: LyricDocument) {
        self.document = document
        timeline = LyricTimeline(document: document)
        sungLines = timeline.sungLines
        var map: [Int: Int] = [:]
        for (index, line) in sungLines.enumerated() { map[line.id] = index }
        sungIndexByLineID = map
        var flat: [FlatWord] = []
        var starts: [Int] = []
        for (lineIndex, line) in sungLines.enumerated() {
            starts.append(flat.count)
            for (wordIndex, word) in line.words.enumerated() {
                flat.append(FlatWord(id: flat.count, sungLine: lineIndex, wordIndex: wordIndex, word: word))
            }
        }
        flatWords = flat
        flatStart = starts
        medianWordDuration = WordStackLayout.medianDuration(of: flat.map(\.word))
    }

    /// Flat index of a word addressed by sung-line and word index.
    func flatIndex(sungLine: Int, word: Int) -> Int? {
        guard sungLine >= 0, sungLine < flatStart.count, word >= 0, word < sungLines[sungLine].words.count else { return nil }
        return flatStart[sungLine] + word
    }

    /// Flat index of the first word of a sung line.
    func firstFlatIndex(ofSungLine line: Int) -> Int? {
        guard line >= 0, line < flatStart.count else { return nil }
        return flatStart[line]
    }

    func locate(at time: TimeInterval) -> LyricPosition {
        lock.lock(); defer { lock.unlock() }
        return timeline.locate(at: time)
    }

    /// Maps a document line index to its index in `sungLines`.
    func sungIndex(forDocumentLine index: Int) -> Int? {
        guard index >= 0, index < document.lines.count else { return nil }
        return sungIndexByLineID[document.lines[index].id]
    }
}

enum LyricsState: Equatable {
    case idle
    case loading
    case ready(LyricTimelineBox)
    case instrumental
    case unavailable(LyricsUnavailableReason)

    static func == (lhs: LyricsState, rhs: LyricsState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.instrumental, .instrumental): return true
        case (.ready(let a), .ready(let b)): return a === b
        case (.unavailable(let a), .unavailable(let b)): return a == b
        default: return false
        }
    }
}

/// What the fullscreen stage should show right now.
enum Stage: Equatable {
    case noPlayer(SourceStatus)
    case idlePlayer(MusicSourceKind)
    case loadingLyrics
    case lyrics(LyricTimelineBox)
    case unsynced(LyricTimelineBox)
    case instrumental
    case lyricsUnavailable(LyricsUnavailableReason)

    static func == (lhs: Stage, rhs: Stage) -> Bool {
        switch (lhs, rhs) {
        case (.noPlayer(let a), .noPlayer(let b)): return a == b
        case (.idlePlayer(let a), .idlePlayer(let b)): return a == b
        case (.loadingLyrics, .loadingLyrics), (.instrumental, .instrumental): return true
        case (.lyrics(let a), .lyrics(let b)), (.unsynced(let a), .unsynced(let b)): return a === b
        case (.lyricsUnavailable(let a), .lyricsUnavailable(let b)): return a == b
        default: return false
        }
    }
}

/// Central observable state for the app. Owns the services and translates their events into
/// UI-facing state. Everything here runs on the main actor; the services do their work elsewhere.
@MainActor
@Observable
final class AppModel {
    // MARK: Dependencies
    let settingsStore: SettingsStore
    let audio = AudioEngine()
    let windowController = WindowController()
    /// Produces the smoothed per-frame visual state for the renderers.
    let director = VisualDirector()
    /// Sparkle-backed in-app updates.
    let updates = UpdateController()
    /// Local forced alignment: pins lyric words to the audio actually playing.
    let alignment = AlignmentCoordinator()
    /// Bumped after a speech permission answer so the settings view re-reads the status.
    private(set) var speechPermissionRevision = 0

    @ObservationIgnored private let demoSource: DemoMusicSource
    @ObservationIgnored private let coordinator: MusicSourceCoordinator
    @ObservationIgnored private let lyricsService: LyricsService
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var lastPointerReschedule: TimeInterval = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private let detector = ProfileDetector()
    @ObservationIgnored private let latencyMonitor = OutputLatencyMonitor()
    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    @ObservationIgnored private var trackGeneration = 0
    @ObservationIgnored private var reduceMotion = false
    /// `VELA_PROFILE=<auto|rapTrap|…>` overrides the saved selection for this run only (captures).
    @ObservationIgnored private let profileOverride: VisualProfileSelection? =
        ProcessInfo.processInfo.environment["VELA_PROFILE"].flatMap(VisualProfileSelection.init(rawValue:))

    // MARK: Playback state
    private(set) var playback: PlaybackSnapshot = .empty
    private(set) var clock = PlaybackClock()
    private(set) var track: TrackInfo?
    private(set) var capabilities: SourceCapabilities = .none
    private(set) var sourceStatus: SourceStatus = .noPlayerRunning
    private(set) var activeSourceKind: MusicSourceKind?
    private(set) var isDemoMode = false

    // MARK: Visual state
    private(set) var artwork: CGImage?
    private(set) var backdrop: CGImage?
    private(set) var backdropSharp: CGImage?
    /// The untreated cover, full resolution, for the Cover Art look.
    private(set) var backdropCover: CGImage?
    /// Increments whenever new backdrops are installed, so the renderer re-uploads once.
    private(set) var artworkGeneration = 0
    private(set) var extractedPalette: Palette = .fallback
    private(set) var lyrics: LyricsState = .idle
    private(set) var transitionID = 0
    private(set) var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    private(set) var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    // MARK: Visual profile state
    private(set) var detection: ProfileDetection = .pending
    /// Audio-heuristic estimate for the diagnostics section (also computed when genre decides).
    private(set) var audioEstimate: ProfileScores = .neutral
    /// Latest downsampled features for diagnostics (4 Hz, never per frame).
    private(set) var diagnostics: MusicFeatureSnapshot = .silent
    private(set) var previewProfile: VisualProfile?
    /// Reported output-device latency and the device it belongs to.
    private(set) var outputLatency: OutputLatencyMonitor.Reading = .none

    // MARK: User-supplied provider keys
    /// Masked form of the stored Musixmatch key, empty when none is set.
    private(set) var musixmatchKeyHint = KeychainStore.redacted(KeychainStore.get(account: MusixmatchProvider.keychainAccount))
    private(set) var musixmatchStatus: String?
    private(set) var isCheckingMusixmatchKey = false
    var hasMusixmatchKey: Bool { !musixmatchKeyHint.isEmpty }

    // MARK: UI state
    var isFullscreen = false
    private(set) var overlayVisible = true
    private(set) var overlayHovering = false
    var settingsVisible = false { didSet { if settingsVisible { cancelHide() } else { scheduleHide() } } }
    /// Direct manipulation of the scene: the elements gain drag handles until this is turned off.
    private(set) var isArrangingScene = false
    var showOnboarding: Bool
    private(set) var toast: String?
    /// Brief title card shown when a new track starts.
    private(set) var introVisible = false
    @ObservationIgnored private var introTask: Task<Void, Never>?

    static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    init(settingsStore: SettingsStore? = nil) {
        let settingsStore = settingsStore ?? SettingsStore()
        self.settingsStore = settingsStore
        showOnboarding = !settingsStore.settings.onboardingComplete
        let demo = DemoMusicSource(enabled: false)
        demoSource = demo
        let preferred = settingsStore.settings.preferredSource
        coordinator = MusicSourceCoordinator(sources: [SpotifySource(), AppleMusicSource(), demo], preferred: preferred.kind)
        lyricsService = LyricsService(cache: LyricsCache(), localStore: LocalLyricsStore())
        if preferred == .demo { isDemoMode = true }
    }

    // MARK: Convenience

    var settings: VelaSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    var isPlaying: Bool { playback.isPlaying }

    var palette: Palette {
        guard settings.paletteMode == .manual else { return extractedPalette }
        let background = PaletteCorrector.darkenedBackground(from: settings.manualBackground)
        let highlight = PaletteCorrector.ensureContrast(settings.manualHighlight, against: background, minimum: PaletteCorrector.highlightContrast)
        let glow = PaletteCorrector.ensureContrast(settings.manualGlow, against: background, minimum: 3)
        let primary = PaletteCorrector.ensureContrast(highlight.withSaturation(0.1).withBrightness(0.95), against: background, minimum: PaletteCorrector.primaryContrast)
        return Palette(background: background, primary: primary, highlight: highlight, glow: glow,
                       gradient: [highlight, glow, highlight.rotatingHue(by: -0.1).withBrightness(0.85), glow.rotatingHue(by: 0.12).withBrightness(0.8)])
    }

    var stage: Stage {
        guard let _ = track else {
            switch sourceStatus {
            case .idle(let kind): return .idlePlayer(kind)
            default: return .noPlayer(sourceStatus)
            }
        }
        switch lyrics {
        case .idle, .loading: return .loadingLyrics
        case .instrumental: return .instrumental
        case .unavailable(let reason): return .lyricsUnavailable(reason)
        case .ready(let box): return box.document.isSynced ? .lyrics(box) : .unsynced(box)
        }
    }

    var currentPosition: TimeInterval { clock.position(at: Date()) }

    var lyricsQualityDescription: String? {
        guard case .ready(let box) = lyrics else { return nil }
        let aligned = box.document.provenance.contains("aligned") ? " · aligned" : ""
        switch box.document.quality {
        case .wordSynced: return "Word-synced" + aligned
        case .lineSynced: return "Line-synced · words estimated" + aligned
        case .estimated: return "Estimated timing" + aligned
        case .unsynced: return "Unsynced"
        }
    }

    /// Seconds added to the playback position when looking up lyrics.
    var lyricTimeShift: TimeInterval {
        LyricTiming.shift(userOffset: settings.lyricsOffset, outputLatency: outputLatency.latency, compensate: settings.compensateOutputLatency)
    }

    /// Moves the user timing offset by one step and reports the result.
    func nudgeLyricsOffset(by delta: TimeInterval) {
        let next = (settings.lyricsOffset + delta).rounded(toNearest: 0.05)
        settings.lyricsOffset = min(max(next, VelaSettings.offsetRange.lowerBound), VelaSettings.offsetRange.upperBound)
        let value = settings.lyricsOffset
        let direction = abs(value) < 0.001 ? "neutral" : (value > 0 ? "earlier" : "later")
        showToast("Lyrics \(TimeFormatting.offset(value)) · \(direction)")
        showOverlay()
    }

    /// The profile in force: a manual lock, otherwise Auto's detection (Pop until settled).
    var effectiveProfile: VisualProfile {
        ProfileResolver.resolve(selection: profileOverride ?? settings.visualProfile, detection: detection)
    }

    /// Demo audio fixture for the current track (defaults to Pop for real players).
    private var currentFixture: ProfileFixture {
        guard let track, track.source == .demo, let demo = DemoCatalog.track(withID: track.id) else { return ProfileFixture(profile: .pop) }
        return demo.fixture
    }

    func setReduceMotion(_ value: Bool) {
        guard value != reduceMotion else { return }
        reduceMotion = value
        pushVisualInputs()
    }

    /// Sends every discrete input the director needs. Cheap; called whenever one changes.
    func pushVisualInputs() {
        let s = settings
        var inputs = VisualDirector.Inputs()
        inputs.profile = effectiveProfile
        inputs.palette = palette
        inputs.reactive = s.reactiveIntensity
        inputs.background = s.backgroundReaction
        inputs.edge = s.edgeReaction
        inputs.lyric = s.lyricMotionIntensity
        inputs.particlesEnabled = s.particlesEnabled
        inputs.reduceMotion = reduceMotion
        inputs.reduceIntenseMotion = s.reduceIntenseMotion
        inputs.reduceEffects = s.reduceEffects
        inputs.glowThickness = s.glowThickness
        inputs.glowIntensity = s.glowIntensity
        inputs.glowSpread = s.glowSpread
        inputs.reactiveMotion = s.reactiveMotion
        inputs.isPlaying = playback.isPlaying
        inputs.trackGeneration = trackGeneration
        director.update(inputs: inputs)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        guard !Self.isRunningTests else { return }
        installKeyMonitor()
        NotificationCenter.default.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                self?.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
        director.onPreviewEnded = { [weak self] in
            Task { @MainActor [weak self] in self?.previewProfile = nil }
        }
        audio.sampleSink = alignment.sampleSink()
        alignment.onRefinedDocument = { [weak self] document in
            self?.applyRefinedLyrics(document)
        }
        outputLatency = latencyMonitor.reading
        latencyMonitor.onChange = { [weak self] reading in
            Task { @MainActor [weak self] in
                self?.outputLatency = reading
                VelaLog.app.info("output latency \(reading.latency, privacy: .public)s on \(reading.deviceName, privacy: .public)")
            }
        }
        pushVisualInputs()
        startDetectionLoop()
        if isDemoMode { Task { await demoSource.setEnabled(true) } }
        // Developer hooks: `VELA_DEMO_TRACK=<catalogue id>` starts straight into that demo fixture;
        // `VELA_SCREENSHOT_SETTINGS=1` / `VELA_SCREENSHOT_ONBOARDING=1` / `VELA_SCREENSHOT_ARRANGE=1`
        // show those layers for captures.
        let env = ProcessInfo.processInfo.environment
        if let requested = env["VELA_DEMO_TRACK"], DemoCatalog.track(withID: requested) != nil {
            selectDemoTrack(id: requested)
        }
        if env["VELA_SCREENSHOT_PATH"] != nil {
            settingsStore.isPersistenceEnabled = false
            if let profileOverride { settings.visualProfile = profileOverride }
            if let layout = env["VELA_LAYOUT"].flatMap(SceneLayout.init(rawValue:)) { settings.sceneLayout = layout }
            if let style = env["VELA_LYRIC_STYLE"].flatMap(LyricStyle.init(rawValue:)) { settings.lyricStyle = style }
            showOnboarding = env["VELA_SCREENSHOT_ONBOARDING"] == "1"
            if env["VELA_SCREENSHOT_SETTINGS"] == "1" || env["VELA_SCREENSHOT_ARRANGE"] == "1" {
                let arranging = env["VELA_SCREENSHOT_ARRANGE"] == "1"
                let delay = max(0.5, (Double(env["VELA_SCREENSHOT_DELAY"] ?? "") ?? 20) - 1.5)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    if arranging { self?.beginArrangingScene() } else { self?.settingsVisible = true }
                }
            }
        }
        eventTask = Task { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            await coordinator.start()
            for await event in coordinator.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        windowController.onFullscreenChange = { [weak self] value in
            guard let self else { return }
            self.isFullscreen = value
            if value { self.showOverlay() }
        }
    }

    /// Samples the feature store four times a second for Auto detection and diagnostics.
    /// Raw audio never reaches SwiftUI at buffer rate.
    private func startDetectionLoop() {
        detectionTask?.cancel()
        detectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.sampleDetection()
            }
        }
    }

    private func sampleDetection() {
        let (snapshot, live) = audio.store.read()
        diagnostics = live ? snapshot : .silent
        if settings.localAlignment, playback.isPlaying, audio.status == .capturing {
            alignment.startListening(songTime: currentPosition)
        }
        guard live, playback.isPlaying, track != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let changed = detector.ingest(snapshot, at: now) {
            detection = changed
            VelaLog.app.info("profile detection: \(changed.profile.rawValue, privacy: .public) \(changed.confidence, privacy: .public) via \(changed.source.rawValue, privacy: .public)")
            pushVisualInputs()
        }
        audioEstimate = detector.audioEstimate
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKey(event) else { return event }
            return nil
        }
    }

    // MARK: Events

    private func handle(_ event: CoordinatorEvent) async {
        sourceStatus = event.status
        activeSourceKind = event.sourceKind
        let snapshot = event.snapshot
        if snapshot.track?.identityKey != track?.identityKey {
            trackDidChange(to: snapshot.track)
        }
        let wasPlaying = playback.isPlaying
        playback = snapshot
        var updated = clock
        updated.apply(snapshot: snapshot)
        clock = updated
        capabilities = event.sourceKind == nil ? .none : await coordinator.activeCapabilities
        audio.updateClock(clock, fixture: currentFixture)
        updateAudioMode()
        if wasPlaying != snapshot.isPlaying {
            if snapshot.isPlaying { scheduleHide() } else { showOverlay() }
            pushVisualInputs()
        }
    }

    private func trackDidChange(to newTrack: TrackInfo?) {
        lyricsTask?.cancel()
        artworkTask?.cancel()
        track = newTrack
        transitionID &+= 1
        trackGeneration &+= 1
        detector.reset(trackID: newTrack?.identityKey, genre: newTrack?.genre)
        detection = detector.detection
        audioEstimate = .neutral
        audio.resetAnalysis()
        alignment.stop()
        audio.updateClock(clock, fixture: currentFixture)
        guard let newTrack else {
            withAnimation(.easeInOut(duration: 1.0)) {
                artwork = nil
                backdrop = nil
                backdropSharp = nil
                backdropCover = nil
                artworkGeneration &+= 1
                extractedPalette = .fallback
            }
            lyrics = .idle
            pushVisualInputs()
            return
        }
        pushVisualInputs()
        lyrics = .loading
        showTrackIntro()
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let image = try? await self.coordinator.artwork(for: newTrack)
            guard !Task.isCancelled else { return }
            let output = await ArtworkProcessor.process(image)
            guard !Task.isCancelled, self.track?.identityKey == newTrack.identityKey else { return }
            withAnimation(.easeInOut(duration: 1.2)) {
                self.artwork = image
                self.backdrop = output.backdrop
                self.backdropSharp = output.backdropSharp
                self.backdropCover = output.cover
                self.artworkGeneration &+= 1
                self.extractedPalette = output.palette
            }
            self.pushVisualInputs()
        }
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.lyricsService.resolve(track: newTrack)
            guard !Task.isCancelled, self.track?.identityKey == newTrack.identityKey else { return }
            VelaLog.lyrics.info("lyrics for \(newTrack.title, privacy: .public): \(String(describing: outcome).prefix(60), privacy: .public)")
            withAnimation(.easeInOut(duration: 0.5)) {
                switch outcome {
                case .found(let doc):
                    self.lyrics = .ready(LyricTimelineBox(document: doc))
                    self.beginAlignment(for: newTrack, document: doc)
                case .instrumental: self.lyrics = .instrumental
                case .notFound: self.lyrics = .unavailable(.notFound)
                case .offline: self.lyrics = .unavailable(.offline)
                case .failed(let message):
                    if message == "cancelled" { return }
                    self.lyrics = .unavailable(.failed(message))
                }
            }
        }
    }

    /// Swaps in a better-timed document without disturbing anything else on screen.
    private func applyRefinedLyrics(_ document: LyricDocument) {
        guard case .ready = lyrics else { return }
        lyrics = .ready(LyricTimelineBox(document: document))
        VelaLog.lyrics.info("alignment refined \(document.provenance, privacy: .public)")
    }

    /// Leaves Settings and hands the scene its drag handles.
    func beginArrangingScene() {
        settingsVisible = false
        isArrangingScene = true
        showOverlay()
    }

    func endArrangingScene() {
        isArrangingScene = false
    }

    /// Puts both elements back where the layout would have placed them.
    func resetArrangement() {
        settings.lyricArrangement = .identity
        settings.panelArrangement = .identity
    }

    /// Whether the user has granted speech recognition, which local alignment needs.
    var speechAuthorisation: SFSpeechRecognizerAuthorizationStatus {
        _ = speechPermissionRevision   // re-reads the live status after the user answers.
        return AlignmentCoordinator.authorisationStatus
    }

    /// Asks for speech recognition and, once granted, starts aligning the current track.
    func requestSpeechPermission() {
        Task { [weak self] in
            _ = await AlignmentCoordinator.requestAuthorisation()
            guard let self else { return }
            self.speechPermissionRevision &+= 1
            if case .ready(let box) = self.lyrics, let track = self.track {
                self.beginAlignment(for: track, document: box.document)
            }
        }
    }

    /// Forgets every alignment learned from listening.
    func clearStoredAlignments() {
        alignment.clearStoredAlignments()
    }

    /// Hands the freshly resolved lyrics to the aligner, and adopts a stored alignment from a
    /// previous listen when there is one.
    private func beginAlignment(for track: TrackInfo, document: LyricDocument) {
        let enabled = settings.localAlignment
        Task { [weak self] in
            guard let self else { return }
            let stored = await self.alignment.begin(query: LyricsQuery(track: track), document: document,
                                                    enabled: enabled, songTime: self.currentPosition)
            guard self.track?.identityKey == track.identityKey, let stored else { return }
            self.applyRefinedLyrics(stored)
        }
    }

    private func updateAudioMode() {
        if isDemoMode {
            audio.setMode(.demo)
        } else if track != nil {
            audio.setMode(.system)
        } else {
            audio.setMode(.off)
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        guard track != nil else { return }
        var updated = clock
        updated.setRunning(!clock.isRunning)
        clock = updated
        audio.updateClock(clock, fixture: currentFixture)
        Task { [coordinator] in
            do { try await coordinator.perform { try await $0.togglePlayPause() } }
            catch { await self.report(error) }
        }
        showOverlay()
    }

    func next() {
        guard capabilities.canSkip else { return }
        Task { [coordinator] in
            do { try await coordinator.perform { try await $0.next() } }
            catch { await self.report(error) }
        }
        showOverlay()
    }

    func previous() {
        guard capabilities.canSkip else { return }
        Task { [coordinator] in
            do { try await coordinator.perform { try await $0.previous() } }
            catch { await self.report(error) }
        }
        showOverlay()
    }

    func seek(to position: TimeInterval) {
        guard capabilities.canSeek, let track else { return }
        let clamped = min(max(0, position), track.duration ?? position)
        var updated = clock
        updated.seek(to: clamped)
        clock = updated
        audio.updateClock(clock, fixture: currentFixture)
        alignment.playbackJumped(to: clamped)
        Task { [coordinator] in
            do { try await coordinator.perform { try await $0.seek(to: clamped) } }
            catch { await self.report(error) }
        }
    }

    func seek(by delta: TimeInterval) {
        seek(to: currentPosition + delta)
        showOverlay()
    }

    private func report(_ error: Error) {
        let message: String
        switch error {
        case MusicSourceError.permissionDenied: message = "Automation permission was denied. Allow Vela in System Settings › Privacy & Security › Automation."
        case MusicSourceError.notRunning: message = "The music app isn't running."
        case MusicSourceError.scriptFailed(let text): message = text
        default: message = error.localizedDescription
        }
        showToast(message)
    }

    private func showTrackIntro() {
        introTask?.cancel()
        withAnimation(.easeOut(duration: 0.5)) { introVisible = true }
        introTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) { self?.introVisible = false }
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }

    // MARK: Demo mode

    func toggleDemoMode() { setDemoMode(!isDemoMode) }

    func setDemoMode(_ enabled: Bool) {
        guard enabled != isDemoMode else { return }
        isDemoMode = enabled
        let preferred = enabled ? MusicSourceKind.demo : settings.preferredSource.kind
        Task { [demoSource, coordinator] in
            await demoSource.setEnabled(enabled)
            await coordinator.setPreferred(preferred)
        }
        updateAudioMode()
        showOverlay()
    }

    // MARK: Settings hooks

    func settingsDidChange(from old: VelaSettings, to new: VelaSettings) {
        pushVisualInputs()
        if old.localAlignment != new.localAlignment {
            alignment.stop()
            if case .ready(let box) = lyrics, let track { beginAlignment(for: track, document: box.document) }
        }
        if old.preferredSource != new.preferredSource {
            if new.preferredSource == .demo {
                setDemoMode(true)
            } else if isDemoMode, old.preferredSource == .demo {
                setDemoMode(false)
            } else if !isDemoMode {
                Task { [coordinator] in await coordinator.setPreferred(new.preferredSource.kind) }
            }
        }
        if old.launchAtLogin != new.launchAtLogin {
            if let failure = LaunchAtLogin.set(new.launchAtLogin) {
                showToast("Launch at login: \(failure)")
                settings.launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
    }

    // MARK: Overlay

    func pointerMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        if !overlayVisible {
            showOverlay()
        } else if now - lastPointerReschedule > 0.3 {
            scheduleHide()
        }
        lastPointerReschedule = now
    }

    func setOverlayHovering(_ hovering: Bool) {
        overlayHovering = hovering
        if hovering { cancelHide() } else { scheduleHide() }
    }

    func showOverlay() {
        if !overlayVisible {
            withAnimation(.easeOut(duration: 0.25)) { overlayVisible = true }
        }
        scheduleHide()
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func scheduleHide() {
        cancelHide()
        guard playback.isPlaying, !settingsVisible, !overlayHovering, !showOnboarding else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.6)) { self.overlayVisible = false }
            if self.isFullscreen { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    // MARK: Window

    func toggleFullscreen() {
        windowController.toggleFullscreen(displayID: settings.selectedDisplayID)
    }

    func exitFullscreen() {
        windowController.exitFullscreen()
    }

    func toggleSettings() {
        settingsVisible.toggle()
        if settingsVisible { showOverlay() }
    }

    // MARK: Keyboard

    /// Returns `true` when the event was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard !showOnboarding else { return false }
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty == false { return false }
        switch event.keyCode {
        case 53: // Escape
            if settingsVisible { settingsVisible = false; return true }
            if isFullscreen { exitFullscreen(); return true }
            return false
        case 49: // Space
            guard !settingsVisible else { return false }
            if overlayVisible { togglePlayPause() } else { showOverlay() }
            return true
        case 123: // Left
            guard !settingsVisible, capabilities.canSeek else { return false }
            seek(by: -5)
            return true
        case 124: // Right
            guard !settingsVisible, capabilities.canSeek else { return false }
            seek(by: 5)
            return true
        case 33: // [
            guard !settingsVisible else { return false }
            nudgeLyricsOffset(by: -LyricTiming.nudgeStep)
            return true
        case 30: // ]
            guard !settingsVisible else { return false }
            nudgeLyricsOffset(by: LyricTiming.nudgeStep)
            return true
        default:
            return false
        }
    }

    // MARK: Onboarding & permissions

    func completeOnboarding(startDemo: Bool) {
        settings.onboardingComplete = true
        withAnimation(.easeInOut(duration: 0.5)) { showOnboarding = false }
        if startDemo { setDemoMode(true) } else if isDemoMode { setDemoMode(false) }
        showOverlay()
    }

    func reopenOnboarding() {
        settingsVisible = false
        withAnimation { showOnboarding = true }
    }

    func requestAudioPermission() {
        let granted = audio.requestPermission()
        if granted { audio.retry() }
    }

    struct AutomationReport: Identifiable {
        var kind: MusicSourceKind
        var status: AutomationPermission.Status
        var id: String { kind.rawValue }
    }

    /// Checks (and optionally prompts for) automation permission for each running player.
    func checkAutomationPermissions(prompt: Bool) -> [AutomationReport] {
        [MusicSourceKind.spotify, .appleMusic].map { kind in
            AutomationReport(kind: kind, status: AutomationPermission.status(for: kind.bundleIdentifier!, askIfNeeded: prompt))
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: User-supplied provider keys

    /// Stores the key in the login keychain and checks it against Musixmatch straight away, so
    /// nobody is left wondering whether it took.
    func saveMusixmatchKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard KeychainStore.set(trimmed, account: MusixmatchProvider.keychainAccount) else {
            musixmatchStatus = "Could not write to the keychain."
            return
        }
        musixmatchKeyHint = KeychainStore.redacted(trimmed)
        checkMusixmatchKey()
    }

    func removeMusixmatchKey() {
        KeychainStore.remove(account: MusixmatchProvider.keychainAccount)
        musixmatchKeyHint = ""
        musixmatchStatus = nil
    }

    func checkMusixmatchKey() {
        guard let key = KeychainStore.get(account: MusixmatchProvider.keychainAccount) else {
            musixmatchStatus = "No key stored."
            return
        }
        isCheckingMusixmatchKey = true
        musixmatchStatus = nil
        Task { [weak self] in
            let failure = await MusixmatchProvider().validate(key: key)
            guard let self else { return }
            self.isCheckingMusixmatchKey = false
            self.musixmatchStatus = failure ?? "Key accepted."
            if failure == nil, let track = self.track {
                // Re-resolve so the current song can pick up word-level lyrics immediately.
                await self.lyricsService.forget(track: track)
                self.retryLyrics()
            }
        }
    }

    // MARK: Lyrics management

    func importLyricsFile() {
        guard let track else { showToast("Play a track first, then import lyrics for it."); return }
        let panel = NSOpenPanel()
        panel.title = "Import lyrics for \(track.title)"
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let doc = try await self.lyricsService.importLyrics(from: url, for: track)
                guard self.track?.identityKey == track.identityKey else { return }
                withAnimation { self.lyrics = .ready(LyricTimelineBox(document: doc)) }
                self.showToast("Imported lyrics (\(doc.quality == .unsynced ? "unsynced" : doc.quality == .wordSynced ? "word-synced" : "line-synced")).")
            } catch {
                self.showToast("Couldn't read that file as lyrics.")
            }
        }
    }

    func retryLyrics() {
        guard let track else { return }
        Task { [weak self] in
            await self?.lyricsService.forget(track: track)
            self?.trackDidChange(to: nil)
            self?.trackDidChange(to: track)
        }
    }

    func clearLyricsCache() {
        Task { [weak self] in
            await self?.lyricsService.clearCache()
            self?.showToast("Cached lyrics cleared.")
        }
    }

    // MARK: Demo fixtures

    /// Jumps Demo Mode to a catalogue track (enabling Demo Mode if needed).
    func selectDemoTrack(id: String) {
        if !isDemoMode { setDemoMode(true) }
        Task { [demoSource, coordinator] in
            await demoSource.jump(toTrackID: id)
            await coordinator.wake()
        }
        showOverlay()
    }

    /// Cycles through one representative demo track per visual profile.
    func nextDemoFixture() {
        let fixtures = DemoCatalog.profileFixtures
        guard !fixtures.isEmpty else { return }
        let currentIndex = fixtures.firstIndex { $0.id == track?.id } ?? -1
        let next = fixtures[(currentIndex + 1) % fixtures.count]
        selectDemoTrack(id: next.id)
    }

    // MARK: Visual profile actions

    func cycleVisualProfile() {
        let all = VisualProfileSelection.allCases
        let index = all.firstIndex(of: settings.visualProfile) ?? 0
        settings.visualProfile = all[(index + 1) % all.count]
        showToast("Visual profile: \(settings.visualProfile.displayName)")
    }

    /// Plays a deterministic simulation of `profile` over the current scene without touching playback.
    func startPreview(_ profile: VisualProfile) {
        previewProfile = profile
        director.startPreview(profile: profile, duration: 10)
    }

    func stopPreview() {
        previewProfile = nil
        director.stopPreview()
    }

    // MARK: Scene geometry

    var sceneGeometry: SceneGeometry {
        SceneGeometry(cornerRadius: windowController.contentCornerRadius, notchRect: windowController.notchRect())
    }
}

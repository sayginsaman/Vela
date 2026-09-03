import SwiftUI
import Observation
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

    init(document: LyricDocument) {
        self.document = document
        timeline = LyricTimeline(document: document)
        sungLines = timeline.sungLines
        var map: [Int: Int] = [:]
        for (index, line) in sungLines.enumerated() { map[line.id] = index }
        sungIndexByLineID = map
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
    private(set) var extractedPalette: Palette = .fallback
    private(set) var lyrics: LyricsState = .idle
    private(set) var transitionID = 0
    private(set) var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

    // MARK: UI state
    var isFullscreen = false
    private(set) var overlayVisible = true
    private(set) var overlayHovering = false
    var settingsVisible = false { didSet { if settingsVisible { cancelHide() } else { scheduleHide() } } }
    var showOnboarding: Bool
    private(set) var toast: String?

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

    /// Tempo used by the demo audio simulator.
    private var currentBPM: Double {
        guard let track, track.source == .demo, let demo = DemoCatalog.track(withID: track.id) else { return 100 }
        return demo.bpm
    }

    var lyricsQualityDescription: String? {
        guard case .ready(let box) = lyrics else { return nil }
        switch box.document.quality {
        case .wordSynced: return "Word-synced"
        case .lineSynced: return "Line-synced · words estimated"
        case .estimated: return "Estimated timing"
        case .unsynced: return "Unsynced"
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        guard !Self.isRunningTests else { return }
        installKeyMonitor()
        NotificationCenter.default.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
        }
        if isDemoMode { Task { await demoSource.setEnabled(true) } }
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
        audio.updateClock(clock, bpm: currentBPM)
        updateAudioMode()
        if wasPlaying != snapshot.isPlaying {
            if snapshot.isPlaying { scheduleHide() } else { showOverlay() }
        }
    }

    private func trackDidChange(to newTrack: TrackInfo?) {
        lyricsTask?.cancel()
        artworkTask?.cancel()
        track = newTrack
        transitionID &+= 1
        guard let newTrack else {
            withAnimation(.easeInOut(duration: 1.0)) {
                artwork = nil
                backdrop = nil
                extractedPalette = .fallback
            }
            lyrics = .idle
            return
        }
        lyrics = .loading
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let image = try? await self.coordinator.artwork(for: newTrack)
            guard !Task.isCancelled else { return }
            let output = await ArtworkProcessor.process(image)
            guard !Task.isCancelled, self.track?.identityKey == newTrack.identityKey else { return }
            withAnimation(.easeInOut(duration: 1.2)) {
                self.artwork = image
                self.backdrop = output.backdrop
                self.extractedPalette = output.palette
            }
        }
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.lyricsService.resolve(track: newTrack)
            guard !Task.isCancelled, self.track?.identityKey == newTrack.identityKey else { return }
            VelaLog.lyrics.info("lyrics for \(newTrack.title, privacy: .public): \(String(describing: outcome).prefix(60), privacy: .public)")
            withAnimation(.easeInOut(duration: 0.5)) {
                switch outcome {
                case .found(let doc): self.lyrics = .ready(LyricTimelineBox(document: doc))
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
        audio.updateClock(clock, bpm: currentBPM)
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

    // MARK: Glow parameters

    func glowParameters(reduceMotion: Bool) -> GlowParameters {
        let s = settings
        let base = 64.0 * s.glowThickness
        return GlowParameters(gradient: palette.gradient,
                              thickness: base,
                              intensity: s.glowIntensity * (s.reduceEffects ? 0.65 : 1),
                              spread: s.glowSpread,
                              reactiveMotion: s.reactiveMotion && !s.reduceEffects,
                              reduceMotion: reduceMotion,
                              cornerRadius: windowController.contentCornerRadius,
                              notchRect: windowController.notchRect(),
                              breathing: audio.status != .capturing)
    }
}

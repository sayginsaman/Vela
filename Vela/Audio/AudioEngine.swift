import Foundation
import Observation
import CoreGraphics
import os

/// Owns whichever producer feeds `AudioLevelStore`: ScreenCaptureKit for real playback, the
/// deterministic simulator in Demo Mode, or nothing (the renderers then "breathe").
@MainActor
@Observable
final class AudioEngine {
    enum Mode: Equatable { case off, system, demo }

    private(set) var mode: Mode = .off
    private(set) var status: AudioCaptureStatus = .idle
    let store = AudioLevelStore()

    @ObservationIgnored private var capture: SystemAudioCapture?
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private let clockBox = ClockBox()
    @ObservationIgnored private var startingTask: Task<Void, Never>?

    /// Shared with the demo simulator so it can follow seeks and pauses without hopping actors.
    final class ClockBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (clock: PlaybackClock(), bpm: 100.0))
        func update(clock: PlaybackClock, bpm: Double) { lock.withLock { $0 = (clock, bpm) } }
        func read() -> (clock: PlaybackClock, bpm: Double) { lock.withLock { $0 } }
    }

    var hasPermission: Bool { SystemAudioCapture.hasPermission }

    /// macOS offers no public way to tell "never asked" from "denied" for Screen Recording, so
    /// Vela remembers whether it has prompted before.
    private static let requestedKey = "app.vela.audioPermissionRequested"
    private var hasRequestedPermission: Bool {
        get { UserDefaults.standard.bool(forKey: Self.requestedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.requestedKey) }
    }

    /// Prompts for Screen Recording (system audio) access. Returns `true` when already granted.
    @discardableResult
    func requestPermission() -> Bool {
        hasRequestedPermission = true
        let granted = SystemAudioCapture.requestPermission()
        if !granted { status = .denied }
        return granted
    }

    func updateClock(_ clock: PlaybackClock, bpm: Double) {
        clockBox.update(clock: clock, bpm: bpm)
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else {
            // Permission can be granted in System Settings while Vela runs: pick it up on the next poll.
            if newMode == .system, capture == nil, startingTask == nil,
               status == .denied || status == .notDetermined || status == .idle,
               SystemAudioCapture.hasPermission {
                startSystemCapture()
            }
            return
        }
        stopCurrent()
        mode = newMode
        switch newMode {
        case .off:
            status = .idle
        case .demo:
            status = .capturing
            startDemo()
        case .system:
            startSystemCapture()
        }
    }

    private func stopCurrent() {
        demoTask?.cancel(); demoTask = nil
        startingTask?.cancel(); startingTask = nil
        if let capture {
            self.capture = nil
            Task { await capture.stop() }
        }
        store.markInactive()
    }

    private func startDemo() {
        let box = clockBox
        let store = store
        demoTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let (clock, bpm) = box.read()
                let now = Date()
                let bands = DemoAudioSimulator(bpm: bpm).bands(at: clock.position(at: now), playing: clock.isRunning)
                store.publish(bands)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func startSystemCapture() {
        guard SystemAudioCapture.hasPermission else {
            status = hasRequestedPermission ? .denied : .notDetermined
            return
        }
        status = .starting
        let capture = SystemAudioCapture(store: store)
        self.capture = capture
        startingTask = Task { [weak self] in
            do {
                try await capture.start { message in
                    Task { @MainActor [weak self] in
                        guard let self, self.capture === capture else { return }
                        self.capture = nil
                        self.status = .failed(message)
                    }
                }
                guard let self, !Task.isCancelled else { await capture.stop(); return }
                self.status = .capturing
            } catch {
                guard let self else { return }
                self.capture = nil
                let text = "\(error)"
                self.status = text.localizedCaseInsensitiveContains("declined") || text.contains("-3801") ? .denied : .failed(error.localizedDescription)
            }
            self?.startingTask = nil
        }
    }

    /// Re-attempts system capture after the user changed permission.
    func retry() {
        guard mode == .system else { return }
        stopCurrent()
        startSystemCapture()
    }
}

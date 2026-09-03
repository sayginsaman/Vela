import Foundation
import Observation
import CoreGraphics
import os

/// Owns whichever producer feeds `FeatureStore`: ScreenCaptureKit for real playback, the
/// deterministic fixture producer in Demo Mode, or nothing (the renderers then "breathe").
@MainActor
@Observable
final class AudioEngine {
    enum Mode: Equatable { case off, system, demo }

    private(set) var mode: Mode = .off
    private(set) var status: AudioCaptureStatus = .idle
    let store = FeatureStore()

    @ObservationIgnored private var capture: SystemAudioCapture?
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private let clockBox = ClockBox()
    @ObservationIgnored private var startingTask: Task<Void, Never>?

    /// Shared with the demo producer so it follows seeks, pauses and fixture changes.
    final class ClockBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (clock: PlaybackClock(), fixture: ProfileFixture(profile: .pop)))
        func update(clock: PlaybackClock, fixture: ProfileFixture) { lock.withLock { $0 = (clock, fixture) } }
        func read() -> (clock: PlaybackClock, fixture: ProfileFixture) { lock.withLock { $0 } }
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

    func updateClock(_ clock: PlaybackClock, fixture: ProfileFixture) {
        clockBox.update(clock: clock, fixture: fixture)
    }

    /// Forgets rhythm history on both producers (track change).
    func resetAnalysis() {
        store.requestReset()
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
            var producer = DemoFeatureProducer(fixture: box.read().fixture)
            var generation = store.resetGeneration
            let interval = 1.0 / FeatureExtractor.gridRate
            while !Task.isCancelled {
                let (clock, fixture) = box.read()
                producer.setFixture(fixture)
                let current = store.resetGeneration
                if current != generation { generation = current; producer.reset() }
                let now = Date()
                store.publish(producer.produce(position: clock.position(at: now), playing: clock.isRunning))
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
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

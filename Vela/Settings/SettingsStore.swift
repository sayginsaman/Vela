import Foundation
import Observation

/// Typed, observable settings persisted to `UserDefaults` as JSON.
@MainActor
@Observable
final class SettingsStore {
    static let storageKey = "app.vela.settings.v1"

    var settings: VelaSettings {
        didSet {
            let normalized = settings.normalized()
            if normalized != settings { settings = normalized; return }
            if settings != oldValue, isPersistenceEnabled { persist() }
        }
    }

    /// Off during scripted screenshot runs so capture-time tweaks never reach disk.
    @ObservationIgnored var isPersistenceEnabled = true

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(VelaSettings.self, from: data) {
            settings = decoded.normalized()
        } else {
            settings = VelaSettings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func reset() {
        var fresh = VelaSettings()
        fresh.onboardingComplete = settings.onboardingComplete
        settings = fresh
    }
}

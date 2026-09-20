import XCTest
@testable import Vela

final class SettingsStoreTests: XCTestCase {
    /// `removePersistentDomain` leaves an empty plist behind; delete it so test runs stay tidy.
    static func removePlist(_ suite: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: url)
    }

    @MainActor
    func testPersistsAcrossInstances() {
        let suite = "app.vela.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); Self.removePlist(suite) }

        let store = SettingsStore(defaults: defaults)
        store.settings.lyricStyle = .bloom
        store.settings.sceneLayout = .split
        store.settings.lyricsOffset = 1.25
        store.settings.glowIntensity = 1.2
        store.settings.onboardingComplete = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings.lyricStyle, .bloom)
        XCTAssertEqual(reloaded.settings.sceneLayout, .split)
        XCTAssertEqual(reloaded.settings.lyricsOffset, 1.25)
        XCTAssertEqual(reloaded.settings.glowIntensity, 1.2)
        XCTAssertTrue(reloaded.settings.onboardingComplete)
    }

    @MainActor
    func testSettingsFromAnOlderVersionStillLoad() {
        // A payload written before the newer keys existed must decode with sensible defaults.
        let suite = "app.vela.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); Self.removePlist(suite) }
        let legacy = #"{"lyricSize":1.2,"glowIntensity":0.8,"onboardingComplete":true}"#
        defaults.set(Data(legacy.utf8), forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings.lyricSize, 1.2)
        XCTAssertTrue(store.settings.onboardingComplete)
        XCTAssertEqual(store.settings.sceneLayout, .centered)
        XCTAssertEqual(store.settings.lyricStyle, .stack, "the stack style is adopted once")
        XCTAssertTrue(store.settings.wordIcons)
        XCTAssertTrue(store.settings.compensateOutputLatency)
    }

    @MainActor
    func testValuesAreClamped() {
        let suite = "app.vela.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); Self.removePlist(suite) }
        let store = SettingsStore(defaults: defaults)
        store.settings.lyricsOffset = 12
        XCTAssertEqual(store.settings.lyricsOffset, 5)
        store.settings.lyricSize = 0.1
        XCTAssertEqual(store.settings.lyricSize, VelaSettings.lyricSizeRange.lowerBound)
    }
}

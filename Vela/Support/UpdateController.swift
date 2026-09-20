import Foundation
import Observation
import Sparkle

/// In-app updates through Sparkle. The feed is the appcast in the repository; every entry is
/// signed with the EdDSA key whose public half is in Info.plist, so only releases produced by
/// the release script are ever installed.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    private(set) var isAvailable = false
    private(set) var canCheck = false
    private(set) var lastCheck: Date?
    private(set) var lastError: String?

    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    override init() {
        super.init()
        // Test hosts and screenshot runs never talk to the update feed.
        guard !AppModel.isRunningTests, ProcessInfo.processInfo.environment["VELA_SCREENSHOT_PATH"] == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        isAvailable = true
        canCheck = controller.updater.canCheckForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        lastError = nil
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.lastCheck = Date()
            self?.canCheck = updater.canCheckForUpdates
            if let error, (error as NSError).code != Int(Sparkle.SUError.noUpdateError.rawValue) {
                self?.lastError = error.localizedDescription
            }
        }
    }
}

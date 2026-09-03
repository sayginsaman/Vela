import Foundation
import AppKit

/// Executes AppleScript on a private serial queue so player queries never block the main thread.
///
/// Each invocation compiles its own `NSAppleScript` instance on the queue; instances are never
/// shared across threads. Error codes from the Apple Event Manager are mapped onto
/// `MusicSourceError` so callers can react to missing permission or a quit player.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()

    enum Result: Sendable {
        case text(String)
        case data(Data)
        case empty
    }

    private let queue = DispatchQueue(label: "app.vela.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]

    func run(_ source: String) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let script: NSAppleScript
                if let cached = self.compiled[source] {
                    script = cached
                } else {
                    guard let fresh = NSAppleScript(source: source) else {
                        continuation.resume(throwing: MusicSourceError.scriptFailed("Could not create script"))
                        return
                    }
                    self.compiled[source] = fresh
                    script = fresh
                }
                var errorInfo: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    continuation.resume(throwing: Self.mapError(errorInfo))
                    return
                }
                continuation.resume(returning: Self.result(from: descriptor))
            }
        }
    }

    private static func result(from descriptor: NSAppleEventDescriptor) -> Result {
        if let string = descriptor.stringValue, descriptor.descriptorType != typeType {
            return .text(string)
        }
        if let data = descriptor.data as Data?, !data.isEmpty, descriptor.descriptorType != typeNull {
            return .data(data)
        }
        return .empty
    }

    static func mapError(_ info: NSDictionary) -> MusicSourceError {
        let number = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(number)"
        VelaLog.sources.error("AppleScript error \(number, privacy: .public): \(message, privacy: .public)")
        switch number {
        case -1743, -10004:
            return .permissionDenied
        case -600, -609, -10814:
            return .notRunning
        default:
            return .scriptFailed(message)
        }
    }
}

/// Automation (Apple Events) permission state for a player, checked with the public
/// `AEDeterminePermissionToAutomateTarget` API.
enum AutomationPermission {
    enum Status: Sendable { case granted, denied, notDetermined, notRunning }

    static func status(for bundleIdentifier: String, askIfNeeded: Bool) -> Status {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            return .notRunning
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, askIfNeeded)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .notRunning
        default: return .denied
        }
    }
}

extension NSRunningApplication {
    static func isRunning(bundleIdentifier: String) -> Bool {
        !runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}

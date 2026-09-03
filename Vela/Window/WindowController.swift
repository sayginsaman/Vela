import AppKit
import SwiftUI

/// Bridges the SwiftUI window to AppKit for fullscreen, display selection and notch geometry.
@MainActor
final class WindowController: NSObject {
    private(set) weak var window: NSWindow?
    var onFullscreenChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 720, height: 460)
        window.appearance = NSAppearance(named: .darkAqua)

        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onFullscreenChange?(true) }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onFullscreenChange?(false) }
            },
        ]
        onFullscreenChange?(isFullscreen)
    }

    var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func toggleFullscreen(displayID: String?) {
        guard let window else { return }
        if !isFullscreen, let target = Self.screen(for: displayID), window.screen != target {
            let frame = target.visibleFrame
            let size = NSSize(width: min(window.frame.width, frame.width), height: min(window.frame.height, frame.height))
            let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        window.toggleFullScreen(nil)
    }

    func exitFullscreen() {
        guard let window, isFullscreen else { return }
        window.toggleFullScreen(nil)
    }

    // MARK: Displays

    struct DisplayOption: Identifiable, Hashable {
        var id: String
        var name: String
    }

    static func availableDisplays() -> [DisplayOption] {
        NSScreen.screens.map { screen in
            DisplayOption(id: Self.identifier(for: screen), name: screen.localizedName)
        }
    }

    static func identifier(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { String($0.intValue) } ?? screen.localizedName
    }

    static func screen(for id: String?) -> NSScreen? {
        guard let id else { return nil }
        return NSScreen.screens.first { identifier(for: $0) == id }
    }

    // MARK: Geometry

    /// Rounded corner radius of the visible content: display corners in fullscreen on notched
    /// Macs, the standard window radius when windowed.
    var contentCornerRadius: Double {
        guard let window else { return 0 }
        if isFullscreen {
            let inset = window.screen?.safeAreaInsets.top ?? 0
            return inset > 0 ? 12 : 0
        }
        return 10
    }

    /// The camera housing, expressed in the window's content coordinates (top-left origin), when
    /// the window covers that part of the screen; `.zero` otherwise.
    func notchRect() -> CGRect {
        guard let window, let screen = window.screen else { return .zero }
        let insets = screen.safeAreaInsets
        guard insets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return .zero }
        let frame = window.frame
        let bandBottom = screen.frame.maxY - insets.top
        guard frame.maxY > bandBottom + 0.5 else { return .zero }
        let x = left.maxX - frame.minX
        let width = right.minX - left.maxX
        let height = min(insets.top, frame.maxY - bandBottom)
        guard width > 0, height > 0 else { return .zero }
        return CGRect(x: x, y: 0, width: width, height: height)
    }
}

/// Grabs the hosting `NSWindow` for a SwiftUI hierarchy.
struct WindowAccessor: NSViewRepresentable {
    let controller: WindowController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { controller.attach(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window, controller.window !== window {
            DispatchQueue.main.async { controller.attach(window) }
        }
    }
}

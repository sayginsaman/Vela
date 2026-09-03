import SwiftUI

@main
struct VelaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Vela") {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.toggleSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Playback") {
                Button(model.clock.isRunning ? "Pause" : "Play") { model.togglePlayPause() }
                    .disabled(model.track == nil)
                Button("Next Track") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!model.capabilities.canSkip)
                Button("Previous Track") { model.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!model.capabilities.canSkip)
                Divider()
                Button(model.isDemoMode ? "Leave Demo Mode" : "Enter Demo Mode") { model.toggleDemoMode() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Import Lyrics File…") { model.importLyricsFile() }
                    .disabled(model.track == nil)
            }
            CommandGroup(after: .toolbar) {
                // AppKit already offers "Enter Full Screen" (⌃⌘F) in this menu; this adds the ⌘F alias.
                Button("Toggle Full Screen") { model.toggleFullscreen() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Show Controls") { model.showOverlay() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

/// Window root: scene plus onboarding, and the AppKit bridges.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            SceneView()
            if model.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .background(WindowAccessor(controller: model.windowController))
        .onAppear { model.start() }
        .onChange(of: model.settings) { old, new in model.settingsDidChange(from: old, to: new) }
        .animation(.easeInOut(duration: 0.4), value: model.showOnboarding)
    }
}

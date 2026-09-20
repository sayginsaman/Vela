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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updates.checkForUpdates() }
                    .disabled(!model.updates.canCheck)
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
                Button("Next Demo Fixture") { model.nextDemoFixture() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Import Lyrics File…") { model.importLyricsFile() }
                    .disabled(model.track == nil)
                Divider()
                Button("Lyrics Earlier") { model.nudgeLyricsOffset(by: LyricTiming.nudgeStep) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Lyrics Later") { model.nudgeLyricsOffset(by: -LyricTiming.nudgeStep) }
                    .keyboardShortcut("[", modifiers: .command)
            }
            CommandMenu("Visual") {
                Picker("Profile", selection: Binding(get: { model.settings.visualProfile }, set: { model.settings.visualProfile = $0 })) {
                    ForEach(VisualProfileSelection.allCases) { Text($0.displayName).tag($0) }
                }
                Button("Cycle Visual Profile") { model.cycleVisualProfile() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Menu("Preview Profile") {
                    ForEach(VisualProfile.allCases) { profile in
                        Button(profile.displayName) { model.startPreview(profile) }
                    }
                }
                Button("Stop Preview") { model.stopPreview() }
                    .disabled(model.previewProfile == nil)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SceneView()
            if model.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .background(WindowAccessor(controller: model.windowController))
        .onAppear { model.start(); model.setReduceMotion(reduceMotion) }
        .onChange(of: reduceMotion) { _, new in model.setReduceMotion(new) }
        .onChange(of: model.settings) { old, new in model.settingsDidChange(from: old, to: new) }
        .animation(.easeInOut(duration: 0.4), value: model.showOnboarding)
    }
}

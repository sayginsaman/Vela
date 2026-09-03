import SwiftUI

/// Four-step welcome: what Vela is, the two permissions it uses, and how to start.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var automation: [AppModel.AutomationReport] = []
    @State private var audioChecked = false

    private let pageCount = 4

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(page)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: reduceMotion ? 0 : 24)),
                                            removal: .opacity.combined(with: .offset(x: reduceMotion ? 0 : -24))))
                footer
            }
            .padding(36)
            .frame(width: 560, height: 460)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black.opacity(0.4)))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .shadow(color: .black.opacity(0.5), radius: 50, y: 24)
            )
            .environment(\.colorScheme, .dark)
            .animation(.easeInOut(duration: 0.3), value: page)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Vela")
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: welcome
        case 1: automationPage
        case 2: audioPage
        default: finish
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Vela")
                .font(.system(size: 52, weight: .bold)).kerning(-1.5)
                .foregroundStyle(LinearGradient(colors: [model.palette.highlight.swiftUIColor, model.palette.glow.swiftUIColor], startPoint: .leading, endPoint: .trailing))
            Text("Lyrics and light for whatever is playing.")
                .font(.system(size: 20, weight: .medium))
            Text("Vela turns your Mac into a stage: synchronized lyrics highlighted word by word, colours pulled from the album art, and an ambient glow around the edges of the display that follows the music. Play something in Spotify or Apple Music, go full screen, and let it run.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var automationPage: some View {
        PermissionPage(symbol: "music.note.list", title: "Reading what's playing",
                       text: "Vela asks Spotify and Apple Music for the current track, position and artwork, and sends play, pause and skip on your behalf. This uses macOS Automation — the system will show a one-time prompt per app. Nothing else on your Mac is touched.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(automation) { report in
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: report.status)).foregroundStyle(color(for: report.status))
                        Text("\(report.kind.displayName): \(text(for: report.status))").font(.system(size: 12))
                    }
                }
                Button("Check access now") { automation = model.checkAutomationPermissions(prompt: true) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .onAppear { automation = model.checkAutomationPermissions(prompt: false) }
        }
    }

    private var audioPage: some View {
        PermissionPage(symbol: "waveform.badge.magnifyingglass", title: "Feeling the music",
                       text: "To make the edge light react to bass and loudness, Vela listens to the audio your Mac is playing through ScreenCaptureKit. macOS files this under Screen Recording. Audio is analysed on this Mac and never stored; the microphone is never used. Without it, the light simply breathes on its own.") {
            HStack(spacing: 10) {
                if model.audio.hasPermission {
                    Label("System audio allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                } else if audioChecked {
                    Label("If you allowed it, you may need to relaunch Vela. Otherwise enable Vela under Screen & System Audio Recording.", systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Open System Settings") { model.openScreenRecordingSettings() }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Allow system audio") { model.requestAudioPermission(); audioChecked = true }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Skip for now") { page += 1 }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 34, weight: .light)).foregroundStyle(model.palette.highlight.swiftUIColor)
            Text("Ready when you are").font(.system(size: 30, weight: .bold)).kerning(-0.5)
            Text("Press ⌘F for full screen. Move the pointer to reveal controls, Space to play or pause, arrows to seek, ⌘, for settings and ⌘⇧D to toggle Demo Mode at any time.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Try Demo") { model.completeOnboarding(startDemo: true) }
                    .buttonStyle(PillButtonStyle(prominent: true, tint: model.palette.highlight.swiftUIColor))
                    .keyboardShortcut(.defaultAction)
                Button("Start Listening") { model.completeOnboarding(startDemo: false) }
                    .buttonStyle(PillButtonStyle(prominent: false, tint: model.palette.highlight.swiftUIColor))
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule().fill(Color.white.opacity(index == page ? 0.9 : 0.25))
                        .frame(width: index == page ? 18 : 6, height: 6)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: page)
            .accessibilityLabel("Step \(page + 1) of \(pageCount)")
            Spacer()
            if page > 0 {
                Button("Back") { page -= 1 }.buttonStyle(.bordered).controlSize(.small)
            }
            if page < pageCount - 1 {
                Button("Continue") { page += 1 }.buttonStyle(.borderedProminent).controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func icon(for status: AutomationPermission.Status) -> String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle"
        case .notRunning: return "circle.dashed"
        }
    }

    private func color(for status: AutomationPermission.Status) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    private func text(for status: AutomationPermission.Status) -> String {
        switch status {
        case .granted: return "allowed"
        case .denied: return "blocked — fix in System Settings › Privacy & Security › Automation"
        case .notDetermined: return "will ask when first used"
        case .notRunning: return "not running (open it to check)"
        }
    }
}

private struct PermissionPage<Extra: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.9))
            Text(title).font(.system(size: 28, weight: .bold)).kerning(-0.5)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            extra().padding(.top, 4)
            Spacer()
        }
    }
}

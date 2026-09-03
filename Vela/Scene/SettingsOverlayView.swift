import SwiftUI

/// Compact translucent settings panel shown over the scene.
struct SettingsOverlayView: View {
    @Environment(AppModel.self) private var model
    @State private var automation: [AppModel.AutomationReport] = []
    @State private var displays = WindowController.availableDisplays()

    var body: some View {
        @Bindable var model = model
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { model.settingsVisible = false }
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08))
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        lyricsSection(model: $model)
                        lightSection(model: $model)
                        playbackSection(model: $model)
                        permissionsSection
                        footer
                    }
                    .padding(22)
                }
            }
            .frame(width: 480)
            .frame(maxHeight: 640)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
            )
            .environment(\.colorScheme, .dark)
            .onHover { model.setOverlayHovering($0) }
        }
        .onAppear { automation = model.checkAutomationPermissions(prompt: false); displays = WindowController.availableDisplays() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private var header: some View {
        HStack {
            Text("Settings").font(.system(size: 15, weight: .semibold))
            Spacer()
            Button { model.settingsVisible = false } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                .buttonStyle(GlyphButtonStyle(size: 28))
                .accessibilityLabel("Close settings")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: Sections

    private func lyricsSection(model: Bindable<AppModel>) -> some View {
        SettingsSection(title: "Lyrics") {
            Picker("Style", selection: model.settings.lyricStyle) {
                ForEach(LyricStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(self.model.settings.lyricStyle.summary)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            SliderRow(title: "Size", value: model.settings.lyricSize, range: VelaSettings.lyricSizeRange, format: { String(format: "%.0f%%", $0 * 100) })
            SliderRow(title: "Timing offset", value: model.settings.lyricsOffset, range: VelaSettings.offsetRange, step: 0.1,
                      format: { TimeFormatting.offset($0) }, reset: { self.model.settings.lyricsOffset = 0 })
            Text("Negative shows lyrics later, positive earlier.").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Import .lrc for this track…") { self.model.importLyricsFile() }
                    .disabled(self.model.track == nil)
                Button("Clear cached lyrics") { self.model.clearLyricsCache() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func lightSection(model: Bindable<AppModel>) -> some View {
        SettingsSection(title: "Ambient light") {
            Picker("Palette", selection: model.settings.paletteMode) {
                ForEach(PaletteMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if self.model.settings.paletteMode == .manual {
                HStack(spacing: 18) {
                    ColorRow(title: "Highlight", color: model.settings.manualHighlight)
                    ColorRow(title: "Glow", color: model.settings.manualGlow)
                    ColorRow(title: "Background", color: model.settings.manualBackground)
                }
            }
            SliderRow(title: "Thickness", value: model.settings.glowThickness, range: VelaSettings.glowThicknessRange, format: { String(format: "%.1f×", $0) })
            SliderRow(title: "Intensity", value: model.settings.glowIntensity, range: VelaSettings.glowIntensityRange, format: { String(format: "%.0f%%", $0 * 100) })
            SliderRow(title: "Blur / spread", value: model.settings.glowSpread, range: VelaSettings.glowSpreadRange, format: { String(format: "%.1f×", $0) })
            Toggle("React to music", isOn: model.settings.reactiveMotion)
            Toggle("Reduce visual effects", isOn: model.settings.reduceEffects)
        }
    }

    private func playbackSection(model: Bindable<AppModel>) -> some View {
        SettingsSection(title: "Playback") {
            LabeledContent("Music source") {
                Picker("Music source", selection: model.settings.preferredSource) {
                    ForEach(PreferredSource.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            LabeledContent("Full-screen display") {
                Picker("Display", selection: Binding(
                    get: { self.model.settings.selectedDisplayID ?? "" },
                    set: { self.model.settings.selectedDisplayID = $0.isEmpty ? nil : $0 })) {
                    Text("Window's display").tag("")
                    ForEach(displays) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Toggle("Launch Vela at login", isOn: model.settings.launchAtLogin)
            Toggle("Demo Mode  (⌘⇧D)", isOn: Binding(get: { self.model.isDemoMode }, set: { self.model.setDemoMode($0) }))
        }
    }

    private var permissionsSection: some View {
        SettingsSection(title: "Permissions") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("System audio").font(.system(size: 12, weight: .semibold))
                    Text(audioStatusText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                switch model.audio.status {
                case .capturing:
                    Label("Active", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                case .denied:
                    Button("Open System Settings") { model.openScreenRecordingSettings() }.controlSize(.small)
                default:
                    Button("Allow") { model.requestAudioPermission() }.controlSize(.small)
                }
            }
            ForEach(automation) { report in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(report.kind.displayName) automation").font(.system(size: 12, weight: .semibold))
                        Text(automationText(report.status)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch report.status {
                    case .granted: Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                    case .denied: Button("Open System Settings") { model.openAutomationSettings() }.controlSize(.small)
                    case .notDetermined: Button("Allow") { automation = model.checkAutomationPermissions(prompt: true) }.controlSize(.small)
                    case .notRunning: Text("Not running").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Show welcome again") { model.reopenOnboarding() }.buttonStyle(.link).font(.system(size: 11))
            Spacer()
            Button("Reset settings") { model.settingsStore.reset() }.buttonStyle(.link).font(.system(size: 11))
        }
    }

    private var audioStatusText: String {
        switch model.audio.status {
        case .capturing: return "Listening to system output. The microphone is never used."
        case .denied: return "Screen Recording access is off, so the light breathes on its own."
        case .starting: return "Starting capture…"
        case .failed(let message): return "Capture stopped: \(message)"
        case .notDetermined, .idle: return "Allow Screen Recording so the light can follow the music."
        }
    }

    private func automationText(_ status: AutomationPermission.Status) -> String {
        switch status {
        case .granted: return "Vela can read playback and send transport commands."
        case .denied: return "Blocked in Privacy & Security › Automation."
        case .notDetermined: return "macOS will ask the first time Vela talks to the app."
        case .notRunning: return "Open the app to check its permission."
        }
    }
}

// MARK: - Pieces

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    var reset: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).frame(width: 96, alignment: .leading)
            if let step {
                Slider(value: $value, in: range, step: step).labelsHidden()
            } else {
                Slider(value: $value, in: range).labelsHidden()
            }
            Text(format(value)).font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            if let reset {
                Button { reset() } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(GlyphButtonStyle(size: 22))
                    .accessibilityLabel("Reset \(title)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
    }
}

private struct ColorRow: View {
    let title: String
    @Binding var color: RGBColor

    var body: some View {
        VStack(spacing: 4) {
            ColorPicker(title, selection: Binding(
                get: { color.swiftUIColor },
                set: { newValue in
                    if let components = NSColor(newValue).usingColorSpace(.sRGB) {
                        color = RGBColor(r: components.redComponent, g: components.greenComponent, b: components.blueComponent)
                    }
                }), supportsOpacity: false)
                .labelsHidden()
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(title) colour")
    }
}

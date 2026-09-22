import SwiftUI

/// Compact translucent settings panel shown over the scene.
struct SettingsOverlayView: View {
    @Environment(AppModel.self) private var model
    @State private var automation: [AppModel.AutomationReport] = []
    @State private var displays = WindowController.availableDisplays()
    @State private var musixmatchKey = ""

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
                        visualProfileSection(model: $model)
                        lyricsSection(model: $model)
                        arrangeSection(model: $model)
                        lightSection(model: $model)
                        playbackSection(model: $model)
                        demoSection
                        keysSection
                        alignmentSection(model: $model)
                        permissionsSection
                        updatesSection
                        footer
                    }
                    .padding(22)
                }
            }
            .frame(width: 500)
            .frame(maxHeight: 700)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(self.model.reduceTransparency ? 0.92 : 0.35)))
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

    private func visualProfileSection(model: Bindable<AppModel>) -> some View {
        SettingsSection(title: "Visual profile") {
            LabeledContent("Profile") {
                Picker("Profile", selection: model.settings.visualProfile) {
                    ForEach(VisualProfileSelection.musicSelections) { Text($0.displayName).tag($0) }
                    Divider()
                    ForEach(VisualProfileSelection.lookSelections) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            Text(profileStatusText)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(self.model.effectiveProfile.summary)
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            SliderRow(title: "Reactivity", value: model.settings.reactiveIntensity, range: VelaSettings.reactionRange, format: { String(format: "%.0f%%", $0 * 100) })
            SliderRow(title: "Background", value: model.settings.backgroundReaction, range: VelaSettings.reactionRange, format: { String(format: "%.0f%%", $0 * 100) })
            SliderRow(title: "Edge light", value: model.settings.edgeReaction, range: VelaSettings.reactionRange, format: { String(format: "%.0f%%", $0 * 100) })
            SliderRow(title: "Lyric motion", value: model.settings.lyricMotionIntensity, range: VelaSettings.reactionRange, format: { String(format: "%.0f%%", $0 * 100) })
            Toggle("Particles", isOn: model.settings.particlesEnabled)
            Toggle("Reduce intense motion", isOn: model.settings.reduceIntenseMotion)
            HStack(spacing: 10) {
                if let previewing = self.model.previewProfile {
                    Label("Previewing \(previewing.displayName)…", systemImage: "eye").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Stop") { self.model.stopPreview() }.controlSize(.small)
                } else {
                    Menu("Preview profile…") {
                        ForEach(VisualProfile.genreProfiles) { profile in
                            Button(profile.displayName) { self.model.startPreview(profile) }
                        }
                        Divider()
                        ForEach(VisualProfile.lookProfiles) { profile in
                            Button(profile.displayName) { self.model.startPreview(profile) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Text("Ten-second simulation over the current scene; playback is untouched.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            DisclosureGroup("Analysis") {
                diagnosticsGrid
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var latencyText: String {
        let reading = self.model.outputLatency
        guard !reading.deviceName.isEmpty else { return "No output device reported." }
        return String(format: "%@ reports %.0f ms of output delay; lyrics are shifted to match when enabled.", reading.deviceName, reading.latency * 1000)
    }

    private var profileStatusText: String {
        let d = self.model.detection
        let detected: String
        switch d.source {
        case .pending: detected = "Auto is listening… (Pop until it settles)"
        case .genre: detected = "Auto: \(d.profile.displayName) from genre metadata"
        case .audio: detected = String(format: "Auto: %@ from audio analysis · %.0f%% confidence", d.profile.displayName, d.confidence * 100)
        case .fallback: detected = String(format: "Auto: Pop (no confident match · %.0f%%)", d.confidence * 100)
        }
        if let locked = self.model.settings.visualProfile.profile {
            return "Locked to \(locked.displayName). \(detected)"
        }
        return detected
    }

    private var diagnosticsGrid: some View {
        let f = self.model.diagnostics
        let estimate = self.model.audioEstimate
        let rows: [(String, String)] = [
            ("Audio estimate", estimate.scores.isEmpty ? "—" : String(format: "%@ · %.0f%%", estimate.best.displayName, estimate.confidence * 100)),
            ("Tempo", f.bpm > 0 ? String(format: "%.0f BPM · confidence %.0f%%", f.bpm, f.bpmConfidence * 100) : "—"),
            ("Bass / mid balance", String(format: "%.2f", f.bassToMid)),
            ("High energy", String(format: "%.2f", f.highEnergy)),
            ("Spectral centroid", String(format: "%.2f", f.spectralCentroid)),
            ("Spectral flux", String(format: "%.2f", f.spectralFlux)),
            ("Onset density", String(format: "%.1f / s", f.onsetDensity)),
            ("Transient strength", String(format: "%.2f", f.transientStrength)),
            ("Dynamic range", String(format: "%.2f", f.dynamicRange)),
            ("Loudness", String(format: "%.2f", f.averageLoudness)),
            ("Rhythmic regularity", String(format: "%.2f", f.rhythmicRegularity)),
            ("Output latency", String(format: "%.0f ms · %@", self.model.outputLatency.latency * 1000, self.model.outputLatency.deviceName.isEmpty ? "—" : self.model.outputLatency.deviceName)),
            ("Lyric time shift", String(format: "%+.2f s", self.model.lyricTimeShift)),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.tertiary)
                    Text(row.1).monospacedDigit()
                }
            }
        }
        .font(.system(size: 10.5))
        .padding(.top, 4)
    }

    private var demoSection: some View {
        SettingsSection(title: "Demo Mode") {
            LabeledContent("Demo track") {
                Picker("Demo track", selection: Binding(
                    get: { self.model.isDemoMode ? (self.model.track?.id ?? "") : "" },
                    set: { if !$0.isEmpty { self.model.selectDemoTrack(id: $0) } })) {
                    Text(self.model.isDemoMode ? "Current" : "Choose…").tag("")
                    ForEach(DemoCatalog.tracks) { track in
                        Text("\(track.title) — \(track.fixtureProfile.displayName)").tag(track.id)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            HStack {
                Button("Next fixture  (⌘⇧N)") { self.model.nextDemoFixture() }
                Toggle("Demo Mode  (⌘⇧D)", isOn: Binding(get: { self.model.isDemoMode }, set: { self.model.setDemoMode($0) }))
            }
            .controlSize(.small)
            Text("Each demo track carries an audio fixture with its own musical personality, so every profile can be judged without a player, permissions or network.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lyricsSection(model: Bindable<AppModel>) -> some View {
        SettingsSection(title: "Lyrics") {
            Picker("Layout", selection: model.settings.sceneLayout) {
                ForEach(SceneLayout.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(self.model.settings.sceneLayout.summary)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Style", selection: model.settings.lyricStyle) {
                ForEach(LyricStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(self.model.settings.lyricStyle.summary)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if self.model.settings.lyricStyle == .stack {
                Toggle("Word icons", isOn: model.settings.wordIcons)
                Text("Matched symbols appear beside words that have one.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            SliderRow(title: "Size", value: model.settings.lyricSize, range: VelaSettings.lyricSizeRange, format: { String(format: "%.0f%%", $0 * 100) })
            SliderRow(title: "Timing offset", value: model.settings.lyricsOffset, range: VelaSettings.offsetRange, step: 0.1,
                      format: { TimeFormatting.offset($0) }, reset: { self.model.settings.lyricsOffset = 0 })
            Text("Negative shows lyrics later, positive earlier. Press [ or ] any time to nudge by 0.1 s.").font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle("Compensate for output latency", isOn: model.settings.compensateOutputLatency)
            Text(latencyText).font(.system(size: 11)).foregroundStyle(.tertiary)
            HStack {
                Button("Import .lrc for this track…") { self.model.importLyricsFile() }
                    .disabled(self.model.track == nil)
                Button("Clear cached lyrics") { self.model.clearLyricsCache() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func arrangeSection(model: Bindable<AppModel>) -> some View {
        SettingsSection(title: "Position & size") {
            Text("Move the lyrics and the music panel, or change how big they are. Both positions are kept as a share of the window, so the composition holds together when you resize Vela.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Resize / Reposition…") { self.model.beginArrangingScene() }
                    .buttonStyle(.borderedProminent)
                Button("Reset") { self.model.resetArrangement() }
                    .buttonStyle(.bordered)
                    .disabled(self.model.settings.lyricArrangement.isIdentity && self.model.settings.panelArrangement.isIdentity)
            }
            .controlSize(.small)
            Text("Closes Settings and lets you drag the elements on the scene itself.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)

            Text("Lyrics").font(.system(size: 11, weight: .semibold)).padding(.top, 4)
            ArrangementRows(arrangement: model.settings.lyricArrangement)
            if self.model.settings.sceneLayout == .split {
                Text("Music panel").font(.system(size: 11, weight: .semibold)).padding(.top, 4)
                ArrangementRows(arrangement: model.settings.panelArrangement)
            }
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

    private var keysSection: some View {
        SettingsSection(title: "Word-by-word lyrics") {
            Text("Vela reads the free AMLL database first. If you have your own Musixmatch key with word-by-word (richsync) access, add it here and it will be tried before LRCLIB. The key is stored in your login keychain and used only for your lookups.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if self.model.hasMusixmatchKey {
                HStack {
                    Label(self.model.musixmatchKeyHint, systemImage: "key.fill")
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Button("Check") { self.model.checkMusixmatchKey() }
                        .controlSize(.small)
                        .disabled(self.model.isCheckingMusixmatchKey)
                    Button("Remove") { self.model.removeMusixmatchKey(); musixmatchKey = "" }
                        .controlSize(.small)
                }
            } else {
                HStack {
                    SecureField("Musixmatch API key", text: $musixmatchKey)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button("Save") { self.model.saveMusixmatchKey(musixmatchKey); musixmatchKey = "" }
                        .controlSize(.small)
                        .disabled(musixmatchKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if self.model.isCheckingMusixmatchKey {
                Text("Checking…").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else if let status = self.model.musixmatchStatus {
                Text(status).font(.system(size: 11))
                    .foregroundStyle(status == "Key accepted." ? .green : .orange)
            }
        }
    }

    private func alignmentSection(model: Bindable<AppModel>) -> some View {
        SettingsSection(title: "Local alignment") {
            Text("Vela can listen to the song through the system audio it already captures and pin each lyric word to the moment it is actually sung. Recognition runs on this Mac, nothing is uploaded, and no audio is kept. It corrects drift as the song plays, and the result is saved so the next play starts in time.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Align lyrics by listening", isOn: model.settings.localAlignment)
            switch self.model.speechAuthorisation {
            case .authorized:
                Text(self.model.alignment.status.summary).font(.system(size: 11)).foregroundStyle(.tertiary)
            case .denied, .restricted:
                Text("Speech recognition is turned off for Vela. Allow it under Privacy & Security › Speech Recognition.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                HStack {
                    Text("Needs permission to recognise speech.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow") { self.model.requestSpeechPermission() }.controlSize(.small)
                }
            }
            HStack {
                Button("Forget learned alignments") { self.model.clearStoredAlignments() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var updatesSection: some View {
        SettingsSection(title: "Updates") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vela \(self.model.updates.currentVersion)").font(.system(size: 12, weight: .semibold))
                    Text(updatesStatusText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check now") { self.model.updates.checkForUpdates() }
                    .controlSize(.small)
                    .disabled(!self.model.updates.canCheck)
            }
            Toggle("Check for updates automatically", isOn: Binding(
                get: { self.model.updates.automaticChecks },
                set: { self.model.updates.automaticChecks = $0 }))
                .disabled(!self.model.updates.isAvailable)
            Text("Updates are downloaded from GitHub, verified against Vela's signing key, and installed when you relaunch.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var updatesStatusText: String {
        let u = self.model.updates
        guard u.isAvailable else { return "Updates are unavailable in this build." }
        if let error = u.lastError { return error }
        if let date = u.lastCheck {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))."
        }
        return "Not checked yet."
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

/// The three sliders that describe where an element sits and how big it is.
private struct ArrangementRows: View {
    @Binding var arrangement: SceneArrangement

    var body: some View {
        SliderRow(title: "Size", value: $arrangement.scale, range: SceneArrangement.scaleRange,
                  format: { String(format: "%.0f%%", $0 * 100) }, reset: { arrangement.scale = 1 })
        SliderRow(title: "Horizontal", value: $arrangement.offsetX, range: SceneArrangement.offsetRange,
                  format: { String(format: "%+.0f%%", $0 * 100) }, reset: { arrangement.offsetX = 0 })
        SliderRow(title: "Vertical", value: $arrangement.offsetY, range: SceneArrangement.offsetRange,
                  format: { String(format: "%+.0f%%", $0 * 100) }, reset: { arrangement.offsetY = 0 })
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

import SwiftUI

/// The full composition: backdrop, stage, edge light and overlays.
struct SceneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let typography = typography(for: proxy.size)
            ZStack {
                ReactiveSceneView(director: model.director, features: model.audio.store,
                                  artworkSoft: model.backdrop, artworkSharp: model.backdropSharp,
                                  artworkGeneration: model.artworkGeneration,
                                  geometry: model.sceneGeometry)
                    .ignoresSafeArea()
                if model.increaseContrast {
                    Color.black.opacity(0.28).ignoresSafeArea()
                }

                stage(typography: typography)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .id(model.transitionID)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.7), value: model.transitionID)

                overlays
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black)
        .onContinuousHover { phase in
            if case .active = phase { model.pointerMoved() }
        }
        .onTapGesture { model.showOverlay() }
        .preferredColorScheme(.dark)
    }

    private func typography(for size: CGSize) -> LyricTypography {
        let base = min(size.width * 0.052, size.height * 0.075)
        return LyricTypography(fontSize: max(22, base * model.settings.lyricSize),
                               style: model.settings.lyricStyle,
                               palette: model.palette,
                               reduceEffects: model.settings.reduceEffects,
                               reduceMotion: reduceMotion,
                               increaseContrast: model.increaseContrast)
    }

    @ViewBuilder
    private func stage(typography: LyricTypography) -> some View {
        let palette = model.palette
        switch model.stage {
        case .lyrics(let box):
            LyricsStageView(box: box, typography: typography, clock: model.clock, offset: model.lyricTimeShift, director: model.director)
                .padding(.vertical, 60)
        case .unsynced(let box):
            UnsyncedLyricsView(box: box, typography: typography, clock: model.clock)
                .padding(.vertical, 40)
        case .instrumental:
            if let track = model.track {
                TrackHeroView(track: track, caption: "Instrumental", palette: palette) {
                    BreathingIndicator(countdown: nil, color: palette.highlight.swiftUIColor, reduceMotion: reduceMotion, size: 12)
                }
            }
        case .loadingLyrics:
            if let track = model.track {
                TrackHeroView(track: track, caption: "Finding lyrics…", palette: palette) {
                    PulsingDot(color: palette.highlight.swiftUIColor, reduceMotion: reduceMotion)
                }
            }
        case .lyricsUnavailable(let reason):
            if let track = model.track {
                TrackHeroView(track: track, caption: unavailableCaption(reason), palette: palette, actions: unavailableActions(reason)) {
                    Image(systemName: reason == .offline ? "wifi.slash" : "text.quote")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(palette.highlight.swiftUIColor.opacity(0.8))
                }
            }
        case .idlePlayer(let kind):
            StatusStageView(symbol: "play.circle", title: "\(kind.displayName) is open",
                            message: "Nothing is playing yet. Start a song in \(kind.displayName) and Vela will pick it up.",
                            actions: [.init(title: "Try Demo Mode", handler: { model.setDemoMode(true) })], palette: palette)
        case .noPlayer(let status):
            noPlayerStage(status, palette: palette)
        }
    }

    private func unavailableCaption(_ reason: LyricsUnavailableReason) -> String {
        switch reason {
        case .notFound: return "No lyrics found for this track"
        case .offline: return "You're offline — lyrics will load when the connection returns"
        case .failed: return "Lyrics service didn't respond"
        }
    }

    private func unavailableActions(_ reason: LyricsUnavailableReason) -> [StatusStageView.StageAction] {
        var actions: [StatusStageView.StageAction] = [.init(title: "Import .lrc…", handler: { model.importLyricsFile() })]
        if reason != .notFound { actions.append(.init(title: "Retry", prominent: true, handler: { model.retryLyrics() })) }
        return actions
    }

    @ViewBuilder
    private func noPlayerStage(_ status: SourceStatus, palette: Palette) -> some View {
        switch status {
        case .permissionDenied(let kind):
            StatusStageView(symbol: "lock.shield", title: "Vela can't see \(kind.displayName)",
                            message: "macOS blocked Vela from reading \(kind.displayName). Allow Vela under Privacy & Security › Automation, then come back.",
                            actions: [.init(title: "Open System Settings", prominent: true, handler: { model.openAutomationSettings() }),
                                      .init(title: "Try Demo Mode", handler: { model.setDemoMode(true) })], palette: palette)
        case .preferredUnavailable(let kind):
            StatusStageView(symbol: "questionmark.app.dashed", title: "\(kind.displayName) isn't running",
                            message: "Vela is set to use \(kind.displayName) only. Open it and play something, or switch to automatic detection.",
                            actions: [.init(title: "Detect automatically", prominent: true, handler: { model.settings.preferredSource = .automatic }),
                                      .init(title: "Try Demo Mode", handler: { model.setDemoMode(true) })], palette: palette)
        case .error(let kind, let message):
            StatusStageView(symbol: "exclamationmark.triangle", title: "\(kind.displayName) didn't respond",
                            message: "Vela will keep trying. If this persists, restart \(kind.displayName).\n\(message)",
                            actions: [.init(title: "Try Demo Mode", handler: { model.setDemoMode(true) })], palette: palette)
        default:
            StatusStageView(symbol: "waveform", title: "Nothing playing",
                            message: "Play something in Spotify or Apple Music and Vela will light up. Other players aren't supported yet.",
                            actions: [.init(title: "Try Demo Mode", prominent: true, handler: { model.setDemoMode(true) })], palette: palette)
        }
    }

    // MARK: Overlays

    private var overlays: some View {
        ZStack {
            VStack {
                HStack {
                    SourceBadge()
                    Spacer()
                }
                .padding(.top, model.isFullscreen ? 18 : 34)
                .padding(.leading, 20)
                Spacer()
                if model.overlayVisible {
                    NowPlayingOverlay()
                        .padding(.bottom, 28)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .opacity(model.overlayVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.35), value: model.overlayVisible)

            // Song progress as a hairline along the bottom edge while the controls are hidden.
            VStack {
                Spacer()
                ProgressHairline()
                    .opacity(!model.overlayVisible && model.track != nil ? 1 : 0)
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.5), value: model.overlayVisible)

            if model.introVisible, !model.overlayVisible, let track = model.track {
                VStack {
                    Spacer()
                    HStack {
                        TrackIntroCard(track: track, palette: model.palette, reduceTransparency: model.reduceTransparency)
                        Spacer()
                    }
                }
                .padding(28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(.bottom, model.overlayVisible ? 132 : 40)
                }
                .transition(.opacity)
            }

            if model.settingsVisible {
                SettingsOverlayView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.settingsVisible)
        .animation(.easeInOut(duration: 0.3), value: model.toast)
        .animation(.easeInOut(duration: 0.6), value: model.introVisible)
    }
}

/// Thin progress line along the bottom edge, visible only while the controls are hidden.
private struct ProgressHairline: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = model.track?.duration ?? 0
            let fraction = duration > 0 ? min(1, max(0, model.clock.position(at: context.date) / duration)) : 0
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Rectangle()
                        .fill(LinearGradient(colors: [model.palette.glow.swiftUIColor, model.palette.highlight.swiftUIColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * fraction)
                        .animation(.linear(duration: 0.5), value: fraction)
                }
            }
            .frame(height: 2)
            .opacity(0.7)
        }
        .accessibilityHidden(true)
    }
}

/// Bottom-left title card that appears for a few seconds when a track starts.
private struct TrackIntroCard: View {
    let track: TrackInfo
    let palette: Palette
    let reduceTransparency: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("NOW PLAYING")
                .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(palette.highlight.swiftUIColor.opacity(0.9))
            Text(track.title)
                .font(.system(size: 24, weight: .semibold)).kerning(-0.3)
                .foregroundStyle(.white)
                .lineLimit(1)
            if !track.artist.isEmpty {
                Text(track.artist)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(reduceTransparency ? 0.85 : 0.42))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        )
        .accessibilityElement(children: .combine)
    }
}

/// Small pill in the top-left naming the source and lyric timing quality.
private struct SourceBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(model.palette.highlight.swiftUIColor).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
            if let quality = model.lyricsQualityDescription {
                Text("·").foregroundStyle(.white.opacity(0.4))
                Text(quality).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            if model.track != nil || model.previewProfile != nil {
                Text("·").foregroundStyle(.white.opacity(0.4))
                Text(model.previewProfile.map { "Preview: \($0.displayName)" } ?? model.effectiveProfile.displayName)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            if model.audio.status == .denied || model.audio.status == .notDetermined, !model.isDemoMode, model.track != nil {
                Text("·").foregroundStyle(.white.opacity(0.4))
                Text("No system audio").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(model.reduceTransparency ? 0.85 : 0.35)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        if model.isDemoMode { return "DEMO" }
        return (model.activeSourceKind?.displayName ?? "VELA").uppercased()
    }
}

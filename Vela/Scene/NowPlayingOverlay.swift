import SwiftUI

/// Minimal transport bar that appears on pointer movement.
struct NowPlayingOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            ArtworkThumbnail(image: model.artwork, palette: model.palette)
                .frame(width: 62, height: 62)
                .shadow(color: model.palette.glow.swiftUIColor.opacity(0.55), radius: 16, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                if let track = model.track {
                    Text(track.title)
                        .font(.system(size: 16, weight: .semibold)).kerning(-0.2)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(track.artist.isEmpty ? track.album : track.artist)
                            .lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
                        Text(model.previewProfile.map { "Preview: \($0.displayName)" } ?? model.effectiveProfile.displayName)
                            .foregroundStyle(model.palette.highlight.swiftUIColor.opacity(0.9))
                            .lineLimit(1)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                } else {
                    Text(placeholderTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Text(placeholderSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                ProgressBar()
            }
            .frame(minWidth: 220, maxWidth: 360)

            LevelMeter()
                .frame(width: 22, height: 26)
                .opacity(model.isPlaying ? 1 : 0.25)

            HStack(spacing: 4) {
                Button { model.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 15, weight: .semibold)) }
                    .buttonStyle(GlyphButtonStyle())
                    .disabled(!model.capabilities.canSkip)
                    .accessibilityLabel("Previous track")
                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.clock.isRunning ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .bold))
                }
                .buttonStyle(GlyphButtonStyle(size: 44, emphasized: true))
                .disabled(model.track == nil)
                .accessibilityLabel(model.clock.isRunning ? "Pause" : "Play")
                Button { model.next() } label: { Image(systemName: "forward.fill").font(.system(size: 15, weight: .semibold)) }
                    .buttonStyle(GlyphButtonStyle())
                    .disabled(!model.capabilities.canSkip)
                    .accessibilityLabel("Next track")
            }

            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 28)

            HStack(spacing: 4) {
                Button { model.toggleFullscreen() } label: {
                    Image(systemName: model.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(GlyphButtonStyle())
                .accessibilityLabel(model.isFullscreen ? "Exit full screen" : "Enter full screen")
                .help(model.isFullscreen ? "Exit Full Screen (Esc)" : "Full Screen (⌘F)")
                Button { model.toggleSettings() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .semibold)) }
                    .buttonStyle(GlyphButtonStyle())
                    .accessibilityLabel("Settings")
                    .help("Settings (⌘,)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(model.reduceTransparency ? 0.9 : 0.28)))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [model.palette.highlight.swiftUIColor.opacity(0.35), Color.white.opacity(0.08), model.palette.glow.swiftUIColor.opacity(0.3)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        )
        .environment(\.colorScheme, .dark)
        .onHover { model.setOverlayHovering($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing controls")
    }

    private var placeholderTitle: String {
        switch model.sourceStatus {
        case .noPlayerRunning: return "Nothing playing"
        case .permissionDenied(let kind): return "\(kind.displayName) access needed"
        case .preferredUnavailable(let kind): return "\(kind.displayName) isn't running"
        case .idle(let kind): return "\(kind.displayName) is idle"
        case .error(let kind, _): return "\(kind.displayName) didn't respond"
        case .active: return "Loading…"
        }
    }

    private var placeholderSubtitle: String {
        model.isDemoMode ? "Demo Mode" : "Spotify · Apple Music"
    }
}

struct ArtworkThumbnail: View {
    let image: CGImage?
    let palette: Palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [palette.glow.swiftUIColor.opacity(0.7), palette.highlight.swiftUIColor.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .animation(.easeInOut(duration: 0.6), value: image == nil)
        .accessibilityHidden(true)
    }
}

/// Scrubbable progress bar with elapsed/remaining labels.
private struct ProgressBar: View {
    @Environment(AppModel.self) private var model
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = model.track?.duration ?? 0
            let position = model.clock.position(at: context.date)
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            let shown = dragFraction ?? fraction
            VStack(spacing: 5) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule().fill(model.palette.highlight.swiftUIColor).frame(width: max(4, proxy.size.width * shown))
                    }
                    .frame(height: hovering || dragFraction != nil ? 6 : 4)
                    .frame(height: 14)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard model.capabilities.canSeek, duration > 0 else { return }
                                dragFraction = min(1, max(0, value.location.x / proxy.size.width))
                            }
                            .onEnded { value in
                                guard model.capabilities.canSeek, duration > 0 else { dragFraction = nil; return }
                                let target = min(1, max(0, value.location.x / proxy.size.width))
                                model.seek(to: target * duration)
                                dragFraction = nil
                            }
                    )
                    .onHover { hovering = $0 }
                }
                .frame(height: 14)
                .animation(.easeOut(duration: 0.15), value: hovering)
                HStack {
                    Text(TimeFormatting.clock(shown * duration))
                    Spacer()
                    Text(duration > 0 ? TimeFormatting.remaining(duration - shown * duration) : "--:--")
                }
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progress")
            .accessibilityValue("\(TimeFormatting.clock(position)) of \(TimeFormatting.clock(duration))")
        }
    }
}


/// Three tiny bars (bass, mids, highs) driven by the director's smoothed bands: a live signal,
/// never decoration.
private struct LevelMeter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { _ in
            let bands = model.director.lastState.bands
            let values = [Double(bands.bass), Double(bands.mid), Double(bands.high)]
            let colors = [model.palette.highlight, model.palette.glow, model.palette.primary].map(\.swiftUIColor)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(colors[index].opacity(0.9))
                        .frame(width: 4, height: 4 + 20 * values[index])
                        .animation(.easeOut(duration: 0.12), value: values[index])
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

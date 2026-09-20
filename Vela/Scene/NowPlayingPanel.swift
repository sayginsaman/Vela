import SwiftUI

/// The left column of the split layout: artwork, track details and a scrubbable progress bar,
/// sitting permanently on screen while the lyrics run alongside it.
struct NowPlayingPanel: View {
    @Environment(AppModel.self) private var model
    let width: CGFloat
    let height: CGFloat

    private var artworkSide: CGFloat {
        min(width - 64, height * 0.4, 380)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            ArtworkThumbnail(image: model.artwork, palette: model.palette)
                .frame(width: artworkSide, height: artworkSide)
                .clipShape(RoundedRectangle(cornerRadius: artworkSide * 0.055, style: .continuous))
                .shadow(color: model.palette.glow.swiftUIColor.opacity(model.settings.reduceEffects ? 0.2 : 0.45),
                        radius: artworkSide * 0.13, y: artworkSide * 0.04)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                .padding(.bottom, 26)

            if let track = model.track {
                Text(track.title)
                    .font(.system(size: min(30, artworkSide * 0.105), weight: .bold))
                    .kerning(-0.4)
                    .foregroundStyle(model.palette.primary.swiftUIColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: min(18, artworkSide * 0.066), weight: .medium))
                        .foregroundStyle(model.palette.primary.swiftUIColor.opacity(0.72))
                        .lineLimit(1)
                        .padding(.top, 5)
                }
                if !track.album.isEmpty, track.album != track.title {
                    Text(track.album)
                        .font(.system(size: min(14, artworkSide * 0.052)))
                        .foregroundStyle(model.palette.primary.swiftUIColor.opacity(0.45))
                        .lineLimit(1)
                        .padding(.top, 3)
                }
            }

            PanelProgress()
                .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing")
    }
}

/// Scrubbable progress with elapsed and remaining time, sized for the panel.
private struct PanelProgress: View {
    @Environment(AppModel.self) private var model
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = model.track?.duration ?? 0
            let position = model.clock.position(at: context.date)
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            let shown = dragFraction ?? fraction
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule()
                            .fill(LinearGradient(colors: [model.palette.glow.swiftUIColor, model.palette.highlight.swiftUIColor],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, proxy.size.width * shown))
                    }
                    .frame(height: hovering || dragFraction != nil ? 6 : 4)
                    .frame(height: 16)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard model.capabilities.canSeek, duration > 0 else { return }
                                dragFraction = min(1, max(0, value.location.x / proxy.size.width))
                            }
                            .onEnded { value in
                                guard model.capabilities.canSeek, duration > 0 else { dragFraction = nil; return }
                                model.seek(to: min(1, max(0, value.location.x / proxy.size.width)) * duration)
                                dragFraction = nil
                            }
                    )
                    .onHover { hovering = $0 }
                }
                .frame(height: 16)
                .animation(.easeOut(duration: 0.15), value: hovering)
                HStack {
                    Text(TimeFormatting.clock(shown * duration))
                    Spacer()
                    Text(duration > 0 ? TimeFormatting.remaining(duration - shown * duration) : "--:--")
                }
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(model.palette.primary.swiftUIColor.opacity(0.5))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progress")
            .accessibilityValue("\(TimeFormatting.clock(position)) of \(TimeFormatting.clock(duration))")
        }
    }
}

/// Compact right-hand message for the split layout, where the panel already names the track.
struct CompactStageMessage: View {
    let symbol: String
    let caption: String
    var actions: [StatusStageView.StageAction] = []
    let palette: Palette
    let alignment: LyricAlignment

    var body: some View {
        VStack(alignment: alignment == .leading ? .leading : .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(palette.highlight.swiftUIColor.opacity(0.85))
                .symbolRenderingMode(.hierarchical)
            Text(caption)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(palette.primary.swiftUIColor.opacity(0.8))
                .multilineTextAlignment(alignment.textAlignment)
                .fixedSize(horizontal: false, vertical: true)
            if !actions.isEmpty {
                HStack(spacing: 12) {
                    ForEach(actions) { action in
                        Button(action.title, action: action.handler)
                            .buttonStyle(PillButtonStyle(prominent: action.prominent, tint: palette.highlight.swiftUIColor))
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: 520, alignment: alignment.frameAlignment)
        .accessibilityElement(children: .contain)
    }
}

import SwiftUI

/// The synced-lyrics stage: samples the playback clock every frame and positions the line stack.
struct LyricsStageView: View {
    let box: LyricTimelineBox
    let typography: LyricTypography
    let clock: PlaybackClock
    let offset: TimeInterval
    let director: VisualDirector

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !clock.isRunning && !director.isPreviewing)) { context in
            let time = clock.position(at: context.date) + offset
            let position = box.locate(at: time)
            let motion = director.lyricSnapshot()
            var liveTypography = typography
            let _ = {
                liveTypography.motion = motion.style
                liveTypography.beatImpulse = (motion.beatImpulse * 50).rounded() / 50
                liveTypography.beatCount = motion.beatCount
            }()
            // Calm profiles float the whole stack very slowly instead of jumping.
            let calm = max(0, 1 - motion.style.tempo)
            let floatOffset: CGFloat = (typography.reduceMotion || calm <= 0.05) ? 0
                : CGFloat(sin(context.date.timeIntervalSinceReferenceDate * 0.45) * 5 * calm)
            let current = position.lineIndex.flatMap { box.sungIndex(forDocumentLine: $0) }
            let inBreak = position.isInBreak
            // During a break the *next* line is centred as an upcoming line.
            let anchor: Int = {
                guard let current else { return 0 }
                return inBreak ? min(current + 1, box.sungLines.count - 1) : current
            }()
            let anchorIsCurrent = current != nil && !inBreak
            LyricLineStack(lines: box.sungLines,
                           anchor: anchor,
                           anchorIsCurrent: anchorIsCurrent,
                           activeWordIndex: anchorIsCurrent ? position.wordIndex : nil,
                           wordProgress: position.wordProgress,
                           typography: liveTypography,
                           showBreathing: inBreak,
                           breathCountdown: position.timeUntilNextLine,
                           floatOffset: floatOffset)
        }
    }
}

/// Plain lyrics without timing: a slowly scrolling column whose progress follows the song.
struct UnsyncedLyricsView: View {
    let box: LyricTimelineBox
    let typography: LyricTypography
    let clock: PlaybackClock

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !clock.isRunning)) { context in
                let duration = clock.duration ?? 1
                let fraction = duration > 0 ? min(1, max(0, clock.position(at: context.date) / duration)) : 0
                let overflow = max(0, contentHeight - proxy.size.height * 0.7)
                VStack(spacing: typography.fontSize * 0.45) {
                    ForEach(box.document.lines) { line in
                        if line.isEmpty {
                            Spacer().frame(height: typography.fontSize * 0.4)
                        } else {
                            Text(line.text)
                                .font(.system(size: typography.fontSize * 0.7, weight: .semibold))
                                .foregroundStyle(typography.primaryColor.opacity(0.82))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: proxy.size.width * 0.8)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .frame(width: proxy.size.width)
                .offset(y: proxy.size.height * 0.15 - overflow * fraction)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(alignment: .bottom) {
                Text("Lyrics for this track aren't time-synced")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 96)
            }
        }
        .accessibilityLabel("Unsynced lyrics")
    }
}

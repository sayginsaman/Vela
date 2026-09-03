import SwiftUI

/// The synced-lyrics stage: samples the playback clock every frame and positions the line stack.
struct LyricsStageView: View {
    let box: LyricTimelineBox
    let typography: LyricTypography
    let clock: PlaybackClock
    let offset: TimeInterval

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !clock.isRunning)) { context in
            let time = clock.position(at: context.date) + offset
            let position = box.locate(at: time)
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
                           typography: typography,
                           showBreathing: inBreak,
                           breathCountdown: position.timeUntilNextLine)
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

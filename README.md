# Vela

Vela is a native macOS app that turns whatever is playing in Spotify or Apple Music into a
full-screen stage: synchronized lyrics highlighted word by word, colours pulled from the album
artwork, and an ambient light around all four edges of the display that follows the music.

It is a normal foreground application, not a screensaver or lock-screen tweak. Open the window,
press ⌘F, and let it run.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon.
- Xcode 16 or later (the project uses Xcode's synchronized folder groups). Built and tested with Xcode 26.
- Spotify and/or Apple Music for real playback. Neither is required for Demo Mode.

## Open and run

```bash
open Vela.xcodeproj
```

Select the **Vela** scheme and press Run, or from the terminal:

```bash
xcodebuild -project Vela.xcodeproj -scheme Vela -configuration Debug build
```

```bash
xcodebuild -project Vela.xcodeproj -scheme Vela -configuration Debug test
```

The project signs ad hoc ("Sign to Run Locally"). Set your team in the target's Signing settings
if you want macOS to remember the privacy permissions across rebuilds; with ad-hoc signing, TCC
treats every new build as a new app and asks again.

The edge-glow shader is compiled at runtime from source (`EdgeGlowShaderSource.swift`), so the
Metal shader toolchain does not need to be installed to build the project.

## Using Vela

| Action | How |
| --- | --- |
| Full screen | ⌘F (or the button in the controls bar) |
| Reveal controls | Move the pointer, or press Space |
| Play / pause | Space while controls are visible |
| Seek ±5 s | ← / → (when the source supports seeking) |
| Previous / next track | ⌘← / ⌘→ |
| Settings | ⌘, |
| Demo Mode | ⌘⇧D |
| Close settings, then leave full screen | Esc |

The controls bar hides after about three seconds of inactivity while music is playing.

Three lyric styles are available in Settings: **Focus** (default; centred line, precise word
highlighting), **Drift** (neighbouring lines recede through depth) and **Bloom** (words swell and
glow as they are sung). Settings also cover palette (automatic from artwork or manual), lyric size,
glow thickness / intensity / spread, music-reactive motion, reduced effects, lyric timing offset
(−5 s … +5 s), preferred music source, full-screen display and launch at login. Settings persist
between launches.

## Permissions and why

Vela asks for two things, both explained during onboarding and both optional:

1. **Automation (Apple Events) for Spotify and Music.** Vela reads the current track, position,
   state and artwork and sends play/pause/skip/seek through each app's public AppleScript
   dictionary. macOS shows a one-time prompt per app the first time Vela talks to it. Vela never
   launches a player on its own; it only talks to players that are already running.
2. **Screen & System Audio Recording.** The ambient light reacts to bass and loudness by analysing
   the audio your Mac is playing, captured with ScreenCaptureKit (`capturesAudio` only; a 2×2 px
   video stream is configured because the API needs a display filter, and its frames are
   discarded). The microphone is never captured. Samples are analysed locally with Accelerate
   and never stored. Without this permission the light breathes on its own.

Denying either permission leaves the app fully usable. Permission state is shown in Settings with
shortcuts to the relevant System Settings panes.

## Architecture

Everything lives in one app target, grouped by responsibility:

- `App/AppModel.swift` — `@MainActor @Observable` application state. Consumes player events,
  drives lyric/artwork loading with cancellation, owns overlay/keyboard/fullscreen state.
- `MusicSources/` — `MusicSource` protocol, `SpotifySource` and `AppleMusicSource` (AppleScript on
  a private serial queue, never the main thread), `DemoMusicSource` (actor with a real-time
  timeline), and `MusicSourceCoordinator` (an actor that detects the active player, polls at an
  adaptive rate, listens to the players' distributed notifications, and forwards commands).
- `Lyrics/` — `LyricsProvider` protocol; `LRCParser` (standard and enhanced word-level LRC),
  `WordTimingEstimator`, `LyricTimeline` (cursor-based active-word lookup with binary-search
  seeking), `LRCLIBProvider`, `LyricsCache` (disk, keyed by a normalised hash of artist/title/
  album/duration), `LocalLyricsStore` (imported `.lrc` files) and `LyricsService` (the resolver).
- `Palette/` — `PaletteExtractor` (histogram over a 32×32 sample), `PaletteCorrector` (contrast,
  similarity and muddiness rules), `ArtworkProcessor` (pre-blurred backdrop via Core Image).
- `Audio/` — `SystemAudioCapture` (ScreenCaptureKit), `SpectrumAnalyzer` (vDSP FFT, band
  energies, auto-gain, attack/release smoothing), `DemoAudioSimulator`, `AudioLevelStore`
  (lock-protected mailbox between the audio thread and the render thread) and `AudioEngine`.
- `Rendering/` — `EdgeGlowRenderer` (Metal, one full-screen triangle with an SDF fragment shader,
  transparent over the SwiftUI scene, paused when occluded), a `Canvas` fallback, and the
  artwork backdrop with drifting gradient and grain.
- `Scene/` — the SwiftUI stage: `LyricsStageView` samples the playback clock each frame,
  `LyricLineStack` positions lines with spring motion, `LyricLineView`/`LyricWordView` render
  words with progressive fill and bloom, plus overlays, onboarding, settings and status states.
- `Settings/` — typed `VelaSettings` persisted by `SettingsStore`.
- `Window/WindowController.swift` — AppKit bridge for fullscreen, display selection and notch
  geometry.

Timing is honest end to end: a `LyricDocument` carries a `TimingQuality` (word-synced,
line-synced, estimated, unsynced) and every `TimedWord` records whether its timestamps were
estimated. LRCLIB returns line-level timing, so its words are estimated by length and punctuation;
enhanced LRC files (`<mm:ss.xx>` tags) are used verbatim. Plain lyrics fall back to a slowly
scrolling unsynced mode.

## Real-integration limitations

- Spotify's AppleScript dictionary reports artwork as a URL, so Spotify artwork needs network
  access. Apple Music artwork comes straight from the app.
- Only Spotify and Apple Music are supported; there is no public API for "whatever is playing
  system-wide". Other players show the "Nothing playing" state.
- LRCLIB is a community database. Coverage is good but not universal; lyrics are line-synced,
  never word-synced. The provider boundary (`LyricsProvider`) is ready for a word-level provider
  should one be added; no keys or paid services are used.
- With ad-hoc signing, macOS re-asks for permissions after each rebuild (see above).
- macOS may require the app to be relaunched after Screen Recording permission is first granted.

## Demo Mode

Demo Mode (⌘⇧D, or "Try Demo" at the end of onboarding) needs no players, permissions or
network. `DemoMusicSource` simulates a four-track album with a real-time timeline, seeking,
skipping and pausing. Artwork is drawn procedurally per track, lyrics are original texts bundled
as `.lrc`/`.txt` files (one word-synced, one line-synced, one plain, one instrumental), and
`DemoAudioSimulator` produces deterministic bass/mid/high/level bands from the track's tempo so the
edge light reacts exactly as it would to captured audio.

All demo lyrics and artwork were created for this project.

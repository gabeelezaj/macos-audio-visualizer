# Music Visualizer

A macOS music visualizer that draws whatever your computer is playing — Apple Music,
Spotify, YouTube, a game, anything that reaches the speakers.

No virtual audio driver (BlackHole, Loopback, Soundflower) and no screen-recording
permission. It uses a **Core Audio process tap**, the API macOS added in 14.2 for
exactly this, so the only thing it asks for is *System Audio Recording*.

## Build and run

```bash
./build.sh && open MusicVisualizer.app
```

Needs only the Xcode Command Line Tools — the Metal shaders are compiled at runtime
by the Metal framework, so a full Xcode install isn't required.

The first launch asks for permission to record system audio. Grant it, and play
something.

## Visualizations

Press `1`–`9`, `0`, `-`, or click the chips along the bottom. Switching dissolves
between modes rather than cutting.

| | Mode | What it does |
|---|---|---|
| 1 | **Aurora** | Luminous ribbons over a drifting nebula. Each rides its own slice of the spectrum, and the stereo image tilts them. |
| 2 | **Spectrum** | Mirrored frequency bars — left channel above the centre line, right below. |
| 3 | **Waveform** | Zero-crossing-triggered oscilloscope with chromatic fringing. |
| 4 | **Bloom** | Radial spectrum flower with rays and beat shockwaves. |
| 5 | **Tunnel** | Flight through a corridor; bass drives the speed. |
| 6 | **Starfield** | Layered motes, each lit by its own frequency band. |
| 7 | **Liquid** | Metaballs whose radii track the bands. |
| 8 | **Horizon** | Synthwave ground plane under a spectrum-sliced sun. |
| 9 | **Waterfall** | Scrolling spectrogram — frequency up, time flowing right to left. |
| 0 | **Kaleidoscope** | Six-fold mirrored shards of a tumbling noise field. |
| - | **Vectorscope** | Left plotted against right, as a hardware scope draws it. Mono collapses to a vertical line; a wide mix opens out. |

Six color palettes, and sliders for sensitivity, smoothing, trail length and color
drift under the tuning button. Every setting carries a small `?` — hover it for an
explanation of what the control actually does and when you'd want to move it. The
controls stay put while you're reading one instead of auto-hiding mid-sentence.

## Keyboard

| Key | Action |
|---|---|
| `1`–`9`, `0`, `-` | Pick a visualization |
| `←` `→` / `Space` | Previous / next visualization |
| `C` | Next color palette |
| `R` | Shuffle mode + palette |
| `A` | Toggle auto-cycle |
| `F` | Full screen |
| `⌘Q` | Quit |

Controls fade out after a few seconds of no mouse movement, and the cursor hides
with them.

## Other things it does

- **Auto-cycle.** Pick an interval and it drifts to a different visualization on its
  own, changing palette every third switch. Good for leaving on at a party.
- **Tempo tracking.** Inter-onset intervals are folded by octaves into 60–190 BPM and
  resolved with a median; the reading appears once the estimate is stable, and shaders
  get a continuous tempo-locked phase for motion that stays on the beat between hits.
- **Stereo throughout.** Both channels are analysed separately. The top bar shows
  stereo width, the bars split by channel, and the vectorscope plots the field directly.
- **Per-app capture.** The menu in the top right switches between the full system mix
  and a single app, so you can visualize Music while a video call runs on the same Mac.
- **Idle drift.** With nothing playing the scene keeps breathing gently instead of
  freezing, which otherwise looks like a crash.
- **Render scale.** Above roughly 4K the visualization renders below native and
  upscales on present. `Auto` picks by display size; `Full`/`Balanced`/`Performance`
  override it.

## How it works

```
Core Audio process tap ─→ private aggregate device ─→ IO proc (real-time thread)
                                                          │
                                          lock-guarded stereo ring buffer
                                                          │
   Hann window → 4096-pt FFT per channel → magnitude → pink-noise tilt
   → 128 log-spaced bands → auto gain → fast-attack/slow-release envelopes
   → spectral-flux onset detection → octave-folded tempo estimate
                                                          │
              spectrum / waveform / spectrogram textures, uniforms
                                                          │
      Metal: fragment shader per mode (plus point geometry for the vectorscope)
      → crossfade → feedback trails → hue-preserving tone map → extended-linear
      framebuffer (XDR headroom on capable displays)
```

Some details worth knowing:

- **Every envelope is a time constant, not a per-frame coefficient.** The visuals
  behave identically at 60 Hz and on a 120 Hz ProMotion display.
- **Beats come from spectral flux**, not raw energy. Flux only counts frequency bins
  that grew, so a kick still registers under a sustained bass note. Measured 80–99%
  accuracy across four-on-the-floor, rock, sparse acoustic and deliberately-buried-kick
  test signals at both 60 and 120 Hz, with tempo correct to ±1 BPM in all eight.
- **Auto gain** chases the loudest band up quickly and drifts down over ~2.5 s, so a
  quiet acoustic track fills the screen as well as a loud master does.
- **Bands are blurred across neighbours** before they reach the GPU. FFT bin jitter
  otherwise shows up as a hard zigzag anywhere frequency is mapped across space.
- **Tone mapping preserves hue.** Per-channel ACES pulls every bright pixel toward
  white, which ruins neon; this maps the peak channel and keeps the color ratio.
- **Starting the tap happens off the main thread.** `AudioHardwareCreateProcessTap`
  blocks, sometimes for a long time if another process is holding a tap open. On the
  main thread that means a launch with no window at all.

## Diagnostics

```bash
MusicVisualizer.app/Contents/MacOS/MusicVisualizer --diagnose
```

There is also a `--snapshot <directory>` mode that renders the controls and every
help explanation to PNGs, so interface changes can be reviewed without launching a
window. It hosts the view in an offscreen window and asks AppKit to cache its
display — SwiftUI's `ImageRenderer` draws sliders, pickers and `.ultraThinMaterial`
as placeholder artwork, which is most of this interface.

Starts the tap headless, samples for ten seconds and reports the device route,
callback count, levels, stereo width, beat count and tempo. Useful for confirming
permissions. Output is flushed line by line, so it stays useful if something hangs.

Three things that look like bugs but aren't:

- **Zero IO callbacks while nothing is playing.** The aggregate device only clocks
  while the output device is active. Play something and callbacks appear.
- **Callbacks arriving full of bit-exact zeros.** macOS does not fail tap creation
  when the audio-recording grant is missing — it silently feeds silence. The app
  detects this (silence while another app is demonstrably playing) and says so.
- **A stalled tap after something crashed.** A process holding a tap open can block
  the next one from starting. Quit the stray process and it clears.

Note that running the binary from a terminal attributes the permission to the
*terminal*, not to Music Visualizer. Launch the `.app` to test the real grant.

## Caveats

- Requires macOS 14.4 or later (Core Audio process taps plus their TCC service).
- The app is ad-hoc signed, and macOS ties the audio-recording grant to the
  signature — so rebuilding can make it ask for permission once more.

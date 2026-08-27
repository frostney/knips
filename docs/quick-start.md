# Quick start

## Executive Summary

- Prereqs: macOS on Apple silicon, FPC 3.2.2, lwpt ≥ 0.7.0 on PATH.
- `lwpt install` → `lwpt build` → `./build/knips probe` → `./build/knips
  record --out=demo.mp4`, Ctrl-C to stop.
- `./build/knips app` is the menu-bar version: click the icon, drag a
  rectangle, click again to stop. A red frame marks the region while it
  records, the finished clip opens in a playback window with a one-click
  GIF export, and **Camera** adds a draggable floating camera window
  that gets recorded along with everything else.
- `./build/knips export --in=demo.mp4 --out=demo.gif` turns the
  recording into an animated GIF, optionally trimmed and scaled;
  `--out=demo.apng` writes truecolour APNG instead, and `--out=cut.mp4
  --trim=1.5,3.5` trims without re-encoding.
- Grant Screen Recording on first run; a rebuilt binary re-prompts.
- `lwpt test` runs the neutral suites on any OS, including Linux CI.

## Prerequisites

- macOS 13+ on Apple silicon (the tested target). ScreenCaptureKit needs
  12.3; window capture via `initWithDesktopIndependentWindow:` and system
  audio (`--audio=system`) need 13; microphone capture (`--audio=mic`,
  `--audio=both`) needs 15.
- FreePascal **3.2.2** (`brew install fpc`).
- **lwpt** on PATH — release binary, or `./bootstrap.sh` in the lwpt repo
  and use `<lwpt-repo>/build/lwpt`.

## Zero to working

```sh
lwpt install       # cli + testing from the lwpt 0.7.0 tag into .lwpt/modules
lwpt build         # build/knips
./build/knips probe
```

`probe` must print `probe: ok`. It registers the runtime-built stream
output class, asks ScreenCaptureKit for displays and windows (this is
where the **Screen Recording** prompt appears), and opens then cancels an
AVAssetWriter on a temp file. If any line fails, read
[docs/spikes/0001-runtime-objc-class.md](spikes/0001-runtime-objc-class.md)
before touching code.

```sh
./build/knips displays
./build/knips record --out=demo.mp4            # main display, auto scale, 30 fps
```

Press Ctrl-C once. The last line reports size, duration, and frame
counts; open the file in QuickTime Player.

## The menu bar app

```sh
./build/knips app          # runs until you quit from the menu
tools/make-app.sh           # or wrap it: build/Knips.app, double-clickable
```

A `◉` appears in the menu bar. Clicking it opens:

| Item | What it does |
| --- | --- |
| Record Region… | Dims every screen, crosshair; drag a rectangle, release to start. **Esc** cancels. |
| Record Display | Records the main display straight away. |
| Record Window ▸ | Up to 20 on-screen application windows as *Application — Title*, refreshed at most once every five seconds. Knips's own windows are never listed. If the list cannot be read within a second the submenu says so instead of stalling. |
| Record Last Region | Repeats the last region recording — same display, same rectangle. Survives a relaunch. |
| Stop Recording | Enabled only while recording. |
| Cancel selection | Enabled only while selecting. The overlay covers the menu bar, so this only matters if the overlay failed to open. |
| Camera | Floating camera window; checked while it is up. Available in every state, recording included. |
| Record System Audio | A checkbox. On, recordings get an AAC track of the system mix. Remembered between launches; not changeable mid-recording. |
| Recordings folder | Opens `~/Movies/knips/` in Finder. |
| Last error: … | Only visible after a failure; the full text is in Console.app. |
| Quit Knips | Stops a running recording first. |

While recording the title reads `⏺ 0:07` and ticks once a second, and the
menu is detached so **one click on the icon stops** — Kap's gesture. The
price of that gesture is that Quit is unreachable until you stop; one
click does it. The finished file lands in
`~/Movies/knips/knips-YYYYMMDD-HHMMSS.mp4`.

**The recording frame.** A region recording puts a red frame around the
rectangle for as long as it runs, so there is never a doubt about what is
being captured. The frame is a passthrough window — clicks go straight
through it — and it is kept out of the file twice over: it is stroked in
the two points *outside* the recorded rectangle, and its window id is
passed to ScreenCaptureKit's `excludingWindows:` so the compositor never
draws it into the stream at all. Display and window recordings get no
frame.

**The playback window.** When a recording finishes, it opens in a normal
window with AVKit's transport controls and three buttons:

| Button | What it does |
| --- | --- |
| Export as GIF… | Writes `<recording>.gif` beside the movie at 20 fps and reveals it in Finder. Retina recordings export at their **point** size (pixel width ÷ capture scale — an exact 2:1 reduction, which is what keeps small text readable); scale-1 recordings cap at 800 px. A large result is noted on the `Last error:` line. Use `knips export --width=N` for anything else. |
| Reveal in Finder | Shows the `.mp4`. |
| Close | Closes the window and releases the player. |

The export runs on the main thread, so nothing responds while it is
going: the title counts up (`Exporting… 42%`), the buttons are disabled,
every menu item is a no-op, and **Quit is refused** until it finishes
(it says so under `Last error: …`). The buttons come back when it is
done and the `.gif` is revealed in Finder. For anything the button's
defaults do not cover — a different rate, a width, a trim — use
`knips export` (below).

**Remembered settings.** Record System Audio and the last region live in
`NSUserDefaults` under `KnipsRecordSystemAudio` and `KnipsLastRegion*`.
The bare binary and `Knips.app` keep separate domains (`knips` versus the
bundle identifier), so a setting made in one is not seen by the other:

```sh
defaults read knips          # what ./build/knips app remembers
defaults delete knips        # forget it
```

If Screen Recording has not been granted, the recording fails
immediately, the icon goes back to `◉`, and the reason shows up as
`Last error: …`. Knips does not retry — grant the permission in System
Settings › Privacy & Security › Screen Recording and click again.

## The camera window

**Camera** puts a small rounded window with your camera in it at the
bottom right of the main screen; the item carries a checkmark while it is
up. Drag it from anywhere in the picture — there is no title bar — and
drop it inside the region you are about to record: Knips does no
compositing, the camera is simply a window and ScreenCaptureKit records
it like any other. It floats above ordinary windows, follows you across
Spaces, and stays up across recordings until you switch it off or quit.

Where you left it and whether it was on are remembered, so — **once
camera access is granted** — the next launch brings it back to the same
corner. A position saved on a display that is no longer attached, or one
the Dock has since covered, is discarded rather than restored somewhere
you cannot reach. If access has *not* been granted, launch does nothing
at all: Knips will not open a permission prompt seconds after login.

The first time you switch it on, macOS asks for the **Camera**
permission. Answer the prompt, then choose *Camera* again — Knips refuses
that first attempt on purpose rather than showing you a black rectangle
while it waits, and it never retries by itself. A denied grant reads as
`Last error: camera access is denied …`; fix it in System Settings ›
Privacy & Security › Camera. Like Screen Recording, the grant is per
binary, so a rebuild re-prompts.

**Use the bundle for the camera.** `tools/make-app.sh` writes the
`NSCameraUsageDescription` that lets macOS prompt for Knips by name.
Measured on device, a bundle-less `./build/knips` is not killed for
lacking one — but it is silently refused, so *Camera* reports an error
and never opens (see [spike 0001](spikes/0001-runtime-objc-class.md)).

While a recording is running, the camera can only be switched **on** if
access was already granted; otherwise you get `Last error: grant camera
access before recording starts`. Switching it off always works.

Two known limits, both cheap to work around:

- The window renders at the scale of the display it opened on. Drag it
  between a Retina and a non-Retina screen and it will look soft until
  you switch it off and on again.
- The position is written when the camera is switched off or Knips quits
  from the menu. Force-quitting loses the last move.

## Exporting

The `--out` extension picks what gets written.

```sh
./build/knips export --in=demo.mp4 --out=demo.gif
./build/knips export --in=demo.mp4 --out=demo.gif --width=800 --fps=15
./build/knips export --in=demo.mp4 --out=demo.gif --trim=1.5,4
./build/knips export --in=demo.mp4 --out=demo.apng --width=800
./build/knips export --in=demo.mp4 --out=cut.mp4 --trim=1.5,3.5
```

**`.gif`** reads the movie twice: once to sample colours for a single
global palette, once to write the frames. The last line reports the size,
frame count, playback length, file size, and how many colours the palette
ended up with. If it says `6-bit histogram`, the source held more than a
million distinct colours and the palette fell back to a coarser one —
unusual for a screen recording.

**`.apng`** reads it once and quantises nothing: truecolour, so the
result is exactly what the scaler produced. Expect roughly ten to twenty
times a GIF's size for a few dB of quality, which is the trade the format
exists to offer. `--no-dither` has no meaning here.

**`.mp4` / `.mov`** with `--trim` is a passthrough trim: the same coded
samples copied into a new container, no decode and no re-encode, so the
picture is bit-identical to the source and the export takes about as long
as a file copy. `--fps`, `--width` and `--no-dither` do not apply and say
so. `--trim` is required — without a range it would only be a copy — and
the input must already be a movie: there is no path from a `.gif`.

`--trim=start,end` takes seconds with an optional decimal part, and
either side may be left out: `--trim=2,` keeps everything from two
seconds on, `--trim=,5` keeps the first five. `--width` scales down and
keeps the aspect ratio; a width above the movie's own is treated as "the
movie's". Frame delays come from the recording's own presentation stamps
snapped to the requested rate, so an idle stretch stays idle instead of
being padded out, and a steady one gets a steady cadence instead of
alternating delays.

A big export prints one line of advice to stderr — a canvas at or past
1280×720, or a file past 20 MB. It suggests `--width=800` or `--fps=15`
when those would help, and a shorter `--trim` when you are already at
both. The file is still written and the exit code is still 0.

A source whose video track carries a rotation or mirroring matrix — a
phone recording held sideways, say — is refused rather than exported the
wrong way up; Knips's own recordings never carry one.

## Flags

```text
knips app                       menu-bar app; no options
knips record --out=<file>       .mp4 or .mov (required; replaced if present)
              [--display=N]      index from `knips displays` (default: main)
              [--window=ID]      one window, id from `knips windows`
              [--rect=x,y,w,h]   region of the display in points
              [--fps=N]          1–120 (default 30)
              [--scale=auto|1|2] pixels per point (default auto)
              [--no-cursor]      hide the pointer
              [--bitrate=N]      average bits/s (default derived from size × fps)
              [--audio=none|system|mic|both]
                                 one AAC track per source (default none)
knips export --in=<file>        .mp4 or .mov (required)
              --out=<file>       .gif, .apng, or .mp4/.mov for a passthrough
                                 trim (required; replaced if present)
              [--fps=N]          1–50 (default 20); GIF and APNG only
              [--width=N]        16–4096; scales down, keeps the aspect ratio
              [--trim=start,end] seconds, decimals allowed, either side optional
                                 (required for a movie --out)
              [--no-dither]      skip Floyd–Steinberg dithering; GIF only
knips displays
knips windows
knips probe
knips --version
```

`--window` and `--rect` are mutually exclusive.

### Audio

| `--audio=` | What is recorded | Needs |
| --- | --- | --- |
| `none` (default) | nothing | — |
| `system` | the audio ScreenCaptureKit mixes for the captured content | macOS 13 |
| `mic` | the system default microphone | macOS 15 |
| `both` | both, as **two separate tracks** | macOS 15 |

Each source becomes its own AAC track at 48 kHz stereo, 128 kbit/s. The
microphone arrives in the device's own format and AVAssetWriter's
encoder converts it, so a mono 44.1 kHz mic still lands on that track.

**`both` does not mix.** The file gets two audio tracks, and most
players play only the first (system audio). Both are there:

```sh
# QuickTime Player: View ▸ Show A/V Controls, then pick the track.
ffprobe -v error -show_entries stream=index,codec_type,channels demo.mp4

# Mix them down to one track:
ffmpeg -i demo.mp4 -filter_complex '[0:a:0][0:a:1]amix=inputs=2[a]' \
  -map 0:v -map '[a]' -c:v copy mixed.mp4

# Or keep just the microphone:
ffmpeg -i demo.mp4 -map 0:v -map 0:a:1 -c copy mic-only.mp4
```

Mixing in-process is deliberately not in this version.

**Microphone permission** is a second TCC grant, separate from Screen
Recording. From a terminal the grant belongs to the terminal app, so
macOS prompts once for it (or you enable it under System Settings ▸
Privacy & Security ▸ Microphone). `Knips.app` carries its own
`NSMicrophoneUsageDescription` so it can prompt as itself once the
menu-bar app gains an audio option; today `--audio` is CLI-only.

## Verifying a change end-to-end

```sh
lwpt format --check && lwpt build && lwpt test
./build/knips probe
./build/knips record --out=/tmp/check.mp4 --rect=0,0,640,360 --fps=60
# Ctrl-C after ~5 s, then:
open /tmp/check.mp4
./build/knips export --in=/tmp/check.mp4 --out=/tmp/check.gif --width=640
./build/knips export --in=/tmp/check.mp4 --out=/tmp/check.apng --width=640
./build/knips export --in=/tmp/check.mp4 --out=/tmp/cut.mp4 --trim=1,3
open /tmp/check.gif /tmp/check.apng /tmp/cut.mp4
```

Check the reported size (1280x720 at scale 2), the duration against the
wall clock, and that dropped frames are near zero. For the GIF and the
APNG, check that the playback length matches the trimmed range and that
Preview loops rather than stopping at the last frame. For the trim,
`ffprobe /tmp/cut.mp4` should report the same codec, profile and
dimensions as the source and a duration of 2 s.

## Development loop

```sh
lwpt format          # canonical style (source/capture/** is exempt)
lwpt build && lwpt test
lefthook install     # once per clone: pre-commit format hook
```

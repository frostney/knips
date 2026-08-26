# Quick start

## Executive Summary

- Prereqs: macOS on Apple silicon, FPC 3.2.2, lwpt ≥ 0.7.0 on PATH.
- `lwpt install` → `lwpt build` → `./build/knips probe` → `./build/knips
  record --out=demo.mp4`, Ctrl-C to stop.
- `./build/knips app` is the menu-bar version: click the icon, drag a
  rectangle, click again to stop. **Camera** adds a draggable floating
  camera window that gets recorded along with everything else.
- `./build/knips export --in=demo.mp4 --out=demo.gif` turns the
  recording into an animated GIF, optionally trimmed and scaled.
- Grant Screen Recording on first run; a rebuilt binary re-prompts.
- `lwpt test` runs the neutral suites on any OS, including Linux CI.

## Prerequisites

- macOS 13+ on Apple silicon (the tested target). ScreenCaptureKit needs
  12.3; window capture via `initWithDesktopIndependentWindow:` and system
  audio (`--audio=system`) need 13.
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
| Stop Recording | Enabled only while recording. |
| Cancel selection | Enabled only while selecting. The overlay covers the menu bar, so this only matters if the overlay failed to open. |
| Camera | Floating camera window; checked while it is up. Available in every state, recording included. |
| Recordings folder | Opens `~/Movies/knips/` in Finder. |
| Last error: … | Only visible after a failure; the full text is in Console.app. |
| Quit Knips | Stops a running recording first. |

While recording the title reads `⏺ 0:07` and ticks once a second, and the
menu is detached so **one click on the icon stops** — Kap's gesture. The
price of that gesture is that Quit is unreachable until you stop; one
click does it. The finished file lands in
`~/Movies/knips/knips-YYYYMMDD-HHMMSS.mp4` and is revealed in Finder.

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

## Exporting a GIF

```sh
./build/knips export --in=demo.mp4 --out=demo.gif
./build/knips export --in=demo.mp4 --out=demo.gif --width=800 --fps=15
./build/knips export --in=demo.mp4 --out=demo.gif --trim=1.5,4
```

`export` reads the movie twice: once to sample colours for a single
global palette, once to write the frames. The last line reports the size,
frame count, playback length, file size, and how many colours the palette
ended up with.

`--trim=start,end` takes seconds with an optional decimal part, and
either side may be left out: `--trim=2,` keeps everything from two
seconds on, `--trim=,5` keeps the first five. `--width` scales down and
keeps the aspect ratio; a width above the movie's own is treated as "the
movie's". Frame delays come from the recording's own presentation
stamps, so an idle stretch stays idle instead of being padded out.

Only `.gif` is accepted for `--out` in this release, and trimming an
`.mp4` into another `.mp4` is not supported — that would need a
re-encoder, and Knips is not an editor. A source whose video track
carries a rotation or mirroring matrix — a phone recording held
sideways, say — is refused rather than exported the wrong way up;
Knips's own recordings never carry one.

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
              [--audio=none|system]
                                 system audio onto an AAC track (default none)
knips export --in=<file>        .mp4 or .mov (required)
              --out=<file>       .gif (required; replaced if present)
              [--fps=N]          1–50 (default 20)
              [--width=N]        16–4096; scales down, keeps the aspect ratio
              [--trim=start,end] seconds, decimals allowed, either side optional
              [--no-dither]      skip Floyd–Steinberg dithering
knips displays
knips windows
knips probe
knips --version
```

`--window` and `--rect` are mutually exclusive. `--audio=system` needs
macOS 13; it records the audio ScreenCaptureKit mixes for the captured
content, not the microphone.

## Verifying a change end-to-end

```sh
lwpt format --check && lwpt build && lwpt test
./build/knips probe
./build/knips record --out=/tmp/check.mp4 --rect=0,0,640,360 --fps=60
# Ctrl-C after ~5 s, then:
open /tmp/check.mp4
./build/knips export --in=/tmp/check.mp4 --out=/tmp/check.gif --width=640
open /tmp/check.gif
```

Check the reported size (1280x720 at scale 2), the duration against the
wall clock, and that dropped frames are near zero. For the GIF, check
that the playback length matches the trimmed range and that Preview
loops it rather than stopping at the last frame.

## Development loop

```sh
lwpt format          # canonical style (source/capture/** is exempt)
lwpt build && lwpt test
lefthook install     # once per clone: pre-commit format hook
```

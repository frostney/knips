# Quick start

## Executive Summary

- Prereqs: macOS on Apple silicon, FPC 3.2.2, lwpt ≥ 0.7.0 on PATH.
- `lwpt install` → `lwpt build` → `./build/opname probe` → `./build/opname
  record --out=demo.mp4`, Ctrl-C to stop.
- `./build/opname export --in=demo.mp4 --out=demo.gif` turns the
  recording into an animated GIF, optionally trimmed and scaled.
- Grant Screen Recording on first run; a rebuilt binary re-prompts.
- `lwpt test` runs the neutral suites on any OS, including Linux CI.

## Prerequisites

- macOS 13+ on Apple silicon (the tested target). ScreenCaptureKit needs
  12.3; window capture via `initWithDesktopIndependentWindow:` needs 13.
- FreePascal **3.2.2** (`brew install fpc`).
- **lwpt** on PATH — release binary, or `./bootstrap.sh` in the lwpt repo
  and use `<lwpt-repo>/build/lwpt`.

## Zero to working

```sh
lwpt install       # cli + testing from the lwpt 0.7.0 tag into .lwpt/modules
lwpt build         # build/opname
./build/opname probe
```

`probe` must print `probe: ok`. It registers the runtime-built stream
output class, asks ScreenCaptureKit for displays and windows (this is
where the **Screen Recording** prompt appears), and opens then cancels an
AVAssetWriter on a temp file. If any line fails, read
[docs/spikes/0001-runtime-objc-class.md](spikes/0001-runtime-objc-class.md)
before touching code.

```sh
./build/opname displays
./build/opname record --out=demo.mp4            # main display, auto scale, 30 fps
```

Press Ctrl-C once. The last line reports size, duration, and frame
counts; open the file in QuickTime Player.

## Exporting a GIF

```sh
./build/opname export --in=demo.mp4 --out=demo.gif
./build/opname export --in=demo.mp4 --out=demo.gif --width=800 --fps=15
./build/opname export --in=demo.mp4 --out=demo.gif --trim=1.5,4
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
re-encoder, and opname is not an editor. A source whose video track
carries a rotation or mirroring matrix — a phone recording held
sideways, say — is refused rather than exported the wrong way up;
opname's own recordings never carry one.

## Flags

```text
opname record --out=<file>       .mp4 or .mov (required; replaced if present)
              [--display=N]      index from `opname displays` (default: main)
              [--window=ID]      one window, id from `opname windows`
              [--rect=x,y,w,h]   region of the display in points
              [--fps=N]          1–120 (default 30)
              [--scale=auto|1|2] pixels per point (default auto)
              [--no-cursor]      hide the pointer
              [--bitrate=N]      average bits/s (default derived from size × fps)
opname export --in=<file>        .mp4 or .mov (required)
              --out=<file>       .gif (required; replaced if present)
              [--fps=N]          1–50 (default 20)
              [--width=N]        16–4096; scales down, keeps the aspect ratio
              [--trim=start,end] seconds, decimals allowed, either side optional
              [--no-dither]      skip Floyd–Steinberg dithering
opname displays
opname windows
opname probe
opname --version
```

`--window` and `--rect` are mutually exclusive.

## Verifying a change end-to-end

```sh
lwpt format --check && lwpt build && lwpt test
./build/opname probe
./build/opname record --out=/tmp/check.mp4 --rect=0,0,640,360 --fps=60
# Ctrl-C after ~5 s, then:
open /tmp/check.mp4
./build/opname export --in=/tmp/check.mp4 --out=/tmp/check.gif --width=640
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

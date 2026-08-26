# Quick start

## Executive Summary

- Prereqs: macOS on Apple silicon, FPC 3.2.2, lwpt ≥ 0.7.0 on PATH.
- `lwpt install` → `lwpt build` → `./build/opname probe` → `./build/opname
  record --out=demo.mp4`, Ctrl-C to stop.
- `./build/opname app` is the menu-bar version: click the icon, drag a
  rectangle, click again to stop.
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

## The menu bar app

```sh
./build/opname app          # runs until you quit from the menu
tools/make-app.sh           # or wrap it: build/Opname.app, double-clickable
```

A `◉` appears in the menu bar. Clicking it opens:

| Item | What it does |
| --- | --- |
| Record Region… | Dims every screen, crosshair; drag a rectangle, release to start. **Esc** cancels. |
| Record Display | Records the main display straight away. |
| Stop Recording | Enabled only while recording. |
| Cancel selection | Enabled only while selecting. The overlay covers the menu bar, so this only matters if the overlay failed to open. |
| Recordings folder | Opens `~/Movies/opname/` in Finder. |
| Last error: … | Only visible after a failure; the full text is in Console.app. |
| Quit opname | Stops a running recording first. |

While recording the title reads `⏺ 0:07` and ticks once a second, and the
menu is detached so **one click on the icon stops** — Kap's gesture. The
price of that gesture is that Quit is unreachable until you stop; one
click does it. The finished file lands in
`~/Movies/opname/opname-YYYYMMDD-HHMMSS.mp4` and is revealed in Finder.

If Screen Recording has not been granted, the recording fails
immediately, the icon goes back to `◉`, and the reason shows up as
`Last error: …`. opname does not retry — grant the permission in System
Settings › Privacy & Security › Screen Recording and click again.

## Flags

```text
opname app                       menu-bar app; no options
opname record --out=<file>       .mp4 or .mov (required; replaced if present)
              [--display=N]      index from `opname displays` (default: main)
              [--window=ID]      one window, id from `opname windows`
              [--rect=x,y,w,h]   region of the display in points
              [--fps=N]          1–120 (default 30)
              [--scale=auto|1|2] pixels per point (default auto)
              [--no-cursor]      hide the pointer
              [--bitrate=N]      average bits/s (default derived from size × fps)
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
```

Check the reported size (1280x720 at scale 2), the duration against the
wall clock, and that dropped frames are near zero.

## Development loop

```sh
lwpt format          # canonical style (source/capture/** is exempt)
lwpt build && lwpt test
lefthook install     # once per clone: pre-commit format hook
```

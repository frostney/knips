# Quick start

## Executive Summary

- Prereqs: macOS on Apple silicon, FPC 3.2.2, lwpt ≥ 0.7.0 on PATH.
- `lwpt install` → `lwpt build` → `./build/knips probe` → `./build/knips
  record --out=demo.mp4`, Ctrl-C to stop.
- `./build/knips app` is the menu-bar version: click the icon, drag a
  rectangle, click again to stop. A red frame marks the region while it
  records, the finished clip opens in a playback window with a one-click
  GIF export, and **Camera ▸ Show Camera** adds a draggable floating
  camera window that gets recorded along with everything else —
  optionally with **Camera ▸ Blur Background**, which keeps you sharp and
  blurs the room behind you.
- **The app records raw and renders what you get.** The take is captured
  with no pointer in its pixels and no zoom in its framing; on stop, Knips
  renders the movie you asked for from it — the pointer drawn back, Zoom
  on Click applied — with the audio copied across untouched. The raw take
  stays beside it as `<name>-raw.mp4`, so the playback window's
  **Effects** control and its **Re-export** button can produce the file
  again with a different choice, as often as you like.
- **That means a take is normally two movies and two sidecars, and Knips
  never deletes any of them.** `~/Movies/knips/` grows at roughly twice
  the rate it used to; the raw take is what makes the effects changeable
  afterwards, and deleting it is a decision only you can make (delete
  `<name>-raw.mp4` and `<name>-raw.knips.jsonl` together — the playback
  window then greys its Effects out and says why). A **window** recording
  is raw and editable too whenever an effect could apply — captured from
  the display, cropped to the window, so overlapping windows appear in
  the picture. Switch every effect off before recording a window to get
  the clean desktop-independent capture instead; that one is written
  once, as a single movie and a single sidecar, and nothing can be
  applied to it after the fact.
- **Follow Mouse** is the one recording setting left in the menu, because
  a pan decides which pixels are read off the screen and cannot be undone
  afterwards. Zoom on Click, Smooth Cursor and Big Cursor moved into the
  Effects control.
- `./build/knips render --in=demo-raw.mp4 --effects=zoom,big-cursor` is
  the same render from a script. `knips record` is unchanged: it still
  bakes the system pointer in, and `--big-cursor` / `--smooth-cursor`
  still mean what they meant.
- `./build/knips export --in=demo.mp4 --out=demo.gif` turns the
  recording into an animated GIF, optionally trimmed and scaled;
  `--out=demo.apng` writes truecolour APNG instead, and `--out=cut.mp4
  --trim=1.5,3.5` trims without re-encoding.
- Grant Screen Recording on first run; a rebuilt binary re-prompts.
- `lwpt test` runs the neutral suites on any OS, including Linux CI.
  `tools/linux-ci.sh` runs them (and a Linux `lwpt build`) in Docker from
  a Mac; `tools/win64-cross.sh` compiles and links the same tree for
  64-bit Windows. See [ports.md](ports.md).

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
output class, checks the app's Dock promotion and main menu, asks
ScreenCaptureKit for displays and windows (this is where the **Screen
Recording** prompt appears), and opens then cancels an AVAssetWriter on a
temp file. Over SSH the Dock line reads `skipped (no window server)`
rather than failing — that one check is the only part that talks to
AppKit, and `knips app` refuses outright there for the same reason. If
any other line fails, read
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
| Stop Recording | Enabled only while recording, and shows **⌘⇧2** — the system-wide shortcut below. |
| Cancel selection | Enabled only while selecting. The overlay covers the menu bar, so this only matters if the overlay failed to open. |
| Camera ▸ | Three checkboxes about the picture-in-picture window, all available in every state, recording included. **Show Camera** puts it on screen. **Circular Camera** makes it a circle instead of a rounded rectangle. **Blur Background** blurs the room behind you and leaves you sharp. All three apply straight away and are remembered between launches. |
| Follow Mouse (region) | The one effect that has to be chosen before a recording, because it decides which pixels are read off the screen at all: a **region** recording pans to keep the pointer inside the middle third of the frame, and the red frame moves with it. Whole-display and window recordings ignore it, since a display has nowhere to pan. Not changeable mid-recording; remembered between launches. Zoom on Click, Smooth Cursor and Big Cursor used to sit beside it and are now in the playback window's **Effects** control, where they can be chosen — and changed — after the take exists. |
| Audio ▸ | Two independent checkboxes, **System Audio** and **Microphone**. Tick either, both, or neither: each ticked source becomes its own AAC track in the file. Remembered between launches; not changeable mid-recording. |
| Recordings folder | Opens `~/Movies/knips/` in Finder. |
| Last error: … | Only visible after a failure, and after anything that switched a recording setting off for one recording; the full text is in `~/Library/Logs/Knips.log`. |
| Quit Knips | Stops a running recording first. |

While recording the title reads `⏺ 0:07` and ticks once a second, and the
menu is detached so **one click on the icon stops** — Kap's gesture — as
does **⌘⇧2** from anywhere. The
price of that gesture is that Quit is unreachable from the icon until you
stop; one click does it. (⌘Q works if a playback window has put the app's
menu bar up; it stops and finalises the recording first, exactly as the
menu's Quit does.) The finished file lands in
`~/Movies/knips/knips-YYYYMMDD-HHMMSS.mp4`.

**⌘⇧2 stops a recording from anywhere.** It is the one thing the icon
cannot do: while Knips records, the icon has no menu (a click stops it),
and the window you are demonstrating in is the last place you should
have to leave. The shortcut is registered with the system — it costs no
extra permission, and no key you press anywhere else is ever seen by
Knips — and it *only* stops. It never starts a recording, because a
global shortcut that starts one starts one by accident; outside a
recording it does nothing at all.

If the shortcut could not be registered (something else in this process
already holds it), the `Last error: …` line says so and the app carries
on without it. **Pressing the keys is the one part of this a test cannot
check** — this project's tooling never synthesises input, and the
system reports success for registering a chord it will not actually
deliver. `knips probe` verifies the registration and the constants;
whether the chord really fires is a human check:

```sh
./build/knips app
# Menu ▸ Record Display, then press ⌘⇧2 anywhere.
# The icon should go back to ◉ and a playback window should open.
```

**Audio.** *Audio ▸ System Audio* and *Audio ▸ Microphone* are
independent, so all four combinations are reachable: neither is a silent
recording, either alone is that one source, and both gives you two
separate AAC tracks (see [Audio](#audio) below for what to do with two
tracks). If you upgraded from a version with *Record System Audio*, the
box you had ticked comes across as *System Audio*.

The microphone needs macOS 15 — where ScreenCaptureKit has no microphone
capture the item is disabled and says so — and it needs the Microphone
privacy grant, which is separate from Screen Recording. The first
microphone recording prompts for it.

Knips does **not** refuse a recording over that grant, and the reason is
measured: on this macOS ScreenCaptureKit captured the microphone
perfectly well while the privacy status still read *not determined*, so
refusing on it would refuse recordings that work. Instead, ticking
*Microphone* while the grant reads denied says so straight away on the
`Last error: …` line — and, whatever the cause, a finished recording
whose microphone delivered **no audio at all** says that too. That last
check is the one that cannot be fooled: it counts what actually arrived.

**The recording frame.** A region recording puts a red frame around the
rectangle for as long as it runs, so there is never a doubt about what is
being captured. The frame is a passthrough window — clicks go straight
through it — and it is kept out of the file twice over: it is stroked in
the two points *outside* the recorded rectangle, and its window id is
passed to ScreenCaptureKit's `excludingWindows:` so the compositor never
draws it into the stream at all. Display and window recordings get no
frame.

**Zoom on Click and Follow Mouse.** Both change what the *file* shows and
neither changes anything on screen or the size of the finished movie —
they move the rectangle the deliverable is taken from, not the video's
dimensions. They are no longer the same kind of setting, though, and the
difference is worth knowing:

**Follow Mouse** has to be chosen *before* you start, because a pan
decides which pixels are read off the screen at all and nothing
afterwards can recover what was never captured. It is greyed out while a
recording runs. It only works for a region: a full-display capture
already contains everywhere the pointer can go, and a window recording
follows the window rather than the pointer.

**Zoom on Click** is decided *after* the take exists, in the playback
window's **Effects** control, because a crop is taken from pixels that
are already in the file. It works for a region, for a whole display and
for a window recording, and it **composes with a pan**: on a Follow Mouse
take the click zooms inside wherever the frame had got to at that
instant, exactly as the live pair used to. A click the pan has drifted
away from is answered as closely as the captured rectangle allows rather
than refused.

**Big Cursor.** A third checkbox in the same group, and the only one that
changes the picture rather than the framing: the system pointer is left
out of the capture and an enlarged arrow is drawn into every frame in its
place. The drawn pointer is always the arrow — it does not become an
I-beam over text or a hand over a link the way the real one does. It is
part of the video, so it survives a GIF or APNG export — which the
system pointer also does, only at its ordinary size. It tracks
a zoom or a pan (it is placed against whatever rectangle is being
captured at that instant) but does not grow with one. Off by default and
greyed out while a recording runs.

Clicks on the menu bar never zoom — including the one on the Knips icon
that stops the recording, which would otherwise end every full-screen
capture by zooming into the top corner.

Two things switch the effects off for a single recording rather than
failing it, both reported on the `Last error: …` line and in
`~/Library/Logs/Knips.log`.
If the red frame around a region could not be excluded from the capture,
Follow Mouse is refused rather than record its own frame sliding into
shot. And if ScreenCaptureKit refuses five source-rectangle changes in a
row, the zoom and the pan stop for the rest of that recording — the file
keeps being written either way.

```sh
defaults write knips KnipsZoomOnClick -bool true   # or use the menu
defaults write knips KnipsFollowMouse -bool true
```

**The playback window.** When a recording finishes, it opens in a normal
window with AVKit's transport controls and three buttons. It is the one
window Knips has that behaves like a document window: while it is open the
app appears **in the Dock and in ⌘-Tab**, with a menu bar of its own —
*Knips ▸ About Knips, Quit Knips ⌘Q* and *Window ▸ Close ⌘W, Minimize
⌘M*. Close the window, by any route, and the app drops back out of the
Dock to being menu-bar-only. The `◉` in the menu bar works exactly the
same either way. (The generic application icon in the Dock is expected —
the bundle has no `.icns` yet.)

Starting any recording closes the playback window first, so the app's own
Dock tile and menu bar are never in the frame — the whole reason Knips is
a menu-bar-only process the rest of the time.

| Control | What it does |
| --- | --- |
| Effects ▾ | **Zoom on Click**, **Smooth Cursor**, **Big Cursor**. What is ticked here is what the movie was rendered with, and what *Re-export* and *Export as GIF…* will use. The two cursor items are one setting — ticking one unticks the other, and clicking the ticked one turns the pointer off. An item the take cannot take is greyed out with the reason as its tooltip: a take where nothing was clicked has nothing to zoom to, a take whose capture was already zooming cannot be zoomed again, a window recording made with every effect switched off was captured the desktop-independent way and has no raw take, and a recording made before this existed has none either. Your choice becomes the default for the next recording. |
| Re-export | Renders the movie again from the raw take with what Effects now says, replacing it in place. The title counts it out; the player reloads when it is done. |
| Export as GIF… | Writes `<recording>.gif` beside the movie at 20 fps and reveals it in Finder, from the **raw** take and with the same Effects selection — so the GIF moves the way the movie beside it moves. Retina recordings export at their **point** size (pixel width ÷ capture scale — an exact 2:1 reduction, which is what keeps small text readable); scale-1 recordings cap at 800 px. A large result is noted on the `Last error:` line. Use `knips export --width=N` for anything else. |
| Reveal in Finder | Shows the `.mp4`. |
| Close | Closes the window and releases the player. |

The export runs on the main thread, so nothing responds while it is
going: the title counts up (`Exporting… 42%`), the buttons are disabled,
every menu item is a no-op, and **Quit is refused** until it finishes —
⌘Q included (it says so under `Last error: …`). Closing the window is
refused too, by every route: the buttons, the titlebar's close button and
⌘W all simply do nothing until the export is done. The buttons come back
when it is done and the `.gif` is revealed in Finder. For anything the
button's
defaults do not cover — a different rate, a width, a trim — use
`knips export` (below).

**Remembered settings.** The two Audio checkboxes, Follow Mouse, the
saved effect defaults, the camera's three and the last region live in
`NSUserDefaults` under `KnipsAudioSystem`, `KnipsAudioMicrophone`,
`KnipsFollowMouse`, `KnipsEffectZoom`, `KnipsEffectCursor`,
`KnipsCameraVisible`, `KnipsCameraShape`, `KnipsCameraBlur`,
`KnipsCameraOriginX`/`Y` and `KnipsLastRegion*`. `KnipsRecordSystemAudio` is
the key the single old checkbox used; it is read once, only when
`KnipsAudioSystem` has never been written, and is never written again.
`KnipsZoomOnClick`, `KnipsBigCursor` and `KnipsSmoothCursor` are the three
menu toggles the effects replaced, and are read the same way: once, only
where the new key is absent, and never written again — a ticked Big Cursor
becomes `KnipsEffectCursor = big`, a ticked Smooth Cursor becomes
`smooth`, and neither ticked becomes `smooth` as well, because those takes
had the system pointer in their frames and a drawn one is the nearest
thing a raw take can offer.
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

**Camera ▸ Show Camera** puts a small rounded window with your camera in
it at the bottom right of the main screen; the item carries a checkmark
while it is up. Knips does no compositing — the camera is simply a window, and
ScreenCaptureKit records it like any other. It floats above ordinary
windows, follows you across Spaces, and stays up across recordings until
you switch it off or quit.

**It is mirrored**, the way every camera preview you have ever used is:
you raise your left hand and the picture's left hand goes up. Because the
recorder captures the window exactly as it looks, the *recording* is
mirrored too — which is what you want, and what Kap does. Text held up to
the camera will read backwards in the file; that is the trade every
selfie mirror makes.

**Drag it from anywhere in the picture** — there is no title bar — and it
**snaps to the nearest corner** of the screen when you let go, tucked in
by the same margin it started with. Drop it in the middle of the screen
and it will pick a corner for you; drop it back where it was and it stays
put. A plain *click* is not a drag: the window has to travel a few points
before letting go moves it anywhere, so clicking the picture never throws
it into a corner. Grabbing it again while it is still gliding takes it
from wherever it has got to.

**Camera ▸ Circular Camera** makes it a circle. The window becomes square and the
picture is cropped to a disc about the middle of the frame; the switch
happens live, about the window's own centre, and the choice is
remembered.

The circle **loses the sides of the picture, it does not move the
middle**. A square window over a wider feed keeps the horizontal centre
and throws away equal slices left and right — so if you are sitting off
to one side of the frame, the circle is where you notice. Move the
camera's *view*, not the window: sit centred, or use the rectangle.

**A recording docks it, and it rides along.** Start a *Record Region…*,
*Record Last Region* or *Record Window* while the camera is up and it
moves into the nearest corner *inside* the rectangle being recorded.
When the recording stops it travels back to where it was before. Nothing
happens for a display recording — that already contains the camera
wherever it stands — or if the camera is off.

For a **region**, that puts the camera in the file: Kap's
picture-in-picture, without any compositing.

For a **window**, the plain window capture would not — ScreenCaptureKit
composits that one window and nothing drawn on top of it, measured. So a
window recording is captured from the *display* instead, through a
rectangle sitting exactly on the window and following it as you drag it.
The camera really is in the file.

That same switch is what makes **the effects work on a window
recording**. A plain window capture is a picture of something that moves
under the recorder with no way to find out, so no pointer can be drawn
back into it and no zoom can be computed for it — which is why a window
take used to come out with the system pointer baked in and every effect
greyed out. Captured from the display, it is a raw take like any other:
Smooth Cursor, Big Cursor and Zoom on Click all apply, and can be changed
afterwards in the playback window.

The price is that anything else in front of the window — a notification, a
menu pulled down over it, another app dragged across — is in the file too.
Knips pays it only where it buys something: with the camera off *and* the
pointer switched off in the Effects control *and* Zoom on Click off, a
window recording goes back to capturing the window alone, because there
would be nothing to render into it anyway.

And it **stays inside** the rectangle while the rectangle moves. With
*Follow Mouse* on, a region pans across the display and the camera pans
with it, keeping the corner it started in. A recorded window goes
wherever you drag it, and the camera follows about five times a second.
Drag the picture yourself mid-recording and it carries on following from
wherever you dropped it — you keep the corner you chose, not the one the
dock picked. Close a recorded window mid-take and the camera simply
stops following rather than chasing a window that is not there; it stays
where it last was.

Where you left it and whether it was on are remembered, so — **once
camera access is granted** — the next launch brings it back to the same
corner. A position saved on a display that is no longer attached, or one
the Dock has since covered, is discarded rather than restored somewhere
you cannot reach. If access has *not* been granted, launch does nothing
at all: Knips will not open a permission prompt seconds after login.

**Camera ▸ Blur Background** keeps you sharp and blurs everything behind
you — the portrait effect, done by Knips rather than by macOS. (macOS has
one of its own in Control Center, but AVFoundation only lets an app
*read* whether it is on, so Knips cannot switch it on for you and it
would apply to every app at once if you did.) Switching it on or off
takes effect immediately with no camera warm-up, and the choice is
remembered.

It costs a Vision person-segmentation pass and a CoreImage composite on
every frame. `./build/knips probe` prints what that costs on your Mac —
about 8 ms a frame at 640×480 on an M-series machine, against the 33 ms
a 30 fps preview has to spend — and says so plainly if your Mac is
slower than the preview. The mask is Vision's *fast* quality level, which
is the one meant for a live stream; the picture is mirrored on this path
exactly as it is without the blur.

The first time you switch the camera on, macOS asks for the **Camera**
permission. Answer the prompt, then choose *Show Camera* again — Knips refuses
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
- A drag you make *during* a docked recording is not kept: when the
  recording stops, the camera returns to where it stood before the
  recording moved it. It returns to the screen it was on, too, even if
  you recorded on a different one.

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
              [--big-cursor]     draw an enlarged pointer into the frames;
                                 display targets only, not with --no-cursor
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
knips mcp                       MCP server on stdin/stdout; no options
knips probe
knips --version
```

`--window` and `--rect` are mutually exclusive.

## The MCP server

`knips mcp` speaks the Model Context Protocol on stdin/stdout, so an AI
client can record and export without a shell. The protocol is
[pascal-mcp-sdk](https://github.com/frostney/pascal-mcp-sdk)'s; the
tools are the CLI's own code paths with JSON arguments instead of flags,
validated by the same `Knips.Options` rules.

Register it the way any local MCP server is registered — the command is
the built binary with one argument:

```json
{
  "mcpServers": {
    "knips": { "command": "/absolute/path/to/build/knips", "args": ["mcp"] }
  }
}
```

| Tool | Arguments | Returns |
| --- | --- | --- |
| `list_displays` | — | index, size in points, backing scale, which is main |
| `list_windows` | — | window id, size, application, title |
| `record_start` | `out?`, `overwrite?`, `display?`, `window?`, `left`/`top`/`width`/`height`?, `fps?`, `scale?`, `audio?`, `cursor?`, `big_cursor?`, `bitrate?` | the path, pixel size, and frame rate it started at |
| `record_stop` | — | the path, duration, frame counters, bytes |
| `record_status` | — | whether it is recording, elapsed seconds, frames so far |
| `export_gif` | `in`, `out?`, `fps?`, `width?`, `trim_start?`, `trim_end?`, `dither?` | the path, pixel size, frames, bytes |
| `export_apng` | `in`, `out?`, `fps?`, `width?`, `trim_start?`, `trim_end?` | as above |
| `export_trim` | `in`, `out?`, `trim_start?`, `trim_end?` | the range kept and the bytes written |

Every argument except `in` is optional. An omitted `out` becomes
`~/Movies/knips/knips-YYYYMMDD-HHMMSS.mp4` for a recording — the same
name the menu-bar app uses — and, for an export, the input path with the
format's extension (a trim adds `-trim`, since it may not overwrite its
own input). A region is four separate integers, all four or none. Every
tool declares an `outputSchema`, so a client knows the shape of
`structuredContent` before it calls.

Paths in and out are absolute. A relative `in`/`out` is expanded against
the server's working directory, and results always report the expanded
path — a client has no way to resolve a relative path against a
directory it never saw.

**`record_start` will not silently replace a file.** `knips record`
overwrites its `--out` without asking, which is right for a path a
person typed; an agent guesses paths, so over MCP an existing `out` is
refused by name unless `"overwrite": true` is passed. Exports keep the
CLI's replace-in-place behaviour, since their default path is derived
from `in` rather than guessed.

**`export_trim` refuses `fps`, `width` and `dither`** instead of
ignoring them. A passthrough trim copies coded samples, so those cannot
be honoured, and the SDK ignores arguments a schema does not declare —
an agent that asked for a scaled trim would otherwise get an unscaled
movie and no hint that the request was dropped.

**Recording does not block the server.** `record_start` returns as soon
as the capture is running and the loop goes back to reading stdin;
ScreenCaptureKit delivers frames on its own queue meanwhile, so
`record_status` and everything else keep answering. `record_stop`
finalises the file. Only one recording runs at a time: a second
`record_start` is refused in-band, naming the file already being
written. Closing stdin is the shutdown signal, and it is also what lets
the server finalise a recording still in flight — a killed process loses
the movie the same way `Ctrl-C`-twice does.

If the writer dies mid-recording — a full disk, a directory that went
away — `record_status` reports the failure as an error result, stops the
session, and says whether the partial file could still be finalised.
Frames stop being counted the moment the writer leaves its writing
state, so a status that kept answering `recording: true` with frozen
counters would leave a client waiting for a file that will never grow.

**Permission.** Screen Recording is granted per *host application*, not
per user, and an MCP server inherits the attribution of whatever
launched it. The first capture therefore makes macOS prompt the MCP
client's own app — Claude Desktop, an editor, a terminal — and until
that is granted in System Settings ▸ Privacy & Security ▸ Screen
Recording, every `record_start` fails with the framework's message. The
same is true of `list_displays` and `list_windows`, which query
ScreenCaptureKit.

By hand, without a client (the stdio binding is one JSON-RPC message per
line):

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_displays","arguments":{}}}' \
  | ./build/knips mcp
```

Standard output carries nothing but MCP messages; diagnostics go to
standard error.

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
`NSMicrophoneUsageDescription` so it can prompt as itself; the app's
Audio ▸ Microphone checkbox and the CLI's `--audio` share the grant.

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

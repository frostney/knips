# Architecture

## Executive Summary

- One binary: ScreenCaptureKit stream → complete-frame filter →
  AVAssetWriter input (hardware H.264) → `.mp4`/`.mov`. Knips never
  touches pixels or NAL units; it moves sample buffers.
- `--audio=system` adds SCK's audio output and a second AVAssetWriter
  input (AAC) to the same file; see [System audio](#system-audio).
- The `SCStreamOutput` object the framework calls back into is a
  **runtime-built Objective-C class** — one plain `cdecl` Pascal routine
  registered with `class_addMethod` — so the build needs no linker flags
  ([ADR-0002](adr/0002-runtime-built-objc-classes.md)). The menu bar's
  target, the selection overlay's view and its window ride on the same
  primitive.
- `knips app` is the same binary in a second shape: an Accessory-policy
  `NSApplication` with a status item, whose recording lifecycle is
  `TRecordingSession.StartCapture` … NSApp's run loop … `FinishCapture`.
  A region recording is framed by a passthrough window that is both drawn
  outside the recorded rectangle and excluded from the content filter;
  the finished clip opens in an `AVPlayerView` window with a one-click
  GIF export. See [Menu bar app](#menu-bar-app).
- Timing is taken from each sample buffer's presentation stamp; the
  writer's session starts at the first appended frame. This is what makes
  SCK's change-driven frame delivery record at real speed.
- Two threads: the main thread (run loop, signals, progress) and SCK's
  capture queue (sample delivery → append). No `cthreads`; shared counters
  sit under a pthread mutex; the capture path never raises or prints.
- Everything platform-neutral (option model, type encodings) is a unit
  with a co-located test that runs on Linux too.

## Process shape

```text
 ┌──────────────────────────── knips (one binary) ────────────────────────┐
 │                                                                        │
 │  main thread                          capture queue (GCD, SCK-owned)   │
 │  ┌──────────────────────┐             ┌──────────────────────────────┐ │
 │  │ knips.pas: CLI       │             │ KnipsStreamOutput            │ │
 │  │ TRecordingSession    │             │  (runtime-built class)       │ │
 │  │  resolve target      │             │  stream:didOutputSample…     │ │
 │  │  size geometry       │             │        │                     │ │
 │  │  TMovieWriter.Open   │   OnSample  │  TScreenStream.DeliverSample │ │
 │  │  TScreenStream.Start │◀────────────│   complete-frame filter      │ │
 │  │  CFRunLoop until ^C  │             │        │                     │ │
 │  │  TScreenStream.Stop  │             │  TMovieWriter.AppendVideo…   │ │
 │  │  TMovieWriter.Finish │             │   (mutex-guarded counters)   │ │
 │  └──────────────────────┘             └──────────────────────────────┘ │
 │                                                                        │
 │   ScreenCaptureKit  ──▶  CMSampleBuffer (BGRA)  ──▶  AVAssetWriter    │
 │                                              (VideoToolbox H.264 → mp4)│
 └────────────────────────────────────────────────────────────────────────┘
```

## Units and layering

| Layer | Units | Notes |
| --- | --- | --- |
| CLI | `knips.pas` | lwpt `cli` package: `app`, `record`, `export`, `displays`, `windows`, `probe`; SIGINT/SIGTERM → `StopRequested` |
| App | `Knips.App`, `Knips.App.Overlay`, `Knips.App.Border`, `Knips.App.Playback`, `Knips.App.State` | Status item + menu, selection overlay, the recording frame, the playback/export window, and the neutral state machine (tested) |
| Recording | `Knips.Recording` | Target → filter + geometry → writer → stream; progress; report |
| Capture | `Knips.Capture.ShareableContent`, `Knips.Capture.Stream` | SCShareableContent query (run-loop pumped); SCStream + runtime output object |
| Export (Darwin) | `Knips.Export.MovieWriter`, `Knips.Export.MovieReader`, `Knips.Export.GifPipeline` | AVAssetWriter/Input bindings; AVAssetReader/TrackOutput bindings; the two-pass GIF export |
| Export (neutral) | `Knips.Export.Gif`, `Knips.Export.Bitmap` | Median cut, dithering, LZW, GIF89a writer; BGRA buffer + resampling (both tested) |
| ObjC | `Knips.ObjC.Runtime`, `Knips.ObjC.TypeEncoding` | Class assembly via libobjc; method type encodings (tested) |
| Options | `Knips.Options` | Neutral option model, validation, derived values (tested) |
| Vendored | `source/capture/*` | CoreMedia/CoreVideo/VideoToolbox/GCD, ScreenCaptureKit externals, pthread mutex |

Nothing above the capture layer knows about `objcclass`; nothing below
the recording layer knows about the CLI. The one edge that crosses
sideways is `Knips.App.Playback` → `Knips.Export.GifPipeline`: the
playback window's *Export as GIF…* button runs the same session the
`export` subcommand does, rather than a second implementation of it.

## The GIF export

`knips export` is the mirror of `record`, and it is deliberately thin on
the Darwin side: `Knips.Export.MovieReader` turns an `.mp4`/`.mov` into
a stream of BGRA `CVPixelBuffer`s with presentation stamps, and
everything that decides what the file looks like —
`Knips.Export.Bitmap` and `Knips.Export.Gif` — is platform-neutral and
unit-tested off-device.

```text
  AVAssetReader (timeRange = --trim)
        │  BGRA CVPixelBuffer + PTS
        ▼
  decimate to --fps (integer grid over the stamps, not a cadence)
        │
        ▼
  BgraResample to --width (integer box reduce, then bilinear)
        │
        ├─ pass 1 ──▶ TGifQuantizer: 6-bit histogram over ≤32 sampled
        │              frames ──▶ median cut ──▶ one global palette
        │
        └─ pass 2 ──▶ TGifEncoder: Floyd–Steinberg ──▶ changed rectangle
                       ──▶ LZW twice, opaque and transparent, keep the
                           shorter ──▶ GIF89a + NETSCAPE2.0 loop
```

Three decisions carry most of the weight:

- **One global palette, two passes.** An `AVAssetReader` cannot seek
  backwards, so the palette pass and the encoding pass are two readers
  opened one after the other over the same `CMTimeRange`. A per-frame
  local palette would need only one pass, but it makes the colours shift
  between frames — very visible on a screen recording's flat UI — and
  costs 768 bytes of colour table per frame. The histogram is a fixed
  4 MB array of 64³ cells that accumulates *exact* 8-bit channel sums, so
  the 6-bit cells decide only which colours share a median-cut box; every
  palette entry is the count-weighted mean of the real colours in it.
- **Decimation counts grid slots, not deadlines.** Each frame's stamp is
  turned into a slot number, `floor((pts - first) * fps)`, and a frame is
  emitted when its slot is past the last one emitted. The obvious
  alternative — carrying a floating-point "next due" time forward — drops
  frames when the source rate equals the requested one, because a stamp
  that should land exactly on the deadline lands a few parts in 10^16
  below it. Counting slots also means a source slower than the target
  never accumulates a backlog of frames that are "due".
- **Delays come from the presentation stamps.** The delay written for a
  frame is the gap to the frame after it, rounded to centiseconds
  (GIF's unit) and clamped to at least 2 — browsers silently turn 0 and
  1 into 10. That is why the pipeline holds one scaled frame back: it
  cannot write frame *n*'s graphic-control block until it has seen
  frame *n+1*.
- **Changed-rectangle frames, and a transparency trial.** Every frame
  after the first is written as the bounding box of the palette indices
  that differ from the previous frame, with disposal "leave in place". A
  frame identical to its predecessor becomes a 1×1 frame carrying only
  the delay. On a *real* recording the rectangle alone is not enough:
  H.264's noise floor moves a few scattered pixels in every corner, so
  the bounding box is almost always the whole canvas. Each frame is
  therefore compressed twice — once plainly, once with the pixels inside
  the rectangle that did not actually change written as a reserved
  transparent index — and the shorter result is what reaches the file.
  Reserving that index costs one palette slot (`GifMaxOpaqueColors`).

  Trying both rather than guessing matters, because neither wins
  everywhere: transparency collapses a varied unchanged background into
  one long LZW run, but when the rectangle is already tight around real
  movement it only fragments the runs LZW would have found. Measured on
  a 1600×1200 ScreenCaptureKit recording, best-of-two is 1.92 MB against
  3.75 MB for rectangles alone; on a synthetic clip whose only motion is
  a small moving box it correctly declines transparency and keeps the
  37 kB the rectangle already achieved. The second LZW pass costs about
  20% more encoding time and nothing in quality — transparency composites
  exactly, with no drift across frames.

Memory is bounded by construction: one decoded frame (the framework's),
one scaled frame, one pending scaled frame, and two palette-index buffers
inside the encoder. Nothing accumulates with the length of the movie.

## The runtime-built output object

`Knips.Capture.Stream.EnsureStreamOutputClass` assembles
`KnipsStreamOutput` once per process:

1. `objc_allocateClassPair(NSObject, "KnipsStreamOutput", 0)`
2. `class_addIvar("knipsOwner", sizeof(Pointer))` — back-pointer to the
   owning `TScreenStream`
3. `class_addMethod("stream:didOutputSampleBuffer:ofType:",
   @StreamOutputSampleBuffer, "v@:@^vq")` — the encoding comes from
   `Knips.ObjC.TypeEncoding`, never a literal
4. `class_addProtocol(SCStreamOutput)` if the runtime has it registered
   (best effort — SCStream dispatches by selector)
5. `objc_registerClassPair`

Instances are made with `alloc`/`init` through a fixed-signature
`objc_msgSend` alias. Every method is a plain Pascal `cdecl` routine, so
FPC emits no Objective-C method-list metadata — the thing ld-prime
rejects.

## Threading model

- **Main thread** owns creation, start, stop, finish, and all output. It
  waits in `CFRunLoopRunInMode` slices so framework completion blocks
  (shareable-content query, start/stop capture, finish writing) can fire.
- **Capture queue** (`knips.capture.video`, created for the stream) runs
  `StreamOutputSampleBuffer` → `DeliverSample` → `OnSample` →
  `AppendVideoSample`. With audio on, a second queue
  (`knips.capture.audio`) runs the same path into `AppendAudioSample`.
  Rules on that path, carried from the prototype:
  no exceptions or `try..finally` (no `cthreads`, so the exception frame
  chain is process-global), no `WriteLn`, no managed-type writes outside
  `FLock`.
- **Why no cthreads:** the prototype documented cthreads' signal handler
  intercepting a benign SIGSEGV raised inside CoreMedia's XPC
  deserialisation of SCK sample buffers. lantaarn escaped it by not using
  SCK in the default build; Knips needs SCK, so it keeps the prototype's
  shape: `cmem` (libc heap, thread-safe without a thread manager) first,
  real pthread mutexes, and `IsMultiThread := True` at startup so the
  RTL's refcount updates use locked instructions.
- **`Knips.ThreadManager`:** the first on-device run showed the shape
  above is not enough by itself — with `IsMultiThread` true, FPC's
  NoThreadManager stubs hard-error (RTE 232) on the critical sections and
  events that `Classes`/`SysUtils` create and destroy in their unit init
  and finalization. The unit, placed directly after `cmem` in the program
  uses clause, installs pthread-backed implementations of exactly the
  lock and event primitives (recursive mutexes, cond-var events) while
  leaving thread creation on the error stubs: the RTL still never spawns
  or adopts a thread, and the capture queue stays foreign.
- Stop order is fixed: `TScreenStream.Stop` (waits for the framework's
  completion) *then* `TMovieWriter.Finish`, so no append can race the
  finish. The output object's owner ivar is cleared before the stream is
  released so a late callback finds `nil` and returns.
- **Completion handlers are foreign-thread code.** SCK calls
  `startCaptureWithCompletionHandler:` and
  `stopCaptureWithCompletionHandler:` back on one of its own queues, never
  the main thread (measured: `pthread_main_np()` returns 0 in both). They
  follow the capture-queue rules and only set globals the main thread
  reads while pumping.
- **One start at a time.** A `startCapture` that times out abandons its
  handler, but the framework may still run it. The handlers are global
  procedures — a `cblock` here cannot capture which attempt it belongs to
  — so a late one would falsely complete the *next* attempt: `FActive`
  with nothing capturing, a `⏺` over a zero-frame file, and a leaked
  retained `NSError`. Only the CLI was immune, because it never retried;
  the app does. `GStartPending` marks a start as outstanding, a second
  `Start` waits it out for a bounded number of slices, and refuses with
  *"a previous capture start is still pending"* rather than proceeding on
  an ambiguous flag. `ClearStartResult` releases any stale error before
  reuse.
- **`Run` is `StartCapture` + wait + `FinishCapture`.** The CLI blocks in
  its own `CFRunLoopRunInMode` slices between the two; the menu-bar app
  calls them from opposite ends of `NSApplication.run`. Both halves stay
  on the main thread, so the slice-pumping the framework's completion
  handlers need works either way — verified with a recording driven
  entirely from an `NSTimer` inside `NSApp.run`.

## Menu bar app

`knips app` sets the activation policy to `Accessory` — a process with a
menu-bar item and no Dock tile — installs one `NSStatusItem`, and hands
the thread to `NSApplication.run`. There is one state machine:

```text
         Record Region…                 mouse up (usable drag)
  asIdle ───────────────▶ asSelecting ───────────────────────▶ asRecording
     ▲                        │                                     │
     │                        │ Esc / stray click / capture failed   │ click the
     │◀───────────────────────┘                                     │ item, or
     │                                                              │ Stop
     │  Record Display / Record Window / Record Last Region ───▶     │
     │◀─────────────────────────────────────────────────────────────┘

  asIdle ──Record System Audio──▶ asIdle   (a self-transition: the command
                                            is legal only where the stream
                                            configuration is not yet fixed)
```

`Knips.App.State` owns the transition table, the status-item title, the
`~/Movies/knips/knips-YYYYMMDD-HHMMSS.mp4` naming, the selection maths,
the Record Window filter and menu titles, and the one-click GIF export's
path/width/percentage arithmetic; it is platform-neutral and has a
co-located suite, so the only untested part of the app is the Cocoa
plumbing.

Five more classes are built through `Knips.ObjC.Runtime`, none of them
an `objcclass`:

| Runtime class | Superclass | Methods |
| --- | --- | --- |
| `KnipsAppTarget` | `NSObject` | `recordRegion:`, `recordDisplay:`, `recordWindow:`, `recordLastRegion:`, `toggleSystemAudio:`, `stopRecording:`, `cancelSelection:`, `revealRecordings:`, `quitKnips:`, `timerFired:`, `startPending:`, `stopPending:`, `exportGif:`, `revealRecording:`, `closePlayback:`, `menuNeedsUpdate:` |
| `KnipsOverlayView` | `NSView` | `drawRect:`, `mouseDown:`, `mouseDragged:`, `mouseUp:`, `keyDown:`, `acceptsFirstResponder` |
| `KnipsOverlayWindow` | `NSWindow` | `canBecomeKeyWindow` (a borderless window answers NO, and then Esc never reaches the view) |
| `KnipsBorderView` | `NSView` | `drawRect:` — the frame drawn around a region while it records |
| `KnipsPlaybackDelegate` | `NSObject` | `windowWillClose:` — the one teardown path for the playback window |

Each carries an `knipsOwner` pointer ivar back to the owning Pascal
object, cleared before the Objective-C instance goes away — the same rule
as the stream output object. `KnipsOverlayView` adds an `knipsIndex`
ivar holding the screen's index, so one overlay object serves every
display.

`KnipsAppTarget` is also the `NSMenuDelegate` of the Record Window
submenu. A separate delegate class would carry no extra state, and the
target is already the object every menu item points at. What that
delegate is allowed to do inside menu tracking is spelled out under
[Deferrals](#deferrals-1) below.

**Which windows the submenu offers.** On screen, layer 0, at least 32
points each way, titled, and **not owned by this process** — decided by
comparing `SCRunningApplication.processID` against
`NSProcessInfo.processIdentifier`, never by application name. The name is
a display name: `Knips` under the bundle and `knips-bin` from the shell,
so a name comparison quietly stops matching in exactly the shape that
ships, and the app starts offering its own playback window as something
to record.

**The recording frame.** A region recording puts one borderless,
passthrough (`ignoresMouseEvents`) window at window level 1000 around the
rectangle for as long as the capture runs (`Knips.App.Border`). It is
kept out of the file two independent ways, and the second is the backstop
for the first:

1. **Geometry.** The window is the region *outset* by the 2-point border
   width, and the stroke runs along the window's own outer edge — a path
   inset by half the line width, stroked at the full width. Every border
   pixel is therefore outside the recorded rectangle. Proven on device by
   recording the whole display with the frame up: 11 165 of the 11 264
   pixels in the four-pixel ring outside the rectangle are red, and 0 of
   the 480 000 inside it are.
2. **Exclusion.** The window's `windowNumber` — which is its
   `CGWindowID`, and is found by `SCShareableContent` immediately, with no
   run-loop turn in between — goes into
   `TRecordingOptions.ExcludedWindowIDs`, which `Knips.Recording` turns
   into `SCWindow` objects for
   `SCContentFilter.initWithDisplay:excludingWindows:`. Proven on device
   by putting a solid-magenta window of the same shape over the region:
   without the exclusion the recorded frame is 100 % magenta, with it
   0 %.

The frame is created *before* `StartCapture`, because the content filter
is built inside it. A frame that cannot be shown is not an error: the
recording runs without one, and rule 1 means there was nothing to exclude
anyway. Display and window recordings get no frame.

**The playback window** (`Knips.App.Playback`). A finished recording
opens in an ordinary titled window with an `AVPlayerView` and three
buttons whose target is the same `KnipsAppTarget`. *Export as GIF…* runs
`TGifExportSession` inline on the main thread — nothing here may pump a
nested run loop, so the window is unresponsive while it works and the
title carries the progress instead (`Exporting… 42%`, from the pipeline's
new per-frame `OnProgress`). The buttons are disabled first, which is
what makes re-entry impossible; `CommandClose` refuses while an export is
running for the same reason. The window is `activateIgnoringOtherApps`'d
into the foreground, exactly as the overlay is — an Accessory process's
titled window can become key on its own, which is why this one needs no
runtime class for it.

**Remembered settings.** Two, both in `NSUserDefaults`:
`KnipsRecordSystemAudio` (the checkbox) and `KnipsLastRegion*` (the
display id and rectangle behind *Record Last Region*). The region is
written only once a capture has actually started, so a region whose
display has gone never becomes the region to repeat. It is read back
through `SanitizeStoredRegion`, because `defaults write` is a public
interface and these keys are not private state: a negative origin would
otherwise land in ScreenCaptureKit's `sourceRect` unexamined.

**The click.** Idle, the status item has its menu; recording, the menu is
detached and the button's action is `stopRecording:`, so a single click
stops — Kap's gesture. An `NSTimer` on `KnipsAppTarget` rewrites the
title once a second while recording (`⏺ 0:07`).

That gesture costs the menu while recording, so **Quit is deliberately
unreachable until the recording stops** — one click stops it, and Quit
finalises any session still open before calling `terminate:` anyway.

**Getting out of a selection.** Inside the overlay, Esc or a click without
a drag cancel. The overlay sits above the menu bar, so the status item is
not clickable while it is up; the menu's *Cancel selection* item
(`acCancelSelection`) exists for the one case where it is — when `Show`
put no window on any screen. `Show` returns `False` there and the
controller refuses to enter `asSelecting`, because a selecting state with
nothing on screen has no way out at all.

**Selection geometry.** One borderless, transparent, screen-saver-level
window per `NSScreen`, dimmed 35 % except for the dragged rectangle. Mouse
locations arrive in window coordinates, whose origin is bottom-left; the
overlay window covers exactly one screen's frame, so those are that
display's own points, measured upwards. ScreenCaptureKit's `sourceRect`
wants the same points measured from the display's *top* left, so both
corners are flipped once — `y' = screenHeight - y` — in
`TSelectionOverlay.SelectionRegion`, and nothing downstream sees a
bottom-left origin. The screen's `NSScreenNumber` gives the
`CGDirectDisplayID`, which `TShareableContent.IndexOfDisplayID` turns into
the display index the recorder takes.

**Deferrals.** Anything that pumps `CFRunLoopRunInMode` is moved off the
AppKit dispatch that asked for it, by a zero-delay one-shot `NSTimer`:

- `startPending:` — the selection commits inside the view's `mouseUp:`,
  and both resolving the display and starting ScreenCaptureKit pump. The
  timer runs them on the next turn, with the overlay already off screen.
- `stopPending:` — the stop arrives as a status-item action, and
  finalising the writer pumps for its completion handler. The state leaves
  `asRecording` immediately (so a second click is a no-op) and the
  finalisation follows one turn later.

Quit is the exception: `terminate:` never returns, so it finalises any
open session inline rather than deferring an unplayable file. Overlay
windows are `autorelease`d rather than released for the same
mid-dispatch reason — and so is `KnipsPlaybackDelegate` itself, which is
let go from inside the `windowWillClose:` that is running *on* it.

**Two places pump deliberately, and both are bounded.** The rule above is
"never pump from inside an AppKit dispatch"; these two do, because there
is no next turn to defer to.

- **`menuNeedsUpdate:`** builds the Record Window submenu, and AppKit is
  already tracking the menu when it asks. The `SCShareableContent` query
  is asynchronous, so waiting for it means pumping `kCFRunLoopDefaultMode`
  nested inside `NSEventTrackingRunLoopMode`. That works — the main
  queue's port is in the common modes, so the completion is drained under
  tracking — but the default five-second budget would freeze the menu on
  every hover if the Screen Recording grant were missing. So this caller
  gets `TShareableContent.CreateWithin(1.0)` and the result is cached for
  five seconds: at most one query per interval however often the submenu
  is opened, at most a second of waiting when the framework does not
  answer, and a single disabled *window list unavailable* line instead of
  an error when it does not. Nothing on this path may call `Fail` or
  `RefreshStatusItem` — the status item's menu is on screen.
- **The GIF export's progress.** `setTitle:` marks the titlebar dirty and
  pushes the string to the window server, but the *drawn* title comes
  from a CoreAnimation commit that runs as a run-loop observer. With the
  export holding the main thread there is no such turn, and the title
  never visibly changes — measured on device: five captures of the window
  across a 4.2 s export were byte identical while the window server's
  title property counted 0 % → 99 %. So the progress handler runs one
  `CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, True)` slice per whole
  percent. That is real event dispatch, so it comes with a hard lockout:
  `TAppController.Transition` returns `False` for **every** command while
  an export is running, the playback buttons are already disabled, and
  Quit refuses with a `Last error: …` note rather than terminating over a
  half-written GIF.

**Exceptions never cross the boundary.** Every `cdecl` method body in
`Knips.App` and `Knips.App.Overlay` is wrapped in `try..except`. There
is no Objective-C frame that could unwind a Pascal exception, and AppKit's
drawing, event dispatch and run loop all sit above these bodies. What is
caught becomes a message on the same NSLog + "Last error" path, and the
method returns normally.

**Errors.** A failed capture — a denied Screen Recording grant is the
common one — goes to `NSLog` and to a disabled `Last error: …` menu item,
and the app returns to idle. It never retries and never opens a dialog.

## Timing and the writer session

`AVAssetWriterInput.appendSampleBuffer:` uses the buffer's own PTS.
`TMovieWriter` calls `startSessionAtSourceTime:` with the first buffer's
PTS and records the last one; duration in the report is the difference.
SCK delivers frames when content changes (plus the configured minimum
interval), so idle stretches simply have fewer samples and the file plays
at real speed — the opposite of a frame-counting encoder.

Frames arriving while the input reports `isReadyForMoreMediaData ==
NO` are dropped and counted; that is the back-pressure path during
keyframe spikes, mirrored by the stream's `queueDepth`.

## System audio

`--audio=system` (macOS 13+) sets `capturesAudio`, `sampleRate` and
`channelCount` on the stream configuration (48 kHz stereo by default) and
registers the *same* runtime-built output object a second time, for
`SCStreamOutputTypeAudio` on its own dispatch queue. Audio buffers reach
`OnSample` as `skAudio`, skipping the complete-frame filter, which is a
video-only attachment. `TMovieWriter` adds a second `AVAssetWriterInput`
— AAC at 128 kbit/s (`AVFormatIDKey` = `kAudioFormatMPEG4AAC`), also
`expectsMediaDataInRealTime` — and the one AVAssetWriter muxes both
tracks into the same file.

The writer's session still starts at the first *video* frame's PTS, so
audio delivered before that has no timeline to sit on: it is dropped and
counted separately, as are audio buffers arriving while the audio input
is not ready. Both appends take the same `FLock`, which is what keeps
SCK's two queues from touching the writer at once; every capture-queue
rule above applies unchanged to the audio path. Microphone capture is a
third SCK output type (macOS 15) and is not wired up.

One rejected buffer fails AVAssetWriter terminally — every later append
on every input returns NO. Both append paths therefore check the
writer's status first (audio buffers additionally
`CMSampleBufferDataIsReady`), flag the failure, and the main loop aborts
the recording rather than streaming minutes into a dead file.

## Geometry

Display/window sizes from SCK are in points. `Scale` (auto = pixels ÷
points from `CGDisplayCopyDisplayMode`) converts to pixels;
`AlignDimension` rounds down to even, as H.264 needs. For a region,
`setSourceRect:` selects the points and the configured width/height is
the region in pixels with `scalesToFit` on. For a window,
`initWithDesktopIndependentWindow:` captures the window regardless of
what overlaps it; the output size is the window's frame at start, and
SCK scales later resizes into it.

## Errors and exit codes

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 1 | usage — options failed validation |
| 2 | failure — framework, permission, writer, or reader error (message printed) |
| 3 | unsupported — not a macOS build |

`knips app` only uses these for set-up failures; once the status item is
up, a failed recording is reported in the menu and the process keeps
running.

A second Ctrl-C during finalisation calls `_exit(2)`; the file may be
unplayable, which is preferable to a corrupted writer state.

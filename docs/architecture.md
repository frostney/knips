# Architecture

## Executive Summary

- One binary: ScreenCaptureKit stream → complete-frame filter →
  AVAssetWriter input (hardware H.264) → `.mp4`/`.mov`. opname never
  touches pixels or NAL units; it moves sample buffers.
- The `SCStreamOutput` object the framework calls back into is a
  **runtime-built Objective-C class** — one plain `cdecl` Pascal routine
  registered with `class_addMethod` — so the build needs no linker flags
  ([ADR-0002](adr/0002-runtime-built-objc-classes.md)). The menu bar's
  target, the selection overlay's view and its window ride on the same
  primitive.
- `opname app` is the same binary in a second shape: an Accessory-policy
  `NSApplication` with a status item, whose recording lifecycle is
  `TRecordingSession.StartCapture` … NSApp's run loop … `FinishCapture`.
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
 ┌──────────────────────────── opname (one binary) ──────────────────────┐
 │                                                                        │
 │  main thread                          capture queue (GCD, SCK-owned)   │
 │  ┌──────────────────────┐             ┌──────────────────────────────┐ │
 │  │ opname.pas: CLI      │             │ OpnameStreamOutput           │ │
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
| CLI | `opname.pas` | lwpt `cli` package: `app`, `record`, `displays`, `windows`, `probe`; SIGINT/SIGTERM → `StopRequested` |
| App | `Opname.App`, `Opname.App.Overlay`, `Opname.App.State` | Status item + menu, selection overlay, and the neutral state machine (tested) |
| Recording | `Opname.Recording` | Target → filter + geometry → writer → stream; progress; report |
| Capture | `Opname.Capture.ShareableContent`, `Opname.Capture.Stream` | SCShareableContent query (run-loop pumped); SCStream + runtime output object |
| Export | `Opname.Export.MovieWriter` | AVAssetWriter/Input bindings; session start; finish |
| ObjC | `Opname.ObjC.Runtime`, `Opname.ObjC.TypeEncoding` | Class assembly via libobjc; method type encodings (tested) |
| Options | `Opname.Options` | Neutral option model, validation, derived values (tested) |
| Vendored | `source/capture/*` | CoreMedia/CoreVideo/VideoToolbox/GCD, ScreenCaptureKit externals, pthread mutex |

Nothing above the capture layer knows about `objcclass`; nothing below
the recording layer knows about the CLI.

## The runtime-built output object

`Opname.Capture.Stream.EnsureStreamOutputClass` assembles
`OpnameStreamOutput` once per process:

1. `objc_allocateClassPair(NSObject, "OpnameStreamOutput", 0)`
2. `class_addIvar("opnameOwner", sizeof(Pointer))` — back-pointer to the
   owning `TScreenStream`
3. `class_addMethod("stream:didOutputSampleBuffer:ofType:",
   @StreamOutputSampleBuffer, "v@:@^vq")` — the encoding comes from
   `Opname.ObjC.TypeEncoding`, never a literal
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
- **Capture queue** (`opname.capture.video`, created for the stream) runs
  `StreamOutputSampleBuffer` → `DeliverSample` → `OnSample` →
  `AppendVideoSample`. Rules on that path, carried from the prototype:
  no exceptions or `try..finally` (no `cthreads`, so the exception frame
  chain is process-global), no `WriteLn`, no managed-type writes outside
  `FLock`.
- **Why no cthreads:** the prototype documented cthreads' signal handler
  intercepting a benign SIGSEGV raised inside CoreMedia's XPC
  deserialisation of SCK sample buffers. lantaarn escaped it by not using
  SCK in the default build; opname needs SCK, so it keeps the prototype's
  shape: `cmem` (libc heap, thread-safe without a thread manager) first,
  real pthread mutexes, and `IsMultiThread := True` at startup so the
  RTL's refcount updates use locked instructions.
- **`Opname.ThreadManager`:** the first on-device run showed the shape
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

`opname app` sets the activation policy to `Accessory` — a process with a
menu-bar item and no Dock tile — installs one `NSStatusItem`, and hands
the thread to `NSApplication.run`. There is one state machine:

```text
         Record Region…                 mouse up (usable drag)
  asIdle ───────────────▶ asSelecting ───────────────────────▶ asRecording
     ▲                        │                                     │
     │                        │ Esc / stray click / capture failed   │ click the
     │◀───────────────────────┘                                     │ item, or
     │                                                              │ Stop
     │        Record Display ─────────────────────────────────▶     │
     │◀─────────────────────────────────────────────────────────────┘
```

`Opname.App.State` owns the transition table, the status-item title, the
`~/Movies/opname/opname-YYYYMMDD-HHMMSS.mp4` naming, and the selection
maths; it is platform-neutral and has a co-located suite, so the only
untested part of the app is the Cocoa plumbing.

Three more classes are built through `Opname.ObjC.Runtime`, none of them
an `objcclass`:

| Runtime class | Superclass | Methods |
| --- | --- | --- |
| `OpnameAppTarget` | `NSObject` | `recordRegion:`, `recordDisplay:`, `stopRecording:`, `cancelSelection:`, `revealRecordings:`, `quitOpname:`, `timerFired:`, `startPending:`, `stopPending:` |
| `OpnameOverlayView` | `NSView` | `drawRect:`, `mouseDown:`, `mouseDragged:`, `mouseUp:`, `keyDown:`, `acceptsFirstResponder` |
| `OpnameOverlayWindow` | `NSWindow` | `canBecomeKeyWindow` (a borderless window answers NO, and then Esc never reaches the view) |

Each carries an `opnameOwner` pointer ivar back to the owning Pascal
object, cleared before the Objective-C instance goes away — the same rule
as the stream output object. `OpnameOverlayView` adds an `opnameIndex`
ivar holding the screen's index, so one overlay object serves every
display.

**The click.** Idle, the status item has its menu; recording, the menu is
detached and the button's action is `stopRecording:`, so a single click
stops — Kap's gesture. An `NSTimer` on `OpnameAppTarget` rewrites the
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
mid-dispatch reason.

**Exceptions never cross the boundary.** Every `cdecl` method body in
`Opname.App` and `Opname.App.Overlay` is wrapped in `try..except`. There
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
| 2 | failure — framework, permission, or writer error (message printed) |
| 3 | unsupported — not a macOS build |

`opname app` only uses these for set-up failures; once the status item is
up, a failed recording is reported in the menu and the process keeps
running.

A second Ctrl-C during finalisation calls `_exit(2)`; the file may be
unplayable, which is preferable to a corrupted writer state.

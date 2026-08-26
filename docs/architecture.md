# Architecture

## Executive Summary

- One binary: ScreenCaptureKit stream → complete-frame filter →
  AVAssetWriter input (hardware H.264) → `.mp4`/`.mov`. Knips never
  touches pixels or NAL units; it moves sample buffers.
- `--audio=system|mic|both` adds SCK's audio and/or microphone output,
  one AVAssetWriter input (AAC) per source, to the same file; see
  [Audio](#audio).
- The `SCStreamOutput` object the framework calls back into is a
  **runtime-built Objective-C class** — one plain `cdecl` Pascal routine
  registered with `class_addMethod` — so the build needs no linker flags
  ([ADR-0002](adr/0002-runtime-built-objc-classes.md)). The menu bar's
  target, the selection overlay's view and its window ride on the same
  primitive.
- `knips app` is the same binary in a second shape: an Accessory-policy
  `NSApplication` with a status item, whose recording lifecycle is
  `TRecordingSession.StartCapture` … NSApp's run loop … `FinishCapture`.
- Timing is taken from each sample buffer's presentation stamp; the
  writer's session starts at the first appended frame. This is what makes
  SCK's change-driven frame delivery record at real speed.
- Two threads: the main thread (run loop, signals, progress) and SCK's
  capture queue (sample delivery → append). No `cthreads`; shared counters
  sit under a pthread mutex; the capture path never raises or prints.
- `knips export` writes three things from one `--out` extension: a GIF
  (exact-colour palette, dithering, LZW), an APNG (truecolour, no
  quantisation, paszlib), or a trimmed movie via
  `AVAssetExportSession` passthrough — no decode, no re-encode. The first
  two share the reader, the decimator, the scaler and the frame-delay
  planner; see [The export pipeline](#the-export-pipeline).
- Everything platform-neutral (option model, type encodings, both image
  encoders, the delay planner) is a unit with a co-located test that runs
  on Linux too.

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
| App | `Knips.App`, `Knips.App.Overlay`, `Knips.App.Camera`, `Knips.App.State` | Status item + menu, selection overlay, the camera picture-in-picture window, and the neutral state machine (tested) |
| Recording | `Knips.Recording` | Target → filter + geometry → writer → stream; progress; report |
| Capture | `Knips.Capture.ShareableContent`, `Knips.Capture.Stream` | SCShareableContent query (run-loop pumped); SCStream + runtime output object |
| Export (Darwin) | `Knips.Export.MovieWriter`, `Knips.Export.MovieReader`, `Knips.Export.MovieTrim`, `Knips.Export.Pipeline` | AVAssetWriter/Input bindings; AVAssetReader/TrackOutput bindings; AVAssetExportSession passthrough trim; the shared GIF/APNG pipeline |
| Export (neutral) | `Knips.Export.Gif`, `Knips.Export.Apng`, `Knips.Export.Bitmap`, `Knips.Export.Timing` | Median cut, dithering, LZW, GIF89a writer; APNG chunks, PNG filters, paszlib; BGRA buffer + resampling; frame-delay planning (all tested) |
| ObjC | `Knips.ObjC.Runtime`, `Knips.ObjC.TypeEncoding` | Class assembly via libobjc; method type encodings (tested) |
| Options | `Knips.Options` | Neutral option model, validation, derived values (tested) |
| Vendored | `source/capture/*` | CoreMedia/CoreVideo/VideoToolbox/GCD, ScreenCaptureKit externals, pthread mutex |

Nothing above the capture layer knows about `objcclass`; nothing below
the recording layer knows about the CLI.

## The export pipeline

`knips export` is the mirror of `record`, and it is deliberately thin on
the Darwin side: `Knips.Export.MovieReader` turns an `.mp4`/`.mov` into
a stream of BGRA `CVPixelBuffer`s with presentation stamps, and
everything that decides what the file looks like —
`Knips.Export.Bitmap`, `Knips.Export.Gif`, `Knips.Export.Apng` and
`Knips.Export.Timing` — is platform-neutral and unit-tested off-device.

`Knips.Export.Pipeline` owns the reader, the decimator and the scaler;
only the sink differs, so GIF and APNG cannot drift apart on which
frames they pick or how long each is shown.

```text
  AVAssetReader (timeRange = --trim)
        │  BGRA CVPixelBuffer + PTS
        ▼
  decimate to --fps (integer grid over the stamps, not a cadence)
        │
        ▼
  BgraResample to --width (integer box reduce, then bilinear)
        │
        ├─ .gif  pass 1 ─▶ TGifQuantizer: exact-colour histogram over ≤32
        │                   sampled frames ─▶ median cut ─▶ one global palette
        │        pass 2 ─▶ TGifEncoder: Floyd–Steinberg ─▶ changed rectangle
        │                   ─▶ LZW twice, opaque and transparent, keep the
        │                       shorter ─▶ GIF89a + NETSCAPE2.0 loop
        │
        └─ .apng one pass ─▶ TApngEncoder: no quantisation at all ─▶ changed
                              rectangle ─▶ PNG line filters ─▶ paszlib
                              ─▶ acTL/fcTL/fdAT
```

Four decisions carry most of the weight:

- **One global palette, two passes.** An `AVAssetReader` cannot seek
  backwards, so the palette pass and the encoding pass are two readers
  opened one after the other over the same `CMTimeRange`. A per-frame
  local palette would need only one pass, but it makes the colours shift
  between frames — very visible on a screen recording's flat UI — and
  costs 768 bytes of colour table per frame. The histogram counts
  *exact* colours: an open-addressed table of packed 24-bit keys, capped
  at 2^20 distinct colours so its 16 MB never grows with the movie, with
  the old fixed 4 MB array of 64³ cells kept as the fallback for a source
  that exceeds the cap (`knips export` says so in its last line when it
  happens). Median cut then splits the box holding the most *squared
  error*, along the channel holding most of it, and every palette entry
  is the count-weighted mean of the real colours in its box.

  Measured on a 14 s, 800×520 ScreenCaptureKit recording, 281 frames,
  PSNR against the same source that every encoder read, with ffmpeg's
  `palettegen` + `paletteuse` as the reference point:

  | encoder | dithered | size | PSNR |
  | --- | --- | --- | --- |
  | knips, 6-bit histogram | Floyd–Steinberg | 14.4 MB | 38.17 dB |
  | knips, exact histogram + error-based cut | Floyd–Steinberg | 1.79 MB | 41.48 dB |
  | ffmpeg palettegen/paletteuse | Floyd–Steinberg | 1.30 MB | 42.50 dB |
  | knips, 6-bit histogram | none | 0.87 MB | 37.47 dB |
  | knips, exact histogram + error-based cut | none | 1.09 MB | 42.58 dB |
  | ffmpeg palettegen/paletteuse | none | 1.11 MB | 43.97 dB |

  The dithered row is the one that matters, because dithering is the
  default. It collapsed by 8.1× — not because the encoder got cleverer
  about bytes, but because a palette that is 3.3 dB closer leaves far
  smaller errors for Floyd–Steinberg to diffuse, and diffused error is
  what was destroying the frame-to-frame coherence the changed rectangle
  and the transparency trial both depend on. Encoding time did not move
  (13.19 s before, 13.20 s after, same machine, same file).

  Undithered, knips is now marginally *smaller* than ffmpeg at 1.4 dB
  less; dithered it is 37% larger at 1.0 dB less. The remaining gap is
  median cut against ffmpeg's own cut, not the histogram.
- **Nearest-colour lookups are exact and memoised.** Mapping a pixel to
  a palette index used to be answered per 6-bit *cell*, for the colour
  the cell's corner expands to rather than for the pixel — a floor of a
  couple of units per channel under every mapped pixel. Now the memo is
  a direct-mapped table keyed by the colour itself (2^20 slots, 6 MB), so
  a collision costs a search and never an answer; the search walks the
  palette outwards from the entry nearest in green and stops when the
  green difference alone exceeds the best distance so far, which gives
  the same answer as scanning all 255 entries for a fraction of the
  comparisons.
- **Decimation counts grid slots, not deadlines.** Each frame's stamp is
  turned into a slot number, `floor((pts - first) * fps)`, and a frame is
  emitted when its slot is past the last one emitted. The obvious
  alternative — carrying a floating-point "next due" time forward — drops
  frames when the source rate equals the requested one, because a stamp
  that should land exactly on the deadline lands a few parts in 10^16
  below it. Counting slots also means a source slower than the target
  never accumulates a backlog of frames that are "due".
- **Delays are snapped to that same grid.** `TFrameDelayPlanner`
  (`Knips.Export.Timing`) rounds each emitted frame's stamp to the
  nearest whole slot and writes the difference between that slot's ideal
  tick count and the ticks already spent. Two things have to hold at
  once and the obvious implementations manage one each: rounding every
  gap on its own loses ten percent of the running time at 30 fps
  (3.33 cs becomes 3), while rounding each stamp against the centisecond
  grid keeps the total honest but turns a 30 fps source decimated to
  20 fps into 7, 3, 7, 3 — the source's frames land 3.33 cs either side
  of every 1/20 s slot, and the alternation is visible judder. Snapping
  to the slot first removes the alternation, taking the ideal from the
  slot removes the drift, and measuring against ticks already spent means
  a delay clamped at the floor (GIF's minimum of 2 — browsers silently
  turn 0 and 1 into 10) is repaid by the frames after it rather than
  lost. A gap longer than one slot keeps its length, so an idle stretch
  stays idle. That is also why the pipeline holds one scaled frame back:
  it cannot write frame *n*'s delay until it has seen frame *n+1*.

  Measured on a 30 fps source: 30 → 20 fps went from `7,3,7,3,…`
  (51 × 7 cs, 49 × 3 cs, 504 cs total) to `5,5,5,…` (100 × 5 cs, 500 cs
  total, which is the source's own length exactly). 30 → 30 fps stays
  `3,4,3,3,4,3` — 3.33 cs is not writable — but its total moved from
  501 cs to 500 cs.

  **The two clamps are deliberately not symmetric.** A delay pushed *up*
  to the minimum is **owed**, and repaid by shortening the delays after
  it, so a burst of frames closer together than the floor allows still
  ends where it should. A delay pushed *down* to the ceiling — a delay
  field is two bytes — is **forgiven**: the gap is emitted as one
  maximum-length delay and the remainder is struck off rather than
  carried. Owing it instead smears the excess over the frames *after* the
  gap, which is the worst possible place for it: measured at APNG's
  millisecond scale, a 300 s pause left the next four motion frames each
  held for 65 535 ticks, turning the moment the recording came back to
  life into a slideshow. Forgiving costs only the idle time past the
  ceiling (the pause plays for 65.5 s instead of 300 s) and every frame
  after it gets its true delay. In centiseconds the ceiling is 655 s, so
  a GIF only meets it after eleven minutes of a perfectly still screen;
  in practice this is an APNG concern.
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

`export` prints one line of advice to **stderr** when the result is going
to be awkward to hand around — a canvas at or past 1280×720, or a file
past 20 MB. It names only the knobs that would actually move: `--width=800`
if the canvas is wider than that, `--fps=15` if the rate is higher, and a
shorter `--trim` when neither is left. It is advice, not a failure: the
file is written and usable, so the exit code stays 0 and the line goes to
stderr where a pipeline will not eat it.
`Knips.Options.LargeExportWarning` decides, and is tested.

### APNG

`--out=x.apng` writes an animated PNG instead, and its whole reason for
existing is that it does **not** quantise: 8-bit truecolour, so the file
holds exactly the pixels the scaler produced. On the same 14 s 800×520
recording as the table above it comes out at 29.1 MB and 45.20 dB —
which is the ceiling the YUV→RGB conversion itself imposes, 3.7 dB above
the best a 256-colour palette managed, for 16× the bytes. It is the right
choice for a UI clip that has to look right and the wrong one for a chat
window.

Everything before the sink is shared with the GIF path, and only two
things differ:

- **One pass, not two.** There is no palette to learn, so the reader runs
  once. The canvas size comes from the track's `naturalSize`.
- **Chunks instead of blocks.** `signature IHDR acTL | fcTL IDAT |
  fcTL fdAT | … IEND`, with one contiguous sequence number shared by
  `fcTL` and `fdAT`. Frames after the first are the changed rectangle at
  its own offset with `dispose_op = NONE` and `blend_op = SOURCE`, which
  with no alpha channel is exactly "replace these pixels and leave the
  rest": the same composition the GIF path gets from disposal 1. Each
  line picks among the five PNG filters by smallest sum of signed
  magnitudes, and the result goes through the RTL's own paszlib
  (`ZStream`) — part of FreePascal, not a new dependency — at the
  **default** level, not level 9. Measured on a 480×312 / 100-frame
  export, interleaved runs on CPU time: level 9 cost 6.28 s against
  2.77 s for 2.0% fewer bytes, which is not a trade an animation format
  should make on the user's behalf. Writing the five filter loops out
  rather than selecting the predictor per byte is free by comparison:
  byte-identical output, 2.92 s → 2.77 s.

`acTL` has to carry the frame count and sits before the first frame, so
it is written as zero and its four bytes and CRC are patched in `Finish`
at a remembered offset. That is the only seek in the encoder; nothing
else buffers, and memory is the current frame's RGB, the previous
frame's, and one frame of compressed bytes.

The co-located suite parses the encoder's own output — chunk order, every
CRC, the sequence numbers, the ops, the delays — inflates it, unfilters
it with an implementation written from the specification rather than from
the encoder, and asserts the pixels come back **byte for byte**.

### The passthrough trim

`knips export --in=a.mp4 --out=b.mp4 --trim=1.5,3.5` does not come
through the pipeline at all: it decodes nothing.
`Knips.Export.MovieTrim` hands the asset to an `AVAssetExportSession`
with `AVAssetExportPresetPassthrough`, a `timeRange`, and an
`outputFileType` from the output extension, so the same coded samples are
copied into a new container. A recording that has been through
VideoToolbox once should not go through it again just to lose its first
two seconds.

The export is asynchronous and this program has no run loop, so the wait
is the same shape as `TMovieWriter.Finish`: a global `cdecl` completion
procedure sets a flag and the main thread pumps `CFRunLoopRunInMode` in
millisecond slices until it does, or gives up and cancels.

Only movie-to-movie is possible — passthrough copies samples, so there is
no path from a GIF and none to one — and a movie `--out` without `--trim`
is refused rather than silently copying the file. `--fps`, `--width` and
`--no-dither` have no meaning here and say so on stderr rather than being
ignored in silence.

Verified on a real 14 s ScreenCaptureKit recording: `--trim=1.5,3.5`
produced a file of duration exactly 2.000 s whose codec, profile, level,
pixel format and dimensions all match the source, and whose decoded
frames are `framemd5`-identical to the source seeked to 1.5 s (PSNR
`inf`). Note that the container keeps the samples from the preceding
keyframe and trims them with an edit list, so `ffprobe`'s `nb_frames` is
larger than the number of frames actually presented; a decoder that
honours the edit list sees exactly the requested range.

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
  (`knips.capture.audio`) runs the same path into `AppendAudioSample`,
  and with the microphone on a third (`knips.capture.mic`) into
  `AppendMicrophoneSample`.
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
     │        Record Display ─────────────────────────────────▶     │
     │◀─────────────────────────────────────────────────────────────┘
```

`Knips.App.State` owns the transition table, the status-item title, the
`~/Movies/knips/knips-YYYYMMDD-HHMMSS.mp4` naming, and the selection
maths; it is platform-neutral and has a co-located suite, so the only
untested part of the app is the Cocoa plumbing.

Four more classes are built through `Knips.ObjC.Runtime`, none of them
an `objcclass`:

| Runtime class | Superclass | Methods |
| --- | --- | --- |
| `KnipsAppTarget` | `NSObject` | `recordRegion:`, `recordDisplay:`, `stopRecording:`, `cancelSelection:`, `revealRecordings:`, `toggleCamera:`, `restoreCamera:`, `quitKnips:`, `timerFired:`, `startPending:`, `stopPending:` |
| `KnipsOverlayView` | `NSView` | `drawRect:`, `mouseDown:`, `mouseDragged:`, `mouseUp:`, `keyDown:`, `acceptsFirstResponder` |
| `KnipsOverlayWindow` | `NSWindow` | `canBecomeKeyWindow` (a borderless window answers NO, and then Esc never reaches the view) |
| `KnipsCameraView` | `NSView` | `acceptsFirstMouse:` (Knips is an Accessory app, so without it the first click on the camera window is eaten as the activating click and dragging takes two) |

`KnipsCameraView` is the exception to what follows: it has no ivar and no
`try..except`, because its one body returns a constant and never calls
back into Pascal. The other three each carry an `knipsOwner` pointer ivar
back to the owning Pascal object, cleared before the Objective-C instance
goes away — the same rule as the stream output object.
`KnipsOverlayView` adds an `knipsIndex`
ivar holding the screen's index, so one overlay object serves every
display.

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
mid-dispatch reason.

**Exceptions never cross the boundary.** Every `cdecl` method body in
`Knips.App` and `Knips.App.Overlay` is wrapped in `try..except`. There
is no Objective-C frame that could unwind a Pascal exception, and AppKit's
drawing, event dispatch and run loop all sit above these bodies. What is
caught becomes a message on the same NSLog + "Last error" path, and the
method returns normally.

**The camera window.** *Camera* puts a 240×180 borderless window at
`kCGFloatingWindowLevel` on screen, its content view hosting an
`AVCaptureVideoPreviewLayer` (`resize-aspect-fill`, 8 pt corner radius,
`masksToBounds`) fed by an `AVCaptureSession` on
`defaultDeviceWithMediaType:AVMediaTypeVideo`. It is
`movableByWindowBackground`, so the whole picture is the drag handle, and
it joins all Spaces the way the overlay does.

Knips does **no** compositing: the camera is simply a window, and
ScreenCaptureKit records it because it is on the display, exactly as Kap
does it. Nothing in `Knips.Recording` or `Knips.Export.MovieWriter`
knows it exists. That is also why the toggle sits **outside** the state
machine and is legal in every state — a passive window cannot fail a
capture, and mid-recording is when the user is most likely to want it on
or off. It keeps running across recordings; only Quit or a second click
takes it down.

`startRunning` blocks for the better part of a second while the camera
warms up. This program has no `cthreads` and creates no queues of its
own, so that hitch is taken on the main thread rather than dispatched;
the launch-time restore is deferred by the same zero-delay `NSTimer` as
`startPending:`, so the status item is in the menu bar before the camera
warms up. The one piece of foreign-thread code is the
`requestAccessForMediaType:completionHandler:` block, a global `cdecl`
procedure that writes two plain Booleans — the capture-queue rules
again.

The Camera grant is TCC, per binary, like Screen Recording. `Show`
consults `authorizationStatusForMediaType:` first: authorised builds the
session, denied or restricted reports through the same `Last error:`
path, and undecided asks **once**, asynchronously, and still refuses that
attempt. There is no retry loop and never a black rectangle standing in
for a camera.

Two facts underneath that were measured, not assumed (recorded in
[spike 0001](spikes/0001-runtime-objc-class.md)):

- **A bundle-less binary is not killed.** The obvious fear — that a
  missing `NSCameraUsageDescription` aborts the process, so *Camera*
  during a recording would destroy the file — is false. `./build/knips`
  survived `requestAccess`, `deviceInputWithDevice:error:` and
  `startRunning` and exited 0. `tools/make-app.sh` writes the key anyway,
  because it is what lets macOS prompt for Knips by name.
- **A denied grant is invisible to the session.** `startRunning`
  succeeds and `isRunning` answers YES with no access; the session just
  never delivers a frame. Consulting the status first is the *only*
  thing between the user and a black rectangle.

Three call sites therefore refuse to touch the access path at all,
gating on `TCameraPreview.IsAuthorized` instead of calling `Show` blind:
the launch-time restore (a prompt seconds after login is not something
the user asked for, and it would not restore anything either way), and
any switch-on while `asRecording` (a permission dialog over the thing
being recorded — belt and braces now that the kill is disproven). The
menu item is still enabled in every state; switching the camera *off*
is always allowed.

Persistence is the user's answer, not the last attempt's outcome: a
refused `Show` stores `False`, so a revoked grant cannot turn into an
error on every launch forever with no way to stop it. One click always
turns it back on.

Position and visibility live in `NSUserDefaults`
(`KnipsCameraOriginX/Y`, `KnipsCameraVisible`), written when the window
is hidden or the app quits. A restored origin is checked against every
attached screen's **`visibleFrame`** — `IsCameraOriginUsable` in
`Knips.App.State`, tested — so a position saved on a display that has
since been unplugged, or one the Dock has since taken, falls back to the
bottom right of the main screen. `visibleFrame` rather than `frame`
because the window floats at level 3 and the Dock sits at 20: under the
Dock it would be neither visible nor draggable.

The layer's `contentsScale` is pinned at `Show`. Dragging the window
between a Retina and a non-Retina display leaves it rendering at the old
scale until it is switched off and on again; tracking it would mean an
`NSWindowDidChangeBackingProperties` observer — another runtime-built
class and another owner ivar — for something one menu click fixes.

**Errors.** A failed capture — a denied Screen Recording grant is the
common one — goes to `NSLog` and to a disabled `Last error: …` menu item,
and the app returns to idle. It never retries and never opens a dialog.
The camera's failures take the same two outputs but *not* the transition:
`HandleCameraError` records and refreshes, where `Fail` would also drive
`acCaptureFailed` and knock a live recording to idle over a preview layer.

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

## Audio

`--audio` selects between ScreenCaptureKit's two audio outputs:
`system` (macOS 13+), `mic` (macOS 15+), `both`, or `none`. Each one is
an independent SCK output and becomes its own AAC track; nothing here
mixes them.

- **System audio** sets `capturesAudio`, `sampleRate` and `channelCount`
  on the stream configuration (48 kHz stereo by default).
- **Microphone** sets `captureMicrophone` and leaves
  `microphoneCaptureDeviceID` nil, which is the documented "system
  default microphone". The configuration's `sampleRate`/`channelCount`
  do *not* apply to it: SCK delivers the microphone in the capture
  device's own native format.

For each enabled output the *same* runtime-built output object is
registered again, on its own dispatch queue — `knips.capture.audio` and
`knips.capture.mic` beside `knips.capture.video`. The buffers reach
`OnSample` as `skAudio`/`skMicrophone`, skipping the complete-frame
filter, which is a video-only attachment.

`TMovieWriter` adds one `AVAssetWriterInput` per enabled source — AAC at
128 kbit/s (`AVFormatIDKey` = `kAudioFormatMPEG4AAC`), each
`expectsMediaDataInRealTime` — and the one AVAssetWriter muxes every
track into the same file. System audio is added before the microphone,
so `--audio=both` leaves `--audio=system`'s track first and a player's
default choice unchanged.

**Both AAC inputs get the identical, fully specified settings
dictionary, whatever format the buffers arrive in.** That is not a
simplification, it is what the API requires and permits.
`AVAssetWriterInput.h` states that a dictionary passed to
`assetWriterInputWithMediaType:outputSettings:` "must be fully
specified, meaning that it must contain AVFormatIDKey, AVSampleRateKey,
and AVNumberOfChannelsKey" — a bit-rate-only dictionary is legal only
alongside a `sourceFormatHint`. The same header constrains *appended*
audio to linear PCM and nothing further, lists
`AVSampleRateConverterAudioQualityKey` among the audio settings keys,
and documents `AVNumberOfChannelsKey` = 2 as producing stereo output
when no other layout information is available. The input's encoder is
therefore the converter: a mono or 44.1 kHz microphone is resampled and
upmixed into the configured track. Knips consequently never inspects a
buffer's `CMFormatDescription`, and never creates an input lazily from
under a capture callback — which the capture-thread rules would have
made awkward anyway.

The writer's session still starts at the first *video* frame's PTS, so
audio delivered before that has no timeline to sit on: it is dropped and
counted, as are buffers arriving while their input is not ready. The two
audio paths share one guard chain (`AppendAudioTo`) and differ only in
which input and which counters they feed, so `--audio=both` reports
per-source appended/early/stalled/failed counts and shows which source
is starving. Every append takes the same `FLock`, which is what keeps
SCK's three queues from touching the writer at once; every capture-queue
rule above applies unchanged to both audio paths.

One rejected buffer fails AVAssetWriter terminally — every later append
on every input returns NO. All append paths therefore check the
writer's status first (audio buffers additionally
`CMSampleBufferDataIsReady`), flag the failure, and the main loop aborts
the recording rather than streaming minutes into a dead file.

**Permissions.** The microphone is a second TCC grant, separate from
Screen Recording. `Knips.app` carries `NSMicrophoneUsageDescription` —
a bundled process that asks without it is killed rather than prompted;
the key is groundwork, since the menu-bar app has no audio surface yet.
The bare CLI binary has no `Info.plist` and inherits the grant of the
app responsible for it, which is the terminal it was launched from.

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

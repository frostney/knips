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
  A region recording is framed by a passthrough window that is both drawn
  outside the recorded rectangle and excluded from the content filter;
  the finished clip opens in an `AVPlayerView` window with a one-click
  GIF export. See [Menu bar app](#menu-bar-app).
- Two menu checkboxes change what a recording shows while it runs —
  *Zoom on Click* and *Follow Mouse*. Neither touches the file's
  dimensions, which `AVAssetWriter` fixes at the first frame: both animate
  the stream's `sourceRect` through
  `SCStream.updateConfiguration:completionHandler:`, so a smaller
  rectangle is a zoom and a sliding one is a pan. See
  [Live effects](#live-effects-zoom-on-click-and-follow-mouse).
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
| App | `Knips.App`, `Knips.App.Overlay`, `Knips.App.Border`, `Knips.App.Playback`, `Knips.App.Camera`, `Knips.App.Live`, `Knips.App.State` | Status item + menu, selection overlay, the recording frame, the playback/export window, the camera picture-in-picture window, the live-effect animator, and the neutral state machine (tested) |
| Recording | `Knips.Recording`, `Knips.Recording.LiveMath` | Target → filter + geometry → writer → stream; progress; report. The live-effect arithmetic is neutral and tested |
| Capture | `Knips.Capture.ShareableContent`, `Knips.Capture.Stream` | SCShareableContent query (run-loop pumped); SCStream + runtime output object |
| Export (Darwin) | `Knips.Export.MovieWriter`, `Knips.Export.MovieReader`, `Knips.Export.MovieTrim`, `Knips.Export.Pipeline` | AVAssetWriter/Input bindings; AVAssetReader/TrackOutput bindings; AVAssetExportSession passthrough trim; the shared GIF/APNG pipeline |
| Export (neutral) | `Knips.Export.Gif`, `Knips.Export.Apng`, `Knips.Export.Bitmap`, `Knips.Export.Timing` | Median cut, dithering, LZW, GIF89a writer; APNG chunks, PNG filters, paszlib; BGRA buffer + resampling; frame-delay planning (all tested) |
| ObjC | `Knips.ObjC.Runtime`, `Knips.ObjC.TypeEncoding` | Class assembly via libobjc; method type encodings (tested) |
| Options | `Knips.Options` | Neutral option model, validation, derived values (tested) |
| Vendored | `source/capture/*` | CoreMedia/CoreVideo/VideoToolbox/GCD, ScreenCaptureKit externals, pthread mutex |

Nothing above the capture layer knows about `objcclass`; nothing below
the recording layer knows about the CLI. The one edge that crosses
sideways is `Knips.App.Playback` → `Knips.Export.Pipeline`: the
playback window's *Export as GIF…* button runs the same session the
`export` subcommand does, rather than a second implementation of it.

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
  BgraResample to --width (integer box reduce, then bicubic)
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

Five decisions carry most of the weight:

- **The scaler is a box pre-pass and a Catmull-Rom bicubic.** A screen
  recording is text and hairlines, and the thing that made the GIFs look
  blurry was the resampling, not the palette. `BgraResample` reduces in
  two steps. First an *integer* box average, whenever both axes shrink
  by 2x or more: for a reduction that large a box is the correct
  antialiasing filter and nothing cheaper is. Whatever fractional ratio
  is left over then goes through Catmull-Rom — four taps an axis, two of
  them negative, separable into a horizontal pass and a vertical one —
  and not through the two-tap bilinear it used to, which is a triangle
  filter and on 8 px type is a blur. The negative lobes overshoot on a
  hard edge and both passes clamp to [0, 255]; the clamped overshoot is
  the crispness, and on dark-mode text it produces no visible halo.

  The weights are fixed point, ten bits, and the rounding residue of
  each destination pixel is handed to its heaviest tap so the four sum
  to exactly one — which is what makes a flat area come back unchanged
  and a 1:1 resize the identity. Measured against a `Double` kernel over
  the same 1800×1000 → 800×444 frame, fixed point is 42 ms a frame
  against 68, and unlike the floating-point version it is bit-identical
  on every host, so the neutral suite can assert exact bytes.

  When the box pass lands *on* the target size there is no second pass
  at all — the export is one integer average and stops. That is not a
  rare case: it is what the app's one-click GIF arranges deliberately,
  by asking for the recording's point size (see
  `Knips.App.State.AppGifWidth`). On a 2x display a 1800×1000 pixel
  recording exports at 900×500, an exact halving. Measured on a real
  6.1 s 1800×1000 region recording, PSNR against the source frame after
  putting each result back at capture size:

  | app default | canvas | GIF | PSNR |
  | --- | --- | --- | --- |
  | old: 800 px cap, box + bilinear | 800×444 | 374 kB | 24.58 dB |
  | 800 px cap, box + bicubic | 800×444 | — | 25.48 dB |
  | new: point size, exact box 2:1 | 900×500 | 418 kB | 27.63 dB |

  The wider canvas costs 12% more bytes for 27% more pixels: an exact
  box reduce leaves longer runs of identical colour than a fractional
  resample does, and LZW is paid in runs.

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
     │  Record Display / Record Window / Record Last Region ───▶     │
     │◀─────────────────────────────────────────────────────────────┘

  asIdle ──Record System Audio──▶ asIdle   (a self-transition: the command
         ──Zoom on Click───────▶            is legal only where the stream
         ──Follow Mouse────────▶            configuration is not yet fixed)
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
| `KnipsAppTarget` | `NSObject` | `recordRegion:`, `recordDisplay:`, `recordWindow:`, `recordLastRegion:`, `toggleSystemAudio:`, `toggleZoomOnClick:`, `toggleFollowMouse:`, `liveTick:`, `stopRecording:`, `cancelSelection:`, `revealRecordings:`, `toggleCamera:`, `restoreCamera:`, `quitKnips:`, `timerFired:`, `startPending:`, `stopPending:`, `exportGif:`, `revealRecording:`, `closePlayback:`, `menuNeedsUpdate:` |
| `KnipsOverlayView` | `NSView` | `drawRect:`, `mouseDown:`, `mouseDragged:`, `mouseUp:`, `keyDown:`, `acceptsFirstResponder` |
| `KnipsOverlayWindow` | `NSWindow` | `canBecomeKeyWindow` (a borderless window answers NO, and then Esc never reaches the view) |
| `KnipsCameraView` | `NSView` | `acceptsFirstMouse:` (Knips is an Accessory app, so without it the first click on the camera window is eaten as the activating click and dragging takes two) |
| `KnipsBorderView` | `NSView` | `drawRect:` — the frame drawn around a region while it records |
| `KnipsPlaybackDelegate` | `NSObject` | `windowWillClose:` — the one teardown path for the playback window |

`KnipsCameraView` is the exception to what follows: it has no ivar and no
`try..except`, because its one body returns a constant and never calls
back into Pascal. The others each carry an `knipsOwner` pointer ivar
back to the owning Pascal object, cleared before the Objective-C instance
goes away — the same rule as the stream output object.
`KnipsOverlayView` adds an `knipsIndex`
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
`TExportSession` inline on the main thread — nothing here may pump a
nested run loop, so the window is unresponsive while it works and the
title carries the progress instead (`Exporting… 42%`, from the pipeline's
new per-frame `OnProgress`). The buttons are disabled first, which is
what makes re-entry impossible; `CommandClose` refuses while an export is
running for the same reason. The window is `activateIgnoringOtherApps`'d
into the foreground, exactly as the overlay is — an Accessory process's
titled window can become key on its own, which is why this one needs no
runtime class for it.

**Remembered settings.** Four, all in `NSUserDefaults`:
`KnipsRecordSystemAudio` (the checkbox), `KnipsZoomOnClick` and
`KnipsFollowMouse` (both off by default, which is what `boolForKey:`
answers for a key that was never written, so nothing registers defaults;
see [Live effects](#live-effects-zoom-on-click-and-follow-mouse)), and
`KnipsLastRegion*` (the display id and rectangle behind *Record Last
Region*). The region is
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

### Live effects: Zoom on Click and Follow Mouse

Two menu checkboxes change what a recording *shows* while it runs, and
both are the same one idea. The file's dimensions are fixed the moment
`AVAssetWriter` opens and nothing may move them; what can move is the
rectangle ScreenCaptureKit reads from the screen —
`SCStreamConfiguration.sourceRect`, in the display's own points — through
`SCStream.updateConfiguration:completionHandler:`. A *smaller* source
rectangle scaled into the same output is a zoom. A *sliding* one is a pan.
The writer never learns that anything happened.

```text
  base      the region the user selected (or the whole display). Fixed:
            it is what sized the writer.
    │
    ├── Follow Mouse pans a base-SIZED window inside the display
    ▼
  window    ── the recording frame on screen tracks THIS ──▶ TRecordingBorder.MoveTo
    │
    ├── Zoom on Click crops inside the window, centred on the click
    ▼
  source    ──▶ TRecordingSession.UpdateSourceRect ──▶ SCStream
```

Zoom composes *inside* follow, never beside it, and that is what makes
the on-screen frame honest: `ZoomedSourceRect` clamps the crop into the
window, so what is captured is always a subset of what is framed. It
also means the aspect ratio never changes — both axes are divided by the
same zoom and the pan never resizes — so `preservesAspectRatio` (YES by
default since macOS 14) has nothing to do and no letterbox appears
mid-zoom.

- **`Knips.Recording.LiveMath`** holds every decision: rectangle
  clamping, the dead zone, the smoothstep easing, the frame-rate
  independent exponential approach, and `ResolveLiveEffects`, which says
  which effects a given target can have at all. It is platform-neutral,
  has no `{$IFDEF DARWIN}`, and has a co-located suite — the only part of
  this feature that can be checked off-device, so all of it lives there.
- **`Knips.App.Live`** is the animator: a plain Pascal object with no
  Objective-C class and no timer of its own. `Knips.App` owns a 30 Hz
  `NSTimer` on the same `KnipsAppTarget` every other action goes through
  (`liveTick:`), so the feature adds no seventh runtime class. The timer
  is added to `NSRunLoopCommonModes` as well, or dragging the camera
  window would freeze a zoom half way.
- **`TScreenStream.UpdateSourceRect`** rebuilds the configuration through
  the same private `BuildConfiguration` the capture started with — one
  place sets dimensions, rate, cursor and audio, so a live update cannot
  drift from the original — and changes only the rectangle.
  `scalesToFit` goes on for *any* source rectangle, not just a region's:
  with it off the header says the output "only scales down", and a zoomed
  rectangle would be letterboxed instead of filling the frame.

**The update is fire-and-forget, and that is the whole concurrency
design.** Start and stop pump `CFRunLoopRunInMode` until their handler
fires; this one must not, because it happens thirty times a second inside
a run loop that has a recording to keep serving. So a global pending flag
allows exactly one update in flight, a call made while one is pending is
*dropped* without touching the last-sent rectangle — the next tick then
carries a newer rectangle than the dropped one would have, which is
latest-wins coalescing for free — and the handler follows the same rules
as the other two: no exceptions, no `WriteLn`, no managed types, and no
allocation at all. It does not even retain the `NSError`; it keeps the
integer `code`, so the report can say why an update was refused. `Stop`
drains an outstanding update before stopping the capture, because a flag
left set would silently disable the feature for the next recording.

**Fire-and-forget has a sharp edge, and it needed three answers.**

- *A refused update strands the dedupe.* `FLastSentRect` records what was
  **asked for**, not what the stream adopted, so one `NSError` anywhere on
  a ramp would leave it holding a rectangle that never took — and every
  later rectangle within half a point of that value would be deduped away.
  The clip would stay zoomed for its remainder while the animator believed
  it had eased out. The handler runs on a framework queue and may only
  touch globals, so the healing is done from the *sending* side:
  `GUpdatesFailed` is snapshotted at each send and compared at the next,
  and a send that turns out to have been refused forces the following
  rectangle through regardless of the epsilon.
- *A framework that keeps saying no is a retry storm.* Twenty refusals a
  second for the rest of a recording, silently. After
  `MaxConsecutiveUpdateFailures` (five) in a row the stream sets
  `SupportsLiveUpdate` to False for good, records one message, and the
  recording carries on plain at whatever rectangle last took. The animator
  watches that flag and stops — otherwise it would go on moving the border
  and the easings against a capture that no longer follows them. The
  message reaches the user on the same `Last error: …` line as everything
  else; it is explicitly **not** a `Fail`, because the file is unharmed.
- *The abandoned configuration is deliberately leaked.* When
  `DrainPendingUpdate` gives up after 300 ms, ScreenCaptureKit is still
  applying that `SCStreamConfiguration` as far as this code can tell, and
  whether it retained a copy is undocumented. The reference is dropped
  **without** a release: a release that turns out to have been the last one
  is a use-after-free inside the framework, and the alternative costs a
  few hundred bytes on a path that needs a stream to have stopped
  answering for a third of a second. Unowned beats freed here. For the
  same reason the global counters are **never reset** — an abandoned
  handler may still increment them minutes later — so each stream
  snapshots them at `Start` and reports differences.

Measured on an M-series Mac: ScreenCaptureKit completes an
`updateConfiguration:` in **no less than 50 ms**, so a live animation gets
about twenty steps a second however fast the animator ticks. The zoom
durations (`LiveZoomInSeconds` 0.30, `LiveZoomOutSeconds` 0.45) are
chosen against that number rather than by feel: 0.18 s would be four
steps across a doubling, and four steps is a visible staircase.

**Which recordings get which effect** is `ResolveLiveEffects`, and it is
not the same answer for both. A **window** capture gets neither: its
source rectangle is in the window's own space, which the user is free to
move and resize with no way for us to find out, so a click in screen
points has no fixed meaning there. A **whole display** can zoom but has
nowhere to pan to. Only a **region** gets both. A display capture that is
going to zoom needs a source rectangle it would not otherwise have, so
`TRecordingOptions.LiveSourceRect` makes `ResolveFilter` seed one
covering the display; the CLI never sets it.

**The border, and the one place rule 1 gives way.** The frame around a
region is kept out of the file two ways ([above](#menu-bar-app)): rule 1,
it is stroked *outside* the recorded rectangle; rule 2, its window id is
excluded from the content filter. Zooming needs neither — the capture
area on screen has not moved, so the frame stays where it is. Panning
does: the frame moves with the region (`TRecordingBorder.MoveTo`, one
`setFrame:display:`, so the window id and therefore the exclusion are
unchanged). But the window server and ScreenCaptureKit apply their
changes on their own schedules, so for a frame or two around a pan the
two disagree and part of the border really is inside the rectangle being
captured. **Rule 1 does not hold during a pan; rule 2 does, and is not
timing-dependent.** Proven on device by recording a 200-point pan twice,
with 138 border moves in lockstep with 41 source-rectangle updates:
with the exclusion, **0** border-red pixels in all 141 frames; with the
exclusion deliberately switched off, **665 792** red pixels across the
run and 2 560 in the worst single frame. That is why Follow Mouse is
*refused* for a recording whose border did not reach the content filter
— the app logs why and records with a fixed region rather than a frame
that keeps sliding into shot.

"The border was excluded" is read conservatively, and not as a
count-above-zero: the report says how many of the requested ids resolved,
not *which*, so the test is "the border was among the requests **and**
every request resolved". The moment a second exclusion joins the list —
the camera window is the obvious candidate — a count test would call the
border excluded because something else was. This one refuses Follow Mouse
instead, which is the right way round when the cost of being wrong is a
recording with its own frame sliding through it.

**Clicks are polled, not monitored.**
`NSEvent.addGlobalMonitorForEventsMatchingMask:handler:` binds in FPC
3.2.2 and needs no Input Monitoring grant for mouse events (keys would),
and it would catch clicks shorter than a tick. It is still not used. The
animator has to sample the mouse *position* every tick for Follow Mouse
anyway, so reading `NSEvent.pressedMouseButtons` in the same breath is
free and avoids a second, block-based source of truth for one gesture,
plus a retained monitor object with a lifetime to get wrong across a
recording that can fail at any point. The cost is stated rather than
hidden: a press-and-release shorter than one tick — about 33 ms — is not
seen. A deliberate click is 50 to 150 ms, and the miss costs a zoom, not
a recording. The detection is edge-triggered on the transition, so
holding the button through a drag zooms once.

**The menu bar is carved out of the clickable area**, even though for a
whole-display recording it is squarely inside it. The click that *stops* a
recording is a click on Knips's own status item, so without this rule
every full-screen capture would end by zooming into the top corner of the
screen. Nothing up there is content anyway — a menu title is a click on a
menu, not on the thing being demonstrated. The band is the larger of
`NSStatusBar.thickness` and the screen's own top inset
(`frame` minus `visibleFrame`, measured from the top, which is the menu
bar because the Dock can sit at the left, right or bottom but never the
top). They disagree and the inset is the honest one: this machine reports
a thickness of 22 points against an inset of 39.

**Every duration in the animator is driven from one clamped tick delta**,
including the post-click hold, which is a countdown rather than a
wall-clock deadline. A backwards clock step — an NTP correction, a DST
change, the user setting the clock — would otherwise leave a `TDateTime`
deadline in the future for as long as the step lasted and freeze a zoom
mid-recording. A negative delta reads as no time passing and a large one
is capped, so the same clamp covers both directions.

A throwing live tick is the one callback that does **not** go down the
`Fail` path: it stops the animator and leaves the recording running with
a fixed frame. A zoom is not worth a lost file. Stopping the animator
sends **nothing** — putting the capture back on its base rectangle was
the obvious thing to do and is the wrong one, because it lands as an
instantaneous jump in the last frames of the clip. The animation is a
valid framing at every instant, so the file ends where it was.

**What was measured, and what was not.** The mechanism is proven on
device against a lattice of known pitch — black bars 8 points wide at a
pitch of 32, so at capture scale 2 the output pitch is 64 px at zoom 1
and 64·Z px at zoom Z:

| | measured |
| --- | --- |
| base rectangle | pitch 64.00 px on both axes |
| zoom 2 | pitch **128.00** px on both axes, output still 1024×768 |
| the ramp between | 64 → 73 → 82 → 104 → 113 → 127 → 128, the smoothstep shape |
| back to base | pitch 64.00, phase back to its starting value |
| a 200-point pan | phase moved 48 px; 200 pt × scale 2 = 400 px, and 400 mod 64 = 400 − 384, so −400 ≡ 48 (mod 64) |
| through `TLiveAnimator` itself | the window panned 341.00 → 0.00 points, matching the tested maths' own fixpoint to the hundredth; content phase moved 42 px, and 341 × 2 = 682 ≡ 42 (mod 64) |
| the writer | 1024×768 for every frame of every run; 0 dropped, 0 failed appends; 28/28, 41/41, 40/40, 25/25, 13/13 and 14/14 updates completed, none refused |

The three answers above were checked against a framework that really does
refuse. A source rectangle at an origin of 10⁹ points comes back as
`-3812`, `SCStreamErrorInvalidParameter`, which makes the whole failure
path reachable on demand:

| | measured |
| --- | --- |
| accepted rectangle, then the same **+ 0.1 pt** | second one **deduped** — the epsilon still works when nothing went wrong |
| refused rectangle, then the same **+ 0.1 pt** | second one **sent** — the heal, twice over, at the same 0.1 pt delta the control deduped |
| five refusals in a row | live updates switched **off** at the sixth call, `live zoom/pan disabled: ScreenCaptureKit refused 5 source-rect updates in a row (last error -3812)`; every later call refused without sending |
| the recording, through all of it | 12 sent, 3 completed, 9 refused, and still 174 frames, 0 dropped, 0 failed appends, 1024×768 |

The two rows at the top are the same experiment with one variable
changed: identical delta, identical epsilon, opposite outcome, and the
only difference is whether the previous rectangle was refused.

The pointer cannot be moved by test tooling — this project does not
inject input — so Follow Mouse was proven by moving the *region* instead
and letting the real animator chase the real, stationary pointer into its
dead zone. **The click that triggers a zoom is the one thing not proven
here**; its arithmetic is unit-tested and its two inputs
(`pressedMouseButtons`, `mouseLocation`) were read on device, but nobody
has clicked a mouse into this code.

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

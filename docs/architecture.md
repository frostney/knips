# Architecture

## Executive Summary

- One binary: ScreenCaptureKit stream → complete-frame filter →
  AVAssetWriter input (hardware H.264) → `.mp4`/`.mov`. opname never
  touches pixels or NAL units; it moves sample buffers.
- The `SCStreamOutput` object the framework calls back into is a
  **runtime-built Objective-C class** — one plain `cdecl` Pascal routine
  registered with `class_addMethod` — so the build needs no linker flags
  ([ADR-0002](adr/0002-runtime-built-objc-classes.md)).
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
| CLI | `opname.pas` | lwpt `cli` package: `record`, `export`, `displays`, `windows`, `probe`; SIGINT/SIGTERM → `StopRequested` |
| Recording | `Opname.Recording` | Target → filter + geometry → writer → stream; progress; report |
| Capture | `Opname.Capture.ShareableContent`, `Opname.Capture.Stream` | SCShareableContent query (run-loop pumped); SCStream + runtime output object |
| Export (Darwin) | `Opname.Export.MovieWriter`, `Opname.Export.MovieReader`, `Opname.Export.GifPipeline` | AVAssetWriter/Input bindings; AVAssetReader/TrackOutput bindings; the two-pass GIF export |
| Export (neutral) | `Opname.Export.Gif`, `Opname.Export.Bitmap` | Median cut, dithering, LZW, GIF89a writer; BGRA buffer + resampling (both tested) |
| ObjC | `Opname.ObjC.Runtime`, `Opname.ObjC.TypeEncoding` | Class assembly via libobjc; method type encodings (tested) |
| Options | `Opname.Options` | Neutral option model, validation, derived values (tested) |
| Vendored | `source/capture/*` | CoreMedia/CoreVideo/VideoToolbox/GCD, ScreenCaptureKit externals, pthread mutex |

Nothing above the capture layer knows about `objcclass`; nothing below
the recording layer knows about the CLI.

## The GIF export

`opname export` is the mirror of `record`, and it is deliberately thin on
the Darwin side: `Opname.Export.MovieReader` turns an `.mp4`/`.mov` into
a stream of BGRA `CVPixelBuffer`s with presentation stamps, and
everything that decides what the file looks like —
`Opname.Export.Bitmap` and `Opname.Export.Gif` — is platform-neutral and
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
| 2 | failure — framework, permission, writer, or reader error (message printed) |
| 3 | unsupported — not a macOS build |

A second Ctrl-C during finalisation calls `_exit(2)`; the file may be
unplayable, which is preferable to a corrupted writer state.

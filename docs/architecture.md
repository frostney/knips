# Architecture

## Executive Summary

- One binary: ScreenCaptureKit stream → complete-frame filter →
  AVAssetWriter input (hardware H.264) → `.mp4`/`.mov`. Knips moves
  sample buffers and never touches a NAL unit; the one thing that writes
  pixels is [Big Cursor](#big-cursor), which draws into the frame before
  the encoder ever sees it.
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
  GIF export. That window is the app's one ordinary document window, and
  for as long as it is open the process switches to the `Regular` policy
  — a Dock tile, a place in ⌘-Tab, and a menu bar with ⌘W and ⌘Q. See
  [Menu bar app](#menu-bar-app).
  GIF export. See [Menu bar app](#menu-bar-app).
- Two menu checkboxes change what a recording shows while it runs —
  *Zoom on Click* and *Follow Mouse*. Neither touches the file's
  dimensions, which `AVAssetWriter` fixes at the first frame: both animate
  the stream's `sourceRect` through
  `SCStream.updateConfiguration:completionHandler:`, so a smaller
  rectangle is a zoom and a sliding one is a pan. See
  [Live effects](#live-effects-zoom-on-click-and-follow-mouse).
- *Big Cursor* is the one place this program does touch pixels:
  ScreenCaptureKit's own pointer is switched off and a sprite rendered
  once on the main thread is blitted into each frame's `CVPixelBuffer`
  before the writer sees it, so the GIF and APNG exports inherit it. The
  arithmetic is neutral and tested; the blit runs on the capture queue
  and is written to that thread's rules. See
  [Big Cursor](#big-cursor).
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
  encoders, the delay planner, the live-effect and big-cursor maths) is a
  unit with a co-located test that runs on Linux too.

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
| CLI | `knips.pas` | lwpt `cli` package: `app`, `record`, `export`, `displays`, `windows`, `mcp`, `probe`; SIGINT/SIGTERM → `StopRequested` |
| MCP | `Knips.Mcp`, `Knips.Mcp.Params` | The tool surface over pascal-mcp-sdk's stdio transport; the neutral half is the tool table, argument mapping, and default paths (tested) |
| App | `Knips.App`, `Knips.App.Overlay`, `Knips.App.Border`, `Knips.App.Playback`, `Knips.App.Camera`, `Knips.App.State` | Status item + menu, selection overlay, the recording frame, the playback/export window, the camera picture-in-picture window, and the neutral state machine (tested) |
| Recording | `Knips.Recording` | Target → filter + geometry → writer → stream; progress; report |
| CLI | `knips.pas` | lwpt `cli` package: `app`, `record`, `export`, `displays`, `windows`, `probe`; SIGINT/SIGTERM → `StopRequested` |
| App | `Knips.App`, `Knips.App.Overlay`, `Knips.App.Border`, `Knips.App.Playback`, `Knips.App.Camera`, `Knips.App.Live`, `Knips.App.Hotkey`, `Knips.App.State` | Status item + menu, selection overlay, the recording frame, the playback/export window, the camera picture-in-picture window, the live-effect animator, the global stop hotkey, and the neutral state machine (tested) |
| Recording | `Knips.Recording`, `Knips.Recording.LiveMath`, `Knips.Recording.CursorMath`, `Knips.Recording.CursorOverlay` | Target → filter + geometry → writer → stream; progress; report. The live-effect and big-cursor arithmetic are neutral and tested; the overlay is the Darwin half that makes the sprite and blits it |
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

## The MCP server

`knips mcp` is a third front end onto the same machine, beside the CLI
and the menu-bar app, and it is built the same way: `Knips.Mcp.Params`
turns a `tools/call` arguments object into a `TRecordingOptions` or
`TExportOptions` and hands it to `ValidateRecordingOptions` /
`ValidateExportOptions`, so an agent and a shell user are refused for
identical reasons. (The messages are rewritten once at that boundary —
`--fps` becomes `fps` — because a refusal naming a flag sends an agent
looking for an argument its schema never declared.) `Knips.Mcp` then
runs the same `TRecordingSession`, `TExportSession`, and
`TMovieTrimSession` the other two front ends do. The neutral half has a
co-located suite and runs on Linux CI; the Darwin half compiles
everywhere and refuses in-band off macOS, so the tool list an agent
discovers is the same list on every host.

Every in-band failure leaves through one function (`KnipsToolError`),
which is where the flag rewrite happens — so a message from
`Knips.Recording` ("no display at index 3 (see `knips displays`)") is
translated exactly like one from `Knips.Options`, rather than the
rewrite being remembered at each of a dozen call sites. The rewrites are
anchored to token boundaries: these templates interpolate the caller's
own text, and a file named `x.--fps.mp4` must come back spelled the way
it was passed.

Two places where the MCP contract deliberately differs from the CLI's,
both because the caller is a program rather than a person:
`record_start` refuses an existing `out` unless `overwrite` is set (the
CLI replaces what you named), and `export_trim` refuses `fps`/`width`/
`dither` rather than warning and ignoring them (nothing is reading
stderr). Paths are expanded and returned absolute for the same reason —
an agent cannot resolve a relative path against a working directory it
never saw.

The protocol comes from
[pascal-mcp-sdk](https://github.com/frostney/pascal-mcp-sdk) (FPC RTL +
fpjson, no third-party runtime dependency). Two consequences matter
here:

- **No new thread.** The SDK's stdio transport is a synchronous
  read-handle-write loop on the calling thread: read one line, run one
  handler, write one line, flush. It creates nothing and adopts nothing,
  so the no-`cthreads` invariant below is untouched. (The SDK's *HTTP*
  transport does need `cthreads` for its listener; Knips does not use
  it, and adding it would cost the SIGSEGV immunity the whole capture
  path depends on.) The SDK's own `TRTLCriticalSection` use is served by
  the pthread-backed locks `Knips.ThreadManager` already installs.
- **Recording outlives a handler.** `record_start` calls
  `StartCapture` and returns; the loop goes straight back to blocking on
  stdin. Nothing pumps a run loop in between and nothing needs to —
  ScreenCaptureKit delivers on its own GCD queue into the writer, which
  is exactly the arrangement the menu-bar app relies on between the
  click that starts and the click that stops. `record_stop` calls
  `FinishCapture` on the same main thread that started it, which is
  where its `CFRunLoopRunInMode` waits belong. `record_status` reads the
  writer's mutex-guarded counters live (`TRecordingSession.LiveStatistics`),
  including `WriterFailed` — a writer that left its writing state stops
  the session then and there and reports it, because every further frame
  would be captured into a dead file. That is the same reason the CLI's
  run loop aborts on it.

The session lives on the server object for the life of the process, not
of a connection, so "one recording at a time" is enforced in one place;
stdin EOF tears the server down and finalises a capture still running,
which is the only clean shutdown a stdio server gets.

Screen Recording permission is granted per host application and this
process inherits its client's attribution, so the first capture prompts
whichever app launched the server — see
[quick-start](quick-start.md#the-mcp-server).

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

**So does time.** Per-frame cost is flat for the whole encode pass —
there is no structure in the encoder that degrades as the export
proceeds, and the nearest-colour memo in particular cannot: it is
direct-mapped, so a full table costs a clobbered slot and never a longer
probe. Measured over an 800-frame 1600×1000 export, the memo's occupancy
climbs to 99.9% of its 2^20 slots while the miss rate stays at 1.8% and
the palette walk stays at 40 steps a miss, first decile to last; per-frame
encoder time over the same run is 75.4 ms in the first decile and 77.0 ms
in the last. On a *real* recording per-frame time moves by a factor of
two either way, and it tracks how much of the screen changed in that
frame — content, not history.

**How many frames the export will emit** is asked twice — once by
whatever draws the progress, once by the palette pass to space its
sample frames — and `ExpectedFrameCount` answers with two different
kinds of number depending on when it is asked.

After the palette pass it is a *count*: that pass walks the whole movie
through the same decimator the encode pass will use, so the frames it
emitted are the frames the encode pass will emit. Before it there is
nothing to count, so it is a bound, and the whole design turns on it
being a bound and not a guess.

The obvious bound — the range times the requested rate, which is the
number of grid slots the decimator can fill — is far too loose for the
input this program actually has. ScreenCaptureKit emits a frame when the
screen *changes*, so a recording with any idle stretch in it holds
nothing like its length times any rate it was asked for: on a 220 s
capture asked for at 20 fps that bound says 4412 frames and the movie
holds 1723. As the encode pass's total it gave a bar that crawled at a
third of its true rate and then stopped at 54%; as the palette's stride
it did worse, and that is the next section.

The second bound is the movie's own frame count.
`AVAssetTrack.nominalFrameRate` is the average a variable-rate track
really achieved — on the recordings measured here it agrees to four
figures with the container's frame count over its duration — so the
*duration* times that rate is how many frames exist at all, which bounds
any part of the movie as surely as the whole. Taking the duration rather
than the range is what keeps it a bound: a `--trim` over a busy stretch
of an otherwise idle recording holds frames far denser than the movie's
average, and the range times the average would sit *below* what that
stretch emits. The answer is the smaller of the two bounds, and on the
220 s capture that is 2428 rather than 4412.

The measured count then replaces both, taken after the first pass has
finished reporting rather than during it: changing the total mid-pass
would walk the bar backwards.

**Which frames the palette is built from** is a stride over the emitted
frame *index*, and the weighting is deliberate. Every frame the encoder
writes counts the same towards how the result looks, so a busy stretch,
which produces more frames, has earned more of the palette than an idle
stretch of the same length. Spreading the samples over the clock instead
— which has the appeal of needing no frame count at all — was tried on
the 220 s capture and cost 0.45 dB.

A stride does need the count in advance, which is exactly what the pass
does not have, and it is the *direction* of the error that matters. Too
large a stride costs samples. Too small a one is worse than that: the
quantiser's sampled-pixel budget (`GifMaxSampledPixels`) is precisely
`PaletteSampleFrames` frames' worth, and past it `SampleFrame` returns
without doing anything — so a stride that runs long leaves the tail of
the movie out of the palette entirely, silently. That is why the bound
above is built to run high and never low.

Measured against the same clip exported as an APNG, which quantises
nothing and so is exactly the pixels the scaler produced:

| recording | sample frames | PSNR |
| --- | --- | --- |
| 220 s 1428×616 → 714 px, 20 fps | 13 → 23 | 39.40 → 39.70 dB |
| 32 s 1160×860 → 800 px, 30 fps | 23 → 31 | 30.83 → 30.88 dB |
| 32 s 1160×860, 20 fps | 24 → 24 | 36.42 dB, byte-identical |

The third row is the point as much as the first two: where the slot
count was already the tighter bound, nothing changes at all.

The other half of an honest bar is the *weight* of the two passes. The
palette pass reads every frame but resamples only every Nth, so it is
much the cheaper of the two, and the more so the larger the canvas — the
encode pass is per-pixel work and the palette pass is not. Measured
shares of the export's wall time: 1.9% (69 s, 1200×800), 2.6% (32 s,
1160×860), 5.8% (220 s, 1428×616). `PaletteProgressPercent` in
`Knips.App.State` is 5 for that reason. It was 25, which is what used to
make the export look like it stalled a quarter of the way in: the bar
sprinted through the palette pass in the first few percent of the time
and then crawled for the rest.

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
the thread to `NSApplication.run`. It stays `Accessory` for everything it
does with the screen; the one exception is the playback window, which
promotes it to `Regular` for as long as it is open
([Dock and the main menu](#dock-and-the-main-menu)). There is one state
machine:

```text
         Record Region…                 mouse up (usable drag)
  asIdle ───────────────▶ asSelecting ───────────────────────▶ asRecording
     ▲                        │                                     │
     │                        │ Esc / stray click / capture failed   │ click the
     │◀───────────────────────┘                                     │ item, or
     │                                                              │ Stop
     │  Record Display / Record Window / Record Last Region ───▶     │
     │◀─────────────────────────────────────────────────────────────┘

  asIdle ──Audio ▸ System Audio─▶ asIdle  (a self-transition: the command
         ──Audio ▸ Microphone──▶           is legal only where the stream
         ──Zoom on Click───────▶           configuration is not yet fixed)
         ──Follow Mouse────────▶
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
| `KnipsAppTarget` | `NSObject` | `recordRegion:`, `recordDisplay:`, `recordWindow:`, `recordLastRegion:`, `toggleSystemAudio:`, `toggleMicrophone:`, `toggleZoomOnClick:`, `toggleFollowMouse:`, `liveTick:`, `cameraRideTick:`, `stopRecording:`, `cancelSelection:`, `revealRecordings:`, `toggleCamera:`, `toggleCameraShape:`, `restoreCamera:`, `quitKnips:`, `timerFired:`, `startPending:`, `stopPending:`, `exportGif:`, `revealRecording:`, `closePlayback:`, `menuNeedsUpdate:` |
| `KnipsOverlayView` | `NSView` | `drawRect:`, `mouseDown:`, `mouseDragged:`, `mouseUp:`, `keyDown:`, `acceptsFirstResponder` |
| `KnipsOverlayWindow` | `NSWindow` | `canBecomeKeyWindow` (a borderless window answers NO, and then Esc never reaches the view) |
| `KnipsCameraView` | `NSView` | `acceptsFirstMouse:` (Knips is an Accessory app, so without it the first click on the camera window is eaten as the activating click and dragging takes two); `mouseDown:`, `mouseDragged:`, `mouseUp:` — the drag, done here rather than by `movableByWindowBackground` so the corner snap has a drag end; `snapTick:` — one step of the snap ease, so the ease needs no nested run loop and no second runtime class |
| `KnipsBorderView` | `NSView` | `drawRect:` — the frame drawn around a region while it records |
| `KnipsPlaybackDelegate` | `NSObject` | `windowWillClose:` — the one teardown path for the playback window; `windowShouldClose:` — NO while a GIF export is running |

The two bodies that return a constant and never call back into Pascal —
`KnipsCameraView.acceptsFirstMouse:` and
`KnipsOverlayWindow.canBecomeKeyWindow` — carry no `try..except`, because
there is nothing there that can raise; `KnipsOverlayWindow` needs no ivar
either. Every other class carries an `knipsOwner` pointer ivar
back to the owning Pascal object, cleared before the Objective-C instance
goes away — the same rule as the stream output object.
`KnipsCameraView` gained its ivar with the drag: the three mouse bodies
have an owner to talk to, where `acceptsFirstMouse:` never did.
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
what makes re-entry impossible. Closing is refused for the same reason,
in two places that between them cover every route: `CommandClose` — the
Close button, Quit, a recording about to start, `Show` replacing the
window — checks the flag itself, and `windowShouldClose:` answers NO to
the closes AppKit drives on the user's behalf, which are the titlebar's
button and ⌘W. `CommandClose` uses `-close`, which deliberately does
*not* consult the delegate: `Show` must be able to replace the previous
window, and a delegate that could veto that would strand it. The window is `activateIgnoringOtherApps`'d
into the foreground, exactly as the overlay is — a titled window can
become key even under the Accessory policy, which is why this one needs no
runtime class for it.

Opening it also promotes the process ([below](#dock-and-the-main-menu)),
and closing it puts the process back. `Knips.App.Playback` does not do
that itself: it fires an `OnClosed` event at the end of
`HandleWindowWillClose`, once every field is already nil, and
`TAppController` owns what a window on screen means for the process. The
window unit knows about `NSWindow`; the activation policy is the app's
business.

**Remembered settings.** Four, all in `NSUserDefaults`:
`KnipsAudioSystem` and `KnipsAudioMicrophone` (the Audio submenu's
two checkboxes, [below](#the-audio-submenu)),
`KnipsZoomOnClick` and
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

**Each toggle writes its own key, and only its own.** The three checkbox
fields are read once, at `Setup`, and never read again, so a procedure
that wrote `KnipsZoomOnClick` and `KnipsFollowMouse` together — as one
did — wrote one value the user had just chosen and one that was however
old the process was. Anything that had changed the other key meanwhile
was silently reverted by the next toggle of its neighbour: the
`defaults write` the paragraph above already treats as a public
interface, or a second Knips, which is not exotic at all — the installed
bundle and a development build both answer to `org.knips.app`. Measured:
with the paired write, an external `KnipsFollowMouse=1` is back to `0`
one *Zoom on Click* click later; with `StoreZoomOnClick` and
`StoreFollowMouse` separate, it survives. What that looked like from
outside was a preference that would not stay switched on — and, because
Follow Mouse then really was off, a region recording that did not pan.

Note what is *not* covered by this, because it is the one setting that
still needs a clean exit: the camera window's position (below, under
*The camera window*) is written by `TCameraPreview.Hide`, so it
survives switching the camera off or quitting from the menu, and is lost
to a force quit, a log-out or a `kill`. Every other remembered setting is
written the moment it changes.

**The click.** Idle, the status item has its menu; recording, the menu is
detached and the button's action is `stopRecording:`, so a single click
stops — Kap's gesture. An `NSTimer` on `KnipsAppTarget` rewrites the
title once a second while recording (`⏺ 0:07`).

That gesture costs the menu while recording, so **Quit is deliberately
unreachable from the status item until the recording stops** — one click
stops it, and Quit finalises any session still open before calling
`terminate:` anyway. ⌘Q is the exception, and only once a playback window
has installed the main menu ([below](#dock-and-the-main-menu)): it runs
the same `quitKnips:`, with the same finalisation and the same refusal
mid-export.

### The Audio submenu

*Audio* is a submenu holding **two independent checkboxes** — *System
Audio* and *Microphone* — which between them offer all four of the
`TAudioMode`s the recorder has taken since the CLI grew `--audio`:
neither ticked is `none`, one is that one, both is `both`
(`AudioModeFromToggles` in `Knips.App.State`, tested). They sit behind
one *Audio* item rather than loose in the root menu because between them
they are one setting — what the recording listens to.

It replaces a single *Record System Audio* checkbox, and the reason is a
regression in experience rather than a bug: the app offered exactly one
of the four modes, so a user who **spoke** into a take got a silent file
and concluded that Knips does not record audio. It did; it just never
offered them the source they meant.

Each checkbox is its own selector (`toggleSystemAudio:`,
`toggleMicrophone:`) and its own command (`acToggleSystemAudio`,
`acToggleMicrophone`), both idle-only for the same reason the
live-effect checkboxes are: what a stream captures is fixed when the
capture starts, and a source switched on mid-take would silently do
nothing.

**One key each, and a one-way migration.** `KnipsAudioSystem` and
`KnipsAudioMicrophone` — separate keys written by separate procedures,
which is the rule the cross-write incident below established and not a
stylistic choice. `objectForKey:` separates *never written* from a
legitimate `False`, and only a never-written `KnipsAudioSystem` consults
the Boolean this replaced: `KnipsRecordSystemAudio` true starts the app
with **System Audio** ticked, so nobody who had the box ticked finds the
next launch recording silence. That "has the key" test is load-bearing
in the other direction too — without it, a user who deliberately
switched system audio *off* would have the stale legacy key switch it
back on at every launch. The old key is read once and never written, and
deliberately not deleted: `defaults` is a public interface and a
downgrade should still find what it wrote. Measured on device: with
`KnipsRecordSystemAudio=true` and no new key, the app launches with
*System Audio* ticked and *Microphone* clear.

**Microphone availability, in two independent layers.**

1. *Does this Mac have it at all.* `SCStreamConfiguration.captureMicrophone`
   is macOS 15 and the project floor is 13, so `StreamSupportsMicrophone`
   is asked once at `Setup`. Where it answers NO the *Microphone* item is
   disabled, the reason rides in the title (`Microphone — needs macOS
   15`) as well as in a tooltip — a greyed-out line that does not say why
   is what users file bugs about — and a stored tick is dropped at load,
   so a checkbox that cannot work never starts out ticked. *System Audio*
   has no equivalent: it is macOS 13, like the floor.
2. *May this binary use it.* The Microphone TCC grant is separate from
   Screen Recording and separate from the Camera, and **a source that
   delivers nothing is invisible from inside ScreenCaptureKit** —
   `setCaptureMicrophone:` takes, `startCapture` succeeds, and the
   microphone output simply never produces a sample. That is the same
   shape the camera's denied grant takes
   ([spike 0001](spikes/0001-runtime-objc-class.md)), and left alone it
   produces exactly the failure this feature exists to end: a finished
   file with a silent second track and no explanation anywhere.

   `Knips.Capture.Stream.MicrophoneAccess` **warns**, and it warns at the
   moment the user ticks *Microphone* — not when a recording starts. Both
   halves of that are deliberate.

   *Warns rather than refuses*, because on macOS 26 a signed bundle whose
   AVFoundation microphone status read *NotDetermined* recorded 421 760
   microphone samples at −39 dB, with no prompt answered, and the status
   still read *NotDetermined* afterwards. ScreenCaptureKit's
   `captureMicrophone` plainly does not go through the gate that API
   reports, so refusing on it could refuse a recording that would have
   worked — a worse failure than the one being prevented.

   *At toggle time*, because that is the only moment it can be seen. The
   app is idle, so the menu is attached and the `Last error:` line is on
   screen; the same warning issued as a recording starts would be written
   while the menu is detached, and would fire again after every recording
   whose microphone had in fact worked.

**The guarantee is the sample count**, because it needs to know nothing
about which gate said no — and it also covers a grant revoked
mid-recording, a device unplugged, and any future framework refusing in
some way nothing here anticipates. When a recording asked for the
microphone and `Report.AppendedMicrophoneSamples` is 0,
`FinishRecording` records an error. Never a `Fail` — the video is
finished and on disk either way.

Which error depends on the *other* three counters. Microphone buffers
that arrive before the first video frame have no timeline to sit on and
are dropped and counted (`DroppedMicrophoneEarly`), as are buffers
arriving while their writer input is not ready. A take short enough to
park every buffer there has a perfectly good grant, so the message only
points at System Settings when all three of those counters are zero;
otherwise it reports the counts and leaves the permission out of it.

### The global stop hotkey

**⌘⇧2 stops a running recording from anywhere.** Kap has the same
gesture, and it is the one thing a recorder is asked for that the status
item cannot do: while Knips records, the status item has *no menu*
(a single click stops it, above), and the window the user is
demonstrating in is the last place they should have to leave.

`Knips.App.Hotkey` registers it with Carbon's `RegisterEventHotKey` and
an `InstallEventHandler` on `GetApplicationEventTarget`. **Carbon is the
point, not an accident of the bindings**: it is the only route to a
global hotkey that costs no TCC grant. The window server matches the
chord and posts an event to the registering process, so no key pressed
anywhere else is ever seen by this app. Both alternatives —
`NSEvent.addGlobalMonitorForEventsMatchingMask:` and a `CGEventTap` —
need Input Monitoring, which is a *"Knips wants to read everything you
type"* dialog in exchange for one shortcut.

The API surface is header-verified against FPC 3.2.2's `univint`
(`MacOSAll` re-exports `CarbonEvents` and `CarbonEventsCore`) and read
back at run time by `knips probe`: `kVK_ANSI_2` = 19, `cmdKey` = 256,
`shiftKey` = 512. `NewEventHandlerUPP` is deliberately **not** used — on
every architecture this project targets a UPP *is* the function pointer,
the symbol is not in the framework at all (linking against it fails
outright, measured), and Apple's header defines the call as the
identity. The `cdecl` handler is cast straight to `EventHandlerUPP`, and
carries the same `try..except` every other foreign-frame callback in
this app does.

**The hotkey fires exactly one thing: a stop.** Not a toggle. A global
chord that could *start* a recording is a global chord that starts one
by accident, and the transition table only accepts `acStopRecording` in
`asRecording` anyway — outside that state the handler runs, finds
nothing to stop, and returns. It goes through the same `CommandStop` the
status-item click does, deferred by the same `stopPending:` one-shot, so
there is one stop path and not two. The handler runs on the main
thread's run loop, which `NSApplication.run` drives.

The chord is shown on the *Stop Recording* item with `setKeyEquivalent:`
and a `⌘⇧` modifier mask. That is **display only** — a key equivalent on
a menu that is detached fires for nobody, which is precisely the state
the menu is in while a recording runs. What it buys is the one place the
shortcut can be discovered.

**One measured surprise, and it is why registration success proves
little.** `RegisterEventHotKey` answers `noErr` for a chord the system
already owns: registering ⌘⇧3, the screenshot shortcut, returns 0 just
as ⌘⇧2 does. What the system keeps is the *delivery*, not the
registration. The case that *is* caught is a second registration by the
same process — `eventHotKeyExistsErr` (−9878). A failed install is a
`Last error:` line and nothing more; the app is perfectly usable without
it. Whether a real keypress arrives is a human check
(docs/quick-start.md), because this project's test tooling may not
synthesise input; what `knips probe` and the harness *can* prove is that
the handler is wired — a `kEventHotKeyPressed` event built and sent to
`GetApplicationEventTarget` reaches the Pascal callback, is ignored when
its `EventHotKeyID` is not ours, and stops arriving after `Remove`.

Unregistered on the way out, in `CommandQuit` before anything else:
`terminate:` never returns, so the destructor is not a place this can
happen, and a chord left held by a departing process is a chord the next
Knips cannot have.

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

  Three details make that lockout actually hold, and each of them was a
  hole first. **`Transition`'s answer has to be read.** `CommandStop`
  used to call it and queue `stopPending:` regardless — and that one-shot
  fires inside the export's *own* run-loop slices, re-entering a
  `FinishRecording` that pumps the run loop from under an export that is
  already pumping it. It now returns when the transition is refused; the
  recording keeps running and one more click stops it once the export is
  done. **`RefreshStatusItem` has to keep the menu detached** while
  `Busy`, or the refusal path puts back the very menu
  `CommandExportGif` removed to keep menu tracking out of the export.
  **The user's own close has to be refused too**, which is
  `windowShouldClose:` rather than a chain of nil-checks.

**Exceptions never cross the boundary.** Every `cdecl` method body in
`Knips.App` and `Knips.App.Overlay` is wrapped in `try..except`. There
is no Objective-C frame that could unwind a Pascal exception, and AppKit's
drawing, event dispatch and run loop all sit above these bodies. What is
caught becomes a message on the same NSLog + log file + "Last error"
path, and the method returns normally.

**The camera window.** *Camera* puts a 240×180 borderless window at
`kCGFloatingWindowLevel` on screen, its content view hosting an
`AVCaptureVideoPreviewLayer` (`resize-aspect-fill`, 8 pt corner radius,
`masksToBounds`) fed by an `AVCaptureSession` on
`defaultDeviceWithMediaType:AVMediaTypeVideo`. The whole picture is the
drag handle — there is no title bar — and it joins all Spaces the way the
overlay does.

Knips does **no** compositing: the camera is simply a window, and
ScreenCaptureKit records it because it is on the display, exactly as Kap
does it. Nothing in `Knips.Recording` or `Knips.Export.MovieWriter`
knows it exists. That is also why the toggle sits **outside** the state
machine and is legal in every state — a passive window cannot fail a
capture, and mid-recording is when the user is most likely to want it on
or off. It keeps running across recordings; only Quit or a second click
takes it down.

*Mirrored*, because everyone expects a selfie mirror and the raw feed is
not one. The preview layer's `AVCaptureConnection` gets
`setAutomaticallyAdjustsVideoMirroring:NO` and then `setVideoMirrored:YES`
— **that order**, and only after `isVideoMirroringSupported` answers YES,
because `AVCaptureSession.h` throws `NSInvalidArgumentException` for
either violation and an Objective-C exception is not something a Pascal
`try..except` can catch. The guards are the whole safety net. The
connection is formed by `initWithSession:` and is non-nil from there on
(measured, [spike 0001](spikes/0001-runtime-objc-class.md)); mirroring is
applied there and again after `startRunning`, in case starting re-forms
it. And because the recorder captures the window as it appears,
**the file gets the mirrored picture too** — which is what Kap does and
what a viewer wants: the presenter pointed left, the video shows left.

*Dragging and snapping.* `movableByWindowBackground` is **off**.
The snap needs a moment that unambiguously means "let go", and AppKit's
background drag runs in `NSWindow`'s own mouse-tracking loop and ends
there. So `KnipsCameraView` implements `mouseDown:`/`mouseDragged:`/
`mouseUp:` and `Knips.App.Camera` moves the window itself, from
`NSEvent.mouseLocation` deltas — global screen points, because
`locationInWindow` is measured against a window that is itself moving.
`mouseUp:` is then the drag end by construction, and it demonstrably
arrives (spike 0001). On release — and only if the window actually
travelled `CameraDragThreshold` points, so a bare *click* never teleports
a window that was deliberately placed — it eases into the **nearest
corner** of the screen's `visibleFrame`, inset by the same
`CameraWindowMargin` the very first placement uses, so a drop where the
camera already was does not move it. `NearestCameraCorner` in
`Knips.App.State` is the maths, and it is separable: four corners on a
2×2 grid means nearest-corner is nearer-edge on each axis.

That ease is **not** `setFrame:display:animate:YES`. AppKit's animated
setFrame runs a nested run loop until it finishes, and a nested run loop
inside `mouseUp:` is the shape this app avoids everywhere else (see
"Deferrals"): a re-grab lands inside it and fights the animation, a shape
change lands inside it and leaves the layer's radius arguing with the
window's size, and a `Hide` lands inside it and has to trust the
autorelease pool to outlive AppKit's animator. Instead the camera owns
twelve steps of a smoothstep on a repeating `NSTimer` in
`NSRunLoopCommonModes` (`snapTick:` on `KnipsCameraView`, so the feature
adds no runtime-built class of its own), with `CameraSnapOrigin` in
`Knips.App.State` as the curve — it returns the target *exactly* on the
last step, because an ease that lands near the corner leaves the window a
fraction of a point out for ever. A single `FSnapping` flag makes the
interactions deterministic: `mouseDown:` **cancels** the ease and drags
on from wherever the window is, while `SetShape`, `DockTo` and `Hide`
**finish** it first, so none of them ever measures a window that is still
travelling. There is no nested run loop anywhere in the camera unit.

*Shape.* *Circular Camera* is a checkbox, not a title that flips, for the
same reason *Camera* is. Checked, the window becomes a **square** 180×180
— a disc needs equal sides — with the layer's corner radius at half the
side; `resize-aspect-fill` was already cropping, so the switch reads as a
re-crop rather than a resize.

**The circle loses the sides; it does not move the middle.** That
distinction is worth stating because the switch is routinely *reported*
as moving the centre of the picture. `resize-aspect-fill` scales the
feed to cover the layer and centres what is left over, so a square layer
over a wider feed keeps the horizontal centre exactly and discards equal
slices left and right. A presenter sitting off to one side of the frame
is inside the 4:3 rectangle and outside the square, which looks like the
picture moved and is the sides being lost.

Measured on device rather than argued. The camera window was captured by
window id in both shapes (`screencapture -l`), giving a 480×360 pixel
rectangle and a 360×360 circle. Sliding a 240×240 patch of the rectangle
across and scoring SSIM against the middle of the circle peaks **exactly
at x = 60 px** — which is `(480 − 360) / 2`, the perfectly centred crop —
and falls away on both sides:

| crop x-offset (px) | 0 | 40 | 56 | 59 | **60** | 61 | 64 | 80 | 120 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SSIM | .613 | .659 | .729 | .805 | **.832** | .800 | .706 | .608 | .560 |

The peak is one device pixel wide — half a point — so the crop is
centred to the limit of the measurement. (It is .832 rather than 1.0
because the two captures are different live frames of a person who
moved.) There is nothing off-centre to fix; what the switch costs is 25 %
of the width from each side.

**What the switch does move, by up to a few points, is the window** —
and only against a screen edge. `SetShape` re-centres and then clamps
back onto the screen, and a 240-wide rectangle re-centred from a
180-wide circle sitting `CameraWindowMargin` from the right edge does
not fit. Measured: a circle at x = 1596 on an 1800-point screen becomes
a rectangle at x = 1560 rather than the centred 1566, so the visual
centre shifts 6 points left and the round trip back to a circle lands at
1590 rather than 1596. Staying on screen is worth more than six points
of centre, and the alternative — snapping to the nearest corner instead
— would move it further. Applied live: the window resizes about its
own centre, clamped back onto the screen, and the layer's frame and radius
follow. Docked, "onto the screen" means into the region *inset by
`CameraWindowMargin`* — the same inset the dock and the snap use, so a
circle growing back into a rectangle against the region's edge keeps the
margin every other placement keeps — and the remembered pre-recording
origin is re-centred with it, or undocking after a shape change would
restore the window by its corner and quietly shift its centre. Persisted under `KnipsCameraShape`, and read back through
`CameraShapeFromStored`, which treats anything that is not the circle as
the rectangle — `defaults write` is a public interface.

*Docking into what is being recorded.* When a recording starts with the
camera up, the window moves into the nearest corner *inside* the
rectangle being captured, inset by the same margin, so the
picture-in-picture is composited into the file the way Kap does it —
still with no compositing code, just a window in the right place.

- A **region** recording docks into the region. `Knips.App` flips the
  capture region (top-left display points) into AppKit's bottom-left
  space with `RegionScreenRect` and hands `TCameraPreview.DockTo` a
  rectangle.
- A **window** recording docks into the recorded window's own frame,
  read straight from the window server with
  `CGWindowListCopyWindowInfo` (`kCGWindowListOptionIncludingWindow`)
  and flipped by `WindowBoundsScreenRect` — Quartz's global space has
  its origin at the *top* left of the primary display. `SCShareableContent`
  is not used for this: it carries no frame, it is asynchronous, and it
  pumps the run loop, which the start path and a timer both must not.
- A **display** recording docks nothing. It already contains the camera
  wherever it stands.

**A window recording does not put the camera in the file, and that is
stated rather than implied.** `SCContentFilter.initWithDesktopIndependentWindow:`
composits that one window and nothing on top of it. Docking there is
about the *screen*: the presenter wants the picture beside the thing
they are demonstrating, and a picture-in-picture stranded in the corner
of a window they have since dragged away is the complaint that produced
this. For the file, a region recording is the mode that composites.

The camera remembers where it was and `Undock` puts it back on every
stop path (`FinishRecording`, `Fail`, and the `StartCapture` failure
branch). The move in is a **single `setFrame`**, not an ease: the
capture is about to open on that frame and a camera sliding into place
would live in the file for ever.

*Riding a rectangle that moves.* The dock is once; staying inside is
continuous, because both docked rectangles move. Follow Mouse pans a
region across the display, and a recorded window goes wherever the user
drags it — ScreenCaptureKit's desktop-independent capture follows it
there. A camera left at the rectangle's *initial* corner is out of shot
the moment either happens.

`TCameraPreview.RideTo` is one unanimated `setFrame:` per tick, exactly
what `TRecordingBorder.MoveTo` does for the frame and for the same
reason: this runs under a live capture, where an ease is an ease in the
file. It keeps **the corner the dock chose** and travels by exactly the
rectangle's displacement — deliberately not "the nearest corner of the
new rectangle", which would teleport the picture across the shot the
moment the rectangle's midline crossed it. Positions are computed from
the dock's own rectangle and origin (`CameraRideOrigin` in
`Knips.App.State`, tested) rather than accumulated tick by tick, so ten
minutes at thirty hertz drift by nothing.

**Two clocks, because two different things move the two rectangles.**

- A **region** rides the live animator's own tick
  (`Knips.App.Live.UpdateCamera`), in the same turn that moves the
  capture and the frame around it — so the three cannot disagree by a
  frame. The animator gets the camera as a second follower beside the
  border and asks it nothing: `RideTo` answers for itself whether a ride
  is live, so a camera that is off, undocked or being dragged costs one
  call and no window-server traffic.
- A **window** is polled at 5 Hz (`cameraRideTick:`). Nothing in this
  process knows when a user drags a window, the poll is a round trip
  rather than arithmetic on numbers the app already has, and a
  picture-in-picture a fifth of a second behind a window drag reads as
  *it follows* while thirty hertz of window-server traffic buys nothing
  anybody can see. A window that has **gone** — closed mid-recording —
  answers with zero entries, and the ride stops rather than chasing a
  rectangle that no longer exists, leaving the camera where it last was.
  Not an error: closing a window mid-take is the user's business.

Both rides were measured on device by driving the app under `lldb` (no
input synthesised — the actions are the app's own selectors, and the
recorded window is one created in-process and moved with `setFrame…`):

| what moved | window moved by | camera moved by |
| --- | --- | --- |
| recorded window | +200, +150 | +200, +150 |
| recorded window | −320, −90 | −320, −90 |
| recorded window | 0, 0 | 0, 0 (the epsilon) |
| panned region | border −182, +298 | camera −182, +298 |
| panned region | border +10, +7 | camera +10, +7 |
| panned region | border +554, −192 | camera +554, −192 |
| panned region | border −477, 0 | camera −477, 0 |

The region rows are the point of the shared tick: the camera's
displacement equals the *frame's* at every sample, because both are moved
in the turn that moved the capture. The dock itself lands where the maths
says — a camera whose home is (1596, 926) docking into a window at
(300, 300, 900, 628) goes to (996, 724), the top-right corner inside it
inset by `CameraWindowMargin`. And the stop restores it to (1596, 926)
exactly.

**The followers are positioned from the animator's INTENT, and that is
measured to be right — a plausible-sounding alternative was tried and
rejected.** The worry was a two-timeline problem: `UpdateSourceRect` is
fire-and-forget and coalescing, so the rectangle the animator intends
must run ahead of the rectangle the capture is reading from, and a camera
placed from the intent would then be displaced in the *file* by that
difference, every frame — a picture-in-picture visibly swimming around
its corner. The fix would be to move the followers on the rectangle whose
`updateConfiguration:` completion had landed, so window and content share
one clock.

It was built and measured, and it is wrong. Recording a region ride over
a flat backdrop makes the camera window's left edge the only structure in
the picture, so a threshold crossing tracks it to a fraction of a pixel:

| followers positioned from | camera edge deviation in the file |
| --- | --- |
| the animator's intent (shipped) | **max 1.4 px = 0.7 pt**, mean 0.11 px |
| the last *completed* update | **max 162 px = 81 pt**, 104 frames >8 px off |

`updateConfiguration:` takes effect when it is **issued**; its completion
handler is a later acknowledgement, not the moment the compositor
switches. So the window server's `setFrame:` and ScreenCaptureKit's
reconfiguration, both issued from the same tick, already land together —
and deliberately delaying the window by one completion *introduces* a
displacement of one tick's worth of pan, which at the start of a fast
pan is the better part of a hundred points. The instrument that caught
this also caught an earlier version of itself being wrong: an
"applied rectangle" poll that waited for nothing to be in flight fired
twice a second instead of thirty times, and reported a 626 pt lag that
did not exist. Logging ScreenCaptureKit's own sent/completed counters
alongside — they advance every tick, with zero refusals — is what showed
the framework was never the slow part.

What that investigation *did* find worth changing is in
`TCameraPreview.ApplyFrame`: it used to hand the preview layer a new
frame on every call, including the up-to-thirty-a-second calls that only
move the window. Re-setting an `AVCaptureVideoPreviewLayer`'s frame to
the value it already has is not a no-op — it is a geometry change that
recomputes how the video sits in its bounds, interleaved with frames
arriving from the capture session. A move now touches the window and
nothing else; the layer is handed a frame only on a real size change,
which is a shape switch and nothing else.

**Three owners, one frame, and they take turns.** A drag, the corner
snap that follows one, and the ride. `RideTo` refuses outright while
either of the other two has the window, and marks itself *stale*; the
next tick then re-anchors on wherever they left it. So a picture dragged
to the other corner mid-recording carries on riding **from there**
instead of being yanked back — and a shape change, which also moves the
window, is absorbed the same way. Zoom moves nothing: it crops inside
the same on-screen rectangle, so neither the frame nor the camera has
any business moving for it.

The move back is eased, and **where** it happens is load-bearing.
`UndockCamera` runs *after* `FSession.FinishCapture` returns, not before
it with `HideBorder`. Until `FinishCapture` returns the stream is still
running and the writer is still appending — measured on device: at the
point the undock used to sit, `Capturing` was still true and the file's
last frame landed 30 ms later, with frames arriving every 33 ms right up
to it. A 200 ms glide there would have put roughly six frames of the
camera sliding away into the tail of *every* docked take — the exact
artefact the unanimated dock exists to avoid, at the other end of the
recording. `FinishCapture` stops the stream before it finalises the
writer ("Stream first, then writer: an append must never race the
finish"), so after it returns there is nothing left for the movement to
land in. The border can go early because it is a static window being
removed; a window in *motion* cannot.

A camera that is **off** does nothing at all, on every path. While
docked, a drag snaps to the *docked rectangle's* corners rather than the
screen's, and the rectangle a drop snaps to follows the ride, so
dragging the picture during a pan lands it in a corner of where the
region is **now**.

**The position restored on stop is the pre-recording one, and it is
restored onto the screen that holds it.** `Undock` clamps `FUndocked`
against the visible frame of the screen that actually contains it
(`HomeFrame`, the same `IsCameraOriginUsable` test `RestoredOrigin`
applies to a position read out of `NSUserDefaults`) — not against the
screen the window happens to be on, which with the dock just cleared is
still the *recorded* one. Without that, a camera the user keeps on
display B and a region recorded on display A came back squeezed onto A —
and because `Hide` writes the restored position out, the next launch
kept it there. A recording had quietly rewritten the camera's home,
which is the one thing the `FUndocked`/`SaveOrigin` split exists to
prevent. Only when no attached screen holds it — the display was
unplugged mid-recording — does the current screen win.

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

Position, visibility and shape live in `NSUserDefaults`
(`KnipsCameraOriginX/Y`, `KnipsCameraVisible`, `KnipsCameraShape`). The
first two are written when the window is hidden or the app quits, the
shape the moment it changes — it is a setting, not a property of a window
that happens to be up. A restored origin is checked against every
attached screen's **`visibleFrame`** — `IsCameraOriginUsable` in
`Knips.App.State` — which takes the *shape's* size, since a circle is 60
points narrower than a rectangle and an origin that leaves a usable
sliver of one can leave nothing of the other — tested, so a position
saved on a display that has
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
common one — goes to `NSLog`, to `~/Library/Logs/Knips.log`, and to a
disabled `Last error: …` menu item, and the app returns to idle. It never
retries and never opens a dialog.

The log file is not belt-and-braces; `NSLog` alone reaches nobody here.
FPC hands `NSLog` a *dynamic* `NSString` as its format string, so the
call cannot take the compile-time `os_log` path, and the unified log
stores every one of these lines with its payload redacted — `log show`
prints `<private>`, literal format strings included (measured on device).
`NSLog`'s other half, a write to fd 2, does survive a redirect as well as
a terminal, but a bundle launched from Finder has fd 2 on `/dev/null`,
and the bundle is how the app is used. `LogMessage` therefore appends to
`~/Library/Logs/Knips.log` — the conventional place, listed by
Console.app — and keeps `NSLog` for the terminal. The file is started
over rather than rotated once it passes 1 MB.

Anything that switches a recording *setting* off for one recording takes
the same three outputs, and that is a change of policy rather than of
plumbing: those messages used to go to `NSLog` only. A user who turned
Follow Mouse on and got a recording that did not pan had no way at all to
find out why.

The camera's failures take the same three outputs but *not* the transition:
`HandleCameraError` records and refreshes, where `Fail` would also drive
`acCaptureFailed` and knock a live recording to idle over a preview layer.

### Dock and the main menu

Everything the app puts on the screen while it records — the status item,
the selection overlay, the recording frame, the camera preview — is either
menu-bar furniture or a borderless window, and none of it wants a Dock
tile. A recorder that owned the Dock and the menu bar while it recorded
would be recording itself. So the process is `Accessory`.

The playback window is the exception, and the reason is simply that it is
an ordinary titled document window: it has a titlebar, a close button and
a filename, and a user who has one on screen expects to find it in the
Dock, ⌘-Tab to it, and close it with ⌘W. `TAppController.ShowPlayback`
therefore switches the process to `NSApplicationActivationPolicyRegular`
around it, and `HandlePlaybackClosed` — reached from the window's
`OnClosed`, and so from *every* way the window can go: the Close button,
the titlebar, ⌘W, a second recording replacing it, Quit — switches it
back.

Three things about that are not obvious:

- **The order is policy, then activation, then the window.** Switching
  the policy changes what the process *is*; it does not put it in front,
  and a Dock tile whose menu bar only appears after the user clicks away
  and back is worse than no promotion. `EnterRegularPolicy` therefore
  installs the main menu, switches the policy, and calls
  `activateIgnoringOtherApps:` — and only then does `TPlaybackWindow.Show`
  run, with its own activation and `makeKeyAndOrderFront:`. The promotion
  also has to happen *before* `Show`, and the previous window has to be
  closed before *that*: closing it fires `OnClosed`, and a demotion
  landing after the promotion would leave the new window without its tile.
- **A `Regular` app needs a main menu**, or it shows an empty menu bar.
  `BuildMainMenu` makes the smallest one that is not a lie: an application
  menu with *About Knips* and *Quit Knips* ⌘Q, and a Window menu with
  *Close* ⌘W and *Minimize* ⌘M. Only Quit is targeted — at the same
  `quitKnips:` the status item's own Quit uses, so ⌘Q inherits the export
  lockout and the finalisation of an open recording rather than becoming a
  second, unguarded way out. The other three are untargeted and travel the
  responder chain, which is also what greys the Window items out when
  there is nothing to close. There is no Edit menu (nothing takes text)
  and no `setWindowsMenu:` (AppKit would keep a window list in it, and the
  app's other windows are an overlay, a frame and a camera preview). The
  menu is built once and left installed: nothing draws it under
  `Accessory`, and clearing it would mean handing AppKit nil from inside
  the `windowWillClose:` a ⌘W out of that very menu just dispatched. The
  price is that ⌘Q stays live between playback windows, so the "Quit is
  unreachable while recording" property below now holds only for the
  *status item*; ⌘Q is still the guarded path, and still finalises the
  file.
- **No new runtime-built class.** The menu items either target
  `KnipsAppTarget`, which already exists, or nothing at all.

Nothing else changes across the switch. Measured on device with the
playback window driven from an instrumented build:

| | before | window open | after close |
| --- | --- | --- | --- |
| `NSApp.activationPolicy` | 1 (accessory) | 0 (regular) | 1 (accessory) |
| `lsappinfo` ApplicationType | UIElement | Foreground | UIElement |
| `lsappinfo front` | — | knips | — |
| `NSApp.mainMenu` items | none | 2 | 2 (kept) |
| status item has a window | yes | yes | yes |
| status item title / menu | `◉` / attached | `◉` / attached | `◉` / attached |

**Three things the promotion must not break**, all three measured in the
same instrumented run:

- **⌘W during an export is refused, not survived.** `performClose:` was
  sent to the window 1.5 s into a 16.8 s export, from the run loop,
  exactly as the key equivalent does. `windowShouldClose:` answered NO,
  the window stayed up, and the export finished — a `.gif` byte-for-byte
  the same size as one produced with nothing interfering. Before
  `windowShouldClose:` existed this path was *permitted*: the window went,
  the export carried on writing through nil-checks, and the demotion
  fired from inside `windowWillClose:` with the export still holding the
  main thread. It worked, and it was one nil-guard away from not
  working. The veto makes the guard `CommandClose` already applies
  authoritative for the closes the user can ask for.
- **⌘Q during an export leaves the status menu detached.** `quitKnips:`
  fired at +3.0 s, `CommandQuit` refused with *"a GIF export is running;
  quit once it has finished"*, and the `RefreshStatusItem` that follows
  the refusal left the menu off — because `RefreshStatusItem` asks `Busy`
  before it re-attaches. It has to: `CommandExportGif` detaches the menu
  precisely so that a click on the status item dispatches nothing, since
  opening an `NSMenu` starts a tracking loop inside `sendEvent` that does
  not return until the menu is dismissed, and the export is draining
  events. Re-attaching mid-export would stall the export on the first
  click. The re-attach is `CommandExportGif`'s own, one line after the
  export returns.
- **A recording never captures the Dock tile.** Every *Record* command
  calls `ClosePlaybackForRecording` immediately after its transition is
  accepted and before anything else. `-close` posts `windowWillClose:`
  synchronously, so the window, the tile and the menu bar are all gone by
  the time the command returns — a full run-loop turn before
  `startPending:` builds the content filter. Measured: policy 0 and a
  visible window before `CommandRecordDisplay`, policy 1 and no window
  after it and before the deferred start. Without this, recording with a
  playback window open would put the app's own Dock tile and menu bar in
  the file, which is the exact thing the Accessory policy exists to
  prevent.

`knips probe` gates the two primitives in the shipped binary: it builds
the main menu, checks its shape (2 menus, 3 + 2 items), promotes, reads
the policy back, demotes, reads it back again, and puts the process back
to the policy it started with — which for a bare CLI binary is
`Prohibited`, not `Accessory`; a check has no business converting the
process it checks. It does *not* exercise the activation nudge — with no
run loop that would mean nothing except taking focus off the terminal.

That check is also the only thing in the probe that touches
`NSApplication`, and AppKit *kills* a process that reaches for it with no
window server rather than failing. Over SSH or under launchd the probe
therefore prints `Dock promotion: skipped (no window server)` and carries
on with the rest, and `knips app` refuses with a message and exit 2
instead of aborting. `CGSessionCopyCurrentDictionary` returning NULL is
the question being asked.
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
run and 2 560 in the worst single frame. Re-measured since, on the app's
own paths and counting *lines* rather than pixels — a border edge in the
file is a full-width or full-height red run four pixels deep at 2x, which
screen content never is: with the exclusion, 0 such lines in the first 30
frames of a heavily panning region recording (drag path and Record Last
Region both); with the exclusion off and Follow Mouse forced on anyway,
22 of the first 30 frames carry them. With the exclusion off and the pan
refused as it normally is, 0 again — a *still* frame never leaks, which
is rule 1 doing its job. That is why Follow Mouse is *refused* for a
recording whose border did not reach the content filter — the app says so
on the `Last error: …` line and records with a fixed region rather than a
frame that keeps sliding into shot.

**Getting the border into the content filter is therefore load-bearing,
and it is on a clock.** `SCShareableContent` hands back a snapshot, and
the frame is a window created milliseconds earlier: a window the window
server has not published yet is simply absent, an absent window cannot
become the `SCWindow` that `initWithDisplay:excludingWindows:` needs, and
the user loses Follow Mouse for the recording without being told. Two
things close that. `StartPending` puts the frame up **before** the
display-resolution query rather than after it, so a whole
ScreenCaptureKit round trip — 40 to 60 ms, measured — passes before the
snapshot that has to contain it is taken. And that query,
`ResolvePendingTarget`, answers both questions at once and retries up to
`BorderVisibilityAttempts` (three) times while the frame is missing, so a
first snapshot taken too early is re-asked rather than believed. The
retry costs nothing in the ordinary case: on this machine the frame is in
the first snapshot every time, 43 to 64 ms after `orderFrontRegardless`.

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
the Audio ▸ Microphone checkbox is the surface that needs it.
The bare CLI binary has no `Info.plist` and inherits the grant of the
app responsible for it, which is the terminal it was launched from.

## Big Cursor

An enlarged pointer, drawn *into* the frames rather than captured with
them: `SCStreamConfiguration.showsCursor` goes off for the recording and
a sprite is composited into each frame's own pixels before
`AVAssetWriterInput.appendSampleBuffer:` sees it. Baking it into the
movie is the point — the GIF, APNG and passthrough-trim exports all read
the finished file, so they inherit it for nothing.

`Knips.Recording.CursorMath` is the whole of the arithmetic and has no
framework in it (tested, like `Knips.Recording.LiveMath`).
`Knips.Recording.CursorOverlay` is the Darwin half: `Prepare` on the main
thread before the capture starts, `DrawInto` on the capture queue.

**The mapping.** A frame is `PixelWidth × PixelHeight` showing the
rectangle ScreenCaptureKit is currently reading, in the recorded
display's own top-left points. A pointer at display point *(x, y)* is at
frame pixel *((x − SourceX) / SourceWidth × PixelWidth)*, and likewise
for y. One expression covers the region's offset, the Retina scale, and
a live zoom, because all three are only ever ratios of the source
rectangle to the output. The rectangle is fed from
`TScreenStream.LastSentRect` — what SCK was *told* to read — and not from
what the animator asked for, because an update inside the epsilon or one
dropped behind another in flight never reached the framework.

**Two threads.** `Prepare` asks AppKit for `NSCursor.arrowCursor`, picks
the largest bitmap representation (macOS ships the arrow at 28×40 points
with representations up to 280×400 pixels, so any sprite this program
asks for is a *downsample* of real pixels), and draws it into a
`CGBitmapContext` over a `GetMem` block — raw memory rather than a
dynamic array, so nothing the capture queue touches is a managed type.
`DrawInto` makes no Objective-C call at all: the pointer position comes
from `CGEventCreate(nil)` + `CGEventGetLocation`, which is plain C,
thread-safe, and needs no privacy grant (it reads the pointer; it taps
nothing and injects nothing). The only shared mutable state is the source
rectangle, and it sits under a `TPThreadMutex` like every other
cross-thread value in this program.

**Decisions, with what they rest on.**

| Decision | Why |
| --- | --- |
| `arrowCursor`, not `currentSystemCursor` | Both bind in FPC 3.2.2 and both answer on device (checked). The sprite is rendered *once*, so whatever shape is under the pointer when the recording starts is frozen for the whole file — and `knips record --big-cursor` from a terminal would freeze an I-beam over a five-minute screencast. Following the live shape needs a main-thread re-render on shape change, which is separate work |
| Fixed size in output pixels | The sprite does not grow with a live zoom. Scaling it per frame means resampling on the capture queue, and a Big Cursor is an artificial pointer to begin with, so one that keeps its size while the content zooms reads as deliberate |
| In place, not copied | Measured. The alternative is a full-frame memcpy plus a pool allocation per frame — about 20 MB at 2880×1800, 600 MB/s at 30 fps. The specific risk is stale sprites, since SCK recycles surfaces and recomposites only what changed; see the table below |
| Display targets only | A window's frames have no fixed relationship to the screen the pointer is measured against, and the window moves under us with no way to find out from the capture queue. `ResolveBigCursor` refuses it, `ValidateRecordingOptions` rejects the flag combination, and the app resolves before it asks so a ticked checkbox never fails a recording |

**What was measured**, on an M-series Mac, macOS 26, 1512×982 points at
two pixels per point. The pointer was never moved by tooling — this
project does not inject input — so it was read where it sat and the
*sprite* was made to move by panning the live `sourceRect` instead.

| | measured |
| --- | --- |
| sprite | 140×200 px, hot spot 25,25; the arrow's opaque box inside it 53×92 at (19, 17) — 2.52× and 2.49× the system pointer's own 21×37, which is the 2.5 magnification |
| whole-display recording, pointer at global (946.59, 201.28) | predicted arrow box (1887, 395)–(1939, 486); found white body (1889, 396)–(1939, 485) — the two-pixel inset is the black outline, which is not white |
| the same recording with Big Cursor off | 90 white pixels in the *system* pointer's own predicted 21×37 box at (1891, 400), found (1891, 400)–(1909, 432) |
| live pan, four plateaus 130 points apart | the sprite at each plateau's predicted pixel, within 2 px, and **nothing at the previous plateau's** |
| the pathological ghost case: the sourceRect flipped between two positions 780 px apart every tick, 54 frames | every frame carried the arrow at exactly one of the two positions (≈700–850 white px there, ≈35–110 at the other, which is background and H.264 ringing). No ghosting |
| cost per frame | 2.05 µs for the pointer read, 300 µs for a 140×200 blit — 0.9 % of a 30 fps frame's budget, dev build, unoptimised |
| frame counts under an identical drive, 8 s | 107 frames with the sprite, 108 and 107 without; 0 dropped, 0 failed appends, 0 refused blits in every run |

The ghost row is the one that settles the in-place decision. If SCK ever
does start handing back a surface it has not recomposited, the symptom is
a trail of pointers standing still in the video, and the fix is to
composite into a copy.

**The toggle** is one menu item next to Zoom on Click and Follow Mouse,
with its own defaults key (`KnipsBigCursor`), its own reader and its own
writer — the rule from "Each toggle writes its own key" below. It is
idle-only, like the other two, for the plainest version of the same
reason: the drawn pointer replaces ScreenCaptureKit's own, which is part
of the configuration the capture started with, and the sprite is rendered
before the first frame arrives.

A sprite that cannot be made is never a reason to fail a recording. The
geometry's `ShowsCursor` is put back before the stream configuration is
built, so the file gets the ordinary system pointer, and the report
carries `BigCursorError` for the CLI to print and the app to show in the
menu. `knips probe` renders the sprite once and prints its size, so a
future macOS that stops answering `+arrowCursor` is a line before a
recording rather than a recording with no pointer in it.

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

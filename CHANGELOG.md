# Changelog

All notable changes to this project are documented here. Hand-maintained:
entries are written for someone deciding whether they want the change,
not transcribed from commit subjects. (`cliff.toml` is kept for the
release-tagging step; it does not produce the entries below.)

## [Unreleased]

### Features

- **Recordings of a still screen are no longer nearly empty.**
  ScreenCaptureKit delivers a frame only when the content changes, so a
  take whose screen went quiet used to stop producing frames — and,
  because the movie's timeline is built from the frames' own stamps, the
  movie stopped with it. A 30-second recording of a still screen came out
  as one frame spanning 0.000 seconds; a real 17.5-second take came out as
  4.3 seconds with three of its four clicks past the end of the file.
  Suppressing the pointer for a raw take made it the common case rather
  than an oddity, because moving the mouse then stopped counting as a
  change.

  knips now repeats the last frame twice a second while nothing is
  changing, and once more at the stop, so a take's movie is as long as the
  recording was: the same still screen, recorded by both builds at the same
  moment, gives 58 frames over 29.6 seconds instead of one frame over
  none. Everything downstream inherits it — clicks land inside the movie's
  span so `render --effects=zoom` has frames to zoom, a take killed with
  `SIGKILL` recovers 10.5 seconds where it used to recover 2.0, and a movie
  with sound no longer has an 11-second audio track over a single video
  frame. Takes whose content keeps changing are untouched: the repeat never
  fires while frames are arriving, and a busy recording measured 0 dropped
  and 0 failed appends either way. Costs about 1.7 ms of CPU and 2.6 kB a
  second while idle. A frame that arrives just behind a heartbeat's stamp
  is retimed one tick forward rather than handed to the writer out of
  order (which would end the recording) — the summary's "N frames
  retimed" is that rescue counted. See
  [docs/architecture.md](docs/architecture.md), "The idle heartbeat".
- **The effects animate instead of jumping.** ScreenCaptureKit only
  delivers a frame when the screen changes, and a raw take has no pointer
  in its pixels — so moving the mouse over a still window produced no
  frames at all, and a zoom easing in over 0.30 s could land on a single
  one. Measured on a real 8.1-second take: 152 frames, 18.8 a second
  against a nominal 30, and **one** frame inside the ease. The render now
  fills those gaps in, re-presenting the last captured frame with the
  effect evaluated at the intervening instant — but only where the result
  would be a different picture, so a zoom's hold and a still stretch with
  nothing moving over it cost nothing. Same take, same binary: one frame
  in the ease became **seven**, for 20 % more bytes and 0.35× realtime
  instead of 0.28×. GIF and APNG exports get the same treatment on their
  own frame grid, and one gap can never cost more than a bounded number
  of frames however damaged the movie's stamps are.

  Every figure above was measured against a recorder that stopped
  producing frames when the screen went still. That recorder-side change
  — the idle heartbeat, the entry above — has since landed, and it moves
  both limits this entry used to carry. The tail a static take used to
  lose is no longer lost, so the fill has a frame on both sides of every
  gap it is asked about; and because the capture now keeps a half-second
  cadence of its own, most of the gaps these numbers came from do not
  arise in the first place. What is left for the fill is the sub-second
  work it is actually good at: measured on a still take on the merged
  build, a zoom that had one real frame to land on now animates over
  several, and the fill is invoked only inside the effect windows.
- **A sparse pointer track is no longer drawn through.** Two samples
  minutes apart — which is what an MCP recording produces between tool
  calls — used to be joined with a straight line, so the drawn pointer
  glided smoothly across the screen for a minute of footage nobody
  watched, and the render filled that minute with frames to draw it on.
  The reader now holds the last known position across a silence longer
  than half a second and snaps when the track speaks again. On a
  three-sample fixture the render went from 81 invented frames to 1.
- **Zoom on Click works on a Follow Mouse take.** It used to be refused,
  because the crop was computed against the rectangle the recording was
  *sized* from rather than the one it was *showing*. It is now composed
  inside the framing each sample records — the same base/window/source
  composition the live effects always used — so a click zooms inside
  wherever the pan had got to. Proved at pixel level against a predicted
  crop of the raw frame: SSIM 0.9965, against 0.8636 for the old
  arithmetic. A click the pan has drifted away from is answered as
  closely as the captured rectangle allows rather than refused. Where the
  sample track runs out — a movie can outlast its own sidecar — the
  frames past its end are passed through uncropped rather than zoomed
  against a rectangle the capture had already left, and the render says
  how many.
- **Window recordings take the effects too.** A desktop-independent
  window capture is a picture of something that moves under the recorder
  with no way to find out, so nothing could ever be drawn back into one —
  which is why *Record Window* produced a single movie with the system
  pointer baked in and every effect greyed out. A window recording is now
  captured from the display through a rectangle riding the window, which
  makes it a raw take like any other: Smooth Cursor, Big Cursor and Zoom
  on Click all apply and can still be changed afterwards. The price is
  that anything in front of the window is in the file, so it is paid only
  where it buys something — with the camera off, the pointer switched off
  and no zoom asked for, a window recording still captures the window
  alone.
- **The camera's background blur is stronger.** `CIGaussianBlur` at
  radius 28 instead of 12 — 2.33× the kernel, taking out two fifths of
  the mid-scale structure the old value left behind (measured on a real
  640×480 frame at three spatial scales). It costs nothing measurable:
  three probe runs at each radius on an idle machine came back 9.1–9.8 ms
  a frame at 28 against 7.6–9.8 ms at 12, ranges that overlap almost
  entirely, with Vision ~78 % of each. Both are far under the 33 ms
  budget.
- **Event sidecar.** Every recording writes `<take>.knips.jsonl` beside
  its movie: the pointer's path at about thirty samples a second, mouse
  button edges, the rectangle the capture was reading at each instant, and
  what was baked into the pixels. Times are on ScreenCaptureKit's own host
  clock and anchored to the movie's first frame, so an event's place on the
  movie's timeline is a subtraction rather than an estimate — measured over
  a 61 s take, the sidecar's prediction matched the recorded pointer's
  pixel position within 1 px on 109 of 120 frames, with a best-fit time lag
  of zero. The format is public and documented in
  [docs/event-sidecar.md](docs/event-sidecar.md).
- **Smooth Cursor.** `record --smooth-cursor` (and a menu item beside Big
  Cursor) leaves the pointer out of the movie entirely and draws it back
  into GIF and APNG exports from the sidecar's track, interpolated to each
  output frame and smoothed over a centred window. `export --cursor=` picks
  the pointer for any take that has room for one: `as-recorded`, `none`,
  `smooth`, or `big`. Mutually exclusive with Big Cursor, and refused for a
  passthrough trim, which re-encodes nothing.
- **Export size estimates.** `export` says what the animation is likely to
  weigh before it writes a byte — from the source movie's own bytes per
  pixel-frame, which is H.264's verdict on how busy the content is — and
  then replaces the estimate with a projection from what the encoder has
  actually produced. The playback window shows both in its title.

  The estimate is reported as a range, and the range is honest about what
  it is rather than about what would sound good: calibrated on sixteen
  exports over seven takes at four output widths, the worst residual is
  2.2x, the band shown is 3x, and content unlike anything in that set can
  still land outside it. Measured too, and stated because it is the sort
  of thing a model like this is usually assumed to need: downscaling does
  **not** need its own term — across a fourfold reduction the ratio moves
  by at most 31 % while content moves it fourfold. The in-flight
  projection is the number that is actually accurate, and it was inside
  5 % of the final size on busy takes (30 % on ones that went quiet
  half way through).
- **Never lose a take.** The writer now flushes a movie fragment every two
  seconds, so a process killed mid-recording leaves a playable movie
  instead of a zero-byte stub (measured: 117 frames of a six-second take
  survived a `kill -9`). The next `knips record`, and the menu-bar app at
  launch, find the unfinished take, re-mux it into an ordinary movie and
  close its sidecar off — a check that costs about ten milliseconds over
  a directory of fifty finished takes, because it reads each sidecar's
  last four kilobytes rather than parsing it. A normally finished take is
  unchanged apart from where its `moov` atom sits: it is `ftyp/mdat/moov`
  with no fragments, since `finishWriting` consolidates them.
- **Audio assurance.** The writer measures each PCM buffer's peak on the
  capture queue, so a track that was enabled and arrived as pure silence is
  now said out loud — on the *Stop Recording* menu item while the recording
  runs, and afterwards in the log, the menu and the playback window's
  title. "Nothing arrived" and "everything arrived and was silence" are
  told apart, because they send the user to different places.
- Headless `record` to `.mp4`/`.mov` from a display, region, or window via
  ScreenCaptureKit and AVAssetWriter.
- `app`: the Kap gesture as a menu-bar app — click the icon, drag a
  region, click again to stop; recordings land in `~/Movies/knips/`.
  `tools/make-app.sh` wraps the binary in `Knips.app`.
- `app`: a red frame marks the region for as long as it records. It is a
  passthrough window, stroked outside the recorded rectangle *and*
  excluded from the capture through
  `SCContentFilter initWithDisplay:excludingWindows:`, so it never
  reaches the file.
- `app`: a finished recording opens in a playback window (AVKit) with
  *Export as GIF…*, *Reveal in Finder*, and *Close*. The export writes
  `<recording>.gif` beside the movie at 20 fps and at the recording's
  own point size — its pixel width divided by the scale it was captured
  at — reporting progress in the window title. On the 2x display that is
  nearly every Mac that makes the export an exact 2:1 integer reduction,
  which is the sharpest a downscale gets; the previous 800 px cap landed
  on a fractional ratio and visibly softened text. A Retina recording
  has no cap — its point size is already half its pixels — while a
  scale-1 recording keeps an 800 px cap, and an oversized result is
  called out on the app's own "Last error" line, since a bundle has no
  stderr.
- `app`: the playback window puts Knips **in the Dock and in ⌘-Tab** for
  as long as it is open, with a menu bar of its own — *About Knips*,
  *Quit Knips* ⌘Q, and a Window menu with *Close* ⌘W and *Minimize* ⌘M.
  Closing the window, by any route, drops the process back to being
  menu-bar-only. The rest of the app stays an Accessory process: a
  recorder has no business owning the Dock while it records. ⌘Q is the
  same guarded quit the menu offers — it finalises an open recording and
  refuses during a GIF export — and the status item is unaffected by the
  switch. Starting a recording closes the playback window first, so the
  Dock tile and the menu bar are never in the frame. `knips probe` now
  gates the promotion and the menu's shape, and skips that one check
  (rather than dying) where there is no window server; `knips app` refuses
  there with a message instead of aborting.

### Fixes

- **A sidecar with no `sampleHz` field read as a sample rate of
  1.5×10⁻³²². The reader's fallback went through `TJSONFloat(30)`, and a
  typecast of an integer constant to a float type in Delphi mode
  reinterprets the bits rather than converting them — so the documented
  default of 30 arrived as the denormal `$000000000000001E`. Nothing
  noticed for as long as nothing divided by it; the first thing that did
  crashed. Every other fallback in the reader casts a literal `0`, whose
  bit pattern is `0.0` either way, which is why this was the only one
  that was wrong.
- **A drawn pointer could be placed against the wrong rectangle on the
  frames of a take whose movie outlasts its sidecar** — reachable after a
  crash-recovered recording, because samples are flushed about a second
  behind and recovery re-muxes the movie without trimming it. Those
  frames now fall back to the last rectangle the track actually holds
  (measured: the pointer had been landing 207 pixels away), and the
  render says how many frames it could not place instead of reporting a
  clean success.

- `app`: a close asked for by the user — the titlebar's button or ⌘W —
  is now refused while a GIF export is running (`windowShouldClose:`),
  rather than taking the window down and leaving the export to write
  through nil-checks. The *Close* button and every internal path were
  already refused.
- `app`: ⌘Q during an export no longer re-attaches the status item's
  menu. `CommandExportGif` detaches it so that a click cannot open menu
  tracking inside the export's event drain, and every refresh during an
  export now leaves it detached.
- `app`: a stop click during an export no longer queues a deferred
  `FinishRecording` that re-enters the run loop from under the export.
  `CommandStop` reads the transition's answer before scheduling anything.
- `app`: *Record Window* submenu (on-screen application windows, refreshed
  at most once every five seconds and never listing Knips's own windows),
  *Record Last Region*, and a *Record System Audio* checkbox. The checkbox
  and the last region are remembered between launches in `NSUserDefaults`;
  the stored region is range-checked on the way back in.
- `app`: **Zoom on Click** and **Follow Mouse**, two remembered menu
  checkboxes that change what a recording *shows* while it runs. A click
  inside the recorded area zooms the recording to 2× around the click,
  holds 0.8 s after the last click and eases back; Follow Mouse pans a
  region recording so the pointer stays inside the middle third, and the
  red frame moves with it. Neither changes the file's dimensions —
  `AVAssetWriter` fixes those at the first frame. Both animate the
  stream's `sourceRect` through
  `SCStream.updateConfiguration:completionHandler:` instead, so a smaller
  rectangle is a zoom and a sliding one is a pan. They compose: zoom crops
  inside wherever the pan has got to. Zoom works for a region or a whole
  display, Follow for a region only (a display has nowhere to pan), and
  window recordings get neither — a window's `sourceRect` is in a space
  that moves and resizes under us. Both are off by default and remembered
  in `NSUserDefaults` under `KnipsZoomOnClick` and `KnipsFollowMouse`;
  like Record System Audio they are idle-only. Clicks are found by polling
  `NSEvent.pressedMouseButtons` at the animator's 30 Hz tick rather than
  by an event monitor, so no permission beyond Screen Recording is
  involved. Measured on device: a 2× zoom magnifies content by exactly
  2.000× with the file still 1024×768 and no dropped frames, a 200-point
  pan moves the picture by exactly 400 px, and the moving frame stays out
  of the file — 0 border pixels in every frame with the exclusion in
  place against 665 792 without it. Clicks on the menu bar are ignored,
  so the click that stops a full-screen recording does not zoom into the
  corner on the way out. If ScreenCaptureKit refuses five rectangle
  changes in a row the effects switch off for the rest of that recording
  and say so on the `Last error:` line rather than retrying twenty times
  a second in silence — reproduced on device with an out-of-range
  rectangle (`-3812`, `SCStreamErrorInvalidParameter`). CLI unchanged.
- `record`: `TRecordingOptions.ExcludedWindowIDs` keeps named windows out
  of a display capture.
- `record --audio=system`: system audio through ScreenCaptureKit into an
  AAC track of the same file (48 kHz stereo, 128 kbit/s).
- `record --audio=mic` and `--audio=both`: the default microphone via
  ScreenCaptureKit's native microphone output (macOS 15), on a second
  AAC track. `both` writes system audio and microphone as two separate
  tracks — players pick the first one; there is no in-process mixing in
  this version. Per-source sample counters in the `record` summary.
- `app`: a **Camera** item puts a small, round-cornered, floating camera
  window on screen. Drag it anywhere — inside the region you are
  recording, and ScreenCaptureKit captures it like any other window. Its
  position and its on/off state survive a relaunch, and it stays up
  across recordings. Needs the Camera grant; `tools/make-app.sh` now
  writes `NSCameraUsageDescription` into the bundle.
- `app`: the camera preview is **mirrored**, the way every camera
  preview is — raise your left hand and the picture's left hand goes up.
  Since Knips records the window as it appears, the file is mirrored
  too, which is what Kap does and what a viewer expects.
- `app`: releasing a drag **snaps the camera window to the nearest
  corner** of the screen it was dropped on, inset by the same margin as
  its first placement, over a short eased glide. A plain click is not a
  drag and never moves the window. The window carries the drag itself now
  (`mouseDown:`/`mouseDragged:`/`mouseUp:` on `KnipsCameraView`) instead
  of `movableByWindowBackground`, because the snap needs a drag end that
  is unambiguously the user letting go, and the glide is a timer this
  unit owns rather than `setFrame:display:animate:` — an AppKit animated
  setFrame runs a nested run loop, and a re-grab, a shape change or a
  Hide landing inside one all misbehave.
- `app`: a **Circular Camera** checkbox turns the camera window into a
  disc — a square window with a half-side corner radius, cropping the
  middle of the feed. It applies to the live window about its own
  centre, and is remembered under `KnipsCameraShape`.
- `app`: starting a **region** recording with the camera up **docks** it
  into the nearest corner inside the region, so the picture-in-picture
  ends up composited into the file the way Kap does it — still with no
  compositing code, just a window moved to the right place. Stopping
  puts it back where it was. Display and window recordings are
  unaffected, and with *Follow Mouse* on it docks once at the start
  rather than chasing the panning region.
- `export` from `.mp4`/`.mov` to an animated GIF: median-cut palette,
  Floyd–Steinberg dithering and LZW in pure Pascal, with `--fps`,
  `--width`, and `--trim=start,end`.
- `export`: the scaler's fractional step is Catmull-Rom bicubic rather
  than bilinear, and an integer box reduction that already lands on the
  target width now stops there instead of resampling its own output.
  Two taps an axis is a triangle filter and blurs small text; four taps
  with clamped negative lobes keeps the edge. Both GIF and APNG go
  through it. Measured on a real 1800×1000 region recording at 800×444,
  +2.9 dB against a Lanczos reference and 19% more edge contrast.
- `export --out=x.apng`: animated PNG in pure Pascal — 8-bit truecolour
  (no quantisation), changed-rectangle subframes with
  `dispose_op=NONE`/`blend_op=SOURCE`, PNG line filters, and the RTL's
  own paszlib for compression.
- `export --in=a.mp4 --out=b.mp4 --trim=s,e`: passthrough trim through
  `AVAssetExportSession` — the same coded samples in a new container, no
  decode and no re-encode. Movie-to-movie only, and `--trim` is required.
- `export` warns on stderr (exit code still 0) when the result is large:
  a canvas at or past 1280×720, or a file past 20 MB, naming whichever of
  `--width`, `--fps` or `--trim` would actually help.
- `mcp`: the recorder as a Model Context Protocol server on stdin/stdout,
  over [pascal-mcp-sdk](https://github.com/frostney/pascal-mcp-sdk).
  Eight tools — `list_displays`, `list_windows`, `record_start` /
  `record_stop` / `record_status`, `export_gif`, `export_apng`,
  `export_trim` — each running the CLI's own session classes with JSON
  arguments in place of flags, refused by the same `Knips.Options`
  validation (with the flag names rewritten to the argument names the
  tool schemas actually declare). Recording is non-blocking: the server
  answers `record_status` and everything else while ScreenCaptureKit
  captures on its own queue, and one recording at a time is enforced
  with an in-band error naming the file already being written. The SDK's
  stdio transport is a single-threaded read-handle-write loop, so no
  `cthreads` and no new thread; its HTTP transport, which would need
  both, is not used. Screen Recording permission is inherited from the
  MCP client's host application — see
  [docs/quick-start.md](docs/quick-start.md#the-mcp-server).
  Two contracts are deliberately stricter than the CLI's, because the
  caller is a program: `record_start` refuses an existing `out` unless
  `overwrite: true` is passed (agents guess paths; `knips record`
  replaces what you typed), and `export_trim` refuses `fps`/`width`/
  `dither` rather than ignoring what a passthrough copy cannot honour.
  Paths are returned absolute, every tool declares an `outputSchema`,
  and a writer that dies mid-recording is reported by `record_status`,
  which stops the session and says whether the partial file was
  finalised.

### Improvements

- GIF palettes are built from an **exact-colour** histogram (a bounded
  hash table of packed 24-bit colours, with the old 6-bit histogram kept
  as the fallback past 2^20 distinct colours), median cut now splits the
  box holding the most squared error, and nearest-colour lookups are
  exact and memoised on the colour itself rather than answered per 6-bit
  cell. On a 14 s 800×520 screen recording the dithered GIF went from
  14.4 MB / 38.17 dB to 1.79 MB / 41.48 dB at unchanged encoding time —
  8.1× smaller and 3.3 dB closer, against 1.30 MB / 42.50 dB for
  ffmpeg's `palettegen`.
- Frame delays are snapped to the decimation grid before being rounded,
  so a 30 fps source exported at 20 fps gets a steady `5,5,5,…` instead
  of `7,3,7,3,…`, while the total playback length stays on the source's
  own (`Knips.Export.Timing`, tested). An idle gap longer than a two-byte
  delay field can express is emitted at the ceiling with the remainder
  forgiven rather than owed, so the frames *after* a very long pause keep
  their true delays instead of being held at the maximum one by one.
- `displays`, `windows`, and `probe` subcommands.
- Runtime-built Objective-C classes (`Knips.ObjC.Runtime`) keeping the
  default build linker-flag-free.

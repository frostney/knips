# Changelog

All notable changes to this project are documented here. Generated from
conventional commits by git-cliff (`cliff.toml`).

## [Unreleased]

### Features

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

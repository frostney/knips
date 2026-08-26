# Changelog

All notable changes to this project are documented here. Generated from
conventional commits by git-cliff (`cliff.toml`).

## [Unreleased]

### Features

- Headless `record` to `.mp4`/`.mov` from a display, region, or window via
  ScreenCaptureKit and AVAssetWriter.
- `app`: the Kap gesture as a menu-bar app — click the icon, drag a
  region, click again to stop; recordings land in `~/Movies/knips/` and
  are revealed in Finder. `tools/make-app.sh` wraps the binary in
  `Knips.app`.
- `record --audio=system`: system audio through ScreenCaptureKit into an
  AAC track of the same file (48 kHz stereo, 128 kbit/s).
- `export` from `.mp4`/`.mov` to an animated GIF: median-cut palette,
  Floyd–Steinberg dithering and LZW in pure Pascal, with `--fps`,
  `--width`, and `--trim=start,end`.
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

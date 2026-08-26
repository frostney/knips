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
  `<recording>.gif` beside the movie at 20 fps and at most 800 px wide,
  reporting progress in the window title.
- `app`: *Record Window* submenu (on-screen application windows, refreshed
  at most once every five seconds and never listing Knips's own windows),
  *Record Last Region*, and a *Record System Audio* checkbox. The checkbox
  and the last region are remembered between launches in `NSUserDefaults`;
  the stored region is range-checked on the way back in.
- `record`: `TRecordingOptions.ExcludedWindowIDs` keeps named windows out
  of a display capture.
- `record --audio=system`: system audio through ScreenCaptureKit into an
  AAC track of the same file (48 kHz stereo, 128 kbit/s).
- `export` from `.mp4`/`.mov` to an animated GIF: median-cut palette,
  Floyd–Steinberg dithering and LZW in pure Pascal, with `--fps`,
  `--width`, and `--trim=start,end`.
- `displays`, `windows`, and `probe` subcommands.
- Runtime-built Objective-C classes (`Knips.ObjC.Runtime`) keeping the
  default build linker-flag-free.

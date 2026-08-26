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
<<<<<<< HEAD
- `record --audio=mic` and `--audio=both`: the default microphone via
  ScreenCaptureKit's native microphone output (macOS 15), on a second
  AAC track. `both` writes system audio and microphone as two separate
  tracks — players pick the first one; there is no in-process mixing in
  this version. Per-source sample counters in the `record` summary.
=======
- `app`: a **Camera** item puts a small, round-cornered, floating camera
  window on screen. Drag it anywhere — inside the region you are
  recording, and ScreenCaptureKit captures it like any other window. Its
  position and its on/off state survive a relaunch, and it stays up
  across recordings. Needs the Camera grant; `tools/make-app.sh` now
  writes `NSCameraUsageDescription` into the bundle.
>>>>>>> lane2/camera
- `export` from `.mp4`/`.mov` to an animated GIF: median-cut palette,
  Floyd–Steinberg dithering and LZW in pure Pascal, with `--fps`,
  `--width`, and `--trim=start,end`.
- `displays`, `windows`, and `probe` subcommands.
- Runtime-built Objective-C classes (`Knips.ObjC.Runtime`) keeping the
  default build linker-flag-free.

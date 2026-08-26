# Changelog

All notable changes to this project are documented here. Generated from
conventional commits by git-cliff (`cliff.toml`).

## [Unreleased]

### Features

- Headless `record` to `.mp4`/`.mov` from a display, region, or window via
  ScreenCaptureKit and AVAssetWriter.
- `app`: the Kap gesture as a menu-bar app — click the icon, drag a
  region, click again to stop; recordings land in `~/Movies/opname/` and
  are revealed in Finder. `tools/make-app.sh` wraps the binary in
  `Opname.app`.
- `record --audio=system`: system audio through ScreenCaptureKit into an
  AAC track of the same file (48 kHz stereo, 128 kbit/s).
- `export` from `.mp4`/`.mov` to an animated GIF: median-cut palette,
  Floyd–Steinberg dithering and LZW in pure Pascal, with `--fps`,
  `--width`, and `--trim=start,end`.
- `displays`, `windows`, and `probe` subcommands.
- Runtime-built Objective-C classes (`Opname.ObjC.Runtime`) keeping the
  default build linker-flag-free.

# ADR-0006: Linux writes GIF and APNG; X11 libraries are loaded at run time

## Status

Accepted on 25 October 2026 by Johannes Stein.

Supersedes only the "Encoding on Linux" paragraph of
[ADR-0005](0005-windows-linux-ports.md) and the consequence that follows from
it (the one that says choosing our own encoders costs `.mp4` output). The rest
of ADR-0005 stands, including one recording session type per platform.

## Context

Linux has no operating-system video encoder. The repository already has two
platform-neutral, tested animated-image encoders, `Knips.Export.Gif` and
`Knips.Export.Apng`, and an APNG written by `Knips.Export.Apng` is lossless
truecolour. H.264 on Linux would mean writing an encoder, a container and a
decoder, or loading a library the user may not have. libx264 is GPL and is
excluded. The H.264 licence position of an encoder Knips ships has not been
assessed.

FPC's own `xlib` and `xshm` units bind libX11 at link time, and `xshm` carries a
`{$LinkLib Xext}` ([docs/ports.md](../ports.md), "Capture: XSHM first"). A
`knips` binary linked that way would not start on a machine without those
libraries, including a headless one that only runs `knips mcp`.

## Decision

1. **Linux output is GIF and APNG.** Knips on Linux does not produce, read or
   trim MP4 or MOV. `record --out=x.mp4` and `--out=x.mov` refuse with a
   message that names `.gif` and `.apng`. No H.264 encoder, MP4 muxer or
   decoder is part of the Linux backend. libx264 stays excluded. Whether
   shipping an H.264 encoder of our own is licence-clean is not assessed here.
2. **Audio is not recorded on Linux**, because an animated image has no audio
   track. `--audio` refuses with a message.
3. **X11 client libraries are loaded with `dlopen`**, never linked at build
   time. The Linux backend declares its own entry points for the libraries it
   uses instead of using FPC's link-time `xlib`/`xshm` bindings. The default
   `knips` build entry stays flag-free, and a machine without X11 still starts
   `knips` and serves `knips mcp`, with capture reporting why it is unavailable.
4. **Platform-neutral geometry is reused.** The Linux session works in
   `TLiveRect` (`source/Knips.Recording.LiveMath.pas`) and `TCaptureRegion`
   (`source/Knips.Options.pas`), both in neutral units with no `{$IFDEF DARWIN}`.
   The macOS session and its `CGRect` signatures in `source/Knips.Recording.pas`
   are not changed by this decision.

## Consequences

- A Linux user gets an animated image, not a video. That is a smaller product
  than macOS by design, and the CLI help says so.
- Hand-written `dlopen` bindings for libX11 and libXext are ours to maintain.
  Once they exist, the Linux gate checks them against a live X server (Xvfb).
  Until then the gate runs only the spike in `source/capture-linux/`, which is
  built on FPC's `xshm` unit.
- No claim in this repository calls audio, the system tray, Wayland capture or
  camera background blur "dependency-free": none of them can be done without a
  system library or a model, and each is decided in its own change.
- Linux export, render and trim work on the files Knips itself writes; they
  are specified in their own changes.
- The Linux playback window and settings window are drawn directly on X11 and
  are specified in their own changes.

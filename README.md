# Knips

Native macOS screen recorder in FreePascal — *Knips*, from the German
*knipsen*, to snap a picture: the shutter sound, borrowed for a tool that
catches what is on your screen. Pick a display, a region, or a window;
get an `.mp4` or `.mov` back, an animated GIF, or a truecolour APNG —
or trim the movie itself without re-encoding a frame. Capture is
ScreenCaptureKit, the file is written by AVAssetWriter with hardware
H.264, the GIF and APNG encoders are pure Pascal, and the whole thing is one
dependency-light binary built with
[lwpt](https://github.com/frostney/lwpt). It grows out of the
[lantaarn](https://github.com/frostney/lantaarn) capture core toward what
[Kap](https://github.com/wulkano/Kap) was: see [VISION.md](VISION.md).

## Install

```sh
lwpt install && lwpt build    # produces build/knips
```

## Usage

```sh
./build/knips app                                     # menu bar: drag a region, click to stop
./build/knips probe                                   # verify the toolchain path once
./build/knips displays                                # what can be recorded
./build/knips record --out=demo.mp4                   # main display, 30 fps, Ctrl-C to stop
./build/knips record --out=demo.mp4 --rect=100,80,1280,720 --fps=60
./build/knips record --out=app.mov --window=<id>      # id from `knips windows`
./build/knips export --in=demo.mp4 --out=demo.gif     # animated GIF, 20 fps
./build/knips export --in=demo.mp4 --out=demo.gif --width=800 --trim=1.5,4
./build/knips export --in=demo.mp4 --out=demo.apng    # truecolour APNG, no palette
./build/knips export --in=demo.mp4 --out=cut.mp4 --trim=1.5,3.5   # passthrough trim
```

`tools/make-app.sh` wraps the built binary in a menu-bar-only
`build/Knips.app` ([docs/deployment.md](docs/deployment.md)).

macOS prompts once for **Screen Recording**. Flags, exit codes, and the
verification loop are in [docs/quick-start.md](docs/quick-start.md).

## Background

The default build carries no linker flags. ScreenCaptureKit needs an
Objective-C object to deliver frames to, and an FPC-declared `objcclass`
makes the current Apple linker demand `-ld_classic`; Knips builds that
object through the Objective-C runtime API instead
([ADR-0002](docs/adr/0002-runtime-built-objc-classes.md)). Encoding and
muxing are AVAssetWriter's job
([ADR-0001](docs/adr/0001-avassetwriter-owns-encoding.md)); the capture
bindings are vendored from lantaarn
([ADR-0003](docs/adr/0003-vendor-capture-units.md),
[porting notes](docs/porting-notes.md)).

## Contribution

`lwpt install && lwpt build && lwpt test` — see
[docs/quick-start.md](docs/quick-start.md) and [AGENTS.md](AGENTS.md).

## References

- [Agent instructions](AGENTS.md)
- Private candidate project — not open-source licensed.

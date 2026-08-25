# opname

Native macOS screen recorder in FreePascal — *opname*, Dutch for
recording. Pick a display, a region, or a window; get an `.mp4` or `.mov`
back. Capture is ScreenCaptureKit, the file is written by AVAssetWriter
with hardware H.264, and the whole thing is one dependency-light binary
built with [lwpt](https://github.com/frostney/lwpt). It grows out of the
[lantaarn](https://github.com/frostney/lantaarn) capture core toward what
[Kap](https://github.com/wulkano/Kap) was: see [VISION.md](VISION.md).

## Install

```sh
lwpt install && lwpt build    # produces build/opname
```

## Usage

```sh
./build/opname probe                                   # verify the toolchain path once
./build/opname displays                                # what can be recorded
./build/opname record --out=demo.mp4                   # main display, 30 fps, Ctrl-C to stop
./build/opname record --out=demo.mp4 --rect=100,80,1280,720 --fps=60
./build/opname record --out=app.mov --window=<id>      # id from `opname windows`
```

macOS prompts once for **Screen Recording**. Flags, exit codes, and the
verification loop are in [docs/quick-start.md](docs/quick-start.md).

## Background

The default build carries no linker flags. ScreenCaptureKit needs an
Objective-C object to deliver frames to, and an FPC-declared `objcclass`
makes the current Apple linker demand `-ld_classic`; opname builds that
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

# ADR-0005: Windows and Linux as parallel backends, not an abstraction

## Status

Accepted for the foundation stage. The Linux half is **proven in CI**
(FPC 3.2.2 in Debian bookworm: nine neutral suites green, `lwpt build`
produces a working Linux `knips`, on both arm64 and x86_64); the Windows
half is **proven to compile and link** for `x86_64-win64` and nothing
more. Every backend claim below is a design commitment awaiting a device
— see [docs/ports.md](../ports.md), "What this Mac can prove".

## Context

[VISION.md](../../VISION.md) already stated the shape a Windows path
would take — "a parallel implementation behind the same `Knips.Options`,
not an abstraction layered on top of macOS" — but the release scoped it
out. The question is now live, and three things have changed since that
sentence was written:

- [ADR-0004](0004-neutral-core-testable-off-device.md) grew far beyond
  option parsing. `Knips.App.State`, `Knips.Recording.LiveMath`,
  `Knips.Mcp.Params`, `Knips.Export.Bitmap`, `Knips.Export.Gif`,
  `Knips.Export.Apng` and `Knips.Export.Timing` contain no `{$IFDEF
  DARWIN}` at all. That is the app's state machine, its selection and
  camera-placement maths, its MCP argument mapping and two complete
  animated-image encoders — already portable, already tested.
- `source/knips.pas` has carried a non-Darwin branch since the first
  release: off macOS it registers the same subcommands, validates the
  same options through the same neutral code, serves the same MCP server,
  and refuses capture in-band with exit 3. The program is a shell that
  already builds elsewhere; what is missing underneath it is a backend.
- The Darwin units are not a layer that could be generalised. They are
  ScreenCaptureKit and AVFoundation, expressed as runtime-built
  Objective-C classes ([ADR-0002](0002-runtime-built-objc-classes.md)).
  Nothing about `SCContentFilter`, `CMSampleBufferRef` or
  `AVAssetWriterInput` survives translation to `IDXGIOutputDuplication`
  or a PipeWire buffer.

The tempting alternative — an `ICaptureBackend` interface with a Darwin,
a Windows and a Linux implementor — would have to be shaped like
whichever platform was written first, and macOS was. Every later platform
would then pay for a vocabulary it does not have: SCK hands over
already-composited frames with the cursor drawn in and system audio
attached; DXGI Desktop Duplication hands over a whole monitor with the
cursor *separate*, and no audio at all; PipeWire hands over a negotiated
stream whose format the compositor chooses.

## Decision

**One recording session type per platform, selected at compile time,
sharing the neutral core and the CLI/MCP surface — not a runtime
abstraction.**

Concretely:

1. `TRecordingSession` stays the boundary. It keeps its current public
   shape — `Create(TRecordingOptions)`, `StartCapture`, `FinishCapture`,
   `Run`, `LiveStatistics`, `UpdateSourceRect`, `SupportsLiveUpdate`,
   `Capturing`, `Report` — because `knips.pas` and `Knips.Mcp` are both
   written against exactly that and must stay one implementation.
   `Knips.Recording.pas` becomes a thin unit whose `{$IFDEF}` picks
   `Knips.Recording.Darwin`, `Knips.Recording.Windows` or
   `Knips.Recording.Linux`; each is written in its own idiom, and no
   two share a base class.
2. `TRecordingReport` and `TStreamGeometry` gain no platform fields.
   Where a platform cannot answer a counter it reports zero, exactly as a
   macOS recording without live effects reports zero live updates today.
3. Anything a new backend is tempted to compute — rectangle clamping,
   scale selection, frame-delay planning, which effects a target
   supports — goes into the neutral units under a co-located `*.Test.pas`
   instead, and is therefore written once. That is ADR-0004's rule,
   applied as the *forcing function* for the ports rather than as a
   nicety.
4. Capture bindings live in per-platform directories beside the vendored
   `source/capture/`: `source/capture-windows/`, `source/capture-linux/`.
   (Of those two, only `source/capture-linux/` exists today, holding the
   X11 spike; the Windows one is named here as the intended shape, not as
   something that has been created.) The macOS ones stay where and as
   they are — [ADR-0003](0003-vendor-capture-units.md)'s vendoring bargain
   with lantaarn is unaffected.

**Windows: DXGI Desktop Duplication first, Media Foundation for the
file.** Desktop Duplication is plain COM vtables (`IDXGIOutput1::DuplicateOutput`
since Windows 8) — the shape Pascal has consumed for thirty years, with
existing Pascal DXGI header translations to check against. Windows.Graphics.Capture
is the better API on paper (per-window capture, no secure-desktop cliff)
and the worse one to reach: it is WinRT, so FPC — which has no WinRT
projection — would have to hand-roll `RoInitialize` /
`RoGetActivationFactory` / `WindowsCreateString` against `combase.dll`,
QueryInterface an undocumented-in-Pascal `IGraphicsCaptureItemInterop`
(Windows 10 1903+) to turn an `HWND`/`HMONITOR` into a capture item, and
build a D3D11 device to hand `Direct3D11CaptureFramePool.Create`, all
before the first frame. It also draws a yellow border that is
unsuppressable on Windows 10 and, on Windows 11, needs a packaged app
manifest capability plus user consent to turn off. WGC is therefore
milestone 2 of the Windows port, justified by window capture, not
milestone 1.

**Linux: X11/XSHM first because it can be proven here, portal + PipeWire
because it is the only future.** XSHM (`XShmCreateImage`/`XShmAttach`/
`XShmGetImage`, libXext) runs headless against Xvfb in the same container
this lane already built, so a Linux capture path can be developed and
regression-tested with no Linux machine. It is also a dead end: under
XWayland an X11 grab sees only XWayland's own surfaces, so it cannot
record a Wayland desktop. The real target is
`org.freedesktop.portal.ScreenCast` (`CreateSession` → `SelectSources` →
`Start` → `OpenPipeWireRemote`) feeding `libpipewire-0.3`, `dlopen`ed at
runtime so the binary still starts on a machine without it. Both are
backends under the same session type; the portal one needs a real desktop
session to verify and is gated accordingly.

**Encoding on Linux is our own, until it is not.** There is no OS
encoder. `Knips.Export.Apng` and `Knips.Export.Gif` already exist, are
neutral, and are tested — so the first Linux recording writes an APNG or
GIF straight to disk, and `knips record --out=x.mp4` says what it cannot
do rather than pretending. H.264 arrives later through a `dlopen`ed
VA-API or LGPL `libavcodec`, never a link-time dependency. **libx264 is
excluded**: it is GPL, and linking it into Knips would make Knips GPL.

**Threading: "no cthreads" is a Darwin rule and stays one.** It exists
because ScreenCaptureKit delivers on a GCD queue the RTL never adopts.
Linux uses `cthreads` like any normal FPC program; Windows uses the RTL's
native thread manager. `Knips.ThreadManager` and the `cmem`-first
uses-clause stay inside the existing `{$IFDEF DARWIN}` in `knips.pas`.

**Toolchain: one build entry, three targets.** `lwpt build` builds every
entry in `[build]`, on every platform, so a `knips-windows` entry would
fail the macOS build and a `knips-linux` entry would fail on Windows —
the same trap `docs/tooling.md` already documents for the `-ld_classic`
variant. The single `knips` entry stays, stays flag-free, and stays
`{$IFDEF}`-selected. `[package] units` grows the two new capture
directories; unit directories cost nothing on a platform that never
`uses` what is in them. Cross-target compilation happens in containers
via `fpc @lwpt.cfg` — the one direct-compiler form AGENTS.md sanctions —
so `lwpt.cfg` and `lwpt.lock` are still never hand-edited.

## Consequences

- Three capture backends means three code paths to keep alive, and no
  compiler will tell you when they drift apart in *behaviour*. The
  defence is that everything decidable is neutral and tested; the report
  record is the contract, and a backend that cannot fill a field fills it
  with zero.
- The Linux container is now a real gate, not a claim
  (`tools/linux-ci.sh`). The neutral core's portability stopped being an
  argument from `{$IFDEF}` counting the day it ran green on two
  architectures.
- The Windows gate is compile-and-link only (`tools/win64-cross.sh`), and
  will stay that way until someone runs it on Windows. Nothing about the
  Windows backend may be described as working before then; the
  needs-device list in `docs/ports.md` is the honest ledger, in the same
  spirit as `docs/spikes/0001`.
- Choosing Desktop Duplication costs per-window capture on Windows for
  the first milestone — Kap's *Record Window* has no Windows equivalent
  until WGC lands. That is a visible product gap, taken deliberately in
  exchange for a capture path FPC can actually reach.
- Choosing our own encoders on Linux costs `.mp4` output. A Linux user
  gets an animated image, which is the format Kap was known for anyway,
  and a small one — the GIF encoder is the same median-cut/LZW code macOS
  exports through.
- The GNOME tray problem is inherited, not solved: StatusNotifierItem is
  a KDE-driven draft that GNOME Shell only honours with a third-party
  extension. The Linux app shell therefore cannot promise a menu-bar icon
  everywhere, and the CLI has to remain a first-class way to use Knips on
  Linux.

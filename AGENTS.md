# Agent Instructions

## Hard Constraints

- **FreePascal only.** FPC 3.2.2, Delphi mode, flags centralised in
  `source/Knips.inc` (`{$I Knips.inc}` per unit). No second compiled
  language, no Swift/ObjC shims. Per-unit modeswitches (`objectivec2`,
  `cblocks`, `cvar`) are the sanctioned addition for Darwin units — see
  [docs/code-style.md](docs/code-style.md).
- **lwpt is the only toolchain entry point** — install, build, test, format
  all go through it. Do not invoke `fpc` directly except as `fpc @lwpt.cfg`.
- **`lwpt.cfg` and `lwpt.lock` are generated** by `lwpt install`; never
  hand-edit them. `lwpt.toml` is the manifest you edit.
- **The default `knips` build entry stays linker-flag-free.** Never add
  `flags` to it. Objective-C classes are built through the runtime API
  (`Knips.ObjC.Runtime`), never declared with `objcclass` except as
  `external` bindings ([ADR-0002](docs/adr/0002-runtime-built-objc-classes.md)).
  The `-k-ld_classic` variant is a separate, documented entry if it is ever
  needed ([docs/tooling.md](docs/tooling.md)).
- **No `cthreads`.** The capture queue is a GCD thread the RTL never
  adopts. On that thread (`TScreenStream.OnSample` and everything it
  calls): no exceptions, no `try..finally`, no `WriteLn`, no managed-type
  writes outside a `TPThreadMutex`. `cmem` stays the first unit of the
  program, `Knips.ThreadManager` (pthread-backed RTL locks/events, no
  thread creation) comes second, and `IsMultiThread` is set at startup
  ([docs/architecture.md](docs/architecture.md)).
- **`source/capture/**` is vendored** from lantaarn and excluded from
  `lwpt format`. Additions go in the marked blocks; do not restyle the
  carried code. Substantive changes are recorded in
  [docs/porting-notes.md](docs/porting-notes.md).
- **Verify platform/framework facts against current sources, not memory.**
  Framework bindings are checked against FPC 3.2.2's `univint`/`cocoaint`
  and Apple's headers before being declared; anything unverified on real
  hardware is listed in [docs/spikes/0001-runtime-objc-class.md](docs/spikes/0001-runtime-objc-class.md)
  until `knips probe` and a real recording clear it.
- **Edit `AGENTS.md` only** — `CLAUDE.md` is a symlink to it. Same for
  `.agents/skills/` (canonical) vs `.claude/skills` (symlink).

## Runtime / Commands

lwpt ≥ 0.7.0 is expected on PATH (or a locally built binary; see
[docs/quick-start.md](docs/quick-start.md)).

```bash
lwpt install          # resolve cli + testing from the lwpt release tag
lwpt build            # build/knips (dev mode)
lwpt test             # co-located unit suites (*.Test.pas) — run on any OS
lwpt format --check   # formatter gate (no flag = rewrite in place)

./build/knips probe                     # toolchain verification (macOS)
./build/knips record --out=demo.mp4     # record; Ctrl-C stops
./build/knips app                       # menu-bar app; drag a region, click to stop
tools/make-app.sh                        # wrap the built binary in build/Knips.app
```

## Code Organization

| Path | Role |
| --- | --- |
| `source/knips.pas` | Program: CLI surface (`app`, `record`, `export`, `displays`, `windows`, `probe`), signals |
| `source/Knips.Options.pas` | Platform-neutral recording + export option models, validation, large-export advice (tested) |
| `source/Knips.App.State.pas` | Platform-neutral app state machine, titles, paths, selection maths (tested) |
| `source/Knips.App.pas` | Menu-bar app: status item, menu, runtime-built `KnipsAppTarget` |
| `source/Knips.App.Overlay.pas` | Region selection overlay; runtime-built `KnipsOverlayView`/`KnipsOverlayWindow` |
| `source/Knips.App.Camera.pas` | Camera picture-in-picture window: AVCaptureSession + preview layer in a floating, draggable NSWindow |
| `source/Knips.Options.pas` | Platform-neutral recording + export option models and validation (tested) |
| `source/Knips.App.State.pas` | Platform-neutral app state machine, titles, paths, selection maths, window-menu filter, export arithmetic (tested) |
| `source/Knips.App.pas` | Menu-bar app: status item, menu, preferences, runtime-built `KnipsAppTarget` |
| `source/Knips.App.Overlay.pas` | Region selection overlay; runtime-built `KnipsOverlayView`/`KnipsOverlayWindow` |
| `source/Knips.App.Border.pas` | The frame around a recorded region; runtime-built `KnipsBorderView` |
| `source/Knips.App.Playback.pas` | Playback + GIF export window (AVKit); runtime-built `KnipsPlaybackDelegate` |
| `source/Knips.ObjC.TypeEncoding.pas` | Method type encodings for runtime classes (tested) |
| `source/Knips.ObjC.Runtime.pas` | Runtime-built ObjC classes (the ADR-0002 primitive) |
| `source/Knips.Capture.ShareableContent.pas` | Display/window enumeration via SCShareableContent |
| `source/Knips.Capture.Stream.pas` | SCStream wrapper; runtime-built SCStreamOutput; frame-status filter |
| `source/Knips.Export.MovieWriter.pas` | AVAssetWriter bindings + the movie sink |
| `source/Knips.Export.MovieReader.pas` | AVAssetReader bindings; BGRA frames + presentation stamps, with a trim range |
| `source/Knips.Export.Bitmap.pas` | Platform-neutral BGRA buffer + box/bilinear resampling (tested) |
| `source/Knips.Export.Gif.pas` | Platform-neutral GIF89a: exact-colour histogram, median cut, dithering, LZW (tested) |
| `source/Knips.Export.Apng.pas` | Platform-neutral APNG: acTL/fcTL/fdAT, PNG filters, paszlib, truecolour (tested) |
| `source/Knips.Export.Timing.pas` | Platform-neutral frame-delay planning: grid-snapped, drift-free (tested) |
| `source/Knips.Export.MovieTrim.pas` | AVAssetExportSession passthrough trim (no decode, no re-encode) |
| `source/Knips.Export.Pipeline.pas` | Orchestrator: reader → decimate → scale → GIF or APNG sink |
| `source/Knips.Recording.pas` | Orchestrator: target → geometry → writer → stream → finish |
| `source/capture/` | Vendored bindings: CoreMedia/CoreVideo/VideoToolbox/GCD, ScreenCaptureKit, pthread mutex |
| `docs/` | Architecture, quick-start, tooling, code style, deployment, porting notes, spikes, ADRs |

Layering: `knips.pas` → {`Knips.App`, `Knips.Recording`,
`Knips.Export.Pipeline`, `Knips.Export.MovieTrim`} → {`Knips.Capture.*`,
`Knips.Export.GifPipeline`} (`Knips.App.Playback` also reaches
`Knips.Export.GifPipeline`, so the *Export as GIF…* button runs the same
session `knips export` does) → {`Knips.Capture.*`,
`Knips.Export.MovieWriter`, `Knips.Export.MovieReader`,
`Knips.Export.Gif`, `Knips.Export.Apng`, `Knips.Export.Timing`} →
{`Knips.ObjC.*`, `Knips.Export.Bitmap`, `source/capture/*`}.
`Knips.Options` is used by every layer and depends on nothing;
`Knips.App.State` depends only on it. The GIF encoder, the APNG encoder
and the delay planner are deliberately below the Darwin line: they have
no `{$IFDEF DARWIN}` at all and are tested on every host.

## Testing

- `lwpt test` discovers `source/*.Test.pas`. Everything platform-neutral
  has a co-located suite and runs on Linux CI as well as macOS.
- Darwin units cannot be unit-tested off-device. Their gate is
  `knips probe` (runtime class registration, SCK enumeration,
  AVAssetWriter open) followed by a real `record` that plays back in
  QuickTime Player. Both are hard gates before handoff of any capture change.
- Off-device, the Darwin units are type-checked with a cross compiler
  (`docs/tooling.md`); that catches declaration errors, not behaviour.

## Safety / Boundaries

- Never commit generated state: `build/`, `.lwpt/tmp/`, `.lwpt/sessions/`,
  `.lwpt/session-roots`, `.lwpt/install.lock`.
- `record` writes to the path given and replaces an existing file without
  asking; `probe` writes and deletes `$TMPDIR/knips-probe.mp4`.
- macOS permissions (Screen Recording, and Camera for the menu-bar app's
  camera window) are per-binary; a fresh build re-prompts. A bundle that
  uses the camera must carry `NSCameraUsageDescription` or macOS kills
  the process — `tools/make-app.sh` writes it. Test tooling never injects
  input — this is a recorder, not lantaarn.

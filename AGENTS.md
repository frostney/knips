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
- **No `cthreads` on Darwin** (a Darwin-only rule: Linux uses `cthreads`
  and Windows the native RTL thread manager — see
  [ADR-0005](docs/adr/0005-windows-linux-ports.md)). The capture queue is
  a GCD thread the RTL never
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
lwpt build --mode release   # -O4; gate: release probe must pass too (DoD)
lwpt test             # co-located unit suites (*.Test.pas) — run on any OS
lwpt format --check   # formatter gate (no flag = rewrite in place)

./build/knips probe                     # toolchain verification (macOS)
./build/knips record --out=demo.mp4     # record; Ctrl-C stops
./build/knips record --out=demo.mp4 --big-cursor   # draw an enlarged pointer
./build/knips render --in=demo-raw.mp4 --effects=zoom,smooth-cursor
                                        # raw take -> deliverable; audio copied
./build/knips app                       # menu-bar app; drag a region, click to stop
./build/knips mcp                       # MCP server on stdin/stdout; EOF stops
tools/make-app.sh                        # wrap the built binary in build/Knips.app
```

## Code Organization

| Path | Role |
| --- | --- |
| `source/knips.pas` | Program: CLI surface (`app`, `record`, `render`, `export`, `displays`, `windows`, `mcp`, `probe`), signals |
| `source/Knips.ThreadManager.pas` | Pthread-backed RTL locks/events for the no-cthreads build; no thread creation |
| `source/Knips.Options.pas` | Platform-neutral recording + export option models, validation, large-export advice (tested) |
| `source/Knips.App.State.pas` | Platform-neutral app state machine, titles, paths, selection maths, window-menu filter, export and render arithmetic, audio-source composition and migration, the saved effect defaults and their one-way migration, camera placement — nearest corner, shape sizes, region flip, ride offsets (tested) |
| `source/Knips.App.pas` | Menu-bar app: status item, menu, preferences, runtime-built `KnipsAppTarget` |
| `source/Knips.App.Overlay.pas` | Region selection overlay; runtime-built `KnipsOverlayView`/`KnipsOverlayWindow` |
| `source/Knips.App.Camera.pas` | Camera picture-in-picture window: mirrored AVCaptureSession + preview layer in a floating NSWindow that drags itself, snaps to the nearest corner, switches between rectangle and circle, and docks into — and rides along with — the recorded rectangle |
| `source/Knips.App.Camera.Blur.pas` | Portrait-style background blur for that window: an AVCaptureVideoDataOutput on the same session, Vision person segmentation and a CoreImage composite on a serial GCD queue, into the window's own layer; runtime-built `KnipsCameraOutput` |
| `source/Knips.App.Live.pas` | Follow Mouse: a main-thread animator on the app's 30 Hz timer that moves the stream's `sourceRect`, the recording border and a docked camera. Zoom on Click was the other half and is now a render-time effect |
| `source/Knips.App.Hotkey.pas` | The global ⌘⇧2 stop hotkey: Carbon `RegisterEventHotKey` + an application-target event handler, no TCC grant |
| `source/Knips.Recording.LiveMath.pas` | Platform-neutral live-effect arithmetic: rect clamping, dead zone, smoothstep easing, which effects a target can have (tested) |
| `source/Knips.Recording.Heartbeat.pas` | Platform-neutral idle-heartbeat arithmetic: whether the movie has fallen behind the host clock and what stamp the repeated frame carries (tested) |
| `source/Knips.Recording.Sidecar.pas` | The event sidecar: the public JSON Lines format for a take's pointer track, clicks, geometry and what was baked into its pixels, and the rule that a silence too long to believe is held rather than interpolated across (tested; [docs/event-sidecar.md](docs/event-sidecar.md)) |
| `source/Knips.Recording.Recovery.pas` | Finishes off a take whose process died: an unfinished sidecar plus a dead pid, then a passthrough re-mux |
| `source/Knips.Export.CursorEffect.pas` | The pointer drawn back into a rendered MP4, a GIF or an APNG from the sidecar's smoothed track |
| `source/Knips.Export.ZoomTrack.pas` | Platform-neutral post-recording Zoom on Click: the live effect's own easing replayed from the sidecar's click track, composed inside the framing each sample records, and the frame crop it comes to (tested) |
| `source/Knips.Export.Cadence.pas` | Platform-neutral frame synthesis: where a render may put a frame the capture never made, whether that frame would be a different picture from the one before it, and how much one gap may ever cost (tested) |
| `source/Knips.Export.Render.pas` | The render pass: raw take + sidecar → deliverable MP4. Video re-encoded through an `AVAssetWriterInputPixelBufferAdaptor`, audio copied sample-for-sample, every source frame's presentation stamp passed through unchanged, extra frames interleaved where an effect is animating |
| `source/Knips.Export.SizeEstimate.pas` | Pre-export size estimate from the source movie's own density, and the in-flight projection (tested) |
| `source/Knips.Recording.CursorMath.pas` | Platform-neutral Big Cursor arithmetic: screen point → frame pixel under a live sourceRect, clipped sprite placement, the premultiplied BGRA blit, sprite metrics (tested) |
| `source/Knips.Recording.CursorOverlay.pas` | Big Cursor: the arrow sprite rendered once on the main thread, composited into each frame's own pixels on the capture queue |
| `source/Knips.App.Border.pas` | The frame around a recorded region; runtime-built `KnipsBorderView` |
| `source/Knips.App.Playback.pas` | Playback window (AVKit): the Effects pull-down, Re-export, GIF export; runtime-built `KnipsPlaybackDelegate` |
| `source/Knips.ObjC.TypeEncoding.pas` | Method type encodings for runtime classes (tested) |
| `source/Knips.ObjC.Runtime.pas` | Runtime-built ObjC classes (the ADR-0002 primitive) |
| `source/Knips.Capture.ShareableContent.pas` | Display/window enumeration via SCShareableContent |
| `source/Knips.Capture.Stream.pas` | SCStream wrapper; runtime-built SCStreamOutput; frame-status filter; live `sourceRect` updates |
| `source/Knips.Export.MovieWriter.pas` | AVAssetWriter bindings + the movie sink; holds the last delivered frame so the idle heartbeat can repeat it under the same mutex the capture queues append through |
| `source/Knips.Export.MovieReader.pas` | AVAssetReader bindings; BGRA frames + presentation stamps, with a trim range |
| `source/Knips.Export.Bitmap.pas` | Platform-neutral BGRA buffer + box/bilinear resampling (tested) |
| `source/Knips.Export.Gif.pas` | Platform-neutral GIF89a: exact-colour histogram (64-bit counters, no sampling budget), median cut, dithering, LZW, and the self-thinning palette sample schedule the pipeline drives (tested) |
| `source/Knips.Export.Apng.pas` | Platform-neutral APNG: acTL/fcTL/fdAT, PNG filters, paszlib, truecolour (tested) |
| `source/Knips.Export.Timing.pas` | Platform-neutral frame-delay planning: grid-snapped, drift-free (tested) |
| `source/Knips.Export.MovieTrim.pas` | AVAssetExportSession passthrough trim (no decode, no re-encode) |
| `source/Knips.Export.Pipeline.pas` | Orchestrator: reader → decimate → crop → scale → GIF or APNG sink |
| `source/Knips.Recording.pas` | Orchestrator: target → geometry → writer → stream → finish |
| `source/Knips.Mcp.Params.pas` | Platform-neutral MCP tool table, JSON argument mapping, default paths, flag→argument message rewriting (tested) |
| `source/Knips.Mcp.pas` | `knips mcp`: the tool handlers on pascal-mcp-sdk's stdio transport; one recording at a time |
| `source/capture/` | Vendored bindings: CoreMedia/CoreVideo/VideoToolbox/GCD, ScreenCaptureKit, pthread mutex |
| `source/capture-linux/` | X11/MIT-SHM capture **spike** and its runner — not shipped, not an lwpt build entry; run against Xvfb by `tools/linux-ci.sh` ([docs/ports.md](docs/ports.md)) |
| `tools/linux-ci.sh`, `tools/win64-cross.sh`, `tools/wine-smoke.sh` | Cross-platform gates in Docker: the neutral suites on Linux, an `x86_64-win64` compile-and-link, a Wine smoke ([docs/ports.md](docs/ports.md)) |
| `docs/` | Architecture, quick-start, tooling, code style, deployment, ports, porting notes, spikes, ADRs |

Layering: `knips.pas` → {`Knips.App`, `Knips.Mcp`, `Knips.Recording`,
`Knips.Export.Pipeline`, `Knips.Export.MovieTrim`} (`Knips.Mcp` reaches
the same session classes the CLI does, so an MCP tool and a subcommand
are one implementation; `Knips.App.Playback` likewise reaches
`Knips.Export.Pipeline`, so the *Export as GIF…* button runs the same
session `knips export` does) →
{`Knips.Capture.*`, `Knips.Export.MovieWriter`,
`Knips.Export.MovieReader`, `Knips.Export.Gif`, `Knips.Export.Apng`,
`Knips.Export.Timing`} →
{`Knips.ObjC.*`, `Knips.Export.Bitmap`, `source/capture/*`}.
`Knips.Export.Render` sits beside `Knips.Export.Pipeline` and consumes
`Knips.Export.MovieReader`, `Knips.Export.MovieWriter`'s bindings,
`Knips.Export.CursorEffect` and `Knips.Export.ZoomTrack`; both
`Knips.App` (the render on every stop) and `Knips.App.Playback` (the
Re-export button) reach it, the same way `Knips.App.Playback` already
reaches `Knips.Export.Pipeline`. `Knips.Export.ZoomTrack` is neutral and
sits with `Knips.Recording.LiveMath`, whose arithmetic it replays, plus
`Knips.Recording.Sidecar`, whose click track and framing track it reads.
`Knips.Export.Cadence` is neutral and depends on nothing at all; both
`Knips.Export.Render` and `Knips.Export.Pipeline` consume it, so an MP4
and a GIF fill the same gaps the same way.
`Knips.App.Hotkey` sits beside the other `Knips.App.*` units and depends
only on `Knips.App.State` and MacOSAll. `Knips.Recording.CursorOverlay`
sits beside `Knips.Recording` and consumes `Knips.Recording.CursorMath`
the way `Knips.App.Live` consumes `Knips.Recording.LiveMath`.
`Knips.Capture.Stream` reaches down to `Knips.Recording.LiveMath` too,
for one thing only: the source-rect epsilon and the rectangle comparison
that decides whether a live update is worth an `updateConfiguration:`
round trip. That number used to exist twice — a documented, tested
constant nothing production read, and a private copy doing the work —
and one of them had to be the source of truth.
`Knips.Recording.Heartbeat` sits beside them and depends on nothing at
all; `Knips.Recording` reads the clock and asks it whether the movie has
fallen behind, and `Knips.Export.MovieWriter` carries the answer out
under the mutex its capture-queue appends already take.
`Knips.Options` is used by every layer and depends on nothing;
`Knips.App.State`, `Knips.Recording.LiveMath` and
`Knips.Recording.CursorMath` depend only on it;
`Knips.Mcp.Params` sits beside them (on it plus fpjson and
`Knips.App.State`, whose path helpers it reuses). `Knips.App.Live`
consumes `Knips.Recording.LiveMath`, the way `Knips.App.Playback`
consumes `Knips.Export.Pipeline`. The GIF encoder, the APNG encoder, the delay
planner, the MCP argument mapping, the live-effect maths, the post-hoc
zoom track and the big-cursor maths are deliberately below the Darwin
line: they have
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
  asking; `render` replaces its output the same way; `probe` writes and
  deletes `$TMPDIR/knips-probe.mp4`. The menu-bar app writes **two**
  movies per take — `<name>-raw.mp4` (the raw take) and `<name>.mp4` (the
  rendered deliverable) — plus a sidecar for each, and never deletes
  either: the raw take is what makes the effects changeable afterwards.
  A window recording is written once only when it takes no effect at all
  — no camera, no pointer, no zoom — because that is the only case where
  ScreenCaptureKit's desktop-independent capture is kept; otherwise it is
  composited from the display and split like any region take
  (`WindowTakeNeedsCompositing`).
  `render` builds into `<out>.knips-render-tmp` and renames it into place,
  so a killed render cannot damage an existing deliverable; the recovery
  pass sweeps any temporary a killed render left behind. The
  menu-bar app appends its diagnostics to `~/Library/Logs/Knips.log`,
  capped at 1 MB and started over rather than rotated — `NSLog` alone is
  unreadable from a bundle (see [docs/architecture.md](docs/architecture.md),
  "Errors").
- macOS permissions (Screen Recording, and Camera for the menu-bar app's
  camera window) are per-binary; a fresh build re-prompts. A bundle that
  uses the camera must carry `NSCameraUsageDescription` or macOS kills
  the process — `tools/make-app.sh` writes it. Test tooling never injects
  input — this is a recorder, not lantaarn.

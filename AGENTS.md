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

lwpt on PATH (or a locally built binary; see
[docs/quick-start.md](docs/quick-start.md)). **0.6.0 is what this repo is
developed against and it runs every gate**, `lwpt agents` included. The
`^0.7.0` in `lwpt.toml` is a different number and means a different
thing: it is the release TAG the `cli` and `testing` packages are
fetched from, not a requirement on the binary doing the fetching.

Everything below the `<!-- lwpt:agents:begin -->` marker at the end of
this file is **generated** by `lwpt agents` — the toolchain's own
command and manifest reference, refreshed rather than edited.
`lwpt agents --check` fails when it is stale, and the pre-push hook runs
that check.

```bash
lwpt install          # resolve cli + testing from the lwpt release tag
lwpt build            # build/knips (dev mode)
lwpt build --mode release   # -O4; gate: release probe must pass too (DoD)
lwpt test             # co-located unit suites (*.Test.pas) — run on any OS
lwpt format --check   # formatter gate (no flag = rewrite in place)

./build/knips probe                     # toolchain verification (macOS)
./build/knips probe --blur-cost         # ...and measure the camera background blur
./build/knips record --out=demo.mp4     # record; Ctrl-C stops
./build/knips record --out=demo.mp4 --big-cursor   # draw an enlarged pointer
./build/knips render --in=demo-raw.mp4 --effects=zoom,smooth-cursor
                                        # raw take -> deliverable; audio copied
./build/knips app                       # menu-bar app; drag a region, click to stop
./build/knips mcp                       # MCP server on stdin/stdout; EOF stops
tools/make-app.sh                        # wrap the built binary in build/Knips.app
tools/release-gate.sh                    # the Definition of Done's six gates, in order
                                         # (leaves build/knips a RELEASE binary)
lefthook install                         # once per clone: pre-commit + pre-push hooks
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
| `source/Knips.Recording.Recovery.pas` | Finishes off a take whose process died: an unfinished sidecar plus a dead pid, then a passthrough re-mux; also the pid-gated sweep of the scratch a killed render left (tested) |
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
| `source/Knips.Export.Atomic.pas` | The temporary-plus-rename every writer commits through, the owner marker the crash sweep reads, and the one symlink policy `record`, `render`, `export`, the trim and the crash recovery's re-mux share |
| `source/Knips.Export.Bitmap.pas` | Platform-neutral BGRA buffer + box/bilinear resampling, and the canvas budget every export is sized against (tested) |
| `source/Knips.Export.Gif.pas` | Platform-neutral GIF89a: exact-colour histogram (64-bit counters, every pixel of every sampled frame counted — the schedule below is what bounds the work, not a per-frame budget), median cut, dithering, LZW, and the self-thinning palette sample schedule the pipeline drives (tested) |
| `source/Knips.Export.Apng.pas` | Platform-neutral APNG: acTL/fcTL/fdAT, PNG filters, paszlib, truecolour (tested) |
| `source/Knips.Export.Timing.pas` | Platform-neutral frame-delay planning: grid-snapped, drift-free (tested) |
| `source/Knips.Export.MovieTrim.pas` | AVAssetExportSession passthrough trim (no decode, no re-encode) |
| `source/Knips.Export.Pipeline.pas` | Orchestrator: reader → decimate → crop → scale → GIF or APNG sink |
| `source/Knips.Recording.pas` | Orchestrator: target → geometry → writer → stream → finish |
| `source/Knips.Mcp.Params.pas` | Platform-neutral MCP tool table, the tools' output schemas, JSON argument mapping (recording, export effects, default paths), the take-info answer, flag→argument message rewriting (tested) |
| `source/Knips.Mcp.pas` | `knips mcp`: the tool handlers on pascal-mcp-sdk's stdio transport; one recording at a time; raw takes, `render`, `take_info` |
| `source/capture/` | Vendored bindings: CoreMedia/CoreVideo/VideoToolbox/GCD, ScreenCaptureKit, pthread mutex |
| `source/capture-linux/` | X11/MIT-SHM capture **spike** and its runner — not shipped, not an lwpt build entry; run against Xvfb by `tools/linux-ci.sh` ([docs/ports.md](docs/ports.md)) |
| `tools/linux-ci.sh`, `tools/win64-cross.sh`, `tools/wine-smoke.sh` | Cross-platform gates in Docker: the neutral suites on Linux, an `x86_64-win64` compile-and-link, a Wine smoke ([docs/ports.md](docs/ports.md)) |
| `docs/` | Architecture, quick-start, tooling, code style, deployment, ports, porting notes, spikes, ADRs |

Layering: `knips.pas` → {`Knips.App`, `Knips.Mcp`, `Knips.Recording`,
`Knips.Export.Pipeline`, `Knips.Export.MovieTrim`, `Knips.Export.Render`}
(`Knips.Mcp` reaches
the same session classes the CLI does — `TRecordingSession`,
`TExportSession`, `TMovieTrimSession` and `TRenderSession` — so an MCP
tool and a subcommand are one implementation, `render` included;
`Knips.App.Playback` likewise reaches
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
`Knips.Export.Atomic` sits with `Knips.Export.MovieWriter` and is
consumed by everything that writes a file the user may already have:
`Knips.Recording` (the symlink refusal), `Knips.Export.Render`,
`Knips.Export.Pipeline`, `Knips.Export.MovieTrim` and
`Knips.Recording.Recovery`, whose re-mux replaces a movie by name and
asks the same refusal before it does. Its naming rules are
`Knips.Options`', so the recovery pass's sweep of what a killed render
left — gated on the owner marker's pid — agrees with the writers on
what a temporary is called without a second copy of the rule.
`Knips.Recording.Heartbeat` sits beside them and depends on nothing at
all; `Knips.Recording` reads the clock and asks it whether the movie has
fallen behind, and `Knips.Export.MovieWriter` carries the answer out
under the mutex its capture-queue appends already take.
`Knips.Options` is used by every layer and depends on nothing;
`Knips.App.State`, `Knips.Recording.LiveMath` and
`Knips.Recording.CursorMath` depend only on it;
`Knips.Options` also owns the words a finished render reports
(`RenderAppliedSummary`, `RenderSummaryLine`, the two effect-note
wrappers), `SidecarSkippedLinesNote` — what a sidecar load could not
use, said the same way by `knips render`, `knips export`, the MCP
payloads and the menu-bar app's log — and `ValidateRenderOutputPath`, so
`knips render` and the MCP render tool describe and refuse identically —
they used to hold a byte-identical copy of the summary each.
`Knips.Mcp.Params` also owns the check that every structured payload
leaving `knips mcp` matches its own tool's declared output schema
(`McpUndeclaredPayloadKeys`, routed through `Knips.Mcp`'s
`KnipsStructuredResult`): the schemas are hand-written JSON and the
payloads hand-written object literals, and comparing the real one
against the real other is the only arrangement with no third list to
keep in step.
`Knips.Mcp.Params` sits beside them (on it plus fpjson,
`Knips.App.State`, whose path helpers it reuses,
`Knips.Recording.Sidecar`, whose take-availability answer `take_info`
reports, and `Knips.Export.ZoomTrack`, for the usable-click count that
answer carries — so the whole take-info payload is neutral and tested).
`Knips.App.Live`
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
  asking; `render` and `export` replace their output the same way, and
  every one of them does it **atomically** — the file is built as
  `<out>.knips-render-tmp` and renamed on, so a Ctrl-C or a crash leaves
  whatever was there untouched (`Knips.Export.Atomic`). A symlink at the
  output is refused by name rather than written through, on every writer
  and both faces. `probe` writes and deletes `$TMPDIR/knips-probe.mp4`
  and measures the camera blur only under `probe --blur-cost`. The menu-bar app writes **two**
  movies per take — `<name>-raw.mp4` (the raw take) and `<name>.mp4` (the
  rendered deliverable) — plus a sidecar for each, and never deletes
  either: the raw take is what makes the effects changeable afterwards.
  A window recording is written once only when it takes no effect at all
  — no camera, no pointer, no zoom — because that is the only case where
  ScreenCaptureKit's desktop-independent capture is kept; otherwise it is
  composited from the display and split like any region take
  (`WindowTakeNeedsCompositing`).
  Over **MCP** the model is the same and the trigger is not: `record_stop`
  writes one movie and its sidecar and renders nothing, and the separate
  `render` tool writes the second pair when a client asks for it. A
  recording that asked for `smooth_cursor` and named no output takes the
  `-raw` name, so the pair lands exactly where the app's would.
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

<!-- lwpt:agents:begin -->

## `lwpt` command reference

Generated by `lwpt agents` from the toolkit's command registry and this project's manifest. Everything between the `lwpt:agents` markers is machine-written: edit outside the markers only, regenerate with `lwpt agents`, verify with `lwpt agents --check`. Run `lwpt <command> --help` for the same reference in a terminal.

### Subcommands

- `lwpt install [--frozen] [--silent]` — Resolve and fetch dependencies
  - `--frozen` — CI mode: refuse to update the lockfile, refuse network, verify hashes
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt add <source[@version]> [--name <name>] [--silent]` — Add a dependency to the manifest and install it
  - `--name=<value>` — Dependency name in the manifest (default: the source's last path segment)
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt remove <name> [<name>...] [--silent]` — Remove dependencies from the manifest and prune their modules
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt build [entry...] [--mode dev|release] [--clean] [--jobs N] [--verbose] [--silent]` — Compile manifest build entries
  - `--mode=<value>` — Build mode: dev (default) or release
  - `--clean` — Force a full rebuild in fresh private staging
  - `--jobs=<N>` — Maximum concurrent build entries (default: machine budget)
  - `--verbose` — Replay successful build-entry logs
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt format [--check] [--silent]` — Format uses-clauses and identifiers
  - `--check` — Report files needing formatting without rewriting; exit 1 if any
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt duplication [--json] [--silent]` — Report manifest-scoped Pascal token clones
  - `--json` — Emit the deterministic machine-readable analysis envelope
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt test [selector...] [--tier default|e2e] [--jobs N] [--bail N] [--verbose] [--inventory] [--silent]` — Discover and run *.Test.pas files
  - `--tier=<value>` — Test tier to include: default (unit + integration) or e2e (adds network-touching tier)
  - `--jobs=<N>` — Maximum concurrent test programs (default: shared machine budget)
  - `--bail=<N>` — Stop after N compile or runtime failures; 0 runs the full queue
  - `--verbose` — Replay successful test logs
  - `--inventory` — Emit registered suites and cases as deterministic JSON without running tests
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt repair [--silent]` — Reclaim install, build-session, and worker-lease residue
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt init [--yes] [--force] [--adopt] [--silent]` — Scaffold a new LWPT project or adopt an existing manifest
  - `--yes` — Skip prompts and use defaults derived from the directory name
  - `--force` — Overwrite an existing lwpt.toml without asking
  - `--adopt` — Fill in missing scaffold around an existing manifest without modifying it
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt run <task-name> | <subcommand> [subcommand-args...] [--silent]` — Invoke a user-declared run task (or a built-in subcommand by name)
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt health [--json] [--hotspots] [--silent]` — Report Pascal complexity and optional Git hotspots
  - `--json` — Write the deterministic machine-readable report
  - `--hotspots` — Enrich complexity with the latest 100 commits of local Git churn
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt agents [--check] [--silent]` — Write or verify the agent-facing command reference in AGENTS.md
  - `--check` — Verify the AGENTS.md block matches the current command surface; exit 1 when stale
  - `--silent` — Suppress ordinary output and emit only the final command result

### Run tasks

No run tasks declared in `lwpt.toml`.

### Manifest schema

Generated from the same immutable structural registry used by manifest validation. Domain-specific syntax and cross-field rules remain in the parser; see the project documentation for those details.

- `[package]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Package identity and Pascal unit roots.
  - `name`: string; optional; default: `unnamed`; invalid values are ignored as absent. Package name; the legacy root name fallback still warns.
  - `version`: string; optional; default: `0.0.0`; invalid values are ignored as absent. Package version.
  - `units`: array of strings; optional; default: `empty`; invalid values and items are skipped. Pascal unit-root paths.
- `[dependencies]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Named dependency declarations.
  - `<name>`: string or table; optional; other values retain legacy handling. Bare `<source>@<version>` shorthand or an inline table.
- `[dependencies].<name>` — string or inline table; all manifests; other values retain legacy handling; unknown keys are ignored. A source shorthand or expanded dependency declaration.
  - `source`: string; required; invalid values are errors. `owner/repo` (GitHub), `<host>:owner/repo` (built-in or custom host), an HTTPS tarball, a local path, or `workspace:<version>`.
  - `version`: string; optional; default: `none`; invalid values are ignored as absent. Version range, exact version, SHA, or tag.
  - `include`: array of strings; optional; default: `all files`; invalid values and items are skipped. Post-extraction include globs.
  - `exclude`: array of strings; optional; default: `none`; invalid values and items are skipped. Post-extraction exclude globs.
  - `repo`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `ref`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `tag`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `asset`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `path`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `subdir`: retired; optional; invalid values are errors. Retired; use include globs.
- `[sources]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Named custom Git-host URL templates.
  - `<name>`: table; optional; invalid values are ignored as absent. One custom source declaration.
- `[sources].<name>` — inline table; all manifests; invalid values are ignored as absent; unknown keys are ignored. One custom Git-host source.
  - `archive`: string; required; invalid values are errors. HTTPS archive template containing {user}, {repository}, and {ref}.
  - `git`: string; required; invalid values are errors. HTTPS smart-HTTP template containing {user} and {repository}.
- `[workspaces]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Workspace discovery globs.
  - `include`: array of strings; optional; default: `empty`; invalid values and items are skipped. Workspace discovery globs.
  - `exclude`: array of strings; optional; default: `empty`; invalid values and items are skipped. Workspace exclusion globs.
- `[build]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Single-entry shorthand or named build entries.
  - `<name>`: string or table; optional; other values retain legacy handling. Named entry; build.source enables single-entry shorthand.
- `[build].<name>` — string or table; all manifests; other values retain legacy handling; unknown keys are ignored. One compiler-neutral build entry.
  - `source`: string; conditional; invalid values are ignored as absent. Compiler entry-point path.
  - `output`: string; optional; default: `build/<name>`; invalid values are ignored as absent. Published executable path.
  - `depends`: array of strings; optional; default: `empty`; invalid values are errors. Prerequisite build-entry names.
  - `flags`: array of strings; optional; default: `empty`; root manifest only; invalid values are errors. Ordered compiler-driver arguments.
  - `compiler`: string; optional; default: `[compiler].default`; root manifest only; invalid values are errors. Named compiler-profile override.
  - `target`: table; optional; default: `compiler native target`; root manifest only; invalid values are errors. Explicit target tuple.
  - `prebuild`: table; optional; default: `empty`; invalid values are ignored as absent. Per-entry prebuild command map.
  - `postbuild`: table; optional; default: `empty`; invalid values are ignored as absent. Per-entry postbuild command map.
- `[build].<name>.target` — table; root manifest only; invalid values are errors; unknown keys are errors. An explicit complete compiler target tuple.
  - `os`: string; required; invalid values are errors. Target operating system.
  - `architecture`: string; required; invalid values are errors. Target architecture.
  - `abi`: string; optional; default: `empty`; invalid values are errors. Optional target ABI.
  - `environment`: string; optional; default: `empty`; invalid values are errors. Optional target execution environment.
- `[compiler]` — table; root manifest only; invalid values are errors; unknown keys are ignored. Root-owned compiler profile selection.
  - `default`: string; optional; default: `host default`; invalid values are errors. Default profile name.
  - `profiles`: table; optional; default: `empty`; invalid values are errors. Named compiler-profile map.
- `[compiler.profiles].<name>` — table; root manifest only; invalid values are errors; unknown keys are ignored. One built-in or external compiler profile.
  - `driver`: string; required; invalid values are errors. Built-in or external driver identity.
  - `command`: string; optional; default: `driver default`; invalid values are errors. Direct compiler command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `version`: string; optional; default: `*`; invalid values are errors. Compiler version constraint.
  - `executable`: retired; optional; invalid values are errors. Retired; use command and args.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.
- `[version]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Generated version-include settings.
  - `output`: string; optional; default: `empty`; invalid values are ignored as absent. Generated include path.
  - `prefix`: string; optional; default: `BAKED`; invalid values are ignored as absent. Generated constant prefix.
- `[lwpt]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Toolkit-state path overrides.
  - `modules-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Installed-module directory override.
  - `archives-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Archive-cache directory override.
  - `tmp-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Private temporary directory override.
  - `sessions-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Private compiler-session directory override.
  - `cfg-file`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Compiler response-file override.
- `[format]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Formatter scope additions and subtractions.
  - `include`: array of strings; optional; default: `empty`; invalid values and items are skipped. Formatter-scope additions.
  - `exclude`: array of strings; optional; default: `empty`; invalid values and items are skipped. Formatter-scope subtraction.
- `[analysis]` — table; all manifests; invalid values are errors; unknown keys are ignored. Shared Pascal analysis source scope.
  - `include`: array of strings; optional; default: `empty`; invalid values are errors. Analysis-scope additions.
  - `exclude`: array of strings; optional; default: `empty`; invalid values are errors. Analysis-scope subtraction.
- `[health]` — table; all manifests; invalid values are errors; unknown keys are errors. Optional complexity and hotspot limits.
  - `max-routine-cyclomatic`: integer; optional; default: `unset`; invalid values are errors. Non-negative routine cyclomatic limit.
  - `max-routine-cognitive`: integer; optional; default: `unset`; invalid values are errors. Non-negative routine cognitive limit.
  - `max-file-cyclomatic`: integer; optional; default: `unset`; invalid values are errors. Non-negative file cyclomatic limit.
  - `max-file-cognitive`: integer; optional; default: `unset`; invalid values are errors. Non-negative file cognitive limit.
  - `max-hotspot-score`: integer; optional; default: `unset`; invalid values are errors. Integer hotspot limit from 0 to 100.
- `[duplication]` — table; all manifests; invalid values are errors; unknown keys are ignored. Token-clone floor and optional percentage limit.
  - `minimum-tokens`: integer; optional; default: `100`; invalid values are errors. Clone floor; minimum accepted value is 25.
  - `maximum-percent`: integer; optional; default: `unset`; invalid values are errors. Integer duplication limit from 0 to 100.
- `[test]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Test compiler and scheduler policy.
  - `bail`: integer; optional; default: `0`; invalid values are errors. Non-negative failure count; zero runs the full queue.
  - `flags`: array of strings; optional; default: `empty`; root manifest only; invalid values are errors. Ordered test compiler arguments.
- `[preinstall] / [postinstall] / [prebuild] / [postbuild] / [pretest] / [posttest]` — table; root manifest only; invalid values are ignored as absent; unknown keys are ignored. Root lifecycle command maps.
  - `<name>`: string or table; optional; invalid values are errors. One lifecycle hook.
- `<hook entry>` — string or inline table; all manifests; invalid values are errors; unknown keys are errors. A direct command with optional staleness gating.
  - `command`: string; required; invalid values are errors. Direct child-process command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `inputs`: array of strings; conditional; default: `empty`; invalid values are errors. Non-empty staleness input globs.
  - `output`: string; conditional; default: `empty`; invalid values are errors. Staleness output, paired with inputs.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.
- `[<task-name>]` — table; root manifest only; invalid values are errors; unknown keys are errors. An otherwise-unknown top-level section carrying command.
  - `command`: string; required; invalid values are errors. Direct child-process command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `inputs`: array of strings; conditional; default: `empty`; invalid values are errors. Non-empty staleness input globs.
  - `output`: string; conditional; default: `empty`; invalid values are errors. Staleness output, paired with inputs.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.

<!-- lwpt:agents:end -->

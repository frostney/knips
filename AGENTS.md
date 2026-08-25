# Agent Instructions

## Hard Constraints

- **FreePascal only.** FPC 3.2.2, Delphi mode, flags centralised in
  `source/Shared.inc` (`{$I Shared.inc}` per unit). No second compiled
  language, no Swift/ObjC shims. Per-unit modeswitches (`objectivec2`,
  `cblocks`, `cvar`) are the sanctioned addition for Darwin units — see
  [docs/code-style.md](docs/code-style.md).
- **lwpt is the only toolchain entry point** — install, build, test, format
  all go through it. Do not invoke `fpc` directly except as `fpc @lwpt.cfg`.
- **`lwpt.cfg` and `lwpt.lock` are generated** by `lwpt install`; never
  hand-edit them. `lwpt.toml` is the manifest you edit.
- **The default `opname` build entry stays linker-flag-free.** Never add
  `flags` to it. Objective-C classes are built through the runtime API
  (`Opname.ObjC.Runtime`), never declared with `objcclass` except as
  `external` bindings ([ADR-0002](docs/adr/0002-runtime-built-objc-classes.md)).
  The `-k-ld_classic` variant is a separate, documented entry if it is ever
  needed ([docs/tooling.md](docs/tooling.md)).
- **No `cthreads`.** The capture queue is a GCD thread the RTL never
  adopts. On that thread (`TScreenStream.OnSample` and everything it
  calls): no exceptions, no `try..finally`, no `WriteLn`, no managed-type
  writes outside a `TPThreadMutex`. `cmem` stays the first unit of the
  program, `Opname.ThreadManager` (pthread-backed RTL locks/events, no
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
  until `opname probe` and a real recording clear it.
- **Edit `AGENTS.md` only** — `CLAUDE.md` is a symlink to it. Same for
  `.agents/skills/` (canonical) vs `.claude/skills` (symlink).

## Runtime / Commands

lwpt ≥ 0.7.0 is expected on PATH (or a locally built binary; see
[docs/quick-start.md](docs/quick-start.md)).

```bash
lwpt install          # resolve cli + testing from the lwpt release tag
lwpt build            # build/opname (dev mode)
lwpt test             # co-located unit suites (*.Test.pas) — run on any OS
lwpt format --check   # formatter gate (no flag = rewrite in place)

./build/opname probe                     # toolchain verification (macOS)
./build/opname record --out=demo.mp4     # record; Ctrl-C stops
```

## Code Organization

| Path | Role |
| --- | --- |
| `source/opname.pas` | Program: CLI surface (`record`, `displays`, `windows`, `probe`), signals |
| `source/Opname.Options.pas` | Platform-neutral option model + validation (tested) |
| `source/Opname.ObjC.TypeEncoding.pas` | Method type encodings for runtime classes (tested) |
| `source/Opname.ObjC.Runtime.pas` | Runtime-built ObjC classes (the ADR-0002 primitive) |
| `source/Opname.Capture.ShareableContent.pas` | Display/window enumeration via SCShareableContent |
| `source/Opname.Capture.Stream.pas` | SCStream wrapper; runtime-built SCStreamOutput; frame-status filter |
| `source/Opname.Export.MovieWriter.pas` | AVAssetWriter bindings + the movie sink |
| `source/Opname.Recording.pas` | Orchestrator: target → geometry → writer → stream → finish |
| `source/capture/` | Vendored bindings: CoreMedia/CoreVideo/VideoToolbox/GCD, ScreenCaptureKit, pthread mutex |
| `docs/` | Architecture, quick-start, tooling, code style, deployment, porting notes, spikes, ADRs |

Layering: `opname.pas` → `Opname.Recording` → {`Opname.Capture.*`,
`Opname.Export.MovieWriter`} → {`Opname.ObjC.*`, `source/capture/*`}.
`Opname.Options` is used by every layer and depends on nothing.

## Testing

- `lwpt test` discovers `source/*.Test.pas`. Everything platform-neutral
  has a co-located suite and runs on Linux CI as well as macOS.
- Darwin units cannot be unit-tested off-device. Their gate is
  `opname probe` (runtime class registration, SCK enumeration,
  AVAssetWriter open) followed by a real `record` that plays back in
  QuickTime Player. Both are hard gates before handoff of any capture change.
- Off-device, the Darwin units are type-checked with a cross compiler
  (`docs/tooling.md`); that catches declaration errors, not behaviour.

## Safety / Boundaries

- Never commit generated state: `build/`, `.lwpt/tmp/`, `.lwpt/sessions/`,
  `.lwpt/session-roots`, `.lwpt/install.lock`.
- `record` writes to the path given and replaces an existing file without
  asking; `probe` writes and deletes `$TMPDIR/opname-probe.mp4`.
- macOS permissions (Screen Recording) are per-binary; a fresh build
  re-prompts. Test tooling never injects input — this is a recorder, not
  lantaarn.

# Tooling

## Executive Summary

- lwpt drives everything: `install`, `build`, `test`, `format`, `health`.
- Other platforms are gated from a Mac in Docker: `tools/linux-ci.sh`,
  `tools/win64-cross.sh`, `tools/wine-smoke.sh` ([ports.md](ports.md)).
- Pinned: FPC 3.2.2, `cli`/`testing` `^0.7.0` (locked in `lwpt.lock`).
  The lwpt BINARY is a separate number: 0.6.0 is what this repo is
  developed against and it runs every gate.
- The default build entry has no `flags`; the `-k-ld_classic` variant is
  a documented, opt-in second entry that is never committed as default.
- Off-device type-checking of Darwin units uses an FPC cross compiler
  (`ppcrossa64`) with clang as the Mach-O assembler; it catches
  declaration and type errors, not runtime behaviour.
- Lefthook is the only automation: pre-commit runs `lwpt format`,
  pre-push runs the real gate. There is no CI service — the release gate
  on top of it is `tools/release-gate.sh`, run by hand
  ([Git hooks and the release gate](#git-hooks-and-the-release-gate)).

## Commands

| Command | What |
| --- | --- |
| `lwpt install` | resolve `lwpt.toml`, fetch deps, write `lwpt.lock` + `lwpt.cfg` |
| `lwpt build` | `build/knips` (dev; `--mode release` for `-O4 -Xs`) |
| `lwpt test` | discover/compile/run `source/*.Test.pas` |
| `lwpt format [--check]` | canonical formatting; `--check` is the gate form |
| `lwpt health [--hotspots]` | complexity report |
| `./build/knips probe` | on-device toolchain gate |

## Versions (verify live, don't trust memory)

The two 0.7.0s in this file are not the same thing and the docs used to
say they were. `^0.7.0` in `lwpt.toml` is the **release tag** the `cli`
and `testing` packages are fetched from; it says nothing about the lwpt
binary doing the fetching, which is 0.6.0 here and runs every gate this
project has. AGENTS.md says the same, in the same words.

| Tool | Pin | Check |
| --- | --- | --- |
| FPC | 3.2.2 | `fpc -iV` |
| lwpt (the binary) | 0.6.0 developed against | `lwpt --version` |
| cli, testing (the packages) | `^0.7.0` release tag | `lwpt.lock` |
| Lefthook | ≥ 1.5 | `lefthook version` |
| macOS | 13+ | `sw_vers` |

There is no changelog generator in that table on purpose. `CHANGELOG.md`
is hand-maintained curated prose (DEFINITION_OF_DONE.md); the
`cliff.toml` that once sat here was carried in from lantaarn, named that
project, and has been deleted.

## The `-ld_classic` escape hatch

If, on some toolchain, the default build fails at link time with
`malformed method list atom` (or a relative), first confirm no
`objcclass` other than `external` ones exists in the tree — that is the
only thing that produces the offending metadata. If the failure is
genuinely elsewhere, add a second build entry rather than touching the
default:

```toml
[build]
knips = { source = "source/knips.pas", output = "build/knips" }
knips-ld-classic = { source = "source/knips.pas", output = "build/knips-ld-classic", flags = ["-k-ld_classic"] }
```

lwpt 0.7.0 passes `flags` verbatim per entry (see lwpt's
`docs/build-system.md`). Do not commit that entry: it fails on Linux,
where the GNU linker has no such option, and `lwpt build` builds every
entry by default.

## Other platforms (Docker)

Three scripts run the parts of the tree that are not macOS-only, from a
Mac, in containers. The design behind them is [ports.md](ports.md).

| Script | What it does |
| --- | --- |
| `tools/linux-ci.sh` | Debian bookworm + FPC 3.2.2 + the real lwpt 0.7.0 Linux binary; `lwpt test`, `lwpt build`, a binary smoke, `lwpt format --check`, and the X11/MIT-SHM capture spike against Xvfb. `--platform linux/amd64` for x86_64. |
| `tools/win64-cross.sh` | Bootstraps an FPC 3.2.2 `x86_64-win64` cross compiler in the container, then compiles and links `knips.pas` and every suite; verifies each artefact is PE32+. Compile-and-link only — it never runs what it builds. |
| `tools/wine-smoke.sh` | Runs those `.exe` files under Wine in an amd64 container. A smoke test, not a gate — but it is what caught the POSIX assumptions in `Knips.Mcp.Params.Test` (stale literals and a wrong absolute-path predicate in the *tests*; the helpers themselves already use `PathDelim`). |

All three mount the checkout read-only and copy it inside the container,
so a Linux or Windows build never leaves foreign `.ppu`/`.o` files or an
ELF/PE `build/knips` in a Mac checkout. `wine-smoke.sh` is the exception
by design: it extracts the built executables into `build/win64/`, which
`.gitignore` already covers.

lwpt stays the entry point on Linux — upstream publishes `linux-arm64`
and `linux-x64` release binaries, so the container runs the same
`lwpt test` a developer runs. Only the cross-compile has no lwpt path;
it uses `fpc @lwpt.cfg`, the one direct-compiler form AGENTS.md sanctions,
adding nothing but `-Twin64 -Px86_64` and output directories.

## Off-device type checking (cross compiler)

FPC on Linux refuses `{$modeswitch objectivec1}`, so a native Linux build
compiles the Darwin units as empty shells. To type-check them for real
without a Mac:

1. Clone `fpc/FPCSource` at `release_3_2_2`.
2. `cd compiler && make compiler PPC_TARGET=aarch64 EXENAME=ppcrossa64
   CROSSBINDIR= BINUTILSPREFIX= CYCLELEVEL=2` — a native-hosted aarch64
   code generator.
3. Provide `aarch64-darwin-clang` on PATH as a shim that drops `-arch`
   and `-mmacosx-version-min` and calls `clang -target arm64-apple-macos12`.
4. `make rtl OS_TARGET=darwin CPU_TARGET=aarch64
   FPC=…/ppcrossa64 BINUTILSPREFIX=aarch64-darwin-`.
5. Compile `packages/univint/src/MacOSAll.pas` (`-Mmacpas`),
   `packages/cocoaint/src/CocoaAll.pas` (`-Mdelphi -dMACOSALL -dCOCOAALL
   -dLEGACY_SETNEEDSDISPLAY`), `rtl-objpas` `varutils`/`variants`, and
   `rtl-generics` into one unit directory.
6. `ppcrossa64 -Tdarwin -Paarch64 -XPaarch64-darwin- -Mdelphi -Sh -Cn
   -Fu<rtl units> -Fu<that directory> @lwpt.cfg source/knips.pas`.

`-Cn` skips linking. This is how the Darwin units in this repository were
checked before the first on-device run; it proves declarations and
types, nothing about the frameworks' behaviour.

## Git hooks and the release gate

`lefthook.yml` is the whole of knips's automation. There is no CI
service behind it — no workflow, no pipeline, nothing that runs on a
server when a branch is pushed. This section used to say the heavyweight
gates "belong to CI / the PR flow", which read as though something else
was running them; nothing was, and in a fresh clone `lefthook install`
had never been run either, so `.git/hooks` held only samples.

    lefthook install     # once per clone; writes .git/hooks/{pre-commit,pre-push}

- **pre-commit** runs `lwpt format` on staged Pascal/TOML files with
  `stage_fixed: true`, so a commit stays fast.
- **pre-push** is the real gate, piped and fail-fast: `lwpt format
  --check`, `lwpt build`, `lwpt test`, `lwpt agents --check`. About a
  minute, measured.
- **`tools/release-gate.sh`** is the Definition of Done as a command:
  the same four the pre-push hook runs — `lwpt format --check`, `lwpt
  build`, `lwpt test`, `lwpt agents --check` — plus `lwpt build --mode
  release` and `knips probe` against the release binary. Six steps, four
  with `--no-probe`. It is not a hook because the probe needs a Mac with
  Screen Recording permission and minutes rather than seconds.
  `--no-probe` runs the part any machine can.

  **It leaves `build/knips` a release binary.** The release build is the
  last thing in the run that writes it, so run `lwpt build` afterwards to
  get the dev binary back. The script says so on the way out.

`KNIPS_LWPT` overrides the lwpt binary for all three.

Worktrees share one hooks directory: git resolves `hooks/` against the
common `.git`, so `lefthook install` from a worktree installs for the
main checkout too. Each working tree still runs its own `lefthook.yml`,
because the installed hook resolves the config from
`git rev-parse --show-toplevel`.

## Code review (CodeRabbit)

CodeRabbit reads `.coderabbit.config.ts`, which inherits the central
`frostney/coderabbit` settings and the web-UI settings (`inheritance:
true`) and excludes the vendored Agent Skills from review, using the
shared `excludeVendoredSkills` function from `frostney/coderabbit`. Every
skill listed in `skills-lock.json` is installed from upstream by the
skills CLI, so findings on it belong upstream. A skill under
`.agents/skills` that the lock does not list is project-authored and is
reviewed like any other file. The config reads the lock through
`skills-lock.yaml`, a symlink, because the config sandbox imports `.yaml`
but not `.json`.

## Known upstream issues

- lwpt `cli` 0.7.0: `TSubcommandRegistry.PrintTopLevelHelp` prints
  lwpt's own tagline. Knips prints its own top-level help and only
  delegates per-command help. Worth a small upstream change (a tagline
  parameter).
- **pascal-mcp-sdk's dev dependency collides with ours.** lwpt reads a
  fetched module's `lwpt.toml` for two things at once — the unit
  directories it contributes *and* the dependencies it requires — and
  the resolver graph is flat and single-version by design
  ([lwpt ADR-0031](https://github.com/frostney/lwpt/blob/main/docs/adr/0031-fixed-point-single-version-resolution.md)),
  because FPC has one global unit namespace. pascal-mcp-sdk 2.0.0
  declares `testing = "^0.2.0"` for its own suites; knips declares
  `testing = "^0.7.0"`; caret on a `0.x` version pins the minor, so the
  two ranges are disjoint and `lwpt install` fails outright:

  ```text
  lwpt install: unresolvable version conflict on "testing":
    knips wants "^0.7.0"
    mcp wants "^0.2.0"
  ```

  The dependency is dev-time only — knips excludes the SDK's
  `*.Test.pas` at fetch, so nothing here would ever compile against it —
  but lwpt has no dev-dependency concept and no override table, so the
  constraint is inherited anyway.

  **What knips does:** the `mcp` dependency's `include` filter omits the
  SDK's `lwpt.toml`. With no nested manifest, lwpt walks no transitive
  dependencies (`FindModuleManifest` → manifest-less behaviour) and the
  conflict disappears; the unit directory the manifest would have
  contributed is named directly in `[package] units` instead. The SDK
  stays a real, tag-resolved, hash-locked dependency — this is not
  vendoring — and its module snapshot is committed like `cli` and
  `testing`, so the named path exists in a fresh clone.

  **What would remove the workaround:** either the SDK relaxing that
  pin (its `main` already moved to `^0.5.1`, still disjoint from
  `^0.7.0`), or lwpt gaining dev-only dependencies or a root-level
  override. Either way the fix is two lines: put `"lwpt.toml"` back in
  the `include` list and drop the `.lwpt/modules/mcp/...` entry from
  `[package] units`.

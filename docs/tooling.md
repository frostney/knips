# Tooling

## Executive Summary

- lwpt drives everything: `install`, `build`, `test`, `format`, `health`.
- Pinned: FPC 3.2.2, lwpt ≥ 0.7.0, `cli`/`testing` `^0.7.0` (locked in
  `lwpt.lock`).
- The default build entry has no `flags`; the `-k-ld_classic` variant is
  a documented, opt-in second entry that is never committed as default.
- Off-device type-checking of Darwin units uses an FPC cross compiler
  (`ppcrossa64`) with clang as the Mach-O assembler; it catches
  declaration and type errors, not runtime behaviour.
- Pre-commit via Lefthook runs `lwpt format`; the full gate runs in PRs.

## Commands

| Command | What |
| --- | --- |
| `lwpt install` | resolve `lwpt.toml`, fetch deps, write `lwpt.lock` + `lwpt.cfg` |
| `lwpt build` | `build/knips` (dev; `--mode release` for `-O4 -Xs`) |
| `lwpt test` | discover/compile/run `source/*.Test.pas` |
| `lwpt format [--check]` | canonical formatting; `--check` is the CI form |
| `lwpt health [--hotspots]` | complexity report |
| `./build/knips probe` | on-device toolchain gate |

## Versions (verify live, don't trust memory)

| Tool | Pin | Check |
| --- | --- | --- |
| FPC | 3.2.2 | `fpc -iV` |
| lwpt | ≥ 0.7.0 | `lwpt --version` |
| cli, testing | `^0.7.0` | `lwpt.lock` |
| Lefthook | ≥ 1.5 | `lefthook version` |
| git-cliff | current | `git-cliff --version` |
| macOS | 13+ | `sw_vers` |

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

## Pre-commit

`lefthook.yml` runs `lwpt format` on staged Pascal/TOML files with
`stage_fixed: true`. Heavyweight gates (`format --check`, `build`,
`test`, `probe`) belong to CI / the PR flow.

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

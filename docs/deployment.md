# Deployment

## Executive Summary

- Release build: `lwpt build --mode release` → `build/opname`, a single
  arm64 binary linking only system frameworks.
- `tools/make-app.sh` wraps that binary in `build/Opname.app`, an
  `LSUIElement` bundle whose executable is a two-line launcher running
  `opname app`.
- Distribution needs code signing with the Screen Recording entitlement
  story in mind: TCC grants are per-binary identity, so ad-hoc-signed
  builds re-prompt on every rebuild.
- No CI workflow yet; the PR gate is manual (`format --check`, `build`,
  `test` on Linux or macOS; `probe` + a recording on macOS).

## Build

```sh
lwpt build --mode release     # -O4 -dPRODUCTION -Xs -CX -XX -B
```

Frameworks linked: ScreenCaptureKit, AVFoundation, CoreMedia, CoreVideo,
Foundation, Cocoa (via CocoaAll). No third-party libraries.

## The app bundle

```sh
lwpt build --mode release
tools/make-app.sh              # prints the path it wrote
open build/Opname.app
```

`make-app.sh` assembles the minimum that makes a menu-bar app a real app:

```text
build/Opname.app/Contents/
  Info.plist        CFBundleIdentifier org.opname.app, CFBundleName Opname,
                    CFBundleExecutable Opname, LSUIElement true,
                    LSMinimumSystemVersion 13.0, version from Opname.Options
  PkgInfo           APPL????
  MacOS/Opname      #!/bin/sh — exec "$(dirname "$0")/opname-bin" app
  MacOS/opname-bin  the built binary, CLI intact
```

The launcher exists so the binary keeps its command-line surface: run
directly it still prints help, and `opname record …` still works from the
bundle. The two files must not differ only in case — the default macOS
volume is case-insensitive, which is why the binary is `opname-bin` and
not `opname`.

The script takes an optional path to a binary other than `build/opname`,
and rewrites the bundle from scratch each time. `build/` is git-ignored,
so the bundle is a build artefact, never a committed one.

## Signing and permissions

Screen Recording permission is keyed to the binary's code signature.
For local use an unsigned build works and re-prompts after each rebuild.
For anything shared, sign with a stable Developer ID identity so the
grant persists across updates. Hardened runtime is compatible with
ScreenCaptureKit; no entitlement beyond the TCC prompt is required for
a non-sandboxed CLI. A sandboxed app (milestone 2) will need the usual
app-sandbox entitlements.

The bundle inherits the same story: an unsigned `Opname.app` re-prompts
whenever `opname-bin` changes. Because the launcher is a shell script, the
process macOS attributes the Screen Recording grant to is the exec'd
binary; sign both the binary and the bundle with the same Developer ID
identity if the grant is meant to survive updates. This is untested on a
signed build — verify before the first release.

## Release flow

1. Bump `version` in `lwpt.toml` and `OpnameVersion` in
   `Opname.Options`.
2. `git-cliff -o CHANGELOG.md`.
3. Tag `X.Y.Z`; attach `build/opname` from a release build on Apple
   silicon.

Rollback is re-downloading the previous tag's binary; opname keeps no
state.

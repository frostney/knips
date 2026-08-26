# Deployment

## Executive Summary

- Release build: `lwpt build --mode release` → `build/knips`, a single
  arm64 binary linking only system frameworks.
- `tools/make-app.sh` wraps that binary in `build/Knips.app`, an
  `LSUIElement` bundle whose executable is the binary itself; the binary
  detects the bundle launch from its own path and runs app mode.
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
open build/Knips.app
```

`make-app.sh` assembles the minimum that makes a menu-bar app a real app:

```text
build/Knips.app/Contents/
  Info.plist        CFBundleIdentifier org.knips.app, CFBundleName Knips,
                    CFBundleExecutable knips-bin, LSUIElement true,
                    LSMinimumSystemVersion 13.0, version from Knips.Options
  PkgInfo           APPL????
  MacOS/knips-bin   the built binary, CLI intact
```

`CFBundleExecutable` is the binary itself, not a launcher script: a
script that execs the binary breaks the LaunchServices handshake AppKit
needs before the menu bar will adopt a status item (seen on device — the
item's window stayed height 0 and invisible). Launched from a bundle
with no arguments, the binary infers app mode from its own path
(`.app/Contents/MacOS/`); run from a shell it keeps the full CLI, and
`Contents/MacOS/knips-bin record …` works from inside the bundle too.

The script takes an optional path to a binary other than `build/knips`,
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

The bundle inherits the same story: an unsigned `Knips.app` re-prompts
whenever `knips-bin` changes. Because the launcher is a shell script, the
process macOS attributes the Screen Recording grant to is the exec'd
binary; sign both the binary and the bundle with the same Developer ID
identity if the grant is meant to survive updates. This is untested on a
signed build — verify before the first release.

## Release flow

1. Bump `version` in `lwpt.toml` and `KnipsVersion` in
   `Knips.Options`.
2. `git-cliff -o CHANGELOG.md`.
3. Tag `X.Y.Z`; attach `build/knips` from a release build on Apple
   silicon.

Rollback is re-downloading the previous tag's binary; Knips keeps no
state.

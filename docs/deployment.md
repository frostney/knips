# Deployment

## Executive Summary

- Release build: `lwpt build --mode release` → `build/knips`, a single
  arm64 binary linking only system frameworks.
- `tools/make-app.sh` wraps that binary in `build/Knips.app`, an
  `LSUIElement` bundle whose executable is the binary itself; the binary
  detects the bundle launch from its own path and runs app mode.
- The bundle is ad-hoc signed with an identifier-only designated
  requirement, so TCC grants survive rebuilds locally; distribution
  still wants a Developer ID (see Signing and permissions).
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

TCC keys a grant to the app's *designated requirement*. `make-app.sh`
ad-hoc signs the bundle with an explicit identifier-only requirement
(`designated => identifier "org.knips.app"`), which is byte-identical
build after build — so Screen Recording and Camera grants persist
across rebuilds on a development machine (measured; an unsigned bundle
gets a limbo identity whose camera requests tccd silently drops, and a
default ad-hoc signature's requirement is the cdhash of the exact
binary, orphaning the grant on every rebuild).

The trade-off of identifier-only matching: ANY ad-hoc binary claiming
`org.knips.app` inherits the grant. That is acceptable for one
developer's machine and wrong for distribution — a release build must
be signed with a Developer ID identity, whose certificate-anchored
requirement replaces this one wholesale. Hardened runtime is compatible
with ScreenCaptureKit; no entitlement beyond the TCC prompts is
required for a non-sandboxed app.

## Release flow

1. Bump `version` in `lwpt.toml` and `KnipsVersion` in
   `Knips.Options`.
2. `git-cliff -o CHANGELOG.md`.
3. Tag `X.Y.Z`; attach `build/knips` from a release build on Apple
   silicon.

Rollback is re-downloading the previous tag's binary; Knips keeps no
state.

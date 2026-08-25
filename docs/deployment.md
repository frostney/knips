# Deployment

## Executive Summary

- Release build: `lwpt build --mode release` → `build/opname`, a single
  arm64 binary linking only system frameworks.
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

## Signing and permissions

Screen Recording permission is keyed to the binary's code signature.
For local use an unsigned build works and re-prompts after each rebuild.
For anything shared, sign with a stable Developer ID identity so the
grant persists across updates. Hardened runtime is compatible with
ScreenCaptureKit; no entitlement beyond the TCC prompt is required for
a non-sandboxed CLI. A sandboxed app (milestone 2) will need the usual
app-sandbox entitlements.

## Release flow

1. Bump `version` in `lwpt.toml` and `OpnameVersion` in
   `Opname.Options`.
2. `git-cliff -o CHANGELOG.md`.
3. Tag `X.Y.Z`; attach `build/opname` from a release build on Apple
   silicon.

Rollback is re-downloading the previous tag's binary; opname keeps no
state.

# Codebase audit remediation — 2026-09-09

All eight selected findings have local implementations. Three sub-agents
handled sidecars, keyboard selection and live-effect cleanup; the coordinator
integrated file ownership, recording replacement and recovery, with independent
source review and shared validation.

Branch: `fix/audit-file-safety`, based on `8a108df` (`origin/main` at start).
Worktree: `../KapoFPC-lanes/audit-remediation`. The original checkout was left
clean. The user requested publication of all changes in one PR after the
Computer Use follow-up; the outstanding checks below keep it in draft.

## Changes grouped for review

| Finding | Remedy | Evidence |
| --- | --- | --- |
| CA-1: sidecar writes follow symlinks | Open without following links, inspect the actual handle before truncation, and apply the same rule to recovery append | Sidecar create/append, dangling-link, directory and path-swap regressions; synthetic CLI test |
| CA-2: recording failure destroys previous output | Write to a reserved recording movie with its own sidecar; replace the movie only after successful finish, then publish metadata | AVAssetWriter cancellation and empty-finish sentinel tests; sidecar publication and retention tests |
| CA-3: another operation deletes live scratch | Reserve unique sibling names with exclusive owner markers; per-operation cleanup acts only on names successfully claimed by this process | Independent claims, unowned sweep, failed/successful commits and marker tests; live-scratch CLI reproduction |
| CA-4: recovery deletes an unrelated neighbour | Reuse the trim writer's atomic in-place replacement and remove the unowned `.recovering.mp4` path | Synthetic recovery re-muxes once while preserving the neighbour byte-for-byte |
| CA-5: different extensions overwrite source metadata | Refuse movie/sidecar path collisions before writes, including existing Unix inode aliases | Path/alias unit tests; same-stem CLI rejection preserves source movie and sidecar |
| CA-6: sidecar failures disappear | Report partial success through CLI, MCP and app; retain the finished movie; skip automatic rendering after recording metadata failure | Publication regressions and synthetic CLI/MCP blocked-sidecar checks |
| CA-7: region selection needs a mouse | Start with a centered selection; arrows move, Shift resizes, Option uses fine steps, Tab changes displays, Return confirms, Escape cancels | Three neutral geometry regressions; AppKit/Carbon bindings checked against available SDK/RTL definitions |
| CA-8: unreachable live zoom remains | Remove zoom, click, focus and hold state from the live animator, preserving Follow Mouse and shared render-time zoom arithmetic | Caller/source review and existing live-math/zoom suites |

The file-safety changes belong together: recording, rendering, trim and recovery
share ownership and replacement rules, while CLI/MCP/app report their results.
Keyboard selection and live-zoom cleanup are independently reviewable changes.
Documentation and the changelog describe the resulting behavior.

A regression also exposed FPC's `TSearchRec.Name` dropping the prefix before a
literal backslash in a Unix filename. Temporary cleanup and recovery now read
literal POSIX directory entries. Tests cover both shadow cleanup and a distinct
live neighbour.

Final review found and reproduced a migration regression: a failed render
publication retained its complete temporary movie and owner marker. Render now
sweeps its own scratch on publication failure. The synthetic check covers both
raw-copy and encoded-render paths, verifies the failed destination stays intact,
and ensures an unrelated live temporary survives.

## Validation observed

- `tools/release-gate.sh --no-probe`: all four gates passed: formatting,
  development build, **17 test programs**, generated agent-reference check.
- `lwpt build --mode release`: passed.
- `tools/check-file-safety.sh` against the release binary: **eight checks
  passed**, using generated H.264/AAC media, CLI/MCP commands and a temporary
  Pascal recovery harness. No personal screen or camera content was captured.
- `git diff --check` and final `lwpt format --check`: passed.

The synthetic integration check requires macOS, the installed FPC toolchain,
FFmpeg/ffprobe, Python 3 and ripgrep. It compiles the temporary harness through
`fpc @lwpt.cfg`, uses a private temporary directory, and removes its fixtures.
It does not add runtime dependencies to Knips.

## Remaining validation and limits

The shell-launched release probe was denied Screen Recording access; subsequent
GUI-launched captures succeeded. Real keyboard and mouse selection, capture,
playback in Knips, and changing Follow Mouse framing were exercised. The release
probe, QuickTime playback, replacement of an existing real take, killed-recording
recovery, keypad Enter, and docked-camera coordination remain on-device checks in
[the runtime spike](../spikes/0001-runtime-objc-class.md#audit-remediation-device-checks-2026-09-09).
The Docker daemon was unavailable, so Linux/Windows execution was not performed;
the Windows file-handle declarations were checked against FPC 3.2.2 sources.

Movie and sidecar publication are separate filesystem operations. A sidecar
publication failure keeps the completed movie, retains its pending metadata,
reports the error and prevents app auto-rendering with old metadata. They are
not a transaction across two files; a crash between those publications can
require manual metadata repair. Recoverable failed recording fragments remain
under their separate recording name and never overwrite the previous take.

## Computer Use follow-up

The audit build was bundled and signed with `tools/make-app.sh`, then
launched through Computer Use using its full worktree application path.
Computer Use could inspect Finder and System Settings, but repeatedly timed
out when requesting app state for both the audit and installed copies of
Knips. A subsequent [controlled diagnosis](2026-09-09-computer-use-diagnosis.md)
reproduced the timeout in a minimal accessory app: inspection succeeds with
an ordinary window, then fails after closing it while the process remains
alive. The internal service stage remains unknown.
The copies share `org.knips.app`, so the full path is required to
select the audit build. Computer Use refused Terminal access for safety
reasons; that UI fallback was not used.

The bundled release `probe` registered the capture, overlay, camera and
playback runtime classes and checked the global stop hotkey, then exited 2
at ScreenCaptureKit enumeration: “The user declined TCCs for application,
window, display capture.” System Settings showed Knips screen-recording
access enabled, so the shell-launched probe's effective authorization does
not establish the authorization of the GUI-launched app.

Real region-selection and recording checks subsequently succeeded through
a temporary copy of the audit build that opens the existing Record Region
action at startup and stops captures after five seconds. Computer Use tested
movement, resizing, fine adjustment, display switching, Escape, Return and
mouse dragging. Two captures produced playable raw/rendered movies and
sidecars; live Follow Mouse framing changed during capture. The
[diagnosis follow-up](2026-09-09-computer-use-diagnosis.md#follow-up-a-test-build-unlocks-real-ui-checks)
records the evidence and remaining checks. Opening the idle status menu
through Computer Use remains blocked.

A repeat app-state call returned server error `-10005: timeoutReached` after
5.576 seconds. A one-second `sample` of the audit process showed the main
thread waiting in the normal AppKit event loop, with no observed application
deadlock. The available tool documentation does not establish which app-state
stage times out (app/window discovery, accessibility, or screenshot capture).
OpenAI's Computer Use documentation confirms desktop testing is supported and
Terminal automation is intentionally unavailable:
https://learn.chatgpt.com/docs/computer-use.

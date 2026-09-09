# Computer Use: get_app_state times out for a windowless accessory app

Status: submitted by the user on 2026-09-09 (user confirmation; no submission
identifier supplied).

Observed 2026-09-09 on macOS 26.5.2, Apple silicon, two displays.
Codex app 26.901.51231 (8109); Computer Use service 26.831.1000926 (1000926).
API: `@oai/sky` through the supported Node REPL.

## Reproduction

1. Launch a minimal AppKit application with accessory activation policy,
   a status item, and one ordinary visible window.
2. Call `sky.get_app_state({app: fullBundlePath})`: UI tree and screenshot
   succeed in approximately 0.99 seconds.
3. Close its only window using `sky.click`, leaving the status item and
   application process running.
4. Call `get_app_state` again: consistently fails after approximately
   5.1 seconds with `Computer Use server error -10005: timeoutReached`.
5. Confirm the same process is still alive. A cold launch with only the
   status item also fails (5.41 seconds).

The REPL has a 30-second timeout, so the five-second deadline is internal
to the Computer Use operation. The minimal app uses a unique bundle ID.
The accessory policy is identical in passing and failing states. Finder
continues to work. No OS permission changes are needed between states.

The issue also blocks a real menu-bar recorder, Knips. Direct `press_key`
is refused because the initial `get_app_state` has not succeeded, so the
agent cannot bootstrap interaction with the status menu. Sampling Knips
showed its main thread waiting normally in the AppKit event loop.

## Expected behavior

Return accessible status-menu controls for a running app without an
ordinary window, or expose a supported way to inspect and click its
status item. If that state is unsupported, return an actionable error
instead of a generic timeout.

## Impact and workaround

Autonomous QA cannot start from an idle menu-bar app. A temporary Knips
build that invokes its existing region-selection action at startup works:
Computer Use can inspect its borderless overlay, send keys, drag a region,
start real recording and operate playback. Thus a usable window resolves
the observed blockage; the internal service stage remains unidentified.

A minimal Pascal/AppKit reproducer and full timings are available locally
in `repro/computer-use-window-probe.pas` and
`2026-09-09-computer-use-diagnosis.md`. This feedback text contains no
recordings, screenshots, credentials or user filesystem paths.

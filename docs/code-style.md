# Code style

## Executive Summary

- Delphi mode via `source/Knips.inc`; style enforced by `lwpt format`.
- Namespaced units (`Knips.<Layer>.<Name>.pas`), flat under `source/`;
  tests co-located as `*.Test.pas`.
- A unit that declares framework bindings adds `{$modeswitch objectivec2}`
  / `cblocks` / `cvar` under `{$IFDEF DARWIN}` and compiles to an empty
  shell elsewhere; a unit that does not declare any has no modeswitch at
  all, whatever its name suggests.
- `source/capture/**` is vendored, unrestyled, and exempt from the
  formatter; additions go in marked blocks.
- Capture-queue code follows the no-exception / no-WriteLn / no-managed
  rules ([docs/architecture.md](architecture.md)).

## Baseline

The stack's conventions (naming — `T`/`F`/`A` prefixes, PascalCase, no
abbreviations; `const` params by default; minimal public API; uses-clause
grouping) apply as written in the `native-nostalgia-stack` skill and are
enforced by `lwpt format` where mechanical. The formatter also renames
parameters of locally declared Objective-C bindings to `A`-prefixed
PascalCase; the `message 'selector:'` clause is what binds them, so the
Pascal identifier is free.

Do not put `//` comments *inside* a uses-clause: lwpt 0.7.0's formatter
desynchronises on them and rewrites the whole file into garbage on the
next `lwpt format` (the `--check` mode only reports "needs formatting",
so the damage lands silently later — see docs/ports.md, "how they were
fixed", for the incident). Comment above the clause instead.

## Compiler mode and modeswitches

- Default: `{$mode delphi}{$H+}` from `source/Knips.inc`.
- A unit enables a modeswitch **because it declares framework bindings**,
  not because of the layer its name puts it in. `objectivec2` is for
  calling `objcclass external` bindings, `cblocks` for passing a global
  `cdecl` procedure where a framework wants a completion block, and `cvar`
  for `NSString` constants declared `cvar; external`. All three sit inside
  `{$IFDEF DARWIN}` so the same unit compiles as an empty shell on Linux
  and `lwpt test` stays cross-platform.

  That splits the tree in a way worth stating, because the layer names do
  not: **every `Knips.App.*` unit below the state machine** talks to AppKit
  and takes `objectivec2`; so do both `Knips.Capture.*` units under
  `source/`, `Knips.Recording` and `Knips.Recording.CursorOverlay`,
  `Knips.Recording.Recovery`, and the `Knips.Export.*` units that touch
  AVFoundation — `MovieWriter`, `MovieReader`, `MovieTrim`, `Pipeline`,
  `Render`, `CursorEffect`. Everything else in `Knips.Export.*` is
  platform-neutral and has **no modeswitch at all**: `Bitmap`, `Gif`,
  `Apng`, `Timing`, `Cadence`, `ZoomTrack`, `SizeEstimate`. So are
  `Knips.Options`, `Knips.App.State`, `Knips.Mcp.Params`, the
  `Knips.Recording.*Math` pair, `Knips.Recording.Heartbeat` and
  `Knips.Recording.Sidecar` — which is what lets `lwpt test` run their
  suites on Linux. `Knips.Mcp` has none either: it reaches the Darwin
  session classes but declares no bindings of its own, and refuses capture
  in-band off Darwin rather than disappearing.
- **`Knips.ObjC.Runtime` is not in that first list, and that is the point.**
  It builds Objective-C classes through the runtime C API in the RTL's
  `objc` unit, so it needs no ObjC language mode of its own
  ([ADR-0002](adr/0002-runtime-built-objc-classes.md)); a modeswitch there
  would be the first step back towards the `objcclass` metadata that costs
  the build `-ld_classic`.
- The vendored units keep whatever they arrived with:
  `Knips.Capture.ScreenCaptureKit` has `objectivec2` and `cblocks`,
  `Knips.Capture.CoreMedia` has `objectivec1`, and the pthread mutex has
  none. They are not restyled to match the rest, on purpose
  ([ADR-0003](adr/0003-vendor-capture-units.md)).
- The program is *not* in ObjC mode; it takes `id` from the RTL's `objc`
  unit for the probe.

## Objective-C binding conventions

Verified against FPC 3.2.2's own headers (`univint`, `cocoaint`):

| Thing | Declare as | Example |
| --- | --- | --- |
| C function | `external name '_Symbol'` (explicit underscore) | `CMSampleBufferGetPresentationTimeStamp` |
| CF key constant | `var X: CFStringRef; external name '_X';` | `SCStreamFrameInfoStatus` |
| NSString constant | `var X: NSString; cvar; external;` | `AVFileTypeMPEG4` |
| Class | `X = objcclass external (NSObject) … end;` | `AVAssetWriter` |
| Completion block param | `reference to procedure(…); cdecl; cblock;` and pass a global `cdecl` procedure by name (no `@` in Delphi mode) | `TSCErrorBlock` |
| Protocol key in dictionaries | pass `id(Key)` to `setObject_forKey` | output settings |

Never declare a non-`external` `objcclass`; build the class through
`Knips.ObjC.Runtime` instead ([ADR-0002](adr/0002-runtime-built-objc-classes.md)).

## Vendored code (`source/capture/`)

Carried from lantaarn (itself from the SoftKVM prototype). Units are
renamed into `Knips.Capture.*`; contents stay unrestyled and inline
directives stay where they were, so diffs against lantaarn remain
readable. Additions live under a `knips additions` banner. Excluded
from `lwpt format` via `[format] exclude`. Substantive changes are in
[porting-notes.md](porting-notes.md).

## Threading rules (style-level)

- Anything reachable from `TScreenStream.OnSample` is capture-queue
  code: no `raise`, no `try`, no `WriteLn`, no string/dynamic-array
  writes outside a `TPThreadMutex`.
- Framework completion handlers are global `cdecl` procedures that only
  set globals; the main thread reads them after pumping the run loop.
- Stop the stream before finishing the writer, always.

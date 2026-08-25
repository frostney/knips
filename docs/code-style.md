# Code style

## Executive Summary

- Delphi mode via `source/Shared.inc`; style enforced by `lwpt format`.
- Namespaced units (`Opname.<Layer>.<Name>.pas`), flat under `source/`;
  tests co-located as `*.Test.pas`.
- Darwin units add `{$modeswitch objectivec2}` / `cblocks` / `cvar`
  under `{$IFDEF DARWIN}` and compile to empty shells elsewhere.
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

## Compiler mode and modeswitches

- Default: `{$mode delphi}{$H+}` from `source/Shared.inc`.
- Darwin units (`Opname.Capture.*`, `Opname.Export.*`,
  `Opname.Recording`, `Opname.ObjC.Runtime`) enable `objectivec2` (to
  call `objcclass external` bindings), `cblocks` (to pass a global
  `cdecl` procedure where a framework wants a completion block), and
  `cvar` (for `NSString` constants declared `cvar; external`). These sit
  inside `{$IFDEF DARWIN}` so the same unit compiles as an empty shell on
  Linux and `lwpt test` stays cross-platform.
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
`Opname.ObjC.Runtime` instead ([ADR-0002](adr/0002-runtime-built-objc-classes.md)).

## Vendored code (`source/capture/`)

Carried from lantaarn (itself from the SoftKVM prototype). Units are
renamed into `Opname.Capture.*`; contents stay unrestyled and inline
directives stay where they were, so diffs against lantaarn remain
readable. Additions live under an `opname additions` banner. Excluded
from `lwpt format` via `[format] exclude`. Substantive changes are in
[porting-notes.md](porting-notes.md).

## Threading rules (style-level)

- Anything reachable from `TScreenStream.OnSample` is capture-queue
  code: no `raise`, no `try`, no `WriteLn`, no string/dynamic-array
  writes outside a `TPThreadMutex`.
- Framework completion handlers are global `cdecl` procedures that only
  set globals; the main thread reads them after pumping the run loop.
- Stop the stream before finishing the writer, always.

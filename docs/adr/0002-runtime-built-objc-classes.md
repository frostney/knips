# ADR-0002: Objective-C classes built through the runtime API

## Status

Accepted and **proven on device** (2026-08-26, Apple silicon, stock
linker, flag-free build): `probe` passed all four checks and a
real region recording produced a playable file with matching frame
statistics — spike 0001's three gates are closed. This is the project's
load-bearing decision.

## Context

ScreenCaptureKit delivers frames to an object implementing
`SCStreamOutput`; a menu bar and a region overlay (later milestones)
need `NSApplication` delegates and views. The natural FPC way is a
`{$modeswitch objectivec2}` `objcclass` subclass of `NSObject`. But FPC
generates Objective-C method-list metadata for such a class, and the
current Apple linker (ld-prime, Xcode 15+) rejects that metadata —
`malformed method list atom` — unless the whole link uses `-ld_classic`.
lantaarn documented exactly this and dodged it by keeping ScreenCaptureKit
out of its default build. Knips cannot dodge it: SCK is the product.

lwpt 0.7.0 can pass `-k-ld_classic` per build entry, so a flagged build
is possible. But `-ld_classic` is the old linker; Apple has signalled its
removal, and hanging the only build of a new project on a deprecated
linker flag is a standing liability, not a fix.

## Decision

Build every Objective-C class Knips defines through libobjc's C runtime
API — `objc_allocateClassPair`, `class_addIvar`, `class_addMethod`,
`class_addProtocol`, `objc_registerClassPair` — with plain `cdecl` Pascal
routines as method bodies. Those runtime functions are already bound in
FPC 3.2.2's RTL `objc` unit (verified in `rtl/inc/objcnf.inc`). A class
assembled this way carries no compiler-emitted method-list metadata, so
the default build links with the stock linker and no flags.
`objcclass` is still used, but only as `external` bindings for framework
classes, which emit no such metadata.

`Knips.ObjC.Runtime` is the primitive (a `TRuntimeClassBuilder` plus
instance helpers); `Knips.ObjC.TypeEncoding` supplies method type
encodings so they are never hand-typed. `knips probe` registers and
exercises the first such class as the on-device gate.

## Consequences

- The default build entry never carries linker flags; that is an AGENTS.md
  hard constraint and a DoD item.
- Method bodies are free functions with an explicit `(self, _cmd, …)`
  signature and a type-encoding string; a wrong encoding corrupts message
  forwarding, which is why the encoding is generated and unit-tested.
- Ivars hold back-pointers to the owning Pascal object
  (`object_setInstanceVariable`); the owner is cleared before the ObjC
  instance is released so late callbacks find `nil`.
- The pattern scales to the menu bar and overlay: more selectors on more
  runtime-built classes, same primitive, still no metadata.
- Escape hatch retained but quarantined: a `-k-ld_classic` second build
  entry is documented in `docs/tooling.md` for the event that some future
  dependency emits the metadata anyway. It is never the default and never
  committed, because it breaks the Linux `lwpt build` and CI.
- Unverified until run on Apple silicon: that a runtime-registered class
  satisfies SCK's `addStreamOutput:` (SCK dispatches by selector, so
  protocol conformance should be cosmetic, but this is asserted, not
  proven). Tracked in the spike.

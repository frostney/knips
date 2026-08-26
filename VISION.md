# Vision

## Mission

Knips is the screen recorder Kap was — a menu-bar tool that records a
region, a window, or a display and hands you a small, shareable file —
rebuilt native: one FreePascal binary, ScreenCaptureKit in, hardware
H.264 out, no Electron, no runtime, no plugins process. It should feel
instant to start, produce files people can drop into a pull request or a
chat, and stay small enough that one person keeps it healthy.

## Product direction

Knips is a **member of the lwpt ecosystem**: built, tested, and
formatted through lwpt, consuming lwpt's `cli` and `testing` packages the
way duetto and lantaarn do, and vendoring lantaarn's capture bindings
rather than a second copy of the framework surface.

The architecture holds one invariant above the rest: **the default build
is linker-flag-free.** Every Objective-C object the frameworks need to
call back into is built through the runtime API
([ADR-0002](docs/adr/0002-runtime-built-objc-classes.md)), so the menu
bar, the region overlay, and the stream output all share one primitive
and none of them drags `-ld_classic` into the build.

### Milestones

1. **Headless recorder** (this release): `knips record` to `.mp4`/`.mov`
   from a display, region, or window; ScreenCaptureKit → AVAssetWriter;
   `probe` as the toolchain gate.
2. **Menu bar + region overlay:** the Kap gesture — click the icon, drag
   a rectangle, record, click to stop. Cocoa through the same runtime-class
   primitive. Pause on Option-click. *Landed as `knips app`, except
   Option-click pause.*
3. **Exports:** GIF (Kap's signature output; palette + LZW in pure
   Pascal, testable on Linux), APNG, WebM via a post-process step; trim
   before export. *GIF, APNG and trim have landed as `knips export` —
   including a passthrough movie trim that never re-encodes; WebM has
   not.*
4. **Audio:** system audio and microphone as a second AVAssetWriter input
   (SCK already delivers system audio buffers). *System audio landed as
   `record --audio=system`; microphone (SCK's macOS 15 output type) has
   not.*
5. **Polish:** highlight clicks, keystroke overlay, Retina toggle, share
   destinations.

### Reachability and trust

A recorder writes files; it needs Screen Recording permission and nothing
else. Knips never listens on a port and never injects input.

## What Knips is not

- **Not a remote desktop** — lantaarn is. Knips shares its capture
  bindings, not its server.
- **Not a plugin host.** Kap's plugin ecosystem was its most fragile part;
  exports are built in, in Pascal.
- **Not cross-platform in this release.** ScreenCaptureKit and
  AVAssetWriter are the whole point; a Windows path
  (Windows.Graphics.Capture + Media Foundation) would be a parallel
  implementation behind the same `Knips.Options`, not an abstraction
  layered on top of macOS.
- **Not an editor.** Trim and export, no timeline.

## Related documents

- [Architecture](docs/architecture.md)
- [ADRs](docs/adr/)
- [CONTEXT.md](CONTEXT.md) — ubiquitous language
- [AGENTS.md](AGENTS.md) — hard constraints

## Grounding

Direction-shaping facts were verified against sources (August 2026), not
memory:

- Kap's interaction model (menu-bar icon → select portion → record →
  click again to stop; Option-click to pause) —
  [wulkano/Kap README](https://github.com/wulkano/Kap)
- FPC 3.2.2's `objc` runtime unit exposes `objc_allocateClassPair`,
  `class_addMethod`, `class_addIvar`, `class_addProtocol`,
  `object_setInstanceVariable` — `rtl/inc/objcnf.inc` in
  [FPCSource release_3_2_2](https://github.com/fpc/FPCSource/tree/release_3_2_2)
- Cocoa method names used (`fileURLWithPath`, `dictionaryWithCapacity`,
  `setObject_forKey`, `numberWithInt`, `numberWithBool`) and the
  `cvar; external` convention for NSString constants — FPC `cocoaint`
- CoreGraphics display-mode functions (`CGDisplayCopyDisplayMode`,
  `CGDisplayModeGetPixelWidth`) — FPC `univint/CGDirectDisplay.pas`
- lwpt 0.7.0 per-entry `flags` (the `-k-ld_classic` escape hatch) —
  [lwpt docs/build-system.md](https://github.com/frostney/lwpt/blob/main/docs/build-system.md)

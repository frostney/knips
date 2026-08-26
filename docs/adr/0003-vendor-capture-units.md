# ADR-0003: Vendor lantaarn's capture units rather than share a package

## Status

Accepted.

## Context

Knips and lantaarn need the same low-level bindings: the
CoreMedia/CoreVideo/VideoToolbox/GCD externals, the ScreenCaptureKit
class declarations, and the no-cthreads pthread mutex. Options: (a)
extract a shared `capture` lwpt package both consume, (b) vendor the
units into Knips, (c) build Knips as a second binary inside lantaarn.

## Decision

Vendor the units into `source/capture/`, renamed `Knips.Capture.*`,
excluded from the formatter, with Knips's additions in marked blocks —
the same treatment lantaarn gave the SoftKVM prototype.

## Consequences

- Knips and lantaarn evolve independently: Knips strips the encoders
  and the FPC-defined handler, adds region/window/frame-status bindings,
  and changes timestamp semantics — divergence a shared package would
  have to absorb as configuration.
- The cost is drift: a fix in one repo's CoreMedia bindings is not
  automatically the other's. Accepted because the surface is small and
  the two projects pull it in opposite directions (streaming vs file).
- If a third consumer appears, revisit extraction — at which point the
  shared package's contract is informed by two real divergent users
  rather than guessed from one.
- `source/capture/**` staying formatter-exempt keeps diffs against
  lantaarn readable, so a genuinely shared fix can still be cherry-picked
  by hand.

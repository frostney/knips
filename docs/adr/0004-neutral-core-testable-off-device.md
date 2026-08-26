# ADR-0004: Platform-neutral core, testable off-device

## Status

Accepted.

## Context

The Darwin units cannot run in CI without a Mac, and FPC on Linux will
not even parse Objective-C mode. Left unmanaged, that pushes all logic
into untestable macOS code and makes every change a device round-trip.

## Decision

Keep everything that does not call a framework in platform-neutral units
with co-located `*.Test.pas` suites: the option model and validation
(`Knips.Options`), the derived geometry maths (alignment, scale, bit
rate), and the Objective-C method type encodings
(`Knips.ObjC.TypeEncoding`). These run under `lwpt test` on any OS.
Darwin units depend on them but add only framework glue.

## Consequences

- Option parsing, region validation, container selection, and encoding
  strings have real regression coverage that runs in Linux CI.
- The macOS gate shrinks to what only a Mac can answer: does the runtime
  class register, does SCK enumerate and stream, does the file play. That
  is `knips probe` plus one recording, not a full manual matrix.
- New logic is written neutral-first by default; reaching for a framework
  call is the signal to check whether the decision could live in a tested
  unit instead. Geometry is the worked example — SCK is asked only for
  sizes, and the pixel maths is tested without it.

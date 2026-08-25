# Definition of Done

A change is shippable only when every applicable item holds.

- `lwpt format --check`, `lwpt build`, and `lwpt test` exit zero.
- Platform-neutral code has co-located `*.Test.pas` coverage of its
  public surface.
- Darwin changes have been exercised on a Mac: `opname probe` passes and
  a recording produced by the change plays in QuickTime Player at the
  expected size, rate, and duration.
- Anything that could not be verified on hardware is listed in the
  relevant `docs/spikes/` entry, not silently assumed.
- The affected `docs/` file is updated (one authoritative document per
  topic); new decisions get a new ADR, existing ADRs are not rewritten.
- No linker flags were added to the default build entry.
- `CHANGELOG.md` is regenerated from conventional commits (`cliff.toml`).

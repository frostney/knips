# Definition of Done

A change is shippable only when every applicable item holds.

- `lwpt format --check`, `lwpt build`, and `lwpt test` exit zero.
- `lwpt build --mode release` exits zero and the release binary passes
  `knips probe` (release turns on -O4's field reordering, which dev
  builds never exercise — an alignment bug it exposed shipped
  crash-free in dev mode from the first on-device commit).
- Platform-neutral code has co-located `*.Test.pas` coverage of its
  public surface.
- Darwin changes have been exercised on a Mac: `knips probe` passes and
  a recording produced by the change plays in QuickTime Player at the
  expected size, rate, and duration.
- Anything that could not be verified on hardware is listed in the
  relevant `docs/spikes/` entry, not silently assumed.
- The affected `docs/` file is updated (one authoritative document per
  topic); new decisions get a new ADR, existing ADRs are not rewritten.
- No linker flags were added to the default build entry.
- `CHANGELOG.md` carries an entry for the change. It is **hand-maintained**
  — curated prose under `## [Unreleased]`, written for someone deciding
  whether they want the change, not a transcription of commit subjects.
  (`cliff.toml` is kept for the release-tagging step and is not what
  produces the entries above.)

# Definition of Done

A change is shippable only when every applicable item holds.

- **`tools/release-gate.sh` exits zero.** That is this list's first six
  items, in order and in one command: `lwpt format --check`, `lwpt
  build`, `lwpt test`, `lwpt agents --check`, `lwpt build --mode
  release`, and `knips probe` against the release binary — release turns
  on -O4's field reordering, which dev builds never exercise, and an
  alignment bug it exposed shipped crash-free in dev mode from the first
  on-device commit. Off a Mac, or without Screen Recording permission,
  `--no-probe` runs the four that do not need one.

  **The run leaves `build/knips` a release binary**; `lwpt build` puts
  the dev one back, and the script says so on the way out.

  The first four also run as the `pre-push` hook, which is installed by
  `lefthook install` and is the only automation this repository has —
  there is no CI service (docs/tooling.md).
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
  Nothing generates it: there was a `cliff.toml` here, carried in from
  lantaarn, naming that project and configured to overwrite this file
  from commit subjects. It has been deleted.

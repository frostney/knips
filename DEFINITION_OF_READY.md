# Definition of Ready

An idea or issue may start implementation only when every applicable
item holds.

- **Scope is one milestone step** from [VISION.md](VISION.md) or a bug
  with a reproduction (`knips` invocation + observed vs expected).
- **The layer is named**: options, ObjC runtime, capture, export,
  recording, or CLI (see [AGENTS.md](AGENTS.md) code organization).
- **Framework facts are sourced.** Any new Apple API is cited to FPC's
  `univint`/`cocoaint` bindings or Apple's headers, with the minimum
  macOS version noted.
- **The verification path is stated**: a `*.Test.pas` suite for neutral
  code; `knips probe` plus a real recording for Darwin code.
- **It does not add linker flags to the default build entry** — or it
  is explicitly an ADR proposing to change that invariant.
- **Vendored-unit changes are additive** (marked block) or documented in
  [docs/porting-notes.md](docs/porting-notes.md).

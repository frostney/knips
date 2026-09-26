# Changelog

All notable changes to this project are documented here. Hand-maintained:
entries are written for someone deciding whether they want the change,
not transcribed from commit subjects. Nothing generates it — there was a
`cliff.toml` in this repository, carried in from lantaarn, which named
that project and was configured to overwrite this file from commit
subjects; it has been deleted.

The section vocabulary is [Keep a
Changelog](https://keepachangelog.com/en/1.1.0/)'s: **Added**,
**Changed**, **Fixed**, in that order.

## [Unreleased]

### Added

- Region selection works from the keyboard: arrows move, Shift resizes,
  Option makes fine adjustments, Tab changes displays, Return confirms
  and Escape cancels. The overlay shows the controls.

- **A sidecar cannot point recovery at a movie outside its own
  directory.** The event sidecar's `movie` field was documented as a
  bare file name and never checked: a sidecar planted in a recording
  directory naming `../B/victim.mp4` made the next `knips record` (and
  the app at launch) re-mux and replace a movie one directory up. The
  reader now states the rule in code (`SidecarMovieNameIsBare`), the
  recovery pass refuses such a name and a movie path that is a
  symbolic link, and a take it will not act on is left exactly as
  found — sidecar included, so a planted file cannot switch recovery
  off for the name it carries. A backslash stays legal in a macOS file
  name and is not refused.
- **A rendered deliverable is encoded with the recorder's own bit-rate
  budget.** The render pass configured its H.264 writer from the raw
  take's average frame rate, which on a still-screen take carried by the
  idle heartbeat is a few frames per second: the budget fell to the
  1 Mbit/s floor and keyframes landed every twenty frames while the
  render filled in thirty frames a second of zoom and pointer motion.
  It now takes the take's configured rate from the sidecar header,
  through the one settings builder the recorder uses, so a
  1280×720 @ 30 fps deliverable gets 2.49 Mbit/s and a keyframe every
  four seconds, exactly like the take it came from.
- `knips render --effects=none` copies the take in megabyte chunks, so
  a Ctrl-C is honoured within a megabyte rather than after the whole
  copy — and a short read fails the copy instead of quietly committing
  a truncated deliverable, which the whole-file copy could.
- **The release runbook is the Definition of Done.** `docs/deployment.md`
  said to run git-cliff over a changelog that is hand-maintained by
  rule; it now says to bump both version numbers, close this section
  by hand, run `tools/release-gate.sh` and tag. The last three
  statements implying a CI service runs the gates are gone.
- **The camera dock and its ride left the app controller.**
  `Knips.App.pas` was 4,500 lines and the tree's most complex unit by a
  wide margin; the camera dock, the composited window recording and the
  poll that keeps both on a moving window are `Knips.App.CameraRide`
  now, owned by the controller and reached back through six questions.
  A structural move with no behaviour change; the recording lifecycle
  was measured for the same treatment and left in place because it
  shares some forty controller members rather than six.
- The MP4 render and the GIF/APNG pipeline answer "what does this frame
  show, and what crop does the zoom come to" through one pair of
  neutral, tested functions instead of a copy each, so the frame
  synthesis can no longer disagree with the draw. Five copies of "bytes
  on disk" are one helper; the two animation-export MCP tools are
  registered through one; `tools/list` is byte-identical.
- **`docs/architecture.md` describes the current design; its superseded
  measurements moved to `docs/measurements.md`.** The architecture
  document had grown to 3,400 lines, a third of them narrating what a
  number used to be. Every current constant, decision and figure stays
  where it was, every heading anchor still resolves, and the history is
  an appendix linked both ways.

- **Every file knips replaces is now replaced atomically, and a Ctrl-C
  cannot cost you the one you already had.** The MP4 render already
  built into a neighbour and renamed it into place; the GIF and APNG
  exports and the passthrough trim did not — the export opened its sink
  on your output path (a GIF's second pass truncated a perfectly good
  animation before it encoded a frame) and the trim deleted your movie
  before asking AVFoundation for a new one. All four share one
  implementation now, and `export`, `render` and `export --trim` install
  the stop-signal handler `record` had, poll it between frames, and fail
  cleanly: the scratch is swept, the previous file is byte-for-byte
  where it was, and the exit code is non-zero.
- **A symbolic link at `--out` is refused by name.** It used to mean two
  different disasters depending on the writer: `export` opened the path
  and destroyed whatever the link pointed at while reporting success
  against the link's own name, and `render` renamed over the link and
  replaced it. One policy for `record`, `render`, `export` and the trim,
  on the command line and over MCP.
- `tools/release-gate.sh` runs the Definition of Done's six gates in
  order — the pre-push four plus the release build and its probe — and
  `lefthook.yml` gained the pre-push hook that was described in three
  documents and existed in none of them: `lwpt format --check`, `lwpt
  build`, `lwpt test`, `lwpt agents --check`, about a minute. There is no
  CI service behind this repository and the documentation no longer
  implies there is. The gate says on its way out that it has left
  `build/knips` a release binary.
- **`take_info`, `render` and the two exports report
  `sidecar_skipped_lines`**, and `knips render` / `knips export` print
  the same sentence when it is not zero. The sidecar reader is
  deliberately tolerant — a truncated tail, a number that is not finite,
  a stamp that does not advance are all skipped rather than fatal — and
  until now the count of what it threw away was reachable only from
  inside the loader. A pointer track with holes in it still renders; it
  renders thinner than the file looks, and that is now something a
  person and an agent can both see.
- `knips probe --blur-cost` measures the camera background blur, which
  is no longer measured on every probe: it gates nothing and was a large
  share of the probe's wall time. The measurement now reports the
  ACHIEVED frame rate beside the arithmetic one.

- **An agent can record a take it can still change its mind about.** The
  MCP server had been frozen at the era before raw takes: it could record
  and it could export, but `record_start` had no way to ask for a
  cursorless take and there was no `render` tool at all — so every
  recording an agent made had the pointer baked into its pixels, for
  good, and the promise that an MCP tool and a subcommand are one
  implementation was true of everything except the one pass that decides
  what a recording looks like.

  `record_start` now takes `smooth_cursor`, `render` is a tool running
  the same `TRenderSession` `knips render` runs, and `render`,
  `export_gif` and `export_apng` take `zoom` and `cursor` — two flat
  arguments rather than the CLI's comma-separated list, because the SDK
  validates flat scalars per call and a nested object would cost the
  whole tool its argument checking. A new read-only `take_info` answers
  the question an agent should ask before any of it: what is this movie,
  what is already in its pixels, which effects can it still be given, and
  where would a render write. `record_stop` now names the take's sidecar,
  the samples that reached it, and that path — but does **not** render:
  the menu-bar app renders on every stop because a person clicked once
  and wants a file, while an agent wants a cheap predictable stop and a
  separate call it chose the effects for.

  The honest part. Nothing runs in this server between tool calls, so a
  raw take's pointer track is exactly as dense as the client's polling —
  one sample at the start, one per `record_status`, one at the stop — and
  a smooth cursor drawn from three samples is a straight line, not a
  smooth cursor. There is no handshake in which a client could promise to
  poll, so `record_start` says so every time `smooth_cursor` is on rather
  than waiting for a promise it can never be given; `record_stop` reports
  the samples that actually arrived, and `take_info` reports the largest
  silence in the track beside the largest one a reader will draw through.
  Measured on a take polled three times: 5 samples, a 1.01 s largest gap
  against a 0.50 s interpolation limit — which is precisely the case
  where the drawn pointer holds still rather than gliding through a
  minute that never happened.

  Also: `render` refuses an existing output unless `overwrite` is set,
  where the command line replaces it. That is the one writer whose CLI
  half deliberately overwrites — the app renders over the deliverable on
  every stop — and it is right there and wrong for a path an agent
  guessed, so the server's own no-silent-replacement rule wins. The check
  runs before the decode, so a refused render costs nothing. `render`
  also refuses `fps`/`width`/`dither` and `trim_start`/`trim_end` — it
  re-encodes the take at the take's own size, rate and length, and the
  SDK drops undeclared arguments silently, so a client asking for a
  scaled render would have got a full-size movie and no hint. Each
  refusal names the tool that can do the thing.

### Changed

- CodeRabbit no longer reviews the Agent Skills vendored from upstream
  (the ones `skills-lock.json` lists); project-authored skills under
  `.agents/skills` are still reviewed. See `docs/tooling.md`.
- Removed unused live Zoom on Click machinery. Follow Mouse remains live;
  Zoom on Click still runs when rendering the recorded take.

- **The project is MIT-licensed.** A `LICENSE` file carries the terms and
  the README links to it; the line calling Knips a private candidate is
  gone.
- **One arrow-sprite renderer.** The recording's Big Cursor and the
  render's drawn pointer each held a copy of the same Quartz routine —
  75 of 96 lines identical, every error string included. Both now call
  `Knips.Recording.CursorSprite`, which sits below the two of them; the
  sprite metrics and the exported pixels are unchanged (the same raw
  take exports byte-identical APNGs before and after), and neither
  caller declares a framework binding any more.
- **The GIF and APNG export's slot walk is one tested record.** The
  decimation, the per-gap fill bound and the "is this a different
  picture" test moved out of the pipeline into `Knips.Export.Cadence`,
  where both passes drive them and a co-located suite covers them on
  every host. One side effect worth knowing: on a take that can
  synthesise frames, the GIF's palette pass now seeds its sample
  schedule from the grid-slot count rather than the source-frame count,
  which is what the estimate always meant; measured, the palette is
  within a tenth of a decibel of the old one.
- The GIF and APNG test suites remove the pid-named scratch directory
  they create under `$TMPDIR`; each run used to leave two empty ones
  behind.
- `docs/quick-start.md` no longer repeats `docs/architecture.md`
  verbatim: eleven passages of reasoning became one clause and a link to
  the section that owns it, and the how-to sentences stayed.

- GIF palettes are built from an **exact-colour** histogram (a bounded
  hash table of packed 24-bit colours, with the old 6-bit histogram kept
  as the fallback past 2^20 distinct colours), median cut now splits the
  box holding the most squared error, and nearest-colour lookups are
  exact and memoised on the colour itself rather than answered per 6-bit
  cell. On a 14 s 800×520 screen recording the dithered GIF went from
  14.4 MB / 38.17 dB to 1.79 MB / 41.48 dB at unchanged encoding time —
  8.1× smaller and 3.3 dB closer, against 1.30 MB / 42.50 dB for
  ffmpeg's `palettegen`.
- Frame delays are snapped to the decimation grid before being rounded,
  so a 30 fps source exported at 20 fps gets a steady `5,5,5,…` instead
  of `7,3,7,3,…`, while the total playback length stays on the source's
  own (`Knips.Export.Timing`, tested). An idle gap longer than a two-byte
  delay field can express is emitted at the ceiling with the remainder
  forgiven rather than owed, so the frames *after* a very long pause keep
  their true delays instead of being held at the maximum one by one.
- `displays`, `windows`, and `probe` subcommands.
- Runtime-built Objective-C classes (`Knips.ObjC.Runtime`) keeping the
  default build linker-flag-free.

### Fixed

- Failed recordings preserve the previous movie and event sidecar.
  Recording fragments stay under a separate recoverable name until the
  movie finishes; sidecar publication failure reports partial success.
- Concurrent exports and renders reserve separate temporary names and
  never sweep each other's active work. Recovery no longer deletes a
  neighbouring `.recovering.mp4` file.
- Sidecar creation and recovery append refuse symbolic links in the file
  open itself. Rendering refuses input/output names that share metadata,
  and CLI, MCP and app diagnostics report failed sidecar writes.

- **The GIF palette pass emitted a frame the file never held.** On the
  GIF path the target size was learned inside the first walk, so the
  first source frame's shape was never recorded and the first empty
  slot was filled unconditionally — one phantom "synthesised" frame on
  a take that cannot synthesise at all, counted by the palette sampler
  and the progress denominator but never written. The size is settled
  before either pass now, a walk on a take that cannot synthesise never
  enters the fill branch, and the palette pass's own count equals the
  encode pass's and the file's at every rate tried.
- **A ScreenCaptureKit query that timed out could answer the next one.**
  `TShareableContent.Query` gave up after its budget but the framework
  still ran the completion later, into whichever query asked next — a
  list a second or more old, plus one leaked retain per timeout. The
  query now marks a completion as outstanding, the next query drains it
  for a bounded number of run-loop slices (about 1.8 s measured) or
  refuses, and any content or error a late completion retained is
  released before a new one is dispatched — the same shape the capture
  start already used.
- `knips render --in=take.mp4` on a movie not named `*-raw.*` said "an
  output path is required", which named the wrong cause; it now says
  the output name cannot be derived from that input and shows the
  `--out` to pass.
- A comment in `Knips.App.State` named a unit that does not exist
  (`Knips.Export.GifPipeline`); it is `Knips.Export.Pipeline`.

- **A sidecar line the reader dropped could silently reframe the rest of
  a take.** `sx/sy/sw/sh` are delta-encoded — the writer emits them only
  on the sample that moves the source rectangle — and the reader carried
  the rectangle forward from the last sample it had ACCEPTED. So a
  record that announced a new rectangle and was then dropped (a stamp
  that does not advance) took its rectangle with it, and every later
  sample reverted to the header's base rectangle. Two sidecars differing
  by one duplicate timestamp rendered to different pictures, with
  nothing but a skipped-line count to say so. The rectangle is carried
  in the reader's own state now, folded in before the stamp rule runs.
- **`export_gif` and `export_apng` emitted six fields their output
  schema never declared** — `palette_colors` (the single biggest fact
  about what a GIF looks like), `exact_palette`, `sampled_frames`,
  `synthesized_frames`, `synthesis_fps`, `unframed_frames`. A client
  validating `structuredContent` strictly rejected a perfectly good
  export; one planning against the schema could not see them at all.
  They are declared and required now, and every structured result the
  server returns is checked against its own tool's schema on the way
  out, so the next payload to outgrow its schema says so on the first
  call rather than at the next audit.
- **`knips render` swept a symlink planted at its temporary path before
  the guard that would have refused it.** No data was lost — the link
  was unlinked, not followed — but the unit promises not to touch a link
  at a path it writes, and this was the one place it did.
- **The menu-bar app's log rotation followed a symlink.** The log is
  opened `O_NOFOLLOW`, and the branch that starts the file over once it
  passes a megabyte reopened it with `FileCreate`, which does not.
- **A movie whose decoder produced a bigger picture than its header
  claimed skipped the canvas budget.** The budget was checked against
  the container's numbers, and the measured picture then overwrote them
  for everything downstream to size its buffers from. It is checked
  again after the measurement, and once more where the render sizes its
  pixel-buffer pool.

- **An export sized its buffers from the movie's header and believed
  it.** An MP4 whose `tkhd` and `avc1` claim 30000x30000 over 800x600
  media is one hex edit from any recording; exporting one reached 6.4 GB
  resident for an APNG and past 7 GB for a GIF, and an 8000x8000 claim
  *succeeded*, writing an "8000x8000" animation out of an 800x600 take.
  There is a canvas budget now, checked in Int64 before a byte is
  reserved and again inside the allocator, and the reader decodes one
  real frame at open rather than taking the header's word for the
  picture. The hostile file is refused in under a tenth of a second with
  a message naming its dimensions.
- **The crash sweep deleted files that were not its business** — an
  ordinary `notes.knips-render-tmp.txt`, and, worse, the temporary of a
  render running in another process. It ran unconditionally at every
  `knips record` and every app launch. It now matches only the three
  shapes a temporary's family takes and leaves any whose owning process
  still answers `kill(pid, 0)`.
- **`knips mcp` leaked memory and file descriptors for the life of the
  process.** No tool handler had an autorelease pool, so every
  AVFoundation factory object each session made was never drained:
  measured at +19.5 MB and exactly +3 open files per
  record → render → export cycle, without bound. Over fifteen cycles the
  server went from 340 MB and 23 open files to 2.3 GB and 65; it now
  stays flat at 20 and does not trend.
- **A pointer track whose timestamps did not advance made a render
  quadratic** — over MCP, on a synchronous server, that is the server.
  The smoothing is linear now and the reader drops a sample whose stamp
  does not advance, as a skipped line. The measured before and after are
  in [docs/event-sidecar.md](docs/event-sidecar.md), *Sampling*, which is
  the one place they are stated.
- **A sidecar was read three times over and parsed twice per render**,
  and `knips export --trim` parsed an entire pointer track to read one
  field of its first line. The reader streams the file, the render lends
  its already-parsed log to the pointer effect, and a header-only load
  exists: on a 63 MB sidecar the trim went from 13.2 s and 461 MB to
  0.06 s and 25 MB.
- **`knips render` on a take it could apply nothing to wrote a
  byte-identical duplicate and reported success.** It asked what the
  take could take in principle rather than what actually applied, so a
  take with one unusable click passed. `--effects=none` (and its MCP
  spelling) still copies, because that is a request.
- A 6K recording at 120 fps was encoded at 1 Mbit/s: the automatic bit
  rate multiplied three Integers before reaching a Double and wrapped
  negative, straight through the low clamp.
- `--display=-5` recorded the main display without a word; a window id
  of 4294967295 was printed and echoed back as `-1`; an out-of-range MCP
  integer came back as `Tool execution failed: Range check error`
  instead of a refusal naming the argument.
- The menu-bar app's log is opened `O_NOFOLLOW`, the probe writes into
  `$TMPDIR` rather than `$TEMP`, and the GIF encoder sizes its frame
  buffers after its bounds check rather than before it.

- **`knips render --out=demo.gif` no longer writes an MP4 called
  demo.gif.** The render pass encodes H.264 into a QuickTime-family
  container and can write nothing else; it used to accept any name at
  all and report success, leaving a file whose extension lied about its
  contents. Both `knips render` and the MCP render tool now refuse the
  path, through one check, in the words the recorder already uses for
  the same mistake.
- **Export advice reached MCP clients still spelled in `--flags`.** A
  large GIF comes back with "consider `--width=800` or `--fps=15`", which
  is exactly the sentence that sends an agent looking for a command line
  it does not have. Every refusal already went through the
  flag-to-argument rewriter; this rode on a *successful* result and did
  not. It does now, along with the Big Cursor idle note on `record_stop`.
- **`knips render` and the MCP render tool no longer describe the same
  work in two copies of the same paragraph.** The four clauses a finished
  render reports — the zoom, the pointer, the frames filled in, the audio
  — plus the "wrote …" line and the two note wrappers were a
  byte-identical 25-line duplicate in each front end. They now come from
  one place in `Knips.Options`, below the Darwin line, with a suite that
  pins the exact sentence: whichever face reports a render, it is the
  same sentence.

- **Recordings of a still screen are no longer nearly empty.**
  ScreenCaptureKit delivers a frame only when the content changes, so a
  take whose screen went quiet used to stop producing frames — and,
  because the movie's timeline is built from the frames' own stamps, the
  movie stopped with it. A 30-second recording of a still screen came out
  as one frame spanning 0.000 seconds; a real 17.5-second take came out as
  4.3 seconds with three of its four clicks past the end of the file.
  Suppressing the pointer for a raw take made it the common case rather
  than an oddity, because moving the mouse then stopped counting as a
  change.

  knips now repeats the last frame twice a second while nothing is
  changing, and once more at the stop, so a take's movie is as long as the
  recording was: the same still screen, recorded by both builds at the same
  moment, gives 58 frames over 29.6 seconds instead of one frame over
  none. Everything downstream inherits it — clicks land inside the movie's
  span so `render --effects=zoom` has frames to zoom, a take killed with
  `SIGKILL` recovers 10.5 seconds where it used to recover 2.0, and a movie
  with sound no longer has an 11-second audio track over a single video
  frame. Takes whose content keeps changing are untouched: the repeat never
  fires while frames are arriving, and a busy recording measured 0 dropped
  and 0 failed appends either way. Costs about 1.7 ms of CPU and 2.6 kB a
  second while idle. A frame that arrives just behind a heartbeat's stamp
  is retimed one tick forward rather than handed to the writer out of
  order (which would end the recording) — the summary's "N frames
  retimed" is that rescue counted. See
  [docs/architecture.md](docs/architecture.md), "The idle heartbeat".
- **The effects animate instead of jumping.** ScreenCaptureKit only
  delivers a frame when the screen changes, and a raw take has no pointer
  in its pixels — so moving the mouse over a still window produced no
  frames at all, and a zoom easing in over 0.30 s could land on a single
  one. Measured on a real 8.1-second take: 152 frames, 18.8 a second
  against a nominal 30, and **one** frame inside the ease. The render now
  fills those gaps in, re-presenting the last captured frame with the
  effect evaluated at the intervening instant — but only where the result
  would be a different picture, so a zoom's hold and a still stretch with
  nothing moving over it cost nothing. Same take, same binary: one frame
  in the ease became **seven**, for 20 % more bytes and 0.35× realtime
  instead of 0.28×. GIF and APNG exports get the same treatment on their
  own frame grid, and one gap can never cost more than a bounded number
  of frames however damaged the movie's stamps are.

  Every figure above was measured against a recorder that stopped
  producing frames when the screen went still. That recorder-side change
  — the idle heartbeat, the entry above — has since landed, and it moves
  both limits this entry used to carry. The tail a static take used to
  lose is no longer lost, so the fill has a frame on both sides of every
  gap it is asked about; and because the capture now keeps a half-second
  cadence of its own, most of the gaps these numbers came from do not
  arise in the first place. What is left for the fill is the sub-second
  work it is actually good at: measured on a still take on the merged
  build, a zoom that had one real frame to land on now animates over
  several, and the fill is invoked only inside the effect windows.
- **A sparse pointer track is no longer drawn through.** Two samples
  minutes apart — which is what an MCP recording produces between tool
  calls — used to be joined with a straight line, so the drawn pointer
  glided smoothly across the screen for a minute of footage nobody
  watched, and the render filled that minute with frames to draw it on.
  The reader now holds the last known position across a silence longer
  than half a second and snaps when the track speaks again. On a
  three-sample fixture the render went from 81 invented frames to 1.
- **Zoom on Click works on a Follow Mouse take.** It used to be refused,
  because the crop was computed against the rectangle the recording was
  *sized* from rather than the one it was *showing*. It is now composed
  inside the framing each sample records — the same base/window/source
  composition the live effects always used — so a click zooms inside
  wherever the pan had got to. Proved at pixel level against a predicted
  crop of the raw frame: SSIM 0.9965, against 0.8636 for the old
  arithmetic. A click the pan has drifted away from is answered as
  closely as the captured rectangle allows rather than refused. Where the
  sample track runs out — a movie can outlast its own sidecar — the
  frames past its end are passed through uncropped rather than zoomed
  against a rectangle the capture had already left, and the render says
  how many.
- **Window recordings take the effects too.** A desktop-independent
  window capture is a picture of something that moves under the recorder
  with no way to find out, so nothing could ever be drawn back into one —
  which is why *Record Window* produced a single movie with the system
  pointer baked in and every effect greyed out. A window recording is now
  captured from the display through a rectangle riding the window, which
  makes it a raw take like any other: Smooth Cursor, Big Cursor and Zoom
  on Click all apply and can still be changed afterwards. The price is
  that anything in front of the window is in the file, so it is paid only
  where it buys something — with the camera off, the pointer switched off
  and no zoom asked for, a window recording still captures the window
  alone.
- **The camera's background blur is stronger.** `CIGaussianBlur` at
  radius 28 instead of 12 — 2.33× the kernel, taking out two fifths of
  the mid-scale structure the old value left behind (measured on a real
  640×480 frame at three spatial scales). It costs nothing measurable:
  three probe runs at each radius on an idle machine came back 9.1–9.8 ms
  a frame at 28 against 7.6–9.8 ms at 12, ranges that overlap almost
  entirely, with Vision ~78 % of each. Both are far under the 33 ms
  budget.
- **A take is recorded raw and the deliverable is rendered from it.** The
  effects used to be decisions you had to get right before you pressed
  record: the pointer went into the pixels as they were captured and a
  zoom cropped the stream itself, so a take made with the wrong ones was
  a take made again. The menu-bar app now captures a *raw* take — no
  pointer in the frames, no zoom in the framing — and renders the movie
  you asked for from it on stop. The raw take stays beside the
  deliverable as `<name>-raw.mp4`, so the playback window's **Effects**
  pull-down and its **Re-export** button produce the file again with a
  different choice, as often as you like, and `knips render
  --in=<take>-raw.mp4 --effects=zoom,smooth-cursor` is the same pass from
  a script.

  The render re-encodes the video and **copies the audio sample for
  sample**, and every source frame's presentation stamp is passed through
  as a `CMTime` rather than through seconds — a stamp taken through a
  `Double` and back at a 1/600 s timescale lands up to 1.7 ms out,
  measured, which is why it is not done that way. So the deliverable's
  timeline *is* the raw take's, and the take's event sidecar still
  describes it. The output is built as `<out>.knips-render-tmp` and
  renamed into place, so a killed render cannot damage a deliverable that
  already existed.

  Two consequences worth knowing. **A take is normally two movies and two
  sidecars, and Knips deletes none of them** — `~/Movies/knips/` grows at
  roughly twice the rate it used to, and the raw take is exactly what
  makes the effects changeable, so throwing it away is a decision only
  you can make. And **Zoom on Click, Smooth Cursor and Big Cursor left
  the menu bar** for the playback window's Effects control, because they
  are now things done to a take rather than choices about what is
  recorded. *Follow Mouse* stayed where it was: a pan decides which
  pixels are read off the screen at all, and nothing afterwards can
  recover what was never captured. The three old menu toggles migrate
  one-way into the new saved defaults (`KnipsEffectZoom`,
  `KnipsEffectCursor`) on the first launch that finds them, and are never
  written again. A take that can take no effect at all is **refused** by
  `knips render` with the reason, rather than copied into a
  byte-identical duplicate you would then have to find and delete.
- **Event sidecar.** Every recording writes `<take>.knips.jsonl` beside
  its movie: the pointer's path at about thirty samples a second, mouse
  button edges, the rectangle the capture was reading at each instant, and
  what was baked into the pixels. Times are on ScreenCaptureKit's own host
  clock and anchored to the movie's first frame, so an event's place on the
  movie's timeline is a subtraction rather than an estimate — measured over
  a 61 s take, the sidecar's prediction matched the recorded pointer's
  pixel position within 1 px on 109 of 120 frames, with a best-fit time lag
  of zero. The format is public and documented in
  [docs/event-sidecar.md](docs/event-sidecar.md).
- **Smooth Cursor.** `record --smooth-cursor` (and a menu item beside Big
  Cursor) leaves the pointer out of the movie entirely and draws it back
  into GIF and APNG exports from the sidecar's track, interpolated to each
  output frame and smoothed over a centred window. `export --cursor=` picks
  the pointer for any take that has room for one: `as-recorded`, `none`,
  `smooth`, or `big`. Mutually exclusive with Big Cursor, and refused for a
  passthrough trim, which re-encodes nothing.
- **Export size estimates.** `export` says what the animation is likely to
  weigh before it writes a byte — from the source movie's own bytes per
  pixel-frame, which is H.264's verdict on how busy the content is — and
  then replaces the estimate with a projection from what the encoder has
  actually produced. The playback window shows both in its title.

  The estimate is reported as a range, and the range is honest about what
  it is rather than about what would sound good: calibrated on sixteen
  exports over seven takes at four output widths, the worst residual is
  2.2x, the band shown is 3x, and content unlike anything in that set can
  still land outside it. Measured too, and stated because it is the sort
  of thing a model like this is usually assumed to need: downscaling does
  **not** need its own term — across a fourfold reduction the ratio moves
  by at most 31 % while content moves it fourfold. The in-flight
  projection is the number that is actually accurate, and it was inside
  5 % of the final size on busy takes (30 % on ones that went quiet
  half way through).
- **Never lose a take.** The writer now flushes a movie fragment every two
  seconds, so a process killed mid-recording leaves a playable movie
  instead of a zero-byte stub (measured: 117 frames of a six-second take
  survived a `kill -9`). The next `knips record`, and the menu-bar app at
  launch, find the unfinished take, re-mux it into an ordinary movie and
  close its sidecar off — a check that costs about ten milliseconds over
  a directory of fifty finished takes, because it reads each sidecar's
  last four kilobytes rather than parsing it. A normally finished take is
  unchanged apart from where its `moov` atom sits: it is `ftyp/mdat/moov`
  with no fragments, since `finishWriting` consolidates them.
- **Audio assurance.** The writer measures each PCM buffer's peak on the
  capture queue, so a track that was enabled and arrived as pure silence is
  now said out loud — on the *Stop Recording* menu item while the recording
  runs, and afterwards in the log, the menu and the playback window's
  title. "Nothing arrived" and "everything arrived and was silence" are
  told apart, because they send the user to different places.
- **Windows and Linux port foundation.** No backend yet, and none is
  claimed — what this lane bought is the ability to find out from a Mac
  whether the neutral core is really neutral, which until now was an
  assertion. `tools/linux-ci.sh` builds a Debian bookworm container with
  FPC 3.2.2 and the real lwpt Linux binary and runs every `*.Test.pas`
  suite plus `lwpt build` plus `lwpt format --check`, green on
  `linux/arm64` and `linux/amd64`; the Linux `knips` it produces is a
  working binary that serves MCP and refuses capture with exit 3 rather
  than pretending. `tools/win64-cross.sh` bootstraps an FPC 3.2.2
  `x86_64-win64` cross compiler inside a container and links `knips.exe`
  and every suite as PE32+ binaries. `tools/wine-smoke.sh` then *runs*
  those suites under Wine, which is the part the compiler had nothing to
  say about: its first run failed eight of 323 tests, all in one file,
  and tracing them found six stale POSIX literals and two predicates that
  ask whether a path starts with a separator — plus the one genuine
  product item, that a recording belongs in `~/Videos` off macOS and not
  `~/Movies`. The checkout is mounted **read-only** and copied inside the
  container, so a foreign `.ppu` or an ELF `build/knips` can never land in
  a developer's Mac tree. There is also an X11/MIT-SHM
  capture spike that grabs a verified frame off Xvfb in CI and writes it
  through the neutral GIF encoder — proof that a Linux capture path can
  be built and regression-tested from a Mac, and explicitly not a
  backend. The stance, and what each platform will actually need, is
  [ADR-0005](docs/adr/0005-windows-linux-ports.md) and
  [docs/ports.md](docs/ports.md).
- **⌘⇧2 stops a recording from anywhere.** It is the one thing the menu
  bar icon cannot do: while Knips records the icon has no menu at all — a
  single click stops it — and the window you are demonstrating in is the
  last place you should have to leave. Registered with Carbon's
  `RegisterEventHotKey` against the application event target, which is
  the one route to a global chord that **costs no extra permission**:
  `NSEvent`'s global monitor and a `CGEventTap` both need Input
  Monitoring, which is a "Knips wants to read everything you type" dialog
  in exchange for one shortcut. No key pressed anywhere else is ever seen
  by Knips. It *only* stops — a global chord that could start a recording
  starts one by accident — so outside a recording it does nothing, and
  the stop goes through the same path the icon's click does rather than a
  second one. If the chord cannot be registered the app says so on its
  `Last error: …` line and carries on without it. Registration success is
  deliberately not treated as proof: measured, `RegisterEventHotKey`
  answers `noErr` for ⌘⇧3, the screenshot shortcut the system already
  owns — what the system keeps is the delivery, not the registration — so
  `knips probe` checks the registration and the constants and whether the
  keys really fire is left to a human, since this project's tooling never
  synthesises input.
- Headless `record` to `.mp4`/`.mov` from a display, region, or window via
  ScreenCaptureKit and AVAssetWriter.
- `app`: the Kap gesture as a menu-bar app — click the icon, drag a
  region, click again to stop; recordings land in `~/Movies/knips/`.
  `tools/make-app.sh` wraps the binary in `Knips.app`.
- `app`: a red frame marks the region for as long as it records. It is a
  passthrough window, stroked outside the recorded rectangle *and*
  excluded from the capture through
  `SCContentFilter initWithDisplay:excludingWindows:`, so it never
  reaches the file.
- `app`: a finished recording opens in a playback window (AVKit) with
  *Export as GIF…*, *Reveal in Finder*, and *Close*. The export writes
  `<recording>.gif` beside the movie at 20 fps and at the recording's
  own point size — its pixel width divided by the scale it was captured
  at — reporting progress in the window title. On the 2x display that is
  nearly every Mac that makes the export an exact 2:1 integer reduction,
  which is the sharpest a downscale gets; the previous 800 px cap landed
  on a fractional ratio and visibly softened text. A Retina recording
  has no cap — its point size is already half its pixels — while a
  scale-1 recording keeps an 800 px cap, and an oversized result is
  called out on the app's own "Last error" line, since a bundle has no
  stderr.
- `app`: the playback window puts Knips **in the Dock and in ⌘-Tab** for
  as long as it is open, with a menu bar of its own — *About Knips*,
  *Quit Knips* ⌘Q, and a Window menu with *Close* ⌘W and *Minimize* ⌘M.
  Closing the window, by any route, drops the process back to being
  menu-bar-only. The rest of the app stays an Accessory process: a
  recorder has no business owning the Dock while it records. ⌘Q is the
  same guarded quit the menu offers — it finalises an open recording and
  refuses during a GIF export — and the status item is unaffected by the
  switch. Starting a recording closes the playback window first, so the
  Dock tile and the menu bar are never in the frame. `knips probe` now
  gates the promotion and the menu's shape, and skips that one check
  (rather than dying) where there is no window server; `knips app` refuses
  there with a message instead of aborting.


- **A sidecar with no `sampleHz` field read as a sample rate of
  1.5×10⁻³²². The reader's fallback went through `TJSONFloat(30)`, and a
  typecast of an integer constant to a float type in Delphi mode
  reinterprets the bits rather than converting them — so the documented
  default of 30 arrived as the denormal `$000000000000001E`. Nothing
  noticed for as long as nothing divided by it; the first thing that did
  crashed. Every other fallback in the reader casts a literal `0`, whose
  bit pattern is `0.0` either way, which is why this was the only one
  that was wrong.
- **A drawn pointer could be placed against the wrong rectangle on the
  frames of a take whose movie outlasts its sidecar** — reachable after a
  crash-recovered recording, because samples are flushed about a second
  behind and recovery re-muxes the movie without trimming it. Those
  frames now fall back to the last rectangle the track actually holds
  (measured: the pointer had been landing 207 pixels away), and the
  render says how many frames it could not place instead of reporting a
  clean success.

- `app`: a close asked for by the user — the titlebar's button or ⌘W —
  is now refused while a GIF export is running (`windowShouldClose:`),
  rather than taking the window down and leaving the export to write
  through nil-checks. The *Close* button and every internal path were
  already refused.
- `app`: ⌘Q during an export no longer re-attaches the status item's
  menu. `CommandExportGif` detaches it so that a click cannot open menu
  tracking inside the export's event drain, and every refresh during an
  export now leaves it detached.
- `app`: a stop click during an export no longer queues a deferred
  `FinishRecording` that re-enters the run loop from under the export.
  `CommandStop` reads the transition's answer before scheduling anything.
- `app`: *Record Window* submenu (on-screen application windows, refreshed
  at most once every five seconds and never listing Knips's own windows),
  *Record Last Region*, and a *Record System Audio* checkbox. The checkbox
  and the last region are remembered between launches in `NSUserDefaults`;
  the stored region is range-checked on the way back in.
- `app`: **Zoom on Click** and **Follow Mouse**, two remembered menu
  checkboxes that change what a recording *shows* while it runs. A click
  inside the recorded area zooms the recording to 2× around the click,
  holds 0.8 s after the last click and eases back; Follow Mouse pans a
  region recording so the pointer stays inside the middle third, and the
  red frame moves with it. Neither changes the file's dimensions —
  `AVAssetWriter` fixes those at the first frame. Both animate the
  stream's `sourceRect` through
  `SCStream.updateConfiguration:completionHandler:` instead, so a smaller
  rectangle is a zoom and a sliding one is a pan. They compose: zoom crops
  inside wherever the pan has got to. Zoom works for a region or a whole
  display, Follow for a region only (a display has nowhere to pan), and
  window recordings get neither — a window's `sourceRect` is in a space
  that moves and resizes under us. Both are off by default and remembered
  in `NSUserDefaults` under `KnipsZoomOnClick` and `KnipsFollowMouse`;
  like Record System Audio they are idle-only. Clicks are found by polling
  `NSEvent.pressedMouseButtons` at the animator's 30 Hz tick rather than
  by an event monitor, so no permission beyond Screen Recording is
  involved. Measured on device: a 2× zoom magnifies content by exactly
  2.000× with the file still 1024×768 and no dropped frames, a 200-point
  pan moves the picture by exactly 400 px, and the moving frame stays out
  of the file — 0 border pixels in every frame with the exclusion in
  place against 665 792 without it. Clicks on the menu bar are ignored,
  so the click that stops a full-screen recording does not zoom into the
  corner on the way out. If ScreenCaptureKit refuses five rectangle
  changes in a row the effects switch off for the rest of that recording
  and say so on the `Last error:` line rather than retrying twenty times
  a second in silence — reproduced on device with an out-of-range
  rectangle (`-3812`, `SCStreamErrorInvalidParameter`). CLI unchanged.
- `record`: `TRecordingOptions.ExcludedWindowIDs` keeps named windows out
  of a display capture.
- `record --audio=system`: system audio through ScreenCaptureKit into an
  AAC track of the same file (48 kHz stereo, 128 kbit/s).
- `record --audio=mic` and `--audio=both`: the default microphone via
  ScreenCaptureKit's native microphone output (macOS 15), on a second
  AAC track. `both` writes system audio and microphone as two separate
  tracks — players pick the first one; there is no in-process mixing in
  this version. Per-source sample counters in the `record` summary.
- `app`: a **Camera** item puts a small, round-cornered, floating camera
  window on screen. Drag it anywhere — inside the region you are
  recording, and ScreenCaptureKit captures it like any other window. Its
  position and its on/off state survive a relaunch, and it stays up
  across recordings. Needs the Camera grant; `tools/make-app.sh` now
  writes `NSCameraUsageDescription` into the bundle.
- `app`: the camera preview is **mirrored**, the way every camera
  preview is — raise your left hand and the picture's left hand goes up.
  Since Knips records the window as it appears, the file is mirrored
  too, which is what Kap does and what a viewer expects.
- `app`: releasing a drag **snaps the camera window to the nearest
  corner** of the screen it was dropped on, inset by the same margin as
  its first placement, over a short eased glide. A plain click is not a
  drag and never moves the window. The window carries the drag itself now
  (`mouseDown:`/`mouseDragged:`/`mouseUp:` on `KnipsCameraView`) instead
  of `movableByWindowBackground`, because the snap needs a drag end that
  is unambiguously the user letting go, and the glide is a timer this
  unit owns rather than `setFrame:display:animate:` — an AppKit animated
  setFrame runs a nested run loop, and a re-grab, a shape change or a
  Hide landing inside one all misbehave.
- `app`: a **Circular Camera** checkbox turns the camera window into a
  disc — a square window with a half-side corner radius, cropping the
  middle of the feed. It applies to the live window about its own
  centre, and is remembered under `KnipsCameraShape`.
- `app`: starting a **region** recording with the camera up **docks** it
  into the nearest corner inside the region, so the picture-in-picture
  ends up composited into the file the way Kap does it — still with no
  compositing code, just a window moved to the right place. Stopping
  puts it back where it was. Display and window recordings are
  unaffected, and with *Follow Mouse* on it docks once at the start
  rather than chasing the panning region.
- `export` from `.mp4`/`.mov` to an animated GIF: median-cut palette,
  Floyd–Steinberg dithering and LZW in pure Pascal, with `--fps`,
  `--width`, and `--trim=start,end`.
- `export`: the scaler's fractional step is Catmull-Rom bicubic rather
  than bilinear, and an integer box reduction that already lands on the
  target width now stops there instead of resampling its own output.
  Two taps an axis is a triangle filter and blurs small text; four taps
  with clamped negative lobes keeps the edge. Both GIF and APNG go
  through it. Measured on a real 1800×1000 region recording at 800×444,
  +2.9 dB against a Lanczos reference and 19% more edge contrast.
- `export --out=x.apng`: animated PNG in pure Pascal — 8-bit truecolour
  (no quantisation), changed-rectangle subframes with
  `dispose_op=NONE`/`blend_op=SOURCE`, PNG line filters, and the RTL's
  own paszlib for compression.
- `export --in=a.mp4 --out=b.mp4 --trim=s,e`: passthrough trim through
  `AVAssetExportSession` — the same coded samples in a new container, no
  decode and no re-encode. Movie-to-movie only, and `--trim` is required.
- `export` warns on stderr (exit code still 0) when the result is large:
  a canvas at or past 1280×720, or a file past 20 MB, naming whichever of
  `--width`, `--fps` or `--trim` would actually help.
- `mcp`: the recorder as a Model Context Protocol server on stdin/stdout,
  over [pascal-mcp-sdk](https://github.com/frostney/pascal-mcp-sdk).
  Ten tools — `list_displays`, `list_windows`, `take_info`,
  `record_start` / `record_stop` / `record_status`, `render`,
  `export_gif`, `export_apng`, `export_trim` — each running the CLI's
  own session classes with JSON
  arguments in place of flags, refused by the same `Knips.Options`
  validation (with the flag names rewritten to the argument names the
  tool schemas actually declare). Recording is non-blocking: the server
  answers `record_status` and everything else while ScreenCaptureKit
  captures on its own queue, and one recording at a time is enforced
  with an in-band error naming the file already being written. The SDK's
  stdio transport is a single-threaded read-handle-write loop, so no
  `cthreads` and no new thread; its HTTP transport, which would need
  both, is not used. Screen Recording permission is inherited from the
  MCP client's host application — see
  [docs/quick-start.md](docs/quick-start.md#the-mcp-server).
  Two contracts are deliberately stricter than the CLI's, because the
  caller is a program: `record_start` refuses an existing `out` unless
  `overwrite: true` is passed (agents guess paths; `knips record`
  replaces what you typed), and `export_trim` refuses `fps`/`width`/
  `dither` rather than ignoring what a passthrough copy cannot honour.
  Paths are returned absolute, every tool declares an `outputSchema`,
  and a writer that dies mid-recording is reported by `record_status`,
  which stops the session and says whether the partial file was
  finalised.

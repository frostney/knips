# The event sidecar

Every knips recording writes a second file beside the movie:

```text
~/Movies/knips/2026-08-27 18-26-07.mp4
~/Movies/knips/2026-08-27 18-26-07.knips.jsonl
```

The movie is pixels. The sidecar is everything knips knew while it was
recording and the pixels cannot say: where the pointer was, thirty times a
second; when a button went down and came back up; which rectangle of which
display was being read at that instant; and what the recording was set to
do. It is written by `knips record`, by the menu-bar app, and by the MCP
server alike.

This is a **public format**. It is documented here so that anything — the
GIF exporter, a script, somebody else's tool — can read a take without
guessing. Nothing about it is private to knips.

**Its first consumer is knips's own render pass.** The menu-bar app records
a *raw take* — no pointer in the pixels, no zoom in the framing — and then
renders the deliverable from it (`knips render`, and
`Knips.Export.Render`): the pointer is drawn back from the track in this
file, and Zoom on Click crops each frame by the click track in it. The GIF
and APNG exporters apply the same effects from the same file. That is why
the header records what was **baked into the pixels** as carefully as it
records what the pointer did: an effect that is already in the movie can
never be taken out again, so those fields decide what a render is still
free to choose. They are covered by the stability promise below exactly as
the sample records are.

## Shape

[JSON Lines](https://jsonlines.org): one JSON object per line, UTF-8, no
enclosing array and no trailing comma. A reader parses line by line.

That shape is deliberate. A recording can end in a killed process, and a
file that is a single enormous JSON array would then be unparseable in its
entirety; this one is readable up to its last complete line, and the lines
before the cut are exactly as good as they ever were.

Every object has a `"k"` naming its kind. **A reader that meets a kind it
does not recognise must skip that line and carry on.** That rule is the
whole of the forward-compatibility story: new kinds can be added without a
version bump, and so can new fields on an existing kind.

The corollary is the refusal rule. Because a new kind and a new field both
cost nothing, a `version` that has actually *moved* means something a
version-1 reader would **misread** rather than merely miss. **A reader must
refuse a file whose `version` is above its own** — not skip it, not
half-read it. `TSidecarLog.LoadFromFile` fails with a message and sets
`TooNew`. A file whose `format` is not `knips-events` is refused for the
same reason and more bluntly: it is not one of these at all —
`LoadFromFile` fails with its own message and sets `ForeignFormat`.

Those are the only ways a file's *contents* can fail a load. There are
two more that are not about contents at all: the file is not there, and
the file could not be read (a permission, a vanished volume) — both of
which `LoadFromFile` reports with the underlying message. Everything else
a bad file can do is a skipped line.

### What a reader must survive

A sidecar is not a file knips was handed. The recovery pass reads every
`*.knips.jsonl` in the recording directory at every `knips record` and at
every launch of the menu-bar app, before anything else happens — so the
reader's input is whatever is in that directory. Knips' own reader
therefore refuses three shapes, and each refusal is a **skipped line**,
counted in `SkippedLines`, never fatal. Two of them are decided *before*
the line is handed to a JSON parser at all, because by then it is too
late; the third is decided after the parse, on the values it returned:

| refused | limit | why |
| --- | --- | --- |
| a deeply nested line | more than **64** levels of `[`/`{` | JSON parsers recurse. Fifty thousand `[` on one line is fifty thousand stack frames, and the process dies of a stack overflow — a *signal*, which a `try` around the parse cannot catch. Measured: one such file in the recording directory made `knips record` exit 139, silently, at every start. The format's deepest real line is one object of scalars |
| an enormous line | more than **1 MB** | a line need not nest to be pathological, and this is a thousand times the longest line the format writes |
| a number that cannot be its field | **after the parse**: any of `t`, `x`, `y`, `sx`/`sy`/`sw`/`sh`, `host`, `duration` or a header measurement that is not finite, and any *integer* field (`version`, `pid`, `pixelWidth`, `pixelHeight`, `scale`, `fps`, `displayId`, `frames`, `samples`, `n`, `b`) that is not finite or does not fit the field | `1e999` is legal JSON and parses to `+Inf`. Two infinities subtracted are a `NaN`, and a `NaN` walks through interpolation and staleness tests into a render that is quietly wrong. The integer fields are worse than that: rounding an infinity into an integer **raises**, and on knips' own reader that used to escape the load and kill the process — so this is the check that has to be a reader's, not a caller's. On macOS the same read is *masked* rather than fatal and comes back as `-1`, which is how a `"version":-1` slips past a version test and a `"pid":-1` reads as a live process |

A reader that cannot check every field should at least wrap the reading
of a line, not only its parse: knips' own does both, and the wrapper is
what makes the promise above true for record kinds nobody has written
yet.

A header carrying a non-finite number is skipped **whole**, not
field-by-field: `baseWidth` seeds every sample's carried-forward source
rectangle and `sampleHz` is divided by, so half a header is worse than
none.

These are knips' numbers, not requirements of the format. Another reader
should pick its own — but it should pick some.

## The clock

Every time in the file — `t` on a sample, `host` on the anchor — is
**seconds on macOS's host clock** (`CMClockGetHostTimeClock`, which is
`mach_absolute_time` in seconds). It is a monotonic uptime clock: it does
not jump when NTP corrects the time, and it means nothing outside the
current boot.

That clock is chosen because it is the same one ScreenCaptureKit stamps its
frames with. The `anchor` record carries the presentation stamp
AVAssetWriter started the movie's timeline at — the first appended frame's
PTS — so

```text
movie time of an event  =  event.t − anchor.host
```

is exact by construction: two readings of one clock, subtracted. No wall
clock is involved anywhere in the pipeline.

**Measured** on a 61.3-second recording: elapsed host time between the
anchor and the stop was 0.034 s longer than the movie's own duration (last
frame PTS minus first frame PTS) — one frame at 30 fps, which is the gap
between the last captured frame and the stop, and it does not grow with the
length of the take (a 5-second recording showed 0.050 s). There is no
drift, because there is only one clock.

That gap used to be bounded only by how long nothing moved: a still screen
delivers no frames at all, so a 30-second recording of one produced a
single frame and a movie spanning **0.000 s** against 30 s of elapsed host
time, and every event after the first was past the end of the file. The
**idle heartbeat** now repeats the last frame twice a second while a
recording runs, and once more at the stop itself, so the movie's own
duration and the anchor-to-stop span agree to within a frame whatever the
screen was doing — measured, 13.972 s against 13.972 s. See
[docs/architecture.md](architecture.md), "The idle heartbeat". Readers that
place events on the movie's timeline are the reason it matters: the
arithmetic above was always exact, but it used to be exact about a moment
the movie did not reach.

The anchor is written as soon as the first frame has been appended, not at
the end, so a recording that dies still carries it.

## Coordinates

`x` and `y` are in the **recorded display's own points, measured from its
top-left corner** — the same space `SCStreamConfiguration.sourceRect` and
`--rect` use. `sx`, `sy`, `sw`, `sh` are the rectangle the capture was
reading at that instant, in the same space.

A point becomes a frame pixel with the ratio of the output to the source
rectangle, which folds the region offset, the Retina scale factor and any
live zoom into one expression:

```text
frameX = (x − sx) / sw × pixelWidth
frameY = (y − sy) / sh × pixelHeight
```

(That is `Knips.Recording.CursorMath.CursorFramePoint`, which is what both
Big Cursor and the export-time cursor use.)

**Window recordings are the exception.** A window's frames are a picture of
something that moves under the recorder with no way to find out, so a
screen position cannot be mapped into them. The header says
`"target":"window"` for those, the samples stay in *global* screen points,
and a reader must not try the arithmetic above. Display recordings, with or
without a region, map exactly.

On a window take the recorder has no rectangle to report, so
`baseX`/`baseY`/`baseWidth`/`baseHeight` — and every sample's
`sx`/`sy`/`sw`/`sh`, which are carried forward from them — are all **zero**.
That is not a rectangle at the origin; it is the absence of one, and a
reader dividing by `sw` gets a division by zero rather than a wrong answer.
Test `target` before the arithmetic, not the numbers: they are zero because
the mapping does not exist, which is the same thing `"target":"window"`
already says. (Knips' own reader answers this as a named reason —
`AvailableExportEffects` refuses a window take before it looks at the
rectangle at all.)

## Sampling

The pointer is sampled on the **main thread**, from the run loop that owns
the recording — the CLI's own loop, and the menu-bar app's 30 Hz timer.
Nothing about the sidecar runs on ScreenCaptureKit's capture queue.

- `sampleHz` in the header is the **target**, not a promise. The CLI's loop
  achieves about 27 Hz in practice (the run-loop slice plus the sampling
  work); a busy run loop achieves less.
- **Readers must use each sample's own `t` and never assume a spacing.**
  Interpolating between the two samples that bracket a time is the
  supported way to ask where the pointer was — **up to a point.** A gap
  is not evidence of a straight line: two samples minutes apart say only
  that the pointer was here, and later was there. Knips' own reader
  therefore refuses to interpolate across a silence longer than fifteen
  of the header's own sample intervals, floored at half a second and
  **capped at two** (`TSidecarLog.MaxInterpolatedGap`) — the cap because
  `sampleHz` is a number in a file somebody else may have written, and a
  header declaring 0.05 Hz must not be able to buy itself a five-minute
  licence to draw a straight line. It **holds the earlier sample's
  position** until the track speaks again, then snaps. Holding claims
  only what the track actually says; the snap is the honest shape of
  "nobody was watching in between". A lerp instead draws a pointer
  gliding smoothly across the screen for a minute — a thing that never
  happened — and, because a render synthesises a frame wherever the
  picture would change, fills that whole minute with frames to draw it
  on. Another reader may choose differently, but it should choose
  deliberately.
- An **MCP** recording is the sparse case: the stdio transport is a
  blocking read/handle/write loop, so between tool calls nothing runs on
  the main thread at all. Those takes get a sample at the start, one per
  `record_status` call, and one at the stop. The times are still exact;
  there are simply fewer of them. That matters more than it used to:
  `record_start` takes `smooth_cursor`, so an agent can record a raw take
  and `render` it, and a pointer drawn from three samples is a straight
  line. The server says so on `record_start`, reports the samples that
  arrived on `record_stop`, and reports the largest gap between them —
  beside the largest gap a reader will draw through, and a sentence
  saying what it means when the first is bigger — from `take_info`.
  Recovery treats such a take like any
  other and the movie comes back whole — but what it recovers is the
  movie, not a dense event track. It is also the take the interpolation
  rule above is written for: minutes can separate two of those samples,
  and nothing may be drawn through the silence between them.

  The idle heartbeat rides the same tick and inherits the same sparseness:
  an unpolled MCP recording gets no periodic heartbeats, only the closing
  one at `record_stop`. Its movie still **spans** the take — measured, 12.0
  seconds of wall time came back as a 12.002 s span from two frames — and
  polling `record_status` is what makes the frames inside it dense. A take
  polled once a second showed frame gaps of exactly 1.005 s.

### Buttons

The left mouse button is polled with `CGEventSourceButtonState` at each
sample, and a change of level is written out as its own `button` record.
This is **deliberately not a `CGEventTap`**: a tap would need the Input
Monitoring privacy grant, and knips asks for Screen Recording (and, for the
camera window, Camera) and nothing else.

The cost is stated rather than hidden:

- a press and release inside one sample period — about 33 ms — is not seen
  at all;
- an edge's time is accurate to one sample period, not better.

Only the left button is sampled. A right-click opens a context menu, which
is not a gesture anybody means to record as a click on the content.

## Records

### `header` — always the first line

```json
{"k":"header","format":"knips-events","version":1,"knips":"0.1.0",
 "movie":"demo.mp4","created":"2026-08-27T17:26:07Z","pid":98342,
 "target":"display","pixelWidth":3024,"pixelHeight":1964,"scale":2,
 "fps":30,"sampleHz":30.000,"displayId":1,"displayWidth":1512.000,
 "displayHeight":982.000,"baseX":0.000,"baseY":0.000,
 "baseWidth":1512.000,"baseHeight":982.000,"menuBarInset":39.000,
 "cursor":"baked",
 "bakedZoomOnClick":false,"bakedFollowMouse":false,
 "bakedWindowFollow":false,"audio":"none"}
```

Field order is the writer's; a reader must not depend on it (JSON objects
are unordered), and this example is in the writer's order so that the
specification and the code can be compared line for line.

| field | meaning |
| --- | --- |
| `format` | always `knips-events`; a reader should refuse anything else |
| `version` | format version; `1` today |
| `knips` | the version of knips that wrote the file |
| `movie` | the movie's **file name**, not a path — a sidecar travels with its movie |
| `created` | ISO 8601 UTC, for humans; nothing is computed from it |
| `target` | `display` or `window` (see *Coordinates*) |
| `pixelWidth`, `pixelHeight` | the movie's dimensions |
| `scale` | pixels per point of the recording |
| `fps` | the frame rate the capture was configured at |
| `sampleHz` | the sampler's target rate (see *Sampling*) |
| `displayId`, `displayWidth`, `displayHeight` | the recorded display; `0`/`0`/`0` for a window target |
| `baseX`, `baseY`, `baseWidth`, `baseHeight` | the rectangle the recording was sized from, and the source rectangle in force before the first sample that carries one |
| `menuBarInset` | how much of the top of the recorded display is menu bar, in that display's points; `0` when it was not measured |
| `pid` | the process that wrote the file; see *Recovery* |
| `cursor` | how the pointer got into the pixels: `system`, `baked`, `none`, or `smooth` |
| `bakedZoomOnClick`, `bakedFollowMouse` | whether a live effect zoomed or panned the capture |
| `bakedWindowFollow` | whether a composited window recording panned it |
| `audio` | `none`, `system`, `mic`, or `both` |

`menuBarInset` is there because **a click is not always content**. The
click that stops a recording is a click on knips's own status item, and a
zoom driven by this file's click track has to leave that band alone or
every full-screen take would end by zooming into its top corner. The
number cannot be recovered from the samples: a notched Mac reports 39
points where an unnotched one reports 22, and an auto-hiding menu bar
reports 0.

Both writers fill it in. The measurement needs AppKit — `NSScreen`'s
`frame` minus its `visibleFrame`, floored at `NSStatusBar`'s thickness —
and `knips record` from a shell turns out to have `NSApp` standing by the
time the sidecar's header is written (measured: a plain `knips record` on
this machine writes `39.000`, the real notch inset, not `0`). So the field
is real for CLI takes too, and `knips render --effects=zoom` on one leaves
the same band alone. A `0` means the band was genuinely not measured — no
`NSApp`, a window target, or a menu bar set to auto-hide — and a reader
should treat it as "no band recorded" rather than as "no menu bar".

`cursor` is the field worth dwelling on, because it is the one thing a
reader cannot recover from the video — a frame with no pointer in it looks
the same whether that was asked for or whether something went wrong:

- **`system`** — ScreenCaptureKit drew the real pointer into the frames.
  The default.
- **`baked`** — knips composited its own enlarged sprite into the frames
  (`--big-cursor`). The real pointer was switched off.
- **`none`** — nothing drew a pointer, and none is wanted. The movie is
  cursorless and this file's track is the only record of where the pointer
  was. That is what `--no-cursor` produces.
- **`smooth`** — nothing drew a pointer *yet*. The movie is cursorless
  because the pointer is meant to be drawn back at export time from the
  track in this file. That is what `--smooth-cursor` produces, and the
  distinction from `none` is the whole reason this is a word and not a
  boolean: one says "no pointer wanted", the other says "the pointer is in
  here, put it back".

The pointer track is written in **all four** cases. A default recording
keeps its baked system cursor *and* logs where the pointer went.

The three `baked…` fields are the same kind of fact about the framing. The live effects move ScreenCaptureKit's own `sourceRect`, so
a take that zoomed is zoomed **in its pixels** and an export must not zoom
it again. A take that merely *panned* is a different case and is not
refused: the pan is in its pixels for good, but every sample says which
rectangle was being read at that instant, so a post-recording zoom is
composed inside that rectangle rather than against the base one. They record what the capture actually did, not what was ticked in
a menu: a window recording with Zoom on Click switched on is not a zoomed
recording, and says `false`.

`bakedWindowFollow` is the third because a **composited window recording**
pans without any live effect being on: it is a display capture underneath
whose source rectangle is polled onto a window as the user drags it.
Neither of the other two is true for one, and without this field such a
take would claim its framing was never touched.

A take with `cursor` of `none` or `smooth` and all three of those `false`
has **nothing** baked into it. `Knips.Recording.Sidecar.IsRawTake` is that
question, and `AvailableExportEffects` answers the larger one — which
post-recording effects a given take can still be given, and why not when
it cannot.

### `anchor` — the movie's first frame

```json
{"k":"anchor","host":120162.809705}
```

Written once, as soon as the first frame has been appended. See *The
clock*. A file with no anchor has no timeline: its samples are still
readable against each other, but not against the movie.

### `cursor` — a pointer sample

```json
{"k":"cursor","t":120162.822,"x":935.7,"y":804.3,"b":0}
{"k":"cursor","t":120162.856,"x":940.1,"y":802.0,"b":1,
 "sx":120.000,"sy":80.000,"sw":640.000,"sh":400.000}
```

| field | meaning |
| --- | --- |
| `t` | host-clock seconds |
| `x`, `y` | the pointer, in the space *Coordinates* describes |
| `b` | button bitmask; bit 0 (value 1) is the left button |
| `sx`, `sy`, `sw`, `sh` | the source rectangle, **only when it changed** |

The source rectangle is written only when it differs from the previous
sample's (the header's base rectangle is the value before the first one).
A reader carries the last value forward. For a recording with no live
effects that means it appears nowhere at all after the header.

### `button` — a press or a release

```json
{"k":"button","t":120165.104,"x":935.7,"y":804.3,"n":0,"d":true}
```

`n` is the button **index** (0 = left), `d` is true for a press. These are
edge records: the same information is in every sample's `b` mask, and this
kind exists so a reader looking for three clicks does not have to diff a
thousand samples to find them. The level at the start of a recording never
produces an edge — whatever the button was doing when the recording began
is not a click into it.

### `trailer` — the stop

```json
{"k":"trailer","t":120224.126164,"frames":1787,"duration":61.282818,
 "samples":1638,"recovered":false}
```

`frames` is how many frames reached the movie, `duration` is the movie's
own length in seconds (last frame PTS minus first), and `samples` is how
many `cursor` records were written. `recovered` is `true` when this trailer
was written by the recovery pass rather than by the recording itself — and
on one of those `frames` is `0` rather than a count, for the reason under
*Recovery*.

**`frames` counts what is in the file, which is no longer the same as
what the capture delivered.** Since the idle heartbeat, a take whose
screen went still has the last frame repeated into it about twice a
second, and those repeats are in this count exactly as captured frames
are — they are frames in the movie, and a reader comparing this against
the file would otherwise find it wrong. So `frames ÷ duration` is the
movie's frame rate and not a measure of how busy the content was: a
wholly still 11.7 s take reports 145 frames of which 13 are repeats,
against the single frame it would have reported before. A reader that
wants capture density has to look at the pixels; the sidecar does not
record which frames were repeats. `duration` is unaffected in meaning and
much improved in accuracy — it now matches the anchor-to-`t` span to
within a frame whatever the screen did.

A file with no trailer was cut short — the process died, or is still
recording.

## Recovery

That last sentence is load-bearing. **A sidecar with no trailer is how
knips finds a recording whose process died**, and it is why there is no
separate lock or marker file: the absence of the last line already says it.

Two things separate a crashed take from one that is still being recorded:
the `pid` in the header, tested with `kill(pid, 0)`, and whether the movie
beside it opens. That pid test has limits — reuse, reboots, sidecars from
another machine on a shared volume — spelled out in
[docs/architecture.md](architecture.md), "Never lose a take"; a tool
writing its own recovery should read them before trusting `kill(pid, 0)`.

One layout rule follows from how knips scans: **the trailer must be the
last record, within the final 4096 bytes of the file.** That is not a
request — it is `TailBytes = 4096` in
`Knips.Recording.Recovery.TailLooksFinished`, which seeks to the end,
reads that many bytes and asks whether `"k":"trailer"` occurs in them.
Nothing else is parsed for a take that answers yes. So a writer that
appends anything after the trailer, or pads the file past that window,
makes its takes look permanently unfinished to knips — and one that
manages to put the string `"k":"trailer"` into the tail some other way
makes an unfinished take look finished, which is the direction that
loses data. (Knips' own writer cannot: `QuoteJsonString` escapes every
quote in a movie name, so no name can fake the match.) The window is a
cost decision, not an arbitrary one: parsing every sidecar to find the
one without a trailer cost 5.12 s over fifty finished takes and would go
on climbing, and this check runs at every start.

The next `knips record`, and the menu-bar app at launch,
run that check over the directory and finish off anything they find — a
passthrough re-mux into an ordinary non-fragmented movie — then append the
trailer with `"recovered":true` so the take is never picked up twice. See
`Knips.Recording.Recovery`.

**A recovery-written trailer reports `"frames":0`, and it is not a count.**
Counting honestly means decoding the whole movie, and a recovery pass that
runs before every recording and at every launch must not do that; the
recorder's own counter died with the process. So `CloseSidecar` writes zero
deliberately, and `duration` — read back from the recovered movie itself —
plus `samples` are what actually say how much survived.

**`duration` can be `0` on a recovered take as well**, and for a
different reason: it is read back off the movie, so it exists only where
the movie could be read. Three of the four paths that close a sidecar
off pass `0` — the movie is empty (the crash beat the first fragment),
the movie will not open at all, or it opens and reports no duration —
and each of those leaves the file exactly as it was found. Only the
fourth, where the movie really was read, carries a length; a *failed
re-mux* still does, because the duration was known before the re-mux was
attempted. So on a `"recovered":true` trailer, `frames` is never a count
and `duration` is one only when it is non-zero. **A reader must
therefore not divide by `frames`, or treat `frames = 0` as an empty movie,
without first testing `recovered`.** On a normally finished take the field
means what the *trailer* section says it means; on a recovered one it means
"nobody counted".

The crash itself costs at most one movie fragment (two seconds) and one
buffer of samples (about a second): the anchor and every button record are
flushed to disk the moment they are written, and pointer samples are
flushed about once a second.

## Two sidecars: the raw take's and the deliverable's

A rendered recording is **two movies and two sidecars**:

```text
~/Movies/knips/2026-08-27 18-26-07-raw.mp4          the raw take
~/Movies/knips/2026-08-27 18-26-07-raw.knips.jsonl  what the pointer did
~/Movies/knips/2026-08-27 18-26-07.mp4              the deliverable
~/Movies/knips/2026-08-27 18-26-07.knips.jsonl      the same, re-headed
```

The deliverable gets its **own copy**, and the reasons are the two rules
this format already has.

A sidecar names its movie (`movie`, a bare file name) and travels with it,
so one file cannot describe two movies. And the two movies no longer say
the same thing about themselves: the raw take has nothing baked in and
everything still open, while the deliverable has the pointer in its pixels
and the crop in its framing. The deliverable's copy therefore carries
`"cursor":"baked"` and `"bakedZoomOnClick":true` where the render applied
them, so `AvailableExportEffects` refuses to apply either a second time —
which is what makes a rendered file safe to hand back to knips.

Two more header fields are the render's own rather than the take's, and
both matter to anything that runs the recovery test over a directory:

- **`pid` is the *rendering* process, not the recorder.** The field is
  documented as "the process that wrote the file" and recovery tests it
  with `kill(pid, 0)`; carrying the recorder's pid across would name a
  process that has nothing to do with this file, and on a pid that had
  since been reused would name a live one. `WriteDeliverableSidecar` sets
  it to its own. A `knips render` run days later therefore stamps that
  day's pid on the deliverable, which is correct and is also why the two
  sidecars of one take routinely disagree here.
- **`recovered` in the trailer is inherited from the raw take's**, not
  recomputed. The render copies the take's trailer and overwrites only
  `frames` (the deliverable's own count) and `samples`. So a deliverable
  rendered from a crash-recovered take says `"recovered":true` even though
  the render itself completed normally. Read it as a fact about the
  *pixels' provenance* — this movie descends from a take that was finished
  off after a crash — and not as a claim about how this file was written.
  It also means the deliverable's `frames` is a real count while the raw
  take's beside it is `0`.

Everything else is carried across unchanged, and one thing deliberately is
not:

- **the anchor is still exact.** The render copies each *source* frame's
  presentation stamp verbatim (`CMTime`, not seconds — a stamp taken
  through a `Double` and back at a 1/600 s timescale lands up to 1.7 ms
  out, which was measured and is why it is not done that way). The
  deliverable's timeline *is* the raw take's timeline, so `event.t −
  anchor.host` means the same on both files.

  The deliverable can hold **more frames than the take did**, and that
  changes nothing about the above. ScreenCaptureKit delivers a frame only
  when the content changes, so a pointer gliding over a still window — or
  a zoom easing over one — has almost no frames to be drawn into; the
  render therefore *interleaves* extra ones between the take's own, made
  by re-presenting the previous source frame with the effect evaluated at
  the new instant, and only where that would be a different picture. Its
  own stamps sit strictly between two source stamps and no source stamp
  is moved, dropped or re-timed, so the file's first and last stamps are
  still the take's and every time in this sidecar still means what it
  meant. The deliverable's `trailer` counts the frames the file actually
  holds, which is what `frames` has always meant;
- **the samples' source rectangles are rewritten** where a zoom was
  applied. A sample's `sx`/`sy`/`sw`/`sh` say what the capture was
  reading; what the deliverable's frames show at that instant is the
  crop, so the crop is what the deliverable's copy records. Anything
  mapping a pointer into the deliverable's pixels then gets the right
  answer from the ordinary arithmetic under *Coordinates*. On a take
  whose framing panned, the crop is composed **inside** the rectangle the
  sample already carried — the pan is in the pixels for good and the zoom
  sits within it — so the rewritten value is a subset of the one it
  replaces. Frames past the end of the track are not cropped at all: a
  movie can outlast its own sidecar (samples flush about a second behind,
  and recovery re-muxes without trimming), and a crop is only as good as
  the rectangle it is measured from, so those frames are passed through
  whole and the render says how many.

**A deliverable's sidecar is not time-ordered the way a recorded one is.**
A recording writes each record as it happens, so a recorded file's lines
ascend in `t` whatever their kind — a `button` sits between the two
`cursor` samples that bracket it. `WriteDeliverableSidecar` replays the
loaded log instead, and it replays it by kind: the header, the anchor,
**every** `cursor` sample, then **every** `button` record, then the
trailer. Within each kind the times still ascend; across kinds they jump
backwards once, at the seam. Nothing in the format ever promised
otherwise — the rule has always been that a reader uses each record's own
`t` — but code that grew up on recorded files and quietly assumed a
monotonic stream will find its first counter-example here. Sort by `t`, or
read each kind into its own array, as `TSidecarLog` does.

**A take that cannot be rendered is never split in the first place.** The
app asks before it names the file, and the answer is written straight to
the deliverable's own name with one sidecar — exactly as every `knips
record` take is. Splitting it would have left two byte-identical movies
and two sidecars on disk for ever.

The take that answers "cannot" is a **desktop-independent** window
recording: its frames have no fixed relationship to the screen its
pointer was measured against, so neither effect can ever apply. The app
only records one of those when nothing would be rendered into it anyway —
no camera, no pointer, no zoom. A window recording that wants any of
those is captured from the display through a rectangle riding the window
instead, which makes it `"target":"display"` with
`"bakedWindowFollow":true` and a per-sample source rectangle for every
move of the window; that take is raw, is split, and takes both effects
like any region take.

`knips render` answers the same question the same way: a take with
nothing that can be applied after the fact is **refused**, with the
reason, rather than copied into a duplicate. A take that *can* be
rendered but was asked for nothing (`--effects=none`) still copies —
that is a real request for the raw pixels as the deliverable — and does
produce the pair.

## Reading one

The reference reader is `Knips.Recording.Sidecar.TSidecarLog`
(`source/Knips.Recording.Sidecar.pas`), which is platform-neutral and
unit-tested on every host. It gives you the header, the anchor, the arrays,
`MovieSeconds`, and `StateAt(movieSeconds)` — the interpolated pointer
position and the source rectangle in force at one instant of the movie.

There is nothing macOS-specific about the format, and reading one in any
other language is a `for line in file: json.loads(line)`.

## Verification

The sidecar's alignment with the movie is measured rather than asserted.
The check records a take with the enlarged pointer baked in (`--big-cursor`),
extracts frames with `AVAssetReader`, and finds the sprite in each frame by
matching its fully opaque pixels — which, after a premultiplied
source-over, are byte-identical to the frame underneath them. The sprite's
found position is then compared with the position the sidecar predicts for
that frame's presentation stamp.

Measured over a 61.3-second take, 120 frames checked:

| measurement | result |
| --- | --- |
| mean offset | 0.06, 0.13 px |
| within 1 px | 109 / 120 |
| within 5 px | 115 / 120 |
| best-fit time lag | 0.000 s (no systematic lag) |
| mean position error | 0.645 points |
| clock drift over the take | 0.034 s, and not growing with duration |
| survives `kill -9` | 483 kB, 117 frames, 4.0 s of a 6 s take |

The handful of checks outside 5 px are frames where the pointer was moving
quickly between two samples: at ~27 Hz a pointer travelling 500 pt/s covers
about 18 points between samples, and the baked sprite is drawn at the
instant the frame reaches the capture queue rather than at its presentation
stamp. That is a property of Big Cursor, not of the sidecar — the best-fit
lag of zero says there is no systematic offset between the two clocks to
correct for.

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

**Its first consumer is knips's own export-time effects.** A recording made
with `--smooth-cursor` has no pointer in its pixels at all; the pointer in
the exported GIF is drawn from this file. The same track is what a
post-recording Zoom on Click will crop by. That is why the header records
what was **baked into the pixels** as carefully as it records what the
pointer did: an effect that is already in the movie can never be taken out
again, so those fields decide what an export is still free to choose. They
are covered by the stability promise below exactly as the sample records
are.

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
same reason and more bluntly: it is not one of these at all.

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

## Sampling

The pointer is sampled on the **main thread**, from the run loop that owns
the recording — the CLI's own loop, and the menu-bar app's 30 Hz timer.
Nothing about the sidecar runs on ScreenCaptureKit's capture queue.

- `sampleHz` in the header is the **target**, not a promise. The CLI's loop
  achieves about 27 Hz in practice (the run-loop slice plus the sampling
  work); a busy run loop achieves less.
- **Readers must use each sample's own `t` and never assume a spacing.**
  Interpolating between the two samples that bracket a time is the
  supported way to ask where the pointer was.
- An **MCP** recording is the sparse case: the stdio transport is a
  blocking read/handle/write loop, so between tool calls nothing runs on
  the main thread at all. Those takes get a sample at the start, one per
  `record_status` call, and one at the stop. The times are still exact;
  there are simply fewer of them. Recovery treats such a take like any
  other and the movie comes back whole — but what it recovers is the
  movie, not a dense event track.

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
 "baseWidth":1512.000,"baseHeight":982.000,"cursor":"baked",
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
| `pid` | the process that wrote the file; see *Recovery* |
| `cursor` | how the pointer got into the pixels: `system`, `baked`, `none`, or `smooth` |
| `bakedZoomOnClick`, `bakedFollowMouse` | whether a live effect zoomed or panned the capture |
| `bakedWindowFollow` | whether a composited window recording panned it |
| `audio` | `none`, `system`, `mic`, or `both` |

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
it again. They record what the capture actually did, not what was ticked in
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
was written by the recovery pass rather than by the recording itself.

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
last record, within the final 4096 bytes of the file.** Knips' recovery
pass reads only that tail to decide whether a take is finished; a writer
that appends anything after the trailer, or pads the file past that
window, makes its takes look permanently unfinished to knips. The next `knips record`, and the menu-bar app at launch,
run that check over the directory and finish off anything they find — a
passthrough re-mux into an ordinary non-fragmented movie — then append the
trailer with `"recovered":true` so the take is never picked up twice. See
`Knips.Recording.Recovery`.

The crash itself costs at most one movie fragment (two seconds) and one
buffer of samples (about a second): the anchor and every button record are
flushed to disk the moment they are written, and pointer samples are
flushed about once a second.

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

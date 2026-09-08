# Measurements and their history

## Executive Summary

- This is the appendix to [architecture.md](architecture.md). That
  document states the design Knips has now, the constants it runs on and
  the reason for each; this one holds the **measurement records** behind
  them — the proof runs, the calibration sets, and the figures that were
  true of a version this program no longer is.
- Nothing here is a decision. Every rule, constant and trade-off lives in
  architecture.md and is linked from the section that carries its
  numbers; each section below links back to the one it came from.
- Superseded figures are kept rather than deleted because they are how
  the current number was arrived at, and because a claim that a change
  helped is worth nothing without the value it started from.
- Unless a section says otherwise, "this machine" is an M-series Mac
  running the release build, and a figure quoted as a range is three runs
  on an otherwise idle machine.

## Frame synthesis before the idle heartbeat

From [The render pass](architecture.md#the-render-pass).

Every number in this section was measured **before** the capture-side
idle heartbeat, which has since landed. That heartbeat re-presents the
last frame while ScreenCaptureKit is idle, which makes takes dense at the
source, and it moves both of the limits these figures were taken against.
They are kept as the record of what the render alone was worth; what the
two do together is measured in architecture.md.

**How sparse a raw take was.** On a real 8.10 s take: 152 frames,
**18.8 a second** against a nominal 30, gaps up to 567 ms, and **one**
frame inside the 0.30 s the zoom takes to ease in.

**What interleaving bought.** Same take, same binary, synthesis off and
on: 152 → 209 frames, one → **seven** frames inside the ease-in,
6.31 MB → 7.56 MB (**+19.8 %**), 2.31 s → 2.88 s of work for an 8.33 s
take (0.28× → 0.35× realtime). The largest remaining gaps in the output
were exactly the stretches where the pointer was motionless and the zoom
was not animating. The GIF and APNG pipeline fills the same gaps on its
own decimation grid, for the same reason, and the same take at 20 fps
went 108 → 146 frames, 2.44 MB → 3.25 MB.

**The tail the render could not invent**, before the heartbeat closed it.
Measured on a real take: 17.54 s of recording, 88 frames, a movie
**4.26 s** long, three of its four clicks past the end of the file; and a
controlled repro of a wholly static 5.67 s recording produced **one frame
and a movie spanning 0.000 s**.

## The post-hoc zoom and the base rectangle

From [The render pass](architecture.md#the-render-pass).

What the crop taken against the recording's *base* rectangle cost, before
the arithmetic changed: **36 silently mis-cropped frames**, measured. The
zoom was refused for those takes, and the refusal was right for the
arithmetic that existed.

The framing-based crop was proved at pixel level on a real Follow Mouse
take (region 868×550 at (732, 268), framing panned to (627, 281) by the
time of the probe): the rendered frame half a second after a click
matched the predicted crop of the raw frame at **SSIM 0.9965**, against
**0.8636** for the same frame cropped against the base rectangle. On a
composited window take with a click outside the base rectangle and inside
the panned one: **0.9925** against **0.6325**.

Where the sidecar's track stops, carrying the last framing forward crops
against a rectangle the capture had already left — measured on the same
Follow Mouse take with its sidecar truncated at 3.4 s, the framing it
really had 0.8 s later was **317 output pixels** away, and the render
reported plain success. That is what the staleness rule closes.

## The GIF scaler and the app default

From [The export pipeline](architecture.md#the-export-pipeline).

The one-click GIF asks for the recording's own point size, so on a 2×
display the box pre-pass lands exactly on the target and there is no
second pass at all. Measured on a real 6.1 s 1800×1000 region recording,
PSNR against the source frame after putting each result back at capture
size:

| app default | canvas | GIF | PSNR |
| --- | --- | --- | --- |
| old: 800 px cap, box + bilinear | 800×444 | 374 kB | 24.58 dB |
| 800 px cap, box + bicubic | 800×444 | — | 25.48 dB |
| new: point size, exact box 2:1 | 900×500 | 418 kB | 27.63 dB |

## The GIF palette

From [The export pipeline](architecture.md#the-export-pipeline).

Measured on a 14 s, 800×520 ScreenCaptureKit recording, 281 frames, PSNR
against the same source that every encoder read, with ffmpeg's
`palettegen` + `paletteuse` as the reference point:

| encoder | dithered | size | PSNR |
| --- | --- | --- | --- |
| knips, 6-bit histogram | Floyd–Steinberg | 14.4 MB | 38.17 dB |
| knips, exact histogram + error-based cut | Floyd–Steinberg | 1.79 MB | 41.48 dB |
| ffmpeg palettegen/paletteuse | Floyd–Steinberg | 1.30 MB | 42.50 dB |
| knips, 6-bit histogram | none | 0.87 MB | 37.47 dB |
| knips, exact histogram + error-based cut | none | 1.09 MB | 42.58 dB |
| ffmpeg palettegen/paletteuse | none | 1.11 MB | 43.97 dB |

The dithered row is the one that matters, because dithering is the
default: it collapsed by 8.1× at 3.3 dB better, and the encoder did not
get slower doing it (13.19 s before, 13.20 s after, same machine, same
file).

The nearest-colour memo replaced a per-cell answer — a palette index
resolved for the colour a 6-bit cell's corner expands to rather than for
the pixel, which put a floor of a couple of units per channel under every
mapped pixel.

## The palette sample schedule

From [The export pipeline](architecture.md#the-export-pipeline).

**The bound the schedule is seeded from**, on a 220 s capture asked for
at 20 fps: the range times the requested rate says 4412 frames where the
movie holds 1723, which made the export's bar crawl at a third of its
true rate and stop at 54 %. The two-bound minimum answers 2428 for the
same capture.

**The budget the single stride could overrun**, since removed: it was
`GifMaxSampledPixels`, 8 M sampled pixels — precisely 32 frames' worth —
and the sampler that stopped at it was `SampleFrame`.

**What the honest bound was worth**, measured against the same clip
exported as an APNG, which quantises nothing and so is exactly the pixels
the scaler produced — a measurement of the *bound* change (loose slot
count → honest two-bound minimum), taken under the previous single-stride
scheme:

| recording | sample frames | PSNR |
| --- | --- | --- |
| 220 s 1428×616 → 714 px, 20 fps | 13 → 23 | 39.40 → 39.70 dB |
| 32 s 1160×860 → 800 px, 30 fps | 23 → 31 | 30.83 → 30.88 dB |
| 32 s 1160×860, 20 fps | 24 → 24 | 36.42 dB, byte-identical |

The third row is the point as much as the first two: where the slot count
was already the tighter bound, nothing changes at all. On the first row's
clip the shipped sampler seeds at the 64 cap (the estimate, 2428, is past
2048) and schedules 27 sample frames — denser than either column, so the
table's PSNR floor still holds.

**The progress split.** The 25 `PaletteProgressPercent` used to hold made
the bar sprint through the palette pass in the first few percent of the
time and then crawl for the rest.

## The paired preference write

From [Menu bar app](architecture.md#menu-bar-app).

The regression the rule came out of: one procedure wrote
`KnipsZoomOnClick` and `KnipsFollowMouse` together, back when both were
menu items, so a toggle of either reverted whatever had changed the other
meanwhile.

Measured at the time: with the paired write, an external
`KnipsFollowMouse=1` was back to `0` one *Zoom on Click* click later; with
the two writers separate, it survived. What that looked like from outside
was a preference that would not stay switched on — and, because Follow
Mouse then really was off, a region recording that did not pan.

Zoom on Click has since become an effect, and its writer is
`StoreEffectZoom`.

## The camera ride

From
[The composited window recording](architecture.md#the-composited-window-recording).

What the old origin anchor looked like on a resized window: a camera
docked into the top-right corner was dragged down with an origin it had
nothing to do with, and a top edge dragged down moved nothing at all, so
`IsCameraRideMovement` saw no work and left the same camera hanging out of
the top of the rectangle, straddling an edge it is supposed to be inside.

For a rectangle that only **translates** the corner anchor is
arithmetically identical to the old displacement — both edges move by the
same amount — so every region-pan row of the ride measurement still holds
unchanged.

**The ride, measured on device** by driving the app under `lldb` (no input
synthesised — the actions are the app's own selectors, and the recorded
window is one created in-process and moved with `setFrame…`):

| what moved | window moved by | camera moved by |
| --- | --- | --- |
| recorded window | +200, +150 | +200, +150 |
| recorded window | −320, −90 | −320, −90 |
| recorded window | 0, 0 | 0, 0 (the epsilon) |
| panned region | border −182, +298 | camera −182, +298 |
| panned region | border +10, +7 | camera +10, +7 |
| panned region | border +554, −192 | camera +554, −192 |
| panned region | border −477, 0 | camera −477, 0 |

The dock's own numbers, from the same run: a camera whose home is
(1596, 926), docking into a window at (300, 300, 900, 628), goes to
(996, 724) — the top-right corner inside it, inset by
`CameraWindowMargin` — and the stop puts it back at (1596, 926) exactly.

**Positioning the followers from the last completed update** was built as
the alternative to positioning them from the animator's intent, and
measured against it. Recording a region ride over a flat backdrop makes
the camera window's left edge the only structure in the picture, so a
threshold crossing tracks it to a fraction of a pixel:

| followers positioned from | camera edge deviation in the file |
| --- | --- |
| the animator's intent (shipped) | **max 1.4 px = 0.7 pt**, mean 0.11 px |
| the last *completed* update | **max 162 px = 81 pt**, 104 frames >8 px off |

The instrument that caught this also caught an earlier version of itself
being wrong: an "applied rectangle" poll that waited for nothing to be in
flight fired twice a second instead of thirty times, and reported a 626 pt
lag that did not exist. Logging ScreenCaptureKit's own sent/completed
counters alongside — they advance every tick, with zero refusals — is what
showed the framework was never the slow part.

## The circular camera

From [Menu bar app](architecture.md#menu-bar-app).

The switch to the circle is routinely *reported* as moving the centre of
the picture, so it was measured rather than argued. The camera window was
captured by window id in both shapes (`screencapture -l`), giving a
480×360 pixel rectangle and a 360×360 circle. Sliding a 240×240 patch of
the rectangle across and scoring SSIM against the middle of the circle
peaks **exactly at x = 60 px** — which is `(480 − 360) / 2`, the perfectly
centred crop — and falls away on both sides:

| crop x-offset (px) | 0 | 40 | 56 | 59 | **60** | 61 | 64 | 80 | 120 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SSIM | .613 | .659 | .729 | .805 | **.832** | .800 | .706 | .608 | .560 |

The peak is one device pixel wide — half a point — so the crop is centred
to the limit of the measurement. (It is .832 rather than 1.0 because the
two captures are different live frames of a person who moved.)

**The window's own shift against a screen edge**, measured: a circle at
x = 1596 on an 1800-point screen becomes a rectangle at x = 1560 rather
than the centred 1566, so the visual centre moves 6 points left, and the
round trip back to a circle lands at 1590 rather than 1596.

## Background blur

From [Background blur](architecture.md#background-blur).

**Radius.** Measured on a real 640×480 frame through the shipped chain, as
the mean absolute luma difference between pixels 1, 4 and 16 apart — the
last of which is the scale at which a room's objects read as objects —
expressed as a share of the unblurred source's own:

| radius | 1 px | 4 px | 16 px | |
| --- | --- | --- | --- | --- |
| 12 | 4.74 % | 11.15 % | 31.74 % | the old value |
| 24 | 3.10 % | 7.28 % | 21.14 % | |
| **28** | **2.81 %** | **6.60 %** | **19.21 %** | shipped |
| 40 | 2.33 % | 5.46 % | 16.02 % | |

The shipped kernel is 2.33× wider than the 12 it replaced and takes out
two fifths of the mid-scale structure that value left behind.

**The radius costs nothing measurable, and the way to see that is the
spread rather than the means.** `knips probe`, three runs at each radius on
an idle machine: **9.1 / 9.4 / 9.8 ms** a frame at radius 28 against
**7.6 / 9.3 / 9.8 ms** at radius 12. The ranges overlap almost entirely,
and Vision is ~78 % of each. The figure moves with what else the machine
is doing far more than with the radius: the same probe on a loaded machine
reports 15–19 ms at *both* radii.

**The budget.** This is the table that chose the shipped
`SegmentationStride` of 1; the verdict it produced is stated in
[architecture.md](architecture.md#background-blur). 120 frames of 640×480
BGRA through the real `TCameraBlur`, model load and kernel compile
excluded:

| quality | Vision every | ms/frame | fps ceiling | Vision alone | CPU |
| --- | --- | --- | --- | --- | --- |
| **fast** | **every frame** | **11.0** | **91** | **8.7 ms** | **45 %** |
| fast | every 2nd | 6.4 | 156 | 8.6 ms | 52 % |
| balanced | every frame | 24.1 | 42 | 21.6 ms | 40 % |
| balanced | every 2nd | 13.4 | 75 | 22.4 ms | 43 % |
| accurate | every frame | 59.9 | 17 | 57.4 ms | 28 % |

The CPU column falls as the frames get slower because more of the wall
time is spent waiting for the ANE.

**Mirroring**, measured from a 1280×960 screen capture and the layer
contents it was rendered into: the output's column-brightness profile
correlates **+0.905** with the *reversed* source and **−0.814** with the
source as it stands, and the mean absolute horizontal gradient collapses
from **8.31 to 0.29** — 28× less high-frequency energy, which is the blur.

## The Dock promotion

From [Dock and the main menu](architecture.md#dock-and-the-main-menu).

Measured on device with the playback window driven from an instrumented
build:

| | before | window open | after close |
| --- | --- | --- | --- |
| `NSApp.activationPolicy` | 1 (accessory) | 0 (regular) | 1 (accessory) |
| `lsappinfo` ApplicationType | UIElement | Foreground | UIElement |
| `lsappinfo front` | — | knips | — |
| `NSApp.mainMenu` items | none | 2 | 2 (kept) |
| status item has a window | yes | yes | yes |
| status item title / menu | `◉` / attached | `◉` / attached | `◉` / attached |

The three properties the promotion must not break were measured in the
same run. `performClose:` was sent to the window 1.5 s into a 16.8 s
export, from the run loop, exactly as the key equivalent does; it was
answered NO, and the export ran to completion — a `.gif` byte-for-byte
the same size as one produced with nothing interfering. Before
`windowShouldClose:` existed that path was *permitted*: the window went,
the export carried on writing through
nil-checks, and the demotion fired from inside `windowWillClose:` with the
export still holding the main thread. It worked, and it was one nil-guard
away from not working. ⌘Q at +3.0 s was refused, and the
`RefreshStatusItem` that follows the refusal left the status menu
detached. And a `Record` command with a playback window open measured
policy 0 and a visible window before `CommandRecordDisplay`, policy 1 and
no window after it and before the deferred start.

## Live effects

From
[Live effects](architecture.md#live-effects-zoom-on-click-and-follow-mouse).

The mechanism was proven against a lattice of known pitch — black bars 8
points wide at a pitch of 32, so at capture scale 2 the output pitch is
64 px at zoom 1 and 64·Z px at zoom Z:

| | measured |
| --- | --- |
| base rectangle | pitch 64.00 px on both axes |
| zoom 2 | pitch **128.00** px on both axes, output still 1024×768 |
| the ramp between | 64 → 73 → 82 → 104 → 113 → 127 → 128, the smoothstep shape |
| back to base | pitch 64.00, phase back to its starting value |
| a 200-point pan | phase moved 48 px; 200 pt × scale 2 = 400 px, and 400 mod 64 = 400 − 384, so −400 ≡ 48 (mod 64) |
| through `TLiveAnimator` itself | the window panned 341.00 → 0.00 points, matching the tested maths' own fixpoint to the hundredth; content phase moved 42 px, and 341 × 2 = 682 ≡ 42 (mod 64) |
| the writer | 1024×768 for every frame of every run; 0 dropped, 0 failed appends; 28/28, 41/41, 40/40, 25/25, 13/13 and 14/14 updates completed, none refused |

The three answers to fire-and-forget's sharp edge, exercised against a
refusal made reachable on demand by a source rectangle at an origin of
10⁹ points:

| | measured |
| --- | --- |
| accepted rectangle, then the same **+ 0.1 pt** | second one **deduped** — the epsilon still works when nothing went wrong |
| refused rectangle, then the same **+ 0.1 pt** | second one **sent** — the heal, twice over, at the same 0.1 pt delta the control deduped |
| five refusals in a row | live updates switched **off** at the sixth call, `live zoom/pan disabled: ScreenCaptureKit refused 5 source-rect updates in a row (last error -3812)`; every later call refused without sending |
| the recording, through all of it | 12 sent, 3 completed, 9 refused, and still 174 frames, 0 dropped, 0 failed appends, 1024×768 |

The two rows at the top are the same experiment with one variable
changed: identical delta, identical epsilon, opposite outcome, and the
only difference is whether the previous rectangle was refused.

**The border exclusion**, proven on device by recording a 200-point pan
twice, with 138 border moves in lockstep with 41 source-rectangle updates:
with the exclusion, **0** border-red pixels in all 141 frames; with the
exclusion deliberately switched off, **665 792** red pixels across the run
and 2 560 in the worst single frame. Re-measured since, on the app's own
paths and counting *lines* rather than pixels — a border edge in the file
is a full-width or full-height red run four pixels deep at 2×, which
screen content never is: with the exclusion, 0 such lines in the first 30
frames of a heavily panning region recording (drag path and Record Last
Region both); with the exclusion off and Follow Mouse forced on anyway, 22
of the first 30 frames carry them. With the exclusion off and the pan
refused, 0 again.

## The idle heartbeat

From [The idle heartbeat](architecture.md#the-idle-heartbeat).

What the uncapped stamp floor cost at `--fps=1`, where a frame is a whole
second and the heartbeat interval half of one: each beat landed at the
last stamp plus a second for half a second of wall time, and the movie ran
**ahead** of the clock — measured, an 11.6 s take reported **0.384 s**
long.

## Big Cursor

From [Big Cursor](architecture.md#big-cursor).

Measured on an M-series Mac, macOS 26, 1512×982 points at two pixels per
point:

| | measured |
| --- | --- |
| sprite | 140×200 px, hot spot 25,25; the arrow's opaque box inside it 53×92 at (19, 17) — 2.52× and 2.49× the system pointer's own 21×37, which is the 2.5 magnification |
| whole-display recording, pointer at global (946.59, 201.28) | predicted arrow box (1887, 395)–(1939, 486); found white body (1889, 396)–(1939, 485) — the two-pixel inset is the black outline, which is not white |
| the same recording with Big Cursor off | 90 white pixels in the *system* pointer's own predicted 21×37 box at (1891, 400), found (1891, 400)–(1909, 432) |
| live pan, four plateaus 130 points apart | the sprite at each plateau's predicted pixel, within 2 px, and **nothing at the previous plateau's** |
| the pathological ghost case: the sourceRect flipped between two positions 780 px apart every tick, 54 frames | every frame carried the arrow at exactly one of the two positions (≈700–850 white px there, ≈35–110 at the other, which is background and H.264 ringing). No ghosting |
| cost per frame | 2.05 µs for the pointer read, 300 µs for a 140×200 blit — 0.9 % of a 30 fps frame's budget, dev build, unoptimised |
| frame counts under an identical drive, 8 s | 107 frames with the sprite, 108 and 107 without; 0 dropped, 0 failed appends, 0 refused blits in every run |

## Export size estimates

From
[What an export is going to weigh](architecture.md#what-an-export-is-going-to-weigh).

### GIF: `K` = 14.9

Sixteen GIF exports over seven takes at four output widths. The column is
the ratio the fit is over: GIF bytes per output pixel, divided by the
source's bytes per source pixel-frame.

| take | native | 1512 px | 600 px | 400 px | 300 px |
| --- | --- | --- | --- | --- | --- |
| busy region | 27.6 | | 27.7 | | 28.0 |
| whole display | | 21.9 | 23.6 | | 23.6 |
| quiet region | 15.3 | | 17.6 | | 20.1 |
| fragmented take | | | 9.5 | | |
| small region | 8.8 | | 9.1 | | 9.1 |
| cursorless region | 8.7 | | | 10.2 | |
| take with audio | | | | 6.8 | |

`K` is the geometric mean of those, **14.9**.

**Why there is no downscale term.** Along each row the ratio barely moves
— at most +31 % across a fourfold linear reduction, and flat to within 2 %
for three of the seven takes — while down the column it spans 6.8 to 28.0.
Fitting `(sourcePixels/outputPixels)^a` gives `a = 0`, and forcing a
positive exponent makes the fit strictly worse: worst-case error 2.19× at
`a = 0`, 2.62× at `a = 0.2`, 3.70× at `a = 0.4`. Over the fourfold range
measured, content dominates the residual and the per-row trend (+8 % to
+31 %, rising with the reduction) was not worth a term; a second
independent sweep reaching 6.4× and 8× reductions found the same trend
continuing to grow at the far end, still second-order against a content
offset. Beyond fourfold the model is extrapolating.

**The band.** The worst GIF residual across those sixteen is 2.19×,
against a reported band of **3×**. The previous **2×** band was set from
five exports that were all halvings, and was exceeded the first time
somebody exported content unlike those five.

`--no-dither` lands at 0.61 of the dithered size (0.525 and 0.694 on two
takes).

### APNG: `K` = 33

APNG used to share the GIF's 3× band with a `K` of **59** and a claim that
"six exports over five takes fit within 1.5×" — which was a property of
those six exports rather than of APNG. Refitted over **twenty-eight**
exports of fourteen real takes (Retina UI, near-blank screens, region and
whole-display captures, each at its own width capped at 1200 px and again
at 600 px):

| | ratio |
| --- | --- |
| geometric mean (the new `K`) | **33** |
| range across the 28 | 2.6 to 302 — a factor of **117** |
| worst residual against `K` | **12.7×** |
| the old constant's worst residual | 22.8× |

Both ends are content and both are real: the nearly blank screens at one
end (three takes, 2.6 to 5.5), where the *movie* is large relative to the
APNG; and at the other a Retina whole-display take reduced threefold (220
to 302), captured at 3600×2338 and concentrated by the reduction into a
quarter of the pixels.

A downscale term was fitted for this too, and is not there for the same
reason it is not on the GIF path: over the same twenty-eight exports
`(sourcePixels/outputPixels)^a` bottoms out at `a = 0.3` and moves the
worst residual from 12.8× to 11.7×. The effect itself is real and small —
exporting the same take at 600 px rather than at its own width raises the
ratio by 25 % to 56 %, consistently, on every one of the fourteen takes.

**The band** is **8×**, which covers 23 of the 28. Six covers 21 and
thirteen covers all 28; thirteen is not chosen precisely because it would
cover all 28, and the five it misses at eight are the two named content
extremes rather than a scatter.

**The flat prior** for a source whose size is not known was refitted with
the same set: APNG's own bytes per output pixel-frame have a geometric
mean of **0.085**, against the **0.45** that constant used to hold. Its
worst residual is **84×**, against the content-aware model's 12.7×.

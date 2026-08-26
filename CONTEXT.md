# opname

Ubiquitous language for opname — a native macOS screen recorder.

## Language

### Capture

**Target**:
What is being recorded: a display, a region of a display, or a window.
_Avoid_: source (SCK uses it for the rect), input.

**Region**:
A rectangle in display points, relative to the display's origin, passed
to ScreenCaptureKit as the source rect.
_Avoid_: crop (implies post-processing), area, selection.

**Geometry**:
The resolved stream shape — pixel width/height, frame rate, cursor flag,
optional region — after scale and alignment are applied
(`TStreamGeometry`).
_Avoid_: config (SCStreamConfiguration is the framework object).

**Scale**:
Pixels per point. Auto-detected from the display's mode; overridable to
1 or 2.
_Avoid_: Retina toggle (Kap's name for the same thing), DPI.

**Stream**:
One running ScreenCaptureKit capture (`TScreenStream`).
_Avoid_: session (used for the recording as a whole), capture (the layer).

**Complete frame**:
A video sample buffer whose `SCStreamFrameInfoStatus` attachment is
`Complete`; only those reach the writer.
_Avoid_: valid frame, real frame.

### Output

**Writer**:
The AVAssetWriter-backed sink (`TMovieWriter`) that encodes and muxes.
_Avoid_: encoder (the writer owns one; opname never sees it), muxer.

**Container**:
`.mp4` (MPEG-4) or `.mov` (QuickTime), chosen from the output extension.
_Avoid_: format (ambiguous with pixel format), file type.

**Session**:
One recording start to finish (`TRecordingSession`), or one export start
to finish (`TGifExportSession`): resolve, open, run, finish.
_Avoid_: job, take.

### Export

**Export**:
Turning a finished recording into another format —
`opname export --in=… --out=….gif`. Never used for writing the
recording itself; that is the writer's job.
_Avoid_: convert, transcode (there is no re-encode to a movie).

**Trim**:
The time range of the input an export keeps, in seconds
(`--trim=start,end`). Applied by the reader as an `AVAssetReader`
`timeRange`, never by dropping frames afterwards.
_Avoid_: cut, clip, range (the last is the CoreMedia type).

**Decimation**:
Dropping input frames to reach the target rate, decided from each
frame's presentation stamp rather than a frame counter.
_Avoid_: downsampling (that is the pixel operation), throttling.

**Palette**:
The ≤256 colours a GIF's global colour table holds, chosen by median cut
over a histogram of sampled frames (`TGifPalette`).
_Avoid_: colour map, LUT.

**Delay**:
How long one GIF frame is shown, in centiseconds, derived from the gap
to the next frame's presentation stamp.
_Avoid_: frame duration (ambiguous with the movie's own), interval.

**Changed rectangle**:
The bounding box of the palette indices that differ from the previous
frame; every frame but the first is written as just that box, with
disposal "leave in place".
_Avoid_: dirty rect, delta frame.

**Transparency trial**:
Compressing a frame's rectangle a second time with the pixels that did
not change written as the reserved transparent index, and keeping
whichever of the two came out shorter.
_Avoid_: delta encoding, optimisation pass.

### Toolchain

**Runtime class**:
An Objective-C class assembled through libobjc's C API at start-up
(`Opname.ObjC.Runtime`), as opposed to an `objcclass` declared in
Pascal.
_Avoid_: dynamic class, fake class, shim.

**Probe**:
`opname probe` — the on-device check that the runtime class registers,
ScreenCaptureKit enumerates, and AVAssetWriter opens.
_Avoid_: smoke test (too generic), self-test.

**Vendored unit**:
A unit under `source/capture/` carried from lantaarn with its contents
unrestyled; opname's additions live in marked blocks.
_Avoid_: fork, copy.

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
One recording start to finish (`TRecordingSession`): resolve, open, run,
finish.
_Avoid_: job, take.

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

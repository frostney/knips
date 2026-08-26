# Porting notes: lantaarn → Knips

What was carried from lantaarn's capture core into a recorder, what
changed, and why. Written for whoever extends this next.

## Executive Summary

- Three units are vendored: the CoreMedia/CoreVideo/VideoToolbox/GCD
  bindings (renamed `Knips.Capture.CoreMedia`), the ScreenCaptureKit
  external declarations, and the pthread mutex. The two encoders are
  deliberately not carried.
- The FPC-defined `TSCKOutputHandler` — the reason lantaarn kept SCK
  out of its default build — is replaced by a runtime-built class.
- Timestamps come from the sample buffer, not a frame counter; that is
  the one semantic change a recorder forces on the streaming design.
- AVAssetWriter replaces the VideoToolbox session + wire framing; there
  is no muxer to write.
- Two things in the carried code are flagged as unverified rather than
  fixed: the AudioEncoder's symbol convention and the exact SCK protocol
  registration behaviour.

## lantaarn, as found

`Lantaarn.Capture.ScreenCaptureKit` was complete and vendored but out of
the default build because `TSCKOutputHandler` (an `objcclass` subclass
of `NSObject`) made FPC emit Objective-C method-list metadata that
ld-prime rejects without `-ld_classic`. The default path was
`CGDisplayCreateImage` → `TVideoEncoder` (VideoToolbox) → Annex-B frames
tagged for a WebSocket. `TVideoEncoder` stamped frames as
`CMTimeMake(FFrameIndex, FFPS)`.

## Decisions

### Runtime-built output object instead of `objcclass`

The only thing SCK needs is an object that responds to
`stream:didOutputSampleBuffer:ofType:`. `Knips.ObjC.Runtime` assembles
one with `objc_allocateClassPair` / `class_addIvar` / `class_addMethod`
/ `objc_registerClassPair` (all in FPC's RTL `objc` unit) and a plain
`cdecl` Pascal routine as the method body. No FPC ObjC metadata is
generated, so the default build links clean and SCK is *in* it — which
is what makes region and window capture possible at all.
[ADR-0002](adr/0002-runtime-built-objc-classes.md).

### AVAssetWriter owns encoding and muxing

The streaming encoder converted AVCC → Annex-B and prepended a wire
tag; a file wants AVCC in an `avcC` box with a sample table. Rather than
port a muxer, knips appends SCK's BGRA sample buffers to an
`AVAssetWriterInput` with H.264 output settings, exactly as Kap's
Aperture did. `Lantaarn.Capture.VideoEncoder` and `AudioEncoder` are
therefore not carried; the bindings unit they used is, renamed to say
what it actually binds. [ADR-0001](adr/0001-avassetwriter-owns-encoding.md).

### Timestamps from the buffer

SCK emits frames when content changes, so a frame-counting PTS makes
idle periods play back fast. `TMovieWriter` starts the session at the
first buffer's `CMSampleBufferGetPresentationTimeStamp` and lets each
buffer carry its own. Added to the vendored CoreMedia unit under the
`knips additions` banner.

### Complete-frame filter

SCK tags every video buffer with `SCStreamFrameInfoStatus`. lantaarn
only checked for a non-nil image buffer; Knips also requires
`Complete`, so idle/blank/suspended buffers never reach the writer.

### Bindings added to the SCK unit

`SCDisplay.frame`, `SCWindow.frame/owningApplication/isOnScreen/
windowLayer`, `SCRunningApplication.processID`,
`SCContentFilter.initWithDesktopIndependentWindow:`,
`SCStreamConfiguration.setSourceRect:/setScalesToFit:`, the frame-status
key and values. `TSCKOutputHandler`, `TSCKCapture`, and the
`SCStreamOutputProtocol` declaration are removed. The block types and
run-loop-pumped completion pattern are unchanged.

Microphone capture (macOS 15) added three more, each checked against
`SCStream.h` in the current `MacOSX.sdk` rather than from memory:
`SCStreamOutputTypeMicrophone`, `SCStreamConfiguration.
setCaptureMicrophone:` and `setMicrophoneCaptureDeviceID:`. The output
type's *value* matters and is not written in the header as a number —
the `SCStreamOutputType` `NS_ENUM` lists `Screen`, `Audio`,
`Microphone` with no explicit initialisers, so `Microphone` is 2. It
sits in the `knips additions` const block with that derivation written
down, because a future SDK inserting a case would silently change it.
`processID` is declared `cint32`, which is what `pid_t` is on Darwin
(verified against the SDK's `SCShareableContent.h`). It is the only
reliable way to recognise this process's own windows: `applicationName`
is a display name and reads `Knips` under the app bundle but `knips-bin`
from the shell, so the Record Window submenu's own-window filter cannot
be built on it.

### The rename reached the vendored units too

The project shipped its first milestones under the name *opname*, and the
vendored units carried that prefix: `Lantaarn.Capture.*` became
`Opname.Capture.*`, and with the rename to Knips they became
`Knips.Capture.*`. Both passes touched only the unit header, the `uses`
clauses, and the `knips additions` banner — never a line of carried body.
That is the same seam the units were vendored along in the first place,
so `source/capture/**` stays outside `lwpt format` and a diff against
lantaarn still reads as it did on day one.

### No cthreads, no duetto

lantaarn needed `cthreads` for duetto and could afford it because its
default capture path was in-process. Knips has no duetto and does need
SCK, so it returns to the prototype's shape: `cmem` first, pthread
mutexes, no exceptions on the capture queue. One addition:
`IsMultiThread := True` at startup, so the RTL's refcount updates use
locked instructions on the GCD thread. Unverified on hardware; see the
spike.

## Verified

- Neutral units: 27 assertions across two suites, `lwpt test` green on
  Linux.
- Every Darwin unit and the program type-check for `aarch64-darwin` with
  an FPC 3.2.2 cross compiler against the real `MacOSAll`/`CocoaAll`
  ([docs/tooling.md](tooling.md)).
- `lwpt format --check`, `lwpt build` (Linux shell binary) green.

## Not verified — needs a Mac

Listed in [spikes/0001-runtime-objc-class.md](spikes/0001-runtime-objc-class.md).
Also noted, in carried code that Knips does not compile today:
`Lantaarn.Capture.AudioEncoder` declares `cdecl; external name
'AudioConverterNew'` without the leading underscore that every other
Darwin binding (and FPC's own `univint/AudioConverter.pas`) uses. Whether
that ever linked is unknown; when audio lands (milestone 4), use
MacOSAll's `AudioConverter` bindings and drop the hand-written ones.

## Next

- `knips probe` and a real recording on Apple silicon — clears the spike.
- Menu bar + region overlay on the same runtime-class primitive.
- GIF export in pure Pascal (testable on Linux).
- Audio as a second writer input from SCK's audio output.

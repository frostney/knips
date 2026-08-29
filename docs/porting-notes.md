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
- The one bet the port rested on — that ScreenCaptureKit accepts a
  runtime-registered class as a stream output — is **closed on device**
  ([spike 0001](spikes/0001-runtime-objc-class.md)), so nothing in the
  carried path is asserted rather than proven any more.
- One thing in it was wrong and is fixed: the pthread mutex declared its
  opaque storage as bytes, which under-states `pthread_mutex_t`'s 8-byte
  alignment and made every `--mode release` build bus-error. See
  [pthread opaque storage is 8-byte aligned](#pthread-opaque-storage-is-8-byte-aligned).

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

The live recording effects added one more:
`SCStream.updateConfiguration:completionHandler:`. It is declared inside
`@interface SCStream` in `SCStream.h` with no availability annotation of
its own, and the interface is `API_AVAILABLE(macos(12.3))` — as old as
`SCStream` itself, and three major versions below the project floor. Its
completion handler is `nullable void (^)(NSError *)`, exactly the shape
of `startCaptureWithCompletionHandler:`, so it takes the vendored
`TSCErrorBlock` and a global `cdecl` procedure like the other two.
`knips probe` still asks the runtime whether the selector is there before
anything sends it: an unrecognised selector is an Objective-C exception
no Pascal handler can catch, and this one would be sent into a live
recording thirty times a second.

### Everything under the `knips additions` banner

`source/capture/Knips.Capture.CoreMedia.pas` is the unit the additions
accumulate in, and the banner is the only place they may go. The whole list,
so that a future reader can tell an addition from carried code without
diffing against lantaarn — one line each for what it is *for here*:

| declaration | what it is for in knips |
| --- | --- |
| `CMSampleBufferGetPresentationTimeStamp` | the frame's own stamp; a recorder cannot count frames, because SCK only delivers on a change (see above) |
| `CMSampleBufferGetDuration` | the length carried across when a colliding frame is retimed, so the copy describes the same span the original did |
| `CMSampleBufferDataIsReady` | refuses an audio buffer whose data has not landed; appending one fails `AVAssetWriter` terminally, video track included (`TMovieWriter.AppendAudioTo`) |
| `CMSampleBufferIsValid` | asked of the *held* frame before the idle heartbeat re-appends it — SCK is not documented to invalidate a buffer the client still holds, and this is what says so out loud instead of failing the writer for good |
| `CMTimeGetSeconds` | every duration and stamp the reports carry, in the reader, the writer and the trim |
| `CMClockGetHostTimeClock`, `CMClockGetTime`, and the `HostClockSeconds` helper on top of them | the sidecar's clock. The cursor is sampled on the main thread and has to be placed on the movie's timeline; reading the clock SCK stamps its frames against is what makes `event.t − anchor.host` exact rather than approximate ([event-sidecar.md](event-sidecar.md), "The clock"). Recovery reads the same clock for the trailer it writes |
| `CMTimeCompare` | the one comparison on the capture queue: a frame arriving at or behind the last appended stamp is retimed one tick forward rather than handed to the writer out of order, which would end the recording |
| `CVPixelBufferGetPixelFormatType`, `CVPixelBufferIsPlanar` | Big Cursor's layout check — see the section below |
| `AudioStreamBasicDescription`, `kKnipsAudioFormatLinearPCM`, `kKnipsAudioFormatFlagIsFloat`, `CMAudioFormatDescriptionGetStreamBasicDescription` | the audio-silence check. A track that was enabled and came out silent is the failure nobody notices until the take is unrepeatable, and reading the samples is the only way to know; the format description is what says whether the bytes are 32-bit floats, so nothing guesses at a layout it was not told |
| `CMSampleBufferCreateCopyWithNewTiming`, `CMSampleBufferRetain`, `InvalidCMTime` | the idle heartbeat — see the section below |

Two shapes in that list are worth knowing before adding to it.
`CMSampleBufferRetain` is an alias for `_CFRetain`, the way
`CMSampleBufferRelease` already aliases `_CFRelease` in the carried code.
And `InvalidCMTime` is *built*, not bound: `kCMTimeInvalid` is documented as
an all-zero structure, so a local function is one fewer external global to
get wrong. There is no `CMTimeIsValid` here and nothing needs one — validity
is asserted by setting `kCMTimeFlags_Valid`, which the carried
`kCMTimeFlags_*` constants already provide.

### Two CoreVideo checks for Big Cursor

Big Cursor writes into the frame's `CVPixelBuffer` on the capture queue,
so it needs the buffer to be what the stream configuration asked for
rather than assumed to be. `CVPixelBufferGetPixelFormatType` and
`CVPixelBufferIsPlanar` went into the CoreMedia unit's `knips additions`
banner beside the lock/base-address/stride calls that were already
carried; both are plain C functions with the same `CVPixelBufferRef`
first argument as their neighbours. Nothing else about that unit
changed. A wrong assumption here is a write into somebody else's memory,
not a wrong colour, which is why it is checked on every frame rather than
once (`Knips.Recording.CursorOverlay.DrawInto`).

### One CoreMedia call for the idle heartbeat

`CMSampleBufferCreateCopyWithNewTiming` went into the same `knips
additions` banner, with `CMSampleBufferRetain` (an alias for `_CFRetain`,
the way `CMSampleBufferRelease` already aliases `_CFRelease`) and a local
`InvalidCMTime` helper. The heartbeat re-appends the last delivered frame
with a fresh presentation stamp, and this is the one call that makes that
possible without touching a pixel: the copy shares the original's image
buffer and differs only in its `CMSampleTimingInfo`. Its signature is the
same shape as `CMSampleBufferCreateReady`, which the unit already carried,
and it uses the `CMSampleTimingInfo` record and `CMItemCount` type that
were already there. `kCMTimeInvalid` is documented as an all-zero
structure, so it is built rather than bound — one fewer external global
for one fewer thing to get wrong. Nothing else about the unit changed.
See [architecture.md](architecture.md), "The idle heartbeat".

### The rename reached the vendored units too

The project shipped its first milestones under the name *opname*, and the
vendored units carried that prefix: `Lantaarn.Capture.*` became
`Opname.Capture.*`, and with the rename to Knips they became
`Knips.Capture.*`. Both passes touched only the unit header, the `uses`
clauses, and the `knips additions` banner — never a line of carried body.
That is the same seam the units were vendored along in the first place,
so `source/capture/**` stays outside `lwpt format` and a diff against
lantaarn still reads as it did on day one.

### pthread opaque storage is 8-byte aligned

lantaarn declared the mutex as one byte array:

```pascal
TPThreadMutex = record
  _opaque: array[0..PTHREAD_MUTEX_OPAQUE_SIZE - 1] of Byte;
end;
```

A record whose only field is a `Byte` array has **alignment 1**, so FPC
is free to place it at any offset inside a containing record or class.
`pthread_mutex_t` is not alignment-1: Apple's `_opaque_pthread_mutex_t`
(`sys/_pthread/_pthread_types.h`) leads with `long __sig`, and
`libsystem_pthread` reaches that word with `casa`, an atomic that faults
with `SIGBUS` on an unaligned address. The declaration therefore
under-stated the type's real alignment for as long as it existed; the
field only ever happened to land on a multiple of eight.

`lwpt build --mode release` compiles with `-O4`, which is `-O3` plus the
optimisations FPC labels "might have unexpected side effects". One of
them is `ORDERFIELDS`, which reorders **class** fields by alignment
(plain records keep their declaration order — measured, and the reason
`CMTime` and the other C-shaped records here are not at risk). Given a
field that claims to need alignment 1, reordering puts it where the
padding is: in `TCameraBlur` it moved `FLock` from offset 224 to **231**,
and `knips probe` died in `pthread_mutex_destroy` with
`EBusError: Bus error or misaligned data access` at the end of
`ProbeCameraBlurCost` — that being the first path in the program that
destroys one of these mutexes. The dev build does not enable
`ORDERFIELDS`, kept the aligned offset, and stayed green, which is what
made this look like an optimiser bug. It is not one. A twenty-line
program says so:

```
class { A, B: Pointer; Flag1, Flag2: Boolean; N: LongInt; D: Double; M }
                 -O1/-O3   -O4
M: array of Byte     40     38   ← misaligned
M: array of QWord    40     32
```

Nor is the crash new in `71aad18`: every release build back to
`7e6d70c`, the first commit that ran on device, dies the same way —
before `TCameraBlur` existed it was `TMovieWriter.FLock`, hit two lines
later in the same `probe`. Release mode had simply never been run.

The fix is to declare the storage in the width the type is actually
aligned to, in both this unit and `Knips.ThreadManager` (whose
`TRawAttr`, `TEventRec.Mutex` and `TEventRec.Cond` had the same shape):

```pascal
_opaque: array[0..PTHREAD_MUTEX_OPAQUE_QWORDS - 1] of QWord;
```

The record is the same 128 bytes, every call site still passes `@Mutex`,
and the record's alignment is now 8 in every mode — so no field
placement, reordered or not, can produce an address libsystem cannot
use. Suppressing the optimisation instead would have left the real
defect in place for the next field that lands on an odd offset.

### No cthreads, no duetto

lantaarn needed `cthreads` for duetto and could afford it because its
default capture path was in-process. Knips has no duetto and does need
SCK, so it returns to the prototype's shape: `cmem` first, pthread
mutexes, no exceptions on the capture queue. One addition:
`IsMultiThread := True` at startup, so the RTL's refcount updates use
locked instructions on the GCD thread. Unverified on hardware; see the
spike.

## Verified

- Neutral units: **523 test cases across sixteen co-located suites**,
  `lwpt test` green on macOS and on Linux in `tools/linux-ci.sh`. The
  carried code is the framework glue and nothing else; everything decidable
  was moved out of it and is now tested on every host.
- Every Darwin unit and the program type-check for `aarch64-darwin` with
  an FPC 3.2.2 cross compiler against the real `MacOSAll`/`CocoaAll`
  ([docs/tooling.md](tooling.md)).
- `lwpt format --check`, `lwpt build` (Linux shell binary) green.
- On device: `knips probe` and a real recording that plays back, which is
  what closed [spike 0001](spikes/0001-runtime-objc-class.md) and struck
  "asserted, not proven" from ADR-0002.

## Not verified — needs a Mac

The ledger is [spikes/0001-runtime-objc-class.md](spikes/0001-runtime-objc-class.md),
and everything load-bearing in it is closed. What is left there is the
camera window's look and feel, which is gated on a camera grant this
machine has never been given.

`Lantaarn.Capture.AudioEncoder` used to be listed here for declaring
`external name 'AudioConverterNew'` without the leading underscore every
other Darwin binding uses. It is moot: audio landed through
AVAssetWriter's own AAC encoder, the unit was never carried into
`source/capture/`, and there is no `AudioConverter` call anywhere in
knips.

## Next

The lantaarn port itself is finished — all three vendored units are in
the shipping build and nothing is waiting on a decision from that side.
What is still open is what a *second* platform does with them, and that
is a different document:

- The vendored units are macOS bindings and stay that way. A Windows or
  Linux backend gets its own directory beside them rather than an
  abstraction over them ([ADR-0005](adr/0005-windows-linux-ports.md),
  [ports.md](ports.md)).
- `CGRect` in `TRecordingSession.UpdateSourceRect` is the one macOS type
  left in the session signature, and should become a neutral rectangle in
  `Knips.Options` before a second backend exists.

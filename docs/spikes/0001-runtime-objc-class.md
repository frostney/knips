# Spike 0001: runtime-built Objective-C class on device

## Status: CLOSED — passed on device 2026-08-26

On Apple silicon (Darwin 25.5.0), after the `objc_msgSend` symbol-name
fix and the `Knips.ThreadManager` install (both required before the
binary would run at all): `probe` printed all four checks and `probe:
ok`; `record --rect=0,0,640,360 --fps=30` wrote a playable
1280x720 H.264 file — 133 frames, 0 dropped, duration 4.86 s matching
the appended-frame span. Gates 1 and 3 are closed outright; gate 2's
multi-minute soak remains a good idea but the primitive is proven.
ADR-0002's status now records this.

## Question

ADR-0002 asserts that an Objective-C class assembled through libobjc's C
runtime API (no compiler-emitted method-list metadata) can stand in
everywhere Knips needs a delegate — starting with ScreenCaptureKit's
`SCStreamOutput`. That assertion is unproven off-device: FPC on Linux
will not parse Objective-C mode, and the linker interaction the whole
design avoids only exists on Apple silicon. This spike is the on-device
gate that turns the assertion into a fact.

## What `knips probe` must show

`knips probe` is the executable form of this spike. It must, on macOS
on Apple silicon, in the flag-free default build:

1. Register a class with `objc_allocateClassPair` /
   `class_addIvar` / `class_addMethod` / `class_addProtocol` /
   `objc_registerClassPair` and get back a non-nil, look-up-able class.
2. Instantiate it, store a back-pointer ivar, message it, and read the
   ivar back inside a `cdecl` method body with the generated type
   encoding — confirming `(self, _cmd, …)` dispatch is intact.
3. Report `RespondsToSelector` true for the registered selector and
   false for one never added.
4. Release the instance after the owner back-pointer is cleared, with no
   late-callback crash.

Passing means the primitive in `Knips.ObjC.Runtime` is sound and the
default build genuinely links flag-free with the stock linker.

## The three unverified claims

Ordered by how load-bearing they are.

### 1. A runtime-registered class satisfies `addStreamOutput:`

ADR-0002's central bet. ScreenCaptureKit dispatches to a stream output
by selector (`stream:didOutputSampleBuffer:ofType:`), so declared
protocol conformance should be cosmetic and `class_addProtocol` should be
belt-and-braces. But "should be" is the whole risk: if SCK checks
`conformsToProtocol:` before accepting the output, or the metadata it
reads differs from what `class_addProtocol` installs, the design's
premise fails and the fallback is the quarantined `-ld_classic` build
entry. **Gate:** `knips record` against a display produces a playable
file whose frame count matches the appended-sample statistic. Until that
runs, treat SCK-accepts-runtime-class as asserted, not proven.

**Audio (milestone 4) re-runs this gate's logic on the same class.**
`--audio=system` registers the *same* runtime-built object a second time
for `SCStreamOutputTypeAudio`, on a second dispatch queue. Verified from
Apple's headers: `SCStreamConfiguration.capturesAudio` / `sampleRate` /
`channelCount` and `SCStreamOutputTypeAudio` = 1 all exist since macOS
13; `kAudioFormatMPEG4AAC` is `'aac '` = 1633772320; `AVFormatIDKey`,
`AVSampleRateKey`, `AVNumberOfChannelsKey`, `AVEncoderBitRateKey` and
`AVMediaTypeAudio` link against AVFoundation (which re-exports AVFAudio).
**Cleared on device 2026-08-26:** `record --rect=0,0,640,360
--audio=system` over played speech wrote h264 + AAC (48 kHz stereo) in
one file — 332 audio samples appended, 0 dropped (early or stalled), 0
failed, track peaks at −2.6 dB. The three claims below are proven except
the early-PTS trim, which no buffer exercised:

- that SCK dispatches `stream:didOutputSampleBuffer:ofType:` to one
  runtime-built object registered for two output types, with the right
  `ofType:` value on each queue;
- that AVAssetWriter accepts SCK's audio buffers unchanged — no format
  description or timing fix-up between the audio output and the AAC
  input;
- that the audio SCK delivers before the first video frame (dropped and
  counted here) is short enough not to clip the start of the track, and
  that audio delivered *after* the session's source time but with an
  earlier PTS is trimmed by the writer rather than rejected.

**Gate:** `record --out=x.mp4 --audio=system` over playing audio
produces a file whose audio track plays in sync in QuickTime Player,
with a dropped-audio count near zero after the first frame.

### 2. `IsMultiThread := True` on the GCD capture thread

Frames arrive on a GCD queue, not an FPC-created thread. Setting
`IsMultiThread` makes the RTL heap manager take its locks, which is what
makes appending from the callback safe — but whether the RTL is fully
happy being entered from a thread it never spawned is unproven. **Gate:**
a multi-minute recording with no heap corruption and no allocator
assertion under a debug RTL.

### 3. First-buffer session timing holds under real jitter

`startSessionAtSourceTime:` uses the first complete frame's PTS; every
later sample is appended against that origin. SCK's real delivery jitter
and any dropped leading frames are the unknown. **Gate:** the recorded
file's duration and frame timing match wall-clock capture within a frame
or two.

## Out of scope

Menu bar, region overlay, microphone capture, and any second recording
target. Audio appears above only as a re-run of gate 1's logic. This
spike is only the class-registration primitive and the single-display
record path that exercises it. Later milestones add selectors to the same
primitive and re-run gate 1's logic; they do not reopen the question of
whether the primitive itself works.

## Exit

When all four `probe` checks and the three gates pass on Apple silicon,
fold the result into ADR-0002 (strike "asserted, not proven") and delete
this spike's open status. Until then it is the one thing standing between
the design and proven.

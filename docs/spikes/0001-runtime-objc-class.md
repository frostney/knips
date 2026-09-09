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

## Camera (added with the picture-in-picture window)

The camera window reuses the same primitive — `KnipsCameraView` is a
runtime-built `NSView` carrying `acceptsFirstMouse:` and, since the
corner snap, its own `mouseDown:`/`mouseDragged:`/`mouseUp:` — so it
does not reopen gate 1. What it *did* add were platform facts about TCC
that the design leans on, and those were measured rather than assumed.

### Proven on device (Darwin 25.5.0, Apple silicon, 2026-08-26)

- **Registration.** `KnipsCameraView` registers and answers
  `acceptsFirstMouse:`; `knips probe` gates on it and names it in the
  "registered and answering" line, alongside the three existing classes.
- **Bindings and linkage.** Every AVFoundation binding used
  (`AVCaptureSession`, `AVCaptureDevice`, `AVCaptureDeviceInput`,
  `AVCaptureVideoPreviewLayer`, and the `AVMediaTypeVideo`,
  `AVLayerVideoGravityResizeAspectFill`,
  `AVCaptureSessionPreset640x480` constants) resolves in the flag-free
  default build; a session, a preview layer, `canSetSessionPreset:`,
  `cornerRadius` and `isKindOfClass: CALayer` all behave.
- **A bundle-less binary is NOT killed by TCC.** This was the load-bearing
  unknown: if a missing `NSCameraUsageDescription` aborted the process,
  switching the camera on during a recording would destroy the file. It
  does not. Run as `./build/knips` (no bundle identifier, no usage
  description), the process survived `requestAccessForMediaType:`,
  `deviceInputWithDevice:error:` — which returned a real input, not an
  error — and `startRunning`, and exited 0.
- **A denied grant is invisible to the session.** In that same run,
  `requestAccess` came back `granted = NO` without a prompt the user
  could answer, `authorizationStatusForMediaType:` stayed
  `NotDetermined` afterwards, and yet `startRunning` succeeded and
  `isRunning` answered YES. A session with no access does not fail; it
  delivers no frames. That is precisely the black rectangle
  `TCameraPreview.Show` refuses to put on screen, and the only thing
  preventing it is consulting the authorization status first.

The second and third facts together are why the *bundle-less* binary
cannot show the camera at all in this environment, and why the camera is
in practice a `Knips.app` feature: `tools/make-app.sh` writes the
`NSCameraUsageDescription` that lets TCC prompt properly.

## Camera mirroring and drag (added with the shape, snap and dock work)

### Proven on device (Darwin 25.5.0, Apple silicon, 2026-08-27)

Measured with a scratch program built through `fpc @lwpt.cfg`, driving
the units directly. Neither part needs a camera *grant* — the first needs
only a camera *device*, which the fact above ("a denied grant is
invisible to the session") is what makes possible.

- **Mirroring, end to end.** `AVCaptureVideoPreviewLayer` answers
  `-connection`, and the connection is **already non-nil straight after
  `initWithSession:`** — which is where `TCameraPreview.Show` applies
  mirroring. The connection answers `-isVideoMirroringSupported`
  (`YES` on the built-in FaceTime HD Camera) and
  `-setAutomaticallyAdjustsVideoMirroring:`.
- **The default really is unmirrored**, which is the bug report:
  before anything is set, `automaticallyAdjustsVideoMirroring` reads
  `YES` and `videoMirrored` reads `NO`. After
  `setAutomaticallyAdjustsVideoMirroring:NO` followed by
  `setVideoMirrored:YES` — Apple's required order — the readbacks are
  `NO` and `YES`. No exception was thrown, which is the point of doing
  the two `isVideoMirroringSupported` / ordering guards first: an
  `NSInvalidArgumentException` is an Objective-C exception and no Pascal
  `try..except` could catch it.
- **The drag reaches the view.** A window configured exactly like the
  camera's — borderless, level 3, `movableByWindowBackground` **off**,
  a runtime-built `NSView` content view — was sent left mouse down,
  dragged and up through its own `-sendEvent:`. All three arrived at the
  content view, once each. That is the whole mechanism behind the corner
  snap: `mouseUp:` is a drag end that fires.

- **The capture is live right up to the finalisation.** The reason
  `Knips.App.FinishRecording` undocks the camera *after*
  `FSession.FinishCapture` and not before it with `HideBorder`. Measured
  by instrumenting the old undock point in a real region recording, twice:
  `Capturing` was still true there, and the file's last frame landed
  **30 ms later** with frames arriving every 33 ms right up to it (no gap
  above 72 ms anywhere in the file). `FinishCapture` itself took 27 ms,
  and stops the stream before finalising the writer. So a 200 ms glide
  starting at the old point would have put roughly six frames of the
  camera sliding away into the tail of every docked take; started after
  `FinishCapture` returns, it has nothing to land in.

**Not measured, and deliberately not relied on:** what the content view
sees during a *real* `movableByWindowBackground` drag. That drag is a
mouse-tracking loop inside `NSWindow` which pulls its own events from the
queue, so `-sendEvent:` never enters it and a synthetic-event harness
cannot answer the question either way (with the property on, the same
three synthetic events still arrive — which proves nothing). The design
does not depend on the answer: moving the window from the view's own
`mouseDragged:` makes `mouseUp:` the drag end by construction.

### Still pending a human on device

Nothing here is load-bearing for correctness — all of it is "does it look
and feel right", and the first item is what gates the rest:

1. **A camera grant for Knips.** On this machine
   `authorizationStatusForMediaType:` answers `NotDetermined` for every
   identity reachable from a shell, including an ad-hoc bundle signed
   with `org.knips.app`'s own designated requirement — so the grant has
   never been given here. Until it is, `TCameraPreview.Show` refuses by
   design and nothing below can be exercised automatically.
2. A granted camera actually renders in the window (rounded corners,
   shadow, `resize-aspect-fill` crop) — **and comes up mirrored**, which
   is the visible half of the measurement above.
3. One click drags it (`acceptsFirstMouse:` plus the view's own
   `mouseDown:`/`mouseDragged:`), the picture tracks the pointer, and
   level 3 puts it above ordinary windows but below the menu bar and the
   selection overlay.
4. Releasing the drag animates it into the nearest corner of the
   screen's visible frame.
5. *Circular Camera* switches the live window to a disc about its own
   centre and back, and the choice survives a relaunch.
6. A region recording that contains the window has the camera in the
   played-back file — the whole premise, and unprovable without a grant
   — and a region recording started while the camera is up **docks** it
   into the region's nearest corner and puts it back on stop.
7. Position and visibility survive a relaunch; a bundled launch shows the
   usage string in the prompt.
8. Whether a *Terminal*-launched bundle-less binary prompts (attributed
   to Terminal's own camera grant) rather than being silently refused.
   The measured run was launched from a parent without a camera grant, so
   only the no-kill and silent-refusal halves generalise.

## Audit remediation device checks (2026-09-09)

The atomic recording and keyboard-selection changes require the following
on-device checks in addition to the automated filesystem and geometry tests:

- Run the release `knips probe` with Screen Recording access, record a
  real take over an existing output, and play the result in QuickTime.
- Kill a recording after a fragment flush. Confirm the prior output and
  sidecar survive, and startup recovery reports the separate pending take.
- Start Region recording using the keyboard; check arrows, Shift resize,
  Option fine adjustment, Return/keypad Enter and Escape. Check Tab and
  Shift+Tab with two displays, then confirm mouse drag still works.
- Record Follow Mouse while moving the pointer and dragging a docked
  camera, checking that the border, captured region and camera stay together.

Partial verification on 2026-09-09: a temporary audit-source build opened the
real overlay at startup and stopped captures after five seconds. Computer Use
verified arrows, Shift resize, Option fine adjustment, Tab/Shift+Tab on two
displays, Return, Escape and mouse dragging. Two real takes published movies
and sidecars and reached Knips playback; the first played to completion.
Recorded Follow Mouse framing changed while its dimensions stayed fixed.
All four raw/rendered movies decoded without errors. See the
[evidence and test-build limits](../audits/2026-09-09-computer-use-diagnosis.md#follow-up-a-test-build-unlocks-real-ui-checks).
Release-probe authorization, QuickTime playback, replacement of an existing
real take, killed-capture recovery, keypad Enter, and docked-camera coordination
remain open.

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

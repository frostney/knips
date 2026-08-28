unit Knips.Recording.Heartbeat;

// The idle heartbeat's arithmetic, with no framework in it at all.
//
// ScreenCaptureKit delivers a frame only when the captured content
// changes. A screen that goes still therefore stops producing frames, and
// because the movie's timeline is built out of the frames' own
// presentation stamps, the movie stops with it: measured on this project,
// a 5.69 s recording of a still screen produced one frame and a movie
// spanning 0.000 s, and a real 17.54 s take came out as 4.26 s with three
// of its four clicks past the end of the file. Suppressing the pointer
// (Smooth Cursor, which every raw take uses) makes it the common case,
// because pointer motion no longer counts as a change.
//
// The fix is to re-append the last delivered frame with a fresh stamp
// whenever nothing has been appended for a while, so the file keeps pace
// with the wall clock. This unit is the part of that which can be decided
// without a frame in hand: is one due, and what stamp should it carry.
//
// Everything here is in seconds on one clock — ScreenCaptureKit's host
// clock, the same one the frames' stamps and the event sidecar's sample
// times come from (Knips.Recording.Sidecar). Nothing here reads a clock
// itself: the caller passes the moment, which is what makes it testable
// off-device and what keeps the Darwin side down to "read the clock once,
// then ask".

{$I Knips.inc}

interface

const
  // Seconds. How long the movie may fall behind the wall clock before the
  // last frame is repeated into it.
  //
  // Half the one-second ceiling this was allowed, for two reasons and one
  // non-reason.
  //
  // The gaps it leaves are unambiguously sub-second (the callers tick at
  // 30 Hz, so the worst gap is this plus a thirtieth), which is the range
  // the render pass's frame interleaving is built for: an effect window
  // that opens inside a still stretch — a click that zooms — always has a
  // real frame within half a second on either side to animate between.
  // And a take killed with SIGKILL keeps its idle stretch, because the
  // heartbeat frames are in the fragments the recovery pass re-muxes;
  // without them the last two seconds before the kill can be empty.
  //
  // The non-reason is size. A repeated frame is a P-frame of an identical
  // picture, and the keyframe interval is counted in frames rather than
  // seconds (Knips.Export.MovieWriter), so a minute of stillness at this
  // rate is 120 appended frames — one keyframe interval. Measured against
  // the same still screen recorded at the same instant by a build without
  // the heartbeat: 1280x800, thirty seconds, 57 heartbeats, 77.6 kB — 1.4
  // kB a frame, 2.6 kB a second of stillness, against a 39 kB keyframe.
  // Doubling or halving this changes nothing a user would ever notice.
  DefaultHeartbeatSeconds = 0.5;

// Whether a frame is overdue: nothing has reached the movie for
// AIntervalSeconds. ALastStampSeconds is the presentation stamp of the
// last appended frame, ANowSeconds the moment being considered, both on
// the host clock.
//
// False before the first real frame (ASessionStarted), always: a heartbeat
// repeats the last frame, and until one has arrived there is nothing to
// repeat and no timeline to put it on. A still screen from t=0 delivers
// exactly one frame and then nothing, which is what starts the clock here.
//
// False for a non-positive interval, and for a clock that has gone
// backwards: neither is a reason to flood the writer.
function HeartbeatDue(ASessionStarted: Boolean;
  ALastStampSeconds, ANowSeconds, AIntervalSeconds: Double): Boolean;

// The stamp a heartbeat frame should carry: now, unless now is not far
// enough past the last frame to be a distinct moment, in which case the
// smallest step that is.
//
// Presentation stamps must strictly increase or AVAssetWriter rejects the
// append and fails the whole file for good. The caller's clock and the
// frame's stamp are the same clock, so ANowSeconds is normally well past
// ALastStampSeconds and is returned unchanged — which is what makes the
// movie's duration equal to the elapsed host time rather than to a count
// of heartbeats. The floor is the guard for the case that is not normal.
//
// The result is never below ALastStampSeconds + AMinimumStepSeconds; a
// negative step is read as zero. Seconds are not the movie's own units,
// so *strict* increase is still the writer's to enforce, in the timescale
// it is stamping in — this only has to keep the two moments apart.
function HeartbeatStamp(ALastStampSeconds, ANowSeconds,
  AMinimumStepSeconds: Double): Double;

// The floor to hand HeartbeatStamp: a frame at the configured rate, but
// never more than the heartbeat interval itself.
//
// The second half is the whole function. A recording at one frame a
// second has a frame interval of 1.0 s and a heartbeat interval of 0.5 s,
// so a floor of "one frame" would push every beat to the last stamp plus
// a full second for half a second of wall time — measured before this
// existed, an 11.6 s take came out 0.384 s LONG, which is the opposite of
// what the heartbeat is for. Above the frame rate the movie is no longer
// tracking the clock, it is running ahead of it.
//
// A frame's worth is still the preferred floor because it is the spacing
// the rest of the file is in, and at any ordinary rate it is far below
// the interval. Monotonicity does not depend on either: the writer clamps
// to one tick past the last stamp in its own timescale, which is the real
// guard (Knips.Export.MovieWriter.EmitHeartbeatFrame).
function HeartbeatMinimumStep(AFrameSeconds, AIntervalSeconds: Double): Double;

implementation

function HeartbeatDue(ASessionStarted: Boolean;
  ALastStampSeconds, ANowSeconds, AIntervalSeconds: Double): Boolean;
begin
  Result := ASessionStarted and (AIntervalSeconds > 0)
    and (ANowSeconds - ALastStampSeconds >= AIntervalSeconds);
end;

function HeartbeatStamp(ALastStampSeconds, ANowSeconds,
  AMinimumStepSeconds: Double): Double;
var
  Floor: Double;
begin
  Floor := AMinimumStepSeconds;
  if Floor <= 0 then
    Floor := 0;
  Result := ANowSeconds;
  if Result < ALastStampSeconds + Floor then
    Result := ALastStampSeconds + Floor;
end;

function HeartbeatMinimumStep(AFrameSeconds,
  AIntervalSeconds: Double): Double;
begin
  Result := AFrameSeconds;
  if (AIntervalSeconds > 0) and (AIntervalSeconds < Result) then
    Result := AIntervalSeconds;
  if Result < 0 then
    Result := 0;
end;

end.

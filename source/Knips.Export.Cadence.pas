unit Knips.Export.Cadence;

// Frames that were never captured, because nothing on the screen changed
// — and the arithmetic that decides which of them are worth making.
//
// **The problem, measured.** ScreenCaptureKit delivers a frame when the
// content changes and not otherwise: an unchanged frame arrives with no
// image buffer at all and `Knips.Capture.Stream` drops it. That is what
// makes a screen recording of a still screen cost nothing, and it is
// exactly right for the *capture*.
//
// It is wrong for the *render*, and the reason is that a raw take has no
// pointer in its pixels. Moving the mouse over a static window changes
// nothing on screen, so it produces no frames — and then the render
// draws the pointer back from the sidecar, onto whatever frames happen
// to exist. Measured on a real take (an 8.10 s full-screen recording
// with one click, on the recorder as it stands today): 152 frames, 18.8
// a second against a nominal 30, with gaps up to 567 ms; inside the
// 0.30 s the zoom takes to ease in, **one** frame. A doubling eased
// across one frame is not an animation, it is a jump-cut, and that is
// what "the zoom and smooth cursor are not smooth at all" is.
//
// **The fix.** The render keeps every source frame exactly as it is —
// same pixels, same presentation stamp, byte-exact where no effect
// touches them — and *interleaves* extra frames between them, made by
// re-presenting the last source frame with the effect evaluated at the
// new instant. The picture behind the effect is unchanged, which is
// true: nothing on screen changed, or there would have been a frame.
//
// **What it does not do.** It fills gaps *between* captured frames, and
// only those. A take whose screen went static has no later frame to
// interleave towards, and no arithmetic here can invent one.
//
// That used to be a live hole in the product and is now only a division
// of labour: the missing half shipped as the recorder-side **idle
// heartbeat** (Knips.Recording.Heartbeat), which re-presents the last
// frame about twice a second while ScreenCaptureKit is idle and once
// more at the stop, so the movie spans the take whatever the screen was
// doing. This unit fills the gaps inside a movie; the heartbeat is what
// makes sure the movie reaches the end of the recording. Neither
// replaces the other.
//
// **What this unit is.** The two decisions that must not live inside a
// framework loop:
//
//   - `CadenceTimes` — where a synthesised frame may go, on a grid of
//     one nominal frame interval anchored at the previous frame;
//   - `TRenderedFrameShape` and `FrameShapesDiffer` — whether it is
//     worth making, which is the question "would this frame be a
//     different picture from the one before it?". A frame that would
//     come out identical is skipped, so a still stretch with nothing
//     animating over it stays exactly as sparse as it was captured, a
//     zoom's *hold* (a constant crop) costs nothing, and only the
//     stretches where something is genuinely moving are filled in.
//
// That second test is what bounds the growth. It is deliberately made of
// integers — the crop in whole source pixels, the sprite's landing place
// in whole output pixels — because those integers are what the renderer
// actually does with them, so two frames with the same shape really are
// the same picture and not merely a close one.
//
// Platform-neutral and unit-tested, like the zoom track whose crop it
// compares and the live arithmetic underneath both.

{$I Knips.inc}

interface

const
  // The cadence to fill in at, when nothing says otherwise. A take's own
  // sidecar header records what the capture was configured for and that
  // is preferred; this is the fallback and the floor of what looks
  // continuous.
  DefaultCadenceFramesPerSecond = 30;
  // Above this the movie is not a screen recording any more, and a
  // corrupted header should not be able to ask a render for a thousand
  // frames a second.
  MaxCadenceFramesPerSecond = 120;
  // How many frames one gap may ever be filled with. At 30 Hz this is a
  // minute of continuous animation over a screen that never changed —
  // far past anything real, and a bound on what a nonsense stamp in a
  // damaged movie can ask a render to encode.
  MaxCadenceStepsPerGap = 1800;
  // How close to the next *source* frame a synthesised one may land, as
  // a share of the interval. Below this the two would be adjacent
  // frames a fortieth of a second apart, which buys nothing and makes
  // the cadence look uneven where it matters least.
  CadenceCrowdingFraction = 0.75;

type
  TCadenceTimes = array of Double;

  // One rendered frame reduced to what decides its pixels, given that
  // the frame it is made from does not change: the crop taken out of
  // that frame, and where the drawn pointer lands in the output.
  //
  // Every field is an integer on purpose. The renderer crops in whole
  // source pixels (Knips.Export.ZoomTrack.ZoomFrameCrop) and blits the
  // sprite at a whole output pixel (Knips.Recording.CursorMath), so two
  // frames with equal shapes are the same picture exactly, not
  // approximately.
  TRenderedFrameShape = record
    CropX: Integer;
    CropY: Integer;
    CropWidth: Integer;
    CropHeight: Integer;
    // False when no pointer is drawn at all, and also when the pointer
    // is off the frame at that instant — which is a real difference from
    // a pointer that is on it, and is why this is a field rather than a
    // sentinel position.
    HasCursor: Boolean;
    CursorX: Integer;
    CursorY: Integer;
  end;

// Seconds per frame at AFramesPerSecond, clamped into what a screen
// recording can be. Zero is never returned.
function CadenceInterval(AFramesPerSecond: Integer): Double;

// The instants a render may put a synthesised frame at, strictly between
// two source frames, on a grid of AIntervalSeconds anchored at the
// earlier one.
//
// Empty when the two are less than about two intervals apart — a gap
// that is already at the cadence has nothing missing from it — and
// capped at MaxCadenceStepsPerGap.
function CadenceTimes(APreviousSeconds, ANextSeconds,
  AIntervalSeconds: Double): TCadenceTimes;

// Whether two frames made from the same pixels would come out
// different. This is the whole of the "is this frame worth making"
// decision.
function FrameShapesDiffer(const ALeft, ARight: TRenderedFrameShape):
  Boolean;

// One past the last grid slot a gap may be filled to, for a caller that
// walks a slot grid it is already counting in rather than asking
// CadenceTimes for instants — which is what the GIF and APNG pipeline
// does, because the decimation grid it decides output frames on is the
// same grid the fill belongs on.
//
// It exists so that the two paths cannot disagree about how much one gap
// may cost. The bound is applied from the START of the gap rather than
// trimmed off its end: what an enormous gap deserves is the first stretch
// of animation and then the next real frame, not a minute of re-encoded
// stills.
function CadenceFillLimit(AFirstEmptySlot, ANextFrameSlot: Int64): Int64;

implementation

function CadenceInterval(AFramesPerSecond: Integer): Double;
var
  Rate: Integer;
begin
  Rate := AFramesPerSecond;
  if Rate < 1 then
    Rate := DefaultCadenceFramesPerSecond;
  if Rate > MaxCadenceFramesPerSecond then
    Rate := MaxCadenceFramesPerSecond;
  Result := 1 / Rate;
end;

function CadenceTimes(APreviousSeconds, ANextSeconds,
  AIntervalSeconds: Double): TCadenceTimes;
var
  Limit, Time: Double;
  Count, Step: Integer;
begin
  Result := nil;
  if AIntervalSeconds <= 0 then
    Exit;
  if not (ANextSeconds > APreviousSeconds) then
    Exit;
  Limit := ANextSeconds - AIntervalSeconds * CadenceCrowdingFraction;
  if Limit <= APreviousSeconds then
    Exit;
  // Sized from the gap rather than from the ceiling. The overwhelmingly
  // common answer is nought or one instant, and reserving a gap's
  // theoretical maximum for every pair of frames in a movie is a
  // thousand-odd doubles allocated and thrown away per frame.
  Count := Trunc((Limit - APreviousSeconds) / AIntervalSeconds) + 1;
  if Count > MaxCadenceStepsPerGap then
    Count := MaxCadenceStepsPerGap;
  SetLength(Result, Count);
  Count := 0;
  for Step := 1 to MaxCadenceStepsPerGap do
  begin
    // From the step index rather than by accumulation: a running sum
    // drifts, and a grid that drifts puts the last synthesised frame of
    // a long gap somewhere the arithmetic does not say it is.
    Time := APreviousSeconds + Step * AIntervalSeconds;
    if Time >= Limit then
      Break;
    // The reservation above is an upper bound taken from the same
    // arithmetic, but floating point decides the loop and integers
    // decided the length; growing rather than trusting them to agree is
    // one comparison and cannot be wrong.
    if Count >= Length(Result) then
      SetLength(Result, Count + 1);
    Result[Count] := Time;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function CadenceFillLimit(AFirstEmptySlot, ANextFrameSlot: Int64): Int64;
begin
  Result := ANextFrameSlot;
  if Result > AFirstEmptySlot + MaxCadenceStepsPerGap then
    Result := AFirstEmptySlot + MaxCadenceStepsPerGap;
  // A gap with nothing missing from it is not a gap.
  if Result < AFirstEmptySlot then
    Result := AFirstEmptySlot;
end;

function FrameShapesDiffer(const ALeft, ARight: TRenderedFrameShape):
  Boolean;
begin
  if (ALeft.CropX <> ARight.CropX) or (ALeft.CropY <> ARight.CropY)
    or (ALeft.CropWidth <> ARight.CropWidth)
    or (ALeft.CropHeight <> ARight.CropHeight) then
    Exit(True);
  if ALeft.HasCursor <> ARight.HasCursor then
    Exit(True);
  // Two frames with no pointer in them are the same picture whatever
  // the (unused) coordinates say.
  if not ALeft.HasCursor then
    Exit(False);
  Result := (ALeft.CursorX <> ARight.CursorX)
    or (ALeft.CursorY <> ARight.CursorY);
end;

end.

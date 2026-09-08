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
// **What this unit is.** The decisions that must not live inside a
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
//     stretches where something is genuinely moving are filled in;
//   - `TCadenceWalk` — the whole of that bookkeeping for a caller that
//     decimates onto a slot grid rather than asking `CadenceTimes` for
//     instants, which is the GIF and APNG pipeline. It is a record
//     rather than advice because that pipeline walks the same movie
//     TWICE, and the two walks have to emit the same frames.
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
  // Slack on the slot grid TCadenceWalk decimates onto, in slots:
  // enough to absorb the last bits of a presentation stamp, nowhere
  // near a real frame interval, so a frame sitting on a slot boundary
  // always counts as having reached it.
  CadenceGridEpsilon = 1E-6;
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

  // Where one walk of a movie's frames onto the output's own slot grid
  // has got to: which slot the last emitted frame sat in, which slot the
  // source frame waiting to be handed out belongs in, how far the gap
  // between the two may be filled, and what the last emitted frame came
  // out looking like.
  //
  // Every input to "what does this walk emit next?" is in here, and that
  // is the point of the record. A GIF walks the movie TWICE — once to
  // build a palette from the frames that will be written, once to write
  // them — and the two walks have to agree exactly, or the palette is
  // built from an animation the file does not hold. They used not to:
  // the shape of an emitted frame was recorded only once the export's
  // target size was known, the palette pass learned that size from its
  // own first frame, and so the first frame of the FIRST pass recorded
  // no shape at all. The next gap then had nothing to compare against
  // and was filled unconditionally — one frame the palette saw, the
  // encode pass never wrote, and both passes' counts disagreed about.
  //
  // Held state rather than a fresh answer per frame, so a walk cannot
  // depend on anything a pass happened to set up along the way.
  TCadenceWalk = record
    // The output rate the grid is in slots of. Never below 1.
    FramesPerSecond: Integer;
    // Whether anything in this take could make one instant a different
    // picture from the one before it — a crop that moves or a drawn
    // pointer that moves; see the caller's own SynthesisPossible. False
    // means no gap is ever filled, which is not an optimisation: a walk
    // that cannot synthesise emits exactly one frame per accepted source
    // frame, and that is the bound its caller's progress and palette
    // seed are computed from.
    SynthesisPossible: Boolean;
    // The first accepted frame's stamp, which anchors the grid, and
    // whether one has been seen.
    BaseSeconds: Double;
    HasBase: Boolean;
    // How many frames this walk has handed out, and how many of those it
    // made rather than read.
    Emitted: Int64;
    Filled: Int64;
    LastSlot: Int64;
    PendingSlot: Int64;
    FillSlot: Int64;
    // One past the last slot the open gap may be filled to — the shared
    // bound (CadenceFillLimit), so this path and the MP4 render's cannot
    // disagree about what one gap may cost.
    FillLimit: Int64;
    LastShape: TRenderedFrameShape;
    HasLastShape: Boolean;
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

// A walk of a movie at AFramesPerSecond, told once whether this take can
// synthesise anything at all. Both are settled before a pass starts and
// neither moves during it.
function CadenceWalkStart(AFramesPerSecond: Integer;
  ASynthesisPossible: Boolean): TCadenceWalk;

// Whether a source frame at ASeconds is kept. The first frame seen is
// always kept and anchors the grid; after that a frame is kept only if
// it reaches a slot later than the one already emitted from, so a source
// faster than the output rate is decimated and one slower than it never
// builds up a backlog of frames that are "due".
//
// A frame that is kept opens the gap in front of it: the slots between
// the last emitted frame and this one are what CadenceWalkNextFill will
// offer, up to the shared bound.
function CadenceWalkAcceptsSource(var AWalk: TCadenceWalk;
  ASeconds: Double): Boolean;

// The next instant in the open gap that may carry a synthesised frame.
// False when the gap is exhausted, and false at once on a take that
// cannot synthesise.
function CadenceWalkNextFill(var AWalk: TCadenceWalk;
  out ASeconds: Double): Boolean;

// Whether a synthesised frame that would come out AShape is worth
// emitting, which is FrameShapesDiffer against the last frame emitted.
function CadenceWalkWantsFill(const AWalk: TCadenceWalk;
  const AShape: TRenderedFrameShape): Boolean;

// Records that the walk handed out a synthesised frame of AShape.
procedure CadenceWalkEmitFill(var AWalk: TCadenceWalk;
  const AShape: TRenderedFrameShape);

// Records that the walk handed out the source frame that was waiting,
// which came out AShape. Unconditional, because a walk that skips this
// for its first frame is exactly the bug TCadenceWalk exists to make
// unrepresentable.
procedure CadenceWalkEmitSource(var AWalk: TCadenceWalk;
  const AShape: TRenderedFrameShape);

implementation

uses
  Math;

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

function CadenceWalkStart(AFramesPerSecond: Integer;
  ASynthesisPossible: Boolean): TCadenceWalk;
begin
  Result := Default(TCadenceWalk);
  Result.FramesPerSecond := AFramesPerSecond;
  if Result.FramesPerSecond < 1 then
    Result.FramesPerSecond := DefaultCadenceFramesPerSecond;
  Result.SynthesisPossible := ASynthesisPossible;
end;

function CadenceWalkAcceptsSource(var AWalk: TCadenceWalk;
  ASeconds: Double): Boolean;
var
  Slot: Int64;
begin
  if not AWalk.HasBase then
  begin
    AWalk.HasBase := True;
    AWalk.BaseSeconds := ASeconds;
    AWalk.LastSlot := 0;
    Slot := 0;
  end
  else
  begin
    Slot := Math.Floor((ASeconds - AWalk.BaseSeconds)
      * AWalk.FramesPerSecond + CadenceGridEpsilon);
    if Slot <= AWalk.LastSlot then
      Exit(False);
  end;
  AWalk.PendingSlot := Slot;
  AWalk.FillSlot := AWalk.LastSlot + 1;
  AWalk.FillLimit := CadenceFillLimit(AWalk.FillSlot, Slot);
  Result := True;
end;

function CadenceWalkNextFill(var AWalk: TCadenceWalk;
  out ASeconds: Double): Boolean;
begin
  ASeconds := 0;
  // Asked before the gap rather than after it, so a take with nothing
  // animating over it never enters the fill at all. It used to be asked
  // only of the SHAPE the fill would come out, which is the same answer
  // whenever a shape to compare against exists — and on the one frame
  // where none did, it was no answer at all.
  if not AWalk.SynthesisPossible then
    Exit(False);
  if AWalk.FillSlot >= AWalk.FillLimit then
    Exit(False);
  ASeconds := AWalk.BaseSeconds + AWalk.FillSlot / AWalk.FramesPerSecond;
  Inc(AWalk.FillSlot);
  Result := True;
end;

function CadenceWalkWantsFill(const AWalk: TCadenceWalk;
  const AShape: TRenderedFrameShape): Boolean;
begin
  // No recorded shape means nothing to compare against, and the answer
  // to that is no fill: this is exactly the arm that produced a phantom
  // frame when the first frame's shape went unrecorded, so a walk driven
  // wrongly must come out sparse rather than padded. Unreachable while
  // the walk is driven as documented — a gap only opens in front of an
  // emitted frame, and emitting one records its shape.
  Result := AWalk.HasLastShape
    and FrameShapesDiffer(AShape, AWalk.LastShape);
end;

procedure CadenceWalkEmitFill(var AWalk: TCadenceWalk;
  const AShape: TRenderedFrameShape);
begin
  AWalk.LastShape := AShape;
  AWalk.HasLastShape := True;
  Inc(AWalk.Emitted);
  Inc(AWalk.Filled);
end;

procedure CadenceWalkEmitSource(var AWalk: TCadenceWalk;
  const AShape: TRenderedFrameShape);
begin
  AWalk.LastSlot := AWalk.PendingSlot;
  AWalk.LastShape := AShape;
  AWalk.HasLastShape := True;
  Inc(AWalk.Emitted);
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

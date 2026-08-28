unit Knips.Export.ZoomTrack;

// Zoom on Click after the fact: the same effect the menu-bar app can run
// live, replayed at render time from the event sidecar's click track.
//
// **Why it is a replay and not a new effect.** The live one moves
// ScreenCaptureKit's own sourceRect, so a take that zoomed is zoomed in
// its pixels and nothing downstream can undo it. The raw-take model turns
// that round: the capture records the whole rectangle, the clicks go into
// the sidecar, and the crop is applied to the decoded frames afterwards —
// which is the same picture, arrived at late enough to be changed. For the
// two to feel like one feature they have to share their arithmetic, so
// everything here is built out of Knips.Recording.LiveMath: the same
// smoothstep easing, the same 2x factor, the same 0.8 s hold,
// the same ClampRectInside, the same ZoomedSourceRect.
//
// **What is deliberately different.** Three things, and each is an
// improvement the live effect cannot have:
//
//   - a click lands at its *exact* time rather than on the next 30 Hz
//     tick, because the sidecar wrote down when it happened;
//   - the curve is evaluated at each frame's own presentation stamp
//     rather than at whatever rate ScreenCaptureKit could be reconfigured
//     at (measured at about 20 Hz — see LiveZoomInSeconds), so the
//     animation is as smooth as the movie's frame rate;
//   - Follow Mouse is not part of it. A pan changes which pixels were
//     read off the screen, so it can only ever be a live effect; a zoom
//     is a crop of pixels that are already in the file. The window this
//     zoom crops out of is therefore the recording's base rectangle,
//     fixed for the whole take — which is exactly what the live
//     composition reduces to with Follow off.
//
// **The menu-bar band.** The live effect refuses clicks in the strip
// along the top of the display, because the click that stops a recording
// is a click on Knips's own status item and a take that ended by zooming
// into the top corner would be nobody's idea of the feature working. The
// same rule applies here, from the inset the sidecar's header records.
//
// Platform-neutral and unit-tested, like the live arithmetic it extends:
// this is the whole of the effect except for the pixels, and the pixels
// are one crop and one scale.

{$I Knips.inc}

interface

uses
  Knips.Options,
  Knips.Recording.LiveMath,
  Knips.Recording.Sidecar;

type
  // One usable click, on the movie's own timeline. Only presses are here
  // — a release is not a gesture at anything — and only presses this
  // effect would actually act on: inside the recorded rectangle, below
  // the menu bar.
  TZoomClick = record
    Seconds: Double;
    X: Double;
    Y: Double;
  end;

  TZoomClickArray = array of TZoomClick;

  // The animator's whole state, as a value. Advancing returns a new one
  // rather than mutating, for the same reason TEasedScalar does: the
  // curve is then testable without a clock, an object or a run loop.
  //
  // Seconds is how far the walk has got, on the movie's timeline. A
  // caller asks for frames in increasing order and the state carries
  // forward; asking for an earlier time needs a fresh start (there is
  // nothing to unwind an easing with, and nothing wants to).
  TZoomWalker = record
    Base: TLiveRect;
    Factor: Double;
    HoldSeconds: Double;
    Zoom: TEasedScalar;
    FocusX: TEasedScalar;
    FocusY: TEasedScalar;
    ZoomedIn: Boolean;
    HoldRemaining: Double;
    Seconds: Double;
    NextClick: Integer;
  end;

  // A crop of one decoded frame, in that frame's own pixels. Always
  // inside the frame and never empty, so the caller has no bounds test to
  // do; Identity says the crop is the whole frame, which is what every
  // frame of an unzoomed stretch produces and is worth knowing because a
  // scale that is not a scale should be a copy.
  TZoomCrop = record
    X: Integer;
    Y: Integer;
    Width: Integer;
    Height: Integer;
    Identity: Boolean;
  end;

// The presses in a loaded sidecar that this effect would act on, in movie
// seconds. Empty when the log has no anchor (nothing can be placed on the
// movie's timeline without one), when it is a window recording (whose
// samples have no fixed relationship to its frames), or when nothing was
// clicked inside the recorded rectangle.
function ZoomClicksFromLog(const ALog: TSidecarLog): TZoomClickArray;

// A walker over ABase — the rectangle the recording was sized from, in
// the display's own top-left points. AFactor and AHoldSeconds take the
// live effect's own values when 0.
//
// The menu-bar band is deliberately not a parameter here: it decides
// which clicks COUNT, and that question is answered once, by
// ZoomClicksFromLog, off the header that records the band. A walker fed
// clicks that already passed that filter has nothing left to do with it.
function ZoomWalkerStart(const ABase: TLiveRect;
  AFactor, AHoldSeconds: Double): TZoomWalker;

// Advances the walk to ASeconds, applying every click up to it. A time at
// or before the walk's current position leaves it untouched.
function ZoomWalkerAdvance(const AWalker: TZoomWalker;
  const AClicks: TZoomClickArray; ASeconds: Double): TZoomWalker;

// The rectangle the render should show at the walk's current position, in
// the display's own top-left points. Always inside Base.
function ZoomWalkerSourceRect(const AWalker: TZoomWalker): TLiveRect;

// The whole thing at one instant, walked from the start. The reference
// definition of the effect — the walker is an optimisation of exactly
// this, and the suite holds the two against each other.
function ZoomSourceRectAt(const ABase: TLiveRect; AFactor,
  AHoldSeconds: Double; const AClicks: TZoomClickArray;
  ASeconds: Double): TLiveRect;

// Which pixels of a frame ASourceRect names, given that the whole frame
// shows ABase. Rounded outward to whole pixels and clamped to the frame:
// a crop is a memory range, so it is settled in integers here rather than
// in the middle of a resampler.
function ZoomFrameCrop(APixelWidth, APixelHeight: Integer;
  const ABase, ASourceRect: TLiveRect): TZoomCrop;

implementation

function ZoomClicksFromLog(const ALog: TSidecarLog): TZoomClickArray;
var
  I, Count: Integer;
  Event: TSidecarButtonEvent;
  Base: TLiveRect;
begin
  Result := nil;
  if ALog = nil then
    Exit;
  if not ALog.HasAnchor then
    Exit;
  if ALog.Header.TargetKind = ctkWindow then
    Exit;
  if (ALog.Header.BaseWidth <= 0) or (ALog.Header.BaseHeight <= 0) then
    Exit;
  Base := LiveRect(ALog.Header.BaseX, ALog.Header.BaseY,
    ALog.Header.BaseWidth, ALog.Header.BaseHeight);
  SetLength(Result, ALog.ButtonCount);
  Count := 0;
  for I := 0 to ALog.ButtonCount - 1 do
  begin
    Event := ALog.ButtonEvent(I);
    // Presses only, left button only — the same two restrictions the
    // sampler already applies to what it writes, repeated here because a
    // reader must not assume a writer's discipline.
    if not Event.Down or (Event.Button <> 0) then
      Continue;
    if Event.Y < ALog.Header.MenuBarInset then
      Continue;
    if not LiveRectContains(Base, Event.X, Event.Y) then
      Continue;
    Result[Count].Seconds := ALog.MovieSeconds(Event.Time);
    Result[Count].X := Event.X;
    Result[Count].Y := Event.Y;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function ZoomWalkerStart(const ABase: TLiveRect;
  AFactor, AHoldSeconds: Double): TZoomWalker;
begin
  Result := Default(TZoomWalker);
  Result.Base := ABase;
  Result.Factor := AFactor;
  if Result.Factor <= LiveMinZoom then
    Result.Factor := LiveClickZoom;
  if Result.Factor > LiveMaxZoom then
    Result.Factor := LiveMaxZoom;
  Result.HoldSeconds := AHoldSeconds;
  if Result.HoldSeconds <= 0 then
    Result.HoldSeconds := LiveZoomHoldSeconds;
  Result.Zoom := EasedScalar(LiveMinZoom);
  Result.FocusX := EasedScalar(ABase.X + ABase.Width / 2);
  Result.FocusY := EasedScalar(ABase.Y + ABase.Height / 2);
  Result.ZoomedIn := False;
  Result.HoldRemaining := 0;
  Result.Seconds := 0;
  Result.NextClick := 0;
end;

// One stretch of time with no click in it, split at the instant the hold
// runs out. Splitting is what makes the result independent of how often
// the caller asks: a caller stepping frame by frame and one asking for a
// single instant must ease out from the same place, or the effect would
// be a function of the renderer's frame rate rather than of the take.
//
// The expiry is tested at the *top* of each pass rather than at the
// bottom, and the reason is arithmetic rather than taste. The hold is
// counted down by subtracting each step's own length, so after a step
// that was supposed to land exactly on the end of the hold it is left
// holding a residue of about one ulp instead of zero. The next pass then
// asks to split at `Seconds + residue`, which at a movie time of a few
// seconds is *not representable* as anything but Seconds itself — a zero
// step. Bottom-testing skipped the ease-out entirely in that case
// (measured: a take stayed at full zoom for the rest of the file);
// top-testing turns the unrepresentable split into an expiry, which is
// what it is.
function StepTo(const AWalker: TZoomWalker; ASeconds: Double): TZoomWalker;
var
  Next, Delta: Double;
begin
  Result := AWalker;
  while Result.Seconds < ASeconds do
  begin
    if Result.ZoomedIn and (Result.HoldRemaining <= 0) then
    begin
      Result.Zoom := EasedScalarRetarget(Result.Zoom, LiveMinZoom,
        LiveZoomOutSeconds);
      Result.ZoomedIn := False;
    end;
    Next := ASeconds;
    if Result.ZoomedIn and (Result.HoldRemaining > 0)
      and (Result.Seconds + Result.HoldRemaining < ASeconds) then
      Next := Result.Seconds + Result.HoldRemaining;
    Delta := Next - Result.Seconds;
    if Delta <= 0 then
    begin
      // The end of the hold is nearer than a Double can say. It has
      // ended; the pass above turns that into the ease-out.
      Result.HoldRemaining := 0;
      Continue;
    end;
    if Result.ZoomedIn then
      Result.HoldRemaining := Result.HoldRemaining - Delta;
    Result.Zoom := EasedScalarAdvance(Result.Zoom, Delta);
    Result.FocusX := EasedScalarAdvance(Result.FocusX, Delta);
    Result.FocusY := EasedScalarAdvance(Result.FocusY, Delta);
    Result.Seconds := Next;
  end;
end;

// TLiveAnimator.HandleClick, with the same retarget-rather-than-restart
// rule: a second click part way through the first zoom begins its curve
// where the old one had got to, and smoothstep leaves that point at zero
// velocity, so nothing jumps and nothing reverses at speed.
function ApplyClick(const AWalker: TZoomWalker;
  const AClick: TZoomClick): TZoomWalker;
begin
  Result := AWalker;
  if not Result.ZoomedIn then
    Result.Zoom := EasedScalarRetarget(Result.Zoom, Result.Factor,
      LiveZoomInSeconds);
  Result.FocusX := EasedScalarRetarget(Result.FocusX, AClick.X,
    LiveZoomInSeconds);
  Result.FocusY := EasedScalarRetarget(Result.FocusY, AClick.Y,
    LiveZoomInSeconds);
  Result.ZoomedIn := True;
  Result.HoldRemaining := Result.HoldSeconds;
end;

function ZoomWalkerAdvance(const AWalker: TZoomWalker;
  const AClicks: TZoomClickArray; ASeconds: Double): TZoomWalker;
begin
  Result := AWalker;
  if ASeconds <= Result.Seconds then
    Exit;
  while (Result.NextClick < Length(AClicks))
    and (AClicks[Result.NextClick].Seconds <= ASeconds) do
  begin
    // A click before the walk began (a negative movie time, which a
    // press between the anchor being written and the first frame can
    // produce) still counts: it is stepped to no time at all and applied
    // where the walk stands.
    if AClicks[Result.NextClick].Seconds > Result.Seconds then
      Result := StepTo(Result, AClicks[Result.NextClick].Seconds);
    Result := ApplyClick(Result, AClicks[Result.NextClick]);
    Inc(Result.NextClick);
  end;
  Result := StepTo(Result, ASeconds);
end;

function ZoomWalkerSourceRect(const AWalker: TZoomWalker): TLiveRect;
begin
  Result := ZoomedSourceRect(AWalker.Base, EasedScalarValue(AWalker.Zoom),
    EasedScalarValue(AWalker.FocusX), EasedScalarValue(AWalker.FocusY));
end;

function ZoomSourceRectAt(const ABase: TLiveRect; AFactor,
  AHoldSeconds: Double; const AClicks: TZoomClickArray;
  ASeconds: Double): TLiveRect;
var
  Walker: TZoomWalker;
begin
  Walker := ZoomWalkerStart(ABase, AFactor, AHoldSeconds);
  Walker := ZoomWalkerAdvance(Walker, AClicks, ASeconds);
  Result := ZoomWalkerSourceRect(Walker);
end;

// One edge of the crop, rounded to a whole pixel and kept on the frame.
function SnapEdge(AValue: Double; ALimit: Integer): Integer;
begin
  Result := Round(AValue);
  if Result < 0 then
    Result := 0;
  if Result > ALimit then
    Result := ALimit;
end;

function ZoomFrameCrop(APixelWidth, APixelHeight: Integer;
  const ABase, ASourceRect: TLiveRect): TZoomCrop;
var
  Left, Top, Right, Bottom: Integer;
begin
  Result := Default(TZoomCrop);
  Result.Width := APixelWidth;
  Result.Height := APixelHeight;
  Result.Identity := True;
  if (APixelWidth <= 0) or (APixelHeight <= 0) or (ABase.Width <= 0)
    or (ABase.Height <= 0) then
    Exit;
  Left := SnapEdge((ASourceRect.X - ABase.X) / ABase.Width * APixelWidth,
    APixelWidth);
  Top := SnapEdge((ASourceRect.Y - ABase.Y) / ABase.Height * APixelHeight,
    APixelHeight);
  Right := SnapEdge((ASourceRect.X + ASourceRect.Width - ABase.X) / ABase.Width
    * APixelWidth, APixelWidth);
  Bottom := SnapEdge((ASourceRect.Y + ASourceRect.Height - ABase.Y)
    / ABase.Height * APixelHeight, APixelHeight);
  if Right <= Left then
    Right := Left + 1;
  if Bottom <= Top then
    Bottom := Top + 1;
  if Right > APixelWidth then
  begin
    Right := APixelWidth;
    if Left >= Right then
      Left := Right - 1;
  end;
  if Bottom > APixelHeight then
  begin
    Bottom := APixelHeight;
    if Top >= Bottom then
      Top := Bottom - 1;
  end;
  Result.X := Left;
  Result.Y := Top;
  Result.Width := Right - Left;
  Result.Height := Bottom - Top;
  Result.Identity := (Result.X = 0) and (Result.Y = 0)
    and (Result.Width = APixelWidth) and (Result.Height = APixelHeight);
end;

end.

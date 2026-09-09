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
//   - Follow Mouse is not replayed, because it cannot be: a pan changes
//     which pixels were read off the screen, so it is a live effect and
//     stays baked into the take. A zoom is a crop of pixels that are
//     already in the file, so it can still be applied — **inside** the
//     pan, which is exactly where the live composition puts it
//     (Knips.Recording.LiveMath: base, then window, then source). The
//     window this zoom crops out of is therefore the rectangle the
//     capture was reading at that instant, which the sidecar's samples
//     record; for a take whose framing never moved, that is the base
//     rectangle for the whole file and the composition reduces to the
//     simple case.
//
// **A panned take is not refused.** It used to be, and the refusal was
// right for the code that existed: the crop was computed against the
// base rectangle, so a Follow Mouse take rendered mis-cropped frames.
// The fix is the composition rather than the refusal — a click still
// means "show me this, closer", and where the framing happens to be at
// that instant does not change what the user asked for. What the
// composition cannot do is put back pixels the pan moved off the
// captured rectangle, so a zoom whose focus has drifted outside the
// framing is clamped to the framing's edge (ZoomedSourceRect's own
// ClampRectInside) rather than reaching for pixels the movie does not
// have.
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
    // True when a zoom walk decided this crop (ZoomCropAt advanced the
    // walk and measured the frame against it); False when the frame was
    // passed through whole because nothing was zooming or the framing
    // was unknown. Not the same question as Identity: a zoom at rest
    // yields an identity crop that WAS applied, and a caller placing
    // a pointer against the crop needs to know which of the two it has
    // — this is what saves it restating ZoomCropAt's own guard.
    Applied: Boolean;
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

// The same, composed inside AWindow — the rectangle the capture was
// actually reading at that instant, which for a take whose framing
// panned is not the base rectangle and changes from frame to frame.
//
// Always inside AWindow, so a render can never ask for pixels the movie
// does not hold; at zoom 1 it *is* AWindow, which is what makes an
// unzoomed stretch of a panned take a plain copy of its frames.
function ZoomWalkerSourceRectIn(const AWalker: TZoomWalker;
  const AWindow: TLiveRect): TLiveRect;

// The rectangle the capture was reading at AMovieSeconds, in the
// display's own top-left points — the framing a zoom composes inside.
// The header's base rectangle when the log has no samples to say
// otherwise, which is also the right answer for a take whose framing
// never moved and is what the format says stands before the first sample
// that carries one.
//
// **AStale is the important output.** Past the end of the sample track
// there is no framing to read, and carrying the last one forward is a
// guess that gets worse the further it goes: a take whose window was
// still being dragged when the track stopped is cropped against a
// rectangle it left. That is reachable rather than theoretical — pointer
// samples are flushed about a second behind, so a take whose process
// died has a movie that runs past its own track, and crash recovery
// re-muxes the movie without trimming it to the track's extent.
// Measured on a real Follow Mouse take with its sidecar truncated at
// 2.0 s: a 443-pixel mis-crop at 3.8 s, reported as plain success.
//
// So the answer past the end is "I do not know" rather than a stale
// rectangle, and the caller's job is to stop cropping for that stretch
// rather than to crop wrongly. The boundary is the take's own
// MaxInterpolatedGap — the same silence this format refuses to draw a
// straight line through anywhere else.
function FramingRectAt(const ALog: TSidecarLog; AMovieSeconds: Double;
  out AStale: Boolean): TLiveRect;

// The framing a render composes inside at ASeconds, with the fallbacks
// every caller of FramingRectAt needs folded in — and it is the same
// question the MP4 render and the GIF/APNG pipeline both ask, which
// they used to answer with a copy of this each.
//
// AFramingPanned is what the caller learned from the take's own header:
// a take whose framing never moved shows ABase for the whole file, and
// the header says so outright, so there is no track to run past and
// nothing to go stale.
//
// **False is the answer that matters.** It means "I do not know what
// this frame was showing" — past the end of the sample track, or from a
// sample too degenerate to crop against. A caller must not crop against
// that and must not place a pointer against it either; ARect still
// carries ABase so that a caller with nothing else to say has a
// rectangle, but it is a rectangle nothing was rendered against.
function FramingAtInstant(const ALog: TSidecarLog; AFramingPanned: Boolean;
  const ABase: TLiveRect; ASeconds: Double;
  out ARect: TLiveRect): Boolean;

// The crop one decoded frame comes to at ASeconds, and — through
// ASource — the rectangle that crop shows in the display's own points,
// which is what a drawn pointer is placed against.
//
// AWalker is advanced in place. The walk is monotonic and a caller asks
// twice for the same instant: once to decide whether the frame is worth
// making at all (Knips.Export.Cadence), once to make it. Advancing to a
// time already reached is a no-op, which is what makes the second ask
// free — and what makes the shape the cadence measures the shape the
// draw produces, which is the whole point of computing one ahead of the
// other.
//
// Not zooming, or a framing the track could not name, is the whole
// frame: the identity crop, with ASource the framing itself. That is
// the one answer that cannot be wrong about pixels the movie holds.
function ZoomCropAt(var AWalker: TZoomWalker;
  const AClicks: TZoomClickArray; AZoomApplied, AFramingKnown: Boolean;
  const AFraming: TLiveRect; ASourceWidth, ASourceHeight: Integer;
  ASeconds: Double; out ASource: TLiveRect): TZoomCrop;

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
  Base, Framing: TLiveRect;
  Seconds: Double;
  Stale: Boolean;
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
    Seconds := ALog.MovieSeconds(Event.Time);
    // Inside what the RECORDING WAS SHOWING when the click happened, not
    // inside the base rectangle: on a take whose framing panned the two
    // are different rectangles, and a click the viewer can see happen is
    // a click this effect should answer. For a take that never panned,
    // the framing IS the base and this is the test it always was.
    // A click past the end of the track has no framing to be tested
    // against; the base rectangle stands in, which is what this test was
    // before there was a framing to compose inside at all.
    Framing := FramingRectAt(ALog, Seconds, Stale);
    if Stale or (Framing.Width <= 0) or (Framing.Height <= 0) then
      Framing := Base;
    if not LiveRectContains(Framing, Event.X, Event.Y) then
      Continue;
    Result[Count].Seconds := Seconds;
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

// Retarget rather than restart: a second click part way through the first zoom begins its curve
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
  Result := ZoomWalkerSourceRectIn(AWalker, AWalker.Base);
end;

function ZoomWalkerSourceRectIn(const AWalker: TZoomWalker;
  const AWindow: TLiveRect): TLiveRect;
begin
  Result := ZoomedSourceRect(AWindow, EasedScalarValue(AWalker.Zoom),
    EasedScalarValue(AWalker.FocusX), EasedScalarValue(AWalker.FocusY));
end;

function FramingRectAt(const ALog: TSidecarLog; AMovieSeconds: Double;
  out AStale: Boolean): TLiveRect;
var
  Sample: TSidecarSample;
  Last: Double;
begin
  AStale := False;
  Result := Default(TLiveRect);
  if ALog = nil then
    Exit;
  Result := LiveRect(ALog.Header.BaseX, ALog.Header.BaseY,
    ALog.Header.BaseWidth, ALog.Header.BaseHeight);
  if not ALog.StateAt(AMovieSeconds, Sample) then
    Exit;
  // Past the end of the track by more than one refusable silence. Only
  // the END is checked: the header's base rectangle is what the format
  // says stands BEFORE the first sample that carries one, so the start
  // is answered rather than guessed.
  if ALog.SampleCount > 0 then
  begin
    Last := ALog.RawSamples[ALog.SampleCount - 1].Time - ALog.AnchorHost;
    if AMovieSeconds - Last > ALog.MaxInterpolatedGap then
    begin
      AStale := True;
      Exit;
    end;
  end;
  // A sample always carries a rectangle — the reader fills it in from
  // the header and carries the last written value forward — but a
  // degenerate one would silently divide the crop by zero downstream,
  // so the base stands in for it.
  if (Sample.SourceWidth <= 0) or (Sample.SourceHeight <= 0) then
    Exit;
  Result := LiveRect(Sample.SourceX, Sample.SourceY, Sample.SourceWidth,
    Sample.SourceHeight);
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

function FramingAtInstant(const ALog: TSidecarLog; AFramingPanned: Boolean;
  const ABase: TLiveRect; ASeconds: Double;
  out ARect: TLiveRect): Boolean;
var
  Stale: Boolean;
begin
  ARect := ABase;
  if not AFramingPanned then
    Exit(True);
  ARect := FramingRectAt(ALog, ASeconds, Stale);
  if (ARect.Width <= 0) or (ARect.Height <= 0) then
  begin
    ARect := ABase;
    Exit(False);
  end;
  Result := not Stale;
end;

function ZoomCropAt(var AWalker: TZoomWalker;
  const AClicks: TZoomClickArray; AZoomApplied, AFramingKnown: Boolean;
  const AFraming: TLiveRect; ASourceWidth, ASourceHeight: Integer;
  ASeconds: Double; out ASource: TLiveRect): TZoomCrop;
begin
  ASource := AFraming;
  Result := Default(TZoomCrop);
  Result.Width := ASourceWidth;
  Result.Height := ASourceHeight;
  Result.Identity := True;
  if not (AZoomApplied and AFramingKnown) then
    Exit;
  AWalker := ZoomWalkerAdvance(AWalker, AClicks, ASeconds);
  ASource := ZoomWalkerSourceRectIn(AWalker, AFraming);
  Result := ZoomFrameCrop(ASourceWidth, ASourceHeight, AFraming, ASource);
  Result.Applied := True;
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

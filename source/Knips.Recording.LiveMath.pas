unit Knips.Recording.LiveMath;

// The arithmetic behind the two live recording effects — Zoom on Click and
// Follow Mouse — with no framework in it at all.
//
// Both effects are one idea: the *output* size of a recording is fixed the
// moment AVAssetWriter opens, so nothing may resize it; what can move is
// the rectangle ScreenCaptureKit reads from the screen
// (SCStreamConfiguration.sourceRect, points, the display's own top-left
// space). A smaller sourceRect scaled into the same output is a zoom; a
// sourceRect that slides across the display is a pan. This unit turns a
// base rectangle, a mouse position, a click and a clock into that one
// rectangle, and Knips.App.Live does nothing but feed it and hand the
// answer to SCStream.
//
// The composition, once, because it is the part that is easy to get wrong:
//
//   base    the region the user asked to record (or the whole display),
//           fixed for the recording — it is what sized the writer
//   window  a base-sized rectangle that Follow Mouse pans inside the
//           display; with Follow off it *is* the base
//   source  the rectangle Zoom on Click crops out of the window, centred
//           on the click and clamped inside it
//
// So zoom composes *inside* follow, never beside it: at zoom 1 the source
// is the window, and at any zoom the source is a subset of the window,
// which is why the on-screen border can track the window and stay an
// honest statement of what is being captured (see Knips.App.Border).
//
// Platform-neutral and unit-tested, deliberately: this is the only part of
// the feature that can be checked off-device.

{$I Knips.inc}

interface

uses
  Knips.Options;

const
  // Zoom on Click. Two-times is Kap's own click zoom and the largest step
  // that still leaves the surrounding context recognisable.
  LiveClickZoom = 2.0;
  LiveMinZoom = 1.0;
  // Nothing asks for more; the clamp exists so a corrupted preference or
  // an arithmetic slip cannot ask for a one-pixel sourceRect.
  LiveMaxZoom = 8.0;
  // Seconds. In faster than out: the zoom should feel like it answers the
  // click, and drift back rather than snap.
  //
  // Both are longer than they would be for an on-screen animation, and
  // the reason is measured rather than aesthetic: ScreenCaptureKit
  // completes an updateConfiguration: in no less than 50 ms (29 samples
  // on an M-series Mac, minimum 50.0 ms), so a live sourceRect animation
  // gets about twenty steps a second however fast the animator ticks. A
  // 0.18 s zoom would be four of them, and four steps across a doubling
  // is a visible staircase; 0.30 s is six and 0.45 s is nine.
  LiveZoomInSeconds = 0.30;
  LiveZoomOutSeconds = 0.45;
  // How long the zoom holds after the *last* click before easing back.
  LiveZoomHoldSeconds = 0.8;

  // Follow Mouse. The middle third of the window each way is dead: inside
  // it the window does not move at all, which is what keeps a hand resting
  // near the centre from shivering the whole frame.
  //
  // Written as a literal rather than as `1.0 / 3.0` on purpose: FPC 3.2.2
  // folds an untyped real *division* at single precision on AArch64
  // (measured — 0.33333334326744080 against 0.33333333333333331), which is
  // three parts in a million of the window's width and lands the dead
  // zone's edge somewhere the arithmetic above does not say it is.
  LiveDeadZoneFraction = 0.3333333333333333;
  // Seconds. The e-folding time of the pan, not a duration: the target
  // moves continuously, so the window chases it rather than animating to
  // it. 0.12 s reaches 93 % of a step in a quarter of a second.
  LiveFollowTimeConstant = 0.12;

  // The animator's tick. 30 Hz is half a 60 Hz display's refresh and twice
  // the rate at which a pan reads as continuous; it is also the rate at
  // which the mouse button is sampled, so it bounds how short a click can
  // be and still be seen (see Knips.App.Live). A literal for the same
  // single-precision folding reason as LiveDeadZoneFraction above.
  LiveTickSeconds = 0.03333333333333333;
  // Points. A sourceRect within this of the one already sent is not worth
  // an updateConfiguration: round trip — SCK is being asked to
  // reconfigure a live stream, not to interpolate.
  LiveSourceRectEpsilon = 0.5;

type
  // A rectangle in a display's own points, top-left origin, y growing
  // downwards — the space SCStreamConfiguration.sourceRect is documented
  // in and the space TCaptureRegion already uses. Doubles rather than
  // integers because the animator lands between points 29 times out of 30
  // and rounding every tick to a whole point is visible stepping.
  TLiveRect = record
    X: Double;
    Y: Double;
    Width: Double;
    Height: Double;
  end;

  // A scalar easing from one value to another over a fixed duration with
  // a smoothstep curve — zero velocity at both ends, so retargeting
  // mid-flight (a second click) starts from rest instead of reversing at
  // speed. Advance/Retarget/Value are pure: the animator keeps the record
  // and replaces it, which is what makes the whole curve testable.
  TEasedScalar = record
    StartValue: Double;
    TargetValue: Double;
    Elapsed: Double;
    Duration: Double;
  end;

function LiveRect(AX, AY, AWidth, AHeight: Double): TLiveRect;
function LiveRectFromRegion(const ARegion: TCaptureRegion): TLiveRect;
// Rounded to whole points, which is what a window frame and a capture
// region both want. Extent is never rounded below 1.
function RegionFromLiveRect(const ARect: TLiveRect): TCaptureRegion;

// True when every edge is within ATolerance points of the other's.
function LiveRectsClose(const ALeft, ARight: TLiveRect;
  ATolerance: Double): Boolean;
function LiveRectContains(const ARect: TLiveRect; AX, AY: Double): Boolean;

// 3t² − 2t³ over a clamped [0, 1]. The one easing curve in the feature.
function Smoothstep(ATime: Double): Double;

// The fraction of the remaining distance an exponential approach covers
// in ADeltaSeconds with the given e-folding time. Frame-rate independent:
// a tick that ran late moves proportionally further, so a stalled run
// loop does not turn a pan into a lurch. Always in [0, 1].
function ApproachFactor(ADeltaSeconds, ATimeConstantSeconds: Double): Double;

function EasedScalar(AValue: Double): TEasedScalar;
function EasedScalarValue(const AScalar: TEasedScalar): Double;
// Starts a new curve from wherever the old one had got to.
function EasedScalarRetarget(const AScalar: TEasedScalar; ATarget,
  ADuration: Double): TEasedScalar;
function EasedScalarAdvance(const AScalar: TEasedScalar;
  ADeltaSeconds: Double): TEasedScalar;
function EasedScalarSettled(const AScalar: TEasedScalar): Boolean;

// Moves ARect inside ABounds without resizing it, shrinking it only when
// it does not fit at all.
function ClampRectInside(const ARect, ABounds: TLiveRect): TLiveRect;

// Where the follow window wants to be so the mouse sits inside its dead
// zone: unchanged while the mouse is inside, otherwise displaced by
// exactly the amount by which the mouse left it, then clamped to the
// display. ADeadZoneFraction is the share of each axis that is dead, in
// [0, 1); 0 makes the window centre on the mouse.
function FollowWindowTarget(const AWindow, ABounds: TLiveRect;
  AMouseX, AMouseY, ADeadZoneFraction: Double): TLiveRect;

// One exponential step of AFactor from AFrom towards ATo.
function ApproachRect(const AFrom, ATo: TLiveRect;
  AFactor: Double): TLiveRect;

// The sourceRect for a zoom of AZoom centred on the focus point, cropped
// out of AWindow. At zoom 1 this is AWindow exactly.
function ZoomedSourceRect(const AWindow: TLiveRect; AZoom, AFocusX,
  AFocusY: Double): TLiveRect;

// Which live effects a given recording can actually have, whatever the
// two preferences say. A window capture has neither: its sourceRect is in
// the window's own space, which moves and resizes under us with no way to
// find out. A whole-display capture can zoom but has nowhere to pan to.
// Only a region on a display gets both.
function ResolveLiveEffects(ATargetKind: TCaptureTargetKind;
  AHasRegion, AZoomOnClick, AFollowMouse: Boolean;
  out AZoom: Boolean; out AFollow: Boolean): Boolean;

implementation

function LiveRect(AX, AY, AWidth, AHeight: Double): TLiveRect;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.Width := AWidth;
  Result.Height := AHeight;
end;

function LiveRectFromRegion(const ARegion: TCaptureRegion): TLiveRect;
begin
  Result := LiveRect(ARegion.Left, ARegion.Top, ARegion.Width,
    ARegion.Height);
end;

function RegionFromLiveRect(const ARect: TLiveRect): TCaptureRegion;
begin
  Result.Left := Round(ARect.X);
  Result.Top := Round(ARect.Y);
  Result.Width := Round(ARect.Width);
  Result.Height := Round(ARect.Height);
  if Result.Width < 1 then
    Result.Width := 1;
  if Result.Height < 1 then
    Result.Height := 1;
end;

function LiveRectsClose(const ALeft, ARight: TLiveRect;
  ATolerance: Double): Boolean;
begin
  Result := (Abs(ALeft.X - ARight.X) <= ATolerance)
    and (Abs(ALeft.Y - ARight.Y) <= ATolerance)
    and (Abs(ALeft.Width - ARight.Width) <= ATolerance)
    and (Abs(ALeft.Height - ARight.Height) <= ATolerance);
end;

function LiveRectContains(const ARect: TLiveRect; AX, AY: Double): Boolean;
begin
  Result := (AX >= ARect.X) and (AX <= ARect.X + ARect.Width)
    and (AY >= ARect.Y) and (AY <= ARect.Y + ARect.Height);
end;

function Smoothstep(ATime: Double): Double;
var
  Time: Double;
begin
  Time := ATime;
  if Time <= 0 then
    Exit(0);
  if Time >= 1 then
    Exit(1);
  Result := Time * Time * (3 - 2 * Time);
end;

function ApproachFactor(ADeltaSeconds, ATimeConstantSeconds: Double): Double;
begin
  if ADeltaSeconds <= 0 then
    Exit(0);
  // A zero or negative time constant is "arrive now", not a division.
  if ATimeConstantSeconds <= 0 then
    Exit(1);
  Result := 1 - Exp(-ADeltaSeconds / ATimeConstantSeconds);
  if Result < 0 then
    Result := 0;
  if Result > 1 then
    Result := 1;
end;

function EasedScalar(AValue: Double): TEasedScalar;
begin
  Result.StartValue := AValue;
  Result.TargetValue := AValue;
  Result.Elapsed := 0;
  Result.Duration := 0;
end;

function EasedScalarValue(const AScalar: TEasedScalar): Double;
begin
  if AScalar.Duration <= 0 then
    Exit(AScalar.TargetValue);
  Result := AScalar.StartValue + (AScalar.TargetValue - AScalar.StartValue)
    * Smoothstep(AScalar.Elapsed / AScalar.Duration);
end;

function EasedScalarRetarget(const AScalar: TEasedScalar; ATarget,
  ADuration: Double): TEasedScalar;
begin
  Result.StartValue := EasedScalarValue(AScalar);
  Result.TargetValue := ATarget;
  Result.Elapsed := 0;
  Result.Duration := ADuration;
  if Result.Duration < 0 then
    Result.Duration := 0;
end;

function EasedScalarAdvance(const AScalar: TEasedScalar;
  ADeltaSeconds: Double): TEasedScalar;
begin
  Result := AScalar;
  if ADeltaSeconds <= 0 then
    Exit;
  Result.Elapsed := Result.Elapsed + ADeltaSeconds;
  if Result.Elapsed > Result.Duration then
    Result.Elapsed := Result.Duration;
end;

function EasedScalarSettled(const AScalar: TEasedScalar): Boolean;
begin
  Result := (AScalar.Duration <= 0) or (AScalar.Elapsed >= AScalar.Duration);
end;

function ClampRectInside(const ARect, ABounds: TLiveRect): TLiveRect;
begin
  Result := ARect;
  // Size first: everything below assumes the rectangle fits.
  if Result.Width > ABounds.Width then
    Result.Width := ABounds.Width;
  if Result.Height > ABounds.Height then
    Result.Height := ABounds.Height;
  if Result.X < ABounds.X then
    Result.X := ABounds.X;
  if Result.Y < ABounds.Y then
    Result.Y := ABounds.Y;
  if Result.X + Result.Width > ABounds.X + ABounds.Width then
    Result.X := ABounds.X + ABounds.Width - Result.Width;
  if Result.Y + Result.Height > ABounds.Y + ABounds.Height then
    Result.Y := ABounds.Y + ABounds.Height - Result.Height;
end;

function FollowWindowTarget(const AWindow, ABounds: TLiveRect;
  AMouseX, AMouseY, ADeadZoneFraction: Double): TLiveRect;
var
  Fraction, DeadWidth, DeadHeight, Low, High: Double;
begin
  Fraction := ADeadZoneFraction;
  if Fraction < 0 then
    Fraction := 0;
  if Fraction > 1 then
    Fraction := 1;
  Result := AWindow;

  DeadWidth := AWindow.Width * Fraction;
  Low := AWindow.X + (AWindow.Width - DeadWidth) / 2;
  High := Low + DeadWidth;
  if AMouseX < Low then
    Result.X := Result.X - (Low - AMouseX)
  else if AMouseX > High then
    Result.X := Result.X + (AMouseX - High);

  DeadHeight := AWindow.Height * Fraction;
  Low := AWindow.Y + (AWindow.Height - DeadHeight) / 2;
  High := Low + DeadHeight;
  if AMouseY < Low then
    Result.Y := Result.Y - (Low - AMouseY)
  else if AMouseY > High then
    Result.Y := Result.Y + (AMouseY - High);

  Result := ClampRectInside(Result, ABounds);
end;

function ApproachRect(const AFrom, ATo: TLiveRect;
  AFactor: Double): TLiveRect;
var
  Factor: Double;
begin
  Factor := AFactor;
  if Factor < 0 then
    Factor := 0;
  if Factor > 1 then
    Factor := 1;
  Result.X := AFrom.X + (ATo.X - AFrom.X) * Factor;
  Result.Y := AFrom.Y + (ATo.Y - AFrom.Y) * Factor;
  Result.Width := AFrom.Width + (ATo.Width - AFrom.Width) * Factor;
  Result.Height := AFrom.Height + (ATo.Height - AFrom.Height) * Factor;
end;

function ZoomedSourceRect(const AWindow: TLiveRect; AZoom, AFocusX,
  AFocusY: Double): TLiveRect;
var
  Zoom: Double;
  Cropped: TLiveRect;
begin
  Zoom := AZoom;
  if Zoom < LiveMinZoom then
    Zoom := LiveMinZoom;
  if Zoom > LiveMaxZoom then
    Zoom := LiveMaxZoom;
  Cropped.Width := AWindow.Width / Zoom;
  Cropped.Height := AWindow.Height / Zoom;
  Cropped.X := AFocusX - Cropped.Width / 2;
  Cropped.Y := AFocusY - Cropped.Height / 2;
  // The crop stays inside the window, so the border drawn around the
  // window never becomes a lie: what is captured is always a subset of
  // what is framed.
  Result := ClampRectInside(Cropped, AWindow);
end;

function ResolveLiveEffects(ATargetKind: TCaptureTargetKind;
  AHasRegion, AZoomOnClick, AFollowMouse: Boolean;
  out AZoom: Boolean; out AFollow: Boolean): Boolean;
begin
  AZoom := False;
  AFollow := False;
  // A window stream's sourceRect is relative to the window, which the
  // user is free to move and resize mid-recording; a click in screen
  // points has no fixed meaning there and there is nothing to pan across.
  if ATargetKind = ctkWindow then
    Exit(False);
  AZoom := AZoomOnClick;
  // A whole-display capture already contains everything the mouse can
  // reach, so panning it could only move the picture off its own edges.
  AFollow := AFollowMouse and AHasRegion;
  Result := AZoom or AFollow;
end;

end.

program Knips.Recording.LiveMath.Test;

// The live-effect arithmetic, checked on the properties the Darwin
// animator depends on and cannot check for itself:
//
//   - the sourceRect never leaves the rectangle it is cropped out of, and
//     the follow window never leaves the display, whatever is asked for;
//   - zoom 1 is the identity, so switching the effect off costs nothing;
//   - the dead zone really is dead, and leaving it moves the window by
//     exactly the overshoot rather than by a guess;
//   - the easing starts and ends at rest, and a retarget mid-flight starts
//     from where the curve had got to instead of jumping;
//   - a pan is frame-rate independent: one long tick and four short ones
//     covering the same time end up in the same place.

{$I Knips.inc}

uses
  SysUtils,

  Knips.Options,
  Knips.Recording.LiveMath,
  TestingPascalLibrary;

type
  TRectTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRegionRoundTrip;
    procedure TestRegionRoundingKeepsExtentPositive;
    procedure TestClampSlidesRatherThanShrinks;
    procedure TestClampShrinksOnlyWhenItCannotFit;
    procedure TestClampIsIdempotent;
    procedure TestContainsIncludesTheEdges;
  end;

  TZoomTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestZoomOneIsTheIdentity;
    procedure TestZoomHalvesEachAxis;
    procedure TestZoomCentresOnTheFocus;
    procedure TestZoomAtACornerStaysInside;
    procedure TestZoomIsAlwaysInsideTheWindow;
    procedure TestZoomIsClamped;
  end;

  TFollowTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDeadZoneDoesNotMove;
    procedure TestLeavingTheDeadZoneMovesByTheOvershoot;
    procedure TestFollowStaysOnTheDisplay;
    procedure TestZeroDeadZoneCentresOnTheMouse;
    procedure TestFollowNeverResizes;
  end;

  TEasingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSmoothstepEndsAndClamps;
    procedure TestSmoothstepIsFlatAtBothEnds;
    procedure TestEasedScalarRunsFromStartToTarget;
    procedure TestRetargetStartsFromTheCurrentValue;
    procedure TestAdvanceNeverOvershoots;
    procedure TestApproachFactorIsFrameRateIndependent;
    procedure TestApproachRectConverges;
  end;

  TCompositionTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestZoomComposesInsideFollow;
    procedure TestWindowCaptureGetsNoEffects;
    procedure TestDisplayCaptureCannotFollow;
    procedure TestRegionCaptureGetsBoth;
    procedure TestBothOffIsNoLiveRecording;
  end;

{ ---------------------------------------------------------------- helpers }

const
  Epsilon = 1E-9;
  // Points. Anything the animator produces is worth trusting to well
  // inside a tenth of a point.
  RectEpsilon = 1E-6;

// Both helpers go through Expect<string> rather than raising: the runner
// counts an assertion only when Expect is used, and a string comparison is
// what lets the failure message carry the numbers and the label. A value
// inside the tolerance is shown *as* the expected one, so the two strings
// are identical exactly when the test passes.
procedure ExpectNear(AActual, AExpected, ATolerance: Double;
  const AWhat: string);
var
  Shown: Double;
begin
  Shown := AActual;
  if Abs(AActual - AExpected) <= ATolerance then
    Shown := AExpected;
  Expect<string>(Format('%s = %.9f', [AWhat, Shown]))
    .ToBe(Format('%s = %.9f', [AWhat, AExpected]));
end;

procedure ExpectTrue(ACondition: Boolean; const AWhat: string);
begin
  Expect<string>(AWhat + ': ' + BoolToStr(ACondition, 'yes', 'no'))
    .ToBe(AWhat + ': yes');
end;

procedure ExpectRect(const AActual: TLiveRect; AX, AY, AWidth,
  AHeight: Double);
begin
  ExpectNear(AActual.X, AX, RectEpsilon, 'x');
  ExpectNear(AActual.Y, AY, RectEpsilon, 'y');
  ExpectNear(AActual.Width, AWidth, RectEpsilon, 'width');
  ExpectNear(AActual.Height, AHeight, RectEpsilon, 'height');
end;

function IsInside(const AInner, AOuter: TLiveRect): Boolean;
begin
  Result := (AInner.X >= AOuter.X - RectEpsilon)
    and (AInner.Y >= AOuter.Y - RectEpsilon)
    and (AInner.X + AInner.Width <= AOuter.X + AOuter.Width + RectEpsilon)
    and (AInner.Y + AInner.Height <= AOuter.Y + AOuter.Height + RectEpsilon);
end;

{ TRectTests }

procedure TRectTests.SetupTests;
begin
  Test('a region survives the trip through a live rect',
    TestRegionRoundTrip);
  Test('rounding never produces an empty region',
    TestRegionRoundingKeepsExtentPositive);
  Test('clamping slides a rectangle in rather than shrinking it',
    TestClampSlidesRatherThanShrinks);
  Test('clamping shrinks only what cannot fit',
    TestClampShrinksOnlyWhenItCannotFit);
  Test('clamping an already-inside rectangle changes nothing',
    TestClampIsIdempotent);
  Test('a point on the edge counts as inside',
    TestContainsIncludesTheEdges);
end;

procedure TRectTests.TestRegionRoundTrip;
var
  Region, Back: TCaptureRegion;
  Rect: TLiveRect;
begin
  Region.Left := 120;
  Region.Top := 64;
  Region.Width := 800;
  Region.Height := 600;
  Rect := LiveRectFromRegion(Region);
  ExpectRect(Rect, 120, 64, 800, 600);
  Back := RegionFromLiveRect(Rect);
  Expect<Integer>(Back.Left).ToBe(120);
  Expect<Integer>(Back.Top).ToBe(64);
  Expect<Integer>(Back.Width).ToBe(800);
  Expect<Integer>(Back.Height).ToBe(600);
end;

procedure TRectTests.TestRegionRoundingKeepsExtentPositive;
var
  Region: TCaptureRegion;
begin
  Region := RegionFromLiveRect(LiveRect(10.4, 10.6, 0.2, 0.0));
  Expect<Integer>(Region.Left).ToBe(10);
  Expect<Integer>(Region.Top).ToBe(11);
  Expect<Integer>(Region.Width).ToBe(1);
  Expect<Integer>(Region.Height).ToBe(1);
end;

procedure TRectTests.TestClampSlidesRatherThanShrinks;
var
  Bounds: TLiveRect;
begin
  Bounds := LiveRect(0, 0, 1000, 800);
  ExpectRect(ClampRectInside(LiveRect(-50, -30, 200, 100), Bounds),
    0, 0, 200, 100);
  ExpectRect(ClampRectInside(LiveRect(900, 750, 200, 100), Bounds),
    800, 700, 200, 100);
end;

procedure TRectTests.TestClampShrinksOnlyWhenItCannotFit;
var
  Bounds: TLiveRect;
begin
  Bounds := LiveRect(100, 50, 400, 300);
  ExpectRect(ClampRectInside(LiveRect(0, 0, 900, 900), Bounds),
    100, 50, 400, 300);
  // One axis too big, the other not.
  ExpectRect(ClampRectInside(LiveRect(0, 60, 900, 100), Bounds),
    100, 60, 400, 100);
end;

procedure TRectTests.TestClampIsIdempotent;
var
  Bounds, Once, Twice: TLiveRect;
begin
  Bounds := LiveRect(-200, -100, 1000, 800);
  Once := ClampRectInside(LiveRect(-500, 600, 300, 400), Bounds);
  Twice := ClampRectInside(Once, Bounds);
  Expect<Boolean>(LiveRectsClose(Once, Twice, RectEpsilon)).ToBe(True);
  Expect<Boolean>(IsInside(Once, Bounds)).ToBe(True);
end;

procedure TRectTests.TestContainsIncludesTheEdges;
var
  Rect: TLiveRect;
begin
  Rect := LiveRect(10, 20, 100, 50);
  Expect<Boolean>(LiveRectContains(Rect, 10, 20)).ToBe(True);
  Expect<Boolean>(LiveRectContains(Rect, 110, 70)).ToBe(True);
  Expect<Boolean>(LiveRectContains(Rect, 60, 45)).ToBe(True);
  Expect<Boolean>(LiveRectContains(Rect, 9.9, 45)).ToBe(False);
  Expect<Boolean>(LiveRectContains(Rect, 60, 70.1)).ToBe(False);
end;

{ TZoomTests }

procedure TZoomTests.SetupTests;
begin
  Test('zoom 1 hands back the window unchanged', TestZoomOneIsTheIdentity);
  Test('zoom 2 halves each axis', TestZoomHalvesEachAxis);
  Test('the crop is centred on the click', TestZoomCentresOnTheFocus);
  Test('a click in a corner still crops inside the window',
    TestZoomAtACornerStaysInside);
  Test('no focus point and no zoom level escapes the window',
    TestZoomIsAlwaysInsideTheWindow);
  Test('the zoom level is clamped at both ends', TestZoomIsClamped);
end;

procedure TZoomTests.TestZoomOneIsTheIdentity;
var
  Window: TLiveRect;
begin
  Window := LiveRect(200, 100, 640, 480);
  ExpectRect(ZoomedSourceRect(Window, 1.0, 520, 340), 200, 100, 640, 480);
  // Even with the focus nowhere near the middle: there is no room to move.
  ExpectRect(ZoomedSourceRect(Window, 1.0, 0, 0), 200, 100, 640, 480);
end;

procedure TZoomTests.TestZoomHalvesEachAxis;
var
  Source: TLiveRect;
begin
  Source := ZoomedSourceRect(LiveRect(0, 0, 640, 480), 2.0, 320, 240);
  ExpectRect(Source, 160, 120, 320, 240);
end;

procedure TZoomTests.TestZoomCentresOnTheFocus;
var
  Source: TLiveRect;
begin
  Source := ZoomedSourceRect(LiveRect(0, 0, 800, 600), 2.0, 300, 200);
  ExpectNear(Source.X + Source.Width / 2, 300, RectEpsilon, 'centre x');
  ExpectNear(Source.Y + Source.Height / 2, 200, RectEpsilon, 'centre y');
end;

procedure TZoomTests.TestZoomAtACornerStaysInside;
var
  Window, Source: TLiveRect;
begin
  Window := LiveRect(100, 100, 400, 400);
  Source := ZoomedSourceRect(Window, 2.0, 100, 100);
  ExpectRect(Source, 100, 100, 200, 200);
  Source := ZoomedSourceRect(Window, 2.0, 500, 500);
  ExpectRect(Source, 300, 300, 200, 200);
end;

procedure TZoomTests.TestZoomIsAlwaysInsideTheWindow;
var
  Window, Source: TLiveRect;
  Zoom, FocusX, FocusY: Double;
  I, J: Integer;
begin
  Window := LiveRect(-40, 17, 733, 411);
  for I := 0 to 40 do
  begin
    Zoom := 0.25 + I * 0.5;
    for J := 0 to 40 do
    begin
      FocusX := -400 + J * 60;
      FocusY := -300 + J * 45;
      Source := ZoomedSourceRect(Window, Zoom, FocusX, FocusY);
      ExpectTrue(IsInside(Source, Window),
        Format('zoom %.2f at (%.0f, %.0f) is inside the window',
        [Zoom, FocusX, FocusY]));
    end;
  end;
end;

procedure TZoomTests.TestZoomIsClamped;
var
  Window, Source: TLiveRect;
begin
  Window := LiveRect(0, 0, 640, 480);
  // Below 1 would ask ScreenCaptureKit for pixels outside the region.
  ExpectRect(ZoomedSourceRect(Window, 0.1, 320, 240), 0, 0, 640, 480);
  Source := ZoomedSourceRect(Window, 1000, 320, 240);
  ExpectNear(Source.Width, 640 / LiveMaxZoom, RectEpsilon, 'width');
  ExpectNear(Source.Height, 480 / LiveMaxZoom, RectEpsilon, 'height');
end;

{ TFollowTests }

procedure TFollowTests.SetupTests;
begin
  Test('the mouse inside the dead zone moves nothing',
    TestDeadZoneDoesNotMove);
  Test('leaving the dead zone moves the window by exactly the overshoot',
    TestLeavingTheDeadZoneMovesByTheOvershoot);
  Test('following never walks off the display', TestFollowStaysOnTheDisplay);
  Test('a zero dead zone centres the window on the mouse',
    TestZeroDeadZoneCentresOnTheMouse);
  Test('following never changes the window size', TestFollowNeverResizes);
end;

procedure TFollowTests.TestDeadZoneDoesNotMove;
var
  Window, Bounds, Target: TLiveRect;
begin
  Bounds := LiveRect(0, 0, 1920, 1080);
  Window := LiveRect(600, 300, 600, 300);
  // The middle third is 200 x 100 centred at (900, 450).
  Target := FollowWindowTarget(Window, Bounds, 900, 450,
    LiveDeadZoneFraction);
  ExpectRect(Target, 600, 300, 600, 300);
  Target := FollowWindowTarget(Window, Bounds, 999, 499,
    LiveDeadZoneFraction);
  ExpectRect(Target, 600, 300, 600, 300);
end;

procedure TFollowTests.TestLeavingTheDeadZoneMovesByTheOvershoot;
var
  Window, Bounds, Target: TLiveRect;
begin
  Bounds := LiveRect(0, 0, 1920, 1080);
  Window := LiveRect(600, 300, 600, 300);
  // Dead zone x spans 800..1000; 1040 overshoots the right edge by 40.
  Target := FollowWindowTarget(Window, Bounds, 1040, 450,
    LiveDeadZoneFraction);
  ExpectRect(Target, 640, 300, 600, 300);
  // Dead zone y spans 400..500; 370 undershoots the top by 30.
  Target := FollowWindowTarget(Window, Bounds, 900, 370,
    LiveDeadZoneFraction);
  ExpectRect(Target, 600, 270, 600, 300);
end;

procedure TFollowTests.TestFollowStaysOnTheDisplay;
var
  Window, Bounds, Target: TLiveRect;
  I: Integer;
begin
  Bounds := LiveRect(0, 0, 1440, 900);
  Window := LiveRect(400, 300, 500, 400);
  for I := -20 to 40 do
  begin
    Target := FollowWindowTarget(Window, Bounds, I * 100, I * 60,
      LiveDeadZoneFraction);
    ExpectTrue(IsInside(Target, Bounds),
      Format('the mouse at (%d, %d) leaves the window on the display',
      [I * 100, I * 60]));
  end;
end;

procedure TFollowTests.TestZeroDeadZoneCentresOnTheMouse;
var
  Target: TLiveRect;
begin
  Target := FollowWindowTarget(LiveRect(0, 0, 400, 200),
    LiveRect(0, 0, 4000, 2000), 1000, 700, 0);
  ExpectNear(Target.X + Target.Width / 2, 1000, RectEpsilon, 'centre x');
  ExpectNear(Target.Y + Target.Height / 2, 700, RectEpsilon, 'centre y');
end;

procedure TFollowTests.TestFollowNeverResizes;
var
  Window, Target: TLiveRect;
begin
  Window := LiveRect(0, 0, 500, 400);
  Target := FollowWindowTarget(Window, LiveRect(0, 0, 1000, 800), 9999,
    -9999, LiveDeadZoneFraction);
  ExpectNear(Target.Width, 500, RectEpsilon, 'width');
  ExpectNear(Target.Height, 400, RectEpsilon, 'height');
end;

{ TEasingTests }

procedure TEasingTests.SetupTests;
begin
  Test('smoothstep spans 0 to 1 and clamps outside it',
    TestSmoothstepEndsAndClamps);
  Test('smoothstep leaves and arrives at rest',
    TestSmoothstepIsFlatAtBothEnds);
  Test('an eased scalar runs the whole way and stops',
    TestEasedScalarRunsFromStartToTarget);
  Test('retargeting mid-flight starts from where the curve had got to',
    TestRetargetStartsFromTheCurrentValue);
  Test('advancing past the duration does not overshoot',
    TestAdvanceNeverOvershoots);
  Test('one long tick lands where four short ones do',
    TestApproachFactorIsFrameRateIndependent);
  Test('an approach converges on its target', TestApproachRectConverges);
end;

procedure TEasingTests.TestSmoothstepEndsAndClamps;
begin
  ExpectNear(Smoothstep(0), 0, Epsilon, 'at 0');
  ExpectNear(Smoothstep(1), 1, Epsilon, 'at 1');
  ExpectNear(Smoothstep(0.5), 0.5, Epsilon, 'at the middle');
  ExpectNear(Smoothstep(-3), 0, Epsilon, 'below');
  ExpectNear(Smoothstep(9), 1, Epsilon, 'above');
end;

procedure TEasingTests.TestSmoothstepIsFlatAtBothEnds;
var
  Step: Double;
begin
  Step := 1E-4;
  // The derivative is zero at both ends, so the first and last slice of
  // the curve move a hundredth of what the middle does.
  ExpectNear((Smoothstep(Step) - Smoothstep(0)) / Step, 0, 1E-3, 'start');
  ExpectNear((Smoothstep(1) - Smoothstep(1 - Step)) / Step, 0, 1E-3, 'end');
  Expect<Boolean>((Smoothstep(0.5 + Step) - Smoothstep(0.5)) / Step
    > 1.4).ToBe(True);
end;

procedure TEasingTests.TestEasedScalarRunsFromStartToTarget;
var
  Scalar: TEasedScalar;
  Previous, Current: Double;
  I: Integer;
begin
  Scalar := EasedScalarRetarget(EasedScalar(1.0), 2.0, LiveZoomInSeconds);
  ExpectNear(EasedScalarValue(Scalar), 1.0, Epsilon, 'at the start');
  Expect<Boolean>(EasedScalarSettled(Scalar)).ToBe(False);
  Previous := EasedScalarValue(Scalar);
  for I := 1 to 30 do
  begin
    Scalar := EasedScalarAdvance(Scalar, LiveTickSeconds);
    Current := EasedScalarValue(Scalar);
    Expect<Boolean>(Current >= Previous - Epsilon).ToBe(True);
    Previous := Current;
  end;
  ExpectNear(EasedScalarValue(Scalar), 2.0, Epsilon, 'at the end');
  Expect<Boolean>(EasedScalarSettled(Scalar)).ToBe(True);
end;

procedure TEasingTests.TestRetargetStartsFromTheCurrentValue;
var
  Scalar: TEasedScalar;
  Midway: Double;
begin
  Scalar := EasedScalarRetarget(EasedScalar(1.0), 2.0, 1.0);
  Scalar := EasedScalarAdvance(Scalar, 0.5);
  Midway := EasedScalarValue(Scalar);
  ExpectNear(Midway, 1.5, Epsilon, 'halfway');
  // A second click while the first zoom is still running.
  Scalar := EasedScalarRetarget(Scalar, 1.0, 1.0);
  ExpectNear(EasedScalarValue(Scalar), Midway, Epsilon, 'no jump');
  Scalar := EasedScalarAdvance(Scalar, 1.0);
  ExpectNear(EasedScalarValue(Scalar), 1.0, Epsilon, 'arrives');
end;

procedure TEasingTests.TestAdvanceNeverOvershoots;
var
  Scalar: TEasedScalar;
begin
  Scalar := EasedScalarRetarget(EasedScalar(0), 10, 0.2);
  Scalar := EasedScalarAdvance(Scalar, 5.0);
  ExpectNear(Scalar.Elapsed, 0.2, Epsilon, 'elapsed');
  ExpectNear(EasedScalarValue(Scalar), 10, Epsilon, 'value');
  // A negative or zero delta is a clock that did not move.
  Scalar := EasedScalarAdvance(Scalar, -1.0);
  ExpectNear(Scalar.Elapsed, 0.2, Epsilon, 'unchanged');
  // A zero-duration retarget is an immediate move, not a division by zero.
  Scalar := EasedScalarRetarget(Scalar, 3, 0);
  ExpectNear(EasedScalarValue(Scalar), 3, Epsilon, 'immediate');
  Expect<Boolean>(EasedScalarSettled(Scalar)).ToBe(True);
end;

procedure TEasingTests.TestApproachFactorIsFrameRateIndependent;
var
  Slow, Fast, Remaining: Double;
  I: Integer;
begin
  // One 1/30 s tick against four 1/120 s ticks over the same 1/30 s.
  Slow := 1 - ApproachFactor(1 / 30, LiveFollowTimeConstant);
  Remaining := 1.0;
  for I := 1 to 4 do
    Remaining := Remaining * (1 - ApproachFactor(1 / 120,
      LiveFollowTimeConstant));
  Fast := Remaining;
  ExpectNear(Fast, Slow, 1E-12, 'remaining distance');
  ExpectNear(ApproachFactor(0, LiveFollowTimeConstant), 0, Epsilon, 'no time');
  ExpectNear(ApproachFactor(1, 0), 1, Epsilon, 'no time constant');
end;

procedure TEasingTests.TestApproachRectConverges;
var
  Current, Target: TLiveRect;
  I: Integer;
begin
  Current := LiveRect(0, 0, 100, 100);
  Target := LiveRect(400, 250, 100, 100);
  for I := 1 to 120 do
    Current := ApproachRect(Current, Target,
      ApproachFactor(LiveTickSeconds, LiveFollowTimeConstant));
  Expect<Boolean>(LiveRectsClose(Current, Target, 0.01)).ToBe(True);
  // A factor of 0 is a tick that did no work; 1 arrives at once.
  ExpectRect(ApproachRect(LiveRect(0, 0, 10, 10), Target, 0), 0, 0, 10, 10);
  ExpectRect(ApproachRect(LiveRect(0, 0, 10, 10), Target, 1), 400, 250,
    100, 100);
end;

{ TCompositionTests }

procedure TCompositionTests.SetupTests;
begin
  Test('the zoomed crop stays inside a panned window',
    TestZoomComposesInsideFollow);
  Test('a window capture gets neither effect',
    TestWindowCaptureGetsNoEffects);
  Test('a whole-display capture can zoom but not follow',
    TestDisplayCaptureCannotFollow);
  Test('a region on a display gets both', TestRegionCaptureGetsBoth);
  Test('both preferences off means no live recording at all',
    TestBothOffIsNoLiveRecording);
end;

// The whole feature in one loop: a mouse walking across the display with
// Follow on, a click every 20 ticks with Zoom on, and the two invariants
// the border and the writer depend on — the crop inside the window, the
// window inside the display, and the window never resized.
procedure TCompositionTests.TestZoomComposesInsideFollow;
var
  Bounds, Base, Window, Source: TLiveRect;
  Zoom: TEasedScalar;
  MouseX, MouseY: Double;
  Tick: Integer;
begin
  Bounds := LiveRect(0, 0, 1728, 1117);
  Base := LiveRect(500, 400, 600, 400);
  Window := Base;
  Zoom := EasedScalar(LiveMinZoom);
  for Tick := 0 to 300 do
  begin
    MouseX := 20 + Tick * 5.5;
    MouseY := 1050 - Tick * 3.3;
    Window := ApproachRect(Window,
      FollowWindowTarget(Window, Bounds, MouseX, MouseY,
      LiveDeadZoneFraction),
      ApproachFactor(LiveTickSeconds, LiveFollowTimeConstant));
    if Tick mod 20 = 0 then
      Zoom := EasedScalarRetarget(Zoom, LiveClickZoom, LiveZoomInSeconds)
    else
      Zoom := EasedScalarAdvance(Zoom, LiveTickSeconds);
    Source := ZoomedSourceRect(Window, EasedScalarValue(Zoom), MouseX,
      MouseY);
    ExpectTrue(IsInside(Source, Window),
      Format('tick %d: the crop is inside the follow window', [Tick]));
    ExpectTrue(IsInside(Window, Bounds),
      Format('tick %d: the follow window is on the display', [Tick]));
    ExpectNear(Window.Width, Base.Width, 1E-6, 'window width');
    ExpectNear(Window.Height, Base.Height, 1E-6, 'window height');
  end;
end;

procedure TCompositionTests.TestWindowCaptureGetsNoEffects;
var
  Zoom, Follow: Boolean;
begin
  Expect<Boolean>(ResolveLiveEffects(ctkWindow, False, True, True, Zoom,
    Follow)).ToBe(False);
  Expect<Boolean>(Zoom).ToBe(False);
  Expect<Boolean>(Follow).ToBe(False);
end;

procedure TCompositionTests.TestDisplayCaptureCannotFollow;
var
  Zoom, Follow: Boolean;
begin
  Expect<Boolean>(ResolveLiveEffects(ctkDisplay, False, True, True, Zoom,
    Follow)).ToBe(True);
  Expect<Boolean>(Zoom).ToBe(True);
  Expect<Boolean>(Follow).ToBe(False);
  // Follow alone on a whole display leaves nothing to do.
  Expect<Boolean>(ResolveLiveEffects(ctkDisplay, False, False, True, Zoom,
    Follow)).ToBe(False);
end;

procedure TCompositionTests.TestRegionCaptureGetsBoth;
var
  Zoom, Follow: Boolean;
begin
  Expect<Boolean>(ResolveLiveEffects(ctkDisplay, True, True, True, Zoom,
    Follow)).ToBe(True);
  Expect<Boolean>(Zoom).ToBe(True);
  Expect<Boolean>(Follow).ToBe(True);
  Expect<Boolean>(ResolveLiveEffects(ctkDisplay, True, False, True, Zoom,
    Follow)).ToBe(True);
  Expect<Boolean>(Zoom).ToBe(False);
  Expect<Boolean>(Follow).ToBe(True);
end;

procedure TCompositionTests.TestBothOffIsNoLiveRecording;
var
  Zoom, Follow: Boolean;
begin
  Expect<Boolean>(ResolveLiveEffects(ctkDisplay, True, False, False, Zoom,
    Follow)).ToBe(False);
  Expect<Boolean>(Zoom).ToBe(False);
  Expect<Boolean>(Follow).ToBe(False);
end;

begin
  TestRunnerProgram.AddSuite(TRectTests.Create('live rectangles'));
  TestRunnerProgram.AddSuite(TZoomTests.Create('zoom on click'));
  TestRunnerProgram.AddSuite(TFollowTests.Create('follow mouse'));
  TestRunnerProgram.AddSuite(TEasingTests.Create('easing'));
  TestRunnerProgram.AddSuite(TCompositionTests.Create(
    'composing zoom and follow'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

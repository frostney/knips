program Knips.Export.ZoomTrack.Test;

// Post-recording Zoom on Click, checked on the properties the render pass
// depends on and cannot check for itself:
//
//   - a take with no clicks is not zoomed at all, at any time, so
//     switching the effect on costs a clickless recording nothing;
//   - one click reproduces the live effect's shape — in over
//     LiveZoomInSeconds, held for LiveZoomHoldSeconds after the *last*
//     click, out over LiveZoomOutSeconds — and lands on the live 2x;
//   - the crop is always inside the recorded rectangle, so the render can
//     never ask for pixels the movie does not have;
//   - the walk is independent of how often it is asked: a caller stepping
//     at 30 fps and one stepping at 60 fps agree, and both agree with the
//     reference function that starts from scratch every time. This is the
//     property that makes the effect a function of the movie rather than
//     of the machine that rendered it;
//   - the sidecar's clicks are filtered the way the live effect filters
//     them: presses only, inside the recorded rectangle, below the menu
//     bar — the last of which is what keeps the click that stops a
//     recording from zooming into the top corner of every take.

{$I Knips.inc}

uses
  Math,
  SysUtils,

  Knips.Export.ZoomTrack,
  Knips.Options,
  Knips.Recording.LiveMath,
  Knips.Recording.Sidecar,
  TestingPascalLibrary;

type
  TQuietTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestNoClicksNeverZooms;
    procedure TestBeforeTheFirstClickIsTheBase;
  end;

  TShapeTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestOneClickReachesTheLiveFactor;
    procedure TestZoomHoldsAfterTheClick;
    procedure TestZoomReturnsToTheBase;
    procedure TestASecondClickRefillsTheHold;
    procedure TestTheCropCentresOnTheClick;
    procedure TestAnExplicitFactorIsHonoured;
  end;

  TInvariantTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestCropStaysInsideTheBase;
    procedure TestWalkMatchesTheReference;
    procedure TestWalkIsIndependentOfStepSize;
  end;

  TClickFilterTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestOnlyPressesAreClicks;
    procedure TestMenuBarClicksAreNotContent;
    procedure TestClicksOutsideTheRegionAreIgnored;
    procedure TestAWindowRecordingHasNoUsableClicks;
    procedure TestNoAnchorMeansNoClicks;
  end;

  TFrameCropTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheBaseIsTheWholeFrame;
    procedure TestHalfTheBaseIsHalfTheFrame;
    procedure TestACropIsNeverEmpty;
    procedure TestACropNeverLeavesTheFrame;
  end;

{ ---------------------------------------------------------------- helpers }

const
  RectEpsilon = 1E-6;
  // The recorded rectangle every test below zooms inside: a 640x400
  // region at (120, 80) of a display, which is the shape a region take
  // has and the one a whole-display take reduces to.
  BaseX = 120.0;
  BaseY = 80.0;
  BaseWidth = 640.0;
  BaseHeight = 400.0;

function TestBase: TLiveRect;
begin
  Result := LiveRect(BaseX, BaseY, BaseWidth, BaseHeight);
end;

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

function OneClick(ASeconds, AX, AY: Double): TZoomClickArray;
begin
  SetLength(Result, 1);
  Result[0].Seconds := ASeconds;
  Result[0].X := AX;
  Result[0].Y := AY;
end;

function RectAt(const AClicks: TZoomClickArray;
  ASeconds: Double): TLiveRect;
begin
  Result := ZoomSourceRectAt(TestBase, 0, 0, AClicks, ASeconds);
end;

function IsInside(const AInner, AOuter: TLiveRect): Boolean;
begin
  Result := (AInner.X >= AOuter.X - RectEpsilon)
    and (AInner.Y >= AOuter.Y - RectEpsilon)
    and (AInner.X + AInner.Width <= AOuter.X + AOuter.Width + RectEpsilon)
    and (AInner.Y + AInner.Height <= AOuter.Y + AOuter.Height + RectEpsilon);
end;

// A sidecar with a header, an anchor and whatever button lines the test
// wants, so the click filter is exercised through the real reader rather
// than through a hand-built array.
function LogWith(const ATarget: string; AMenuBarInset: Double;
  const AButtons: string; AWithAnchor: Boolean): TSidecarLog;
var
  Text, Error: string;
begin
  Text := '{"k":"header","format":"knips-events","version":1,'
    + '"knips":"0.1.0","movie":"demo.mp4","created":"2026-08-27T00:00:00Z",'
    + '"pid":1,"target":"' + ATarget + '","pixelWidth":1280,'
    + '"pixelHeight":800,"scale":2,"fps":30,"sampleHz":30.000,'
    + '"displayId":1,"displayWidth":1512.000,"displayHeight":982.000,'
    + '"baseX":120.000,"baseY":80.000,"baseWidth":640.000,'
    + '"baseHeight":400.000,"menuBarInset":'
    + FloatToStrF(AMenuBarInset, ffFixed, 15, 3, DefaultFormatSettings)
    + ',"cursor":"smooth","bakedZoomOnClick":false,'
    + '"bakedFollowMouse":false,"bakedWindowFollow":false,"audio":"none"}'
    + LineEnding;
  if AWithAnchor then
    Text := Text + '{"k":"anchor","host":1000.000000}' + LineEnding;
  Text := Text + AButtons;
  Result := TSidecarLog.Create;
  Result.LoadFromText(Text, Error);
end;

function ButtonLine(AHost, AX, AY: Double; ADown: Boolean): string;
begin
  Result := Format('{"k":"button","t":%.6f,"x":%.3f,"y":%.3f,"n":0,"d":%s}',
    [AHost, AX, AY, BoolToStr(ADown, 'true', 'false')], DefaultFormatSettings)
    + LineEnding;
end;

{ TQuietTests }

procedure TQuietTests.SetupTests;
begin
  Test('a take with no clicks is never zoomed', TestNoClicksNeverZooms);
  Test('before the first click the crop is the whole rectangle',
    TestBeforeTheFirstClickIsTheBase);
end;

procedure TQuietTests.TestNoClicksNeverZooms;
var
  Clicks: TZoomClickArray;
  Rect: TLiveRect;
  I: Integer;
begin
  SetLength(Clicks, 0);
  for I := 0 to 20 do
  begin
    Rect := RectAt(Clicks, I * 0.5);
    ExpectNear(Rect.Width, BaseWidth, RectEpsilon, 'width');
    ExpectNear(Rect.Height, BaseHeight, RectEpsilon, 'height');
  end;
end;

procedure TQuietTests.TestBeforeTheFirstClickIsTheBase;
var
  Rect: TLiveRect;
begin
  Rect := RectAt(OneClick(2.0, 300, 200), 1.999);
  ExpectNear(Rect.X, BaseX, RectEpsilon, 'x');
  ExpectNear(Rect.Y, BaseY, RectEpsilon, 'y');
  ExpectNear(Rect.Width, BaseWidth, RectEpsilon, 'width');
end;

{ TShapeTests }

procedure TShapeTests.SetupTests;
begin
  Test('a click reaches the live effect''s own zoom factor',
    TestOneClickReachesTheLiveFactor);
  Test('the zoom holds after the click', TestZoomHoldsAfterTheClick);
  Test('the zoom eases back to the whole rectangle',
    TestZoomReturnsToTheBase);
  Test('a second click refills the hold rather than easing out between',
    TestASecondClickRefillsTheHold);
  Test('the crop centres on the click', TestTheCropCentresOnTheClick);
  Test('an explicit factor replaces the live one',
    TestAnExplicitFactorIsHonoured);
end;

procedure TShapeTests.TestOneClickReachesTheLiveFactor;
var
  Clicks: TZoomClickArray;
begin
  Clicks := OneClick(1.0, 400, 250);
  // At the click itself nothing has moved yet: smoothstep starts at rest.
  ExpectNear(RectAt(Clicks, 1.0).Width, BaseWidth, RectEpsilon,
    'width at the click');
  ExpectNear(RectAt(Clicks, 1.0 + LiveZoomInSeconds).Width,
    BaseWidth / LiveClickZoom, RectEpsilon, 'width when the zoom is in');
  ExpectNear(RectAt(Clicks, 1.0 + LiveZoomInSeconds).Height,
    BaseHeight / LiveClickZoom, RectEpsilon, 'height when the zoom is in');
end;

procedure TShapeTests.TestZoomHoldsAfterTheClick;
var
  Clicks: TZoomClickArray;
begin
  Clicks := OneClick(1.0, 400, 250);
  // The hold runs from the click, and the zoom-in fits inside it.
  ExpectNear(RectAt(Clicks, 1.0 + LiveZoomHoldSeconds - 0.01).Width,
    BaseWidth / LiveClickZoom, RectEpsilon, 'width just before the hold ends');
end;

procedure TShapeTests.TestZoomReturnsToTheBase;
var
  Clicks: TZoomClickArray;
begin
  Clicks := OneClick(1.0, 400, 250);
  ExpectNear(RectAt(Clicks,
    1.0 + LiveZoomHoldSeconds + LiveZoomOutSeconds).Width, BaseWidth,
    RectEpsilon, 'width once the zoom has eased out');
  // And it stays there: nothing restarts on its own.
  ExpectNear(RectAt(Clicks, 30.0).Width, BaseWidth, RectEpsilon,
    'width long afterwards');
end;

procedure TShapeTests.TestASecondClickRefillsTheHold;
var
  Clicks: TZoomClickArray;
begin
  SetLength(Clicks, 2);
  Clicks[0].Seconds := 1.0;
  Clicks[0].X := 400;
  Clicks[0].Y := 250;
  Clicks[1].Seconds := 1.0 + LiveZoomHoldSeconds - 0.05;
  Clicks[1].X := 400;
  Clicks[1].Y := 250;
  // Without the refill the zoom would have started easing out by now.
  ExpectNear(RectAt(Clicks, 1.0 + LiveZoomHoldSeconds + 0.2).Width,
    BaseWidth / LiveClickZoom, RectEpsilon,
    'width after the first hold would have expired');
end;

procedure TShapeTests.TestTheCropCentresOnTheClick;
var
  Clicks: TZoomClickArray;
  Rect: TLiveRect;
begin
  // A click in the middle of the rectangle, where the crop can centre
  // without being clamped by an edge.
  Clicks := OneClick(1.0, BaseX + BaseWidth / 2, BaseY + BaseHeight / 2);
  Rect := RectAt(Clicks, 1.0 + LiveZoomInSeconds);
  ExpectNear(Rect.X + Rect.Width / 2, BaseX + BaseWidth / 2, RectEpsilon,
    'crop centre x');
  ExpectNear(Rect.Y + Rect.Height / 2, BaseY + BaseHeight / 2, RectEpsilon,
    'crop centre y');
end;

procedure TShapeTests.TestAnExplicitFactorIsHonoured;
var
  Clicks: TZoomClickArray;
  Rect: TLiveRect;
begin
  Clicks := OneClick(1.0, 400, 250);
  Rect := ZoomSourceRectAt(TestBase, 4.0, 0, Clicks,
    1.0 + LiveZoomInSeconds);
  ExpectNear(Rect.Width, BaseWidth / 4, RectEpsilon, 'width at 4x');
end;

{ TInvariantTests }

procedure TInvariantTests.SetupTests;
begin
  Test('the crop never leaves the recorded rectangle',
    TestCropStaysInsideTheBase);
  Test('walking forward agrees with starting from scratch',
    TestWalkMatchesTheReference);
  Test('the walk does not depend on how often it is asked',
    TestWalkIsIndependentOfStepSize);
end;

procedure TInvariantTests.TestCropStaysInsideTheBase;
var
  Clicks: TZoomClickArray;
  I: Integer;
  Rect: TLiveRect;
begin
  // Clicks in every corner, including exactly on the edges, which is
  // where a crop centred on the click would hang off the rectangle.
  SetLength(Clicks, 4);
  Clicks[0].Seconds := 0.5;
  Clicks[0].X := BaseX;
  Clicks[0].Y := BaseY;
  Clicks[1].Seconds := 2.5;
  Clicks[1].X := BaseX + BaseWidth;
  Clicks[1].Y := BaseY;
  Clicks[2].Seconds := 4.5;
  Clicks[2].X := BaseX;
  Clicks[2].Y := BaseY + BaseHeight;
  Clicks[3].Seconds := 6.5;
  Clicks[3].X := BaseX + BaseWidth;
  Clicks[3].Y := BaseY + BaseHeight;
  for I := 0 to 400 do
  begin
    Rect := RectAt(Clicks, I * 0.02);
    ExpectTrue(IsInside(Rect, TestBase),
      Format('the crop at %.2fs is inside the rectangle', [I * 0.02]));
  end;
end;

procedure TInvariantTests.TestWalkMatchesTheReference;
var
  Clicks: TZoomClickArray;
  Walker: TZoomWalker;
  I: Integer;
  Seconds: Double;
  Walked, Fresh: TLiveRect;
begin
  SetLength(Clicks, 3);
  Clicks[0].Seconds := 0.4;
  Clicks[0].X := 300;
  Clicks[0].Y := 200;
  Clicks[1].Seconds := 0.9;
  Clicks[1].X := 600;
  Clicks[1].Y := 300;
  Clicks[2].Seconds := 3.0;
  Clicks[2].X := 200;
  Clicks[2].Y := 120;
  Walker := ZoomWalkerStart(TestBase, 0, 0);
  for I := 0 to 200 do
  begin
    Seconds := I / 30;
    Walker := ZoomWalkerAdvance(Walker, Clicks, Seconds);
    Walked := ZoomWalkerSourceRect(Walker);
    Fresh := RectAt(Clicks, Seconds);
    ExpectNear(Walked.X, Fresh.X, RectEpsilon,
      Format('walked x at %.4fs', [Seconds]));
    ExpectNear(Walked.Width, Fresh.Width, RectEpsilon,
      Format('walked width at %.4fs', [Seconds]));
  end;
end;

procedure TInvariantTests.TestWalkIsIndependentOfStepSize;
var
  Clicks: TZoomClickArray;
  Coarse, Fine: TZoomWalker;
  I: Integer;
begin
  Clicks := OneClick(0.25, 500, 300);
  Coarse := ZoomWalkerStart(TestBase, 0, 0);
  Fine := ZoomWalkerStart(TestBase, 0, 0);
  for I := 1 to 60 do
    Coarse := ZoomWalkerAdvance(Coarse, Clicks, I / 30);
  for I := 1 to 120 do
    Fine := ZoomWalkerAdvance(Fine, Clicks, I / 60);
  ExpectNear(ZoomWalkerSourceRect(Fine).Width,
    ZoomWalkerSourceRect(Coarse).Width, RectEpsilon,
    'width after two step sizes');
  ExpectNear(ZoomWalkerSourceRect(Fine).X, ZoomWalkerSourceRect(Coarse).X,
    RectEpsilon, 'x after two step sizes');
end;

{ TClickFilterTests }

procedure TClickFilterTests.SetupTests;
begin
  Test('a release is not a click', TestOnlyPressesAreClicks);
  Test('a click on the menu bar is not content',
    TestMenuBarClicksAreNotContent);
  Test('a click outside the recorded rectangle is ignored',
    TestClicksOutsideTheRegionAreIgnored);
  Test('a window recording has no clicks this effect can use',
    TestAWindowRecordingHasNoUsableClicks);
  Test('without an anchor there is no timeline to place a click on',
    TestNoAnchorMeansNoClicks);
end;

procedure TClickFilterTests.TestOnlyPressesAreClicks;
var
  Log: TSidecarLog;
  Clicks: TZoomClickArray;
begin
  Log := LogWith('display', 0, ButtonLine(1001.0, 400, 250, True)
    + ButtonLine(1001.1, 400, 250, False), True);
  try
    Clicks := ZoomClicksFromLog(Log);
    Expect<Integer>(Length(Clicks)).ToBe(1);
    ExpectNear(Clicks[0].Seconds, 1.0, 1E-6, 'the press, in movie seconds');
  finally
    Log.Free;
  end;
end;

procedure TClickFilterTests.TestMenuBarClicksAreNotContent;
var
  Log: TSidecarLog;
begin
  // y = 12 is inside a 39-point menu-bar band; y = 250 is not.
  Log := LogWith('display', 39, ButtonLine(1001.0, 400, 12, True)
    + ButtonLine(1002.0, 400, 250, True), True);
  try
    Expect<Integer>(Length(ZoomClicksFromLog(Log))).ToBe(1);
  finally
    Log.Free;
  end;
end;

procedure TClickFilterTests.TestClicksOutsideTheRegionAreIgnored;
var
  Log: TSidecarLog;
begin
  // The base rectangle in LogWith is 120,80 640x400.
  Log := LogWith('display', 0, ButtonLine(1001.0, 20, 250, True)
    + ButtonLine(1002.0, 400, 250, True), True);
  try
    Expect<Integer>(Length(ZoomClicksFromLog(Log))).ToBe(1);
  finally
    Log.Free;
  end;
end;

procedure TClickFilterTests.TestAWindowRecordingHasNoUsableClicks;
var
  Log: TSidecarLog;
begin
  Log := LogWith('window', 0, ButtonLine(1001.0, 400, 250, True), True);
  try
    Expect<Integer>(Length(ZoomClicksFromLog(Log))).ToBe(0);
  finally
    Log.Free;
  end;
end;

procedure TClickFilterTests.TestNoAnchorMeansNoClicks;
var
  Log: TSidecarLog;
begin
  Log := LogWith('display', 0, ButtonLine(1001.0, 400, 250, True), False);
  try
    Expect<Integer>(Length(ZoomClicksFromLog(Log))).ToBe(0);
  finally
    Log.Free;
  end;
end;

{ TFrameCropTests }

procedure TFrameCropTests.SetupTests;
begin
  Test('the whole rectangle is the whole frame', TestTheBaseIsTheWholeFrame);
  Test('half the rectangle is half the frame',
    TestHalfTheBaseIsHalfTheFrame);
  Test('a crop is never empty', TestACropIsNeverEmpty);
  Test('a crop never leaves the frame', TestACropNeverLeavesTheFrame);
end;

procedure TFrameCropTests.TestTheBaseIsTheWholeFrame;
var
  Crop: TZoomCrop;
begin
  Crop := ZoomFrameCrop(1280, 800, TestBase, TestBase);
  Expect<Integer>(Crop.X).ToBe(0);
  Expect<Integer>(Crop.Y).ToBe(0);
  Expect<Integer>(Crop.Width).ToBe(1280);
  Expect<Integer>(Crop.Height).ToBe(800);
  ExpectTrue(Crop.Identity, 'the crop is the identity');
end;

procedure TFrameCropTests.TestHalfTheBaseIsHalfTheFrame;
var
  Crop: TZoomCrop;
begin
  Crop := ZoomFrameCrop(1280, 800, TestBase,
    LiveRect(BaseX + BaseWidth / 4, BaseY + BaseHeight / 4, BaseWidth / 2,
    BaseHeight / 2));
  Expect<Integer>(Crop.X).ToBe(320);
  Expect<Integer>(Crop.Y).ToBe(200);
  Expect<Integer>(Crop.Width).ToBe(640);
  Expect<Integer>(Crop.Height).ToBe(400);
  ExpectTrue(not Crop.Identity, 'a half crop is not the identity');
end;

procedure TFrameCropTests.TestACropIsNeverEmpty;
var
  Crop: TZoomCrop;
begin
  Crop := ZoomFrameCrop(1280, 800, TestBase,
    LiveRect(BaseX, BaseY, 0.01, 0.01));
  ExpectTrue(Crop.Width >= 1, 'the crop has width');
  ExpectTrue(Crop.Height >= 1, 'the crop has height');
end;

procedure TFrameCropTests.TestACropNeverLeavesTheFrame;
var
  Crop: TZoomCrop;
begin
  // A source rectangle that hangs off both far edges, which nothing
  // upstream produces and everything downstream indexes memory with.
  Crop := ZoomFrameCrop(1280, 800, TestBase,
    LiveRect(BaseX + BaseWidth - 10, BaseY + BaseHeight - 10, 400, 400));
  ExpectTrue(Crop.X >= 0, 'x is on the frame');
  ExpectTrue(Crop.Y >= 0, 'y is on the frame');
  ExpectTrue(Crop.X + Crop.Width <= 1280, 'the crop ends on the frame');
  ExpectTrue(Crop.Y + Crop.Height <= 800, 'the crop ends on the frame');
end;

begin
  TestRunnerProgram.AddSuite(TQuietTests.Create('a take with no clicks'));
  TestRunnerProgram.AddSuite(TShapeTests.Create('the shape of one zoom'));
  TestRunnerProgram.AddSuite(TInvariantTests.Create('invariants'));
  TestRunnerProgram.AddSuite(TClickFilterTests.Create(
    'which clicks count'));
  TestRunnerProgram.AddSuite(TFrameCropTests.Create('the frame crop'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

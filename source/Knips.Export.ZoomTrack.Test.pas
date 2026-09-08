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
  SysUtils,

  Knips.Export.ZoomTrack,
  Knips.Options,
  Knips.Recording.CursorMath,
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
    procedure TestWalkMatchesTheReferenceWithAnExplicitHold;
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

  // Zoom composed inside a framing the capture panned. This is what
  // makes a Follow Mouse take and a composited window recording
  // zoomable: the crop is taken inside the rectangle the capture was
  // reading at that instant, exactly as the live effect composes zoom
  // inside follow (Knips.Recording.LiveMath), rather than against the
  // recording's fixed base rectangle — which is the rectangle those
  // takes are NOT showing, and computing against it was the bug the
  // whole effect used to be refused over.
  TCompositionTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestUnzoomedIsThePannedWindowExactly;
    procedure TestTheCropCentresOnTheClickInsideThePan;
    procedure TestTheCropStaysInsideThePannedWindow;
    procedure TestAFocusOutsideThePanIsClamped;
    procedure TestTheFrameCropIsIdentityWhenUnzoomed;
    procedure TestThePointerMapsThroughBothTransforms;
    procedure TestFramingComesFromTheSampleTrack;
    procedure TestFramingPastTheTrackIsRefusedNotGuessed;
    procedure TestAClickOutsideTheBaseButInsideThePanCounts;
  end;

  TFrameCropTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheBaseIsTheWholeFrame;
    procedure TestHalfTheBaseIsHalfTheFrame;
    procedure TestACropIsNeverEmpty;
    procedure TestACropNeverLeavesTheFrame;
  end;

  // The two questions every render pass asks per frame, which the MP4
  // render and the GIF/APNG pipeline used to answer with a copy of the
  // arithmetic each. They are checked here, once, on the properties both
  // faces depend on: what the framing is when the track can say and when
  // it cannot, and that a frame nothing is zooming is left whole.
  TFrameShapeTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestThePannedFramingIsTheTrack;
    procedure TestPastTheTrackTheFramingIsNotKnown;
    procedure TestAnUnpannedTakeIsTheBaseForever;
    procedure TestAnUnreadableTrackFallsBackToTheBase;
    procedure TestNoZoomIsTheWholeFrame;
    procedure TestAnUnknownFramingIsTheWholeFrame;
    procedure TestAZoomCropsInsideThePannedFraming;
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
  // A managed result is not initialised on entry.
  Result := nil;
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

// A take whose framing PANNED: the header's base rectangle, an anchor,
// and a sample track that slides the source rectangle 300 points right
// and 200 down a second in.
//
// The click is at (790, 400), and the two coordinates are chosen rather
// than convenient. The base rectangle spans x 120..760, the panned one
// spans x 420..1060 — so 790 is **outside the base and inside the pan**,
// which is the only kind of click that can tell the new filter from the
// old one. A click inside both (which this fixture used to carry) passes
// either way and pins nothing at all.
function PannedLogText: string;
begin
  Result := '{"k":"header","format":"knips-events","version":1,'
    + '"knips":"0.1.0","movie":"demo.mp4","created":"2026-08-27T00:00:00Z",'
    + '"pid":1,"target":"display","pixelWidth":1280,'
    + '"pixelHeight":800,"scale":2,"fps":30,"sampleHz":30.000,'
    + '"displayId":1,"displayWidth":1512.000,"displayHeight":982.000,'
    + '"baseX":120.000,"baseY":80.000,"baseWidth":640.000,'
    + '"baseHeight":400.000,"menuBarInset":0.000,'
    + '"cursor":"smooth","bakedZoomOnClick":false,'
    + '"bakedFollowMouse":true,"bakedWindowFollow":false,"audio":"none"}'
    + LineEnding
    + '{"k":"anchor","host":1000.000000}' + LineEnding
    + '{"k":"cursor","t":1000.000000,"x":200.000,"y":150.000,"b":0}'
    + LineEnding
    + '{"k":"cursor","t":1001.000000,"x":430.000,"y":290.000,"b":0,'
    + '"sx":420.000,"sy":280.000,"sw":640.000,"sh":400.000}' + LineEnding
    + '{"k":"cursor","t":1002.000000,"x":430.000,"y":290.000,"b":0}'
    + LineEnding
    + '{"k":"button","t":1001.500000,"x":790.000,"y":400.000,"n":0,'
    + '"d":true}' + LineEnding;
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
  Test('and the two agree on an explicit factor and hold too',
    TestWalkMatchesTheReferenceWithAnExplicitHold);
end;

// Both call sites of ZoomSourceRectAt passed 0 for the factor and 0 for
// the hold, so the oracle only ever checked the walker against the
// DEFAULTS — and the zero-means-the-feature's-own-default substitution
// happens inside ZoomWalkerStart, which both of them go through. An
// explicit hold and an explicit factor take a different path through the
// same code and were never compared at all.
procedure TInvariantTests.TestWalkMatchesTheReferenceWithAnExplicitHold;
const
  Factor = 3.0;
  Hold = 1.5;
var
  Clicks: TZoomClickArray;
  Walker: TZoomWalker;
  I: Integer;
  Seconds: Double;
  Walked, Fresh: TLiveRect;
  SawZoom: Boolean;
begin
  SetLength(Clicks, 2);
  Clicks[0].Seconds := 0.4;
  Clicks[0].X := 300;
  Clicks[0].Y := 200;
  Clicks[1].Seconds := 1.1;
  Clicks[1].X := 600;
  Clicks[1].Y := 300;
  Walker := ZoomWalkerStart(TestBase, Factor, Hold);
  SawZoom := False;
  // Past the last click plus the hold plus the ease out, so the whole
  // shape — in, hold, out — is walked at a hold nothing else exercises.
  for I := 0 to Round(30 * (1.1 + Hold + LiveZoomOutSeconds + 0.5)) do
  begin
    Seconds := I / 30;
    Walker := ZoomWalkerAdvance(Walker, Clicks, Seconds);
    Walked := ZoomWalkerSourceRect(Walker);
    Fresh := ZoomSourceRectAt(TestBase, Factor, Hold, Clicks, Seconds);
    ExpectNear(Walked.X, Fresh.X, RectEpsilon,
      Format('walked x at %.4fs', [Seconds]));
    ExpectNear(Walked.Width, Fresh.Width, RectEpsilon,
      Format('walked width at %.4fs', [Seconds]));
    if Walked.Width < BaseWidth - RectEpsilon then
      SawZoom := True;
  end;
  // The walk really did zoom, or the agreement above would be an
  // agreement about the base rectangle and nothing else.
  Expect<Boolean>(SawZoom).ToBe(True);
  // And the explicit hold is honoured rather than replaced by the
  // default: at the last click plus most of the hold the crop is still
  // in, where the shorter default (LiveZoomHoldSeconds) would have let
  // it start easing out.
  Expect<Boolean>(ZoomSourceRectAt(TestBase, Factor, Hold, Clicks,
    1.1 + Hold - 0.05).Width < BaseWidth - RectEpsilon).ToBe(True);
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

{ TCompositionTests }

// A framing the capture panned to: the same 640x400 rectangle, slid
// 300 points right and 200 down from where the recording was sized.
// Nothing about it is inside the base rectangle, which is the point —
// a crop computed against the base would land on pixels these frames
// are not showing.
const
  PanX = BaseX + 300;
  PanY = BaseY + 200;

function PannedWindow: TLiveRect;
begin
  Result := LiveRect(PanX, PanY, BaseWidth, BaseHeight);
end;

function WalkerAt(const AClicks: TZoomClickArray;
  ASeconds: Double): TZoomWalker;
begin
  Result := ZoomWalkerStart(TestBase, 0, 0);
  Result := ZoomWalkerAdvance(Result, AClicks, ASeconds);
end;

procedure TCompositionTests.SetupTests;
begin
  Test('with no zoom in force the composed rectangle is the panned '
    + 'window exactly', TestUnzoomedIsThePannedWindowExactly);
  Test('a click crops inside the panned window, centred on the click',
    TestTheCropCentresOnTheClickInsideThePan);
  Test('the composed crop never leaves the panned window',
    TestTheCropStaysInsideThePannedWindow);
  Test('a focus that drifted outside the pan is clamped to its edge',
    TestAFocusOutsideThePanIsClamped);
  Test('an unzoomed frame of a panned take is copied, not resampled',
    TestTheFrameCropIsIdentityWhenUnzoomed);
  Test('the pointer maps through the pan and the zoom together',
    TestThePointerMapsThroughBothTransforms);
  Test('the framing comes from the sample track, not the header',
    TestFramingComesFromTheSampleTrack);
  Test('past the end of the track the framing is refused, not guessed',
    TestFramingPastTheTrackIsRefusedNotGuessed);
  Test('a click outside the base but inside the pan is a click',
    TestAClickOutsideTheBaseButInsideThePanCounts);
end;

procedure TCompositionTests.TestUnzoomedIsThePannedWindowExactly;
var
  Rect: TLiveRect;
begin
  // This is the property that makes an unzoomed stretch of a panned take
  // a plain copy of its frames: at zoom 1 the composition is the
  // identity on whatever window it is given.
  Rect := ZoomWalkerSourceRectIn(WalkerAt(nil, 3.0), PannedWindow);
  ExpectNear(Rect.X, PanX, RectEpsilon, 'x');
  ExpectNear(Rect.Y, PanY, RectEpsilon, 'y');
  ExpectNear(Rect.Width, BaseWidth, RectEpsilon, 'width');
  ExpectNear(Rect.Height, BaseHeight, RectEpsilon, 'height');
end;

procedure TCompositionTests.TestTheCropCentresOnTheClickInsideThePan;
var
  Clicks: TZoomClickArray;
  Rect: TLiveRect;
  ClickX, ClickY: Double;
begin
  // A click in the middle of the PANNED window, which is well outside
  // the base rectangle.
  ClickX := PanX + BaseWidth / 2;
  ClickY := PanY + BaseHeight / 2;
  Clicks := OneClick(1.0, ClickX, ClickY);
  // Past the ease-in, so the zoom has reached the live factor.
  Rect := ZoomWalkerSourceRectIn(WalkerAt(Clicks, 1.0 + LiveZoomInSeconds),
    PannedWindow);
  ExpectNear(Rect.Width, BaseWidth / LiveClickZoom, RectEpsilon, 'width');
  ExpectNear(Rect.Height, BaseHeight / LiveClickZoom, RectEpsilon,
    'height');
  ExpectNear(Rect.X + Rect.Width / 2, ClickX, RectEpsilon, 'centre x');
  ExpectNear(Rect.Y + Rect.Height / 2, ClickY, RectEpsilon, 'centre y');
end;

procedure TCompositionTests.TestTheCropStaysInsideThePannedWindow;
var
  Clicks: TZoomClickArray;
  Step: Integer;
  Rect: TLiveRect;
begin
  // Every instant of a whole zoom, against the panned window rather than
  // the base one: the render indexes memory with this rectangle, so a
  // crop that left the window would read pixels the frame does not hold.
  Clicks := OneClick(0.5, PanX + 40, PanY + BaseHeight - 30);
  for Step := 0 to 120 do
  begin
    Rect := ZoomWalkerSourceRectIn(WalkerAt(Clicks, Step / 60),
      PannedWindow);
    ExpectTrue(IsInside(Rect, PannedWindow),
      Format('the crop at %.3fs is inside the panned window',
      [Step / 60]));
  end;
end;

procedure TCompositionTests.TestAFocusOutsideThePanIsClamped;
var
  Clicks: TZoomClickArray;
  Rect: TLiveRect;
begin
  // The ill-defined case, clamped rather than refused: a click near the
  // window's edge, and then a framing that has since panned away from
  // it. The crop cannot centre on the click without reaching for pixels
  // the movie does not have, so it sits against the edge nearest to it.
  Clicks := OneClick(1.0, PanX - 500, PanY - 400);
  Rect := ZoomWalkerSourceRectIn(WalkerAt(Clicks, 1.0 + LiveZoomInSeconds),
    PannedWindow);
  ExpectTrue(IsInside(Rect, PannedWindow), 'the clamped crop is inside');
  ExpectNear(Rect.X, PanX, RectEpsilon, 'clamped to the left edge');
  ExpectNear(Rect.Y, PanY, RectEpsilon, 'clamped to the top edge');
end;

procedure TCompositionTests.TestTheFrameCropIsIdentityWhenUnzoomed;
var
  Crop: TZoomCrop;
begin
  Crop := ZoomFrameCrop(1280, 800, PannedWindow,
    ZoomWalkerSourceRectIn(WalkerAt(nil, 2.0), PannedWindow));
  ExpectTrue(Crop.Identity, 'an unzoomed panned frame is the whole frame');
end;

procedure TCompositionTests.TestThePointerMapsThroughBothTransforms;
var
  Clicks: TZoomClickArray;
  Rect: TLiveRect;
  Mapping: TCursorFrameMapping;
  FrameX, FrameY: Double;
  ClickX, ClickY: Double;
begin
  // The pointer is placed against what the frame SHOWS, which after the
  // composition is the zoomed crop of the panned window. A pointer at
  // the zoom's focus therefore lands in the middle of the frame, whether
  // or not the framing had panned away from the base rectangle.
  ClickX := PanX + BaseWidth / 2;
  ClickY := PanY + BaseHeight / 2;
  Clicks := OneClick(1.0, ClickX, ClickY);
  Rect := ZoomWalkerSourceRectIn(WalkerAt(Clicks, 1.0 + LiveZoomInSeconds),
    PannedWindow);
  Mapping := CursorFrameMapping(1280, 800, Rect.X, Rect.Y, Rect.Width,
    Rect.Height);
  ExpectTrue(CursorFramePoint(Mapping, ClickX, ClickY, FrameX, FrameY),
    'the mapping is usable');
  ExpectNear(FrameX, 640, 1E-6, 'the focus is centred across');
  ExpectNear(FrameY, 400, 1E-6, 'the focus is centred down');
end;

procedure TCompositionTests.TestFramingComesFromTheSampleTrack;
var
  Log: TSidecarLog;
  Rect: TLiveRect;
  Error: string;
  Stale: Boolean;
begin
  Log := TSidecarLog.Create;
  try
    Log.LoadFromText(PannedLogText, Error);
    // Before the first sample that carries a rectangle: the header's
    // base, which is what the format says stands until one does — and
    // answered rather than refused, because the format says it.
    Rect := FramingRectAt(Log, 0.0, Stale);
    ExpectNear(Rect.X, BaseX, RectEpsilon, 'x before the pan');
    ExpectTrue(not Stale, 'the start of the track is not stale');
    // At the panned sample: the rectangle the capture was reading.
    Rect := FramingRectAt(Log, 1.0, Stale);
    ExpectNear(Rect.X, PanX, RectEpsilon, 'x during the pan');
    ExpectNear(Rect.Y, PanY, RectEpsilon, 'y during the pan');
    ExpectNear(Rect.Width, BaseWidth, RectEpsilon, 'width during the pan');
    ExpectTrue(not Stale, 'a time inside the track is not stale');
  finally
    Log.Free;
  end;
end;

// The regression this exists for, and it is reachable rather than
// theoretical: pointer samples are flushed about a second behind, and
// crash recovery re-muxes a dead take's movie without trimming it to the
// track's extent — so a movie can run past its own sidecar. Carrying the
// last framing forward then crops every one of those frames against a
// rectangle the capture had already left. Measured on the user's own
// Follow Mouse take with its sidecar truncated at 2.0 s: a 443-pixel
// mis-crop at 3.8 s, reported as plain success.
procedure TCompositionTests.TestFramingPastTheTrackIsRefusedNotGuessed;
var
  Log: TSidecarLog;
  Rect: TLiveRect;
  Error: string;
  Stale: Boolean;
begin
  Log := TSidecarLog.Create;
  try
    Log.LoadFromText(PannedLogText, Error);
    // The fixture's last sample is at movie time 2.0 and it claims 30 Hz,
    // so the limit is half a second. Just inside it the last known
    // framing still stands...
    Rect := FramingRectAt(Log, 2.4, Stale);
    ExpectTrue(not Stale, 'just past the last sample is still answerable');
    ExpectNear(Rect.X, PanX, RectEpsilon, 'the last known framing');
    // ...and past it the answer is "I do not know", which is what stops
    // the render cropping through it.
    Rect := FramingRectAt(Log, 3.8, Stale);
    ExpectTrue(Stale, 'well past the last sample is stale');
    // A degenerate track cannot make the question unanswerable either.
    ExpectTrue(FramingRectAt(Log, 1000.0, Stale).Width > 0,
      'a stale answer still names a usable rectangle');
    ExpectTrue(Stale, 'a time far past the end is stale');
  finally
    Log.Free;
  end;
end;

procedure TCompositionTests.TestAClickOutsideTheBaseButInsideThePanCounts;
var
  Log: TSidecarLog;
  Clicks: TZoomClickArray;
  Error: string;
begin
  // The click that used to be thrown away: it is outside the base
  // rectangle, which is all the old filter looked at, but it is inside
  // what the recording was showing when it happened.
  Log := TSidecarLog.Create;
  try
    Log.LoadFromText(PannedLogText, Error);
    Clicks := ZoomClicksFromLog(Log);
    Expect<Integer>(Length(Clicks)).ToBe(1);
    ExpectNear(Clicks[0].X, 790, RectEpsilon, 'the click''s x');
    // The half that makes this a regression test rather than a
    // restatement: the click really is outside the rectangle the old
    // filter tested against.
    ExpectTrue(not LiveRectContains(TestBase, 790, 400),
      'the click is outside the base rectangle');
    ExpectTrue(LiveRectContains(PannedWindow, 790, 400),
      'the click is inside the panned window');
  finally
    Log.Free;
  end;
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

{ TFrameShapeTests }

procedure TFrameShapeTests.SetupTests;
begin
  Test('a panned take is framed by its sample track',
    TestThePannedFramingIsTheTrack);
  Test('past the end of the track the framing is not known',
    TestPastTheTrackTheFramingIsNotKnown);
  Test('a take that never panned is the base rectangle for the whole '
    + 'file', TestAnUnpannedTakeIsTheBaseForever);
  Test('a track that cannot be read falls back to the base and says so',
    TestAnUnreadableTrackFallsBackToTheBase);
  Test('a frame nothing is zooming is left whole',
    TestNoZoomIsTheWholeFrame);
  Test('a frame whose framing is unknown is left whole',
    TestAnUnknownFramingIsTheWholeFrame);
  Test('a zoom crops inside the framing, not the base',
    TestAZoomCropsInsideThePannedFraming);
end;

procedure TFrameShapeTests.TestThePannedFramingIsTheTrack;
var
  Log: TSidecarLog;
  Rect: TLiveRect;
  Error: string;
begin
  Log := TSidecarLog.Create;
  try
    Log.LoadFromText(PannedLogText, Error);
    ExpectTrue(FramingAtInstant(Log, True, TestBase, 1.0, Rect),
      'a time inside the track is known');
    ExpectNear(Rect.X, PanX, RectEpsilon, 'x');
    ExpectNear(Rect.Y, PanY, RectEpsilon, 'y');
    ExpectNear(Rect.Width, BaseWidth, RectEpsilon, 'width');
  finally
    Log.Free;
  end;
end;

// The important half. False means "I do not know what this frame was
// showing", and both callers turn that into "leave the frame whole and
// place the pointer against the last rectangle the track holds" — so a
// wrong answer here is a mis-cropped movie reported as plain success.
procedure TFrameShapeTests.TestPastTheTrackTheFramingIsNotKnown;
var
  Log: TSidecarLog;
  Rect: TLiveRect;
  Error: string;
begin
  Log := TSidecarLog.Create;
  try
    Log.LoadFromText(PannedLogText, Error);
    ExpectTrue(not FramingAtInstant(Log, True, TestBase, 3.8, Rect),
      'well past the last sample is not known');
    // A rectangle is still named, so a caller has something to hold —
    // but it is the base one, which is not what those frames show.
    ExpectNear(Rect.X, BaseX, RectEpsilon, 'x falls back to the base');
    ExpectNear(Rect.Width, BaseWidth, RectEpsilon, 'width');
  finally
    Log.Free;
  end;
end;

procedure TFrameShapeTests.TestAnUnpannedTakeIsTheBaseForever;
var
  Log: TSidecarLog;
  Rect: TLiveRect;
  Error: string;
begin
  Log := TSidecarLog.Create;
  try
    Log.LoadFromText(PannedLogText, Error);
    // The same log, asked as a take whose header says the framing never
    // moved: the track is not consulted at all, so there is nothing to
    // run past and the answer stands for the whole file.
    ExpectTrue(FramingAtInstant(Log, False, TestBase, 3.8, Rect),
      'an unpanned take is known at any time');
    ExpectNear(Rect.X, BaseX, RectEpsilon, 'x');
    ExpectNear(Rect.Y, BaseY, RectEpsilon, 'y');
    ExpectNear(Rect.Width, BaseWidth, RectEpsilon, 'width');
    ExpectNear(Rect.Height, BaseHeight, RectEpsilon, 'height');
  finally
    Log.Free;
  end;
end;

procedure TFrameShapeTests.TestAnUnreadableTrackFallsBackToTheBase;
var
  Rect: TLiveRect;
begin
  // No log at all — a panned take whose sidecar would not load. The
  // rectangle is the base and the verdict is "not known", which is the
  // pair that keeps the render from cropping against a guess.
  ExpectTrue(not FramingAtInstant(nil, True, TestBase, 1.0, Rect),
    'no track means the framing is not known');
  ExpectNear(Rect.X, BaseX, RectEpsilon, 'x');
  ExpectNear(Rect.Width, BaseWidth, RectEpsilon, 'width');
end;

procedure TFrameShapeTests.TestNoZoomIsTheWholeFrame;
var
  Walker: TZoomWalker;
  Crop: TZoomCrop;
  Source: TLiveRect;
begin
  Walker := ZoomWalkerStart(TestBase, 0, 0);
  Crop := ZoomCropAt(Walker, OneClick(0.5, PanX + 40, PanY + 40), False,
    True, PannedWindow, 1280, 800, 1.0, Source);
  ExpectTrue(Crop.Identity, 'the crop is the whole frame');
  ExpectTrue(not Crop.Applied, 'no zoom was applied to it');
  Expect<Integer>(Crop.X).ToBe(0);
  Expect<Integer>(Crop.Y).ToBe(0);
  Expect<Integer>(Crop.Width).ToBe(1280);
  Expect<Integer>(Crop.Height).ToBe(800);
  // The rectangle the frame shows is the framing itself, which is what a
  // pointer is placed against when nothing is zooming.
  ExpectNear(Source.X, PanX, RectEpsilon, 'the source is the framing');
  // And the walk was not advanced by a question about an effect that is
  // not running.
  ExpectNear(Walker.Seconds, 0, RectEpsilon, 'the walk stayed put');
end;

procedure TFrameShapeTests.TestAnUnknownFramingIsTheWholeFrame;
var
  Walker: TZoomWalker;
  Crop: TZoomCrop;
  Source: TLiveRect;
begin
  // Zoom asked for, framing unknown: the frame is passed through whole
  // rather than cropped against a rectangle nothing was rendered from.
  Walker := ZoomWalkerStart(TestBase, 0, 0);
  Crop := ZoomCropAt(Walker, OneClick(0.5, PanX + 40, PanY + 40), True,
    False, PannedWindow, 1280, 800, 1.0, Source);
  ExpectTrue(Crop.Identity, 'the crop is the whole frame');
  ExpectTrue(not Crop.Applied, 'no zoom was applied to it');
  ExpectNear(Walker.Seconds, 0, RectEpsilon, 'the walk stayed put');
end;

procedure TFrameShapeTests.TestAZoomCropsInsideThePannedFraming;
var
  Walker: TZoomWalker;
  Crop: TZoomCrop;
  Source: TLiveRect;
  Clicks: TZoomClickArray;
  ClickX, ClickY: Double;
begin
  ClickX := PanX + BaseWidth / 2;
  ClickY := PanY + BaseHeight / 2;
  Clicks := OneClick(1.0, ClickX, ClickY);
  Walker := ZoomWalkerStart(TestBase, 0, 0);
  // Past the ease-in, so the zoom has reached the live factor: half the
  // framing, centred on the click, which in the frame's own pixels is
  // the middle quarter of a 1280x800 frame.
  Crop := ZoomCropAt(Walker, Clicks, True, True, PannedWindow, 1280, 800,
    1.0 + LiveZoomInSeconds, Source);
  ExpectTrue(Crop.Applied, 'the zoom was applied');
  ExpectNear(Source.X + Source.Width / 2, ClickX, RectEpsilon,
    'centre x');
  ExpectNear(Source.Y + Source.Height / 2, ClickY, RectEpsilon,
    'centre y');
  ExpectNear(Source.Width, BaseWidth / LiveClickZoom, RectEpsilon,
    'width');
  ExpectTrue(not Crop.Identity, 'the frame is cropped');
  Expect<Integer>(Crop.Width).ToBe(1280 div Round(LiveClickZoom));
  Expect<Integer>(Crop.Height).ToBe(800 div Round(LiveClickZoom));
  // The walk really was advanced, which is what makes a second ask for
  // the same instant free rather than a second replay.
  ExpectNear(Walker.Seconds, 1.0 + LiveZoomInSeconds, RectEpsilon,
    'the walk reached the instant');
end;

begin
  TestRunnerProgram.AddSuite(TQuietTests.Create('a take with no clicks'));
  TestRunnerProgram.AddSuite(TShapeTests.Create('the shape of one zoom'));
  TestRunnerProgram.AddSuite(TInvariantTests.Create('invariants'));
  TestRunnerProgram.AddSuite(TClickFilterTests.Create(
    'which clicks count'));
  TestRunnerProgram.AddSuite(TCompositionTests.Create(
    'zoom composed inside a panned framing'));
  TestRunnerProgram.AddSuite(TFrameCropTests.Create('the frame crop'));
  TestRunnerProgram.AddSuite(TFrameShapeTests.Create(
    'the shape one frame comes to'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

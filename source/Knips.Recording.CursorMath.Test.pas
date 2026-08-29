program Knips.Recording.CursorMath.Test;

// Big Cursor's arithmetic, checked on the properties the Darwin
// compositor depends on and cannot check for itself:
//
//   - a display point lands where the frame's own scale says it does,
//     with a region's offset and a live zoom's crop both folded into the
//     same ratio;
//   - the hot spot, not the sprite's corner, is what sits on the cursor;
//   - a sprite that hangs off any of the four edges is clipped rather
//     than wrapped, and the copy starts at the matching place inside the
//     sprite;
//   - a cursor outside the captured rectangle draws nothing at all;
//   - the blit is a real premultiplied source-over, it writes only the
//     pixels the plan names, and it honours two different row strides —
//     a CVPixelBuffer's row is padded and the sprite's is not.
//
// The blit tests matter more than they look: that routine runs on
// ScreenCaptureKit's capture queue, where a bad index is a crash in a
// process with no cthreads and nowhere to raise.

{$I Knips.inc}

uses
  SysUtils,

  Knips.Options,
  Knips.Recording.CursorMath,
  TestingPascalLibrary;

type
  TMappingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestWholeDisplayScalesByPixelsPerPoint;
    procedure TestRegionOffsetIsSubtracted;
    procedure TestZoomedSourceRectMagnifies;
    procedure TestDegenerateMappingIsRefused;
  end;

  TPlacementTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestHotSpotSitsOnTheCursor;
    procedure TestClipsAtTheLeftEdge;
    procedure TestClipsAtTheTopEdge;
    procedure TestClipsAtTheRightEdge;
    procedure TestClipsAtTheBottomEdge;
    procedure TestCursorOutsideDrawsNothing;
    procedure TestCursorInsideAZoomedCropIsPlaced;
    procedure TestEmptySpriteDrawsNothing;
  end;

  TBlitTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestOpaqueSourceReplaces;
    procedure TestTransparentSourceLeavesTheFrame;
    procedure TestHalfAlphaBlends;
    procedure TestOnlyThePlannedPixelsAreTouched;
    procedure TestClippedPlanReadsTheMatchingSpriteColumn;
    procedure TestInvisiblePlanDrawsNothing;
  end;

  TSpriteMetricTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestExtentIsPointsTimesScaleTimesMagnification;
    procedure TestExtentIsClamped;
    procedure TestHotSpotScalesWithTheSprite;
    procedure TestHotSpotIsClampedIntoTheSprite;
    procedure TestWindowCaptureGetsNoBigCursor;
    procedure TestWindowCaptureGetsNoSmoothCursor;
  end;

{ ---------------------------------------------------------------- helpers }

const
  PointEpsilon = 1E-9;
  // A frame big enough that a 20x20 sprite can hang off every edge with
  // room to spare, and small enough to write out by hand in a test.
  FrameWidth = 64;
  FrameHeight = 48;
  SpriteExtent = 8;

// The same two Expect-based helpers the live-effect suite uses: the
// runner only counts an assertion made through Expect, and a string
// comparison is what lets a failure carry the numbers.
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

procedure ExpectPlan(const APlan: TCursorBlitPlan; AVisible: Boolean;
  ADestinationX, ADestinationY, ASpriteX, ASpriteY, AWidth,
  AHeight: Integer; const AWhat: string);
begin
  Expect<string>(Format('%s: visible=%s dest=%d,%d sprite=%d,%d size=%dx%d',
    [AWhat, BoolToStr(APlan.Visible, 'yes', 'no'), APlan.DestinationX,
    APlan.DestinationY, APlan.SpriteX, APlan.SpriteY, APlan.Width,
    APlan.Height]))
    .ToBe(Format('%s: visible=%s dest=%d,%d sprite=%d,%d size=%dx%d',
    [AWhat, BoolToStr(AVisible, 'yes', 'no'), ADestinationX, ADestinationY,
    ASpriteX, ASpriteY, AWidth, AHeight]));
end;

// A whole 1440x900-point display recorded at two pixels per point.
function RetinaDisplayMapping: TCursorFrameMapping;
begin
  Result := CursorFrameMapping(2880, 1800, 0, 0, 1440, 900);
end;

// The little frame the blit tests scribble on.
function SmallFrameMapping: TCursorFrameMapping;
begin
  Result := CursorFrameMapping(FrameWidth, FrameHeight, 0, 0, FrameWidth,
    FrameHeight);
end;

// Four bytes per pixel, no padding, unless a test asks for padding.
function BgraBuffer(AWidth, AHeight, APadding: Integer;
  AFill: Byte): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, (AWidth * 4 + APadding) * AHeight);
  for I := 0 to High(Result) do
    Result[I] := AFill;
end;

function PixelByte(const ABuffer: TBytes; ABytesPerRow, AX, AY,
  AChannel: Integer): Integer;
begin
  Result := ABuffer[AY * ABytesPerRow + AX * 4 + AChannel];
end;

procedure ExpectPixel(const ABuffer: TBytes; ABytesPerRow, AX, AY: Integer;
  ABlue, AGreen, ARed, AAlpha: Integer);
begin
  Expect<string>(Format('(%d,%d) = %d,%d,%d,%d', [AX, AY,
    PixelByte(ABuffer, ABytesPerRow, AX, AY, 0),
    PixelByte(ABuffer, ABytesPerRow, AX, AY, 1),
    PixelByte(ABuffer, ABytesPerRow, AX, AY, 2),
    PixelByte(ABuffer, ABytesPerRow, AX, AY, 3)]))
    .ToBe(Format('(%d,%d) = %d,%d,%d,%d', [AX, AY, ABlue, AGreen, ARed,
    AAlpha]));
end;

// A sprite of one flat colour at one flat alpha, premultiplied.
function FlatSprite(AExtent, ABlue, AGreen, ARed, AAlpha: Integer): TBytes;
var
  X, Y, Offset: Integer;
begin
  Result := BgraBuffer(AExtent, AExtent, 0, 0);
  for Y := 0 to AExtent - 1 do
    for X := 0 to AExtent - 1 do
    begin
      Offset := (Y * AExtent + X) * 4;
      Result[Offset] := Byte(ABlue * AAlpha div 255);
      Result[Offset + 1] := Byte(AGreen * AAlpha div 255);
      Result[Offset + 2] := Byte(ARed * AAlpha div 255);
      Result[Offset + 3] := Byte(AAlpha);
    end;
end;

{ TMappingTests }

procedure TMappingTests.SetupTests;
begin
  Test('a whole display maps by its pixels per point',
    TestWholeDisplayScalesByPixelsPerPoint);
  Test('a region''s origin is subtracted before the scale',
    TestRegionOffsetIsSubtracted);
  Test('a zoomed source rectangle magnifies the same point',
    TestZoomedSourceRectMagnifies);
  Test('an empty source rectangle is refused rather than divided by',
    TestDegenerateMappingIsRefused);
end;

procedure TMappingTests.TestWholeDisplayScalesByPixelsPerPoint;
var
  X, Y: Double;
begin
  Expect<Boolean>(CursorFramePoint(RetinaDisplayMapping, 100, 200, X, Y))
    .ToBe(True);
  ExpectNear(X, 200, PointEpsilon, 'x');
  ExpectNear(Y, 400, PointEpsilon, 'y');
  // The far corner lands on the far corner, which is what says the
  // mapping is a ratio and not an offset plus a guess.
  Expect<Boolean>(CursorFramePoint(RetinaDisplayMapping, 1440, 900, X, Y))
    .ToBe(True);
  ExpectNear(X, 2880, PointEpsilon, 'x');
  ExpectNear(Y, 1800, PointEpsilon, 'y');
end;

procedure TMappingTests.TestRegionOffsetIsSubtracted;
var
  Mapping: TCursorFrameMapping;
  X, Y: Double;
begin
  // A 400x300-point region at (100, 50), recorded at two pixels per point.
  Mapping := CursorFrameMapping(800, 600, 100, 50, 400, 300);
  Expect<Boolean>(CursorFramePoint(Mapping, 100, 50, X, Y)).ToBe(True);
  ExpectNear(X, 0, PointEpsilon, 'x');
  ExpectNear(Y, 0, PointEpsilon, 'y');
  Expect<Boolean>(CursorFramePoint(Mapping, 300, 200, X, Y)).ToBe(True);
  ExpectNear(X, 400, PointEpsilon, 'x');
  ExpectNear(Y, 300, PointEpsilon, 'y');
  // A point left of and above the region maps to negative pixels rather
  // than being clamped: clipping is PlanCursorBlit's job, not this one's.
  Expect<Boolean>(CursorFramePoint(Mapping, 50, 25, X, Y)).ToBe(True);
  ExpectNear(X, -100, PointEpsilon, 'x');
  ExpectNear(Y, -50, PointEpsilon, 'y');
end;

procedure TMappingTests.TestZoomedSourceRectMagnifies;
var
  Mapping: TCursorFrameMapping;
  X, Y: Double;
begin
  // Zoom on Click at 2x on the same 400x300 region: half the points into
  // the same output, centred on (300, 200).
  Mapping := CursorFrameMapping(800, 600, 200, 125, 200, 150);
  Expect<Boolean>(CursorFramePoint(Mapping, 300, 200, X, Y)).ToBe(True);
  ExpectNear(X, 400, PointEpsilon, 'x');
  ExpectNear(Y, 300, PointEpsilon, 'y');
  // One point of movement now covers twice as many pixels (four rather
  // than two), which is the whole of what "the cursor tracks the zoom"
  // means.
  Expect<Boolean>(CursorFramePoint(Mapping, 301, 201, X, Y)).ToBe(True);
  ExpectNear(X, 404, PointEpsilon, 'x');
  ExpectNear(Y, 304, PointEpsilon, 'y');
end;

procedure TMappingTests.TestDegenerateMappingIsRefused;
var
  X, Y: Double;
begin
  Expect<Boolean>(CursorFramePoint(CursorFrameMapping(800, 600, 0, 0, 0,
    300), 10, 10, X, Y)).ToBe(False);
  ExpectNear(X, 0, PointEpsilon, 'x');
  Expect<Boolean>(CursorFramePoint(CursorFrameMapping(0, 600, 0, 0, 400,
    300), 10, 10, X, Y)).ToBe(False);
  Expect<Boolean>(CursorFramePoint(CursorFrameMapping(800, 0, 0, 0, 400,
    300), 10, 10, X, Y)).ToBe(False);
end;

{ TPlacementTests }

procedure TPlacementTests.SetupTests;
begin
  Test('the hot spot, not the corner, sits on the cursor',
    TestHotSpotSitsOnTheCursor);
  Test('a sprite off the left edge is clipped and offset into',
    TestClipsAtTheLeftEdge);
  Test('a sprite off the top edge is clipped and offset into',
    TestClipsAtTheTopEdge);
  Test('a sprite off the right edge is clipped', TestClipsAtTheRightEdge);
  Test('a sprite off the bottom edge is clipped',
    TestClipsAtTheBottomEdge);
  Test('a cursor outside the captured rectangle draws nothing',
    TestCursorOutsideDrawsNothing);
  Test('a cursor inside a zoomed crop is placed by the crop',
    TestCursorInsideAZoomedCropIsPlaced);
  Test('a sprite with no pixels draws nothing',
    TestEmptySpriteDrawsNothing);
end;

procedure TPlacementTests.TestHotSpotSitsOnTheCursor;
var
  Plan: TCursorBlitPlan;
begin
  // Cursor at display point (20, 10) on a 1:1 frame, sprite 8x8 with its
  // hot spot at (2, 3): the sprite's corner goes at (18, 7).
  Plan := PlanCursorBlit(SmallFrameMapping, 20, 10, SpriteExtent,
    SpriteExtent, 2, 3);
  ExpectPlan(Plan, True, 18, 7, 0, 0, SpriteExtent, SpriteExtent,
    'centre of the frame');
  // A hot spot at the origin puts the corner on the cursor.
  Plan := PlanCursorBlit(SmallFrameMapping, 20, 10, SpriteExtent,
    SpriteExtent, 0, 0);
  ExpectPlan(Plan, True, 20, 10, 0, 0, SpriteExtent, SpriteExtent,
    'hot spot at the origin');
end;

procedure TPlacementTests.TestClipsAtTheLeftEdge;
var
  Plan: TCursorBlitPlan;
begin
  // Hot spot at (5, 0) and a cursor two pixels in: three columns of the
  // sprite are off the frame, so the copy starts at sprite column 3.
  Plan := PlanCursorBlit(SmallFrameMapping, 2, 10, SpriteExtent,
    SpriteExtent, 5, 0);
  ExpectPlan(Plan, True, 0, 10, 3, 0, SpriteExtent - 3, SpriteExtent,
    'three columns off the left');
  // Exactly one column left showing is still a draw.
  Plan := PlanCursorBlit(SmallFrameMapping, 0, 10, SpriteExtent,
    SpriteExtent, SpriteExtent - 1, 0);
  ExpectPlan(Plan, True, 0, 10, SpriteExtent - 1, 0, 1, SpriteExtent,
    'one column left showing');
end;

procedure TPlacementTests.TestClipsAtTheTopEdge;
var
  Plan: TCursorBlitPlan;
begin
  Plan := PlanCursorBlit(SmallFrameMapping, 20, 1, SpriteExtent,
    SpriteExtent, 0, 4);
  ExpectPlan(Plan, True, 20, 0, 0, 3, SpriteExtent, SpriteExtent - 3,
    'three rows off the top');
end;

procedure TPlacementTests.TestClipsAtTheRightEdge;
var
  Plan: TCursorBlitPlan;
begin
  // The cursor two pixels from the right edge with the hot spot at the
  // sprite's origin: two columns fit, the rest is cut, and nothing is
  // taken from further into the sprite.
  Plan := PlanCursorBlit(SmallFrameMapping, FrameWidth - 2, 10,
    SpriteExtent, SpriteExtent, 0, 0);
  ExpectPlan(Plan, True, FrameWidth - 2, 10, 0, 0, 2, SpriteExtent,
    'two columns before the right edge');
  // On the edge itself there is nothing left to draw.
  Plan := PlanCursorBlit(SmallFrameMapping, FrameWidth, 10, SpriteExtent,
    SpriteExtent, 0, 0);
  ExpectPlan(Plan, False, 0, 0, 0, 0, 0, 0, 'on the right edge');
end;

procedure TPlacementTests.TestClipsAtTheBottomEdge;
var
  Plan: TCursorBlitPlan;
begin
  Plan := PlanCursorBlit(SmallFrameMapping, 20, FrameHeight - 3,
    SpriteExtent, SpriteExtent, 0, 0);
  ExpectPlan(Plan, True, 20, FrameHeight - 3, 0, 0, SpriteExtent, 3,
    'three rows before the bottom edge');
  Plan := PlanCursorBlit(SmallFrameMapping, 20, FrameHeight, SpriteExtent,
    SpriteExtent, 0, 0);
  ExpectPlan(Plan, False, 0, 0, 0, 0, 0, 0, 'on the bottom edge');
end;

procedure TPlacementTests.TestCursorOutsideDrawsNothing;
var
  Mapping: TCursorFrameMapping;
  Plan: TCursorBlitPlan;
begin
  // A 400x300-point region at (100, 50): a cursor over on the other side
  // of the display is not in this recording at all.
  Mapping := CursorFrameMapping(800, 600, 100, 50, 400, 300);
  Plan := PlanCursorBlit(Mapping, 1200, 700, SpriteExtent, SpriteExtent,
    2, 2);
  ExpectPlan(Plan, False, 0, 0, 0, 0, 0, 0, 'far outside the region');
  Plan := PlanCursorBlit(Mapping, 0, 0, SpriteExtent, SpriteExtent, 2, 2);
  ExpectPlan(Plan, False, 0, 0, 0, 0, 0, 0, 'above and left of it');
end;

procedure TPlacementTests.TestCursorInsideAZoomedCropIsPlaced;
var
  Mapping: TCursorFrameMapping;
  Plan: TCursorBlitPlan;
begin
  // The 2x crop from the mapping tests. A cursor at the crop's centre is
  // at the frame's centre; one just outside the crop is gone entirely.
  Mapping := CursorFrameMapping(800, 600, 200, 125, 200, 150);
  Plan := PlanCursorBlit(Mapping, 300, 200, 20, 20, 10, 10);
  ExpectPlan(Plan, True, 390, 290, 0, 0, 20, 20, 'centre of the crop');
  Plan := PlanCursorBlit(Mapping, 150, 200, 20, 20, 10, 10);
  ExpectPlan(Plan, False, 0, 0, 0, 0, 0, 0, 'left of the crop');
end;

procedure TPlacementTests.TestEmptySpriteDrawsNothing;
var
  Plan: TCursorBlitPlan;
begin
  Plan := PlanCursorBlit(SmallFrameMapping, 20, 10, 0, 8, 0, 0);
  ExpectPlan(Plan, False, 0, 0, 0, 0, 0, 0, 'zero-width sprite');
  Plan := PlanCursorBlit(SmallFrameMapping, 20, 10, 8, 0, 0, 0);
  ExpectPlan(Plan, False, 0, 0, 0, 0, 0, 0, 'zero-height sprite');
end;

{ TBlitTests }

procedure TBlitTests.SetupTests;
begin
  Test('an opaque sprite pixel replaces the frame''s',
    TestOpaqueSourceReplaces);
  Test('a fully transparent sprite pixel leaves the frame alone',
    TestTransparentSourceLeavesTheFrame);
  Test('a half-transparent sprite pixel blends premultiplied',
    TestHalfAlphaBlends);
  Test('nothing outside the plan is written, at either stride',
    TestOnlyThePlannedPixelsAreTouched);
  Test('a clipped plan reads the matching column of the sprite',
    TestClippedPlanReadsTheMatchingSpriteColumn);
  Test('an invisible plan draws nothing', TestInvisiblePlanDrawsNothing);
end;

procedure TBlitTests.TestOpaqueSourceReplaces;
var
  Frame, Sprite: TBytes;
  Plan: TCursorBlitPlan;
begin
  Frame := BgraBuffer(FrameWidth, FrameHeight, 0, 10);
  Sprite := FlatSprite(SpriteExtent, 200, 100, 50, 255);
  Plan := PlanCursorBlit(SmallFrameMapping, 20, 10, SpriteExtent,
    SpriteExtent, 0, 0);
  BlitPremultipliedBgra(@Frame[0], FrameWidth * 4, @Sprite[0],
    SpriteExtent * 4, Plan);
  ExpectPixel(Frame, FrameWidth * 4, 20, 10, 200, 100, 50, 255);
  ExpectPixel(Frame, FrameWidth * 4, 27, 17, 200, 100, 50, 255);
end;

procedure TBlitTests.TestTransparentSourceLeavesTheFrame;
var
  Frame, Sprite: TBytes;
  Plan: TCursorBlitPlan;
begin
  Frame := BgraBuffer(FrameWidth, FrameHeight, 0, 77);
  Sprite := FlatSprite(SpriteExtent, 200, 100, 50, 0);
  Plan := PlanCursorBlit(SmallFrameMapping, 20, 10, SpriteExtent,
    SpriteExtent, 0, 0);
  BlitPremultipliedBgra(@Frame[0], FrameWidth * 4, @Sprite[0],
    SpriteExtent * 4, Plan);
  ExpectPixel(Frame, FrameWidth * 4, 20, 10, 77, 77, 77, 77);
end;

procedure TBlitTests.TestHalfAlphaBlends;
var
  Frame, Sprite: TBytes;
  Plan: TCursorBlitPlan;
  Expected: Integer;
begin
  Frame := BgraBuffer(FrameWidth, FrameHeight, 0, 100);
  // Premultiplied white at alpha 128: 255 * 128 div 255 = 128 per colour.
  Sprite := FlatSprite(SpriteExtent, 255, 255, 255, 128);
  Plan := PlanCursorBlit(SmallFrameMapping, 20, 10, SpriteExtent,
    SpriteExtent, 0, 0);
  BlitPremultipliedBgra(@Frame[0], FrameWidth * 4, @Sprite[0],
    SpriteExtent * 4, Plan);
  // dst = src + dst * (255 - a) / 255, rounded to nearest.
  Expected := 128 + (100 * 127 + 127) div 255;
  ExpectPixel(Frame, FrameWidth * 4, 20, 10, Expected, Expected, Expected,
    128 + (100 * 127 + 127) div 255);
end;

procedure TBlitTests.TestOnlyThePlannedPixelsAreTouched;
var
  Frame, Sprite: TBytes;
  Plan: TCursorBlitPlan;
  BytesPerRow, X, Y, Touched: Integer;
begin
  // A padded stride, as a CVPixelBuffer has: the row is wider than the
  // pixels, and a blit that used width * 4 would skew by a pixel a row.
  BytesPerRow := FrameWidth * 4 + 16;
  Frame := BgraBuffer(FrameWidth, FrameHeight, 16, 0);
  Sprite := FlatSprite(SpriteExtent, 255, 255, 255, 255);
  Plan := PlanCursorBlit(SmallFrameMapping, 20, 10, SpriteExtent,
    SpriteExtent, 0, 0);
  BlitPremultipliedBgra(@Frame[0], BytesPerRow, @Sprite[0],
    SpriteExtent * 4, Plan);
  Touched := 0;
  for Y := 0 to FrameHeight - 1 do
    for X := 0 to FrameWidth - 1 do
      if PixelByte(Frame, BytesPerRow, X, Y, 3) <> 0 then
      begin
        Inc(Touched);
        // Every touched pixel is inside the planned rectangle.
        Expect<string>(Format('touched (%d,%d) inside plan: %s', [X, Y,
          BoolToStr((X >= 20) and (X < 20 + SpriteExtent) and (Y >= 10)
          and (Y < 10 + SpriteExtent), 'yes', 'no')]))
          .ToBe(Format('touched (%d,%d) inside plan: yes', [X, Y]));
      end;
  Expect<Integer>(Touched).ToBe(SpriteExtent * SpriteExtent);
end;

procedure TBlitTests.TestClippedPlanReadsTheMatchingSpriteColumn;
var
  Frame, Sprite: TBytes;
  Plan: TCursorBlitPlan;
  X, Y, Offset: Integer;
begin
  Frame := BgraBuffer(FrameWidth, FrameHeight, 0, 0);
  // A sprite whose blue channel is its own column index, so the frame
  // says which column of the sprite reached it.
  Sprite := BgraBuffer(SpriteExtent, SpriteExtent, 0, 0);
  for Y := 0 to SpriteExtent - 1 do
    for X := 0 to SpriteExtent - 1 do
    begin
      Offset := (Y * SpriteExtent + X) * 4;
      Sprite[Offset] := Byte(X);
      Sprite[Offset + 3] := 255;
    end;
  // Three columns off the left edge (the placement test's case).
  Plan := PlanCursorBlit(SmallFrameMapping, 2, 10, SpriteExtent,
    SpriteExtent, 5, 0);
  BlitPremultipliedBgra(@Frame[0], FrameWidth * 4, @Sprite[0],
    SpriteExtent * 4, Plan);
  // Frame column 0 must carry sprite column 3, not sprite column 0.
  Expect<Integer>(PixelByte(Frame, FrameWidth * 4, 0, 10, 0)).ToBe(3);
  Expect<Integer>(PixelByte(Frame, FrameWidth * 4, 4, 10, 0)).ToBe(7);
end;

procedure TBlitTests.TestInvisiblePlanDrawsNothing;
var
  Frame, Sprite: TBytes;
  Plan: TCursorBlitPlan;
  I, Touched: Integer;
begin
  Frame := BgraBuffer(FrameWidth, FrameHeight, 0, 0);
  Sprite := FlatSprite(SpriteExtent, 255, 255, 255, 255);
  Plan := PlanCursorBlit(SmallFrameMapping, -100, -100, SpriteExtent,
    SpriteExtent, 0, 0);
  BlitPremultipliedBgra(@Frame[0], FrameWidth * 4, @Sprite[0],
    SpriteExtent * 4, Plan);
  Touched := 0;
  for I := 0 to High(Frame) do
    if Frame[I] <> 0 then
      Inc(Touched);
  Expect<Integer>(Touched).ToBe(0);
end;

{ TSpriteMetricTests }

procedure TSpriteMetricTests.SetupTests;
begin
  Test('the sprite is the image times the scale times the magnification',
    TestExtentIsPointsTimesScaleTimesMagnification);
  Test('the sprite extent is clamped at both ends', TestExtentIsClamped);
  Test('the hot spot scales with the sprite',
    TestHotSpotScalesWithTheSprite);
  Test('a nonsense hot spot is clamped into the sprite',
    TestHotSpotIsClampedIntoTheSprite);
  Test('a window recording gets no Big Cursor',
    TestWindowCaptureGetsNoBigCursor);
  Test('nor a smooth one, for the same reason',
    TestWindowCaptureGetsNoSmoothCursor);
end;

procedure TSpriteMetricTests.TestExtentIsPointsTimesScaleTimesMagnification;
begin
  // macOS's arrow is 28x40 points; at two pixels per point and 2.5x that
  // is 140x200, which the system image happens to carry a real
  // representation for.
  Expect<Integer>(BigCursorSpriteExtent(28, 2, BigCursorMagnification))
    .ToBe(140);
  Expect<Integer>(BigCursorSpriteExtent(40, 2, BigCursorMagnification))
    .ToBe(200);
  Expect<Integer>(BigCursorSpriteExtent(28, 1, BigCursorMagnification))
    .ToBe(70);
  // Rounded, not truncated.
  Expect<Integer>(BigCursorSpriteExtent(11, 1, 2.5)).ToBe(28);
end;

procedure TSpriteMetricTests.TestExtentIsClamped;
begin
  Expect<Integer>(BigCursorSpriteExtent(1, 0.1, 1)).ToBe(MinBigCursorExtent);
  Expect<Integer>(BigCursorSpriteExtent(28, 2, 1000))
    .ToBe(MaxBigCursorExtent);
  Expect<Integer>(BigCursorSpriteExtent(0, 0, 0)).ToBe(MinBigCursorExtent);
end;

procedure TSpriteMetricTests.TestHotSpotScalesWithTheSprite;
begin
  // The arrow's hot spot is 5 points into a 28-point image; at 140 pixels
  // across that is 25.
  Expect<Integer>(BigCursorHotSpot(5, 28, 140)).ToBe(25);
  Expect<Integer>(BigCursorHotSpot(0, 28, 140)).ToBe(0);
  Expect<Integer>(BigCursorHotSpot(14, 28, 140)).ToBe(70);
end;

procedure TSpriteMetricTests.TestHotSpotIsClampedIntoTheSprite;
begin
  Expect<Integer>(BigCursorHotSpot(-3, 28, 140)).ToBe(0);
  Expect<Integer>(BigCursorHotSpot(99, 28, 140)).ToBe(140);
  Expect<Integer>(BigCursorHotSpot(5, 0, 140)).ToBe(0);
  Expect<Integer>(BigCursorHotSpot(5, 28, 0)).ToBe(0);
end;

procedure TSpriteMetricTests.TestWindowCaptureGetsNoBigCursor;
begin
  Expect<Boolean>(ResolveBigCursor(ctkDisplay, True)).ToBe(True);
  Expect<Boolean>(ResolveBigCursor(ctkDisplay, False)).ToBe(False);
  Expect<Boolean>(ResolveBigCursor(ctkWindow, True)).ToBe(False);
  Expect<Boolean>(ResolveBigCursor(ctkWindow, False)).ToBe(False);
end;

// The same four, for the other half of the pair. They are deliberately
// separate functions — one may grow a case the other does not — and
// separate functions want separate tests, or the second is only as
// covered as somebody assumed.
procedure TSpriteMetricTests.TestWindowCaptureGetsNoSmoothCursor;
begin
  Expect<Boolean>(ResolveSmoothCursor(ctkDisplay, True)).ToBe(True);
  Expect<Boolean>(ResolveSmoothCursor(ctkDisplay, False)).ToBe(False);
  Expect<Boolean>(ResolveSmoothCursor(ctkWindow, True)).ToBe(False);
  Expect<Boolean>(ResolveSmoothCursor(ctkWindow, False)).ToBe(False);
end;

begin
  TestRunnerProgram.AddSuite(TMappingTests.Create(
    'mapping the screen onto a frame'));
  TestRunnerProgram.AddSuite(TPlacementTests.Create(
    'placing and clipping the sprite'));
  TestRunnerProgram.AddSuite(TBlitTests.Create('the premultiplied blit'));
  TestRunnerProgram.AddSuite(TSpriteMetricTests.Create('sprite metrics'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

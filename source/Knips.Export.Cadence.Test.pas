program Knips.Export.Cadence.Test;

// The render's frame synthesis, checked on the properties the two
// framework loops that use it depend on and cannot check for
// themselves:
//
//   - a gap that is already at the cadence gets nothing put into it, so
//     a movie whose frames arrived steadily is not touched at all;
//   - a gap gets frames on a grid of exactly one interval from the
//     earlier frame, so the filled cadence is the nominal one and not
//     whatever the gap happened to divide into;
//   - nothing is ever placed at or past the next source frame, and
//     nothing is crowded up against it;
//   - the grid does not drift over a long gap — the last synthesised
//     frame of a ten-second stretch is where the step count says it is,
//     not a few milliseconds off it;
//   - one gap can never ask a render for an unbounded number of frames;
//   - two frames made from the same pixels count as different exactly
//     when the crop or the drawn pointer moved by a whole pixel, which
//     is what keeps a still stretch as sparse as it was captured and a
//     zoom's hold free.

{$I Knips.inc}

uses
  Math,
  SysUtils,

  Knips.Export.Cadence,
  TestingPascalLibrary;

type
  TIntervalTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestThirtyHertzIsAThirtieth;
    procedure TestNonsenseRatesAreClamped;
  end;

  TPlacementTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestASteadyGapIsLeftAlone;
    procedure TestAGapIsFilledOnTheInterval;
    procedure TestNothingLandsOnOrPastTheNextFrame;
    procedure TestNothingIsCrowdedAgainstTheNextFrame;
    procedure TestALongGapDoesNotDrift;
    procedure TestAGapIsBounded;
    procedure TestASlotGapIsBoundedByTheSameNumber;
    procedure TestBackwardsAndDegenerateGapsAreEmpty;
  end;

  TShapeTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheSameShapeIsTheSamePicture;
    procedure TestAMovedCropIsADifferentPicture;
    procedure TestAMovedPointerIsADifferentPicture;
    procedure TestAPointerThatLeftTheFrameIsADifferentPicture;
    procedure TestPointerCoordinatesDoNotCountWithoutAPointer;
  end;

{ ---------------------------------------------------------------- helpers }

const
  Epsilon = 1E-9;
  Interval = 1 / 30;

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

procedure ExpectCount(const ATimes: TCadenceTimes; AExpected: Integer;
  const AWhat: string);
begin
  Expect<string>(Format('%s = %d', [AWhat, Length(ATimes)]))
    .ToBe(Format('%s = %d', [AWhat, AExpected]));
end;

function Shape(ACropX, ACropY, ACropWidth, ACropHeight: Integer;
  AHasCursor: Boolean; ACursorX, ACursorY: Integer): TRenderedFrameShape;
begin
  Result.CropX := ACropX;
  Result.CropY := ACropY;
  Result.CropWidth := ACropWidth;
  Result.CropHeight := ACropHeight;
  Result.HasCursor := AHasCursor;
  Result.CursorX := ACursorX;
  Result.CursorY := ACursorY;
end;

{ TIntervalTests }

procedure TIntervalTests.SetupTests;
begin
  Test('thirty hertz is a thirtieth of a second',
    TestThirtyHertzIsAThirtieth);
  Test('a nonsense frame rate is clamped rather than divided by',
    TestNonsenseRatesAreClamped);
end;

procedure TIntervalTests.TestThirtyHertzIsAThirtieth;
begin
  ExpectNear(CadenceInterval(30), 1 / 30, Epsilon, 'interval');
  ExpectNear(CadenceInterval(60), 1 / 60, Epsilon, 'interval');
end;

procedure TIntervalTests.TestNonsenseRatesAreClamped;
begin
  ExpectNear(CadenceInterval(0), 1 / DefaultCadenceFramesPerSecond,
    Epsilon, 'zero falls back');
  ExpectNear(CadenceInterval(-5), 1 / DefaultCadenceFramesPerSecond,
    Epsilon, 'a negative rate falls back');
  ExpectNear(CadenceInterval(100000), 1 / MaxCadenceFramesPerSecond,
    Epsilon, 'an absurd rate is capped');
end;

{ TPlacementTests }

procedure TPlacementTests.SetupTests;
begin
  Test('two frames already one interval apart get nothing between them',
    TestASteadyGapIsLeftAlone);
  Test('a gap is filled on the interval, from the earlier frame',
    TestAGapIsFilledOnTheInterval);
  Test('nothing is placed on or past the next source frame',
    TestNothingLandsOnOrPastTheNextFrame);
  Test('nothing is crowded up against the next source frame',
    TestNothingIsCrowdedAgainstTheNextFrame);
  Test('a long gap''s grid does not drift', TestALongGapDoesNotDrift);
  Test('one gap can never ask for an unbounded number of frames',
    TestAGapIsBounded);
  Test('a caller counting in slots is bounded by the same number',
    TestASlotGapIsBoundedByTheSameNumber);
  Test('a backwards or degenerate gap is empty',
    TestBackwardsAndDegenerateGapsAreEmpty);
end;

procedure TPlacementTests.TestASteadyGapIsLeftAlone;
begin
  // The whole point of the crowding rule: a movie that arrived at the
  // nominal rate is not re-timed, not padded, not touched.
  ExpectCount(CadenceTimes(1.0, 1.0 + Interval, Interval), 0,
    'one interval apart');
  ExpectCount(CadenceTimes(1.0, 1.0 + Interval * 1.4, Interval), 0,
    'a slightly long interval');
end;

procedure TPlacementTests.TestAGapIsFilledOnTheInterval;
var
  Times: TCadenceTimes;
  I: Integer;
begin
  // A tenth of a second between two frames is three intervals; two of
  // them are missing.
  Times := CadenceTimes(2.0, 2.1, Interval);
  ExpectCount(Times, 2, 'frames in a 100 ms gap');
  for I := 0 to High(Times) do
    ExpectNear(Times[I], 2.0 + (I + 1) * Interval, Epsilon,
      Format('step %d', [I + 1]));
end;

procedure TPlacementTests.TestNothingLandsOnOrPastTheNextFrame;
var
  Times: TCadenceTimes;
  I: Integer;
begin
  Times := CadenceTimes(0.0, 0.567, Interval);
  ExpectTrue(Length(Times) > 0, 'a 567 ms gap is filled');
  for I := 0 to High(Times) do
  begin
    ExpectTrue(Times[I] > 0.0, Format('step %d is after the first', [I]));
    ExpectTrue(Times[I] < 0.567,
      Format('step %d is before the next', [I]));
    if I > 0 then
      ExpectTrue(Times[I] > Times[I - 1],
        Format('step %d increases', [I]));
  end;
end;

procedure TPlacementTests.TestNothingIsCrowdedAgainstTheNextFrame;
var
  Times: TCadenceTimes;
begin
  // Two and a half intervals: the second grid step would land half an
  // interval before the next frame, which is crowding.
  Times := CadenceTimes(0, Interval * 2.5, Interval);
  ExpectCount(Times, 1, 'frames in a two-and-a-half interval gap');
  ExpectNear(Times[0], Interval, Epsilon, 'the one step');
end;

procedure TPlacementTests.TestALongGapDoesNotDrift;
var
  Times: TCadenceTimes;
  Last: Integer;
begin
  // Ten seconds at 30 Hz. Accumulating the interval instead of
  // multiplying the step index puts the last frame about a hundred
  // nanoseconds from where it belongs; over a longer gap it is worse.
  Times := CadenceTimes(100.0, 110.0, Interval);
  Last := High(Times);
  ExpectTrue(Last > 250, 'a ten-second gap is filled');
  ExpectNear(Times[Last], 100.0 + (Last + 1) * Interval, Epsilon,
    'the last step is exactly on the grid');
end;

procedure TPlacementTests.TestAGapIsBounded;
var
  Times: TCadenceTimes;
begin
  // An hour between two frames, which only a damaged movie produces.
  Times := CadenceTimes(0, 3600, Interval);
  ExpectCount(Times, MaxCadenceStepsPerGap, 'an hour-long gap');
end;

// The GIF and APNG pipeline walks the decimation grid it is already
// counting output frames on rather than asking for instants, so the
// bound has to be expressible in slots too — and has to be the SAME
// bound, or one of the two paths quietly becomes the unbounded one.
procedure TPlacementTests.TestASlotGapIsBoundedByTheSameNumber;
begin
  // An ordinary gap is filled entirely: the limit is the next frame.
  Expect<Int64>(CadenceFillLimit(5, 9)).ToBe(9);
  // A gap with nothing missing from it asks for nothing.
  Expect<Int64>(CadenceFillLimit(5, 5)).ToBe(5);
  Expect<Int64>(CadenceFillLimit(5, 4)).ToBe(5);
  // And an absurd one is cut to the shared bound, counted from the start
  // of the gap rather than the end of it.
  Expect<Int64>(CadenceFillLimit(5, 1000000))
    .ToBe(5 + MaxCadenceStepsPerGap);
  Expect<Int64>(CadenceFillLimit(0, 1000000)).ToBe(MaxCadenceStepsPerGap);
end;

procedure TPlacementTests.TestBackwardsAndDegenerateGapsAreEmpty;
begin
  ExpectCount(CadenceTimes(2.0, 1.0, Interval), 0, 'backwards');
  ExpectCount(CadenceTimes(1.0, 1.0, Interval), 0, 'no gap at all');
  ExpectCount(CadenceTimes(0.0, 5.0, 0), 0, 'no interval');
  ExpectCount(CadenceTimes(0.0, 5.0, -1), 0, 'a negative interval');
end;

{ TShapeTests }

procedure TShapeTests.SetupTests;
begin
  Test('a frame with the same crop and the same pointer is the same '
    + 'picture', TestTheSameShapeIsTheSamePicture);
  Test('a crop that moved by a pixel is a different picture',
    TestAMovedCropIsADifferentPicture);
  Test('a pointer that moved by a pixel is a different picture',
    TestAMovedPointerIsADifferentPicture);
  Test('a pointer that left the frame is a different picture',
    TestAPointerThatLeftTheFrameIsADifferentPicture);
  Test('where a pointer that is not drawn would have been does not count',
    TestPointerCoordinatesDoNotCountWithoutAPointer);
end;

procedure TShapeTests.TestTheSameShapeIsTheSamePicture;
begin
  // This is the case that keeps a zoom's hold — a constant crop over
  // 0.8 s — from being filled in with 24 identical frames.
  ExpectTrue(not FrameShapesDiffer(Shape(10, 20, 640, 400, True, 100, 200),
    Shape(10, 20, 640, 400, True, 100, 200)), 'identical shapes agree');
  ExpectTrue(not FrameShapesDiffer(Shape(0, 0, 1280, 800, False, 0, 0),
    Shape(0, 0, 1280, 800, False, 0, 0)), 'no crop and no pointer');
end;

procedure TShapeTests.TestAMovedCropIsADifferentPicture;
begin
  ExpectTrue(FrameShapesDiffer(Shape(10, 20, 640, 400, False, 0, 0),
    Shape(11, 20, 640, 400, False, 0, 0)), 'the crop slid');
  ExpectTrue(FrameShapesDiffer(Shape(10, 20, 640, 400, False, 0, 0),
    Shape(10, 20, 641, 400, False, 0, 0)), 'the crop grew');
  ExpectTrue(FrameShapesDiffer(Shape(10, 20, 640, 400, False, 0, 0),
    Shape(10, 20, 640, 401, False, 0, 0)), 'the crop grew downwards');
end;

procedure TShapeTests.TestAMovedPointerIsADifferentPicture;
begin
  ExpectTrue(FrameShapesDiffer(Shape(0, 0, 1280, 800, True, 100, 200),
    Shape(0, 0, 1280, 800, True, 101, 200)), 'the pointer moved across');
  ExpectTrue(FrameShapesDiffer(Shape(0, 0, 1280, 800, True, 100, 200),
    Shape(0, 0, 1280, 800, True, 100, 199)), 'the pointer moved up');
end;

procedure TShapeTests.TestAPointerThatLeftTheFrameIsADifferentPicture;
begin
  ExpectTrue(FrameShapesDiffer(Shape(0, 0, 1280, 800, True, 100, 200),
    Shape(0, 0, 1280, 800, False, 100, 200)), 'the pointer left');
end;

procedure TShapeTests.TestPointerCoordinatesDoNotCountWithoutAPointer;
begin
  ExpectTrue(not FrameShapesDiffer(Shape(0, 0, 1280, 800, False, 1, 2),
    Shape(0, 0, 1280, 800, False, 900, 900)),
    'coordinates of a pointer nobody draws');
end;

begin
  TestRunnerProgram.AddSuite(TIntervalTests.Create('the cadence interval'));
  TestRunnerProgram.AddSuite(TPlacementTests.Create(
    'where a synthesised frame goes'));
  TestRunnerProgram.AddSuite(TShapeTests.Create(
    'whether it is worth making'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

program Knips.Export.Timing.Test;

// The planner is checked on two properties at once: the delays it hands
// out must be smooth (no alternation on a uniform source) and the sum of
// them must track the true elapsed time. Either alone is easy; the pair
// is what the implementation is for.

{$I Knips.inc}

uses
  Math,
  SysUtils,
  Types,

  Knips.Export.Timing,
  TestingPascalLibrary;

type
  TSmoothnessTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestThirtyIntoTwentyIsUniform;
    procedure TestMatchingRateIsUniform;
    procedure TestThirtyFpsAlternatesAroundTheTrueInterval;
    procedure TestMillisecondTicksAreExactAtTwenty;
  end;

  TAccuracyTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestUniformSourceKeepsItsDuration;
    procedure TestThirtyFpsNeverDrifts;
    procedure TestDecimatedSourceKeepsItsDuration;
    procedure TestIdleGapKeepsItsLength;
    procedure TestClampedDelayIsRepaid;
    procedure TestTrailingDelayIsOneInterval;
    procedure TestResetStartsOver;
  end;

  TCeilingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestGapJustUnderTheCeilingIsKeptExactly;
    procedure TestGapOverTheCeilingForgivesTheRemainder;
    procedure TestLongPauseDoesNotSlideshowTheFramesAfterIt;
    procedure TestCentisecondsReachFarEnoughInPractice;
  end;

  TIntervalTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestIntervalRoundsToNearest;
    procedure TestSlotTicksAreMonotonic;
  end;

{ ---------------------------------------------------------------- helpers }

// Delays for a source running at ASourceFps, decimated onto the
// planner's own grid the way TExportSession does it: a frame is emitted
// when its floor slot passes the last emitted one.
function DecimatedDelays(ASourceFps, ATargetFps, ACount: Integer;
  ATicksPerSecond, AMinimumTicks: Integer;
  out ASpentTicks: Int64; out ALastSeconds: Double): TIntegerDynArray;
var
  Planner: TFrameDelayPlanner;
  Index: Integer;
  Seconds, BaseSeconds: Double;
  Slot, LastSlot: Int64;
  Emitted: Integer;
  Pending: Boolean;
begin
  SetLength(Result, 0);
  ASpentTicks := 0;
  ALastSeconds := 0;
  BaseSeconds := 0;
  LastSlot := 0;
  Emitted := 0;
  Pending := False;
  Planner := TFrameDelayPlanner.Create(ATargetFps, ATicksPerSecond,
    AMinimumTicks);
  try
    Index := 0;
    while Length(Result) < ACount do
    begin
      Seconds := Index / ASourceFps;
      Inc(Index);
      if Emitted = 0 then
        BaseSeconds := Seconds
      else
      begin
        Slot := Floor((Seconds - BaseSeconds) * ATargetFps + 1E-6);
        if Slot <= LastSlot then
          Continue;
        LastSlot := Slot;
      end;
      Inc(Emitted);
      if Pending then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Planner.NextDelay(Seconds - BaseSeconds);
      end;
      Pending := True;
      ALastSeconds := Seconds - BaseSeconds;
    end;
    ASpentTicks := Planner.SpentTicks;
  finally
    Planner.Free;
  end;
end;

function AllEqual(const AValues: TIntegerDynArray; AValue: Integer): Boolean;
var
  I: Integer;
begin
  Result := Length(AValues) > 0;
  for I := 0 to High(AValues) do
    if AValues[I] <> AValue then
      Exit(False);
end;

function Total(const AValues: TIntegerDynArray): Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(AValues) do
    Inc(Result, AValues[I]);
end;

{ TSmoothnessTests }

procedure TSmoothnessTests.SetupTests;
begin
  Test('a 30 fps source decimated to 20 fps gets one delay, not 7 and 3',
    TestThirtyIntoTwentyIsUniform);
  Test('a source already at the target rate gets one delay',
    TestMatchingRateIsUniform);
  Test('30 fps, which no whole centisecond expresses, alternates by one',
    TestThirtyFpsAlternatesAroundTheTrueInterval);
  Test('milliseconds express 20 fps exactly', TestMillisecondTicksAreExactAtTwenty);
end;

// The regression this exists for: the stamps of a 30 fps source land
// 3.33 cs either side of every 1/20 s slot, so measuring each gap
// against the centisecond grid produced 7, 3, 7, 3.
procedure TSmoothnessTests.TestThirtyIntoTwentyIsUniform;
var
  Delays: TIntegerDynArray;
  Spent: Int64;
  LastSeconds: Double;
begin
  Delays := DecimatedDelays(30, 20, 40, GifDelayTicksPerSecond,
    GifMinimumDelayTicks, Spent, LastSeconds);
  Expect<Integer>(Length(Delays)).ToBe(40);
  Expect<Boolean>(AllEqual(Delays, 5)).ToBe(True);
end;

procedure TSmoothnessTests.TestMatchingRateIsUniform;
var
  Delays: TIntegerDynArray;
  Spent: Int64;
  LastSeconds: Double;
begin
  Delays := DecimatedDelays(20, 20, 30, GifDelayTicksPerSecond,
    GifMinimumDelayTicks, Spent, LastSeconds);
  Expect<Boolean>(AllEqual(Delays, 5)).ToBe(True);
end;

procedure TSmoothnessTests.TestThirtyFpsAlternatesAroundTheTrueInterval;
var
  Delays: TIntegerDynArray;
  Spent: Int64;
  LastSeconds: Double;
  I, Smallest, Largest: Integer;
begin
  Delays := DecimatedDelays(30, 30, 60, GifDelayTicksPerSecond,
    GifMinimumDelayTicks, Spent, LastSeconds);
  Smallest := MaxInt;
  Largest := 0;
  for I := 0 to High(Delays) do
  begin
    Smallest := Min(Smallest, Delays[I]);
    Largest := Max(Largest, Delays[I]);
  end;
  // 3.33 cs cannot be written down, so the best any encoder can do is
  // stay within one tick of it.
  Expect<Integer>(Smallest).ToBe(3);
  Expect<Integer>(Largest).ToBe(4);
  Expect<Integer>(Integer(Total(Delays))).ToBe(200);
end;

procedure TSmoothnessTests.TestMillisecondTicksAreExactAtTwenty;
var
  Delays: TIntegerDynArray;
  Spent: Int64;
  LastSeconds: Double;
begin
  Delays := DecimatedDelays(30, 20, 25, ApngDelayTicksPerSecond,
    ApngMinimumDelayTicks, Spent, LastSeconds);
  Expect<Boolean>(AllEqual(Delays, 50)).ToBe(True);
end;

{ TAccuracyTests }

procedure TAccuracyTests.SetupTests;
begin
  Test('a uniform source''s delays add up to its own length',
    TestUniformSourceKeepsItsDuration);
  Test('30 fps never drifts, however many frames go by',
    TestThirtyFpsNeverDrifts);
  Test('a decimated source''s delays add up to its own length',
    TestDecimatedSourceKeepsItsDuration);
  Test('an idle stretch keeps its length instead of one interval',
    TestIdleGapKeepsItsLength);
  Test('a delay clamped at the minimum is repaid by the next one',
    TestClampedDelayIsRepaid);
  Test('the last frame is shown for one interval', TestTrailingDelayIsOneInterval);
  Test('Reset puts the planner back at the first frame', TestResetStartsOver);
end;

procedure TAccuracyTests.TestUniformSourceKeepsItsDuration;
var
  Delays: TIntegerDynArray;
  Spent: Int64;
  LastSeconds: Double;
begin
  Delays := DecimatedDelays(20, 20, 100, GifDelayTicksPerSecond,
    GifMinimumDelayTicks, Spent, LastSeconds);
  // 100 gaps of exactly 1/20 s.
  Expect<Integer>(Integer(Spent)).ToBe(500);
  Expect<Boolean>(Abs(Spent - Round(LastSeconds * 100)) <= 1).ToBe(True);
end;

// The property the grid-anchored delays were written for in the first
// place: rounding each 3.33 cs gap on its own would lose 10% of the
// running time over a thousand frames, which is three whole seconds.
procedure TAccuracyTests.TestThirtyFpsNeverDrifts;
var
  Delays: TIntegerDynArray;
  Spent: Int64;
  LastSeconds: Double;
begin
  Delays := DecimatedDelays(30, 30, 1000, GifDelayTicksPerSecond,
    GifMinimumDelayTicks, Spent, LastSeconds);
  Expect<Integer>(Length(Delays)).ToBe(1000);
  Expect<Boolean>(Abs(Spent - Round(LastSeconds * 100)) <= 1).ToBe(True);
end;

procedure TAccuracyTests.TestDecimatedSourceKeepsItsDuration;
var
  Delays: TIntegerDynArray;
  Spent: Int64;
  LastSeconds: Double;
begin
  Delays := DecimatedDelays(30, 20, 200, GifDelayTicksPerSecond,
    GifMinimumDelayTicks, Spent, LastSeconds);
  // Snapping to the nearest slot can move a frame by at most half a
  // slot, so a decimated source's total stays inside one slot of true.
  Expect<Boolean>(Abs(Spent - Round(LastSeconds * 100)) <= 5).ToBe(True);
end;

procedure TAccuracyTests.TestIdleGapKeepsItsLength;
var
  Planner: TFrameDelayPlanner;
begin
  Planner := TFrameDelayPlanner.Create(20, GifDelayTicksPerSecond,
    GifMinimumDelayTicks);
  try
    Expect<Integer>(Planner.NextDelay(0.05)).ToBe(5);
    // Two seconds of nothing happening: forty slots, not one.
    Expect<Integer>(Planner.NextDelay(2.05)).ToBe(200);
    Expect<Integer>(Planner.NextDelay(2.10)).ToBe(5);
    Expect<Integer>(Integer(Planner.SpentTicks)).ToBe(210);
  finally
    Planner.Free;
  end;
end;

procedure TAccuracyTests.TestClampedDelayIsRepaid;
var
  Planner: TFrameDelayPlanner;
  First, Second: Integer;
begin
  // 50 fps is 2 cs a slot, which is exactly the floor; a source that
  // hands the planner two frames inside one slot must not pay twice.
  Planner := TFrameDelayPlanner.Create(50, GifDelayTicksPerSecond,
    GifMinimumDelayTicks);
  try
    First := Planner.NextDelay(0.02);
    Second := Planner.NextDelay(0.021);
    Expect<Integer>(First).ToBe(2);
    Expect<Integer>(Second).ToBe(2);
    Expect<Integer>(Integer(Planner.SpentTicks)).ToBe(4);
  finally
    Planner.Free;
  end;
end;

procedure TAccuracyTests.TestTrailingDelayIsOneInterval;
var
  Planner: TFrameDelayPlanner;
begin
  Planner := TFrameDelayPlanner.Create(20, GifDelayTicksPerSecond,
    GifMinimumDelayTicks);
  try
    Expect<Integer>(Planner.TrailingDelay).ToBe(5);
    Expect<Integer>(Integer(Planner.SpentTicks)).ToBe(5);
  finally
    Planner.Free;
  end;
end;

procedure TAccuracyTests.TestResetStartsOver;
var
  Planner: TFrameDelayPlanner;
begin
  Planner := TFrameDelayPlanner.Create(20, GifDelayTicksPerSecond,
    GifMinimumDelayTicks);
  try
    Planner.NextDelay(0.05);
    Planner.NextDelay(0.10);
    Planner.Reset;
    Expect<Integer>(Integer(Planner.SpentTicks)).ToBe(0);
    Expect<Integer>(Planner.NextDelay(0.05)).ToBe(5);
  finally
    Planner.Free;
  end;
end;

{ TCeilingTests }

procedure TCeilingTests.SetupTests;
begin
  Test('a gap that still fits the delay field is written exactly',
    TestGapJustUnderTheCeilingIsKeptExactly);
  Test('a gap past the ceiling is one maximum delay, remainder forgiven',
    TestGapOverTheCeilingForgivesTheRemainder);
  Test('the frames after a very long pause keep their true delays',
    TestLongPauseDoesNotSlideshowTheFramesAfterIt);
  Test('centiseconds reach 655 s, so a GIF never meets the ceiling',
    TestCentisecondsReachFarEnoughInPractice);
end;

procedure TCeilingTests.TestGapJustUnderTheCeilingIsKeptExactly;
var
  Planner: TFrameDelayPlanner;
begin
  Planner := TFrameDelayPlanner.Create(20, ApngDelayTicksPerSecond,
    ApngMinimumDelayTicks);
  try
    Expect<Integer>(Planner.NextDelay(0.05)).ToBe(50);
    // 65.5 s of idle is 65500 ms, still inside a two-byte field.
    Expect<Integer>(Planner.NextDelay(65.55)).ToBe(65500);
    Expect<Integer>(Integer(Planner.ForgivenTicks)).ToBe(0);
    Expect<Integer>(Planner.NextDelay(65.60)).ToBe(50);
    Expect<Integer>(Integer(Planner.SpentTicks)).ToBe(65600);
  finally
    Planner.Free;
  end;
end;

procedure TCeilingTests.TestGapOverTheCeilingForgivesTheRemainder;
var
  Planner: TFrameDelayPlanner;
begin
  Planner := TFrameDelayPlanner.Create(20, ApngDelayTicksPerSecond,
    ApngMinimumDelayTicks);
  try
    Expect<Integer>(Planner.NextDelay(0.05)).ToBe(50);
    // 70 s of idle is 70000 ms, which no delay field holds.
    Expect<Integer>(Planner.NextDelay(70.05)).ToBe(MaximumDelayTicks);
    Expect<Integer>(Integer(Planner.ForgivenTicks))
      .ToBe(70000 - MaximumDelayTicks);
    // The very next frame is back to its own true delay, not the rest of
    // the pause paid off a frame at a time.
    Expect<Integer>(Planner.NextDelay(70.10)).ToBe(50);
    Expect<Integer>(Planner.NextDelay(70.15)).ToBe(50);
  finally
    Planner.Free;
  end;
end;

// The measured regression: at APNG's millisecond scale a 300 s pause used
// to leave the four frames after it each held for 65 535 ticks, so the
// moment the recording came back to life played as a slideshow.
procedure TCeilingTests.TestLongPauseDoesNotSlideshowTheFramesAfterIt;
var
  Planner: TFrameDelayPlanner;
  I: Integer;
begin
  Planner := TFrameDelayPlanner.Create(20, ApngDelayTicksPerSecond,
    ApngMinimumDelayTicks);
  try
    Expect<Integer>(Planner.NextDelay(0.05)).ToBe(50);
    Expect<Integer>(Planner.NextDelay(300.05)).ToBe(MaximumDelayTicks);
    Expect<Integer>(Integer(Planner.ForgivenTicks))
      .ToBe(300000 - MaximumDelayTicks);
    for I := 1 to 4 do
      Expect<Integer>(Planner.NextDelay(300.05 + I * 0.05)).ToBe(50);
    // Playback is the pause capped at the ceiling plus every real delay,
    // which is the whole cost of forgiving rather than owing.
    Expect<Integer>(Integer(Planner.SpentTicks))
      .ToBe(50 + MaximumDelayTicks + 4 * 50);
  finally
    Planner.Free;
  end;
end;

procedure TCeilingTests.TestCentisecondsReachFarEnoughInPractice;
var
  Planner: TFrameDelayPlanner;
begin
  Planner := TFrameDelayPlanner.Create(20, GifDelayTicksPerSecond,
    GifMinimumDelayTicks);
  try
    Expect<Integer>(Planner.NextDelay(0.05)).ToBe(5);
    // The same 300 s pause is 30000 cs, well inside the field.
    Expect<Integer>(Planner.NextDelay(300.05)).ToBe(30000);
    Expect<Integer>(Integer(Planner.ForgivenTicks)).ToBe(0);
    Expect<Integer>(Planner.NextDelay(300.10)).ToBe(5);
  finally
    Planner.Free;
  end;
end;

{ TIntervalTests }

procedure TIntervalTests.SetupTests;
begin
  Test('the interval is the rate rounded to the nearest tick',
    TestIntervalRoundsToNearest);
  Test('slot ticks never go backwards', TestSlotTicksAreMonotonic);
end;

procedure TIntervalTests.TestIntervalRoundsToNearest;
begin
  Expect<Integer>(FrameIntervalTicks(20, GifDelayTicksPerSecond)).ToBe(5);
  Expect<Integer>(FrameIntervalTicks(30, GifDelayTicksPerSecond)).ToBe(3);
  Expect<Integer>(FrameIntervalTicks(50, GifDelayTicksPerSecond)).ToBe(2);
  Expect<Integer>(FrameIntervalTicks(1, GifDelayTicksPerSecond)).ToBe(100);
  Expect<Integer>(FrameIntervalTicks(30, ApngDelayTicksPerSecond)).ToBe(33);
  Expect<Integer>(FrameIntervalTicks(20, ApngDelayTicksPerSecond)).ToBe(50);
end;

procedure TIntervalTests.TestSlotTicksAreMonotonic;
var
  I: Integer;
  Previous, Current: Int64;
begin
  Previous := -1;
  for I := 0 to 500 do
  begin
    Current := SlotTicks(I, 30, GifDelayTicksPerSecond);
    Expect<Boolean>(Current > Previous).ToBe(True);
    Previous := Current;
  end;
  Expect<Integer>(Integer(SlotTicks(30, 30, GifDelayTicksPerSecond))).ToBe(100);
  Expect<Integer>(Integer(SlotTicks(20, 20, GifDelayTicksPerSecond))).ToBe(100);
end;

begin
  TestRunnerProgram.AddSuite(TSmoothnessTests.Create('delay smoothing'));
  TestRunnerProgram.AddSuite(TAccuracyTests.Create('delay accuracy'));
  TestRunnerProgram.AddSuite(TCeilingTests.Create('the delay ceiling'));
  TestRunnerProgram.AddSuite(TIntervalTests.Create('grid arithmetic'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

program Knips.Recording.Heartbeat.Test;

// The idle heartbeat's arithmetic, checked on the properties the Darwin
// side depends on and cannot check for itself:
//
//   - nothing is ever due before the first real frame, whatever the
//     clock says: a heartbeat repeats the last frame, and there isn't one;
//   - the interval is a floor, not a target — a caller ticking at 30 Hz
//     gets a heartbeat on the first tick at or past it and not before;
//   - a still stretch produces heartbeats at the tick rate the interval
//     asks for, not one per tick and not one per stretch;
//   - the stamp is the caller's own moment whenever that is a distinct
//     one, so the movie's duration tracks elapsed host time rather than a
//     count of heartbeats;
//   - it is never behind the last frame, however the clock behaves;
//   - and the floor under it never exceeds the interval, so a recording
//     at one frame a second does not run the movie AHEAD of the clock.

{$I Knips.inc}

uses
  SysUtils,

  Knips.Recording.Heartbeat,
  TestingPascalLibrary;

type
  TDueTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestNothingIsDueBeforeTheFirstFrame;
    procedure TestNothingIsDueWhileFramesFlow;
    procedure TestDueExactlyAtTheInterval;
    procedure TestDueStaysDueUntilItIsAnswered;
    procedure TestNonPositiveIntervalIsNeverDue;
    procedure TestBackwardsClockIsNeverDue;
  end;

  TStampTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestStampIsTheCallersMoment;
    procedure TestStampNeverPrecedesTheLastFrame;
    procedure TestStampKeepsAMinimumStep;
    procedure TestNegativeStepIsReadAsZero;
    procedure TestStampsIncreaseAcrossAStillStretch;
  end;

  TMinimumStepTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAFramesWorthAtOrdinaryRates;
    procedure TestTheIntervalCapsASlowFrameRate;
    procedure TestASlowRateNoLongerOvershoots;
    procedure TestNoIntervalLeavesTheFrameAlone;
  end;

  TCadenceTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAStillStretchBeatsAtTheInterval;
    procedure TestABusyStretchNeverBeats;
  end;

{ ---------------------------------------------------------------- helpers }

const
  // Seconds. Host-clock stamps are large (uptime), so the tolerance is
  // about double precision rather than about the arithmetic.
  Epsilon = 1E-9;
  // What every caller ticks at: the CLI's run loop slice and the menu-bar
  // app's timer are both 30 Hz.
  TickSeconds = 1 / 30;

procedure ExpectNear(AActual, AExpected: Double; const AWhat: string);
var
  Shown: Double;
begin
  Shown := AActual;
  if Abs(AActual - AExpected) <= Epsilon then
    Shown := AExpected;
  Expect<string>(Format('%s = %.9f', [AWhat, Shown]))
    .ToBe(Format('%s = %.9f', [AWhat, AExpected]));
end;

procedure ExpectTrue(ACondition: Boolean; const AWhat: string);
begin
  Expect<string>(AWhat + ': ' + BoolToStr(ACondition, 'yes', 'no'))
    .ToBe(AWhat + ': yes');
end;

// One still stretch, ticked at 30 Hz exactly the way a caller does it:
// ask, and when the answer is yes take the stamp and treat it as the new
// last frame. Answers how many heartbeats came out and where the last one
// landed.
procedure BeatThrough(ADurationSeconds, AIntervalSeconds: Double;
  out ACount: Integer; out ALastStamp: Double);
var
  Now, Last, Stop: Double;
begin
  ACount := 0;
  // A uptime-sized origin on purpose: the arithmetic must not depend on
  // the clock being near zero.
  Last := 123456.75;
  ALastStamp := Last;
  Now := Last;
  Stop := Last + ADurationSeconds;
  while Now < Stop do
  begin
    Now := Now + TickSeconds;
    if HeartbeatDue(True, ALastStamp, Now, AIntervalSeconds) then
    begin
      ALastStamp := HeartbeatStamp(ALastStamp, Now, TickSeconds);
      Inc(ACount);
    end;
  end;
end;

{ TDueTests }

procedure TDueTests.SetupTests;
begin
  Test('nothing is due before the first frame',
    TestNothingIsDueBeforeTheFirstFrame);
  Test('nothing is due while frames are still flowing',
    TestNothingIsDueWhileFramesFlow);
  Test('a heartbeat is due exactly at the interval',
    TestDueExactlyAtTheInterval);
  Test('a heartbeat stays due until it is answered',
    TestDueStaysDueUntilItIsAnswered);
  Test('a non-positive interval never asks for one',
    TestNonPositiveIntervalIsNeverDue);
  Test('a clock that went backwards never asks for one',
    TestBackwardsClockIsNeverDue);
end;

procedure TDueTests.TestNothingIsDueBeforeTheFirstFrame;
begin
  // Hours past a stamp that means nothing yet, and still no.
  Expect<Boolean>(HeartbeatDue(False, 0, 3600, DefaultHeartbeatSeconds))
    .ToBe(False);
  Expect<Boolean>(HeartbeatDue(False, 100, 200, DefaultHeartbeatSeconds))
    .ToBe(False);
end;

procedure TDueTests.TestNothingIsDueWhileFramesFlow;
var
  I: Integer;
  Last: Double;
begin
  // Thirty frames a second: the gap is never anywhere near the interval.
  Last := 500;
  for I := 1 to 60 do
  begin
    Expect<Boolean>(HeartbeatDue(True, Last, Last + TickSeconds,
      DefaultHeartbeatSeconds)).ToBe(False);
    Last := Last + TickSeconds;
  end;
end;

procedure TDueTests.TestDueExactlyAtTheInterval;
begin
  ExpectTrue(not HeartbeatDue(True, 10, 10.49, 0.5),
    'just under the interval is not due');
  ExpectTrue(HeartbeatDue(True, 10, 10.5, 0.5),
    'exactly the interval is due');
  ExpectTrue(HeartbeatDue(True, 10, 10.51, 0.5),
    'past the interval is due');
end;

procedure TDueTests.TestDueStaysDueUntilItIsAnswered;
var
  I: Integer;
begin
  // The caller may be late — a slow tick, a busy main thread. Being late
  // must not lose the heartbeat, and it must not queue up either: the
  // answer is still one frame, at the moment the caller finally asks.
  for I := 1 to 10 do
    ExpectTrue(HeartbeatDue(True, 10, 10 + I, 0.5),
      Format('still due %d s late', [I]));
end;

procedure TDueTests.TestNonPositiveIntervalIsNeverDue;
begin
  Expect<Boolean>(HeartbeatDue(True, 10, 20, 0)).ToBe(False);
  Expect<Boolean>(HeartbeatDue(True, 10, 20, -1)).ToBe(False);
end;

procedure TDueTests.TestBackwardsClockIsNeverDue;
begin
  Expect<Boolean>(HeartbeatDue(True, 20, 10, 0.5)).ToBe(False);
end;

{ TStampTests }

procedure TStampTests.SetupTests;
begin
  Test('the stamp is the moment the caller asked about',
    TestStampIsTheCallersMoment);
  Test('the stamp never precedes the last frame',
    TestStampNeverPrecedesTheLastFrame);
  Test('the stamp keeps a minimum step from the last frame',
    TestStampKeepsAMinimumStep);
  Test('a negative minimum step is read as zero',
    TestNegativeStepIsReadAsZero);
  Test('stamps increase across a still stretch',
    TestStampsIncreaseAcrossAStillStretch);
end;

procedure TStampTests.TestStampIsTheCallersMoment;
begin
  // This is the whole point: the movie's last stamp becomes the host time
  // the caller read, so duration and elapsed time are the same number.
  ExpectNear(HeartbeatStamp(123456.75, 123457.30, 1 / 30), 123457.30,
    'stamp');
end;

procedure TStampTests.TestStampNeverPrecedesTheLastFrame;
begin
  ExpectNear(HeartbeatStamp(100, 90, 0), 100, 'stamp');
  ExpectTrue(HeartbeatStamp(100, 90, 1 / 30) > 100,
    'a backwards clock still moves the stamp forward');
end;

procedure TStampTests.TestStampKeepsAMinimumStep;
begin
  ExpectNear(HeartbeatStamp(100, 100.001, 1 / 30), 100 + 1 / 30, 'stamp');
end;

procedure TStampTests.TestNegativeStepIsReadAsZero;
begin
  ExpectNear(HeartbeatStamp(100, 100.5, -5), 100.5, 'stamp');
  ExpectNear(HeartbeatStamp(100, 99, -5), 100, 'stamp');
end;

procedure TStampTests.TestStampsIncreaseAcrossAStillStretch;
var
  Count: Integer;
  Last: Double;
begin
  BeatThrough(10, DefaultHeartbeatSeconds, Count, Last);
  // Ten seconds of stillness must leave the movie's last stamp ten
  // seconds on, not one heartbeat on.
  ExpectTrue(Last - 123456.75 > 9.5,
    Format('the still stretch advanced the movie by %.3f s',
    [Last - 123456.75]));
end;

{ TMinimumStepTests }

procedure TMinimumStepTests.SetupTests;
begin
  Test('at ordinary frame rates the floor is one frame',
    TestAFramesWorthAtOrdinaryRates);
  Test('a frame slower than the interval is capped by the interval',
    TestTheIntervalCapsASlowFrameRate);
  Test('one frame a second no longer runs the movie ahead of the clock',
    TestASlowRateNoLongerOvershoots);
  Test('no interval leaves the frame interval alone',
    TestNoIntervalLeavesTheFrameAlone);
end;

procedure TMinimumStepTests.TestAFramesWorthAtOrdinaryRates;
begin
  ExpectNear(HeartbeatMinimumStep(1 / 30, DefaultHeartbeatSeconds), 1 / 30,
    'step at 30 fps');
  ExpectNear(HeartbeatMinimumStep(1 / 60, DefaultHeartbeatSeconds), 1 / 60,
    'step at 60 fps');
  ExpectNear(HeartbeatMinimumStep(1 / 3, DefaultHeartbeatSeconds), 1 / 3,
    'step at 3 fps');
end;

procedure TMinimumStepTests.TestTheIntervalCapsASlowFrameRate;
begin
  // --fps=1: a frame is a whole second, twice the heartbeat interval.
  ExpectNear(HeartbeatMinimumStep(1, DefaultHeartbeatSeconds), 0.5,
    'step at 1 fps');
  ExpectNear(HeartbeatMinimumStep(0.5, 0.5), 0.5, 'step at exactly 2 fps');
end;

// The regression this function exists for, stated as the invariant that
// makes it true rather than as one reading of a simulation.
//
// The movie's last stamp must never be AHEAD of the clock it is tracking.
// A floor no larger than the interval guarantees that outright: a beat is
// only due once the clock is at least an interval past the last stamp, so
// the floor is already satisfied and the stamp is the caller's own moment
// exactly. A floor larger than the interval — a frame at --fps=1 against a
// half-second heartbeat — breaks it, and the movie runs ahead by the
// difference and stays there for the rest of the still stretch.
//
// Ticked at 30 Hz through ten still seconds, measuring the worst moment
// rather than the last one: the overshoot oscillates as the two rates beat
// against each other, so the reading at an arbitrary stop says nothing.
procedure TMinimumStepTests.TestASlowRateNoLongerOvershoots;
var
  Now, Stop, Naive, Capped, NaiveWorst, CappedWorst: Double;
begin
  // At the instant a beat falls due, the difference is visible on its own.
  ExpectNear(HeartbeatStamp(100, 100.5, 1), 101,
    'a floor of one frame, half a second in');
  ExpectNear(HeartbeatStamp(100, 100.5,
    HeartbeatMinimumStep(1, DefaultHeartbeatSeconds)), 100.5,
    'the capped floor, half a second in');

  Naive := 123456.75;
  Capped := Naive;
  Now := Naive;
  Stop := Naive + 10;
  NaiveWorst := 0;
  CappedWorst := 0;
  while Now < Stop do
  begin
    Now := Now + TickSeconds;
    if HeartbeatDue(True, Naive, Now, DefaultHeartbeatSeconds) then
      Naive := HeartbeatStamp(Naive, Now, 1);
    if HeartbeatDue(True, Capped, Now, DefaultHeartbeatSeconds) then
      Capped := HeartbeatStamp(Capped, Now,
        HeartbeatMinimumStep(1, DefaultHeartbeatSeconds));
    if Naive - Now > NaiveWorst then
      NaiveWorst := Naive - Now;
    if Capped - Now > CappedWorst then
      CappedWorst := Capped - Now;
  end;
  ExpectTrue(NaiveWorst > 0.4,
    Format('a floor of one frame runs up to %.3f s ahead of the clock',
    [NaiveWorst]));
  ExpectTrue(CappedWorst <= 0,
    Format('the capped floor never gets ahead of it (worst %.3f s)',
    [CappedWorst]));
end;

procedure TMinimumStepTests.TestNoIntervalLeavesTheFrameAlone;
begin
  ExpectNear(HeartbeatMinimumStep(1 / 30, 0), 1 / 30, 'step');
  ExpectNear(HeartbeatMinimumStep(1 / 30, -1), 1 / 30, 'step');
  ExpectNear(HeartbeatMinimumStep(-1, 0.5), 0, 'step');
end;

{ TCadenceTests }

procedure TCadenceTests.SetupTests;
begin
  Test('a still stretch beats at the interval, not at the tick rate',
    TestAStillStretchBeatsAtTheInterval);
  Test('a busy stretch never beats at all', TestABusyStretchNeverBeats);
end;

procedure TCadenceTests.TestAStillStretchBeatsAtTheInterval;
var
  Count: Integer;
  Last: Double;
begin
  BeatThrough(10, DefaultHeartbeatSeconds, Count, Last);
  // Ten seconds at half a second apart: twenty, give or take the tick the
  // interval is sampled on.
  ExpectTrue((Count >= 19) and (Count <= 21),
    Format('ten still seconds produced %d heartbeats', [Count]));
  BeatThrough(10, 1, Count, Last);
  ExpectTrue((Count >= 9) and (Count <= 11),
    Format('at a one-second interval, %d heartbeats', [Count]));
end;

procedure TCadenceTests.TestABusyStretchNeverBeats;
var
  I, Count: Integer;
  Last, Now: Double;
begin
  // A real frame every tick, and the caller asking on every one of them:
  // the answer must be no, every time. This is the no-regression property
  // the busy-recording proof measures on device.
  Count := 0;
  Last := 987.5;
  Now := Last;
  for I := 1 to 300 do
  begin
    Now := Now + TickSeconds;
    // The frame arrived, so the last stamp moves with the clock.
    Last := Now;
    if HeartbeatDue(True, Last, Now, DefaultHeartbeatSeconds) then
      Inc(Count);
  end;
  Expect<Integer>(Count).ToBe(0);
end;

begin
  TestRunnerProgram.AddSuite(TDueTests.Create('when a heartbeat is due'));
  TestRunnerProgram.AddSuite(TStampTests.Create('the stamp it carries'));
  TestRunnerProgram.AddSuite(TMinimumStepTests.Create(
    'the floor under the stamp'));
  TestRunnerProgram.AddSuite(TCadenceTests.Create('cadence over a take'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

program Knips.Recording.LinuxPlan.Test;

// What the Linux recorder decides before and between frames, checked
// without a display: what it refuses and why, which pixels it records,
// and how it paces. The pacing tests pin the property that matters for a
// screen recording: a slow encoder makes frames SKIPPED, never grabbed in
// a burst, so playback stays in real time.

{$I Knips.inc}

uses
  SysUtils,

  Knips.Options,
  Knips.Recording.LinuxPlan,
  TestingPascalLibrary;

type
  TRefusalTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAnApngOfTheWholeScreenIsFine;
    procedure TestAnApngOfARegionIsFine;
    procedure TestMovieOutputIsRefusedByName;
    procedure TestGifIsRefusedUntilItsReaderExists;
    procedure TestAudioIsRefused;
    procedure TestABitRateIsRefused;
    procedure TestScaleTwoIsRefused;
    procedure TestAWindowIsRefused;
    procedure TestTheBigAndSmoothCursorAreRefused;
    procedure TestASecondDisplayIsRefused;
  end;

  TRectTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestNoRegionRecordsTheWholeScreen;
    procedure TestARegionIsKeptAsAsked;
    procedure TestARegionTouchingTheEdgeFits;
    procedure TestARegionPastTheRightEdgeIsRefusedWithNumbers;
    procedure TestARegionPastTheBottomEdgeIsRefused;
    procedure TestAScreenWithNoSizeIsRefused;
    procedure TestACanvasOverTheBudgetIsRefused;
  end;

  TPacingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheIntervalIsRoundedDown;
    procedure TestTheIntervalNeverDividesByZero;
    procedure TestDeadlinesSitOnAFixedGrid;
    procedure TestOnTimeFramesDropNothing;
    procedure TestALateFrameSkipsInsteadOfBursting;
    procedure TestEarlyIsNeverSkipped;
    procedure TestDelayIsRoundedToTheNearestMillisecond;
    procedure TestDelayIsNeverZero;
    procedure TestDelayFitsTheFormatsSixteenBits;
    procedure TestAchievedRate;
  end;

  TTemporaryTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheTemporarySitsBesideTheTarget;
    procedure TestTwoRecordingsDoNotShareATemporary;
    procedure TestOnlyOurTemporariesAreRecognised;
  end;

function LinuxOptions(const APath: string): TRecordingOptions;
begin
  Result := DefaultRecordingOptions;
  Result.OutputPath := APath;
end;

{ TRefusalTests }

procedure TRefusalTests.SetupTests;
begin
  Test('an .apng of the whole screen is fine',
    TestAnApngOfTheWholeScreenIsFine);
  Test('an .apng of a region is fine', TestAnApngOfARegionIsFine);
  Test('.mp4 and .mov are refused by name', TestMovieOutputIsRefusedByName);
  Test('.gif is refused until its reader exists',
    TestGifIsRefusedUntilItsReaderExists);
  Test('audio is refused', TestAudioIsRefused);
  Test('a bit rate is refused', TestABitRateIsRefused);
  Test('--scale=2 is refused', TestScaleTwoIsRefused);
  Test('a window target is refused', TestAWindowIsRefused);
  Test('the big and the smooth cursor are refused',
    TestTheBigAndSmoothCursorAreRefused);
  Test('a second display is refused', TestASecondDisplayIsRefused);
end;

procedure TRefusalTests.TestAnApngOfTheWholeScreenIsFine;
begin
  Expect<string>(LinuxRecordingRefusal(LinuxOptions('demo.apng'))).ToBe('');
end;

procedure TRefusalTests.TestAnApngOfARegionIsFine;
var
  Options: TRecordingOptions;
begin
  Options := LinuxOptions('demo.apng');
  Options.HasRegion := True;
  Options.Region.Width := 100;
  Options.Region.Height := 100;
  Expect<string>(LinuxRecordingRefusal(Options)).ToBe('');
end;

procedure TRefusalTests.TestMovieOutputIsRefusedByName;
begin
  Expect<Boolean>(Pos('not MP4 or MOV',
    LinuxRecordingRefusal(LinuxOptions('demo.mp4'))) > 0).ToBe(True);
  Expect<Boolean>(Pos('not MP4 or MOV',
    LinuxRecordingRefusal(LinuxOptions('DEMO.MOV'))) > 0).ToBe(True);
end;

procedure TRefusalTests.TestGifIsRefusedUntilItsReaderExists;
begin
  Expect<Boolean>(LinuxGifOutputAvailable).ToBe(False);
  Expect<Boolean>(Pos('.gif',
    LinuxRecordingRefusal(LinuxOptions('demo.gif'))) > 0).ToBe(True);
end;

procedure TRefusalTests.TestAudioIsRefused;
var
  Options: TRecordingOptions;
begin
  Options := LinuxOptions('demo.apng');
  Options.AudioMode := amSystem;
  Expect<Boolean>(Pos('--audio',
    LinuxRecordingRefusal(Options)) > 0).ToBe(True);
end;

procedure TRefusalTests.TestABitRateIsRefused;
var
  Options: TRecordingOptions;
begin
  Options := LinuxOptions('demo.apng');
  Options.BitRate := 8000000;
  Expect<Boolean>(Pos('--bitrate',
    LinuxRecordingRefusal(Options)) > 0).ToBe(True);
end;

procedure TRefusalTests.TestScaleTwoIsRefused;
var
  Options: TRecordingOptions;
begin
  Options := LinuxOptions('demo.apng');
  Options.Scale := 2;
  Expect<Boolean>(Pos('--scale',
    LinuxRecordingRefusal(Options)) > 0).ToBe(True);
end;

procedure TRefusalTests.TestAWindowIsRefused;
var
  Options: TRecordingOptions;
begin
  Options := LinuxOptions('demo.apng');
  Options.TargetKind := ctkWindow;
  Expect<Boolean>(Pos('--window',
    LinuxRecordingRefusal(Options)) > 0).ToBe(True);
end;

procedure TRefusalTests.TestTheBigAndSmoothCursorAreRefused;
var
  Options: TRecordingOptions;
begin
  Options := LinuxOptions('demo.apng');
  Options.BigCursor := True;
  Expect<Boolean>(Pos('--big-cursor',
    LinuxRecordingRefusal(Options)) > 0).ToBe(True);
  Options.BigCursor := False;
  Options.SmoothCursor := True;
  Expect<Boolean>(Pos('--smooth-cursor',
    LinuxRecordingRefusal(Options)) > 0).ToBe(True);
end;

procedure TRefusalTests.TestASecondDisplayIsRefused;
var
  Options: TRecordingOptions;
begin
  Options := LinuxOptions('demo.apng');
  Options.DisplayIndex := 1;
  Expect<Boolean>(Pos('--display=1',
    LinuxRecordingRefusal(Options)) > 0).ToBe(True);
end;

{ TRectTests }

procedure TRectTests.SetupTests;
begin
  Test('no region records the whole screen',
    TestNoRegionRecordsTheWholeScreen);
  Test('a region is kept as asked', TestARegionIsKeptAsAsked);
  Test('a region touching the edge fits', TestARegionTouchingTheEdgeFits);
  Test('a region past the right edge is refused with the numbers',
    TestARegionPastTheRightEdgeIsRefusedWithNumbers);
  Test('a region past the bottom edge is refused',
    TestARegionPastTheBottomEdgeIsRefused);
  Test('a screen with no size is refused', TestAScreenWithNoSizeIsRefused);
  Test('a canvas over the budget is refused',
    TestACanvasOverTheBudgetIsRefused);
end;

procedure TRectTests.TestNoRegionRecordsTheWholeScreen;
var
  Region: TCaptureRegion;
  Error: string;
begin
  Expect<Boolean>(ResolveLinuxCaptureRect(LinuxOptions('d.apng'), 1920, 1200,
    Region, Error)).ToBe(True);
  Expect<Integer>(Region.Left).ToBe(0);
  Expect<Integer>(Region.Top).ToBe(0);
  Expect<Integer>(Region.Width).ToBe(1920);
  Expect<Integer>(Region.Height).ToBe(1200);
end;

procedure TRectTests.TestARegionIsKeptAsAsked;
var
  Options: TRecordingOptions;
  Region: TCaptureRegion;
  Error: string;
begin
  Options := LinuxOptions('d.apng');
  Options.HasRegion := True;
  Options.Region.Left := 101;
  Options.Region.Top := 53;
  Options.Region.Width := 641;
  Options.Region.Height := 479;
  Expect<Boolean>(ResolveLinuxCaptureRect(Options, 1920, 1200, Region,
    Error)).ToBe(True);
  // Odd sizes stay odd: APNG has no alignment rule, and a recording of a
  // rectangle other than the one asked for is the quiet failure.
  Expect<Integer>(Region.Left).ToBe(101);
  Expect<Integer>(Region.Top).ToBe(53);
  Expect<Integer>(Region.Width).ToBe(641);
  Expect<Integer>(Region.Height).ToBe(479);
end;

procedure TRectTests.TestARegionTouchingTheEdgeFits;
var
  Options: TRecordingOptions;
  Region: TCaptureRegion;
  Error: string;
begin
  Options := LinuxOptions('d.apng');
  Options.HasRegion := True;
  Options.Region.Left := 1820;
  Options.Region.Top := 1100;
  Options.Region.Width := 100;
  Options.Region.Height := 100;
  Expect<Boolean>(ResolveLinuxCaptureRect(Options, 1920, 1200, Region,
    Error)).ToBe(True);
end;

procedure TRectTests.TestARegionPastTheRightEdgeIsRefusedWithNumbers;
var
  Options: TRecordingOptions;
  Region: TCaptureRegion;
  Error: string;
begin
  Options := LinuxOptions('d.apng');
  Options.HasRegion := True;
  Options.Region.Left := 1821;
  Options.Region.Top := 0;
  Options.Region.Width := 100;
  Options.Region.Height := 100;
  Expect<Boolean>(ResolveLinuxCaptureRect(Options, 1920, 1200, Region,
    Error)).ToBe(False);
  Expect<string>(Error).ToBe(
    '--rect=1821,0,100,100 does not fit the 1920x1200 screen');
end;

procedure TRectTests.TestARegionPastTheBottomEdgeIsRefused;
var
  Options: TRecordingOptions;
  Region: TCaptureRegion;
  Error: string;
begin
  Options := LinuxOptions('d.apng');
  Options.HasRegion := True;
  Options.Region.Left := 0;
  Options.Region.Top := 1101;
  Options.Region.Width := 100;
  Options.Region.Height := 100;
  Expect<Boolean>(ResolveLinuxCaptureRect(Options, 1920, 1200, Region,
    Error)).ToBe(False);
end;

procedure TRectTests.TestAScreenWithNoSizeIsRefused;
var
  Region: TCaptureRegion;
  Error: string;
begin
  Expect<Boolean>(ResolveLinuxCaptureRect(LinuxOptions('d.apng'), 0, 0,
    Region, Error)).ToBe(False);
  Expect<Boolean>(Error <> '').ToBe(True);
end;

procedure TRectTests.TestACanvasOverTheBudgetIsRefused;
var
  Region: TCaptureRegion;
  Error: string;
begin
  Expect<Boolean>(ResolveLinuxCaptureRect(LinuxOptions('d.apng'), 40000,
    40000, Region, Error)).ToBe(False);
  Expect<Boolean>(Error <> '').ToBe(True);
end;

{ TPacingTests }

procedure TPacingTests.SetupTests;
begin
  Test('the interval is rounded down', TestTheIntervalIsRoundedDown);
  Test('the interval never divides by zero',
    TestTheIntervalNeverDividesByZero);
  Test('deadlines sit on a fixed grid', TestDeadlinesSitOnAFixedGrid);
  Test('on-time frames drop nothing', TestOnTimeFramesDropNothing);
  Test('a late frame skips instead of bursting',
    TestALateFrameSkipsInsteadOfBursting);
  Test('early is never skipped', TestEarlyIsNeverSkipped);
  Test('a delay is rounded to the nearest millisecond',
    TestDelayIsRoundedToTheNearestMillisecond);
  Test('a delay is never zero', TestDelayIsNeverZero);
  Test('a delay fits the format''s sixteen bits',
    TestDelayFitsTheFormatsSixteenBits);
  Test('the achieved rate', TestAchievedRate);
end;

procedure TPacingTests.TestTheIntervalIsRoundedDown;
begin
  Expect<Int64>(FrameIntervalMicros(30)).ToBe(33333);
  Expect<Int64>(FrameIntervalMicros(10)).ToBe(100000);
end;

procedure TPacingTests.TestTheIntervalNeverDividesByZero;
begin
  Expect<Int64>(FrameIntervalMicros(0)).ToBe(1000000);
end;

procedure TPacingTests.TestDeadlinesSitOnAFixedGrid;
begin
  // Frame N is due at start + N * interval, not at "when the last one
  // finished + interval": lateness does not accumulate as drift.
  Expect<Int64>(FrameDeadlineMicros(5000, 100000, 0)).ToBe(5000);
  Expect<Int64>(FrameDeadlineMicros(5000, 100000, 7)).ToBe(705000);
end;

procedure TPacingTests.TestOnTimeFramesDropNothing;
var
  Dropped: Int64;
begin
  Expect<Int64>(NextFrameIndex(0, 100000, 3, 400000, Dropped)).ToBe(4);
  Expect<Int64>(Dropped).ToBe(0);
end;

procedure TPacingTests.TestALateFrameSkipsInsteadOfBursting;
var
  Dropped: Int64;
begin
  // Frame 3 was grabbed; the encoder then took until t = 1.05 s, past the
  // deadlines of frames 4..10. The next grab is frame 10 (due at 1.0 s)
  // and 6 frames (4..9) are counted as dropped, not grabbed back to back.
  Expect<Int64>(NextFrameIndex(0, 100000, 3, 1050000, Dropped)).ToBe(10);
  Expect<Int64>(Dropped).ToBe(6);
end;

procedure TPacingTests.TestEarlyIsNeverSkipped;
var
  Dropped: Int64;
begin
  Expect<Int64>(NextFrameIndex(1000, 100000, 0, 500, Dropped)).ToBe(1);
  Expect<Int64>(Dropped).ToBe(0);
  Expect<Int64>(NextFrameIndex(0, 0, 0, 500, Dropped)).ToBe(1);
  Expect<Int64>(Dropped).ToBe(0);
end;

procedure TPacingTests.TestDelayIsRoundedToTheNearestMillisecond;
begin
  Expect<Integer>(DelayMilliseconds(0, 33333)).ToBe(33);
  Expect<Integer>(DelayMilliseconds(0, 33500)).ToBe(34);
  Expect<Integer>(DelayMilliseconds(1000, 101000)).ToBe(100);
end;

procedure TPacingTests.TestDelayIsNeverZero;
begin
  Expect<Integer>(DelayMilliseconds(0, 0)).ToBe(1);
  Expect<Integer>(DelayMilliseconds(0, 400)).ToBe(1);
  Expect<Integer>(DelayMilliseconds(500, 100)).ToBe(1);
end;

procedure TPacingTests.TestDelayFitsTheFormatsSixteenBits;
begin
  Expect<Integer>(DelayMilliseconds(0, 65535000)).ToBe(65535);
  Expect<Integer>(DelayMilliseconds(0, 900000000)).ToBe(65535);
end;

procedure TPacingTests.TestAchievedRate;
begin
  Expect<Boolean>(Abs(AchievedFramesPerSecond(90, 3.0) - 30.0) < 0.0001)
    .ToBe(True);
  Expect<Boolean>(AchievedFramesPerSecond(0, 3.0) = 0).ToBe(True);
  Expect<Boolean>(AchievedFramesPerSecond(5, 0) = 0).ToBe(True);
end;

{ TTemporaryTests }

procedure TTemporaryTests.SetupTests;
begin
  Test('the temporary sits beside the target',
    TestTheTemporarySitsBesideTheTarget);
  Test('two recordings do not share a temporary',
    TestTwoRecordingsDoNotShareATemporary);
  Test('only our temporaries are recognised',
    TestOnlyOurTemporariesAreRecognised);
end;

procedure TTemporaryTests.TestTheTemporarySitsBesideTheTarget;
begin
  Expect<string>(LinuxTemporaryPath('/tmp/demo.apng', 1234, 'ab12')).ToBe(
    '/tmp/demo.apng.knips-recording-1234-ab12.tmp');
end;

procedure TTemporaryTests.TestTwoRecordingsDoNotShareATemporary;
begin
  Expect<Boolean>(LinuxTemporaryPath('d.apng', 1, 'a')
    <> LinuxTemporaryPath('d.apng', 2, 'a')).ToBe(True);
  Expect<Boolean>(LinuxTemporaryPath('d.apng', 1, 'a')
    <> LinuxTemporaryPath('d.apng', 1, 'b')).ToBe(True);
end;

procedure TTemporaryTests.TestOnlyOurTemporariesAreRecognised;
begin
  Expect<Boolean>(IsLinuxTemporaryPath(
    LinuxTemporaryPath('/tmp/demo.apng', 9, 'ff'))).ToBe(True);
  Expect<Boolean>(IsLinuxTemporaryPath('/tmp/demo.apng')).ToBe(False);
  Expect<Boolean>(IsLinuxTemporaryPath('/tmp/notes.tmp')).ToBe(False);
end;

begin
  TestRunnerProgram.AddSuite(TRefusalTests.Create(
    'what Linux refuses to record'));
  TestRunnerProgram.AddSuite(TRectTests.Create('which pixels Linux records'));
  TestRunnerProgram.AddSuite(TPacingTests.Create('how Linux paces frames'));
  TestRunnerProgram.AddSuite(TTemporaryTests.Create(
    'what a Linux take is called while it is written'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

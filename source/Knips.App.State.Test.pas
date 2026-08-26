program Knips.App.State.Test;

{$I Shared.inc}

uses
  SysUtils,

  Knips.App.State,
  Knips.Options,
  TestingPascalLibrary;

type
  TTransitionTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestIdleStartsSelectionOrDisplay;
    procedure TestIdleRejectsStop;
    procedure TestSelectingCommitsOrCancels;
    procedure TestCancelSelectionOnlyAppliesWhileSelecting;
    procedure TestRecordingStopsOrFails;
    procedure TestRejectedCommandKeepsTheState;
    procedure TestEnabledMirrorsTheTable;
  end;

  TTitleTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestIdleAndSelectingShowTheIdleGlyph;
    procedure TestRecordingShowsElapsed;
    procedure TestElapsedBelowAnHour;
    procedure TestElapsedFromAnHour;
    procedure TestNegativeElapsedReadsAsZero;
  end;

  TOutputTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestFileNameCarriesTheTimestamp;
    procedure TestDirectoryIsUnderMovies;
    procedure TestDirectoryToleratesATrailingSlash;
  end;

  TSelectionTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDragDownRight;
    procedure TestDragUpLeftNormalises;
    procedure TestClampKeepsTheRegionOnTheDisplay;
    procedure TestClampPullsANegativeOriginIn;
    procedure TestUsableNeedsTwoPointsEachWay;
  end;

  TErrorTitleTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestShortMessagesArePrefixed;
    procedure TestLongMessagesAreElided;
    procedure TestEmptyMessageStillReads;
  end;

  TCameraTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheCheckmarkFollowsTheWindow;
    procedure TestDefaultIsBottomRightOfTheVisibleFrame;
    procedure TestDefaultHonoursANonZeroScreenOrigin;
    procedure TestDefaultStaysOnATinyScreen;
    procedure TestASavedOriginOnTheScreenIsUsable;
    procedure TestAnOriginOnAVanishedScreenIsNot;
    procedure TestAMostlyOffScreenOriginIsNot;
    procedure TestAnOriginUnderTheDockIsNot;
  end;

{ TTransitionTests }

procedure TTransitionTests.SetupTests;
begin
  Test('idle accepts region and display recording',
    TestIdleStartsSelectionOrDisplay);
  Test('idle rejects stop', TestIdleRejectsStop);
  Test('selecting commits or cancels', TestSelectingCommitsOrCancels);
  Test('the menu''s cancel only applies while selecting',
    TestCancelSelectionOnlyAppliesWhileSelecting);
  Test('recording stops or fails back to idle', TestRecordingStopsOrFails);
  Test('a rejected command leaves the state alone',
    TestRejectedCommandKeepsTheState);
  Test('IsCommandEnabled mirrors the transition table',
    TestEnabledMirrorsTheTable);
end;

procedure TTransitionTests.TestIdleStartsSelectionOrDisplay;
var
  Next: TAppState;
begin
  Expect<Boolean>(NextAppState(asIdle, acRecordRegion, Next)).ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asSelecting));
  Expect<Boolean>(NextAppState(asIdle, acRecordDisplay, Next)).ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asRecording));
end;

procedure TTransitionTests.TestIdleRejectsStop;
var
  Next: TAppState;
begin
  Expect<Boolean>(NextAppState(asIdle, acStopRecording, Next)).ToBe(False);
  Expect<Boolean>(NextAppState(asIdle, acSelectionCommitted, Next)).ToBe(False);
end;

procedure TTransitionTests.TestSelectingCommitsOrCancels;
var
  Next: TAppState;
begin
  Expect<Boolean>(NextAppState(asSelecting, acSelectionCommitted, Next))
    .ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asRecording));
  Expect<Boolean>(NextAppState(asSelecting, acSelectionCancelled, Next))
    .ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asIdle));
  Expect<Boolean>(NextAppState(asSelecting, acCaptureFailed, Next)).ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asIdle));
end;

procedure TTransitionTests.TestCancelSelectionOnlyAppliesWhileSelecting;
var
  Next: TAppState;
begin
  Expect<Boolean>(NextAppState(asSelecting, acCancelSelection, Next))
    .ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asIdle));
  Expect<Boolean>(NextAppState(asIdle, acCancelSelection, Next)).ToBe(False);
  Expect<Boolean>(NextAppState(asRecording, acCancelSelection, Next))
    .ToBe(False);
  Expect<Boolean>(IsCommandEnabled(asSelecting, acCancelSelection)).ToBe(True);
  Expect<Boolean>(IsCommandEnabled(asIdle, acCancelSelection)).ToBe(False);
end;

procedure TTransitionTests.TestRecordingStopsOrFails;
var
  Next: TAppState;
begin
  Expect<Boolean>(NextAppState(asRecording, acStopRecording, Next)).ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asIdle));
  Expect<Boolean>(NextAppState(asRecording, acCaptureFailed, Next)).ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asIdle));
  Expect<Boolean>(NextAppState(asRecording, acRecordRegion, Next)).ToBe(False);
end;

procedure TTransitionTests.TestRejectedCommandKeepsTheState;
var
  Next: TAppState;
begin
  Next := asIdle;
  Expect<Boolean>(NextAppState(asRecording, acRecordDisplay, Next)).ToBe(False);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asRecording));
end;

procedure TTransitionTests.TestEnabledMirrorsTheTable;
begin
  Expect<Boolean>(IsCommandEnabled(asIdle, acStopRecording)).ToBe(False);
  Expect<Boolean>(IsCommandEnabled(asRecording, acStopRecording)).ToBe(True);
  Expect<Boolean>(IsCommandEnabled(asIdle, acRecordRegion)).ToBe(True);
  Expect<Boolean>(IsCommandEnabled(asRecording, acRecordRegion)).ToBe(False);
end;

{ TTitleTests }

procedure TTitleTests.SetupTests;
begin
  Test('idle and selecting show the idle glyph',
    TestIdleAndSelectingShowTheIdleGlyph);
  Test('recording shows the glyph and the elapsed time',
    TestRecordingShowsElapsed);
  Test('elapsed below an hour reads M:SS', TestElapsedBelowAnHour);
  Test('elapsed from an hour reads H:MM:SS', TestElapsedFromAnHour);
  Test('negative elapsed reads as 0:00', TestNegativeElapsedReadsAsZero);
end;

procedure TTitleTests.TestIdleAndSelectingShowTheIdleGlyph;
begin
  Expect<string>(StatusItemTitle(asIdle, 0)).ToBe(IdleGlyph);
  Expect<string>(StatusItemTitle(asSelecting, 12)).ToBe(IdleGlyph);
end;

procedure TTitleTests.TestRecordingShowsElapsed;
begin
  Expect<string>(StatusItemTitle(asRecording, 7))
    .ToBe(RecordingGlyph + ' 0:07');
end;

procedure TTitleTests.TestElapsedBelowAnHour;
begin
  Expect<string>(FormatElapsed(0)).ToBe('0:00');
  Expect<string>(FormatElapsed(59)).ToBe('0:59');
  Expect<string>(FormatElapsed(60)).ToBe('1:00');
  Expect<string>(FormatElapsed(3599)).ToBe('59:59');
end;

procedure TTitleTests.TestElapsedFromAnHour;
begin
  Expect<string>(FormatElapsed(3600)).ToBe('1:00:00');
  Expect<string>(FormatElapsed(3661)).ToBe('1:01:01');
end;

procedure TTitleTests.TestNegativeElapsedReadsAsZero;
begin
  Expect<string>(FormatElapsed(-5)).ToBe('0:00');
end;

{ TOutputTests }

procedure TOutputTests.SetupTests;
begin
  Test('the file name carries a sortable timestamp',
    TestFileNameCarriesTheTimestamp);
  Test('recordings live under ~/Movies/knips', TestDirectoryIsUnderMovies);
  Test('a home directory with a trailing slash is not doubled',
    TestDirectoryToleratesATrailingSlash);
end;

procedure TOutputTests.TestFileNameCarriesTheTimestamp;
begin
  Expect<string>(RecordingFileName(EncodeDate(2026, 8, 26)
    + EncodeTime(14, 5, 9, 0))).ToBe('knips-20260826-140509.mp4');
end;

procedure TOutputTests.TestDirectoryIsUnderMovies;
begin
  Expect<string>(RecordingsDirectory('/Users/x'))
    .ToBe('/Users/x' + PathDelim + 'Movies' + PathDelim + 'knips'
    + PathDelim);
end;

procedure TOutputTests.TestDirectoryToleratesATrailingSlash;
begin
  Expect<string>(RecordingsDirectory('/Users/x' + PathDelim))
    .ToBe(RecordingsDirectory('/Users/x'));
end;

{ TSelectionTests }

procedure TSelectionTests.SetupTests;
begin
  Test('a drag down and right keeps the anchor as the origin',
    TestDragDownRight);
  Test('a drag up and left is normalised', TestDragUpLeftNormalises);
  Test('clamping keeps the region on the display',
    TestClampKeepsTheRegionOnTheDisplay);
  Test('clamping pulls a negative origin in',
    TestClampPullsANegativeOriginIn);
  Test('a region below the alignment is not usable',
    TestUsableNeedsTwoPointsEachWay);
end;

procedure TSelectionTests.TestDragDownRight;
var
  Region: TCaptureRegion;
begin
  Region := NormalizeSelection(10, 20, 110, 220);
  Expect<Integer>(Region.Left).ToBe(10);
  Expect<Integer>(Region.Top).ToBe(20);
  Expect<Integer>(Region.Width).ToBe(100);
  Expect<Integer>(Region.Height).ToBe(200);
end;

procedure TSelectionTests.TestDragUpLeftNormalises;
var
  Region: TCaptureRegion;
begin
  Region := NormalizeSelection(110, 220, 10, 20);
  Expect<Integer>(Region.Left).ToBe(10);
  Expect<Integer>(Region.Top).ToBe(20);
  Expect<Integer>(Region.Width).ToBe(100);
  Expect<Integer>(Region.Height).ToBe(200);
end;

procedure TSelectionTests.TestClampKeepsTheRegionOnTheDisplay;
var
  Region: TCaptureRegion;
begin
  Region := ClampSelection(NormalizeSelection(1000, 500, 2000, 1500),
    1440, 900);
  Expect<Integer>(Region.Left).ToBe(1000);
  Expect<Integer>(Region.Top).ToBe(500);
  Expect<Integer>(Region.Width).ToBe(440);
  Expect<Integer>(Region.Height).ToBe(400);
end;

procedure TSelectionTests.TestClampPullsANegativeOriginIn;
var
  Region: TCaptureRegion;
begin
  Region := ClampSelection(NormalizeSelection(-40, -10, 60, 90), 1440, 900);
  Expect<Integer>(Region.Left).ToBe(0);
  Expect<Integer>(Region.Top).ToBe(0);
  Expect<Integer>(Region.Width).ToBe(60);
  Expect<Integer>(Region.Height).ToBe(90);
end;

procedure TSelectionTests.TestUsableNeedsTwoPointsEachWay;
begin
  Expect<Boolean>(IsSelectionUsable(NormalizeSelection(10, 10, 10, 10)))
    .ToBe(False);
  Expect<Boolean>(IsSelectionUsable(NormalizeSelection(10, 10, 11, 40)))
    .ToBe(False);
  Expect<Boolean>(IsSelectionUsable(NormalizeSelection(10, 10, 40, 40)))
    .ToBe(True);
end;

{ TErrorTitleTests }

procedure TErrorTitleTests.SetupTests;
begin
  Test('a short message is prefixed', TestShortMessagesArePrefixed);
  Test('a long message is elided', TestLongMessagesAreElided);
  Test('an empty message still reads', TestEmptyMessageStillReads);
end;

procedure TErrorTitleTests.TestShortMessagesArePrefixed;
begin
  Expect<string>(ErrorMenuTitle('no permission'))
    .ToBe(ErrorTitlePrefix + 'no permission');
end;

procedure TErrorTitleTests.TestLongMessagesAreElided;
var
  Title: string;
begin
  Title := ErrorMenuTitle(StringOfChar('x', MaxErrorTitleLength + 40));
  Expect<Boolean>(Length(Title) < MaxErrorTitleLength
    + Length(ErrorTitlePrefix) + 4).ToBe(True);
  Expect<Boolean>(Pos(ErrorTitlePrefix, Title) = 1).ToBe(True);
end;

procedure TErrorTitleTests.TestEmptyMessageStillReads;
begin
  Expect<string>(ErrorMenuTitle('   ')).ToBe(ErrorTitlePrefix
    + 'unknown error');
end;

{ TCameraTests }

procedure TCameraTests.SetupTests;
begin
  Test('the camera item''s checkmark follows the window',
    TestTheCheckmarkFollowsTheWindow);
  Test('the default origin is the visible frame''s bottom right',
    TestDefaultIsBottomRightOfTheVisibleFrame);
  Test('the default origin honours a secondary screen''s origin',
    TestDefaultHonoursANonZeroScreenOrigin);
  Test('the default origin stays on a screen smaller than the window',
    TestDefaultStaysOnATinyScreen);
  Test('a saved origin on an attached screen is kept',
    TestASavedOriginOnTheScreenIsUsable);
  Test('a saved origin from a vanished screen is rejected',
    TestAnOriginOnAVanishedScreenIsNot);
  Test('a saved origin with only a sliver on screen is rejected',
    TestAMostlyOffScreenOriginIsNot);
  Test('a saved origin that would restore under the Dock is rejected',
    TestAnOriginUnderTheDockIsNot);
end;

procedure TCameraTests.TestTheCheckmarkFollowsTheWindow;
begin
  Expect<Integer>(CameraMenuState(False)).ToBe(MenuItemStateOff);
  Expect<Integer>(CameraMenuState(True)).ToBe(MenuItemStateOn);
  // The title never flips; the checkmark is the whole signal.
  Expect<string>(CameraMenuTitle).ToBe('Camera');
end;

procedure TCameraTests.TestDefaultIsBottomRightOfTheVisibleFrame;
var
  Origin: TCameraOrigin;
begin
  // A 1440x900 screen whose visible frame excludes a 25 pt menu bar.
  Origin := DefaultCameraOrigin(0, 0, 1440, 875);
  Expect<Double>(Origin.X)
    .ToBe(1440 - CameraWindowWidth - CameraWindowMargin);
  Expect<Double>(Origin.Y).ToBe(CameraWindowMargin);
end;

procedure TCameraTests.TestDefaultHonoursANonZeroScreenOrigin;
var
  Origin: TCameraOrigin;
begin
  // A display to the right of the main one starts at x = 1440.
  Origin := DefaultCameraOrigin(1440, -200, 1920, 1080);
  Expect<Double>(Origin.X)
    .ToBe(1440 + 1920 - CameraWindowWidth - CameraWindowMargin);
  Expect<Double>(Origin.Y).ToBe(-200 + CameraWindowMargin);
end;

procedure TCameraTests.TestDefaultStaysOnATinyScreen;
var
  Origin: TCameraOrigin;
begin
  Origin := DefaultCameraOrigin(0, 0, CameraWindowWidth div 2,
    CameraWindowHeight div 2);
  Expect<Double>(Origin.X).ToBe(0);
  Expect<Double>(Origin.Y).ToBe(0);
end;

procedure TCameraTests.TestASavedOriginOnTheScreenIsUsable;
var
  Origin: TCameraOrigin;
begin
  Origin.X := 100;
  Origin.Y := 100;
  Expect<Boolean>(IsCameraOriginUsable(Origin, 0, 0, 1440, 900)).ToBe(True);
end;

procedure TCameraTests.TestAnOriginOnAVanishedScreenIsNot;
var
  Origin: TCameraOrigin;
begin
  // Saved while a second display sat to the right; that display is gone.
  Origin.X := 2000;
  Origin.Y := 400;
  Expect<Boolean>(IsCameraOriginUsable(Origin, 0, 0, 1440, 900)).ToBe(False);
end;

procedure TCameraTests.TestAMostlyOffScreenOriginIsNot;
var
  Origin: TCameraOrigin;
begin
  // Only MinVisibleCameraExtent - 1 points of width remain on screen.
  Origin.X := 1440 - (MinVisibleCameraExtent - 1);
  Origin.Y := 100;
  Expect<Boolean>(IsCameraOriginUsable(Origin, 0, 0, 1440, 900)).ToBe(False);
  Origin.X := 1440 - MinVisibleCameraExtent;
  Expect<Boolean>(IsCameraOriginUsable(Origin, 0, 0, 1440, 900)).ToBe(True);
end;

// The reason the caller passes visibleFrame and not frame: the camera
// window floats at level 3 and the Dock sits at 20, so a position the
// Dock now covers is unreachable — the user could neither see nor drag
// it. Judged against the full frame the same origin looks fine.
procedure TCameraTests.TestAnOriginUnderTheDockIsNot;
var
  Origin: TCameraOrigin;
begin
  Origin.X := 100;
  Origin.Y := -100;
  Expect<Boolean>(IsCameraOriginUsable(Origin, 0, 0, 1440, 900)).ToBe(True);
  // Same screen with a 70 pt Dock along the bottom.
  Expect<Boolean>(IsCameraOriginUsable(Origin, 0, 70, 1440, 805)).ToBe(False);
end;

begin
  TestRunnerProgram.AddSuite(TTransitionTests.Create('NextAppState'));
  TestRunnerProgram.AddSuite(TTitleTests.Create('StatusItemTitle'));
  TestRunnerProgram.AddSuite(TOutputTests.Create('recording output paths'));
  TestRunnerProgram.AddSuite(TSelectionTests.Create('selection geometry'));
  TestRunnerProgram.AddSuite(TErrorTitleTests.Create('ErrorMenuTitle'));
  TestRunnerProgram.AddSuite(TCameraTests.Create('camera window placement'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

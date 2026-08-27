program Knips.App.State.Test;

{$I Knips.inc}

uses
  StrUtils,
  SysUtils,

  Knips.App.State,
  Knips.Options,
  TestingPascalLibrary;

type
  TTransitionTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestIdleStartsSelectionOrDisplay;
    procedure TestIdleStartsWindowOrLastRegion;
    procedure TestSystemAudioTogglesOnlyWhileIdle;
    procedure TestLiveEffectsToggleOnlyWhileIdle;
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
    procedure TestStoredRegionSurvivesARoundTrip;
    procedure TestStoredNegativeOriginIsPulledIn;
    procedure TestStoredNonsenseIsRejected;
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
    procedure TestTheCircleIsJudgedBySquareSize;
  end;

  TCameraShapeTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheCircleIsASquareWindow;
    procedure TestTheCircleRadiusIsHalfTheSide;
    procedure TestTheCheckmarkNamesTheCircle;
    procedure TestAStoredShapeSurvivesARoundTrip;
    procedure TestStoredNonsenseReadsAsTheRectangle;
    procedure TestASizeChangeKeepsTheCentre;
    procedure TestAResizedWindowIsClampedOntoTheScreen;
    procedure TestAWindowBiggerThanTheFrameSitsAtItsOrigin;
  end;

  TCameraSnapTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEachCornerAttractsItsOwnQuadrant;
    procedure TestTheMarginIsTheInset;
    procedure TestASmallFrameCollapsesToItsOrigin;
    procedure TestTheCircleSnapsByItsOwnSize;
    procedure TestTheMidpointBreaksToTheLowEdge;
    procedure TestAClickIsNotADrag;
    procedure TestTheEaseStartsAndLandsExactly;
    procedure TestTheEaseIsMonotonicAndSlowAtBothEnds;
    procedure TestADegenerateStepCountArrives;
  end;

  TCameraDockTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestARegionFlipsIntoScreenSpace;
    procedure TestARegionOnASecondScreenFlipsToo;
    procedure TestTheDockCornerIsInsideTheRegion;
    procedure TestATinyRegionDocksAsFarInAsItFits;
    procedure TestTheInsetMatchesTheSnapCorner;
    procedure TestAnInsetTooBigForTheRectLeavesItAlone;
  end;

  TExportTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestGifPathSitsBesideTheRecording;
    procedure TestGifPathNeverOverwritesTheMovie;
    procedure TestGifPathOfNothingIsNothing;
    procedure TestWidthKeepsSmallRecordings;
    procedure TestWidthIsThePointSizeOfARetinaRecording;
    procedure TestWidthDeclinesWhatTheExporterWouldReject;
    procedure TestPercentSpansBothPasses;
    procedure TestPercentSurvivesABadTotal;
    procedure TestProgressTitleClamps;
  end;

  TWindowMenuTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTitleJoinsApplicationAndWindow;
    procedure TestTitleFallsBackToWhatThereIs;
    procedure TestTitleIsElided;
    procedure TestElisionKeepsUtf8Whole;
    procedure TestOrdinaryWindowIsRecordable;
    procedure TestOffScreenAndOtherLayersAreSkipped;
    procedure TestTinyAndUntitledWindowsAreSkipped;
    procedure TestOurOwnWindowsAreSkipped;
  end;

{ TTransitionTests }

procedure TTransitionTests.SetupTests;
begin
  Test('idle accepts region and display recording',
    TestIdleStartsSelectionOrDisplay);
  Test('idle accepts a window and a repeat of the last region',
    TestIdleStartsWindowOrLastRegion);
  Test('the system-audio checkbox only toggles while idle',
    TestSystemAudioTogglesOnlyWhileIdle);
  Test('the two live-effect checkboxes only toggle while idle',
    TestLiveEffectsToggleOnlyWhileIdle);
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

procedure TTransitionTests.TestIdleStartsWindowOrLastRegion;
var
  Next: TAppState;
begin
  Expect<Boolean>(NextAppState(asIdle, acRecordWindow, Next)).ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asRecording));
  Expect<Boolean>(NextAppState(asIdle, acRecordLastRegion, Next)).ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asRecording));
  // Neither is a way out of a recording or a selection.
  Expect<Boolean>(NextAppState(asRecording, acRecordWindow, Next)).ToBe(False);
  Expect<Boolean>(NextAppState(asSelecting, acRecordLastRegion, Next))
    .ToBe(False);
end;

// The stream configuration is fixed once the capture has started, so the
// checkbox is a legal command in exactly one state — and it leaves that
// state where it found it.
procedure TTransitionTests.TestSystemAudioTogglesOnlyWhileIdle;
var
  Next: TAppState;
begin
  Next := asRecording;
  Expect<Boolean>(NextAppState(asIdle, acToggleSystemAudio, Next)).ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asIdle));
  Expect<Boolean>(NextAppState(asRecording, acToggleSystemAudio, Next))
    .ToBe(False);
  Expect<Boolean>(NextAppState(asSelecting, acToggleSystemAudio, Next))
    .ToBe(False);
  Expect<Boolean>(IsCommandEnabled(asIdle, acToggleSystemAudio)).ToBe(True);
  Expect<Boolean>(IsCommandEnabled(asRecording, acToggleSystemAudio))
    .ToBe(False);
end;

// Zoom on Click and Follow Mouse move the stream's sourceRect, which only
// exists because the capture was *started* with one. That is settled when
// the recording begins, so like the audio checkbox they are legal in
// exactly one state and leave it where they found it.
procedure TTransitionTests.TestLiveEffectsToggleOnlyWhileIdle;
var
  Next: TAppState;
begin
  Next := asRecording;
  Expect<Boolean>(NextAppState(asIdle, acToggleZoomOnClick, Next)).ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asIdle));
  Expect<Boolean>(NextAppState(asIdle, acToggleFollowMouse, Next)).ToBe(True);
  Expect<Integer>(Ord(Next)).ToBe(Ord(asIdle));
  Expect<Boolean>(NextAppState(asRecording, acToggleZoomOnClick, Next))
    .ToBe(False);
  Expect<Boolean>(NextAppState(asRecording, acToggleFollowMouse, Next))
    .ToBe(False);
  Expect<Boolean>(NextAppState(asSelecting, acToggleZoomOnClick, Next))
    .ToBe(False);
  Expect<Boolean>(NextAppState(asSelecting, acToggleFollowMouse, Next))
    .ToBe(False);
  Expect<Boolean>(IsCommandEnabled(asIdle, acToggleZoomOnClick)).ToBe(True);
  Expect<Boolean>(IsCommandEnabled(asIdle, acToggleFollowMouse)).ToBe(True);
  Expect<Boolean>(IsCommandEnabled(asRecording, acToggleFollowMouse))
    .ToBe(False);
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
  Test('a stored region survives a round trip unchanged',
    TestStoredRegionSurvivesARoundTrip);
  Test('a stored negative origin is pulled in',
    TestStoredNegativeOriginIsPulledIn);
  Test('stored nonsense is rejected outright', TestStoredNonsenseIsRejected);
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

function StoredRegion(ALeft, ATop, AWidth, AHeight: Integer): TCaptureRegion;
begin
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Width := AWidth;
  Result.Height := AHeight;
end;

procedure TSelectionTests.TestStoredRegionSurvivesARoundTrip;
var
  Region: TCaptureRegion;
begin
  Expect<Boolean>(SanitizeStoredRegion(StoredRegion(100, 200, 640, 480),
    Region)).ToBe(True);
  Expect<Integer>(Region.Left).ToBe(100);
  Expect<Integer>(Region.Top).ToBe(200);
  Expect<Integer>(Region.Width).ToBe(640);
  Expect<Integer>(Region.Height).ToBe(480);
end;

// `defaults write knips KnipsLastRegionLeft -- -500` must not reach
// ScreenCaptureKit's sourceRect.
procedure TSelectionTests.TestStoredNegativeOriginIsPulledIn;
var
  Region: TCaptureRegion;
begin
  Expect<Boolean>(SanitizeStoredRegion(StoredRegion(-40, -10, 640, 480),
    Region)).ToBe(True);
  Expect<Integer>(Region.Left).ToBe(0);
  Expect<Integer>(Region.Top).ToBe(0);
  Expect<Integer>(Region.Width).ToBe(600);
  Expect<Integer>(Region.Height).ToBe(470);
end;

procedure TSelectionTests.TestStoredNonsenseIsRejected;
var
  Region: TCaptureRegion;
begin
  // Nothing written at all.
  Expect<Boolean>(SanitizeStoredRegion(StoredRegion(0, 0, 0, 0), Region))
    .ToBe(False);
  // An origin so negative the region is consumed entirely.
  Expect<Boolean>(SanitizeStoredRegion(StoredRegion(-800, 0, 640, 480),
    Region)).ToBe(False);
  Expect<Integer>(Region.Width).ToBe(0);
  // Absurd extents, and absurd origins.
  Expect<Boolean>(SanitizeStoredRegion(StoredRegion(0, 0,
    MaxStoredRegionExtent + 1, 480), Region)).ToBe(False);
  Expect<Boolean>(SanitizeStoredRegion(StoredRegion(
    MaxStoredRegionExtent + 1, 0, 640, 480), Region)).ToBe(False);
  // Too small to align to anything, exactly as a stray click is.
  Expect<Boolean>(SanitizeStoredRegion(StoredRegion(10, 10, 1, 1), Region))
    .ToBe(False);
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
  Test('a circular camera''s origin is judged by its own square size',
    TestTheCircleIsJudgedBySquareSize);
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
  Origin := DefaultCameraOrigin(CameraWindowSize(csRectangle),
    CameraRect(0, 0, 1440, 875));
  Expect<Double>(Origin.X)
    .ToBe(1440 - CameraWindowWidth - CameraWindowMargin);
  Expect<Double>(Origin.Y).ToBe(CameraWindowMargin);
end;

procedure TCameraTests.TestDefaultHonoursANonZeroScreenOrigin;
var
  Origin: TCameraOrigin;
begin
  // A display to the right of the main one starts at x = 1440.
  Origin := DefaultCameraOrigin(CameraWindowSize(csRectangle),
    CameraRect(1440, -200, 1920, 1080));
  Expect<Double>(Origin.X)
    .ToBe(1440 + 1920 - CameraWindowWidth - CameraWindowMargin);
  Expect<Double>(Origin.Y).ToBe(-200 + CameraWindowMargin);
end;

procedure TCameraTests.TestDefaultStaysOnATinyScreen;
var
  Origin: TCameraOrigin;
begin
  Origin := DefaultCameraOrigin(CameraWindowSize(csRectangle),
    CameraRect(0, 0, CameraWindowWidth div 2, CameraWindowHeight div 2));
  Expect<Double>(Origin.X).ToBe(0);
  Expect<Double>(Origin.Y).ToBe(0);
end;

procedure TCameraTests.TestASavedOriginOnTheScreenIsUsable;
var
  Origin: TCameraOrigin;
begin
  Origin.X := 100;
  Origin.Y := 100;
  Expect<Boolean>(IsCameraOriginUsable(Origin,
    CameraWindowSize(csRectangle), CameraRect(0, 0, 1440, 900))).ToBe(True);
end;

procedure TCameraTests.TestAnOriginOnAVanishedScreenIsNot;
var
  Origin: TCameraOrigin;
begin
  // Saved while a second display sat to the right; that display is gone.
  Origin.X := 2000;
  Origin.Y := 400;
  Expect<Boolean>(IsCameraOriginUsable(Origin,
    CameraWindowSize(csRectangle), CameraRect(0, 0, 1440, 900))).ToBe(False);
end;

procedure TCameraTests.TestAMostlyOffScreenOriginIsNot;
var
  Origin: TCameraOrigin;
  Screen: TCameraRect;
begin
  Screen := CameraRect(0, 0, 1440, 900);
  // Only MinVisibleCameraExtent - 1 points of width remain on screen.
  Origin.X := 1440 - (MinVisibleCameraExtent - 1);
  Origin.Y := 100;
  Expect<Boolean>(IsCameraOriginUsable(Origin,
    CameraWindowSize(csRectangle), Screen)).ToBe(False);
  Origin.X := 1440 - MinVisibleCameraExtent;
  Expect<Boolean>(IsCameraOriginUsable(Origin,
    CameraWindowSize(csRectangle), Screen)).ToBe(True);
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
  Expect<Boolean>(IsCameraOriginUsable(Origin,
    CameraWindowSize(csRectangle), CameraRect(0, 0, 1440, 900))).ToBe(True);
  // Same screen with a 70 pt Dock along the bottom.
  Expect<Boolean>(IsCameraOriginUsable(Origin,
    CameraWindowSize(csRectangle), CameraRect(0, 70, 1440, 805))).ToBe(False);
end;

// The size is a parameter precisely because the circle is 60 points
// narrower: an origin that leaves a usable sliver of the rectangle on
// screen can leave nothing at all of the circle.
procedure TCameraTests.TestTheCircleIsJudgedBySquareSize;
var
  Origin: TCameraOrigin;
  Screen: TCameraRect;
begin
  Screen := CameraRect(0, 0, 1440, 900);
  // The rectangle's left edge is 60 points further left than the
  // circle's for the same origin, so at this x the rectangle still has
  // MinVisibleCameraExtent on screen and the circle has none.
  Origin.X := 1440 - CameraWindowWidth + (CameraWindowWidth
    - CameraCircleSide);
  Origin.Y := 100;
  Expect<Boolean>(IsCameraOriginUsable(Origin,
    CameraWindowSize(csRectangle), Screen)).ToBe(True);
  Origin.X := 1440 - MinVisibleCameraExtent + 1;
  Expect<Boolean>(IsCameraOriginUsable(Origin,
    CameraWindowSize(csCircle), Screen)).ToBe(False);
  Origin.X := 1440 - MinVisibleCameraExtent;
  Expect<Boolean>(IsCameraOriginUsable(Origin,
    CameraWindowSize(csCircle), Screen)).ToBe(True);
  // And the vertical extent is the circle's, not the rectangle's: a
  // window whose top 40 points are on screen passes either way, but the
  // origin that puts them there differs by the height difference — zero
  // here, since both are 180 tall, which is worth pinning down.
  Expect<Double>(CameraWindowSize(csCircle).Height)
    .ToBe(CameraWindowSize(csRectangle).Height);
end;

{ TCameraShapeTests }

procedure TCameraShapeTests.SetupTests;
begin
  Test('the circular camera is a square window',
    TestTheCircleIsASquareWindow);
  Test('the circle''s corner radius is half its side',
    TestTheCircleRadiusIsHalfTheSide);
  Test('the shape item''s checkmark names the circle',
    TestTheCheckmarkNamesTheCircle);
  Test('a stored shape survives a round trip',
    TestAStoredShapeSurvivesARoundTrip);
  Test('a stored value that is not a shape reads as the rectangle',
    TestStoredNonsenseReadsAsTheRectangle);
  Test('changing shape keeps the window''s centre',
    TestASizeChangeKeepsTheCentre);
  Test('a shape change that would leave the screen is clamped back on',
    TestAResizedWindowIsClampedOntoTheScreen);
  Test('a window larger than the frame sits at the frame''s origin',
    TestAWindowBiggerThanTheFrameSitsAtItsOrigin);
end;

procedure TCameraShapeTests.TestTheCircleIsASquareWindow;
var
  Circle, Rectangle: TCameraSize;
begin
  Rectangle := CameraWindowSize(csRectangle);
  Expect<Double>(Rectangle.Width).ToBe(CameraWindowWidth);
  Expect<Double>(Rectangle.Height).ToBe(CameraWindowHeight);
  // Square, or the disc would be an ellipse.
  Circle := CameraWindowSize(csCircle);
  Expect<Double>(Circle.Width).ToBe(Circle.Height);
  // And the same height as the rectangle, so the switch reads as a crop.
  Expect<Double>(Circle.Height).ToBe(CameraWindowHeight);
end;

procedure TCameraShapeTests.TestTheCircleRadiusIsHalfTheSide;
begin
  Expect<Double>(CameraCornerRadiusForShape(csRectangle))
    .ToBe(CameraCornerRadius);
  Expect<Double>(CameraCornerRadiusForShape(csCircle))
    .ToBe(CameraCircleSide / 2);
end;

procedure TCameraShapeTests.TestTheCheckmarkNamesTheCircle;
begin
  Expect<Integer>(CameraShapeMenuState(csRectangle)).ToBe(MenuItemStateOff);
  Expect<Integer>(CameraShapeMenuState(csCircle)).ToBe(MenuItemStateOn);
  Expect<string>(CircularCameraMenuTitle).ToBe('Circular Camera');
end;

procedure TCameraShapeTests.TestAStoredShapeSurvivesARoundTrip;
begin
  Expect<Boolean>(CameraShapeFromStored(StoredCameraShape(csRectangle))
    = csRectangle).ToBe(True);
  Expect<Boolean>(CameraShapeFromStored(StoredCameraShape(csCircle))
    = csCircle).ToBe(True);
end;

// `defaults write KnipsCameraShape 47` is a thing a user can do, and a
// never-written key reads back as 0.
procedure TCameraShapeTests.TestStoredNonsenseReadsAsTheRectangle;
begin
  Expect<Boolean>(CameraShapeFromStored(0) = csRectangle).ToBe(True);
  Expect<Boolean>(CameraShapeFromStored(47) = csRectangle).ToBe(True);
  Expect<Boolean>(CameraShapeFromStored(-1) = csRectangle).ToBe(True);
end;

procedure TCameraShapeTests.TestASizeChangeKeepsTheCentre;
var
  Origin, Moved: TCameraOrigin;
begin
  Origin.X := 500;
  Origin.Y := 300;
  Moved := RecenteredCameraOrigin(Origin, CameraWindowSize(csRectangle),
    CameraWindowSize(csCircle));
  // 240 -> 180 on the width, so the origin moves right by half the loss;
  // the height does not change, so neither does y.
  Expect<Double>(Moved.X).ToBe(500 + (CameraWindowWidth - CameraCircleSide)
    / 2);
  Expect<Double>(Moved.Y).ToBe(300);
  // And the centre is where it was, which is the point of the exercise.
  Expect<Double>(Moved.X + CameraCircleSide / 2)
    .ToBe(500 + CameraWindowWidth / 2);
end;

procedure TCameraShapeTests.TestAResizedWindowIsClampedOntoTheScreen;
var
  Origin, Clamped: TCameraOrigin;
  Screen: TCameraRect;
begin
  Screen := CameraRect(0, 0, 1440, 875);
  // A rectangle hard against the right edge, grown back from a circle:
  // the recentred origin would hang 30 points off the screen.
  Origin.X := 1440 - CameraWindowWidth + 30;
  Origin.Y := -10;
  Clamped := ClampCameraOrigin(Origin, CameraWindowSize(csRectangle),
    Screen);
  Expect<Double>(Clamped.X).ToBe(1440 - CameraWindowWidth);
  Expect<Double>(Clamped.Y).ToBe(0);
end;

procedure TCameraShapeTests.TestAWindowBiggerThanTheFrameSitsAtItsOrigin;
var
  Origin, Clamped: TCameraOrigin;
begin
  Origin.X := 900;
  Origin.Y := 900;
  Clamped := ClampCameraOrigin(Origin, CameraWindowSize(csRectangle),
    CameraRect(100, 50, 120, 90));
  Expect<Double>(Clamped.X).ToBe(100);
  Expect<Double>(Clamped.Y).ToBe(50);
end;

{ TCameraSnapTests }

procedure TCameraSnapTests.SetupTests;
begin
  Test('a drop in each quadrant snaps to that quadrant''s corner',
    TestEachCornerAttractsItsOwnQuadrant);
  Test('the snapped window is inset by the margin', TestTheMarginIsTheInset);
  Test('a frame with no room for the margins collapses to its origin',
    TestASmallFrameCollapsesToItsOrigin);
  Test('the circle snaps by its own square size',
    TestTheCircleSnapsByItsOwnSize);
  Test('a drop exactly between two corners breaks to the low edge',
    TestTheMidpointBreaksToTheLowEdge);
  Test('a click is not a drag', TestAClickIsNotADrag);
  Test('the ease starts at the origin and lands on the corner exactly',
    TestTheEaseStartsAndLandsExactly);
  Test('the ease only moves forwards and is slow at both ends',
    TestTheEaseIsMonotonicAndSlowAtBothEnds);
  Test('a degenerate step count arrives rather than dividing by zero',
    TestADegenerateStepCountArrives);
end;

// The four corners form a 2x2 grid, so nearest-corner separates into
// nearer-edge per axis; these are the four quadrants of a 1440x875
// visible frame.
procedure TCameraSnapTests.TestEachCornerAttractsItsOwnQuadrant;
var
  Screen: TCameraRect;
  Size: TCameraSize;
  Dropped, Snapped: TCameraOrigin;
  Left, Right, Bottom, Top: Double;
begin
  Screen := CameraRect(0, 0, 1440, 875);
  Size := CameraWindowSize(csRectangle);
  Left := CameraWindowMargin;
  Right := 1440 - CameraWindowWidth - CameraWindowMargin;
  Bottom := CameraWindowMargin;
  Top := 875 - CameraWindowHeight - CameraWindowMargin;

  Dropped.X := 60;
  Dropped.Y := 60;
  Snapped := NearestCameraCorner(Dropped, Size, Screen, CameraWindowMargin);
  Expect<Double>(Snapped.X).ToBe(Left);
  Expect<Double>(Snapped.Y).ToBe(Bottom);

  Dropped.X := 1100;
  Dropped.Y := 60;
  Snapped := NearestCameraCorner(Dropped, Size, Screen, CameraWindowMargin);
  Expect<Double>(Snapped.X).ToBe(Right);
  Expect<Double>(Snapped.Y).ToBe(Bottom);

  Dropped.X := 60;
  Dropped.Y := 700;
  Snapped := NearestCameraCorner(Dropped, Size, Screen, CameraWindowMargin);
  Expect<Double>(Snapped.X).ToBe(Left);
  Expect<Double>(Snapped.Y).ToBe(Top);

  Dropped.X := 1100;
  Dropped.Y := 700;
  Snapped := NearestCameraCorner(Dropped, Size, Screen, CameraWindowMargin);
  Expect<Double>(Snapped.X).ToBe(Right);
  Expect<Double>(Snapped.Y).ToBe(Top);
end;

// And the corner it lands on is the one the very first placement used,
// which is what stops the camera moving on its own the first time it is
// dragged and dropped where it already was.
procedure TCameraSnapTests.TestTheMarginIsTheInset;
var
  Screen: TCameraRect;
  Size: TCameraSize;
  Default_, Snapped: TCameraOrigin;
begin
  Screen := CameraRect(1440, -200, 1920, 1080);
  Size := CameraWindowSize(csRectangle);
  Default_ := DefaultCameraOrigin(Size, Screen);
  Snapped := NearestCameraCorner(Default_, Size, Screen, CameraWindowMargin);
  Expect<Double>(Snapped.X).ToBe(Default_.X);
  Expect<Double>(Snapped.Y).ToBe(Default_.Y);
end;

procedure TCameraSnapTests.TestASmallFrameCollapsesToItsOrigin;
var
  Dropped, Snapped: TCameraOrigin;
begin
  Dropped.X := 5000;
  Dropped.Y := 5000;
  // A region smaller than the camera window: every corner is the same
  // corner, and it is the region's own origin.
  Snapped := NearestCameraCorner(Dropped, CameraWindowSize(csRectangle),
    CameraRect(300, 400, 200, 150), CameraWindowMargin);
  Expect<Double>(Snapped.X).ToBe(300);
  Expect<Double>(Snapped.Y).ToBe(400);
end;

procedure TCameraSnapTests.TestTheCircleSnapsByItsOwnSize;
var
  Dropped, Snapped: TCameraOrigin;
begin
  Dropped.X := 1300;
  Dropped.Y := 800;
  Snapped := NearestCameraCorner(Dropped, CameraWindowSize(csCircle),
    CameraRect(0, 0, 1440, 875), CameraWindowMargin);
  // The square window is 60 points narrower, so its top-right origin sits
  // 60 points further right than the rectangle's would.
  Expect<Double>(Snapped.X)
    .ToBe(1440 - CameraCircleSide - CameraWindowMargin);
  Expect<Double>(Snapped.Y).ToBe(875 - CameraCircleSide - CameraWindowMargin);
end;

// The tie has to break somewhere, and it breaks low — left and bottom.
// Only an origin at the exact midpoint of the two insets can hit it, so
// this is documentation as much as a test.
procedure TCameraSnapTests.TestTheMidpointBreaksToTheLowEdge;
var
  Dropped, Snapped: TCameraOrigin;
  Low, High: Double;
begin
  Low := CameraWindowMargin;
  High := 1440 - CameraWindowWidth - CameraWindowMargin;
  Dropped.X := (Low + High) / 2;
  Dropped.Y := (CameraWindowMargin
    + (875 - CameraWindowHeight - CameraWindowMargin)) / 2;
  Snapped := NearestCameraCorner(Dropped, CameraWindowSize(csRectangle),
    CameraRect(0, 0, 1440, 875), CameraWindowMargin);
  Expect<Double>(Snapped.X).ToBe(Low);
  Expect<Double>(Snapped.Y).ToBe(CameraWindowMargin);
end;

// Without this a bare click on the picture flings the window into a
// corner — including a corner a shape change deliberately moved it away
// from a moment earlier.
procedure TCameraSnapTests.TestAClickIsNotADrag;
var
  Start, Ended: TCameraOrigin;
begin
  Start.X := 500;
  Start.Y := 300;
  Ended := Start;
  Expect<Boolean>(IsCameraDragMovement(Start, Ended)).ToBe(False);
  // A jitter under the threshold on both axes is still a click.
  Ended.X := Start.X + CameraDragThreshold - 1;
  Ended.Y := Start.Y - (CameraDragThreshold - 1);
  Expect<Boolean>(IsCameraDragMovement(Start, Ended)).ToBe(False);
  // One axis reaching it is enough: a purely horizontal nudge is a drag.
  Ended.X := Start.X + CameraDragThreshold;
  Ended.Y := Start.Y;
  Expect<Boolean>(IsCameraDragMovement(Start, Ended)).ToBe(True);
  Ended.X := Start.X;
  Ended.Y := Start.Y - CameraDragThreshold;
  Expect<Boolean>(IsCameraDragMovement(Start, Ended)).ToBe(True);
end;

procedure TCameraSnapTests.TestTheEaseStartsAndLandsExactly;
var
  From_, Target, Step: TCameraOrigin;
begin
  From_.X := 100;
  From_.Y := 200;
  Target.X := 1176;
  Target.Y := 24;
  Step := CameraSnapOrigin(From_, Target, 0, CameraSnapSteps);
  Expect<Double>(Step.X).ToBe(From_.X);
  Expect<Double>(Step.Y).ToBe(From_.Y);
  // Exactly, not nearly: the ease has to land on the corner, or the
  // window ends up a fraction of a point out of position for ever.
  Step := CameraSnapOrigin(From_, Target, CameraSnapSteps, CameraSnapSteps);
  Expect<Double>(Step.X).ToBe(Target.X);
  Expect<Double>(Step.Y).ToBe(Target.Y);
  // And a tick that somehow overran still lands on it rather than past.
  Step := CameraSnapOrigin(From_, Target, CameraSnapSteps + 5,
    CameraSnapSteps);
  Expect<Double>(Step.X).ToBe(Target.X);
end;

procedure TCameraSnapTests.TestTheEaseIsMonotonicAndSlowAtBothEnds;
var
  From_, Target, Step, Previous: TCameraOrigin;
  I: Integer;
  FirstJump, MiddleJump: Double;
begin
  From_.X := 0;
  From_.Y := 0;
  Target.X := 1200;
  Target.Y := 0;
  Previous := From_;
  for I := 1 to CameraSnapSteps do
  begin
    Step := CameraSnapOrigin(From_, Target, I, CameraSnapSteps);
    Expect<Boolean>(Step.X >= Previous.X).ToBe(True);
    Expect<Boolean>(Step.X <= Target.X).ToBe(True);
    Previous := Step;
  end;
  // Smoothstep, not a straight line: the first step is much smaller than
  // one in the middle, which is what stops the move looking mechanical.
  FirstJump := CameraSnapOrigin(From_, Target, 1, CameraSnapSteps).X;
  MiddleJump := CameraSnapOrigin(From_, Target, CameraSnapSteps div 2 + 1,
    CameraSnapSteps).X
    - CameraSnapOrigin(From_, Target, CameraSnapSteps div 2,
    CameraSnapSteps).X;
  Expect<Boolean>(FirstJump < MiddleJump).ToBe(True);
end;

procedure TCameraSnapTests.TestADegenerateStepCountArrives;
var
  From_, Target, Step: TCameraOrigin;
begin
  From_.X := 10;
  From_.Y := 20;
  Target.X := 900;
  Target.Y := 40;
  Step := CameraSnapOrigin(From_, Target, 0, 0);
  Expect<Double>(Step.X).ToBe(Target.X);
  Expect<Double>(Step.Y).ToBe(Target.Y);
end;

{ TCameraDockTests }

procedure TCameraDockTests.SetupTests;
begin
  Test('a region flips from top-left display points into screen space',
    TestARegionFlipsIntoScreenSpace);
  Test('a region on a screen with a non-zero origin flips too',
    TestARegionOnASecondScreenFlipsToo);
  Test('the dock corner is inside the region, not on the screen',
    TestTheDockCornerIsInsideTheRegion);
  Test('a region smaller than the camera docks as far in as it fits',
    TestATinyRegionDocksAsFarInAsItFits);
  Test('the inset frame agrees with the snap about where the corner is',
    TestTheInsetMatchesTheSnapCorner);
  Test('an inset bigger than the rectangle leaves it alone',
    TestAnInsetTooBigForTheRectLeavesItAlone);
end;

procedure TCameraDockTests.TestARegionFlipsIntoScreenSpace;
var
  Region: TCaptureRegion;
  Rect: TCameraRect;
begin
  Region.Left := 100;
  Region.Top := 50;
  Region.Width := 800;
  Region.Height := 600;
  Rect := RegionScreenRect(Region, CameraRect(0, 0, 1440, 900));
  Expect<Double>(Rect.X).ToBe(100);
  // 900 - (50 + 600): the region's bottom edge measured up from the
  // screen's bottom, which is where AppKit counts from.
  Expect<Double>(Rect.Y).ToBe(250);
  Expect<Double>(Rect.Width).ToBe(800);
  Expect<Double>(Rect.Height).ToBe(600);
end;

procedure TCameraDockTests.TestARegionOnASecondScreenFlipsToo;
var
  Region: TCaptureRegion;
  Rect: TCameraRect;
begin
  Region.Left := 10;
  Region.Top := 10;
  Region.Width := 400;
  Region.Height := 300;
  // A display below and to the right of the main one.
  Rect := RegionScreenRect(Region, CameraRect(1440, -1080, 1920, 1080));
  Expect<Double>(Rect.X).ToBe(1450);
  Expect<Double>(Rect.Y).ToBe(-1080 + 1080 - 310);
end;

// The whole point of docking: the picture-in-picture ends up composited
// into the recording, which means inside the recorded rectangle and not
// merely near it.
procedure TCameraDockTests.TestTheDockCornerIsInsideTheRegion;
var
  Region: TCaptureRegion;
  Rect: TCameraRect;
  Camera, Docked: TCameraOrigin;
  Size: TCameraSize;
begin
  Region.Left := 200;
  Region.Top := 100;
  Region.Width := 1000;
  Region.Height := 700;
  Rect := RegionScreenRect(Region, CameraRect(0, 0, 1440, 900));
  Size := CameraWindowSize(csRectangle);
  // The camera was parked at the screen's bottom right, outside the
  // region entirely.
  Camera := DefaultCameraOrigin(Size, CameraRect(0, 0, 1440, 875));
  Docked := NearestCameraCorner(Camera, Size, Rect, CameraWindowMargin);
  Expect<Double>(Docked.X)
    .ToBe(Rect.X + Rect.Width - Size.Width - CameraWindowMargin);
  Expect<Double>(Docked.Y).ToBe(Rect.Y + CameraWindowMargin);
  Expect<Boolean>(Docked.X >= Rect.X).ToBe(True);
  Expect<Boolean>(Docked.Y >= Rect.Y).ToBe(True);
  Expect<Boolean>(Docked.X + Size.Width <= Rect.X + Rect.Width).ToBe(True);
  Expect<Boolean>(Docked.Y + Size.Height <= Rect.Y + Rect.Height).ToBe(True);
end;

// "As far in as it fits", not "inside": a 200x160 region cannot contain a
// 240x180 window at all, so the window overhangs by design. Lining its
// corner up with the region's is the most of it that can be in shot.
procedure TCameraDockTests.TestATinyRegionDocksAsFarInAsItFits;
var
  Region: TCaptureRegion;
  Rect: TCameraRect;
  Camera, Docked: TCameraOrigin;
  Size: TCameraSize;
begin
  Region.Left := 400;
  Region.Top := 400;
  Region.Width := 200;
  Region.Height := 160;
  Rect := RegionScreenRect(Region, CameraRect(0, 0, 1440, 900));
  Size := CameraWindowSize(csRectangle);
  Camera.X := 1200;
  Camera.Y := 40;
  Docked := NearestCameraCorner(Camera, Size, Rect, CameraWindowMargin);
  // No room for the window and the margins both; the region's own origin
  // is as far inside as it gets.
  Expect<Double>(Docked.X).ToBe(Rect.X);
  Expect<Double>(Docked.Y).ToBe(Rect.Y);
  // And this is the case that really does hang out of the region — said
  // plainly here so the name is not read as a promise it cannot keep.
  Expect<Boolean>(Docked.X + Size.Width > Rect.X + Rect.Width).ToBe(True);
  Expect<Boolean>(Docked.Y + Size.Height > Rect.Y + Rect.Height).ToBe(True);
end;

// SetShape clamps into an inset frame while docked; the drop snaps to a
// margin-inset corner. The two have to agree, or a shape change nudges
// the window off the corner it had just snapped to.
procedure TCameraDockTests.TestTheInsetMatchesTheSnapCorner;
var
  Rect, Inset: TCameraRect;
  Size: TCameraSize;
  Far_, Snapped, Clamped: TCameraOrigin;
begin
  Rect := CameraRect(200, 100, 1000, 700);
  Size := CameraWindowSize(csRectangle);
  Inset := InsetCameraRect(Rect, CameraWindowMargin);
  Expect<Double>(Inset.X).ToBe(200 + CameraWindowMargin);
  Expect<Double>(Inset.Y).ToBe(100 + CameraWindowMargin);
  Expect<Double>(Inset.Width).ToBe(1000 - 2 * CameraWindowMargin);
  // A window shoved past the far corner: clamping into the inset frame
  // lands on the same origin the snap would pick.
  Far_.X := 5000;
  Far_.Y := 5000;
  Snapped := NearestCameraCorner(Far_, Size, Rect, CameraWindowMargin);
  Clamped := ClampCameraOrigin(Far_, Size, Inset);
  Expect<Double>(Clamped.X).ToBe(Snapped.X);
  Expect<Double>(Clamped.Y).ToBe(Snapped.Y);
end;

procedure TCameraDockTests.TestAnInsetTooBigForTheRectLeavesItAlone;
var
  Inset: TCameraRect;
begin
  // 40 points wide with a 24 point margin each side would invert; the
  // axis is left as it was, the same give-up-on-the-margins rule
  // NearestCameraCorner uses.
  Inset := InsetCameraRect(CameraRect(10, 20, 40, 500), CameraWindowMargin);
  Expect<Double>(Inset.X).ToBe(10);
  Expect<Double>(Inset.Width).ToBe(40);
  Expect<Double>(Inset.Y).ToBe(20 + CameraWindowMargin);
  Expect<Double>(Inset.Height).ToBe(500 - 2 * CameraWindowMargin);
end;

{ TExportTests }

procedure TExportTests.SetupTests;
begin
  Test('the GIF sits beside the recording', TestGifPathSitsBesideTheRecording);
  Test('a movie with no extension still exports to a .gif',
    TestGifPathNeverOverwritesTheMovie);
  Test('no recording means no GIF path', TestGifPathOfNothingIsNothing);
  Test('a one-pixel-per-point recording keeps its own width',
    TestWidthKeepsSmallRecordings);
  Test('a Retina recording exports at its point size',
    TestWidthIsThePointSizeOfARetinaRecording);
  Test('a point size the exporter would refuse is not asked for',
    TestWidthDeclinesWhatTheExporterWouldReject);
  Test('the percentage spans both passes', TestPercentSpansBothPasses);
  Test('the percentage survives an estimate that was too low',
    TestPercentSurvivesABadTotal);
  Test('the progress title clamps to 0..100', TestProgressTitleClamps);
end;

procedure TExportTests.TestGifPathSitsBesideTheRecording;
begin
  Expect<string>(GifPathForRecording('/Users/x/Movies/knips/clip.mp4'))
    .ToBe('/Users/x/Movies/knips/clip.gif');
  Expect<string>(GifPathForRecording('/Users/x/clip.mov'))
    .ToBe('/Users/x/clip.gif');
end;

procedure TExportTests.TestGifPathNeverOverwritesTheMovie;
var
  Path: string;
begin
  Path := GifPathForRecording('/Users/x/clip');
  Expect<Boolean>(Path <> '/Users/x/clip').ToBe(True);
  Expect<Boolean>(ExtractFileExt(Path) = GifFileExtension).ToBe(True);
end;

procedure TExportTests.TestGifPathOfNothingIsNothing;
begin
  Expect<string>(GifPathForRecording('')).ToBe('');
end;

procedure TExportTests.TestWidthKeepsSmallRecordings;
begin
  // GifWidthFromSource is the exporter's "keep the movie's own width",
  // and at one pixel per point there is nothing to divide away — up to
  // the sendable-size cap, which point size cannot justify removing at
  // scale 1.
  Expect<Integer>(AppGifWidth(640, 1)).ToBe(GifWidthFromSource);
  Expect<Integer>(AppGifWidth(2560, 1)).ToBe(MaxAppGifWidth);
  // An unknown width has nowhere else to go; an unknown scale behaves
  // like scale 1, cap included — safety cannot depend on a field nobody
  // filled in.
  Expect<Integer>(AppGifWidth(0, 2)).ToBe(GifWidthFromSource);
  Expect<Integer>(AppGifWidth(1800, 0)).ToBe(MaxAppGifWidth);
  Expect<Integer>(AppGifWidth(640, 0)).ToBe(GifWidthFromSource);
end;

procedure TExportTests.TestWidthIsThePointSizeOfARetinaRecording;
begin
  // The whole point: a 2x recording exports at half its pixel width, so
  // the scaler runs one exact integer box reduction and stops. No cap —
  // a 2560 pt recording asks for 2560, and the exporter's own advice
  // line is where "that will be big" belongs.
  Expect<Integer>(AppGifWidth(1800, 2)).ToBe(900);
  Expect<Integer>(AppGifWidth(2560, 2)).ToBe(1280);
  Expect<Integer>(AppGifWidth(5120, 2)).ToBe(2560);
end;

procedure TExportTests.TestWidthDeclinesWhatTheExporterWouldReject;
begin
  // Below MinGifWidth the export would fail validation; falling back to
  // the movie's own width still produces a file. Above MaxGifWidth the
  // answer is the exporter's maximum — never the sentinel, which would
  // resolve to the full pixel width, twice what was just refused.
  Expect<Integer>(AppGifWidth(30, 2)).ToBe(GifWidthFromSource);
  Expect<Integer>(AppGifWidth(MaxGifWidth * 2 + 2, 2)).ToBe(MaxGifWidth);
  Expect<Integer>(AppGifWidth(MaxGifWidth * 2, 2)).ToBe(MaxGifWidth);
end;

procedure TExportTests.TestPercentSpansBothPasses;
begin
  Expect<Integer>(ExportPercent(True, 0, 100)).ToBe(0);
  Expect<Integer>(ExportPercent(True, 100, 100)).ToBe(PaletteProgressPercent);
  Expect<Integer>(ExportPercent(False, 0, 100)).ToBe(PaletteProgressPercent);
  Expect<Integer>(ExportPercent(False, 100, 100)).ToBe(100);
  Expect<Integer>(ExportPercent(False, 50, 100))
    .ToBe(PaletteProgressPercent + Round((100 - PaletteProgressPercent) / 2));
end;

procedure TExportTests.TestPercentSurvivesABadTotal;
begin
  // The total is an estimate; overshooting it must not read as 118%.
  Expect<Integer>(ExportPercent(False, 118, 100)).ToBe(100);
  Expect<Integer>(ExportPercent(True, 5, 0)).ToBe(0);
  Expect<Integer>(ExportPercent(False, -3, 100)).ToBe(PaletteProgressPercent);
end;

procedure TExportTests.TestProgressTitleClamps;
begin
  Expect<string>(ExportProgressTitle(0)).ToBe(ExportingTitlePrefix + '0%');
  Expect<string>(ExportProgressTitle(42)).ToBe(ExportingTitlePrefix + '42%');
  Expect<string>(ExportProgressTitle(-1)).ToBe(ExportingTitlePrefix + '0%');
  Expect<string>(ExportProgressTitle(101)).ToBe(ExportingTitlePrefix + '100%');
end;

{ TWindowMenuTests }

procedure TWindowMenuTests.SetupTests;
begin
  Test('a menu title reads "Application — Window"',
    TestTitleJoinsApplicationAndWindow);
  Test('a missing half leaves the other one', TestTitleFallsBackToWhatThereIs);
  Test('a long menu title is elided', TestTitleIsElided);
  Test('elision never splits a UTF-8 character',
    TestElisionKeepsUtf8Whole);
  Test('an ordinary on-screen window is recordable',
    TestOrdinaryWindowIsRecordable);
  Test('off-screen windows and other layers are skipped',
    TestOffScreenAndOtherLayersAreSkipped);
  Test('tiny and untitled windows are skipped',
    TestTinyAndUntitledWindowsAreSkipped);
  Test('our own windows are skipped', TestOurOwnWindowsAreSkipped);
end;

procedure TWindowMenuTests.TestTitleJoinsApplicationAndWindow;
begin
  Expect<string>(WindowMenuItemTitle('Safari', 'Apple'))
    .ToBe('Safari' + WindowMenuSeparator + 'Apple');
end;

procedure TWindowMenuTests.TestTitleFallsBackToWhatThereIs;
begin
  Expect<string>(WindowMenuItemTitle('Safari', '')).ToBe('Safari');
  Expect<string>(WindowMenuItemTitle('', 'Apple')).ToBe('Apple');
  Expect<Boolean>(WindowMenuItemTitle('  ', '  ') <> '').ToBe(True);
end;

procedure TWindowMenuTests.TestTitleIsElided;
var
  Title: string;
begin
  Title := WindowMenuItemTitle('App',
    StringOfChar('x', MaxWindowMenuTitleLength * 2));
  Expect<Boolean>(Length(Title) <= MaxWindowMenuTitleLength).ToBe(True);
  Expect<Boolean>(Pos('App', Title) = 1).ToBe(True);
end;

// NSString.stringWithUTF8String: hands back nil for an ill-formed
// sequence, and a nil menu title is an exception inside AppKit — so this
// checks the property that matters, not the byte count.
function IsWellFormedUtf8(const AText: string): Boolean;
var
  I, J, Extra: Integer;
  First: Byte;
begin
  Result := False;
  I := 1;
  while I <= Length(AText) do
  begin
    First := Ord(AText[I]);
    if First < $80 then
      Extra := 0
    else if First and $E0 = $C0 then
      Extra := 1
    else if First and $F0 = $E0 then
      Extra := 2
    else if First and $F8 = $F0 then
      Extra := 3
    else
      Exit;
    if I + Extra > Length(AText) then
      Exit;
    for J := 1 to Extra do
      if Ord(AText[I + J]) and $C0 <> $80 then
        Exit;
    Inc(I, Extra + 1);
  end;
  Result := True;
end;

procedure TWindowMenuTests.TestElisionKeepsUtf8Whole;
var
  Title: string;
begin
  // 'AB' plus the three-byte separator puts the cut point in the middle
  // of a three-byte character, which is exactly the case that used to
  // produce half a character.
  Title := WindowMenuItemTitle('AB', StringOfChar('x', 0)
    + DupeString('★', MaxWindowMenuTitleLength));
  Expect<Boolean>(Length(Title) <= MaxWindowMenuTitleLength).ToBe(True);
  Expect<Boolean>(IsWellFormedUtf8(Title)).ToBe(True);
  // And the same for the error line, which shares the elision.
  Expect<Boolean>(IsWellFormedUtf8(ErrorMenuTitle(
    DupeString('★', MaxErrorTitleLength)))).ToBe(True);
end;

procedure TWindowMenuTests.TestOrdinaryWindowIsRecordable;
begin
  Expect<Boolean>(IsWindowRecordable(True, RecordableWindowLayer, 800, 600,
    'Apple', False)).ToBe(True);
end;

procedure TWindowMenuTests.TestOffScreenAndOtherLayersAreSkipped;
begin
  Expect<Boolean>(IsWindowRecordable(False, RecordableWindowLayer, 800, 600,
    'Apple', False)).ToBe(False);
  // 1000 is where this app's own overlay and border windows live.
  Expect<Boolean>(IsWindowRecordable(True, 1000, 800, 600, 'Apple', False))
    .ToBe(False);
end;

procedure TWindowMenuTests.TestTinyAndUntitledWindowsAreSkipped;
begin
  Expect<Boolean>(IsWindowRecordable(True, RecordableWindowLayer,
    MinRecordableWindowSize - 1, 600, 'Apple', False)).ToBe(False);
  Expect<Boolean>(IsWindowRecordable(True, RecordableWindowLayer, 800,
    MinRecordableWindowSize - 1, 'Apple', False)).ToBe(False);
  Expect<Boolean>(IsWindowRecordable(True, RecordableWindowLayer, 800, 600,
    '   ', False)).ToBe(False);
end;

// The own-process flag comes from the owning pid, never from the
// application name — that reads 'Knips' under the bundle and 'knips-bin'
// from the shell, so a name comparison silently stopped matching and the
// playback window was offered as something to record.
procedure TWindowMenuTests.TestOurOwnWindowsAreSkipped;
begin
  Expect<Boolean>(IsWindowRecordable(True, RecordableWindowLayer, 800, 600,
    'clip.mp4', True)).ToBe(False);
  Expect<Boolean>(IsWindowRecordable(True, RecordableWindowLayer, 800, 600,
    'clip.mp4', False)).ToBe(True);
end;

begin
  TestRunnerProgram.AddSuite(TTransitionTests.Create('NextAppState'));
  TestRunnerProgram.AddSuite(TTitleTests.Create('StatusItemTitle'));
  TestRunnerProgram.AddSuite(TOutputTests.Create('recording output paths'));
  TestRunnerProgram.AddSuite(TSelectionTests.Create('selection geometry'));
  TestRunnerProgram.AddSuite(TErrorTitleTests.Create('ErrorMenuTitle'));
  TestRunnerProgram.AddSuite(TCameraTests.Create('camera window placement'));
  TestRunnerProgram.AddSuite(TCameraShapeTests.Create('camera shape'));
  TestRunnerProgram.AddSuite(TCameraSnapTests.Create('camera corner snap'));
  TestRunnerProgram.AddSuite(TCameraDockTests.Create(
    'camera docking into a region'));
  TestRunnerProgram.AddSuite(TExportTests.Create('one-click GIF export'));
  TestRunnerProgram.AddSuite(TWindowMenuTests.Create('Record Window submenu'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

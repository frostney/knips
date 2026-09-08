program Knips.Options.Test;

{$I Knips.inc}

uses
  SysUtils,

  Knips.Options,
  Knips.Recording.CursorMath,
  TestingPascalLibrary;

type
  TRegionTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestParsesFourValues;
    procedure TestTrimsWhitespace;
    procedure TestRejectsWrongArity;
    procedure TestRejectsNonNumeric;
    procedure TestRejectsEmptySize;
    procedure TestRejectsNegativeOrigin;
  end;

  TContainerTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestMp4;
    procedure TestMovCaseInsensitive;
    procedure TestUnknownExtension;
  end;

  TAudioModeTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestParsesNone;
    procedure TestParsesSystemCaseInsensitive;
    procedure TestParsesMicrophone;
    procedure TestParsesBoth;
    procedure TestRejectsUnknownMode;
    procedure TestNamesRoundTrip;
    procedure TestSourcePredicates;
  end;

  TValidationTests = class(TTestSuite)
  private
    function Valid: TRecordingOptions;
  public
    procedure SetupTests; override;
    procedure TestPointerFlagsAreMutuallyExclusive;
    procedure TestSmoothCursorNeedsADisplay;
    procedure TestDefaultsPlusOutputAreValid;
    procedure TestRequiresOutput;
    procedure TestRejectsBadExtension;
    procedure TestRejectsFpsOutOfRange;
    procedure TestRejectsScaleOutOfRange;
    procedure TestRejectsWindowWithRect;
    procedure TestRejectsZeroWindowId;
    procedure TestAcceptsExcludedWindows;
    procedure TestRejectsZeroExcludedWindowId;
    procedure TestRejectsExcludedWindowsOnAWindowTarget;
    procedure TestBigCursorIsOffByDefault;
    procedure TestAcceptsBigCursorOnADisplay;
    procedure TestRejectsBigCursorOnAWindowTarget;
    procedure TestRejectsBigCursorWithNoCursor;
    procedure TestRejectsRectSmallerThanAlignment;
    procedure TestFillsContainer;
    procedure TestDefaultsHaveNoAudio;
    procedure TestSystemAudioFillsFormatDefaults;
    procedure TestEveryAudioModeFillsFormatDefaults;
    procedure TestNoAudioLeavesFormatUntouched;
    procedure TestKeepsExplicitAudioFormat;
    procedure TestRejectsAudioSampleRateOutOfRange;
    procedure TestRejectsAudioChannelCountOutOfRange;
    procedure TestRejectsAudioBitRateOutOfRange;
  end;

  TTrimTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestParsesBothEnds;
    procedure TestAcceptsDecimals;
    procedure TestEmptyStartMeansZero;
    procedure TestEmptyEndMeansEndOfMovie;
    procedure TestExplicitZeroEndIsNotAnOpenEnd;
    procedure TestRejectsWrongArity;
    procedure TestRejectsNonNumeric;
    procedure TestIgnoresTheHostDecimalSeparator;
  end;

  TExportValidationTests = class(TTestSuite)
  private
    function Valid: TExportOptions;
  public
    procedure SetupTests; override;
    procedure TestDefaultsPlusPathsAreValid;
    procedure TestRequiresInput;
    procedure TestRequiresOutput;
    procedure TestRejectsNonMovieInput;
    procedure TestRejectsNonGifOutput;
    procedure TestRejectsInputEqualToOutput;
    procedure TestRejectsFpsOutOfRange;
    procedure TestRejectsWidthOutOfRange;
    procedure TestAcceptsSourceWidth;
    procedure TestRejectsNegativeTrimStart;
    procedure TestRejectsInvertedTrim;
    procedure TestRejectsAnExplicitZeroEnd;
    procedure TestAcceptsOpenEndedTrim;
    procedure TestApngOutputIsAccepted;
    procedure TestMovieOutputNeedsATrim;
    procedure TestMovieOutputFillsItsContainer;
    procedure TestMovieOutputRefusesAWholeMovieRange;
    procedure TestDefaultEffectsAskForNothingUnusual;
    procedure TestCursorModeNamesRoundTrip;
    procedure TestAnEffectOnAPassthroughTrimIsRefused;
    procedure TestAnEffectOnAGifIsAccepted;
    procedure TestEffectListsRoundTrip;
    procedure TestEffectListNoneIsTheWholeAnswer;
    procedure TestOneCursorEffectAtATime;
    procedure TestUnknownEffectsAreNamed;
    procedure TestZoomOnAPassthroughTrimIsRefused;
  end;

  TRawTakePathTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheSuffixGoesBeforeTheExtension;
    procedure TestTheRoundTrip;
    procedure TestRecognisingARawTake;
    procedure TestATakeAlreadyCalledRawCollides;
  end;

  TExportFormatTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestFormatFollowsTheExtension;
    procedure TestUnknownExtensionsAreRefused;
    procedure TestFormatNamesAreHumanReadable;
  end;

  TLargeExportTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSmallExportsSaySilent;
    procedure TestLargeCanvasWarns;
    procedure TestLargeFileWarns;
    procedure TestAdviceOnlyNamesKnobsThatMove;
    procedure TestPassthroughTrimNeverWarns;
  end;

  // The sentences knips says after a stop about something that went
  // quietly wrong. Every one of them is a fact nothing failed over, so
  // nothing else would ever notice them being lost.
  TAfterTheStopTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSilentSourceIsToldFromAnAbsentOne;
    procedure TestAnOffSourceSaysNothing;
    procedure TestUnmeasuredLevelSaysNothing;
    procedure TestLevelNoteNamesWhatArrived;
    procedure TestBigCursorIdleOnlyFiresOnAnIdleTake;
    procedure TestBigCursorIdleNamesBothCounts;
    procedure TestNoteSummaryPutsTheFramingFirst;
  end;

  TDerivedValueTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAlignsDown;
    procedure TestBitRateClampsLow;
    procedure TestBitRateClampsHigh;
    procedure TestBitRateScalesWithArea;
  end;

  // The words `knips render` and the MCP render tool both report with.
  // They used to be a byte-identical copy in each front end; these
  // assert the one implementation they now share.
  TRenderWordingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestNothingAppliedSaysNothing;
    procedure TestEveryClauseAppears;
    procedure TestReEncodedAudioIsShouted;
    procedure TestACopyDoesNotClaimWork;
    procedure TestNoteLinesWrapOnlyWhenThereIsANote;
    procedure TestRenderOutputMustBeAMovie;
  end;

  // The export's half of the same job. It had none at all: `knips
  // export` and the MCP export tools each composed their own sentence.
  TExportWordingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAPngSaysTruecolour;
    procedure TestGifNamesItsPalette;
    procedure TestAnInexactPaletteIsShouted;
    procedure TestEveryClauseAppearsInOrder;
    procedure TestTheSummaryLine;
    procedure TestTheTrimLine;
    procedure TestTheFramingNoteHasOneSpelling;
  end;

  // The half of the export surface that had no assertion at all: whether
  // an --effects list NAMED the pointer, and the refusal that answer
  // drives when --cursor names it too.
  TCursorNamingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheThreeCursorWordsCountAsNaming;
    procedure TestZoomAndNothingDoNotName;
    procedure TestNoneNamesThePointerToo;
    procedure TestAgreeingSpellingsAreAccepted;
    procedure TestDisagreeingSpellingsAreRefused;
    procedure TestEitherSpellingAloneIsFine;
    procedure TestAnUnknownCursorWordIsRefusedByName;
    procedure TestAnEmptyCursorModeIsNotParsed;
  end;

  // The three shapes a render temporary's family takes, and the fourth
  // that is somebody else's file. The crash sweep turns on this.
  TTemporaryNameTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheTemporaryItself;
    procedure TestTheOwnerMarker;
    procedure TestTheSandboxShadow;
    procedure TestAnOrdinaryFileIsNotOurs;
    procedure TestTheDerivedPaths;
  end;

{ TRegionTests }

procedure TRegionTests.SetupTests;
begin
  Test('parses left,top,width,height', TestParsesFourValues);
  Test('tolerates whitespace around numbers', TestTrimsWhitespace);
  Test('rejects three or five values', TestRejectsWrongArity);
  Test('rejects non-numeric parts', TestRejectsNonNumeric);
  Test('rejects zero or negative size', TestRejectsEmptySize);
  Test('rejects a negative origin', TestRejectsNegativeOrigin);
end;

procedure TRegionTests.TestParsesFourValues;
var
  Region: TCaptureRegion;
begin
  Expect<Boolean>(ParseCaptureRegion('10,20,640,480', Region)).ToBe(True);
  Expect<Integer>(Region.Left).ToBe(10);
  Expect<Integer>(Region.Top).ToBe(20);
  Expect<Integer>(Region.Width).ToBe(640);
  Expect<Integer>(Region.Height).ToBe(480);
end;

procedure TRegionTests.TestTrimsWhitespace;
var
  Region: TCaptureRegion;
begin
  Expect<Boolean>(ParseCaptureRegion(' 0, 0 , 100 ,100 ', Region)).ToBe(True);
  Expect<Integer>(Region.Width).ToBe(100);
end;

procedure TRegionTests.TestRejectsWrongArity;
var
  Region: TCaptureRegion;
begin
  Expect<Boolean>(ParseCaptureRegion('0,0,100', Region)).ToBe(False);
  Expect<Boolean>(ParseCaptureRegion('0,0,100,100,5', Region)).ToBe(False);
  Expect<Boolean>(ParseCaptureRegion('', Region)).ToBe(False);
end;

procedure TRegionTests.TestRejectsNonNumeric;
var
  Region: TCaptureRegion;
begin
  Expect<Boolean>(ParseCaptureRegion('0,0,wide,100', Region)).ToBe(False);
end;

procedure TRegionTests.TestRejectsEmptySize;
var
  Region: TCaptureRegion;
begin
  Expect<Boolean>(ParseCaptureRegion('0,0,0,100', Region)).ToBe(False);
  Expect<Boolean>(ParseCaptureRegion('0,0,100,-1', Region)).ToBe(False);
end;

procedure TRegionTests.TestRejectsNegativeOrigin;
var
  Region: TCaptureRegion;
begin
  Expect<Boolean>(ParseCaptureRegion('-5,0,100,100', Region)).ToBe(False);
end;

{ TContainerTests }

procedure TContainerTests.SetupTests;
begin
  Test('.mp4 selects MPEG-4', TestMp4);
  Test('.MOV selects QuickTime regardless of case', TestMovCaseInsensitive);
  Test('unknown extensions are rejected', TestUnknownExtension);
end;

procedure TContainerTests.TestMp4;
var
  Container: TOutputContainer;
begin
  Expect<Boolean>(ContainerForPath('/tmp/demo.mp4', Container)).ToBe(True);
  Expect<Boolean>(Container = ocMPEG4).ToBe(True);
end;

procedure TContainerTests.TestMovCaseInsensitive;
var
  Container: TOutputContainer;
begin
  Expect<Boolean>(ContainerForPath('Demo.MOV', Container)).ToBe(True);
  Expect<Boolean>(Container = ocQuickTime).ToBe(True);
end;

procedure TContainerTests.TestUnknownExtension;
var
  Container: TOutputContainer;
begin
  Expect<Boolean>(ContainerForPath('demo.gif', Container)).ToBe(False);
  Expect<Boolean>(ContainerForPath('demo', Container)).ToBe(False);
end;

{ TAudioModeTests }

procedure TAudioModeTests.SetupTests;
begin
  Test('"none" parses to amNone', TestParsesNone);
  Test('"System" parses regardless of case', TestParsesSystemCaseInsensitive);
  Test('"mic" parses regardless of case', TestParsesMicrophone);
  Test('"both" parses regardless of case', TestParsesBoth);
  Test('unknown modes are rejected', TestRejectsUnknownMode);
  Test('names round-trip through the parser', TestNamesRoundTrip);
  Test('each mode reports the sources it captures', TestSourcePredicates);
end;

procedure TAudioModeTests.TestParsesNone;
var
  Mode: TAudioMode;
begin
  Expect<Boolean>(ParseAudioMode('none', Mode)).ToBe(True);
  Expect<Boolean>(Mode = amNone).ToBe(True);
end;

procedure TAudioModeTests.TestParsesSystemCaseInsensitive;
var
  Mode: TAudioMode;
begin
  Expect<Boolean>(ParseAudioMode(' System ', Mode)).ToBe(True);
  Expect<Boolean>(Mode = amSystem).ToBe(True);
end;

procedure TAudioModeTests.TestParsesMicrophone;
var
  Mode: TAudioMode;
begin
  Expect<Boolean>(ParseAudioMode(' Mic ', Mode)).ToBe(True);
  Expect<Boolean>(Mode = amMicrophone).ToBe(True);
end;

procedure TAudioModeTests.TestParsesBoth;
var
  Mode: TAudioMode;
begin
  Expect<Boolean>(ParseAudioMode('BOTH', Mode)).ToBe(True);
  Expect<Boolean>(Mode = amBoth).ToBe(True);
end;

procedure TAudioModeTests.TestRejectsUnknownMode;
var
  Mode: TAudioMode;
begin
  // "microphone" is deliberately not an alias: one spelling per mode, so
  // AudioModeName round-trips.
  Expect<Boolean>(ParseAudioMode('microphone', Mode)).ToBe(False);
  Expect<Boolean>(ParseAudioMode('all', Mode)).ToBe(False);
  Expect<Boolean>(ParseAudioMode('', Mode)).ToBe(False);
end;

procedure TAudioModeTests.TestNamesRoundTrip;
var
  Mode: TAudioMode;
  Named: TAudioMode;
begin
  Expect<string>(AudioModeName(amNone)).ToBe('none');
  Expect<string>(AudioModeName(amSystem)).ToBe('system');
  Expect<string>(AudioModeName(amMicrophone)).ToBe('mic');
  Expect<string>(AudioModeName(amBoth)).ToBe('both');
  for Mode := Low(TAudioMode) to High(TAudioMode) do
  begin
    Expect<Boolean>(ParseAudioMode(AudioModeName(Mode), Named)).ToBe(True);
    Expect<Boolean>(Named = Mode).ToBe(True);
  end;
end;

procedure TAudioModeTests.TestSourcePredicates;
begin
  Expect<Boolean>(AudioModeCapturesSystem(amNone)).ToBe(False);
  Expect<Boolean>(AudioModeCapturesMicrophone(amNone)).ToBe(False);
  Expect<Boolean>(AudioModeCapturesSystem(amSystem)).ToBe(True);
  Expect<Boolean>(AudioModeCapturesMicrophone(amSystem)).ToBe(False);
  Expect<Boolean>(AudioModeCapturesSystem(amMicrophone)).ToBe(False);
  Expect<Boolean>(AudioModeCapturesMicrophone(amMicrophone)).ToBe(True);
  Expect<Boolean>(AudioModeCapturesSystem(amBoth)).ToBe(True);
  Expect<Boolean>(AudioModeCapturesMicrophone(amBoth)).ToBe(True);
end;

{ TValidationTests }

function TValidationTests.Valid: TRecordingOptions;
begin
  Result := DefaultRecordingOptions;
  Result.OutputPath := 'out.mp4';
end;

procedure TValidationTests.SetupTests;
begin
  Test('the three pointer flags are mutually exclusive',
    TestPointerFlagsAreMutuallyExclusive);
  Test('a smooth cursor is refused for a window capture',
    TestSmoothCursorNeedsADisplay);
  Test('defaults plus an output path validate', TestDefaultsPlusOutputAreValid);
  Test('an output path is required', TestRequiresOutput);
  Test('unknown container extension is rejected', TestRejectsBadExtension);
  Test('fps outside 1..120 is rejected', TestRejectsFpsOutOfRange);
  Test('scale outside auto/1/2 is rejected', TestRejectsScaleOutOfRange);
  Test('--window and --rect cannot combine', TestRejectsWindowWithRect);
  Test('window target needs a window id', TestRejectsZeroWindowId);
  Test('a display recording may exclude windows',
    TestAcceptsExcludedWindows);
  Test('an excluded window id of zero is rejected',
    TestRejectsZeroExcludedWindowId);
  Test('excluded windows are rejected on a window target',
    TestRejectsExcludedWindowsOnAWindowTarget);
  Test('a big cursor is off by default', TestBigCursorIsOffByDefault);
  Test('a display recording may have a big cursor',
    TestAcceptsBigCursorOnADisplay);
  Test('a big cursor is rejected on a window target',
    TestRejectsBigCursorOnAWindowTarget);
  Test('--no-cursor and --big-cursor are rejected together',
    TestRejectsBigCursorWithNoCursor);
  Test('rect smaller than the alignment is rejected',
    TestRejectsRectSmallerThanAlignment);
  Test('validation fills the container from the path', TestFillsContainer);
  Test('audio is off by default', TestDefaultsHaveNoAudio);
  Test('system audio fills 48 kHz stereo 128 kbit/s',
    TestSystemAudioFillsFormatDefaults);
  Test('mic and both fill the same format defaults',
    TestEveryAudioModeFillsFormatDefaults);
  Test('audio off leaves the format fields alone',
    TestNoAudioLeavesFormatUntouched);
  Test('an explicit audio format is kept', TestKeepsExplicitAudioFormat);
  Test('audio sample rate outside the range is rejected',
    TestRejectsAudioSampleRateOutOfRange);
  Test('audio channel count outside 1..2 is rejected',
    TestRejectsAudioChannelCountOutOfRange);
  Test('audio bit rate outside the range is rejected',
    TestRejectsAudioBitRateOutOfRange);
end;

procedure TValidationTests.TestDefaultsPlusOutputAreValid;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
  Expect<string>(Error).ToBe('');
end;

procedure TValidationTests.TestRequiresOutput;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := DefaultRecordingOptions;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('--out', Error) > 0).ToBe(True);
end;

procedure TValidationTests.TestRejectsBadExtension;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.OutputPath := 'out.webm';
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('.webm', Error) > 0).ToBe(True);
end;

procedure TValidationTests.TestRejectsFpsOutOfRange;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.FramesPerSecond := 0;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Options.FramesPerSecond := MaxFramesPerSecond + 1;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Options.FramesPerSecond := MaxFramesPerSecond;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
end;

procedure TValidationTests.TestRejectsScaleOutOfRange;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.Scale := 3;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Options.Scale := 2;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
end;

procedure TValidationTests.TestRejectsWindowWithRect;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.TargetKind := ctkWindow;
  Options.WindowID := 42;
  Options.HasRegion := True;
  Options.Region.Width := 10;
  Options.Region.Height := 10;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
end;

procedure TValidationTests.TestRejectsZeroWindowId;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.TargetKind := ctkWindow;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
end;

procedure TValidationTests.TestAcceptsExcludedWindows;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  SetLength(Options.ExcludedWindowIDs, 2);
  Options.ExcludedWindowIDs[0] := 17;
  Options.ExcludedWindowIDs[1] := 4711;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
  Expect<Integer>(Length(Options.ExcludedWindowIDs)).ToBe(2);
end;

procedure TValidationTests.TestRejectsZeroExcludedWindowId;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  SetLength(Options.ExcludedWindowIDs, 2);
  Options.ExcludedWindowIDs[0] := 17;
  Options.ExcludedWindowIDs[1] := 0;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('excluded window id', Error) > 0).ToBe(True);
end;

// The window filter has no exclusion list, so honouring these is
// impossible; the recorder must say so rather than drop them.
procedure TValidationTests.TestRejectsExcludedWindowsOnAWindowTarget;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.TargetKind := ctkWindow;
  Options.WindowID := 42;
  SetLength(Options.ExcludedWindowIDs, 1);
  Options.ExcludedWindowIDs[0] := 17;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('display recordings only', Error) > 0).ToBe(True);
end;

procedure TValidationTests.TestBigCursorIsOffByDefault;
var
  Options: TRecordingOptions;
begin
  Options := DefaultRecordingOptions;
  Expect<Boolean>(Options.BigCursor).ToBe(False);
  // The ordinary pointer is still on: nothing about this feature changes
  // what a recording does until it is asked for.
  Expect<Boolean>(Options.ShowsCursor).ToBe(True);
end;

procedure TValidationTests.TestAcceptsBigCursorOnADisplay;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.BigCursor := True;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
  Options.HasRegion := True;
  Options.Region.Left := 10;
  Options.Region.Top := 20;
  Options.Region.Width := 400;
  Options.Region.Height := 300;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
end;

procedure TValidationTests.TestRejectsBigCursorOnAWindowTarget;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.TargetKind := ctkWindow;
  Options.WindowID := 42;
  Options.BigCursor := True;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('display recordings only', Error) > 0).ToBe(True);
end;

procedure TValidationTests.TestRejectsBigCursorWithNoCursor;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.BigCursor := True;
  Options.ShowsCursor := False;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('mutually exclusive', Error) > 0).ToBe(True);
end;

procedure TValidationTests.TestRejectsRectSmallerThanAlignment;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.HasRegion := True;
  Options.Region.Width := 1;
  Options.Region.Height := 100;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
end;

procedure TValidationTests.TestFillsContainer;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.OutputPath := 'clip.mov';
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
  Expect<Boolean>(Options.Container = ocQuickTime).ToBe(True);
end;

procedure TValidationTests.TestDefaultsHaveNoAudio;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
  Expect<Boolean>(Options.AudioMode = amNone).ToBe(True);
end;

procedure TValidationTests.TestSystemAudioFillsFormatDefaults;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.AudioMode := amSystem;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
  Expect<Integer>(Options.AudioSampleRate).ToBe(DefaultAudioSampleRate);
  Expect<Integer>(Options.AudioChannelCount).ToBe(DefaultAudioChannelCount);
  Expect<Integer>(Options.AudioBitRate).ToBe(DefaultAudioBitRate);
end;

// The microphone track is encoded with the same AAC settings as system
// audio — AVAssetWriterInput converts the device's native format into
// them — so every mode that captures anything derives the same defaults.
procedure TValidationTests.TestEveryAudioModeFillsFormatDefaults;
var
  Options: TRecordingOptions;
  Error: string;
  Mode: TAudioMode;
begin
  for Mode := Low(TAudioMode) to High(TAudioMode) do
  begin
    if Mode = amNone then
      Continue;
    Options := Valid;
    Options.AudioMode := Mode;
    Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
    Expect<Integer>(Options.AudioSampleRate).ToBe(DefaultAudioSampleRate);
    Expect<Integer>(Options.AudioChannelCount).ToBe(DefaultAudioChannelCount);
    Expect<Integer>(Options.AudioBitRate).ToBe(DefaultAudioBitRate);
  end;
end;

procedure TValidationTests.TestNoAudioLeavesFormatUntouched;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
  Expect<Integer>(Options.AudioSampleRate).ToBe(0);
  Expect<Integer>(Options.AudioChannelCount).ToBe(0);
  Expect<Integer>(Options.AudioBitRate).ToBe(0);
end;

procedure TValidationTests.TestKeepsExplicitAudioFormat;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.AudioMode := amSystem;
  Options.AudioSampleRate := 44100;
  Options.AudioChannelCount := 1;
  Options.AudioBitRate := 64000;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
  Expect<Integer>(Options.AudioSampleRate).ToBe(44100);
  Expect<Integer>(Options.AudioChannelCount).ToBe(1);
  Expect<Integer>(Options.AudioBitRate).ToBe(64000);
end;

procedure TValidationTests.TestRejectsAudioSampleRateOutOfRange;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.AudioMode := amSystem;
  Options.AudioSampleRate := MinAudioSampleRate - 1;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Options.AudioSampleRate := MaxAudioSampleRate + 1;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
end;

procedure TValidationTests.TestRejectsAudioChannelCountOutOfRange;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.AudioMode := amSystem;
  Options.AudioChannelCount := MaxAudioChannelCount + 1;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
end;

procedure TValidationTests.TestRejectsAudioBitRateOutOfRange;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.AudioMode := amSystem;
  Options.AudioBitRate := MaxAudioBitRate + 1;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
end;

{ TTrimTests }

procedure TTrimTests.SetupTests;
begin
  Test('parses start,end in seconds', TestParsesBothEnds);
  Test('accepts a decimal part on either side', TestAcceptsDecimals);
  Test('an empty start means the beginning', TestEmptyStartMeansZero);
  Test('an empty end means the end of the movie',
    TestEmptyEndMeansEndOfMovie);
  Test('an explicit zero end is a real end, not an open one',
    TestExplicitZeroEndIsNotAnOpenEnd);
  Test('rejects one or three values', TestRejectsWrongArity);
  Test('rejects non-numeric parts', TestRejectsNonNumeric);
  Test('reads the decimal point the same in every locale',
    TestIgnoresTheHostDecimalSeparator);
end;

procedure TTrimTests.TestParsesBothEnds;
var
  Start, Finish: Double;
  HasEnd: Boolean;
begin
  Expect<Boolean>(ParseTrimRange('2,7', Start, Finish, HasEnd)).ToBe(True);
  Expect<Boolean>(Abs(Start - 2) < 1E-9).ToBe(True);
  Expect<Boolean>(Abs(Finish - 7) < 1E-9).ToBe(True);
end;

procedure TTrimTests.TestAcceptsDecimals;
var
  Start, Finish: Double;
  HasEnd: Boolean;
begin
  Expect<Boolean>(ParseTrimRange(' 1.25 , 3.5 ', Start, Finish, HasEnd)).ToBe(True);
  Expect<Boolean>(Abs(Start - 1.25) < 1E-9).ToBe(True);
  Expect<Boolean>(Abs(Finish - 3.5) < 1E-9).ToBe(True);
end;

procedure TTrimTests.TestEmptyStartMeansZero;
var
  Start, Finish: Double;
  HasEnd: Boolean;
begin
  Expect<Boolean>(ParseTrimRange(',4', Start, Finish, HasEnd)).ToBe(True);
  Expect<Boolean>(Start = 0).ToBe(True);
  Expect<Boolean>(HasEnd).ToBe(True);
  Expect<Boolean>(Abs(Finish - 4) < 1E-9).ToBe(True);
end;

procedure TTrimTests.TestEmptyEndMeansEndOfMovie;
var
  Start, Finish: Double;
  HasEnd: Boolean;
begin
  Expect<Boolean>(ParseTrimRange('4,', Start, Finish, HasEnd)).ToBe(True);
  Expect<Boolean>(Abs(Start - 4) < 1E-9).ToBe(True);
  Expect<Boolean>(HasEnd).ToBe(False);
end;

procedure TTrimTests.TestExplicitZeroEndIsNotAnOpenEnd;
var
  Start, Finish: Double;
  HasEnd: Boolean;
begin
  // "0" is a value, not a missing value: --trim=0,0 and --trim=3,0 are
  // empty ranges and validation has to be able to see that.
  Expect<Boolean>(ParseTrimRange('0,0', Start, Finish, HasEnd)).ToBe(True);
  Expect<Boolean>(HasEnd).ToBe(True);
  Expect<Boolean>(Finish = 0).ToBe(True);
  Expect<Boolean>(ParseTrimRange('3,0', Start, Finish, HasEnd)).ToBe(True);
  Expect<Boolean>(HasEnd).ToBe(True);
end;

procedure TTrimTests.TestRejectsWrongArity;
var
  Start, Finish: Double;
  HasEnd: Boolean;
begin
  Expect<Boolean>(ParseTrimRange('4', Start, Finish, HasEnd)).ToBe(False);
  Expect<Boolean>(ParseTrimRange('1,2,3', Start, Finish, HasEnd)).ToBe(False);
end;

procedure TTrimTests.TestRejectsNonNumeric;
var
  Start, Finish: Double;
  HasEnd: Boolean;
begin
  Expect<Boolean>(ParseTrimRange('start,4', Start, Finish, HasEnd)).ToBe(False);
  Expect<Boolean>(ParseTrimRange('1,later', Start, Finish, HasEnd)).ToBe(False);
end;

procedure TTrimTests.TestIgnoresTheHostDecimalSeparator;
var
  Start, Finish: Double;
  HasEnd: Boolean;
  Saved: Char;
begin
  Saved := DefaultFormatSettings.DecimalSeparator;
  try
    DefaultFormatSettings.DecimalSeparator := ',';
    Expect<Boolean>(ParseTrimRange('1.5,2.5', Start, Finish, HasEnd)).ToBe(True);
    Expect<Boolean>(Abs(Start - 1.5) < 1E-9).ToBe(True);
    Expect<Boolean>(Abs(Finish - 2.5) < 1E-9).ToBe(True);
  finally
    DefaultFormatSettings.DecimalSeparator := Saved;
  end;
end;

{ TExportValidationTests }

function TExportValidationTests.Valid: TExportOptions;
begin
  Result := DefaultExportOptions;
  Result.InputPath := 'demo.mp4';
  Result.OutputPath := 'demo.gif';
end;

// The record side of the pointer decision. All three flags switch
// ScreenCaptureKit's own cursor off or on, and any two of them together
// ask for opposite things — so every pair is refused rather than
// silently resolved, and this pins that none of the three refusals was
// lost when the third arrived.
procedure TValidationTests.TestPointerFlagsAreMutuallyExclusive;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.BigCursor := True;
  Options.SmoothCursor := True;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('--big-cursor and --smooth-cursor', Error) > 0)
    .ToBe(True);

  Options := Valid;
  Options.SmoothCursor := True;
  Options.ShowsCursor := False;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('--no-cursor and --smooth-cursor', Error) > 0)
    .ToBe(True);

  Options := Valid;
  Options.BigCursor := True;
  Options.ShowsCursor := False;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('--no-cursor and --big-cursor', Error) > 0).ToBe(True);

  // Each on its own is fine.
  Options := Valid;
  Options.SmoothCursor := True;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
  Options := Valid;
  Options.BigCursor := True;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(True);
end;

procedure TValidationTests.TestSmoothCursorNeedsADisplay;
var
  Options: TRecordingOptions;
  Error: string;
begin
  Options := Valid;
  Options.TargetKind := ctkWindow;
  Options.WindowID := 42;
  Options.SmoothCursor := True;
  Expect<Boolean>(ValidateRecordingOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('display recordings only', Error) > 0).ToBe(True);
  // And the resolver agrees with the validator, which is what keeps the
  // app (which resolves rather than refuses) from asking for a
  // combination the recorder would reject.
  Expect<Boolean>(ResolveSmoothCursor(ctkWindow, True)).ToBe(False);
  Expect<Boolean>(ResolveSmoothCursor(ctkDisplay, True)).ToBe(True);
end;

procedure TExportValidationTests.SetupTests;
begin
  Test('defaults plus both paths validate', TestDefaultsPlusPathsAreValid);
  Test('an input movie is required', TestRequiresInput);
  Test('an output path is required', TestRequiresOutput);
  Test('the input must be .mp4 or .mov', TestRejectsNonMovieInput);
  Test('an unknown output extension is refused', TestRejectsNonGifOutput);
  Test('writing over the input is refused', TestRejectsInputEqualToOutput);
  Test('fps outside 1..50 is rejected', TestRejectsFpsOutOfRange);
  Test('width outside 16..4096 is rejected', TestRejectsWidthOutOfRange);
  Test('a zero width means the movie width', TestAcceptsSourceWidth);
  Test('a trim cannot start before zero', TestRejectsNegativeTrimStart);
  Test('a trim cannot end before it starts', TestRejectsInvertedTrim);
  Test('a trim ending at zero is an empty range, not an open one',
    TestRejectsAnExplicitZeroEnd);
  Test('a trim with no end runs to the end', TestAcceptsOpenEndedTrim);
  Test('an .apng output validates', TestApngOutputIsAccepted);
  Test('a movie output without --trim is refused', TestMovieOutputNeedsATrim);
  Test('a movie output fills in its own container',
    TestMovieOutputFillsItsContainer);
  Test('the default effects are as-recorded and nothing else',
    TestDefaultEffectsAskForNothingUnusual);
  Test('every cursor mode survives a name round trip',
    TestCursorModeNamesRoundTrip);
  Test('an export effect on a passthrough trim is refused',
    TestAnEffectOnAPassthroughTrimIsRefused);
  Test('an export effect on a GIF is accepted',
    TestAnEffectOnAGifIsAccepted);
  Test('a movie output refuses a range that is the whole movie',
    TestMovieOutputRefusesAWholeMovieRange);
  Test('an effects list survives a round trip through its own text',
    TestEffectListsRoundTrip);
  Test('--effects=none is the whole answer, not a word among words',
    TestEffectListNoneIsTheWholeAnswer);
  Test('the cursor effects are one setting and refuse to be named twice',
    TestOneCursorEffectAtATime);
  Test('an unknown effect is named back to the caller',
    TestUnknownEffectsAreNamed);
  Test('a post-hoc zoom on a passthrough trim is refused',
    TestZoomOnAPassthroughTrimIsRefused);
end;

// The list is the interface three things speak — the CLI's --effects, the
// playback window's control, and the saved defaults — so what matters is
// that writing it and reading it back are inverses.
procedure TExportValidationTests.TestEffectListsRoundTrip;
var
  Effects, Parsed: TExportEffects;
  Error: string;
begin
  Effects := DefaultExportEffects;
  // 'as-recorded', not 'none': the two mean opposite things and the
  // default is not "no pointer".
  Expect<string>(DescribeExportEffects(Effects)).ToBe('as-recorded');
  Parsed := DefaultExportEffects;
  Parsed.Cursor := ecmBig;
  Expect<Boolean>(ParseExportEffects(DescribeExportEffects(Effects), Parsed,
    Error)).ToBe(True);
  Expect<string>(DescribeExportEffects(Parsed)).ToBe('as-recorded');
  Effects.ZoomOnClick := True;
  Effects.Cursor := ecmSmooth;
  Expect<string>(DescribeExportEffects(Effects)).ToBe('zoom,smooth-cursor');
  Parsed := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffects('zoom,smooth-cursor', Parsed, Error))
    .ToBe(True);
  Expect<string>(DescribeExportEffects(Parsed)).ToBe('zoom,smooth-cursor');
  // Case and spacing are the caller's business, not the format's.
  Parsed := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffects(' ZOOM , Big-Cursor ', Parsed, Error))
    .ToBe(True);
  Expect<string>(DescribeExportEffects(Parsed)).ToBe('zoom,big-cursor');
  // An empty list changes nothing, which is what an absent flag means.
  Parsed := DefaultExportEffects;
  Parsed.ZoomOnClick := True;
  Expect<Boolean>(ParseExportEffects('', Parsed, Error)).ToBe(True);
  Expect<Boolean>(Parsed.ZoomOnClick).ToBe(True);
end;

procedure TExportValidationTests.TestEffectListNoneIsTheWholeAnswer;
var
  Effects: TExportEffects;
  Error: string;
begin
  Effects := DefaultExportEffects;
  Effects.ZoomOnClick := True;
  Expect<Boolean>(ParseExportEffects('none', Effects, Error)).ToBe(True);
  Expect<Boolean>(Effects.ZoomOnClick).ToBe(False);
  Expect<string>(ExportCursorModeName(Effects.Cursor)).ToBe('none');
  // Mixed with a request it says two opposite things at once.
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffects('none,zoom', Effects, Error)).ToBe(False);
  Expect<Boolean>(Error <> '').ToBe(True);
  // But a trailing comma combines it with nothing at all, which is not a
  // combination. Counting the split parts got this wrong.
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffects('none,', Effects, Error)).ToBe(True);
  Expect<string>(ExportCursorModeName(Effects.Cursor)).ToBe('none');
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffects(' , none , ', Effects, Error))
    .ToBe(True);
  Expect<string>(ExportCursorModeName(Effects.Cursor)).ToBe('none');
end;

procedure TExportValidationTests.TestOneCursorEffectAtATime;
var
  Effects: TExportEffects;
  Error: string;
begin
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffects('smooth-cursor,big-cursor', Effects,
    Error)).ToBe(False);
  Expect<Boolean>(Error <> '').ToBe(True);
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffects('as-recorded,no-cursor', Effects,
    Error)).ToBe(False);
end;

procedure TExportValidationTests.TestUnknownEffectsAreNamed;
var
  Effects: TExportEffects;
  Error: string;
begin
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffects('zoom,sparkles', Effects, Error))
    .ToBe(False);
  Expect<Boolean>(Pos('sparkles', Error) > 0).ToBe(True);
  // The zoom before it still took effect on AEffects; that is deliberate
  // and harmless, because a caller that got False must not use the
  // record at all. What matters is that the caller is told which word.
  Expect<Boolean>(Pos('sparkles', Error) > 0).ToBe(True);
end;

procedure TExportValidationTests.TestZoomOnAPassthroughTrimIsRefused;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := DefaultExportOptions;
  Options.InputPath := 'in.mp4';
  Options.OutputPath := 'out.mp4';
  Options.HasTrim := True;
  Options.TrimStartSeconds := 1;
  Options.HasTrimEnd := True;
  Options.TrimEndSeconds := 2;
  Options.Effects.ZoomOnClick := True;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('render', Error) > 0).ToBe(True);
end;

procedure TExportValidationTests.TestDefaultsPlusPathsAreValid;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
  Expect<string>(Error).ToBe('');
  Expect<Boolean>(Options.Format = efGif).ToBe(True);
  Expect<Boolean>(Options.InputContainer = ocMPEG4).ToBe(True);
  Expect<Integer>(Options.FramesPerSecond).ToBe(DefaultGifFramesPerSecond);
  Expect<Boolean>(Options.Dither).ToBe(True);
end;

procedure TExportValidationTests.TestRequiresInput;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.InputPath := '';
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('--in', Error) > 0).ToBe(True);
end;

procedure TExportValidationTests.TestRequiresOutput;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.OutputPath := '';
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('--out', Error) > 0).ToBe(True);
end;

procedure TExportValidationTests.TestRejectsNonMovieInput;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.InputPath := 'demo.gif';
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Options.InputPath := 'demo.MOV';
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
  Expect<Boolean>(Options.InputContainer = ocQuickTime).ToBe(True);
end;

procedure TExportValidationTests.TestRejectsNonGifOutput;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.OutputPath := 'demo.webm';
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('.webm', Error) > 0).ToBe(True);
  Options.OutputPath := 'demo.GIF';
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
end;

procedure TExportValidationTests.TestRejectsInputEqualToOutput;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.InputPath := 'clip.mov';
  Options.OutputPath := 'clip.mov';
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
end;

procedure TExportValidationTests.TestRejectsFpsOutOfRange;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.FramesPerSecond := 0;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Options.FramesPerSecond := MaxGifFramesPerSecond + 1;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Options.FramesPerSecond := MaxGifFramesPerSecond;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
end;

procedure TExportValidationTests.TestRejectsWidthOutOfRange;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.Width := MinGifWidth - 1;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Options.Width := MaxGifWidth + 1;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Options.Width := 640;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
end;

procedure TExportValidationTests.TestAcceptsSourceWidth;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.Width := GifWidthFromSource;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
end;

procedure TExportValidationTests.TestRejectsNegativeTrimStart;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.TrimStartSeconds := -1;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
end;

procedure TExportValidationTests.TestRejectsInvertedTrim;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.TrimStartSeconds := 5;
  Options.HasTrimEnd := True;
  Options.TrimEndSeconds := 2;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
end;

procedure TExportValidationTests.TestRejectsAnExplicitZeroEnd;
var
  Options: TExportOptions;
  Error: string;
begin
  // --trim=0,0 and --trim=3,0 used to export the whole movie because
  // zero doubled as the "no end given" sentinel.
  Options := Valid;
  Options.TrimStartSeconds := 0;
  Options.HasTrimEnd := True;
  Options.TrimEndSeconds := 0;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Options.TrimStartSeconds := 3;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
end;

procedure TExportValidationTests.TestAcceptsOpenEndedTrim;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.TrimStartSeconds := 5;
  Options.HasTrimEnd := False;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
end;

procedure TExportValidationTests.TestApngOutputIsAccepted;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.OutputPath := 'demo.APNG';
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
  Expect<Boolean>(Options.Format = efApng).ToBe(True);
end;

// A passthrough trim with no range is a copy, which is not what the
// command is for; saying so is better than silently duplicating a file.
procedure TExportValidationTests.TestMovieOutputNeedsATrim;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.OutputPath := 'cut.mp4';
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('--trim', Error) > 0).ToBe(True);
  Options.HasTrim := True;
  Options.TrimStartSeconds := 1.5;
  Options.HasTrimEnd := True;
  Options.TrimEndSeconds := 3.5;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
  Expect<Boolean>(Options.Format = efMovie).ToBe(True);
end;

procedure TExportValidationTests.TestMovieOutputFillsItsContainer;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.OutputPath := 'cut.mov';
  Options.HasTrim := True;
  Options.HasTrimEnd := True;
  Options.TrimEndSeconds := 2;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
  Expect<Boolean>(Options.OutputContainer = ocQuickTime).ToBe(True);
  Options.OutputPath := 'cut.mp4';
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
  Expect<Boolean>(Options.OutputContainer = ocMPEG4).ToBe(True);
end;

// --trim=0, parses and is a range, so it slips past "a movie output
// needs --trim" while being exactly the whole-file copy that rule
// exists to refuse.
// The export-effects list: the cursor is its first member, and the shape
// matters more than the member — the playback window's Effects control and
// the next post-recording effect both hang off this record.
procedure TExportValidationTests.TestDefaultEffectsAskForNothingUnusual;
var
  Options: TExportOptions;
begin
  Options := DefaultExportOptions;
  Expect<string>(ExportCursorModeName(Options.Effects.Cursor))
    .ToBe('as-recorded');
  Expect<Boolean>(EffectsDrawCursor(Options.Effects)).ToBe(True);
  Expect<Boolean>(EffectsDrawCursor(DefaultExportEffects)).ToBe(True);
  // Zero means "the feature's own default" everywhere. Asserting that
  // the fields ARE zero says nothing worth knowing — a record nobody
  // fills in is zero by construction. What is worth pinning is the rule
  // the zero buys: every reader of these four fields substitutes a named
  // default for it, so a caller that fills nothing in gets the sensible
  // thing rather than a magnification of zero and a hold of nothing.
  // Knips.Export.ZoomTrack.ZoomWalkerStart is where the zoom half of
  // that rule lives and is tested; this is the half the record itself
  // owns, which is that the default really is the unfilled record.
  Expect<TExportEffects>(DefaultExportEffects).ToBe(Default(TExportEffects));
end;

procedure TExportValidationTests.TestCursorModeNamesRoundTrip;
var
  Mode: TExportCursorMode;
  Parsed: TExportCursorMode;
begin
  for Mode := Low(TExportCursorMode) to High(TExportCursorMode) do
  begin
    Expect<Boolean>(ParseExportCursorMode(ExportCursorModeName(Mode),
      Parsed)).ToBe(True);
    Expect<string>(ExportCursorModeName(Parsed))
      .ToBe(ExportCursorModeName(Mode));
  end;
  // An empty string is NOT the default and is not a mode: an unset
  // --cursor is a caller with nothing to parse, and the difference
  // between that and an explicit `as-recorded` is a difference this
  // function has to be able to report. See
  // TCursorNamingTests.TestAnEmptyCursorModeIsNotParsed.
  Expect<Boolean>(ParseExportCursorMode('', Parsed)).ToBe(False);
  Expect<Boolean>(ParseExportCursorMode('BIG', Parsed)).ToBe(True);
  Expect<string>(ExportCursorModeName(Parsed)).ToBe('big');
  Expect<Boolean>(ParseExportCursorMode('enormous', Parsed)).ToBe(False);
  Expect<Boolean>(EffectsDrawCursor(DefaultExportEffects)).ToBe(True);
end;

// The scope limit, as a rule rather than as a note in a document: a
// passthrough trim copies coded samples, so an effect on one would have
// to re-encode the video, and that is the one thing that output exists
// not to do.
procedure TExportValidationTests.TestAnEffectOnAPassthroughTrimIsRefused;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.OutputPath := 'cut.mp4';
  Options.HasTrim := True;
  Options.TrimStartSeconds := 0;
  Options.HasTrimEnd := True;
  Options.TrimEndSeconds := 3;
  Options.Effects.Cursor := ecmSmooth;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('.gif and .apng only', Error) > 0).ToBe(True);
  // as-recorded is not "an effect": it is what every export has always
  // done, and a trim must go on validating.
  Options.Effects.Cursor := ecmAsRecorded;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
end;

procedure TExportValidationTests.TestAnEffectOnAGifIsAccepted;
var
  Options: TExportOptions;
  Error: string;
  Mode: TExportCursorMode;
begin
  for Mode := Low(TExportCursorMode) to High(TExportCursorMode) do
  begin
    Options := Valid;
    Options.Effects.Cursor := Mode;
    Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
    Options := Valid;
    Options.OutputPath := 'demo.apng';
    Options.Effects.Cursor := Mode;
    Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
  end;
end;

procedure TExportValidationTests.TestMovieOutputRefusesAWholeMovieRange;
var
  Options: TExportOptions;
  Error: string;
begin
  Options := Valid;
  Options.OutputPath := 'cut.mp4';
  Options.HasTrim := True;
  Options.TrimStartSeconds := 0;
  Options.HasTrimEnd := False;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('whole movie', Error) > 0).ToBe(True);
  // An end makes it a real trim...
  Options.HasTrimEnd := True;
  Options.TrimEndSeconds := 3.5;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
  // ...and so does a later start with no end.
  Options.HasTrimEnd := False;
  Options.TrimStartSeconds := 1.5;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
  // A GIF, which is not a copy of anything, is unaffected.
  Options.OutputPath := 'demo.gif';
  Options.TrimStartSeconds := 0;
  Expect<Boolean>(ValidateExportOptions(Options, Error)).ToBe(True);
end;

{ TRawTakePathTests }

procedure TRawTakePathTests.SetupTests;
begin
  Test('the suffix goes before the extension, not after it',
    TestTheSuffixGoesBeforeTheExtension);
  Test('a deliverable name survives the trip through the raw name',
    TestTheRoundTrip);
  Test('only a stem ending in the suffix is a raw take',
    TestRecognisingARawTake);
  Test('a take the user already called "-raw" collides, as documented',
    TestATakeAlreadyCalledRawCollides);
end;

procedure TRawTakePathTests.TestTheSuffixGoesBeforeTheExtension;
begin
  Expect<string>(RawTakePathFor('/m/demo.mp4')).ToBe('/m/demo-raw.mp4');
  Expect<string>(RawTakePathFor('/m/demo.mov')).ToBe('/m/demo-raw.mov');
  // A directory with dots in it must not be mistaken for an extension.
  Expect<string>(RawTakePathFor('/m/a.b/demo.mp4'))
    .ToBe('/m/a.b/demo-raw.mp4');
  Expect<string>(RawTakePathFor('')).ToBe('');
end;

procedure TRawTakePathTests.TestTheRoundTrip;
begin
  Expect<string>(DeliverablePathFor(RawTakePathFor('/m/demo.mp4')))
    .ToBe('/m/demo.mp4');
  Expect<string>(DeliverablePathFor(RawTakePathFor('/m/2026-08-27 18-26.mov')))
    .ToBe('/m/2026-08-27 18-26.mov');
  // A path that is not a raw take comes back untouched rather than
  // having its last four characters removed.
  Expect<string>(DeliverablePathFor('/m/demo.mp4')).ToBe('/m/demo.mp4');
end;

procedure TRawTakePathTests.TestRecognisingARawTake;
begin
  Expect<Boolean>(IsRawTakePath('/m/demo-raw.mp4')).ToBe(True);
  Expect<Boolean>(IsRawTakePath('/m/demo.mp4')).ToBe(False);
  // The suffix has to be the END of the stem, not anywhere in it.
  Expect<Boolean>(IsRawTakePath('/m/raw-demo.mp4')).ToBe(False);
  Expect<Boolean>(IsRawTakePath('/m/demo-rawish.mp4')).ToBe(False);
  // And the stem has to be longer than the suffix: a file actually
  // called `-raw.mp4` has no deliverable name left underneath it.
  Expect<Boolean>(IsRawTakePath('/m/-raw.mp4')).ToBe(False);
  Expect<Boolean>(IsRawTakePath('')).ToBe(False);
end;

// Documented behaviour rather than a defect, pinned so a change to it is
// a decision: `knips render --in=demo-raw.mp4` with no --out derives
// `demo.mp4`, and if the user's own file was already called
// `demo-raw.mp4` with a `demo.mp4` beside it, that `demo.mp4` is
// replaced — which is what every knips output path does.
procedure TRawTakePathTests.TestATakeAlreadyCalledRawCollides;
begin
  Expect<string>(DeliverablePathFor('/m/demo-raw.mp4')).ToBe('/m/demo.mp4');
  // Nesting is not special-cased either: rendering a raw take twice
  // would want two different names, and knips only ever makes one.
  Expect<string>(RawTakePathFor('/m/demo-raw.mp4'))
    .ToBe('/m/demo-raw-raw.mp4');
  Expect<Boolean>(IsRawTakePath(RawTakePathFor('/m/demo-raw.mp4')))
    .ToBe(True);
end;

{ TExportFormatTests }

procedure TExportFormatTests.SetupTests;
begin
  Test('the extension picks the format', TestFormatFollowsTheExtension);
  Test('anything else is refused', TestUnknownExtensionsAreRefused);
  Test('formats have names worth printing',
    TestFormatNamesAreHumanReadable);
end;

procedure TExportFormatTests.TestFormatFollowsTheExtension;
var
  Format: TExportFormat;
begin
  Expect<Boolean>(ExportFormatForPath('a.gif', Format)).ToBe(True);
  Expect<Boolean>(Format = efGif).ToBe(True);
  Expect<Boolean>(ExportFormatForPath('a.Apng', Format)).ToBe(True);
  Expect<Boolean>(Format = efApng).ToBe(True);
  Expect<Boolean>(ExportFormatForPath('a.mp4', Format)).ToBe(True);
  Expect<Boolean>(Format = efMovie).ToBe(True);
  Expect<Boolean>(ExportFormatForPath('a.MOV', Format)).ToBe(True);
  Expect<Boolean>(Format = efMovie).ToBe(True);
end;

procedure TExportFormatTests.TestUnknownExtensionsAreRefused;
var
  Format: TExportFormat;
begin
  Expect<Boolean>(ExportFormatForPath('a.png', Format)).ToBe(False);
  Expect<Boolean>(ExportFormatForPath('a.webp', Format)).ToBe(False);
  Expect<Boolean>(ExportFormatForPath('a', Format)).ToBe(False);
end;

procedure TExportFormatTests.TestFormatNamesAreHumanReadable;
begin
  Expect<string>(ExportFormatName(efGif)).ToBe('GIF');
  Expect<string>(ExportFormatName(efApng)).ToBe('APNG');
  Expect<string>(ExportFormatName(efMovie)).ToBe('movie');
end;

{ TLargeExportTests }

procedure TLargeExportTests.SetupTests;
begin
  Test('an ordinary export says nothing', TestSmallExportsSaySilent);
  Test('a canvas at or past 1280x720 is worth a word',
    TestLargeCanvasWarns);
  Test('a small canvas that ran long is worth a word', TestLargeFileWarns);
  Test('the advice only names knobs that would move',
    TestAdviceOnlyNamesKnobsThatMove);
  Test('a passthrough trim has nothing to suggest',
    TestPassthroughTrimNeverWarns);
end;

procedure TLargeExportTests.TestSmallExportsSaySilent;
begin
  Expect<string>(LargeExportWarning(efGif, 800, 520, 20, 2 * 1024 * 1024))
    .ToBe('');
  Expect<string>(LargeExportWarning(efApng, 640, 400, 20, 19 * 1024 * 1024))
    .ToBe('');
end;

procedure TLargeExportTests.TestLargeCanvasWarns;
var
  Warning: string;
begin
  Warning := LargeExportWarning(efGif, 1280, 720, 20, 1024);
  Expect<Boolean>(Warning <> '').ToBe(True);
  Expect<Boolean>(Pos('1280x720', Warning) > 0).ToBe(True);
  Expect<Boolean>(Pos('--width=800', Warning) > 0).ToBe(True);
  Expect<Boolean>(Pos('--fps=15', Warning) > 0).ToBe(True);
  // The same area in a different shape still counts.
  Expect<Boolean>(LargeExportWarning(efApng, 1600, 600, 20, 1024) <> '')
    .ToBe(True);
end;

procedure TLargeExportTests.TestLargeFileWarns;
var
  Warning: string;
begin
  Warning := LargeExportWarning(efGif, 400, 300, 20, LargeExportBytes);
  Expect<Boolean>(Warning <> '').ToBe(True);
  Expect<Boolean>(Pos('20 MB', Warning) > 0).ToBe(True);
  Expect<string>(LargeExportWarning(efGif, 400, 300, 20,
    LargeExportBytes - 1)).ToBe('');
end;

// Advice nobody can act on is worse than none: a caller already at 800
// pixels and 15 fps is told to shorten the range instead.
procedure TLargeExportTests.TestAdviceOnlyNamesKnobsThatMove;
var
  Warning: string;
begin
  Warning := LargeExportWarning(efApng, 800, 520, 15, LargeExportBytes);
  Expect<Boolean>(Pos('--width', Warning) > 0).ToBe(False);
  Expect<Boolean>(Pos('--fps', Warning) > 0).ToBe(False);
  Expect<Boolean>(Pos('--trim', Warning) > 0).ToBe(True);
  Warning := LargeExportWarning(efApng, 800, 520, 30, LargeExportBytes);
  Expect<Boolean>(Pos('--width', Warning) > 0).ToBe(False);
  Expect<Boolean>(Pos('--fps=15', Warning) > 0).ToBe(True);
end;

procedure TLargeExportTests.TestPassthroughTrimNeverWarns;
begin
  Expect<string>(LargeExportWarning(efMovie, 1920, 1080, 30,
    Int64(500) * 1024 * 1024)).ToBe('');
end;

{ TDerivedValueTests }

procedure TDerivedValueTests.SetupTests;
begin
  Test('odd dimensions round down to even', TestAlignsDown);
  Test('tiny captures get the minimum bit rate', TestBitRateClampsLow);
  Test('huge captures get the maximum bit rate', TestBitRateClampsHigh);
  Test('bit rate grows with area and frame rate', TestBitRateScalesWithArea);
end;

procedure TDerivedValueTests.TestAlignsDown;
begin
  Expect<Integer>(AlignDimension(1441)).ToBe(1440);
  Expect<Integer>(AlignDimension(1440)).ToBe(1440);
  Expect<Integer>(AlignDimension(1)).ToBe(0);
end;

procedure TDerivedValueTests.TestBitRateClampsLow;
begin
  Expect<Integer>(SuggestedBitRate(16, 16, 1)).ToBe(MinBitRate);
end;

procedure TDerivedValueTests.TestBitRateClampsHigh;
begin
  Expect<Integer>(SuggestedBitRate(7680, 4320, 120)).ToBe(MaxBitRate);
end;

procedure TDerivedValueTests.TestBitRateScalesWithArea;
var
  Small, Large, Faster: Integer;
begin
  Small := SuggestedBitRate(1280, 720, 30);
  Large := SuggestedBitRate(2560, 1440, 30);
  Faster := SuggestedBitRate(1280, 720, 60);
  Expect<Boolean>(Large > Small).ToBe(True);
  Expect<Boolean>(Faster > Small).ToBe(True);
end;

{ TAfterTheStopTests }

procedure TAfterTheStopTests.SetupTests;
begin
  Test('nothing arrived and nothing was audible are different faults',
    TestSilentSourceIsToldFromAnAbsentOne);
  Test('a source that was off is never warned about',
    TestAnOffSourceSaysNothing);
  Test('a level nothing could be measured over says nothing',
    TestUnmeasuredLevelSaysNothing);
  Test('the live level note says what has arrived so far',
    TestLevelNoteNamesWhatArrived);
  Test('the big-cursor idle note fires only on a mostly idle take',
    TestBigCursorIdleOnlyFiresOnAnIdleTake);
  Test('and names the frames and the repeats among them',
    TestBigCursorIdleNamesBothCounts);
  Test('the note summary leads with the framing, not with an effect',
    TestNoteSummaryPutsTheFramingFirst);
end;

procedure TAfterTheStopTests.TestSilentSourceIsToldFromAnAbsentOne;
var
  Nothing, Silent: string;
begin
  // The distinction is the whole point of the function: "check the
  // privacy grant and the device" is the wrong advice for a muted mixer
  // and wastes an afternoon.
  Nothing := AudioSilenceWarning('system audio', True, 0, 0, 0);
  Silent := AudioSilenceWarning('system audio', True, 4000, 12, 0);
  Expect<Boolean>(Nothing <> '').ToBe(True);
  Expect<Boolean>(Silent <> '').ToBe(True);
  Expect<Boolean>(Nothing = Silent).ToBe(False);
  Expect<Boolean>(Pos('grant', Nothing) > 0).ToBe(True);
  Expect<Boolean>(Pos('muted', Silent) > 0).ToBe(True);
  // The source's own name is in both, because a take can have two.
  Expect<Boolean>(Pos('system audio', Nothing) > 0).ToBe(True);
  Expect<Boolean>(Pos('system audio', Silent) > 0).ToBe(True);
  // Audible: nothing to say.
  Expect<string>(AudioSilenceWarning('the microphone', True, 4000, 12,
    0.4)).ToBe('');
end;

procedure TAfterTheStopTests.TestAnOffSourceSaysNothing;
begin
  Expect<string>(AudioSilenceWarning('the microphone', False, 0, 0, 0))
    .ToBe('');
  Expect<string>(AudioSilenceWarning('the microphone', False, 4000, 12, 0))
    .ToBe('');
end;

procedure TAfterTheStopTests.TestUnmeasuredLevelSaysNothing;
begin
  // Samples arrived but the format could not be read, so the peak means
  // nothing. Claiming silence on that would be an accusation with no
  // evidence behind it.
  Expect<string>(AudioSilenceWarning('system audio', True, 4000, 0, 0))
    .ToBe('');
end;

procedure TAfterTheStopTests.TestLevelNoteNamesWhatArrived;
var
  Off, Waiting, Silent, Sound: string;
begin
  Off := AudioLevelNote(False, 4000, 12, 0.5);
  Waiting := AudioLevelNote(True, 0, 0, 0);
  Silent := AudioLevelNote(True, 4000, 12, 0);
  Sound := AudioLevelNote(True, 4000, 12, 0.5);
  Expect<string>(Off).ToBe('');
  Expect<Boolean>(Waiting <> '').ToBe(True);
  Expect<Boolean>(Silent <> '').ToBe(True);
  Expect<Boolean>(Sound <> '').ToBe(True);
  // Three different answers, because they are three different states —
  // and the note hangs off a menu item, so each is a few characters.
  Expect<Boolean>(Waiting = Silent).ToBe(False);
  Expect<Boolean>(Silent = Sound).ToBe(False);
  Expect<Boolean>(Length(Sound) <= 16).ToBe(True);
end;

procedure TAfterTheStopTests.TestBigCursorIdleOnlyFiresOnAnIdleTake;
begin
  // Off: never.
  Expect<string>(BigCursorIdleWarning(False, 0, 15, 16)).ToBe('');
  // On, but the screen never stopped changing: no heartbeats, nothing
  // to say.
  Expect<string>(BigCursorIdleWarning(True, 300, 0, 300)).ToBe('');
  // On, and a few heartbeats in a busy take: still nothing. The note is
  // about a take that is MOSTLY repeats, not about one that paused.
  Expect<string>(BigCursorIdleWarning(True, 290, 10, 300)).ToBe('');
  // And a take with no frames at all cannot be described.
  Expect<string>(BigCursorIdleWarning(True, 0, 0, 0)).ToBe('');
end;

procedure TAfterTheStopTests.TestBigCursorIdleNamesBothCounts;
var
  Note: string;
begin
  // The measured shape: 16 frames, 15 of them repeats, the sprite in
  // none of them.
  Note := BigCursorIdleWarning(True, 0, 15, 16);
  Expect<Boolean>(Note <> '').ToBe(True);
  Expect<Boolean>(Pos('16', Note) > 0).ToBe(True);
  Expect<Boolean>(Pos('15', Note) > 0).ToBe(True);
  // And it points at the way out rather than only naming the problem.
  Expect<Boolean>(Pos('--smooth-cursor', Note) > 0).ToBe(True);
  // Exactly at the threshold, which is a share and not a strict
  // majority: half the frames being repeats is already the take.
  Expect<Boolean>(BigCursorIdleWarning(True, 50, 50, 100) <> '').ToBe(True);
end;

procedure TAfterTheStopTests.TestNoteSummaryPutsTheFramingFirst;
begin
  // The framing note is the only one of the three about the PIXELS
  // being other than the take could account for; the other two say an
  // effect did not happen. So it leads, whatever else is set.
  Expect<string>(EffectNoteSummary('framing', 'cursor', 'zoom'))
    .ToBe('framing');
  Expect<string>(EffectNoteSummary('', 'cursor', 'zoom')).ToBe('cursor');
  Expect<string>(EffectNoteSummary('', '', 'zoom')).ToBe('zoom');
  Expect<string>(EffectNoteSummary('', '', '')).ToBe('');
  // A cosmetic zoom note can never hide the framing one, which is the
  // bug this replaced: one field, first writer wins.
  Expect<string>(EffectNoteSummary('framing', '', 'nothing was clicked'))
    .ToBe('framing');
end;

{ TRenderWordingTests }

procedure TRenderWordingTests.SetupTests;
begin
  Test('a render that applied nothing says nothing',
    TestNothingAppliedSaysNothing);
  Test('every clause appears when every fact is set',
    TestEveryClauseAppears);
  Test('re-encoded audio is shouted', TestReEncodedAudioIsShouted);
  Test('a copy does not claim work it did not do',
    TestACopyDoesNotClaimWork);
  Test('a note line is wrapped only when there is a note',
    TestNoteLinesWrapOnlyWhenThereIsANote);
  Test('a render output must be a movie container',
    TestRenderOutputMustBeAMovie);
end;

procedure TRenderWordingTests.TestNothingAppliedSaysNothing;
begin
  Expect<string>(RenderAppliedSummary(DefaultRenderAppliedFacts)).ToBe('');
end;

procedure TRenderWordingTests.TestEveryClauseAppears;
var
  Facts: TRenderAppliedFacts;
  Line: string;
begin
  Facts := DefaultRenderAppliedFacts;
  Facts.ZoomApplied := True;
  Facts.ZoomedFrames := 34;
  Facts.FramesWritten := 100;
  Facts.UsableClicks := 1;
  Facts.CursorDrawn := True;
  Facts.CursorFrames := 100;
  Facts.CursorOffFrameFrames := 2;
  Facts.SynthesizedFrames := 7;
  Facts.SynthesisFramesPerSecond := 30;
  Facts.AudioTracks := 2;
  Facts.AudioPassthrough := True;
  Facts.AudioSamples := 480;
  Line := RenderAppliedSummary(Facts);
  // The exact sentence both front ends now report. It is asserted
  // whole rather than by substring because the point of moving it here
  // was that the CLI and the MCP tool say the SAME thing, and two
  // substring checks would pass on two different sentences.
  Expect<string>(Line).ToBe(', zoom on 34 of 100 frames from 1 clicks'
    + ', pointer on 100 frames (2 off frame)'
    + ', 7 frames filled in at 30 fps where the capture had none'
    + ', 2 audio track(s) copied (480 samples, not re-encoded)');
end;

procedure TRenderWordingTests.TestReEncodedAudioIsShouted;
var
  Facts: TRenderAppliedFacts;
begin
  // The render pass has no re-encoding path, so this branch should
  // never fire — and if it ever does, it must be impossible to miss in
  // the summary rather than buried in a comment.
  Facts := DefaultRenderAppliedFacts;
  Facts.AudioTracks := 1;
  Facts.AudioSamples := 9;
  Facts.AudioPassthrough := False;
  Expect<Boolean>(Pos('RE-ENCODED', RenderAppliedSummary(Facts)) > 0)
    .ToBe(True);
  Facts.AudioPassthrough := True;
  Expect<Boolean>(Pos('RE-ENCODED', RenderAppliedSummary(Facts)) > 0)
    .ToBe(False);
  Expect<Boolean>(Pos('not re-encoded', RenderAppliedSummary(Facts)) > 0)
    .ToBe(True);
end;

procedure TRenderWordingTests.TestACopyDoesNotClaimWork;
var
  Line: string;
begin
  // A render with nothing to apply is a byte copy. Reporting
  // "1280x720, 300 frames" about one would claim an encode that never
  // happened and hide that the deliverable IS the take.
  Line := RenderSummaryLine('/tmp/demo.mp4', 1280, 720, 300, 10.0,
    5 * 1024, True, ', zoom on 12 frames');
  Expect<string>(Line).ToBe('wrote /tmp/demo.mp4: nothing to render, so '
    + 'the take was copied unchanged (5 kB)');
  Line := RenderSummaryLine('/tmp/demo.mp4', 1280, 720, 300, 10.0,
    5 * 1024, False, ', zoom on 12 frames');
  Expect<string>(Line).ToBe('wrote /tmp/demo.mp4: 1280x720, 300 frames, '
    + '10.0s, 5 kB, zoom on 12 frames');
end;

procedure TRenderWordingTests.TestNoteLinesWrapOnlyWhenThereIsANote;
begin
  Expect<string>(EffectCursorNoteLine('')).ToBe('');
  Expect<string>(EffectZoomNoteLine('')).ToBe('');
  Expect<string>(EffectCursorNoteLine('the pointer is already there'))
    .ToBe('no cursor drawn (the pointer is already there)');
  Expect<string>(EffectZoomNoteLine('nothing was clicked'))
    .ToBe('no zoom applied (nothing was clicked)');
end;

procedure TRenderWordingTests.TestRenderOutputMustBeAMovie;
var
  Error: string;
begin
  Expect<Boolean>(ValidateRenderOutputPath('/tmp/demo.mp4', Error))
    .ToBe(True);
  Expect<string>(Error).ToBe('');
  Expect<Boolean>(ValidateRenderOutputPath('/tmp/demo.mov', Error))
    .ToBe(True);
  // A render writes H.264 into a QuickTime-family container. It used to
  // write exactly that into a file called demo.gif and report success —
  // a name that lies about its contents, which is worse than a refusal.
  Expect<Boolean>(ValidateRenderOutputPath('/tmp/demo.gif', Error))
    .ToBe(False);
  Expect<string>(Error).ToBe('unsupported output extension ".gif" '
    + '(use .mp4 or .mov)');
  Expect<Boolean>(ValidateRenderOutputPath('/tmp/demo', Error))
    .ToBe(False);
  Expect<Boolean>(ValidateRenderOutputPath('', Error)).ToBe(False);
end;

{ TExportWordingTests }

procedure TExportWordingTests.SetupTests;
begin
  Test('an APNG says truecolour and nothing about a palette',
    TestAPngSaysTruecolour);
  Test('a GIF names the colours it quantised to',
    TestGifNamesItsPalette);
  Test('a histogram that overflowed says so',
    TestAnInexactPaletteIsShouted);
  Test('framing, then cursor, then zoom, then the filled frames',
    TestEveryClauseAppearsInOrder);
  Test('the whole line a finished export reports', TestTheSummaryLine);
  Test('the whole line a finished trim reports', TestTheTrimLine);
  Test('the framing note is one sentence, not two',
    TestTheFramingNoteHasOneSpelling);
end;

procedure TExportWordingTests.TestAPngSaysTruecolour;
var
  Facts: TExportAppliedFacts;
begin
  Facts := DefaultExportAppliedFacts;
  Facts.Format := efApng;
  Facts.PaletteColors := 0;
  Expect<string>(ExportAppliedSummary(Facts)).ToBe(' (truecolour)');
end;

procedure TExportWordingTests.TestGifNamesItsPalette;
var
  Facts: TExportAppliedFacts;
begin
  Facts := DefaultExportAppliedFacts;
  Facts.Format := efGif;
  Facts.PaletteColors := 255;
  Expect<string>(ExportAppliedSummary(Facts)).ToBe(' (255 colours)');
end;

procedure TExportWordingTests.TestAnInexactPaletteIsShouted;
var
  Facts: TExportAppliedFacts;
begin
  Facts := DefaultExportAppliedFacts;
  Facts.Format := efGif;
  Facts.PaletteColors := 255;
  Facts.ExactPalette := False;
  Expect<string>(ExportAppliedSummary(Facts))
    .ToBe(' (255 colours, 6-bit histogram)');
end;

procedure TExportWordingTests.TestEveryClauseAppearsInOrder;
var
  Facts: TExportAppliedFacts;
begin
  Facts := DefaultExportAppliedFacts;
  Facts.Format := efGif;
  Facts.PaletteColors := 128;
  Facts.SmoothCursor := True;
  Facts.SmoothCursorFrames := 145;
  Facts.SmoothCursorOffFrame := 3;
  Facts.ZoomOnClick := True;
  Facts.ZoomedFrames := 35;
  Facts.ZoomClicks := 1;
  Facts.SynthesizedFrames := 12;
  Facts.SynthesisFramesPerSecond := 20;
  // The whole sentence, not a substring search: the ORDER is the thing
  // under test, and a Pos() check would pass on any permutation.
  Expect<string>(ExportAppliedSummary(Facts))
    .ToBe(' (128 colours), export cursor on 145 frames (3 off frame), '
    + 'zoom on 35 frames from 1 clicks, 12 frames filled in at 20 fps '
    + 'where the capture had none');
end;

procedure TExportWordingTests.TestTheSummaryLine;
var
  Facts: TExportAppliedFacts;
begin
  Facts := DefaultExportAppliedFacts;
  Facts.Format := efApng;
  Expect<string>(ExportSummaryLine('/tmp/clip.apng', 800, 450, 60, 3.0,
    2048 * 1024, ExportAppliedSummary(Facts)))
    .ToBe('wrote /tmp/clip.apng: 800x450, 60 frames, 3.0s, 2048 kB '
    + '(truecolour)');
end;

procedure TExportWordingTests.TestTheTrimLine;
begin
  Expect<string>(TrimSummaryLine('/tmp/cut.mp4', 2, 5, 8.5, 4096 * 1024))
    .ToBe('wrote /tmp/cut.mp4: 2.00s–5.00s of 8.50s, 4096 kB '
    + '(streams copied)');
end;

procedure TExportWordingTests.TestTheFramingNoteHasOneSpelling;
begin
  Expect<string>(UnframedFramesNote(0)).ToBe('');
  // The MP4 render said "this take's" and the animation export said
  // "this recording's", about the same fact, from two copies of the
  // same Format call. One sentence now, asserted whole.
  Expect<string>(UnframedFramesNote(7))
    .ToBe('7 frame(s) run past the end of this take''s pointer track, so '
    + 'what they were showing is not recorded; nothing was cropped for '
    + 'them and the pointer was placed from the last position the track '
    + 'holds');
  // The third wrapper passes the note through unchanged; it exists so a
  // caller composes the same way for all three notes.
  Expect<string>(EffectFramingNoteLine(UnframedFramesNote(7)))
    .ToBe(UnframedFramesNote(7));
  Expect<string>(EffectFramingNoteLine('')).ToBe('');
end;

{ TCursorNamingTests }

procedure TCursorNamingTests.SetupTests;
begin
  Test('smooth-cursor, big-cursor and no-cursor all name the pointer',
    TestTheThreeCursorWordsCountAsNaming);
  Test('zoom and an empty list do not name it',
    TestZoomAndNothingDoNotName);
  Test('none names the pointer as well as the zoom',
    TestNoneNamesThePointerToo);
  Test('--cursor and --effects may say the same thing twice',
    TestAgreeingSpellingsAreAccepted);
  Test('--cursor and --effects may not disagree about it',
    TestDisagreeingSpellingsAreRefused);
  Test('either spelling on its own applies', TestEitherSpellingAloneIsFine);
  Test('an unknown --cursor word is refused by name',
    TestAnUnknownCursorWordIsRefusedByName);
  Test('the empty string is not a cursor mode',
    TestAnEmptyCursorModeIsNotParsed);
end;

procedure TCursorNamingTests.TestTheThreeCursorWordsCountAsNaming;
var
  Effects: TExportEffects;
  Named: Boolean;
  Error: string;
begin
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffectsNaming('smooth-cursor', Effects, Named,
    Error)).ToBe(True);
  Expect<Boolean>(Named).ToBe(True);
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffectsNaming('big-cursor', Effects, Named,
    Error)).ToBe(True);
  Expect<Boolean>(Named).ToBe(True);
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffectsNaming('no-cursor', Effects, Named,
    Error)).ToBe(True);
  Expect<Boolean>(Named).ToBe(True);
  // And the fourth spelling, which names the pointer by naming the value
  // it already has — the whole reason "named" is not the same question
  // as "changed".
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffectsNaming('as-recorded', Effects, Named,
    Error)).ToBe(True);
  Expect<Boolean>(Named).ToBe(True);
  Expect<Boolean>(Effects.Cursor = ecmAsRecorded).ToBe(True);
end;

procedure TCursorNamingTests.TestZoomAndNothingDoNotName;
var
  Effects: TExportEffects;
  Named: Boolean;
  Error: string;
begin
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffectsNaming('zoom', Effects, Named, Error))
    .ToBe(True);
  Expect<Boolean>(Named).ToBe(False);
  Expect<Boolean>(Effects.ZoomOnClick).ToBe(True);
  Effects := DefaultExportEffects;
  Expect<Boolean>(ParseExportEffectsNaming('', Effects, Named, Error))
    .ToBe(True);
  Expect<Boolean>(Named).ToBe(False);
end;

procedure TCursorNamingTests.TestNoneNamesThePointerToo;
var
  Effects: TExportEffects;
  Named: Boolean;
  Error: string;
begin
  // `none` is no pointer AND no zoom, so it names the pointer as surely
  // as `no-cursor` does.
  Effects := DefaultExportEffects;
  Effects.ZoomOnClick := True;
  Expect<Boolean>(ParseExportEffectsNaming('none', Effects, Named, Error))
    .ToBe(True);
  Expect<Boolean>(Named).ToBe(True);
  Expect<Boolean>(Effects.ZoomOnClick).ToBe(False);
  Expect<Boolean>(Effects.Cursor = ecmNone).ToBe(True);
end;

procedure TCursorNamingTests.TestAgreeingSpellingsAreAccepted;
var
  Effects: TExportEffects;
  Error: string;
begin
  Effects := DefaultExportEffects;
  Expect<Boolean>(ReconcileCursorAndEffects('none', 'no-cursor', Effects,
    Error)).ToBe(True);
  Expect<string>(Error).ToBe('');
  Expect<Boolean>(Effects.Cursor = ecmNone).ToBe(True);
end;

procedure TCursorNamingTests.TestDisagreeingSpellingsAreRefused;
var
  Effects: TExportEffects;
  Error: string;
begin
  Effects := DefaultExportEffects;
  Expect<Boolean>(ReconcileCursorAndEffects('big', 'smooth-cursor', Effects,
    Error)).ToBe(False);
  // The whole sentence, because it is what the user reads and both
  // offending values have to be in it.
  Expect<string>(Error).ToBe('--cursor and --effects both name the '
    + 'pointer and disagree (--cursor=big against '
    + '--effects=smooth-cursor); pass one of them');
end;

procedure TCursorNamingTests.TestEitherSpellingAloneIsFine;
var
  Effects: TExportEffects;
  Error: string;
begin
  Effects := DefaultExportEffects;
  Expect<Boolean>(ReconcileCursorAndEffects('big', '', Effects, Error))
    .ToBe(True);
  Expect<Boolean>(Effects.Cursor = ecmBig).ToBe(True);
  Effects := DefaultExportEffects;
  Expect<Boolean>(ReconcileCursorAndEffects('', 'zoom,smooth-cursor',
    Effects, Error)).ToBe(True);
  Expect<Boolean>(Effects.Cursor = ecmSmooth).ToBe(True);
  Expect<Boolean>(Effects.ZoomOnClick).ToBe(True);
end;

procedure TCursorNamingTests.TestAnUnknownCursorWordIsRefusedByName;
var
  Effects: TExportEffects;
  Error: string;
begin
  Effects := DefaultExportEffects;
  Expect<Boolean>(ReconcileCursorAndEffects('enormous', '', Effects, Error))
    .ToBe(False);
  Expect<string>(Error)
    .ToBe('--cursor must be as-recorded, none, smooth, or big');
end;

procedure TCursorNamingTests.TestAnEmptyCursorModeIsNotParsed;
var
  Mode: TExportCursorMode;
begin
  // It used to come back True as as-recorded, so a caller with nothing
  // to parse could not tell that from a caller who asked for the
  // default — which is how a saved effect default whose `cursor` key is
  // not a string silently overrode the legacy keys it was meant to
  // migrate.
  Expect<Boolean>(ParseExportCursorMode('', Mode)).ToBe(False);
  Expect<Boolean>(ParseExportCursorMode('   ', Mode)).ToBe(False);
  Expect<Boolean>(ParseExportCursorMode('as-recorded', Mode)).ToBe(True);
  Expect<Boolean>(Mode = ecmAsRecorded).ToBe(True);
end;

{ TTemporaryNameTests }

procedure TTemporaryNameTests.SetupTests;
begin
  Test('the temporary itself', TestTheTemporaryItself);
  Test('its owner marker', TestTheOwnerMarker);
  Test('AVAssetWriter''s sandbox shadow of it', TestTheSandboxShadow);
  Test('a user file that merely contains the suffix is not ours',
    TestAnOrdinaryFileIsNotOurs);
  Test('the two derived paths', TestTheDerivedPaths);
end;

procedure TTemporaryNameTests.TestTheTemporaryItself;
var
  Name: string;
begin
  Expect<Boolean>(ClassifyRenderTemporary('demo.mp4'
    + RenderTemporarySuffix, Name) = rtkTemporary).ToBe(True);
  Expect<string>(Name).ToBe('demo.mp4' + RenderTemporarySuffix);
end;

procedure TTemporaryNameTests.TestTheOwnerMarker;
var
  Name: string;
begin
  Expect<Boolean>(ClassifyRenderTemporary('demo.mp4'
    + RenderTemporarySuffix + RenderTemporaryOwnerSuffix, Name)
    = rtkOwnerMarker).ToBe(True);
  // The temporary it belongs to, so a caller can judge the whole family
  // at once.
  Expect<string>(Name).ToBe('demo.mp4' + RenderTemporarySuffix);
end;

procedure TTemporaryNameTests.TestTheSandboxShadow;
var
  Name: string;
begin
  Expect<Boolean>(ClassifyRenderTemporary('demo.mp4'
    + RenderTemporarySuffix + '.sb-1a2b3c', Name)
    = rtkSandboxShadow).ToBe(True);
  Expect<string>(Name).ToBe('demo.mp4' + RenderTemporarySuffix);
  // A bare `.sb-` with no token is not a name the framework produces.
  Expect<Boolean>(ClassifyRenderTemporary('demo.mp4'
    + RenderTemporarySuffix + '.sb-', Name) = rtkNotOurs).ToBe(True);
end;

procedure TTemporaryNameTests.TestAnOrdinaryFileIsNotOurs;
var
  Name: string;
begin
  // The file the old `*<suffix>*` glob actually destroyed.
  Expect<Boolean>(ClassifyRenderTemporary('notes'
    + RenderTemporarySuffix + '.txt', Name) = rtkNotOurs).ToBe(True);
  Expect<string>(Name).ToBe('');
  Expect<Boolean>(ClassifyRenderTemporary('demo.mp4', Name)
    = rtkNotOurs).ToBe(True);
  // Nothing but the suffix: no deliverable in front of it, so it names
  // no render either.
  Expect<Boolean>(ClassifyRenderTemporary(RenderTemporarySuffix, Name)
    = rtkNotOurs).ToBe(True);
end;

procedure TTemporaryNameTests.TestTheDerivedPaths;
var
  Name: string;
begin
  Expect<string>(RenderTemporaryPathFor('/tmp/demo.mp4'))
    .ToBe('/tmp/demo.mp4' + RenderTemporarySuffix);
  Expect<string>(RenderTemporaryOwnerPathFor('/tmp/demo.mp4'
    + RenderTemporarySuffix))
    .ToBe('/tmp/demo.mp4' + RenderTemporarySuffix
    + RenderTemporaryOwnerSuffix);
  // The round trip the render itself makes.
  Expect<Boolean>(ClassifyRenderTemporary(
    ExtractFileName(RenderTemporaryPathFor('demo.mp4')), Name)
    = rtkTemporary).ToBe(True);
end;

begin
  TestRunnerProgram.AddSuite(TRegionTests.Create('ParseCaptureRegion'));
  TestRunnerProgram.AddSuite(TContainerTests.Create('ContainerForPath'));
  TestRunnerProgram.AddSuite(TAudioModeTests.Create('ParseAudioMode'));
  TestRunnerProgram.AddSuite(TValidationTests.Create('ValidateRecordingOptions'));
  TestRunnerProgram.AddSuite(TTrimTests.Create('ParseTrimRange'));
  TestRunnerProgram.AddSuite(TExportValidationTests.Create(
    'ValidateExportOptions'));
  TestRunnerProgram.AddSuite(TRawTakePathTests.Create('raw take paths'));
  TestRunnerProgram.AddSuite(TExportFormatTests.Create('ExportFormatForPath'));
  TestRunnerProgram.AddSuite(TLargeExportTests.Create('LargeExportWarning'));
  TestRunnerProgram.AddSuite(TAfterTheStopTests.Create(
    'what knips says after a stop'));
  TestRunnerProgram.AddSuite(TDerivedValueTests.Create('derived values'));
  TestRunnerProgram.AddSuite(TRenderWordingTests.Create(
    'what a render reports, in both front ends'' words'));
  TestRunnerProgram.AddSuite(TExportWordingTests.Create(
    'what an export reports, in every front end''s words'));
  TestRunnerProgram.AddSuite(TCursorNamingTests.Create(
    'the two spellings of one pointer setting'));
  TestRunnerProgram.AddSuite(TTemporaryNameTests.Create(
    'what a render temporary is called'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

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

  TDerivedValueTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAlignsDown;
    procedure TestBitRateClampsLow;
    procedure TestBitRateClampsHigh;
    procedure TestBitRateScalesWithArea;
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
  // Zero means "the feature's own default" everywhere, so a caller that
  // fills nothing in gets the sensible thing.
  Expect<Boolean>(Options.Effects.CursorMagnification = 0).ToBe(True);
  Expect<Boolean>(Options.Effects.CursorSmoothingSeconds = 0).ToBe(True);
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
  // An empty string is the default, not an error: it is what an unset
  // --cursor looks like.
  Expect<Boolean>(ParseExportCursorMode('', Parsed)).ToBe(True);
  Expect<string>(ExportCursorModeName(Parsed)).ToBe('as-recorded');
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

begin
  TestRunnerProgram.AddSuite(TRegionTests.Create('ParseCaptureRegion'));
  TestRunnerProgram.AddSuite(TContainerTests.Create('ContainerForPath'));
  TestRunnerProgram.AddSuite(TAudioModeTests.Create('ParseAudioMode'));
  TestRunnerProgram.AddSuite(TValidationTests.Create('ValidateRecordingOptions'));
  TestRunnerProgram.AddSuite(TTrimTests.Create('ParseTrimRange'));
  TestRunnerProgram.AddSuite(TExportValidationTests.Create(
    'ValidateExportOptions'));
  TestRunnerProgram.AddSuite(TExportFormatTests.Create('ExportFormatForPath'));
  TestRunnerProgram.AddSuite(TLargeExportTests.Create('LargeExportWarning'));
  TestRunnerProgram.AddSuite(TDerivedValueTests.Create('derived values'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

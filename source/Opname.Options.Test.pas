program Opname.Options.Test;

{$I Shared.inc}

uses
  SysUtils,

  Opname.Options,
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

  TValidationTests = class(TTestSuite)
  private
    function Valid: TRecordingOptions;
  public
    procedure SetupTests; override;
    procedure TestDefaultsPlusOutputAreValid;
    procedure TestRequiresOutput;
    procedure TestRejectsBadExtension;
    procedure TestRejectsFpsOutOfRange;
    procedure TestRejectsScaleOutOfRange;
    procedure TestRejectsWindowWithRect;
    procedure TestRejectsZeroWindowId;
    procedure TestRejectsRectSmallerThanAlignment;
    procedure TestFillsContainer;
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

{ TValidationTests }

function TValidationTests.Valid: TRecordingOptions;
begin
  Result := DefaultRecordingOptions;
  Result.OutputPath := 'out.mp4';
end;

procedure TValidationTests.SetupTests;
begin
  Test('defaults plus an output path validate', TestDefaultsPlusOutputAreValid);
  Test('an output path is required', TestRequiresOutput);
  Test('unknown container extension is rejected', TestRejectsBadExtension);
  Test('fps outside 1..120 is rejected', TestRejectsFpsOutOfRange);
  Test('scale outside auto/1/2 is rejected', TestRejectsScaleOutOfRange);
  Test('--window and --rect cannot combine', TestRejectsWindowWithRect);
  Test('window target needs a window id', TestRejectsZeroWindowId);
  Test('rect smaller than the alignment is rejected',
    TestRejectsRectSmallerThanAlignment);
  Test('validation fills the container from the path', TestFillsContainer);
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
  TestRunnerProgram.AddSuite(TValidationTests.Create('ValidateRecordingOptions'));
  TestRunnerProgram.AddSuite(TDerivedValueTests.Create('derived values'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

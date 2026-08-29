program Knips.Mcp.Params.Test;

// The MCP argument mapping, on every host: the tool table, the optional
// scalar readers, the default paths, and the two builders that turn a
// tools/call arguments object into the same validated options the CLI
// builds from --flags.
//
// "On every host" is meant literally, and two things follow for the
// fixtures here. The builders return every path through ExpandFileName,
// so an expectation is the *expansion* of the literal a test passed in,
// never a POSIX rendering of it — under Wine that same call yields
// `Z:\tmp\…`. And the default recording folder is named by
// Knips.App.State's MoviesFolderName, which is 'Movies' on macOS and
// 'Videos' elsewhere, so it is referenced rather than spelled out.

{$I Knips.inc}

uses
  SysUtils,

  fpjson,
  jsonparser,
  Knips.App.State,
  Knips.Mcp.Params,
  Knips.Options,
  TestingPascalLibrary;

type
  TToolTableTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEveryToolIsNamed;
    procedure TestNamesAreUniqueAndLowerCase;
    procedure TestEveryToolIsDescribed;
  end;

  TScalarTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAbsentLeavesDefault;
    procedure TestNullCountsAsAbsent;
    procedure TestReadsInteger;
    procedure TestRejectsFractionalInteger;
    procedure TestRejectsStringForInteger;
    procedure TestReadsNumber;
    procedure TestReadsStringAndBoolean;
    procedure TestRejectsWrongStringType;
    procedure TestNilArgumentsAreAbsent;
  end;

  TDefaultPathTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRecordingPathUsesAppFolder;
    procedure TestGifSitsBesideItsInput;
    procedure TestApngSitsBesideItsInput;
    procedure TestTrimNeverOverwritesItsInput;
    procedure TestExtensionlessInputStillGetsOne;
    procedure TestRootedPathKnowsBothFamilies;
  end;

  TRecordingArgumentTests = class(TTestSuite)
  private
    function Build(const AJson: string;
      out ARecording: TRecordingOptions; out AError: string): Boolean;
  public
    procedure SetupTests; override;
    procedure TestEmptyArgumentsUseTheDefaultPath;
    procedure TestExplicitOutWins;
    procedure TestRegionNeedsAllFourSides;
    procedure TestRegionIsRead;
    procedure TestRejectsNegativeRegionOrigin;
    procedure TestWindowSelectsWindowTarget;
    procedure TestWindowAndDisplayAreExclusive;
    procedure TestAudioModeIsParsed;
    procedure TestRejectsUnknownAudioMode;
    procedure TestScaleAutoAndInteger;
    procedure TestCursorFlag;
    procedure TestBigCursorFlag;
    procedure TestValidationStillApplies;
    procedure TestRejectsBadOutputExtension;
    procedure TestRejectsNegativeDisplayIndex;
    procedure TestOutputPathComesBackAbsolute;
  end;

  TOverwriteTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAbsentFileIsAlwaysWritable;
    procedure TestExistingFileIsRefused;
    procedure TestOverwriteTrueAllowsIt;
    procedure TestOverwriteMustBeBoolean;
  end;

  TExportArgumentTests = class(TTestSuite)
  private
    function Build(const AJson: string; AFormat: TExportFormat;
      out AExport: TExportOptions; out AError: string): Boolean;
  public
    procedure SetupTests; override;
    procedure TestGifDefaultsBesideInput;
    procedure TestRequiresInput;
    procedure TestRejectsFormatMismatch;
    procedure TestAcceptsMatchingExplicitOut;
    procedure TestTrimEndAloneIsARange;
    procedure TestTrimStartAloneIsARange;
    procedure TestNoTrimLeavesNoRange;
    procedure TestTrimIsRequiredForAMovie;
    procedure TestRejectsFpsOutOfRange;
    procedure TestDitherDefaultsOn;
    procedure TestTrimRefusesInapplicableArguments;
    procedure TestPathsComeBackAbsolute;
  end;

  TMessageTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRenamesBareFlags;
    procedure TestRenamesFlagPhrasesBeforeFlags;
    procedure TestPointsAtTheRightTool;
    procedure TestLeavesOrdinaryTextAlone;
    procedure TestLeavesCallerTextAlone;
    procedure TestRewriterClearsEveryReachableMessage;
  end;

  TSummaryTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRecordingSummaryNamesThePath;
    procedure TestExportSummaryNamesTheFormat;
  end;

function ParseArguments(const AJson: string): TJSONObject;
begin
  Result := GetJSON(AJson) as TJSONObject;
end;

// Whether a path is rooted, in either family's spelling. FPC 3.2.2's
// SysUtils has no portable predicate for this, and the old test asked
// `Path[1] = PathDelim`, which is false by construction for `C:\x` — it
// is what the Wine smoke caught. No production code asks the question at
// all: Knips.Mcp.Params calls ExpandFileName and trusts the RTL, so this
// stays here, beside the two tests that need it.
//
// Accepted: a leading `/` (POSIX, and the separator ExpandFileName keeps
// there); a `\\server\share` UNC prefix; and a `X:\` or `X:/` drive
// root. Both families' shapes are accepted on every host rather than
// under a conditional, so the suite makes one claim, not two — the cost is
// that `C:\x`, a legal *relative* file name on POSIX, would read as
// absolute here. Nothing feeds this anything but ExpandFileName output.
function IsRootedPath(const APath: string): Boolean;
begin
  Result := True;
  if (Length(APath) >= 1) and (APath[1] = '/') then
    Exit;
  if (Length(APath) >= 2) and (APath[1] = '\') and (APath[2] = '\') then
    Exit;
  if (Length(APath) >= 3) and (APath[2] = ':')
    and (((APath[1] >= 'A') and (APath[1] <= 'Z'))
    or ((APath[1] >= 'a') and (APath[1] <= 'z')))
    and ((APath[3] = '\') or (APath[3] = '/')) then
    Exit;
  Result := False;
end;

{ TToolTableTests }

procedure TToolTableTests.SetupTests;
begin
  Test('every tool has a name', TestEveryToolIsNamed);
  Test('names are unique and wire-shaped', TestNamesAreUniqueAndLowerCase);
  Test('every tool has a description', TestEveryToolIsDescribed);
end;

procedure TToolTableTests.TestEveryToolIsNamed;
begin
  Expect<string>(KnipsMcpToolName(kmtListDisplays)).ToBe('list_displays');
  Expect<string>(KnipsMcpToolName(kmtListWindows)).ToBe('list_windows');
  Expect<string>(KnipsMcpToolName(kmtRecordStart)).ToBe('record_start');
  Expect<string>(KnipsMcpToolName(kmtRecordStop)).ToBe('record_stop');
  Expect<string>(KnipsMcpToolName(kmtRecordStatus)).ToBe('record_status');
  Expect<string>(KnipsMcpToolName(kmtExportGif)).ToBe('export_gif');
  Expect<string>(KnipsMcpToolName(kmtExportApng)).ToBe('export_apng');
  Expect<string>(KnipsMcpToolName(kmtExportTrim)).ToBe('export_trim');
end;

procedure TToolTableTests.TestNamesAreUniqueAndLowerCase;
var
  Tool, Other: TKnipsMcpTool;
  Name: string;
  I: Integer;
begin
  for Tool := Low(TKnipsMcpTool) to High(TKnipsMcpTool) do
  begin
    Name := KnipsMcpToolName(Tool);
    Expect<string>(Name).ToBe(LowerCase(Name));
    for I := 1 to Length(Name) do
      Expect<Boolean>(Name[I] in ['a'..'z', '_']).ToBe(True);
    for Other := Low(TKnipsMcpTool) to High(TKnipsMcpTool) do
      if Other <> Tool then
        Expect<Boolean>(KnipsMcpToolName(Other) = Name).ToBe(False);
  end;
end;

procedure TToolTableTests.TestEveryToolIsDescribed;
var
  Tool: TKnipsMcpTool;
begin
  // A tool an agent cannot tell apart from another is a tool it will
  // pick wrong; the description is the whole selection surface.
  for Tool := Low(TKnipsMcpTool) to High(TKnipsMcpTool) do
    Expect<Boolean>(Length(KnipsMcpToolDescription(Tool)) > 30).ToBe(True);
end;

{ TScalarTests }

procedure TScalarTests.SetupTests;
begin
  Test('an absent argument leaves the default', TestAbsentLeavesDefault);
  Test('an explicit null counts as absent', TestNullCountsAsAbsent);
  Test('reads an integer', TestReadsInteger);
  Test('rejects a fractional integer', TestRejectsFractionalInteger);
  Test('rejects a string where an integer belongs',
    TestRejectsStringForInteger);
  Test('reads a fractional number', TestReadsNumber);
  Test('reads a string and a boolean', TestReadsStringAndBoolean);
  Test('rejects a number where a string belongs',
    TestRejectsWrongStringType);
  Test('nil arguments read as all-absent', TestNilArgumentsAreAbsent);
end;

procedure TScalarTests.TestAbsentLeavesDefault;
var
  Arguments: TJSONObject;
  Value: Integer;
  Error: string;
begin
  Arguments := ParseArguments('{}');
  try
    Value := 30;
    Expect<Boolean>(McpOptionalInteger(Arguments, 'fps', Value,
      Error)).ToBe(True);
    Expect<Integer>(Value).ToBe(30);
    Expect<string>(Error).ToBe('');
  finally
    Arguments.Free;
  end;
end;

procedure TScalarTests.TestNullCountsAsAbsent;
var
  Arguments: TJSONObject;
  Value: Integer;
  Error: string;
begin
  // Clients that fill every declared property send null for the ones
  // the user left blank; that has to mean "unset", not "zero".
  Arguments := ParseArguments('{"fps": null}');
  try
    Value := 30;
    Expect<Boolean>(McpHasArgument(Arguments, 'fps')).ToBe(False);
    Expect<Boolean>(McpOptionalInteger(Arguments, 'fps', Value,
      Error)).ToBe(True);
    Expect<Integer>(Value).ToBe(30);
  finally
    Arguments.Free;
  end;
end;

procedure TScalarTests.TestReadsInteger;
var
  Arguments: TJSONObject;
  Value: Integer;
  Error: string;
begin
  Arguments := ParseArguments('{"fps": 24, "width": 800.0}');
  try
    Value := 0;
    Expect<Boolean>(McpOptionalInteger(Arguments, 'fps', Value,
      Error)).ToBe(True);
    Expect<Integer>(Value).ToBe(24);
    // JSON has one number type; 800.0 is a whole number and is taken.
    Value := 0;
    Expect<Boolean>(McpOptionalInteger(Arguments, 'width', Value,
      Error)).ToBe(True);
    Expect<Integer>(Value).ToBe(800);
  finally
    Arguments.Free;
  end;
end;

procedure TScalarTests.TestRejectsFractionalInteger;
var
  Arguments: TJSONObject;
  Value: Integer;
  Error: string;
begin
  Arguments := ParseArguments('{"fps": 23.976}');
  try
    Value := 30;
    Expect<Boolean>(McpOptionalInteger(Arguments, 'fps', Value,
      Error)).ToBe(False);
    Expect<Boolean>(Pos('fps', Error) > 0).ToBe(True);
  finally
    Arguments.Free;
  end;
end;

procedure TScalarTests.TestRejectsStringForInteger;
var
  Arguments: TJSONObject;
  Value: Integer;
  Error: string;
begin
  Arguments := ParseArguments('{"fps": "30"}');
  try
    Value := 30;
    Expect<Boolean>(McpOptionalInteger(Arguments, 'fps', Value,
      Error)).ToBe(False);
    Expect<Boolean>(Error <> '').ToBe(True);
  finally
    Arguments.Free;
  end;
end;

procedure TScalarTests.TestReadsNumber;
var
  Arguments: TJSONObject;
  Value: Double;
  Error: string;
begin
  Arguments := ParseArguments('{"trim_start": 1.5}');
  try
    Value := 0;
    Expect<Boolean>(McpOptionalNumber(Arguments, 'trim_start', Value,
      Error)).ToBe(True);
    Expect<Boolean>(Abs(Value - 1.5) < 1E-9).ToBe(True);
  finally
    Arguments.Free;
  end;
end;

procedure TScalarTests.TestReadsStringAndBoolean;
var
  Arguments: TJSONObject;
  Text: string;
  Flag: Boolean;
  Error: string;
begin
  Arguments := ParseArguments('{"audio": "system", "cursor": false}');
  try
    Text := '';
    Flag := True;
    Expect<Boolean>(McpOptionalString(Arguments, 'audio', Text,
      Error)).ToBe(True);
    Expect<string>(Text).ToBe('system');
    Expect<Boolean>(McpOptionalBoolean(Arguments, 'cursor', Flag,
      Error)).ToBe(True);
    Expect<Boolean>(Flag).ToBe(False);
  finally
    Arguments.Free;
  end;
end;

procedure TScalarTests.TestRejectsWrongStringType;
var
  Arguments: TJSONObject;
  Text: string;
  Error: string;
begin
  Arguments := ParseArguments('{"audio": 1}');
  try
    Text := 'none';
    Expect<Boolean>(McpOptionalString(Arguments, 'audio', Text,
      Error)).ToBe(False);
    Expect<string>(Text).ToBe('none');
  finally
    Arguments.Free;
  end;
end;

procedure TScalarTests.TestNilArgumentsAreAbsent;
var
  Value: Integer;
  Error: string;
begin
  // tools/call may omit "arguments" entirely for a no-argument tool.
  Value := 7;
  Expect<Boolean>(McpHasArgument(nil, 'fps')).ToBe(False);
  Expect<Boolean>(McpOptionalInteger(nil, 'fps', Value, Error)).ToBe(True);
  Expect<Integer>(Value).ToBe(7);
end;

{ TDefaultPathTests }

procedure TDefaultPathTests.SetupTests;
begin
  Test('a recording defaults into ~/Movies/knips/',
    TestRecordingPathUsesAppFolder);
  Test('a GIF sits beside its input', TestGifSitsBesideItsInput);
  Test('an APNG sits beside its input', TestApngSitsBesideItsInput);
  Test('a trim never overwrites its input',
    TestTrimNeverOverwritesItsInput);
  Test('an extension-less input still gets one',
    TestExtensionlessInputStillGetsOne);
  Test('the rooted-path check knows both families',
    TestRootedPathKnowsBothFamilies);
end;

procedure TDefaultPathTests.TestRecordingPathUsesAppFolder;
var
  Path: string;
begin
  // Spelled out except for the two things the host decides: the
  // separator, and MoviesFolderName ('Movies' on macOS, 'Videos'
  // elsewhere — Knips.App.State). Naming them is what makes this one
  // expectation true everywhere; the folder nesting, the prefix and the
  // timestamp format are still asserted literally.
  Path := DefaultMcpRecordingPath('/Users/tester',
    EncodeDate(2026, 8, 27) + EncodeTime(14, 5, 9, 0));
  Expect<string>(Path).ToBe('/Users/tester' + PathDelim
    + MoviesFolderName + PathDelim + 'knips' + PathDelim
    + 'knips-20260827-140509.mp4');
end;

procedure TDefaultPathTests.TestGifSitsBesideItsInput;
begin
  Expect<string>(DefaultMcpExportPath('/tmp/clip.mp4',
    efGif)).ToBe('/tmp/clip.gif');
end;

procedure TDefaultPathTests.TestApngSitsBesideItsInput;
begin
  Expect<string>(DefaultMcpExportPath('/tmp/clip.mov',
    efApng)).ToBe('/tmp/clip.apng');
end;

procedure TDefaultPathTests.TestTrimNeverOverwritesItsInput;
var
  Path: string;
begin
  Path := DefaultMcpExportPath('/tmp/clip.mp4', efMovie);
  Expect<string>(Path).ToBe('/tmp/clip-trim.mp4');
  Expect<Boolean>(SameText(Path, '/tmp/clip.mp4')).ToBe(False);
end;

procedure TDefaultPathTests.TestExtensionlessInputStillGetsOne;
var
  Path: string;
begin
  Path := DefaultMcpExportPath('/tmp/clip', efGif);
  Expect<Boolean>(SameText(Path, '/tmp/clip')).ToBe(False);
  Expect<Boolean>(Pos('.gif', Path) > 0).ToBe(True);
end;

procedure TDefaultPathTests.TestRootedPathKnowsBothFamilies;
begin
  // IsRootedPath is what the two "comes back absolute" tests assert
  // through, so it gets its own coverage rather than being trusted: a
  // helper that answered True to everything would make both of them
  // vacuous, which is precisely the failure mode the old
  // `Path[1] = PathDelim` had in the other direction.
  Expect<Boolean>(IsRootedPath('/tmp/clip.mp4')).ToBe(True);
  Expect<Boolean>(IsRootedPath('C:\clip.mp4')).ToBe(True);
  Expect<Boolean>(IsRootedPath('c:/clip.mp4')).ToBe(True);
  Expect<Boolean>(IsRootedPath('\\server\share\clip.mp4')).ToBe(True);
  Expect<Boolean>(IsRootedPath('clip.mp4')).ToBe(False);
  Expect<Boolean>(IsRootedPath('sub/clip.mp4')).ToBe(False);
  Expect<Boolean>(IsRootedPath('sub\clip.mp4')).ToBe(False);
  Expect<Boolean>(IsRootedPath('C:clip.mp4')).ToBe(False);
  Expect<Boolean>(IsRootedPath('')).ToBe(False);
  // Whatever the host's own ExpandFileName produces is rooted by it.
  Expect<Boolean>(IsRootedPath(ExpandFileName('clip.mp4'))).ToBe(True);
end;

{ TRecordingArgumentTests }

function TRecordingArgumentTests.Build(const AJson: string;
  out ARecording: TRecordingOptions; out AError: string): Boolean;
var
  Arguments: TJSONObject;
begin
  Arguments := ParseArguments(AJson);
  try
    Result := BuildMcpRecordingOptions(Arguments, '/tmp/default.mp4',
      ARecording, AError);
  finally
    Arguments.Free;
  end;
end;

procedure TRecordingArgumentTests.SetupTests;
begin
  Test('no arguments record the main display to the default path',
    TestEmptyArgumentsUseTheDefaultPath);
  Test('an explicit out wins over the default', TestExplicitOutWins);
  Test('a partial region is refused', TestRegionNeedsAllFourSides);
  Test('a complete region is read', TestRegionIsRead);
  Test('a region cannot start off the display',
    TestRejectsNegativeRegionOrigin);
  Test('a window id selects the window target',
    TestWindowSelectsWindowTarget);
  Test('window and display are mutually exclusive',
    TestWindowAndDisplayAreExclusive);
  Test('the audio mode is parsed', TestAudioModeIsParsed);
  Test('an unknown audio mode is refused', TestRejectsUnknownAudioMode);
  Test('scale takes auto or an integer', TestScaleAutoAndInteger);
  Test('the cursor can be turned off', TestCursorFlag);
  Test('a big cursor can be asked for', TestBigCursorFlag);
  Test('the shared validation still applies',
    TestValidationStillApplies);
  Test('a non-movie out extension is refused',
    TestRejectsBadOutputExtension);
  Test('a negative display index is refused',
    TestRejectsNegativeDisplayIndex);
  Test('the output path comes back absolute',
    TestOutputPathComesBackAbsolute);
end;

procedure TRecordingArgumentTests.TestEmptyArgumentsUseTheDefaultPath;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  // BuildMcpRecordingOptions expands every path it returns, so what the
  // fixture gets back is the expansion of the default it was handed —
  // '/tmp/default.mp4' on POSIX, 'Z:\tmp\default.mp4' under Wine. The
  // claim under test is *which* path was chosen, so it is expressed the
  // same way: the expansion of that literal, not a POSIX rendering of it.
  Expect<Boolean>(Build('{}', Recording, Error)).ToBe(True);
  Expect<string>(Recording.OutputPath)
    .ToBe(ExpandFileName('/tmp/default.mp4'));
  Expect<Integer>(Recording.DisplayIndex).ToBe(-1);
  Expect<Boolean>(Recording.TargetKind = ctkDisplay).ToBe(True);
  Expect<Boolean>(Recording.HasRegion).ToBe(False);
  Expect<Integer>(Recording.FramesPerSecond).ToBe(DefaultFramesPerSecond);
  Expect<Boolean>(Recording.AudioMode = amNone).ToBe(True);
  Expect<Boolean>(Recording.ShowsCursor).ToBe(True);
end;

procedure TRecordingArgumentTests.TestExplicitOutWins;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"out": "/tmp/mine.mov"}', Recording,
    Error)).ToBe(True);
  Expect<string>(Recording.OutputPath)
    .ToBe(ExpandFileName('/tmp/mine.mov'));
  // And it is *not* the default the builder was handed.
  Expect<Boolean>(SameText(Recording.OutputPath,
    ExpandFileName('/tmp/default.mp4'))).ToBe(False);
  Expect<Boolean>(Recording.Container = ocQuickTime).ToBe(True);
end;

procedure TRecordingArgumentTests.TestRegionNeedsAllFourSides;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"left": 0, "top": 0, "width": 640}', Recording,
    Error)).ToBe(False);
  Expect<Boolean>(Pos('all four', Error) > 0).ToBe(True);
end;

procedure TRecordingArgumentTests.TestRegionIsRead;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"left": 10, "top": 20, "width": 640, '
    + '"height": 480}', Recording, Error)).ToBe(True);
  Expect<Boolean>(Recording.HasRegion).ToBe(True);
  Expect<Integer>(Recording.Region.Left).ToBe(10);
  Expect<Integer>(Recording.Region.Top).ToBe(20);
  Expect<Integer>(Recording.Region.Width).ToBe(640);
  Expect<Integer>(Recording.Region.Height).ToBe(480);
end;

procedure TRecordingArgumentTests.TestRejectsNegativeRegionOrigin;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"left": -1, "top": 0, "width": 640, '
    + '"height": 480}', Recording, Error)).ToBe(False);
  Expect<Boolean>(Error <> '').ToBe(True);
end;

procedure TRecordingArgumentTests.TestWindowSelectsWindowTarget;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"window": 4211}', Recording, Error)).ToBe(True);
  Expect<Boolean>(Recording.TargetKind = ctkWindow).ToBe(True);
  Expect<Boolean>(Recording.WindowID = 4211).ToBe(True);
end;

procedure TRecordingArgumentTests.TestWindowAndDisplayAreExclusive;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"window": 4211, "display": 0}', Recording,
    Error)).ToBe(False);
  Expect<Boolean>(Pos('exclusive', Error) > 0).ToBe(True);
end;

procedure TRecordingArgumentTests.TestAudioModeIsParsed;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"audio": "both"}', Recording, Error)).ToBe(True);
  Expect<Boolean>(Recording.AudioMode = amBoth).ToBe(True);
  // Validation fills the derived audio format once a mode is on.
  Expect<Integer>(Recording.AudioSampleRate).ToBe(DefaultAudioSampleRate);
  Expect<Integer>(Recording.AudioChannelCount).ToBe(
    DefaultAudioChannelCount);
end;

procedure TRecordingArgumentTests.TestRejectsUnknownAudioMode;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"audio": "surround"}', Recording,
    Error)).ToBe(False);
  Expect<Boolean>(Pos('audio', Error) > 0).ToBe(True);
end;

procedure TRecordingArgumentTests.TestScaleAutoAndInteger;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"scale": "auto"}', Recording, Error)).ToBe(True);
  Expect<Integer>(Recording.Scale).ToBe(ScaleAuto);
  Expect<Boolean>(Build('{"scale": "2"}', Recording, Error)).ToBe(True);
  Expect<Integer>(Recording.Scale).ToBe(2);
  Expect<Boolean>(Build('{"scale": "half"}', Recording, Error)).ToBe(False);
end;

procedure TRecordingArgumentTests.TestCursorFlag;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"cursor": false}', Recording, Error)).ToBe(True);
  Expect<Boolean>(Recording.ShowsCursor).ToBe(False);
end;

procedure TRecordingArgumentTests.TestBigCursorFlag;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  // Absent means off, and off is what every recording made before this
  // argument existed got.
  Expect<Boolean>(Build('{}', Recording, Error)).ToBe(True);
  Expect<Boolean>(Recording.BigCursor).ToBe(False);
  Expect<Boolean>(Build('{"big_cursor": true}', Recording, Error)).ToBe(True);
  Expect<Boolean>(Recording.BigCursor).ToBe(True);
  Expect<Boolean>(Recording.ShowsCursor).ToBe(True);
  // The two cursor arguments contradict each other. The builder hands
  // back the shared message in the CLI's words — Knips.Mcp rewrites it
  // at the one boundary where every failure becomes an MCP result — so
  // what is checked here is that the rewrite leaves an agent nothing it
  // has never seen, AND that it says which value of which key to change.
  // "cursor and big_cursor are mutually exclusive" was true of the flags
  // and useless as advice: both arguments are booleans, and the two that
  // clash are `false` and `true` rather than the keys themselves.
  Expect<Boolean>(Build('{"big_cursor": true, "cursor": false}', Recording,
    Error)).ToBe(False);
  Expect<string>(McpArgumentMessage(Error))
    .ToBe('"cursor": false and "big_cursor": true are mutually '
    + 'exclusive: one asks for no pointer and the other for a bigger '
    + 'one. Pass exactly one of them');
  // A window recording cannot have one; the reason travels unchanged.
  Expect<Boolean>(Build('{"big_cursor": true, "window": 42}', Recording,
    Error)).ToBe(False);
  Expect<Boolean>(Pos('display recordings only', Error) > 0).ToBe(True);
end;

procedure TRecordingArgumentTests.TestValidationStillApplies;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  // The range rule lives in Knips.Options and is reached through the
  // builder, so MCP and the CLI refuse the same fps in the same words.
  Expect<Boolean>(Build('{"fps": 500}', Recording, Error)).ToBe(False);
  Expect<Boolean>(Pos('fps', Error) > 0).ToBe(True);
end;

procedure TRecordingArgumentTests.TestRejectsBadOutputExtension;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"out": "/tmp/clip.gif"}', Recording,
    Error)).ToBe(False);
  Expect<Boolean>(Pos('.mp4', Error) > 0).ToBe(True);
end;

procedure TRecordingArgumentTests.TestRejectsNegativeDisplayIndex;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  // -1 is the internal main-display sentinel, not a request a client
  // may make: display:-7 used to record the main display full-screen
  // and say nothing about the index it ignored.
  Expect<Boolean>(Build('{"display": -7}', Recording, Error)).ToBe(False);
  Expect<Boolean>(Pos('list_displays', Error) > 0).ToBe(True);
  Expect<Boolean>(Build('{"display": -1}', Recording, Error)).ToBe(False);
  // Absent still means the main display.
  Expect<Boolean>(Build('{}', Recording, Error)).ToBe(True);
  Expect<Integer>(Recording.DisplayIndex).ToBe(-1);
  Expect<Boolean>(Build('{"display": 0}', Recording, Error)).ToBe(True);
  Expect<Integer>(Recording.DisplayIndex).ToBe(0);
end;

procedure TRecordingArgumentTests.TestOutputPathComesBackAbsolute;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  // An agent cannot resolve a relative path against a working directory
  // it never saw, so what comes back has to be absolute.
  Expect<Boolean>(Build('{"out": "clip.mp4"}', Recording, Error))
    .ToBe(True);
  Expect<Boolean>(IsRootedPath(Recording.OutputPath)).ToBe(True);
  Expect<string>(Recording.OutputPath).ToBe(ExpandFileName('clip.mp4'));
  // An already-rooted path is taken as given rather than resolved
  // against the working directory: same name, same rooted shape, and
  // the same directory the caller asked for.
  Expect<Boolean>(Build('{"out": "/tmp/clip.mp4"}', Recording, Error))
    .ToBe(True);
  Expect<Boolean>(IsRootedPath(Recording.OutputPath)).ToBe(True);
  Expect<string>(ExtractFileName(Recording.OutputPath)).ToBe('clip.mp4');
  Expect<string>(Recording.OutputPath)
    .ToBe(ExpandFileName('/tmp/clip.mp4'));
end;

{ TOverwriteTests }

procedure TOverwriteTests.SetupTests;
begin
  Test('a path that does not exist is always writable',
    TestAbsentFileIsAlwaysWritable);
  Test('an existing path is refused by default',
    TestExistingFileIsRefused);
  Test('overwrite: true allows it', TestOverwriteTrueAllowsIt);
  Test('overwrite must be a boolean', TestOverwriteMustBeBoolean);
end;

procedure TOverwriteTests.TestAbsentFileIsAlwaysWritable;
var
  Arguments: TJSONObject;
  Error: string;
begin
  Arguments := ParseArguments('{}');
  try
    Expect<Boolean>(McpMayWriteRecording(Arguments, '/tmp/new.mp4',
      False, Error)).ToBe(True);
    Expect<string>(Error).ToBe('');
  finally
    Arguments.Free;
  end;
end;

procedure TOverwriteTests.TestExistingFileIsRefused;
var
  Arguments: TJSONObject;
  Error: string;
begin
  // The CLI replaces without asking, because a person typed the path.
  // An agent guesses, and a guess that lands on last week's recording
  // destroys it with nothing to undo.
  Arguments := ParseArguments('{}');
  try
    Expect<Boolean>(McpMayWriteRecording(Arguments, '/tmp/old.mp4',
      True, Error)).ToBe(False);
    Expect<Boolean>(Pos('/tmp/old.mp4', Error) > 0).ToBe(True);
    Expect<Boolean>(Pos('overwrite', Error) > 0).ToBe(True);
  finally
    Arguments.Free;
  end;
  Arguments := ParseArguments('{"overwrite": false}');
  try
    Expect<Boolean>(McpMayWriteRecording(Arguments, '/tmp/old.mp4',
      True, Error)).ToBe(False);
  finally
    Arguments.Free;
  end;
end;

procedure TOverwriteTests.TestOverwriteTrueAllowsIt;
var
  Arguments: TJSONObject;
  Error: string;
begin
  Arguments := ParseArguments('{"overwrite": true}');
  try
    Expect<Boolean>(McpMayWriteRecording(Arguments, '/tmp/old.mp4',
      True, Error)).ToBe(True);
  finally
    Arguments.Free;
  end;
end;

procedure TOverwriteTests.TestOverwriteMustBeBoolean;
var
  Arguments: TJSONObject;
  Error: string;
begin
  Arguments := ParseArguments('{"overwrite": "yes"}');
  try
    Expect<Boolean>(McpMayWriteRecording(Arguments, '/tmp/old.mp4',
      False, Error)).ToBe(False);
    Expect<Boolean>(Pos('overwrite', Error) > 0).ToBe(True);
  finally
    Arguments.Free;
  end;
end;

{ TExportArgumentTests }

function TExportArgumentTests.Build(const AJson: string;
  AFormat: TExportFormat; out AExport: TExportOptions;
  out AError: string): Boolean;
var
  Arguments: TJSONObject;
begin
  Arguments := ParseArguments(AJson);
  try
    Result := BuildMcpExportOptions(Arguments, AFormat, AExport, AError);
  finally
    Arguments.Free;
  end;
end;

procedure TExportArgumentTests.SetupTests;
begin
  Test('a GIF defaults beside its input', TestGifDefaultsBesideInput);
  Test('an input movie is required', TestRequiresInput);
  Test('an out that disagrees with the tool is refused',
    TestRejectsFormatMismatch);
  Test('an out that agrees with the tool is taken',
    TestAcceptsMatchingExplicitOut);
  Test('trim_end alone is a range', TestTrimEndAloneIsARange);
  Test('trim_start alone is a range', TestTrimStartAloneIsARange);
  Test('no trim leaves no range', TestNoTrimLeavesNoRange);
  Test('a movie output needs a trim', TestTrimIsRequiredForAMovie);
  Test('the shared fps range still applies', TestRejectsFpsOutOfRange);
  Test('dithering is on unless turned off', TestDitherDefaultsOn);
  Test('a trim refuses arguments it cannot honour',
    TestTrimRefusesInapplicableArguments);
  Test('in and out come back absolute', TestPathsComeBackAbsolute);
end;

procedure TExportArgumentTests.TestGifDefaultsBesideInput;
var
  Options: TExportOptions;
  Error: string;
begin
  // BuildMcpExportOptions expands the input first and derives the
  // output from the expanded path, so the expectation is the expansion
  // of the sibling name — the literal it used to spell out is only the
  // POSIX rendering of that.
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4"}', efGif, Options,
    Error)).ToBe(True);
  Expect<string>(Options.OutputPath).ToBe(ExpandFileName('/tmp/clip.gif'));
  // "Beside its input" is the actual claim: same directory, same stem.
  Expect<string>(ExtractFilePath(Options.OutputPath))
    .ToBe(ExtractFilePath(Options.InputPath));
  Expect<string>(ExtractFileName(Options.OutputPath)).ToBe('clip.gif');
  Expect<Boolean>(Options.Format = efGif).ToBe(True);
  Expect<Integer>(Options.FramesPerSecond).ToBe(
    DefaultGifFramesPerSecond);
  Expect<Integer>(Options.Width).ToBe(GifWidthFromSource);
end;

procedure TExportArgumentTests.TestRequiresInput;
var
  Options: TExportOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{}', efGif, Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('"in"', Error) > 0).ToBe(True);
end;

procedure TExportArgumentTests.TestRejectsFormatMismatch;
var
  Options: TExportOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4", "out": "/tmp/x.apng"}',
    efGif, Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('APNG', Error) > 0).ToBe(True);
end;

procedure TExportArgumentTests.TestAcceptsMatchingExplicitOut;
var
  Options: TExportOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4", "out": "/tmp/x.apng"}',
    efApng, Options, Error)).ToBe(True);
  Expect<string>(Options.OutputPath).ToBe(ExpandFileName('/tmp/x.apng'));
end;

procedure TExportArgumentTests.TestTrimEndAloneIsARange;
var
  Options: TExportOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4", "trim_end": 3.5}', efGif,
    Options, Error)).ToBe(True);
  Expect<Boolean>(Options.HasTrim).ToBe(True);
  Expect<Boolean>(Options.HasTrimEnd).ToBe(True);
  Expect<Boolean>(Abs(Options.TrimEndSeconds - 3.5) < 1E-9).ToBe(True);
  Expect<Boolean>(Options.TrimStartSeconds = 0).ToBe(True);
end;

procedure TExportArgumentTests.TestTrimStartAloneIsARange;
var
  Options: TExportOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4", "trim_start": 2}', efGif,
    Options, Error)).ToBe(True);
  Expect<Boolean>(Options.HasTrim).ToBe(True);
  Expect<Boolean>(Options.HasTrimEnd).ToBe(False);
end;

procedure TExportArgumentTests.TestNoTrimLeavesNoRange;
var
  Options: TExportOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4"}', efGif, Options,
    Error)).ToBe(True);
  Expect<Boolean>(Options.HasTrim).ToBe(False);
end;

procedure TExportArgumentTests.TestTrimIsRequiredForAMovie;
var
  Options: TExportOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4"}', efMovie, Options,
    Error)).ToBe(False);
  Expect<Boolean>(Pos('trim', Error) > 0).ToBe(True);
  // With a range it is the passthrough trim, written beside the input.
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4", "trim_start": 1.5, '
    + '"trim_end": 3.5}', efMovie, Options, Error)).ToBe(True);
  Expect<string>(Options.OutputPath)
    .ToBe(ExpandFileName('/tmp/clip-trim.mp4'));
  // And beside the input rather than over it — the point of the suffix.
  Expect<string>(ExtractFilePath(Options.OutputPath))
    .ToBe(ExtractFilePath(Options.InputPath));
  Expect<Boolean>(SameText(Options.OutputPath, Options.InputPath))
    .ToBe(False);
  Expect<Boolean>(Options.Format = efMovie).ToBe(True);
end;

procedure TExportArgumentTests.TestRejectsFpsOutOfRange;
var
  Options: TExportOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4", "fps": 0}', efGif,
    Options, Error)).ToBe(False);
  Expect<Boolean>(Pos('fps', Error) > 0).ToBe(True);
end;

procedure TExportArgumentTests.TestDitherDefaultsOn;
var
  Options: TExportOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4"}', efGif, Options,
    Error)).ToBe(True);
  Expect<Boolean>(Options.Dither).ToBe(True);
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4", "dither": false}', efGif,
    Options, Error)).ToBe(True);
  Expect<Boolean>(Options.Dither).ToBe(False);
end;

procedure TExportArgumentTests.TestTrimRefusesInapplicableArguments;
const
  Inapplicable: array[0..2] of string = ('"fps": 10', '"width": 320',
    '"dither": false');
var
  Options: TExportOptions;
  Error: string;
  I: Integer;
begin
  // The SDK ignores arguments a schema does not declare, so without
  // this an agent that asked export_trim for width 320 would get an
  // unscaled movie and no hint that the request was dropped.
  for I := Low(Inapplicable) to High(Inapplicable) do
  begin
    Expect<Boolean>(Build('{"in": "/tmp/clip.mp4", "trim_end": 2, '
      + Inapplicable[I] + '}', efMovie, Options, Error)).ToBe(False);
    Expect<Boolean>(Pos('passthrough trim', Error) > 0).ToBe(True);
  end;
  // The same arguments are fine on the tools that can honour them.
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4", "width": 320}', efGif,
    Options, Error)).ToBe(True);
end;

procedure TExportArgumentTests.TestPathsComeBackAbsolute;
var
  Options: TExportOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"in": "clip.mp4"}', efGif, Options, Error))
    .ToBe(True);
  Expect<string>(Options.InputPath).ToBe(ExpandFileName('clip.mp4'));
  // The default output is derived from the expanded input, so it is
  // absolute too — and still sits beside it.
  Expect<string>(Options.OutputPath).ToBe(ExpandFileName('clip.gif'));
  Expect<Boolean>(IsRootedPath(Options.InputPath)).ToBe(True);
  Expect<Boolean>(IsRootedPath(Options.OutputPath)).ToBe(True);
  // An explicit relative out is expanded as well.
  Expect<Boolean>(Build('{"in": "/tmp/clip.mp4", "out": "o.gif"}', efGif,
    Options, Error)).ToBe(True);
  Expect<string>(Options.OutputPath).ToBe(ExpandFileName('o.gif'));
end;

{ TMessageTests }

procedure TMessageTests.SetupTests;
begin
  Test('a bare flag becomes its argument name', TestRenamesBareFlags);
  Test('a phrase is rewritten before the flag inside it',
    TestRenamesFlagPhrasesBeforeFlags);
  Test('it points at the tool, not the subcommand',
    TestPointsAtTheRightTool);
  Test('ordinary text is left alone', TestLeavesOrdinaryTextAlone);
  Test('caller-supplied text is never rewritten',
    TestLeavesCallerTextAlone);
  Test('every reachable message comes out of the rewriter flag-free',
    TestRewriterClearsEveryReachableMessage);
end;

procedure TMessageTests.TestRenamesBareFlags;
begin
  Expect<string>(McpArgumentMessage('--fps must be between 1 and 50'))
    .ToBe('fps must be between 1 and 50');
  Expect<string>(McpArgumentMessage(
    'an output path is required (--out=demo.mp4)'))
    .ToBe('an output path is required (out=demo.mp4)');
  Expect<string>(McpArgumentMessage('--in and --out are the same file'))
    .ToBe('in and out are the same file');
end;

procedure TMessageTests.TestRenamesFlagPhrasesBeforeFlags;
var
  Line: string;
begin
  // '--trim' is a prefix of the example that follows it, so the longer
  // phrase has to win or the example comes out mangled.
  Line := McpArgumentMessage('a movie output is a passthrough trim, so '
    + '--trim is required (--trim=1.5,3.5)');
  Expect<string>(Line).ToBe('a movie output is a passthrough trim, so '
    + 'trim_start/trim_end is required (trim_start=1.5 and trim_end=3.5)');
  Expect<string>(McpArgumentMessage(
    '--window and --rect are mutually exclusive'))
    .ToBe('a window and a region are mutually exclusive');
end;

procedure TMessageTests.TestPointsAtTheRightTool;
begin
  Expect<string>(McpArgumentMessage(
    '--window needs a non-zero window id (see `knips windows`)'))
    .ToBe('window needs a non-zero window id (see list_windows)');
end;

procedure TMessageTests.TestLeavesOrdinaryTextAlone;
begin
  Expect<string>(McpArgumentMessage(
    'unsupported output extension ".png" (use .mp4 or .mov)'))
    .ToBe('unsupported output extension ".png" (use .mp4 or .mov)');
  Expect<string>(McpArgumentMessage('')).ToBe('');
end;

procedure TMessageTests.TestLeavesCallerTextAlone;
var
  Arguments: TJSONObject;
  Options: TExportOptions;
  Error: string;
begin
  // The rewrites are anchored to token boundaries, so a flag-looking
  // run inside the caller's own text — which these templates
  // interpolate verbatim — is not touched. Reporting an extension the
  // caller never passed is worse than reporting a flag.
  Expect<string>(McpArgumentMessage(
    'unsupported output extension ".--fps" (use .mp4 or .mov)'))
    .ToBe('unsupported output extension ".--fps" (use .mp4 or .mov)');
  Expect<string>(McpArgumentMessage('no such file: /tmp/--width/x.mp4'))
    .ToBe('no such file: /tmp/--width/x.mp4');
  Expect<string>(McpArgumentMessage('cannot replace /tmp/a--out.mov'))
    .ToBe('cannot replace /tmp/a--out.mov');
  // End to end: the extension really does come back verbatim.
  Arguments := ParseArguments('{"in": "/tmp/clip.--fps"}');
  try
    Expect<Boolean>(BuildMcpExportOptions(Arguments, efGif, Options,
      Error)).ToBe(False);
    Expect<Boolean>(Pos('".--fps"', McpArgumentMessage(Error)) > 0)
      .ToBe(True);
  finally
    Arguments.Free;
  end;
end;

procedure TMessageTests.TestRewriterClearsEveryReachableMessage;
const
  // Every refusal an MCP client can provoke through the builders.
  RecordingCases: array[0..7] of string = (
    '{"out": "/tmp/x.png"}',
    '{"fps": 500}',
    '{"scale": "3"}',
    '{"bitrate": -1}',
    '{"window": 0}',
    '{"window": 12, "left": 0, "top": 0, "width": 1, "height": 1}',
    '{"left": 0, "top": 0, "width": 1, "height": 1}',
    '{"display": -7}');
  ExportCases: array[0..4] of string = (
    '{"in": "/tmp/x.png"}',
    '{"in": "/tmp/x.mp4", "fps": 500}',
    '{"in": "/tmp/x.mp4", "width": 4}',
    '{"in": "/tmp/x.mp4", "trim_start": 3, "trim_end": 1}',
    '{"in": "/tmp/x.mp4", "out": "/tmp/x.mp4"}');
  // The session and pipeline layers refuse in --flags too, and those
  // messages reach a client through Knips.Mcp's error boundary rather
  // than through a builder. They are stable literals in
  // Knips.Recording / Knips.Export.Pipeline, so they are pinned here:
  // if one is reworded upstream, this test stops proving anything and
  // should be updated with it.
  SessionMessages: array[0..3] of string = (
    'no on-screen window with id 12 (see `knips windows`)',
    'no display at index 3 (see `knips displays`)',
    '--rect exceeds the display (1800x1169 points)',
    '--trim starts at 5.00s but the movie is 2.90s long');
var
  Arguments: TJSONObject;
  Recording: TRecordingOptions;
  Options: TExportOptions;
  Error: string;
  I: Integer;
begin
  for I := Low(RecordingCases) to High(RecordingCases) do
  begin
    Arguments := ParseArguments(RecordingCases[I]);
    try
      Expect<Boolean>(BuildMcpRecordingOptions(Arguments, '/tmp/d.mp4',
        Recording, Error)).ToBe(False);
      Expect<Boolean>(Error <> '').ToBe(True);
      Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0)
        .ToBe(False);
    finally
      Arguments.Free;
    end;
  end;
  for I := Low(ExportCases) to High(ExportCases) do
  begin
    Arguments := ParseArguments(ExportCases[I]);
    try
      Expect<Boolean>(BuildMcpExportOptions(Arguments, efGif, Options,
        Error)).ToBe(False);
      Expect<Boolean>(Error <> '').ToBe(True);
      Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0)
        .ToBe(False);
    finally
      Arguments.Free;
    end;
  end;
  // The movie tool's own refusals.
  Arguments := ParseArguments('{"in": "/tmp/x.mp4"}');
  try
    Expect<Boolean>(BuildMcpExportOptions(Arguments, efMovie, Options,
      Error)).ToBe(False);
    Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0).ToBe(False);
  finally
    Arguments.Free;
  end;
  Arguments := ParseArguments('{"in": "/tmp/x.mp4", "trim_start": 0}');
  try
    Expect<Boolean>(BuildMcpExportOptions(Arguments, efMovie, Options,
      Error)).ToBe(False);
    Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0).ToBe(False);
  finally
    Arguments.Free;
  end;
  // And the layers a builder never sees.
  for I := Low(SessionMessages) to High(SessionMessages) do
  begin
    // The fixture really does carry something to be rewritten — a
    // `--flag` or a `knips <command>` — because without this the two
    // assertions below would pass just as well on a message that never
    // had one, which is the one thing they must not do. (This used to
    // assert a value against itself, which is true of anything.)
    Expect<Boolean>((Pos('--', SessionMessages[I]) > 0)
      or (Pos('knips ', SessionMessages[I]) > 0)).ToBe(True);
    Expect<Boolean>(Pos('--', McpArgumentMessage(SessionMessages[I])) > 0)
      .ToBe(False);
    Expect<Boolean>(Pos('knips ',
      McpArgumentMessage(SessionMessages[I])) > 0).ToBe(False);
  end;
  Expect<string>(McpArgumentMessage(SessionMessages[1]))
    .ToBe('no display at index 3 (see list_displays)');
  Expect<string>(McpArgumentMessage(SessionMessages[2]))
    .ToBe('a region of left/top/width/height exceeds the display '
    + '(1800x1169 points)');
end;

{ TSummaryTests }

procedure TSummaryTests.SetupTests;
begin
  Test('a recording summary names its file',
    TestRecordingSummaryNamesThePath);
  Test('an export summary names its format',
    TestExportSummaryNamesTheFormat);
end;

procedure TSummaryTests.TestRecordingSummaryNamesThePath;
var
  Line: string;
begin
  Line := McpRecordingSummary('/tmp/clip.mp4', 1280, 720, 4.25, 128, 1, 0);
  Expect<Boolean>(Pos('/tmp/clip.mp4', Line) > 0).ToBe(True);
  Expect<Boolean>(Pos('1280x720', Line) > 0).ToBe(True);
  Expect<Boolean>(Pos('128 frames', Line) > 0).ToBe(True);
end;

procedure TSummaryTests.TestExportSummaryNamesTheFormat;
var
  Line: string;
begin
  Line := McpExportSummary('/tmp/clip.gif', efGif, 800, 450, 60, 3.0,
    2048 * 1024);
  Expect<Boolean>(Pos('GIF', Line) > 0).ToBe(True);
  Expect<Boolean>(Pos('2048 kB', Line) > 0).ToBe(True);
end;

begin
  TestRunnerProgram.AddSuite(TToolTableTests.Create('tool table'));
  TestRunnerProgram.AddSuite(TScalarTests.Create('optional arguments'));
  TestRunnerProgram.AddSuite(TDefaultPathTests.Create('default paths'));
  TestRunnerProgram.AddSuite(TRecordingArgumentTests.Create(
    'BuildMcpRecordingOptions'));
  TestRunnerProgram.AddSuite(TOverwriteTests.Create(
    'McpMayWriteRecording'));
  TestRunnerProgram.AddSuite(TExportArgumentTests.Create(
    'BuildMcpExportOptions'));
  TestRunnerProgram.AddSuite(TMessageTests.Create('McpArgumentMessage'));
  TestRunnerProgram.AddSuite(TSummaryTests.Create('result summaries'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

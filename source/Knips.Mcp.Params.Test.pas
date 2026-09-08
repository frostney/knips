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
  Knips.Recording.Sidecar,
  TestingPascalLibrary;

type
  TToolTableTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEveryToolIsNamed;
    procedure TestNamesAreUniqueAndLowerCase;
    procedure TestEveryToolIsDescribed;
  end;

  TOutputSchemaTests = class(TTestSuite)
  private
    function SchemaOf(ATool: TKnipsMcpTool): TJSONObject;
  public
    procedure SetupTests; override;
    procedure TestEverySchemaParses;
    procedure TestEveryRequiredKeyIsDeclared;
    procedure TestTheNewToolsPromiseTheirAnswers;
    procedure TestUnconditionalKeysAreRequired;
    procedure TestTheExportsDeclareWhatTheyEmit;
    procedure TestAPayloadIsCheckedAgainstItsOwnSchema;
    procedure TestEveryToolHasReadableProperties;
  end;

  TRenderArgumentTests = class(TTestSuite)
  private
    function Refuses(const AJson: string; out AError: string): Boolean;
  public
    procedure SetupTests; override;
    procedure TestRescalingArgumentsPointAtTheExports;
    procedure TestRangeArgumentsPointAtTheTrim;
    procedure TestTheEffectsAndPathsAreStillAccepted;
  end;

  TEffectArgumentTests = class(TTestSuite)
  private
    function Read(const AJson: string; out AEffects: TExportEffects;
      out AError: string): Boolean;
  public
    procedure SetupTests; override;
    procedure TestDefaultsAreAsRecordedAndNoZoom;
    procedure TestZoomIsRead;
    procedure TestEveryCursorModeIsRead;
    procedure TestRejectsUnknownCursorMode;
    procedure TestRejectsWrongTypes;
    procedure TestExportCarriesThem;
    procedure TestTrimRefusesThemWithAPointerAtRender;
  end;

  TTakeInfoTests = class(TTestSuite)
  private
    function Info(const ASidecar: string): TJSONObject;
  public
    procedure SetupTests; override;
    procedure TestNoSidecarSaysSo;
    procedure TestRawTakeOffersBoth;
    procedure TestBakedCursorClosesTheCursor;
    procedure TestNoClicksClosesTheZoom;
    procedure TestReportsTheTrackDensity;
    procedure TestNamesTheRenderOutput;
    procedure TestUsableClicksIsTheRendersOwnCount;
    procedure TestASparseTrackSaysSoInWords;
    procedure TestEveryKeyItCarriesIsDeclared;
    procedure TestItReportsWhatTheLoaderCouldNotUse;
  end;

  TScalarTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAbsentLeavesDefault;
    procedure TestNullCountsAsAbsent;
    procedure TestReadsInteger;
    procedure TestRejectsFractionalInteger;
    procedure TestRejectsStringForInteger;
    procedure TestRejectsAnIntegerOutsideTheSignedRange;
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
    procedure TestRenderOfARawTakeIsTheDeliverable;
    procedure TestRenderOfAnythingElseSitsBesideIt;
    procedure TestRenderNeverWritesOverItsInput;
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
    procedure TestSmoothCursorFlag;
    procedure TestSmoothCursorTakesTheRawName;
    procedure TestAnExplicitOutIsNeverRenamed;
    procedure TestSmoothCursorExclusionsStillApply;
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
    procedure TestSparseTrackNoteOnlyForARawTake;
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
  Expect<string>(KnipsMcpToolName(kmtTakeInfo)).ToBe('take_info');
  Expect<string>(KnipsMcpToolName(kmtRecordStart)).ToBe('record_start');
  Expect<string>(KnipsMcpToolName(kmtRecordStop)).ToBe('record_stop');
  Expect<string>(KnipsMcpToolName(kmtRecordStatus)).ToBe('record_status');
  Expect<string>(KnipsMcpToolName(kmtRender)).ToBe('render');
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
  Tool, Other: TKnipsMcpTool;
begin
  // A tool an agent cannot tell apart from another is a tool it will
  // pick wrong; the description is the whole selection surface. So the
  // check is that they DIFFER, not merely that each is long enough —
  // ten identical thirty-character descriptions would have passed the
  // old assertion and told a client nothing.
  for Tool := Low(TKnipsMcpTool) to High(TKnipsMcpTool) do
  begin
    Expect<Boolean>(Length(KnipsMcpToolDescription(Tool)) > 30).ToBe(True);
    for Other := Low(TKnipsMcpTool) to High(TKnipsMcpTool) do
      if Other <> Tool then
        Expect<Boolean>(KnipsMcpToolDescription(Other)
          = KnipsMcpToolDescription(Tool)).ToBe(False);
    // And no flag spellings: a description is the one place a client is
    // told what a tool does, and `--out` is not an argument it has.
    Expect<Boolean>(Pos('--', KnipsMcpToolDescription(Tool)) > 0)
      .ToBe(False);
  end;
end;

{ TOutputSchemaTests }

procedure TOutputSchemaTests.SetupTests;
begin
  Test('every output schema is valid JSON', TestEverySchemaParses);
  Test('every required key is a declared property',
    TestEveryRequiredKeyIsDeclared);
  Test('the render and take_info answers are promised',
    TestTheNewToolsPromiseTheirAnswers);
  Test('an always-emitted key is a required key',
    TestUnconditionalKeysAreRequired);
  Test('the exports declare the six fields they always emitted',
    TestTheExportsDeclareWhatTheyEmit);
  Test('a payload is checked against its own schema, key by key',
    TestAPayloadIsCheckedAgainstItsOwnSchema);
  Test('every tool''s property list is readable',
    TestEveryToolHasReadableProperties);
end;

function TOutputSchemaTests.SchemaOf(ATool: TKnipsMcpTool): TJSONObject;
begin
  Result := GetJSON(KnipsMcpOutputSchema(ATool)) as TJSONObject;
end;

procedure TOutputSchemaTests.TestEverySchemaParses;
var
  Tool: TKnipsMcpTool;
  Schema: TJSONObject;
begin
  // These are hand-written JSON in a Pascal string literal, concatenated
  // across a dozen lines. Nothing else in the program parses them — the
  // SDK hands an outputSchema through to the client untouched — so a
  // missing comma would ship as a tool whose schema no client can read.
  for Tool := Low(TKnipsMcpTool) to High(TKnipsMcpTool) do
  begin
    Schema := SchemaOf(Tool);
    try
      Expect<string>(Schema.Get('type', '')).ToBe('object');
      Expect<Boolean>(Schema.Find('properties') <> nil).ToBe(True);
      Expect<Boolean>(Schema.Find('properties').JSONType = jtObject)
        .ToBe(True);
    finally
      Schema.Free;
    end;
  end;
end;

procedure TOutputSchemaTests.TestEveryRequiredKeyIsDeclared;
var
  Tool: TKnipsMcpTool;
  Schema, Properties: TJSONObject;
  Required: TJSONArray;
  I: Integer;
begin
  // A "required" naming a property the schema does not declare is a
  // promise about a field whose type nobody stated — which is worse than
  // no promise, because a client validating against it fails on a
  // perfectly good result.
  for Tool := Low(TKnipsMcpTool) to High(TKnipsMcpTool) do
  begin
    Schema := SchemaOf(Tool);
    try
      Properties := Schema.Find('properties') as TJSONObject;
      Expect<Boolean>(Schema.Find('required') <> nil).ToBe(True);
      Required := Schema.Find('required') as TJSONArray;
      Expect<Boolean>(Required.Count > 0).ToBe(True);
      for I := 0 to Required.Count - 1 do
      begin
        Expect<Boolean>(Required[I].JSONType = jtString).ToBe(True);
        Expect<Boolean>(Properties.Find(Required[I].AsString) <> nil)
          .ToBe(True);
      end;
    finally
      Schema.Free;
    end;
  end;
end;

procedure TOutputSchemaTests.TestTheNewToolsPromiseTheirAnswers;
var
  Schema, Properties: TJSONObject;
begin
  // The fields a client plans against. Pinned by name, because a rename
  // on one side of this pair is invisible until an agent asks for a
  // field that is no longer there.
  Schema := SchemaOf(kmtTakeInfo);
  try
    Properties := Schema.Find('properties') as TJSONObject;
    Expect<Boolean>(Properties.Find('can_draw_cursor') <> nil).ToBe(True);
    Expect<Boolean>(Properties.Find('can_zoom_on_click') <> nil)
      .ToBe(True);
    Expect<Boolean>(Properties.Find('raw') <> nil).ToBe(True);
    Expect<Boolean>(Properties.Find('max_sample_gap_seconds') <> nil)
      .ToBe(True);
    Expect<Boolean>(Properties.Find('render_output_path') <> nil)
      .ToBe(True);
  finally
    Schema.Free;
  end;
  Schema := SchemaOf(kmtRender);
  try
    Properties := Schema.Find('properties') as TJSONObject;
    // Asked for, and reached the pixels: both, because they are
    // different questions and only the pair answers "did I get it".
    Expect<Boolean>(Properties.Find('zoom') <> nil).ToBe(True);
    Expect<Boolean>(Properties.Find('cursor') <> nil).ToBe(True);
    Expect<Boolean>(Properties.Find('zoom_applied') <> nil).ToBe(True);
    Expect<Boolean>(Properties.Find('cursor_drawn') <> nil).ToBe(True);
    Expect<Boolean>(Properties.Find('copied') <> nil).ToBe(True);
    // …and NOT the one-line summary of the three notes. A JSON object
    // has room for all three, so carrying the summary as well would be
    // one of them repeated under a fourth name.
    Expect<Boolean>(Properties.Find('note') = nil).ToBe(True);
  finally
    Schema.Free;
  end;
end;

procedure TOutputSchemaTests.TestUnconditionalKeysAreRequired;

  procedure PinRequired(ATool: TKnipsMcpTool;
    const AKeys: array of string);
  var
    Schema: TJSONObject;
    Required: TJSONArray;
    I, J: Integer;
    Found: Boolean;
  begin
    Schema := SchemaOf(ATool);
    try
      Required := Schema.Find('required') as TJSONArray;
      for I := Low(AKeys) to High(AKeys) do
      begin
        Found := False;
        for J := 0 to Required.Count - 1 do
          if Required[J].AsString = AKeys[I] then
            Found := True;
        Expect<Boolean>(Found).ToBe(True);
      end;
    finally
      Schema.Free;
    end;
  end;

begin
  // "required" lists the keys EVERY path through a handler emits — the
  // rule this unit states about its own schemas. These eight on the
  // render and four on the exports were emitted unconditionally and
  // promised conditionally, which tells a client to guard for an
  // absence that cannot happen; pinned here so they stay promised.
  PinRequired(kmtRender, ['zoomed_frames', 'clicks', 'cursor_frames',
    'cursor_off_frame_frames', 'synthesis_fps', 'unframed_frames',
    'audio_samples', 'realtime_factor']);
  PinRequired(kmtExportGif, ['zoomed_frames', 'clicks', 'cursor_frames',
    'cursor_off_frame_frames']);
  PinRequired(kmtExportApng, ['zoomed_frames', 'clicks', 'cursor_frames',
    'cursor_off_frame_frames']);
end;

procedure TOutputSchemaTests.TestTheExportsDeclareWhatTheyEmit;

  procedure PinDeclaredAndRequired(ATool: TKnipsMcpTool;
    const AKeys: array of string);
  var
    Schema, Properties: TJSONObject;
    Required: TJSONArray;
    I, J: Integer;
    Found: Boolean;
  begin
    Schema := SchemaOf(ATool);
    try
      Properties := Schema.Find('properties') as TJSONObject;
      Required := Schema.Find('required') as TJSONArray;
      for I := Low(AKeys) to High(AKeys) do
      begin
        Expect<Boolean>(Properties.Find(AKeys[I]) <> nil).ToBe(True);
        Found := False;
        for J := 0 to Required.Count - 1 do
          if Required[J].AsString = AKeys[I] then
            Found := True;
        Expect<Boolean>(Found).ToBe(True);
      end;
    finally
      Schema.Free;
    end;
  end;

begin
  // The six the export handlers emitted on every successful path and
  // this schema did not declare at all — a GIF's palette among them,
  // which is the single biggest fact about what the file looks like. A
  // client validating structuredContent in strict mode rejected a good
  // export over them; one planning against the schema could not see
  // them. Emitted unconditionally, so promised unconditionally.
  PinDeclaredAndRequired(kmtExportGif, ['palette_colors', 'exact_palette',
    'sampled_frames', 'synthesized_frames', 'synthesis_fps',
    'unframed_frames', 'sidecar_skipped_lines']);
  PinDeclaredAndRequired(kmtExportApng, ['palette_colors',
    'exact_palette', 'sampled_frames', 'synthesized_frames',
    'synthesis_fps', 'unframed_frames', 'sidecar_skipped_lines']);
  // The render says it too, and take_info answers it for a take nobody
  // has rendered yet.
  PinDeclaredAndRequired(kmtRender, ['sidecar_skipped_lines']);
end;

procedure TOutputSchemaTests.TestAPayloadIsCheckedAgainstItsOwnSchema;
var
  Payload: TJSONObject;
begin
  // The check itself, on a payload built to be wrong. This is what runs
  // at the one place every structured result leaves the server
  // (Knips.Mcp.KnipsStructuredResult), so a payload that outgrows its
  // schema says so on the first call rather than at the next audit.
  Payload := TJSONObject.Create(['path', '/tmp/demo.gif',
    'palette_colors', 255]);
  try
    Expect<string>(McpUndeclaredPayloadKeys(kmtExportGif, Payload))
      .ToBe('');
  finally
    Payload.Free;
  end;
  Payload := TJSONObject.Create(['path', '/tmp/demo.gif',
    'invented_field', 3]);
  try
    Expect<string>(McpUndeclaredPayloadKeys(kmtExportGif, Payload))
      .ToBe('invented_field');
  finally
    Payload.Free;
  end;
  // Every offender named, not just the first: a schema that has fallen
  // this far behind is fixed in one pass or not at all.
  Payload := TJSONObject.Create(['first_invention', 1,
    'second_invention', 2]);
  try
    Expect<string>(McpUndeclaredPayloadKeys(kmtRender, Payload))
      .ToBe('first_invention, second_invention');
  finally
    Payload.Free;
  end;
  // A tool with no payload at all is not an offender.
  Expect<string>(McpUndeclaredPayloadKeys(kmtRender, nil)).ToBe('');
end;

procedure TOutputSchemaTests.TestEveryToolHasReadableProperties;
var
  Tool: TKnipsMcpTool;
  Names: TMcpKeyArray;
  Schema, Properties: TJSONObject;
begin
  // The parse the check above depends on. An unreadable schema would
  // make every key look undeclared, which is a loud failure rather than
  // a silent one — but only if the parse is exercised on every host.
  for Tool := Low(TKnipsMcpTool) to High(TKnipsMcpTool) do
  begin
    Names := KnipsMcpSchemaProperties(Tool);
    Expect<Boolean>(Length(Names) > 0).ToBe(True);
    Schema := SchemaOf(Tool);
    try
      Properties := Schema.Find('properties') as TJSONObject;
      Expect<Integer>(Length(Names)).ToBe(Properties.Count);
    finally
      Schema.Free;
    end;
  end;
end;

{ TRenderArgumentTests }

procedure TRenderArgumentTests.SetupTests;
begin
  Test('fps/width/dither point at the animation exports',
    TestRescalingArgumentsPointAtTheExports);
  Test('trim_start/trim_end point at export_trim',
    TestRangeArgumentsPointAtTheTrim);
  Test('the arguments render does take are untouched',
    TestTheEffectsAndPathsAreStillAccepted);
end;

function TRenderArgumentTests.Refuses(const AJson: string;
  out AError: string): Boolean;
var
  Arguments: TJSONObject;
begin
  Arguments := ParseArguments(AJson);
  try
    Result := not McpRenderRefusesArguments(Arguments, AError);
  finally
    Arguments.Free;
  end;
end;

procedure TRenderArgumentTests.TestRescalingArgumentsPointAtTheExports;
const
  Cases: array[0..2] of string = ('{"width": 320}', '{"fps": 10}',
    '{"dither": false}');
var
  Error: string;
  I: Integer;
begin
  // The SDK ignores properties a schema does not declare, so a render
  // asked to scale would silently write a full-size movie. Refused, and
  // the refusal names the tool that can actually do it.
  for I := Low(Cases) to High(Cases) do
  begin
    Expect<Boolean>(Refuses(Cases[I], Error)).ToBe(True);
    Expect<Boolean>(Pos('export_gif', Error) > 0).ToBe(True);
    Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0).ToBe(False);
  end;
end;

procedure TRenderArgumentTests.TestRangeArgumentsPointAtTheTrim;
const
  Cases: array[0..1] of string = ('{"trim_start": 1}', '{"trim_end": 2}');
var
  Error: string;
  I: Integer;
begin
  for I := Low(Cases) to High(Cases) do
  begin
    Expect<Boolean>(Refuses(Cases[I], Error)).ToBe(True);
    Expect<Boolean>(Pos('export_trim', Error) > 0).ToBe(True);
    Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0).ToBe(False);
  end;
end;

procedure TRenderArgumentTests.TestTheEffectsAndPathsAreStillAccepted;
var
  Error: string;
begin
  Expect<Boolean>(Refuses('{}', Error)).ToBe(False);
  Expect<Boolean>(Refuses('{"in": "/tmp/x-raw.mp4", "out": "/tmp/x.mp4", '
    + '"overwrite": true, "zoom": true, "cursor": "smooth"}', Error))
    .ToBe(False);
  // An explicit null is "unset" here as everywhere else, so a client
  // that fills every property it knows of is not refused for it.
  Expect<Boolean>(Refuses('{"width": null, "trim_end": null}', Error))
    .ToBe(False);
end;

{ TScalarTests }

procedure TScalarTests.SetupTests;
begin
  Test('an absent argument leaves the default', TestAbsentLeavesDefault);
  Test('an explicit null counts as absent', TestNullCountsAsAbsent);
  Test('reads an integer', TestReadsInteger);
  Test('rejects a fractional integer', TestRejectsFractionalInteger);
  Test('rejects a whole number outside the 32-bit signed range',
    TestRejectsAnIntegerOutsideTheSignedRange);
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

procedure TScalarTests.TestRejectsAnIntegerOutsideTheSignedRange;
var
  Arguments: TJSONObject;
  Value: Integer;
  Error: string;
begin
  // `{"width": 4294971392}` is a whole number and legal JSON, and it
  // used to reach `AValue: Integer` as a truncating Int64 assignment:
  // the client got `Tool execution failed: Range check error`, a leaked
  // implementation detail where a refusal naming the argument belonged.
  Arguments := ParseArguments('{"width": 4294971392}');
  try
    Value := 800;
    Expect<Boolean>(McpOptionalInteger(Arguments, 'width', Value,
      Error)).ToBe(False);
    Expect<Boolean>(Pos('width', Error) > 0).ToBe(True);
    Expect<Boolean>(Pos('out of range', Error) > 0).ToBe(True);
    // Refused, and the caller's value untouched: a refusal that half
    // applied itself would be worse than the range check error.
    Expect<Integer>(Value).ToBe(800);
  finally
    Arguments.Free;
  end;
  // The other end, and the same answer.
  Arguments := ParseArguments('{"width": -4294971392}');
  try
    Value := 800;
    Expect<Boolean>(McpOptionalInteger(Arguments, 'width', Value,
      Error)).ToBe(False);
    Expect<Integer>(Value).ToBe(800);
  finally
    Arguments.Free;
  end;
  // And the boundaries themselves are inside the range, so the check is
  // a range check and not an off-by-one.
  Arguments := ParseArguments('{"width": 2147483647}');
  try
    Value := 0;
    Expect<Boolean>(McpOptionalInteger(Arguments, 'width', Value,
      Error)).ToBe(True);
    Expect<Integer>(Value).ToBe(2147483647);
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
  Test('a render of a raw take writes the deliverable',
    TestRenderOfARawTakeIsTheDeliverable);
  Test('a render of anything else sits beside it',
    TestRenderOfAnythingElseSitsBesideIt);
  Test('a render never writes over its own input',
    TestRenderNeverWritesOverItsInput);
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

procedure TDefaultPathTests.TestRenderOfARawTakeIsTheDeliverable;
begin
  // Identical to what `knips render` derives, which is the point: the
  // pair on disk is the same pair whichever face of knips made it.
  Expect<string>(DefaultMcpRenderPath('/tmp/demo-raw.mp4'))
    .ToBe('/tmp/demo.mp4');
  Expect<string>(DefaultMcpRenderPath('/tmp/demo-raw.mov'))
    .ToBe('/tmp/demo.mov');
end;

procedure TDefaultPathTests.TestRenderOfAnythingElseSitsBesideIt;
begin
  // The CLI demands --out here. Over MCP the input already names a
  // directory — which is the whole content of the CLI's asymmetry — so
  // refusing would buy nothing.
  Expect<string>(DefaultMcpRenderPath('/tmp/demo.mp4'))
    .ToBe('/tmp/demo-rendered.mp4');
  Expect<string>(DefaultMcpRenderPath('')).ToBe('');
end;

procedure TDefaultPathTests.TestRenderNeverWritesOverItsInput;
var
  Inputs: array[0..2] of string = ('/tmp/demo.mp4', '/tmp/demo-raw.mp4',
    '/tmp/a.b.mov');
  I: Integer;
begin
  // The raw take is what makes the effects changeable later, so a
  // derived output that landed on the input would destroy exactly the
  // thing the model exists to keep. TRenderSession refuses in = out
  // outright, and this is the rule that means it never has to.
  for I := Low(Inputs) to High(Inputs) do
    Expect<Boolean>(SameText(DefaultMcpRenderPath(Inputs[I]), Inputs[I]))
      .ToBe(False);
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
  Test('a smooth cursor can be asked for', TestSmoothCursorFlag);
  Test('a smooth-cursor default path is a raw take''s',
    TestSmoothCursorTakesTheRawName);
  Test('an explicit out is never renamed',
    TestAnExplicitOutIsNeverRenamed);
  Test('the smooth cursor''s exclusions still apply',
    TestSmoothCursorExclusionsStillApply);
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

procedure TRecordingArgumentTests.TestSmoothCursorFlag;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"out": "/tmp/clip.mp4"}', Recording, Error))
    .ToBe(True);
  Expect<Boolean>(Recording.SmoothCursor).ToBe(False);
  Expect<Boolean>(Build('{"out": "/tmp/clip.mp4", '
    + '"smooth_cursor": true}', Recording, Error)).ToBe(True);
  Expect<Boolean>(Recording.SmoothCursor).ToBe(True);
  // The pointer is left out of the pixels, which is a different setting
  // from "no pointer wanted" and must not have turned that one on.
  Expect<Boolean>(Recording.ShowsCursor).ToBe(True);
  Expect<Boolean>(Recording.BigCursor).ToBe(False);
end;

procedure TRecordingArgumentTests.TestSmoothCursorTakesTheRawName;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  // The derived name only. A raw take is not the deliverable, and
  // naming it as though it were is what makes a client render over its
  // own raw material later.
  Expect<Boolean>(Build('{"smooth_cursor": true}', Recording, Error))
    .ToBe(True);
  Expect<Boolean>(IsRawTakePath(Recording.OutputPath)).ToBe(True);
  // …and the deliverable render would write from it is the plain name
  // the default would have had.
  Expect<string>(DefaultMcpRenderPath(Recording.OutputPath))
    .ToBe(DeliverablePathFor(Recording.OutputPath));
  Expect<Boolean>(Build('{}', Recording, Error)).ToBe(True);
  Expect<Boolean>(IsRawTakePath(Recording.OutputPath)).ToBe(False);
  // A big cursor is finished pixels — still zoomable, but nothing is
  // waiting to be put into it — so it keeps the plain name.
  Expect<Boolean>(Build('{"big_cursor": true}', Recording, Error))
    .ToBe(True);
  Expect<Boolean>(IsRawTakePath(Recording.OutputPath)).ToBe(False);
end;

procedure TRecordingArgumentTests.TestAnExplicitOutIsNeverRenamed;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  Expect<Boolean>(Build('{"out": "/tmp/clip.mp4", '
    + '"smooth_cursor": true}', Recording, Error)).ToBe(True);
  Expect<string>(Recording.OutputPath)
    .ToBe(ExpandFileName('/tmp/clip.mp4'));
end;

procedure TRecordingArgumentTests.TestSmoothCursorExclusionsStillApply;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  // Knips.Options owns both rules; this asserts they are still reached
  // through the MCP builder, and that what comes back names JSON keys
  // rather than flags.
  Expect<Boolean>(Build('{"smooth_cursor": true, "big_cursor": true}',
    Recording, Error)).ToBe(False);
  Expect<Boolean>(Pos('smooth_cursor', McpArgumentMessage(Error)) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0).ToBe(False);
  Expect<Boolean>(Build('{"smooth_cursor": true, "cursor": false}',
    Recording, Error)).ToBe(False);
  Expect<Boolean>(Pos('smooth_cursor', McpArgumentMessage(Error)) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0).ToBe(False);
  // A window take cannot have one at all: the drawn pointer is placed by
  // mapping a screen position into the frame.
  Expect<Boolean>(Build('{"window": 12, "smooth_cursor": true}',
    Recording, Error)).ToBe(False);
  Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0).ToBe(False);
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
  RecordingCases: array[0..10] of string = (
    '{"out": "/tmp/x.png"}',
    '{"fps": 500}',
    '{"scale": "3"}',
    '{"bitrate": -1}',
    '{"window": 0}',
    '{"window": 12, "left": 0, "top": 0, "width": 1, "height": 1}',
    '{"left": 0, "top": 0, "width": 1, "height": 1}',
    '{"display": -7}',
    // The three the smooth cursor adds.
    '{"smooth_cursor": true, "big_cursor": true}',
    '{"smooth_cursor": true, "cursor": false}',
    '{"window": 12, "smooth_cursor": true}');
  ExportCases: array[0..5] of string = (
    '{"in": "/tmp/x.png"}',
    '{"in": "/tmp/x.mp4", "fps": 500}',
    '{"in": "/tmp/x.mp4", "width": 4}',
    '{"in": "/tmp/x.mp4", "trim_start": 3, "trim_end": 1}',
    '{"in": "/tmp/x.mp4", "out": "/tmp/x.mp4"}',
    '{"in": "/tmp/x.mp4", "cursor": "smooth-cursor"}');
  // The session and pipeline layers refuse in --flags too, and those
  // messages reach a client through Knips.Mcp's error boundary rather
  // than through a builder. They are stable literals in
  // Knips.Recording / Knips.Export.Pipeline, so they are pinned here:
  // if one is reworded upstream, this test stops proving anything and
  // should be updated with it.
  SessionMessages: array[0..4] of string = (
    'no on-screen window with id 12 (see `knips windows`)',
    'no display at index 3 (see `knips displays`)',
    '--rect exceeds the display (1800x1169 points)',
    '--trim starts at 5.00s but the movie is 2.90s long',
    // Knips.Options' scope limit on a passthrough trim. It names a knips
    // command that now HAS a tool of the same shape, so the rewrite is
    // the difference between advice a client can act on and advice about
    // a shell it does not have.
    'export effects apply to .gif and .apng only, not to a passthrough '
      + 'trim; use `knips render` for an MP4 with effects');
var
  Arguments: TJSONObject;
  Recording: TRecordingOptions;
  Options: TExportOptions;
  Error, Line: string;
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
  Expect<Boolean>(Pos('the render tool',
    McpArgumentMessage(SessionMessages[4])) > 0).ToBe(True);
  // The two flags that became arguments this round say so by name.
  Expect<string>(McpArgumentMessage(
    'a smooth cursor applies to display recordings only'))
    .ToBe('a smooth cursor applies to display recordings only');
  Expect<string>(McpArgumentMessage('--smooth-cursor was refused'))
    .ToBe('smooth_cursor was refused');

  // The ADVICE path, which is not a refusal and was the one message
  // reaching clients with flags still in it. LargeExportWarning rides on
  // a SUCCESSFUL export_gif result — in the text block and in `advice` —
  // and it advises in --flags, which is exactly the sentence that sends
  // an agent looking for a command line it does not have. Asked of the
  // real function rather than a literal, so a reworded suggestion is
  // caught here rather than in a client.
  //
  // 3840x2160 is past the large-canvas threshold, and both suggestions
  // fire: a narrower width and a slower rate.
  Line := LargeExportWarning(efGif, 3840, 2160, 30, 4 * 1024 * 1024);
  Expect<Boolean>(Pos('--', Line) > 0).ToBe(True);
  Expect<Boolean>(Pos('--', McpArgumentMessage(Line)) > 0).ToBe(False);
  Expect<Boolean>(Pos('width=', McpArgumentMessage(Line)) > 0).ToBe(True);
  Expect<Boolean>(Pos('fps=', McpArgumentMessage(Line)) > 0).ToBe(True);
  // The fallback branch names --trim, which is two arguments over MCP.
  Line := LargeExportWarning(efGif, 640, 480, 5, 64 * 1024 * 1024);
  Expect<Boolean>(Pos('--', Line) > 0).ToBe(True);
  Expect<Boolean>(Pos('--', McpArgumentMessage(Line)) > 0).ToBe(False);
  Expect<Boolean>(Pos('trim_start/trim_end', McpArgumentMessage(Line)) > 0)
    .ToBe(True);
  // And the other advice a successful call can carry: the Big Cursor /
  // idle-heartbeat note on record_stop, which names two flags and a
  // knips command.
  Line := BigCursorIdleWarning(True, 1, 15, 16);
  Expect<Boolean>(Pos('--', Line) > 0).ToBe(True);
  Expect<Boolean>(Pos('--', McpArgumentMessage(Line)) > 0).ToBe(False);
  Expect<Boolean>(Pos('knips ', McpArgumentMessage(Line)) > 0).ToBe(False);
end;

{ TEffectArgumentTests }

procedure TEffectArgumentTests.SetupTests;
begin
  Test('the default is as-recorded with no zoom',
    TestDefaultsAreAsRecordedAndNoZoom);
  Test('zoom is read', TestZoomIsRead);
  Test('every cursor mode is read', TestEveryCursorModeIsRead);
  Test('an unknown cursor mode is refused',
    TestRejectsUnknownCursorMode);
  Test('a wrong type is refused', TestRejectsWrongTypes);
  Test('an export carries the effects through',
    TestExportCarriesThem);
  Test('a trim refuses them and points at render',
    TestTrimRefusesThemWithAPointerAtRender);
end;

function TEffectArgumentTests.Read(const AJson: string;
  out AEffects: TExportEffects; out AError: string): Boolean;
var
  Arguments: TJSONObject;
begin
  AEffects := DefaultExportEffects;
  Arguments := ParseArguments(AJson);
  try
    Result := ReadMcpExportEffects(Arguments, AEffects, AError);
  finally
    Arguments.Free;
  end;
end;

procedure TEffectArgumentTests.TestDefaultsAreAsRecordedAndNoZoom;
var
  Effects: TExportEffects;
  Error: string;
begin
  // The default is "whatever the recording asked for", NOT "no pointer".
  // They are different answers and the distinction is the reason
  // ecmAsRecorded exists.
  Expect<Boolean>(Read('{}', Effects, Error)).ToBe(True);
  Expect<string>(ExportCursorModeName(Effects.Cursor))
    .ToBe('as-recorded');
  Expect<Boolean>(Effects.ZoomOnClick).ToBe(False);
  // The four tunables are reserved: nothing here may set them, so they
  // stay at the values that make a rendered effect match the live one.
  Expect<Boolean>(Effects.ZoomFactor = 0).ToBe(True);
  Expect<Boolean>(Effects.ZoomHoldSeconds = 0).ToBe(True);
  Expect<Boolean>(Effects.CursorMagnification = 0).ToBe(True);
  Expect<Boolean>(Effects.CursorSmoothingSeconds = 0).ToBe(True);
end;

procedure TEffectArgumentTests.TestZoomIsRead;
var
  Effects: TExportEffects;
  Error: string;
begin
  Expect<Boolean>(Read('{"zoom": true}', Effects, Error)).ToBe(True);
  Expect<Boolean>(Effects.ZoomOnClick).ToBe(True);
  Expect<Boolean>(Read('{"zoom": false}', Effects, Error)).ToBe(True);
  Expect<Boolean>(Effects.ZoomOnClick).ToBe(False);
end;

procedure TEffectArgumentTests.TestEveryCursorModeIsRead;
const
  Modes: array[0..3] of string = ('as-recorded', 'none', 'smooth',
    'big');
var
  Effects: TExportEffects;
  Error: string;
  I: Integer;
begin
  // Read and echoed back under the same word: the resolved value a
  // result reports is ExportCursorModeName of what was parsed, so the
  // two have to be inverses or a client cannot tell what it got.
  for I := Low(Modes) to High(Modes) do
  begin
    Expect<Boolean>(Read('{"cursor": "' + Modes[I] + '"}', Effects,
      Error)).ToBe(True);
    Expect<string>(ExportCursorModeName(Effects.Cursor)).ToBe(Modes[I]);
  end;
end;

procedure TEffectArgumentTests.TestRejectsUnknownCursorMode;
var
  Effects: TExportEffects;
  Error: string;
begin
  // The CLI's own words for these are `smooth-cursor` and `big-cursor`,
  // which is a list, not a mode. A client that sent one gets the four
  // legal values back rather than silence.
  Expect<Boolean>(Read('{"cursor": "smooth-cursor"}', Effects, Error))
    .ToBe(False);
  Expect<Boolean>(Pos('as-recorded', Error) > 0).ToBe(True);
  Expect<Boolean>(Pos('"smooth"', Error) > 0).ToBe(True);
  Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0).ToBe(False);
end;

procedure TEffectArgumentTests.TestRejectsWrongTypes;
var
  Effects: TExportEffects;
  Error: string;
begin
  Expect<Boolean>(Read('{"zoom": "yes"}', Effects, Error)).ToBe(False);
  Expect<Boolean>(Pos('zoom', Error) > 0).ToBe(True);
  Expect<Boolean>(Read('{"cursor": true}', Effects, Error)).ToBe(False);
  Expect<Boolean>(Pos('cursor', Error) > 0).ToBe(True);
  // An explicit null is "unset", as everywhere else in this mapping.
  Expect<Boolean>(Read('{"zoom": null, "cursor": null}', Effects, Error))
    .ToBe(True);
  Expect<string>(ExportCursorModeName(Effects.Cursor))
    .ToBe('as-recorded');
end;

procedure TEffectArgumentTests.TestExportCarriesThem;
var
  Arguments: TJSONObject;
  Options: TExportOptions;
  Error: string;
begin
  Arguments := ParseArguments('{"in": "/tmp/x.mp4", "zoom": true, '
    + '"cursor": "smooth"}');
  try
    Expect<Boolean>(BuildMcpExportOptions(Arguments, efGif, Options,
      Error)).ToBe(True);
    Expect<Boolean>(Options.Effects.ZoomOnClick).ToBe(True);
    Expect<string>(ExportCursorModeName(Options.Effects.Cursor))
      .ToBe('smooth');
  finally
    Arguments.Free;
  end;
end;

procedure TEffectArgumentTests.TestTrimRefusesThemWithAPointerAtRender;
var
  Arguments: TJSONObject;
  Options: TExportOptions;
  Error: string;
begin
  // A passthrough trim copies coded samples; an effect would mean
  // decoding and re-encoding the whole video, which is what render is
  // for — so the refusal names the tool that CAN do it rather than
  // merely turning the caller away.
  Arguments := ParseArguments('{"in": "/tmp/x.mp4", "trim_end": 2, '
    + '"zoom": true}');
  try
    Expect<Boolean>(BuildMcpExportOptions(Arguments, efMovie, Options,
      Error)).ToBe(False);
    Expect<Boolean>(Pos('render', Error) > 0).ToBe(True);
    Expect<Boolean>(Pos('--', McpArgumentMessage(Error)) > 0).ToBe(False);
  finally
    Arguments.Free;
  end;
  Arguments := ParseArguments('{"in": "/tmp/x.mp4", "trim_end": 2, '
    + '"cursor": "smooth"}');
  try
    Expect<Boolean>(BuildMcpExportOptions(Arguments, efMovie, Options,
      Error)).ToBe(False);
    Expect<Boolean>(Pos('render', Error) > 0).ToBe(True);
  finally
    Arguments.Free;
  end;
end;

{ TTakeInfoTests }

const
  // A display take, 1280x800, whose framing was never touched. The
  // cursor word and the click are what each test varies.
  TakeHeaderPrefix =
    '{"k":"header","format":"knips-events","version":1,"knips":"0.1.0",'
    + '"movie":"demo.mp4","created":"2026-08-27T09:15:00Z",'
    + '"target":"display","pid":0,'
    + '"pixelWidth":1280,"pixelHeight":800,"scale":2,"fps":30,'
    + '"sampleHz":30,"displayId":1,"displayWidth":1440,'
    + '"displayHeight":900,'
    + '"baseX":0,"baseY":0,"baseWidth":640,"baseHeight":400,'
    + '"cursor":"';
  TakeHeaderSuffix =
    '","bakedZoomOnClick":false,"bakedFollowMouse":false,'
    + '"audio":"none"}';

function TakeSidecar(const ACursor: string; AClick: Boolean): string;
begin
  Result := TakeHeaderPrefix + ACursor + TakeHeaderSuffix + LineEnding
    + '{"k":"anchor","host":100.0}' + LineEnding
    + '{"k":"cursor","t":100.0,"x":10,"y":20,"b":0}' + LineEnding
    + '{"k":"cursor","t":103.5,"x":30,"y":40,"b":0}';
  if AClick then
    Result := Result + LineEnding
      + '{"k":"button","t":101.0,"x":20,"y":30,"n":0,"d":true}';
  Result := Result + LineEnding
    + '{"k":"trailer","t":104.0,"frames":90,"duration":4.0,'
    + '"samples":2}';
end;

// The same take sampled the way a polled client produces: no silence
// longer than the reader will draw a straight line through.
function DenseSidecar: string;
var
  I: Integer;
begin
  Result := TakeHeaderPrefix + 'smooth' + TakeHeaderSuffix + LineEnding
    + '{"k":"anchor","host":100.0}';
  for I := 0 to 20 do
    Result := Result + LineEnding
      + Format('{"k":"cursor","t":%d.%d,"x":10,"y":20,"b":0}',
      [100 + I div 10, (I mod 10)]);
  Result := Result + LineEnding
    + '{"k":"trailer","t":104.0,"frames":90,"duration":4.0,'
    + '"samples":21}';
end;

procedure TTakeInfoTests.SetupTests;
begin
  Test('no sidecar is an answer, not a crash', TestNoSidecarSaysSo);
  Test('a raw take can have both effects', TestRawTakeOffersBoth);
  Test('a baked pointer closes the cursor',
    TestBakedCursorClosesTheCursor);
  Test('no clicks closes the zoom', TestNoClicksClosesTheZoom);
  Test('the track density is reported', TestReportsTheTrackDensity);
  Test('the render output is named in advance',
    TestNamesTheRenderOutput);
  Test('usable_clicks is the number a render will use',
    TestUsableClicksIsTheRendersOwnCount);
  Test('a sparse track says so in words as well as numbers',
    TestASparseTrackSaysSoInWords);
  Test('every key the answer carries is declared in the schema',
    TestEveryKeyItCarriesIsDeclared);
  Test('a sidecar with unreadable lines says how many',
    TestItReportsWhatTheLoaderCouldNotUse);
end;

function TTakeInfoTests.Info(const ASidecar: string): TJSONObject;
var
  Log: TSidecarLog;
  Error: string;
begin
  Log := nil;
  Error := '';
  if ASidecar <> '' then
  begin
    Log := TSidecarLog.Create;
    if not Log.LoadFromText(ASidecar, Error) then
      FreeAndNil(Log);
  end
  else
    Error := 'there is no event sidecar for this recording';
  try
    Result := McpTakeInfoObject('/tmp/demo.mp4', '/tmp/demo.knips.jsonl',
      4096, Log, Error);
  finally
    Log.Free;
  end;
end;

procedure TTakeInfoTests.TestNoSidecarSaysSo;
var
  Answer: TJSONObject;
begin
  Answer := Info('');
  try
    Expect<Boolean>(Answer.Get('has_sidecar', True)).ToBe(False);
    Expect<Boolean>(Answer.Get('raw', True)).ToBe(False);
    Expect<Boolean>(Answer.Get('can_draw_cursor', True)).ToBe(False);
    Expect<Boolean>(Answer.Get('can_zoom_on_click', True)).ToBe(False);
    // Why not, in the sidecar's own words: a take nothing can be applied
    // to is a fact the client can act on only if it is told which fact.
    Expect<Boolean>(Length(Answer.Get('reason', '')) > 0).ToBe(True);
    // The keys the schema promises unconditionally are all here even on
    // this, the emptiest answer this tool gives.
    Expect<Boolean>(Answer.Find('path') <> nil).ToBe(True);
    Expect<Boolean>(Answer.Find('bytes') <> nil).ToBe(True);
    Expect<Boolean>(Answer.Find('render_output_path') <> nil).ToBe(True);
  finally
    Answer.Free;
  end;
end;

procedure TTakeInfoTests.TestRawTakeOffersBoth;
var
  Answer: TJSONObject;
begin
  Answer := Info(TakeSidecar('smooth', True));
  try
    Expect<Boolean>(Answer.Get('raw', False)).ToBe(True);
    Expect<Boolean>(Answer.Get('fully_renderable', False)).ToBe(True);
    Expect<Boolean>(Answer.Get('can_draw_cursor', False)).ToBe(True);
    Expect<Boolean>(Answer.Get('can_zoom_on_click', False)).ToBe(True);
    Expect<Boolean>(Answer.Get('cursor_already_baked', True)).ToBe(False);
    Expect<string>(Answer.Get('cursor_render', '')).ToBe('smooth');
    Expect<string>(Answer.Get('target', '')).ToBe('display');
    Expect<Integer>(Answer.Get('width', 0)).ToBe(1280);
    Expect<Integer>(Answer.Get('clicks', 0)).ToBe(1);
    Expect<Boolean>(Answer.Get('finished', False)).ToBe(True);
    // Nothing is refused, so there is nothing to explain.
    Expect<Boolean>(Answer.Find('reason') = nil).ToBe(True);
    Expect<Boolean>(Answer.Find('cursor_reason') = nil).ToBe(True);
    Expect<Boolean>(Answer.Find('zoom_reason') = nil).ToBe(True);
  finally
    Answer.Free;
  end;
end;

procedure TTakeInfoTests.TestBakedCursorClosesTheCursor;
var
  Answer: TJSONObject;
begin
  // An ordinary take: ScreenCaptureKit drew the system pointer into the
  // frames, and nothing can take it out again. The zoom is still open —
  // a baked pointer scales with a crop exactly as the live effect's
  // would have.
  Answer := Info(TakeSidecar('system', True));
  try
    Expect<Boolean>(Answer.Get('raw', True)).ToBe(False);
    Expect<Boolean>(Answer.Get('can_draw_cursor', True)).ToBe(False);
    Expect<Boolean>(Answer.Get('cursor_already_baked', False)).ToBe(True);
    Expect<Boolean>(Answer.Get('can_zoom_on_click', False)).ToBe(True);
    Expect<Boolean>(Length(Answer.Get('cursor_reason', '')) > 0)
      .ToBe(True);
    Expect<Boolean>(Answer.Find('zoom_reason') = nil).ToBe(True);
  finally
    Answer.Free;
  end;
end;

procedure TTakeInfoTests.TestNoClicksClosesTheZoom;
var
  Answer: TJSONObject;
begin
  Answer := Info(TakeSidecar('smooth', False));
  try
    Expect<Boolean>(Answer.Get('can_draw_cursor', False)).ToBe(True);
    Expect<Boolean>(Answer.Get('can_zoom_on_click', True)).ToBe(False);
    Expect<Integer>(Answer.Get('clicks', -1)).ToBe(0);
    Expect<Boolean>(Length(Answer.Get('zoom_reason', '')) > 0).ToBe(True);
  finally
    Answer.Free;
  end;
end;

procedure TTakeInfoTests.TestReportsTheTrackDensity;
var
  Answer: TJSONObject;
begin
  // The two samples in the fixture are 3.5 s apart, which is the shape
  // an MCP take polled twice has. The count alone cannot say that — a
  // track can be dense for most of a take and have one hole in it — and
  // it is the hole that decides whether a drawn pointer tells the truth.
  Answer := Info(TakeSidecar('smooth', True));
  try
    Expect<Integer>(Answer.Get('pointer_samples', 0)).ToBe(2);
    // Measured, not policy: the two samples are 3.5 s apart.
    Expect<Boolean>(Abs(Answer.Get('max_sample_gap_seconds', 0.0) - 3.5)
      < 1E-9).ToBe(True);
    // And the number it has to be compared against, which is the
    // longest silence a reader will draw a straight line through. This
    // track's hole is bigger, so a pointer rendered from it stands still
    // across it — which is the honest answer and the whole reason both
    // numbers are reported.
    Expect<Boolean>(Answer.Get('max_sample_gap_seconds', 0.0)
      > Answer.Get('interpolation_limit_seconds', 0.0)).ToBe(True);
  finally
    Answer.Free;
  end;
end;

procedure TTakeInfoTests.TestNamesTheRenderOutput;
var
  Answer: TJSONObject;
  Summary: string;
  Log: TSidecarLog;
  Error: string;
begin
  Answer := Info(TakeSidecar('smooth', True));
  try
    // The literal path, not the function that produced it: asserting
    // one call of DefaultMcpRenderPath against another only says the
    // payload used that function, which is the one thing the reader can
    // already see. What is under test is the path a client receives.
    Expect<string>(Answer.Get('render_output_path', ''))
      .ToBe('/tmp/demo-rendered.mp4');
  finally
    Answer.Free;
  end;
  // And the one-line form, for a client that reads the content block.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(TakeSidecar('smooth', True), Error))
      .ToBe(True);
    Summary := McpTakeInfoSummary('/tmp/demo.mp4', Log, '');
    Expect<Boolean>(Pos('/tmp/demo.mp4', Summary) > 0).ToBe(True);
    Expect<Boolean>(Pos('cursor and zoom', Summary) > 0).ToBe(True);
  finally
    Log.Free;
  end;
  Summary := McpTakeInfoSummary('/tmp/demo.mp4', nil, 'boom');
  Expect<Boolean>(Pos('boom', Summary) > 0).ToBe(True);
end;

procedure TTakeInfoTests.TestUsableClicksIsTheRendersOwnCount;
var
  Answer: TJSONObject;
begin
  // The fixture's click is a left press at 20,30 inside a 640x400 base:
  // one click, and one a zoom would answer.
  Answer := Info(TakeSidecar('smooth', True));
  try
    Expect<Integer>(Answer.Get('clicks', -1)).ToBe(1);
    Expect<Integer>(Answer.Get('usable_clicks', -1)).ToBe(1);
  finally
    Answer.Free;
  end;
  // A click OUTSIDE the recorded rectangle still counts as a click —
  // AvailableExportEffects asks only whether the track has one, so
  // can_zoom_on_click stays true — but a render drops it and reports
  // "nothing was clicked inside the recorded rectangle". That gap is
  // exactly what usable_clicks closes: 1 and 0 are different answers to
  // two different questions, and a client planning a zoom wants the
  // second.
  Answer := Info(StringReplace(TakeSidecar('smooth', True),
    '"k":"button","t":101.0,"x":20,"y":30',
    '"k":"button","t":101.0,"x":9000,"y":9000', [rfReplaceAll]));
  try
    Expect<Integer>(Answer.Get('clicks', -1)).ToBe(1);
    Expect<Boolean>(Answer.Get('can_zoom_on_click', False)).ToBe(True);
    Expect<Integer>(Answer.Get('usable_clicks', -1)).ToBe(0);
  finally
    Answer.Free;
  end;
end;

procedure TTakeInfoTests.TestASparseTrackSaysSoInWords;
var
  Log: TSidecarLog;
  Summary, Error: string;
begin
  // The numbers are in the structured answer either way; a client
  // reading the text block would have to already know the rule to see
  // what they mean. The fixture's 3.5 s hole is well past the 0.5 s a
  // reader will draw through.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(TakeSidecar('smooth', True), Error))
      .ToBe(True);
    Expect<Boolean>(LargestSampleGap(Log) > Log.MaxInterpolatedGap)
      .ToBe(True);
    Summary := McpTakeInfoSummary('/tmp/demo.mp4', Log, '');
    Expect<Boolean>(Pos('stands still', Summary) > 0).ToBe(True);
    Expect<Boolean>(Pos('record_status', Summary) > 0).ToBe(True);
  finally
    Log.Free;
  end;
  // A dense track says nothing about density: the sentence is a
  // consequence, not a disclaimer, and one that fired on every take
  // would stop being read.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(DenseSidecar, Error)).ToBe(True);
    Expect<Boolean>(LargestSampleGap(Log) > Log.MaxInterpolatedGap)
      .ToBe(False);
    Summary := McpTakeInfoSummary('/tmp/demo.mp4', Log, '');
    Expect<Boolean>(Pos('stands still', Summary) > 0).ToBe(False);
  finally
    Log.Free;
  end;
end;

procedure TTakeInfoTests.TestEveryKeyItCarriesIsDeclared;

  procedure ExpectDeclared(const ASidecar: string);
  var
    Answer: TJSONObject;
  begin
    Answer := Info(ASidecar);
    try
      Expect<string>(McpUndeclaredPayloadKeys(kmtTakeInfo, Answer))
        .ToBe('');
    finally
      Answer.Free;
    end;
  end;

begin
  // The real builder against the real schema, over every shape this
  // answer has: no sidecar at all, a finished take, a take with no
  // trailer, and one whose loader threw a line away. take_info is the
  // one payload builder in this program that is neutral, so it is the
  // one this check can drive off Darwin — the other nine are checked at
  // the chokepoint every structured result leaves the server through
  // (Knips.Mcp.KnipsStructuredResult).
  ExpectDeclared('');
  ExpectDeclared(TakeSidecar('smooth', True));
  ExpectDeclared(TakeSidecar('system', False));
  ExpectDeclared(DenseSidecar);
  ExpectDeclared(TakeSidecar('smooth', True) + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}');
end;

procedure TTakeInfoTests.TestItReportsWhatTheLoaderCouldNotUse;
var
  Answer: TJSONObject;
begin
  // Clean file, nothing thrown away.
  Answer := Info(TakeSidecar('smooth', True));
  try
    Expect<Integer>(Answer.Get('sidecar_skipped_lines', -1)).ToBe(0);
  finally
    Answer.Free;
  end;
  // Two lines the loader cannot use: a stamp that does not advance and
  // a record kind this version does not know. Neither is an error and
  // both leave the track thinner than the file looks, which is a fact a
  // client planning a render is entitled to before it spends the time.
  Answer := Info(TakeSidecar('smooth', True) + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}' + LineEnding
    + '{"k":"invented","t":105.0}');
  try
    Expect<Integer>(Answer.Get('sidecar_skipped_lines', -1)).ToBe(2);
  finally
    Answer.Free;
  end;
end;

{ TSummaryTests }

procedure TSummaryTests.SetupTests;
begin
  Test('a recording summary names its file',
    TestRecordingSummaryNamesThePath);
  Test('the sparse-track note fires only for a raw take',
    TestSparseTrackNoteOnlyForARawTake);
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

procedure TSummaryTests.TestSparseTrackNoteOnlyForARawTake;
var
  Note: string;
begin
  Expect<string>(McpSparseTrackNote(False)).ToBe('');
  Note := McpSparseTrackNote(True);
  // The two things it has to say: what makes the track dense, and what
  // a track that is not dense produces.
  Expect<Boolean>(Pos('record_status', Note) > 0).ToBe(True);
  Expect<Boolean>(Pos('straight line', Note) > 0).ToBe(True);
end;

begin
  TestRunnerProgram.AddSuite(TToolTableTests.Create('tool table'));
  TestRunnerProgram.AddSuite(TOutputSchemaTests.Create(
    'output schemas'));
  TestRunnerProgram.AddSuite(TScalarTests.Create('optional arguments'));
  TestRunnerProgram.AddSuite(TDefaultPathTests.Create('default paths'));
  TestRunnerProgram.AddSuite(TRecordingArgumentTests.Create(
    'BuildMcpRecordingOptions'));
  TestRunnerProgram.AddSuite(TOverwriteTests.Create(
    'McpMayWriteRecording'));
  TestRunnerProgram.AddSuite(TExportArgumentTests.Create(
    'BuildMcpExportOptions'));
  TestRunnerProgram.AddSuite(TEffectArgumentTests.Create(
    'ReadMcpExportEffects'));
  TestRunnerProgram.AddSuite(TRenderArgumentTests.Create(
    'McpRenderRefusesArguments'));
  TestRunnerProgram.AddSuite(TTakeInfoTests.Create('take_info'));
  TestRunnerProgram.AddSuite(TMessageTests.Create('McpArgumentMessage'));
  TestRunnerProgram.AddSuite(TSummaryTests.Create('result summaries'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

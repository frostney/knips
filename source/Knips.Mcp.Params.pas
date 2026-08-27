unit Knips.Mcp.Params;

// The platform-neutral half of `knips mcp`: the tool table, the JSON
// argument mapping, and the default output paths.
//
// Everything here turns a tools/call arguments object into the same
// validated TRecordingOptions / TExportOptions the CLI builds from
// --flags, so an MCP client and a shell command are refused for the
// same reasons in the same words. Nothing here touches a framework;
// Knips.Mcp is where the Darwin half lives.
//
// One deliberate asymmetry with the CLI: --out is required on the
// command line and optional over MCP. A shell user picked a directory
// by being in one; an agent has no working directory worth writing to,
// so an absent path becomes the app's own ~/Movies/knips/ name and an
// absent export path sits beside its input.

{$I Knips.inc}

interface

uses
  SysUtils,

  fpjson,
  Knips.App.State,
  Knips.Options;

const
  McpServerName = 'knips';
  // The trim export writes beside its input under this suffix rather
  // than over it; ValidateExportOptions refuses in = out outright.
  TrimFileSuffix = '-trim';
  ApngFileExtension = '.apng';

type
  TKnipsMcpTool = (kmtListDisplays, kmtListWindows, kmtRecordStart,
    kmtRecordStop, kmtRecordStatus, kmtExportGif, kmtExportApng,
    kmtExportTrim);

function KnipsMcpToolName(ATool: TKnipsMcpTool): string;
function KnipsMcpToolDescription(ATool: TKnipsMcpTool): string;

// Optional scalar readers. Absent leaves AValue alone and returns True;
// present-but-wrong-type returns False with a message naming the
// argument. The MCP server validates types against the registered
// schema before a handler runs, so these are the second line of
// defence rather than the first — but a tool marked
// ApplicationValidated has no first line at all.
function McpOptionalInteger(AArguments: TJSONObject; const AName: string;
  var AValue: Integer; out AError: string): Boolean;
function McpOptionalNumber(AArguments: TJSONObject; const AName: string;
  var AValue: Double; out AError: string): Boolean;
function McpOptionalString(AArguments: TJSONObject; const AName: string;
  var AValue: string; out AError: string): Boolean;
function McpOptionalBoolean(AArguments: TJSONObject; const AName: string;
  var AValue: Boolean; out AError: string): Boolean;

// True when the argument is present and not JSON null.
function McpHasArgument(AArguments: TJSONObject;
  const AName: string): Boolean;

// ~/Movies/knips/knips-YYYYMMDD-HHMMSS.mp4 — the same name and folder
// the menu-bar app records into, so a client's recordings land where a
// user already looks for them.
function DefaultMcpRecordingPath(const AHomeDirectory: string;
  const AWhen: TDateTime): string;

// Beside the input movie, same stem, the format's extension (and the
// trim suffix for a passthrough trim, which may not overwrite its own
// input).
function DefaultMcpExportPath(const AInputPath: string;
  AFormat: TExportFormat): string;

// Knips.Options speaks in --flags, because the CLI is what it was
// written for. An agent holding this tool's schema has never seen a
// flag, so a refusal naming one sends it looking for an argument that
// does not exist. This renames the flags in a validation message to the
// arguments the schema actually declares, and leaves everything else —
// including the reason, which is the part that matters — untouched.
function McpArgumentMessage(const AMessage: string): string;

// record_start's arguments -> a validated recording request.
// ADefaultPath is used when the caller passed no "out". Paths come back
// absolute (ExpandFileName): an agent has no reliable idea what this
// process's working directory is, so a relative path it passed in must
// come back as something it can resolve.
function BuildMcpRecordingOptions(AArguments: TJSONObject;
  const ADefaultPath: string; out ARecording: TRecordingOptions;
  out AError: string): Boolean;

// Whether record_start may write APath. `record` on the command line
// replaces an existing file without asking, and for a path someone
// typed that is the right behaviour. An agent guesses paths, and a
// guess that lands on last week's recording destroys it silently — so
// over MCP an existing file is refused unless "overwrite" says
// otherwise. AExists is passed in rather than probed here so the rule
// stays platform-neutral and testable.
function McpMayWriteRecording(AArguments: TJSONObject;
  const APath: string; AExists: Boolean; out AError: string): Boolean;

// export_gif / export_apng / export_trim arguments -> a validated
// export request. AFormat is the tool's own format; an "out" whose
// extension disagrees with it is refused rather than quietly
// exporting something else.
function BuildMcpExportOptions(AArguments: TJSONObject;
  AFormat: TExportFormat; out AExport: TExportOptions;
  out AError: string): Boolean;

// The one-line summary a finished recording reports back.
function McpRecordingSummary(const APath: string; APixelWidth,
  APixelHeight: Integer; ADurationSeconds: Double; AFrames,
  ADropped, AFailed: Int64): string;

// The one-line summary a finished GIF/APNG export reports back.
function McpExportSummary(const APath: string; AFormat: TExportFormat;
  APixelWidth, APixelHeight: Integer; AFrames: Int64;
  ADurationSeconds: Double; AOutputBytes: Int64): string;

implementation

const
  ToolNames: array[TKnipsMcpTool] of string = (
    'list_displays', 'list_windows', 'record_start', 'record_stop',
    'record_status', 'export_gif', 'export_apng', 'export_trim');

  ToolDescriptions: array[TKnipsMcpTool] of string = (
    'List the displays that can be recorded, with their index, size in '
      + 'points, and backing scale.',
    'List the on-screen application windows that can be recorded, with '
      + 'their window id, size, application, and title.',
    'Start recording a display, a region of one, or a single window to '
      + 'an .mp4/.mov file. Returns immediately; the recording runs '
      + 'until record_stop. Only one recording at a time.',
    'Stop the running recording and finalise the file. Returns the '
      + 'output path and the frame counters.',
    'Report whether a recording is running, and for how long. If the '
    + 'writer has failed, this stops the recording and finalises the '
    + 'partial file.',
    'Convert a recorded movie to an animated GIF.',
    'Convert a recorded movie to an animated PNG (APNG): truecolour, '
      + 'larger than a GIF, no palette banding.',
    'Cut a movie down to a time range by copying the coded samples into '
      + 'a new container — no decode, no re-encode, no quality loss.');

function KnipsMcpToolName(ATool: TKnipsMcpTool): string;
begin
  Result := ToolNames[ATool];
end;

function KnipsMcpToolDescription(ATool: TKnipsMcpTool): string;
begin
  Result := ToolDescriptions[ATool];
end;

function McpHasArgument(AArguments: TJSONObject;
  const AName: string): Boolean;
var
  Data: TJSONData;
begin
  Result := False;
  if AArguments = nil then
    Exit;
  Data := AArguments.Find(AName);
  Result := (Data <> nil) and (Data.JSONType <> jtNull);
end;

function McpOptionalInteger(AArguments: TJSONObject; const AName: string;
  var AValue: Integer; out AError: string): Boolean;
var
  Data: TJSONData;
begin
  AError := '';
  Result := True;
  if not McpHasArgument(AArguments, AName) then
    Exit;
  Data := AArguments.Find(AName);
  // jtNumber covers ntFloat too; a float with a fractional part is a
  // different mistake from a string, and worth its own words.
  if Data.JSONType <> jtNumber then
  begin
    AError := Format('"%s" must be a whole number', [AName]);
    Exit(False);
  end;
  if Frac(Data.AsFloat) <> 0 then
  begin
    AError := Format('"%s" must be a whole number, not %s',
      [AName, Data.AsString]);
    Exit(False);
  end;
  AValue := Data.AsInt64;
end;

function McpOptionalNumber(AArguments: TJSONObject; const AName: string;
  var AValue: Double; out AError: string): Boolean;
var
  Data: TJSONData;
begin
  AError := '';
  Result := True;
  if not McpHasArgument(AArguments, AName) then
    Exit;
  Data := AArguments.Find(AName);
  if Data.JSONType <> jtNumber then
  begin
    AError := Format('"%s" must be a number of seconds', [AName]);
    Exit(False);
  end;
  AValue := Data.AsFloat;
end;

function McpOptionalString(AArguments: TJSONObject; const AName: string;
  var AValue: string; out AError: string): Boolean;
var
  Data: TJSONData;
begin
  AError := '';
  Result := True;
  if not McpHasArgument(AArguments, AName) then
    Exit;
  Data := AArguments.Find(AName);
  if Data.JSONType <> jtString then
  begin
    AError := Format('"%s" must be a string', [AName]);
    Exit(False);
  end;
  AValue := Data.AsString;
end;

function McpOptionalBoolean(AArguments: TJSONObject; const AName: string;
  var AValue: Boolean; out AError: string): Boolean;
var
  Data: TJSONData;
begin
  AError := '';
  Result := True;
  if not McpHasArgument(AArguments, AName) then
    Exit;
  Data := AArguments.Find(AName);
  if Data.JSONType <> jtBoolean then
  begin
    AError := Format('"%s" must be true or false', [AName]);
    Exit(False);
  end;
  AValue := Data.AsBoolean;
end;

function DefaultMcpRecordingPath(const AHomeDirectory: string;
  const AWhen: TDateTime): string;
begin
  Result := RecordingsDirectory(AHomeDirectory) + RecordingFileName(AWhen);
end;

function DefaultMcpExportPath(const AInputPath: string;
  AFormat: TExportFormat): string;
var
  Extension: string;
begin
  if AInputPath = '' then
    Exit('');
  case AFormat of
    efGif: Extension := GifFileExtension;
    efApng: Extension := ApngFileExtension;
  else
    // A passthrough trim keeps its input's container, so the stem has
    // to move instead of the extension.
    Exit(ChangeFileExt(AInputPath, '') + TrimFileSuffix
      + ExtractFileExt(AInputPath));
  end;
  Result := ChangeFileExt(AInputPath, Extension);
  // ChangeFileExt on an extension-less name appends nothing in some RTL
  // versions; never hand back the input path itself.
  if SameText(Result, AInputPath) then
    Result := AInputPath + Extension;
end;

// Rewrites are ordered longest-match-first at each position: the phrase
// entries have to be tried before the bare flag they contain, or
// '--trim' eats the example that follows it.
//
// Every entry is anchored. A blanket StringReplace also rewrites the
// caller's own text where a message interpolates it — a file named
// "x.--fps.mp4" came back as "x.fps.mp4", which is a lie about what the
// caller passed — so a candidate only counts when it sits on a token
// boundary: the character before it is the start of the message, a
// space, or an opening parenthesis, and the character after it is the
// end, a space, or one of the punctuation marks these templates
// actually use. Inside a path or a quoted extension, a flag-looking run
// is preceded by '.', '/', or '"' and passes through untouched.
const
  RewriteCount = 21;
  McpMessageRewrites: array[0..RewriteCount - 1, 0..1] of string = (
    ('--scale must be 1, 2, or 0 for auto',
      'scale must be "auto", "1", or "2"'),
    ('--window and --rect are mutually exclusive',
      'a window and a region are mutually exclusive'),
    ('(see `knips windows`)', '(see list_windows)'),
    ('(see `knips displays`)', '(see list_displays)'),
    ('--trim=1.5,3.5', 'trim_start=1.5 and trim_end=3.5'),
    ('--trim=0,3.5', 'trim_start=0 and trim_end=3.5'),
    ('--trim starts at', 'trim_start is at'),
    ('--rect', 'a region of left/top/width/height'),
    ('--trim', 'trim_start/trim_end'),
    ('--no-dither', 'dither'),
    ('--big-cursor', 'big_cursor'),
    ('--no-cursor', 'cursor'),
    ('--bitrate', 'bitrate'),
    ('--display', 'display'),
    ('--window', 'window'),
    ('--width', 'width'),
    ('--scale', 'scale'),
    ('--audio', 'audio'),
    ('--fps', 'fps'),
    ('--out', 'out'),
    ('--in', 'in'));

function McpArgumentMessage(const AMessage: string): string;

  function BoundaryBefore(APosition: Integer): Boolean;
  begin
    Result := (APosition = 1)
      or (AMessage[APosition - 1] in [' ', '(']);
  end;

  function BoundaryAfter(APosition: Integer): Boolean;
  begin
    Result := (APosition > Length(AMessage))
      or (AMessage[APosition] in [' ', '=', ',', ')', ';']);
  end;

var
  Position, I, CandidateLength: Integer;
  Matched: Boolean;
begin
  Result := '';
  Position := 1;
  while Position <= Length(AMessage) do
  begin
    Matched := False;
    for I := Low(McpMessageRewrites) to High(McpMessageRewrites) do
    begin
      CandidateLength := Length(McpMessageRewrites[I, 0]);
      if Copy(AMessage, Position, CandidateLength)
        <> McpMessageRewrites[I, 0] then
        Continue;
      if not BoundaryBefore(Position) then
        Continue;
      if not BoundaryAfter(Position + CandidateLength) then
        Continue;
      Result := Result + McpMessageRewrites[I, 1];
      Inc(Position, CandidateLength);
      Matched := True;
      Break;
    end;
    if not Matched then
    begin
      Result := Result + AMessage[Position];
      Inc(Position);
    end;
  end;
end;

// left/top/width/height are four separate integers rather than an array
// or a nested object because the server-enforced schema subset is flat
// scalars — a nested rect would have to be ApplicationValidated, which
// costs the client its argument checking for the whole tool.
function ReadRegion(AArguments: TJSONObject; out ARegion: TCaptureRegion;
  out AHasRegion: Boolean; out AError: string): Boolean;
const
  RegionNames: array[0..3] of string = ('left', 'top', 'width', 'height');
var
  Present, I: Integer;
begin
  Result := False;
  AError := '';
  ARegion := Default(TCaptureRegion);
  AHasRegion := False;

  Present := 0;
  for I := Low(RegionNames) to High(RegionNames) do
    if McpHasArgument(AArguments, RegionNames[I]) then
      Inc(Present);
  if Present = 0 then
    Exit(True);
  if Present < Length(RegionNames) then
  begin
    AError := 'a region needs all four of left, top, width and height';
    Exit;
  end;

  if not McpOptionalInteger(AArguments, 'left', ARegion.Left, AError) then
    Exit;
  if not McpOptionalInteger(AArguments, 'top', ARegion.Top, AError) then
    Exit;
  if not McpOptionalInteger(AArguments, 'width', ARegion.Width, AError) then
    Exit;
  if not McpOptionalInteger(AArguments, 'height', ARegion.Height,
    AError) then
    Exit;
  if (ARegion.Left < 0) or (ARegion.Top < 0) then
  begin
    AError := 'a region cannot start left of or above the display origin';
    Exit;
  end;
  AHasRegion := True;
  Result := True;
end;

function BuildMcpRecordingOptions(AArguments: TJSONObject;
  const ADefaultPath: string; out ARecording: TRecordingOptions;
  out AError: string): Boolean;
var
  Audio, Scale: string;
  WindowID: Integer;
  ShowsCursor, BigCursor: Boolean;
begin
  Result := False;
  AError := '';
  ARecording := DefaultRecordingOptions;
  ARecording.OutputPath := ADefaultPath;

  if not McpOptionalString(AArguments, 'out', ARecording.OutputPath,
    AError) then
    Exit;
  if ARecording.OutputPath = '' then
  begin
    AError := 'no output path, and no default could be derived';
    Exit;
  end;
  ARecording.OutputPath := ExpandFileName(ARecording.OutputPath);
  if not McpOptionalInteger(AArguments, 'display', ARecording.DisplayIndex,
    AError) then
    Exit;
  // -1 is the internal "main display" sentinel, not something a caller
  // may ask for: a client that sent display:-7 meaning "the last one"
  // used to get a full-screen recording of the main display and no hint
  // that its index was ignored.
  if McpHasArgument(AArguments, 'display') and (ARecording.DisplayIndex < 0) then
  begin
    AError := '"display" must be an index from list_displays (0 or more)';
    Exit;
  end;

  WindowID := 0;
  if not McpOptionalInteger(AArguments, 'window', WindowID, AError) then
    Exit;
  if McpHasArgument(AArguments, 'window') then
  begin
    if WindowID < 0 then
    begin
      AError := '"window" must be a window id from list_windows';
      Exit;
    end;
    ARecording.WindowID := Cardinal(WindowID);
    ARecording.TargetKind := ctkWindow;
    if McpHasArgument(AArguments, 'display') then
    begin
      AError := '"window" and "display" are mutually exclusive';
      Exit;
    end;
  end;

  if not McpOptionalInteger(AArguments, 'fps', ARecording.FramesPerSecond,
    AError) then
    Exit;
  if not McpOptionalInteger(AArguments, 'bitrate', ARecording.BitRate,
    AError) then
    Exit;

  ShowsCursor := True;
  if not McpOptionalBoolean(AArguments, 'cursor', ShowsCursor, AError) then
    Exit;
  ARecording.ShowsCursor := ShowsCursor;

  BigCursor := False;
  if not McpOptionalBoolean(AArguments, 'big_cursor', BigCursor, AError) then
    Exit;
  ARecording.BigCursor := BigCursor;

  Scale := 'auto';
  if not McpOptionalString(AArguments, 'scale', Scale, AError) then
    Exit;
  if SameText(Scale, 'auto') then
    ARecording.Scale := ScaleAuto
  else if not TryStrToInt(Scale, ARecording.Scale) then
  begin
    AError := '"scale" must be "auto", "1", or "2"';
    Exit;
  end;

  Audio := AudioModeName(amNone);
  if not McpOptionalString(AArguments, 'audio', Audio, AError) then
    Exit;
  if not ParseAudioMode(Audio, ARecording.AudioMode) then
  begin
    AError := '"audio" must be none, system, mic, or both';
    Exit;
  end;

  if not ReadRegion(AArguments, ARecording.Region, ARecording.HasRegion,
    AError) then
    Exit;

  // The message is NOT rewritten here: Knips.Mcp applies
  // McpArgumentMessage at the one boundary where every failure — this
  // one, the session's, the framework's — becomes an MCP result, so no
  // path can reach a client having skipped it.
  Result := ValidateRecordingOptions(ARecording, AError);
end;

function McpMayWriteRecording(AArguments: TJSONObject;
  const APath: string; AExists: Boolean; out AError: string): Boolean;
var
  Overwrite: Boolean;
begin
  AError := '';
  Overwrite := False;
  Result := McpOptionalBoolean(AArguments, 'overwrite', Overwrite, AError);
  if not Result then
    Exit;
  if AExists and not Overwrite then
  begin
    AError := APath + ' already exists; pass "overwrite": true to '
      + 'replace it, or give a different "out"';
    Exit(False);
  end;
end;

function BuildMcpExportOptions(AArguments: TJSONObject;
  AFormat: TExportFormat; out AExport: TExportOptions;
  out AError: string): Boolean;
const
  TrimInapplicable: array[0..2] of string = ('fps', 'width', 'dither');
var
  Requested: TExportFormat;
  Dither: Boolean;
  I: Integer;
begin
  Result := False;
  AError := '';
  AExport := DefaultExportOptions;

  if not McpOptionalString(AArguments, 'in', AExport.InputPath, AError) then
    Exit;
  if AExport.InputPath = '' then
  begin
    AError := '"in" is required: the movie to convert';
    Exit;
  end;
  AExport.InputPath := ExpandFileName(AExport.InputPath);
  AExport.OutputPath := DefaultMcpExportPath(AExport.InputPath, AFormat);
  if not McpOptionalString(AArguments, 'out', AExport.OutputPath,
    AError) then
    Exit;
  AExport.OutputPath := ExpandFileName(AExport.OutputPath);
  // The tool decides the format; an explicit "out" may only agree with
  // it. Silently exporting a GIF from export_apng because the path said
  // so would make the tool's own description a lie.
  if ExportFormatForPath(AExport.OutputPath, Requested)
    and (Requested <> AFormat) then
  begin
    AError := Format('"out" names %s, but this tool writes %s',
      [ExportFormatName(Requested), ExportFormatName(AFormat)]);
    Exit;
  end;

  // A passthrough trim copies coded samples; there is no rate to change,
  // no frame to scale, and no palette to dither. The SDK deliberately
  // ignores arguments a schema does not declare, so an agent that sent
  // width to export_trim would otherwise get a silent no-op where it
  // expected a scaled movie. (The CLI warns and continues; over MCP a
  // refusal is the honest answer, because nothing here is watching
  // stderr.)
  if AFormat = efMovie then
  begin
    for I := Low(TrimInapplicable) to High(TrimInapplicable) do
      if McpHasArgument(AArguments, TrimInapplicable[I]) then
      begin
        AError := Format('"%s" does not apply to a passthrough trim: it '
          + 'copies the coded samples unchanged', [TrimInapplicable[I]]);
        Exit;
      end;
  end
  else
  begin
    if not McpOptionalInteger(AArguments, 'fps', AExport.FramesPerSecond,
      AError) then
      Exit;
    if not McpOptionalInteger(AArguments, 'width', AExport.Width,
      AError) then
      Exit;
    Dither := True;
    if not McpOptionalBoolean(AArguments, 'dither', Dither, AError) then
      Exit;
    AExport.Dither := Dither;
  end;

  if not McpOptionalNumber(AArguments, 'trim_start',
    AExport.TrimStartSeconds, AError) then
    Exit;
  if not McpOptionalNumber(AArguments, 'trim_end', AExport.TrimEndSeconds,
    AError) then
    Exit;
  AExport.HasTrimEnd := McpHasArgument(AArguments, 'trim_end');
  AExport.HasTrim := AExport.HasTrimEnd
    or McpHasArgument(AArguments, 'trim_start');

  Result := ValidateExportOptions(AExport, AError);
end;

function McpRecordingSummary(const APath: string; APixelWidth,
  APixelHeight: Integer; ADurationSeconds: Double; AFrames,
  ADropped, AFailed: Int64): string;
begin
  Result := Format('wrote %s: %dx%d, %.1fs, %d frames '
    + '(%d dropped, %d failed)', [APath, APixelWidth, APixelHeight,
    ADurationSeconds, AFrames, ADropped, AFailed]);
end;

function McpExportSummary(const APath: string; AFormat: TExportFormat;
  APixelWidth, APixelHeight: Integer; AFrames: Int64;
  ADurationSeconds: Double; AOutputBytes: Int64): string;
begin
  Result := Format('wrote %s: %s, %dx%d, %d frames, %.1fs, %d kB',
    [APath, ExportFormatName(AFormat), APixelWidth, APixelHeight, AFrames,
    ADurationSeconds, AOutputBytes div 1024]);
end;

end.

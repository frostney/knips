unit Knips.Mcp;

// `knips mcp` — the recorder as an MCP server on stdin/stdout.
//
// pascal-mcp-sdk owns the protocol; this unit owns the tools. Every
// handler is the CLI's own code path with the arguments coming from
// JSON instead of --flags: Knips.Mcp.Params builds the same validated
// option records, and the same TRecordingSession / TExportSession /
// TMovieTrimSession do the work.
//
// Threading. The stdio transport is a synchronous read-handle-write
// loop on the main thread — one line in, one handler, one line out —
// so it adds no thread of its own and needs no thread manager beyond
// the pthread-backed RTL locks Knips already installs. (The SDK's HTTP
// transport does need cthreads; knips does not use it, and the
// no-cthreads invariant stands.)
//
// Recording without blocking. record_start calls StartCapture and
// returns; the handler is over and the loop goes back to reading
// stdin. Nothing pumps a run loop in between, and nothing has to:
// ScreenCaptureKit delivers on its own GCD queue straight into the
// writer, which is exactly what the menu-bar app relies on between a
// click that starts and a click that stops. record_stop calls
// FinishCapture on the same main thread that started it, which is
// where its CFRunLoop-slice waits belong.
//
// One recording at a time. The session lives on the controller for the
// life of the process, not of a connection: a second record_start
// while one is running is an in-band error naming the file already
// being written, and record_stop with nothing running says so.

{$I Knips.inc}

interface

uses
  SysUtils;

// Serves the knips tool surface over newline-delimited JSON-RPC on
// stdin/stdout until the client closes stdin. False with a one-line
// message when the server could not be built at all; a tool that
// fails at call time reports in-band instead and the server stays up.
function RunKnipsMcpServer(out AError: string): Boolean;

implementation

uses
  fpjson,
  jsonparser,

  Knips.Mcp.Params,
  Knips.Options,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  MCP.Transport.Stdio
  {$IFDEF DARWIN}
  ,
  Knips.Capture.ShareableContent,
  Knips.Export.MovieTrim,
  Knips.Export.Pipeline,
  Knips.Export.MovieWriter,
  Knips.Recording
  {$ENDIF};

const
  ServerInstructions =
    'knips records a macOS display, a region of one, or a single '
    + 'window to an .mp4/.mov file, and converts recordings to GIF or '
    + 'APNG. Start with list_displays or list_windows to learn what can '
    + 'be captured, then record_start; the recording runs in the '
    + 'background until record_stop, and record_status reports on it '
    + 'meanwhile. Only one recording runs at a time. Screen recording '
    + 'is permitted per host application: the first capture makes macOS '
    + 'ask the app that launched this server for Screen Recording '
    + 'permission, and until that is granted every capture fails.';
  {$IFNDEF DARWIN}
  UnsupportedMessage = 'screen capture is macOS-only in this build';
  {$ENDIF}

type
  TKnipsMcpController = class
  private
    {$IFDEF DARWIN}
    // nil when nothing is recording. A session records once, so a new
    // one is created per record_start and freed by record_stop.
    FSession: TRecordingSession;
    FStartedAt: TDateTime;
    FOutputPath: string;
    function StopSession(out ASummary, AError: string): Boolean;
    function RunExport(AArguments: TJSONObject;
      AFormat: TExportFormat): TMCPToolResult;
    {$ENDIF}
    function ListDisplays(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
    function ListWindows(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
    function RecordStart(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
    function RecordStop(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
    function RecordStatus(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
    function ExportGif(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
    function ExportApng(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
    function ExportTrim(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
  public
    destructor Destroy; override;
    procedure RegisterTools(AServer: TMCPServer);
  end;

// THE boundary. Every in-band failure a tool reports — argument
// validation, the recording session, the export pipeline, a framework
// message — leaves through this one function, so the flag-to-argument
// rewrite is applied once rather than remembered at a dozen call sites.
// Messages from Knips.Recording ("--rect exceeds the display", "no
// display at index 3 (see `knips displays`)") reach a client having
// gone through it exactly like the ones from Knips.Options do.
function KnipsToolError(const AMessage: string): TMCPToolResult;
begin
  Result := MCPErrorResult(McpArgumentMessage(AMessage));
end;

{$IFDEF DARWIN}
// Bytes on disk, or 0 when the file cannot be opened. SysUtils has no
// path-taking FileSize, and a size is what a client wants before it
// decides whether to attach the thing.
function FileSizeOf(const APath: string): Int64;
var
  Handle: THandle;
begin
  Result := 0;
  Handle := FileOpen(APath, fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then
    Exit;
  try
    Result := FileSeek(Handle, Int64(0), fsFromEnd);
    if Result < 0 then
      Result := 0;
  finally
    FileClose(Handle);
  end;
end;
{$ENDIF}

{$IFNDEF DARWIN}
// Off Darwin the tool table is identical and every capture tool
// reports the same in-band refusal the CLI prints — so an agent that
// discovered the server on Linux learns what it would get rather than
// finding a tool missing.
function UnsupportedResult: TMCPToolResult;
begin
  Result := KnipsToolError(McpServerName + ': ' + UnsupportedMessage);
end;
{$ENDIF}

{ TKnipsMcpController }

destructor TKnipsMcpController.Destroy;
{$IFDEF DARWIN}
var
  Ignored: string;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  // The client closed stdin mid-recording (or killed the process
  // politely). Finalising beats leaving an unplayable fragment: the
  // moov atom is only written by AVAssetWriter's finish.
  if (FSession <> nil) and FSession.Capturing then
    FSession.FinishCapture(Ignored);
  FreeAndNil(FSession);
  {$ENDIF}
  inherited Destroy;
end;

function TKnipsMcpController.ListDisplays(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
{$IFDEF DARWIN}
var
  Content: TShareableContent;
  Display: TDisplayInfo;
  Displays: TJSONArray;
  Text: string;
  I, Scale: Integer;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  try
    Content := TShareableContent.Create;
  except
    on E: EShareableContent do
      Exit(KnipsToolError(E.Message));
  end;
  Displays := TJSONArray.Create;
  try
    Text := '';
    for I := 0 to Content.DisplayCount - 1 do
    begin
      Display := Content.DisplayAt(I);
      Scale := DisplayBackingScale(Display.DisplayID);
      Displays.Add(TJSONObject.Create([
        'index', Display.Index,
        'display_id', Int64(Display.DisplayID),
        'width', Display.Width,
        'height', Display.Height,
        'scale', Scale,
        'main', Display.IsMain]));
      Text := Text + Format('%d: %dx%d points @%dx%s'#10,
        [Display.Index, Display.Width, Display.Height, Scale,
        BoolToStr(Display.IsMain, ' [main]', '')]);
    end;
    if Text = '' then
      Text := 'no capturable displays';
    Result := MCPStructuredResult(Text,
      TJSONObject.Create(['displays', Displays]));
    // Ownership moved into the structured result.
    Displays := nil;
  finally
    Displays.Free;
    Content.Free;
  end;
  {$ELSE}
  Result := UnsupportedResult;
  {$ENDIF}
end;

function TKnipsMcpController.ListWindows(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
{$IFDEF DARWIN}
var
  Content: TShareableContent;
  Window: TWindowInfo;
  Windows: TJSONArray;
  Text: string;
  I: Integer;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  try
    Content := TShareableContent.Create;
  except
    on E: EShareableContent do
      Exit(KnipsToolError(E.Message));
  end;
  Windows := TJSONArray.Create;
  try
    Text := '';
    for I := 0 to Content.WindowCount - 1 do
    begin
      Window := Content.WindowAt(I);
      // The same filter `knips windows` prints: layer 0, on screen, and
      // big enough to be a window rather than a shadow helper.
      if (not Window.OnScreen) or (Window.Layer <> 0) then
        Continue;
      if (Window.Width = 0) or (Window.Height = 0) then
        Continue;
      Windows.Add(TJSONObject.Create([
        'window_id', Int64(Window.WindowID),
        'width', Window.Width,
        'height', Window.Height,
        'application', Window.ApplicationName,
        'title', Window.Title]));
      Text := Text + Format('%d: %dx%d  %s — %s'#10,
        [Window.WindowID, Window.Width, Window.Height,
        Window.ApplicationName, Window.Title]);
    end;
    if Text = '' then
      Text := 'no capturable windows';
    Result := MCPStructuredResult(Text,
      TJSONObject.Create(['windows', Windows]));
    Windows := nil;
  finally
    Windows.Free;
    Content.Free;
  end;
  {$ELSE}
  Result := UnsupportedResult;
  {$ENDIF}
end;

function TKnipsMcpController.RecordStart(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
{$IFDEF DARWIN}
var
  Recording: TRecordingOptions;
  Error, Directory: string;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  if (FSession <> nil) and FSession.Capturing then
    Exit(KnipsToolError('already recording to ' + FOutputPath
      + '; call record_stop first (knips records one file at a time)'));
  // A finished session is not restartable; drop it before the next.
  FreeAndNil(FSession);

  if not BuildMcpRecordingOptions(AArguments,
    DefaultMcpRecordingPath(GetUserDir, Now), Recording, Error) then
    Exit(KnipsToolError(Error));
  if not McpMayWriteRecording(AArguments, Recording.OutputPath,
    FileExists(Recording.OutputPath), Error) then
    Exit(KnipsToolError(Error));

  Directory := ExtractFilePath(Recording.OutputPath);
  if (Directory <> '') and not ForceDirectories(Directory) then
    Exit(KnipsToolError('could not create ' + Directory));

  FSession := TRecordingSession.Create(Recording);
  if not FSession.StartCapture(Error) then
  begin
    FreeAndNil(FSession);
    Exit(KnipsToolError(Error));
  end;
  FStartedAt := Now;
  FOutputPath := Recording.OutputPath;

  Result := MCPStructuredResult(
    Format('recording %dx%d @ %d fps to %s — call record_stop to finish',
    [FSession.Geometry.PixelWidth, FSession.Geometry.PixelHeight,
    FSession.Geometry.FramesPerSecond, FOutputPath]),
    TJSONObject.Create([
    'recording', True,
    'path', FOutputPath,
    'width', FSession.Geometry.PixelWidth,
    'height', FSession.Geometry.PixelHeight,
    'fps', FSession.Geometry.FramesPerSecond,
    'audio', AudioModeName(Recording.AudioMode),
    // The resolved value, like audio: a sprite failure downgrades the
    // recording to the system pointer, and a client that asked for the
    // big cursor is told what it actually got.
    'big_cursor', FSession.Report.BigCursor]));
  {$ELSE}
  Result := UnsupportedResult;
  {$ENDIF}
end;

{$IFDEF DARWIN}
function TKnipsMcpController.StopSession(out ASummary,
  AError: string): Boolean;
begin
  ASummary := '';
  Result := FSession.FinishCapture(AError);
  if Result then
    ASummary := McpRecordingSummary(FSession.Report.OutputPath,
      FSession.Geometry.PixelWidth, FSession.Geometry.PixelHeight,
      FSession.Report.DurationSeconds, FSession.Report.AppendedFrames,
      FSession.Report.DroppedFrames, FSession.Report.FailedAppends);
end;
{$ENDIF}

function TKnipsMcpController.RecordStop(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
{$IFDEF DARWIN}
var
  Summary, Error: string;
  Structured: TJSONObject;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  if (FSession = nil) or not FSession.Capturing then
    Exit(KnipsToolError('no recording is running'));
  if not StopSession(Summary, Error) then
  begin
    FreeAndNil(FSession);
    Exit(KnipsToolError(Error));
  end;
  Structured := TJSONObject.Create([
    'path', FSession.Report.OutputPath,
    'width', FSession.Geometry.PixelWidth,
    'height', FSession.Geometry.PixelHeight,
    'duration_seconds', FSession.Report.DurationSeconds,
    'frames', FSession.Report.AppendedFrames,
    'dropped_frames', FSession.Report.DroppedFrames,
    'failed_appends', FSession.Report.FailedAppends,
    'bytes', FileSizeOf(FSession.Report.OutputPath)]);
  FreeAndNil(FSession);
  Result := MCPStructuredResult(Summary, Structured);
  {$ELSE}
  Result := UnsupportedResult;
  {$ENDIF}
end;

function TKnipsMcpController.RecordStatus(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
{$IFDEF DARWIN}
var
  Elapsed: Double;
  Statistics: TMovieWriterStatistics;
  Finished: Boolean;
  Path, Summary, StopError, Text: string;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  if (FSession = nil) or not FSession.Capturing then
    Exit(MCPStructuredResult('not recording',
      TJSONObject.Create(['recording', False])));
  // One pointer sample into the event sidecar, because this is the only
  // moment an MCP recording has a main thread to sample on: the stdio
  // transport is a blocking read/handle/write loop, so between tool calls
  // nothing here runs at all. An MCP take's pointer track is therefore as
  // dense as the client's polling and no denser — the start, one per
  // record_status, and the stop. Documented in docs/event-sidecar.md
  // rather than hidden, and it is why the samples carry their own times.
  FSession.SampleMetadata;
  Elapsed := (Now - FStartedAt) * SecsPerDay;
  Statistics := FSession.LiveStatistics;

  // The writer left Writing state — a full disk, a vanished directory,
  // an encoder that gave up. The counters are frozen from here on, so
  // reporting "recording: true" forever is the one answer that leaves a
  // client waiting for a file that will never grow. Stop the session
  // for the same reason the CLI's run loop aborts on it: every further
  // frame is being recorded into a dead file. Finalising may itself
  // fail (the writer is already broken); either way the client is told
  // which happened and gets its session back.
  if Statistics.WriterFailed then
  begin
    Path := FOutputPath;
    Finished := StopSession(Summary, StopError);
    FreeAndNil(FSession);
    if Finished then
      Text := 'the recording failed while writing and has been stopped; '
        + 'the partial file was finalised — ' + Summary
    else
      Text := 'the recording failed while writing and has been stopped; '
        + 'finalising the partial file also failed (' + StopError
        + '). ' + Path + ' may be unplayable.';
    Result := MCPStructuredResult(McpArgumentMessage(Text),
      TJSONObject.Create([
      'recording', False,
      'failed', True,
      'finalised', Finished,
      'path', Path,
      'elapsed_seconds', Elapsed,
      'frames', Statistics.AppendedFrames,
      'dropped_frames', Statistics.DroppedFrames,
      'failed_appends', Statistics.FailedAppends]));
    // In-band error, not a protocol one: the status query itself
    // worked. isError is what stops an agent from reading the numbers
    // and carrying on as though the recording were fine.
    Result.IsError := True;
    Exit;
  end;

  Result := MCPStructuredResult(
    Format('recording %s for %.1fs: %d frames (%d dropped)',
    [FOutputPath, Elapsed, Statistics.AppendedFrames,
    Statistics.DroppedFrames]),
    TJSONObject.Create([
    'recording', True,
    'path', FOutputPath,
    'elapsed_seconds', Elapsed,
    'frames', Statistics.AppendedFrames,
    'dropped_frames', Statistics.DroppedFrames,
    'width', FSession.Geometry.PixelWidth,
    'height', FSession.Geometry.PixelHeight,
    'fps', FSession.Geometry.FramesPerSecond]));
  {$ELSE}
  Result := UnsupportedResult;
  {$ENDIF}
end;

{$IFDEF DARWIN}
// GIF and APNG differ only in which sink the pipeline opens, and the
// pipeline picks that from the validated format — so one body serves
// both tools.
function TKnipsMcpController.RunExport(AArguments: TJSONObject;
  AFormat: TExportFormat): TMCPToolResult;
var
  Options: TExportOptions;
  Session: TExportSession;
  Structured: TJSONObject;
  Error, Summary, Advice: string;
begin
  if not BuildMcpExportOptions(AArguments, AFormat, Options, Error) then
    Exit(KnipsToolError(Error));
  // The same no-silent-truncation contract record_start carries: agents
  // guess paths, and one server must not refuse an overwrite in one tool
  // and perform it wordlessly in the next.
  if not McpMayWriteRecording(AArguments, Options.OutputPath,
    FileExists(Options.OutputPath), Error) then
    Exit(KnipsToolError(Error));
  Session := TExportSession.Create(Options);
  try
    // Progress on stdout would land in the middle of the JSON-RPC
    // stream, which is the one thing the stdio binding forbids.
    Session.Verbose := False;
    if not Session.Run(Error) then
      Exit(KnipsToolError(Error));
    Summary := McpExportSummary(Session.Report.OutputPath,
      Session.Report.Format, Session.Report.PixelWidth,
      Session.Report.PixelHeight, Session.Report.FramesWritten,
      Session.Report.DurationSeconds, Session.Report.OutputBytes);
    Advice := LargeExportWarning(Session.Report.Format,
      Session.Report.PixelWidth, Session.Report.PixelHeight,
      Options.FramesPerSecond, Session.Report.OutputBytes);
    if Advice <> '' then
      Summary := Summary + #10 + Advice;
    Structured := TJSONObject.Create([
      'path', Session.Report.OutputPath,
      'format', ExportFormatName(Session.Report.Format),
      'width', Session.Report.PixelWidth,
      'height', Session.Report.PixelHeight,
      'frames', Session.Report.FramesWritten,
      'duration_seconds', Session.Report.DurationSeconds,
      'bytes', Session.Report.OutputBytes]);
    // Present only when there is advice to give: an always-there ""
    // reads as "there is an advice field and it is empty", which is a
    // different claim from "nothing to say".
    if Advice <> '' then
      Structured.Add('advice', Advice);
    Result := MCPStructuredResult(Summary, Structured);
  finally
    Session.Free;
  end;
end;
{$ENDIF}

function TKnipsMcpController.ExportGif(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  {$IFDEF DARWIN}
  Result := RunExport(AArguments, efGif);
  {$ELSE}
  Result := UnsupportedResult;
  {$ENDIF}
end;

function TKnipsMcpController.ExportApng(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  {$IFDEF DARWIN}
  Result := RunExport(AArguments, efApng);
  {$ELSE}
  Result := UnsupportedResult;
  {$ENDIF}
end;

function TKnipsMcpController.ExportTrim(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
{$IFDEF DARWIN}
var
  Options: TExportOptions;
  Session: TMovieTrimSession;
  Error: string;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  if not BuildMcpExportOptions(AArguments, efMovie, Options, Error) then
    Exit(KnipsToolError(Error));
  Session := TMovieTrimSession.Create(Options);
  try
    if not Session.Run(Error) then
      Exit(KnipsToolError(Error));
    Result := MCPStructuredResult(Format(
      'wrote %s: %.2fs–%.2fs of %.2fs, %d kB (streams copied)',
      [Session.Report.OutputPath, Session.Report.StartSeconds,
      Session.Report.EndSeconds, Session.Report.SourceDurationSeconds,
      Session.Report.OutputBytes div 1024]),
      TJSONObject.Create([
      'path', Session.Report.OutputPath,
      'start_seconds', Session.Report.StartSeconds,
      'end_seconds', Session.Report.EndSeconds,
      'source_duration_seconds', Session.Report.SourceDurationSeconds,
      'bytes', Session.Report.OutputBytes]));
  finally
    Session.Free;
  end;
  {$ELSE}
  Result := UnsupportedResult;
  {$ENDIF}
end;

// Output schemas. The fluent builder covers flat scalar inputs and
// nothing else, so these are raw JSON handed to the definition-taking
// RegisterTool overload — arrays of objects are not expressible any
// other way. Only inputSchema is subset-checked at freeze, so a rich
// outputSchema costs the input validation nothing.
//
// They are a promise about structuredContent, so "required" lists only
// the keys every path through the handler emits. record_status's other
// keys depend on which of its three answers it gives.
const
  DisplaysOutputSchema =
    '{"type":"object","properties":{"displays":{"type":"array","items":'
    + '{"type":"object","properties":{"index":{"type":"integer"},'
    + '"display_id":{"type":"integer"},"width":{"type":"integer"},'
    + '"height":{"type":"integer"},"scale":{"type":"integer"},'
    + '"main":{"type":"boolean"}}}}},"required":["displays"]}';
  WindowsOutputSchema =
    '{"type":"object","properties":{"windows":{"type":"array","items":'
    + '{"type":"object","properties":{"window_id":{"type":"integer"},'
    + '"width":{"type":"integer"},"height":{"type":"integer"},'
    + '"application":{"type":"string"},"title":{"type":"string"}}}}},'
    + '"required":["windows"]}';
  RecordStartOutputSchema =
    '{"type":"object","properties":{"recording":{"type":"boolean"},'
    + '"path":{"type":"string"},"width":{"type":"integer"},'
    + '"height":{"type":"integer"},"fps":{"type":"integer"},'
    + '"audio":{"type":"string"},"big_cursor":{"type":"boolean"}},'
    + '"required":["recording","path",'
    + '"width","height","fps","audio","big_cursor"]}';
  RecordStopOutputSchema =
    '{"type":"object","properties":{"path":{"type":"string"},'
    + '"width":{"type":"integer"},"height":{"type":"integer"},'
    + '"duration_seconds":{"type":"number"},"frames":{"type":"integer"},'
    + '"dropped_frames":{"type":"integer"},'
    + '"failed_appends":{"type":"integer"},"bytes":{"type":"integer"}},'
    + '"required":["path","width","height","duration_seconds","frames",'
    + '"dropped_frames","failed_appends","bytes"]}';
  RecordStatusOutputSchema =
    '{"type":"object","properties":{"recording":{"type":"boolean"},'
    + '"failed":{"type":"boolean"},"finalised":{"type":"boolean"},'
    + '"path":{"type":"string"},"elapsed_seconds":{"type":"number"},'
    + '"frames":{"type":"integer"},"dropped_frames":{"type":"integer"},'
    + '"failed_appends":{"type":"integer"},"width":{"type":"integer"},'
    + '"height":{"type":"integer"},"fps":{"type":"integer"}},'
    + '"required":["recording"]}';
  ExportOutputSchema =
    '{"type":"object","properties":{"path":{"type":"string"},'
    + '"format":{"type":"string"},"width":{"type":"integer"},'
    + '"height":{"type":"integer"},"frames":{"type":"integer"},'
    + '"duration_seconds":{"type":"number"},"bytes":{"type":"integer"},'
    + '"advice":{"type":"string"}},"required":["path","format","width",'
    + '"height","frames","duration_seconds","bytes"]}';
  TrimOutputSchema =
    '{"type":"object","properties":{"path":{"type":"string"},'
    + '"start_seconds":{"type":"number"},"end_seconds":{"type":"number"},'
    + '"source_duration_seconds":{"type":"number"},'
    + '"bytes":{"type":"integer"}},"required":["path","start_seconds",'
    + '"end_seconds","source_duration_seconds","bytes"]}';

// One tool definition: the name and description from the neutral table,
// the built input schema, and the output schema this tool promises.
function ToolDefinition(ATool: TKnipsMcpTool; constref AInput: TMCPSchema;
  const AOutputSchemaJson: string): TJSONObject;
begin
  Result := TJSONObject.Create([
    'name', KnipsMcpToolName(ATool),
    'description', KnipsMcpToolDescription(ATool),
    'inputSchema', AInput.Build,
    'outputSchema', GetJSON(AOutputSchemaJson)]);
end;

procedure TKnipsMcpController.RegisterTools(AServer: TMCPServer);
begin
  // Input schemas stay inside the server-enforced subset (flat scalar
  // properties) so every call is type-checked before a handler runs; a
  // region is four integers for the same reason. The SDK ignores
  // properties a schema does not declare, so anything inapplicable that
  // slips through is refused in Knips.Mcp.Params instead.
  AServer.RegisterTool(ToolDefinition(kmtListDisplays, ObjectSchema,
    DisplaysOutputSchema), ListDisplays)
    .Title('List displays').ReadOnlyHint;

  AServer.RegisterTool(ToolDefinition(kmtListWindows, ObjectSchema,
    WindowsOutputSchema), ListWindows)
    .Title('List windows').ReadOnlyHint;

  AServer.RegisterTool(ToolDefinition(kmtRecordStart,
    ObjectSchema
      .AddString('out', 'Output file, .mp4 or .mov. Defaults to a '
      + 'timestamped name in ~/Movies/knips/. A relative path is '
      + 'resolved against the server''s working directory and returned '
      + 'absolute.', False)
      .AddBoolean('overwrite', 'Replace "out" if it already exists '
      + '(default false). Without this, an existing file is refused '
      + 'rather than destroyed.', False)
      .AddInteger('display', 'Display index from list_displays (0 or '
      + 'more); omit for the main display.', False)
      .AddInteger('window', 'Window id from list_windows. Records that '
      + 'window alone; mutually exclusive with display and a region.',
      False)
      .AddInteger('left', 'Region origin X in points. All four of '
      + 'left/top/width/height are needed, or none.', False)
      .AddInteger('top', 'Region origin Y in points, from the top.',
      False)
      .AddInteger('width', 'Region width in points.', False)
      .AddInteger('height', 'Region height in points.', False)
      .AddInteger('fps', Format('Frames per second, %d-%d (default %d).',
      [MinFramesPerSecond, MaxFramesPerSecond, DefaultFramesPerSecond]),
      False)
      .AddString('scale', 'Pixels per point: "auto", "1", or "2" '
      + '(default "auto").', False)
      .AddString('audio', 'Record audio: none, system, mic, or both '
      + '(default none).', False)
      .AddBoolean('cursor', 'Show the pointer in the recording '
      + '(default true).', False)
      .AddBoolean('big_cursor', 'Draw an enlarged pointer into the '
      + 'frames instead of capturing the system one (default false). '
      + 'Display recordings only, and not with cursor=false.', False)
      .AddInteger('bitrate', 'Average video bit rate in bits per '
      + 'second; omit to derive one from the capture size.', False),
    RecordStartOutputSchema), RecordStart)
    .Title('Start recording').OpenWorldHint(False);

  AServer.RegisterTool(ToolDefinition(kmtRecordStop, ObjectSchema,
    RecordStopOutputSchema), RecordStop)
    .Title('Stop recording').OpenWorldHint(False);

  // NOT ReadOnlyHint: on a dead writer this tool stops and finalises
  // the recording (the CLI's abort-don't-record-into-a-dead-file rule),
  // and clients auto-approve read-only tools — an annotation that
  // promised no side effects would let a polling agent finalise the
  // user's recording without anyone consenting to a mutating call.
  AServer.RegisterTool(ToolDefinition(kmtRecordStatus, ObjectSchema,
    RecordStatusOutputSchema), RecordStatus)
    .Title('Recording status').OpenWorldHint(False);

  AServer.RegisterTool(ToolDefinition(kmtExportGif,
    ObjectSchema
      .AddString('in', 'The recorded movie to convert (.mp4 or .mov).')
      .AddString('out', 'Output .gif; defaults to the input path with '
      + 'a .gif extension. Returned absolute.', False)
      .AddBoolean('overwrite', 'Replace "out" if it already exists '
      + '(default false: an existing file is refused).', False)
      .AddInteger('fps', Format('Frames per second, %d-%d (default %d).',
      [MinGifFramesPerSecond, MaxGifFramesPerSecond,
      DefaultGifFramesPerSecond]), False)
      .AddInteger('width', Format('Scale to this width in pixels, '
      + '%d-%d; omit to keep the movie''s own.',
      [MinGifWidth, MaxGifWidth]), False)
      .AddNumber('trim_start', 'Seconds to start from.', False)
      .AddNumber('trim_end', 'Seconds to stop at; omit to run to the '
      + 'end.', False)
      .AddBoolean('dither', 'Floyd-Steinberg dithering (default true). '
      + 'False is smaller but bands.', False),
    ExportOutputSchema), ExportGif)
    .Title('Export GIF').OpenWorldHint(False);

  AServer.RegisterTool(ToolDefinition(kmtExportApng,
    ObjectSchema
      .AddString('in', 'The recorded movie to convert (.mp4 or .mov).')
      .AddString('out', 'Output .apng; defaults to the input path with '
      + 'an .apng extension. Returned absolute.', False)
      .AddBoolean('overwrite', 'Replace "out" if it already exists '
      + '(default false: an existing file is refused).', False)
      .AddInteger('fps', Format('Frames per second, %d-%d (default %d).',
      [MinGifFramesPerSecond, MaxGifFramesPerSecond,
      DefaultGifFramesPerSecond]), False)
      .AddInteger('width', Format('Scale to this width in pixels, '
      + '%d-%d; omit to keep the movie''s own.',
      [MinGifWidth, MaxGifWidth]), False)
      .AddNumber('trim_start', 'Seconds to start from.', False)
      .AddNumber('trim_end', 'Seconds to stop at; omit to run to the '
      + 'end.', False),
    ExportOutputSchema), ExportApng)
    .Title('Export APNG').OpenWorldHint(False);

  AServer.RegisterTool(ToolDefinition(kmtExportTrim,
    ObjectSchema
      .AddString('in', 'The movie to trim (.mp4 or .mov).')
      .AddString('out', 'Output movie; defaults to the input path with '
      + 'a -trim suffix. Must not be the input itself. Returned '
      + 'absolute.', False)
      .AddBoolean('overwrite', 'Replace "out" if it already exists '
      + '(default false: an existing file is refused).', False)
      .AddNumber('trim_start', 'Seconds to start from.', False)
      .AddNumber('trim_end', 'Seconds to stop at; omit to run to the '
      + 'end. At least one side is required.', False),
    TrimOutputSchema), ExportTrim)
    .Title('Trim movie').OpenWorldHint(False);
  // No fps/width/dither here: a passthrough trim copies coded samples,
  // so they would be a silent no-op. Params refuses them.
end;

function RunKnipsMcpServer(out AError: string): Boolean;
var
  Server: TMCPServer;
  Controller: TKnipsMcpController;
begin
  Result := False;
  AError := '';
  Controller := TKnipsMcpController.Create;
  try
    Server := TMCPServer.Create(McpServerName, KnipsVersion);
    try
      Server.Instructions := ServerInstructions;
      try
        Controller.RegisterTools(Server);
      except
        on E: Exception do
        begin
          AError := 'could not register the tools: ' + E.Message;
          Exit;
        end;
      end;
      RunMCPStdioServer(Server);
      Result := True;
    finally
      Server.Free;
    end;
  finally
    Controller.Free;
  end;
end;

end.

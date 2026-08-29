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
  Knips.Recording.Sidecar,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  MCP.Transport.Stdio
  {$IFDEF DARWIN}
  ,
  Knips.Capture.ShareableContent,
  Knips.Export.MovieTrim,
  Knips.Export.MovieWriter,
  Knips.Export.Pipeline,
  Knips.Export.Render,
  Knips.Recording
  {$ENDIF};

const
  ServerInstructions =
    'knips records a macOS display, a region of one, or a single '
    + 'window to an .mp4/.mov file, renders raw takes into deliverables, '
    + 'and converts recordings to GIF or APNG. Start with list_displays '
    + 'or list_windows to learn what can be captured, then record_start; '
    + 'the recording runs in the background until record_stop, and '
    + 'record_status reports on it meanwhile. Only one recording runs at '
    + 'a time. '
    // The product model, in the one place every client reads before it
    // picks a tool. Without it an agent records with the pointer baked
    // in, which is the one decision that cannot be taken back.
    + 'A recording made with "smooth_cursor": true is a RAW take: no '
    + 'pointer in its pixels, and an event sidecar beside it holding the '
    + 'pointer track and the clicks. render turns a raw take into a '
    + 'deliverable with the pointer drawn back and a zoom driven by the '
    + 'clicks, and leaves the take on disk — so the same recording can '
    + 'be rendered again with different effects for as long as it is '
    + 'kept. A take recorded WITHOUT smooth_cursor has the pointer in '
    + 'its pixels for good. record_stop does not render; it hands back '
    + 'the take and says where render would write. take_info answers, '
    + 'for any movie on disk, which effects it can still be given. '
    // The sampling rule, said in the instructions as well as on the
    // tool, because it is the one thing about this server a client has
    // to do something about WHILE a recording runs.
    + 'The pointer track of an MCP recording is only as dense as your '
    + 'polling: one sample at the start, one per record_status, one at '
    + 'the stop. Poll about once a second during a raw take or the drawn '
    + 'pointer will be a straight line. '
    + 'Screen recording '
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
    function TakeInfo(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
    function Render(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
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

// A note field is present only when there is something to say. An
// always-there "" reads as "there is a reason field and the reason is
// empty", which is a different claim from "the effect applied" — the
// same rule the export's `advice` already follows.
procedure AddNote(AStructured: TJSONObject; const AName, ANote: string);
begin
  if ANote <> '' then
    AStructured.Add(AName, McpArgumentMessage(ANote));
end;

// The three effect notes as text lines, in the order
// Knips.Options.EffectNoteSummary ranks them and — through
// EffectCursorNoteLine / EffectZoomNoteLine — in the words `knips
// render` prints. All three, not the summary: a JSON-RPC result has
// room, and the summary exists for the places that do not.
//
// An effect that was asked for and could not be applied is NOT a failure
// — the file is written and correct without it — so this rides on a
// successful result rather than turning it into an error. It is never
// silent either, which is the whole point: a client that asked for a
// zoom and got none has to be able to find out why without diffing
// pixels.
function EffectNoteLines(const AFramingNote, ACursorNote,
  AZoomNote: string): string;
begin
  Result := '';
  if AFramingNote <> '' then
    Result := Result + #10 + McpArgumentMessage(AFramingNote);
  if ACursorNote <> '' then
    Result := Result + #10
      + EffectCursorNoteLine(McpArgumentMessage(ACursorNote));
  if AZoomNote <> '' then
    Result := Result + #10
      + EffectZoomNoteLine(McpArgumentMessage(AZoomNote));
end;

// Bytes on disk, or 0 when the file cannot be opened. SysUtils has no
// path-taking FileSize, and a size is what a client wants before it
// decides whether to attach the thing. Outside the Darwin guard because
// take_info is: reading a sidecar needs no framework.
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
  Structured: TJSONObject;
  Error, Directory, Note, Text: string;
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

  Text := Format('recording %dx%d @ %d fps to %s — call record_stop to '
    + 'finish', [FSession.Geometry.PixelWidth,
    FSession.Geometry.PixelHeight, FSession.Geometry.FramesPerSecond,
    FOutputPath]);
  // Said on the call that decides it, not left for the client to find
  // out from a flat pointer track afterwards — see McpSparseTrackNote.
  Note := McpSparseTrackNote(FSession.Report.SmoothCursor);
  if Note <> '' then
    Text := Text + #10 + Note;
  Structured := TJSONObject.Create([
    'recording', True,
    'path', FOutputPath,
    'width', FSession.Geometry.PixelWidth,
    'height', FSession.Geometry.PixelHeight,
    'fps', FSession.Geometry.FramesPerSecond,
    'audio', AudioModeName(Recording.AudioMode),
    // The resolved values, like audio: a sprite failure downgrades the
    // recording to the system pointer, and a client that asked for the
    // big cursor is told what it actually got.
    'big_cursor', FSession.Report.BigCursor,
    'smooth_cursor', FSession.Report.SmoothCursor,
    // The same fact under the name the rest of the surface uses for it:
    // a raw take is one whose pixels are still undecided.
    'raw', FSession.Report.SmoothCursor]);
  if Note <> '' then
    Structured.Add('note', Note);
  Result := MCPStructuredResult(Text, Structured);
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
  Summary, Error, Advice: string;
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
  // Nothing is rendered here, on purpose. The menu-bar app renders on
  // every stop because a person clicked once and wants a file; an agent
  // is a different caller. A render is seconds of work with no progress
  // a stdio client can see, it needs a second output path, and it is a
  // decision — which effects — that this call has no arguments for. So
  // the stop stays what it is (the raw take plus its sidecar, cheaply
  // and predictably), render is a separate call, and both tools say so
  // in their descriptions. What the stop DOES do is hand back everything
  // that call needs: the take, its sidecar, the samples that arrived,
  // and the path a render would write.
  Structured := TJSONObject.Create([
    'path', FSession.Report.OutputPath,
    'width', FSession.Geometry.PixelWidth,
    'height', FSession.Geometry.PixelHeight,
    'duration_seconds', FSession.Report.DurationSeconds,
    'frames', FSession.Report.AppendedFrames,
    'dropped_frames', FSession.Report.DroppedFrames,
    'failed_appends', FSession.Report.FailedAppends,
    // How much of `frames` was the idle heartbeat repeating the last one,
    // and how many repeats were due and could not be made. An MCP take is
    // the sparse case — nothing runs on the main thread between tool
    // calls — so a client that polled rarely should expect few of the
    // first, and `heartbeats_refused` above zero is the one number that
    // says the mechanism stopped working (docs/architecture.md, "The
    // idle heartbeat").
    'heartbeats', FSession.Report.HeartbeatFrames,
    'heartbeats_refused', FSession.Report.HeartbeatRefused,
    // Whether this take's pixels are still undecided, and how much of
    // the track that decides them actually arrived. The count is the
    // measured half of the warning record_start gives: a client that
    // polled twice sees 3 here and knows what a smooth cursor drawn from
    // it would look like before it renders one.
    'raw', FSession.Report.SmoothCursor,
    'pointer_samples', FSession.Report.SidecarSamples,
    // Where render would write if it were called with this take and no
    // "out". Named here because the pair on disk is the product model
    // and a client should not have to derive it — but it is a NAME, not
    // a promise: a take with the pointer already in its pixels and no
    // clicks has nothing to apply and render refuses it outright. `raw`
    // above, or take_info, is what says whether a render would happen.
    'render_output_path', DefaultMcpRenderPath(
    FSession.Report.OutputPath),
    'bytes', FileSizeOf(FSession.Report.OutputPath)]);
  if FSession.Report.SidecarPath <> '' then
    Structured.Add('sidecar_path', FSession.Report.SidecarPath);
  if FSession.Report.SmoothCursor then
    Summary := Summary + #10 + 'this is a raw take: call render with '
      + '"in": "' + FSession.Report.OutputPath + '" to draw the pointer '
      + 'back and apply a zoom, or take_info to see what it can have.';
  // The one cross-feature surprise worth a sentence: an enlarged pointer
  // composited on the capture queue, on a take the idle heartbeat spent
  // repeating, stands still wherever the screen did. Never a failure,
  // and never silent (Knips.Options.BigCursorIdleWarning). Through the
  // rewriter, because it names the flags that would have avoided it.
  Advice := McpArgumentMessage(BigCursorIdleWarning(
    FSession.Report.BigCursor, FSession.Report.CursorFrames,
    FSession.Report.HeartbeatFrames, FSession.Report.AppendedFrames));
  if Advice <> '' then
  begin
    Summary := Summary + #10 + Advice;
    Structured.Add('advice', Advice);
  end;
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
      'failed_appends', Statistics.FailedAppends,
      // The failed branch is where a client most wants to know whether
      // the heartbeat had stopped working before the writer did.
      'heartbeats', Statistics.HeartbeatFrames,
      'heartbeats_refused', Statistics.HeartbeatRefused]));
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
    // See record_stop: how much of `frames` is the idle heartbeat, and
    // the refusal count that would say it had stopped working. Mid-take
    // here rather than at the end, which is what lets a client watching a
    // long recording notice.
    'heartbeats', Statistics.HeartbeatFrames,
    'heartbeats_refused', Statistics.HeartbeatRefused,
    // The track this very call just added to. A client that polls can
    // watch it grow and see for itself that its polling is what makes a
    // raw take renderable; one that does not poll never reads this.
    'pointer_samples', FSession.SidecarSampleCount,
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
    // Through the rewriter, like every other message that leaves this
    // server. This one advises in flags — "consider --width=800 or
    // --fps=15" — which is exactly the sentence that sends an agent
    // looking for a command line it does not have; its sibling
    // BigCursorIdleWarning on record_stop is rewritten for the same
    // reason.
    Advice := McpArgumentMessage(LargeExportWarning(Session.Report.Format,
      Session.Report.PixelWidth, Session.Report.PixelHeight,
      Options.FramesPerSecond, Session.Report.OutputBytes));
    if Advice <> '' then
      Summary := Summary + #10 + Advice;
    Structured := TJSONObject.Create([
      'path', Session.Report.OutputPath,
      'format', ExportFormatName(Session.Report.Format),
      'width', Session.Report.PixelWidth,
      'height', Session.Report.PixelHeight,
      'frames', Session.Report.FramesWritten,
      'duration_seconds', Session.Report.DurationSeconds,
      'bytes', Session.Report.OutputBytes,
      // What was asked for, echoed the way record_start echoes audio and
      // big_cursor…
      'zoom', Options.Effects.ZoomOnClick,
      'cursor', ExportCursorModeName(Options.Effects.Cursor),
      // …and what actually reached the pixels, which is a different
      // question: an effect that could not apply is never a failure, so
      // these and the notes below are the only way a caller finds out.
      'zoom_applied', Session.Report.ZoomOnClick,
      'zoomed_frames', Session.Report.ZoomedFrames,
      'clicks', Session.Report.ZoomClicks,
      'cursor_drawn', Session.Report.SmoothCursor,
      'cursor_frames', Session.Report.SmoothCursorFrames,
      'cursor_off_frame_frames', Session.Report.SmoothCursorOffFrame]);
    Summary := Summary + EffectNoteLines(Session.Report.FramingNote,
      Session.Report.SmoothCursorNote, Session.Report.ZoomNote);
    AddNote(Structured, 'framing_note', Session.Report.FramingNote);
    AddNote(Structured, 'cursor_note', Session.Report.SmoothCursorNote);
    AddNote(Structured, 'zoom_note', Session.Report.ZoomNote);
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

// take_info. Read-only, and outside the Darwin guard on purpose: it
// opens no framework, it reads a sidecar and stats two files, and a
// client that can ask "what is this take" on any host is strictly better
// than one that cannot.
//
// A dedicated tool rather than more fields on record_stop, for two
// reasons. The question is asked about takes this server did not record
// — the interesting one is "can I still zoom the file I found on disk",
// and record_stop can only ever answer for the take it just finished.
// And it is the question an agent asks BEFORE it acts: folding it into a
// stop would mean recording something in order to learn what render can
// do, which is the wrong order and an expensive way to find out. Being
// its own tool is also what lets it carry ReadOnlyHint, so a client can
// let a planning call through without a confirmation it would have to
// ask for on record_stop.
function TKnipsMcpController.TakeInfo(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Log: TSidecarLog;
  Loaded: Boolean;
  Path, SidecarPath, LoadError, Error: string;
begin
  Path := '';
  if not McpOptionalString(AArguments, 'path', Path, Error) then
    Exit(KnipsToolError(Error));
  if Path = '' then
    Exit(KnipsToolError('"path" is required: the movie to describe'));
  Path := ExpandFileName(Path);
  // A path that names nothing is a mistake, not a fact about a take: an
  // agent that mistyped one wants to be told, not handed a confident
  // "nothing can be applied to this".
  if not FileExists(Path) then
    Exit(KnipsToolError('no such file: ' + Path));
  SidecarPath := SidecarPathFor(Path);
  Log := TSidecarLog.Create;
  try
    LoadError := '';
    Loaded := Log.LoadFromFile(SidecarPath, LoadError);
    if not Loaded then
      FreeAndNil(Log);
    Result := MCPStructuredResult(
      McpTakeInfoSummary(Path, Log, LoadError),
      McpTakeInfoObject(Path, SidecarPath, FileSizeOf(Path), Log,
      LoadError));
  finally
    Log.Free;
  end;
end;

// render: a raw take plus its sidecar in, the deliverable out. The same
// TRenderSession `knips render` runs, so an MCP tool and a subcommand
// are one implementation — which is the invariant this server was
// breaking for as long as it had no render at all.
function TKnipsMcpController.Render(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
{$IFDEF DARWIN}
var
  Effects: TExportEffects;
  Facts: TRenderAppliedFacts;
  Session: TRenderSession;
  Structured: TJSONObject;
  InputPath, OutputPath, Error, Summary, Applied: string;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  InputPath := '';
  if not McpOptionalString(AArguments, 'in', InputPath, Error) then
    Exit(KnipsToolError(Error));
  if InputPath = '' then
    Exit(KnipsToolError('"in" is required: the raw take to render'));
  InputPath := ExpandFileName(InputPath);
  OutputPath := DefaultMcpRenderPath(InputPath);
  if not McpOptionalString(AArguments, 'out', OutputPath, Error) then
    Exit(KnipsToolError(Error));
  if OutputPath = '' then
    Exit(KnipsToolError('no output path, and none could be derived from '
      + '"in"'));
  OutputPath := ExpandFileName(OutputPath);
  // The same check `knips render` makes, from the same function: this
  // pass writes H.264 into a QuickTime-family container and nothing
  // else, so an "out" it cannot honour is refused rather than written
  // under a name that lies about what is inside it.
  if not ValidateRenderOutputPath(OutputPath, Error) then
    Exit(KnipsToolError(Error));
  // Arguments this tool has no use for, refused rather than dropped —
  // the SDK ignores properties a schema does not declare, so a client
  // that sent width to render would otherwise get a full-size movie and
  // no hint the request went nowhere. Exactly the rule export_trim
  // already documents, and the refusal names the tool that CAN do it.
  if not McpRenderRefusesArguments(AArguments, Error) then
    Exit(KnipsToolError(Error));
  Effects := DefaultExportEffects;
  if not ReadMcpExportEffects(AArguments, Effects, Error) then
    Exit(KnipsToolError(Error));

  // The overwrite gate, and it is worth saying exactly what it is doing
  // here because this is the one writer whose CLI half deliberately
  // replaces its output. `knips render` overwrites the deliverable —
  // atomically, through a temporary — because the app renders on every
  // stop and the deliverable IS the thing being replaced; that is the
  // right behaviour for a path a person named and a file they are
  // watching. Over MCP the same rule would let a re-render with the
  // wrong "in" quietly replace a finished deliverable an agent has
  // already handed to somebody. So the server's own convention wins: an
  // existing output is refused by name unless "overwrite" says
  // otherwise, exactly as record_start and the three exports refuse
  // theirs.
  //
  // The check runs BEFORE the render, so a refused call costs nothing —
  // no decode, no temporary, and the existing deliverable is not even
  // opened. And when it does go ahead, the replacement is still atomic:
  // TRenderSession builds into `<out>.knips-render-tmp` and renames,
  // so a killed render cannot leave a stub where the old file was.
  if not McpMayWriteRecording(AArguments, OutputPath,
    FileExists(OutputPath), Error) then
    Exit(KnipsToolError(Error));

  Session := TRenderSession.Create(InputPath, OutputPath, Effects);
  try
    // Progress on stdout would land in the middle of the JSON-RPC
    // stream, exactly as it would for an export.
    Session.Verbose := False;
    // A take that can carry no effect at all is refused in here, with
    // its own reason ("nothing in this take can be applied after the
    // fact… it is already the deliverable"). That refusal is the honest
    // answer rather than a duplicate movie, and take_info is how a
    // client sees it coming.
    if not Session.Run(Error) then
      Exit(KnipsToolError(Error));
    // The same clause list `knips render` prints, from the same
    // function in Knips.Options — the two used to hold a byte-identical
    // copy of it each.
    Facts := RenderAppliedFacts;
    Facts.ZoomApplied := Session.Report.ZoomApplied;
    Facts.ZoomedFrames := Session.Report.ZoomedFrames;
    Facts.FramesWritten := Session.Report.FramesWritten;
    Facts.UsableClicks := Session.Report.UsableClicks;
    Facts.CursorDrawn := Session.Report.CursorDrawn;
    Facts.CursorFrames := Session.Report.CursorFrames;
    Facts.CursorOffFrameFrames := Session.Report.CursorOffFrameFrames;
    Facts.SynthesizedFrames := Session.Report.SynthesizedFrames;
    Facts.SynthesisFramesPerSecond :=
      Session.Report.SynthesisFramesPerSecond;
    Facts.AudioTracks := Session.Report.AudioTracks;
    Facts.AudioPassthrough := Session.Report.AudioPassthrough;
    Facts.AudioSamples := Session.Report.AudioSamples;
    Applied := RenderAppliedSummary(Facts);
    Summary := RenderSummaryLine(Session.Report.OutputPath,
      Session.Report.PixelWidth, Session.Report.PixelHeight,
      Session.Report.FramesWritten,
      Session.Report.SourceDurationSeconds, Session.Report.OutputBytes,
      Session.Report.Copied, Applied);
    Summary := Summary + EffectNoteLines(Session.Report.FramingNote,
      Session.Report.CursorNote, Session.Report.ZoomNote);
    Structured := TJSONObject.Create([
      'path', Session.Report.OutputPath,
      'input_path', Session.Report.InputPath,
      'width', Session.Report.PixelWidth,
      'height', Session.Report.PixelHeight,
      'frames', Session.Report.FramesWritten,
      'duration_seconds', Session.Report.SourceDurationSeconds,
      'bytes', Session.Report.OutputBytes,
      // True when nothing applied and the take was copied byte for byte
      // rather than re-encoded to produce the same movie.
      'copied', Session.Report.Copied,
      // Asked for…
      'zoom', Effects.ZoomOnClick,
      'cursor', ExportCursorModeName(Effects.Cursor),
      // …and whether the effect ENGAGED. Not the same claim as "reached
      // the pixels": TRenderReport sets these when the effect was
      // prepared and had something to work with, and a zoom that was
      // engaged over a stretch with nothing to crop still shows as
      // applied. The pixel-level numbers are the two counts under each
      // of them — zoomed_frames and cursor_frames — and those are what a
      // caller checking whether it actually got the effect should read.
      // Same fields the CLI prints from, so the two agree.
      'zoom_applied', Session.Report.ZoomApplied,
      'zoomed_frames', Session.Report.ZoomedFrames,
      'clicks', Session.Report.UsableClicks,
      'cursor_drawn', Session.Report.CursorDrawn,
      'cursor_frames', Session.Report.CursorFrames,
      'cursor_off_frame_frames', Session.Report.CursorOffFrameFrames,
      'synthesized_frames', Session.Report.SynthesizedFrames,
      'synthesis_fps', Session.Report.SynthesisFramesPerSecond,
      'unframed_frames', Session.Report.UnframedFrames,
      'audio_tracks', Session.Report.AudioTracks,
      'audio_samples', Session.Report.AudioSamples,
      'audio_passthrough', Session.Report.AudioPassthrough,
      'elapsed_seconds', Session.Report.ElapsedSeconds,
      'realtime_factor', Session.Report.RealtimeFactor]);
    // The deliverable's own sidecar. A rendered take is two movies and
    // two sidecars, and without this the second pair is written and
    // never mentioned.
    if Session.Report.SidecarPath <> '' then
      Structured.Add('sidecar_path', Session.Report.SidecarPath);
    // The three, and not TRenderReport.Note beside them. Note is the
    // one-line SUMMARY of exactly these three, for a caller that has one
    // line to show — the menu's Last-error slot, the playback title.
    // A JSON object has room for all three, so carrying the summary as
    // well would be one of them repeated under a fourth name, which is
    // the shape that makes a client wonder which one is authoritative.
    // (Knips.Options.EffectNoteSummary says as much about what it is
    // for.)
    AddNote(Structured, 'framing_note', Session.Report.FramingNote);
    AddNote(Structured, 'cursor_note', Session.Report.CursorNote);
    AddNote(Structured, 'zoom_note', Session.Report.ZoomNote);
    Result := MCPStructuredResult(Summary, Structured);
  finally
    Session.Free;
  end;
  {$ELSE}
  Result := UnsupportedResult;
  {$ENDIF}
end;

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
  // Exactly as RunExport does, and for the same reason its comment
  // gives: this tool's own schema promises to refuse an existing output
  // unless `overwrite` says otherwise, and a trim that destroyed the
  // file anyway was the one tool in this server breaking that promise.
  if not McpMayWriteRecording(AArguments, Options.OutputPath,
    FileExists(Options.OutputPath), Error) then
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

// One tool definition: the name, the description and the output schema
// from the neutral table, plus the built input schema.
//
// The output schemas moved to Knips.Mcp.Params, beside the names they
// belong to: they are raw JSON handed to the definition-taking
// RegisterTool overload (the fluent builder covers flat scalar inputs
// and nothing else, so an array of objects is not expressible any other
// way), and raw JSON that nothing parses is raw JSON that goes stale.
// There, the suite parses every one of them on every host and checks it
// against its own "required" list.
function ToolDefinition(ATool: TKnipsMcpTool;
  constref AInput: TMCPSchema): TJSONObject;
begin
  Result := TJSONObject.Create([
    'name', KnipsMcpToolName(ATool),
    'description', KnipsMcpToolDescription(ATool),
    'inputSchema', AInput.Build,
    'outputSchema', GetJSON(KnipsMcpOutputSchema(ATool))]);
end;

procedure TKnipsMcpController.RegisterTools(AServer: TMCPServer);
const
  // The two effect arguments, on the three tools that decode frames.
  // Flat scalars rather than one `effects` object because the SDK's
  // server-enforced schema subset is flat scalars, and leaving it costs
  // the whole tool its call-time argument checking — see
  // Knips.Mcp.Params.ReadMcpExportEffects. The four tunable numbers of
  // TExportEffects are reserved and not exposed.
  ZoomHelp = 'Zoom on Click, replayed after the fact from the event '
    + 'sidecar''s click track with the same easing and hold the live '
    + 'effect uses (default false). Refused for a take whose capture was '
    + 'already zooming; take_info says so in advance.';
  CursorHelp = 'The pointer, drawn from the event sidecar''s smoothed '
    + 'track: "as-recorded" (default — whatever the recording asked '
    + 'for), "none", "smooth", or "big". Anything but "as-recorded" '
    + 'needs a movie with no pointer already in its pixels, which means '
    + 'a take recorded with smooth_cursor or with cursor=false.';
  OverwriteHelp = 'Replace "out" if it already exists (default false: '
    + 'an existing file is refused by name rather than destroyed).';
begin
  // Input schemas stay inside the server-enforced subset (flat scalar
  // properties) so every call is type-checked before a handler runs; a
  // region is four integers for the same reason. The SDK ignores
  // properties a schema does not declare, so anything inapplicable that
  // slips through is refused in Knips.Mcp.Params instead.
  AServer.RegisterTool(ToolDefinition(kmtListDisplays, ObjectSchema),
    ListDisplays)
    .Title('List displays').ReadOnlyHint;

  AServer.RegisterTool(ToolDefinition(kmtListWindows, ObjectSchema),
    ListWindows)
    .Title('List windows').ReadOnlyHint;

  // ReadOnlyHint, and it is the only writer-adjacent tool here that gets
  // it: take_info opens nothing, writes nothing and stops nothing. That
  // is what makes it useful — a client can let a planning call through
  // without the confirmation it would rightly demand for a render.
  AServer.RegisterTool(ToolDefinition(kmtTakeInfo,
    ObjectSchema
      .AddString('path', 'The movie to describe (.mp4 or .mov). Its '
      + 'event sidecar is looked for beside it.')),
    TakeInfo)
    .Title('Describe a take').ReadOnlyHint;

  AServer.RegisterTool(ToolDefinition(kmtRecordStart,
    ObjectSchema
      .AddString('out', 'Output file, .mp4 or .mov. Defaults to a '
      + 'timestamped name in ~/Movies/knips/ — with a "-raw" suffix when '
      + 'smooth_cursor is on, so the deliverable render writes has the '
      + 'plain name. A relative path is resolved against the server''s '
      + 'working directory and returned absolute.', False)
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
      .AddBoolean('smooth_cursor', 'Record a RAW take (default false): '
      + 'no pointer in the pixels, the pointer track and the clicks in '
      + 'an event sidecar beside the movie, so render can draw the '
      + 'pointer back and zoom on the clicks afterwards — and can do it '
      + 'again with different effects for as long as the take is kept. '
      + 'Display recordings only, and not with cursor=false or '
      + 'big_cursor=true. NOTE: over MCP the pointer is sampled only at '
      + 'the start, at each record_status call, and at the stop, so poll '
      + 'record_status about once a second while the take runs or the '
      + 'drawn pointer will be a straight line between a handful of '
      + 'points.', False)
      .AddInteger('bitrate', 'Average video bit rate in bits per '
      + 'second; omit to derive one from the capture size.', False)),
    RecordStart)
    .Title('Start recording').OpenWorldHint(False);

  AServer.RegisterTool(ToolDefinition(kmtRecordStop, ObjectSchema),
    RecordStop)
    .Title('Stop recording').OpenWorldHint(False);

  // NOT ReadOnlyHint: on a dead writer this tool stops and finalises
  // the recording (the CLI's abort-don't-record-into-a-dead-file rule),
  // and clients auto-approve read-only tools — an annotation that
  // promised no side effects would let a polling agent finalise the
  // user's recording without anyone consenting to a mutating call.
  AServer.RegisterTool(ToolDefinition(kmtRecordStatus, ObjectSchema),
    RecordStatus)
    .Title('Recording status').OpenWorldHint(False);

  AServer.RegisterTool(ToolDefinition(kmtRender,
    ObjectSchema
      .AddString('in', 'The raw take to render (.mp4 or .mov). Its event '
      + 'sidecar is read from beside it.')
      .AddString('out', 'Output .mp4/.mov. Defaults to the take''s own '
      + 'name without the "-raw" suffix, or — for an input that is not a '
      + 'raw take — the input name with a "-rendered" suffix beside it. '
      + 'Never the input itself: the take is what makes the effects '
      + 'changeable later. Returned absolute.', False)
      .AddBoolean('overwrite', OverwriteHelp, False)
      .AddBoolean('zoom', ZoomHelp, False)
      .AddString('cursor', CursorHelp, False)),
    Render)
    .Title('Render a take').OpenWorldHint(False);

  AServer.RegisterTool(ToolDefinition(kmtExportGif,
    ObjectSchema
      .AddString('in', 'The recorded movie to convert (.mp4 or .mov).')
      .AddString('out', 'Output .gif; defaults to the input path with '
      + 'a .gif extension. Returned absolute.', False)
      .AddBoolean('overwrite', OverwriteHelp, False)
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
      + 'False is smaller but bands.', False)
      .AddBoolean('zoom', ZoomHelp, False)
      .AddString('cursor', CursorHelp, False)),
    ExportGif)
    .Title('Export GIF').OpenWorldHint(False);

  AServer.RegisterTool(ToolDefinition(kmtExportApng,
    ObjectSchema
      .AddString('in', 'The recorded movie to convert (.mp4 or .mov).')
      .AddString('out', 'Output .apng; defaults to the input path with '
      + 'an .apng extension. Returned absolute.', False)
      .AddBoolean('overwrite', OverwriteHelp, False)
      .AddInteger('fps', Format('Frames per second, %d-%d (default %d).',
      [MinGifFramesPerSecond, MaxGifFramesPerSecond,
      DefaultGifFramesPerSecond]), False)
      .AddInteger('width', Format('Scale to this width in pixels, '
      + '%d-%d; omit to keep the movie''s own.',
      [MinGifWidth, MaxGifWidth]), False)
      .AddNumber('trim_start', 'Seconds to start from.', False)
      .AddNumber('trim_end', 'Seconds to stop at; omit to run to the '
      + 'end.', False)
      .AddBoolean('zoom', ZoomHelp, False)
      .AddString('cursor', CursorHelp, False)),
    ExportApng)
    .Title('Export APNG').OpenWorldHint(False);

  AServer.RegisterTool(ToolDefinition(kmtExportTrim,
    ObjectSchema
      .AddString('in', 'The movie to trim (.mp4 or .mov).')
      .AddString('out', 'Output movie; defaults to the input path with '
      + 'a -trim suffix. Must not be the input itself. Returned '
      + 'absolute.', False)
      .AddBoolean('overwrite', OverwriteHelp, False)
      .AddNumber('trim_start', 'Seconds to start from.', False)
      .AddNumber('trim_end', 'Seconds to stop at; omit to run to the '
      + 'end. At least one side is required.', False)),
    ExportTrim)
    .Title('Trim movie').OpenWorldHint(False);
  // No fps/width/dither/zoom/cursor here: a passthrough trim copies
  // coded samples, so the first three would be a silent no-op and the
  // last two would mean decoding the whole video — which is what render
  // is for. Params refuses all five.
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

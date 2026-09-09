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
  jsonparser,
  Knips.App.State,
  Knips.Export.ZoomTrack,
  Knips.Options,
  Knips.Recording.Sidecar;

const
  McpServerName = 'knips';
  // The trim export writes beside its input under this suffix rather
  // than over it; ValidateExportOptions refuses in = out outright.
  TrimFileSuffix = '-trim';
  // Where a render writes when its input is NOT a raw take and the
  // caller named no output. A raw take has an obvious deliverable name
  // (its own, without the `-raw`), and `knips render` uses it; anything
  // else has none, and the CLI answers by demanding `--out`. Over MCP
  // that refusal buys nothing — the input path already names a
  // directory, which is the only thing the CLI's asymmetry is about —
  // so a name is derived instead. It is deliberately NOT the input:
  // rendering over the take destroys the raw material the whole
  // raw-take model exists to keep (and TRenderSession refuses in = out
  // outright anyway).
  RenderedFileSuffix = '-rendered';

type
  TKnipsMcpTool = (kmtListDisplays, kmtListWindows, kmtTakeInfo,
    kmtRecordStart, kmtRecordStop, kmtRecordStatus, kmtRender,
    kmtExportGif, kmtExportApng, kmtExportTrim);

function KnipsMcpToolName(ATool: TKnipsMcpTool): string;
function KnipsMcpToolDescription(ATool: TKnipsMcpTool): string;

// The JSON Schema a tool's structuredContent is promised to match.
//
// These live here, beside the names and the descriptions, rather than
// with the handlers that fill them: they are a promise about a shape,
// the shape is decided by the neutral mapping, and a schema no test can
// reach is a schema that goes stale. Every one of them is parsed and
// checked against its own "required" list by this unit's suite, on every
// host.
//
// Only inputSchema is subset-checked by the SDK at freeze time, so a
// rich outputSchema costs the input validation nothing. "required" lists
// only the keys EVERY path through a handler emits — record_status has
// three different answers, and the notes are present only when there is
// something to say.
function KnipsMcpOutputSchema(ATool: TKnipsMcpTool): string;

type
  TMcpKeyArray = array of string;

// The property names ATool's output schema declares, in the order the
// schema declares them.
function KnipsMcpSchemaProperties(ATool: TKnipsMcpTool): TMcpKeyArray;

// The keys of APayload that ATool's output schema does NOT declare, as
// one comma-separated list; '' when every key is declared, which is the
// only acceptable answer.
//
// This is the check that closes a whole class of bug rather than one
// instance of it. The schemas are hand-written JSON and the payloads are
// hand-written TJSONObject.Create lists, and for as long as the only
// thing tying the two together was a person reading both, they drifted:
// export_gif and export_apng emitted six fields — the palette a GIF was
// quantised to among them — that their schema never declared, so a
// client validating in strict mode rejected a good export and one
// planning against the schema could not see them at all.
//
// A hand-maintained table of "the keys this tool emits" would be a
// SECOND list that can drift from the builder in exactly the way the
// schema did. Checking the real payload against the real schema cannot:
// there is nothing left to keep in step. Knips.Mcp routes every
// structured result through it (KnipsStructuredResult), so the first
// call to a tool whose payload has outgrown its schema is the call that
// says so — and this unit's suite drives it directly, on every host,
// over the payload builders that are neutral.
//
// Deliberately not fatal. A key the schema forgot is a mistake in this
// program and never in the client's request; dropping a caller's numbers
// to punish it would turn a documentation bug into data loss.
function McpUndeclaredPayloadKeys(ATool: TKnipsMcpTool;
  APayload: TJSONObject): string;

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
//
// BuildMcpRecordingOptions adds the app's own `-raw` suffix to this when
// the recording asked for a smooth cursor and named no "out" — see
// there.
function DefaultMcpRecordingPath(const AHomeDirectory: string;
  const AWhen: TDateTime): string;

// Where the render tool writes when the caller named no output:
// `demo-raw.mp4` -> `demo.mp4` exactly as `knips render` derives it, and
// anything else -> `demo-rendered.mp4` beside its input. See
// RenderedFileSuffix for why the input itself is never the answer.
function DefaultMcpRenderPath(const AInputPath: string): string;

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

// The post-recording effects, read off a tools/call arguments object.
//
// **Two flat scalars, not one nested object.** A `{"zoom": true,
// "cursor": "smooth"}` argument reads better in isolation and is what a
// JSON-RPC surface would reach for first — but the SDK's server-enforced
// schema subset is flat scalar properties, and a schema that leaves it
// has to be marked ApplicationValidated, which switches off call-time
// argument checking for the WHOLE tool. Paying for one nested object
// with the type checking of every other argument on export_gif is a bad
// trade, and it is the same trade the region already refused: left/top/
// width/height are four integers for exactly this reason. So the effects
// are `zoom` and `cursor`, checked here.
//
// The four tunable fields of TExportEffects — the magnification, the
// smoothing window, the zoom factor and its hold — are deliberately not
// exposed. They are reserved: every one of them defaults to the value
// that makes a rendered effect match the live one, which is the property
// worth keeping, and an agent has no way to judge a better number.
function ReadMcpExportEffects(AArguments: TJSONObject;
  var AEffects: TExportEffects; out AError: string): Boolean;

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

// What record_start says about the pointer track it is about to write,
// or '' when there is nothing to say.
//
// An MCP recording has no main thread between tool calls: the stdio
// transport is a blocking read-handle-write loop, so the pointer is
// sampled at the start, once per record_status, and at the stop, and
// nowhere else. A take polled twice has a three-sample track, and a
// smooth cursor drawn from three samples is a straight line — which is
// not a smooth cursor, it is a lie about where the pointer was.
//
// So it is said, up front, on the tool that decides it. Not
// conditionally: MCP has no handshake in which a client could promise to
// poll, so a warning that waited for one would never fire. It costs a
// sentence, and the alternative is a take that cannot be recorded again
// with the truth in it. record_stop then reports the samples that
// actually arrived and take_info the largest gap between them, so the
// claim is measured as well as made.
function McpSparseTrackNote(ASmoothCursor: Boolean): string;

// What record_start says about the tidying up it did on the way in: a
// take an earlier process left unfinished, and the scratch a killed
// render left behind. '' when there was nothing to do, which is the
// usual case — the note exists because a directory that keeps producing
// either is telling the client something, and this face had no way to
// say it at all.
function McpRecoveryNote(ARecoveredTakes, ASweptTemporaries: Integer): string;

// Whether these render arguments ask, in so many words, for a copy —
// the MCP spelling of `--effects=none`: cursor "none", and zoom either
// absent or false. See Knips.Export.Render's ExplicitCopy.
function McpRequestsCopy(AArguments: TJSONObject): Boolean;

// Arguments the render tool has no use for, refused rather than
// dropped.
//
// The SDK deliberately ignores properties a schema does not declare, so
// an agent that sent `width` to render would otherwise get a full-size
// movie and no hint that the request went nowhere — the same trap
// export_trim already documents and refuses for. A render re-encodes the
// take at the take's own size, rate and length; scaling and slowing down
// are what the animation exports are for, and cutting a range is what
// export_trim is for, so the refusal names the tool that CAN do it
// instead of merely turning the caller away.
function McpRenderRefusesArguments(AArguments: TJSONObject;
  out AError: string): Boolean;

// The longest silence a take's pointer track actually contains, in
// seconds; 0 for a track with fewer than two samples.
//
// TSidecarLog.MaxInterpolatedGap is a different number entirely — it is
// the POLICY, the longest silence a reader may draw a straight line
// through — and confusing the two is easy enough to be worth a function
// with a name that cannot be. take_info reports both, and the comparison
// between them is what says whether a drawn pointer will glide or stand
// still.
function LargestSampleGap(ALog: TSidecarLog): Double;

// take_info's answer about one take on disk: what is already in its
// pixels, what its event sidecar holds, and which post-recording effects
// a render or an export could still give it.
//
// ALog is a loaded sidecar or nil; ALoadError is why it is nil, when it
// is, because "there is no sidecar" and "this sidecar is a version this
// knips cannot read" are different facts and only one of them is worth
// re-recording over. The caller owns ALog; the returned object is the
// caller's.
function McpTakeInfoObject(const AMoviePath, ASidecarPath: string;
  AMovieBytes: Int64; ALog: TSidecarLog;
  const ALoadError: string): TJSONObject;

// The same answer as one line of text, for a client that shows the
// content block rather than the structured one.
function McpTakeInfoSummary(const AMoviePath: string; ALog: TSidecarLog;
  const ALoadError: string): string;

implementation

const
  ToolNames: array[TKnipsMcpTool] of string = (
    'list_displays', 'list_windows', 'take_info', 'record_start',
    'record_stop', 'record_status', 'render', 'export_gif',
    'export_apng', 'export_trim');

  ToolDescriptions: array[TKnipsMcpTool] of string = (
    'List the displays that can be recorded, with their index, size in '
      + 'points, and backing scale.',
    'List the on-screen application windows that can be recorded, with '
      + 'their window id, size, application, and title.',
    'Describe a recorded movie without changing anything: whether it is '
      + 'a raw take, what is already baked into its pixels, what its '
      + 'event sidecar holds, and which effects render, export_gif and '
      + 'export_apng could still apply to it — with the reason when one '
      + 'cannot. Ask this before render or an export rather than '
      + 'guessing.',
    'Start recording a display, a region of one, or a single window to '
      + 'an .mp4/.mov file. Returns immediately; the recording runs '
      + 'until record_stop. Only one recording at a time. Pass '
      + 'smooth_cursor to record a RAW take — no pointer in the pixels, '
      + 'the pointer track in a sidecar — which is the only kind of '
      + 'recording whose effects can still be chosen afterwards, with '
      + 'render.',
    'Stop the running recording and finalise the file. Returns the '
      + 'output path, the frame counters, and — for a raw take — where '
      + 'render would write the deliverable. Nothing is rendered here: '
      + 'the stop is the raw take plus its sidecar, and render is the '
      + 'separate call that applies effects.',
    'Report whether a recording is running, and for how long. Also '
      + 'takes one pointer sample into the event sidecar, so polling '
      + 'this is what makes a raw take''s pointer track dense enough to '
      + 'draw from. If the writer has failed, this stops the recording '
      + 'and finalises the partial file.',
    'Render a raw take into a deliverable .mp4: the pointer drawn back '
      + 'from the event sidecar''s track and a zoom driven by its '
      + 'clicks, with the audio copied sample-for-sample rather than '
      + 're-encoded. The take is left on disk, so the same recording can '
      + 'be rendered again with different effects. Ask take_info first '
      + 'for which effects this take can still have.',
    'Convert a recorded movie to an animated GIF, optionally with the '
      + 'post-recording effects applied from its event sidecar.',
    'Convert a recorded movie to an animated PNG (APNG): truecolour, '
      + 'larger than a GIF, no palette banding. Takes the same effects '
      + 'as export_gif.',
    'Cut a movie down to a time range by copying the coded samples into '
      + 'a new container — no decode, no re-encode, no quality loss.');

  // See KnipsMcpOutputSchema.
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
  TakeInfoOutputSchema =
    '{"type":"object","properties":{"path":{"type":"string"},'
    + '"bytes":{"type":"integer"},"sidecar_path":{"type":"string"},'
    + '"has_sidecar":{"type":"boolean"},"raw":{"type":"boolean"},'
    + '"fully_renderable":{"type":"boolean"},'
    + '"can_draw_cursor":{"type":"boolean"},'
    + '"can_zoom_on_click":{"type":"boolean"},'
    + '"cursor_already_baked":{"type":"boolean"},'
    + '"cursor_render":{"type":"string"},"target":{"type":"string"},'
    + '"baked_zoom_on_click":{"type":"boolean"},'
    + '"baked_follow_mouse":{"type":"boolean"},'
    + '"baked_window_follow":{"type":"boolean"},'
    + '"width":{"type":"integer"},"height":{"type":"integer"},'
    + '"scale":{"type":"integer"},"fps":{"type":"integer"},'
    + '"audio":{"type":"string"},'
    + '"duration_seconds":{"type":"number"},"frames":{"type":"integer"},'
    + '"pointer_samples":{"type":"integer"},"clicks":{"type":"integer"},'
    + '"usable_clicks":{"type":"integer"},'
    + '"sample_hz":{"type":"number"},'
    + '"max_sample_gap_seconds":{"type":"number"},'
    + '"interpolation_limit_seconds":{"type":"number"},'
    + '"finished":{"type":"boolean"},"reason":{"type":"string"},'
    + '"cursor_reason":{"type":"string"},"zoom_reason":{"type":"string"},'
    + '"sidecar_error":{"type":"string"},'
    + '"sidecar_skipped_lines":{"type":"integer"},'
    + '"render_output_path":{"type":"string"}},'
    + '"required":["path","bytes","sidecar_path","has_sidecar","raw",'
    + '"fully_renderable","can_draw_cursor","can_zoom_on_click",'
    + '"cursor_already_baked","render_output_path"]}';
  RecordStartOutputSchema =
    '{"type":"object","properties":{"recording":{"type":"boolean"},'
    + '"path":{"type":"string"},"width":{"type":"integer"},'
    + '"height":{"type":"integer"},"fps":{"type":"integer"},'
    + '"audio":{"type":"string"},"big_cursor":{"type":"boolean"},'
    + '"smooth_cursor":{"type":"boolean"},"raw":{"type":"boolean"},'
    + '"note":{"type":"string"}},'
    + '"required":["recording","path",'
    + '"width","height","fps","audio","big_cursor","smooth_cursor",'
    + '"raw"]}';
  RecordStopOutputSchema =
    '{"type":"object","properties":{"path":{"type":"string"},'
    + '"width":{"type":"integer"},"height":{"type":"integer"},'
    + '"duration_seconds":{"type":"number"},"frames":{"type":"integer"},'
    + '"dropped_frames":{"type":"integer"},'
    + '"failed_appends":{"type":"integer"},'
    + '"heartbeats":{"type":"integer"},'
    + '"heartbeats_refused":{"type":"integer"},'
    + '"raw":{"type":"boolean"},"sidecar_path":{"type":"string"},'
    + '"sidecar_error":{"type":"string"},'
    + '"pointer_samples":{"type":"integer"},'
    + '"render_output_path":{"type":"string"},'
    + '"advice":{"type":"string"},'
    + '"bytes":{"type":"integer"}},'
    + '"required":["path","width","height","duration_seconds","frames",'
    + '"dropped_frames","failed_appends","heartbeats",'
    + '"heartbeats_refused","raw","pointer_samples",'
    + '"render_output_path","bytes"]}';
  RecordStatusOutputSchema =
    '{"type":"object","properties":{"recording":{"type":"boolean"},'
    + '"failed":{"type":"boolean"},"finalised":{"type":"boolean"},'
    + '"path":{"type":"string"},"elapsed_seconds":{"type":"number"},'
    + '"frames":{"type":"integer"},"dropped_frames":{"type":"integer"},'
    + '"failed_appends":{"type":"integer"},'
    + '"heartbeats":{"type":"integer"},'
    + '"heartbeats_refused":{"type":"integer"},'
    + '"pointer_samples":{"type":"integer"},'
    + '"width":{"type":"integer"},'
    + '"height":{"type":"integer"},"fps":{"type":"integer"}},'
    + '"required":["recording"]}';
  RenderOutputSchema =
    '{"type":"object","properties":{"path":{"type":"string"},'
    + '"input_path":{"type":"string"},"width":{"type":"integer"},'
    + '"height":{"type":"integer"},"frames":{"type":"integer"},'
    + '"duration_seconds":{"type":"number"},"bytes":{"type":"integer"},'
    + '"copied":{"type":"boolean"},"zoom":{"type":"boolean"},'
    + '"cursor":{"type":"string"},"zoom_applied":{"type":"boolean"},'
    + '"zoomed_frames":{"type":"integer"},"clicks":{"type":"integer"},'
    + '"cursor_drawn":{"type":"boolean"},'
    + '"cursor_frames":{"type":"integer"},'
    + '"cursor_off_frame_frames":{"type":"integer"},'
    + '"synthesized_frames":{"type":"integer"},'
    + '"synthesis_fps":{"type":"integer"},'
    + '"unframed_frames":{"type":"integer"},'
    + '"audio_tracks":{"type":"integer"},'
    + '"audio_samples":{"type":"integer"},'
    + '"audio_passthrough":{"type":"boolean"},'
    + '"elapsed_seconds":{"type":"number"},'
    + '"realtime_factor":{"type":"number"},'
    + '"sidecar_skipped_lines":{"type":"integer"},'
    + '"sidecar_error":{"type":"string"},'
    + '"sidecar_path":{"type":"string"},"framing_note":{"type":"string"},'
    + '"cursor_note":{"type":"string"},"zoom_note":{"type":"string"}},'
    // Every key the handler emits on every successful path, which is the
    // rule this file states at the top and used to keep only half of:
    // eight of these were emitted unconditionally and promised
    // conditionally, which tells a client to guard for an absence that
    // cannot happen. Only sidecar_path, sidecar_error and the three notes are genuinely
    // conditional.
    + '"required":["path","input_path","width","height","frames",'
    + '"duration_seconds","bytes","copied","zoom","cursor",'
    + '"zoom_applied","zoomed_frames","clicks","cursor_drawn",'
    + '"cursor_frames","cursor_off_frame_frames","synthesized_frames",'
    + '"synthesis_fps","unframed_frames","audio_tracks","audio_samples",'
    + '"audio_passthrough","elapsed_seconds","realtime_factor",'
    + '"sidecar_skipped_lines"]}';
  ExportOutputSchema =
    '{"type":"object","properties":{"path":{"type":"string"},'
    + '"format":{"type":"string"},"width":{"type":"integer"},'
    + '"height":{"type":"integer"},"frames":{"type":"integer"},'
    + '"duration_seconds":{"type":"number"},"bytes":{"type":"integer"},'
    + '"zoom":{"type":"boolean"},"cursor":{"type":"string"},'
    + '"zoom_applied":{"type":"boolean"},'
    + '"zoomed_frames":{"type":"integer"},"clicks":{"type":"integer"},'
    + '"cursor_drawn":{"type":"boolean"},'
    + '"cursor_frames":{"type":"integer"},'
    + '"cursor_off_frame_frames":{"type":"integer"},'
    // The six the handler had been emitting all along and this schema
    // did not declare — the palette a GIF was quantised to, how much of
    // the take was sampled for it, the frames synthesised and the
    // cadence they were made at, and the frames the pointer track could
    // not place. A client validating against this schema in strict mode
    // rejected a perfectly good export; one reading it to plan against
    // could not see the single biggest fact about a GIF.
    + '"palette_colors":{"type":"integer"},'
    + '"exact_palette":{"type":"boolean"},'
    + '"sampled_frames":{"type":"integer"},'
    + '"synthesized_frames":{"type":"integer"},'
    + '"synthesis_fps":{"type":"integer"},'
    + '"unframed_frames":{"type":"integer"},'
    + '"sidecar_skipped_lines":{"type":"integer"},'
    + '"framing_note":{"type":"string"},"cursor_note":{"type":"string"},'
    + '"zoom_note":{"type":"string"},'
    // As RenderOutputSchema: everything the handler always emits.
    // framing_note, cursor_note, zoom_note and advice are the only
    // conditional keys.
    + '"advice":{"type":"string"}},"required":["path","format","width",'
    + '"height","frames","duration_seconds","bytes","zoom","cursor",'
    + '"zoom_applied","zoomed_frames","clicks","cursor_drawn",'
    + '"cursor_frames","cursor_off_frame_frames","palette_colors",'
    + '"exact_palette","sampled_frames","synthesized_frames",'
    + '"synthesis_fps","unframed_frames","sidecar_skipped_lines"]}';
  TrimOutputSchema =
    '{"type":"object","properties":{"path":{"type":"string"},'
    + '"start_seconds":{"type":"number"},"end_seconds":{"type":"number"},'
    + '"source_duration_seconds":{"type":"number"},'
    + '"bytes":{"type":"integer"}},"required":["path","start_seconds",'
    + '"end_seconds","source_duration_seconds","bytes"]}';

  ToolOutputSchemas: array[TKnipsMcpTool] of string = (
    DisplaysOutputSchema, WindowsOutputSchema, TakeInfoOutputSchema,
    RecordStartOutputSchema, RecordStopOutputSchema,
    RecordStatusOutputSchema, RenderOutputSchema, ExportOutputSchema,
    ExportOutputSchema, TrimOutputSchema);

function KnipsMcpToolName(ATool: TKnipsMcpTool): string;
begin
  Result := ToolNames[ATool];
end;

function KnipsMcpToolDescription(ATool: TKnipsMcpTool): string;
begin
  Result := ToolDescriptions[ATool];
end;

function KnipsMcpOutputSchema(ATool: TKnipsMcpTool): string;
begin
  Result := ToolOutputSchemas[ATool];
end;

function KnipsMcpSchemaProperties(ATool: TKnipsMcpTool): TMcpKeyArray;
var
  Schema: TJSONObject;
  Properties: TJSONData;
  I: Integer;
begin
  Result := nil;
  // The schema is a constant in this unit and its suite parses every one
  // of them, so a parse failure here cannot happen in a build that
  // passes its tests. An empty list is still the safe answer to one:
  // it makes the caller report every key rather than none.
  Schema := nil;
  try
    Schema := GetJSON(ToolOutputSchemas[ATool]) as TJSONObject;
  except
    on EJSON do
      Exit;
  end;
  try
    Properties := Schema.Find('properties');
    if (Properties = nil) or (Properties.JSONType <> jtObject) then
      Exit;
    SetLength(Result, TJSONObject(Properties).Count);
    for I := 0 to TJSONObject(Properties).Count - 1 do
      Result[I] := TJSONObject(Properties).Names[I];
  finally
    Schema.Free;
  end;
end;

function McpUndeclaredPayloadKeys(ATool: TKnipsMcpTool;
  APayload: TJSONObject): string;
var
  Declared: TMcpKeyArray;
  I, J: Integer;
  Found: Boolean;
begin
  Result := '';
  if APayload = nil then
    Exit;
  Declared := KnipsMcpSchemaProperties(ATool);
  for I := 0 to APayload.Count - 1 do
  begin
    Found := False;
    for J := Low(Declared) to High(Declared) do
      if Declared[J] = APayload.Names[I] then
      begin
        Found := True;
        Break;
      end;
    if Found then
      Continue;
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + APayload.Names[I];
  end;
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
  // Bounds BEFORE the assignment, the way the sidecar's own
  // ReadIntegerField does it. Without this, `{"width": 4294971392}`
  // reached `AValue: Integer` as a truncating Int64 assignment and came
  // back to the client as `Tool execution failed: Range check error` —
  // a leaked implementation detail where a refusal naming the argument
  // belonged. Every value this surface takes is a pixel count, a rate
  // or an index, so a 32-bit signed range is the whole of the domain;
  // the per-argument minimum and maximum are checked afterwards, by
  // Knips.Options, which is where they live.
  if (Data.AsFloat < Low(Integer)) or (Data.AsFloat > High(Integer)) then
  begin
    AError := Format('"%s" is out of range: %s', [AName, Data.AsString]);
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

function DefaultMcpRenderPath(const AInputPath: string): string;
begin
  if AInputPath = '' then
    Exit('');
  if IsRawTakePath(AInputPath) then
    Exit(DeliverablePathFor(AInputPath));
  Result := ChangeFileExt(AInputPath, '') + RenderedFileSuffix
    + ExtractFileExt(AInputPath);
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
  RewriteCount = 31;
  McpMessageRewrites: array[0..RewriteCount - 1, 0..1] of string = (
    // Built from Knips.Options's own constant, not retyped: it used to
    // be a literal here while the producer composed it with Format, so
    // a change to ScaleAuto would have broken the match silently.
    (ScaleRefusal, 'scale must be "auto", "1", or "2"'),
    // The three cursor refusals, as whole clauses. A token-for-token
    // rewrite of these produces "cursor and big_cursor are mutually
    // exclusive", which is true of the flags and useless as advice: the
    // JSON argument is a BOOLEAN, so the client has to be told which
    // value of which key to change, not which two words disagree.
    //
    // Only the naming half is rewritten now. The EXPLANATION that used
    // to be added here is in Knips.Options's own message, where a
    // person at the command line gets it too, and it passes through
    // this rewrite untouched.
    ('--no-cursor and --big-cursor are mutually exclusive',
      '"cursor": false and "big_cursor": true are mutually exclusive'),
    ('--no-cursor and --smooth-cursor are mutually exclusive',
      '"cursor": false and "smooth_cursor": true are mutually '
      + 'exclusive'),
    ('--big-cursor and --smooth-cursor are mutually exclusive',
      '"big_cursor": true and "smooth_cursor": true are mutually '
      + 'exclusive'),
    ('--effects=none cannot be combined with another effect',
      'an empty effect list cannot be combined with another effect'),
    ('--window and --rect are mutually exclusive',
      'a window and a region are mutually exclusive'),
    ('(see `knips windows`)', '(see list_windows)'),
    ('(see `knips displays`)', '(see list_displays)'),
    // The one command name that now has a tool of the same shape behind
    // it. `use \`knips render\` for an MP4 with effects` is advice an MCP
    // client can act on — but only if it is told the name of the thing
    // it can call.
    ('`knips render`', 'the render tool'),
    ('--trim=1.5,3.5', 'trim_start=1.5 and trim_end=3.5'),
    ('--trim=0,3.5', 'trim_start=0 and trim_end=3.5'),
    ('--trim starts at', 'trim_start is at'),
    // Whole sentences, each naming the ONE argument at fault. The bare
    // '--trim' entry below rewrites to 'trim_start/trim_end', which on
    // these two produced "trim_start/trim_end cannot start before
    // zero" — a refusal that names both arguments and blames neither.
    ('--trim cannot start before zero',
      'trim_start cannot be negative'),
    ('--trim must end after it starts',
      'trim_end must be greater than trim_start'),
    ('--rect', 'a region of left/top/width/height'),
    ('--trim', 'trim_start/trim_end'),
    ('--no-dither', 'dither'),
    // Both of these have a JSON argument now: record_start takes
    // smooth_cursor, and render and the two animation exports take zoom
    // and cursor. They used to be rewritten into a sentence explaining
    // that the server did not offer them, which was true and is not any
    // more.
    ('--smooth-cursor', 'smooth_cursor'),
    // Plural, because one flag became two arguments; a refusal that
    // named `--effects` was about the pair.
    ('--effects', 'the zoom and cursor arguments'),
    ('--big-cursor', 'big_cursor'),
    ('--no-cursor', 'cursor'),
    ('--cursor', 'cursor'),
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
      // ':' among them: a refusal that names the flags and then
      // explains itself — '--no-cursor and --big-cursor are mutually
      // exclusive: one asks for…' — has to match on the clause, or the
      // two bare flag entries match instead and the sentence comes back
      // as 'cursor and big_cursor are mutually exclusive: …'.
      or (AMessage[APosition] in [' ', '=', ',', ')', ';', ':']);
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
  ShowsCursor, BigCursor, SmoothCursor, NamedOutput: Boolean;
begin
  Result := False;
  AError := '';
  ARecording := DefaultRecordingOptions;
  ARecording.OutputPath := ADefaultPath;

  NamedOutput := McpHasArgument(AArguments, 'out');
  if not McpOptionalString(AArguments, 'out', ARecording.OutputPath,
    AError) then
    Exit;
  if ARecording.OutputPath = '' then
  begin
    AError := 'no output path, and no default could be derived';
    Exit;
  end;
  SmoothCursor := False;
  if not McpOptionalBoolean(AArguments, 'smooth_cursor', SmoothCursor,
    AError) then
    Exit;
  ARecording.SmoothCursor := SmoothCursor;
  // The one flag that says this movie is deliberately incomplete: the
  // pointer is left out of the pixels for a render to draw back from the
  // sidecar. A take like that is not the deliverable, and naming it as
  // though it were is what makes a client render over its own raw
  // material later. So the derived name takes the menu-bar app's `-raw`
  // suffix, and the pair on disk comes out exactly as the app writes it
  // — `knips-….mp4` beside `knips-…-raw.mp4` — which is also what lets
  // the render tool work out its own output with no argument at all.
  //
  // Only the DERIVED name: a caller that chose a path gets the path it
  // chose. And only for the smooth cursor — an ordinary take and a big
  // cursor take are finished pixels (still zoomable, but nothing is
  // waiting to be put into them), so they keep the plain name.
  if SmoothCursor and not NamedOutput then
    ARecording.OutputPath := RawTakePathFor(ARecording.OutputPath);
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

function ReadMcpExportEffects(AArguments: TJSONObject;
  var AEffects: TExportEffects; out AError: string): Boolean;
var
  Zoom: Boolean;
  Cursor: string;
begin
  Result := False;
  AError := '';
  Zoom := AEffects.ZoomOnClick;
  if not McpOptionalBoolean(AArguments, 'zoom', Zoom, AError) then
    Exit;
  AEffects.ZoomOnClick := Zoom;
  Cursor := ExportCursorModeName(AEffects.Cursor);
  if not McpOptionalString(AArguments, 'cursor', Cursor, AError) then
    Exit;
  if not ParseExportCursorMode(Cursor, AEffects.Cursor) then
  begin
    AError := '"cursor" must be "as-recorded", "none", "smooth", or '
      + '"big"';
    Exit;
  end;
  Result := True;
end;

function BuildMcpExportOptions(AArguments: TJSONObject;
  AFormat: TExportFormat; out AExport: TExportOptions;
  out AError: string): Boolean;
const
  TrimInapplicable: array[0..2] of string = ('fps', 'width', 'dither');
  // Refused separately from the three above, because the answer is
  // different: those cannot be honoured by any movie output, while these
  // can — by the render tool, which is where a caller that wants an MP4
  // with effects should be sent rather than merely turned away.
  TrimNoEffects: array[0..1] of string = ('zoom', 'cursor');
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
    for I := Low(TrimNoEffects) to High(TrimNoEffects) do
      if McpHasArgument(AArguments, TrimNoEffects[I]) then
      begin
        AError := Format('"%s" does not apply to a passthrough trim: it '
          + 'copies the coded samples unchanged, and an effect would '
          + 'mean decoding and re-encoding the whole video. Use the '
          + 'render tool for an MP4 with effects', [TrimNoEffects[I]]);
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
    if not ReadMcpExportEffects(AArguments, AExport.Effects, AError) then
      Exit;
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

function McpRequestsCopy(AArguments: TJSONObject): Boolean;
var
  Cursor: string;
  Zoom: Boolean;
  Error: string;
begin
  Result := False;
  if not McpHasArgument(AArguments, 'cursor') then
    Exit;
  Cursor := '';
  if not McpOptionalString(AArguments, 'cursor', Cursor, Error) then
    Exit;
  if LowerCase(Trim(Cursor)) <> 'none' then
    Exit;
  Zoom := False;
  if not McpOptionalBoolean(AArguments, 'zoom', Zoom, Error) then
    Exit;
  Result := not Zoom;
end;

function McpRecoveryNote(ARecoveredTakes,
  ASweptTemporaries: Integer): string;
begin
  Result := '';
  if ARecoveredTakes > 0 then
    Result := Format('%d earlier recording(s) had not been finished off '
      + 'and were recovered', [ARecoveredTakes]);
  if ASweptTemporaries > 0 then
  begin
    if Result <> '' then
      Result := Result + '; ';
    Result := Result + Format('%d leftover render scratch file(s) removed',
      [ASweptTemporaries]);
  end;
end;

function McpSparseTrackNote(ASmoothCursor: Boolean): string;
begin
  Result := '';
  if not ASmoothCursor then
    Exit;
  Result := 'this is a raw take: no pointer is in its pixels, and the '
    + 'pointer track is written to the event sidecar beside it. Over MCP '
    + 'that track is only as dense as your polling — one sample at the '
    + 'start, one for every record_status call, and one at the stop — '
    + 'because nothing in this server runs between tool calls. A pointer '
    + 'drawn from three samples is a straight line. Call record_status '
    + 'every second or so while the take runs; record_stop reports how '
    + 'many samples arrived, and take_info reports the largest gap '
    + 'between them.';
end;

function McpRenderRefusesArguments(AArguments: TJSONObject;
  out AError: string): Boolean;
const
  Rescaling: array[0..2] of string = ('fps', 'width', 'dither');
  Ranging: array[0..1] of string = ('trim_start', 'trim_end');
var
  I: Integer;
begin
  AError := '';
  Result := False;
  for I := Low(Rescaling) to High(Rescaling) do
    if McpHasArgument(AArguments, Rescaling[I]) then
    begin
      AError := Format('"%s" does not apply to a render: it re-encodes '
        + 'the take at the take''s own size and rate. Use export_gif or '
        + 'export_apng to scale a movie down or slow it', [Rescaling[I]]);
      Exit;
    end;
  for I := Low(Ranging) to High(Ranging) do
    if McpHasArgument(AArguments, Ranging[I]) then
    begin
      AError := Format('"%s" does not apply to a render: it renders the '
        + 'whole take. Use export_trim to cut a movie down to a range',
        [Ranging[I]]);
      Exit;
    end;
  Result := True;
end;

function LargestSampleGap(ALog: TSidecarLog): Double;
var
  I: Integer;
  Gap: Double;
begin
  Result := 0;
  if (ALog = nil) or (ALog.SampleCount < 2) then
    Exit;
  for I := 1 to ALog.SampleCount - 1 do
  begin
    Gap := ALog.Sample(I).Time - ALog.Sample(I - 1).Time;
    if Gap > Result then
      Result := Gap;
  end;
end;

// The two words the sidecar's target kind gets in a JSON answer.
// SidecarTargetName is the format's own spelling and is not exported;
// these are the same two words and are pinned by this unit's suite.
function McpTargetName(AKind: TCaptureTargetKind): string;
begin
  if AKind = ctkWindow then
    Result := 'window'
  else
    Result := 'display';
end;

function McpTakeInfoObject(const AMoviePath, ASidecarPath: string;
  AMovieBytes: Int64; ALog: TSidecarLog;
  const ALoadError: string): TJSONObject;
var
  Available: TSidecarEffectAvailability;
begin
  Available := AvailableExportEffects(ALog);
  Result := TJSONObject.Create([
    'path', AMoviePath,
    'bytes', AMovieBytes,
    'sidecar_path', ASidecarPath,
    'has_sidecar', ALog <> nil,
    // The two questions a caller planning a render asks first, and the
    // three that say how much of the answer is already decided.
    'raw', (ALog <> nil) and IsRawTake(ALog.Header),
    'fully_renderable', Available.FullyRenderable,
    'can_draw_cursor', Available.CanDrawCursor,
    'can_zoom_on_click', Available.CanZoomOnClick,
    'cursor_already_baked', Available.CursorAlreadyBaked,
    // Where the render tool would write if it were called with this
    // path and no "out". Answered here so a client can see the pair it
    // is about to end up with before it commits to one.
    //
    // It is a NAME, not a promise that a render would succeed: a take
    // with nothing left to apply is refused outright rather than
    // duplicated, and this field is filled for it just the same. The two
    // can_ flags above are what say whether the render would happen —
    // both false means it would not, whatever this path says.
    'render_output_path', DefaultMcpRenderPath(AMoviePath)]);
  if Available.Reason <> '' then
    Result.Add('reason', Available.Reason);
  if Available.CursorReason <> '' then
    Result.Add('cursor_reason', Available.CursorReason);
  if Available.ZoomReason <> '' then
    Result.Add('zoom_reason', Available.ZoomReason);
  // Why there is no sidecar, when there is none and somebody said. An
  // absent file and a file this knips is too old to read are different
  // problems and only one of them is worth recording again over.
  if (ALog = nil) and (ALoadError <> '') then
    Result.Add('sidecar_error', ALoadError);
  if ALog = nil then
    Exit;

  Result.Add('cursor_render',
    SidecarCursorRenderName(ALog.Header.CursorRender));
  Result.Add('target', McpTargetName(ALog.Header.TargetKind));
  Result.Add('baked_zoom_on_click', ALog.Header.BakedZoomOnClick);
  Result.Add('baked_follow_mouse', ALog.Header.BakedFollowMouse);
  Result.Add('baked_window_follow', ALog.Header.BakedWindowFollow);
  Result.Add('width', ALog.Header.PixelWidth);
  Result.Add('height', ALog.Header.PixelHeight);
  Result.Add('scale', ALog.Header.Scale);
  Result.Add('fps', ALog.Header.FramesPerSecond);
  Result.Add('audio', AudioModeName(ALog.Header.AudioMode));
  Result.Add('sample_hz', ALog.Header.SampleHz);
  Result.Add('pointer_samples', Int64(ALog.SampleCount));
  Result.Add('clicks', ALog.ButtonCount);
  // The clicks a zoom would actually answer, which is a smaller number
  // than `clicks` and sometimes zero when `clicks` is not.
  // AvailableExportEffects asks only whether the track has any button
  // event at all; the render then drops the ones a zoom cannot use — a
  // right button, a click in the menu-bar band, a click outside the
  // rectangle the recording was showing at that instant. So a take could
  // answer can_zoom_on_click: true and still come back from a render
  // saying "nothing was clicked inside the recorded rectangle". Reported
  // here so the planning answer carries the number the render will use,
  // rather than only the one the availability check looked at.
  Result.Add('usable_clicks', Length(ZoomClicksFromLog(ALog)));
  // The density answer, and the reason it is here rather than left to be
  // inferred from the sample count: a track can be dense for most of a
  // take and have one two-minute hole in it, and it is the hole that
  // decides whether a drawn pointer tells the truth.
  //
  // The pair is what makes it actionable. The first is measured — the
  // longest silence this track actually contains. The second is the
  // longest silence a reader is willing to draw a straight line through
  // (docs/event-sidecar.md); past it the pointer HOLDS its last position
  // instead. So a first number above the second says, precisely, that
  // some stretch of the rendered take will show a pointer standing
  // still. Over MCP that is the client's own polling, and no one else's,
  // deciding it.
  Result.Add('max_sample_gap_seconds', LargestSampleGap(ALog));
  Result.Add('interpolation_limit_seconds', ALog.MaxInterpolatedGap);
  // A take with no trailer did not finish: the process died, and the
  // recovery pass has not been over it yet.
  Result.Add('finished', ALog.HasTrailer);
  // How much of the file the loader could not use. Zero on a clean
  // sidecar, and the one number that says a pointer track is thinner
  // than its file looks — a truncated tail, a number that is not
  // finite, a stamp that does not advance. The loader is deliberately
  // tolerant of all three and says nothing about it on its own.
  Result.Add('sidecar_skipped_lines', ALog.SkippedLines);
  if ALog.HasTrailer then
  begin
    Result.Add('duration_seconds', ALog.Trailer.DurationSeconds);
    Result.Add('frames', ALog.Trailer.Frames);
  end;
end;

function McpTakeInfoSummary(const AMoviePath: string; ALog: TSidecarLog;
  const ALoadError: string): string;
var
  Available: TSidecarEffectAvailability;
  Effects: string;
  Gap: Double;
begin
  Available := AvailableExportEffects(ALog);
  if ALog = nil then
  begin
    Result := AMoviePath + ': no readable event sidecar, so nothing can '
      + 'be applied to it after the fact';
    if ALoadError <> '' then
      Result := Result + ' (' + ALoadError + ')';
    Exit;
  end;
  Effects := '';
  if Available.CanDrawCursor then
    Effects := 'cursor';
  if Available.CanZoomOnClick then
    if Effects = '' then
      Effects := 'zoom'
    else
      Effects := Effects + ' and zoom';
  if Effects = '' then
    Effects := 'nothing'
  else
    Effects := Effects + ' can still be applied';
  Result := Format('%s: %dx%d, %d pointer samples, %d clicks, cursor %s '
    + 'in the pixels; %s',
    [AMoviePath, ALog.Header.PixelWidth, ALog.Header.PixelHeight,
    ALog.SampleCount, ALog.ButtonCount,
    SidecarCursorRenderName(ALog.Header.CursorRender), Effects]);
  if Available.Reason <> '' then
    Result := Result + ' (' + Available.Reason + ')';
  // The structured answer carries both numbers, and comparing them is
  // the whole point — but a client reading the text block would have to
  // already know the rule to see it. So when this take's longest silence
  // is longer than the longest one a reader will draw a line through,
  // the consequence is said rather than left to be derived. Only for a
  // take a pointer can still be drawn into: a baked take's track is
  // nothing anybody will render from, and "poll record_status" is no
  // advice for a file this server did not record.
  // Walked once. Three calls used to walk the whole track between them
  // — twice here and once in the structured answer — for one number.
  Gap := LargestSampleGap(ALog);
  if Available.CanDrawCursor and (Gap > ALog.MaxInterpolatedGap) then
    Result := Result + Format('. Its pointer track has a %.1fs gap, '
      + 'longer than the %.1fs a reader will draw a straight line '
      + 'through, so a drawn pointer stands still across it rather than '
      + 'gliding — poll record_status more often for a denser track',
      [Gap, ALog.MaxInterpolatedGap]);
  // And what the loader threw away, in the sentence every other face
  // uses for it.
  if ALog.SkippedLines > 0 then
    Result := Result + '. '
      + SidecarSkippedLinesNote(ALog.SkippedLines);
end;

end.

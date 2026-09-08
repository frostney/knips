program knips;

// knips — a native macOS screen recorder in FreePascal.
//
//   knips app                   menu-bar app: drag a region, click to stop
//   knips record --out=demo.mp4 [--display=N | --window=ID] [--rect=x,y,w,h]
//                 [--fps=30] [--scale=auto|1|2] [--no-cursor] [--bitrate=N]
//                 [--audio=none|system|mic|both]
//                 [--big-cursor | --smooth-cursor]
//   knips render --in=demo-raw.mp4 [--out=demo.mp4]
//                 [--effects=zoom,as-recorded|smooth-cursor|big-cursor|
//                            no-cursor|none]
//                               raw take -> deliverable; audio copied, not
//                               re-encoded; presentation stamps unchanged
//   knips export --in=demo.mp4 --out=demo.gif|.apng [--fps=20] [--width=N]
//                 [--trim=start,end] [--no-dither]
//                 [--cursor=as-recorded|none|smooth|big] [--effects=…]
//   knips export --in=demo.mp4 --out=cut.mp4 --trim=1.5,3.5
//                               passthrough trim: no decode, no re-encode
//   knips displays              list capturable displays
//   knips windows               list capturable on-screen windows
//   knips mcp                   MCP server on stdin/stdout for AI clients
//   knips probe                 verify the ObjC runtime + framework path
//
// Built and tested with lwpt. Capture is ScreenCaptureKit, the file is
// written by AVAssetWriter, and the GIF encoder is pure Pascal; see
// docs/architecture.md.

{$I Knips.inc}

// Three units in the Darwin block below are not obvious, and the note has
// to live *above* the clause rather than beside them: lwpt 0.7.0's
// formatter desynchronises on a `//` inside a uses-clause and rewrites the
// whole file into garbage on the next `lwpt format` — and lefthook runs the
// rewriting formatter on every commit. See docs/code-style.md.
//
//   cmem                 libc heap: thread-safe without cthreads, and the
//                        first unit of the program by prototype invariant
//   Knips.ThreadManager  pthread-backed RTL locks and events for the
//                        no-cthreads build; creates no threads
//   objc                 the `id` type for the probe; the program itself
//                        is not in Objective-C mode
uses
  {$IFDEF DARWIN}
  cmem,
  Knips.ThreadManager,
  BaseUnix,
  ctypes,
  objc,
  {$ENDIF}
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Subcommands,
  {$IFDEF DARWIN}
  Knips.App,
  Knips.App.Border,
  Knips.App.Camera,
  Knips.App.Camera.Blur,
  Knips.App.Hotkey,
  Knips.App.Overlay,
  Knips.App.Playback,
  Knips.Capture.ShareableContent,
  Knips.Capture.Stream,
  Knips.Export.MovieTrim,
  Knips.Export.MovieWriter,
  Knips.Export.Pipeline,
  Knips.Export.Render,
  Knips.Export.SizeEstimate,
  Knips.ObjC.Runtime,
  Knips.Recording,
  Knips.Recording.CursorOverlay,
  Knips.Recording.Recovery,
  Knips.Recording.Sidecar,
  {$ENDIF}
  Knips.Mcp,
  Knips.Options;

const
  ProgramName = 'knips';
  ExitOk = 0;
  ExitUsage = 1;
  ExitFailure = 2;
  ExitUnsupported = 3;

function FindOption(const AOptions: TOptionArray;
  const ALongName: string): TOptionBase;
var
  I: Integer;
begin
  for I := 0 to High(AOptions) do
    if SameText(AOptions[I].LongName, ALongName) then
      Exit(AOptions[I]);
  Result := nil;
end;

function StringValue(const AOptions: TOptionArray; const ALongName: string;
  const ADefault: string): string;
var
  Option: TOptionBase;
begin
  Option := FindOption(AOptions, ALongName);
  if (Option is TStringOption) and Option.Present then
    Result := TStringOption(Option).Value
  else
    Result := ADefault;
end;

function IntegerValue(const AOptions: TOptionArray; const ALongName: string;
  ADefault: Integer): Integer;
var
  Option: TOptionBase;
begin
  Option := FindOption(AOptions, ALongName);
  if (Option is TIntegerOption) and Option.Present then
    Result := TIntegerOption(Option).Value
  else
    Result := ADefault;
end;

function FlagPresent(const AOptions: TOptionArray;
  const ALongName: string): Boolean;
var
  Option: TOptionBase;
begin
  Option := FindOption(AOptions, ALongName);
  Result := (Option <> nil) and Option.Present;
end;

// Turns the parsed CLI options into a validated recording request.
function BuildRecordingOptions(const AOptions: TOptionArray;
  out ARecording: TRecordingOptions; out AError: string): Boolean;
var
  Rect, Scale, Audio: string;
begin
  Result := False;
  ARecording := DefaultRecordingOptions;
  ARecording.OutputPath := StringValue(AOptions, 'out', '');
  ARecording.DisplayIndex := IntegerValue(AOptions, 'display',
    MainDisplayIndex);
  ARecording.WindowID := Cardinal(IntegerValue(AOptions, 'window', 0));
  if FlagPresent(AOptions, 'window') then
    ARecording.TargetKind := ctkWindow;
  ARecording.FramesPerSecond := IntegerValue(AOptions, 'fps',
    DefaultFramesPerSecond);
  ARecording.BitRate := IntegerValue(AOptions, 'bitrate', 0);
  ARecording.ShowsCursor := not FlagPresent(AOptions, 'no-cursor');
  ARecording.BigCursor := FlagPresent(AOptions, 'big-cursor');
  ARecording.SmoothCursor := FlagPresent(AOptions, 'smooth-cursor');

  Scale := LowerCase(StringValue(AOptions, 'scale', 'auto'));
  if Scale = 'auto' then
    ARecording.Scale := ScaleAuto
  else if not TryStrToInt(Scale, ARecording.Scale) then
  begin
    AError := '--scale must be auto, 1, or 2';
    Exit;
  end;

  Audio := StringValue(AOptions, 'audio', AudioModeName(amNone));
  if not ParseAudioMode(Audio, ARecording.AudioMode) then
  begin
    AError := '--audio must be none, system, mic, or both';
    Exit;
  end;

  Rect := StringValue(AOptions, 'rect', '');
  if Rect <> '' then
  begin
    if not ParseCaptureRegion(Rect, ARecording.Region) then
    begin
      AError := '--rect expects left,top,width,height in points';
      Exit;
    end;
    ARecording.HasRegion := True;
  end;

  Result := ValidateRecordingOptions(ARecording, AError);
end;

// Turns the parsed CLI options into a validated export request.
function BuildExportOptions(const AOptions: TOptionArray;
  out AExport: TExportOptions; out AError: string): Boolean;
var
  TrimText, CursorText, EffectsText: string;
begin
  Result := False;
  AExport := DefaultExportOptions;
  AExport.InputPath := StringValue(AOptions, 'in', '');
  AExport.OutputPath := StringValue(AOptions, 'out', '');
  AExport.FramesPerSecond := IntegerValue(AOptions, 'fps',
    DefaultGifFramesPerSecond);
  AExport.Width := IntegerValue(AOptions, 'width', GifWidthFromSource);
  AExport.Dither := not FlagPresent(AOptions, 'no-dither');
  // The export-effects record, which the GIF sink, the APNG sink and the
  // MP4 render all take. --cursor names one member of it; --effects names
  // the set, and is what the playback window's control and `knips render`
  // both speak.
  // Both spellings, reconciled in Knips.Options: naming two cursor words
  // INSIDE one --effects list is already refused rather than resolved
  // last-one-wins (ParseExportEffects), and this is the same rule across
  // the two ways of saying it.
  CursorText := StringValue(AOptions, 'cursor', '');
  EffectsText := StringValue(AOptions, 'effects', '');
  if not ReconcileCursorAndEffects(CursorText, EffectsText, AExport.Effects,
    AError) then
    Exit;

  TrimText := StringValue(AOptions, 'trim', '');
  if TrimText <> '' then
  begin
    if not ParseTrimRange(TrimText, AExport.TrimStartSeconds,
      AExport.TrimEndSeconds, AExport.HasTrimEnd) then
    begin
      AError := '--trim expects start,end in seconds; either side may be '
        + 'empty (--trim=2, or --trim=,5)';
      Exit;
    end;
    AExport.HasTrim := True;
  end;

  Result := ValidateExportOptions(AExport, AError);
end;

{$IFDEF DARWIN}

// libc _exit(2) is async-signal-safe; nothing else in a handler is. The
// handler only flips the flag the run loop polls; a second Ctrl-C while
// finalising exits hard rather than corrupting the writer.
procedure c_exit(code: cint); cdecl; external name '_exit';

procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  if StopRequested then
    c_exit(ExitFailure);
  StopRequested := True;
end;

procedure InstallStopSignals;
var
  Action, Previous: SigActionRec;
begin
  FillChar(Action, SizeOf(Action), 0);
  Action.sa_handler := SigActionHandler(@HandleStopSignal);
  FpSigAction(SIGINT, @Action, @Previous);
  FpSigAction(SIGTERM, @Action, @Previous);
end;

// The crash-recovery pass, run at every start. Reported on standard
// error, not standard output: it is about a different recording than the
// one the caller asked for, and a script parsing this command's output
// must not suddenly find a line it has never seen.
procedure RecoverTakesBeside(const AOutputPath: string);
var
  Takes: TRecoveredTakes;
  Summary: string;
  Recovered, Swept: Integer;
begin
  Recovered := RecoverOrphanedTakes(
    ExtractFileDir(ExpandFileName(AOutputPath)), Takes, Swept);
  // Said even when no take needed recovering: a scratch file still on
  // disk is a render that died, and this is the only place that ever
  // notices.
  if Swept > 0 then
  begin
    WriteLn(ErrOutput, ProgramName, ' record: ', Swept,
      ' leftover render scratch file(s) removed');
    Flush(ErrOutput);
  end;
  if Recovered = 0 then
    Exit;
  Summary := DescribeRecoveredTakes(Takes);
  if Summary = '' then
    Exit;
  WriteLn(ErrOutput, ProgramName, ' record: an earlier recording did not '
    + 'finish; it has been recovered:');
  WriteLn(ErrOutput, Summary);
  Flush(ErrOutput);
end;

function HandleRecord(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Recording: TRecordingOptions;
  Session: TRecordingSession;
  Error: string;
  Audio: string;
  Cursor: string;
  Heartbeat: string;
  Silence: string;
begin
  if not BuildRecordingOptions(AOptions, Recording, Error) then
  begin
    WriteLn(ErrOutput, ProgramName, ' record: ', Error);
    Flush(ErrOutput);
    Exit(ExitUsage);
  end;
  // Before anything else: a take whose process died is finished off now,
  // in the directory this one is about to write into. It is one directory
  // listing when nothing is wrong, which is the usual case.
  RecoverTakesBeside(Recording.OutputPath);
  InstallStopSignals;
  Session := TRecordingSession.Create(Recording);
  try
    if not Session.Run(Error) then
    begin
      WriteLn(ErrOutput, ProgramName, ' record: ', Error);
      Flush(ErrOutput);
      Exit(ExitFailure);
    end;
    // One segment per audio track, so --audio=both shows which source is
    // starving rather than one merged count.
    Audio := '';
    if AudioModeCapturesSystem(Session.Report.AudioMode) then
      Audio := Audio + Format(
        ', %d system audio samples (%d dropped early, %d stalled, %d failed)',
        [Session.Report.AppendedAudioSamples,
        Session.Report.DroppedAudioEarly,
        Session.Report.DroppedAudioStalled,
        Session.Report.FailedAudioAppends]);
    if AudioModeCapturesMicrophone(Session.Report.AudioMode) then
      Audio := Audio + Format(
        ', %d mic samples (%d dropped early, %d stalled, %d failed)',
        [Session.Report.AppendedMicrophoneSamples,
        Session.Report.DroppedMicrophoneEarly,
        Session.Report.DroppedMicrophoneStalled,
        Session.Report.FailedMicrophoneAppends]);
    // Big Cursor's own totals. "Off frame" is not a fault — the pointer
    // was somewhere this recording does not show — but a refusal is, so
    // it is named rather than folded into the frame count.
    Cursor := '';
    if Session.Report.SmoothCursor then
      Cursor := ', no pointer in the movie (smooth cursor)';
    if Session.Report.BigCursor then
      Cursor := Format(
        ', big cursor on %d frames (%d off frame, %d refused)',
        [Session.Report.CursorFrames, Session.Report.CursorOffFrame,
        Session.Report.CursorRefused]);
    // The idle heartbeat's share of the frame count, when there was one:
    // a still screen produces no frames at all, so the difference between
    // "this take was 20 seconds long" and "this take was 20 seconds of
    // nothing changing" is worth saying out loud rather than hiding
    // inside one total.
    Heartbeat := '';
    if (Session.Report.HeartbeatFrames > 0)
      or (Session.Report.HeartbeatRefused > 0)
      or (Session.Report.RetimedFrames > 0) then
      Heartbeat := Format(
        ', %d idle heartbeats (%d refused, %d frames retimed)',
        [Session.Report.HeartbeatFrames, Session.Report.HeartbeatRefused,
        Session.Report.RetimedFrames]);
    WriteLn(Format(
      'wrote %s: %dx%d, %.1fs, %d frames (%d dropped, %d failed)%s%s%s',
      [Session.Report.OutputPath, Session.Report.PixelWidth,
      Session.Report.PixelHeight, Session.Report.DurationSeconds,
      Session.Report.AppendedFrames, Session.Report.DroppedFrames,
      Session.Report.FailedAppends, Heartbeat, Cursor, Audio]));
    // Silence, said out loud. Never a failure — the file is written and
    // the video is fine — so this goes to standard error like the other
    // advice, and after the summary line it is about.
    Flush(Output);
    Silence := AudioSilenceWarning('system audio',
      AudioModeCapturesSystem(Session.Report.AudioMode),
      Session.Report.AppendedAudioSamples, Session.Report.AudioInspected,
      Session.Report.AudioPeak);
    if Silence <> '' then
      WriteLn(ErrOutput, ProgramName, ' record: ', Silence);
    Silence := AudioSilenceWarning('the microphone',
      AudioModeCapturesMicrophone(Session.Report.AudioMode),
      Session.Report.AppendedMicrophoneSamples,
      Session.Report.MicrophoneInspected, Session.Report.MicrophonePeak);
    if Silence <> '' then
      WriteLn(ErrOutput, ProgramName, ' record: ', Silence);
    // The other thing a take can come back with that nothing failed
    // over: an enlarged pointer standing still because the frames it was
    // drawn into were repeats. Same treatment as the silence — advice on
    // stderr, exit code untouched.
    Silence := BigCursorIdleWarning(Session.Report.BigCursor,
      Session.Report.CursorFrames, Session.Report.HeartbeatFrames,
      Session.Report.AppendedFrames);
    if Silence <> '' then
      WriteLn(ErrOutput, ProgramName, ' record: ', Silence);
    // And the stop the framework never confirmed. Same treatment again:
    // the file is written, and this is the explanation for a take that
    // comes back a frame or two short.
    if Session.Report.StopUnconfirmed then
      WriteLn(ErrOutput, ProgramName, ' record: ScreenCaptureKit did not '
        + 'confirm the stop; the movie was finalised anyway and may be a '
        + 'frame or two short');
    Flush(ErrOutput);
    // The event sidecar, and the two spans that say whether its clock is
    // the movie's. Both are measured from the same host clock: the first
    // is anchor-to-stop, the second is the movie's own first-to-last
    // frame. Before the idle heartbeat they differed by however long
    // nothing moved, because ScreenCaptureKit delivers a frame only when
    // something changes; now the closing heartbeat puts the last frame at
    // the stop itself, so the two agree to a few milliseconds whatever
    // the screen was doing. A difference of more than a frame is the
    // thing to worry about.
    // The two spans are only a pair when there IS an anchor: without one
    // no frame was ever appended, and StopHostSeconds minus zero is the
    // machine's uptime.
    if (Session.Report.SidecarPath <> '')
      and (Session.Report.AnchorHostSeconds > 0) then
      WriteLn(Format('wrote %s: %d pointer samples over %.3f s '
        + '(the movie spans %.3f s)',
        [Session.Report.SidecarPath, Session.Report.SidecarSamples,
        Session.Report.StopHostSeconds - Session.Report.AnchorHostSeconds,
        Session.Report.DurationSeconds]))
    else if Session.Report.SidecarPath <> '' then
      WriteLn(Format('wrote %s: %d pointer samples (no anchor — no frame '
        + 'reached the movie)',
        [Session.Report.SidecarPath, Session.Report.SidecarSamples]))
    else if Session.Report.SidecarError <> '' then
      WriteLn('no event sidecar: ', Session.Report.SidecarError);
    Result := ExitOk;
  finally
    Session.Free;
  end;
end;

// The menu-bar app. Nothing is captured until the user asks; the process
// simply installs a status item and hands itself to NSApp's run loop.
function HandleApp(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Error: string;
begin
  if not RunMenuBarApp(Error) then
  begin
    WriteLn(ErrOutput, ProgramName, ' app: ', Error);
    Flush(ErrOutput);
    Exit(ExitFailure);
  end;
  Result := ExitOk;
end;

// True when the movie beside this path was recorded with the pointer left
// out for an export to draw back. Reading the sidecar's header is enough,
// and now that is all it reads: the comment made that claim while the
// call underneath it parsed the whole track — every sample of it — to
// look at one field of line one.
function MovieWantsSmoothCursor(const AMoviePath: string): Boolean;
var
  Log: TSidecarLog;
  Error: string;
begin
  Result := False;
  Log := TSidecarLog.Create;
  try
    if Log.LoadFromFile(SidecarPathFor(AMoviePath), slmHeaderOnly, Error) then
      Result := Log.Header.CursorRender = scrSmooth;
  finally
    Log.Free;
  end;
end;

// A passthrough trim: same samples, new container, no decode at all.
function HandleTrimExport(const AOptions: TExportOptions;
  const AParsed: TOptionArray): Integer;
var
  Session: TMovieTrimSession;
  Error: string;
begin
  // The scope limit, said out loud where somebody would otherwise meet it
  // as a mystery. A trim copies coded samples; drawing a pointer into
  // them would mean decoding and re-encoding the whole video, which this
  // command exists precisely not to do.
  if MovieWantsSmoothCursor(AOptions.InputPath) then
  begin
    WriteLn(ErrOutput, ProgramName, ' export: this recording keeps its '
      + 'pointer in its event sidecar (--smooth-cursor), and a passthrough '
      + 'trim cannot draw one in — the trimmed movie has no pointer. '
      + 'Export to .gif or .apng for the smooth pointer.');
    Flush(ErrOutput);
  end;
  if FlagPresent(AParsed, 'fps') or FlagPresent(AParsed, 'width')
    or FlagPresent(AParsed, 'no-dither') then
  begin
    WriteLn(ErrOutput, ProgramName, ' export: --fps, --width and '
      + '--no-dither do not apply to a passthrough trim and are ignored');
    Flush(ErrOutput);
  end;
  // Ctrl-C mid-trim now fails cleanly rather than killing the process
  // where it stands: the neighbour is swept and the movie the caller
  // already had is untouched (Knips.Export.Atomic).
  InstallStopSignals;
  Session := TMovieTrimSession.Create(AOptions);
  try
    if not Session.Run(Error) then
    begin
      WriteLn(ErrOutput, ProgramName, ' export: ', Error);
      Flush(ErrOutput);
      Exit(ExitFailure);
    end;
    WriteLn(TrimSummaryLine(Session.Report.OutputPath,
      Session.Report.StartSeconds, Session.Report.EndSeconds,
      Session.Report.SourceDurationSeconds, Session.Report.OutputBytes));
    Result := ExitOk;
  finally
    Session.Free;
  end;
end;

function HandleExport(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Options: TExportOptions;
  Session: TExportSession;
  Error, Warning: string;
begin
  if not BuildExportOptions(AOptions, Options, Error) then
  begin
    WriteLn(ErrOutput, ProgramName, ' export: ', Error);
    Flush(ErrOutput);
    Exit(ExitUsage);
  end;
  if Options.Format = efMovie then
    Exit(HandleTrimExport(Options, AOptions));
  // See HandleTrimExport: an export that is stopped must not be able to
  // destroy the animation that was already at that path.
  InstallStopSignals;
  Session := TExportSession.Create(Options);
  try
    if not Session.Run(Error) then
    begin
      WriteLn(ErrOutput, ProgramName, ' export: ', Error);
      Flush(ErrOutput);
      Exit(ExitFailure);
    end;
    // Every clause of what this export did, composed once in
    // Knips.Options so the CLI, the MCP export tools and the playback
    // window describe the same work in the same words and the same
    // order. The render round did this for renders and never reached
    // the export side; this is that half.
    WriteLn(ExportSummaryLine(Session.Report.OutputPath,
      Session.Report.PixelWidth, Session.Report.PixelHeight,
      Session.Report.FramesWritten, Session.Report.DurationSeconds,
      Session.Report.OutputBytes,
      ExportAppliedSummary(ExportFactsOf(Session.Report))));
    // The sidecar asked for a pointer and it could not be drawn. Never a
    // failure — the animation is right, it is the pointer that is missing
    // — but never silent either, because the movie has none of its own.
    if Session.Report.SmoothCursorNote <> '' then
    begin
      Flush(Output);
      WriteLn(ErrOutput, ProgramName, ' export: ',
        EffectCursorNoteLine(Session.Report.SmoothCursorNote));
      Flush(ErrOutput);
    end;
    // The same shape for the zoom: asked for, could not be applied, and
    // never a reason to fail the export.
    if Session.Report.ZoomNote <> '' then
    begin
      Flush(Output);
      WriteLn(ErrOutput, ProgramName, ' export: ',
        EffectZoomNoteLine(Session.Report.ZoomNote));
      Flush(ErrOutput);
    end;
    // And the one about the pixels rather than about an effect. Its own
    // line, always, whatever the two above said: it is the only note
    // here that means some frames show something the take could not
    // account for.
    if Session.Report.FramingNote <> '' then
    begin
      Flush(Output);
      WriteLn(ErrOutput, ProgramName, ' export: ',
        EffectFramingNoteLine(Session.Report.FramingNote));
      Flush(ErrOutput);
    end;
    // And what the sidecar loader could not use. The loader is tolerant
    // on purpose and says nothing about it; a run that drew a pointer
    // from a track with holes in it should say so.
    if Session.Report.SidecarSkippedLines > 0 then
    begin
      Flush(Output);
      WriteLn(ErrOutput, ProgramName, ' export: ',
        SidecarSkippedLinesNote(Session.Report.SidecarSkippedLines));
      Flush(ErrOutput);
    end;
    // How close the pre-export estimate came. Printed because an estimate
    // nobody ever checks is an estimate nobody can improve — and because
    // a reader who was told "about 3.5 MB" deserves to see the 3.6.
    if Session.Report.EstimatedBytes > 0 then
      WriteLn(Format('  estimated %s before encoding (%s to %s), actual %s',
        [FormatByteSize(Session.Report.EstimatedBytes),
        FormatByteSize(Session.Report.EstimatedLowBytes),
        FormatByteSize(Session.Report.EstimatedHighBytes),
        FormatByteSize(Session.Report.OutputBytes)]));
    // Advice, not a failure: the file is written and usable either way,
    // so this goes to stderr and the exit code stays zero. Stdout is
    // flushed first, or the two streams interleave and the advice lands
    // above the line it is about.
    Flush(Output);
    Warning := LargeExportWarning(Session.Report.Format,
      Session.Report.PixelWidth, Session.Report.PixelHeight,
      Options.FramesPerSecond, Session.Report.OutputBytes);
    if Warning <> '' then
    begin
      WriteLn(ErrOutput, ProgramName, ' export: ', Warning);
      Flush(ErrOutput);
    end;
    Result := ExitOk;
  finally
    Session.Free;
  end;
end;

// `knips render` — the scriptable face of the render pass the menu-bar app
// runs on every stop. A raw take plus its sidecar in, the deliverable out;
// audio copied rather than re-encoded.
function HandleRender(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Effects: TExportEffects;
  Facts: TRenderAppliedFacts;
  Session: TRenderSession;
  InputPath, OutputPath, Error, Applied, EffectsText: string;
begin
  InputPath := StringValue(AOptions, 'in', '');
  OutputPath := StringValue(AOptions, 'out', '');
  if InputPath = '' then
  begin
    WriteLn(ErrOutput, ProgramName, ' render: an input take is required '
      + '(--in=demo-raw.mp4)');
    Flush(ErrOutput);
    Exit(ExitUsage);
  end;
  if OutputPath = '' then
  begin
    // The obvious answer when the input is a raw take: the deliverable is
    // the same name without the suffix. Anything else has to be named,
    // and the refusal says which half of that rule the input missed
    // rather than 'an output path is required' — --out is optional, but
    // only for a raw take.
    if not IsRawTakePath(InputPath) then
    begin
      WriteLn(ErrOutput, ProgramName, ' render: cannot derive an output name '
        + 'from "' + ExtractFileName(InputPath) + '" (only *-raw names have '
        + 'one); pass --out=demo.mp4');
      Flush(ErrOutput);
      Exit(ExitUsage);
    end;
    OutputPath := DeliverablePathFor(InputPath);
  end;
  // The render writes H.264 into a QuickTime-family container and can
  // write nothing else; `--out=demo.gif` used to produce exactly that,
  // named demo.gif, and report success. Refused here rather than in
  // TRenderSession so the exit code is a usage one — and through the
  // same function the MCP tool asks, so the two faces cannot drift.
  if not ValidateRenderOutputPath(OutputPath, Error) then
  begin
    WriteLn(ErrOutput, ProgramName, ' render: ', Error);
    Flush(ErrOutput);
    Exit(ExitUsage);
  end;
  EffectsText := StringValue(AOptions, 'effects', '');
  Effects := DefaultExportEffects;
  if not ParseExportEffects(EffectsText, Effects, Error) then
  begin
    WriteLn(ErrOutput, ProgramName, ' render: ', Error);
    Flush(ErrOutput);
    Exit(ExitUsage);
  end;
  InstallStopSignals;
  Session := TRenderSession.Create(InputPath, OutputPath, Effects);
  // `--effects=none` is a request for the raw pixels as the
  // deliverable, and the only way to ask a render to apply nothing.
  Session.ExplicitCopy := ExportEffectsRequestCopy(EffectsText);
  try
    if not Session.Run(Error) then
    begin
      WriteLn(ErrOutput, ProgramName, ' render: ', Error);
      Flush(ErrOutput);
      Exit(ExitFailure);
    end;
    // Every clause of what this render did, composed once in
    // Knips.Options so `knips render` and the MCP render tool describe
    // the same work in the same words. The two used to hold a
    // byte-identical copy of it each, which is exactly the duplication
    // that drifts the first time one clause is reworded.
    // Fourteen assignments used to sit here and again in the other
    // front end, byte for byte. The report is the render's own record,
    // so the render is where it gets turned into the neutral facts the
    // wording is composed from.
    Facts := RenderFactsOf(Session.Report);
    Applied := RenderAppliedSummary(Facts);
    WriteLn(RenderSummaryLine(Session.Report.OutputPath,
      Session.Report.PixelWidth, Session.Report.PixelHeight,
      Session.Report.FramesWritten, Session.Report.SourceDurationSeconds,
      Session.Report.OutputBytes, Session.Report.Copied, Applied));
    // The deliverable's own sidecar, named the way `record` names the
    // one it writes. A rendered take is two movies and two sidecars
    // (docs/event-sidecar.md), and this is the line that says the second
    // pair is there — without it the deliverable's copy was written and
    // never mentioned.
    if Session.Report.SidecarPath <> '' then
      WriteLn('wrote ', Session.Report.SidecarPath,
        ': the take''s events, re-headed for the deliverable');
    // The number that decides whether this can run on every stop.
    WriteLn(Format('  %.2fs of work for %.2fs of take (%.2fx realtime)',
      [Session.Report.ElapsedSeconds, Session.Report.SourceDurationSeconds,
      Session.Report.RealtimeFactor]));
    // An effect that was asked for and could not be applied, and the
    // frames the take could not account for. Never a failure — the
    // deliverable is correct without them — and never silent. All three
    // printed, not the summary: a console has the room, and the summary
    // exists for the places that do not (see EffectNoteSummary).
    Flush(Output);
    if Session.Report.FramingNote <> '' then
      WriteLn(ErrOutput, ProgramName, ' render: ',
        EffectFramingNoteLine(Session.Report.FramingNote));
    // The two wrappers come from Knips.Options for the same reason the
    // clause list above does: one field, one set of words, whichever
    // face is reporting it.
    if Session.Report.CursorNote <> '' then
      WriteLn(ErrOutput, ProgramName, ' render: ',
        EffectCursorNoteLine(Session.Report.CursorNote));
    if Session.Report.ZoomNote <> '' then
      WriteLn(ErrOutput, ProgramName, ' render: ',
        EffectZoomNoteLine(Session.Report.ZoomNote));
    // And what the sidecar loader could not use — same sentence the
    // export prints, from the same function.
    if Session.Report.SidecarSkippedLines > 0 then
      WriteLn(ErrOutput, ProgramName, ' render: ',
        SidecarSkippedLinesNote(Session.Report.SidecarSkippedLines));
    Flush(ErrOutput);
    Result := ExitOk;
  finally
    Session.Free;
  end;
end;

function HandleDisplays(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Content: TShareableContent;
  I: Integer;
  Display: TDisplayInfo;
  Main: string;
begin
  try
    Content := TShareableContent.Create;
  except
    on E: EShareableContent do
    begin
      WriteLn(ErrOutput, ProgramName, ' displays: ', E.Message);
      Flush(ErrOutput);
      Exit(ExitFailure);
    end;
  end;
  try
    WriteLn('index  id          points        scale  ');
    for I := 0 to Content.DisplayCount - 1 do
    begin
      Display := Content.DisplayAt(I);
      if Display.IsMain then
        Main := ' [main]'
      else
        Main := '';
      WriteLn(Format('%5d  %-10d  %5dx%-5d   %dx%s', [Display.Index,
        Display.DisplayID, Display.Width, Display.Height,
        DisplayBackingScale(Display.DisplayID), Main]));
    end;
  finally
    Content.Free;
  end;
  Result := ExitOk;
end;

function HandleWindows(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Content: TShareableContent;
  I: Integer;
  Window: TWindowInfo;
begin
  try
    Content := TShareableContent.Create;
  except
    on E: EShareableContent do
    begin
      WriteLn(ErrOutput, ProgramName, ' windows: ', E.Message);
      Flush(ErrOutput);
      Exit(ExitFailure);
    end;
  end;
  try
    WriteLn('id          points        application            title');
    for I := 0 to Content.WindowCount - 1 do
    begin
      Window := Content.WindowAt(I);
      // Layer 0 is ordinary application windows; menu bar items, the
      // dock and overlays sit on other layers and are rarely wanted.
      if (not Window.OnScreen) or (Window.Layer <> 0) then
        Continue;
      if (Window.Width = 0) or (Window.Height = 0) then
        Continue;
      // %u, not %d: a CGWindowID is unsigned and 4294967295 printed as
      // "-1" is not an id anybody can pass back in.
      WriteLn(Format('%-10u  %5dx%-5d   %-22s %s', [Window.WindowID,
        Window.Width, Window.Height, Copy(Window.ApplicationName, 1, 22),
        Window.Title]));
    end;
  finally
    Content.Free;
  end;
  Result := ExitOk;
end;

// Checks that each app runtime class carries the methods AppKit will
// dispatch on it. False (with a printed reason) fails the probe.
function CheckAppRuntimeClasses: Boolean;

  function HasMethod(const AClassName, ASelector: string): Boolean;
  begin
    Result := ClassImplementsSelector(LookUpClass(AClassName), ASelector);
    if not Result then
      WriteLn(AClassName, ': no implementation for ', ASelector);
  end;

const
  // Every action AppKit will dispatch on the target: the menu items, the
  // status-item button, the deferred one-shots, the playback window's
  // buttons, and the Record Window submenu's delegate callback.
  TargetSelectors: array[0..28] of string = (
    'recordRegion:', 'recordDisplay:', 'recordWindow:', 'recordLastRegion:',
    'toggleSystemAudio:', 'toggleMicrophone:', 'stopRecording:',
    'cancelSelection:',
    'revealRecordings:', 'quitKnips:', 'timerFired:', 'startPending:',
    'stopPending:', 'menuNeedsUpdate:', 'exportGif:', 'revealRecording:',
    'closePlayback:', 'toggleCamera:', 'toggleCameraShape:',
    'toggleCameraBlur:',
    'restoreCamera:', 'toggleFollowMouse:', 'toggleEffectZoom:',
    'toggleEffectSmoothCursor:', 'toggleEffectBigCursor:',
    'reexportRecording:', 'recoverTakes:',
    'liveTick:', 'cameraRideTick:');
  // The camera window's own drag, and the snap ease's timer callback.
  // Without the three mouse methods the window still appears and still
  // shows a picture — it simply cannot be moved at all, because
  // movableByWindowBackground is off precisely so that mouseUp: reaches
  // the view and the corner snap has a drag end to fire on. Without
  // snapTick: the drop never travels: the timer fires into an
  // unrecognised selector, which is an ObjC exception no Pascal handler
  // could catch.
  CameraViewSelectors: array[0..4] of string = (
    'acceptsFirstMouse:', 'mouseDown:', 'mouseDragged:', 'mouseUp:',
    'snapTick:');
var
  Instance: id;
  I: Integer;
begin
  Result := False;
  if not HasMethod(OverlayViewClassName, 'drawRect:') then
    Exit;
  if not HasMethod(OverlayViewClassName, 'mouseUp:') then
    Exit;
  if not HasMethod(OverlayWindowClassName, 'canBecomeKeyWindow') then
    Exit;
  // Without acceptsFirstMouse: the camera window still appears — it just
  // takes two clicks to drag, which is the kind of failure nobody
  // reports and everybody blames on themselves. The three mouse methods
  // are worse still: the window would not move at all.
  for I := Low(CameraViewSelectors) to High(CameraViewSelectors) do
    if not HasMethod(CameraViewClassName, CameraViewSelectors[I]) then
      Exit;
  if not HasMethod(BorderViewClassName, 'drawRect:') then
    Exit;
  if not HasMethod(PlaybackDelegateClassName, 'windowWillClose:') then
    Exit;
  // Without it a titlebar close or ⌘W lands in the middle of a GIF export
  // — the one close AppKit drives that CommandClose's guard never sees.
  if not HasMethod(PlaybackDelegateClassName, 'windowShouldClose:') then
    Exit;
  Instance := InstantiateClass(LookUpClass(AppTargetClassName));
  if Instance = nil then
  begin
    WriteLn(AppTargetClassName, ': instantiation failed');
    Exit;
  end;
  try
    for I := Low(TargetSelectors) to High(TargetSelectors) do
      if not RespondsToSelector(Instance, TargetSelectors[I]) then
      begin
        WriteLn(AppTargetClassName, ': does not respond to ',
          TargetSelectors[I]);
        Exit;
      end;
  finally
    ReleaseInstance(Instance);
  end;
  // The camera's background-blur delegate. AVCaptureVideoDataOutput
  // dispatches by selector like SCStream does, so a class_addMethod that
  // silently failed would show up only as a blur toggle that switches
  // on, stops the preview layer, and then shows nothing at all.
  if not HasMethod(CameraBlurOutputClassName,
    'captureOutput:didOutputSampleBuffer:fromConnection:') then
    Exit;
  WriteLn('runtime classes ', AppTargetClassName, ', ',
    OverlayViewClassName, ', ', OverlayWindowClassName, ', ',
    CameraViewClassName, ', ', BorderViewClassName, ', ',
    PlaybackDelegateClassName, ', ', CameraBlurOutputClassName,
    ': registered and answering');
  Result := True;
end;

// What the camera's background blur costs on THIS Mac, in the numbers
// that decide whether it can be switched on: milliseconds per frame and
// the frame rate that implies, against the camera window's own 30 Hz.
//
// Measured rather than asserted, and measured here rather than from the
// camera, because the Camera TCC grant belongs to the *bundle* and a
// probe run from a shell has no camera at all. Vision's segmentation
// network costs what the frame size and the quality level make it cost,
// so synthetic frames answer the timing question exactly; what they
// cannot answer is how the mask looks, which needs eyes and a face.
//
// Never fatal. A Mac too slow for the effect is a Mac where the checkbox
// is a bad idea, not one where the recorder is broken.
//
// And no HasWindowServer gate, unlike the Dock and hotkey checks above.
// Nothing here touches NSApplication or HIToolbox: CIContext
// contextWithOptions: (given only the cache-intermediates option) picks
// a renderer for itself
// (Metal headless, no window server, no display attached), Vision runs
// on the ANE or the CPU, and the CALayer it renders into is never put on
// a screen. Over SSH or under launchd this measures exactly what it
// measures at the console.
procedure ProbeCameraBlurCost;
const
  // The camera window's own feed: AVCaptureSessionPreset640x480.
  FrameWidth = 640;
  FrameHeight = 480;
  // Enough that the first frame's model load and kernel compile is not
  // what the mean reports. Both caches are PROCESS-wide, not per
  // pipeline — Vision's segmentation model and CoreImage's compiled
  // kernels outlive any one CIContext — so the second call below starts
  // from a warm process even though it builds a fresh pipeline.
  WarmUpFrames = 5;
  MeasuredFrames = 30;
  PreviewFramesPerSecond = 30;
var
  Blur: TCameraBlur;
  Error: string;
  Milliseconds, Sustainable: Double;
begin
  Blur := TCameraBlur.Create;
  try
    Blur.Quality := cbqFast;
    if not Blur.MeasureOffline(FrameWidth, FrameHeight, WarmUpFrames,
      Error) then
    begin
      WriteLn('camera background blur cost: not measured (', Error, ')');
      Exit;
    end;
    if not Blur.MeasureOffline(FrameWidth, FrameHeight, MeasuredFrames,
      Error) then
    begin
      WriteLn('camera background blur cost: not measured (', Error, ')');
      Exit;
    end;
    Milliseconds := Blur.MeanFrameMilliseconds;
    if Milliseconds <= 0 then
    begin
      WriteLn('camera background blur cost: nothing to report');
      Exit;
    end;
    Sustainable := 1000 / Milliseconds;
    // Two different numbers, and the difference is the point.
    // Sustainable is arithmetic: what the per-frame mean implies if
    // nothing else ever gets in the way. Achieved is what the run
    // actually managed, wall clock, queue waits and all — it is the one
    // TCameraBlur reports live and the one nothing printed, so a
    // pipeline that was fast per frame and slow in aggregate looked
    // fine here.
    WriteLn(Format('camera background blur cost: %.1f ms/frame at '
      + '%dx%d (%.1f ms of it Vision), %.0f fps sustainable and %.0f fps '
      + 'achieved against a %d fps preview',
      [Milliseconds, FrameWidth, FrameHeight,
      Blur.MeanSegmentationMilliseconds, Sustainable,
      Blur.AchievedFramesPerSecond, PreviewFramesPerSecond]));
    if Sustainable < PreviewFramesPerSecond then
      WriteLn('camera background blur: SLOWER than the preview on this '
        + 'Mac — the picture will drop frames while it is on');
  finally
    Blur.Free;
  end;
end;

// The spike check (ADR-0002): register the runtime-built stream output
// class, instantiate it, confirm it answers the SCStreamOutput selector,
// and touch ScreenCaptureKit + AVFoundation so linking is exercised. If
// this prints ok, `record` depends on nothing unverified but pixels.
function HandleProbe(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Instance: id;
  Content: TShareableContent;
  Writer: TMovieWriter;
  SpriteWidth, SpriteHeight, HotSpotX, HotSpotY: Integer;
  Error: string;
  Detail: string;
  TempPath: string;
begin
  Result := ExitFailure;
  try
    EnsureStreamOutputClass;
    WriteLn('runtime class ', StreamOutputClassName, ': registered');
    Instance := InstantiateClass(LookUpClass(StreamOutputClassName));
    if Instance = nil then
    begin
      WriteLn('runtime class: instantiation failed');
      Exit;
    end;
    try
      if not RespondsToSelector(Instance,
        'stream:didOutputSampleBuffer:ofType:') then
      begin
        WriteLn('runtime class: does not respond to the SCStreamOutput selector');
        Exit;
      end;
      WriteLn('runtime class: responds to stream:didOutputSampleBuffer:ofType:');
    finally
      ReleaseInstance(Instance);
    end;
  except
    on E: Exception do
    begin
      WriteLn('runtime class: ', E.Message);
      Exit;
    end;
  end;

  // The menu bar and the overlay ride on the same primitive, so the gate
  // has to cover them too: register, then check that the overrides AppKit
  // dispatches on are really installed, and that a target instance
  // answers an action selector. A registration that silently dropped a
  // method would otherwise only show up as a dead menu or an undrawn
  // overlay on someone's machine.
  try
    EnsureAppClasses;
    if not CheckAppRuntimeClasses then
      Exit;
  except
    on E: Exception do
    begin
      WriteLn('app runtime classes: ', E.Message);
      Exit;
    end;
  end;

  // The playback window puts the process in the Dock and gives it a menu
  // bar, and puts it back afterwards. Both halves are one AppKit call that
  // can decline, so the gate is the policy read back rather than the call
  // made — and the menu is checked for shape, because an app that promotes
  // with no ⌘Q is worse than one that never promotes. The activation nudge
  // is deliberately not exercised here: with no run loop it would mean
  // nothing, and it would take focus off the terminal.
  //
  // Skipped, not failed, without a window server. This is the only check
  // in the probe that touches NSApplication, and AppKit kills a process
  // that reaches for it over SSH or under launchd — where the rest of the
  // probe (runtime classes, encodings, and the type-check the cross
  // compiler does) is still worth running.
  if not HasWindowServer then
    WriteLn('Dock promotion: skipped (no window server)')
  else
    try
      if not CheckDockPromotion(Detail, Error) then
      begin
        WriteLn('Dock promotion: ', Error);
        Exit;
      end;
      WriteLn('Dock promotion: ', Detail);
    except
      on E: Exception do
      begin
        WriteLn('Dock promotion: ', E.Message);
        Exit;
      end;
    end;

  // The global stop hotkey: register the chord with Carbon, read the key
  // code and modifier constants back out of the headers, and hand it
  // back. A gate, unlike the two informational lines below, because
  // every one of these calls answers an OSStatus that is easy to ignore
  // and a hotkey that silently did not register is indistinguishable
  // from one the user simply has not pressed.
  //
  // What this CANNOT prove is delivery. RegisterEventHotKey answers
  // noErr even for a chord the system already owns (measured: ⌘⇧3, the
  // screenshot shortcut, registers just as cleanly as ⌘⇧2), and the only
  // way to see an event arrive is to press the keys — which this
  // project's test tooling is forbidden to synthesise. Pressing ⌘⇧2
  // during a recording is on the human checklist in
  // docs/quick-start.md.
  //
  // Skipped, not failed, without a window server — the same rule the Dock
  // check above follows and for the same reason: HIToolbox is as
  // window-server-bound as AppKit is, and the rest of the probe is still
  // worth running over SSH or under launchd.
  if not HasWindowServer then
    WriteLn('global stop hotkey: skipped (no window server)')
  else
    try
      if not CheckStopHotKey(Detail, Error) then
      begin
        WriteLn('global stop hotkey: ', Error);
        Exit;
      end;
      WriteLn('global stop hotkey: ', Detail);
    except
      on E: Exception do
      begin
        WriteLn('global stop hotkey: ', E.Message);
        Exit;
      end;
    end;

  // Informational, not a gate: microphone capture is macOS 15+, the
  // project floor is 13. record --audio=mic refuses cleanly where this
  // prints unavailable.
  if StreamSupportsMicrophone then
    WriteLn('microphone capture: supported')
  else
    WriteLn('microphone capture: unavailable (needs macOS 15+)');

  // Also informational, and per binary: TCC grants the microphone to
  // this executable, not to Knips in the abstract, so a fresh build
  // starts undecided and the first `--audio=mic` recording prompts.
  //
  // Informational is all it can be. Measured on this machine,
  // ScreenCaptureKit captured the microphone while this status read
  // *undecided*, so it is not the gate SCK goes through: the menu-bar app
  // warns on a denied grant when the box is ticked and lets the recording
  // run, and what actually catches a silent track is the microphone
  // sample count in the finished recording's report.
  case MicrophoneAccess of
    maAuthorized: WriteLn('microphone access: granted');
    maDenied: WriteLn('microphone access: denied — ',
      'System Settings › Privacy & Security › Microphone');
    maRestricted: WriteLn('microphone access: restricted');
  else
    WriteLn('microphone access: not yet asked (the first mic recording ',
      'will prompt)');
  end;

  // Informational, and per binary exactly as the microphone is: the
  // Camera grant is its own TCC entry, so a fresh build starts undecided
  // and the first Camera click prompts. A denied grant is invisible from
  // inside AVCaptureSession — startRunning succeeds and isRunning
  // answers YES with no access, measured — which is why the camera
  // window consults this status rather than the session.
  case CameraAccess of
    caAuthorized: WriteLn('camera access: granted');
    caDenied: WriteLn('camera access: denied — ',
      'System Settings › Privacy & Security › Camera');
    caRestricted: WriteLn('camera access: restricted');
  else
    WriteLn('camera access: not yet asked (the first Camera click ',
      'will prompt)');
  end;

  // Background blur, and what the system's own Portrait effect says.
  // Both informational. The second line is the record of a fact worth
  // re-checking on a later SDK: AVCaptureDevice exposes the Portrait
  // effect read-only in both of its forms, so this is the state of a
  // Control Center switch Knips can neither set nor own — which is why
  // Blur Background is Vision and CoreImage rather than one property
  // assignment (docs/architecture.md, "Background blur").
  if CameraBlurSupported then
  begin
    WriteLn('camera background blur: available (Vision + CoreImage)');
    // Behind a flag. It costs more than the whole of the rest of the
    // probe (the measurement is at ProbeOptions) and it gates NOTHING —
    // a slow Mac gets a warning and the probe still passes — so the
    // check that runs before every handoff should not be paying for it.
    // `knips probe --blur-cost` when the question is whether this
    // machine can hold 30 fps with the effect on.
    if FlagPresent(AOptions, 'blur-cost') then
      ProbeCameraBlurCost
    else
      WriteLn('camera background blur cost: not measured '
        + '(pass --blur-cost)');
  end
  else
    WriteLn('camera background blur: unavailable on this Mac');
  if SystemPortraitEffectEnabled then
    WriteLn('system Portrait effect: on in Control Center (read-only to '
      + 'every app, including this one)')
  else
    WriteLn('system Portrait effect: off in Control Center (read-only to '
      + 'every app, including this one)');

  // Likewise informational. The header puts updateConfiguration: at
  // macOS 12.3, below the project floor, so this should always say
  // supported; the app turns Zoom on Click and Follow Mouse off for a
  // recording rather than failing it where it does not.
  if StreamSupportsLiveUpdate then
    WriteLn('live source-rect updates: supported')
  else
    WriteLn('live source-rect updates: unavailable (Zoom on Click and '
      + 'Follow Mouse will be off)');

  // Big Cursor's one framework dependency, exercised rather than
  // assumed: the sprite is made from NSCursor's own image, and without
  // an NSApplication +arrowCursor answers nil (measured). Rendering it
  // here is what turns "the pointer did not come out" into a line
  // printed before anything is recorded. Informational, like the two
  // above: a recording falls back to the system pointer instead.
  if ProbeCursorSprite(SpriteWidth, SpriteHeight, HotSpotX, HotSpotY,
    Error) then
    WriteLn(Format('big cursor: sprite %dx%d px, hot spot %d,%d',
      [SpriteWidth, SpriteHeight, HotSpotX, HotSpotY]))
  else
    WriteLn('big cursor: unavailable (', Error, ')');

  try
    Content := TShareableContent.Create;
    try
      WriteLn(Format('ScreenCaptureKit: %d display(s), %d window(s)',
        [Content.DisplayCount, Content.WindowCount]));
    finally
      Content.Free;
    end;
  except
    on E: EShareableContent do
    begin
      WriteLn('ScreenCaptureKit: ', E.Message);
      Exit;
    end;
  end;

  // GetTempDir prefers $TEMP, which on macOS is not the temporary
  // directory anybody means: $TMPDIR is, and it is the per-user one the
  // sandbox and every other Apple convention point at. GetTempDir(False)
  // still falls back to /tmp when neither is set.
  TempPath := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TMPDIR'));
  if TempPath = PathDelim then
    TempPath := IncludeTrailingPathDelimiter(GetTempDir);
  TempPath := TempPath + 'knips-probe.mp4';
  Writer := TMovieWriter.Create(TempPath, ocMPEG4, 1280, 720,
    DefaultFramesPerSecond, MinBitRate);
  try
    if not Writer.Open(Error) then
    begin
      WriteLn('AVAssetWriter: ', Error);
      Exit;
    end;
    Writer.Cancel;
    WriteLn('AVAssetWriter: opened and cancelled ', TempPath);
  finally
    Writer.Free;
    DeleteFile(TempPath);
  end;
  WriteLn('probe: ok');
  Result := ExitOk;
end;

{$ELSE}

function HandleUnsupported(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Recording: TRecordingOptions;
  Error: string;
begin
  // Validation is platform-neutral, so bad invocations fail the same way
  // everywhere; only the capture itself is macOS-only.
  if (Length(AOptions) > 0)
    and not BuildRecordingOptions(AOptions, Recording, Error) then
  begin
    WriteLn(ErrOutput, ProgramName, ' record: ', Error);
    Flush(ErrOutput);
    Exit(ExitUsage);
  end;
  // Stderr like every other refusal on this surface: the exit code
  // is non-zero and stdout is where a caller expects the thing it
  // asked for, not the reason it is not getting one.
  WriteLn(ErrOutput, ProgramName, ': screen capture is macOS-only in this build');
  Flush(ErrOutput);
  Result := ExitUnsupported;
end;

function HandleExportUnsupported(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Options: TExportOptions;
  Error: string;
begin
  // The GIF encoder is platform-neutral; only reading the movie needs
  // AVFoundation, so the same invocation fails the same way everywhere.
  if (Length(AOptions) > 0)
    and not BuildExportOptions(AOptions, Options, Error) then
  begin
    WriteLn(ErrOutput, ProgramName, ' export: ', Error);
    Flush(ErrOutput);
    Exit(ExitUsage);
  end;
  // Stderr like every other refusal on this surface: the exit code
  // is non-zero and stdout is where a caller expects the thing it
  // asked for, not the reason it is not getting one.
  WriteLn(ErrOutput, ProgramName, ': reading movies is macOS-only in this build');
  Flush(ErrOutput);
  Result := ExitUnsupported;
end;

{$ENDIF}

// The MCP server. Platform-neutral at this level: the protocol loop
// compiles everywhere and the capture tools refuse in-band off Darwin,
// so a client that discovers the server on Linux is told why rather
// than finding half a tool list.
//
// Standard output belongs to the JSON-RPC stream from here on — the
// stdio binding allows nothing else on it — so this command prints
// diagnostics to standard error and nothing at all on success. Stdin
// EOF is the shutdown signal, and it is also what gives the server the
// chance to finalise a recording still in flight; a killed process
// loses the movie's moov atom, as `record` would.
function HandleMcp(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Error: string;
begin
  if not RunKnipsMcpServer(Error) then
  begin
    WriteLn(ErrOutput, ProgramName, ' mcp: ', Error);
    Flush(ErrOutput);
    Exit(ExitFailure);
  end;
  Result := ExitOk;
end;

// Option objects are owned by the registry once the subcommand is added.
// The one flag `probe` takes. Measuring the camera blur gates nothing
// and costs MORE than the rest of the probe put together: measured on
// this machine at 0.33 s of a 0.58 s run, against 0.25 s without it.
// The comment used to say "40-50% of the probe's wall time", which was
// the wrong side of half; this is the one place the measurement is
// written down and the site that runs it points here.
//
// TOptionArray is managed and a function result is not initialised on
// entry, so SetLength on it reads whatever the caller's variable held.
// `Result := nil` first, here and in the three below.
function ProbeOptions: TOptionArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := TFlagOption.Create('blur-cost',
    'Also measure the camera background blur, which costs a few seconds');
end;

function RecordOptions: TOptionArray;
begin
  Result := nil;
  SetLength(Result, 11);
  Result[0] := TStringOption.Create('out',
    'Output file; .mp4 or .mov (required)');
  Result[1] := TIntegerOption.Create('display',
    'Display index from `knips displays` (default: main)');
  Result[2] := TIntegerOption.Create('window',
    'Record one window by id from `knips windows`');
  Result[3] := TStringOption.Create('rect',
    'Region of the display in points: left,top,width,height');
  Result[4] := TIntegerOption.Create('fps',
    Format('Frames per second, %d-%d (default %d)',
    [MinFramesPerSecond, MaxFramesPerSecond, DefaultFramesPerSecond]));
  Result[5] := TStringOption.Create('scale',
    'Pixels per point: auto, 1, or 2 (default auto)');
  Result[6] := TFlagOption.Create('no-cursor',
    'Hide the pointer in the recording');
  Result[7] := TIntegerOption.Create('bitrate',
    'Average video bit rate in bits per second (default: derived)');
  Result[8] := TStringOption.Create('audio',
    Format('Record audio: none, system, mic, or both (default %s)',
    [AudioModeName(amNone)]));
  Result[9] := TFlagOption.Create('big-cursor',
    'Draw an enlarged pointer into the frames; display targets only');
  Result[10] := TFlagOption.Create('smooth-cursor',
    'Leave the pointer out of the movie and draw a smoothed one into '
    + 'GIF/APNG exports; display targets only');
end;

function ExportOptions: TOptionArray;
begin
  Result := nil;
  SetLength(Result, 8);
  Result[0] := TStringOption.Create('in',
    'Input movie; .mp4 or .mov (required)');
  Result[1] := TStringOption.Create('out',
    'Output file; .gif, .apng, or .mp4/.mov for a passthrough trim (required)');
  Result[2] := TIntegerOption.Create('fps',
    Format('Frames per second, %d-%d (default %d)',
    [MinGifFramesPerSecond, MaxGifFramesPerSecond,
    DefaultGifFramesPerSecond]));
  Result[3] := TIntegerOption.Create('width',
    Format('Scale to this width in pixels, %d-%d (default: the movie''s)',
    [MinGifWidth, MaxGifWidth]));
  Result[4] := TStringOption.Create('trim',
    'Seconds to keep: start,end — either side may be empty');
  Result[5] := TFlagOption.Create('no-dither',
    'Skip Floyd-Steinberg dithering; GIF only (smaller file, banding)');
  Result[6] := TStringOption.Create('cursor',
    'Pointer in the animation: as-recorded, none, smooth, or big — '
    + 'drawn from the event sidecar; .gif/.apng only');
  Result[7] := TStringOption.Create('effects',
    'Comma-separated post-recording effects: zoom, as-recorded, '
    + 'smooth-cursor, big-cursor, no-cursor, none; .gif/.apng only');
end;

function RenderOptions: TOptionArray;
begin
  Result := nil;
  SetLength(Result, 3);
  Result[0] := TStringOption.Create('in',
    'The raw take to render; .mp4 or .mov (required)');
  Result[1] := TStringOption.Create('out',
    'The deliverable to write (default: the take''s name without "-raw")');
  Result[2] := TStringOption.Create('effects',
    'Comma-separated: zoom, as-recorded, smooth-cursor, big-cursor, '
    + 'no-cursor, none (default as-recorded — whatever the take asked '
    + 'for, which for a raw take is its pointer)');
end;

// The cli package's top-level help carries lwpt's own tagline, so the
// program prints its own when no command (or help) is given — and, since
// the registry's own fallback carries that tagline too, when a command
// nobody recognises is given. AOutput is stdout for a help somebody asked
// for and stderr for one they earned by mistyping.
procedure PrintTopLevelHelp(const ARegistry: TSubcommandRegistry;
  var AOutput: Text);
var
  I: Integer;
begin
  WriteLn(AOutput, ProgramName, ' — native macOS screen recorder');
  WriteLn(AOutput);
  WriteLn(AOutput, 'usage: ', ProgramName, ' <command> [options]');
  WriteLn(AOutput);
  WriteLn(AOutput, 'commands:');
  for I := 0 to ARegistry.Count - 1 do
    WriteLn(AOutput, '  ', ARegistry.Item(I).Name:10, '  ',
      ARegistry.Item(I).Summary);
  WriteLn(AOutput);
  WriteLn(AOutput, 'run "', ProgramName,
    ' <command> --help" for command options');
end;

// Whether the first argument names something this program can run. The
// registry answers an unknown command with the cli package's OWN help,
// which introduces knips as "lightweight Pascal toolkit" and prints it to
// standard output with a usage exit code — so the check is made here
// instead, and the mistyped command gets knips's own help on stderr.
function RegistryKnows(const ARegistry: TSubcommandRegistry;
  const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to ARegistry.Count - 1 do
    if SameText(ARegistry.Item(I).Name, AName) then
      Exit(True);
  Result := False;
end;

function WantsTopLevelHelp: Boolean;
var
  First: string;
begin
  if ParamCount = 0 then
    Exit(True);
  First := LowerCase(ParamStr(1));
  Result := (First = '--help') or (First = '-h') or (First = 'help');
end;

// True when this process was started as an app bundle (Knips.app). The
// bundle's CFBundleExecutable is the binary itself: a launcher script
// that execs it breaks the LaunchServices handshake AppKit needs before
// the menu bar will adopt a status item (seen on device — the item's
// window stayed height 0 and invisible when exec'd from a script, and
// the same binary worked when the bundle pointed at it directly). So the
// bundle passes no arguments and the binary infers app mode from its
// own path.
function LaunchedFromBundle: Boolean;
begin
  Result := Pos('.app/Contents/MacOS/', ParamStr(0)) > 0;
end;

var
  Registry: TSubcommandRegistry;
  NoOptions: TOptionArray;

begin
  {$IFDEF DARWIN}
  // Refcounted strings and dynamic arrays are only updated atomically
  // once the RTL believes it is multithreaded; the capture queue makes
  // that true without a thread manager ever being installed.
  IsMultiThread := True;
  {$ENDIF}

  if (ParamCount = 1) and ((ParamStr(1) = '--version')
    or (ParamStr(1) = '-v')) then
  begin
    WriteLn(ProgramName, ' ', KnipsVersion);
    ExitCode := ExitOk;
    Exit;
  end;

  SetLength(NoOptions, 0);
  Registry := TSubcommandRegistry.Create;
  try
    {$IFDEF DARWIN}
    Registry.Add(TSubcommand.Create('app',
      'Run the menu-bar app: drag a region, click the icon to stop', '',
      @HandleApp, NoOptions));
    Registry.Add(TSubcommand.Create('record',
      'Record a display, region, or window to an .mp4/.mov file',
      '--out=<file> [--display=N|--window=ID] [--rect=x,y,w,h] [--fps=N] [--audio=system|mic|both]',
      @HandleRecord, RecordOptions));
    Registry.Add(TSubcommand.Create('export',
      'Convert a recording to a GIF or APNG, or trim it without re-encoding',
      '--in=<movie> --out=<file.gif|.apng|.mp4> [--fps=N] [--width=N] [--trim=start,end]',
      @HandleExport, ExportOptions));
    Registry.Add(TSubcommand.Create('render',
      'Render a raw take into the deliverable with its effects applied',
      '--in=<take> [--out=<file>] [--effects=zoom,smooth-cursor]',
      @HandleRender, RenderOptions));
    Registry.Add(TSubcommand.Create('displays',
      'List capturable displays', '', @HandleDisplays, NoOptions));
    Registry.Add(TSubcommand.Create('windows',
      'List capturable on-screen windows', '', @HandleWindows, NoOptions));
    Registry.Add(TSubcommand.Create('mcp',
      'Serve the recorder to an MCP client on stdin/stdout', '',
      @HandleMcp, NoOptions));
    Registry.Add(TSubcommand.Create('probe',
      'Verify the runtime-built ObjC class and framework linking', '',
      @HandleProbe, ProbeOptions));
    {$ELSE}
    Registry.Add(TSubcommand.Create('app',
      'Run the menu-bar app (macOS only)', '', @HandleUnsupported,
      NoOptions));
    Registry.Add(TSubcommand.Create('record',
      'Record a display, region, or window (macOS only)',
      '--out=<file> [--display=N|--window=ID] [--rect=x,y,w,h] [--fps=N] [--audio=system|mic|both]',
      @HandleUnsupported, RecordOptions));
    Registry.Add(TSubcommand.Create('export',
      'Convert a recording to a GIF or APNG, or trim it (macOS only)',
      '--in=<movie> --out=<file.gif|.apng|.mp4> [--fps=N] [--width=N] [--trim=start,end]',
      @HandleExportUnsupported, ExportOptions));
    Registry.Add(TSubcommand.Create('render',
      'Render a raw take into the deliverable (macOS only)',
      '--in=<take> [--out=<file>] [--effects=zoom,smooth-cursor]',
      @HandleUnsupported, RenderOptions));
    Registry.Add(TSubcommand.Create('displays',
      'List capturable displays (macOS only)', '', @HandleUnsupported,
      NoOptions));
    Registry.Add(TSubcommand.Create('windows',
      'List capturable on-screen windows (macOS only)', '',
      @HandleUnsupported, NoOptions));
    Registry.Add(TSubcommand.Create('mcp',
      'Serve the recorder to an MCP client on stdin/stdout', '',
      @HandleMcp, NoOptions));
    Registry.Add(TSubcommand.Create('probe',
      'Verify the runtime-built ObjC class and framework linking (macOS only)',
      '', @HandleUnsupported, NoOptions));
    {$ENDIF}
    if (ParamCount = 0) and LaunchedFromBundle then
      {$IFDEF DARWIN}
      ExitCode := HandleApp(nil, NoOptions)
      {$ELSE}
      ExitCode := ExitUnsupported
      {$ENDIF}
    else if WantsTopLevelHelp then
    begin
      PrintTopLevelHelp(Registry, Output);
      ExitCode := ExitOk;
    end
    else if not RegistryKnows(Registry, ParamStr(1)) then
    begin
      WriteLn(ErrOutput, ProgramName, ': unknown command "', ParamStr(1),
        '"');
      WriteLn(ErrOutput);
      PrintTopLevelHelp(Registry, ErrOutput);
      Flush(ErrOutput);
      ExitCode := ExitUsage;
    end
    else
      ExitCode := Registry.Run(ProgramName);
  finally
    Registry.Free;
  end;
end.

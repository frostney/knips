program opname;

// opname — a native macOS screen recorder in FreePascal.
//
//   opname record --out=demo.mp4 [--display=N | --window=ID] [--rect=x,y,w,h]
//                 [--fps=30] [--scale=auto|1|2] [--no-cursor] [--bitrate=N]
//   opname export --in=demo.mp4 --out=demo.gif [--fps=20] [--width=N]
//                 [--trim=start,end] [--no-dither]
//   opname displays              list capturable displays
//   opname windows               list capturable on-screen windows
//   opname probe                 verify the ObjC runtime + framework path
//
// Built and tested with lwpt. Capture is ScreenCaptureKit, the file is
// written by AVAssetWriter, and the GIF encoder is pure Pascal; see
// docs/architecture.md.

{$I Shared.inc}

uses
  {$IFDEF DARWIN}
  cmem,        // libc heap: thread-safe without cthreads (prototype invariant)
  Opname.ThreadManager, // pthread-backed RTL locks/events; no thread creation
  BaseUnix,
  ctypes,
  objc,        // the id type for the probe; the program is not in ObjC mode
  {$ENDIF}
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Subcommands,
  {$IFDEF DARWIN}
  Opname.Capture.ShareableContent,
  Opname.Capture.Stream,
  Opname.Export.GifPipeline,
  Opname.Export.MovieWriter,
  Opname.ObjC.Runtime,
  Opname.Recording,
  {$ENDIF}
  Opname.Options;

const
  ProgramName = 'opname';
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
  Rect, Scale: string;
begin
  Result := False;
  ARecording := DefaultRecordingOptions;
  ARecording.OutputPath := StringValue(AOptions, 'out', '');
  ARecording.DisplayIndex := IntegerValue(AOptions, 'display', -1);
  ARecording.WindowID := Cardinal(IntegerValue(AOptions, 'window', 0));
  if FlagPresent(AOptions, 'window') then
    ARecording.TargetKind := ctkWindow;
  ARecording.FramesPerSecond := IntegerValue(AOptions, 'fps',
    DefaultFramesPerSecond);
  ARecording.BitRate := IntegerValue(AOptions, 'bitrate', 0);
  ARecording.ShowsCursor := not FlagPresent(AOptions, 'no-cursor');

  Scale := LowerCase(StringValue(AOptions, 'scale', 'auto'));
  if Scale = 'auto' then
    ARecording.Scale := ScaleAuto
  else if not TryStrToInt(Scale, ARecording.Scale) then
  begin
    AError := '--scale must be auto, 1, or 2';
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
  Trim: string;
begin
  Result := False;
  AExport := DefaultExportOptions;
  AExport.InputPath := StringValue(AOptions, 'in', '');
  AExport.OutputPath := StringValue(AOptions, 'out', '');
  AExport.FramesPerSecond := IntegerValue(AOptions, 'fps',
    DefaultGifFramesPerSecond);
  AExport.Width := IntegerValue(AOptions, 'width', GifWidthFromSource);
  AExport.Dither := not FlagPresent(AOptions, 'no-dither');

  Trim := StringValue(AOptions, 'trim', '');
  if Trim <> '' then
    if not ParseTrimRange(Trim, AExport.TrimStartSeconds,
      AExport.TrimEndSeconds, AExport.HasTrimEnd) then
    begin
      AError := '--trim expects start,end in seconds; either side may be '
        + 'empty (--trim=2, or --trim=,5)';
      Exit;
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

function HandleRecord(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Recording: TRecordingOptions;
  Session: TRecordingSession;
  Error: string;
begin
  if not BuildRecordingOptions(AOptions, Recording, Error) then
  begin
    WriteLn(ProgramName, ' record: ', Error);
    Exit(ExitUsage);
  end;
  InstallStopSignals;
  Session := TRecordingSession.Create(Recording);
  try
    if not Session.Run(Error) then
    begin
      WriteLn(ProgramName, ' record: ', Error);
      Exit(ExitFailure);
    end;
    WriteLn(Format('wrote %s: %dx%d, %.1fs, %d frames (%d dropped, %d failed)',
      [Session.Report.OutputPath, Session.Report.PixelWidth,
      Session.Report.PixelHeight, Session.Report.DurationSeconds,
      Session.Report.AppendedFrames, Session.Report.DroppedFrames,
      Session.Report.FailedAppends]));
    Result := ExitOk;
  finally
    Session.Free;
  end;
end;

function HandleExport(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Options: TExportOptions;
  Session: TGifExportSession;
  Error: string;
begin
  if not BuildExportOptions(AOptions, Options, Error) then
  begin
    WriteLn(ProgramName, ' export: ', Error);
    Exit(ExitUsage);
  end;
  Session := TGifExportSession.Create(Options);
  try
    if not Session.Run(Error) then
    begin
      WriteLn(ProgramName, ' export: ', Error);
      Exit(ExitFailure);
    end;
    WriteLn(Format('wrote %s: %dx%d, %d frames, %.1fs, %d kB (%d colours)',
      [Session.Report.OutputPath, Session.Report.PixelWidth,
      Session.Report.PixelHeight, Session.Report.FramesWritten,
      Session.Report.DurationSeconds, Session.Report.OutputBytes div 1024,
      Session.Report.PaletteColors]));
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
      WriteLn(ProgramName, ' displays: ', E.Message);
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
      WriteLn(ProgramName, ' windows: ', E.Message);
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
      WriteLn(Format('%-10d  %5dx%-5d   %-22s %s', [Window.WindowID,
        Window.Width, Window.Height, Copy(Window.ApplicationName, 1, 22),
        Window.Title]));
    end;
  finally
    Content.Free;
  end;
  Result := ExitOk;
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
  Error: string;
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

  TempPath := IncludeTrailingPathDelimiter(GetTempDir) + 'opname-probe.mp4';
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
    WriteLn(ProgramName, ' record: ', Error);
    Exit(ExitUsage);
  end;
  WriteLn(ProgramName, ': screen capture is macOS-only in this build');
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
    WriteLn(ProgramName, ' export: ', Error);
    Exit(ExitUsage);
  end;
  WriteLn(ProgramName, ': reading movies is macOS-only in this build');
  Result := ExitUnsupported;
end;

{$ENDIF}

// Option objects are owned by the registry once the subcommand is added.
function RecordOptions: TOptionArray;
begin
  SetLength(Result, 8);
  Result[0] := TStringOption.Create('out',
    'Output file; .mp4 or .mov (required)');
  Result[1] := TIntegerOption.Create('display',
    'Display index from `opname displays` (default: main)');
  Result[2] := TIntegerOption.Create('window',
    'Record one window by id from `opname windows`');
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
end;

function ExportOptions: TOptionArray;
begin
  SetLength(Result, 6);
  Result[0] := TStringOption.Create('in',
    'Input movie; .mp4 or .mov (required)');
  Result[1] := TStringOption.Create('out',
    'Output file; .gif (required)');
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
    'Skip Floyd-Steinberg dithering (smaller file, visible banding)');
end;

// The cli package's top-level help carries lwpt's own tagline, so the
// program prints its own when no command (or help) is given.
procedure PrintTopLevelHelp(const ARegistry: TSubcommandRegistry);
var
  I: Integer;
begin
  WriteLn(ProgramName, ' — native macOS screen recorder');
  WriteLn;
  WriteLn('usage: ', ProgramName, ' <command> [options]');
  WriteLn;
  WriteLn('commands:');
  for I := 0 to ARegistry.Count - 1 do
    WriteLn('  ', ARegistry.Item(I).Name:10, '  ', ARegistry.Item(I).Summary);
  WriteLn;
  WriteLn('run "', ProgramName, ' <command> --help" for command options');
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
    WriteLn(ProgramName, ' ', OpnameVersion);
    ExitCode := ExitOk;
    Exit;
  end;

  SetLength(NoOptions, 0);
  Registry := TSubcommandRegistry.Create;
  try
    {$IFDEF DARWIN}
    Registry.Add(TSubcommand.Create('record',
      'Record a display, region, or window to an .mp4/.mov file',
      '--out=<file> [--display=N|--window=ID] [--rect=x,y,w,h] [--fps=N]',
      @HandleRecord, RecordOptions));
    Registry.Add(TSubcommand.Create('export',
      'Convert a recording to an animated GIF',
      '--in=<movie> --out=<file.gif> [--fps=N] [--width=N] [--trim=start,end]',
      @HandleExport, ExportOptions));
    Registry.Add(TSubcommand.Create('displays',
      'List capturable displays', '', @HandleDisplays, NoOptions));
    Registry.Add(TSubcommand.Create('windows',
      'List capturable on-screen windows', '', @HandleWindows, NoOptions));
    Registry.Add(TSubcommand.Create('probe',
      'Verify the runtime-built ObjC class and framework linking', '',
      @HandleProbe, NoOptions));
    {$ELSE}
    Registry.Add(TSubcommand.Create('record',
      'Record a display, region, or window (macOS only)',
      '--out=<file> [--display=N|--window=ID] [--rect=x,y,w,h] [--fps=N]',
      @HandleUnsupported, RecordOptions));
    Registry.Add(TSubcommand.Create('export',
      'Convert a recording to an animated GIF (macOS only)',
      '--in=<movie> --out=<file.gif> [--fps=N] [--width=N] [--trim=start,end]',
      @HandleExportUnsupported, ExportOptions));
    Registry.Add(TSubcommand.Create('displays',
      'List capturable displays (macOS only)', '', @HandleUnsupported,
      NoOptions));
    Registry.Add(TSubcommand.Create('windows',
      'List capturable on-screen windows (macOS only)', '',
      @HandleUnsupported, NoOptions));
    Registry.Add(TSubcommand.Create('probe',
      'Verify the runtime-built ObjC class and framework linking (macOS only)',
      '', @HandleUnsupported, NoOptions));
    {$ENDIF}
    if WantsTopLevelHelp then
    begin
      PrintTopLevelHelp(Registry);
      ExitCode := ExitOk;
    end
    else
      ExitCode := Registry.Run(ProgramName);
  finally
    Registry.Free;
  end;
end.

program knips;

// knips — a native macOS screen recorder in FreePascal.
//
//   knips app                   menu-bar app: drag a region, click to stop
//   knips record --out=demo.mp4 [--display=N | --window=ID] [--rect=x,y,w,h]
//                 [--fps=30] [--scale=auto|1|2] [--no-cursor] [--bitrate=N]
//                 [--audio=none|system|mic|both]
//   knips export --in=demo.mp4 --out=demo.gif|.apng [--fps=20] [--width=N]
//                 [--trim=start,end] [--no-dither]
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

uses
  {$IFDEF DARWIN}
  cmem,        // libc heap: thread-safe without cthreads (prototype invariant)
  Knips.ThreadManager, // pthread-backed RTL locks/events; no thread creation
  BaseUnix,
  ctypes,
  objc,        // the id type for the probe; the program is not in ObjC mode
  {$ENDIF}
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Subcommands,
  {$IFDEF DARWIN}
  Knips.App,
  Knips.App.Border,
  Knips.App.Camera,
  Knips.App.Overlay,
  Knips.App.Playback,
  Knips.Capture.ShareableContent,
  Knips.Capture.Stream,
  Knips.Export.MovieTrim,
  Knips.Export.MovieWriter,
  Knips.Export.Pipeline,
  Knips.ObjC.Runtime,
  Knips.Recording,
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
  begin
    if not ParseTrimRange(Trim, AExport.TrimStartSeconds,
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

function HandleRecord(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Recording: TRecordingOptions;
  Session: TRecordingSession;
  Error: string;
  Audio: string;
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
    WriteLn(Format('wrote %s: %dx%d, %.1fs, %d frames (%d dropped, %d failed)%s',
      [Session.Report.OutputPath, Session.Report.PixelWidth,
      Session.Report.PixelHeight, Session.Report.DurationSeconds,
      Session.Report.AppendedFrames, Session.Report.DroppedFrames,
      Session.Report.FailedAppends, Audio]));
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
    WriteLn(ProgramName, ' app: ', Error);
    Exit(ExitFailure);
  end;
  Result := ExitOk;
end;

// A passthrough trim: same samples, new container, no decode at all.
function HandleTrimExport(const AOptions: TExportOptions;
  const AParsed: TOptionArray): Integer;
var
  Session: TMovieTrimSession;
  Error: string;
begin
  if FlagPresent(AParsed, 'fps') or FlagPresent(AParsed, 'width')
    or FlagPresent(AParsed, 'no-dither') then
  begin
    WriteLn(ErrOutput, ProgramName, ' export: --fps, --width and '
      + '--no-dither do not apply to a passthrough trim and are ignored');
    Flush(ErrOutput);
  end;
  Session := TMovieTrimSession.Create(AOptions);
  try
    if not Session.Run(Error) then
    begin
      WriteLn(ProgramName, ' export: ', Error);
      Exit(ExitFailure);
    end;
    WriteLn(Format('wrote %s: %.2fs–%.2fs of %.2fs, %d kB (streams copied)',
      [Session.Report.OutputPath, Session.Report.StartSeconds,
      Session.Report.EndSeconds, Session.Report.SourceDurationSeconds,
      Session.Report.OutputBytes div 1024]));
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
  Error, Warning, Palette: string;
begin
  if not BuildExportOptions(AOptions, Options, Error) then
  begin
    WriteLn(ProgramName, ' export: ', Error);
    Exit(ExitUsage);
  end;
  if Options.Format = efMovie then
    Exit(HandleTrimExport(Options, AOptions));
  Session := TExportSession.Create(Options);
  try
    if not Session.Run(Error) then
    begin
      WriteLn(ProgramName, ' export: ', Error);
      Exit(ExitFailure);
    end;
    if Session.Report.Format = efGif then
    begin
      Palette := Format(' (%d colours', [Session.Report.PaletteColors]);
      if not Session.Report.ExactPalette then
        Palette := Palette + ', 6-bit histogram';
      Palette := Palette + ')';
    end
    else
      Palette := ' (truecolour)';
    WriteLn(Format('wrote %s: %dx%d, %d frames, %.1fs, %d kB%s',
      [Session.Report.OutputPath, Session.Report.PixelWidth,
      Session.Report.PixelHeight, Session.Report.FramesWritten,
      Session.Report.DurationSeconds, Session.Report.OutputBytes div 1024,
      Palette]));
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
  TargetSelectors: array[0..20] of string = (
    'recordRegion:', 'recordDisplay:', 'recordWindow:', 'recordLastRegion:',
    'toggleSystemAudio:', 'stopRecording:', 'cancelSelection:',
    'revealRecordings:', 'quitKnips:', 'timerFired:', 'startPending:',
    'stopPending:', 'menuNeedsUpdate:', 'exportGif:', 'revealRecording:',
    'closePlayback:', 'toggleCamera:', 'restoreCamera:',
    'toggleZoomOnClick:', 'toggleFollowMouse:', 'liveTick:');
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
  // reports and everybody blames on themselves.
  if not HasMethod(CameraViewClassName, 'acceptsFirstMouse:') then
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
  WriteLn('runtime classes ', AppTargetClassName, ', ',
    OverlayViewClassName, ', ', OverlayWindowClassName, ', ',
    CameraViewClassName, ', ', BorderViewClassName, ', ',
    PlaybackDelegateClassName, ': registered and answering');
  Result := True;
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

  // Informational, not a gate: microphone capture is macOS 15+, the
  // project floor is 13. record --audio=mic refuses cleanly where this
  // prints unavailable.
  if StreamSupportsMicrophone then
    WriteLn('microphone capture: supported')
  else
    WriteLn('microphone capture: unavailable (needs macOS 15+)');

  // Likewise informational. The header puts updateConfiguration: at
  // macOS 12.3, below the project floor, so this should always say
  // supported; the app turns Zoom on Click and Follow Mouse off for a
  // recording rather than failing it where it does not.
  if StreamSupportsLiveUpdate then
    WriteLn('live source-rect updates: supported')
  else
    WriteLn('live source-rect updates: unavailable (Zoom on Click and '
      + 'Follow Mouse will be off)');

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

  TempPath := IncludeTrailingPathDelimiter(GetTempDir) + 'knips-probe.mp4';
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
function RecordOptions: TOptionArray;
begin
  SetLength(Result, 9);
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
end;

function ExportOptions: TOptionArray;
begin
  SetLength(Result, 6);
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
    Registry.Add(TSubcommand.Create('displays',
      'List capturable displays', '', @HandleDisplays, NoOptions));
    Registry.Add(TSubcommand.Create('windows',
      'List capturable on-screen windows', '', @HandleWindows, NoOptions));
    Registry.Add(TSubcommand.Create('mcp',
      'Serve the recorder to an MCP client on stdin/stdout', '',
      @HandleMcp, NoOptions));
    Registry.Add(TSubcommand.Create('probe',
      'Verify the runtime-built ObjC class and framework linking', '',
      @HandleProbe, NoOptions));
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
      PrintTopLevelHelp(Registry);
      ExitCode := ExitOk;
    end
    else
      ExitCode := Registry.Run(ProgramName);
  finally
    Registry.Free;
  end;
end.

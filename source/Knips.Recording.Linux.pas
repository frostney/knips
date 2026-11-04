unit Knips.Recording.Linux;

// The Linux recording session: the X screen (or a rectangle of it) into an
// APNG, frame by frame, on a clock.
//
// ADR-0005 gives each platform its own session type, so this is not
// TRecordingSession and does not pretend to be one: that class is
// ScreenCaptureKit and AVAssetWriter from top to bottom. What the two share
// is the options record, the neutral APNG encoder and the `knips record`
// command line, not a base class.
//
// How a take is made:
//
//   - A grab is due every 1/fps seconds on a monotonic clock. A grab that
//     is late because the encoder was busy does not make up the time in a
//     burst: the frames whose moment has passed are skipped and counted
//     (Knips.Recording.LinuxPlan.NextFrameIndex), so playback is real time
//     with fewer frames instead of a fast-forwarded one.
//   - Each frame is held until the next grab, then written with the time
//     it was actually on screen as its delay, because an APNG carries a
//     delay per frame and a timer that wobbles would otherwise bake the
//     wobble into the file. The last frame is held until the stop.
//   - Output goes to a uniquely named temporary beside the target and is
//     renamed over it only when the file is whole (Finish has written
//     IEND and patched the frame count). A SIGKILL leaves the temporary,
//     named so that it is plainly not a finished take; nothing recovers it
//     yet. Every other way out removes it or turns it into the take.
//   - Ctrl-C and SIGTERM stop the recording and keep it. A second one
//     while the file is being finished removes the temporary and exits.
//   - If the X connection is lost mid-recording Xlib calls an IO error
//     handler and then exit(). The handler installed here finishes the file
//     first, so what was recorded is a valid APNG, and then ends the
//     process with the failure exit code. A protocol error on a grab (the
//     screen was resized under us) is the same outcome by a different
//     route.
//
// Only the thread that calls Run touches X.

{$I Knips.inc}

interface

{$IFDEF LINUX}

uses
  Classes,
  SysUtils,

  Knips.Capture.X11.Dl,
  Knips.Export.Apng,
  Knips.Options,
  Knips.Recording.LinuxPlan;

type
  // What a Linux recording reports. The names that also exist on
  // Knips.Recording.TRecordingReport (OutputPath, PixelWidth, PixelHeight,
  // Scale, FramesPerSecond, AppendedFrames, DroppedFrames, FailedAppends,
  // DurationSeconds) are spelled the same and mean the same, so the
  // command's summary line is one format string on both platforms. That
  // record is macOS-only and carries audio and ScreenCaptureKit fields
  // that mean nothing here; moving it to a neutral unit is the follow-up
  // for when a Mac can verify the change (ADR-0005, item 2).
  TLinuxRecordingReport = record
    OutputPath: string;
    PixelWidth: Integer;
    PixelHeight: Integer;
    Scale: Integer;
    FramesPerSecond: Integer;
    AppendedFrames: Int64;
    DroppedFrames: Int64;
    FailedAppends: Int64;
    DurationSeconds: Double;
    // Linux only.
    FileBytes: Int64;
    // True once the file at OutputPath is a complete APNG, which is also
    // true of a take cut short by an error.
    Committed: Boolean;
    // Why the take ended early, or '' when it ended on a stop request.
    EndedEarly: string;
    // The screen has a pointer and the recording does not draw it.
    PointerNotDrawn: Boolean;
  end;

  TLinuxRecordingSession = class
  private
    FOptions: TRecordingOptions;
    FReport: TLinuxRecordingReport;
    FGrabber: TX11Grabber;
    FEncoder: TApngEncoder;
    FTemporaryPath: string;
    FHeld: TBytes;
    FHeldBytes: Integer;
    FHeldAtUs: Int64;
    FHasHeld: Boolean;
    FStartUs: Int64;
    FFirstGrabUs: Int64;
    FFinished: Boolean;
    function PrepareOutput(out AError: string): Boolean;
    function WriteHeld(AUntilUs: Int64; out AError: string): Boolean;
    function FinishTake(AStopUs: Int64; out AError: string): Boolean;
    procedure Abandon;
  public
    constructor Create(const AOptions: TRecordingOptions);
    destructor Destroy; override;
    // Records until a stop signal. True when the take ended on one. False
    // with AError when it did not; Report.Committed then says whether a
    // partial take was kept.
    function Run(out AError: string): Boolean;
    // Called from the Xlib IO error handler only.
    procedure FinishAfterLostDisplay;
    property Report: TLinuxRecordingReport read FReport;
  end;

// SIGINT and SIGTERM request a stop instead of killing the process.
procedure InstallLinuxStopSignals;

// True once a stop has been requested.
function LinuxStopRequested: Boolean;

// Why APath cannot be written, or '' when it can: refuses a symbolic link
// whatever it points at, the same rule and words as the macOS side.
function LinuxOutputPathRefusal(const APath: string): string;

{$ENDIF}

implementation

{$IFDEF LINUX}

uses
  BaseUnix,
  ctypes,

  Knips.Export.Bitmap,
  Linux,
  UnixType;

const
  ExitFailureCode = 2;
  // A second stop request this long after the first abandons the take.
  GiveUpAfterMicros = 1000000;
  // How long one wait for the next deadline is. A stop request is noticed
  // within this, and 5 ms is well under one frame at any allowed rate but
  // the very highest.
  WaitSliceMilliseconds = 5;

var
  StopFlag: Boolean = False;
  // When the first stop request arrived. timeout(1) and shells deliver one
  // signal to the child and another to its whole process group, so a
  // second request only counts as "give up" once the first has had a
  // moment to be honoured.
  StopRequestedAtMicros: Int64 = 0;
  // The temporary's name as a C string, for the second-signal handler,
  // which may call only async-signal-safe functions (unlink and _exit).
  TemporaryPathC: array[0..4095] of AnsiChar;
  ActiveSession: TLinuxRecordingSession = nil;

procedure c_exit(ACode: cint); cdecl; external name '_exit';

function NowMicros: Int64;
var
  Spec: timespec;
begin
  clock_gettime(CLOCK_MONOTONIC, @Spec);
  Result := Int64(Spec.tv_sec) * 1000000 + Int64(Spec.tv_nsec) div 1000;
end;

procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  if StopFlag then
  begin
    // Second request, a second or more after the first, while the file is
    // still being finished: give up on it.
    if (NowMicros - StopRequestedAtMicros >= GiveUpAfterMicros) then
    begin
      if TemporaryPathC[0] <> #0 then
        FpUnlink(PAnsiChar(@TemporaryPathC[0]));
      c_exit(ExitFailureCode);
    end;
    Exit;
  end;
  StopRequestedAtMicros := NowMicros;
  StopFlag := True;
end;

procedure InstallLinuxStopSignals;
var
  Action, Previous: SigActionRec;
begin
  FillChar(Action, SizeOf(Action), 0);
  Action.sa_handler := SigActionHandler(@HandleStopSignal);
  FpSigAction(SIGINT, @Action, @Previous);
  FpSigAction(SIGTERM, @Action, @Previous);
end;

function LinuxStopRequested: Boolean;
begin
  Result := StopFlag;
end;

function LinuxOutputPathRefusal(const APath: string): string;
var
  Info: Stat;
begin
  Result := '';
  if APath = '' then
    Exit;
  // lstat, never stat: the question is what the NAME is, not what it
  // leads to.
  if FpLStat(APath, Info) <> 0 then
    Exit;
  if FpS_ISLNK(Info.st_mode) then
    Result := APath + ' is a symbolic link; knips will not write through '
      + 'one: pass the file it points at instead'
  else if FpS_ISDIR(Info.st_mode) then
    Result := APath + ' is a directory';
end;

// Xlib's IO error handler: the X connection is gone and the process is
// about to be exited by Xlib. Finish the file, say so, and end the
// process here. Must not return and must not call Xlib.
function LostDisplayHandler(ADisplay: Pointer): cint; cdecl;
begin
  if ActiveSession <> nil then
    ActiveSession.FinishAfterLostDisplay;
  Halt(ExitFailureCode);
  Result := 0;
end;

{ TLinuxRecordingSession }

constructor TLinuxRecordingSession.Create(const AOptions: TRecordingOptions);
begin
  inherited Create;
  FOptions := AOptions;
  FReport := Default(TLinuxRecordingReport);
  FReport.OutputPath := AOptions.OutputPath;
  FReport.Scale := 1;
  FReport.FramesPerSecond := AOptions.FramesPerSecond;
  FGrabber := TX11Grabber.Create;
end;

destructor TLinuxRecordingSession.Destroy;
begin
  Abandon;
  if ActiveSession = Self then
    ActiveSession := nil;
  FGrabber.Free;
  inherited Destroy;
end;

// Drops an unfinished take: closes the encoder and removes the temporary.
// A no-op once the take has been committed.
procedure TLinuxRecordingSession.Abandon;
begin
  FEncoder.Free;
  FEncoder := nil;
  if (FTemporaryPath <> '') and not FFinished then
    DeleteFile(FTemporaryPath);
  FTemporaryPath := '';
  TemporaryPathC[0] := #0;
end;

function TLinuxRecordingSession.PrepareOutput(out AError: string): Boolean;
var
  Directory, Nonce: string;
  Attempt: Integer;
begin
  Result := False;
  AError := LinuxOutputPathRefusal(FOptions.OutputPath);
  if AError <> '' then
    Exit;
  Directory := ExtractFileDir(ExpandFileName(FOptions.OutputPath));
  if not DirectoryExists(Directory) then
  begin
    AError := 'the directory ' + Directory + ' does not exist';
    Exit;
  end;
  Randomize;
  for Attempt := 1 to 20 do
  begin
    Nonce := LowerCase(IntToHex(Random(High(Word) + 1), 4)
      + IntToHex(Random(High(Word) + 1), 4));
    FTemporaryPath := LinuxTemporaryPath(FOptions.OutputPath,
      Integer(FpGetPid), Nonce);
    if not FileExists(FTemporaryPath) then
      Break;
    FTemporaryPath := '';
  end;
  if FTemporaryPath = '' then
  begin
    AError := 'could not find an unused temporary name beside '
      + FOptions.OutputPath;
    Exit;
  end;
  if Length(FTemporaryPath) >= SizeOf(TemporaryPathC) then
  begin
    AError := 'the output path is too long';
    FTemporaryPath := '';
    Exit;
  end;
  StrPCopy(PAnsiChar(@TemporaryPathC[0]), FTemporaryPath);
  Result := True;
end;

// Writes the held frame with the time it was on screen: from its own
// grab to AUntilUs.
function TLinuxRecordingSession.WriteHeld(AUntilUs: Int64;
  out AError: string): Boolean;
begin
  Result := True;
  AError := '';
  if not FHasHeld then
    Exit;
  Result := FEncoder.AddFrame(@FHeld[0], FGrabber.BytesPerLine,
    DelayMilliseconds(FHeldAtUs, AUntilUs), AError);
  if not Result then
    Inc(FReport.FailedAppends);
end;

// Writes the last held frame, closes the file and puts it at the output
// path. Shared by a normal stop and the two early endings.
function TLinuxRecordingSession.FinishTake(AStopUs: Int64;
  out AError: string): Boolean;
var
  Temporary: string;
  Info: Stat;
begin
  Result := False;
  AError := '';
  if FFinished or (FEncoder = nil) then
    Exit;
  if not WriteHeld(AStopUs, AError) then
    Exit;
  FHasHeld := False;
  if not FEncoder.Finish(AError) then
    Exit;
  FReport.AppendedFrames := FEncoder.FrameCount;
  FEncoder.Free;
  FEncoder := nil;
  Temporary := FTemporaryPath;
  // rename(2) replaces the destination atomically on one filesystem; there
  // is deliberately no delete first.
  if FpRename(Temporary, FOptions.OutputPath) <> 0 then
  begin
    AError := Format('could not move the finished recording to %s (errno %d)',
      [FOptions.OutputPath, fpgeterrno]);
    Exit;
  end;
  FFinished := True;
  FTemporaryPath := '';
  TemporaryPathC[0] := #0;
  if FpStat(FOptions.OutputPath, Info) = 0 then
    FReport.FileBytes := Info.st_size;
  if FFirstGrabUs > 0 then
    FReport.DurationSeconds := (AStopUs - FFirstGrabUs) / 1000000;
  FReport.Committed := True;
  Result := True;
end;

function TLinuxRecordingSession.Run(out AError: string): Boolean;
var
  Region: TCaptureRegion;
  IntervalUs, DeadlineUs, GrabbedAtUs, Dropped: Int64;
  LastIndex, NextIndex, Remaining: Int64;
  FinishError: string;
begin
  Result := False;
  AError := '';
  FReport.PointerNotDrawn := FOptions.ShowsCursor;
  if not FGrabber.Open('', AError) then
    Exit;
  if not ResolveLinuxCaptureRect(FOptions, FGrabber.ScreenWidth,
    FGrabber.ScreenHeight, Region, AError) then
    Exit;
  if not FGrabber.Prepare(Region.Left, Region.Top, Region.Width,
    Region.Height, AError) then
    Exit;
  FReport.PixelWidth := Region.Width;
  FReport.PixelHeight := Region.Height;
  if not PrepareOutput(AError) then
    Exit;
  FEncoder := TApngEncoder.Create(Region.Width, Region.Height,
    LinuxDelayDenominator);
  if not FEncoder.Open(FTemporaryPath, AError) then
  begin
    Abandon;
    Exit;
  end;
  SetLength(FHeld, Int64(FGrabber.BytesPerLine) * Region.Height);
  FHeldBytes := Length(FHeld);

  // From here an IO error ends the process through our handler, which
  // needs the session to finish the file.
  ActiveSession := Self;
  SetX11IOErrorHandler(@LostDisplayHandler);

  IntervalUs := FrameIntervalMicros(FOptions.FramesPerSecond);
  FStartUs := NowMicros;
  LastIndex := -1;
  while not StopFlag do
  begin
    NextIndex := NextFrameIndex(FStartUs, IntervalUs, LastIndex, NowMicros,
      Dropped);
    DeadlineUs := FrameDeadlineMicros(FStartUs, IntervalUs, NextIndex);
    // Wait for the deadline in short slices so a stop is noticed quickly.
    repeat
      Remaining := (DeadlineUs - NowMicros) div 1000;
      if (Remaining <= 0) or StopFlag then
        Break;
      if Remaining > WaitSliceMilliseconds then
        Remaining := WaitSliceMilliseconds;
      Sleep(Integer(Remaining));
    until False;
    if StopFlag then
      Break;
    Inc(FReport.DroppedFrames, Dropped);
    GrabbedAtUs := NowMicros;
    if not FGrabber.Grab(AError) then
    begin
      FReport.EndedEarly := AError;
      Break;
    end;
    if FFirstGrabUs = 0 then
      FFirstGrabUs := GrabbedAtUs;
    if not WriteHeld(GrabbedAtUs, AError) then
    begin
      // The file cannot be written (a full disk, most likely): nothing
      // here is worth keeping.
      Abandon;
      Exit;
    end;
    Move(FGrabber.Pixels^, FHeld[0], FHeldBytes);
    FHeldAtUs := GrabbedAtUs;
    FHasHeld := True;
    LastIndex := NextIndex;
  end;

  if FFinished then
    Exit;
  if not FinishTake(NowMicros, FinishError) then
  begin
    Abandon;
    if AError = '' then
      AError := FinishError;
    Exit;
  end;
  if FReport.EndedEarly <> '' then
  begin
    AError := FReport.EndedEarly + '; kept the ' + IntToStr(FReport.AppendedFrames)
      + ' frames recorded so far in ' + FReport.OutputPath;
    Exit;
  end;
  Result := True;
end;

procedure TLinuxRecordingSession.FinishAfterLostDisplay;
var
  Error: string;
begin
  if FFinished or (FEncoder = nil) then
    Exit;
  if FinishTake(NowMicros, Error) then
    WriteLn(ErrOutput, 'knips record: the X display went away; kept the ',
      FReport.AppendedFrames, ' frames recorded so far in ',
      FReport.OutputPath, ' (', FReport.DurationSeconds:0:1, 's)')
  else
  begin
    WriteLn(ErrOutput, 'knips record: the X display went away and the '
      + 'recording could not be finished: ', Error);
    Abandon;
  end;
  Flush(ErrOutput);
end;

{$ENDIF}

end.

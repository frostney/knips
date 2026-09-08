unit Knips.Export.MovieTrim;

// The passthrough trim: `knips export --in=a.mp4 --out=b.mp4 --trim=s,e`
// writes the same coded samples into a new container between two stamps.
// Nothing is decoded and nothing is re-encoded, so the output is bit-for-
// bit the source's own H.264 — which is the point, since a recording that
// has been through VideoToolbox once should not go through it again just
// to lose its first two seconds.
//
// AVAssetExportSession with AVAssetExportPresetPassthrough is the whole
// mechanism; the work here is asking for the right range and waiting for
// an asynchronous export from a program with no run loop of its own. The
// wait is the same shape as TMovieWriter.Finish: a global completion
// procedure sets a flag, and the main thread pumps CFRunLoopRunInMode in
// slices until it does.
//
// Only movie-to-movie is possible: passthrough copies samples, so there
// is no path from a GIF and none to one. Knips.Options refuses the rest
// before this unit is reached.

{$I Knips.inc}

interface

{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cblocks}
{$modeswitch cvar}

uses
  SysUtils,

  CocoaAll,
  Knips.Capture.CoreMedia,
  Knips.Export.Atomic,
  Knips.Export.MovieReader,
  Knips.Options,
  MacOSAll;

{$linkframework AVFoundation}
{$linkframework CoreMedia}

const
  // AVAssetExportSessionStatus, verified against AVAssetExportSession.h.
  // Transcribed whole though only three of the six are compared against;
  // the rest are documentary, as in Knips.Export.MovieWriter.
  AVAssetExportSessionStatusUnknown = 0;
  AVAssetExportSessionStatusWaiting = 1;
  AVAssetExportSessionStatusExporting = 2;
  AVAssetExportSessionStatusCompleted = 3;
  AVAssetExportSessionStatusFailed = 4;
  AVAssetExportSessionStatusCancelled = 5;

type
  TAVExportCompletionBlock = reference to procedure; cdecl; cblock;

  AVAssetExportSession = objcclass external (NSObject)
    class function ExportSessionWithAsset_presetName(AAsset: AVAsset;
      APresetName: NSString): id;
      message 'exportSessionWithAsset:presetName:';
    procedure SetOutputURL(AOutputURL: NSURL); message 'setOutputURL:';
    procedure SetOutputFileType(AOutputFileType: NSString);
      message 'setOutputFileType:';
    procedure SetShouldOptimizeForNetworkUse(AOptimize: ObjCBOOL);
      message 'setShouldOptimizeForNetworkUse:';
    procedure SetTimeRange(ATimeRange: CMTimeRange); message 'setTimeRange:';
    procedure ExportAsynchronouslyWithCompletionHandler(
      AHandler: TAVExportCompletionBlock);
      message 'exportAsynchronouslyWithCompletionHandler:';
    procedure CancelExport; message 'cancelExport';
    function Status: NSInteger; message 'status';
    function Error: NSError; message 'error';
  end;

var
  AVAssetExportPresetPassthrough: NSString; cvar; external;
  AVFileTypeMPEG4: NSString; cvar; external;
  AVFileTypeQuickTimeMovie: NSString; cvar; external;

type
  TMovieTrimReport = record
    InputPath: string;
    OutputPath: string;
    SourceDurationSeconds: Double;
    StartSeconds: Double;
    EndSeconds: Double;
    // What was asked for; the file's own duration may differ by a frame.
    DurationSeconds: Double;
    OutputBytes: Int64;
  end;

  TMovieTrimSession = class
  private
    FOptions: TExportOptions;
    FReport: TMovieTrimReport;
    function FileTypeString: NSString;
  public
    constructor Create(const AOptions: TExportOptions);
    // False with a one-line message on any failure; a partial output is
    // removed.
    function Run(out AError: string): Boolean;
    property Report: TMovieTrimReport read FReport;
  end;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // The export runs at disk speed on a passthrough, but a large source
  // over a slow volume still deserves room; a slice is a millisecond.
  ExportTimeoutSlices = 600000;
  // A cancelled session settles in well under a second; this is the
  // bound on waiting for it before the partial file is removed anyway.
  CancelTimeoutSlices = 2000;

var
  GExportReady: Boolean = False;

// Foreign-thread code: AVFoundation calls this back on one of its own
// queues, so it only sets the flag the main thread is polling.
procedure ExportCompletionHandler; cdecl;
begin
  GExportReady := True;
end;

{ TMovieTrimSession }

constructor TMovieTrimSession.Create(const AOptions: TExportOptions);
begin
  inherited Create;
  FOptions := AOptions;
end;

function TMovieTrimSession.FileTypeString: NSString;
begin
  case FOptions.OutputContainer of
    ocQuickTime: Result := AVFileTypeQuickTimeMovie;
  else
    Result := AVFileTypeMPEG4;
  end;
end;

function TMovieTrimSession.Run(out AError: string): Boolean;
var
  Asset: AVAsset;
  Session: AVAssetExportSession;
  URL: NSURL;
  Range: CMTimeRange;
  Status: NSInteger;
  ErrorObject: NSError;
  WaitCount: Integer;
  Handle: THandle;
  TempPath: string;
  Cancelled: Boolean;
begin
  Result := False;
  AError := '';
  FReport := Default(TMovieTrimReport);
  FReport.InputPath := FOptions.InputPath;
  FReport.OutputPath := FOptions.OutputPath;

  if not FileExists(FOptions.InputPath) then
  begin
    AError := 'no such file: ' + FOptions.InputPath;
    Exit;
  end;
  AError := OutputPathRefusal(FOptions.OutputPath);
  if AError <> '' then
    Exit;
  TempPath := RenderTemporaryPathFor(FOptions.OutputPath);

  URL := NSURL.fileURLWithPath(NSString.stringWithUTF8String(PAnsiChar(FOptions.InputPath)));
  Asset := AVAsset(AVURLAsset.URLAssetWithURL_options(URL, nil));
  if Asset = nil then
  begin
    AError := 'AVURLAsset could not open ' + FOptions.InputPath;
    Exit;
  end;
  Asset.retain;
  try
    FReport.SourceDurationSeconds := CMTimeGetSeconds(Asset.duration);
    if not (FReport.SourceDurationSeconds > 0) then
    begin
      AError := FOptions.InputPath + ' reports no duration, so it cannot '
        + 'be trimmed';
      Exit;
    end;
    FReport.StartSeconds := FOptions.TrimStartSeconds;
    if FOptions.HasTrimEnd then
      FReport.EndSeconds := FOptions.TrimEndSeconds
    else
      FReport.EndSeconds := FReport.SourceDurationSeconds;
    if FReport.StartSeconds >= FReport.SourceDurationSeconds then
    begin
      AError := Format('--trim starts at %.2fs but the movie is %.2fs long',
        [FReport.StartSeconds, FReport.SourceDurationSeconds]);
      Exit;
    end;
    if FReport.EndSeconds > FReport.SourceDurationSeconds then
      FReport.EndSeconds := FReport.SourceDurationSeconds;
    FReport.DurationSeconds := FReport.EndSeconds - FReport.StartSeconds;
    if not (FReport.DurationSeconds > 0) then
    begin
      AError := '--trim leaves nothing of the movie';
      Exit;
    end;

    // AVAssetExportSession refuses to start when the output exists — so
    // the trim used to DELETE the caller's file and then ask the
    // framework for a new one, which a timeout or a refusal left as
    // nothing at all. It builds into a neighbour instead and renames
    // that on, so the previous movie survives every failure there is
    // (Knips.Export.Atomic).
    if not ClaimTemporary(TempPath, AError) then
      Exit;

    Session := AVAssetExportSession(
      AVAssetExportSession.exportSessionWithAsset_presetName(Asset,
      AVAssetExportPresetPassthrough));
    if Session = nil then
    begin
      AError := 'this movie cannot be copied without re-encoding '
        + '(AVAssetExportPresetPassthrough is unavailable for it)';
      Exit;
    end;
    Session.retain;
    try
      Session.setOutputURL(NSURL.fileURLWithPath(
        NSString.stringWithUTF8String(PAnsiChar(TempPath))));
      Session.setOutputFileType(FileTypeString);
      Session.setShouldOptimizeForNetworkUse(ObjCBOOL(True));
      Range.start := CMTimeMakeWithSeconds(FReport.StartSeconds,
        TrimTimeScale);
      Range.duration := CMTimeMakeWithSeconds(FReport.DurationSeconds,
        TrimTimeScale);
      Session.setTimeRange(Range);

      GExportReady := False;
      Session.exportAsynchronouslyWithCompletionHandler(
        ExportCompletionHandler);
      WaitCount := 0;
      Cancelled := False;
      while (not GExportReady) and (WaitCount < ExportTimeoutSlices) do
      begin
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
        Inc(WaitCount);
        if StopRequested then
        begin
          Cancelled := True;
          Break;
        end;
      end;
      if Cancelled then
      begin
        Session.cancelExport;
        AError := ExportCancelledMessage;
        SweepTemporary(TempPath);
        Exit;
      end;
      if not GExportReady then
      begin
        // cancelExport is asynchronous too. Deleting the output while
        // the session is still winding down races a writer that may yet
        // touch the path, so the status is pumped out of Exporting
        // first — bounded, because a cancelled session that never
        // settles is worse than a leftover file.
        Session.cancelExport;
        WaitCount := 0;
        while (not GExportReady) and (WaitCount < CancelTimeoutSlices)
          and ((Session.status = AVAssetExportSessionStatusExporting)
          or (Session.status = AVAssetExportSessionStatusWaiting)) do
        begin
          CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds,
            False);
          Inc(WaitCount);
        end;
        AError := 'timed out trimming the movie';
        SweepTemporary(TempPath);
        Exit;
      end;

      Status := Session.status;
      if Status <> AVAssetExportSessionStatusCompleted then
      begin
        AError := 'AVAssetExportSession finished with status '
          + IntToStr(Status);
        ErrorObject := Session.error;
        if ErrorObject <> nil then
          AError := AError + ': '
            + string(ErrorObject.localizedDescription.UTF8String);
        SweepTemporary(TempPath);
        Exit;
      end;
    finally
      Session.release;
    end;
  finally
    Asset.release;
  end;

  if not FileExists(TempPath) then
  begin
    AError := 'the trim reported success but wrote no file';
    SweepTemporary(TempPath);
    Exit;
  end;
  // Only here does the previous movie stop being the answer.
  if not CommitTemporary(TempPath, FOptions.OutputPath, AError) then
    Exit;
  SweepTemporary(TempPath);
  Handle := FileOpen(FOptions.OutputPath, fmOpenRead or fmShareDenyNone);
  if Handle <> THandle(-1) then
  begin
    FReport.OutputBytes := FileSeek(Handle, Int64(0), fsFromEnd);
    FileClose(Handle);
  end;
  Result := True;
end;

{$ENDIF}

end.

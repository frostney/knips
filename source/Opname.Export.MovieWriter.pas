unit Opname.Export.MovieWriter;

// The movie sink: AVAssetWriter owns encoding (VideoToolbox underneath)
// and muxing, so opname appends the raw BGRA sample buffers SCK delivers
// and gets an .mp4/.mov back — the same shape Kap's Aperture used
// (ADR-0001). Timing comes from each buffer's own presentation stamp;
// the session starts at the first appended frame's PTS.
//
// Threading: AppendVideoSample runs on the capture queue; Open and Finish
// run on the main thread after the stream has stopped, so no two threads
// touch the writer at once. Counters shared with the main thread sit
// under a pthread mutex (no cthreads in this program).

{$I Shared.inc}

interface

{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cblocks}
{$modeswitch cvar}

uses
  SysUtils,

  CocoaAll,
  MacOSAll,
  Opname.Capture.CoreMedia,
  Opname.Capture.PThreadMutex,
  Opname.Options;

{$linkframework AVFoundation}
{$linkframework CoreMedia}
{$linkframework CoreVideo}

const
  // AVAssetWriterStatus
  AVAssetWriterStatusUnknown = 0;
  AVAssetWriterStatusWriting = 1;
  AVAssetWriterStatusCompleted = 2;
  AVAssetWriterStatusFailed = 3;
  AVAssetWriterStatusCancelled = 4;

type
  TAVCompletionBlock = reference to procedure; cdecl; cblock;

  AVAssetWriterInput = objcclass external (NSObject)
    class function AssetWriterInputWithMediaType_outputSettings(
      AMediaType: NSString; AOutputSettings: NSDictionary): id;
      message 'assetWriterInputWithMediaType:outputSettings:';
    procedure SetExpectsMediaDataInRealTime(AExpects: ObjCBOOL);
      message 'setExpectsMediaDataInRealTime:';
    function IsReadyForMoreMediaData: ObjCBOOL;
      message 'isReadyForMoreMediaData';
    function AppendSampleBuffer(ASampleBuffer: CMSampleBufferRef): ObjCBOOL;
      message 'appendSampleBuffer:';
    procedure MarkAsFinished; message 'markAsFinished';
  end;

  AVAssetWriter = objcclass external (NSObject)
    class function AssetWriterWithURL_fileType_error(AOutputURL: NSURL;
      AOutputFileType: NSString; AOutError: NSErrorPtr): id;
      message 'assetWriterWithURL:fileType:error:';
    function CanAddInput(AInput: AVAssetWriterInput): ObjCBOOL;
      message 'canAddInput:';
    procedure AddInput(AInput: AVAssetWriterInput); message 'addInput:';
    procedure SetShouldOptimizeForNetworkUse(AOptimize: ObjCBOOL);
      message 'setShouldOptimizeForNetworkUse:';
    function StartWriting: ObjCBOOL; message 'startWriting';
    procedure StartSessionAtSourceTime(AStartTime: CMTime);
      message 'startSessionAtSourceTime:';
    procedure FinishWritingWithCompletionHandler(AHandler: TAVCompletionBlock);
      message 'finishWritingWithCompletionHandler:';
    procedure CancelWriting; message 'cancelWriting';
    function Status: NSInteger; message 'status';
    function Error: NSError; message 'error';
  end;

var
  AVFileTypeMPEG4: NSString; cvar; external;
  AVFileTypeQuickTimeMovie: NSString; cvar; external;
  AVMediaTypeVideo: NSString; cvar; external;
  AVVideoCodecKey: NSString; cvar; external;
  AVVideoCodecTypeH264: NSString; cvar; external;
  AVVideoWidthKey: NSString; cvar; external;
  AVVideoHeightKey: NSString; cvar; external;
  AVVideoCompressionPropertiesKey: NSString; cvar; external;
  AVVideoAverageBitRateKey: NSString; cvar; external;
  AVVideoMaxKeyFrameIntervalKey: NSString; cvar; external;
  AVVideoExpectedSourceFrameRateKey: NSString; cvar; external;
  AVVideoAllowFrameReorderingKey: NSString; cvar; external;
  AVVideoProfileLevelKey: NSString; cvar; external;
  AVVideoProfileLevelH264HighAutoLevel: NSString; cvar; external;

type
  TMovieWriterStatistics = record
    AppendedFrames: Int64;
    DroppedFrames: Int64;
    FailedAppends: Int64;
    // Seconds between the first and last appended frame.
    Duration: Double;
  end;

  TMovieWriter = class
  private
    FOutputPath: string;
    FContainer: TOutputContainer;
    FPixelWidth: Integer;
    FPixelHeight: Integer;
    FFramesPerSecond: Integer;
    FBitRate: Integer;
    FWriter: AVAssetWriter;
    FInput: AVAssetWriterInput;
    FLock: TPThreadMutex;
    FSessionStarted: Boolean;
    FFirstTime: CMTime;
    FLastTime: CMTime;
    FAppended: Int64;
    FDropped: Int64;
    FFailed: Int64;
    FOpen: Boolean;
    function BuildOutputSettings: NSDictionary;
    function WriterError: string;
  public
    constructor Create(const AOutputPath: string;
      AContainer: TOutputContainer; APixelWidth, APixelHeight,
      AFramesPerSecond, ABitRate: Integer);
    destructor Destroy; override;
    // Creates the writer and input; replaces an existing file.
    function Open(out AError: string): Boolean;
    // Capture-queue side. Returns False when the frame was dropped or the
    // append failed; the reason is counted, not reported, on this thread.
    function AppendVideoSample(ASampleBuffer: CMSampleBufferRef): Boolean;
    // Main-thread side, after the stream has stopped.
    function Finish(out AError: string): Boolean;
    procedure Cancel;
    function Statistics: TMovieWriterStatistics;
    property OutputPath: string read FOutputPath;
  end;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // Keyframe every four seconds: fine for playback, small files.
  KeyframeIntervalSeconds = 4;
  FinishTimeoutSlices = 30000;
  RunLoopSliceSeconds = 0.001;

var
  GFinishReady: Boolean = False;

procedure FinishCompletionHandler; cdecl;
begin
  GFinishReady := True;
end;

function ContainerFileTypeString(AContainer: TOutputContainer): NSString;
begin
  case AContainer of
    ocQuickTime: Result := AVFileTypeQuickTimeMovie;
  else
    Result := AVFileTypeMPEG4;
  end;
end;

{ TMovieWriter }

constructor TMovieWriter.Create(const AOutputPath: string;
  AContainer: TOutputContainer; APixelWidth, APixelHeight,
  AFramesPerSecond, ABitRate: Integer);
begin
  inherited Create;
  FOutputPath := AOutputPath;
  FContainer := AContainer;
  FPixelWidth := APixelWidth;
  FPixelHeight := APixelHeight;
  FFramesPerSecond := AFramesPerSecond;
  FBitRate := ABitRate;
  PThreadMutexInit(FLock);
end;

destructor TMovieWriter.Destroy;
begin
  if FOpen then
    Cancel;
  if FInput <> nil then
    FInput.release;
  if FWriter <> nil then
    FWriter.release;
  PThreadMutexDestroy(FLock);
  inherited Destroy;
end;

function TMovieWriter.BuildOutputSettings: NSDictionary;
var
  Settings: NSMutableDictionary;
  Compression: NSMutableDictionary;
begin
  Compression := NSMutableDictionary.dictionaryWithCapacity(5);
  Compression.setObject_forKey(NSNumber.numberWithInt(FBitRate),
    id(AVVideoAverageBitRateKey));
  Compression.setObject_forKey(
    NSNumber.numberWithInt(FFramesPerSecond * KeyframeIntervalSeconds),
    id(AVVideoMaxKeyFrameIntervalKey));
  Compression.setObject_forKey(NSNumber.numberWithInt(FFramesPerSecond),
    id(AVVideoExpectedSourceFrameRateKey));
  Compression.setObject_forKey(NSNumber.numberWithBool(ObjCBOOL(False)),
    id(AVVideoAllowFrameReorderingKey));
  Compression.setObject_forKey(id(AVVideoProfileLevelH264HighAutoLevel),
    id(AVVideoProfileLevelKey));

  Settings := NSMutableDictionary.dictionaryWithCapacity(4);
  Settings.setObject_forKey(id(AVVideoCodecTypeH264), id(AVVideoCodecKey));
  Settings.setObject_forKey(NSNumber.numberWithInt(FPixelWidth),
    id(AVVideoWidthKey));
  Settings.setObject_forKey(NSNumber.numberWithInt(FPixelHeight),
    id(AVVideoHeightKey));
  Settings.setObject_forKey(Compression, id(AVVideoCompressionPropertiesKey));
  Result := Settings;
end;

function TMovieWriter.WriterError: string;
var
  Error: NSError;
begin
  Result := '';
  if FWriter = nil then
    Exit;
  Error := FWriter.error;
  if Error <> nil then
    Result := string(Error.localizedDescription.UTF8String);
end;

function TMovieWriter.Open(out AError: string): Boolean;
var
  URL: NSURL;
  Error: NSError;
begin
  Result := False;
  AError := '';
  if FileExists(FOutputPath) and not DeleteFile(FOutputPath) then
  begin
    AError := 'cannot replace ' + FOutputPath;
    Exit;
  end;

  URL := NSURL.fileURLWithPath(NSSTR(PAnsiChar(FOutputPath)));
  Error := nil;
  FWriter := AVAssetWriter(AVAssetWriter.assetWriterWithURL_fileType_error(
    URL, ContainerFileTypeString(FContainer), @Error));
  if FWriter = nil then
  begin
    if Error <> nil then
      AError := 'AVAssetWriter: '
        + string(Error.localizedDescription.UTF8String)
    else
      AError := 'AVAssetWriter could not be created';
    Exit;
  end;
  FWriter.retain;
  FWriter.setShouldOptimizeForNetworkUse(ObjCBOOL(True));

  FInput := AVAssetWriterInput(
    AVAssetWriterInput.assetWriterInputWithMediaType_outputSettings(
    AVMediaTypeVideo, BuildOutputSettings));
  if FInput = nil then
  begin
    AError := 'AVAssetWriterInput could not be created';
    Exit;
  end;
  FInput.retain;
  FInput.setExpectsMediaDataInRealTime(ObjCBOOL(True));

  if not FWriter.canAddInput(FInput) then
  begin
    AError := 'AVAssetWriter rejected the video input';
    Exit;
  end;
  FWriter.addInput(FInput);

  if not FWriter.startWriting then
  begin
    AError := 'startWriting failed: ' + WriterError;
    Exit;
  end;
  FOpen := True;
  Result := True;
end;

function TMovieWriter.AppendVideoSample(
  ASampleBuffer: CMSampleBufferRef): Boolean;
var
  Time: CMTime;
begin
  Result := False;
  if not FOpen then
    Exit;
  Time := CMSampleBufferGetPresentationTimeStamp(ASampleBuffer);

  PThreadMutexLock(FLock);
  if not FInput.isReadyForMoreMediaData then
  begin
    Inc(FDropped);
    PThreadMutexUnlock(FLock);
    Exit;
  end;
  if not FSessionStarted then
  begin
    FWriter.startSessionAtSourceTime(Time);
    FFirstTime := Time;
    FSessionStarted := True;
  end;
  if FInput.appendSampleBuffer(ASampleBuffer) then
  begin
    Inc(FAppended);
    FLastTime := Time;
    Result := True;
  end
  else
    Inc(FFailed);
  PThreadMutexUnlock(FLock);
end;

function TMovieWriter.Finish(out AError: string): Boolean;
var
  WaitCount: Integer;
begin
  Result := False;
  AError := '';
  if not FOpen then
  begin
    AError := 'writer is not open';
    Exit;
  end;
  FOpen := False;

  PThreadMutexLock(FLock);
  FInput.markAsFinished;
  PThreadMutexUnlock(FLock);

  if not FSessionStarted then
  begin
    // Nothing was ever appended; a finished session would be empty.
    FWriter.cancelWriting;
    AError := 'no frames were captured';
    Exit;
  end;

  GFinishReady := False;
  FWriter.finishWritingWithCompletionHandler(FinishCompletionHandler);
  WaitCount := 0;
  while (not GFinishReady) and (WaitCount < FinishTimeoutSlices) do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, RunLoopSliceSeconds, False);
    Inc(WaitCount);
  end;
  if not GFinishReady then
  begin
    AError := 'timed out finishing the movie';
    Exit;
  end;
  if FWriter.status <> AVAssetWriterStatusCompleted then
  begin
    AError := 'AVAssetWriter finished with status '
      + IntToStr(FWriter.status) + ': ' + WriterError;
    Exit;
  end;
  Result := True;
end;

procedure TMovieWriter.Cancel;
begin
  if not FOpen then
    Exit;
  FOpen := False;
  if FWriter <> nil then
    FWriter.cancelWriting;
end;

function TMovieWriter.Statistics: TMovieWriterStatistics;
begin
  PThreadMutexLock(FLock);
  Result.AppendedFrames := FAppended;
  Result.DroppedFrames := FDropped;
  Result.FailedAppends := FFailed;
  if FSessionStarted and (FAppended > 0) then
    Result.Duration := CMTimeGetSeconds(FLastTime)
      - CMTimeGetSeconds(FFirstTime)
  else
    Result.Duration := 0;
  PThreadMutexUnlock(FLock);
end;

{$ENDIF}

end.

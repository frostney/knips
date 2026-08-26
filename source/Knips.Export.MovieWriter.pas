unit Knips.Export.MovieWriter;

// The movie sink: AVAssetWriter owns encoding (VideoToolbox underneath)
// and muxing, so knips appends the raw BGRA sample buffers SCK delivers
// and gets an .mp4/.mov back — the same shape Kap's Aperture used
// (ADR-0001). Timing comes from each buffer's own presentation stamp;
// the session starts at the first appended frame's PTS.
//
// With audio enabled the movie gains a second input: an AAC track fed
// from ScreenCaptureKit's audio output, muxed by the same writer. The
// microphone is a third input and a third track — nothing here mixes the
// two audio sources, and a player picks the first track by default.
//
// Both AAC inputs are configured with the same fully specified settings
// dictionary (48 kHz stereo by default), whatever format the buffers
// arrive in. AVAssetWriterInput.h requires exactly that: an audio
// settings dictionary passed to
// assetWriterInputWithMediaType:outputSettings: "must be fully
// specified, meaning that it must contain AVFormatIDKey, AVSampleRateKey,
// and AVNumberOfChannelsKey" — a bit-rate-only dictionary is legal only
// with a sourceFormatHint. The same header constrains appended audio to
// linear PCM and nothing more, and lists AVSampleRateConverterAudioQuality
// as a settings key, so the input's encoder is what converts a mono or
// 44.1 kHz microphone into the configured track. A mono source with
// AVNumberOfChannelsKey = 2 is documented to produce stereo output. So
// there is no per-buffer format inspection here, and no lazy input
// creation under a capture callback.
//
// Threading: AppendVideoSample, AppendAudioSample and
// AppendMicrophoneSample run on capture queues (SCK uses a separate one
// per output type); Open and Finish run on the main thread after the
// stream has stopped, so no two threads touch the writer at once.
// Counters shared with the main thread — and the appends with each
// other — sit under a pthread mutex (no cthreads in this program).

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
  Knips.Capture.PThreadMutex,
  Knips.Options,
  MacOSAll;

{$linkframework AVFoundation}
{$linkframework CoreMedia}
{$linkframework CoreVideo}

const
  // kAudioFormatMPEG4AAC from CoreAudioTypes: the four-character code
  // 'aac ' (0x61616320). AVFormatIDKey wants it as a plain integer.
  AudioFormatMPEG4AAC = 1633772320;

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
  AVMediaTypeAudio: NSString; cvar; external;
  // AVFAudio's settings keys; AVFoundation re-exports them.
  AVFormatIDKey: NSString; cvar; external;
  AVSampleRateKey: NSString; cvar; external;
  AVNumberOfChannelsKey: NSString; cvar; external;
  AVEncoderBitRateKey: NSString; cvar; external;
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
    AppendedAudioSamples: Int64;
    // Audio drops, by cause: before the session's first video frame vs.
    // AAC back-pressure while the input was not ready.
    DroppedAudioEarly: Int64;
    DroppedAudioStalled: Int64;
    FailedAudioAppends: Int64;
    // The microphone track's own counters, same three causes. Kept apart
    // from the system-audio ones so `--audio=both` can show which source
    // is starving.
    AppendedMicrophoneSamples: Int64;
    DroppedMicrophoneEarly: Int64;
    DroppedMicrophoneStalled: Int64;
    FailedMicrophoneAppends: Int64;
    // True once the writer left Writing state; the recording is dead and
    // the main thread should stop instead of appending into it.
    WriterFailed: Boolean;
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
    FAudioEnabled: Boolean;
    FMicrophoneEnabled: Boolean;
    FAudioSampleRate: Integer;
    FAudioChannelCount: Integer;
    FAudioBitRate: Integer;
    FWriter: AVAssetWriter;
    FInput: AVAssetWriterInput;
    FAudioInput: AVAssetWriterInput;
    FMicrophoneInput: AVAssetWriterInput;
    FLock: TPThreadMutex;
    FSessionStarted: Boolean;
    FFirstTime: CMTime;
    FLastTime: CMTime;
    FAppended: Int64;
    FDropped: Int64;
    FFailed: Int64;
    FAudioAppended: Int64;
    FAudioDroppedEarly: Int64;
    FAudioDroppedStalled: Int64;
    FAudioFailed: Int64;
    FMicrophoneAppended: Int64;
    FMicrophoneDroppedEarly: Int64;
    FMicrophoneDroppedStalled: Int64;
    FMicrophoneFailed: Int64;
    FWriterFailed: Boolean;
    FOpen: Boolean;
    function BuildOutputSettings: NSDictionary;
    function BuildAudioOutputSettings: NSDictionary;
    // Adds one AAC input to the writer; the two audio tracks differ only
    // in which counters they feed.
    function AddAudioInput(out AInput: AVAssetWriterInput;
      const AWhat: string; out AError: string): Boolean;
    // The shared capture-queue append path for both audio tracks. Runs
    // under FLock; no allocation, no managed types, no exceptions.
    function AppendAudioTo(AInput: AVAssetWriterInput;
      ASampleBuffer: CMSampleBufferRef;
      var AAppended, ADroppedEarly, ADroppedStalled, AFailed: Int64): Boolean;
    function WriterError: string;
  public
    constructor Create(const AOutputPath: string;
      AContainer: TOutputContainer; APixelWidth, APixelHeight,
      AFramesPerSecond, ABitRate: Integer);
    destructor Destroy; override;
    // Adds AAC audio tracks — system audio, microphone, or both — in one
    // shared format (the inputs' encoders convert whatever the sources
    // deliver). One format for all tracks by design: per-track formats
    // would need per-input settings in AddAudioInput. Must be called
    // before Open.
    procedure EnableAudioTracks(ASystem, AMicrophone: Boolean;
      ASampleRate, AChannelCount, ABitRate: Integer);
    // Creates the writer and inputs; replaces an existing file.
    function Open(out AError: string): Boolean;
    // Capture-queue side. Returns False when the frame was dropped or the
    // append failed; the reason is counted, not reported, on this thread.
    function AppendVideoSample(ASampleBuffer: CMSampleBufferRef): Boolean;
    // Capture-queue side, on ScreenCaptureKit's audio queue. The session
    // starts at the first video frame, so earlier audio is dropped.
    function AppendAudioSample(ASampleBuffer: CMSampleBufferRef): Boolean;
    // The same, on ScreenCaptureKit's microphone queue.
    function AppendMicrophoneSample(ASampleBuffer: CMSampleBufferRef): Boolean;
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
  if FAudioInput <> nil then
    FAudioInput.release;
  if FMicrophoneInput <> nil then
    FMicrophoneInput.release;
  if FWriter <> nil then
    FWriter.release;
  PThreadMutexDestroy(FLock);
  inherited Destroy;
end;

procedure TMovieWriter.EnableAudioTracks(ASystem, AMicrophone: Boolean;
  ASampleRate, AChannelCount, ABitRate: Integer);
begin
  FAudioEnabled := ASystem;
  FMicrophoneEnabled := AMicrophone;
  FAudioSampleRate := ASampleRate;
  FAudioChannelCount := AChannelCount;
  FAudioBitRate := ABitRate;
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

function TMovieWriter.BuildAudioOutputSettings: NSDictionary;
var
  Settings: NSMutableDictionary;
begin
  Settings := NSMutableDictionary.dictionaryWithCapacity(4);
  Settings.setObject_forKey(NSNumber.numberWithInt(AudioFormatMPEG4AAC),
    id(AVFormatIDKey));
  // AVSampleRateKey is documented as a floating-point value in hertz.
  Settings.setObject_forKey(NSNumber.numberWithDouble(FAudioSampleRate),
    id(AVSampleRateKey));
  Settings.setObject_forKey(NSNumber.numberWithInt(FAudioChannelCount),
    id(AVNumberOfChannelsKey));
  Settings.setObject_forKey(NSNumber.numberWithInt(FAudioBitRate),
    id(AVEncoderBitRateKey));
  Result := Settings;
end;

function TMovieWriter.AddAudioInput(out AInput: AVAssetWriterInput;
  const AWhat: string; out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  AInput := AVAssetWriterInput(
    AVAssetWriterInput.assetWriterInputWithMediaType_outputSettings(
    AVMediaTypeAudio, BuildAudioOutputSettings));
  if AInput = nil then
  begin
    AError := 'the ' + AWhat + ' AVAssetWriterInput could not be created';
    Exit;
  end;
  AInput.retain;
  AInput.setExpectsMediaDataInRealTime(ObjCBOOL(True));
  if not FWriter.canAddInput(AInput) then
  begin
    AError := 'AVAssetWriter rejected the ' + AWhat + ' input';
    Exit;
  end;
  FWriter.addInput(AInput);
  Result := True;
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

  // Track order is the order the inputs are added, and players pick the
  // first audio track: system audio comes before the microphone so
  // --audio=both keeps --audio=system's default playback.
  if FAudioEnabled and not AddAudioInput(FAudioInput, 'audio', AError) then
    Exit;
  if FMicrophoneEnabled
    and not AddAudioInput(FMicrophoneInput, 'microphone', AError) then
    Exit;

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
  // A writer that left Writing state (one rejected buffer fails it for
  // good) rejects every later append on every input; record the fact so
  // the main thread can abort instead of recording into a dead file.
  if FWriter.status <> AVAssetWriterStatusWriting then
  begin
    FWriterFailed := True;
    Inc(FFailed);
    PThreadMutexUnlock(FLock);
    Exit;
  end;
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

function TMovieWriter.AppendAudioTo(AInput: AVAssetWriterInput;
  ASampleBuffer: CMSampleBufferRef;
  var AAppended, ADroppedEarly, ADroppedStalled, AFailed: Int64): Boolean;
begin
  Result := False;
  if not FOpen or (AInput = nil) then
    Exit;
  // A buffer whose data is not ready would fail the writer terminally,
  // video track included; refuse it before it reaches appendSampleBuffer.
  if not CMSampleBufferDataIsReady(ASampleBuffer) then
  begin
    PThreadMutexLock(FLock);
    Inc(AFailed);
    PThreadMutexUnlock(FLock);
    Exit;
  end;

  PThreadMutexLock(FLock);
  if FWriter.status <> AVAssetWriterStatusWriting then
  begin
    FWriterFailed := True;
    Inc(AFailed);
    PThreadMutexUnlock(FLock);
    Exit;
  end;
  // The session's source time is the first video frame's PTS; audio that
  // arrives before it has no timeline to be placed on yet.
  if not FSessionStarted then
  begin
    Inc(ADroppedEarly);
    PThreadMutexUnlock(FLock);
    Exit;
  end;
  if not AInput.isReadyForMoreMediaData then
  begin
    Inc(ADroppedStalled);
    PThreadMutexUnlock(FLock);
    Exit;
  end;
  if AInput.appendSampleBuffer(ASampleBuffer) then
  begin
    Inc(AAppended);
    Result := True;
  end
  else
    Inc(AFailed);
  PThreadMutexUnlock(FLock);
end;

function TMovieWriter.AppendAudioSample(
  ASampleBuffer: CMSampleBufferRef): Boolean;
begin
  Result := AppendAudioTo(FAudioInput, ASampleBuffer, FAudioAppended,
    FAudioDroppedEarly, FAudioDroppedStalled, FAudioFailed);
end;

function TMovieWriter.AppendMicrophoneSample(
  ASampleBuffer: CMSampleBufferRef): Boolean;
begin
  Result := AppendAudioTo(FMicrophoneInput, ASampleBuffer,
    FMicrophoneAppended, FMicrophoneDroppedEarly, FMicrophoneDroppedStalled,
    FMicrophoneFailed);
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
  if FAudioInput <> nil then
    FAudioInput.markAsFinished;
  if FMicrophoneInput <> nil then
    FMicrophoneInput.markAsFinished;
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
  Result.AppendedAudioSamples := FAudioAppended;
  Result.DroppedAudioEarly := FAudioDroppedEarly;
  Result.DroppedAudioStalled := FAudioDroppedStalled;
  Result.FailedAudioAppends := FAudioFailed;
  Result.AppendedMicrophoneSamples := FMicrophoneAppended;
  Result.DroppedMicrophoneEarly := FMicrophoneDroppedEarly;
  Result.DroppedMicrophoneStalled := FMicrophoneDroppedStalled;
  Result.FailedMicrophoneAppends := FMicrophoneFailed;
  Result.WriterFailed := FWriterFailed;
  if FSessionStarted and (FAppended > 0) then
    Result.Duration := CMTimeGetSeconds(FLastTime)
      - CMTimeGetSeconds(FFirstTime)
  else
    Result.Duration := 0;
  PThreadMutexUnlock(FLock);
end;

{$ENDIF}

end.

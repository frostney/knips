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
//
// EmitHeartbeatFrame is the one exception to "the main thread only writes
// when the stream has stopped": it appends while the capture queue may
// still be delivering. That raises two separate hazards, and only one of
// them is about the lock.
//
// **Concurrency.** AVAssetWriterInput is not safe for two callers at
// once, so the whole of EmitHeartbeatFrame — reading the retained last
// frame, copying it with a new stamp, and the append itself — happens
// inside the *same* FLock the capture path already takes around its
// appends. There is no second lock and therefore no ordering to get
// wrong: every append on every input, from every thread, is serialised by
// that one mutex, and a heartbeat is just one more of them.
//
// **Ordering, which the lock does NOT solve.** Serialising the two
// appends says nothing about their stamps. ScreenCaptureKit stamps a
// buffer at capture time and delivers it milliseconds later; a heartbeat
// stamps at the moment the main thread reads the clock. So a frame
// captured before a heartbeat and delivered after it arrives with a
// presentation stamp EARLIER than the one already in the file, and one
// out-of-order stamp fails AVAssetWriter terminally — the take is lost,
// reproduced and measured. AppendVideoSample closes that by retiming such
// a frame forward one tick; its comment is the full account. Nothing
// about this hazard existed before the heartbeat, because before it every
// stamp in the file came from ScreenCaptureKit in delivery order.
//
// See "The idle heartbeat" in docs/architecture.md.

{$I Knips.inc}

interface

{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cblocks}
{$modeswitch cvar}

uses
  ctypes,
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
  // Keyframe every four seconds: fine for playback, small files.
  // Public because Knips.Export.Render encodes into the same container
  // and had a second copy of the number with "as the recorder does"
  // written beside it — which is a comment where a reference belongs.
  KeyframeIntervalSeconds = 4;

const
  // kAudioFormatMPEG4AAC from CoreAudioTypes: the four-character code
  // 'aac ' (0x61616320). AVFormatIDKey wants it as a plain integer.
  AudioFormatMPEG4AAC = 1633772320;

  // AVAssetWriterStatus, verified against AVAssetWriter.h. Transcribed
  // whole though only Writing and Completed are compared against; the
  // rest are documentary. See Knips.Capture.ScreenCaptureKit's
  // SCFrameStatus block for the reasoning.
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
    // Movie fragments. Set before startWriting, this makes AVAssetWriter
    // flush a moof/mdat pair every interval instead of holding everything
    // for one moov at the end — which is what turns a killed recording
    // from an unplayable stub into a movie that ends where the process
    // did. See "Never lose a take" in docs/architecture.md.
    procedure SetMovieFragmentInterval(AInterval: CMTime);
      message 'setMovieFragmentInterval:';
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
    // The loudest sample seen on each track, as a magnitude in 0..1, and
    // how many buffers it was actually measured over. Zero inspected
    // means the format was not one this code reads (see MeasurePeak), and
    // the peak then says nothing at all — which is why the two travel
    // together and no caller may read one without the other.
    //
    // This is what turns "the microphone was enabled" into "the
    // microphone was enabled and produced sound": a track that arrived
    // and was silent is the failure nobody notices until the take cannot
    // be repeated.
    AudioPeak: Double;
    AudioInspected: Int64;
    MicrophonePeak: Double;
    MicrophoneInspected: Int64;
    // How many of AppendedFrames were idle heartbeats — the last frame
    // repeated because ScreenCaptureKit had gone quiet — rather than
    // frames it delivered. Zero for any take whose content kept changing,
    // which is what makes this the no-regression measurement.
    HeartbeatFrames: Int64;
    // Heartbeats that were due and could not be made: the writer was not
    // ready for more data, or the retained frame had been invalidated
    // under us. Never a reason to fail a recording — the movie is simply
    // the length it was before — but the one number that would say the
    // heartbeat had stopped working.
    HeartbeatRefused: Int64;
    // Frames ScreenCaptureKit delivered with a stamp at or before the one
    // already in the file, moved forward one tick so the track stays
    // monotonic. Only a heartbeat can put a stamp in the file ahead of
    // capture time, so this is zero for every take that never went idle —
    // and a small number, on the transitions back out of idle, for the
    // ones that did. See AppendVideoSample.
    RetimedFrames: Int64;
    // True once the writer left Writing state; the recording is dead and
    // the main thread should stop instead of appending into it.
    WriterFailed: Boolean;
    // Seconds between the first and last appended frame.
    Duration: Double;
    // True once startSessionAtSourceTime: has been called, which is the
    // instant the movie's timeline begins.
    SessionStarted: Boolean;
    // The presentation stamp the session was started at, in seconds on
    // ScreenCaptureKit's host clock — the anchor that turns a host-clock
    // event time into a time on the movie's own timeline. Meaningless
    // until SessionStarted; see Knips.Recording.Sidecar.
    FirstSampleSeconds: Double;
    // The same for the *last* appended frame, which is how far the movie
    // has got on that clock. Comparing it with the clock is the whole of
    // the idle heartbeat's decision (Knips.Recording.Heartbeat).
    // Meaningless until SessionStarted.
    LastSampleSeconds: Double;
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
    FAudioPeak: Double;
    FAudioInspected: Int64;
    FMicrophonePeak: Double;
    FMicrophoneInspected: Int64;
    FHeartbeatFrames: Int64;
    FHeartbeatRefused: Int64;
    FRetimedFrames: Int64;
    // The most recent frame that reached the movie, retained so it can be
    // appended again when ScreenCaptureKit goes quiet. Exactly one is
    // held at a time — the new one replaces and releases the old under
    // FLock — so the stream's buffer pool is down one slot of its queue
    // depth and no more, and the buffer held is the one AVAssetWriter has
    // just been given anyway. Nil until the first successful append.
    FLastVideoSample: CMSampleBufferRef;
    FWriterFailed: Boolean;
    FOpen: Boolean;
    // Drops the retained frame. Callers hold FLock, or run when no
    // capture queue is left to race them.
    procedure ReleaseLastVideoSample;
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
      var AAppended, ADroppedEarly, ADroppedStalled, AFailed: Int64;
      var APeak: Double; var AInspected: Int64): Boolean;
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
    // The idle heartbeat: the last delivered frame again, at
    // AStampSeconds on ScreenCaptureKit's host clock, so a movie whose
    // content has stopped changing goes on keeping pace with the wall
    // clock. Whether one is *due* is the caller's decision
    // (Knips.Recording.Heartbeat); this only carries it out.
    //
    // Main thread, and — unlike Finish — while the capture queue may
    // still be delivering: the append happens under the same FLock every
    // other append takes, so the two serialise rather than race. See the
    // threading note at the top of this unit.
    //
    // False, and nothing appended, when there is no frame to repeat yet,
    // when the writer is not ready for more data, or when the stamp would
    // not be strictly later than the last one. None of those is an error.
    function EmitHeartbeatFrame(AStampSeconds: Double): Boolean;
    // Main-thread side, after the stream has stopped.
    function Finish(out AError: string): Boolean;
    procedure Cancel;
    function Statistics: TMovieWriterStatistics;
    property OutputPath: string read FOutputPath;
  end;

// The H.264 output settings every movie knips writes are encoded with:
// codec, size, average bit rate, keyframe interval, expected source rate,
// no frame reordering, high profile. One builder because there are two
// writers — the recorder's TMovieWriter and the render pass's own
// AVAssetWriter (Knips.Export.Render.OpenWriter) — and they had a
// dictionary each, built key for key the same. Two copies of an encoder
// configuration drift silently: the file still plays, it is simply worse
// than the other one, and nothing says so.
//
// AFramesPerSecond is what the deliverable is CONFIGURED for, not what a
// sparse take averaged; it feeds both the keyframe interval and the
// encoder's rate expectation, so passing an average buys a keyframe
// every few frames and a bit rate sized for a slideshow.
function BuildH264OutputSettings(APixelWidth, APixelHeight,
  AFramesPerSecond, ABitRate: Integer): NSDictionary;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // How often a movie fragment is flushed. Two seconds is the most a
  // kill -9 can cost, and the overhead is one moof header per fragment —
  // measured at well under a tenth of a percent of a real recording.
  // Shorter would buy less than it costs in index bloat; longer starts
  // to lose takes.
  MovieFragmentSeconds = 2;
  FinishTimeoutSlices = 30000;

var
  // One process-global flag for a completion handler that is a global
  // `cdecl` procedure, because that is what a `cblock` parameter can be
  // given (docs/code-style.md). It is set to False immediately before
  // finishWritingWithCompletionHandler: and polled by the caller.
  //
  // **It is never drained.** A finish that times out leaves a handler
  // still out there, and if it fires afterwards it sets this flag with
  // nobody waiting — so the NEXT writer's finish could see a True it did
  // not earn and stop waiting one slice in. That is the residual risk,
  // stated rather than engineered around: the status check below is what
  // catches it, because a writer whose finish has not actually completed
  // is not in AVAssetWriterStatusCompleted, and the finish then fails
  // with the status rather than claiming a movie that is not there.
  //
  // The other reason it is left alone: reaching the timeout at all means
  // AVAssetWriter did not answer in thirty seconds, and by then the take
  // is being reported as failed either way.
  //
  // Worth restating now that there IS a long-lived multi-finish
  // process: `knips mcp` runs an unbounded number of sessions in one
  // process, so it is the first face where a stale handler could reach
  // a *later* writer at all. The CLI finishes once and exits and the
  // app finishes one take at a time; the reasoning above is unchanged
  // and the status check is still what catches it, but the window it
  // guards is no longer hypothetical.
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
  // After Cancel, and before the inputs go: the capture queue has been
  // stopped by the session long before a writer is freed, so nothing is
  // racing this.
  ReleaseLastVideoSample;
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

procedure TMovieWriter.ReleaseLastVideoSample;
begin
  if FLastVideoSample = nil then
    Exit;
  CMSampleBufferRelease(FLastVideoSample);
  FLastVideoSample := nil;
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

function BuildH264OutputSettings(APixelWidth, APixelHeight,
  AFramesPerSecond, ABitRate: Integer): NSDictionary;
var
  Settings: NSMutableDictionary;
  Compression: NSMutableDictionary;
begin
  Compression := NSMutableDictionary.dictionaryWithCapacity(5);
  Compression.setObject_forKey(NSNumber.numberWithInt(ABitRate),
    id(AVVideoAverageBitRateKey));
  Compression.setObject_forKey(
    NSNumber.numberWithInt(AFramesPerSecond * KeyframeIntervalSeconds),
    id(AVVideoMaxKeyFrameIntervalKey));
  Compression.setObject_forKey(NSNumber.numberWithInt(AFramesPerSecond),
    id(AVVideoExpectedSourceFrameRateKey));
  Compression.setObject_forKey(NSNumber.numberWithBool(ObjCBOOL(False)),
    id(AVVideoAllowFrameReorderingKey));
  Compression.setObject_forKey(id(AVVideoProfileLevelH264HighAutoLevel),
    id(AVVideoProfileLevelKey));

  Settings := NSMutableDictionary.dictionaryWithCapacity(4);
  Settings.setObject_forKey(id(AVVideoCodecTypeH264), id(AVVideoCodecKey));
  Settings.setObject_forKey(NSNumber.numberWithInt(APixelWidth),
    id(AVVideoWidthKey));
  Settings.setObject_forKey(NSNumber.numberWithInt(APixelHeight),
    id(AVVideoHeightKey));
  Settings.setObject_forKey(Compression, id(AVVideoCompressionPropertiesKey));
  Result := Settings;
end;

function TMovieWriter.BuildOutputSettings: NSDictionary;
begin
  Result := BuildH264OutputSettings(FPixelWidth, FPixelHeight,
    FFramesPerSecond, FBitRate);
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
  // The existing file goes BEFORE the writer is even created, which
  // means a failure anywhere below leaves the old file deleted and no
  // new one in its place. That is deliberate and it is not a choice:
  // +[AVAssetWriter assetWriterWithURL:fileType:error:] refuses a URL
  // that already exists (AVErrorFileAlreadyExists), so there is no
  // ordering in which the writer is known to be good before the path is
  // clear. Moving the delete down to just before startWriting would
  // narrow the window and not close it.
  //
  // The exposure is bounded by what is at the path. `record` and the
  // menu-bar app write a name nothing else owns — a timestamp, or a path
  // the caller named, and `record` replacing what it is pointed at
  // without asking is the documented contract (AGENTS.md). The one place
  // where a valuable file really is at the output path is a re-render of
  // an existing deliverable, and that path does not come through here at
  // all: Knips.Export.Render builds into `<out>.knips-render-tmp` and
  // renames it into place, precisely so a failed render cannot destroy
  // the file it was replacing.
  if FileExists(FOutputPath) and not DeleteFile(FOutputPath) then
  begin
    AError := 'cannot replace ' + FOutputPath;
    Exit;
  end;

  // stringWithUTF8String:, not NSSTR: NSSTR bridges through MacRoman, so
  // a path with a non-ASCII character in it becomes a DIFFERENT path —
  // measured, it double-encodes the UTF-8 bytes. The movie would then be
  // written somewhere the event sidecar beside it does not name, and
  // recovery would never find the pair again.
  URL := NSURL.fileURLWithPath(
    NSString.stringWithUTF8String(PAnsiChar(FOutputPath)));
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
  // Deliberately OFF, and it is the price of the line below. With it on,
  // AVAssetWriter holds the movie back and puts a complete file at the
  // output path only when finishWriting succeeds — measured on device, a
  // recording killed six seconds in left a file of exactly zero bytes,
  // fragments or no fragments. With it off and fragments on, the same
  // kill left 483 kB that ffprobe decoded as 117 frames of 4.0 s.
  //
  // What this costs a NORMALLY finished take is one thing only: the moov
  // atom sits after the media data instead of before it. Measured by
  // walking the boxes, a finished take is ftyp / mdat / moov with no moof
  // at all — finishWriting consolidates the fragments — so the file is an
  // ordinary MP4 in every other respect, and only a crashed one stays
  // fragmented (ftyp / mdat / moov / mdat / moof / …). Front-loaded moov
  // matters for progressive download over a network and not at all for a
  // recorder writing to a local disk.
  //
  // To revert, if that trade is ever the wrong way round: this one line
  // back to setShouldOptimizeForNetworkUse(ObjCBOOL(True)). Crash
  // recovery then loses everything, so the movieFragmentInterval below
  // should go with it.
  FWriter.setShouldOptimizeForNetworkUse(ObjCBOOL(False));
  // Before startWriting, which is where AVAssetWriter reads it. Every
  // recording is fragmented, not only the ones that go wrong: there is no
  // way to know in advance which ones those are, and the cost is a header
  // every two seconds. What it buys is that a process killed mid-take
  // leaves a file that plays up to its last fragment instead of a stub
  // with no moov atom at all.
  FWriter.setMovieFragmentInterval(MakeCMTime(MovieFragmentSeconds, 1));

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
  Previous, Retimed, Appending: CMSampleBufferRef;
  Timing: CMSampleTimingInfo;
begin
  Result := False;
  // The cheap answer, off the lock, for the overwhelmingly common case
  // of a writer that was never opened at all. It is re-asked under the
  // lock below and that is the answer that counts: Finish and Cancel
  // clear this flag from the MAIN thread while capture queues are still
  // delivering, so a read here can be stale by the time the append
  // happens.
  if not FOpen then
    Exit;
  Time := CMSampleBufferGetPresentationTimeStamp(ASampleBuffer);

  PThreadMutexLock(FLock);
  if not FOpen then
  begin
    PThreadMutexUnlock(FLock);
    Exit;
  end;
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

  // A frame from BEFORE the last stamp, which the idle heartbeat makes
  // possible and nothing else does.
  //
  // ScreenCaptureKit stamps a buffer when it captured the content and
  // delivers it some milliseconds later — measured on this machine, up to
  // 27 ms on a busy 1280x800 take. A heartbeat stamps at the moment the
  // main thread reads the clock. So a frame captured just before a
  // heartbeat fired, and delivered just after, arrives here with a
  // presentation stamp EARLIER than the one already in the file. One
  // out-of-order stamp fails AVAssetWriter terminally: the writer leaves
  // Writing state, every later append on every input is rejected, and the
  // take ends as a moov-less corpse. Reproduced by forcing the heartbeat
  // interval to 20 ms — "AVAssetWriter finished with status 3", 37 kB, no
  // recoverable movie — and estimated at roughly one idle-to-busy
  // transition in twenty at the shipped half-second.
  //
  // So the frame is retimed forward rather than trusted or dropped: the
  // smallest stamp that is strictly later than the last one, which is one
  // tick in the timescale the last one was in. The pixels are the user's
  // content and are kept; what moves is a stamp that was at most a few
  // tens of milliseconds from where it now sits. A whole backlog arriving
  // at once is retimed a tick apart each — in the written file, measured,
  // that lands them 1/600 s apart, the movie track's own resolution — so
  // the worst case is a short burst rather than a lost take, and the queue
  // depth is 5, so the backlog is small.
  //
  // Capture-queue legal, and only in the collision: CMTimeCompare and
  // CMSampleBufferCreateCopyWithNewTiming are C calls, CMSampleTimingInfo
  // is a stack record, the copy shares the original's pixels. No managed
  // type, no exception, no pixel work.
  Retimed := nil;
  Appending := ASampleBuffer;
  if (FAppended > 0) and (CMTimeCompare(Time, FLastTime) <= 0) then
  begin
    Timing.duration := CMSampleBufferGetDuration(ASampleBuffer);
    Timing.presentationTimeStamp.value := FLastTime.value + 1;
    Timing.presentationTimeStamp.timescale := FLastTime.timescale;
    Timing.presentationTimeStamp.flags := kCMTimeFlags_Valid;
    Timing.presentationTimeStamp.epoch := FLastTime.epoch;
    Timing.decodeTimeStamp := InvalidCMTime;
    if (CMSampleBufferCreateCopyWithNewTiming(nil, ASampleBuffer, 1,
      @Timing, @Retimed) <> noErr) or (Retimed = nil) then
    begin
      // The one thing that must not happen is appending it anyway. A
      // frame lost here costs a frame; an out-of-order stamp costs the
      // recording.
      Inc(FFailed);
      PThreadMutexUnlock(FLock);
      Exit;
    end;
    Time := Timing.presentationTimeStamp;
    Appending := Retimed;
  end;

  if FInput.appendSampleBuffer(Appending) then
  begin
    Inc(FAppended);
    if Retimed <> nil then
      Inc(FRetimedFrames);
    FLastTime := Time;
    // Hold on to it for the idle heartbeat: exactly one frame of
    // ScreenCaptureKit's pool is ever held, and the one held is the frame
    // AVAssetWriter was just handed anyway. Two C calls into
    // CoreFoundation — no allocation this thread has to account for, no
    // managed type, nothing that can raise. Retain before release, in
    // case the new buffer and the old are ever the same object.
    //
    // The original, not the retimed copy: the copy exists only to carry a
    // stamp, and a heartbeat re-times whatever it holds anyway.
    Previous := FLastVideoSample;
    FLastVideoSample := CMSampleBufferRetain(ASampleBuffer);
    if Previous <> nil then
      CMSampleBufferRelease(Previous);
    Result := True;
  end
  else
    Inc(FFailed);
  if Retimed <> nil then
    CMSampleBufferRelease(Retimed);
  PThreadMutexUnlock(FLock);
end;

// Everything here runs with FLock held, which is what makes it safe
// against a frame arriving on the capture queue at the same moment: that
// append takes the same mutex, so the two serialise. The lock is held
// across the copy and the append together on purpose — the retained frame
// must not be swapped out from under the copy — and both are cheap: the
// copy shares the original's pixels rather than duplicating them, and the
// append is the same call the capture path makes thirty times a second.
function TMovieWriter.EmitHeartbeatFrame(AStampSeconds: Double): Boolean;
var
  Timing: CMSampleTimingInfo;
  Beat: CMSampleBufferRef;
  Ticks, Frame: cint64;
begin
  Result := False;
  if not FOpen then
    Exit;

  PThreadMutexLock(FLock);
  // Re-asked under the lock; see AppendVideoSample.
  if not FOpen then
  begin
    PThreadMutexUnlock(FLock);
    Exit;
  end;
  // Nothing to repeat: no frame has reached the movie yet, so there is no
  // timeline to put one on either. Not counted — it is not a refusal, it
  // is the state every recording starts in.
  //
  // This is also the guard that covers a caller who asked because
  // Statistics said SessionStarted with a LastSampleSeconds of zero — the
  // session began but the first append failed. See Statistics.
  if (FLastVideoSample = nil) or not FSessionStarted then
  begin
    PThreadMutexUnlock(FLock);
    Exit;
  end;
  if FWriter.status <> AVAssetWriterStatusWriting then
  begin
    FWriterFailed := True;
    PThreadMutexUnlock(FLock);
    Exit;
  end;
  // Back-pressure, the same shape AppendVideoSample handles it in: the
  // encoder is behind, and a repeated frame is the first thing that
  // should give way. Counted, because a heartbeat that is always refused
  // is the failure this feature would have.
  if not FInput.isReadyForMoreMediaData then
  begin
    Inc(FHeartbeatRefused);
    PThreadMutexUnlock(FLock);
    Exit;
  end;
  // A frame the framework has invalidated has no pixels left to encode.
  // Checked rather than assumed: ScreenCaptureKit is not documented to
  // invalidate a buffer the client still holds, and if it ever does, this
  // is what says so out loud instead of failing the writer for good.
  if not CMSampleBufferIsValid(FLastVideoSample) then
  begin
    Inc(FHeartbeatRefused);
    ReleaseLastVideoSample;
    PThreadMutexUnlock(FLock);
    Exit;
  end;

  // The movie's own units, not seconds: the stamp is built in the last
  // frame's timescale and epoch, so every frame in the track is on one
  // scale and the comparison below is exact rather than floating-point.
  // Strictly greater is the hard requirement — an out-of-order stamp
  // fails AVAssetWriter terminally, which would cost the whole take.
  Ticks := Round(AStampSeconds * FLastTime.timescale);
  if Ticks <= FLastTime.value then
    Ticks := FLastTime.value + 1;
  // One frame at the configured rate, stated rather than left invalid.
  // Interior samples take their length from the stamp of the next one, so
  // this only ever describes the *last* frame in the track — and that one
  // is nearly always a heartbeat, since the closing one is stamped at the
  // stop. Left invalid, AVAssetWriter gives the final frame the length of
  // the gap before it, which for a still take is the heartbeat interval:
  // measured, a 14.005 s take reported a 14.518 s container duration. A
  // frame's worth is the honest answer.
  Frame := 0;
  if FFramesPerSecond > 0 then
    Frame := FLastTime.timescale div FFramesPerSecond;
  if Frame < 1 then
    Frame := 1;
  Timing.duration.value := Frame;
  Timing.duration.timescale := FLastTime.timescale;
  Timing.duration.flags := kCMTimeFlags_Valid;
  Timing.duration.epoch := 0;
  Timing.presentationTimeStamp.value := Ticks;
  Timing.presentationTimeStamp.timescale := FLastTime.timescale;
  Timing.presentationTimeStamp.flags := kCMTimeFlags_Valid;
  Timing.presentationTimeStamp.epoch := FLastTime.epoch;
  // Left to AVAssetWriter: frame reordering is off (BuildOutputSettings),
  // so decode order is presentation order and there is nothing to say.
  Timing.decodeTimeStamp := InvalidCMTime;

  Beat := nil;
  if (CMSampleBufferCreateCopyWithNewTiming(nil, FLastVideoSample, 1,
    @Timing, @Beat) <> noErr) or (Beat = nil) then
  begin
    Inc(FHeartbeatRefused);
    PThreadMutexUnlock(FLock);
    Exit;
  end;
  if FInput.appendSampleBuffer(Beat) then
  begin
    Inc(FAppended);
    Inc(FHeartbeatFrames);
    FLastTime := Timing.presentationTimeStamp;
    Result := True;
  end
  else
    Inc(FFailed);
  CMSampleBufferRelease(Beat);
  PThreadMutexUnlock(FLock);
end;

// The loudest magnitude in one PCM buffer, or -1 when the buffer is not a
// layout this reads.
//
// Capture-queue code, and written to the same rules as the cursor blit:
// no allocation, no exception, no managed type, no Objective-C message.
// Every step is a check rather than an assumption — the format
// description is asked what the bytes are, and anything that is not
// 32-bit float linear PCM is declined rather than guessed at. Interleaved
// and planar both work, because a peak does not care which channel a
// sample belongs to.
//
// The scan is capped: a peak is a peak, and reading four thousand samples
// out of a buffer answers the question "was there any sound at all" as
// well as reading all of them, at a fixed cost per buffer.
function MeasurePeak(ASampleBuffer: CMSampleBufferRef): Double;
const
  MaxSamplesScanned = 4096;
var
  Format: CMFormatDescriptionRef;
  Description: PAudioStreamBasicDescription;
  Block: CMBlockBufferRef;
  Data: Pointer;
  Total, LengthAtOffset: csize_t;
  Count, I, Step: PtrInt;
  Value: Single;
  Peak: Double;
begin
  Result := -1;
  Format := CMSampleBufferGetFormatDescription(ASampleBuffer);
  if Format = nil then
    Exit;
  Description := CMAudioFormatDescriptionGetStreamBasicDescription(Format);
  if Description = nil then
    Exit;
  if (Description^.mFormatID <> kKnipsAudioFormatLinearPCM)
    or ((Description^.mFormatFlags and kKnipsAudioFormatFlagIsFloat) = 0)
    or (Description^.mBitsPerChannel <> 32) then
    Exit;
  Block := CMSampleBufferGetDataBuffer(ASampleBuffer);
  if Block = nil then
    Exit;
  Data := nil;
  Total := 0;
  LengthAtOffset := 0;
  if CMBlockBufferGetDataPointer(Block, 0, @LengthAtOffset, @Total,
    @Data) <> noErr then
    Exit;
  // Only the contiguous run at offset zero is scanned: a block buffer can
  // be a chain, and walking one on this thread is more machinery than a
  // silence check is worth.
  if (Data = nil) or (LengthAtOffset < SizeOf(Single)) then
    Exit;
  Count := PtrInt(LengthAtOffset) div SizeOf(Single);
  // Ceiling division, so the scan really is bounded by MaxSamplesScanned:
  // a plain `div` leaves a stride one too small and reads up to twice the
  // cap (Count = 8191 with a cap of 4096 gives Step 1).
  Step := (Count + MaxSamplesScanned - 1) div MaxSamplesScanned;
  if Step < 1 then
    Step := 1;
  Peak := 0;
  I := 0;
  while I < Count do
  begin
    Value := PSingle(PByte(Data) + I * SizeOf(Single))^;
    // A NaN or an infinity compares false against everything, so this
    // rejects both without a special case: neither is louder than Peak.
    if Value > Peak then
      Peak := Value
    else if -Value > Peak then
      Peak := -Value;
    Inc(I, Step);
  end;
  if Peak > 1 then
    Peak := 1;
  Result := Peak;
end;

function TMovieWriter.AppendAudioTo(AInput: AVAssetWriterInput;
  ASampleBuffer: CMSampleBufferRef;
  var AAppended, ADroppedEarly, ADroppedStalled, AFailed: Int64;
  var APeak: Double; var AInspected: Int64): Boolean;
var
  Peak: Double;
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
  // Re-asked under the lock; see AppendVideoSample.
  if not FOpen then
  begin
    PThreadMutexUnlock(FLock);
    Exit;
  end;
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
  // After the append and outside the lock: the measurement reads the
  // buffer's own bytes, which AVAssetWriter has copied out by now, and
  // holding the mutex across a four-thousand-sample scan would put the
  // video track's appends behind it.
  if not Result then
    Exit;
  Peak := MeasurePeak(ASampleBuffer);
  if Peak < 0 then
    Exit;
  PThreadMutexLock(FLock);
  Inc(AInspected);
  if Peak > APeak then
    APeak := Peak;
  PThreadMutexUnlock(FLock);
end;

function TMovieWriter.AppendAudioSample(
  ASampleBuffer: CMSampleBufferRef): Boolean;
begin
  Result := AppendAudioTo(FAudioInput, ASampleBuffer, FAudioAppended,
    FAudioDroppedEarly, FAudioDroppedStalled, FAudioFailed, FAudioPeak,
    FAudioInspected);
end;

function TMovieWriter.AppendMicrophoneSample(
  ASampleBuffer: CMSampleBufferRef): Boolean;
begin
  Result := AppendAudioTo(FMicrophoneInput, ASampleBuffer,
    FMicrophoneAppended, FMicrophoneDroppedEarly, FMicrophoneDroppedStalled,
    FMicrophoneFailed, FMicrophonePeak, FMicrophoneInspected);
end;

function TMovieWriter.Finish(out AError: string): Boolean;
var
  WaitCount: Integer;
begin
  Result := False;
  AError := '';
  // Tested AND cleared under the lock, in one critical section with the
  // markAsFinished calls below: the capture queues read this flag to
  // decide whether to append, and clearing it outside the lock left a
  // window in which a queue had already passed its own check and was
  // waiting on the mutex this method was about to take.
  PThreadMutexLock(FLock);
  if not FOpen then
  begin
    PThreadMutexUnlock(FLock);
    AError := 'writer is not open';
    Exit;
  end;
  FOpen := False;
  FInput.markAsFinished;
  if FAudioInput <> nil then
    FAudioInput.markAsFinished;
  if FMicrophoneInput <> nil then
    FMicrophoneInput.markAsFinished;
  // The heartbeat's frame goes back to ScreenCaptureKit's pool here: the
  // inputs are finished, so nothing will be repeated again, and holding
  // it across finishWriting would keep one buffer of a stopped stream
  // alive for no reason.
  ReleaseLastVideoSample;
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
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
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
  // Under the lock for the same reason Finish clears it there.
  PThreadMutexLock(FLock);
  if not FOpen then
  begin
    PThreadMutexUnlock(FLock);
    Exit;
  end;
  FOpen := False;
  PThreadMutexUnlock(FLock);
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
  Result.AudioPeak := FAudioPeak;
  Result.AudioInspected := FAudioInspected;
  Result.MicrophonePeak := FMicrophonePeak;
  Result.MicrophoneInspected := FMicrophoneInspected;
  Result.HeartbeatFrames := FHeartbeatFrames;
  Result.HeartbeatRefused := FHeartbeatRefused;
  Result.RetimedFrames := FRetimedFrames;
  Result.WriterFailed := FWriterFailed;
  Result.SessionStarted := FSessionStarted;
  if FSessionStarted then
    Result.FirstSampleSeconds := CMTimeGetSeconds(FFirstTime)
  else
    Result.FirstSampleSeconds := 0;
  // SessionStarted and LastSampleSeconds are not the same question, and
  // the gap between them is one the heartbeat's caller walks into: the
  // session begins at the first frame that reaches startSessionAtSourceTime,
  // but FLastTime is only written by an append that SUCCEEDED. A first
  // append that failed leaves SessionStarted true and this zero, so
  // HeartbeatDue says yes against a stamp meaning "never" and asks for a
  // heartbeat at once. What saves it is EmitHeartbeatFrame's own guard:
  // no successful append means FLastVideoSample is nil, and there is
  // nothing to repeat, so it returns without appending or counting. The
  // two are kept in step by that, not by luck — but they are two
  // conditions, and this is the note that says so.
  if FSessionStarted and (FAppended > 0) then
    Result.LastSampleSeconds := CMTimeGetSeconds(FLastTime)
  else
    Result.LastSampleSeconds := 0;
  if FSessionStarted and (FAppended > 0) then
    Result.Duration := CMTimeGetSeconds(FLastTime)
      - CMTimeGetSeconds(FFirstTime)
  else
    Result.Duration := 0;
  PThreadMutexUnlock(FLock);
end;

{$ENDIF}

end.

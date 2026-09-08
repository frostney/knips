unit Knips.Capture.Stream;

// One ScreenCaptureKit stream: display or window filter, optional source
// rect, fixed output size and frame rate. Video sample buffers arrive on
// a private dispatch queue and are handed to OnSample after the frame
// status attachment says they are complete.
//
// With CapturesAudio set, the same output object is registered a second
// time for SCStreamOutputTypeAudio on its own queue; those buffers reach
// OnSample as skAudio without the frame-status filter, which is video-only.
// CapturesMicrophone does the same for SCStreamOutputTypeMicrophone
// (macOS 15) on a third queue, delivering skMicrophone.
//
// The SCStreamOutput object is assembled at run time (Knips.ObjC.Runtime)
// rather than declared as an objcclass — see ADR-0002. Its one method is
// the plain cdecl routine StreamOutputSampleBuffer below.
//
// UpdateSourceRect moves the captured rectangle while the stream runs,
// through SCStream.updateConfiguration:completionHandler:. The output
// width and height never change — they are the writer's dimensions and
// AVAssetWriter will not have them move — so a smaller sourceRect scaled
// into the same output is a zoom and a sliding one is a pan. Unlike start
// and stop, this one is fire-and-forget: the caller ticks thirty times a
// second and the newest rectangle wins, so nothing here waits, and at most
// one update is ever in flight.
//
// Threading: OnSample runs on the capture queue, not the main thread.
// There is no cthreads in this program, so nothing on that path may raise,
// use try..finally, or WriteLn (the prototype's rules, carried over).

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cblocks}
{$modeswitch cvar}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  CocoaAll,
  Knips.Capture.CoreMedia,
  Knips.Capture.ScreenCaptureKit,
  Knips.ObjC.Runtime,
  Knips.Options,
  MacOSAll;

// The Microphone TCC grant is asked of AVFoundation, which is where the
// answer lives whatever framework then uses the device.
{$linkframework AVFoundation}

type
  TSampleKind = (skVideo, skAudio, skMicrophone);

  // The Microphone privacy grant for THIS binary — TCC is per binary,
  // exactly like Screen Recording and the Camera.
  TMicrophoneAccess = (maAuthorized, maDenied, maRestricted, maUndecided);

  TSampleHandler = procedure(ASampleBuffer: CMSampleBufferRef;
    AKind: TSampleKind) of object;

  TStreamGeometry = record
    PixelWidth: Integer;
    PixelHeight: Integer;
    FramesPerSecond: Integer;
    ShowsCursor: Boolean;
    HasSourceRect: Boolean;
    // Points, relative to the filtered content's origin.
    SourceRect: CGRect;
    // System audio: SCK mixes it and delivers it on the audio output.
    CapturesAudio: Boolean;
    AudioSampleRate: Integer;
    AudioChannelCount: Integer;
    // Microphone: a separate SCK output, in the device's native format.
    // The rate and channel count above do not apply to it.
    CapturesMicrophone: Boolean;
  end;

  TScreenStream = class
  private
    FFilter: SCContentFilter;
    FGeometry: TStreamGeometry;
    FStream: SCStream;
    FOutput: id;
    FQueue: dispatch_queue_t;
    FAudioQueue: dispatch_queue_t;
    FMicrophoneQueue: dispatch_queue_t;
    FActive: Boolean;
    FOnSample: TSampleHandler;
    FLastError: string;
    // The configuration handed to the most recent updateConfiguration:.
    // Held rather than released on the spot: the call is asynchronous and
    // ScreenCaptureKit does not document whether it copies. Released when
    // the next one replaces it, which is only ever after the previous
    // update's handler has run.
    FUpdateConfiguration: SCStreamConfiguration;
    FSupportsLiveUpdate: Boolean;
    FLastSentRect: CGRect;
    FHasSentRect: Boolean;
    FLiveUpdatesSent: Int64;
    // What GUpdatesCompleted/GUpdatesFailed read when this stream
    // started. The counters are process-global and are deliberately never
    // zeroed — an abandoned handler from a previous stream may still be
    // out there — so this stream's own totals are differences.
    FBaseUpdatesCompleted: Int64;
    FBaseUpdatesFailed: Int64;
    // GUpdatesFailed as it stood when the last update was issued. When it
    // has moved on by the next call, that update was refused and
    // FLastSentRect records a rectangle the stream never adopted.
    FFailuresAtLastSend: Int64;
    FConsecutiveFailures: Integer;
    // stopCaptureWithCompletionHandler: never called back inside the
    // timeout. See Stop.
    FStopUnconfirmed: Boolean;
    // Called on the capture queue by StreamOutputSampleBuffer.
    procedure DeliverSample(ASampleBuffer: CMSampleBufferRef;
      AOutputType: NSInteger);
    // One place builds the stream configuration, so a live update cannot
    // drift from the configuration the capture started with: everything
    // but the source rectangle comes from FGeometry either way.
    function BuildConfiguration(AHasSourceRect: Boolean;
      const ASourceRect: CGRect; out AConfiguration: SCStreamConfiguration;
      out AError: string): Boolean;
    procedure ReleaseUpdateConfiguration;
    procedure DrainPendingUpdate;
    function LastSendWasRefused: Boolean;
  public
    // Retains the filter for the stream's lifetime.
    constructor Create(const AFilter: SCContentFilter;
      const AGeometry: TStreamGeometry);
    destructor Destroy; override;
    function Start: Boolean;
    procedure Stop;
    // Moves the captured rectangle without touching the output size.
    // False when the stream cannot do it at all (not running, no source
    // rectangle configured, an empty rectangle, or a build failure that
    // leaves a message in LastError); True when the rectangle is either
    // on its way or already where it was asked to be.
    //
    // Fire-and-forget by design. A call made while an update is still in
    // flight is dropped and reported True: the caller is a thirty-hertz
    // animator, LastSentRect is deliberately left alone, and the next
    // tick therefore carries a *newer* rectangle than this one would
    // have. Latest wins, and nothing queues up behind the framework.
    function UpdateSourceRect(const ARect: CGRect): Boolean;
    property Active: Boolean read FActive;
    property LastError: string read FLastError;
    // True when the stop was asked for and ScreenCaptureKit never
    // confirmed it. Not a failure — the teardown runs regardless — but
    // the one state in which frames may still have been arriving while
    // the writer was being finalised, so the recording says so rather
    // than reporting a clean stop.
    property StopUnconfirmed: Boolean read FStopUnconfirmed;
    property OnSample: TSampleHandler read FOnSample write FOnSample;
    // False when this stream has no rectangle to move, when the running
    // framework has no updateConfiguration:, and from the moment
    // MaxConsecutiveUpdateFailures refusals in a row have made the live
    // effects give up for the rest of the recording. A caller that
    // animates should watch this and stop when it goes False, or it will
    // go on moving things that no longer follow the capture.
    property SupportsLiveUpdate: Boolean read FSupportsLiveUpdate;
    // Diagnostics for the recording report: how many updates this stream
    // handed to ScreenCaptureKit, how many it completed and how many it
    // refused (both differences against a baseline taken at Start, since
    // the underlying counters are process-global and never reset), and
    // the last NSError code seen — which is process-wide and therefore
    // only meaningful when LiveUpdatesFailed is above zero.
    property LiveUpdatesSent: Int64 read FLiveUpdatesSent;
    // The rectangle ScreenCaptureKit was last *told* to read, which is
    // not always the one the caller last asked for: a request inside the
    // epsilon, or one that arrived while an update was in flight, is
    // dropped and leaves this alone. Big Cursor places its sprite from
    // this rather than from the request, so the drawn pointer sits where
    // the capture actually is (Knips.Recording.CursorOverlay).
    //
    // Main-thread only, like every other reader of the update machinery,
    // and meaningless before the first send: HasSentRect says whether
    // there has been one.
    property LastSentRect: CGRect read FLastSentRect;
    property HasSentRect: Boolean read FHasSentRect;
    function LiveUpdatesCompleted: Int64;
    function LiveUpdatesFailed: Int64;
    function LiveUpdateErrorCode: NSInteger;
  end;

// The runtime-built output class, registered on first use. Exposed so
// `knips probe` can verify registration without starting a stream.
function EnsureStreamOutputClass: pobjc_class;

function StreamOutputClassName: string;

// True when this macOS has ScreenCaptureKit microphone capture
// (setCaptureMicrophone:, macOS 15+). Probe prints it; Start refuses
// cleanly without it.
function StreamSupportsMicrophone: Boolean;

// AVFoundation's Microphone privacy status for this binary — TCC is per
// binary, exactly like Screen Recording and the Camera.
//
// Read this as *advice*, not as a gate, and the distinction is measured
// rather than assumed. On macOS 26 a signed bundle whose status read
// maUndecided recorded 421 760 microphone samples through
// ScreenCaptureKit at −39 dB, with no prompt answered, and the status
// still read maUndecided afterwards. ScreenCaptureKit's
// captureMicrophone therefore does not go through the gate this API
// reports, so a caller that *refused* on maDenied could refuse a
// recording that would have worked — a worse failure than the one it
// would be preventing.
//
// What it is good for is telling the user, before they record, that
// something about the microphone looks wrong. What actually proves a
// microphone worked is the sample count in the recording's report. A
// source that delivers nothing is invisible from inside the stream —
// setCaptureMicrophone: takes, startCapture succeeds, and the output
// simply never produces a sample, the same shape the camera's own denied
// grant takes (docs/spikes/0001, "Camera") — so counting what arrived is
// the one check that does not depend on knowing which gate said no.
function MicrophoneAccess: TMicrophoneAccess;

// The one-line warning a doubtful microphone grant is worth, or '' when
// there is nothing to say.
function MicrophoneAccessMessage(AAccess: TMicrophoneAccess): string;

// True when SCStream carries updateConfiguration:completionHandler:, which
// Zoom on Click and Follow Mouse are built on. The header puts it at
// macOS 12.3, the same version as SCStream itself, so this should never be
// False — it is checked rather than assumed because an unrecognised
// selector is an Objective-C exception no Pascal handler can catch, and
// this one would be sent thirty times a second into a live recording.
// `knips probe` prints it.
function StreamSupportsLiveUpdate: Boolean;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Knips.ObjC.TypeEncoding,
  Knips.Recording.LiveMath;

type
  // An external binding, not a class of ours (ADR-0002 allows exactly
  // this) — and only the one class method the grant check needs.
  // Knips.App.Camera declares the same class for the *video* grant; the
  // two are deliberately separate, because a unit that must not depend on
  // the camera window should not have to.
  AVCaptureDevice = objcclass external (NSObject)
    class function AuthorizationStatusForMediaType(
      AMediaType: NSString): NSInteger;
      message 'authorizationStatusForMediaType:';
  end;

var
  // AVMediaTypeAudio, and it is the audio one on purpose: the microphone
  // grant is 'soun' (read back and checked on device), where the camera's
  // is 'vide'.
  AVMediaTypeAudio: NSString; cvar; external;

const
  // AVAuthorizationStatus (AVCaptureDevice.h), the same four values
  // Knips.App.Camera spells out for the camera grant.
  AVAuthorizationStatusNotDetermined = 0;
  AVAuthorizationStatusRestricted = 1;
  AVAuthorizationStatusDenied = 2;
  AVAuthorizationStatusAuthorized = 3;

  OutputClassName = 'KnipsStreamOutput';
  OutputSuperclassName = 'NSObject';
  OutputProtocolName = 'SCStreamOutput';
  SampleSelector = 'stream:didOutputSampleBuffer:ofType:';
  StreamClassName = 'SCStream';
  UpdateSelector = 'updateConfiguration:completionHandler:';
  VideoQueueLabel = 'knips.capture.video';
  // SCK delivers audio on its own output; giving it its own queue keeps
  // audio delivery from waiting behind a video append. The two appends
  // still serialise on the writer's mutex, but only for the append itself.
  AudioQueueLabel = 'knips.capture.audio';
  // Likewise for the microphone output: SCK delivers it independently of
  // the system mix, so it must not queue behind either of the others.
  MicrophoneQueueLabel = 'knips.capture.mic';
  // Frames SCK may hold while the writer catches up during a keyframe.
  QueueDepth = 5;
  CompletionTimeoutSlices = 5000;
  StopTimeoutSlices = 3000;
  // How long a *second* Start waits for a first one's abandoned handler
  // before refusing. Short: this only ever runs after a timeout, and the
  // caller (the menu-bar app) must not freeze on a retry.
  StalePendingSlices = 1000;
  // How long Stop waits for an outstanding live reconfiguration. Short on
  // purpose: this is a property change on a running stream, not a capture
  // start, so it either lands in milliseconds or it is not going to.
  PendingUpdateSlices = 300;
  // How many refusals in a row before the live effects give up for the
  // rest of the recording. The caller retries about twenty times a
  // second, so a framework that has decided to say no would otherwise be
  // asked forever, silently. Five is enough to ride out a one-off and
  // short enough that a real refusal is noticed in a quarter of a second.
  MaxConsecutiveUpdateFailures = 5;

var
  GOutputClass: pobjc_class = nil;
  GStartError: NSError = nil;
  GStartReady: Boolean = False;
  // True from the moment startCaptureWithCompletionHandler: is issued
  // until its handler runs. A Start that times out leaves this set, and
  // the framework may still call the handler minutes later — see
  // DrainPendingStart.
  GStartPending: Boolean = False;
  GStopReady: Boolean = False;
  // True from the moment updateConfiguration:completionHandler: is issued
  // until its handler runs. One at a time, process-wide — the same shape
  // as the start flag, and for the same reason: the handler is a global
  // cdecl procedure with nowhere to carry a back-pointer. Only one
  // TScreenStream exists at a time (the app makes a fresh session per
  // recording), and Stop drains this before the next one can start.
  GUpdatePending: Boolean = False;
  // Written on a ScreenCaptureKit queue and read on the main thread;
  // unsynchronised on purpose, because only one update is ever
  // outstanding, so only one thread is ever incrementing.
  //
  // Monotonic for the life of the process and never reset. A stream that
  // gave up waiting for an update (DrainPendingUpdate) leaves a handler
  // the framework may still run minutes later, and zeroing these would
  // let that handler push a *later* stream's totals negative. Each stream
  // snapshots them at Start and reports differences instead.
  //
  // GUpdatesFailed is not only a diagnostic: UpdateSourceRect watches it
  // to notice that the rectangle it last issued was refused.
  GUpdatesCompleted: Int64 = 0;
  GUpdatesFailed: Int64 = 0;
  GUpdateErrorCode: NSInteger = 0;

// The SCStreamOutput method. Runs on the capture queue.
procedure StreamOutputSampleBuffer(ASelf: id; ACommand: SEL; AStream: id;
  ASampleBuffer: CMSampleBufferRef; AOutputType: NSInteger); cdecl;
var
  Owner: Pointer;
begin
  Owner := GetPointerIvar(ASelf, OwnerIvarName);
  if (Owner = nil) or (ASampleBuffer = nil) then
    Exit;
  TScreenStream(Owner).DeliverSample(ASampleBuffer, AOutputType);
end;

// ScreenCaptureKit calls both completion handlers on one of its own
// queues, never the main thread (measured: pthread_main_np() = 0 in both).
// They are therefore capture-thread code — no exceptions, no WriteLn, no
// managed-type writes — and only set globals the main thread reads while
// it pumps the run loop. The pending flag is cleared *last* so a main
// thread that sees it cleared has already seen the result written.
procedure StartCompletionHandler(AError: id); cdecl;
begin
  GStartError := NSError(AError);
  if GStartError <> nil then
    GStartError.retain;
  GStartReady := True;
  GStartPending := False;
end;

procedure StopCompletionHandler(AError: id); cdecl;
begin
  GStopReady := True;
end;

// The live-reconfiguration handler. Same queue rules as the two above,
// and a little stricter: it does not retain the NSError, because nobody
// waits for this one. Only its `code` is kept — a plain integer read
// through one message send — so the report can say *why* an update was
// refused without this handler ever touching a managed type or the heap.
// The pending flag is cleared last, exactly as in StartCompletionHandler.
procedure UpdateCompletionHandler(AError: id); cdecl;
begin
  if AError <> nil then
  begin
    Inc(GUpdatesFailed);
    GUpdateErrorCode := NSError(AError).code;
  end
  else
    Inc(GUpdatesCompleted);
  GUpdatePending := False;
end;

// Drops whatever a previous start left behind, including a retained
// NSError nobody read.
procedure ClearStartResult;
begin
  if GStartError <> nil then
  begin
    GStartError.release;
    GStartError := nil;
  end;
  GStartReady := False;
end;

// A start that timed out abandoned its handler, but the framework can
// still run it — and a global handler cannot tell which Start it belongs
// to, so a late one would falsely complete the next attempt (FActive with
// nothing capturing, and a zero-frame file). Only the CLI was immune,
// because it never retried. Wait the stale handler out; refuse the new
// start rather than proceed on an ambiguous flag.
function DrainPendingStart(out AError: string): Boolean;
var
  WaitCount: Integer;
begin
  Result := True;
  AError := '';
  if not GStartPending then
    Exit;
  WaitCount := 0;
  while GStartPending and (WaitCount < StalePendingSlices) do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
    Inc(WaitCount);
  end;
  if GStartPending then
  begin
    AError := 'a previous capture start is still pending; try again in a '
      + 'moment';
    Result := False;
  end;
end;

function StreamOutputClassName: string;
begin
  Result := OutputClassName;
end;

function StreamSupportsMicrophone: Boolean;
var
  Configuration: SCStreamConfiguration;
begin
  Configuration := SCStreamConfiguration(SCStreamConfiguration.alloc.init);
  if Configuration = nil then
    Exit(False);
  Result := RespondsToSelector(id(Configuration), 'setCaptureMicrophone:');
  Configuration.release;
end;

function MicrophoneAccess: TMicrophoneAccess;
begin
  case AVCaptureDevice.authorizationStatusForMediaType(AVMediaTypeAudio) of
    AVAuthorizationStatusAuthorized: Result := maAuthorized;
    AVAuthorizationStatusDenied: Result := maDenied;
    AVAuthorizationStatusRestricted: Result := maRestricted;
  else
    Result := maUndecided;
  end;
end;

function MicrophoneAccessMessage(AAccess: TMicrophoneAccess): string;
begin
  case AAccess of
    maDenied:
      Result := 'microphone access is denied — if this recording has a '
        + 'silent microphone track, allow Knips in System Settings › '
        + 'Privacy & Security › Microphone';
    maRestricted:
      Result := 'microphone access is restricted on this Mac — this '
        + 'recording may end up with a silent microphone track';
  else
    Result := '';
  end;
end;

// Asked of the class rather than of an instance: SCStream's -init is
// NS_UNAVAILABLE, so there is no instance to be had without a filter and a
// configuration, and `knips probe` has neither.
function StreamSupportsLiveUpdate: Boolean;
begin
  Result := ClassImplementsSelector(LookUpClass(StreamClassName),
    UpdateSelector);
end;

function EnsureStreamOutputClass: pobjc_class;
var
  Builder: TRuntimeClassBuilder;
begin
  if GOutputClass = nil then
  begin
    GOutputClass := LookUpClass(OutputClassName);
    if GOutputClass = nil then
    begin
      Builder := TRuntimeClassBuilder.Create(OutputClassName,
        OutputSuperclassName);
      try
        if not Builder.AddPointerIvar(OwnerIvarName) then
          raise EObjCRuntime.Create('class_addIvar failed for '
            + OwnerIvarName);
        if not Builder.AddMethod(SampleSelector, @StreamOutputSampleBuffer,
          MethodTypeEncoding(otVoid, [otObject, otPointer, otInteger])) then
          raise EObjCRuntime.Create('class_addMethod failed for '
            + SampleSelector);
        // A missing protocol is survivable: SCStream dispatches by selector.
        Builder.AddProtocol(OutputProtocolName);
        GOutputClass := Builder.Register;
      finally
        Builder.Free;
      end;
    end;
  end;
  Result := GOutputClass;
end;

// SCK tags every video buffer with a status; only complete frames have
// pixels to encode. Reads CoreFoundation only, so it is safe on the
// capture queue.
function FrameStatus(ASampleBuffer: CMSampleBufferRef): Integer;
var
  Attachments: CFArrayRef;
  Attachment: CFDictionaryRef;
  Status: CFNumberRef;
  Value: SInt32;
begin
  Result := SCFrameStatusComplete;
  Attachments := CMSampleBufferGetSampleAttachmentsArray(ASampleBuffer,
    False);
  if (Attachments = nil) or (CFArrayGetCount(Attachments) = 0) then
    Exit;
  Attachment := CFDictionaryRef(CFArrayGetValueAtIndex(Attachments, 0));
  if Attachment = nil then
    Exit;
  Status := CFNumberRef(CFDictionaryGetValue(Attachment,
    SCStreamFrameInfoStatus));
  if Status = nil then
    Exit;
  Value := 0;
  if CFNumberGetValue(Status, kCFNumberSInt32Type, @Value) then
    Result := Value;
end;

{ TScreenStream }

constructor TScreenStream.Create(const AFilter: SCContentFilter;
  const AGeometry: TStreamGeometry);
begin
  inherited Create;
  FFilter := AFilter;
  FFilter.retain;
  FGeometry := AGeometry;
end;

destructor TScreenStream.Destroy;
begin
  if FActive then
    Stop
  else if FStream <> nil then
  begin
    // Start failed after the output was attached (addStreamOutput or
    // startCapture error/timeout). A capture start may still be in
    // flight — permission granted just after the timeout, say — so
    // detach the owner first: a late callback on either queue finds nil
    // and returns, instead of calling into this freed object.
    if FOutput <> nil then
      SetPointerIvar(FOutput, OwnerIvarName, nil);
    FStream.release;
    FStream := nil;
  end;
  if FOutput <> nil then
    ReleaseInstance(FOutput);
  if FQueue <> nil then
    dispatch_release(FQueue);
  if FAudioQueue <> nil then
    dispatch_release(FAudioQueue);
  if FMicrophoneQueue <> nil then
    dispatch_release(FMicrophoneQueue);
  ReleaseUpdateConfiguration;
  if FFilter <> nil then
    FFilter.release;
  inherited Destroy;
end;

procedure TScreenStream.DeliverSample(ASampleBuffer: CMSampleBufferRef;
  AOutputType: NSInteger);
begin
  if not Assigned(FOnSample) then
    Exit;
  if AOutputType = SCStreamOutputTypeScreen then
  begin
    if CMSampleBufferGetImageBuffer(ASampleBuffer) = nil then
      Exit;
    if FrameStatus(ASampleBuffer) <> SCFrameStatusComplete then
      Exit;
    FOnSample(ASampleBuffer, skVideo);
  end
  else if AOutputType = SCStreamOutputTypeAudio then
    FOnSample(ASampleBuffer, skAudio)
  else if AOutputType = SCStreamOutputTypeMicrophone then
    FOnSample(ASampleBuffer, skMicrophone);
end;

// Everything but the source rectangle comes from FGeometry, so the
// configuration a live update sends is the one the capture started with
// in every other respect — dimensions, rate, cursor, audio. The output
// size in particular is never derived from the source rectangle: it is
// the writer's, and AVAssetWriter will not have it change mid-file.
//
// scalesToFit goes on for *any* source rectangle, not only a region's:
// with it off the header says the output "only scales down", so a zoomed
// (smaller) rectangle would be letterboxed into the fixed output instead
// of filling it, which is the whole effect.
function TScreenStream.BuildConfiguration(AHasSourceRect: Boolean;
  const ASourceRect: CGRect; out AConfiguration: SCStreamConfiguration;
  out AError: string): Boolean;
var
  Configuration: SCStreamConfiguration;
begin
  Result := False;
  AConfiguration := nil;
  AError := '';
  Configuration := SCStreamConfiguration(SCStreamConfiguration.alloc.init);
  if Configuration = nil then
  begin
    AError := 'SCStreamConfiguration init failed';
    Exit;
  end;
  Configuration.setWidth(FGeometry.PixelWidth);
  Configuration.setHeight(FGeometry.PixelHeight);
  Configuration.setMinimumFrameInterval(CMTimeMake(1,
    FGeometry.FramesPerSecond));
  Configuration.setPixelFormat(kCVPixelFormatType_32BGRA);
  Configuration.setShowsCursor(ObjCBOOL(FGeometry.ShowsCursor));
  Configuration.setQueueDepth(QueueDepth);
  if FGeometry.CapturesAudio then
  begin
    Configuration.setCapturesAudio(ObjCBOOL(True));
    Configuration.setSampleRate(FGeometry.AudioSampleRate);
    Configuration.setChannelCount(FGeometry.AudioChannelCount);
  end;
  if FGeometry.CapturesMicrophone then
  begin
    // captureMicrophone is macOS 15+; the project floor is 13. On an
    // older OS the send would raise an ObjC unrecognized-selector
    // exception no Pascal handler can catch — abort with a message
    // instead of a SIGABRT and a zero-byte file.
    if not RespondsToSelector(id(Configuration), 'setCaptureMicrophone:') then
    begin
      AError := 'microphone capture needs macOS 15 or newer';
      Configuration.release;
      Exit;
    end;
    Configuration.setCaptureMicrophone(ObjCBOOL(True));
    // nil is the documented "system default microphone"; setting it
    // explicitly keeps the v1 choice visible rather than implied.
    Configuration.setMicrophoneCaptureDeviceID(nil);
  end;
  if AHasSourceRect then
  begin
    Configuration.setSourceRect(ASourceRect);
    Configuration.setScalesToFit(ObjCBOOL(True));
  end;
  AConfiguration := Configuration;
  Result := True;
end;

procedure TScreenStream.ReleaseUpdateConfiguration;
begin
  if FUpdateConfiguration <> nil then
  begin
    FUpdateConfiguration.release;
    FUpdateConfiguration := nil;
  end;
end;

// An update still in flight has a handler that will fire on a framework
// queue. Letting it outlive the stream leaves the pending flag set for the
// *next* recording, whose first updates would then all be dropped. Pumping
// is what lets the handler run at all, since the main thread is where the
// caller is.
procedure TScreenStream.DrainPendingUpdate;
var
  WaitCount: Integer;
begin
  WaitCount := 0;
  while GUpdatePending and (WaitCount < PendingUpdateSlices) do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
    Inc(WaitCount);
  end;
  if not GUpdatePending then
    Exit;

  // Abandoned rather than waited out forever: leaving the flag set would
  // silently disable the feature for the rest of the process's life. Two
  // things are given up here, both deliberately.
  //
  // The configuration is **leaked** — the reference is dropped without a
  // release. ScreenCaptureKit is, as far as this code can tell, still
  // applying it; whether it retained a copy is undocumented, and a
  // release that turns out to have been the last one is a use-after-free
  // inside the framework. One SCStreamConfiguration is a few hundred
  // bytes, this path needs a stream that has stopped answering for three
  // hundred milliseconds, and the process is a screen recorder, not a
  // server. Unowned beats freed here.
  FUpdateConfiguration := nil;
  // And a handler that arrives after this can clear a later update's flag
  // early — at most one extra update in flight for one tick, corrected by
  // the next one — or add one to the global counters after a later stream
  // has taken its baseline, which overstates that recording's totals by
  // one. Both are diagnostics-grade at a frequency of approximately
  // never; the counters are never zeroed, so neither can go negative.
  GUpdatePending := False;
end;

function TScreenStream.LiveUpdatesCompleted: Int64;
begin
  Result := GUpdatesCompleted - FBaseUpdatesCompleted;
  if Result < 0 then
    Result := 0;
end;

function TScreenStream.LiveUpdatesFailed: Int64;
begin
  Result := GUpdatesFailed - FBaseUpdatesFailed;
  if Result < 0 then
    Result := 0;
end;

function TScreenStream.LiveUpdateErrorCode: NSInteger;
begin
  Result := GUpdateErrorCode;
end;

// Whether the update this stream last issued was refused. FLastSentRect
// records what was *asked for*, not what the stream adopted, so a refusal
// strands it on a rectangle that never took: every later rectangle within
// the epsilon of that stranded value would then be deduped away, and a
// clip would stay zoomed for its remainder while the animator believed it
// had eased out. The completion handler runs on a framework queue and can
// only touch globals, so the healing is done here, from the sending side:
// the failure counter is remembered at each send and compared at the next.
function TScreenStream.LastSendWasRefused: Boolean;
begin
  Result := FHasSentRect and (GUpdatesFailed <> FFailuresAtLastSend);
end;

// Main-thread only, like every other reader of the update machinery.
// The completion handler runs on a framework queue and may only touch
// plain globals; this side reads GUpdatePending (one update in flight,
// coalesce the rest) and, via LastSendWasRefused above, GUpdatesFailed
// (a refusal breaks the epsilon dedupe so the next rect resends).
// Measured: updateConfiguration takes effect when ISSUED — the
// completion is a later acknowledgement, not the compositor switching —
// so followers positioned from the send timeline are already in step
// with the content, to 0.7pt on device.
function TScreenStream.UpdateSourceRect(const ARect: CGRect): Boolean;
var
  Configuration: SCStreamConfiguration;
  Error: string;
  Refused: Boolean;
begin
  Result := False;
  if not FActive or (FStream = nil) or not FSupportsLiveUpdate then
    Exit;
  // A stream that started without a source rectangle captures its whole
  // content and has nothing to move; giving it one now would change what
  // the output means halfway through the file. The caller asks for the
  // rectangle up front (TRecordingOptions.LiveSourceRect).
  if not FGeometry.HasSourceRect then
    Exit;
  if (ARect.size.width <= 0) or (ARect.size.height <= 0) then
    Exit;

  Refused := LastSendWasRefused;
  if Refused then
  begin
    FFailuresAtLastSend := GUpdatesFailed;
    Inc(FConsecutiveFailures);
    if FConsecutiveFailures >= MaxConsecutiveUpdateFailures then
    begin
      // Twenty retries a second into a framework that keeps saying no is
      // a silent storm. Stop for the rest of the recording and say so
      // once; the capture carries on at whatever rectangle last took.
      FSupportsLiveUpdate := False;
      FLastError := Format('live zoom/pan disabled: ScreenCaptureKit '
        + 'refused %d source-rect updates in a row (last error %d)',
        [FConsecutiveFailures, Integer(GUpdateErrorCode)]);
      Exit;
    end;
    if FLastError = '' then
      FLastError := Format('ScreenCaptureKit refused a live source-rect '
        + 'update (error %d); retrying', [Integer(GUpdateErrorCode)]);
  end
  else if FHasSentRect and not GUpdatePending then
    // The last send resolved and nothing failed: the streak is over.
    FConsecutiveFailures := 0;

  // Already there. Not an error, and the common case once the animation
  // has settled: the animator keeps ticking for the whole recording.
  // Skipped entirely after a refusal — the rectangle it would compare
  // against is one the stream never adopted.
  //
  // The tolerance and the comparison both come from
  // Knips.Recording.LiveMath — LiveSourceRectEpsilon and LiveRectsClose
  // — rather than from a private copy of the number here. There were two
  // 0.5s in the tree saying the same thing, one of them documented and
  // unit-tested with nothing production reading it and the other doing
  // the actual work four lines at a time. One of them had to be the
  // source of truth, and the tested one is the obvious choice.
  if not Refused and FHasSentRect
    and LiveRectsClose(
    LiveRect(ARect.origin.x, ARect.origin.y,
    ARect.size.width, ARect.size.height),
    LiveRect(FLastSentRect.origin.x, FLastSentRect.origin.y,
    FLastSentRect.size.width, FLastSentRect.size.height),
    LiveSourceRectEpsilon) then
    Exit(True);
  // Coalescing, such as it is: drop this one and leave FLastSentRect
  // alone, so the next tick — a thirtieth of a second away — sends a
  // newer rectangle than this one. Latest wins; nothing queues.
  if GUpdatePending then
    Exit(True);

  if not BuildConfiguration(True, ARect, Configuration, Error) then
  begin
    FLastError := Error;
    Exit;
  end;
  // The previous configuration has done its work — its update completed,
  // or this call would have been dropped above.
  ReleaseUpdateConfiguration;
  FUpdateConfiguration := Configuration;
  GUpdatePending := True;
  // Snapshot before the send, so the handler cannot move the counter
  // between the send and the record of where it stood.
  FFailuresAtLastSend := GUpdatesFailed;
  FStream.updateConfiguration_completionHandler(Configuration,
    UpdateCompletionHandler);
  FLastSentRect := ARect;
  FHasSentRect := True;
  Inc(FLiveUpdatesSent);
  Result := True;
end;

function TScreenStream.Start: Boolean;
var
  Configuration: SCStreamConfiguration;
  Error: NSError;
  WaitCount: Integer;
begin
  Result := False;
  if FActive then
    Exit(True);
  FLastError := '';

  // Nothing below may run while another Start's handler is outstanding.
  if not DrainPendingStart(FLastError) then
    Exit;
  ClearStartResult;
  // Baselines, not a reset: an abandoned handler from a previous stream
  // may still increment the globals, and zeroing them would let it push
  // this stream's totals negative. See the declarations above.
  FBaseUpdatesCompleted := GUpdatesCompleted;
  FBaseUpdatesFailed := GUpdatesFailed;
  FFailuresAtLastSend := GUpdatesFailed;
  FConsecutiveFailures := 0;
  FLiveUpdatesSent := 0;

  EnsureStreamOutputClass;

  if not BuildConfiguration(FGeometry.HasSourceRect, FGeometry.SourceRect,
    Configuration, FLastError) then
    Exit;
  try
    FStream := SCStream(SCStream.alloc.initWithFilter_configuration_delegate(
      FFilter, Configuration, nil));
    if FStream = nil then
    begin
      FLastError := 'SCStream init failed';
      Exit;
    end;
  finally
    Configuration.release;
  end;
  FSupportsLiveUpdate := FGeometry.HasSourceRect
    and RespondsToSelector(id(FStream), UpdateSelector);
  FLastSentRect := FGeometry.SourceRect;
  FHasSentRect := FGeometry.HasSourceRect;

  FOutput := InstantiateClass(GOutputClass);
  if FOutput = nil then
  begin
    FLastError := 'could not instantiate ' + OutputClassName;
    Exit;
  end;
  SetPointerIvar(FOutput, OwnerIvarName, Self);

  FQueue := dispatch_queue_create(VideoQueueLabel, nil);

  Error := nil;
  if not FStream.addStreamOutput_type_sampleHandlerQueue_error(FOutput,
    SCStreamOutputTypeScreen, FQueue, @Error) then
  begin
    if Error <> nil then
      FLastError := 'addStreamOutput: '
        + string(Error.localizedDescription.UTF8String)
    else
      FLastError := 'addStreamOutput failed';
    Exit;
  end;

  if FGeometry.CapturesAudio then
  begin
    FAudioQueue := dispatch_queue_create(AudioQueueLabel, nil);
    Error := nil;
    if not FStream.addStreamOutput_type_sampleHandlerQueue_error(FOutput,
      SCStreamOutputTypeAudio, FAudioQueue, @Error) then
    begin
      if Error <> nil then
        FLastError := 'addStreamOutput (audio): '
          + string(Error.localizedDescription.UTF8String)
      else
        FLastError := 'addStreamOutput (audio) failed';
      Exit;
    end;
  end;

  if FGeometry.CapturesMicrophone then
  begin
    FMicrophoneQueue := dispatch_queue_create(MicrophoneQueueLabel, nil);
    Error := nil;
    if not FStream.addStreamOutput_type_sampleHandlerQueue_error(FOutput,
      SCStreamOutputTypeMicrophone, FMicrophoneQueue, @Error) then
    begin
      if Error <> nil then
        FLastError := 'addStreamOutput (microphone): '
          + string(Error.localizedDescription.UTF8String)
      else
        FLastError := 'addStreamOutput (microphone) failed';
      Exit;
    end;
  end;

  ClearStartResult;
  GStartPending := True;
  FStream.startCaptureWithCompletionHandler(StartCompletionHandler);
  WaitCount := 0;
  while (not GStartReady) and (WaitCount < CompletionTimeoutSlices) do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
    Inc(WaitCount);
  end;
  if not GStartReady then
  begin
    FLastError := 'timed out starting capture (Screen Recording permission?)';
    Exit;
  end;
  if GStartError <> nil then
  begin
    FLastError := 'startCapture: '
      + string(GStartError.localizedDescription.UTF8String);
    ClearStartResult;
    Exit;
  end;

  FActive := True;
  Result := True;
end;

procedure TScreenStream.Stop;
var
  WaitCount: Integer;
begin
  if not FActive or (FStream = nil) then
    Exit;
  // Before the stop, not after: while the stream is still running the
  // update either completes in a millisecond or never will, and this is
  // the only place that can clear the flag for the next recording.
  DrainPendingUpdate;
  GStopReady := False;
  FStream.stopCaptureWithCompletionHandler(StopCompletionHandler);
  WaitCount := 0;
  while (not GStopReady) and (WaitCount < StopTimeoutSlices) do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
    Inc(WaitCount);
  end;
  // The stop is not confirmable, so this is not a failure and the
  // teardown below runs either way: whatever the stream is doing, the
  // owner has to be detached and the object released or a late callback
  // finds a freed session. But it is not nothing, either — an
  // unconfirmed stop is the one state in which frames may still be
  // arriving while the writer is being finalised, which is exactly the
  // shape of a take that finishes short. Recorded rather than swallowed,
  // so FinishCapture can say so.
  if not GStopReady then
    FStopUnconfirmed := True;
  if (not GStopReady) and (FLastError = '') then
    FLastError := 'the capture did not confirm its stop within '
      + IntToStr(StopTimeoutSlices) + ' run-loop slices; the movie was '
      + 'finalised anyway and may be a frame or two short';
  // Detach before the stream goes away so a late callback finds no owner.
  if FOutput <> nil then
    SetPointerIvar(FOutput, OwnerIvarName, nil);
  FStream.release;
  FStream := nil;
  FActive := False;
  FSupportsLiveUpdate := False;
  ReleaseUpdateConfiguration;
end;

{$ENDIF}

end.

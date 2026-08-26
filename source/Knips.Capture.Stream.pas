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
// Threading: OnSample runs on the capture queue, not the main thread.
// There is no cthreads in this program, so nothing on that path may raise,
// use try..finally, or WriteLn (the prototype's rules, carried over).

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cblocks}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  CocoaAll,
  Knips.Capture.CoreMedia,
  Knips.Capture.ScreenCaptureKit,
  Knips.ObjC.Runtime,
  MacOSAll;

type
  TSampleKind = (skVideo, skAudio, skMicrophone);

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
    // Called on the capture queue by StreamOutputSampleBuffer.
    procedure DeliverSample(ASampleBuffer: CMSampleBufferRef;
      AOutputType: NSInteger);
  public
    // Retains the filter for the stream's lifetime.
    constructor Create(const AFilter: SCContentFilter;
      const AGeometry: TStreamGeometry);
    destructor Destroy; override;
    function Start: Boolean;
    procedure Stop;
    property Active: Boolean read FActive;
    property LastError: string read FLastError;
    property OnSample: TSampleHandler read FOnSample write FOnSample;
  end;

// The runtime-built output class, registered on first use. Exposed so
// `knips probe` can verify registration without starting a stream.
function EnsureStreamOutputClass: pobjc_class;

function StreamOutputClassName: string;

// True when this macOS has ScreenCaptureKit microphone capture
// (setCaptureMicrophone:, macOS 15+). Probe prints it; Start refuses
// cleanly without it.
function StreamSupportsMicrophone: Boolean;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Knips.ObjC.TypeEncoding;

const
  OutputClassName = 'KnipsStreamOutput';
  OutputSuperclassName = 'NSObject';
  OutputProtocolName = 'SCStreamOutput';
  OwnerIvarName = 'knipsOwner';
  SampleSelector = 'stream:didOutputSampleBuffer:ofType:';
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
  RunLoopSliceSeconds = 0.001;
  // How long a *second* Start waits for a first one's abandoned handler
  // before refusing. Short: this only ever runs after a timeout, and the
  // caller (the menu-bar app) must not freeze on a retry.
  StalePendingSlices = 1000;

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
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, RunLoopSliceSeconds, False);
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

  EnsureStreamOutputClass;

  Configuration := SCStreamConfiguration.alloc.init;
  try
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
        FLastError := 'microphone capture needs macOS 15 or newer';
        Exit;
      end;
      Configuration.setCaptureMicrophone(ObjCBOOL(True));
      // nil is the documented "system default microphone"; setting it
      // explicitly keeps the v1 choice visible rather than implied.
      Configuration.setMicrophoneCaptureDeviceID(nil);
    end;
    if FGeometry.HasSourceRect then
    begin
      Configuration.setSourceRect(FGeometry.SourceRect);
      Configuration.setScalesToFit(ObjCBOOL(True));
    end;

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
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, RunLoopSliceSeconds, False);
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
  GStopReady := False;
  FStream.stopCaptureWithCompletionHandler(StopCompletionHandler);
  WaitCount := 0;
  while (not GStopReady) and (WaitCount < StopTimeoutSlices) do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, RunLoopSliceSeconds, False);
    Inc(WaitCount);
  end;
  // Detach before the stream goes away so a late callback finds no owner.
  if FOutput <> nil then
    SetPointerIvar(FOutput, OwnerIvarName, nil);
  FStream.release;
  FStream := nil;
  FActive := False;
end;

{$ENDIF}

end.

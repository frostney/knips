unit Opname.Capture.Stream;

// One ScreenCaptureKit stream: display or window filter, optional source
// rect, fixed output size and frame rate. Video sample buffers arrive on
// a private dispatch queue and are handed to OnSample after the frame
// status attachment says they are complete.
//
// With CapturesAudio set, the same output object is registered a second
// time for SCStreamOutputTypeAudio on its own queue; those buffers reach
// OnSample as skAudio without the frame-status filter, which is video-only.
//
// The SCStreamOutput object is assembled at run time (Opname.ObjC.Runtime)
// rather than declared as an objcclass — see ADR-0002. Its one method is
// the plain cdecl routine StreamOutputSampleBuffer below.
//
// Threading: OnSample runs on the capture queue, not the main thread.
// There is no cthreads in this program, so nothing on that path may raise,
// use try..finally, or WriteLn (the prototype's rules, carried over).

{$I Shared.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cblocks}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  CocoaAll,
  MacOSAll,
  Opname.Capture.CoreMedia,
  Opname.Capture.ScreenCaptureKit,
  Opname.ObjC.Runtime;

type
  TSampleKind = (skVideo, skAudio);

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
  end;

  TScreenStream = class
  private
    FFilter: SCContentFilter;
    FGeometry: TStreamGeometry;
    FStream: SCStream;
    FOutput: id;
    FQueue: dispatch_queue_t;
    FAudioQueue: dispatch_queue_t;
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
// `opname probe` can verify registration without starting a stream.
function EnsureStreamOutputClass: pobjc_class;

function StreamOutputClassName: string;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Opname.ObjC.TypeEncoding;

const
  OutputClassName = 'OpnameStreamOutput';
  OutputSuperclassName = 'NSObject';
  OutputProtocolName = 'SCStreamOutput';
  OwnerIvarName = 'opnameOwner';
  SampleSelector = 'stream:didOutputSampleBuffer:ofType:';
  VideoQueueLabel = 'opname.capture.video';
  // SCK delivers audio on its own output; giving it its own queue keeps
  // audio delivery from waiting behind a video append. The two appends
  // still serialise on the writer's mutex, but only for the append itself.
  AudioQueueLabel = 'opname.capture.audio';
  // Frames SCK may hold while the writer catches up during a keyframe.
  QueueDepth = 5;
  CompletionTimeoutSlices = 5000;
  StopTimeoutSlices = 3000;
  RunLoopSliceSeconds = 0.001;

var
  GOutputClass: pobjc_class = nil;
  GStartError: NSError = nil;
  GStartReady: Boolean = False;
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

procedure StartCompletionHandler(AError: id); cdecl;
begin
  GStartError := NSError(AError);
  if GStartError <> nil then
    GStartError.retain;
  GStartReady := True;
end;

procedure StopCompletionHandler(AError: id); cdecl;
begin
  GStopReady := True;
end;

function StreamOutputClassName: string;
begin
  Result := OutputClassName;
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
    FOnSample(ASampleBuffer, skAudio);
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

  GStartError := nil;
  GStartReady := False;
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
    GStartError.release;
    GStartError := nil;
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

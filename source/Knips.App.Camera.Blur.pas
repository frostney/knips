unit Knips.App.Camera.Blur;

// Portrait-style background blur for the camera picture-in-picture: the
// person sharp, the room behind them blurred. Knips.App.Camera owns one
// of these and switches the window between two display paths — the
// AVCaptureVideoPreviewLayer when blur is off, this one when it is on.
//
// **There is no programmatic route to the system Portrait effect, and
// that was checked rather than assumed.** AVFoundation's
// AVCaptureDevicePortraitEffect category on this SDK (macOS 26.5,
// AVCaptureDevice.h) declares exactly two members and both are
// `readonly`: `+isPortraitEffectEnabled`, "a class property indicating
// whether the Portrait Effect feature is currently enabled in Control
// Center", and `-isPortraitEffectActive` for one device. The only
// writable thing anywhere near it is
// `+showSystemUserInterface:AVCaptureSystemUserInterfaceVideoEffects`,
// which "brings up the system user interface and deep links to the
// appropriate module" — it opens Control Center's Video Effects panel
// and returns immediately. That is a request to the *user*, applies to
// every app on the Mac at once, and cannot be read back as a setting of
// ours. So the effect is built here.
//
// The pipeline, per frame, on the video-data queue:
//
//   CMSampleBuffer ─▶ CVPixelBuffer (BGRA)
//        │
//        ├─▶ Vision: VNGeneratePersonSegmentationRequest through a
//        │   VNSequenceRequestHandler ─▶ a one-component mask buffer,
//        │   scaled up to the frame's extent
//        │
//        └─▶ CoreImage: CIGaussianBlur over the clamped frame, then
//            CIBlendWithMask(sharp over blurred, through the mask),
//            then the mirror transform
//                 │
//                 └─▶ CIContext.createCGImage ─▶ CALayer.contents
//
// **Everything that can be built once is built once.** The CIContext,
// the Vision request, the sequence handler, the one-element request
// array, the two filter-parameter dictionaries and the four CoreImage
// filter/key names are created at Start and reused for every frame. What
// the queue body still allocates is the CGImage it hands the layer (and
// releases), the autorelease pool it drains, the CIImages of the
// pipeline — CIImage is a lazy recipe object, so each frame builds a
// short chain of them — the NSNumber-free dictionary writes, and
// whatever CoreImage and Vision allocate internally. "Allocation-light",
// not allocation-free: the point of the pre-building is that no *kernel
// compile* and no model load happen per frame. A CIContext created per
// frame would recompile the
// filter kernels every time, and VNGeneratePersonSegmentationRequest is
// a VNStatefulRequest — its header says it "may hold on to previous
// masks to improve temporal stability", so a fresh request per frame
// would also be a worse mask.
//
// **The delegate is a runtime-built class** (ADR-0002):
// KnipsCameraOutput, one plain cdecl Pascal routine registered with
// class_addMethod, carrying the same knipsOwner ivar every other class
// in this app does. AVCaptureVideoDataOutput dispatches by selector, so
// the protocol is added best-effort exactly as SCStream's output object
// does it.
//
// **Queue rules.** The video-data queue is a serial GCD queue this unit
// creates and the RTL never adopts — the same standing as
// ScreenCaptureKit's capture queue, and the same discipline applies to
// everything reachable from the delegate body: no exceptions, no
// try..finally, no WriteLn, no managed-type writes outside the mutex.
// What is different from the SCK path, and is a deliberate exception, is
// that the *heavy* work happens there: Vision and CoreImage both run on
// this queue because there is nowhere else for them to run — this
// program has no cthreads on Darwin (ADR-0005) and creates no other
// queues. Their allocations
// are Objective-C's, not the RTL's, which is why they are safe: the
// rules exist to keep FPC's process-global exception frame chain and its
// managed-type refcounts off a foreign thread, and neither framework
// touches either. One NSAutoreleasePool is opened and drained around
// each frame rather than trusting GCD's own, because a pool that drains
// "at unspecified times" holding a few frames of 640x480 buffers is a
// memory graph nobody can predict.
//
// **The layer is written from that queue too.** CALayer is thread-safe,
// but a background thread has no run loop to commit an implicit
// transaction, so the contents assignment is wrapped in an explicit
// CATransaction with actions disabled — without the commit the picture
// would simply never appear, and without the disable every frame would
// start a quarter-second cross-fade.
//
// **Mirroring is done in CoreImage, not by the layer.** The preview
// layer's AVCaptureConnection mirroring does not exist on this path —
// there is no preview layer — and a transform on the hosted root layer
// would fight the corner radius and the mask. One
// CGAffineTransform(-1, 0, 0, 1, width, 0) on the composited image is
// free by comparison: CoreImage folds it into the same kernel pass it
// was already running, and what reaches the layer is a mirrored bitmap,
// which is also what makes the result verifiable from a screenshot.
//
// **Honest degradation.** alwaysDiscardsLateVideoFrames is YES, so a
// queue that cannot keep up is handed fewer frames rather than falling
// behind; nothing ever queues. Beyond that, SegmentationStride runs
// Vision on every Nth frame and reuses the last mask for the others —
// the mask is the expensive half and a person does not move far in
// 33 ms, so a stride of 2 buys most of the frame rate back at a mask
// that is one frame stale. The statistics below are what decides: they
// are read by the caller and reported, rather than the frame rate being
// asserted.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cvar}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  ctypes,
  SysUtils,

  CocoaAll,
  Knips.Capture.PThreadMutex,
  Knips.ObjC.Runtime,
  MacOSAll;

{$linkframework AVFoundation}
{$linkframework CoreImage}
{$linkframework CoreMedia}
{$linkframework QuartzCore}
{$linkframework Vision}

type
  // CoreMedia's opaque sample buffer. Declared here rather than borrowed
  // from source/capture: the App layer does not reach into the vendored
  // capture bindings, and this is one type and one function.
  CMSampleBufferRef = Pointer;

  // A serial GCD queue. The delegate's queue "may not be NULL" and "a
  // serial dispatch queue must be used to guarantee that video frames
  // will be delivered in order" (AVCaptureVideoDataOutput.h).
  dispatch_queue_t = Pointer;

// The frame's pixels, owned by the sample buffer. NULL for a buffer that
// carries no image.
function CMSampleBufferGetImageBuffer(
  ASampleBuffer: CMSampleBufferRef): CVPixelBufferRef;
  external name '_CMSampleBufferGetImageBuffer';

function Dispatch_queue_create(ALabel: PAnsiChar;
  AAttributes: Pointer): dispatch_queue_t;
  external name '_dispatch_queue_create';
procedure Dispatch_release(AObject: Pointer);
  external name '_dispatch_release';

const
  // kCVPixelFormatType_32BGRA — 'BGRA'. The one format both CoreImage
  // and Vision take without a conversion of our own.
  PixelFormatBGRA = $42475241;

  // VNGeneratePersonSegmentationRequestQualityLevel
  // (VNGeneratePersonSegmentationRequest.h). Accurate is the framework's
  // default and is a matting refinement over Balanced — far too slow for
  // 30 Hz; Fast "generates a low accuracy segmentation mask that can be
  // used in streaming scenarios on devices that have a neural engine".
  VisionQualityAccurate = 0;
  VisionQualityBalanced = 1;
  VisionQualityFast = 2;

type
  // Which mask Vision is asked for. Measured against the frame budget in
  // docs/architecture.md; Fast is the shipped default.
  TCameraBlurQuality = (cbqFast, cbqBalanced, cbqAccurate);

  // What the queue measured, snapshotted under the mutex. Every field is
  // plain — no managed types cross the thread boundary.
  TCameraBlurStatistics = record
    // Frames handed to the delegate, and frames that reached the layer.
    Received: Int64;
    Rendered: Int64;
    // Frames that produced no picture: no image buffer, a CoreImage
    // render that came back nil. Not the same as a mask that failed —
    // that one still renders, blurred whole.
    Failed: Int64;
    // How often Vision actually ran, against Received: the stride made
    // visible.
    Segmented: Int64;
    // Vision refusals. The frame still renders.
    SegmentationFailed: Int64;
    // Seconds spent inside the delegate body, and inside Vision alone.
    ProcessingSeconds: Double;
    SegmentationSeconds: Double;
    // CFAbsoluteTime of the first and last rendered frame, which is what
    // an achieved frame rate is computed from.
    FirstRenderedAt: Double;
    LastRenderedAt: Double;
  end;

  // The blur path. Created by TCameraPreview, handed the session it
  // shares with the preview and the layer it draws into.
  //
  // Start adds an AVCaptureVideoDataOutput to the running session and
  // begins delivering; Stop removes it and drops everything. Both are
  // main-thread only. Nothing here retains the session or the layer:
  // they outlive this object by construction, and TCameraPreview.Stop
  // runs before either goes.
  TCameraBlur = class
  private
    FSession: id;
    FLayer: CALayer;
    FOutput: id;
    FDelegate: id;
    FQueue: dispatch_queue_t;
    FContext: CIContext;
    FRequest: id;
    FHandler: id;
    FRequests: NSArray;
    FBlurParameters: NSMutableDictionary;
    FBlendParameters: NSMutableDictionary;
    // The four CoreImage names the frame body would otherwise build from
    // Pascal strings thirty times a second. They never change, so they
    // are made and retained once beside the dictionaries they key.
    FBlurFilterName: NSString;
    FBlendFilterName: NSString;
    FBlendBackgroundName: NSString;
    FBlendMaskName: NSString;
    // The last mask Vision produced, already scaled to the frame's
    // extent, retained across frames so a stride can reuse it. Touched
    // only on the video queue.
    FMask: CIImage;
    FRunning: Boolean;
    FMirrored: Boolean;
    FQuality: TCameraBlurQuality;
    FStride: Integer;
    FRadius: Double;
    FStatistics: TCameraBlurStatistics;
    // The statistics record is nine plain scalars, so nothing managed
    // crosses the thread boundary — but a snapshot read while the queue
    // is half way through updating it is a torn one, and this is the
    // project's own primitive for exactly that (the capture path uses it
    // for the writer's counters).
    FLock: TPThreadMutex;
    function BuildPipeline(out AError: string): Boolean;
    // The frame body, split out so HandleSample can drain its
    // autorelease pool on exactly one path however this returns.
    procedure ProcessSample(ASampleBuffer: CMSampleBufferRef);
    // The whole of the work, from the frame's pixels onwards. Separate
    // from ProcessSample only because the camera is not the only thing
    // that can hand this pipeline a frame: MeasureOffline pushes
    // synthetic ones through it, and a measurement that skipped a step
    // would be measuring something other than what the camera runs.
    procedure ProcessPixelBuffer(ABuffer: CVPixelBufferRef);
    // Runs Vision over the frame and replaces FMask when it answers.
    // Never raises; a refusal leaves the previous mask in place.
    procedure RefreshMask(APixelBuffer: CVPixelBufferRef;
      AWidth, AHeight: Double);
    procedure ReleaseMask;
    procedure TearDown;
    // TearDown with the frame mutex held, which is how every caller
    // outside the video queue has to do it — see the note above Stop.
    procedure TearDownLocked;
  public
    constructor Create;
    destructor Destroy; override;
    // Attaches to ASession and starts delivering into ALayer. False with
    // a reason when the output cannot be added or the pipeline cannot be
    // built; the caller then leaves the preview path alone.
    function Start(ASession: id; ALayer: CALayer; AMirrored: Boolean;
      out AError: string): Boolean;
    procedure Stop;
    // Called by the runtime-built delegate's method body, on the video
    // queue.
    procedure HandleSample(ASampleBuffer: CMSampleBufferRef);
    // A consistent snapshot of what the queue has measured. Read by
    // `knips probe` through MeasureOffline, and by a human under lldb
    // when a live camera's rate is in question — there is no menu item
    // that shows it, on purpose: a frame-rate counter in a recorder's
    // menu is noise until something is wrong. Kept rather than trimmed
    // because it is the only way to answer "is the blur keeping up on
    // this Mac", which is the one question this feature raises.
    function Statistics: TCameraBlurStatistics;
    // Frames per second actually delivered to the layer, or 0 before
    // there are two of them to measure between.
    function AchievedFramesPerSecond: Double;
    // Mean milliseconds inside the delegate body, and inside Vision.
    function MeanFrameMilliseconds: Double;
    function MeanSegmentationMilliseconds: Double;
    // The pipeline measured with no camera attached: AFrames synthetic
    // frames of AWidth x AHeight pushed through the *same* Vision request,
    // the same CoreImage graph and the same createCGImage as a camera
    // frame takes, on the calling thread, into a layer of this object's
    // own. Statistics afterwards are the answer.
    //
    // It exists because the camera cannot be the only way to find out
    // what this costs. The Camera TCC grant is per binary and per
    // *bundle*, so a plain `knips probe` from a shell has no camera at
    // all — and "does the blur hold 30 Hz on this Mac" is exactly the
    // question probe is for. Vision's segmentation network runs over
    // whatever it is given at a cost set by the frame's size and the
    // quality level, not by whether there is a person in it, so a
    // synthetic frame measures the real thing; what it cannot measure is
    // how good the mask looks, which is a matter for eyes and a camera.
    function MeasureOffline(AWidth, AHeight, AFrames: Integer;
      out AError: string): Boolean;
    property Running: Boolean read FRunning;
    // Which mask Vision is asked for, and how often, and how hard the
    // background is blurred. All three are read on the video queue, so
    // all three are set before Start and left alone.
    //
    // **Nothing in knips writes the last two.** They are the tuning
    // point, kept assignable rather than frozen into the constants
    // below, and the only writers today are a debugger and a
    // hand-edited probe — the same standing as TCameraPreview.Blur's
    // own note about who reads it. Raising SegmentationStride above 1
    // has a documented consequence in HandleSegmentation (the reused
    // mask would track the newest frame), which is exactly why the knob
    // is here to be found rather than buried.
    property Quality: TCameraBlurQuality read FQuality write FQuality;
    property SegmentationStride: Integer read FStride write FStride;
    property Radius: Double read FRadius write FRadius;
  end;

// Registers KnipsCameraOutput once per process, the same way
// EnsureCameraClasses registers the view. `knips probe` gates on it.
procedure EnsureCameraBlurClasses;

function CameraBlurOutputClassName: string;

// Whether this Mac has the two frameworks' classes at all. Vision's
// person segmentation is macOS 12 and the project floor is 13, so this
// answers YES everywhere the app runs — but a class lookup is cheaper
// than finding out from a nil that only shows up as a black window.
function CameraBlurSupported: Boolean;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Knips.ObjC.TypeEncoding;

type
  // --- AVFoundation ------------------------------------------------
  //
  // AVCaptureVideoDataOutput and the two AVCaptureSession selectors this
  // unit needs. Knips.App.Camera declares the rest of the session; these
  // are the members only the blur path uses, and they live with it.
  AVCaptureOutput = objcclass external (NSObject)
  end;

  AVCaptureVideoDataOutput = objcclass external (AVCaptureOutput)
    procedure SetVideoSettings(ASettings: NSDictionary);
      message 'setVideoSettings:';
    procedure SetAlwaysDiscardsLateVideoFrames(ADiscards: ObjCBOOL);
      message 'setAlwaysDiscardsLateVideoFrames:';
    // "The sampleBufferCallbackQueue parameter may not be NULL, except
    // when setting the sampleBufferDelegate to nil otherwise
    // -setSampleBufferDelegate:queue: throws an
    // NSInvalidArgumentException" — AVCaptureVideoDataOutput.h. Stop
    // therefore passes nil and nil together, never one of them.
    procedure SetSampleBufferDelegate_queue(ADelegate: id;
      AQueue: dispatch_queue_t); message 'setSampleBufferDelegate:queue:';
  end;

  // The three session selectors the blur path adds to the ones
  // Knips.App.Camera already binds. Deliberately NOT a redeclaration of
  // AVCaptureSession and deliberately not an objccategory either: a
  // category has to name the real class, which would mean importing
  // Knips.App.Camera's binding into this unit and giving the two units
  // one shared declaration to keep in step. This is a *phantom* external
  // class — a name the Objective-C runtime never has to resolve, because
  // nothing here sends a class message to it. Every use is a cast of an
  // existing AVCaptureSession instance, and the message goes out by
  // selector to the real object. (KnipsCIContextOptions above is a real
  // objccategory because CIContext's own class *is* in scope, and the
  // selector it adds is a class method that needs the metaclass.)
  //
  // canAddOutput: is not politeness — "an AVCaptureOutput instance can
  // only be added to a session using -addOutput: if -canAddOutput:
  // returns YES, otherwise an NSInvalidArgumentException is thrown",
  // and an Objective-C exception is not catchable from Pascal.
  AVCaptureSessionOutputs = objcclass external (NSObject)
    function CanAddOutput(AOutput: id): ObjCBOOL; message 'canAddOutput:';
    procedure AddOutput(AOutput: id); message 'addOutput:';
    procedure RemoveOutput(AOutput: id); message 'removeOutput:';
  end;

  // --- Vision ------------------------------------------------------
  VNRequest = objcclass external (NSObject)
    function Results: NSArray; message 'results';
  end;

  VNGeneratePersonSegmentationRequest = objcclass external (VNRequest)
    procedure SetQualityLevel(ALevel: NSUInteger); message 'setQualityLevel:';
  end;

  VNPixelBufferObservation = objcclass external (NSObject)
    // CF_RETURNS_NOT_RETAINED: the observation owns it.
    function PixelBuffer: CVPixelBufferRef; message 'pixelBuffer';
  end;

  // The handler for a *sequence* of images rather than one image.
  // VNGeneratePersonSegmentationRequest is a VNStatefulRequest, so this
  // is the handler its temporal stability is defined against — and it is
  // created once instead of a VNImageRequestHandler per frame.
  VNSequenceRequestHandler = objcclass external (NSObject)
    function PerformRequests_onCVPixelBuffer_error(ARequests: NSArray;
      APixelBuffer: CVPixelBufferRef; AError: NSErrorPtr): ObjCBOOL;
      message 'performRequests:onCVPixelBuffer:error:';
  end;

  // --- CoreImage ---------------------------------------------------
  //
  // FPC 3.2.2's CocoaAll has CIImage and CIContext, but its CIContext
  // predates +contextWithOptions: (10.4-era bindings). One external
  // category adds the constructor; everything else this unit needs —
  // imageWithCVPixelBuffer:, imageByApplyingFilter:withInputParameters:,
  // imageByClampingToExtent, imageByApplyingTransform:, extent,
  // createCGImage:fromRect: — is already there.
  KnipsCIContextOptions = objccategory external (CIContext)
    class function ContextWithOptions(AOptions: NSDictionary): CIContext;
      message 'contextWithOptions:';
  end;

var
  // kCIContextCacheIntermediates (CIContext.h, macOS 10.12+): "an
  // NSNumber wrapping a BOOL … controls whether the context will cache
  // intermediate images". Passed NO because the intermediates of a graph
  // that never sees the same input twice can never be reused.
  //
  // **What it did not do, measured, so nobody chases it twice.** The
  // offline measurement's peak resident set climbs with the number of
  // frames rendered and then stops: 74 MB at 10 frames, 186 MB at 100,
  // 423 MB at 300, 663 MB at 600 — and still 663 MB at 900 and at 1500,
  // against a 27 MB baseline for a `knips displays`. That is a bounded
  // working set of about 640 MB (Metal, Vision's model, CoreImage's own
  // pools), not a leak, and this option moves it by nothing at all: the
  // same run with the cache left on peaks within a percent of the same
  // figure. It is kept because it is the right answer for a stream of
  // unique frames, not because it bought anything here.
  kCIContextCacheIntermediates: NSString; cvar; external;

// The four CoreVideo entry points MeasureOffline needs to build a frame
// of its own. Declared here for the reason CMSampleBufferGetImageBuffer
// is: the App layer does not reach into the vendored capture bindings,
// and these are four functions.
function CVPixelBufferCreate(AAllocator: CFAllocatorRef; AWidth,
  AHeight: csize_t; APixelFormat: OSType; AAttributes: CFDictionaryRef;
  ABufferOut: Pointer): CVReturn; external name '_CVPixelBufferCreate';
function CVPixelBufferLockBaseAddress(ABuffer: CVPixelBufferRef;
  AFlags: cuint64): CVReturn;
  external name '_CVPixelBufferLockBaseAddress';
function CVPixelBufferUnlockBaseAddress(ABuffer: CVPixelBufferRef;
  AFlags: cuint64): CVReturn;
  external name '_CVPixelBufferUnlockBaseAddress';
function CVPixelBufferGetBaseAddress(
  ABuffer: CVPixelBufferRef): Pointer;
  external name '_CVPixelBufferGetBaseAddress';
function CVPixelBufferGetBytesPerRow(
  ABuffer: CVPixelBufferRef): csize_t;
  external name '_CVPixelBufferGetBytesPerRow';

const
  OutputClassName = 'KnipsCameraOutput';
  OutputSuperclassName = 'NSObject';
  OutputProtocolName = 'AVCaptureVideoDataOutputSampleBufferDelegate';
  OwnerIvarName = 'knipsOwner';
  SampleSelector = 'captureOutput:didOutputSampleBuffer:fromConnection:';
  QueueLabel = 'knips.camera.blur';

  // CoreImage filter names and their parameter keys. Strings because
  // that is what CoreImage's own API takes; the two keys are the ones
  // CIFilter.h exports as kCIInputBackgroundImageKey and
  // kCIInputMaskImageKey.
  GaussianBlurFilter = 'CIGaussianBlur';
  BlurRadiusKey = 'inputRadius';
  BlendWithMaskFilter = 'CIBlendWithMask';
  BlendBackgroundKey = 'inputBackgroundImage';
  BlendMaskKey = 'inputMaskImage';

  // The blur, in **source** pixels — and the source is not what anybody
  // looks at, which is the whole reason this number is what it is. The
  // feed is 640x480 (the camera window asks for
  // AVCaptureSessionPreset640x480) and the window is 240x180 points, so
  // on a 2x display the composited frame is shown at 480x360: every
  // source pixel of blur arrives on screen as 0.75 of a backing pixel.
  // A radius that looks right in a 640-wide still is three quarters of
  // itself by the time it is a picture-in-picture.
  //
  // 28 is a twenty-third of the frame width, and about 10.5 points — a
  // sixteenth of the window's height — once that scaling is done.
  //
  // **Measured** rather than chosen by eye, on a real 640x480 frame put
  // through this exact chain (imageByClampingToExtent -> CIGaussianBlur
  // -> imageByCroppingToRect), as the mean absolute luma difference
  // between pixels 1, 4 and 16 apart — the last of which is the scale
  // at which a room's objects read as objects:
  //
  //   radius   1 px     4 px    16 px   (share of the source's own)
  //   12      4.74 %  11.15 %  31.74 %  the old value
  //   24      3.10 %   7.28 %  21.14 %
  //   28      2.81 %   6.60 %  19.21 %  shipped
  //   40      2.33 %   5.46 %  16.02 %
  //
  // So this is 2.33x the kernel and takes out two fifths of the
  // mid-scale structure 12 left behind. Past about 40 the curve is flat:
  // more radius stops buying softness and starts buying halo, because
  // the background is blurred from the *whole* frame — the person
  // included — so a wider kernel smears more of the person's own colour
  // out to where a Fast-quality mask's edge is. Getting past that is not
  // a bigger number: it is a feathered mask, or a background inpainted
  // before it is blurred, which is what the system Portrait effect does
  // and what this would have to become to go further.
  DefaultBlurRadius = 28.0;
  // Vision every frame until something measured says otherwise.
  DefaultSegmentationStride = 1;

var
  GOutputClass: pobjc_class = nil;

function CameraBlurOutputClassName: string;
begin
  Result := OutputClassName;
end;

function CameraBlurSupported: Boolean;
begin
  Result := (LookUpClass('VNGeneratePersonSegmentationRequest') <> nil)
    and (LookUpClass('VNSequenceRequestHandler') <> nil)
    and (LookUpClass('CIContext') <> nil)
    and (LookUpClass('AVCaptureVideoDataOutput') <> nil);
end;

{ The runtime-built delegate (ADR-0002). One method, the same knipsOwner
  ivar every other class in this app carries, and no try..except — this
  body runs on the video-data queue, where the exception frame chain is
  process-global and an exception has nowhere to go. Everything it calls
  is written not to raise. }

procedure CameraOutputSampleBuffer(ASelf: id; ACommand: SEL; AOutput: id;
  ASampleBuffer: CMSampleBufferRef; AConnection: id); cdecl;
var
  Owner: Pointer;
begin
  Owner := GetPointerIvar(ASelf, OwnerIvarName);
  if (Owner = nil) or (ASampleBuffer = nil) then
    Exit;
  TCameraBlur(Owner).HandleSample(ASampleBuffer);
end;

procedure EnsureCameraBlurClasses;
var
  Builder: TRuntimeClassBuilder;
begin
  if GOutputClass <> nil then
    Exit;
  GOutputClass := LookUpClass(OutputClassName);
  if GOutputClass <> nil then
    Exit;
  Builder := TRuntimeClassBuilder.Create(OutputClassName,
    OutputSuperclassName);
  try
    if not Builder.AddPointerIvar(OwnerIvarName) then
      raise EObjCRuntime.Create('class_addIvar failed for ' + OwnerIvarName);
    if not Builder.AddMethod(SampleSelector, @CameraOutputSampleBuffer,
      MethodTypeEncoding(otVoid, [otObject, otPointer, otObject])) then
      raise EObjCRuntime.Create('class_addMethod failed for '
        + SampleSelector);
    // Best effort, exactly as the SCStream output object does it:
    // AVCaptureVideoDataOutput dispatches by selector, and a protocol
    // only exists at run time when some loaded image references it.
    Builder.AddProtocol(OutputProtocolName);
    GOutputClass := Builder.Register;
  finally
    Builder.Free;
  end;
end;

{ Core Animation from a thread with no run loop. Without the explicit
  commit the assignment below is never flushed and the picture simply
  never appears; without the disable, every single frame starts a
  quarter-second cross-fade against the one before it. }

procedure BeginLayerChange;
begin
  CATransaction.begin_;
  CATransaction.setDisableActions(True);
end;

procedure EndLayerChange;
begin
  CATransaction.commit;
end;

function PascalToNSString(const AValue: string): NSString; inline;
begin
  Result := NSString.stringWithUTF8String(PAnsiChar(AValue));
end;

function VisionQualityOf(AQuality: TCameraBlurQuality): NSUInteger;
begin
  case AQuality of
    cbqBalanced: Result := VisionQualityBalanced;
    cbqAccurate: Result := VisionQualityAccurate;
  else
    Result := VisionQualityFast;
  end;
end;

{ TCameraBlur }

constructor TCameraBlur.Create;
begin
  inherited Create;
  FQuality := cbqFast;
  FStride := DefaultSegmentationStride;
  FRadius := DefaultBlurRadius;
  PThreadMutexInit(FLock);
end;

destructor TCameraBlur.Destroy;
begin
  Stop;
  PThreadMutexDestroy(FLock);
  inherited Destroy;
end;

function TCameraBlur.BuildPipeline(out AError: string): Boolean;
var
  Options, Settings: NSMutableDictionary;
  RequestClass, HandlerClass: pobjc_class;
begin
  Result := False;
  AError := '';

  // See kCIContextCacheIntermediates above: NO, or the pipeline grows by
  // a frame's worth of memory for every frame it renders.
  Options := NSMutableDictionary.dictionaryWithCapacity(1);
  Options.setObject_forKey(NSNumber.numberWithBool(False),
    id(kCIContextCacheIntermediates));
  FContext := CIContext.contextWithOptions(Options);
  if FContext = nil then
  begin
    AError := 'CoreImage could not create a rendering context';
    Exit;
  end;
  FContext.retain;

  RequestClass := LookUpClass('VNGeneratePersonSegmentationRequest');
  HandlerClass := LookUpClass('VNSequenceRequestHandler');
  if (RequestClass = nil) or (HandlerClass = nil) then
  begin
    AError := 'Vision has no person segmentation on this Mac';
    Exit;
  end;
  FRequest := InstantiateClass(RequestClass);
  FHandler := InstantiateClass(HandlerClass);
  if (FRequest = nil) or (FHandler = nil) then
  begin
    AError := 'the person segmentation request could not be created';
    Exit;
  end;
  VNGeneratePersonSegmentationRequest(FRequest).setQualityLevel(
    VisionQualityOf(FQuality));
  // performRequests: takes an array, and it is the same array every
  // frame — built once rather than thirty times a second.
  FRequests := NSArray.arrayWithObject(FRequest);
  FRequests.retain;

  // The two parameter dictionaries, mutated per frame rather than
  // rebuilt. Both are read synchronously inside
  // imageByApplyingFilter:withInputParameters:, so reuse on one thread
  // is safe.
  FBlurFilterName := PascalToNSString(GaussianBlurFilter);
  FBlurFilterName.retain;
  FBlendFilterName := PascalToNSString(BlendWithMaskFilter);
  FBlendFilterName.retain;
  FBlendBackgroundName := PascalToNSString(BlendBackgroundKey);
  FBlendBackgroundName.retain;
  FBlendMaskName := PascalToNSString(BlendMaskKey);
  FBlendMaskName.retain;
  FBlurParameters := NSMutableDictionary.dictionaryWithCapacity(1);
  FBlurParameters.retain;
  FBlurParameters.setObject_forKey(NSNumber.numberWithDouble(FRadius),
    id(PascalToNSString(BlurRadiusKey)));
  FBlendParameters := NSMutableDictionary.dictionaryWithCapacity(2);
  FBlendParameters.retain;

  Settings := NSMutableDictionary.dictionaryWithCapacity(1);
  Settings.setObject_forKey(NSNumber.numberWithUnsignedInt(PixelFormatBGRA),
    id(kCVPixelBufferPixelFormatTypeKey));

  FOutput := InstantiateClass(LookUpClass('AVCaptureVideoDataOutput'));
  if FOutput = nil then
  begin
    AError := 'AVCaptureVideoDataOutput could not be created';
    Exit;
  end;
  AVCaptureVideoDataOutput(FOutput).setVideoSettings(Settings);
  // YES is also the framework default, and it is the whole back-pressure
  // design: a queue that cannot keep up is handed fewer frames rather
  // than accumulating them.
  AVCaptureVideoDataOutput(FOutput).setAlwaysDiscardsLateVideoFrames(
    ObjCBOOL(True));
  Result := True;
end;

function TCameraBlur.Start(ASession: id; ALayer: CALayer;
  AMirrored: Boolean; out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  if FRunning then
    Exit(True);
  if (ASession = nil) or (ALayer = nil) then
  begin
    AError := 'the camera session is not running';
    Exit;
  end;
  if not CameraBlurSupported then
  begin
    AError := 'background blur needs Vision and CoreImage, which this '
      + 'Mac does not have';
    Exit;
  end;

  try
    EnsureCameraBlurClasses;
  except
    on E: Exception do
    begin
      AError := 'the camera output class could not be registered: '
        + E.Message;
      Exit;
    end;
  end;

  FSession := ASession;
  FLayer := ALayer;
  FMirrored := AMirrored;
  FStatistics := Default(TCameraBlurStatistics);

  if not BuildPipeline(AError) then
  begin
    TearDown;
    Exit;
  end;

  if not Boolean(AVCaptureSessionOutputs(FSession).canAddOutput(FOutput)) then
  begin
    TearDown;
    AError := 'the camera session refused a video data output';
    Exit;
  end;

  FDelegate := InstantiateClass(GOutputClass);
  if FDelegate = nil then
  begin
    TearDown;
    AError := 'could not instantiate ' + OutputClassName;
    Exit;
  end;
  SetPointerIvar(FDelegate, OwnerIvarName, Self);

  // Serial: nil attributes is DISPATCH_QUEUE_SERIAL, which is what the
  // header requires for in-order delivery.
  FQueue := Dispatch_queue_create(QueueLabel, nil);
  if FQueue = nil then
  begin
    TearDown;
    AError := 'the camera blur queue could not be created';
    Exit;
  end;

  // The owner ivar is set before the delegate is installed, so the first
  // frame — which can arrive before this line returns — finds an owner.
  AVCaptureVideoDataOutput(FOutput).setSampleBufferDelegate_queue(FDelegate,
    FQueue);
  // addOutput: "may be called while the session is running", so the
  // camera does not have to be stopped and warmed up again to switch
  // blur on.
  AVCaptureSessionOutputs(FSession).addOutput(FOutput);
  FRunning := True;
  Result := True;
end;

{ Stopping, and the one race that matters.

  **AVCaptureVideoDataOutput.h promises nothing about a frame already
  executing.** Its whole discussion of -setSampleBufferDelegate:queue: is
  about *dropping* frames — "if the queue is blocked when new frames are
  captured, those frames will be automatically dropped at a time
  determined by the value of the alwaysDiscardsLateVideoFrames property"
  — plus the serial-queue and non-NULL requirements. There is no sentence
  anywhere in it saying that setting the delegate to nil waits for a
  callback that is running, and this unit used to claim there was. It is
  the wrong thing to have believed: the queue body spends about 8.6 ms of
  every frame inside Vision, so a Blur Background click, a Hide, or a
  camera error landing in that window would have had TearDown release the
  request, the handler, the mask, the parameter dictionaries and the
  CIContext out from under a frame still using them.

  So the mutex that was guarding the statistics guards the teardown too,
  and the frame body runs *inside* it. A frame already executing is
  waited out; one that arrives afterwards wakes up on nil fields and
  returns without touching anything.

  **The lock is deliberately NOT held across the two framework calls.**
  If setSampleBufferDelegate: does in fact synchronise with the queue —
  which is exactly what the header does not say either way — then holding
  a lock that the queue is waiting for while calling it is a deadlock,
  and the version of this fix that keeps everything inside one critical
  section has one. Clearing FRunning under the lock first is what makes
  the two calls safe to make outside it: any frame that starts after that
  point returns immediately, and any frame still running holds the lock
  we are not asking for. The teardown then takes the lock again and
  blocks until that frame has finished. }

procedure TCameraBlur.TearDownLocked;
begin
  PThreadMutexLock(FLock);
  TearDown;
  PThreadMutexUnlock(FLock);
end;

procedure TCameraBlur.Stop;
begin
  if not FRunning then
  begin
    TearDownLocked;
    Exit;
  end;
  // Under the lock, so a frame that reads it has either not started yet
  // (and will return at once) or is already past the guard and holding
  // the lock itself.
  PThreadMutexLock(FLock);
  FRunning := False;
  PThreadMutexUnlock(FLock);
  // Outside the lock — see above. With the delegate cleared the
  // framework has nothing left to call into.
  if FOutput <> nil then
    AVCaptureVideoDataOutput(FOutput).setSampleBufferDelegate_queue(nil, nil);
  if (FSession <> nil) and (FOutput <> nil) then
    AVCaptureSessionOutputs(FSession).removeOutput(FOutput);
  // Blocks until a frame that was mid-Vision when FRunning went false
  // has finished with the objects this is about to release.
  TearDownLocked;
end;

procedure TCameraBlur.ReleaseMask;
begin
  if FMask = nil then
    Exit;
  FMask.release;
  FMask := nil;
end;

procedure TCameraBlur.TearDown;
begin
  if FDelegate <> nil then
  begin
    // Before the instance goes: a frame dispatched into a delegate whose
    // owner has been freed is exactly what the ivar is checked for.
    SetPointerIvar(FDelegate, OwnerIvarName, nil);
    ReleaseInstance(FDelegate);
    FDelegate := nil;
  end;
  if FQueue <> nil then
  begin
    Dispatch_release(FQueue);
    FQueue := nil;
  end;
  if FOutput <> nil then
  begin
    ReleaseInstance(FOutput);
    FOutput := nil;
  end;
  if FRequests <> nil then
  begin
    FRequests.release;
    FRequests := nil;
  end;
  if FRequest <> nil then
  begin
    ReleaseInstance(FRequest);
    FRequest := nil;
  end;
  if FHandler <> nil then
  begin
    ReleaseInstance(FHandler);
    FHandler := nil;
  end;
  if FBlurParameters <> nil then
  begin
    FBlurParameters.release;
    FBlurParameters := nil;
  end;
  if FBlendParameters <> nil then
  begin
    FBlendParameters.release;
    FBlendParameters := nil;
  end;
  if FBlurFilterName <> nil then
  begin
    FBlurFilterName.release;
    FBlurFilterName := nil;
  end;
  if FBlendFilterName <> nil then
  begin
    FBlendFilterName.release;
    FBlendFilterName := nil;
  end;
  if FBlendBackgroundName <> nil then
  begin
    FBlendBackgroundName.release;
    FBlendBackgroundName := nil;
  end;
  if FBlendMaskName <> nil then
  begin
    FBlendMaskName.release;
    FBlendMaskName := nil;
  end;
  ReleaseMask;
  if FContext <> nil then
  begin
    FContext.release;
    FContext := nil;
  end;
  FSession := nil;
  FLayer := nil;
end;

{ The video queue. Everything below this line runs on it. }

procedure TCameraBlur.RefreshMask(APixelBuffer: CVPixelBufferRef;
  AWidth, AHeight: Double);
var
  Error: NSError;
  Results: NSArray;
  Observation: VNPixelBufferObservation;
  MaskBuffer: CVPixelBufferRef;
  MaskImage: CIImage;
  MaskWidth, MaskHeight: Double;
  Started: Double;
begin
  Started := CFAbsoluteTimeGetCurrent;
  Error := nil;
  if not Boolean(VNSequenceRequestHandler(FHandler)
    .performRequests_onCVPixelBuffer_error(FRequests, APixelBuffer,
    @Error)) then
  begin
    Inc(FStatistics.SegmentationFailed);
    Exit;
  end;
  Results := VNRequest(FRequest).results;
  if (Results = nil) or (Results.count = 0) then
  begin
    Inc(FStatistics.SegmentationFailed);
    Exit;
  end;
  Observation := VNPixelBufferObservation(Results.objectAtIndex(0));
  if Observation = nil then
  begin
    Inc(FStatistics.SegmentationFailed);
    Exit;
  end;
  // CF_RETURNS_NOT_RETAINED: the observation owns this buffer, and
  // Vision is free to recycle it for the next request rather than hand
  // out a fresh one. The CIImage built from it below is retained across
  // frames so a stride can reuse the mask — and CIImage retains the
  // pixel buffer, which keeps this one alive, but does NOT stop Vision
  // writing into it again. At the shipped stride of 1 that cannot bite:
  // every frame runs the request and replaces the mask before it is
  // read. Raise SegmentationStride above 1 and this becomes real —
  // the reused mask would silently track the newest frame — and the fix
  // is a copy here (CIImage.imageByApplyingFilter with a CICopy-style
  // render into a buffer of ours), not a longer retain.
  MaskBuffer := Observation.pixelBuffer;
  if MaskBuffer = nil then
  begin
    Inc(FStatistics.SegmentationFailed);
    Exit;
  end;
  MaskWidth := CVPixelBufferGetWidth(MaskBuffer);
  MaskHeight := CVPixelBufferGetHeight(MaskBuffer);
  if (MaskWidth <= 0) or (MaskHeight <= 0) then
  begin
    Inc(FStatistics.SegmentationFailed);
    Exit;
  end;
  MaskImage := CIImage.imageWithCVPixelBuffer(MaskBuffer);
  if MaskImage = nil then
  begin
    Inc(FStatistics.SegmentationFailed);
    Exit;
  end;
  // Vision answers at its own resolution — smaller than the frame at
  // every quality level — so the mask is scaled onto the frame's extent
  // before it can index it. A scale is a lazy transform in CoreImage:
  // it costs nothing until the composite is rendered, and then it is
  // folded into the same pass.
  if (MaskWidth <> AWidth) or (MaskHeight <> AHeight) then
    MaskImage := MaskImage.imageByApplyingTransform(
      CGAffineTransformMakeScale(AWidth / MaskWidth, AHeight / MaskHeight));
  // Retained across frames: a stride reuses it, and the CIImage holds
  // the observation's pixel buffer alive for as long as it does.
  ReleaseMask;
  FMask := MaskImage;
  FMask.retain;
  Inc(FStatistics.Segmented);
  FStatistics.SegmentationSeconds := FStatistics.SegmentationSeconds
    + (CFAbsoluteTimeGetCurrent - Started);
end;

procedure TCameraBlur.ProcessSample(ASampleBuffer: CMSampleBufferRef);
var
  Buffer: CVPixelBufferRef;
begin
  Buffer := CMSampleBufferGetImageBuffer(ASampleBuffer);
  if Buffer = nil then
  begin
    Inc(FStatistics.Failed);
    Exit;
  end;
  ProcessPixelBuffer(Buffer);
end;

procedure TCameraBlur.ProcessPixelBuffer(ABuffer: CVPixelBufferRef);
var
  Source, Blurred, Composite: CIImage;
  Extent: CGRect;
  Width, Height: Double;
  Image: CGImageRef;
begin
  Source := CIImage.imageWithCVPixelBuffer(ABuffer);
  if Source = nil then
  begin
    Inc(FStatistics.Failed);
    Exit;
  end;
  Extent := Source.extent;
  Width := Extent.size.width;
  Height := Extent.size.height;
  if (Width <= 0) or (Height <= 0) then
  begin
    Inc(FStatistics.Failed);
    Exit;
  end;

  // The stride: Vision on frame 0 of every group, and whenever there is
  // no mask yet at all. Received has already been incremented, so the
  // first frame of a run is 1 and the test is against that.
  if (FStride <= 1) or (FMask = nil)
    or (((FStatistics.Received - 1) mod FStride) = 0) then
    RefreshMask(ABuffer, Width, Height);

  // Clamped before the blur and cropped after it: a gaussian over an
  // image with a hard edge pulls transparent pixels in from outside and
  // leaves a dark rim all the way round.
  Blurred := Source.imageByClampingToExtent
    .imageByApplyingFilter_withInputParameters(
    FBlurFilterName, FBlurParameters)
    .imageByCroppingToRect(Extent);
  if Blurred = nil then
  begin
    Inc(FStatistics.Failed);
    Exit;
  end;

  if FMask <> nil then
  begin
    FBlendParameters.setObject_forKey(id(Blurred),
      id(FBlendBackgroundName));
    FBlendParameters.setObject_forKey(id(FMask),
      id(FBlendMaskName));
    // CIBlendWithMask takes the receiver as the foreground: sharp where
    // the mask is white, which is where Vision found a person.
    Composite := Source.imageByApplyingFilter_withInputParameters(
      FBlendFilterName, FBlendParameters);
  end
  else
    // No mask yet — the first frame or two, and any frame Vision
    // refused. Blurring the whole picture is the honest answer: it is
    // visibly the effect starting up rather than a frame that silently
    // skipped it.
    Composite := Blurred;
  if Composite = nil then
  begin
    Inc(FStatistics.Failed);
    Exit;
  end;

  // The mirror, here rather than on the layer — see the unit header.
  // x maps to (2·originX + width) − x, which for an extent at the
  // origin is width − x.
  if FMirrored then
    Composite := Composite.imageByApplyingTransform(CGAffineTransformMake(
      -1, 0, 0, 1, 2 * Extent.origin.x + Width, 0));

  Image := FContext.createCGImage_fromRect(Composite, Extent);
  if Image = nil then
  begin
    Inc(FStatistics.Failed);
    Exit;
  end;
  BeginLayerChange;
  FLayer.setContents(id(Image));
  EndLayerChange;
  // createCGImage: is CF_RETURNS_RETAINED and the layer has taken its
  // own reference by now.
  CGImageRelease(Image);

  Inc(FStatistics.Rendered);
  FStatistics.LastRenderedAt := CFAbsoluteTimeGetCurrent;
  if FStatistics.FirstRenderedAt = 0 then
    FStatistics.FirstRenderedAt := FStatistics.LastRenderedAt;
end;

procedure TCameraBlur.HandleSample(ASampleBuffer: CMSampleBufferRef);
var
  Pool: NSAutoreleasePool;
  Started: Double;
begin
  // GCD drains its own pool "at unspecified times"; CoreImage and Vision
  // between them autorelease several buffers a frame, and a pool that
  // holds a second of 640x480 frames is a footprint nobody can predict.
  Pool := NSAutoreleasePool.alloc.init;
  // The guard is INSIDE the lock, not before it. Read outside, it is a
  // check of three fields that Stop is free to clear one instruction
  // later, which is a use-after-free of everything TearDown releases —
  // see the note above Stop. Inside, a frame that lost the race wakes up
  // on the nil fields it is testing and returns.
  PThreadMutexLock(FLock);
  if FRunning and (FLayer <> nil) and (FContext <> nil) then
  begin
    Started := CFAbsoluteTimeGetCurrent;
    Inc(FStatistics.Received);
    ProcessSample(ASampleBuffer);
    FStatistics.ProcessingSeconds := FStatistics.ProcessingSeconds
      + (CFAbsoluteTimeGetCurrent - Started);
  end;
  PThreadMutexUnlock(FLock);
  if Pool <> nil then
    Pool.release;
end;

{ Read from the main thread. }

function TCameraBlur.Statistics: TCameraBlurStatistics;
begin
  PThreadMutexLock(FLock);
  Result := FStatistics;
  PThreadMutexUnlock(FLock);
end;

function TCameraBlur.AchievedFramesPerSecond: Double;
var
  Snapshot: TCameraBlurStatistics;
  Span: Double;
begin
  Result := 0;
  Snapshot := Statistics;
  if Snapshot.Rendered < 2 then
    Exit;
  Span := Snapshot.LastRenderedAt - Snapshot.FirstRenderedAt;
  if Span <= 0 then
    Exit;
  Result := (Snapshot.Rendered - 1) / Span;
end;

function TCameraBlur.MeanFrameMilliseconds: Double;
var
  Snapshot: TCameraBlurStatistics;
begin
  Result := 0;
  Snapshot := Statistics;
  if Snapshot.Received <= 0 then
    Exit;
  Result := 1000 * Snapshot.ProcessingSeconds / Snapshot.Received;
end;

function TCameraBlur.MeanSegmentationMilliseconds: Double;
var
  Snapshot: TCameraBlurStatistics;
begin
  Result := 0;
  Snapshot := Statistics;
  if Snapshot.Segmented <= 0 then
    Exit;
  Result := 1000 * Snapshot.SegmentationSeconds / Snapshot.Segmented;
end;

{ The offline measurement. Main thread, no session, no delegate, no
  queue: BuildPipeline is asked for everything but those, the frames come
  from here, and TearDown puts it all back. }

// A frame with structure in it. A flat fill would let CoreImage's
// gaussian collapse to nothing measurable, and Vision would still cost
// exactly what it costs — but a graph the optimiser can shortcut is not
// the graph the camera runs. Diagonal bands plus a per-pixel wobble is
// two multiplies a pixel and defeats both.
procedure FillMeasurementFrame(ABuffer: CVPixelBufferRef;
  AWidth, AHeight, AFrame: Integer);
var
  Base: PByte;
  Row: PByte;
  Stride, X, Y: Integer;
begin
  if CVPixelBufferLockBaseAddress(ABuffer, 0) <> 0 then
    Exit;
  try
    Base := PByte(CVPixelBufferGetBaseAddress(ABuffer));
    Stride := CVPixelBufferGetBytesPerRow(ABuffer);
    if (Base = nil) or (Stride <= 0) then
      Exit;
    for Y := 0 to AHeight - 1 do
    begin
      Row := Base + Y * Stride;
      for X := 0 to AWidth - 1 do
      begin
        Row[X * 4 + 0] := Byte((X + Y + AFrame * 3) and 255);
        Row[X * 4 + 1] := Byte((X * 3 - Y * 2 + AFrame) and 255);
        Row[X * 4 + 2] := Byte((X xor Y) and 255);
        Row[X * 4 + 3] := 255;
      end;
    end;
  finally
    CVPixelBufferUnlockBaseAddress(ABuffer, 0);
  end;
end;

function TCameraBlur.MeasureOffline(AWidth, AHeight, AFrames: Integer;
  out AError: string): Boolean;
var
  Buffer: CVPixelBufferRef;
  Layer: CALayer;
  Pool: NSAutoreleasePool;
  Started: Double;
  I: Integer;
begin
  Result := False;
  AError := '';
  if FRunning then
  begin
    AError := 'the blur pipeline is already attached to a camera';
    Exit;
  end;
  if (AWidth <= 0) or (AHeight <= 0) or (AFrames <= 0) then
  begin
    AError := 'a measurement needs a frame size and a frame count';
    Exit;
  end;
  if not CameraBlurSupported then
  begin
    AError := 'background blur needs Vision and CoreImage, which this '
      + 'Mac does not have';
    Exit;
  end;

  if not BuildPipeline(AError) then
  begin
    TearDownLocked;
    Exit;
  end;
  // Somewhere for the composited frame to land. A real layer rather than
  // a nil check inside ProcessPixelBuffer, so the measurement includes
  // the createCGImage and the CATransaction the camera path pays for.
  Layer := CALayer(CALayer.alloc.init);
  if Layer = nil then
  begin
    TearDownLocked;
    AError := 'the measurement layer could not be created';
    Exit;
  end;
  FLayer := Layer;

  Buffer := nil;
  if (CVPixelBufferCreate(nil, AWidth, AHeight, PixelFormatBGRA, nil,
    @Buffer) <> 0) or (Buffer = nil) then
  begin
    FLayer := nil;
    Layer.release;
    TearDownLocked;
    AError := 'a measurement frame could not be allocated';
    Exit;
  end;

  FStatistics := Default(TCameraBlurStatistics);
  ReleaseMask;
  for I := 0 to AFrames - 1 do
  begin
    // The same pool discipline as the queue body, for the same reason:
    // Vision and CoreImage autorelease several buffers a frame.
    Pool := NSAutoreleasePool.alloc.init;
    // Fresh pixels every frame, so neither Vision's temporal stability
    // nor CoreImage's caching can answer from the last one — the camera
    // never hands it the same frame twice either.
    FillMeasurementFrame(Buffer, AWidth, AHeight, I);
    Started := CFAbsoluteTimeGetCurrent;
    Inc(FStatistics.Received);
    ProcessPixelBuffer(Buffer);
    FStatistics.ProcessingSeconds := FStatistics.ProcessingSeconds
      + (CFAbsoluteTimeGetCurrent - Started);
    if Pool <> nil then
      Pool.release;
  end;

  CVPixelBufferRelease(Buffer);
  FLayer := nil;
  Layer.release;
  // Everything but the statistics, which are the answer and are read
  // after this returns.
  TearDownLocked;
  Result := True;
end;

{$ENDIF}

end.

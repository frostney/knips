unit Knips.App.Camera;

// The camera picture-in-picture window: a small, borderless, floating
// NSWindow whose content view hosts an AVCaptureVideoPreviewLayer fed by
// an AVCaptureSession on the default video device. The user drags it
// wherever they want — typically inside the region they are about to
// record — and ScreenCaptureKit captures it like any other window.
//
// That is the whole trick, and it is Kap's: there is no compositing, no
// second capture path and no writer change. The recorder never learns
// that the camera exists; it just happens to be on screen. Which is also
// why the toggle is independent of the app's state machine (see
// docs/architecture.md): putting a passive window on screen cannot fail a
// recording, and forbidding it while recording would be the one moment
// the user most wants it. The single exception is the permission path —
// mid-recording, the controller starts the camera only when access is
// already granted, so no system dialog can land over the take.
//
// The one Objective-C class defined here, KnipsCameraView, is assembled
// at run time (ADR-0002). It answers YES to acceptsFirstMouse:, so the
// first click on the window of a background Accessory app starts the drag
// instead of being spent activating Knips, and it carries the drag
// itself — see "Dragging" below. Everything else is external bindings.
//
// Mirrored, like every other camera picture on the machine. The preview
// layer's AVCaptureConnection is switched off automatic mirroring and
// then set mirrored, in that order (the reverse throws
// NSInvalidArgumentException, and an Objective-C exception is not
// something a Pascal try..except can catch — so the guards here are the
// whole safety net). This mirrors what the *user* sees, and because
// ScreenCaptureKit records the window exactly as it is on screen, the
// recording gets the mirrored picture too. That is the Kap behaviour and
// it is the right one: what the viewer sees is what the presenter saw
// while they were pointing at things.
//
// Dragging. movableByWindowBackground is deliberately NOT used, because
// the snap needs a moment that unambiguously means "the user has let go".
// AppKit's background drag is a mouse-tracking loop run from inside
// NSWindow: it pulls its own events out of the queue and ends on its own
// schedule, and the window's position while it runs is AppKit's business,
// not this unit's. Moving the window here instead makes mouseUp: the drag
// end by construction — there is nothing left to infer.
//
// So KnipsCameraView implements mouseDown:, mouseDragged: and mouseUp:,
// and this unit moves the window from NSEvent.mouseLocation deltas —
// global screen points, so a window that is itself moving cannot make its
// own coordinates drift the way locationInWindow would. That all three
// really do reach the content view of a window built like this one, with
// movableByWindowBackground off, is measured rather than assumed
// (docs/spikes/0001, "Camera drag and snap"). On release — and only if
// the window actually travelled, so a bare click never teleports it — it
// eases to the nearest corner of whatever it was dropped on: the screen's
// visibleFrame normally, the recorded region while it is docked.
//
// Animation. That ease is a repeating NSTimer on the content view, NOT
// setFrame:display:animate:YES. AppKit's animated setFrame runs a nested
// run loop until it finishes, and a nested run loop inside mouseUp: is
// exactly the shape this app avoids everywhere else (docs/architecture.md,
// "Deferrals"): a second grab lands inside it and fights the animation,
// a shape change lands inside it and leaves the layer's radius arguing
// with the window's size, and a Hide lands inside it and has to hope the
// autorelease pool outlives AppKit's animator. Twelve steps of a
// smoothstep this unit owns has none of those problems — and the three
// operations that need a settled window (SetShape, DockTo, Hide) call
// FinishSnap first, which lands it on the corner and stops the timer.
// There is no nested run loop anywhere in this unit.
//
// Coordinates. Unlike the selection overlay, nothing here is flipped:
// the window origin lives in AppKit's own bottom-left screen space from
// the moment it is read out of NSUserDefaults to the moment it is
// written back. The one flip — a capture region, which arrives in the
// display's own top-left points — is done by the caller through
// RegionScreenRect, so this unit only ever sees AppKit space. All of the
// placement maths (nearest corner, shape sizes, clamping) is neutral and
// tested in Knips.App.State.
//
// Permission. The camera is TCC-gated per binary, exactly like Screen
// Recording. Show consults authorizationStatusForMediaType: first and
// refuses with a message rather than putting a black rectangle on screen;
// an undecided status asks once, asynchronously, and still refuses this
// time round. There is deliberately no retry loop: a denied grant fails
// identically every time, and the user has to visit System Settings
// either way.
//
// Two facts here were measured rather than assumed (docs/spikes/0001,
// "Camera"), because the design depends on both:
//
//   - A bundle-less `./build/knips` carrying no NSCameraUsageDescription
//     is NOT killed when it touches the camera. It survives the whole
//     path — requestAccess, deviceInputWithDevice:error:, startRunning —
//     so the camera toggle can never abort a live recording. What it
//     gets instead is a silent refusal.
//   - That refusal is invisible to the session: with access denied,
//     startRunning still succeeds and isRunning still answers YES. The
//     session simply delivers no frames, which is exactly the black
//     rectangle this unit refuses to show. Consulting the status first is
//     the only thing standing between the user and that window.
//
// Callers that must not put a prompt on screen at all — the launch-time
// restore, and any Show while a recording is running — gate on
// IsAuthorized instead of calling Show blind.
//
// Threading. Everything but the access-request completion handler runs on
// the main thread inside NSApp's run loop. startRunning blocks for the
// better part of a second while the camera warms up; that hitch is
// accepted rather than dispatched, because this program has no cthreads
// and owns no queues of its own (AGENTS.md). The completion handler is
// foreign-thread code and follows the capture-queue rules: it writes two
// plain Booleans and nothing else.

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
  Knips.App.State,
  Knips.ObjC.Runtime,
  MacOSAll;

{$linkframework AVFoundation}
{$linkframework QuartzCore}

const
  // AVAuthorizationStatus (AVCaptureDevice.h).
  AVAuthorizationStatusNotDetermined = 0;
  AVAuthorizationStatusRestricted = 1;
  AVAuthorizationStatusDenied = 2;
  AVAuthorizationStatusAuthorized = 3;

type
  // void (^)(BOOL granted) — requestAccessForMediaType:completionHandler:
  TAVAccessBlock = reference to procedure(AGranted: ObjCBOOL); cdecl; cblock;

  AVCaptureInput = objcclass external (NSObject)
  end;

  // The preview layer's one connection. Only the mirroring half is bound;
  // the ordering rule is Apple's, from AVCaptureSession.h:
  // "This property may not be set unless -isVideoMirroringSupported
  // returns YES, otherwise a NSInvalidArgumentException is thrown. This
  // property may not be set if -automaticallyAdjustsVideoMirroring
  // returns YES, otherwise an NSInvalidArgumentException is thrown."
  // Both are ObjC exceptions and neither is catchable from Pascal, so
  // MirroringConnection checks both conditions — and that every selector
  // is really there — before RefreshMirroring sets anything.
  AVCaptureConnection = objcclass external (NSObject)
    function IsVideoMirroringSupported: ObjCBOOL;
      message 'isVideoMirroringSupported';
    function IsVideoMirrored: ObjCBOOL; message 'isVideoMirrored';
    procedure SetVideoMirrored(AMirrored: ObjCBOOL);
      message 'setVideoMirrored:';
    procedure SetAutomaticallyAdjustsVideoMirroring(AAdjusts: ObjCBOOL);
      message 'setAutomaticallyAdjustsVideoMirroring:';
  end;

  AVCaptureDevice = objcclass external (NSObject)
    class function DefaultDeviceWithMediaType(AMediaType: NSString): id;
      message 'defaultDeviceWithMediaType:';
    class function AuthorizationStatusForMediaType(
      AMediaType: NSString): NSInteger;
      message 'authorizationStatusForMediaType:';
    class procedure RequestAccessForMediaType_completionHandler(
      AMediaType: NSString; AHandler: TAVAccessBlock);
      message 'requestAccessForMediaType:completionHandler:';
    function LocalizedName: NSString; message 'localizedName';
  end;

  AVCaptureDeviceInput = objcclass external (AVCaptureInput)
    class function DeviceInputWithDevice_error(ADevice: AVCaptureDevice;
      AOutError: NSErrorPtr): id; message 'deviceInputWithDevice:error:';
  end;

  AVCaptureSession = objcclass external (NSObject)
    function CanAddInput(AInput: AVCaptureInput): ObjCBOOL;
      message 'canAddInput:';
    procedure AddInput(AInput: AVCaptureInput); message 'addInput:';
    procedure SetSessionPreset(APreset: NSString); message 'setSessionPreset:';
    function CanSetSessionPreset(APreset: NSString): ObjCBOOL;
      message 'canSetSessionPreset:';
    procedure StartRunning; message 'startRunning';
    procedure StopRunning; message 'stopRunning';
    function IsRunning: ObjCBOOL; message 'isRunning';
  end;

  AVCaptureVideoPreviewLayer = objcclass external (CALayer)
    function InitWithSession(ASession: AVCaptureSession): id;
      message 'initWithSession:';
    procedure SetVideoGravity(AGravity: NSString); message 'setVideoGravity:';
    // Formed greedily by the session the moment the layer is created with
    // initWithSession:, and nil if it was not — hence the check.
    function Connection: AVCaptureConnection; message 'connection';
  end;

var
  AVMediaTypeVideo: NSString; cvar; external;
  AVLayerVideoGravityResizeAspectFill: NSString; cvar; external;
  AVCaptureSessionPreset640x480: NSString; cvar; external;

type
  // Reports a failure the way the rest of the app does — NSLog plus the
  // "Last error" menu item — without this unit knowing about either.
  TCameraErrorEvent = procedure(const AMessage: string) of object;

  TCameraPreview = class
  private
    FWindow: NSWindow;
    FView: NSView;
    FLayer: AVCaptureVideoPreviewLayer;
    FSession: AVCaptureSession;
    FVisible: Boolean;
    FMirrored: Boolean;
    FShape: TCameraShape;
    FOnError: TCameraErrorEvent;
    // The drag in progress: where the pointer was and where the window
    // was when it started, both in AppKit's global screen points.
    FDragging: Boolean;
    FDragMouse: NSPoint;
    FDragOrigin: NSPoint;
    // The dock, while a region recording has the camera inside its
    // rectangle. FUndocked is where the user had it before, and is what
    // Undock puts it back to and what SaveOrigin writes out — a docked
    // position is the recording's, not the user's.
    FDocked: Boolean;
    FDockRect: TCameraRect;
    FUndocked: TCameraOrigin;
    // The snap ease. A repeating NSTimer on the content view, not
    // setFrame:display:animate:YES — see "Animation" in the header.
    FSnapTimer: NSTimer;
    FSnapping: Boolean;
    FSnapFrom: TCameraOrigin;
    FSnapTo: TCameraOrigin;
    FSnapSize: TCameraSize;
    FSnapStep: Integer;
    function CheckAuthorization(out AError: string): Boolean;
    function BuildSession(out AError: string): Boolean;
    // The connection to mirror, or nil when there is nothing to talk to
    // — no layer, no -connection, or a connection that cannot mirror.
    function MirroringConnection: AVCaptureConnection;
    procedure RefreshMirroring;
    procedure ApplyShapeToLayer;
    function WindowOrigin: TCameraOrigin;
    // Starts the ease towards AOrigin. Replaces one already running.
    procedure StartSnap(const AOrigin: TCameraOrigin;
      const ASize: TCameraSize);
    // Jumps to the end of a running ease and stops it. Every operation
    // that needs a settled frame — a shape change, a dock, a Hide —
    // calls this first, so none of them has to reason about a window
    // that is half way somewhere.
    procedure FinishSnap;
    // Stops a running ease where it stands. Only the start of a drag
    // wants this: the user has grabbed the window, and it should come
    // away from under the pointer rather than from the corner it was
    // heading for.
    procedure CancelSnap;
    procedure StopSnapTimer;
    // The rectangle a drop snaps to: the dock while there is one, else
    // the visibleFrame of the screen the window is on.
    function SnapFrame: TCameraRect;
    procedure ApplyFrame(const AOrigin: TCameraOrigin;
      const ASize: TCameraSize);
    procedure SnapToNearestCorner;
    function RestoredOrigin: TCameraOrigin;
    procedure SaveOrigin;
    procedure SetShape(AShape: TCameraShape);
    procedure TearDown;
  public
    constructor Create;
    destructor Destroy; override;
    // Starts the capture session and puts the window on screen. False
    // (with the reason already reported through OnError) when the camera
    // is unavailable or not granted; the caller leaves the menu alone.
    function Show: Boolean;
    // Stops the session, remembers where the window ended up, and takes
    // it off screen. Safe to call when nothing is showing.
    procedure Hide;
    // Moves the window to the corner of ARect nearest to where it
    // already is, remembering where it came from, so a region recording
    // composites the picture-in-picture into the file the way Kap does.
    // ARect is in AppKit's global bottom-left points — Knips.App flips
    // the capture region with RegionScreenRect. False when there is no
    // window, when one dock is already in force, or when the rectangle is
    // empty; the recording then runs with the camera where it was.
    //
    // Docking happens ONCE, at the start. A Follow Mouse recording pans
    // its region across the screen and the camera deliberately does not
    // chase it: a picture-in-picture that slides around mid-take is worse
    // than one that drifts out of a shot the user is steering themselves.
    function DockTo(const ARect: TCameraRect): Boolean;
    // Puts the window back where the dock found it. Safe to call when
    // nothing is docked, which is what makes it a plain line on every
    // stop path.
    procedure Undock;
    // Called by the runtime-built view's method bodies.
    procedure BeginDrag;
    procedure DragTo;
    procedure EndDrag;
    // One step of the snap ease; the timer's target calls it.
    procedure SnapTick;
    procedure ReportError(const AMessage: string);
    // Whether the toggle should show the camera at launch.
    class function ShouldRestore: Boolean;
    class procedure RememberVisible(AVisible: Boolean);
    class function RestoredShape: TCameraShape;
    class procedure RememberShape(AShape: TCameraShape);
    // True only for AVAuthorizationStatusAuthorized. Callers use it to
    // stay off the access path entirely: asking when the status is
    // undecided puts a system prompt on screen, which is wrong at launch
    // and wrong in the middle of a recording.
    class function IsAuthorized: Boolean;
    property Visible: Boolean read FVisible;
    property Docked: Boolean read FDocked;
    // Whether the preview layer's connection really did come back
    // mirrored. Cosmetic, so a False is not an error — but it is the one
    // thing about this window that cannot be seen from the outside
    // without a camera pointed at something asymmetric.
    property Mirrored: Boolean read FMirrored;
    // Assigning applies immediately when the window is up: the window
    // resizes about its own centre and the layer's corner radius follows.
    property Shape: TCameraShape read FShape write SetShape;
    property OnError: TCameraErrorEvent read FOnError write FOnError;
  end;

// Registers KnipsCameraView once per process. Knips.App calls this from
// EnsureAppClasses, so `knips probe` gates on it with everything else —
// a class_addMethod that silently failed would otherwise only show up as
// a camera window that takes two clicks to drag.
procedure EnsureCameraClasses;

function CameraViewClassName: string;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Knips.ObjC.TypeEncoding;

const
  ViewClassName = 'KnipsCameraView';
  ViewSuperclassName = 'NSView';
  OwnerIvarName = 'knipsOwner';
  // kCGWindowLevelForKey(kCGFloatingWindowLevelKey): above ordinary
  // windows, below the menu bar and the selection overlay. NOT the
  // CocoaAll constant — every NSWindowLevel in FPC 3.2.2's CocoaAll
  // evaluates to -1 (measured: NSNormalWindowLevel, NSFloatingWindowLevel,
  // NSStatusWindowLevel and NSScreenSaverWindowLevel all come back -1,
  // while CGWindowLevelForKey answers 0, 3, 25 and 1000). The overlay
  // carries the same note for its 1000.
  CameraWindowLevel = 3;
  SnapTickSelector = 'snapTick:';
  // CameraSnapSteps ticks at this rate is the ease's whole duration:
  // twelve steps at 60 Hz is 200 ms, which reads as "it moved" without
  // making the user wait for it.
  SnapTickSeconds = 1 / 60;
  NoCameraMessage = 'no camera is available';
  DeniedMessage = 'camera access is denied — allow Knips in System '
    + 'Settings › Privacy & Security › Camera';
  RestrictedMessage = 'camera access is restricted on this Mac';
  UndecidedMessage = 'camera access has not been granted yet — answer the '
    + 'prompt, then choose Camera again';

var
  // Written by the access-request completion handler on one of
  // AVFoundation's own queues, read by the main thread on the next Show.
  // Plain Booleans: no managed types, no allocation, nothing to unwind —
  // the capture-queue rules apply here as much as they do in
  // Knips.Capture.Stream.
  GAccessAnswered: Boolean = False;
  GAccessGranted: Boolean = False;
  // One outstanding request at a time. A second Show while the prompt is
  // up must not stack another one behind it.
  GAccessRequested: Boolean = False;
  GViewClass: pobjc_class = nil;

function CameraViewClassName: string;
begin
  Result := ViewClassName;
end;

{ The one runtime-built class here (ADR-0002). Knips is an Accessory app
  and the camera window is usually not in the active application, so a
  click on it would be swallowed as the activating click and the user
  would have to click twice to start dragging. acceptsFirstMouse: makes
  the first click count.

  The three mouse methods are the drag. movableByWindowBackground did the
  moving for free until corner snapping arrived, and then stopped being
  enough: the snap needs a drag *end*, and AppKit's background drag runs
  in NSWindow's own tracking loop and ends there. Doing the move here
  costs three method bodies and buys a mouseUp: that is the drag end by
  construction — and that measurably arrives.

  The bodies recover the owning Pascal object from the knipsOwner ivar; a
  nil owner means the window is gone and the event is ignored. Wrapped in
  try..except for the reason every body in this app is: there is no
  Objective-C frame above them that could unwind a Pascal exception.
  acceptsFirstMouse: is the exception — it returns a constant and cannot
  raise. }

function OwnerOf(ASelf: id): TCameraPreview; inline;
begin
  Result := TCameraPreview(GetPointerIvar(ASelf, OwnerIvarName));
end;

// Reports what a body caught, without letting the reporting itself throw.
procedure HandleBodyException(AOwner: TCameraPreview;
  const ASelector: string; E: Exception);
begin
  if AOwner = nil then
    Exit;
  try
    AOwner.ReportError(ASelector + ': ' + E.Message);
  except
    // Nothing left to try; swallowing beats unwinding into AppKit.
  end;
end;

function CameraAcceptsFirstMouse(ASelf: id; ACommand: SEL;
  AEvent: id): ObjCBOOL; cdecl;
begin
  Result := ObjCBOOL(True);
end;

procedure CameraMouseDown(ASelf: id; ACommand: SEL; AEvent: id); cdecl;
var
  Owner: TCameraPreview;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.BeginDrag;
  except
    on E: Exception do
      HandleBodyException(Owner, 'mouseDown:', E);
  end;
end;

procedure CameraMouseDragged(ASelf: id; ACommand: SEL; AEvent: id); cdecl;
var
  Owner: TCameraPreview;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.DragTo;
  except
    on E: Exception do
      HandleBodyException(Owner, 'mouseDragged:', E);
  end;
end;

procedure CameraMouseUp(ASelf: id; ACommand: SEL; AEvent: id); cdecl;
var
  Owner: TCameraPreview;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.EndDrag;
  except
    on E: Exception do
      HandleBodyException(Owner, 'mouseUp:', E);
  end;
end;

// The snap ease's timer target. It hangs off the content view rather
// than off a class of its own: the view already carries the back-pointer,
// already lives exactly as long as the window, and a second runtime-built
// class for one repeating timer would be a class for its own sake.
procedure CameraSnapTick(ASelf: id; ACommand: SEL; ATimer: id); cdecl;
var
  Owner: TCameraPreview;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.SnapTick;
  except
    on E: Exception do
      HandleBodyException(Owner, 'snapTick:', E);
  end;
end;

procedure EnsureCameraClasses;
var
  Builder: TRuntimeClassBuilder;
  EventEncoding: string;

  procedure AddOrFail(const ASelector: string;
    AImplementation: TObjCMethodImplementation; const AEncoding: string);
  begin
    if not Builder.AddMethod(ASelector, AImplementation, AEncoding) then
      raise EObjCRuntime.Create('class_addMethod failed for ' + ASelector);
  end;

begin
  if GViewClass <> nil then
    Exit;
  GViewClass := LookUpClass(ViewClassName);
  if GViewClass <> nil then
    Exit;
  Builder := TRuntimeClassBuilder.Create(ViewClassName, ViewSuperclassName);
  try
    if not Builder.AddPointerIvar(OwnerIvarName) then
      raise EObjCRuntime.Create('class_addIvar failed for ' + OwnerIvarName);
    EventEncoding := MethodTypeEncoding(otVoid, [otObject]);
    AddOrFail('acceptsFirstMouse:', @CameraAcceptsFirstMouse,
      MethodTypeEncoding(otBool, [otObject]));
    AddOrFail('mouseDown:', @CameraMouseDown, EventEncoding);
    AddOrFail('mouseDragged:', @CameraMouseDragged, EventEncoding);
    AddOrFail('mouseUp:', @CameraMouseUp, EventEncoding);
    // Same shape as the three above — an object argument, here the timer.
    AddOrFail('snapTick:', @CameraSnapTick, EventEncoding);
    GViewClass := Builder.Register;
  finally
    Builder.Free;
  end;
end;

// The block this becomes escapes: requestAccess returns at once and calls
// back whenever the user answers. Safe, and checked rather than assumed —
// FPC emits a *static* literal for a cblock over a global routine
// (`_TC_$KNIPS.APP.CAMERA_$$_block_literal_for_…` in the data segment,
// isa __NSConcreteGlobalBlock; the binary references
// _NSConcreteStackBlock nowhere at all), so there is no dead stack frame
// to come back to.
procedure AccessCompletionHandler(AGranted: ObjCBOOL); cdecl;
begin
  GAccessGranted := Boolean(AGranted);
  GAccessAnswered := True;
end;

function Defaults: NSUserDefaults; inline;
begin
  Result := NSUserDefaults.standardUserDefaults;
end;

// Local rather than borrowed from Knips.Capture.ShareableContent: the
// camera has no business depending on the capture layer for a string.
function DefaultsKey(const AName: string): NSString; inline;
begin
  Result := NSString.stringWithUTF8String(PAnsiChar(AName));
end;

{ TCameraPreview }

constructor TCameraPreview.Create;
begin
  inherited Create;
  // Before the first Show, because the shape decides the window size the
  // restored origin is judged against.
  FShape := RestoredShape;
end;

destructor TCameraPreview.Destroy;
begin
  Hide;
  inherited Destroy;
end;

procedure TCameraPreview.ReportError(const AMessage: string);
begin
  if Assigned(FOnError) then
    FOnError(AMessage);
end;

class function TCameraPreview.ShouldRestore: Boolean;
begin
  Result := Defaults.boolForKey(DefaultsKey(CameraVisibleDefaultsKey));
end;

class procedure TCameraPreview.RememberVisible(AVisible: Boolean);
begin
  Defaults.setBool_forKey(AVisible, DefaultsKey(CameraVisibleDefaultsKey));
end;

class function TCameraPreview.RestoredShape: TCameraShape;
begin
  // A key that has never been written reads back 0, which is the
  // rectangle — no registerDefaults: needed, and `defaults write
  // KnipsCameraShape 47` is handled by the same line.
  Result := CameraShapeFromStored(
    Defaults.integerForKey(DefaultsKey(CameraShapeDefaultsKey)));
end;

class procedure TCameraPreview.RememberShape(AShape: TCameraShape);
begin
  Defaults.setInteger_forKey(StoredCameraShape(AShape),
    DefaultsKey(CameraShapeDefaultsKey));
end;

class function TCameraPreview.IsAuthorized: Boolean;
begin
  Result := AVCaptureDevice.authorizationStatusForMediaType(AVMediaTypeVideo)
    = AVAuthorizationStatusAuthorized;
end;

// Never raises: the caller is a menu action, and a refusal is a message,
// not an exception.
function TCameraPreview.CheckAuthorization(out AError: string): Boolean;
var
  Status: NSInteger;
begin
  AError := '';
  Status := AVCaptureDevice.authorizationStatusForMediaType(AVMediaTypeVideo);
  case Status of
    AVAuthorizationStatusAuthorized:
      Exit(True);
    AVAuthorizationStatusDenied:
      AError := DeniedMessage;
    AVAuthorizationStatusRestricted:
      AError := RestrictedMessage;
  else
    // NotDetermined. Ask once — the prompt is modal to the user, not to
    // us, and the handler comes back on another thread — then refuse this
    // attempt. The next Show sees Authorized if they allowed it, and
    // Denied if they did not; either way there is no loop and no black
    // window in the meantime.
    if not GAccessRequested then
    begin
      GAccessRequested := True;
      AVCaptureDevice.requestAccessForMediaType_completionHandler(
        AVMediaTypeVideo, AccessCompletionHandler);
    end;
    // The handler may already have come back with a No that the status
    // query has not caught up with; say so rather than telling the user
    // to answer a prompt they have just dismissed.
    if GAccessAnswered and not GAccessGranted then
      AError := DeniedMessage
    else
      AError := UndecidedMessage;
  end;
  Result := False;
end;

function TCameraPreview.BuildSession(out AError: string): Boolean;
var
  Device: AVCaptureDevice;
  Input: AVCaptureDeviceInput;
  Error: NSError;
begin
  Result := False;
  AError := '';
  Device := AVCaptureDevice(
    AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeVideo));
  if Device = nil then
  begin
    AError := NoCameraMessage;
    Exit;
  end;

  FSession := AVCaptureSession(AVCaptureSession.alloc.init);
  if FSession = nil then
  begin
    AError := 'AVCaptureSession could not be created';
    Exit;
  end;
  // The preview is 240 points wide; asking for more than VGA would heat
  // the machine up for pixels nobody sees. A camera that cannot do the
  // preset keeps whatever it defaults to.
  if FSession.canSetSessionPreset(AVCaptureSessionPreset640x480) then
    FSession.setSessionPreset(AVCaptureSessionPreset640x480);

  Error := nil;
  Input := AVCaptureDeviceInput(
    AVCaptureDeviceInput.deviceInputWithDevice_error(Device, @Error));
  if Input = nil then
  begin
    if Error <> nil then
      AError := 'the camera could not be opened: '
        + string(Error.localizedDescription.UTF8String)
    else
      AError := 'the camera could not be opened';
    Exit;
  end;
  if not FSession.canAddInput(Input) then
  begin
    AError := 'AVCaptureSession rejected the camera input';
    Exit;
  end;
  // addInput: retains the input; the autoreleased instance above needs no
  // balancing from us, and the session owns it until it is released.
  FSession.addInput(Input);
  Result := True;
end;

// An NSRect as the neutral unit's rectangle. Both are AppKit global
// bottom-left points; only the shape of the record differs.
function AsCameraRect(const AFrame: NSRect): TCameraRect; inline;
begin
  Result := CameraRect(AFrame.origin.x, AFrame.origin.y, AFrame.size.width,
    AFrame.size.height);
end;

function TCameraPreview.RestoredOrigin: TCameraOrigin;
var
  Screens: NSArray;
  Frame: NSRect;
  Size: TCameraSize;
  I: Integer;
  Usable: Boolean;
begin
  Result.X := 0;
  Result.Y := 0;
  Size := CameraWindowSize(FShape);
  Screens := NSScreen.screens;
  if (Screens = nil) or (Screens.count = 0) then
    Exit;

  // objectForKey: separates "never saved" from a legitimate 0.
  if Defaults.objectForKey(DefaultsKey(CameraOriginXDefaultsKey)) <> nil then
  begin
    Result.X := Defaults.doubleForKey(DefaultsKey(CameraOriginXDefaultsKey));
    Result.Y := Defaults.doubleForKey(DefaultsKey(CameraOriginYDefaultsKey));
    Usable := False;
    for I := 0 to Screens.count - 1 do
    begin
      // visibleFrame, not frame: the window floats at level 3 and the
      // Dock sits at 20, so a saved position the Dock has since covered
      // would come back invisible and undraggable.
      Frame := NSScreen(Screens.objectAtIndex(I)).visibleFrame;
      if IsCameraOriginUsable(Result, Size, AsCameraRect(Frame)) then
      begin
        Usable := True;
        Break;
      end;
    end;
    if Usable then
      Exit;
  end;

  // No saved position, or one that belonged to a display that has since
  // been unplugged: bottom-right of the main screen.
  Result := DefaultCameraOrigin(Size,
    AsCameraRect(NSScreen.mainScreen.visibleFrame));
end;

function TCameraPreview.WindowOrigin: TCameraOrigin;
var
  Frame: NSRect;
begin
  Result.X := 0;
  Result.Y := 0;
  if FWindow = nil then
    Exit;
  Frame := FWindow.frame;
  Result.X := Frame.origin.x;
  Result.Y := Frame.origin.y;
end;

procedure TCameraPreview.SaveOrigin;
var
  Origin: TCameraOrigin;
begin
  if FWindow = nil then
    Exit;
  // A docked window is standing where a recording put it, not where the
  // user did. Saving that would mean a recording quietly rewrote the
  // camera's home position.
  if FDocked then
    Origin := FUndocked
  else
    Origin := WindowOrigin;
  Defaults.setDouble_forKey(Origin.X, DefaultsKey(CameraOriginXDefaultsKey));
  Defaults.setDouble_forKey(Origin.Y, DefaultsKey(CameraOriginYDefaultsKey));
end;

{ Geometry: one place that moves the window, one that decides what it
  snaps to, and the neutral maths in Knips.App.State for the rest. }

function TCameraPreview.SnapFrame: TCameraRect;
var
  Screen: NSScreen;
begin
  // Docked into a region: the corners that matter are the region's, not
  // the screen's. Dragging the picture-in-picture out of the shot it is
  // being composited into is never what the drag meant.
  if FDocked then
    Exit(FDockRect);
  Result := CameraRect(0, 0, 0, 0);
  if FWindow = nil then
    Exit;
  // The screen with the largest part of the window on it, which is the
  // screen the user thinks they dropped it on.
  Screen := FWindow.screen;
  if Screen = nil then
    Screen := NSScreen.mainScreen;
  if Screen = nil then
    // No screen at all: answer the window's own frame, which makes the
    // nearest corner the corner it is already in and the snap a no-op.
    Exit(AsCameraRect(FWindow.frame));
  Result := AsCameraRect(Screen.visibleFrame);
end;

// The one place that moves the window. Never animated by AppKit — see
// "Animation" in the header; the ease is StartSnap's timer calling this
// once per step.
procedure TCameraPreview.ApplyFrame(const AOrigin: TCameraOrigin;
  const ASize: TCameraSize);
begin
  if FWindow = nil then
    Exit;
  FWindow.setFrame_display(NSMakeRect(AOrigin.X, AOrigin.Y, ASize.Width,
    ASize.Height), True);
  // The view is layer-*hosting*, so AppKit resizes the content view with
  // the window but leaves the layer where it was; only a shape change
  // ever gets here with a different size, but setting it every time costs
  // nothing and cannot go stale.
  if FLayer <> nil then
    FLayer.setFrame(NSMakeRect(0, 0, ASize.Width, ASize.Height));
end;

{ The snap ease. Twelve steps of smoothstep on a repeating timer, in
  NSRunLoopCommonModes — the same mode the live animator's timer uses, and
  for the same reason: a default-mode timer stops firing while a menu is
  tracking or a window is being dragged, and an ease that freezes half way
  is worse than no ease at all. }

procedure TCameraPreview.StopSnapTimer;
begin
  FSnapping := False;
  FSnapStep := 0;
  if FSnapTimer = nil then
    Exit;
  FSnapTimer.invalidate;
  FSnapTimer.release;
  FSnapTimer := nil;
end;

procedure TCameraPreview.StartSnap(const AOrigin: TCameraOrigin;
  const ASize: TCameraSize);
begin
  StopSnapTimer;
  if (FWindow = nil) or not FVisible then
    Exit;
  FSnapFrom := WindowOrigin;
  FSnapTo := AOrigin;
  FSnapSize := ASize;
  FSnapStep := 0;
  // Already there: nothing to ease, and a timer that fires once to move
  // the window nowhere is just a frame of latency.
  if (FSnapFrom.X = FSnapTo.X) and (FSnapFrom.Y = FSnapTo.Y) then
  begin
    ApplyFrame(FSnapTo, ASize);
    Exit;
  end;
  FSnapping := True;
  // Created unscheduled and added to the common modes, not scheduled and
  // then added again — scheduling first would register the same timer
  // twice and run the ease at double speed. Knips.App's live timer
  // carries the same note.
  FSnapTimer := NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats(
    SnapTickSeconds, id(FView), SelectorNamed(SnapTickSelector), nil, True);
  if FSnapTimer = nil then
  begin
    // No timer, no ease: land on the corner rather than leave the window
    // stranded where the drag ended.
    FSnapping := False;
    ApplyFrame(FSnapTo, ASize);
    Exit;
  end;
  FSnapTimer.retain;
  NSRunLoop.currentRunLoop.addTimer_forMode(FSnapTimer, NSRunLoopCommonModes);
end;

procedure TCameraPreview.SnapTick;
var
  Origin: TCameraOrigin;
begin
  if not FSnapping then
  begin
    StopSnapTimer;
    Exit;
  end;
  Inc(FSnapStep);
  Origin := CameraSnapOrigin(FSnapFrom, FSnapTo, FSnapStep, CameraSnapSteps);
  ApplyFrame(Origin, FSnapSize);
  // CameraSnapOrigin returns the target exactly on the last step, so the
  // window is already there when the timer goes.
  if FSnapStep >= CameraSnapSteps then
    StopSnapTimer;
end;

procedure TCameraPreview.FinishSnap;
begin
  if not FSnapping then
  begin
    StopSnapTimer;
    Exit;
  end;
  FSnapping := False;
  ApplyFrame(FSnapTo, FSnapSize);
  StopSnapTimer;
end;

procedure TCameraPreview.CancelSnap;
begin
  // Deliberately no ApplyFrame: the window keeps whatever frame the last
  // tick gave it, which is where the user can see it and, for the one
  // caller, where they have just grabbed it.
  StopSnapTimer;
end;

procedure TCameraPreview.SnapToNearestCorner;
var
  Size: TCameraSize;
begin
  if (FWindow = nil) or not FVisible then
    Exit;
  Size := CameraWindowSize(FShape);
  StartSnap(NearestCameraCorner(WindowOrigin, Size, SnapFrame,
    CameraWindowMargin), Size);
end;

{ The drag. movableByWindowBackground is off; these three are what move
  the window, and mouseUp: is the drag end the snap needs. Deltas come
  from NSEvent.mouseLocation — global screen points — rather than from
  the event's locationInWindow, which is measured against a window that
  is itself moving and would make the picture crawl away under the
  pointer. }

procedure TCameraPreview.BeginDrag;
begin
  if (FWindow = nil) or not FVisible then
    Exit;
  // Grabbing a window that is still easing takes it from where it *is*,
  // not from where it was going. Cancel rather than finish: finishing
  // would jump it to the corner under the pointer first, which is the
  // fight the blocking animation used to lose.
  CancelSnap;
  FDragMouse := NSEvent.mouseLocation;
  FDragOrigin := FWindow.frame.origin;
  FDragging := True;
end;

procedure TCameraPreview.DragTo;
var
  Mouse: NSPoint;
begin
  if not FDragging or (FWindow = nil) then
    Exit;
  Mouse := NSEvent.mouseLocation;
  FWindow.setFrameOrigin(NSMakePoint(
    FDragOrigin.x + (Mouse.x - FDragMouse.x),
    FDragOrigin.y + (Mouse.y - FDragMouse.y)));
end;

procedure TCameraPreview.EndDrag;
var
  Started: TCameraOrigin;
begin
  if not FDragging then
    Exit;
  // The release can carry movement the last mouseDragged: did not; take
  // it before the snap decides which corner is nearest.
  DragTo;
  FDragging := False;
  Started.X := FDragOrigin.x;
  Started.Y := FDragOrigin.y;
  // A *click* is not a drag, and must not move the window. Without this
  // every click on the picture would fling it into a corner — including
  // the corner it was deliberately moved away from a moment earlier by a
  // shape change, and including a position restored from a version of
  // this app that had no snapping at all.
  if not IsCameraDragMovement(Started, WindowOrigin) then
    Exit;
  SnapToNearestCorner;
end;

{ Docking, for a region recording. }

function TCameraPreview.DockTo(const ARect: TCameraRect): Boolean;
var
  Size: TCameraSize;
begin
  Result := False;
  if (FWindow = nil) or not FVisible or FDocked then
    Exit;
  if (ARect.Width <= 0) or (ARect.Height <= 0) then
    Exit;
  // Land a running ease first: FUndocked is what the stop path restores,
  // and a position read half way through a glide is a position the user
  // never chose.
  FinishSnap;
  FUndocked := WindowOrigin;
  FDockRect := ARect;
  FDocked := True;
  Size := CameraWindowSize(FShape);
  // In one move, not eased. The capture is about to open on this frame,
  // and a camera sliding into position across the first fifth of a second
  // is something the file would keep for ever.
  ApplyFrame(NearestCameraCorner(FUndocked, Size, ARect,
    CameraWindowMargin), Size);
  Result := True;
end;

procedure TCameraPreview.Undock;
var
  Size: TCameraSize;
begin
  if not FDocked then
    Exit;
  // Cleared first, so SnapFrame below reads the screen and not the
  // region the recording has just finished with.
  FDocked := False;
  FDockRect := CameraRect(0, 0, 0, 0);
  if (FWindow = nil) or not FVisible then
    Exit;
  Size := CameraWindowSize(FShape);
  // Eased, unlike the dock: the caller only reaches this once the writer
  // has been finalised (Knips.App.FinishRecording), so there is no file
  // left for the movement to land in, and watching the camera travel back
  // is what says the move was temporary.
  StartSnap(ClampCameraOrigin(FUndocked, Size, SnapFrame), Size);
end;

{ Shape. }

procedure TCameraPreview.ApplyShapeToLayer;
begin
  if FLayer = nil then
    Exit;
  FLayer.setCornerRadius(CameraCornerRadiusForShape(FShape));
  FLayer.setMasksToBounds(True);
end;

procedure TCameraPreview.SetShape(AShape: TCameraShape);
var
  Old, Fresh: TCameraSize;
  Origin: TCameraOrigin;
  Frame: TCameraRect;
begin
  if AShape = FShape then
    Exit;
  Old := CameraWindowSize(FShape);
  FShape := AShape;
  // Remembered even when nothing is on screen: the shape is a setting,
  // not a property of the current window.
  RememberShape(FShape);
  if (FWindow = nil) or not FVisible then
    Exit;
  // Land a running ease before measuring: re-centring a window that is
  // still travelling would centre it on a position it was only passing
  // through, and the ease's own remaining steps would then fight the
  // new size.
  FinishSnap;
  Fresh := CameraWindowSize(FShape);
  // About the centre, so the switch reads as the picture being re-cropped
  // where it stands, then pulled back on if that hung it off the edge.
  // Docked, "on" means inside the region and inset the way DockTo insets
  // — a circle that grew back into a rectangle against the region's edge
  // would otherwise sit flush against it while every other placement
  // keeps the margin.
  Frame := SnapFrame;
  if FDocked then
    Frame := InsetCameraRect(Frame, CameraWindowMargin);
  Origin := ClampCameraOrigin(RecenteredCameraOrigin(WindowOrigin, Old, Fresh),
    Fresh, Frame);
  // The remembered pre-recording origin is a bottom-left corner for a
  // window of the OLD size. Left alone, undocking after a shape change
  // would put the window back by its corner and so shift its centre;
  // re-centring it here is what makes the round trip land where the user
  // is looking.
  FUndocked := RecenteredCameraOrigin(FUndocked, Old, Fresh);
  // In one move: an eased resize would leave the layer at its final size
  // inside a window still growing into it.
  ApplyFrame(Origin, Fresh);
  ApplyShapeToLayer;
end;

{ Mirroring. }

function TCameraPreview.MirroringConnection: AVCaptureConnection;
begin
  Result := nil;
  if FLayer = nil then
    Exit;
  if not RespondsToSelector(id(FLayer), 'connection') then
    Exit;
  Result := FLayer.connection;
  if Result = nil then
    Exit;
  // All four selectors, not the two that are typed here: an
  // unrecognised-selector send is an ObjC exception like the two
  // AVCaptureSession.h documents, and no Pascal handler can catch any of
  // them. A binding that is right today and gone on some later macOS
  // should leave the camera unmirrored, not take the process with it.
  if not RespondsToSelector(id(Result), 'isVideoMirroringSupported')
    or not RespondsToSelector(id(Result),
    'setAutomaticallyAdjustsVideoMirroring:')
    or not RespondsToSelector(id(Result), 'setVideoMirrored:')
    or not RespondsToSelector(id(Result), 'isVideoMirrored') then
    Exit(nil);
  // The other documented throw: videoMirrored may not be set at all
  // unless this answers YES.
  if not Boolean(Result.isVideoMirroringSupported) then
    Exit(nil);
end;

procedure TCameraPreview.RefreshMirroring;
var
  Connection: AVCaptureConnection;
begin
  Connection := MirroringConnection;
  // Nothing to talk to *this instant* says nothing about the connection
  // that was mirrored a moment ago — the second pass runs right after
  // startRunning, where the session may be between connections. Leaving
  // the flag alone beats lying about it in either direction.
  if Connection = nil then
    Exit;
  // Order matters and is Apple's: automatic adjustment off *first*, or
  // setting videoMirrored throws NSInvalidArgumentException.
  Connection.setAutomaticallyAdjustsVideoMirroring(ObjCBOOL(False));
  Connection.setVideoMirrored(ObjCBOOL(True));
  // Read back rather than assumed: this is the whole feature, and a
  // silently ignored setter would look exactly like a camera that mirrors
  // itself in hardware on one Mac and not on the next.
  FMirrored := Boolean(Connection.isVideoMirrored);
end;

function TCameraPreview.Show: Boolean;
var
  Origin: TCameraOrigin;
  Size: TCameraSize;
  Frame, ContentBounds: NSRect;
  View: NSView;
  Layer: AVCaptureVideoPreviewLayer;
  Error: string;
begin
  Result := FVisible;
  if FVisible then
    Exit;
  EnsureCameraClasses;

  if not CheckAuthorization(Error) then
  begin
    if Assigned(FOnError) then
      FOnError(Error);
    Exit(False);
  end;

  if not BuildSession(Error) then
  begin
    TearDown;
    if Assigned(FOnError) then
      FOnError(Error);
    Exit(False);
  end;

  Size := CameraWindowSize(FShape);
  Origin := RestoredOrigin;
  Frame := NSMakeRect(Origin.X, Origin.Y, Size.Width, Size.Height);
  ContentBounds := NSMakeRect(0, 0, Size.Width, Size.Height);

  FWindow := NSWindow(NSWindow.alloc
    .initWithContentRect_styleMask_backing_defer(Frame,
    NSBorderlessWindowMask, NSBackingStoreBuffered, False));
  if FWindow = nil then
  begin
    // A failed initialiser has already released the allocation.
    TearDown;
    if Assigned(FOnError) then
      FOnError('the camera window could not be created');
    Exit(False);
  end;
  // Transparent behind the rounded corners, and a shadow so the window
  // reads as a floating object rather than a rectangle pasted on.
  FWindow.setOpaque(False);
  FWindow.setBackgroundColor(NSColor.clearColor);
  FWindow.setHasShadow(True);
  FWindow.setLevel(CameraWindowLevel);
  FWindow.setReleasedWhenClosed(False);
  // Drag it from anywhere in the picture: there is no title bar to grab.
  // Deliberately NOT movableByWindowBackground — KnipsCameraView's own
  // mouseDown:/mouseDragged:/mouseUp: do the moving, because AppKit's
  // background drag never delivers the mouseUp: the corner snap needs.
  FWindow.setMovableByWindowBackground(False);
  // Follows the user across Spaces and sits over full-screen apps — the
  // same behaviour the selection overlay asks for, and for the same
  // reason: the thing being recorded may be on any of them.
  FWindow.setCollectionBehavior(NSWindowCollectionBehaviorCanJoinAllSpaces
    or NSWindowCollectionBehaviorStationary
    or NSWindowCollectionBehaviorFullScreenAuxiliary);

  View := NSView(AllocateInstance(GViewClass)).initWithFrame(ContentBounds);
  Layer := AVCaptureVideoPreviewLayer(
    AVCaptureVideoPreviewLayer.alloc.initWithSession(FSession));
  if (View = nil) or (Layer = nil) then
  begin
    if View <> nil then
      View.release;
    if Layer <> nil then
      Layer.release;
    TearDown;
    if Assigned(FOnError) then
      FOnError('the camera preview layer could not be created');
    Exit(False);
  end;
  SetPointerIvar(id(View), OwnerIvarName, Self);
  Layer.setFrame(ContentBounds);
  // Fill the window with the camera and crop, rather than letting the
  // picture letterbox inside a rounded rectangle. It is also what makes
  // the circle work: a square window cropping the middle of a 4:3 feed.
  Layer.setVideoGravity(AVLayerVideoGravityResizeAspectFill);
  // Before the corner radius, which ApplyShapeToLayer sets from the shape.
  FLayer := Layer;
  ApplyShapeToLayer;
  // The connection exists from initWithSession: onwards, so this is
  // already the right moment; it is done again after startRunning in case
  // the session re-forms the connection while it starts.
  RefreshMirroring;
  // Pinned at Show, not tracked. Dragging the window from a Retina
  // display to a non-Retina one (or back) leaves the layer rendering at
  // the old scale until the camera is hidden and shown again. Tracking it
  // would mean an NSWindowDidChangeBackingProperties observer — another
  // runtime-built class and another owner ivar — for a case that costs
  // one menu click to fix. Recorded in docs/quick-start.md.
  Layer.setContentsScale(FWindow.backingScaleFactor);
  // Layer-hosting, not layer-backed: the layer goes on before wantsLayer,
  // and AppKit then draws nothing of its own over the video.
  View.setLayer(CALayer(Layer));
  View.setWantsLayer(True);
  // setLayer: and setContentView: both retain; balance the two allocs.
  // FLayer and FView stay as unretained back-pointers, alive for exactly
  // as long as the window is — the border unit holds its view the same
  // way — and both are cleared in TearDown before the window goes.
  Layer.release;
  FWindow.setContentView(View);
  FView := View;
  View.release;

  // Blocks while the camera warms up — the better part of a second on a
  // built-in FaceTime camera. See the unit header: no queue of ours, no
  // cthreads, so the hitch is taken on the main thread and accepted.
  FSession.startRunning;
  // Again, now that the session is running: starting it can re-form the
  // connection, and a fresh connection comes back with automatic
  // mirroring switched on. Idempotent on a connection that is already
  // mirrored; a connection that is momentarily nil leaves the flag as
  // the first pass set it.
  RefreshMirroring;
  // orderFront rather than makeKeyAndOrderFront: the camera has nothing
  // to type into, and stealing key status would pull focus out of
  // whatever the user is recording.
  FWindow.orderFront(nil);
  FVisible := True;
  Result := True;
end;

procedure TCameraPreview.Hide;
begin
  if not FVisible then
  begin
    TearDown;
    Exit;
  end;
  if FSession <> nil then
    FSession.stopRunning;
  // Land a running ease before reading the frame, or the position that
  // survives the relaunch is one the window was only passing through on
  // its way to a corner.
  FinishSnap;
  // Where the user left it is the position the next launch restores —
  // and while a recording has the camera docked, that is where the user
  // left it *before* the recording. SaveOrigin knows the difference.
  SaveOrigin;
  TearDown;
  FVisible := False;
end;

procedure TCameraPreview.TearDown;
begin
  // The timer holds the view, and the view holds a back-pointer to this
  // object; it has to go before either does. StopSnapTimer rather than
  // FinishSnap: Hide has already landed the ease, and every other route
  // here is a failed Show with nothing to land.
  StopSnapTimer;
  // A window that is going away is not docked and is not being dragged;
  // a stale dock would otherwise send the next Show's snap at a region
  // nobody is recording any more.
  FDocked := False;
  FDockRect := CameraRect(0, 0, 0, 0);
  FDragging := False;
  FMirrored := False;
  if FView <> nil then
  begin
    // Before the window goes: a mouse event dispatched into a view whose
    // owner has been freed is exactly what the ivar is checked for.
    SetPointerIvar(id(FView), OwnerIvarName, nil);
    FView := nil;
  end;
  FLayer := nil;
  if FWindow <> nil then
  begin
    FWindow.orderOut(nil);
    // Autorelease rather than release: Hide can run from inside an AppKit
    // dispatch (the menu action), and the content view's layer is still
    // wired to the session until the pool drains. The overlay defers its
    // window release for the same reason.
    FWindow.autorelease;
    FWindow := nil;
  end;
  if FSession <> nil then
  begin
    FSession.release;
    FSession := nil;
  end;
end;

{$ENDIF}

end.

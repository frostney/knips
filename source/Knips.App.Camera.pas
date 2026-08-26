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
// at run time (ADR-0002) and exists solely to answer YES to
// acceptsFirstMouse:, so the first click on the window of a background
// Accessory app starts the drag instead of being spent activating Knips.
// Everything else is external bindings.
//
// Coordinates. Unlike the selection overlay, nothing here is flipped:
// the window origin lives in AppKit's own bottom-left screen space from
// the moment it is read out of NSUserDefaults to the moment it is
// written back. The neutral placement maths is in Knips.App.State.
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

{$I Shared.inc}
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
    FSession: AVCaptureSession;
    FVisible: Boolean;
    FOnError: TCameraErrorEvent;
    function CheckAuthorization(out AError: string): Boolean;
    function BuildSession(out AError: string): Boolean;
    function RestoredOrigin: TCameraOrigin;
    procedure SaveOrigin;
    procedure TearDown;
  public
    destructor Destroy; override;
    // Starts the capture session and puts the window on screen. False
    // (with the reason already reported through OnError) when the camera
    // is unavailable or not granted; the caller leaves the menu alone.
    function Show: Boolean;
    // Stops the session, remembers where the window ended up, and takes
    // it off screen. Safe to call when nothing is showing.
    procedure Hide;
    // Whether the toggle should show the camera at launch.
    class function ShouldRestore: Boolean;
    class procedure RememberVisible(AVisible: Boolean);
    // True only for AVAuthorizationStatusAuthorized. Callers use it to
    // stay off the access path entirely: asking when the status is
    // undecided puts a system prompt on screen, which is wrong at launch
    // and wrong in the middle of a recording.
    class function IsAuthorized: Boolean;
    property Visible: Boolean read FVisible;
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
  // kCGWindowLevelForKey(kCGFloatingWindowLevelKey): above ordinary
  // windows, below the menu bar and the selection overlay. NOT the
  // CocoaAll constant — every NSWindowLevel in FPC 3.2.2's CocoaAll
  // evaluates to -1 (measured: NSNormalWindowLevel, NSFloatingWindowLevel,
  // NSStatusWindowLevel and NSScreenSaverWindowLevel all come back -1,
  // while CGWindowLevelForKey answers 0, 3, 25 and 1000). The overlay
  // carries the same note for its 1000.
  CameraWindowLevel = 3;
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

  No owner ivar and no try..except: the body returns a constant and
  cannot raise, so there is nothing to recover from and nothing to
  report. Every body that *can* raise still carries the guard — see
  Knips.App and Knips.App.Overlay. mouseDown: is deliberately NOT
  overridden: NSResponder forwards it to the window, which is what
  performs the movableByWindowBackground drag. }

function CameraAcceptsFirstMouse(ASelf: id; ACommand: SEL;
  AEvent: id): ObjCBOOL; cdecl;
begin
  Result := ObjCBOOL(True);
end;

procedure EnsureCameraClasses;
var
  Builder: TRuntimeClassBuilder;
begin
  if GViewClass <> nil then
    Exit;
  GViewClass := LookUpClass(ViewClassName);
  if GViewClass <> nil then
    Exit;
  Builder := TRuntimeClassBuilder.Create(ViewClassName, ViewSuperclassName);
  try
    if not Builder.AddMethod('acceptsFirstMouse:', @CameraAcceptsFirstMouse,
      MethodTypeEncoding(otBool, [otObject])) then
      raise EObjCRuntime.Create(
        'class_addMethod failed for acceptsFirstMouse:');
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

destructor TCameraPreview.Destroy;
begin
  Hide;
  inherited Destroy;
end;

class function TCameraPreview.ShouldRestore: Boolean;
begin
  Result := Defaults.boolForKey(DefaultsKey(CameraVisibleDefaultsKey));
end;

class procedure TCameraPreview.RememberVisible(AVisible: Boolean);
begin
  Defaults.setBool_forKey(AVisible, DefaultsKey(CameraVisibleDefaultsKey));
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

function TCameraPreview.RestoredOrigin: TCameraOrigin;
var
  Screens: NSArray;
  Frame: NSRect;
  I: Integer;
  Usable: Boolean;
begin
  Result.X := 0;
  Result.Y := 0;
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
      if IsCameraOriginUsable(Result, Frame.origin.x, Frame.origin.y,
        Frame.size.width, Frame.size.height) then
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
  Frame := NSScreen.mainScreen.visibleFrame;
  Result := DefaultCameraOrigin(Frame.origin.x, Frame.origin.y,
    Frame.size.width, Frame.size.height);
end;

procedure TCameraPreview.SaveOrigin;
var
  Frame: NSRect;
begin
  if FWindow = nil then
    Exit;
  Frame := FWindow.frame;
  Defaults.setDouble_forKey(Frame.origin.x,
    DefaultsKey(CameraOriginXDefaultsKey));
  Defaults.setDouble_forKey(Frame.origin.y,
    DefaultsKey(CameraOriginYDefaultsKey));
end;

function TCameraPreview.Show: Boolean;
var
  Origin: TCameraOrigin;
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

  Origin := RestoredOrigin;
  Frame := NSMakeRect(Origin.X, Origin.Y, CameraWindowWidth,
    CameraWindowHeight);
  ContentBounds := NSMakeRect(0, 0, CameraWindowWidth, CameraWindowHeight);

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
  // KnipsCameraView overrides nothing but acceptsFirstMouse:, so
  // mouseDown: falls through NSResponder to the window, which is what
  // performs the drag.
  FWindow.setMovableByWindowBackground(True);
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
  Layer.setFrame(ContentBounds);
  // Fill the 4:3 window with a 16:9 camera and crop, rather than letting
  // the picture letterbox inside a rounded rectangle.
  Layer.setVideoGravity(AVLayerVideoGravityResizeAspectFill);
  Layer.setCornerRadius(CameraCornerRadius);
  Layer.setMasksToBounds(True);
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
  Layer.release;
  FWindow.setContentView(View);
  View.release;

  // Blocks while the camera warms up — the better part of a second on a
  // built-in FaceTime camera. See the unit header: no queue of ours, no
  // cthreads, so the hitch is taken on the main thread and accepted.
  FSession.startRunning;
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
  // Where the user left it is the position the next launch restores.
  SaveOrigin;
  TearDown;
  FVisible := False;
end;

procedure TCameraPreview.TearDown;
begin
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

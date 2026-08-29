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
// Docking and riding. While a recording is capturing a rectangle — a
// region, or one window — the camera moves into a corner *inside* that
// rectangle, so ScreenCaptureKit finds the picture-in-picture there. The
// rectangle can then move: Follow Mouse pans a region, and a recorded
// window goes wherever the user drags it (ScreenCaptureKit's
// desktop-independent window capture follows it). So the camera rides —
// one unanimated setFrame: per tick, keeping the corner the dock chose
// and travelling by exactly the rectangle's displacement, which is the
// same thing TRecordingBorder.MoveTo does for the frame. Positions are
// computed from the dock's own rectangle and origin rather than
// accumulated, so a long take drifts by nothing.
//
// Three owners, one frame, and they take turns rather than fight: a
// drag, the corner snap that follows one, and the ride. RideTo refuses
// outright while either of the other two has the window and marks itself
// stale; the next tick then re-anchors on wherever they left it. So a
// picture dragged to the other corner mid-recording carries on riding
// from there instead of being yanked back.
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
  Knips.App.Camera.Blur,
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
    // The system Portrait effect, and the whole of what AVFoundation
    // offers of it: a class property that is `readonly` in
    // AVCaptureDevice.h — "a class property indicating whether the
    // Portrait Effect feature is currently enabled in Control Center".
    // There is no setter anywhere in the framework; the only writable
    // thing near it is +showSystemUserInterface:, which opens Control
    // Center's Video Effects panel and hands the decision to the user,
    // system-wide, for every app at once. That is why
    // Knips.App.Camera.Blur exists — see its header.
    //
    // Called through the class, never through an instance cast: a
    // Delphi-mode class method invoked on an instance expression sends
    // to [instance class], which for a class object is its *metaclass*
    // and is an unrecognised selector (measured, and it aborts the
    // process rather than returning nil).
    class function IsPortraitEffectEnabled: ObjCBOOL;
      message 'isPortraitEffectEnabled';
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
    // The content view hosts FRootLayer, always. What draws into it is
    // one of two things and never both: the AVCaptureVideoPreviewLayer
    // as a sublayer (blur off, and the framework moves the pixels), or
    // FRootLayer's own `contents`, replaced frame by frame by
    // TCameraBlur (blur on).
    //
    // The rounded corner, the mask and the aspect-fill crop live on the
    // root, so switching paths changes what fills the window and nothing
    // about its shape. Both layers are owned here — the preview layer
    // spends the whole of a blurred recording detached from any
    // superlayer, so the sublayer's retain cannot be what keeps it
    // alive.
    FRootLayer: CALayer;
    FLayer: AVCaptureVideoPreviewLayer;
    FSession: AVCaptureSession;
    FBlur: TCameraBlur;
    FBlurEnabled: Boolean;
    FVisible: Boolean;
    FMirrored: Boolean;
    FShape: TCameraShape;
    FOnError: TCameraErrorEvent;
    // The drag in progress: where the pointer was and where the window
    // was when it started, both in AppKit's global screen points.
    FDragging: Boolean;
    FDragMouse: NSPoint;
    FDragOrigin: NSPoint;
    // The dock, while a recording has the camera inside the rectangle it
    // is capturing. FUndocked is where the user had it before, and is
    // what Undock puts it back to and what SaveOrigin writes out — a
    // docked position is the recording's, not the user's.
    FDocked: Boolean;
    FDockRect: TCameraRect;
    FUndocked: TCameraOrigin;
    // The ride: the docked window travelling with a rectangle that is
    // itself moving (a region Follow Mouse is panning, a recorded window
    // the user is dragging or resizing). Measured from the dock rather
    // than accumulated per tick, so a thousand ticks cannot drift:
    // FRideAnchor is the corner the dock landed in and how far inside it
    // the window sat, and every position is that pair against the
    // rectangle's current edges. FRideAt is only the epsilon's memory.
    FRiding: Boolean;
    FRideAt: TCameraRect;
    FRideAnchor: TCameraRideAnchor;
    // Set whenever something *else* moved the window — a drag, the snap
    // that follows one, a shape change. The next ride tick re-anchors on
    // wherever the window now is instead of yanking it back to where the
    // ride left off.
    FRideStale: Boolean;
    // The snap ease. A repeating NSTimer on the content view, not
    // setFrame:display:animate:YES — see "Animation" in the header.
    FSnapTimer: NSTimer;
    FSnapping: Boolean;
    FSnapFrom: TCameraOrigin;
    FSnapTo: TCameraOrigin;
    FSnapSize: TCameraSize;
    FSnapStep: Integer;
    // What a cancelled ease was heading for. A drag cancels the ease and
    // takes the window from where it stands; a release that turns out not
    // to have been a drag at all has to put that back, or the window is
    // stranded on step 7 of 12 for ever — and SaveOrigin would then
    // persist an interpolated point as the camera's home.
    FSnapPending: Boolean;
    FSnapPendingTo: TCameraOrigin;
    FSnapPendingSize: TCameraSize;
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
    // The visibleFrame of the screen that would hold a window of ASize at
    // AOrigin — the same question RestoredOrigin asks of a position read
    // back out of NSUserDefaults, asked here of the position a dock is
    // about to restore. False when no attached screen holds it.
    function HomeFrame(const AOrigin: TCameraOrigin; const ASize: TCameraSize;
      out AFrame: TCameraRect): Boolean;
    procedure ApplyFrame(const AOrigin: TCameraOrigin;
      const ASize: TCameraSize);
    procedure SnapToNearestCorner;
    function RestoredOrigin: TCameraOrigin;
    procedure SaveOrigin;
    procedure SetShape(AShape: TCameraShape);
    // The two halves of the blur switch, each safe to call when the
    // window is not up. EnableBlurPath reports and leaves the preview in
    // place when the pipeline refuses to start.
    procedure EnableBlurPath;
    procedure DisableBlurPath;
    procedure SetBlurEnabled(AEnabled: Boolean);
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
    // Docking happens once, at the start; keeping the window inside a
    // rectangle that then MOVES is RideTo's job, and DockTo arms it.
    function DockTo(const ARect: TCameraRect): Boolean;
    // Follows the docked rectangle to ARect: the window keeps the corner
    // the dock chose and travels by exactly the rectangle's displacement.
    // One unanimated setFrame:, the same way the recording border's
    // MoveTo works and for the same reason — this runs under a live
    // capture, where an ease is an ease in the file.
    //
    // Does nothing unless a dock armed a ride, and nothing at all while
    // the user is dragging the window or the corner snap is easing it:
    // two owners for one frame is a window that jitters. Whatever those
    // two do to the window is absorbed rather than fought — the next
    // tick re-anchors the ride wherever they left it, so a picture
    // dragged to a different corner mid-recording goes on following from
    // there.
    //
    // ARect is in AppKit's global bottom-left points, like DockTo's.
    // False when nothing moved, which is most ticks.
    function RideTo(const ARect: TCameraRect): Boolean;
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
    // Off for a key that was never written, which is what boolForKey:
    // answers — so nothing has to register a default for a feature that
    // costs a Vision pass per frame.
    class function RestoredBlur: Boolean;
    class procedure RememberBlur(ABlur: Boolean);
    // True only for AVAuthorizationStatusAuthorized. Callers use it to
    // stay off the access path entirely: asking when the status is
    // undecided puts a system prompt on screen, which is wrong at launch
    // and wrong in the middle of a recording.
    class function IsAuthorized: Boolean;
    property Visible: Boolean read FVisible;
    // Whether a dock armed a ride that is still live. False once the
    // recording undocks.
    property Riding: Boolean read FRiding;
    // Assigning applies immediately when the window is up: the window
    // resizes about its own centre and the layer's corner radius follows.
    property Shape: TCameraShape read FShape write SetShape;
    // Assigning switches the display path under a running session — no
    // stop, no second warm-up — and remembers the answer. The setting is
    // the user's choice, not the last attempt's outcome: a pipeline that
    // refuses to start reports and leaves the preview up, and the
    // preference still says what was asked for.
    property BlurEnabled: Boolean read FBlurEnabled write SetBlurEnabled;
    // The blur pipeline while one is running, for the caller that wants
    // its measured frame rate. Nil when blur is off.
    property Blur: TCameraBlur read FBlur;
    property OnError: TCameraErrorEvent read FOnError write FOnError;
  end;

// Registers KnipsCameraView once per process. Knips.App calls this from
// EnsureAppClasses, so `knips probe` gates on it with everything else —
// a class_addMethod that silently failed would otherwise only show up as
// a camera window that takes two clicks to drag.
procedure EnsureCameraClasses;

function CameraViewClassName: string;

type
  // What TCC says about the camera for this executable, in the shape
  // Knips.Capture.Stream.MicrophoneAccess already answers for the
  // microphone. `knips probe` prints it; nothing gates on it, because
  // Show consults the same status itself.
  TCameraAccess = (caNotDetermined, caRestricted, caDenied, caAuthorized);

function CameraAccess: TCameraAccess;

// Whether the *system* Portrait effect is switched on in Control Center.
// Read-only — see the binding above — and reported by `knips probe` so
// the claim that there is no programmatic route can be re-checked on a
// later SDK rather than believed. False when the selector is not there.
function SystemPortraitEffectEnabled: Boolean;

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

function CameraAccess: TCameraAccess;
begin
  case AVCaptureDevice.authorizationStatusForMediaType(AVMediaTypeVideo) of
    AVAuthorizationStatusAuthorized: Result := caAuthorized;
    AVAuthorizationStatusDenied: Result := caDenied;
    AVAuthorizationStatusRestricted: Result := caRestricted;
  else
    Result := caNotDetermined;
  end;
end;

function SystemPortraitEffectEnabled: Boolean;
var
  DeviceClass: pobjc_class;
begin
  Result := False;
  DeviceClass := LookUpClass('AVCaptureDevice');
  if DeviceClass = nil then
    Exit;
  // respondsToSelector: sent to a class object asks about its class
  // methods, which is exactly the question here.
  if not RespondsToSelector(id(DeviceClass), 'isPortraitEffectEnabled') then
    Exit;
  Result := Boolean(AVCaptureDevice.isPortraitEffectEnabled);
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
  FBlurEnabled := RestoredBlur;
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

class function TCameraPreview.RestoredBlur: Boolean;
begin
  Result := Defaults.boolForKey(DefaultsKey(CameraBlurDefaultsKey));
end;

class procedure TCameraPreview.RememberBlur(ABlur: Boolean);
begin
  Defaults.setBool_forKey(ABlur, DefaultsKey(CameraBlurDefaultsKey));
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
  Size: TCameraSize;
  Home: TCameraRect;
begin
  Result.X := 0;
  Result.Y := 0;
  Size := CameraWindowSize(FShape);
  Screens := NSScreen.screens;
  if (Screens = nil) or (Screens.count = 0) then
    Exit;

  // objectForKey: separates "never saved" from a legitimate 0 — and it
  // is asked of BOTH keys. They are written together, so in practice
  // either both are there or neither is; but `defaults write` is a
  // public interface (see SanitizeStoredRegion for the same reasoning
  // about the region), so somebody really can leave one of the two
  // behind, and reading Y under X's guard turned that into a window
  // pinned to the bottom of the screen rather than into the fallback.
  if (Defaults.objectForKey(DefaultsKey(CameraOriginXDefaultsKey)) <> nil)
    and (Defaults.objectForKey(DefaultsKey(CameraOriginYDefaultsKey))
    <> nil) then
  begin
    Result.X := Defaults.doubleForKey(DefaultsKey(CameraOriginXDefaultsKey));
    Result.Y := Defaults.doubleForKey(DefaultsKey(CameraOriginYDefaultsKey));
    if HomeFrame(Result, Size, Home) then
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
  Origin, DragStart: TCameraOrigin;
begin
  DragStart.X := FDragOrigin.x;
  DragStart.Y := FDragOrigin.y;
  if FWindow = nil then
    Exit;
  // A docked window is standing where a recording put it, not where the
  // user did. Saving that would mean a recording quietly rewrote the
  // camera's home position.
  if FDocked then
    Origin := FUndocked
  else if FSnapping then
    // Mid-ease. The corner the window is travelling to is the position
    // the user chose; the interpolated point it happens to be standing
    // on is step 7 of 12 and nothing anybody meant. Reading the target
    // is also what lets Hide skip the ease's visible teleport-to-corner
    // in the instant before the window is ordered out.
    Origin := FSnapTo
  else if FSnapPending and not (FDragging
    and IsCameraDragMovement(DragStart, WindowOrigin)) then
    // The same interpolated point, parked rather than running: a
    // mouseDown: cancelled an ease and the mouseUp: that would put it
    // back has not arrived. Quitting in that window — the camera is held
    // down while ⌘Q goes through the main menu — would otherwise persist
    // step 7 of 12 as the camera's home. But only while the press has
    // not MOVED the window: once it is a real drag, where the user
    // dragged it to beats the corner the cancelled ease was heading for.
    Origin := FSnapPendingTo
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

// The one screen scan, and both callers that ask the question use it:
// RestoredOrigin, judging a position read back out of NSUserDefaults, and
// Undock, judging the position a recording is about to give back. They
// were the same loop written twice.
//
// visibleFrame rather than frame throughout: the window floats at level 3
// and the Dock sits at 20, so space the Dock has taken is not somewhere a
// window can be put.
function TCameraPreview.HomeFrame(const AOrigin: TCameraOrigin;
  const ASize: TCameraSize; out AFrame: TCameraRect): Boolean;
var
  Screens: NSArray;
  I: Integer;
begin
  AFrame := CameraRect(0, 0, 0, 0);
  Result := False;
  Screens := NSScreen.screens;
  if (Screens = nil) or (Screens.count = 0) then
    Exit;
  for I := 0 to Screens.count - 1 do
  begin
    AFrame := AsCameraRect(NSScreen(Screens.objectAtIndex(I)).visibleFrame);
    if IsCameraOriginUsable(AOrigin, ASize, AFrame) then
      Exit(True);
  end;
  AFrame := CameraRect(0, 0, 0, 0);
end;

{ Core Animation's implicit actions, off for the length of one change.

  The content view is layer-*hosting*, which is what keeps AppKit from
  drawing over the video — and also what leaves Core Animation's own
  default actions in force on the layer. Every setFrame: and
  setCornerRadius: below is therefore a quarter-second implicit animation
  unless it is wrapped, which is precisely the artefact the "in one move"
  comments in SetShape and DockTo exist to prevent: an instantly resized
  window with a layer easing into it. During a docked recording that
  quarter second is *in the file*. }

procedure BeginLayerChange;
begin
  CATransaction.begin_;
  CATransaction.setDisableActions(True);
end;

procedure EndLayerChange;
begin
  CATransaction.commit;
end;

// The one place that moves the window. Never animated by AppKit — see
// "Animation" in the header; the ease is StartSnap's timer calling this
// once per step.
//
// **A move and a resize are different operations here, and telling them
// apart is not tidiness.** This is called up to thirty times a second by
// the ride and by the snap ease, and the two things the resize path does
// — force the window to redraw synchronously, and hand the video layer a
// new frame — are both wasted work on a move, and both are visible:
//
//   - `setFrame:display:YES` makes AppKit redraw the window *now*. On a
//     move nothing about the window's contents has changed, and forcing
//     a redraw thirty times a second on a window whose layer is being
//     filled asynchronously by a capture session is exactly the race
//     that shows up as tearing. `setFrameOrigin:` moves the window and
//     lets the window server composite it, which is what a moving window
//     wants.
//   - Re-setting the layer's frame to the value it already has is not a
//     no-op inside Core Animation: it is a geometry change on an
//     AVCaptureVideoPreviewLayer, which recomputes how the video sits in
//     its bounds. Thirty of those a second, interleaved with frames
//     arriving from the capture session, is the other half of the same
//     flicker.
//
// So: origin only when only the origin moved, and the full path — with
// the layer, in one CATransaction — only when the size really changed,
// which is a shape switch and nothing else.
procedure TCameraPreview.ApplyFrame(const AOrigin: TCameraOrigin;
  const ASize: TCameraSize);
var
  Frame: NSRect;
begin
  if FWindow = nil then
    Exit;
  Frame := FWindow.frame;
  if (Frame.size.width = ASize.Width)
    and (Frame.size.height = ASize.Height) then
  begin
    // A pure move. setFrameOrigin: lets the window server composite the
    // window at its new place on its own schedule; setFrame:display:YES
    // would force a synchronous redraw thirty times a second on a window
    // whose layer a capture session is filling asynchronously — the
    // tearing path the comment above names.
    if (Frame.origin.x <> AOrigin.X) or (Frame.origin.y <> AOrigin.Y) then
      FWindow.setFrameOrigin(NSMakePoint(AOrigin.X, AOrigin.Y));
    Exit;
  end;
  FWindow.setFrame_display(NSMakeRect(AOrigin.X, AOrigin.Y, ASize.Width,
    ASize.Height), True);
  // The view is layer-*hosting*, so AppKit resizes the content view with
  // the window but leaves the layers where they were. Both of them: the
  // root that carries the shape, and the preview sublayer inside it.
  if (FRootLayer = nil) and (FLayer = nil) then
    Exit;
  BeginLayerChange;
  try
    if FRootLayer <> nil then
      FRootLayer.setFrame(NSMakeRect(0, 0, ASize.Width, ASize.Height));
    if FLayer <> nil then
      FLayer.setFrame(NSMakeRect(0, 0, ASize.Width, ASize.Height));
  finally
    EndLayerChange;
  end;
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
  // A fresh ease supersedes whatever a cancelled one was heading for.
  FSnapPending := False;
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
  FSnapPending := False;
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
  //
  // But where it was *going* is remembered, because the one caller is
  // mouseDown: and a mouseDown: is not yet a drag. A press-and-release
  // that never travels fails EndDrag's threshold, starts no new ease, and
  // used to leave the window stranded on whichever step of twelve the
  // cancel caught — permanently, and persisted as the camera's home by
  // the next Hide. EndDrag puts this back.
  if FSnapping then
  begin
    FSnapPending := True;
    FSnapPendingTo := FSnapTo;
    FSnapPendingSize := FSnapSize;
  end;
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
  // fight the blocking animation used to lose. CancelSnap remembers the
  // target so a press that turns out not to be a drag can resume it.
  CancelSnap;
  // The user now owns the window; a ride that kept moving it under the
  // pointer would be two owners for one frame. RideTo refuses while
  // FDragging, and this says that whatever the drag does to the window
  // is the ride's new anchor rather than something to undo.
  FRideStale := True;
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
  Started, PendingTo: TCameraOrigin;
  PendingSize: TCameraSize;
  Pending: Boolean;
begin
  if not FDragging then
    Exit;
  // The release can carry movement the last mouseDragged: did not; take
  // it before the snap decides which corner is nearest.
  DragTo;
  FDragging := False;
  Started.X := FDragOrigin.x;
  Started.Y := FDragOrigin.y;
  // Read before either branch below can clear it.
  Pending := FSnapPending;
  PendingTo := FSnapPendingTo;
  PendingSize := FSnapPendingSize;
  FSnapPending := False;
  // A *click* is not a drag, and must not move the window. Without this
  // every click on the picture would fling it into a corner — including
  // the corner it was deliberately moved away from a moment earlier by a
  // shape change, and including a position restored from a version of
  // this app that had no snapping at all.
  if not IsCameraDragMovement(Started, WindowOrigin) then
  begin
    // …but a click that landed on a window still gliding to a corner
    // cancelled that glide on the way in. Put it back rather than leave
    // the picture parked between two corners for good.
    if Pending then
      StartSnap(PendingTo, PendingSize);
    Exit;
  end;
  SnapToNearestCorner;
end;

{ Docking into the rectangle a recording is capturing, and riding it. }

function TCameraPreview.DockTo(const ARect: TCameraRect): Boolean;
var
  Size: TCameraSize;
  Origin: TCameraOrigin;
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
  Origin := NearestCameraCorner(FUndocked, Size, ARect, CameraWindowMargin);
  // In one move, not eased. The capture is about to open on this frame,
  // and a camera sliding into position across the first fifth of a second
  // is something the file would keep for ever.
  ApplyFrame(Origin, Size);
  // Arm the ride from exactly this corner and this inset. Every later
  // position is computed from that anchor rather than from the last one,
  // so thirty ticks a second for ten minutes accumulate no drift at all.
  FRiding := True;
  FRideAt := ARect;
  FRideAnchor := CameraRideAnchorFor(Origin, Size, ARect);
  FRideStale := False;
  Result := True;
end;

function TCameraPreview.RideTo(const ARect: TCameraRect): Boolean;
var
  Size: TCameraSize;
begin
  Result := False;
  if not FRiding or not FDocked then
    Exit;
  if (FWindow = nil) or not FVisible then
    Exit;
  if (ARect.Width <= 0) or (ARect.Height <= 0) then
    Exit;
  // Where a drop snaps to follows the rectangle FIRST, and unconditionally
  // — before the stand-aside below, not after it. A drag is exactly when
  // the region is most likely to be moving, and a dock rectangle frozen
  // for the length of the drag is a drop that snaps to where the region
  // *was*, followed by a re-anchor onto that wrong origin for the rest of
  // the take.
  FDockRect := ARect;
  // Mutual exclusion with the two other things that own this window's
  // frame, and the whole of it. A drag is the user moving the picture; a
  // snap is the ease that follows one. Either way the ride stands aside
  // and marks itself stale, so it re-anchors instead of yanking the
  // window back the moment it gets the frame again.
  if FDragging or FSnapping then
  begin
    FRideStale := True;
    Exit;
  end;
  Size := CameraWindowSize(FShape);
  if FRideStale then
  begin
    // Somebody else moved the window while the ride was standing aside.
    // Re-anchor on the rectangle and the window as they are now; the
    // picture goes on following from wherever the user dropped it,
    // rather than teleporting back to the corner the dock chose a minute
    // ago — and it follows from the corner it is now *nearest*, which is
    // the corner the drop's own snap put it in.
    FRideAt := ARect;
    FRideAnchor := CameraRideAnchorFor(WindowOrigin, Size, ARect);
    FRideStale := False;
    Exit;
  end;
  if not IsCameraRideMovement(FRideAt, ARect) then
    Exit;
  FRideAt := ARect;
  // One unanimated setFrame:, exactly like TRecordingBorder.MoveTo. This
  // runs under a live capture: an ease here is an ease in the file.
  ApplyFrame(CameraRideOrigin(FRideAnchor, Size, ARect), Size);
  Result := True;
end;

procedure TCameraPreview.Undock;
var
  Size: TCameraSize;
  Home: TCameraRect;
begin
  if not FDocked then
    Exit;
  // Cleared first, so SnapFrame below reads the screen and not the
  // rectangle the recording has just finished with.
  FDocked := False;
  FRiding := False;
  FRideStale := False;
  FDockRect := CameraRect(0, 0, 0, 0);
  if (FWindow = nil) or not FVisible then
    Exit;
  Size := CameraWindowSize(FShape);
  // Clamped against the screen that actually HOLDS the remembered
  // position, not against SnapFrame. SnapFrame answers the visibleFrame
  // of the screen the *window* is on, which with the dock just cleared is
  // still the recorded one — so a camera the user keeps on display B,
  // docked into a region on display A, used to come back squeezed onto A.
  // And because Hide writes the restored position out, the next launch
  // then kept it there: a recording had quietly rewritten the camera's
  // home, which is the one thing the FUndocked/SaveOrigin split exists to
  // prevent. Only when no attached screen holds it — the display it lived
  // on has been unplugged mid-recording — is the current screen the right
  // answer.
  if not HomeFrame(FUndocked, Size, Home) then
    Home := SnapFrame;
  // Eased, unlike the dock: the caller only reaches this once the writer
  // has been finalised (Knips.App.FinishRecording), so there is no file
  // left for the movement to land in, and watching the camera travel back
  // is what says the move was temporary.
  StartSnap(ClampCameraOrigin(FUndocked, Size, Home), Size);
end;

{ Shape. }

procedure TCameraPreview.ApplyShapeToLayer;
begin
  if FRootLayer = nil then
    Exit;
  // On the ROOT layer, so one radius shapes both display paths: the
  // preview layer is a sublayer and masksToBounds clips it, and the
  // blurred frames are the root's own contents. A radius on the preview
  // layer as well would be a second place to keep in step for no visible
  // difference.
  //
  // cornerRadius is an animatable property like frame, so without the
  // transaction the rectangle rounds itself into a disc over a quarter of
  // a second while the window has already been square for a whole frame.
  BeginLayerChange;
  try
    FRootLayer.setCornerRadius(CameraCornerRadiusForShape(FShape));
    FRootLayer.setMasksToBounds(True);
  finally
    EndLayerChange;
  end;
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
  // The shape change is the third thing that moves this window behind the
  // ride's back; the next tick re-anchors on the re-centred position
  // rather than dragging the window back to where the old size sat.
  FRideStale := True;
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
  Root: CALayer;
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
  Root := CALayer(CALayer.alloc.init);
  Layer := AVCaptureVideoPreviewLayer(
    AVCaptureVideoPreviewLayer.alloc.initWithSession(FSession));
  if (View = nil) or (Root = nil) or (Layer = nil) then
  begin
    if View <> nil then
      View.release;
    if Root <> nil then
      Root.release;
    if Layer <> nil then
      Layer.release;
    TearDown;
    if Assigned(FOnError) then
      FOnError('the camera preview layer could not be created');
    Exit(False);
  end;
  SetPointerIvar(id(View), OwnerIvarName, Self);
  Root.setFrame(ContentBounds);
  // Fill the window with the camera and crop, rather than letting the
  // picture letterbox inside a rounded rectangle. It is also what makes
  // the circle work: a square window cropping the middle of a 4:3 feed.
  // The root's contentsGravity is the blurred path's half of the same
  // rule — a 640x480 rendered frame in a 240x180 layer, cropped, not
  // squashed — and the preview layer's videoGravity is the other.
  Root.setContentsGravity(kCAGravityResizeAspectFill);
  Layer.setFrame(ContentBounds);
  Layer.setVideoGravity(AVLayerVideoGravityResizeAspectFill);
  // Before the corner radius, which ApplyShapeToLayer sets on the root.
  FRootLayer := Root;
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
  Root.setContentsScale(FWindow.backingScaleFactor);
  Layer.setContentsScale(FWindow.backingScaleFactor);
  // The preview goes on as a SUBLAYER of the root rather than as the
  // hosted layer itself, because the blur path takes it off again and
  // puts it back. Both are released in TearDown: while blur is on the
  // preview layer has no superlayer at all, so a sublayer's retain
  // cannot be the thing keeping it alive.
  Root.addSublayer(CALayer(Layer));
  // Layer-hosting, not layer-backed: the layer goes on before wantsLayer,
  // and AppKit then draws nothing of its own over the video.
  View.setLayer(Root);
  View.setWantsLayer(True);
  FWindow.setContentView(View);
  FView := View;
  // setContentView: retains; FView stays an unretained back-pointer,
  // alive for exactly as long as the window is — the border unit holds
  // its view the same way — and it is cleared in TearDown before the
  // window goes.
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
  // Last, and only if the preference says so: the blur pipeline attaches
  // a second output to the session that is now running. A refusal is
  // reported and the preview stays up — the window is already correct
  // without it.
  if FBlurEnabled then
    EnableBlurPath;
  // orderFront rather than makeKeyAndOrderFront: the camera has nothing
  // to type into, and stealing key status would pull focus out of
  // whatever the user is recording.
  FWindow.orderFront(nil);
  FVisible := True;
  Result := True;
end;

{ The blur switch. Both halves leave the session alone: addOutput: and
  removeOutput: "may be called while the session is running"
  (AVCaptureSession.h), so switching the effect on costs nothing like the
  second-long warm-up that stopping and restarting the camera would. }

procedure TCameraPreview.EnableBlurPath;
var
  Error: string;
begin
  if (FSession = nil) or (FRootLayer = nil) then
    Exit;
  if FBlur = nil then
    FBlur := TCameraBlur.Create;
  if FBlur.Running then
    Exit;
  // Mirrored by the pipeline rather than by a connection: there is no
  // AVCaptureConnection on this path, and the composited image is
  // flipped in CoreImage before it reaches the layer.
  if not FBlur.Start(id(FSession), FRootLayer, True, Error) then
  begin
    ReportError('background blur: ' + Error);
    Exit;
  end;
  // The preview layer would otherwise draw the unblurred feed straight
  // over the root's contents.
  if FLayer <> nil then
    FLayer.removeFromSuperlayer;
  // The picture really is mirrored, by the transform rather than by the
  // connection — so the flag says the same thing it says on the other
  // path.
  FMirrored := True;
end;

procedure TCameraPreview.DisableBlurPath;
begin
  if FBlur <> nil then
    FBlur.Stop;
  if FRootLayer <> nil then
  begin
    // The last blurred frame would otherwise stay behind the preview
    // layer for the life of the window — invisible while the preview
    // covers it, and back the moment the shape changes.
    BeginLayerChange;
    try
      FRootLayer.setContents(nil);
    finally
      EndLayerChange;
    end;
    if (FLayer <> nil) and (FLayer.superlayer = nil) then
    begin
      FRootLayer.addSublayer(CALayer(FLayer));
      // A layer that has been off the tree keeps its frame, but the
      // window may have changed shape while it was away.
      BeginLayerChange;
      try
        FLayer.setFrame(FRootLayer.bounds);
      finally
        EndLayerChange;
      end;
    end;
  end;
  RefreshMirroring;
end;

procedure TCameraPreview.SetBlurEnabled(AEnabled: Boolean);
begin
  if AEnabled = FBlurEnabled then
    Exit;
  FBlurEnabled := AEnabled;
  // Remembered even when nothing is on screen: like the shape, this is a
  // setting rather than a property of the current window.
  RememberBlur(FBlurEnabled);
  if (FWindow = nil) or not FVisible then
    Exit;
  if FBlurEnabled then
    EnableBlurPath
  else
    DisableBlurPath;
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
  // Deliberately NOT FinishSnap. Landing the ease here means one visible
  // teleport to the corner in the instant before the window is ordered
  // out — the user's last sight of the camera is it jumping. Nothing else
  // needed the window settled: the only reader is SaveOrigin, and it
  // takes the ease's *target* when one is running, which is the position
  // the drop chose and the one the teleport was going to produce anyway.
  // TearDown below stops the timer.
  //
  // Where the user left it is the position the next launch restores —
  // and while a recording has the camera docked, that is where the user
  // left it *before* the recording. SaveOrigin knows both differences.
  SaveOrigin;
  TearDown;
  FVisible := False;
end;

procedure TCameraPreview.TearDown;
begin
  // First: the blur pipeline holds a delegate whose ivar points here and
  // a GCD queue that may be half way through a frame. Stop waits for it.
  if FBlur <> nil then
  begin
    FBlur.Free;
    FBlur := nil;
  end;
  // The timer holds the view, and the view holds a back-pointer to this
  // object; it has to go before either does. StopSnapTimer rather than
  // FinishSnap: Hide has already read the ease's target, and every other
  // route here is a failed Show with nothing to land.
  StopSnapTimer;
  FSnapPending := False;
  // A window that is going away is not docked, is not riding and is not
  // being dragged; a stale dock would otherwise send the next Show's snap
  // at a rectangle nobody is recording any more.
  FDocked := False;
  FRiding := False;
  FRideStale := False;
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
  // Both layers are ours: the preview layer is detached from the tree
  // for the whole of a blurred session, so nothing else is holding it.
  if FLayer <> nil then
  begin
    FLayer.release;
    FLayer := nil;
  end;
  if FRootLayer <> nil then
  begin
    FRootLayer.release;
    FRootLayer := nil;
  end;
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

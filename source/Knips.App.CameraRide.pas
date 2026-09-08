unit Knips.App.CameraRide;

// The camera dock and the window ride: one recorded *window*, two things
// that have to keep following it, and the 5 Hz poll that moves both.
//
// This is a seam cut out of Knips.App, which had grown to hold the menu,
// the preferences, the state transitions, the recording lifecycle and
// this — and this is the part that answers to a clock of its own and
// touches almost nothing else. What lives here is everything that knows
// where a recorded window currently is:
//
//   - the composited window recording (CompositeWindowForPending and
//     UpdateCompositedSourceRect), which turns a window request into a
//     region capture of that window's display and then pans the capture
//     onto the window as it moves;
//   - the camera dock (DockCameraForPending, UndockCamera), which puts
//     the picture-in-picture inside the rectangle being recorded so
//     ScreenCaptureKit finds it there;
//   - the poll that keeps both on the window (Start, Stop, Tick).
//
// It owns no Objective-C class and no Cocoa object but the timer. The
// `cameraRideTick:` selector stays registered on Knips.App's
// runtime-built KnipsAppTarget — the app adds no runtime class per
// feature (ADR-0002), and `knips probe` checks that selector on that
// target — and the target's method body forwards straight to Tick.
//
// Everything below runs on the main thread inside NSApp's run loop, so
// none of the capture-queue rules apply here.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  CocoaAll,
  Knips.App.Border,
  Knips.App.Camera,
  Knips.App.State,
  Knips.Options,
  Knips.Recording,
  MacOSAll;

type
  // What the ride needs from the app controller that owns it, and the
  // whole of it. Named answers rather than a pointer to the controller,
  // because Knips.App uses this unit and so this unit cannot use it
  // back — and because writing the list down is what keeps the seam
  // honest: anything the ride comes to need that is not here has to be
  // added on purpose.
  //
  // Four of the six are asked afresh every time rather than held. The
  // session is replaced under the ride's feet — the dock starts the poll
  // and StartPending then frees one session and creates the next — and
  // the camera can be switched off in the middle of a take, so a pointer
  // taken once would be a dead one.
  TCameraRideHost = class
  protected
    // The recording whose source rectangle the composited pan steers.
    // nil between takes.
    function RideSession: TRecordingSession; virtual; abstract;
    // The picture-in-picture window, or nil when the camera is off.
    function RideCamera: TCameraPreview; virtual; abstract;
    // The runtime-built KnipsAppTarget and the `cameraRideTick:`
    // selector registered on it. The ride builds no class of its own; it
    // only asks who the timer should fire into.
    function RideTimerTarget: id; virtual; abstract;
    function RideTimerSelector: SEL; virtual; abstract;
    // True while an export or a render owns the main thread and drains
    // events to draw its progress, which is how a timer can fire in the
    // middle of one.
    function RideBusy: Boolean; virtual; abstract;
    // The one thing the ride ever has to say out loud: the recorded
    // window has been dragged onto a display this capture cannot follow
    // it to. Goes to the menu's single "Last error" slot and puts the
    // status item back in step.
    procedure RideRecordError(const AMessage: string); virtual; abstract;
  end;

  TCameraRide = class
  private
    // Not owned: the host outlives the ride, which is created with the
    // controller and freed with it.
    FHost: TCameraRideHost;
    // The ride's timer, alive only while a WINDOW recording has a docked
    // camera or a composited pan to drive. A region ride needs no timer
    // of its own: it happens inside the live animator's tick, in the
    // same turn as the frame.
    FTimer: NSTimer;
    // The recorded window the ride is following. 0 when nothing is being
    // ridden.
    FRideWindowID: Cardinal;
    // The composited window recording. A window recording that needs
    // anything composited in is captured as a DISPLAY with a source
    // rectangle riding the window's frame, because ScreenCaptureKit's
    // desktop-independent window capture composits that window alone and
    // leaves everything in front of it out of the file — measured, see
    // docs/architecture.md. These three are the window being ridden, the
    // display it was on, and the rectangle whose SIZE the writer was
    // opened with; 0 when the recording is an ordinary one.
    FCompositedWindowID: Cardinal;
    FCompositedDisplayID: UInt32;
    FCompositedRegion: TCaptureRegion;
    // Set once the recorded window has been dragged onto a display this
    // capture cannot follow it to, so the message is said once rather
    // than five times a second; cleared if it comes back.
    FCompositedDisplayLost: Boolean;
    // One tick of the composited pan: the recorded window's frame now,
    // as a source rectangle of the recording's own fixed size.
    procedure UpdateCompositedSourceRect; overload;
    // The same, for a caller that has already asked the window server
    // where the window is. Tick is that caller, and it needs the answer
    // for the camera anyway.
    procedure UpdateCompositedSourceRect(
      const AWindowRect: TCameraRect); overload;
    // Ends the poll. Private: Start restarts through it, Tick ends through
    // it, and Destroy is the only other caller.
    procedure Stop;
  public
    constructor Create(AHost: TCameraRideHost);
    destructor Destroy; override;
    // Turns a pending WINDOW recording into a pending region recording
    // on the display that window is on, so the capture composits
    // everything in front of it — the camera included. The four
    // parameters are the caller's pending request and are rewritten in
    // place when the answer is True. False, leaving all four untouched,
    // when the window's frame or its display cannot be resolved; the
    // recording then runs desktop-independent as it always did.
    function CompositeWindowForPending(var AWindowID: Cardinal;
      var ADisplayID: UInt32; var AHasRegion: Boolean;
      var ARegion: TCaptureRegion): Boolean;
    // Moves a visible camera window into the corner of the rectangle
    // about to be recorded, so the picture-in-picture goes into the file
    // the way Kap does it. A region recording docks into the region; a
    // window recording docks into the window's own frame. A display
    // recording already contains the camera wherever it stands, and a
    // camera that is off has nothing to move. UndockCamera puts it back
    // and is safe on every stop path, docked or not.
    procedure DockCameraForPending(AWindowID: Cardinal;
      ADisplayID: UInt32; AHasRegion: Boolean;
      const ARegion: TCaptureRegion);
    procedure UndockCamera;
    // Starts and stops the window ride's timer. Region recordings never
    // touch either: they ride the live animator's tick.
    procedure Start(AWindowID: Cardinal);
    // One turn of the ride; the 5 Hz timer's target.
    procedure Tick;
    // Forgets the composited recording without touching the camera —
    // what clearing a pending request does, where UndockCamera is what
    // ending a take does.
    procedure ClearComposited;
    // 0 unless the take running (or about to run) is a composited window
    // recording. The caller that started it reads this back to decide
    // whether to start the poll, whether to draw a frame, and whether
    // the rectangle is one the user chose.
    property CompositedWindowID: Cardinal read FCompositedWindowID;
  end;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // How often the camera ride polls a recorded *window*'s frame. Five
  // times a second, not thirty: nothing moves a window but a hand on a
  // trackpad, the poll is a CGWindowListCopyWindowInfo round trip rather
  // than arithmetic on numbers the app already has, and a
  // picture-in-picture that lands a fifth of a second behind a window
  // drag reads as "it follows" while thirty hertz of window-server
  // traffic buys nothing anybody can see. A region ride is free of this
  // trade entirely — it rides the live animator's own tick.
  CameraRideTickSeconds = 0.2;

// One window's frame, straight out of the window server. Synchronous and
// cheap — no run loop is pumped, which is what makes it callable from the
// recording start path and from a timer alike — where SCShareableContent
// is neither and carries no frame anyway.
//
// CGWindowListCopyWindowInfo answers in Quartz's global space: points
// with the origin at the TOP left of the primary display and y growing
// downwards. WindowBoundsScreenRect flips it into AppKit's, against the
// height of the screen whose origin is (0, 0) — which is
// NSScreen.screens[0], the one both spaces are anchored to.
function WindowScreenRect(AWindowID: Cardinal;
  out ARect: TCameraRect): Boolean;
var
  List: CFArrayRef;
  Info, BoundsDictionary: CFDictionaryRef;
  Bounds: CGRect;
  Screens: NSArray;
  PrimaryFrame: NSRect;
begin
  ARect := CameraRect(0, 0, 0, 0);
  Result := False;
  if AWindowID = 0 then
    Exit;
  Screens := NSScreen.screens;
  if (Screens = nil) or (Screens.count = 0) then
    Exit;
  PrimaryFrame := NSScreen(Screens.objectAtIndex(0)).frame;
  List := CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,
    AWindowID);
  if List = nil then
    Exit;
  try
    // Zero entries is the answer for a window that has gone — closed
    // mid-recording — and is how the ride stops gracefully rather than
    // leaving the camera parked on a rectangle that no longer exists.
    if CFArrayGetCount(List) < 1 then
      Exit;
    Info := CFDictionaryRef(CFArrayGetValueAtIndex(List, 0));
    if Info = nil then
      Exit;
    BoundsDictionary := CFDictionaryRef(CFDictionaryGetValue(Info,
      kCGWindowBounds));
    if BoundsDictionary = nil then
      Exit;
    if CGRectMakeWithDictionaryRepresentation(BoundsDictionary, Bounds) = 0 then
      Exit;
    ARect := WindowBoundsScreenRect(Bounds.origin.x, Bounds.origin.y,
      Bounds.size.width, Bounds.size.height,
      PrimaryFrame.origin.y + PrimaryFrame.size.height);
    Result := (ARect.Width > 0) and (ARect.Height > 0);
  finally
    CFRelease(List);
  end;
end;

constructor TCameraRide.Create(AHost: TCameraRideHost);
begin
  inherited Create;
  FHost := AHost;
end;

destructor TCameraRide.Destroy;
begin
  // A timer left scheduled would fire into an object that is going away;
  // Stop invalidates and releases it.
  Stop;
  inherited Destroy;
end;

{ The composited window recording.

  **A window recording does not put the camera in the file.** That is not
  a guess: measured on this machine by recording one application's window
  through the ordinary path with a solid-magenta borderless window at
  window level 3 — the camera's own level — demonstrably over it on
  screen, and counting near-magenta pixels in the resulting frames.
  Zero, out of 1 754 000. `SCContentFilter.initWithDesktopIndependentWindow:`
  composits that one window and nothing on top of it, exactly as its
  header says.

  So docking the camera onto a recorded window used to be about the
  *screen* only. This is the other half: capture the **display** instead,
  with a source rectangle sitting exactly on that window's frame.
  ScreenCaptureKit then reads the screen, which has the camera on it, and
  the picture-in-picture really is composited into the file — the same
  way it already is for a region.

  **And it is not only the camera any more.** A desktop-independent
  window capture is the one target no post-recording effect can ever
  reach: its frames have no fixed relationship to the screen the pointer
  was measured against, so no pointer can be drawn back into them and no
  crop can be computed for them. A composited one is a display take in
  every way that matters — the samples map, the framing is written into
  the sidecar's own per-sample source rectangles, and a zoom composes
  inside the pan (Knips.Export.ZoomTrack) — so a window recording gets
  the same effects a region recording does, and gets them the same way:
  a raw take plus a render.

  **The trade is real and is not hidden.** A composited window recording
  captures whatever is in front of the window: a notification, a menu
  pulled down over it, another app's window dragged across. The
  desktop-independent path has none of that, and it is still what a
  window take that wants **nothing** uses — no camera, no pointer, no
  zoom. WindowTakeNeedsCompositing is where that line is drawn, and the
  principle behind it is that the cost is paid only where it buys
  something.

  **The rectangle pans and never resizes.** AVAssetWriter fixes the
  file's dimensions at the first frame; a window resized mid-take would
  otherwise stretch the picture. So the size is the window's frame at the
  start and the origin follows it, which is exactly what Follow Mouse
  does to a region — and it reuses the same machinery: the 5 Hz window
  poll that already moves the camera, and TRecordingSession.UpdateSourceRect.

  **Live effects stay off.** ResolveLiveEffects gives a window recording
  no Follow Mouse (and no live zoom, back when there was one), and that
  answer does not change
  because the capture underneath is now a display: a click has no fixed
  meaning in a window the user is free to move, and two owners for one
  source rectangle — the animator and this poll — is a rectangle that
  fights itself. StartPending therefore does not start the animator for a
  composited recording.

  The post-recording effects are a different matter and are not off at
  all: they are applied to the finished take, where the poll's own track
  says exactly which rectangle each frame was showing. }

function TCameraRide.CompositeWindowForPending(var AWindowID: Cardinal;
  var ADisplayID: UInt32; var AHasRegion: Boolean;
  var ARegion: TCaptureRegion): Boolean;
var
  WindowRect, Region: TCameraRect;
  ScreenFrame: NSRect;
  DisplayID: UInt32;
begin
  Result := False;
  if AWindowID = 0 then
    Exit;
  if not WindowScreenRect(AWindowID, WindowRect) then
    Exit;
  // The display the window is on, by its own frame rather than by the
  // main screen: a window on the external display must be captured from
  // the external display.
  if not DisplayIDForScreenRect(NSMakeRect(WindowRect.X, WindowRect.Y,
    WindowRect.Width, WindowRect.Height), DisplayID, ScreenFrame) then
    Exit;
  Region := ScreenRectRegion(WindowRect,
    CameraRect(ScreenFrame.origin.x, ScreenFrame.origin.y,
    ScreenFrame.size.width, ScreenFrame.size.height),
    WindowRect.Width, WindowRect.Height);
  if (Region.Width < 1) or (Region.Height < 1) then
    Exit;
  FCompositedWindowID := AWindowID;
  FCompositedDisplayID := DisplayID;
  FCompositedRegion.Left := Round(Region.X);
  FCompositedRegion.Top := Round(Region.Y);
  FCompositedRegion.Width := Round(Region.Width);
  FCompositedRegion.Height := Round(Region.Height);
  // From here the pending request is a region on a display, and every
  // step below — the display index, the source rectangle, the writer's
  // dimensions — treats it as one. The window id lives on in
  // FCompositedWindowID, which is what the poll rides and what the
  // camera docks onto.
  AWindowID := 0;
  ADisplayID := DisplayID;
  AHasRegion := True;
  ARegion := FCompositedRegion;
  Result := True;
end;

procedure TCameraRide.UpdateCompositedSourceRect;
var
  WindowRect: TCameraRect;
begin
  if (FCompositedWindowID = 0) or (FHost.RideSession = nil) then
    Exit;
  if not WindowScreenRect(FCompositedWindowID, WindowRect) then
    Exit;
  UpdateCompositedSourceRect(WindowRect);
end;

procedure TCameraRide.UpdateCompositedSourceRect(
  const AWindowRect: TCameraRect);
var
  WindowRect, Region: TCameraRect;
  ScreenFrame: NSRect;
  DisplayID: UInt32;
  Session: TRecordingSession;
begin
  Session := FHost.RideSession;
  if (FCompositedWindowID = 0) or (Session = nil) then
    Exit;
  WindowRect := AWindowRect;
  // The display is re-resolved every tick rather than taken from the
  // start, because the window can be dragged onto another one — and the
  // frame it comes back with is in AppKit's *global* space, so flipping
  // it against the display it started on would silently pan the capture
  // into whatever happens to sit at those coordinates on that screen.
  if not DisplayIDForScreenRect(NSMakeRect(WindowRect.X, WindowRect.Y,
    WindowRect.Width, WindowRect.Height), DisplayID, ScreenFrame) then
    Exit;
  if DisplayID <> FCompositedDisplayID then
  begin
    // The window has left the display this capture opened on. Following
    // it would mean rebuilding the content filter mid-stream — a new
    // SCDisplay, and an output size the writer fixed at the first frame
    // and cannot move — so the honest answer is to stop panning and
    // leave the capture where it is. Said once, not five times a second.
    if not FCompositedDisplayLost then
    begin
      FCompositedDisplayLost := True;
      FHost.RideRecordError('the recorded window moved to another '
        + 'display; the recording stays on the display it started on '
        + 'and no longer follows the window');
    end;
    Exit;
  end;
  // Back on the original display after a trip to another one: resume.
  FCompositedDisplayLost := False;
  // The size is the recording's, never the window's — see the header.
  Region := ScreenRectRegion(WindowRect,
    CameraRect(ScreenFrame.origin.x, ScreenFrame.origin.y,
    ScreenFrame.size.width, ScreenFrame.size.height),
    FCompositedRegion.Width, FCompositedRegion.Height);
  // Fire and forget, with the same latest-wins coalescing the live
  // animator relies on: an update refused while another is in flight is
  // dropped, and the next tick carries a newer rectangle than the
  // dropped one would have.
  Session.UpdateSourceRect(CGRectMake(Region.X, Region.Y, Region.Width,
    Region.Height));
end;

{ Docking the camera into the rectangle being recorded, and riding it.
  Kap composes the picture-in-picture into the file; Knips does no
  compositing at all (see the header of Knips.App.Camera), so the
  equivalent is to *put the window inside the rectangle* and let
  ScreenCaptureKit find it there.

  A region recording docks into the region. A window recording docks into
  the recorded window's own frame — which is where the user wants the
  picture whether or not it lands in the file, and for a window recording
  it does not: SCContentFilter.initWithDesktopIndependentWindow: composits
  that one window and nothing on top of it, measured (docs/architecture.md,
  "Docking"). A display recording does nothing at all, because it already
  contains the camera wherever it stands.

  And the rectangle moves. Follow Mouse pans a region; a recorded window
  goes wherever the user drags it, and ScreenCaptureKit's
  desktop-independent capture follows it there. A camera left at the
  rectangle's *initial* corner is out of shot the moment either happens,
  which is the bug the ride fixes. Two clocks drive it, because two very
  different things move the two rectangles:

  - a region rides the live animator's own tick, in the same turn that
    moves the capture and the frame around it, so the three cannot
    disagree by a frame (Knips.App.Live.UpdateCamera);
  - a window is polled, five times a second, because nothing in this
    process knows when a user drags a window and asking the window server
    is a round trip rather than arithmetic (Tick below). }

procedure TCameraRide.DockCameraForPending(AWindowID: Cardinal;
  ADisplayID: UInt32; AHasRegion: Boolean;
  const ARegion: TCaptureRegion);
var
  ScreenFrame: NSRect;
  WindowRect: TCameraRect;
  WindowID: Cardinal;
  Camera: TCameraPreview;
begin
  Camera := FHost.RideCamera;
  if (Camera = nil) or not Camera.Visible then
    Exit;
  // A window recording, ordinary or composited. The window's frame is
  // the rectangle, and it is read from the window server rather than
  // from ScreenCaptureKit: SCShareableContent carries no frame, and
  // asking it would pump the run loop on the one path that must not.
  //
  // CompositeWindowForPending has already moved the id across to
  // FCompositedWindowID by the time this runs, which is why both are
  // consulted; the dock itself is identical either way.
  WindowID := AWindowID;
  if WindowID = 0 then
    WindowID := FCompositedWindowID;
  if WindowID <> 0 then
  begin
    if not WindowScreenRect(WindowID, WindowRect) then
      Exit;
    if Camera.DockTo(WindowRect) then
      Start(WindowID);
    Exit;
  end;
  if not AHasRegion or (ADisplayID = 0) then
    Exit;
  // The same NSScreen lookup the border does, and the same flip: a
  // capture region is top-left display points, an NSWindow frame is
  // global bottom-left ones.
  if not ScreenFrameForDisplayID(ADisplayID, ScreenFrame) then
    Exit;
  // No timer for a region: StartLive hands the camera to the animator,
  // which rides it on the tick that pans the region.
  Camera.DockTo(RegionScreenRect(ARegion,
    CameraRect(ScreenFrame.origin.x, ScreenFrame.origin.y,
    ScreenFrame.size.width, ScreenFrame.size.height)));
end;

procedure TCameraRide.ClearComposited;
begin
  FCompositedWindowID := 0;
  FCompositedDisplayID := 0;
  FCompositedRegion := Default(TCaptureRegion);
  FCompositedDisplayLost := False;
end;

procedure TCameraRide.UndockCamera;
var
  Camera: TCameraPreview;
begin
  Stop;
  // The composited window recording ends with the same call that undocks
  // the camera, because it began with the same one that docked it: the
  // poll they share has no other reason to run. Cleared here rather than
  // in Stop, which Start calls on the way in.
  ClearComposited;
  Camera := FHost.RideCamera;
  if Camera <> nil then
    Camera.Undock;
end;

procedure TCameraRide.Start(AWindowID: Cardinal);
begin
  Stop;
  if AWindowID = 0 then
    Exit;
  FRideWindowID := AWindowID;
  // Created unscheduled and added to the common modes, exactly like the
  // live animator's timer and the camera's own snap ease — and for the
  // same measured reason: the camera window is draggable during a
  // recording, and a drag puts the run loop in
  // NSEventTrackingRunLoopMode, where a default-mode-only timer stops
  // firing. Scheduling first and then adding would register the same
  // timer twice and poll at ten hertz instead of five.
  FTimer :=
    NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats(
    CameraRideTickSeconds, FHost.RideTimerTarget, FHost.RideTimerSelector,
    nil, True);
  if FTimer = nil then
  begin
    // No timer, no ride: the camera stays wherever the dock put it while
    // the recorded window moves out from under it. Worth neither an error
    // nor a failed recording — the picture-in-picture is cosmetic and the
    // file is unaffected — but it is a real loss of the feature, not
    // "the old behaviour" as this once claimed.
    FRideWindowID := 0;
    Exit;
  end;
  FTimer.retain;
  NSRunLoop.currentRunLoop.addTimer_forMode(FTimer, NSRunLoopCommonModes);
end;

procedure TCameraRide.Stop;
begin
  FRideWindowID := 0;
  if FTimer = nil then
    Exit;
  FTimer.invalidate;
  FTimer.release;
  FTimer := nil;
end;

procedure TCameraRide.Tick;
var
  Rect: TCameraRect;
  HasRect: Boolean;
  Camera: TCameraPreview;
begin
  // An export owns the main thread and drains events to draw its
  // progress, which is how a timer can fire in the middle of one — the
  // same guard the live tick carries, for the same reason.
  if FHost.RideBusy then
    Exit;
  // ONE window-server round trip a tick. The composited pan and the
  // camera ride follow the same window whenever both are live, and each
  // used to ask for its frame separately — two synchronous round trips
  // five times a second for one answer, on the thread the whole app
  // draws from.
  HasRect := (FRideWindowID <> 0) and WindowScreenRect(FRideWindowID, Rect);
  // The composited recording's pan comes first and is unconditional: it
  // is what keeps the *capture* on the window, where the camera ride is
  // only what keeps the picture-in-picture in the corner. A camera
  // switched off mid-take must not stop the capture following the
  // window.
  if HasRect and (FCompositedWindowID = FRideWindowID) then
    UpdateCompositedSourceRect(Rect)
  else
    UpdateCompositedSourceRect;
  if FRideWindowID = 0 then
  begin
    Stop;
    Exit;
  end;
  Camera := FHost.RideCamera;
  if (Camera = nil) or not Camera.Riding then
  begin
    // The camera decides for itself whether a ride is still live; a stop
    // that has already undocked answers False here. The timer only goes
    // if nothing else needs it — a composited recording does.
    if FCompositedWindowID = 0 then
      Stop;
    Exit;
  end;
  if not HasRect then
  begin
    // The recorded window has gone. The recording carries on — SCK is
    // free to keep a stream on a window that closed — but there is
    // nothing left to follow, so stop rather than chase a rectangle that
    // no longer exists. Not an error: closing a window mid-recording is
    // the user's business.
    Stop;
    Exit;
  end;
  Camera.RideTo(Rect);
end;

{$ENDIF}

end.

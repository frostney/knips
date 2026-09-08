unit Knips.App.Live;

// The live recording effects — Zoom on Click and Follow Mouse — as one
// main-thread animator driven by the menu-bar app's 30 Hz timer.
//
// It owns no Objective-C class and no timer of its own. Knips.App holds
// the NSTimer (whose target is the same runtime-built KnipsAppTarget every
// other action goes through, so this feature adds no seventh runtime
// class) and calls Tick; everything below runs inside NSApp's run loop on
// the main thread, so none of the capture-queue rules apply here.
//
// What a tick does, in order:
//
//   1. take the real elapsed time since the last tick — not the timer's
//      nominal interval, so a run loop held up by something else pans
//      further rather than lurching;
//   2. read the mouse position and button state (see "Why polling");
//   3. turn a fresh press inside the recorded area into a zoom target;
//   4. pan the follow window toward the mouse, ease the zoom toward its
//      target, and compose the two into one sourceRect
//      (Knips.Recording.LiveMath — platform-neutral and tested);
//   5. hand that rectangle to the recording session, and move the
//      on-screen border — and a docked camera — to the *follow window*
//      if there is one.
//
// **Two followers, one clock.** The frame around the region and a camera
// docked into it both have to move with the pan, and both move in the
// tick that moves the capture, so the three never disagree by a frame.
// The camera's own arithmetic is its unit's (TCameraPreview.RideTo);
// this one only says when and to where.
//
// **The border tracks the window, not the crop.** Zoom is a crop of the
// same on-screen area, so zooming changes nothing about which pixels of
// the screen are being read and the frame must stay put; panning really
// does move the captured area, so the frame moves with it. Since the crop
// is by construction a subset of the window (ZoomedSourceRect clamps into
// it), a frame drawn around the window is never a lie — and a frame that
// chased the click point thirty times a second would be.
//
// **Why polling and not a global event monitor.** NSEvent's
// addGlobalMonitorForEventsMatchingMask:handler: does bind in FPC 3.2.2
// (checked) and needs no Input Monitoring grant for mouse events, and it
// would catch clicks shorter than a tick. It is not used, for three
// reasons. The animator has to sample the mouse *position* every tick for
// Follow Mouse anyway, so the button read is free and the monitor would be
// a second, block-based source of truth for the same gesture. A monitor is
// a retained object with a lifetime to get wrong across a recording that
// can fail at any point. And the project's own rules forbid test tooling
// that injects input, so a monitor's delivery could not be proven on this
// machine, where NSEvent.pressedMouseButtons and NSEvent.mouseLocation are
// two calls whose values can be read straight out.
//
// The cost is stated rather than hidden: a press-and-release shorter than
// one tick — about 33 ms — is not seen. A deliberate click is 50 to 150 ms,
// so this is a rare miss and it costs a zoom, not a recording.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  CocoaAll,
  Knips.App.Border,
  Knips.App.Camera,
  Knips.App.State,
  Knips.Options,
  Knips.Recording,
  Knips.Recording.LiveMath,
  MacOSAll;

type
  TLiveAnimator = class
  private
    // None of the three is owned: the controller outlives the animator
    // and all of them go away with the recording.
    FSession: TRecordingSession;
    FBorder: TRecordingBorder;
    FCamera: TCameraPreview;
    FActive: Boolean;
    FZoomOnClick: Boolean;
    FFollowMouse: Boolean;
    // The recorded display, in AppKit's global bottom-left points; the
    // one thing that turns NSEvent.mouseLocation into this display's own
    // top-left points.
    FScreenFrame: NSRect;
    // Everything below is in the display's top-left points, the space
    // sourceRect and TCaptureRegion both live in.
    FBounds: TLiveRect;
    FBase: TLiveRect;
    FWindow: TLiveRect;
    FZoom: TEasedScalar;
    FFocusX: TEasedScalar;
    FFocusY: TEasedScalar;
    FZoomedIn: Boolean;
    // Seconds of hold left, counted down by the same clamped tick delta
    // the easings advance on — *not* a wall-clock deadline. `Now` can
    // step backwards (an NTP correction, a DST change, the user setting
    // the clock), and a deadline in that scale would then sit in the
    // future for as long as the step lasted and freeze the zoom.
    FHoldRemaining: Double;
    FLastTick: TDateTime;
    FButtonDown: Boolean;
    // The band along the top of the recorded display that belongs to the
    // menu bar. Clicks there are never content — including the click on
    // the status item that stops the recording.
    FMenuBarInset: Double;
    // What the border was last moved to, so a settled pan stops sending
    // setFrame: to the window server every tick.
    FBorderRegion: TCaptureRegion;
    FHasBorderRegion: Boolean;

    // The last rectangle handed to the session, kept so a caller can see
    // what the animator is actually asking for.
    FSourceRect: TLiveRect;
    function ScreenPointToDisplay(const APoint: NSPoint;
      out AX: Double; out AY: Double): Boolean;
    procedure HandleClick(AX, AY: Double);
    procedure UpdateBorder;
    procedure UpdateCamera;
  public
    // ADisplayFrame is the NSScreen frame of the display being recorded,
    // and ABaseRect the rectangle the recording was sized from, in that
    // display's top-left points (TRecordingSession.BaseSourceRect).
    // ABorder may be nil; pass it only when the frame is safe to move —
    // that is, when the capture really did exclude it.
    //
    // ACamera may be nil too, and is simply ignored unless it is docked
    // into the region this recording is panning: the camera decides for
    // itself whether a ride is live (TCameraPreview.RideTo), so nothing
    // here has to know what the dock did.
    //
    // Does nothing at all when neither effect is asked for, or when the
    // session cannot move its source rectangle.
    procedure Start(ASession: TRecordingSession; ABorder: TRecordingBorder;
      ACamera: TCameraPreview; const ADisplayFrame: NSRect;
      const ABaseRect: TLiveRect; AZoomOnClick, AFollowMouse: Boolean);
    // Lets go of the session, the border and the camera without sending
    // anything — see the body for why the obvious "put it back" is wrong.
    procedure Stop;
    procedure Tick;
    property Active: Boolean read FActive;
    // The base-sized rectangle Follow Mouse has panned to, and the
    // rectangle actually being captured (that one cropped by the zoom).
    // Both in the recorded display's own top-left points. Read-only, and
    // only meaningful while Active.
    property Window: TLiveRect read FWindow;
    property SourceRect: TLiveRect read FSourceRect;
  end;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // A tick that arrives later than this is a run loop that was blocked
  // (a menu tracked, a window resized). Advancing the easings by the
  // whole gap would jump the picture; capping turns it into a slower
  // animation instead, which is the lesser of the two.
  MaxTickSeconds = 0.25;
  // NSEvent.pressedMouseButtons is a bitmask; bit 0 is the left button.
  // The right button and the others are deliberately ignored: a
  // right-click opens a context menu, and zooming the recording out from
  // under one is not what anybody means by it.
  LeftMouseButtonMask = 1;
  // Points. Below this the border is already where it should be, and
  // setFrame:display: is a trip to the window server.
  BorderMoveEpsilon = 0.5;

// How much of the top of a screen the menu bar takes, in points. Two
// sources, and the larger wins: NSStatusBar's own `thickness` (22 on
// every Mac so far) and the screen's actual top inset, which is
// `frame` minus `visibleFrame` measured from the top. They disagree, and
// the inset is the honest one where they do — on a notched Mac this
// machine reports thickness 22 against an inset of 39. Only the *top*
// inset is used: the Dock, which is the other thing visibleFrame
// excludes, can sit at the left, right or bottom but never the top.
// A menu bar set to auto-hide gives an inset of 0, and the thickness
// floor then still covers the moment it is showing.
function MenuBarInsetOf(const AScreenFrame: NSRect): Double;
var
  Screen: NSScreen;
  Screens: NSArray;
  Inset, Thickness: Double;
  I: Integer;
begin
  Thickness := NSStatusBar.systemStatusBar.thickness;
  Result := Thickness;
  Screens := NSScreen.screens;
  for I := 0 to Integer(Screens.count) - 1 do
  begin
    Screen := NSScreen(Screens.objectAtIndex(I));
    if not NSEqualRects(Screen.frame, AScreenFrame) then
      Continue;
    Inset := (Screen.frame.origin.y + Screen.frame.size.height)
      - (Screen.visibleFrame.origin.y + Screen.visibleFrame.size.height);
    if Inset > Result then
      Result := Inset;
    Break;
  end;
  if Result < 0 then
    Result := 0;
end;

{ TLiveAnimator }

procedure TLiveAnimator.Start(ASession: TRecordingSession;
  ABorder: TRecordingBorder; ACamera: TCameraPreview;
  const ADisplayFrame: NSRect; const ABaseRect: TLiveRect;
  AZoomOnClick, AFollowMouse: Boolean);
begin
  Stop;
  if (ASession = nil) or not ASession.SupportsLiveUpdate then
    Exit;
  if not AZoomOnClick and not AFollowMouse then
    Exit;
  if (ABaseRect.Width <= 0) or (ABaseRect.Height <= 0) then
    Exit;
  if (ADisplayFrame.size.width <= 0) or (ADisplayFrame.size.height <= 0) then
    Exit;
  FSession := ASession;
  FBorder := ABorder;
  FCamera := ACamera;
  FZoomOnClick := AZoomOnClick;
  FFollowMouse := AFollowMouse;
  FScreenFrame := ADisplayFrame;
  // The display in its own top-left points: the origin is 0, 0 whatever
  // the screen's place in the global arrangement, because that is the
  // space ScreenCaptureKit measures sourceRect in.
  FBounds := LiveRect(0, 0, ADisplayFrame.size.width,
    ADisplayFrame.size.height);
  FBase := ClampRectInside(ABaseRect, FBounds);
  FWindow := FBase;
  FSourceRect := FBase;
  FZoom := EasedScalar(LiveMinZoom);
  FFocusX := EasedScalar(FBase.X + FBase.Width / 2);
  FFocusY := EasedScalar(FBase.Y + FBase.Height / 2);
  FZoomedIn := False;
  FHoldRemaining := 0;
  FMenuBarInset := MenuBarInsetOf(ADisplayFrame);
  FLastTick := Now;
  // Whatever the button is doing at this instant is not a click *into*
  // this recording: the click that started it may still be down.
  FButtonDown := (NSEvent.pressedMouseButtons and LeftMouseButtonMask) <> 0;
  FHasBorderRegion := False;
  FActive := True;
end;

// Deliberately sends nothing. A last update putting the capture back on
// its base rectangle was the obvious thing to do and is the wrong one:
// it lands as an instantaneous jump in the final frames of the clip,
// which is the worst possible place for one. The animation is by
// construction a valid framing at every instant, so the file simply ends
// where it was, and there is one fewer update racing the stop.
procedure TLiveAnimator.Stop;
begin
  FActive := False;
  FSession := nil;
  FBorder := nil;
  // Not Undock: putting the camera back is the stop path's business, and
  // it has to happen after FinishCapture rather than here (see
  // Knips.App.FinishRecording). Letting go of the pointer is all this owes.
  FCamera := nil;
  FZoomOnClick := False;
  FFollowMouse := False;
  FHasBorderRegion := False;
end;

// NSEvent.mouseLocation is in AppKit's global screen space: points,
// bottom-left origin, measured from the *main* screen's lower-left
// corner. ScreenCaptureKit wants the recorded display's own points from
// its top-left corner, so the y flip happens against that display's
// frame, exactly as in Knips.App.Overlay and Knips.App.Border. False when
// the pointer is on some other display, where neither effect has anything
// to say.
function TLiveAnimator.ScreenPointToDisplay(const APoint: NSPoint;
  out AX: Double; out AY: Double): Boolean;
begin
  AX := APoint.x - FScreenFrame.origin.x;
  AY := FScreenFrame.origin.y + FScreenFrame.size.height - APoint.y;
  Result := (AX >= 0) and (AX <= FScreenFrame.size.width)
    and (AY >= 0) and (AY <= FScreenFrame.size.height);
end;

// A press inside the area being recorded. Outside it the click belongs to
// something the viewer will never see, so it does not restart the hold
// either — a zoom that refuses to let go because the user is working in
// another window would be worse than no zoom at all.
//
// The menu-bar band is carved out even when it *is* inside the recorded
// area, which for a whole-display recording it always is. The click that
// stops a recording is a click on Knips's own status item, and without
// this rule every full-screen capture would end by zooming into the top
// corner of the screen. Nothing else up there is content either: a menu
// title is a click on a menu, not on the thing being demonstrated.
procedure TLiveAnimator.HandleClick(AX, AY: Double);
begin
  if AY < FMenuBarInset then
    Exit;
  if not LiveRectContains(FWindow, AX, AY) then
    Exit;
  // Retarget rather than restart: EasedScalarRetarget begins the new
  // curve at the value the old one had reached, and smoothstep leaves
  // that point at zero velocity, so a second click part way through the
  // first zoom neither jumps nor reverses at speed.
  if not FZoomedIn then
    FZoom := EasedScalarRetarget(FZoom, LiveClickZoom, LiveZoomInSeconds);
  FFocusX := EasedScalarRetarget(FFocusX, AX, LiveZoomInSeconds);
  FFocusY := EasedScalarRetarget(FFocusY, AY, LiveZoomInSeconds);
  FZoomedIn := True;
  // The hold runs from the *last* click, so a burst of clicks holds once
  // rather than easing out between them.
  FHoldRemaining := LiveZoomHoldSeconds;
end;

procedure TLiveAnimator.UpdateBorder;
var
  Region: TCaptureRegion;
begin
  // Only a pan moves the frame. A zoom crops inside the same on-screen
  // rectangle, so the capture area has not moved and neither should the
  // thing drawn around it.
  if (FBorder = nil) or not FFollowMouse then
    Exit;
  Region := RegionFromLiveRect(FWindow);
  if FHasBorderRegion and (Abs(Region.Left - FBorderRegion.Left)
    < BorderMoveEpsilon) and (Abs(Region.Top - FBorderRegion.Top)
    < BorderMoveEpsilon) then
    Exit;
  FBorder.MoveTo(Region);
  FBorderRegion := Region;
  FHasBorderRegion := True;
end;

// The second follower. Same rule as the border — only a pan moves it,
// because a zoom crops inside the same on-screen rectangle — and the same
// space conversion the controller did when it docked the camera in the
// first place: the follow window is in the recorded display's own
// top-left points, an NSWindow frame is in AppKit's global bottom-left
// ones.
//
// No epsilon here: RideTo has its own, and it is the one that knows
// whether the *window* would actually move. Nothing else is filtered
// either — the camera answers "am I riding?" for itself, so a camera
// that is off, undocked, being dragged or mid-snap costs one call and
// nothing else.
procedure TLiveAnimator.UpdateCamera;
var
  Region: TCaptureRegion;
begin
  if (FCamera = nil) or not FFollowMouse then
    Exit;
  Region := RegionFromLiveRect(FWindow);
  FCamera.RideTo(RegionScreenRect(Region,
    CameraRect(FScreenFrame.origin.x, FScreenFrame.origin.y,
    FScreenFrame.size.width, FScreenFrame.size.height)));
end;

procedure TLiveAnimator.Tick;
var
  Moment: TDateTime;
  Delta, MouseX, MouseY: Double;
  OnDisplay, Down: Boolean;
begin
  if not FActive or (FSession = nil) then
    Exit;
  // The recording ended under us — a writer failure, a stop that has not
  // reached this object yet. Nothing to animate and nothing to report.
  if not FSession.Capturing then
  begin
    FActive := False;
    Exit;
  end;
  // ScreenCaptureKit gave up on live reconfiguration part way through
  // (it refused enough updates in a row that the stream stopped trying).
  // Carrying on would move the border and the easings against a capture
  // that no longer follows them, which is worse than standing still: the
  // recording continues, at whatever rectangle last took. The frame is
  // left where it is rather than snapped anywhere — it is excluded from
  // the capture either way, and every candidate position is a guess.
  if not FSession.SupportsLiveUpdate then
  begin
    FActive := False;
    Exit;
  end;

  Moment := Now;
  Delta := (Moment - FLastTick) * SecsPerDay;
  FLastTick := Moment;
  // A clock that stepped backwards reads as no time passing; one that
  // stepped forward, as a single late tick. Every duration in the
  // animator is driven from this one clamped number, which is what keeps
  // an NTP correction mid-zoom from being visible at all.
  if Delta < 0 then
    Delta := 0;
  if Delta > MaxTickSeconds then
    Delta := MaxTickSeconds;
  if FZoomedIn then
    FHoldRemaining := FHoldRemaining - Delta;

  OnDisplay := ScreenPointToDisplay(NSEvent.mouseLocation, MouseX, MouseY);

  // Edge-triggered: the transition, not the level, so holding the button
  // down through a drag zooms once rather than every tick.
  Down := (NSEvent.pressedMouseButtons and LeftMouseButtonMask) <> 0;
  if FZoomOnClick and Down and not FButtonDown and OnDisplay then
    HandleClick(MouseX, MouseY);
  FButtonDown := Down;

  // After the click, so a click that has just refilled the hold is not
  // immediately expired by the tick it arrived on.
  if FZoomedIn and (FHoldRemaining <= 0) then
  begin
    FZoom := EasedScalarRetarget(FZoom, LiveMinZoom, LiveZoomOutSeconds);
    FZoomedIn := False;
  end;

  if FFollowMouse and OnDisplay then
    FWindow := ApproachRect(FWindow,
      FollowWindowTarget(FWindow, FBounds, MouseX, MouseY,
      LiveDeadZoneFraction),
      ApproachFactor(Delta, LiveFollowTimeConstant));

  FZoom := EasedScalarAdvance(FZoom, Delta);
  FFocusX := EasedScalarAdvance(FFocusX, Delta);
  FFocusY := EasedScalarAdvance(FFocusY, Delta);

  FSourceRect := ZoomedSourceRect(FWindow, EasedScalarValue(FZoom),
    EasedScalarValue(FFocusX), EasedScalarValue(FFocusY));
  // Fire-and-forget. A rectangle that has not moved is skipped inside the
  // session, and one that arrives while ScreenCaptureKit is still
  // applying the last is dropped — the next tick carries a newer one.
  FSession.UpdateSourceRect(CGRectMake(FSourceRect.X, FSourceRect.Y,
    FSourceRect.Width, FSourceRect.Height));
  UpdateBorder;
  UpdateCamera;
end;

{$ENDIF}

end.

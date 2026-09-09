unit Knips.App.Live;

// Follow Mouse as a main-thread animator driven by the menu-bar app's
// 30 Hz timer. Zoom on Click is applied later by Knips.Export.ZoomTrack.
//
// Knips.App owns the timer and calls Tick inside NSApp's run loop. Each
// tick pans the capture toward the mouse using the elapsed time and the
// platform-neutral arithmetic in Knips.Recording.LiveMath, then moves
// the recording border and a docked camera with that same rectangle.
// TCameraPreview.RideTo decides whether the camera is riding.

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
    // The recorded display, in AppKit's global bottom-left points; the
    // one thing that turns NSEvent.mouseLocation into this display's own
    // top-left points.
    FScreenFrame: NSRect;
    // Everything below is in the display's top-left points, the space
    // sourceRect and TCaptureRegion both live in.
    FBounds: TLiveRect;
    FWindow: TLiveRect;
    FLastTick: TDateTime;
    // What the border was last moved to, so a settled pan stops sending
    // setFrame: to the window server every tick.
    FBorderRegion: TCaptureRegion;
    FHasBorderRegion: Boolean;

    function ScreenPointToDisplay(const APoint: NSPoint;
      out AX: Double; out AY: Double): Boolean;
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
    // The caller resolves Follow Mouse eligibility before starting. Does
    // nothing when the session cannot move its source rectangle.
    procedure Start(ASession: TRecordingSession; ABorder: TRecordingBorder;
      ACamera: TCameraPreview; const ADisplayFrame: NSRect;
      const ABaseRect: TLiveRect);
    // Lets go of the session, the border and the camera without sending
    // anything — see the body for why the obvious "put it back" is wrong.
    procedure Stop;
    procedure Tick;
    property Active: Boolean read FActive;
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
  // Points. Below this the border is already where it should be, and
  // setFrame:display: is a trip to the window server.
  BorderMoveEpsilon = 0.5;

{ TLiveAnimator }

procedure TLiveAnimator.Start(ASession: TRecordingSession;
  ABorder: TRecordingBorder; ACamera: TCameraPreview;
  const ADisplayFrame: NSRect; const ABaseRect: TLiveRect);
begin
  Stop;
  if (ASession = nil) or not ASession.SupportsLiveUpdate then
    Exit;
  if (ABaseRect.Width <= 0) or (ABaseRect.Height <= 0) then
    Exit;
  if (ADisplayFrame.size.width <= 0) or (ADisplayFrame.size.height <= 0) then
    Exit;
  FSession := ASession;
  FBorder := ABorder;
  FCamera := ACamera;
  FScreenFrame := ADisplayFrame;
  // The display in its own top-left points: the origin is 0, 0 whatever
  // the screen's place in the global arrangement, because that is the
  // space ScreenCaptureKit measures sourceRect in.
  FBounds := LiveRect(0, 0, ADisplayFrame.size.width,
    ADisplayFrame.size.height);
  FWindow := ClampRectInside(ABaseRect, FBounds);
  FLastTick := Now;
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
  FHasBorderRegion := False;
end;

// NSEvent.mouseLocation is in AppKit's global screen space: points,
// bottom-left origin, measured from the *main* screen's lower-left
// corner. ScreenCaptureKit wants the recorded display's own points from
// its top-left corner, so the y flip happens against that display's
// frame, exactly as in Knips.App.Overlay and Knips.App.Border. False when
// the pointer is on some other display, where Follow Mouse has nothing
// to track.
function TLiveAnimator.ScreenPointToDisplay(const APoint: NSPoint;
  out AX: Double; out AY: Double): Boolean;
begin
  AX := APoint.x - FScreenFrame.origin.x;
  AY := FScreenFrame.origin.y + FScreenFrame.size.height - APoint.y;
  Result := (AX >= 0) and (AX <= FScreenFrame.size.width)
    and (AY >= 0) and (AY <= FScreenFrame.size.height);
end;

procedure TLiveAnimator.UpdateBorder;
var
  Region: TCaptureRegion;
begin
  if FBorder = nil then
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

// The second follower uses the same space conversion the controller
// did when it docked the camera: the follow window is in the recorded
// display's own top-left points, an NSWindow frame is in AppKit's global
// bottom-left ones.
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
  if FCamera = nil then
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
  // Carrying on would move the border and the camera against a capture
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
  // stepped forward, as a single late tick, so a clock correction cannot
  // jump the pan across the display.
  if Delta < 0 then
    Delta := 0;
  if Delta > MaxTickSeconds then
    Delta := MaxTickSeconds;
  if ScreenPointToDisplay(NSEvent.mouseLocation, MouseX, MouseY) then
    FWindow := ApproachRect(FWindow,
      FollowWindowTarget(FWindow, FBounds, MouseX, MouseY,
      LiveDeadZoneFraction),
      ApproachFactor(Delta, LiveFollowTimeConstant));

  // Fire-and-forget. A rectangle that has not moved is skipped inside the
  // session, and one that arrives while ScreenCaptureKit is still
  // applying the last is dropped — the next tick carries a newer one.
  FSession.UpdateSourceRect(CGRectMake(FWindow.X, FWindow.Y,
    FWindow.Width, FWindow.Height));
  UpdateBorder;
  UpdateCamera;
end;

{$ENDIF}

end.

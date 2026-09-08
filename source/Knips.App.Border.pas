unit Knips.App.Border;

// The frame that stays on screen while a region is recorded: one
// borderless, transparent, passthrough window sitting on the region, with
// nothing in it but a stroked rectangle. Kap's marching-ants without the
// ants.
//
// Two rules decide the geometry, and both are about keeping the border
// out of the file:
//
//   1. The window is the recorded region *outset* by BorderWidth, and the
//      stroke runs along the window's own outer edge. Every border pixel
//      therefore lies outside the recorded rectangle — even if the
//      exclusion below were to fail, the capture cannot contain it.
//   2. The window's CGWindowID goes into TRecordingOptions.ExcludedWindowIDs,
//      which Knips.Recording hands to
//      SCContentFilter.initWithDisplay:excludingWindows:, so
//      ScreenCaptureKit never composites it into the stream at all.
//
// Coordinates. TCaptureRegion is in the display's own points with a
// top-left origin (see Knips.App.Overlay); NSWindow frames are in global
// points with a bottom-left origin. The flip happens once, in Show, using
// the NSScreen whose NSScreenNumber matches the region's display.
//
// The one Objective-C class here, KnipsBorderView, is assembled at run
// time (ADR-0002), same shape as the overlay's: a cdecl drawRect: that
// recovers the owning Pascal object from a knipsOwner ivar and never lets
// an exception back into AppKit.
//
// Everything runs on the main thread inside NSApp's run loop; the
// capture-queue rules do not apply here.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  CocoaAll,
  Knips.ObjC.Runtime,
  Knips.Options,
  MacOSAll;

type
  // Raised inside the drawRect: callback, where an exception cannot be
  // allowed to escape; the cdecl body reports through this instead.
  TBorderErrorEvent = procedure(const AMessage: string) of object;

  TRecordingBorder = class
  private
    FWindow: NSWindow;
    FView: NSView;
    FVisible: Boolean;
    FOnError: TBorderErrorEvent;
    // The screen the frame was put on, cached at Show so MoveTo can flip
    // a region into window coordinates without walking NSScreen.screens
    // thirty times a second.
    FScreenFrame: NSRect;
    // Top-left display points -> the borderless window's global,
    // bottom-left frame, outset by the border width.
    function FrameForRegion(const ARegion: TCaptureRegion): NSRect;
  public
    destructor Destroy; override;
    // Puts the frame around ARegion on the display ADisplayID names.
    // False when that display has no NSScreen or the window could not be
    // made — the caller records without a border rather than failing.
    // Raises EObjCRuntime when the border class cannot be registered.
    function Show(ADisplayID: UInt32; const ARegion: TCaptureRegion): Boolean;
    // Follows the region a Follow Mouse recording has panned to. One
    // setFrame:display: on the window that is already up, so the
    // CGWindowID — which is what the capture excludes — does not change,
    // and neither does rule 2 in the header above.
    //
    // Rule 1 (the geometry) does weaken here, and deliberately: the
    // window server lands the new frame on its own schedule and
    // ScreenCaptureKit applies the new sourceRect on its own, so for a
    // frame or two around a pan the two can disagree and part of the
    // border can fall inside the rectangle being captured. That is
    // exactly what rule 2 is the backstop for, and it is not
    // timing-dependent: an excluded window is never composited into the
    // stream at all. A recording whose border could *not* be excluded
    // therefore does not get Follow Mouse — Knips.App refuses it rather
    // than record a frame that keeps sliding into shot.
    procedure MoveTo(const ARegion: TCaptureRegion);
    procedure Hide;
    // The CGWindowID to exclude from the capture; 0 while hidden.
    function WindowID: Cardinal;
    // Called by the runtime-built view's method body.
    procedure Draw;
    procedure ReportError(const AMessage: string);
    property Visible: Boolean read FVisible;
    property OnError: TBorderErrorEvent read FOnError write FOnError;
  end;

// Registers KnipsBorderView once per process. Exposed so `knips probe`
// can gate on registration alone.
procedure EnsureBorderClasses;

// The frame, in AppKit's global bottom-left points, of the NSScreen
// carrying a CGDirectDisplayID. False when that display is not attached.
// Lives here because this is where the top-left/bottom-left flip already
// is; Knips.App.Live needs the same frame to turn a mouse position into
// the recorded display's own points.
function ScreenFrameForDisplayID(ADisplayID: UInt32;
  out AFrame: NSRect): Boolean;

// The other direction: which display holds a rectangle, by its centre.
// The composited window recording needs it — a window recording becomes
// a *display* recording with a source rectangle, and the display has to
// be the one the window is actually on rather than the main one. The
// centre rather than the origin, so a window straddling two displays is
// captured from the one showing most of it, which is also the one
// NSWindow.screen would answer. False when no attached display holds the
// centre; the caller then leaves the recording as it was.
function DisplayIDForScreenRect(const ARect: NSRect;
  out ADisplayID: UInt32; out AFrame: NSRect): Boolean;

function BorderViewClassName: string;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Knips.ObjC.TypeEncoding;

const
  ViewClassName = 'KnipsBorderView';
  ViewSuperclassName = 'NSView';
  // Points, so two device pixels on a Retina display — a one-point hair
  // reads as a smudge next to a window edge. The whole width lies
  // outside the recorded rectangle, so widening it costs the user
  // nothing but screen real estate.
  BorderWidth = 2;
  // The same level the selection overlay uses, and for the same reason:
  // FPC 3.2.2's NSScreenSaverWindowLevel evaluates to -1, while Apple's
  // CGWindowLevelForKey(kCGScreenSaverWindowLevelKey) is 1000. Above
  // every normal window, which is where a recording indicator belongs.
  BorderWindowLevel = 1000;
  ScreenNumberKey = 'NSScreenNumber';

var
  GViewClass: pobjc_class = nil;

function BorderViewClassName: string;
begin
  Result := ViewClassName;
end;

{ Runtime-built method body. Recovers the owning Pascal object from the
  view's knipsOwner ivar; a nil owner means the border is gone and the
  message is ignored. Wrapped in try..except for the same reason every
  body in Knips.App and Knips.App.Overlay is: AppKit's drawing sits above
  this frame and there is nothing there to unwind a Pascal exception. }

function OwnerOf(ASelf: id): TRecordingBorder; inline;
begin
  Result := TRecordingBorder(GetPointerIvar(ASelf, OwnerIvarName));
end;

procedure BorderDrawRect(ASelf: id; ACommand: SEL; ADirtyRect: NSRect); cdecl;
var
  Owner: TRecordingBorder;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.Draw;
  except
    on E: Exception do
      try
        if Owner <> nil then
          Owner.ReportError('drawRect:: ' + E.Message);
      except
        // Nothing left to try; swallowing beats unwinding into AppKit.
      end;
  end;
end;

procedure EnsureBorderClasses;
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
    if not Builder.AddPointerIvar(OwnerIvarName) then
      raise EObjCRuntime.Create('class_addIvar failed for ' + OwnerIvarName);
    if not Builder.AddMethod('drawRect:', @BorderDrawRect,
      MethodTypeEncoding(otVoid, [otRect])) then
      raise EObjCRuntime.Create('class_addMethod failed for drawRect:');
    GViewClass := Builder.Register;
  finally
    Builder.Free;
  end;
end;

// The NSScreen carrying a CGDirectDisplayID, or nil when the display has
// gone (unplugged between the drag and the start of the recording).
function ScreenForDisplayID(ADisplayID: UInt32): NSScreen;
var
  Screens: NSArray;
  Screen: NSScreen;
  Number: NSNumber;
  I: Integer;
begin
  Result := nil;
  Screens := NSScreen.screens;
  for I := 0 to Integer(Screens.count) - 1 do
  begin
    Screen := NSScreen(Screens.objectAtIndex(I));
    Number := NSNumber(Screen.deviceDescription.objectForKey(
      NSSTR(ScreenNumberKey)));
    if (Number <> nil) and (Number.unsignedIntValue = ADisplayID) then
      Exit(Screen);
  end;
end;

function ScreenFrameForDisplayID(ADisplayID: UInt32;
  out AFrame: NSRect): Boolean;
var
  Screen: NSScreen;
begin
  AFrame := NSMakeRect(0, 0, 0, 0);
  Screen := ScreenForDisplayID(ADisplayID);
  Result := Screen <> nil;
  if Result then
    AFrame := Screen.frame;
end;

function DisplayIDForScreenRect(const ARect: NSRect;
  out ADisplayID: UInt32; out AFrame: NSRect): Boolean;
var
  Screens: NSArray;
  Screen: NSScreen;
  Frame: NSRect;
  Number: NSNumber;
  CentreX, CentreY: Double;
  I: Integer;
begin
  ADisplayID := 0;
  AFrame := NSMakeRect(0, 0, 0, 0);
  Result := False;
  Screens := NSScreen.screens;
  if (Screens = nil) or (Screens.count = 0) then
    Exit;
  CentreX := ARect.origin.x + ARect.size.width / 2;
  CentreY := ARect.origin.y + ARect.size.height / 2;
  for I := 0 to Screens.count - 1 do
  begin
    Screen := NSScreen(Screens.objectAtIndex(I));
    Frame := Screen.frame;
    if (CentreX < Frame.origin.x)
      or (CentreX >= Frame.origin.x + Frame.size.width)
      or (CentreY < Frame.origin.y)
      or (CentreY >= Frame.origin.y + Frame.size.height) then
      Continue;
    // The same lookup the overlay does for a selection: NSScreenNumber
    // is the CGDirectDisplayID, and a screen without one is a screen the
    // recorder cannot name.
    Number := NSNumber(Screen.deviceDescription.objectForKey(
      NSSTR(ScreenNumberKey)));
    if Number = nil then
      Exit;
    ADisplayID := UInt32(Number.unsignedIntValue);
    AFrame := Frame;
    Exit(True);
  end;
end;

{ TRecordingBorder }

destructor TRecordingBorder.Destroy;
begin
  Hide;
  inherited Destroy;
end;

// Top-left display points -> global bottom-left points, then outset by the
// full border width so the stroke never overlaps the region.
function TRecordingBorder.FrameForRegion(
  const ARegion: TCaptureRegion): NSRect;
begin
  Result := NSMakeRect(
    FScreenFrame.origin.x + ARegion.Left - BorderWidth,
    FScreenFrame.origin.y + FScreenFrame.size.height
      - (ARegion.Top + ARegion.Height) - BorderWidth,
    ARegion.Width + 2 * BorderWidth,
    ARegion.Height + 2 * BorderWidth);
end;

function TRecordingBorder.Show(ADisplayID: UInt32;
  const ARegion: TCaptureRegion): Boolean;
var
  Screen: NSScreen;
  WindowRect, ContentBounds: NSRect;
  Allocated: id;
begin
  Hide;
  Result := False;
  if (ARegion.Width <= 0) or (ARegion.Height <= 0) then
    Exit;
  Screen := ScreenForDisplayID(ADisplayID);
  if Screen = nil then
    Exit;
  EnsureBorderClasses;

  FScreenFrame := Screen.frame;
  WindowRect := FrameForRegion(ARegion);
  ContentBounds := NSMakeRect(0, 0, WindowRect.size.width,
    WindowRect.size.height);

  FWindow := NSWindow(NSWindow.alloc
    .initWithContentRect_styleMask_backing_defer(WindowRect,
    NSBorderlessWindowMask, NSBackingStoreBuffered, False));
  if FWindow = nil then
    Exit;
  FWindow.setOpaque(False);
  FWindow.setBackgroundColor(NSColor.clearColor);
  FWindow.setLevel(BorderWindowLevel);
  // The whole point of the window: it is a marker, not a target. A plain
  // NSWindow also answers NO to canBecomeKeyWindow, so nothing here can
  // steal focus from whatever the user is recording.
  FWindow.setIgnoresMouseEvents(True);
  FWindow.setHasShadow(False);
  FWindow.setReleasedWhenClosed(False);
  FWindow.setCollectionBehavior(NSWindowCollectionBehaviorCanJoinAllSpaces
    or NSWindowCollectionBehaviorStationary
    or NSWindowCollectionBehaviorFullScreenAuxiliary);

  Allocated := AllocateInstance(GViewClass);
  if Allocated = nil then
  begin
    FWindow.release;
    FWindow := nil;
    Exit;
  end;
  FView := NSView(Allocated).initWithFrame(ContentBounds);
  if FView = nil then
  begin
    FWindow.release;
    FWindow := nil;
    Exit;
  end;
  SetPointerIvar(id(FView), OwnerIvarName, Self);
  FWindow.setContentView(FView);
  // setContentView: retains; balance the alloc.
  FView.release;
  // Not makeKeyAndOrderFront: the border must not take key status away
  // from the app the user is recording.
  FWindow.orderFrontRegardless;

  FVisible := True;
  Result := True;
end;

procedure TRecordingBorder.MoveTo(const ARegion: TCaptureRegion);
begin
  if (FWindow = nil) or not FVisible then
    Exit;
  if (ARegion.Width <= 0) or (ARegion.Height <= 0) then
    Exit;
  // The view keeps its own bounds because the region never changes size
  // — Follow Mouse pans a base-sized window — so this is a move, and
  // drawRect: has nothing new to do.
  FWindow.setFrame_display(FrameForRegion(ARegion), True);
end;

procedure TRecordingBorder.Hide;
begin
  if FView <> nil then
  begin
    SetPointerIvar(id(FView), OwnerIvarName, nil);
    FView := nil;
  end;
  if FWindow <> nil then
  begin
    FWindow.orderOut(nil);
    // Deferred like the overlay's: Hide can run from inside an AppKit
    // dispatch, and the window must outlive it.
    FWindow.autorelease;
    FWindow := nil;
  end;
  FVisible := False;
end;

function TRecordingBorder.WindowID: Cardinal;
begin
  if FWindow = nil then
    Result := 0
  else
    // NSWindow.windowNumber is the CGWindowID; ScreenCaptureKit's
    // SCWindow.windowID is the same number (verified on device: the
    // number this returns is found by TShareableContent.RetainWindow).
    Result := Cardinal(FWindow.windowNumber);
end;

procedure TRecordingBorder.Draw;
var
  Border: NSRect;
  Outline: NSBezierPath;
begin
  if FView = nil then
    Exit;
  // A path inset by half the line width, stroked at the full width,
  // covers exactly the outermost BorderWidth points of the window — the
  // ring that Show placed outside the recorded rectangle.
  Border := NSInsetRect(FView.bounds, BorderWidth / 2, BorderWidth / 2);
  NSColor.redColor.setStroke;
  Outline := NSBezierPath.bezierPathWithRect(Border);
  Outline.setLineWidth(BorderWidth);
  Outline.stroke;
end;

procedure TRecordingBorder.ReportError(const AMessage: string);
begin
  if Assigned(FOnError) then
    FOnError(AMessage);
end;

{$ENDIF}

end.

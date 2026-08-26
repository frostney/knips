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

{$I Shared.inc}
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
  public
    destructor Destroy; override;
    // Puts the frame around ARegion on the display ADisplayID names.
    // False when that display has no NSScreen or the window could not be
    // made — the caller records without a border rather than failing.
    // Raises EObjCRuntime when the border class cannot be registered.
    function Show(ADisplayID: UInt32; const ARegion: TCaptureRegion): Boolean;
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

function BorderViewClassName: string;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Knips.ObjC.TypeEncoding;

const
  ViewClassName = 'KnipsBorderView';
  ViewSuperclassName = 'NSView';
  OwnerIvarName = 'knipsOwner';
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

{ TRecordingBorder }

destructor TRecordingBorder.Destroy;
begin
  Hide;
  inherited Destroy;
end;

function TRecordingBorder.Show(ADisplayID: UInt32;
  const ARegion: TCaptureRegion): Boolean;
var
  Screen: NSScreen;
  Frame, WindowRect, ContentBounds: NSRect;
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

  Frame := Screen.frame;
  // Top-left display points -> global bottom-left points, then outset by
  // the full border width so the stroke never overlaps the region.
  WindowRect := NSMakeRect(
    Frame.origin.x + ARegion.Left - BorderWidth,
    Frame.origin.y + Frame.size.height - (ARegion.Top + ARegion.Height)
      - BorderWidth,
    ARegion.Width + 2 * BorderWidth,
    ARegion.Height + 2 * BorderWidth);
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

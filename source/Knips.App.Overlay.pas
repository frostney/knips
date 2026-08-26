unit Knips.App.Overlay;

// The Kap selection gesture: one borderless, transparent, screen-saver
// level window per display, the screen dimmed behind a crosshair, and a
// click-drag that punches the recording region out of the dim.
//
// Both Objective-C classes here are assembled at run time
// (ADR-0002): KnipsOverlayView is an NSView subclass whose drawRect:,
// mouse and key handlers are plain cdecl Pascal routines, and
// KnipsOverlayWindow is an NSWindow subclass that exists only to answer
// YES to canBecomeKeyWindow — a borderless window says NO by default, and
// without key status the view never sees the Esc keystroke.
//
// Coordinates. AppKit hands mouse locations in window coordinates, whose
// origin is the window's bottom-left corner with y growing upwards. The
// content view fills the window, so window coordinates are view
// coordinates. Each overlay window covers exactly one NSScreen's frame,
// so view coordinates are that display's own coordinates — with the
// origin at the bottom. ScreenCaptureKit's sourceRect wants the same
// points measured from the display's *top* left, so every y is flipped
// once, at the edge of this unit, as `ScreenHeight - y` — see
// SelectionRegion, the only place it happens. Nothing downstream deals in
// bottom-left origins.
//
// Everything in this unit runs on the main thread, inside NSApp's run
// loop; the capture-queue rules do not apply here.

{$I Shared.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  CocoaAll,
  Knips.App.State,
  Knips.Capture.ShareableContent,
  Knips.ObjC.Runtime,
  Knips.Options,
  MacOSAll;

type
  // ADisplayID is the CGDirectDisplayID of the screen the drag ended on;
  // ARegion is in that display's points with a top-left origin.
  TRegionSelectedEvent = procedure(ADisplayID: UInt32;
    const ARegion: TCaptureRegion) of object;

  TSelectionCancelledEvent = procedure of object;

  // Raised inside an Objective-C callback, where an exception cannot be
  // allowed to escape; the cdecl bodies report through this instead.
  TOverlayErrorEvent = procedure(const AMessage: string) of object;

  TSelectionOverlay = class
  private
    type
      TOverlayScreen = record
        Window: NSWindow;
        View: NSView;
        DisplayID: UInt32;
        // Points; Height is the flip pivot for view -> display.
        Width: Double;
        Height: Double;
      end;
    var
      FScreens: array of TOverlayScreen;
      FVisible: Boolean;
      FSelecting: Boolean;
      FCursorPushed: Boolean;
      FActiveIndex: Integer;
      FAnchor: NSPoint;
      FCurrent: NSPoint;
      FOnSelected: TRegionSelectedEvent;
      FOnCancelled: TSelectionCancelledEvent;
      FOnError: TOverlayErrorEvent;
    function SelectionRegion(AIndex: Integer): TCaptureRegion;
    // The region the recorder will be given, back in the view's own
    // bottom-left coordinates, so what is drawn is what is recorded.
    function ClampedSelectionRect(AIndex: Integer): NSRect;
    procedure Invalidate;
    procedure DrawSizeLabel(AIndex: Integer; const ASelection: NSRect);
    procedure Finish(ACommitted: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    // One window per screen, key and in front, crosshair pushed. False
    // when not a single window could be created — the caller must not
    // stay in the selecting state on a False, or there is no way out.
    // Raises EObjCRuntime when the overlay classes cannot be registered.
    function Show: Boolean;
    procedure Hide;
    // Reports a message from inside an Objective-C callback.
    procedure ReportError(const AMessage: string);
    // Called by the runtime-built view's method bodies.
    procedure Draw(AIndex: Integer);
    procedure BeginSelection(AIndex: Integer; const APoint: NSPoint);
    procedure ExtendSelection(AIndex: Integer; const APoint: NSPoint);
    procedure EndSelection(AIndex: Integer; const APoint: NSPoint);
    procedure HandleKey(AKeyCode: Word);
    property Visible: Boolean read FVisible;
    property OnSelected: TRegionSelectedEvent read FOnSelected
      write FOnSelected;
    property OnCancelled: TSelectionCancelledEvent read FOnCancelled
      write FOnCancelled;
    property OnError: TOverlayErrorEvent read FOnError write FOnError;
  end;

// Registers KnipsOverlayView and KnipsOverlayWindow once per process.
// Exposed so `knips probe` can gate on registration alone.
procedure EnsureOverlayClasses;

function OverlayViewClassName: string;
function OverlayWindowClassName: string;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Knips.ObjC.TypeEncoding;

const
  ViewClassName = 'KnipsOverlayView';
  WindowClassName = 'KnipsOverlayWindow';
  ViewSuperclassName = 'NSView';
  WindowSuperclassName = 'NSWindow';
  OwnerIvarName = 'knipsOwner';
  IndexIvarName = 'knipsIndex';
  // Kap dims the rest of the screen rather than hiding it.
  DimAlpha = 0.35;
  // kCGScreenSaverWindowLevel: above every normal window, the Dock, and
  // the menu bar, which is where a selection overlay belongs. NOT the
  // CocoaAll constant: FPC 3.2.2's NSScreenSaverWindowLevel evaluates to
  // -1 — *below* the desktop — which put the overlay behind everything
  // (seen on device; Apple's CGWindowLevelForKey(kCGScreenSaverWindowLevelKey)
  // is 1000).
  OverlayWindowLevel = 1000;
  LabelBackdropAlpha = 0.75;
  LabelFontSize = 11;
  LabelPadding = 4;
  LabelGap = 6;
  LabelCornerRadius = 3;
  SelectionBorderWidth = 1;
  // kVK_Escape from Carbon's Events.h; AppKit reports it in keyCode.
  EscapeKeyCode = 53;
  ScreenNumberKey = 'NSScreenNumber';
  NoActiveScreen = -1;

var
  GViewClass: pobjc_class = nil;
  GWindowClass: pobjc_class = nil;

function OverlayViewClassName: string;
begin
  Result := ViewClassName;
end;

function OverlayWindowClassName: string;
begin
  Result := WindowClassName;
end;

{ Runtime-built method bodies. Each one recovers the owning Pascal object
  from the view's knipsOwner ivar; a nil owner means the overlay is gone
  and the message is ignored.

  Every body is wrapped in try..except. There is no Objective-C frame that
  could catch a Pascal exception, so one escaping here would unwind
  through AppKit's own stack — drawing, event dispatch and the run loop
  all sit above these. Anything raised is turned into a message on the
  overlay's OnError (the app's NSLog + "Last error" path) and the method
  returns normally. }

function OwnerOf(ASelf: id): TSelectionOverlay; inline;
begin
  Result := TSelectionOverlay(GetPointerIvar(ASelf, OwnerIvarName));
end;

function IndexOf(ASelf: id): Integer; inline;
begin
  Result := Integer(PtrUInt(GetPointerIvar(ASelf, IndexIvarName)));
end;

function PointInView(ASelf: id; AEvent: id): NSPoint; inline;
begin
  // locationInWindow is in window coordinates; the overlay's content view
  // fills the window, so the conversion is an identity today and stays
  // correct if that ever changes.
  Result := NSView(ASelf).convertPoint_fromView(
    NSEvent(AEvent).locationInWindow, nil);
end;

// Reports what a body caught, without letting the reporting itself throw.
procedure HandleBodyException(AOwner: TSelectionOverlay;
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

procedure OverlayDrawRect(ASelf: id; ACommand: SEL; ADirtyRect: NSRect); cdecl;
var
  Owner: TSelectionOverlay;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.Draw(IndexOf(ASelf));
  except
    on E: Exception do
      HandleBodyException(Owner, 'drawRect:', E);
  end;
end;

procedure OverlayMouseDown(ASelf: id; ACommand: SEL; AEvent: id); cdecl;
var
  Owner: TSelectionOverlay;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.BeginSelection(IndexOf(ASelf), PointInView(ASelf, AEvent));
  except
    on E: Exception do
      HandleBodyException(Owner, 'mouseDown:', E);
  end;
end;

procedure OverlayMouseDragged(ASelf: id; ACommand: SEL; AEvent: id); cdecl;
var
  Owner: TSelectionOverlay;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.ExtendSelection(IndexOf(ASelf), PointInView(ASelf, AEvent));
  except
    on E: Exception do
      HandleBodyException(Owner, 'mouseDragged:', E);
  end;
end;

procedure OverlayMouseUp(ASelf: id; ACommand: SEL; AEvent: id); cdecl;
var
  Owner: TSelectionOverlay;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.EndSelection(IndexOf(ASelf), PointInView(ASelf, AEvent));
  except
    on E: Exception do
      HandleBodyException(Owner, 'mouseUp:', E);
  end;
end;

procedure OverlayKeyDown(ASelf: id; ACommand: SEL; AEvent: id); cdecl;
var
  Owner: TSelectionOverlay;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.HandleKey(NSEvent(AEvent).keyCode);
  except
    on E: Exception do
      HandleBodyException(Owner, 'keyDown:', E);
  end;
end;

function OverlayAcceptsFirstResponder(ASelf: id; ACommand: SEL): ObjCBOOL;
  cdecl;
begin
  Result := ObjCBOOL(True);
end;

// A borderless NSWindow answers NO, which would keep the view off the
// responder chain and swallow Esc.
function OverlayCanBecomeKeyWindow(ASelf: id; ACommand: SEL): ObjCBOOL; cdecl;
begin
  Result := ObjCBOOL(True);
end;

procedure AddMethodOrFail(ABuilder: TRuntimeClassBuilder;
  const ASelector: string; AImplementation: TObjCMethodImplementation;
  const ATypeEncoding: string);
begin
  if not ABuilder.AddMethod(ASelector, AImplementation, ATypeEncoding) then
    raise EObjCRuntime.Create('class_addMethod failed for ' + ASelector);
end;

procedure BuildViewClass;
var
  Builder: TRuntimeClassBuilder;
  EventEncoding: string;
begin
  Builder := TRuntimeClassBuilder.Create(ViewClassName, ViewSuperclassName);
  try
    if not Builder.AddPointerIvar(OwnerIvarName) then
      raise EObjCRuntime.Create('class_addIvar failed for ' + OwnerIvarName);
    if not Builder.AddPointerIvar(IndexIvarName) then
      raise EObjCRuntime.Create('class_addIvar failed for ' + IndexIvarName);
    EventEncoding := MethodTypeEncoding(otVoid, [otObject]);
    AddMethodOrFail(Builder, 'drawRect:', @OverlayDrawRect,
      MethodTypeEncoding(otVoid, [otRect]));
    AddMethodOrFail(Builder, 'mouseDown:', @OverlayMouseDown, EventEncoding);
    AddMethodOrFail(Builder, 'mouseDragged:', @OverlayMouseDragged,
      EventEncoding);
    AddMethodOrFail(Builder, 'mouseUp:', @OverlayMouseUp, EventEncoding);
    AddMethodOrFail(Builder, 'keyDown:', @OverlayKeyDown, EventEncoding);
    AddMethodOrFail(Builder, 'acceptsFirstResponder',
      @OverlayAcceptsFirstResponder, MethodTypeEncoding(otBool, []));
    GViewClass := Builder.Register;
  finally
    Builder.Free;
  end;
end;

procedure BuildWindowClass;
var
  Builder: TRuntimeClassBuilder;
begin
  Builder := TRuntimeClassBuilder.Create(WindowClassName,
    WindowSuperclassName);
  try
    AddMethodOrFail(Builder, 'canBecomeKeyWindow',
      @OverlayCanBecomeKeyWindow, MethodTypeEncoding(otBool, []));
    GWindowClass := Builder.Register;
  finally
    Builder.Free;
  end;
end;

procedure EnsureOverlayClasses;
begin
  if GViewClass = nil then
  begin
    GViewClass := LookUpClass(ViewClassName);
    if GViewClass = nil then
      BuildViewClass;
  end;
  if GWindowClass = nil then
  begin
    GWindowClass := LookUpClass(WindowClassName);
    if GWindowClass = nil then
      BuildWindowClass;
  end;
end;

function NonNegative(AValue: Double): Double; inline;
begin
  if AValue < 0 then
    Result := 0
  else
    Result := AValue;
end;

function ScreenDisplayID(AScreen: NSScreen): UInt32;
var
  Number: NSNumber;
begin
  Result := 0;
  if AScreen = nil then
    Exit;
  Number := NSNumber(AScreen.deviceDescription.objectForKey(
    PascalToNSString(ScreenNumberKey)));
  if Number <> nil then
    Result := Number.unsignedIntValue;
end;

{ TSelectionOverlay }

constructor TSelectionOverlay.Create;
begin
  inherited Create;
  FActiveIndex := NoActiveScreen;
end;

destructor TSelectionOverlay.Destroy;
begin
  Hide;
  inherited Destroy;
end;

function TSelectionOverlay.Show: Boolean;
var
  Screens: NSArray;
  Screen: NSScreen;
  Frame, ContentBounds: NSRect;
  Window: NSWindow;
  Allocated: id;
  View: NSView;
  I, Created: Integer;
begin
  Result := FVisible;
  if FVisible then
    Exit;
  EnsureOverlayClasses;

  FSelecting := False;
  FActiveIndex := NoActiveScreen;
  Screens := NSScreen.screens;
  SetLength(FScreens, Screens.count);
  Created := 0;
  for I := 0 to High(FScreens) do
  begin
    FScreens[I] := Default(TOverlayScreen);
    Screen := NSScreen(Screens.objectAtIndex(I));
    Frame := Screen.frame;
    ContentBounds := NSMakeRect(0, 0, Frame.size.width, Frame.size.height);

    Allocated := AllocateInstance(GWindowClass);
    if Allocated = nil then
      Continue;
    Window := NSWindow(Allocated)
      .initWithContentRect_styleMask_backing_defer(Frame,
      NSBorderlessWindowMask, NSBackingStoreBuffered, False);
    if Window = nil then
    begin
      // An initialiser that returns nil has already released the
      // allocation; nothing to clean up, and nothing to store.
      Continue;
    end;
    Window.setOpaque(False);
    Window.setBackgroundColor(NSColor.clearColor);
    Window.setLevel(OverlayWindowLevel);
    Window.setIgnoresMouseEvents(False);
    Window.setHasShadow(False);
    Window.setReleasedWhenClosed(False);
    Window.setCollectionBehavior(NSWindowCollectionBehaviorCanJoinAllSpaces
      or NSWindowCollectionBehaviorStationary
      or NSWindowCollectionBehaviorFullScreenAuxiliary);

    View := NSView(AllocateInstance(GViewClass)).initWithFrame(ContentBounds);
    if View = nil then
    begin
      Window.release;
      Continue;
    end;
    SetPointerIvar(id(View), OwnerIvarName, Self);
    SetPointerIvar(id(View), IndexIvarName, Pointer(PtrUInt(I)));
    Window.setContentView(View);
    // setContentView: retains; balance the alloc.
    View.release;
    Window.makeFirstResponder(View);
    Window.makeKeyAndOrderFront(nil);

    FScreens[I].Window := Window;
    FScreens[I].View := View;
    FScreens[I].DisplayID := ScreenDisplayID(Screen);
    FScreens[I].Width := Frame.size.width;
    FScreens[I].Height := Frame.size.height;
    Inc(Created);
  end;

  if Created = 0 then
  begin
    // No window means no Esc, no click, no way out — and the overlay
    // sits above the menu bar, so the caller must not enter the
    // selecting state on this.
    Hide;
    Exit(False);
  end;

  NSApp.activateIgnoringOtherApps(True);
  if not FCursorPushed then
  begin
    NSCursor.crosshairCursor.push;
    FCursorPushed := True;
  end;
  FVisible := True;
  Result := True;
end;

procedure TSelectionOverlay.ReportError(const AMessage: string);
begin
  if Assigned(FOnError) then
    FOnError(AMessage);
end;

procedure TSelectionOverlay.Hide;
var
  I: Integer;
begin
  if FCursorPushed then
  begin
    NSCursor.crosshairCursor.pop;
    FCursorPushed := False;
  end;
  for I := 0 to High(FScreens) do
  begin
    if FScreens[I].View <> nil then
      SetPointerIvar(id(FScreens[I].View), OwnerIvarName, nil);
    if FScreens[I].Window <> nil then
    begin
      FScreens[I].Window.orderOut(nil);
      // Hide runs from inside the view's own event handler; deferring the
      // last release to the pool keeps the window alive until AppKit has
      // finished dispatching.
      FScreens[I].Window.autorelease;
    end;
  end;
  SetLength(FScreens, 0);
  FSelecting := False;
  FActiveIndex := NoActiveScreen;
  FVisible := False;
end;

procedure TSelectionOverlay.Invalidate;
var
  I: Integer;
begin
  for I := 0 to High(FScreens) do
    if FScreens[I].View <> nil then
      FScreens[I].View.setNeedsDisplay_(True);
end;

// The one place bottom-left view coordinates become top-left display
// points: y_display = screen height - y_view, applied to both corners
// before they are normalised into a region and clamped to the display.
function TSelectionOverlay.SelectionRegion(AIndex: Integer): TCaptureRegion;
var
  Height: Double;
begin
  Height := FScreens[AIndex].Height;
  Result := NormalizeSelection(FAnchor.x, Height - FAnchor.y,
    FCurrent.x, Height - FCurrent.y);
  Result := ClampSelection(Result, Round(FScreens[AIndex].Width),
    Round(Height));
end;

// …and back again, so the rectangle on screen is the rectangle recorded.
// Drawing the raw drag instead would show a border the capture never
// honours as soon as the pointer leaves the display.
function TSelectionOverlay.ClampedSelectionRect(AIndex: Integer): NSRect;
var
  Region: TCaptureRegion;
  Height: Double;
begin
  Region := SelectionRegion(AIndex);
  Height := FScreens[AIndex].Height;
  Result := NSMakeRect(Region.Left, Height - (Region.Top + Region.Height),
    Region.Width, Region.Height);
end;

procedure TSelectionOverlay.Draw(AIndex: Integer);
var
  Bounds, Selection, Border: NSRect;
  Outline: NSBezierPath;
  Top, Right: Double;
begin
  if (AIndex < 0) or (AIndex > High(FScreens))
    or (FScreens[AIndex].View = nil) then
    Exit;
  Bounds := FScreens[AIndex].View.bounds;
  NSColor.blackColor.colorWithAlphaComponent(DimAlpha).setFill;

  if (not FSelecting) or (AIndex <> FActiveIndex) then
  begin
    NSRectFill(Bounds);
    Exit;
  end;

  Selection := ClampedSelectionRect(AIndex);
  if (Selection.size.width < 1) or (Selection.size.height < 1) then
  begin
    NSRectFill(Bounds);
    Exit;
  end;

  // Dim in four bands around the selection instead of compositing a
  // transparent hole: no drawing mode to get wrong, same result. Every
  // extent goes through NonNegative — a band of negative width would be
  // normalised by NSRectFill into a filled strip on the wrong side.
  Top := Selection.origin.y + Selection.size.height;
  Right := Selection.origin.x + Selection.size.width;
  NSRectFill(NSMakeRect(0, 0, Bounds.size.width,
    NonNegative(Selection.origin.y)));
  NSRectFill(NSMakeRect(0, Top, Bounds.size.width,
    NonNegative(Bounds.size.height - Top)));
  NSRectFill(NSMakeRect(0, Selection.origin.y,
    NonNegative(Selection.origin.x), Selection.size.height));
  NSRectFill(NSMakeRect(Right, Selection.origin.y,
    NonNegative(Bounds.size.width - Right), Selection.size.height));

  // A half-point outset puts the 1 pt stroke outside the recorded pixels.
  Border := NSInsetRect(Selection, -0.5, -0.5);
  NSColor.whiteColor.setStroke;
  Outline := NSBezierPath.bezierPathWithRect(Border);
  Outline.setLineWidth(SelectionBorderWidth);
  Outline.stroke;

  DrawSizeLabel(AIndex, Selection);
end;

procedure TSelectionOverlay.DrawSizeLabel(AIndex: Integer;
  const ASelection: NSRect);
var
  Region: TCaptureRegion;
  Text: NSString;
  Attributes: NSMutableDictionary;
  TextSize: NSSize;
  Origin: NSPoint;
  Backdrop: NSRect;
  Bounds: NSRect;
begin
  Region := SelectionRegion(AIndex);
  Text := PascalToNSString(Format('%d × %d', [Region.Width, Region.Height]));
  Attributes := NSMutableDictionary.dictionaryWithCapacity(2);
  Attributes.setObject_forKey(NSFont.systemFontOfSize(LabelFontSize),
    id(NSFontAttributeName));
  Attributes.setObject_forKey(NSColor.whiteColor,
    id(NSForegroundColorAttributeName));
  TextSize := Text.sizeWithAttributes(Attributes);

  Bounds := FScreens[AIndex].View.bounds;
  Origin.x := ASelection.origin.x
    + (ASelection.size.width - TextSize.width) / 2;
  Origin.y := ASelection.origin.y - TextSize.height - LabelGap;
  if Origin.y - LabelPadding < 0 then
    Origin.y := ASelection.origin.y + ASelection.size.height + LabelGap;
  if Origin.x < LabelPadding then
    Origin.x := LabelPadding;
  if Origin.x + TextSize.width + LabelPadding > Bounds.size.width then
    Origin.x := Bounds.size.width - TextSize.width - LabelPadding;

  Backdrop := NSInsetRect(NSMakeRect(Origin.x, Origin.y, TextSize.width,
    TextSize.height), -LabelPadding, -LabelPadding / 2);
  NSColor.blackColor.colorWithAlphaComponent(LabelBackdropAlpha).setFill;
  NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(Backdrop,
    LabelCornerRadius, LabelCornerRadius).fill;
  Text.drawAtPoint_withAttributes(Origin, Attributes);
end;

procedure TSelectionOverlay.BeginSelection(AIndex: Integer;
  const APoint: NSPoint);
begin
  FActiveIndex := AIndex;
  FAnchor := APoint;
  FCurrent := APoint;
  FSelecting := True;
  Invalidate;
end;

procedure TSelectionOverlay.ExtendSelection(AIndex: Integer;
  const APoint: NSPoint);
begin
  if (not FSelecting) or (AIndex <> FActiveIndex) then
    Exit;
  FCurrent := APoint;
  Invalidate;
end;

procedure TSelectionOverlay.EndSelection(AIndex: Integer;
  const APoint: NSPoint);
begin
  if (not FSelecting) or (AIndex <> FActiveIndex) then
  begin
    Finish(False);
    Exit;
  end;
  FCurrent := APoint;
  Finish(True);
end;

procedure TSelectionOverlay.HandleKey(AKeyCode: Word);
begin
  if AKeyCode = EscapeKeyCode then
    Finish(False);
end;

// The single exit: tear the overlay down first so the windows are off
// screen before a capture can start, then report.
procedure TSelectionOverlay.Finish(ACommitted: Boolean);
var
  Region: TCaptureRegion;
  DisplayID: UInt32;
  Usable: Boolean;
begin
  if not FVisible then
    Exit;
  Usable := False;
  Region := Default(TCaptureRegion);
  DisplayID := 0;
  if ACommitted and FSelecting and (FActiveIndex >= 0)
    and (FActiveIndex <= High(FScreens)) then
  begin
    Region := SelectionRegion(FActiveIndex);
    DisplayID := FScreens[FActiveIndex].DisplayID;
    Usable := IsSelectionUsable(Region);
  end;
  Hide;
  if Usable then
  begin
    if Assigned(FOnSelected) then
      FOnSelected(DisplayID, Region);
  end
  else if Assigned(FOnCancelled) then
    FOnCancelled;
end;

{$ENDIF}

end.

unit Knips.Capture.ShareableContent;

// What the host can capture, as ScreenCaptureKit reports it. The query is
// asynchronous in the framework; this unit pumps the run loop until the
// completion block fires (the prototype's pattern) so callers get a plain
// synchronous object. Creating one triggers the Screen Recording
// permission prompt on first use.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cblocks}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  CocoaAll,
  Knips.Capture.ScreenCaptureKit,
  Knips.Options,
  MacOSAll;

type
  TDisplayInfo = record
    Index: Integer;
    DisplayID: UInt32;
    // Size in points; multiply by the backing scale for pixels.
    Width: Integer;
    Height: Integer;
    IsMain: Boolean;
  end;

  TWindowInfo = record
    WindowID: UInt32;
    Title: string;
    ApplicationName: string;
    // The owning process. ApplicationName is a display name and differs
    // between the shell binary and the app bundle, so this is what
    // identifies a window as one of ours.
    ProcessID: Integer;
    Width: Integer;
    Height: Integer;
    OnScreen: Boolean;
    Layer: Integer;
  end;

  EShareableContent = class(Exception);

  TShareableContent = class
  private
    FContent: SCShareableContent;
    function DisplayObject(AIndex: Integer): SCDisplay;
    procedure Query(ATimeoutSeconds: Double);
  public
    // Runs the framework query; raises EShareableContent on timeout or
    // framework error (typically missing Screen Recording permission).
    constructor Create;
    // The same query on a caller's own time budget, for the one caller
    // that cannot afford the default one: the Record Window submenu is
    // built inside AppKit's menu tracking, where five seconds of waiting
    // is a frozen menu. Everything else wants Create.
    constructor CreateWithin(ATimeoutSeconds: Double);
    destructor Destroy; override;
    function DisplayCount: Integer;
    function DisplayAt(AIndex: Integer): TDisplayInfo;
    // -1 selects the main display. The result is retained; release it.
    function RetainDisplay(AIndex: Integer): SCDisplay;
    // The enumeration index of a CGDirectDisplayID, or -1 when the
    // display is not shareable. The menu-bar app uses it to turn the
    // NSScreen the user dragged on into a --display index.
    function IndexOfDisplayID(ADisplayID: UInt32): Integer;
    function WindowCount: Integer;
    function WindowAt(AIndex: Integer): TWindowInfo;
    // nil when no window has that id. The result is retained; release it.
    function RetainWindow(AWindowID: UInt32): SCWindow;
  end;

// Pixels per point for a display, from its current display mode.
// Falls back to 1 when the mode cannot be read.
function DisplayBackingScale(ADisplayID: UInt32): Integer;

function NSStringToPascal(const AString: NSString): string;

// The other direction, for titles the app hands to AppKit. The result is
// autoreleased, as every +stringWith… is.
function PascalToNSString(const AValue: string): NSString;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // 5000 x 1 ms run-loop slices, as in the prototype.
  QueryTimeoutSlices = 5000;
  DefaultQueryTimeoutSeconds = QueryTimeoutSlices * FrameworkSliceSeconds;
  // How long a query waits for a previous, abandoned one's completion
  // before refusing: Knips.Options.StalePendingSlices, the same budget
  // TScreenStream's start drain uses, and short for the same reason.

var
  GContentResult: SCShareableContent = nil;
  GContentError: NSError = nil;
  GContentReady: Boolean = False;
  GContentQueryActive: Boolean = False;
  // True from the moment getShareableContent… is issued until its
  // completion has finished writing the globals below. A query that times
  // out leaves this set, and the framework may still run that completion
  // much later — see DrainPendingContent.
  GContentPending: Boolean = False;

// The completion block. FPC compiles this global cdecl routine to a
// static block literal with no captured context, so it cannot tell which
// query handed it out; nothing here decides whether an arrival is
// welcome. GContentPending is what does: a query that gave up leaves the
// flag set, and the next one waits it out (DrainPendingContent) and drops
// what this left behind (ClearContentResult) before dispatching its own.
//
// Runs on whichever queue ScreenCaptureKit delivers on, which need not be
// the main thread, so the style is the capture queue's: plain globals, no
// exceptions, no managed-type writes, and only whole-word stores the main
// thread reads back. Both arguments arrive at +0 — the framework's own
// references, valid for the length of this call — and are retained
// because the main thread reads them after this returns; an error may
// arrive with a content object, in which case both are retained and both
// are released by whoever clears up. The pending flag is cleared LAST,
// after the retains and after Ready, so a main thread that sees it clear
// has already seen everything this wrote.
procedure ContentCompletionHandler(AContent: id; AError: id); cdecl;
begin
  GContentResult := SCShareableContent(AContent);
  GContentError := NSError(AError);
  if GContentResult <> nil then
    GContentResult.retain;
  if GContentError <> nil then
    GContentError.retain;
  GContentReady := True;
  GContentPending := False;
end;

// Drops whatever a previous query left behind: the content and the error
// a late completion retained after that query had already raised, and the
// Ready flag that came with them. Called only once the pending flag is
// clear, so nothing can be writing these while they are released.
procedure ClearContentResult;
begin
  if GContentResult <> nil then
  begin
    GContentResult.release;
    GContentResult := nil;
  end;
  if GContentError <> nil then
  begin
    GContentError.release;
    GContentError := nil;
  end;
  GContentReady := False;
end;

// A query that timed out abandoned its completion, but the framework can
// still run it — and a global handler cannot tell which query it belongs
// to, so a late one would otherwise answer whoever asks next, or be
// overwritten by the next query and leak the retains it took. Wait the
// stale one out; refuse the new query rather than proceed on an ambiguous
// flag. The same shape, and the same reasoning, as DrainPendingStart in
// Knips.Capture.Stream.
//
// The wait is bounded at StalePendingSlices run-loop slices — about
// 1.8 s measured, because a 1 ms slice costs nearer 1.7 ms of wall
// clock. The one caller inside AppKit's menu tracking is the Record
// Window submenu (Knips.App, WindowListTimeoutSeconds), so a hover right
// after a timed-out query can spend that before spending its own
// similarly-priced second; that caller catches every exception, so a
// refusal here is the submenu's one flat "window list unavailable" line
// rather than a frozen menu.
function DrainPendingContent: Boolean;
var
  WaitCount: Integer;
begin
  if not GContentPending then
    Exit(True);
  WaitCount := 0;
  while GContentPending and (WaitCount < StalePendingSlices) do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
    Inc(WaitCount);
  end;
  Result := not GContentPending;
end;

function NSStringToPascal(const AString: NSString): string;
begin
  if AString = nil then
    Result := ''
  else
    Result := string(AString.UTF8String);
end;

function PascalToNSString(const AValue: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PAnsiChar(AValue));
end;

function DisplayBackingScale(ADisplayID: UInt32): Integer;
var
  Mode: CGDisplayModeRef;
  PixelWidth: NativeUInt;
  PointWidth: Double;
begin
  Result := 1;
  Mode := CGDisplayCopyDisplayMode(ADisplayID);
  if Mode = nil then
    Exit;
  try
    PixelWidth := CGDisplayModeGetPixelWidth(Mode);
    PointWidth := CGDisplayBounds(ADisplayID).size.width;
    if (PointWidth > 0) and (PixelWidth > 0) then
      Result := Round(PixelWidth / PointWidth);
    if Result < 1 then
      Result := 1;
  finally
    CGDisplayModeRelease(Mode);
  end;
end;

{ TShareableContent }

constructor TShareableContent.Create;
begin
  inherited Create;
  Query(DefaultQueryTimeoutSeconds);
end;

constructor TShareableContent.CreateWithin(ATimeoutSeconds: Double);
begin
  inherited Create;
  Query(ATimeoutSeconds);
end;

procedure TShareableContent.Query(ATimeoutSeconds: Double);
var
  Slices, WaitCount: Integer;
  Message: string;
begin
  // The wait below pumps a nested run loop over these process globals.
  // A second Query entered from inside that pump would clobber the
  // outer one's result and leak its retain; refuse instead. Callers are
  // all main-thread, so a plain flag is enough.
  if GContentQueryActive then
    raise EShareableContent.Create(
      'a shareable-content query is already running');
  GContentQueryActive := True;
  try
    if not DrainPendingContent then
      raise EShareableContent.Create(
        'a previous shareable-content query is still pending; try again in '
        + 'a moment');
    // Nothing is in flight now, so anything still in the globals belongs
    // to a query that gave up: release it before dispatching.
    ClearContentResult;

    GContentPending := True;
    SCShareableContent.getShareableContentExcludingDesktopWindows_onScreenWindowsOnly_completionHandler(
      ObjCBOOL(False), ObjCBOOL(True), ContentCompletionHandler);

    Slices := Round(ATimeoutSeconds / FrameworkSliceSeconds);
    if Slices < 1 then
      Slices := 1;
    WaitCount := 0;
    while (not GContentReady) and (WaitCount < Slices) do
    begin
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
      Inc(WaitCount);
    end;

    if not GContentReady then
    begin
      // Giving up does not cancel the block: it will still run, whole
      // seconds from now, into a process that has moved on.
      // GContentPending is deliberately left set — that is what tells the
      // next query a completion is still in flight, so it waits that out
      // and releases whatever the completion retained instead of reading
      // it as an answer.
      raise EShareableContent.Create(
        'timed out waiting for ScreenCaptureKit; grant Screen Recording in '
        + 'System Settings > Privacy & Security and retry');
    end;
    if GContentError <> nil then
    begin
      Message := NSStringToPascal(GContentError.localizedDescription);
      GContentError.release;
      GContentError := nil;
      // A framework that reports an error may hand over a content
      // object as well, and the handler retained it. Nobody will ever
      // read it — this raises — so it is released here rather than
      // left for the next query to overwrite.
      if GContentResult <> nil then
      begin
        GContentResult.release;
        GContentResult := nil;
      end;
      raise EShareableContent.Create('ScreenCaptureKit: ' + Message);
    end;
    FContent := GContentResult;
    GContentResult := nil;
  finally
    GContentQueryActive := False;
  end;
end;

destructor TShareableContent.Destroy;
begin
  if FContent <> nil then
    FContent.release;
  inherited Destroy;
end;

function TShareableContent.DisplayCount: Integer;
begin
  Result := Integer(FContent.displays.count);
end;

function TShareableContent.DisplayObject(AIndex: Integer): SCDisplay;
begin
  Result := SCDisplay(FContent.displays.objectAtIndex(AIndex));
end;

function TShareableContent.DisplayAt(AIndex: Integer): TDisplayInfo;
var
  Display: SCDisplay;
begin
  Display := DisplayObject(AIndex);
  Result.Index := AIndex;
  Result.DisplayID := Display.displayID;
  Result.Width := Integer(Display.width);
  Result.Height := Integer(Display.height);
  Result.IsMain := Display.displayID = CGMainDisplayID;
end;

function TShareableContent.RetainDisplay(AIndex: Integer): SCDisplay;
var
  I: Integer;
  Candidate: SCDisplay;
begin
  Result := nil;
  if DisplayCount = 0 then
    Exit;
  if AIndex < 0 then
  begin
    for I := 0 to DisplayCount - 1 do
    begin
      Candidate := DisplayObject(I);
      if Candidate.displayID = CGMainDisplayID then
      begin
        Result := Candidate;
        Break;
      end;
    end;
    if Result = nil then
      Result := DisplayObject(0);
  end
  else if AIndex < DisplayCount then
    Result := DisplayObject(AIndex);
  if Result <> nil then
    Result.retain;
end;

function TShareableContent.IndexOfDisplayID(ADisplayID: UInt32): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to DisplayCount - 1 do
    if DisplayObject(I).displayID = ADisplayID then
      Exit(I);
end;

function TShareableContent.WindowCount: Integer;
begin
  Result := Integer(FContent.windows.count);
end;

function TShareableContent.WindowAt(AIndex: Integer): TWindowInfo;
var
  Window: SCWindow;
  Frame: CGRect;
  Application: SCRunningApplication;
begin
  Window := SCWindow(FContent.windows.objectAtIndex(AIndex));
  Frame := Window.frame;
  Result.WindowID := Window.windowID;
  Result.Title := NSStringToPascal(Window.title);
  Application := Window.owningApplication;
  if Application <> nil then
  begin
    Result.ApplicationName := NSStringToPascal(Application.applicationName);
    Result.ProcessID := Application.processID;
  end
  else
  begin
    Result.ApplicationName := '';
    // Not zero: pid 0 is the kernel, and a caller comparing against its
    // own pid must never accidentally match an unknown owner.
    Result.ProcessID := -1;
  end;
  Result.Width := Round(Frame.size.width);
  Result.Height := Round(Frame.size.height);
  Result.OnScreen := Window.isOnScreen;
  Result.Layer := Integer(Window.windowLayer);
end;

function TShareableContent.RetainWindow(AWindowID: UInt32): SCWindow;
var
  I: Integer;
  Candidate: SCWindow;
begin
  Result := nil;
  for I := 0 to WindowCount - 1 do
  begin
    Candidate := SCWindow(FContent.windows.objectAtIndex(I));
    if Candidate.windowID = AWindowID then
    begin
      Result := Candidate;
      Result.retain;
      Exit;
    end;
  end;
end;

{$ENDIF}

end.

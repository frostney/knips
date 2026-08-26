unit Knips.Capture.ShareableContent;

// What the host can capture, as ScreenCaptureKit reports it. The query is
// asynchronous in the framework; this unit pumps the run loop until the
// completion block fires (the prototype's pattern) so callers get a plain
// synchronous object. Creating one triggers the Screen Recording
// permission prompt on first use.

{$I Shared.inc}
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
  public
    // Runs the framework query; raises EShareableContent on timeout or
    // framework error (typically missing Screen Recording permission).
    constructor Create;
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
  RunLoopSliceSeconds = 0.001;

var
  GContentResult: SCShareableContent = nil;
  GContentError: NSError = nil;
  GContentReady: Boolean = False;

procedure ContentCompletionHandler(AContent: id; AError: id); cdecl;
begin
  GContentResult := SCShareableContent(AContent);
  GContentError := NSError(AError);
  if GContentResult <> nil then
    GContentResult.retain;
  if GContentError <> nil then
    GContentError.retain;
  GContentReady := True;
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
var
  WaitCount: Integer;
  Message: string;
begin
  inherited Create;
  GContentResult := nil;
  GContentError := nil;
  GContentReady := False;

  SCShareableContent.getShareableContentExcludingDesktopWindows_onScreenWindowsOnly_completionHandler(
    ObjCBOOL(False), ObjCBOOL(True), ContentCompletionHandler);

  WaitCount := 0;
  while (not GContentReady) and (WaitCount < QueryTimeoutSlices) do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, RunLoopSliceSeconds, False);
    Inc(WaitCount);
  end;

  if not GContentReady then
    raise EShareableContent.Create(
      'timed out waiting for ScreenCaptureKit; grant Screen Recording in '
      + 'System Settings > Privacy & Security and retry');
  if GContentError <> nil then
  begin
    Message := NSStringToPascal(GContentError.localizedDescription);
    GContentError.release;
    GContentError := nil;
    raise EShareableContent.Create('ScreenCaptureKit: ' + Message);
  end;
  FContent := GContentResult;
  GContentResult := nil;
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
    Result.ApplicationName := NSStringToPascal(Application.applicationName)
  else
    Result.ApplicationName := '';
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

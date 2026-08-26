unit Knips.App;

// The menu-bar app: an NSStatusItem, its menu, and the state machine that
// decides what each click means. `knips app` sets the activation policy
// to Accessory (no Dock tile, no main menu) and hands the process to
// NSApp's run loop; everything below happens inside it, on the main
// thread.
//
//   asIdle  --Record Region…-->  asSelecting  --mouse up-->  asRecording
//      |                              |                          |
//      +--------Record Display--------+--Esc/empty drag----------+
//                                                     click/Stop |
//                                                                v
//                                                             asIdle
//
// Legal transitions live in Knips.App.State (platform-neutral, tested);
// this unit only owns the Cocoa objects and the recording session.
//
// The one Objective-C class defined here, KnipsAppTarget, is assembled
// at run time (ADR-0002): AppKit needs a target object for the menu
// items, the status item's button and the elapsed-time timer, and every
// one of its methods is a plain cdecl Pascal routine that recovers the
// controller from an ivar back-pointer — the same shape as the capture
// layer's SCStreamOutput.
//
// Errors never open a dialog. The message goes to NSLog (where a
// menu-bar-only process's output actually lands) and to a disabled
// "Last error: …" menu item, and the app returns to idle without
// retrying — a denied Screen Recording grant must not become a loop.

{$I Shared.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  CocoaAll,
  Knips.App.Border,
  Knips.App.Overlay,
  Knips.App.Playback,
  Knips.App.State,
  Knips.Capture.ShareableContent,
  Knips.ObjC.Runtime,
  Knips.Options,
  Knips.Recording,
  MacOSAll;

// Installs the status item and runs NSApp until the user quits. Returns
// False with a message when the app cannot be set up at all; a failed
// recording is reported through the menu, not through this result.
function RunMenuBarApp(out AError: string): Boolean;

// Registers KnipsAppTarget once per process; exposed so `knips probe`
// can gate on registration without starting the app.
procedure EnsureAppClasses;

function AppTargetClassName: string;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Knips.ObjC.TypeEncoding;

const
  TargetClassName = 'KnipsAppTarget';
  TargetSuperclassName = 'NSObject';
  OwnerIvarName = 'knipsOwner';

  RecordRegionSelector = 'recordRegion:';
  RecordDisplaySelector = 'recordDisplay:';
  RecordWindowSelector = 'recordWindow:';
  RecordLastRegionSelector = 'recordLastRegion:';
  ToggleSystemAudioSelector = 'toggleSystemAudio:';
  StopRecordingSelector = 'stopRecording:';
  CancelSelectionSelector = 'cancelSelection:';
  RevealRecordingsSelector = 'revealRecordings:';
  QuitSelector = 'quitKnips:';
  TimerFiredSelector = 'timerFired:';
  StartPendingSelector = 'startPending:';
  StopPendingSelector = 'stopPending:';
  // KnipsAppTarget doubles as the Record Window submenu's NSMenuDelegate;
  // the list is rebuilt when AppKit is about to show it, so it is never
  // stale and never costs a ScreenCaptureKit query the user did not ask
  // for. A separate delegate class would carry no extra information.
  MenuNeedsUpdateSelector = 'menuNeedsUpdate:';

  RecordRegionTitle = 'Record Region…';
  RecordDisplayTitle = 'Record Display';
  RecordWindowTitle = 'Record Window';
  RecordLastRegionTitle = 'Record Last Region';
  SystemAudioTitle = 'Record System Audio';
  StopRecordingTitle = 'Stop Recording';
  CancelSelectionTitle = 'Cancel selection';
  RevealRecordingsTitle = 'Recordings folder';
  QuitTitle = 'Quit Knips';
  MenuTitle = 'Knips';
  WindowMenuTitle = 'Windows';
  NoWindowsTitle = 'No recordable windows';
  NoWindowListTitle =
    'window list unavailable — check Screen Recording permission';
  IdleToolTip = 'Knips — click for the menu';
  RecordingToolTip = 'Knips — click to stop recording';

  // NSUserDefaults keys. The system-audio checkbox and the last region
  // are the only two things the app remembers between launches.
  SystemAudioKey = 'KnipsRecordSystemAudio';
  LastRegionDisplayKey = 'KnipsLastRegionDisplay';
  LastRegionLeftKey = 'KnipsLastRegionLeft';
  LastRegionTopKey = 'KnipsLastRegionTop';
  LastRegionWidthKey = 'KnipsLastRegionWidth';
  LastRegionHeightKey = 'KnipsLastRegionHeight';

  ElapsedTimerSeconds = 1.0;
  // A zero-delay one-shot: the selection commits inside the overlay
  // view's mouseUp:, and starting ScreenCaptureKit there would pump a
  // nested run loop while AppKit is still dispatching that event. The
  // timer moves the start to the next turn, with the overlay already off
  // screen. Stopping is deferred the same way and for the same reason:
  // finishing the writer pumps the run loop too, and the stop arrives
  // from a status-item action.
  DeferredStartSeconds = 0.0;
  SecondsPerDay = 86400;

  // The Record Window submenu is built inside AppKit's menu tracking,
  // which is the one place in this app that pumps a nested run loop
  // without being a deferred one-shot (see docs/architecture.md,
  // "Deferrals"). Both numbers exist to make that bounded: at most one
  // ScreenCaptureKit query per interval however often the submenu is
  // hovered, and at most a second of waiting when the framework does not
  // answer — a denied Screen Recording grant would otherwise freeze the
  // menu for five seconds on every single hover.
  WindowListTimeoutSeconds = 1.0;
  WindowListCacheSeconds = 5.0;

type
  // One line of the Record Window submenu, cached between hovers so the
  // framework query does not run on every one.
  TWindowMenuEntry = record
    WindowID: Cardinal;
    Title: string;
  end;

  TAppController = class
  private
    FState: TAppState;
    FTarget: id;
    FStatusItem: NSStatusItem;
    FMenu: NSMenu;
    FRegionItem: NSMenuItem;
    FDisplayItem: NSMenuItem;
    FWindowItem: NSMenuItem;
    FWindowMenu: NSMenu;
    FLastRegionItem: NSMenuItem;
    FSystemAudioItem: NSMenuItem;
    FStopItem: NSMenuItem;
    FCancelItem: NSMenuItem;
    FRevealItem: NSMenuItem;
    FErrorItem: NSMenuItem;
    FQuitItem: NSMenuItem;
    FTimer: NSTimer;
    FOverlay: TSelectionOverlay;
    FBorder: TRecordingBorder;
    FPlayback: TPlaybackWindow;
    FSession: TRecordingSession;
    FStartedAt: TDateTime;
    FLastError: string;
    // Own process id, so the Record Window submenu does not offer the
    // playback window as something to record. The application name will
    // not do: ScreenCaptureKit reports a display name, which is 'Knips'
    // under the bundle and 'knips-bin' from the shell.
    FProcessID: Integer;
    // The Record Window submenu's contents and when they were read.
    FWindowEntries: array of TWindowMenuEntry;
    FWindowEntriesAt: TDateTime;
    FWindowEntriesValid: Boolean;
    FWindowListFailed: Boolean;
    // Persisted preferences.
    FSystemAudio: Boolean;
    FHasLastRegion: Boolean;
    FLastRegionDisplayID: UInt32;
    FLastRegion: TCaptureRegion;
    // What StartPending will record. 0 selects the main display.
    FPendingDisplayID: UInt32;
    FPendingHasRegion: Boolean;
    FPendingRegion: TCaptureRegion;
    FPendingWindowID: Cardinal;
    function AddMenuItem(const ATitle, ASelector: string): NSMenuItem;
    procedure BuildMenu;
    procedure BuildWindowMenu;
    procedure AddInertItem(AMenu: NSMenu; const ATitle: string);
    function WindowEntriesFresh: Boolean;
    procedure RefreshWindowEntries;
    function ElapsedSeconds: Int64;
    procedure RecordError(const AMessage: string);
    procedure LoadPreferences;
    procedure StoreSystemAudio;
    procedure StoreLastRegion;
    procedure ClearPending;
    // Puts the frame on the region about to be recorded and returns the
    // window id the capture must exclude. 0 when there is no region or
    // the border could not be shown; the recording then runs without one.
    function ShowBorderForPending: Cardinal;
    procedure HideBorder;
    procedure ShowPlayback(const APath: string; APixelWidth,
      APixelHeight: Integer);
    procedure HandlePlaybackError(const AMessage: string);
    function Transition(ACommand: TAppCommand): Boolean;
    function ResolveDisplayIndex(ADisplayID: UInt32; out AIndex: Integer;
      out AError: string): Boolean;
    function PrepareOutputPath(out APath: string; out AError: string): Boolean;
    procedure ScheduleOneShot(const ASelector: string);
    procedure StartElapsedTimer;
    procedure StopElapsedTimer;
    procedure Reveal(const APath: string);
    // Finalises the file and, unless the app is on its way out, opens it
    // in the playback window. Pumps the run loop, so it is only ever
    // called from a deferred timer or from Quit.
    procedure FinishRecording(AShowPlayback: Boolean);
    // True while the GIF export has the main thread. The export turns
    // the run loop over to draw its progress, so AppKit can dispatch
    // clicks in the middle of it; this is what makes them no-ops.
    function Busy: Boolean;
    procedure HandleRegionSelected(ADisplayID: UInt32;
      const ARegion: TCaptureRegion);
    procedure HandleSelectionCancelled;
    procedure HandleOverlayError(const AMessage: string);
  public
    constructor Create;
    destructor Destroy; override;
    function Setup(out AError: string): Boolean;
    procedure RefreshStatusItem;
    procedure CommandRecordRegion;
    procedure CommandRecordDisplay;
    procedure CommandRecordWindow(AWindowID: Cardinal);
    procedure CommandRecordLastRegion;
    procedure CommandToggleSystemAudio;
    procedure CommandStop;
    procedure CommandCancelSelection;
    procedure CommandRevealRecordings;
    procedure CommandQuit;
    // Playback-window actions; the buttons target this same object.
    procedure CommandExportGif;
    procedure CommandRevealRecording;
    procedure CommandClosePlayback;
    // NSMenuDelegate for the Record Window submenu.
    procedure RebuildWindowMenu;
    procedure Tick;
    procedure StartPending;
    procedure StopPending;
    // Reports a failure the way every other failure is reported and puts
    // the status item back in step.
    procedure Fail(const AMessage: string);
    property Target: id read FTarget;
  end;

var
  GTargetClass: pobjc_class = nil;

function AppTargetClassName: string;
begin
  Result := TargetClassName;
end;

procedure LogMessage(const AMessage: string);
begin
  NSLog(PascalToNSString('knips: %@'), PascalToNSString(AMessage));
end;

{ KnipsAppTarget method bodies. Each recovers the controller from the
  knipsOwner ivar; a nil owner means the app is tearing down.

  Every body is wrapped in try..except. AppKit calls these directly, and a
  Pascal exception escaping into an Objective-C frame has nothing to
  unwind it — a denied Screen Recording grant reaching StartCapture, an
  EObjCRuntime out of EnsureStreamOutputClass, a Format or NSString
  failure while drawing, all end up here. The message goes to the same
  NSLog + "Last error" path as any other failure and the method returns. }

function ControllerOf(ASelf: id): TAppController; inline;
begin
  Result := TAppController(GetPointerIvar(ASelf, OwnerIvarName));
end;

// Reports what a body caught, without letting the reporting itself throw.
procedure HandleBodyException(AController: TAppController;
  const ASelector: string; E: Exception);
begin
  try
    if AController <> nil then
      AController.Fail(ASelector + ': ' + E.Message)
    else
      LogMessage(ASelector + ': ' + E.Message);
  except
    // Nothing left to try; swallowing beats unwinding into AppKit.
  end;
end;

procedure TargetRecordRegion(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandRecordRegion;
  except
    on E: Exception do
      HandleBodyException(Controller, RecordRegionSelector, E);
  end;
end;

procedure TargetRecordDisplay(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandRecordDisplay;
  except
    on E: Exception do
      HandleBodyException(Controller, RecordDisplaySelector, E);
  end;
end;

// The submenu items carry their CGWindowID in the menu item's tag, which
// is the only piece of the sender this body reads.
procedure TargetRecordWindow(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
  WindowID: Cardinal;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller = nil then
      Exit;
    WindowID := 0;
    if ASender <> nil then
      WindowID := Cardinal(NSMenuItem(ASender).tag);
    Controller.CommandRecordWindow(WindowID);
  except
    on E: Exception do
      HandleBodyException(Controller, RecordWindowSelector, E);
  end;
end;

procedure TargetRecordLastRegion(ASelf: id; ACommand: SEL;
  ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandRecordLastRegion;
  except
    on E: Exception do
      HandleBodyException(Controller, RecordLastRegionSelector, E);
  end;
end;

procedure TargetToggleSystemAudio(ASelf: id; ACommand: SEL;
  ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandToggleSystemAudio;
  except
    on E: Exception do
      HandleBodyException(Controller, ToggleSystemAudioSelector, E);
  end;
end;

// NSMenuDelegate. AppKit calls this on the Record Window submenu just
// before showing it, which is the only moment the window list is worth
// asking ScreenCaptureKit for.
procedure TargetMenuNeedsUpdate(ASelf: id; ACommand: SEL; AMenu: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.RebuildWindowMenu;
  except
    on E: Exception do
      HandleBodyException(Controller, MenuNeedsUpdateSelector, E);
  end;
end;

procedure TargetExportGif(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandExportGif;
  except
    on E: Exception do
      HandleBodyException(Controller, ExportGifSelector, E);
  end;
end;

procedure TargetRevealRecording(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandRevealRecording;
  except
    on E: Exception do
      HandleBodyException(Controller, RevealRecordingSelector, E);
  end;
end;

procedure TargetClosePlayback(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandClosePlayback;
  except
    on E: Exception do
      HandleBodyException(Controller, ClosePlaybackSelector, E);
  end;
end;

procedure TargetStopRecording(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandStop;
  except
    on E: Exception do
      HandleBodyException(Controller, StopRecordingSelector, E);
  end;
end;

procedure TargetCancelSelection(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandCancelSelection;
  except
    on E: Exception do
      HandleBodyException(Controller, CancelSelectionSelector, E);
  end;
end;

procedure TargetRevealRecordings(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandRevealRecordings;
  except
    on E: Exception do
      HandleBodyException(Controller, RevealRecordingsSelector, E);
  end;
end;

procedure TargetQuit(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandQuit;
  except
    on E: Exception do
      HandleBodyException(Controller, QuitSelector, E);
  end;
end;

procedure TargetTimerFired(ASelf: id; ACommand: SEL; ATimer: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.Tick;
  except
    on E: Exception do
      HandleBodyException(Controller, TimerFiredSelector, E);
  end;
end;

procedure TargetStartPending(ASelf: id; ACommand: SEL; ATimer: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.StartPending;
  except
    on E: Exception do
      HandleBodyException(Controller, StartPendingSelector, E);
  end;
end;

procedure TargetStopPending(ASelf: id; ACommand: SEL; ATimer: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.StopPending;
  except
    on E: Exception do
      HandleBodyException(Controller, StopPendingSelector, E);
  end;
end;

procedure AddTargetMethod(ABuilder: TRuntimeClassBuilder;
  const ASelector: string; AImplementation: TObjCMethodImplementation);
begin
  if not ABuilder.AddMethod(ASelector, AImplementation,
    MethodTypeEncoding(otVoid, [otObject])) then
    raise EObjCRuntime.Create('class_addMethod failed for ' + ASelector);
end;

procedure EnsureAppClasses;
var
  Builder: TRuntimeClassBuilder;
begin
  EnsureOverlayClasses;
  EnsureBorderClasses;
  EnsurePlaybackClasses;
  if GTargetClass <> nil then
    Exit;
  GTargetClass := LookUpClass(TargetClassName);
  if GTargetClass <> nil then
    Exit;
  Builder := TRuntimeClassBuilder.Create(TargetClassName,
    TargetSuperclassName);
  try
    if not Builder.AddPointerIvar(OwnerIvarName) then
      raise EObjCRuntime.Create('class_addIvar failed for ' + OwnerIvarName);
    AddTargetMethod(Builder, RecordRegionSelector, @TargetRecordRegion);
    AddTargetMethod(Builder, RecordDisplaySelector, @TargetRecordDisplay);
    AddTargetMethod(Builder, RecordWindowSelector, @TargetRecordWindow);
    AddTargetMethod(Builder, RecordLastRegionSelector,
      @TargetRecordLastRegion);
    AddTargetMethod(Builder, ToggleSystemAudioSelector,
      @TargetToggleSystemAudio);
    AddTargetMethod(Builder, MenuNeedsUpdateSelector, @TargetMenuNeedsUpdate);
    AddTargetMethod(Builder, ExportGifSelector, @TargetExportGif);
    AddTargetMethod(Builder, RevealRecordingSelector, @TargetRevealRecording);
    AddTargetMethod(Builder, ClosePlaybackSelector, @TargetClosePlayback);
    AddTargetMethod(Builder, StopRecordingSelector, @TargetStopRecording);
    AddTargetMethod(Builder, CancelSelectionSelector, @TargetCancelSelection);
    AddTargetMethod(Builder, RevealRecordingsSelector,
      @TargetRevealRecordings);
    AddTargetMethod(Builder, QuitSelector, @TargetQuit);
    AddTargetMethod(Builder, TimerFiredSelector, @TargetTimerFired);
    AddTargetMethod(Builder, StartPendingSelector, @TargetStartPending);
    AddTargetMethod(Builder, StopPendingSelector, @TargetStopPending);
    // AppKit only asks respondsToSelector:, so a runtime without the
    // protocol registered is not an error; claiming it is tidier.
    Builder.AddProtocol('NSMenuDelegate');
    GTargetClass := Builder.Register;
  finally
    Builder.Free;
  end;
end;

{ TAppController }

constructor TAppController.Create;
begin
  inherited Create;
  FState := asIdle;
end;

destructor TAppController.Destroy;
begin
  StopElapsedTimer;
  if FTarget <> nil then
    SetPointerIvar(FTarget, OwnerIvarName, nil);
  FreeAndNil(FOverlay);
  FreeAndNil(FBorder);
  FreeAndNil(FPlayback);
  FreeAndNil(FSession);
  if FStatusItem <> nil then
  begin
    NSStatusBar.systemStatusBar.removeStatusItem(FStatusItem);
    FStatusItem.release;
    FStatusItem := nil;
  end;
  if FWindowMenu <> nil then
  begin
    // The target is about to go; a delegate call after that would find a
    // nil owner, but clearing it is cheaper than relying on that.
    FWindowMenu.setDelegate(nil);
    FWindowMenu.release;
    FWindowMenu := nil;
  end;
  if FMenu <> nil then
  begin
    FMenu.release;
    FMenu := nil;
  end;
  if FTarget <> nil then
  begin
    ReleaseInstance(FTarget);
    FTarget := nil;
  end;
  inherited Destroy;
end;

// An empty selector makes an inert item — the "Last error" line, which
// only ever displays.
function TAppController.AddMenuItem(const ATitle,
  ASelector: string): NSMenuItem;
var
  Action: SEL;
begin
  if ASelector = '' then
    Action := nil
  else
    Action := SelectorNamed(ASelector);
  Result := NSMenuItem(NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    PascalToNSString(ATitle), Action, PascalToNSString('')));
  if Action <> nil then
    Result.setTarget(FTarget);
  FMenu.addItem(Result);
  Result.release;
end;

// An inert line — a placeholder in the window submenu, or the "Last
// error" item. Disabled, no action, and not added through AddMenuItem
// because that one always targets the root menu.
procedure TAppController.AddInertItem(AMenu: NSMenu; const ATitle: string);
var
  Item: NSMenuItem;
begin
  Item := NSMenuItem(NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    PascalToNSString(ATitle), nil, PascalToNSString('')));
  Item.setEnabled(False);
  AMenu.addItem(Item);
  Item.release;
end;

// The submenu is created empty and filled by RebuildWindowMenu when
// AppKit is about to show it (menuNeedsUpdate:).
procedure TAppController.BuildWindowMenu;
begin
  FWindowMenu := NSMenu(NSMenu.alloc.initWithTitle(
    PascalToNSString(WindowMenuTitle)));
  FWindowMenu.setAutoenablesItems(False);
  FWindowMenu.setDelegate(NSMenuDelegateProtocol(FTarget));
  AddInertItem(FWindowMenu, NoWindowsTitle);
end;

procedure TAppController.BuildMenu;
begin
  FMenu := NSMenu(NSMenu.alloc.initWithTitle(PascalToNSString(MenuTitle)));
  // The controller decides what is enabled; AppKit's own validation would
  // enable every item whose target answers the selector.
  FMenu.setAutoenablesItems(False);
  FRegionItem := AddMenuItem(RecordRegionTitle, RecordRegionSelector);
  FDisplayItem := AddMenuItem(RecordDisplayTitle, RecordDisplaySelector);
  // A submenu item carries no action of its own; opening it is what the
  // click does, and the items inside carry recordWindow:.
  FWindowItem := AddMenuItem(RecordWindowTitle, '');
  BuildWindowMenu;
  FWindowItem.setSubmenu(FWindowMenu);
  FLastRegionItem := AddMenuItem(RecordLastRegionTitle,
    RecordLastRegionSelector);
  FStopItem := AddMenuItem(StopRecordingTitle, StopRecordingSelector);
  // Only reachable when the overlay failed to come up — a live overlay
  // covers the menu bar, and inside it Esc or a stray click cancel.
  FCancelItem := AddMenuItem(CancelSelectionTitle, CancelSelectionSelector);
  FMenu.addItem(NSMenuItem.separatorItem);
  FSystemAudioItem := AddMenuItem(SystemAudioTitle, ToggleSystemAudioSelector);
  FMenu.addItem(NSMenuItem.separatorItem);
  FRevealItem := AddMenuItem(RevealRecordingsTitle, RevealRecordingsSelector);
  FErrorItem := AddMenuItem(ErrorMenuTitle(''), '');
  FErrorItem.setEnabled(False);
  FErrorItem.setHidden(True);
  FMenu.addItem(NSMenuItem.separatorItem);
  FQuitItem := AddMenuItem(QuitTitle, QuitSelector);
end;

function TAppController.WindowEntriesFresh: Boolean;
var
  Age: Double;
begin
  if not FWindowEntriesValid then
    Exit(False);
  Age := (Now - FWindowEntriesAt) * SecondsPerDay;
  // A clock that moved backwards reads as stale, not as fresh forever.
  Result := (Age >= 0) and (Age < WindowListCacheSeconds);
end;

// The only ScreenCaptureKit query in the app that is not on a deferred
// one-shot. It is bounded twice: WindowListTimeoutSeconds caps how long
// menu tracking can be held up when the framework does not answer, and
// the cache caps how often it happens at all.
procedure TAppController.RefreshWindowEntries;
var
  Content: TShareableContent;
  Info: TWindowInfo;
  I, Added: Integer;
begin
  SetLength(FWindowEntries, 0);
  FWindowEntriesAt := Now;
  FWindowEntriesValid := True;
  FWindowListFailed := False;
  Content := nil;
  try
    // Every exception, not just EShareableContent: this runs inside
    // AppKit's menu tracking, where the app's usual Fail path would
    // rewrite the status item under an open menu.
    try
      Content := TShareableContent.CreateWithin(WindowListTimeoutSeconds);
    except
      on E: Exception do
      begin
        FWindowListFailed := True;
        // The log is the full story; the menu gets one flat line.
        LogMessage('window list: ' + E.Message);
        Exit;
      end;
    end;
    Added := 0;
    for I := 0 to Content.WindowCount - 1 do
    begin
      if Added >= MaxWindowMenuEntries then
        Break;
      Info := Content.WindowAt(I);
      if not IsWindowRecordable(Info.OnScreen, Info.Layer, Info.Width,
        Info.Height, Info.Title, Info.ProcessID = FProcessID) then
        Continue;
      SetLength(FWindowEntries, Added + 1);
      FWindowEntries[Added].WindowID := Info.WindowID;
      FWindowEntries[Added].Title := WindowMenuItemTitle(
        Info.ApplicationName, Info.Title);
      Inc(Added);
    end;
  finally
    Content.Free;
  end;
end;

// Runs from menuNeedsUpdate:, just before AppKit shows the submenu.
// Nothing in here may raise into AppKit, call Fail, or touch the status
// item: the menu is open and being tracked.
procedure TAppController.RebuildWindowMenu;
var
  Item: NSMenuItem;
  I: Integer;
begin
  if FWindowMenu = nil then
    Exit;
  try
    if not WindowEntriesFresh then
      RefreshWindowEntries;
    FWindowMenu.removeAllItems;
    if FWindowListFailed then
    begin
      AddInertItem(FWindowMenu, NoWindowListTitle);
      Exit;
    end;
    if Length(FWindowEntries) = 0 then
    begin
      AddInertItem(FWindowMenu, NoWindowsTitle);
      Exit;
    end;
    for I := 0 to High(FWindowEntries) do
    begin
      Item := NSMenuItem(NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
        PascalToNSString(FWindowEntries[I].Title),
        SelectorNamed(RecordWindowSelector), PascalToNSString('')));
      Item.setTarget(FTarget);
      // The tag is how recordWindow: learns which window was picked;
      // a CGWindowID is 32-bit and an NSInteger is 64, so it fits.
      Item.setTag(NSInteger(FWindowEntries[I].WindowID));
      Item.setEnabled(True);
      FWindowMenu.addItem(Item);
      Item.release;
    end;
  except
    on E: Exception do
    begin
      // Last resort. Reporting through Fail would rewrite the status
      // item's menu while this one is on screen.
      LogMessage('rebuilding the window menu: ' + E.Message);
      try
        FWindowMenu.removeAllItems;
        AddInertItem(FWindowMenu, NoWindowListTitle);
      except
        // Nothing left to try.
      end;
    end;
  end;
end;

function TAppController.Setup(out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  try
    EnsureAppClasses;
  except
    on E: Exception do
    begin
      AError := 'could not register the app classes: ' + E.Message;
      Exit;
    end;
  end;

  FTarget := InstantiateClass(GTargetClass);
  if FTarget = nil then
  begin
    AError := 'could not instantiate ' + TargetClassName;
    Exit;
  end;
  SetPointerIvar(FTarget, OwnerIvarName, Self);

  FProcessID := NSProcessInfo.processInfo.processIdentifier;
  LoadPreferences;

  FStatusItem := NSStatusBar.systemStatusBar.statusItemWithLength(
    NSVariableStatusItemLength);
  if FStatusItem = nil then
  begin
    AError := 'the system status bar refused a status item';
    Exit;
  end;
  // statusItemWithLength: hands back an autoreleased item.
  FStatusItem.retain;

  BuildMenu;

  FOverlay := TSelectionOverlay.Create;
  FOverlay.OnSelected := HandleRegionSelected;
  FOverlay.OnCancelled := HandleSelectionCancelled;
  FOverlay.OnError := HandleOverlayError;

  FBorder := TRecordingBorder.Create;
  FBorder.OnError := HandleOverlayError;

  RefreshStatusItem;
  Result := True;
end;

{ Preferences. Two settings, both plain scalars, both written straight
  through — NSUserDefaults flushes on its own schedule and the app has
  nothing to lose if a crash beats it to disk. }

procedure TAppController.LoadPreferences;
var
  Defaults: NSUserDefaults;
  Stored: TCaptureRegion;
begin
  Defaults := NSUserDefaults.standardUserDefaults;
  FSystemAudio := Defaults.boolForKey(PascalToNSString(SystemAudioKey));
  FLastRegionDisplayID := UInt32(Defaults.integerForKey(
    PascalToNSString(LastRegionDisplayKey)));
  Stored.Left := Integer(Defaults.integerForKey(
    PascalToNSString(LastRegionLeftKey)));
  Stored.Top := Integer(Defaults.integerForKey(
    PascalToNSString(LastRegionTopKey)));
  Stored.Width := Integer(Defaults.integerForKey(
    PascalToNSString(LastRegionWidthKey)));
  Stored.Height := Integer(Defaults.integerForKey(
    PascalToNSString(LastRegionHeightKey)));
  // `defaults write` is a public interface and these keys are not this
  // app's private business; whatever is under them has to be treated as
  // input, not as something we wrote. A negative origin would otherwise
  // reach ScreenCaptureKit's sourceRect unexamined.
  FHasLastRegion := SanitizeStoredRegion(Stored, FLastRegion);
  // A region without the display it was drawn on is unusable. Whether
  // that display is still attached is settled at StartPending, which
  // resolves it against ScreenCaptureKit like any other recording.
  if FLastRegionDisplayID = 0 then
  begin
    FHasLastRegion := False;
    FLastRegion := Default(TCaptureRegion);
  end;
end;

procedure TAppController.StoreSystemAudio;
begin
  NSUserDefaults.standardUserDefaults.setBool_forKey(ObjCBOOL(FSystemAudio),
    PascalToNSString(SystemAudioKey));
end;

procedure TAppController.StoreLastRegion;
var
  Defaults: NSUserDefaults;
begin
  Defaults := NSUserDefaults.standardUserDefaults;
  Defaults.setInteger_forKey(NSInteger(FLastRegionDisplayID),
    PascalToNSString(LastRegionDisplayKey));
  Defaults.setInteger_forKey(FLastRegion.Left,
    PascalToNSString(LastRegionLeftKey));
  Defaults.setInteger_forKey(FLastRegion.Top,
    PascalToNSString(LastRegionTopKey));
  Defaults.setInteger_forKey(FLastRegion.Width,
    PascalToNSString(LastRegionWidthKey));
  Defaults.setInteger_forKey(FLastRegion.Height,
    PascalToNSString(LastRegionHeightKey));
end;

procedure TAppController.ClearPending;
begin
  FPendingDisplayID := 0;
  FPendingHasRegion := False;
  FPendingRegion := Default(TCaptureRegion);
  FPendingWindowID := 0;
end;

function TAppController.ShowBorderForPending: Cardinal;
begin
  Result := 0;
  if (FBorder = nil) or not FPendingHasRegion or (FPendingDisplayID = 0) then
    Exit;
  // A border that will not come up is not worth failing a recording over;
  // the recording simply runs without one.
  if not FBorder.Show(FPendingDisplayID, FPendingRegion) then
    Exit;
  Result := FBorder.WindowID;
end;

procedure TAppController.HideBorder;
begin
  if (FBorder <> nil) and FBorder.Visible then
    FBorder.Hide;
end;

procedure TAppController.ShowPlayback(const APath: string; APixelWidth,
  APixelHeight: Integer);
begin
  if FPlayback = nil then
  begin
    FPlayback := TPlaybackWindow.Create;
    FPlayback.OnError := HandlePlaybackError;
  end;
  // One window per recording: Show closes whatever was open first, so a
  // second clip replaces the first rather than stacking players that all
  // hold their files open.
  if not FPlayback.Show(FTarget, APath, APixelWidth, APixelHeight) then
    // Falling back to the old behaviour is better than a finished
    // recording that never says so.
    Reveal(APath);
end;

procedure TAppController.HandlePlaybackError(const AMessage: string);
begin
  RecordError(AMessage);
  RefreshStatusItem;
end;

function TAppController.ElapsedSeconds: Int64;
begin
  if FState <> asRecording then
    Exit(0);
  Result := Trunc((Now - FStartedAt) * SecondsPerDay);
  if Result < 0 then
    Result := 0;
end;

procedure TAppController.RefreshStatusItem;
var
  Button: NSStatusBarButton;
begin
  if FStatusItem = nil then
    Exit;
  Button := FStatusItem.button;
  if Button <> nil then
    Button.setTitle(PascalToNSString(StatusItemTitle(FState,
      ElapsedSeconds)));

  FRegionItem.setEnabled(IsCommandEnabled(FState, acRecordRegion));
  FDisplayItem.setEnabled(IsCommandEnabled(FState, acRecordDisplay));
  FWindowItem.setEnabled(IsCommandEnabled(FState, acRecordWindow));
  // The table says when the command could be legal; the region on file
  // says whether there is anything to repeat.
  FLastRegionItem.setEnabled(FHasLastRegion
    and IsCommandEnabled(FState, acRecordLastRegion));
  FSystemAudioItem.setEnabled(IsCommandEnabled(FState, acToggleSystemAudio));
  if FSystemAudio then
    FSystemAudioItem.setState(NSOnState)
  else
    FSystemAudioItem.setState(NSOffState);
  FStopItem.setEnabled(IsCommandEnabled(FState, acStopRecording));
  FCancelItem.setEnabled(IsCommandEnabled(FState, acCancelSelection));

  if FLastError <> '' then
  begin
    FErrorItem.setTitle(PascalToNSString(ErrorMenuTitle(FLastError)));
    FErrorItem.setHidden(False);
  end
  else
    FErrorItem.setHidden(True);

  // While recording the status item has no menu, so a single click stops
  // — the Kap gesture. Idle, the click opens the menu.
  if FState = asRecording then
  begin
    FStatusItem.setMenu(nil);
    if Button <> nil then
    begin
      Button.setTarget(FTarget);
      Button.setAction(SelectorNamed(StopRecordingSelector));
      Button.setToolTip(PascalToNSString(RecordingToolTip));
    end;
  end
  else
  begin
    if Button <> nil then
    begin
      Button.setTarget(nil);
      Button.setAction(nil);
      Button.setToolTip(PascalToNSString(IdleToolTip));
    end;
    FStatusItem.setMenu(FMenu);
  end;
end;

procedure TAppController.RecordError(const AMessage: string);
begin
  FLastError := AMessage;
  LogMessage(AMessage);
end;

procedure TAppController.Fail(const AMessage: string);
begin
  RecordError(AMessage);
  // Whatever raised left the state machine mid-move; anything but idle
  // would have no way back, since the failing command is the one the
  // user just tried.
  Transition(acCaptureFailed);
  // A frame left on screen with no recording behind it is a lie about
  // what the app is doing.
  HideBorder;
  RefreshStatusItem;
end;

procedure TAppController.HandleOverlayError(const AMessage: string);
begin
  RecordError(AMessage);
  RefreshStatusItem;
end;

function TAppController.Busy: Boolean;
begin
  Result := (FPlayback <> nil) and FPlayback.Exporting;
end;

function TAppController.Transition(ACommand: TAppCommand): Boolean;
var
  Next: TAppState;
begin
  // The single global lockout. The GIF export owns the main thread but
  // turns the run loop over once per whole percent so its progress can
  // actually be drawn, and that hands AppKit the chance to dispatch a
  // menu click into a controller that is halfway through something. No
  // command is legal until the export gives the thread back.
  if Busy then
    Exit(False);
  Result := NextAppState(FState, ACommand, Next);
  if Result then
    FState := Next;
end;

function TAppController.ResolveDisplayIndex(ADisplayID: UInt32;
  out AIndex: Integer; out AError: string): Boolean;
var
  Content: TShareableContent;
begin
  Result := False;
  AIndex := -1;
  AError := '';
  try
    Content := TShareableContent.Create;
  except
    on E: EShareableContent do
    begin
      AError := E.Message;
      Exit;
    end;
  end;
  try
    AIndex := Content.IndexOfDisplayID(ADisplayID);
    if AIndex < 0 then
    begin
      AError := Format('display %u is not capturable', [ADisplayID]);
      Exit;
    end;
  finally
    Content.Free;
  end;
  Result := True;
end;

function TAppController.PrepareOutputPath(out APath: string;
  out AError: string): Boolean;
var
  Directory: string;
begin
  APath := '';
  AError := '';
  Directory := RecordingsDirectory(GetUserDir);
  Result := ForceDirectories(Directory);
  if not Result then
  begin
    AError := 'could not create ' + Directory;
    Exit;
  end;
  APath := Directory + RecordingFileName(Now);
end;

procedure TAppController.ScheduleOneShot(const ASelector: string);
begin
  NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
    DeferredStartSeconds, FTarget, SelectorNamed(ASelector), nil, False);
end;

procedure TAppController.StartElapsedTimer;
begin
  StopElapsedTimer;
  FTimer := NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
    ElapsedTimerSeconds, FTarget, SelectorNamed(TimerFiredSelector), nil,
    True);
  if FTimer <> nil then
    FTimer.retain;
end;

procedure TAppController.StopElapsedTimer;
begin
  if FTimer = nil then
    Exit;
  FTimer.invalidate;
  FTimer.release;
  FTimer := nil;
end;

procedure TAppController.Reveal(const APath: string);
begin
  NSWorkspace.sharedWorkspace.selectFile_inFileViewerRootedAtPath(
    PascalToNSString(APath), PascalToNSString(''));
end;

procedure TAppController.CommandRecordRegion;
var
  Shown: Boolean;
begin
  if not Transition(acRecordRegion) then
    Exit;
  FLastError := '';
  // The window id of a previous Record Window would otherwise still be
  // sitting there when the drag commits, and StartPending would record
  // that window instead of the rectangle just drawn.
  ClearPending;
  Shown := False;
  try
    Shown := FOverlay.Show;
    if not Shown then
      RecordError('the selection overlay could not open a window on any '
        + 'screen');
  except
    on E: Exception do
      RecordError('could not open the selection overlay: ' + E.Message);
  end;
  // Staying in asSelecting without an overlay would leave every command
  // disabled and nothing on screen to press Esc in.
  if not Shown then
    Transition(acCaptureFailed);
  RefreshStatusItem;
end;

procedure TAppController.CommandRecordDisplay;
begin
  if not Transition(acRecordDisplay) then
    Exit;
  FLastError := '';
  ClearPending;
  RefreshStatusItem;
  ScheduleOneShot(StartPendingSelector);
end;

procedure TAppController.CommandRecordWindow(AWindowID: Cardinal);
begin
  if AWindowID = 0 then
    Exit;
  if not Transition(acRecordWindow) then
    Exit;
  FLastError := '';
  ClearPending;
  FPendingWindowID := AWindowID;
  RefreshStatusItem;
  ScheduleOneShot(StartPendingSelector);
end;

procedure TAppController.CommandRecordLastRegion;
begin
  if not FHasLastRegion then
    Exit;
  if not Transition(acRecordLastRegion) then
    Exit;
  FLastError := '';
  ClearPending;
  FPendingDisplayID := FLastRegionDisplayID;
  FPendingHasRegion := True;
  FPendingRegion := FLastRegion;
  RefreshStatusItem;
  ScheduleOneShot(StartPendingSelector);
end;

procedure TAppController.CommandToggleSystemAudio;
begin
  // The stream configuration is fixed once a capture has started, so the
  // checkbox is a no-op anywhere but idle — the table says so, and this
  // makes a stray click on a disabled item a no-op too.
  if not Transition(acToggleSystemAudio) then
    Exit;
  FSystemAudio := not FSystemAudio;
  StoreSystemAudio;
  RefreshStatusItem;
end;

procedure TAppController.CommandExportGif;
begin
  if FPlayback <> nil then
    FPlayback.CommandExportGif;
end;

procedure TAppController.CommandRevealRecording;
begin
  if FPlayback <> nil then
    FPlayback.CommandReveal;
end;

procedure TAppController.CommandClosePlayback;
begin
  if FPlayback <> nil then
    FPlayback.CommandClose;
end;

procedure TAppController.CommandCancelSelection;
begin
  if not Transition(acCancelSelection) then
    Exit;
  if (FOverlay <> nil) and FOverlay.Visible then
    FOverlay.Hide;
  RefreshStatusItem;
end;

// Runs inside the overlay view's mouseUp:, so it only records the request;
// resolving the display asks ScreenCaptureKit, which pumps the run loop,
// and that has no business happening mid-event.
procedure TAppController.HandleRegionSelected(ADisplayID: UInt32;
  const ARegion: TCaptureRegion);
begin
  ClearPending;
  FPendingDisplayID := ADisplayID;
  FPendingHasRegion := True;
  FPendingRegion := ARegion;
  if not Transition(acSelectionCommitted) then
    Exit;
  RefreshStatusItem;
  ScheduleOneShot(StartPendingSelector);
end;

procedure TAppController.HandleSelectionCancelled;
begin
  Transition(acSelectionCancelled);
  RefreshStatusItem;
end;

// Runs one turn after the command that asked for a recording.
procedure TAppController.StartPending;
var
  Options: TRecordingOptions;
  Error: string;
  DisplayIndex: Integer;
  BorderWindowID: Cardinal;
begin
  if FState <> asRecording then
    Exit;
  DisplayIndex := -1;
  // A region is meaningless without the display it was drawn on: the
  // NSScreen had no NSScreenNumber, so falling back to the main display
  // would record a rectangle from a different screen's coordinates.
  if FPendingHasRegion and (FPendingDisplayID = 0) then
  begin
    Transition(acCaptureFailed);
    RecordError('could not identify the display the region was drawn on');
    RefreshStatusItem;
    Exit;
  end;
  if (FPendingDisplayID <> 0)
    and not ResolveDisplayIndex(FPendingDisplayID, DisplayIndex, Error) then
  begin
    Transition(acCaptureFailed);
    RecordError(Error);
    RefreshStatusItem;
    Exit;
  end;
  Options := DefaultRecordingOptions;
  Options.DisplayIndex := DisplayIndex;
  Options.HasRegion := FPendingHasRegion;
  Options.Region := FPendingRegion;
  if FPendingWindowID <> 0 then
  begin
    Options.TargetKind := ctkWindow;
    Options.WindowID := FPendingWindowID;
  end;
  if FSystemAudio then
    Options.AudioMode := amSystem;
  // The border has to exist before the content filter is built: its
  // window id is what StartCapture hands to
  // initWithDisplay:excludingWindows:. The frame is stroked outside the
  // region either way, so a failed exclusion still cannot reach the file.
  BorderWindowID := ShowBorderForPending;
  if BorderWindowID <> 0 then
  begin
    SetLength(Options.ExcludedWindowIDs, 1);
    Options.ExcludedWindowIDs[0] := BorderWindowID;
  end;
  if not PrepareOutputPath(Options.OutputPath, Error) then
  begin
    HideBorder;
    Transition(acCaptureFailed);
    RecordError(Error);
    RefreshStatusItem;
    Exit;
  end;
  if not ValidateRecordingOptions(Options, Error) then
  begin
    HideBorder;
    Transition(acCaptureFailed);
    RecordError(Error);
    RefreshStatusItem;
    Exit;
  end;

  FreeAndNil(FSession);
  FSession := TRecordingSession.Create(Options);
  if not FSession.StartCapture(Error) then
  begin
    HideBorder;
    FreeAndNil(FSession);
    Transition(acCaptureFailed);
    // One shot: a denied Screen Recording grant fails the same way every
    // time, so the app goes back to idle and waits for the user.
    RecordError(Error);
    RefreshStatusItem;
    Exit;
  end;

  // The frame is drawn outside the recorded rectangle either way, so a
  // window ScreenCaptureKit did not resolve is not a failure — but it is
  // the first thing worth knowing if a border ever does turn up in a
  // file, and silence would make that unfindable.
  if Length(Options.ExcludedWindowIDs) > FSession.Report.ExcludedWindows then
    LogMessage(Format('the recording border was not excluded from the '
      + 'capture (%d of %d windows resolved); the frame is drawn outside '
      + 'the recorded region, so the file is unaffected',
      [FSession.Report.ExcludedWindows, Length(Options.ExcludedWindowIDs)]));

  // Only once the capture is really running, so a repeat of a region that
  // no longer resolves does not become the region to repeat.
  if FPendingHasRegion and (FPendingDisplayID <> 0) then
  begin
    FLastRegionDisplayID := FPendingDisplayID;
    FLastRegion := FPendingRegion;
    FHasLastRegion := IsSelectionUsable(FLastRegion);
    if FHasLastRegion then
      StoreLastRegion;
  end;

  FStartedAt := Now;
  StartElapsedTimer;
  RefreshStatusItem;
end;

// The click that stops arrives as a status-item action. Leave the
// recording state immediately so a second click is a no-op, then hand the
// finalisation — which pumps the run loop for the writer's completion
// handler — to the next turn, exactly as StartPending does for the start.
procedure TAppController.CommandStop;
begin
  if FState <> asRecording then
    Exit;
  StopElapsedTimer;
  Transition(acStopRecording);
  RefreshStatusItem;
  ScheduleOneShot(StopPendingSelector);
end;

procedure TAppController.StopPending;
begin
  // A nil session means the stop beat the deferred start; StartPending
  // saw the idle state and did nothing. Nothing to finish, nothing to
  // report.
  if FSession <> nil then
    FinishRecording(True);
end;

procedure TAppController.FinishRecording(AShowPlayback: Boolean);
var
  Error, Path: string;
  Finished: Boolean;
  PixelWidth, PixelHeight: Integer;
begin
  if FSession = nil then
    Exit;
  // The frame goes first: it belongs to the recording, not to the
  // finalisation, and finishing the writer pumps the run loop.
  HideBorder;
  Path := FSession.Report.OutputPath;
  PixelWidth := FSession.Report.PixelWidth;
  PixelHeight := FSession.Report.PixelHeight;
  Finished := FSession.FinishCapture(Error);
  if not Finished then
    RecordError(Error);
  FreeAndNil(FSession);
  RefreshStatusItem;
  // Playing the clip back is the "done" signal, and the window is where
  // the GIF export lives; a window that cannot be made falls back to
  // revealing the file in Finder. On the way out there is no signal to
  // give: Quit finalises the file and terminates, and a window (or a
  // Finder window) flashing up on the last turn before terminate: is
  // noise, not information.
  if AShowPlayback and Finished and (Path <> '') then
    ShowPlayback(Path, PixelWidth, PixelHeight);
end;

procedure TAppController.CommandRevealRecordings;
var
  Directory: string;
begin
  Directory := RecordingsDirectory(GetUserDir);
  if not ForceDirectories(Directory) then
  begin
    RecordError('could not create ' + Directory);
    RefreshStatusItem;
    Exit;
  end;
  NSWorkspace.sharedWorkspace.openURL(NSURL.fileURLWithPath(
    PascalToNSString(Directory)));
end;

procedure TAppController.CommandQuit;
begin
  // An export has the main thread and is only reachable here because it
  // turns the run loop over to draw its progress. Tearing the process
  // down underneath it would leave a half-written GIF; the user gets a
  // reason and can quit again when it is done.
  if Busy then
  begin
    RecordError('a GIF export is running; quit once it has finished');
    RefreshStatusItem;
    Exit;
  end;
  if FState = asRecording then
  begin
    StopElapsedTimer;
    Transition(acStopRecording);
  end;
  // Quit cannot defer: terminate: does not come back, so an unfinished
  // writer would leave an unplayable file. Any session still open is
  // finalised here, deferred start or not — silently: no playback
  // window, no Finder, nothing that outlives the process by a frame.
  if FSession <> nil then
    FinishRecording(False);
  HideBorder;
  if (FOverlay <> nil) and FOverlay.Visible then
    FOverlay.Hide;
  if FPlayback <> nil then
    FPlayback.CommandClose;
  NSApplication.sharedApplication.terminate(nil);
end;

procedure TAppController.Tick;
begin
  RefreshStatusItem;
end;

function RunMenuBarApp(out AError: string): Boolean;
var
  Pool: NSAutoreleasePool;
  Controller: TAppController;
  Application: NSApplication;
begin
  Result := False;
  AError := '';
  Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
  try
    Application := NSApplication.sharedApplication;
    // Accessory: a menu-bar-only process — no Dock tile, no main menu,
    // and windows can still become key (the overlay needs that).
    Application.setActivationPolicy(NSApplicationActivationPolicyAccessory);
    // A status item created before the app has finished launching gets a
    // window the menu bar never adopts (height 0, never visible — seen
    // on device). finishLaunching first; run tolerates the early call.
    Application.finishLaunching;
    Controller := TAppController.Create;
    try
      if not Controller.Setup(AError) then
        Exit;
      // Returns only when the app is stopped; Quit calls terminate:,
      // which does not return at all.
      Application.run;
      Result := True;
    finally
      Controller.Free;
    end;
  finally
    Pool.release;
  end;
end;

{$ENDIF}

end.

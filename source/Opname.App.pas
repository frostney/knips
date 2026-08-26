unit Opname.App;

// The menu-bar app: an NSStatusItem, its menu, and the state machine that
// decides what each click means. `opname app` sets the activation policy
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
// Legal transitions live in Opname.App.State (platform-neutral, tested);
// this unit only owns the Cocoa objects and the recording session.
//
// The one Objective-C class defined here, OpnameAppTarget, is assembled
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
  MacOSAll,
  Opname.App.Overlay,
  Opname.App.State,
  Opname.Capture.ShareableContent,
  Opname.ObjC.Runtime,
  Opname.Options,
  Opname.Recording;

// Installs the status item and runs NSApp until the user quits. Returns
// False with a message when the app cannot be set up at all; a failed
// recording is reported through the menu, not through this result.
function RunMenuBarApp(out AError: string): Boolean;

// Registers OpnameAppTarget once per process; exposed so `opname probe`
// can gate on registration without starting the app.
procedure EnsureAppClasses;

function AppTargetClassName: string;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Opname.ObjC.TypeEncoding;

const
  TargetClassName = 'OpnameAppTarget';
  TargetSuperclassName = 'NSObject';
  OwnerIvarName = 'opnameOwner';

  RecordRegionSelector = 'recordRegion:';
  RecordDisplaySelector = 'recordDisplay:';
  StopRecordingSelector = 'stopRecording:';
  CancelSelectionSelector = 'cancelSelection:';
  RevealRecordingsSelector = 'revealRecordings:';
  QuitSelector = 'quitOpname:';
  TimerFiredSelector = 'timerFired:';
  StartPendingSelector = 'startPending:';
  StopPendingSelector = 'stopPending:';

  RecordRegionTitle = 'Record Region…';
  RecordDisplayTitle = 'Record Display';
  StopRecordingTitle = 'Stop Recording';
  CancelSelectionTitle = 'Cancel selection';
  RevealRecordingsTitle = 'Recordings folder';
  QuitTitle = 'Quit opname';
  MenuTitle = 'opname';
  IdleToolTip = 'opname — click for the menu';
  RecordingToolTip = 'opname — click to stop recording';

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

type
  TAppController = class
  private
    FState: TAppState;
    FTarget: id;
    FStatusItem: NSStatusItem;
    FMenu: NSMenu;
    FRegionItem: NSMenuItem;
    FDisplayItem: NSMenuItem;
    FStopItem: NSMenuItem;
    FCancelItem: NSMenuItem;
    FRevealItem: NSMenuItem;
    FErrorItem: NSMenuItem;
    FQuitItem: NSMenuItem;
    FTimer: NSTimer;
    FOverlay: TSelectionOverlay;
    FSession: TRecordingSession;
    FStartedAt: TDateTime;
    FLastError: string;
    // What StartPending will record. 0 selects the main display.
    FPendingDisplayID: UInt32;
    FPendingHasRegion: Boolean;
    FPendingRegion: TCaptureRegion;
    function AddMenuItem(const ATitle, ASelector: string): NSMenuItem;
    procedure BuildMenu;
    function ElapsedSeconds: Int64;
    procedure RecordError(const AMessage: string);
    function Transition(ACommand: TAppCommand): Boolean;
    function ResolveDisplayIndex(ADisplayID: UInt32; out AIndex: Integer;
      out AError: string): Boolean;
    function PrepareOutputPath(out APath: string; out AError: string): Boolean;
    procedure ScheduleOneShot(const ASelector: string);
    procedure StartElapsedTimer;
    procedure StopElapsedTimer;
    procedure Reveal(const APath: string);
    // Finalises the file and reveals it. Pumps the run loop, so it is
    // only ever called from a deferred timer or from Quit.
    procedure FinishRecording;
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
    procedure CommandStop;
    procedure CommandCancelSelection;
    procedure CommandRevealRecordings;
    procedure CommandQuit;
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
  NSLog(PascalToNSString('opname: %@'), PascalToNSString(AMessage));
end;

{ OpnameAppTarget method bodies. Each recovers the controller from the
  opnameOwner ivar; a nil owner means the app is tearing down.

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
    AddTargetMethod(Builder, StopRecordingSelector, @TargetStopRecording);
    AddTargetMethod(Builder, CancelSelectionSelector, @TargetCancelSelection);
    AddTargetMethod(Builder, RevealRecordingsSelector,
      @TargetRevealRecordings);
    AddTargetMethod(Builder, QuitSelector, @TargetQuit);
    AddTargetMethod(Builder, TimerFiredSelector, @TargetTimerFired);
    AddTargetMethod(Builder, StartPendingSelector, @TargetStartPending);
    AddTargetMethod(Builder, StopPendingSelector, @TargetStopPending);
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
  FreeAndNil(FSession);
  if FStatusItem <> nil then
  begin
    NSStatusBar.systemStatusBar.removeStatusItem(FStatusItem);
    FStatusItem.release;
    FStatusItem := nil;
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

procedure TAppController.BuildMenu;
begin
  FMenu := NSMenu(NSMenu.alloc.initWithTitle(PascalToNSString(MenuTitle)));
  // The controller decides what is enabled; AppKit's own validation would
  // enable every item whose target answers the selector.
  FMenu.setAutoenablesItems(False);
  FRegionItem := AddMenuItem(RecordRegionTitle, RecordRegionSelector);
  FDisplayItem := AddMenuItem(RecordDisplayTitle, RecordDisplaySelector);
  FStopItem := AddMenuItem(StopRecordingTitle, StopRecordingSelector);
  // Only reachable when the overlay failed to come up — a live overlay
  // covers the menu bar, and inside it Esc or a stray click cancel.
  FCancelItem := AddMenuItem(CancelSelectionTitle, CancelSelectionSelector);
  FMenu.addItem(NSMenuItem.separatorItem);
  FRevealItem := AddMenuItem(RevealRecordingsTitle, RevealRecordingsSelector);
  FErrorItem := AddMenuItem(ErrorMenuTitle(''), '');
  FErrorItem.setEnabled(False);
  FErrorItem.setHidden(True);
  FMenu.addItem(NSMenuItem.separatorItem);
  FQuitItem := AddMenuItem(QuitTitle, QuitSelector);
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

  RefreshStatusItem;
  Result := True;
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
  RefreshStatusItem;
end;

procedure TAppController.HandleOverlayError(const AMessage: string);
begin
  RecordError(AMessage);
  RefreshStatusItem;
end;

function TAppController.Transition(ACommand: TAppCommand): Boolean;
var
  Next: TAppState;
begin
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
  FPendingDisplayID := 0;
  FPendingHasRegion := False;
  FPendingRegion := Default(TCaptureRegion);
  RefreshStatusItem;
  ScheduleOneShot(StartPendingSelector);
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
  if not PrepareOutputPath(Options.OutputPath, Error) then
  begin
    Transition(acCaptureFailed);
    RecordError(Error);
    RefreshStatusItem;
    Exit;
  end;
  if not ValidateRecordingOptions(Options, Error) then
  begin
    Transition(acCaptureFailed);
    RecordError(Error);
    RefreshStatusItem;
    Exit;
  end;

  FreeAndNil(FSession);
  FSession := TRecordingSession.Create(Options);
  if not FSession.StartCapture(Error) then
  begin
    FreeAndNil(FSession);
    Transition(acCaptureFailed);
    // One shot: a denied Screen Recording grant fails the same way every
    // time, so the app goes back to idle and waits for the user.
    RecordError(Error);
    RefreshStatusItem;
    Exit;
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
    FinishRecording;
end;

procedure TAppController.FinishRecording;
var
  Error, Path: string;
  Finished: Boolean;
begin
  if FSession = nil then
    Exit;
  Path := FSession.Report.OutputPath;
  Finished := FSession.FinishCapture(Error);
  if not Finished then
    RecordError(Error);
  FreeAndNil(FSession);
  RefreshStatusItem;
  // Revealing the file in Finder is the "done" signal; no notification
  // permission, no extra framework.
  if Finished and (Path <> '') then
    Reveal(Path);
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
  if FState = asRecording then
  begin
    StopElapsedTimer;
    Transition(acStopRecording);
  end;
  // Quit cannot defer: terminate: does not come back, so an unfinished
  // writer would leave an unplayable file. Any session still open is
  // finalised here, deferred start or not.
  if FSession <> nil then
    FinishRecording;
  if (FOverlay <> nil) and FOverlay.Visible then
    FOverlay.Hide;
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

unit Knips.App;

// The menu-bar app: an NSStatusItem, its menu, and the state machine that
// decides what each click means. `knips app` sets the activation policy
// to Accessory (no Dock tile, no main menu) and hands the process to
// NSApp's run loop; everything below happens inside it, on the main
// thread. The one departure from Accessory is the playback window, which
// promotes the process to Regular for as long as it is open — see
// PromoteForPlayback.
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
  Knips.App.Live,
  Knips.App.Overlay,
  Knips.App.Playback,
  Knips.App.State,
  Knips.Capture.ShareableContent,
  Knips.ObjC.Runtime,
  Knips.Options,
  Knips.Recording,
  Knips.Recording.LiveMath,
  MacOSAll;

// Installs the status item and runs NSApp until the user quits. Returns
// False with a message when the app cannot be set up at all; a failed
// recording is reported through the menu, not through this result.
function RunMenuBarApp(out AError: string): Boolean;

// Registers KnipsAppTarget once per process; exposed so `knips probe`
// can gate on registration without starting the app.
procedure EnsureAppClasses;

function AppTargetClassName: string;

// True when this process can reach the window server. Nothing that
// touches NSApplication may be called without it — AppKit aborts rather
// than failing — so `knips probe` and `knips app` both ask first.
function HasWindowServer: Boolean;

// `knips probe`'s gate for the Dock promotion the playback window
// performs: builds the main menu, switches the process to the Regular
// policy, reads the policy back, switches it to Accessory and reads it
// back again, and restores the policy the process started with. ADetail
// is one line for the probe to print. False with a reason when a step did
// not take, which is the failure worth catching — setActivationPolicy:
// returns a BOOL and AppKit is free to decline. Requires
// HasWindowServer.
function CheckDockPromotion(out ADetail: string;
  out AError: string): Boolean;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Knips.ObjC.TypeEncoding;

type
  // autosaveName is on NSStatusItem since 10.12; FPC 3.2.2's CocoaAll
  // predates it. External category: a binding, not a class of ours
  // (ADR-0002 allows exactly this). Setting the name makes AppKit apply
  // the position saved under "NSStatusItem Preferred Position <name>".
  KnipsStatusItemAutosave = objccategory external (NSStatusItem)
    procedure SetAutosaveName(AName: NSString);
      message 'setAutosaveName:';
  end;

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
  ToggleCameraSelector = 'toggleCamera:';
  ToggleCameraShapeSelector = 'toggleCameraShape:';
  RestoreCameraSelector = 'restoreCamera:';
  ToggleZoomOnClickSelector = 'toggleZoomOnClick:';
  ToggleFollowMouseSelector = 'toggleFollowMouse:';
  // The live animator's 30 Hz tick while a recording with Zoom on Click
  // or Follow Mouse is running. On the same target as everything else, so
  // the feature adds no runtime-built class of its own.
  LiveTickSelector = 'liveTick:';
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

  // The main menu, which only a Regular app shows. macOS takes the first
  // item's submenu as the application menu and titles it with the running
  // application's name, so MainAppMenuTitle is never actually drawn; the
  // Dock tile and the switcher take the same name (CFBundleName under
  // Knips.app, the executable's name from the shell).
  MainMenuTitle = 'MainMenu';
  MainAppMenuTitle = 'Knips';
  AboutTitle = 'About Knips';
  // Implemented by NSApplication, so it is reached through the responder
  // chain with no target of ours — the item is left untargeted.
  AboutSelector = 'orderFrontStandardAboutPanel:';
  MainWindowMenuTitle = 'Window';
  CloseWindowTitle = 'Close';
  CloseWindowSelector = 'performClose:';
  MinimizeWindowTitle = 'Minimize';
  MinimizeWindowSelector = 'performMiniaturize:';
  // Cmd is a menu item's default modifier, so none of the three sets a
  // keyEquivalentModifierMask (measured: 1 << 20, NSCommandKeyMask).
  QuitKeyEquivalent = 'q';
  CloseWindowKeyEquivalent = 'w';
  MinimizeWindowKeyEquivalent = 'm';

  // The status item's autosave name, and the AppKit-owned defaults key
  // derived from it. AppKit stores the item's distance from the RIGHT
  // edge of the menu bar under that key and honours it on creation; on a
  // notched Mac with a full menu bar a brand-new item is otherwise
  // placed around the centre — behind the notch, invisible, with no
  // indicator (measured on device, repeatedly). Seeding the position
  // once, only when the key is absent, makes the first launch land among
  // the visible icons; after that the key belongs to AppKit and to the
  // user's own Cmd-drags.
  StatusItemAutosaveName = 'knips';
  StatusItemPositionKey = 'NSStatusItem Preferred Position '
    + StatusItemAutosaveName;
  StatusItemSeedFromRight = 280.0;

  // NSUserDefaults keys. The system-audio checkbox and the last region
  // are the only two things the app remembers between launches.
  SystemAudioKey = 'KnipsRecordSystemAudio';
  ZoomOnClickKey = ZoomOnClickDefaultsKey;
  FollowMouseKey = FollowMouseDefaultsKey;
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
    FZoomOnClickItem: NSMenuItem;
    FFollowMouseItem: NSMenuItem;
    FStopItem: NSMenuItem;
    FCancelItem: NSMenuItem;
    FRevealItem: NSMenuItem;
    FCameraItem: NSMenuItem;
    FCameraShapeItem: NSMenuItem;
    FErrorItem: NSMenuItem;
    FQuitItem: NSMenuItem;
    // The menu bar the process shows while it is a Regular app. Built on
    // the first promotion and kept — see PromoteForPlayback.
    FMainMenu: NSMenu;
    FTimer: NSTimer;
    // The live effects' own timer, only alive while a recording that has
    // one is running. Separate from FTimer, which ticks once a second to
    // rewrite the status item and would be a strange place to hang a
    // thirty-hertz animation.
    FLiveTimer: NSTimer;
    FLive: TLiveAnimator;
    FOverlay: TSelectionOverlay;
    FCamera: TCameraPreview;
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
    FZoomOnClick: Boolean;
    FFollowMouse: Boolean;
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
    procedure StoreLiveEffects;
    procedure StoreLastRegion;
    procedure ClearPending;
    // Starts the live animator and its timer for the recording that has
    // just begun, if either effect applies to it. ABorderExcluded says
    // whether the frame around the region really did reach the content
    // filter — Follow Mouse is refused when it did not, because a frame
    // that pans with the region would then be composited into the file.
    procedure StartLive(ABorderWindowID: Cardinal; ABorderExcluded: Boolean);
    procedure StopLive;
    // Puts the frame on the region about to be recorded and returns the
    // window id the capture must exclude. 0 when there is no region or
    // the border could not be shown; the recording then runs without one.
    function ShowBorderForPending: Cardinal;
    procedure HideBorder;
    // Moves a visible camera window into the corner of the region about
    // to be recorded, so the picture-in-picture is composited into the
    // file the way Kap does it. Nothing happens for a display or window
    // recording, or when the camera is off. UndockCamera puts it back and
    // is safe on every stop path, docked or not.
    procedure DockCameraForPending;
    procedure UndockCamera;
    procedure ShowPlayback(const APath: string; APixelWidth,
      APixelHeight, AScale: Integer);
    procedure HandlePlaybackError(const AMessage: string);
    // The playback window is the only thing in this app that puts the
    // process in the Dock; these two are the whole of it.
    procedure PromoteForPlayback;
    procedure HandlePlaybackClosed;
    procedure ClosePlaybackForRecording;
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
    procedure HandleCameraError(const AMessage: string);
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
    procedure CommandToggleZoomOnClick;
    procedure CommandToggleFollowMouse;
    procedure CommandStop;
    procedure CommandCancelSelection;
    procedure CommandRevealRecordings;
    procedure CommandToggleCamera;
    procedure CommandToggleCameraShape;
    // The launch-time restore, one run-loop turn after Setup, so the
    // status item is in the menu bar before the camera warms up.
    procedure CommandRestoreCamera;
    procedure CommandQuit;
    // Playback-window actions; the buttons target this same object.
    procedure CommandExportGif;
    procedure CommandRevealRecording;
    procedure CommandClosePlayback;
    // NSMenuDelegate for the Record Window submenu.
    procedure RebuildWindowMenu;
    procedure Tick;
    // One turn of the live animator; the 30 Hz timer's target.
    procedure LiveTick;
    procedure StartPending;
    procedure StopPending;
    // Reports a failure the way every other failure is reported and puts
    // the status item back in step.
    procedure Fail(const AMessage: string);
    // What a throwing live tick does instead of Fail: the animator stops
    // and the recording keeps running with a fixed frame. A zoom is not
    // worth a lost file.
    procedure StopLiveAfterFailure(const AMessage: string);
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

// Whether a window id was among the ones a recording asked to exclude.
// Spelled out rather than assumed from the array's shape, because the
// list has one entry today and the assumption would rot silently.
function WindowIDRequested(const AIDs: array of Cardinal;
  AWindowID: Cardinal): Boolean;
var
  I: Integer;
begin
  for I := Low(AIDs) to High(AIDs) do
    if AIDs[I] = AWindowID then
      Exit(True);
  Result := False;
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

procedure TargetToggleZoomOnClick(ASelf: id; ACommand: SEL;
  ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandToggleZoomOnClick;
  except
    on E: Exception do
      HandleBodyException(Controller, ToggleZoomOnClickSelector, E);
  end;
end;

procedure TargetToggleFollowMouse(ASelf: id; ACommand: SEL;
  ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandToggleFollowMouse;
  except
    on E: Exception do
      HandleBodyException(Controller, ToggleFollowMouseSelector, E);
  end;
end;

// Thirty times a second while a live recording runs. Deliberately NOT on
// the Fail path: a live effect that throws must not knock the recording
// to idle and lose the file. The animator is stopped instead, and the
// recording carries on with a fixed frame.
procedure TargetLiveTick(ASelf: id; ACommand: SEL; ATimer: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.LiveTick;
  except
    on E: Exception do
      try
        if Controller <> nil then
        begin
          Controller.StopLiveAfterFailure(LiveTickSelector + ': '
            + E.Message);
        end
        else
          LogMessage(LiveTickSelector + ': ' + E.Message);
      except
        // Nothing left to try; swallowing beats unwinding into AppKit.
      end;
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

// The camera is passive UI: it never touches the recorder, so a failure
// inside its two bodies is reported but must NOT drive the state machine
// the way HandleBodyException does. Knocking a live recording to idle
// because a preview layer refused to come up would lose the file.
procedure HandleCameraBodyException(AController: TAppController;
  const ASelector: string; E: Exception);
begin
  try
    if AController <> nil then
      AController.HandleCameraError(ASelector + ': ' + E.Message)
    else
      LogMessage(ASelector + ': ' + E.Message);
  except
    // Nothing left to try; swallowing beats unwinding into AppKit.
  end;
end;

procedure TargetToggleCamera(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandToggleCamera;
  except
    on E: Exception do
      HandleCameraBodyException(Controller, ToggleCameraSelector, E);
  end;
end;

procedure TargetToggleCameraShape(ASelf: id; ACommand: SEL;
  ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandToggleCameraShape;
  except
    on E: Exception do
      HandleCameraBodyException(Controller, ToggleCameraShapeSelector, E);
  end;
end;

procedure TargetRestoreCamera(ASelf: id; ACommand: SEL; ATimer: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandRestoreCamera;
  except
    on E: Exception do
      HandleCameraBodyException(Controller, RestoreCameraSelector, E);
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
  // Registered here rather than lazily on the first Show, so `knips
  // probe` — which calls this — fails on a bad class_addMethod instead of
  // the user finding out from a camera window that will not drag.
  EnsureCameraClasses;
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
    AddTargetMethod(Builder, ToggleZoomOnClickSelector,
      @TargetToggleZoomOnClick);
    AddTargetMethod(Builder, ToggleFollowMouseSelector,
      @TargetToggleFollowMouse);
    AddTargetMethod(Builder, LiveTickSelector, @TargetLiveTick);
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
    AddTargetMethod(Builder, ToggleCameraSelector, @TargetToggleCamera);
    AddTargetMethod(Builder, ToggleCameraShapeSelector,
      @TargetToggleCameraShape);
    AddTargetMethod(Builder, RestoreCameraSelector, @TargetRestoreCamera);
    // AppKit only asks respondsToSelector:, so a runtime without the
    // protocol registered is not an error; claiming it is tidier.
    Builder.AddProtocol('NSMenuDelegate');
    GTargetClass := Builder.Register;
  finally
    Builder.Free;
  end;
end;

{ The menu bar of a Regular app, and the policy switch that makes the
  process one. `knips app` is an Accessory process — no Dock tile, no
  menu bar — for everything it does with the screen: the status item, the
  selection overlay, the recording frame, the camera window. The playback
  window is the exception. It is an ordinary titled window and a user is
  entitled to treat it as one: find it in the Dock, ⌘-Tab to it, close it
  with ⌘W. That needs the Regular policy, and the Regular policy needs a
  main menu, because a Regular app with none shows an empty menu bar. }

procedure AddSubmenu(AMenu, ASubmenu: NSMenu; const ATitle: string);
var
  Item: NSMenuItem;
begin
  // A submenu hangs off an item that carries no action of its own — the
  // same shape as the Record Window item in the status menu.
  Item := NSMenuItem(NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    PascalToNSString(ATitle), nil, PascalToNSString('')));
  Item.setSubmenu(ASubmenu);
  AMenu.addItem(Item);
  Item.release;
end;

// Two menus, five items, and only one of them is ours. Quit is targeted at
// KnipsAppTarget's quitKnips: — the very selector the status item's own
// Quit uses — so ⌘Q inherits the export lockout and the finalisation of an
// open recording instead of becoming a second, unguarded way out. The
// other three are left untargeted on purpose: AppKit sends an untargeted
// action down the responder chain, which is what puts performClose: and
// performMiniaturize: on whichever window is key and
// orderFrontStandardAboutPanel: on NSApp. A new NSMenu autoenables its
// items — unlike the status menu, which switches that off because the
// controller decides what is legal — and that is exactly what is wanted
// here: the two Window items grey themselves out when no window can
// answer them.
//
// There is deliberately no Edit menu (nothing here takes text) and no
// setWindowsMenu: (AppKit would then keep a window list in it, and the
// windows this app has besides the playback one are a borderless overlay,
// a frame and a camera preview, none of which belong in a menu).
function BuildMainMenu(ATarget: id): NSMenu;
var
  AppMenu, WindowMenu: NSMenu;
  QuitItem: NSMenuItem;
begin
  Result := NSMenu(NSMenu.alloc.initWithTitle(
    PascalToNSString(MainMenuTitle)));

  AppMenu := NSMenu(NSMenu.alloc.initWithTitle(
    PascalToNSString(MainAppMenuTitle)));
  AppMenu.addItemWithTitle_action_keyEquivalent(PascalToNSString(AboutTitle),
    SelectorNamed(AboutSelector), PascalToNSString(''));
  AppMenu.addItem(NSMenuItem.separatorItem);
  QuitItem := AppMenu.addItemWithTitle_action_keyEquivalent(
    PascalToNSString(QuitTitle), SelectorNamed(QuitSelector),
    PascalToNSString(QuitKeyEquivalent));
  if QuitItem <> nil then
    QuitItem.setTarget(ATarget);
  AddSubmenu(Result, AppMenu, MainAppMenuTitle);
  AppMenu.release;

  WindowMenu := NSMenu(NSMenu.alloc.initWithTitle(
    PascalToNSString(MainWindowMenuTitle)));
  WindowMenu.addItemWithTitle_action_keyEquivalent(
    PascalToNSString(CloseWindowTitle), SelectorNamed(CloseWindowSelector),
    PascalToNSString(CloseWindowKeyEquivalent));
  WindowMenu.addItemWithTitle_action_keyEquivalent(
    PascalToNSString(MinimizeWindowTitle),
    SelectorNamed(MinimizeWindowSelector),
    PascalToNSString(MinimizeWindowKeyEquivalent));
  AddSubmenu(Result, WindowMenu, MainWindowMenuTitle);
  WindowMenu.release;
end;

function InRegularPolicy: Boolean;
begin
  Result := NSApplication.sharedApplication.activationPolicy
    = NSApplicationActivationPolicyRegular;
end;

// The menu goes in first and the policy second, so the menu bar the system
// adopts on the switch is already populated rather than briefly empty.
//
// AActivate is the nudge a policy switch made mid-run needs. Promoting
// changes what the process *is*; it does not put it in front, and a Dock
// tile whose menu bar only turns up after the user clicks away and back is
// worse than no promotion. This is a complete operation on purpose — a
// caller should not have to know that. `knips probe` is the one caller
// that passes False: it has no run loop and no window, so activating would
// mean nothing except taking focus off the terminal.
//
// Measured on device, this order followed by the window's own
// makeKeyAndOrderFront:: `lsappinfo` reports the process as Foreground and
// as the front application while the window is up, and back to UIElement
// once it closes.
procedure EnterRegularPolicy(AMainMenu: NSMenu; AActivate: Boolean);
var
  App: NSApplication;
begin
  App := NSApplication.sharedApplication;
  if AMainMenu <> nil then
    App.setMainMenu(AMainMenu);
  if InRegularPolicy then
    Exit;
  App.setActivationPolicy(NSApplicationActivationPolicyRegular);
  if AActivate then
    App.activateIgnoringOtherApps(True);
end;

// The main menu is left in place. Nothing draws it under the Accessory
// policy, and clearing it would mean handing AppKit nil from inside the
// windowWillClose: that a ⌘Q or ⌘W out of that very menu just dispatched.
// The cost is that the two key equivalents stay live between playback
// windows, and both are already safe: ⌘W needs a window that can close,
// and ⌘Q is the same guarded quitKnips: the status item offers.
procedure LeaveRegularPolicy;
begin
  if not InRegularPolicy then
    Exit;
  NSApplication.sharedApplication.setActivationPolicy(
    NSApplicationActivationPolicyAccessory);
end;

function HasWindowServer: Boolean;
var
  Session: CFDictionaryRef;
begin
  // Everything below NSApplication.sharedApplication needs a connection to
  // the window server, and without one AppKit does not fail — it kills the
  // process ("FAILED TO establish the default connection to the
  // WindowServer"). Over SSH, from launchd, or in a build container there
  // is none. CGSessionCopyCurrentDictionary answers NULL outside a
  // graphical login session, which is the documented way to ask before
  // touching AppKit at all.
  Session := CGSessionCopyCurrentDictionary;
  Result := Session <> nil;
  if Result then
    CFRelease(Session);
end;

function CheckDockPromotion(out ADetail: string;
  out AError: string): Boolean;
var
  Target: id;
  Menu: NSMenu;
  AppItems, WindowItems: Integer;
  EntryPolicy: NSInteger;
begin
  Result := False;
  ADetail := '';
  AError := '';
  EnsureAppClasses;
  Target := InstantiateClass(GTargetClass);
  if Target = nil then
  begin
    AError := 'could not instantiate ' + TargetClassName;
    Exit;
  end;
  // Whatever the process was before this ran is what it goes back to, on
  // every path out. Not "Accessory": a bare CLI binary starts Prohibited,
  // and a check has no business converting the process it is checking.
  EntryPolicy := NSApplication.sharedApplication.activationPolicy;
  Menu := nil;
  try
    Menu := BuildMainMenu(Target);
    if Menu.numberOfItems <> 2 then
    begin
      AError := Format('the main menu has %d top-level menus, expected 2',
        [Menu.numberOfItems]);
      Exit;
    end;
    AppItems := Menu.itemAtIndex(0).submenu.numberOfItems;
    WindowItems := Menu.itemAtIndex(1).submenu.numberOfItems;
    if (AppItems <> 3) or (WindowItems <> 2) then
    begin
      AError := Format('the main menu has %d application items and %d '
        + 'window items, expected 3 and 2', [AppItems, WindowItems]);
      Exit;
    end;
    // The round trip in this very process. setActivationPolicy: answers a
    // BOOL, but what matters is what the policy reads back as.
    EnterRegularPolicy(Menu, False);
    if not InRegularPolicy then
    begin
      AError := 'the process did not take the Regular activation policy';
      Exit;
    end;
    if NSApplication.sharedApplication.mainMenu = nil then
    begin
      AError := 'the main menu was not installed';
      Exit;
    end;
    LeaveRegularPolicy;
    if InRegularPolicy then
    begin
      AError := 'the process did not go back to the Accessory policy';
      Exit;
    end;
    ADetail := Format('regular and accessory both taken, entry policy %d '
      + 'restored; main menu %s(%d), %s(%d)', [EntryPolicy, MainAppMenuTitle,
      AppItems, MainWindowMenuTitle, WindowItems]);
    Result := True;
  finally
    // Order matters. The menu holds an item whose target is the
    // KnipsAppTarget released two lines down, so NSApp has to let go of
    // the menu first or it is left holding one that points at freed
    // memory. Then the policy, so a failure on any branch above still
    // leaves the process as it was found rather than stranded Regular.
    NSApplication.sharedApplication.setMainMenu(nil);
    NSApplication.sharedApplication.setActivationPolicy(EntryPolicy);
    if Menu <> nil then
      Menu.release;
    ReleaseInstance(Target);
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
  StopLive;
  if FTarget <> nil then
    SetPointerIvar(FTarget, OwnerIvarName, nil);
  FreeAndNil(FLive);
  FreeAndNil(FOverlay);
  FreeAndNil(FCamera);
  FreeAndNil(FBorder);
  // Freeing the window closes it, which fires OnClosed; putting the
  // process back to Accessory from inside the controller's own destructor
  // would be reaching into an object that is half gone, for a process that
  // is leaving anyway.
  if FPlayback <> nil then
    FPlayback.OnClosed := nil;
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
  if FMainMenu <> nil then
  begin
    // NSApp retained it in setMainMenu:; this only balances the alloc.
    FMainMenu.release;
    FMainMenu := nil;
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
  // Legal in every state on purpose: the camera window is passive — it is
  // captured by ScreenCaptureKit like any other window and touches
  // nothing the recorder owns — and mid-recording is exactly when the
  // user is most likely to want it on or off.
  FCameraItem := AddMenuItem(CameraMenuTitle, ToggleCameraSelector);
  // Legal in every state for the same reason the toggle above is: the
  // shape is a property of a passive window, and switching it mid-take
  // changes nothing the recorder owns.
  FCameraShapeItem := AddMenuItem(CircularCameraMenuTitle,
    ToggleCameraShapeSelector);
  // The two live effects sit with the other recording settings and are
  // idle-only for the same reason the audio checkbox is: what the stream
  // is configured to capture is fixed when the capture starts.
  FZoomOnClickItem := AddMenuItem(ZoomOnClickMenuTitle,
    ToggleZoomOnClickSelector);
  FFollowMouseItem := AddMenuItem(FollowMouseMenuTitle,
    ToggleFollowMouseSelector);
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
  // Mid-export the event drain can deliver this too; the shareable
  // content query pumps a nested run loop on process globals, which is
  // exactly what must not re-enter while an export owns the thread.
  if Busy then
  begin
    FWindowMenu.removeAllItems;
    AddInertItem(FWindowMenu, NoWindowsTitle);
    Exit;
  end;
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

  // Seed the item's position once, before AppKit reads it: without a
  // saved position a new item lands near the middle of a full menu bar,
  // which on a notched display means behind the notch. Only when the
  // key is absent — a position the user has dragged to is theirs.
  if NSUserDefaults.standardUserDefaults.objectForKey(
    NSSTR(StatusItemPositionKey)) = nil then
    NSUserDefaults.standardUserDefaults.setDouble_forKey(
      StatusItemSeedFromRight, NSSTR(StatusItemPositionKey));

  FStatusItem := NSStatusBar.systemStatusBar.statusItemWithLength(
    NSVariableStatusItemLength);
  if FStatusItem = nil then
  begin
    AError := 'the system status bar refused a status item';
    Exit;
  end;
  // statusItemWithLength: hands back an autoreleased item.
  FStatusItem.retain;
  FStatusItem.setAutosaveName(NSSTR(StatusItemAutosaveName));

  BuildMenu;

  FOverlay := TSelectionOverlay.Create;
  FOverlay.OnSelected := HandleRegionSelected;
  FOverlay.OnCancelled := HandleSelectionCancelled;
  FOverlay.OnError := HandleOverlayError;

  FCamera := TCameraPreview.Create;
  FCamera.OnError := HandleCameraError;
  FBorder := TRecordingBorder.Create;
  FBorder.OnError := HandleOverlayError;

  RefreshStatusItem;
  // Deferred, not inline: starting an AVCaptureSession blocks for the
  // better part of a second, and the status item should be in the menu
  // bar before that happens.
  if TCameraPreview.ShouldRestore then
    ScheduleOneShot(RestoreCameraSelector);
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
  // Both default to False, which is what boolForKey: answers for a key
  // that has never been written — no registerDefaults: needed.
  FZoomOnClick := Defaults.boolForKey(PascalToNSString(ZoomOnClickKey));
  FFollowMouse := Defaults.boolForKey(PascalToNSString(FollowMouseKey));
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

procedure TAppController.StoreLiveEffects;
var
  Defaults: NSUserDefaults;
begin
  Defaults := NSUserDefaults.standardUserDefaults;
  Defaults.setBool_forKey(ObjCBOOL(FZoomOnClick),
    PascalToNSString(ZoomOnClickKey));
  Defaults.setBool_forKey(ObjCBOOL(FFollowMouse),
    PascalToNSString(FollowMouseKey));
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

{ Docking the camera into the region being recorded. Kap composes the
  picture-in-picture into the file; Knips does no compositing at all (see
  the header of Knips.App.Camera), so the equivalent is to *put the
  window inside the rectangle* and let ScreenCaptureKit find it there.

  Region recordings only. A display recording already contains the camera
  wherever it stands, and a window recording captures one window and would
  not contain it whatever we did — moving it there would be theatre.

  Once, at the start. A Follow Mouse recording pans its region across the
  display and the camera deliberately does not follow: a
  picture-in-picture that slides around by itself mid-take is worse than
  one that ends up outside a rectangle the user is steering. }

procedure TAppController.DockCameraForPending;
var
  ScreenFrame: NSRect;
begin
  if (FCamera = nil) or not FCamera.Visible then
    Exit;
  if not FPendingHasRegion or (FPendingDisplayID = 0) then
    Exit;
  // The same NSScreen lookup the border does, and the same flip: a
  // capture region is top-left display points, an NSWindow frame is
  // global bottom-left ones.
  if not ScreenFrameForDisplayID(FPendingDisplayID, ScreenFrame) then
    Exit;
  FCamera.DockTo(RegionScreenRect(FPendingRegion,
    CameraRect(ScreenFrame.origin.x, ScreenFrame.origin.y,
    ScreenFrame.size.width, ScreenFrame.size.height)));
end;

procedure TAppController.UndockCamera;
begin
  if FCamera <> nil then
    FCamera.Undock;
end;

procedure TAppController.ShowPlayback(const APath: string; APixelWidth,
  APixelHeight, AScale: Integer);
var
  Shown: Boolean;
begin
  if FPlayback = nil then
  begin
    FPlayback := TPlaybackWindow.Create;
    FPlayback.OnError := HandlePlaybackError;
    FPlayback.OnClosed := HandlePlaybackClosed;
  end;
  // A stop click that arrived while a GIF export owned the main thread
  // can reach this far: the Busy lockout refuses the transition, but the
  // deferred one-shot it queued still fires, and the export's own run-loop
  // slices are where it fires. Taking the window down under a running
  // export is what CommandClose already refuses; building a second one —
  // and switching the activation policy around it — is worse. The
  // recording is finished and on disk either way, so say so the way a
  // window that could not be made says it.
  if FPlayback.Exporting then
  begin
    Reveal(APath);
    Exit;
  end;
  // One window per recording, and the old one goes *here* rather than
  // inside Show: its teardown fires OnClosed, which demotes the process,
  // and a demotion landing after the promotion below would leave the new
  // window's Dock tile behind.
  FPlayback.CommandClose;
  // Before Show, not after. Show activates the app and makes the window
  // key, and the policy has to be Regular by then for the menu bar to
  // come with it.
  PromoteForPlayback;
  Shown := False;
  try
    Shown := FPlayback.Show(FTarget, APath, APixelWidth, APixelHeight,
      AScale);
  finally
    // False *or* a raise — Show can throw EObjCRuntime out of
    // EnsurePlaybackClasses — and either way there is no window. A
    // process left Regular with nothing on screen is the worst of both:
    // a Dock tile that does nothing, a menu bar whose Close is dead, and
    // no windowWillClose: ever coming to put it right, because there was
    // never a window to close.
    if not Shown then
      HandlePlaybackClosed;
  end;
  // Falling back to the old behaviour is better than a finished recording
  // that never says so.
  if not Shown then
    Reveal(APath);
end;

procedure TAppController.HandlePlaybackError(const AMessage: string);
begin
  RecordError(AMessage);
  RefreshStatusItem;
end;

// A Regular process has a Dock tile, a place in ⌘-Tab, and a menu bar; an
// Accessory one has none of the three. Knips is Accessory for everything
// it does with the screen — a recorder that owned the Dock and the menu
// bar while it recorded would be recording itself — and Regular for
// exactly as long as the playback window is up, because that window is an
// ordinary document window and users look for those in the Dock.
//
// The main menu is built once and kept, rather than rebuilt per
// promotion: it holds no state, and AppKit is happier keeping a menu than
// being handed a new one under a live menu bar.
procedure TAppController.PromoteForPlayback;
begin
  if FMainMenu = nil then
    FMainMenu := BuildMainMenu(FTarget);
  EnterRegularPolicy(FMainMenu, True);
end;

// Every way the window can go — the Close button, the titlebar, ⌘W, a new
// recording replacing it, Quit — ends in the window's windowWillClose:,
// and so here.
procedure TAppController.HandlePlaybackClosed;
begin
  LeaveRegularPolicy;
end;


// Every Record command calls this before it starts anything. A recording
// with the playback window still up would capture the app's own Dock tile
// and menu bar — the app would be recording itself, which is the whole
// reason the process is Accessory in the first place — and for a display
// or region capture the window itself would be in the frame.
//
// The close is synchronous all the way down, which is what makes it safe
// to do here: TPlaybackWindow.CommandClose uses -close, which posts
// windowWillClose: on the spot rather than deferring it, so
// HandleWindowWillClose, OnClosed, HandlePlaybackClosed and the switch
// back to Accessory have all run by the time this returns. That is one
// full run-loop turn before startPending: builds the content filter, so
// the window is gone and the Dock is back down before ScreenCaptureKit is
// asked what to capture.
//
// An export cannot be running here: Transition refuses every command
// while Busy, and each caller checks it before getting this far.
procedure TAppController.ClosePlaybackForRecording;
begin
  if (FPlayback <> nil) and FPlayback.Visible then
    FPlayback.CommandClose;
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
  CameraVisible: Boolean;
  CameraShape: TCameraShape;
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
  FZoomOnClickItem.setEnabled(IsCommandEnabled(FState, acToggleZoomOnClick));
  FZoomOnClickItem.setState(MenuCheckState(FZoomOnClick));
  FFollowMouseItem.setEnabled(IsCommandEnabled(FState, acToggleFollowMouse));
  FFollowMouseItem.setState(MenuCheckState(FFollowMouse));
  FStopItem.setEnabled(IsCommandEnabled(FState, acStopRecording));
  FCancelItem.setEnabled(IsCommandEnabled(FState, acCancelSelection));

  // Not part of the state machine — see BuildMenu. The title is constant;
  // the checkmark is what says whether the window is up.
  CameraVisible := (FCamera <> nil) and FCamera.Visible;
  FCameraItem.setState(CameraMenuState(CameraVisible));
  // Both items are read the same way, off a nil-tolerant local: a camera
  // that does not exist yet is not visible and is the default shape.
  if FCamera <> nil then
    CameraShape := FCamera.Shape
  else
    CameraShape := csRectangle;
  FCameraShapeItem.setState(CameraShapeMenuState(CameraShape));

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
    // Not while a GIF export owns the main thread. CommandExportGif
    // detaches the menu on purpose: opening an NSMenu starts a tracking
    // loop inside sendEvent that does not return until the menu is
    // dismissed, and the export drains events, so an attached menu stalls
    // it indefinitely. Every path that refreshes mid-export has to leave
    // it detached — ⌘Q's refusal, a camera error, the elapsed timer — and
    // the reattach is CommandExportGif's own, one line after the export
    // returns and Busy has gone false.
    if Busy then
      FStatusItem.setMenu(nil)
    else
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
  // The animator holds a session that may be on its way out; it must not
  // outlive the recording it was animating.
  StopLive;
  // A frame left on screen with no recording behind it is a lie about
  // what the app is doing.
  HideBorder;
  // And so is a camera window parked in the corner of a region nothing
  // is recording any more.
  UndockCamera;
  RefreshStatusItem;
end;

procedure TAppController.HandleOverlayError(const AMessage: string);
begin
  RecordError(AMessage);
  RefreshStatusItem;
end;

// Deliberately not Fail: the camera has no bearing on whether a recording
// can continue, so a refused grant becomes a "Last error" line and
// nothing else.
procedure TAppController.HandleCameraError(const AMessage: string);
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
  // Before the overlay, not just before the capture: the selection dims
  // every screen, and the playback window has no business sitting under
  // the rectangle the user is about to draw.
  ClosePlaybackForRecording;
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
  ClosePlaybackForRecording;
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
  ClosePlaybackForRecording;
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
  ClosePlaybackForRecording;
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

// Both toggles are idle-only for the same reason as the audio checkbox:
// the effects move the stream's sourceRect, and whether the stream has
// one at all is decided when the capture starts.
procedure TAppController.CommandToggleZoomOnClick;
begin
  if not Transition(acToggleZoomOnClick) then
    Exit;
  FZoomOnClick := not FZoomOnClick;
  StoreLiveEffects;
  RefreshStatusItem;
end;

procedure TAppController.CommandToggleFollowMouse;
begin
  if not Transition(acToggleFollowMouse) then
    Exit;
  FFollowMouse := not FFollowMouse;
  StoreLiveEffects;
  RefreshStatusItem;
end;

procedure TAppController.CommandExportGif;
begin
  if FPlayback = nil then
    Exit;
  // A click on the status item opens NSMenu's tracking loop inside
  // sendEvent, which does not return until the menu is dismissed — and
  // the export drains events, so that would stall it indefinitely.
  // Detach the menu for the duration; a click on the bare item then
  // dispatches nothing at all.
  if FStatusItem <> nil then
    FStatusItem.setMenu(nil);
  try
    FPlayback.CommandExportGif;
  finally
    // Reattaches the menu for the current state.
    RefreshStatusItem;
  end;
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

{ The live effects. Everything that decides *what* they do is in
  Knips.Recording.LiveMath (neutral, tested); everything that decides
  *whether* they run is here, because it needs the recording that just
  started. }

procedure TAppController.StartLive(ABorderWindowID: Cardinal;
  ABorderExcluded: Boolean);
var
  Zoom, Follow: Boolean;
  TargetKind: TCaptureTargetKind;
  DisplayID: UInt32;
  ScreenFrame: NSRect;
  Base: CGRect;
  Border: TRecordingBorder;
begin
  StopLive;
  if FSession = nil then
    Exit;
  // The same reading of the pending request StartPending made a moment
  // ago, from the same fields.
  if FPendingWindowID <> 0 then
    TargetKind := ctkWindow
  else
    TargetKind := ctkDisplay;
  if not ResolveLiveEffects(TargetKind, FPendingHasRegion, FZoomOnClick,
    FFollowMouse, Zoom, Follow) then
    Exit;
  if not FSession.SupportsLiveUpdate then
  begin
    LogMessage('this ScreenCaptureKit has no updateConfiguration:, so Zoom '
      + 'on Click and Follow Mouse are off for this recording');
    Exit;
  end;

  // A pan moves the recorded rectangle across the screen, and the frame
  // has to move with it. Rule 1 in Knips.App.Border — the stroke lies
  // outside the recorded rectangle — cannot hold at every instant while
  // both are moving, because the window server and ScreenCaptureKit
  // apply their changes on their own schedules. Rule 2, the exclusion,
  // can and does; but only if it actually took. Without it, refuse the
  // pan rather than record a frame that keeps sliding into shot.
  Border := nil;
  if ABorderWindowID <> 0 then
  begin
    if ABorderExcluded then
      Border := FBorder
    else if Follow then
    begin
      Follow := False;
      LogMessage('Follow Mouse is off for this recording: the frame around '
        + 'the region was not excluded from the capture, and a region that '
        + 'moves would record its own border');
    end;
  end;
  if not Zoom and not Follow then
    Exit;

  DisplayID := FPendingDisplayID;
  if DisplayID = 0 then
    // What TShareableContent.RetainDisplay(-1) resolved to.
    DisplayID := CGMainDisplayID;
  if not ScreenFrameForDisplayID(DisplayID, ScreenFrame) then
  begin
    LogMessage('the recorded display has no NSScreen, so Zoom on Click and '
      + 'Follow Mouse are off for this recording');
    Exit;
  end;

  Base := FSession.BaseSourceRect;
  if FLive = nil then
    FLive := TLiveAnimator.Create;
  FLive.Start(FSession, Border, ScreenFrame,
    LiveRect(Base.origin.x, Base.origin.y, Base.size.width,
    Base.size.height), Zoom, Follow);
  if not FLive.Active then
    Exit;
  // Created unscheduled and added to the *common* modes, not scheduled
  // and then added again: the camera window is draggable during a
  // recording, and a drag puts the run loop in
  // NSEventTrackingRunLoopMode, where a default-mode-only timer stops
  // firing and a zoom freezes half way. NSRunLoopCommonModes already
  // includes the default mode, so scheduling first would register the
  // same timer twice and fire it at sixty hertz.
  FLiveTimer := NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats(
    LiveTickSeconds, FTarget, SelectorNamed(LiveTickSelector), nil, True);
  if FLiveTimer <> nil then
  begin
    FLiveTimer.retain;
    NSRunLoop.currentRunLoop.addTimer_forMode(FLiveTimer,
      NSRunLoopCommonModes);
  end;
end;

procedure TAppController.StopLive;
begin
  if FLiveTimer <> nil then
  begin
    FLiveTimer.invalidate;
    FLiveTimer.release;
    FLiveTimer := nil;
  end;
  // Every caller is on the stopping path *before* FinishCapture: the
  // animator holds the session, and a tick that arrived after the writer
  // had been finalised would be talking to a freed object.
  if FLive <> nil then
    FLive.Stop;
end;

procedure TAppController.LiveTick;
begin
  // An export owns the main thread and drains events to draw its
  // progress, which is how a timer can fire in the middle of one. There
  // is no recording running then, but the guard is cheap and the rule is
  // the same everywhere else in this unit.
  if Busy or (FLive = nil) then
    Exit;
  FLive.Tick;
  // The animator switches itself off when the session stops capturing;
  // the timer would otherwise keep firing until the stop path reaches it.
  if FLive.Active then
    Exit;
  // The other way it switches itself off is ScreenCaptureKit giving up on
  // live reconfiguration part way through. That is worth telling the user
  // about, and is deliberately not a Fail: the recording is unharmed and
  // goes on being written — it just stopped zooming and panning.
  if (FSession <> nil) and FSession.Capturing
    and not FSession.SupportsLiveUpdate
    and (FSession.LiveUpdateError <> '') then
  begin
    RecordError(FSession.LiveUpdateError);
    RefreshStatusItem;
  end;
  StopLive;
end;

procedure TAppController.StopLiveAfterFailure(const AMessage: string);
begin
  StopLive;
  RecordError(AMessage);
  RefreshStatusItem;
end;

// Runs one turn after the command that asked for a recording.
procedure TAppController.StartPending;
var
  Options: TRecordingOptions;
  Error: string;
  DisplayIndex: Integer;
  BorderWindowID: Cardinal;
  LiveZoom, LiveFollow: Boolean;
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
  // Zoom on Click and Follow Mouse move the stream's sourceRect, so the
  // capture has to be started with one even for a whole display, which
  // otherwise goes without. Asked for only when an effect is actually
  // going to apply — ResolveLiveEffects is the single place that
  // decides, and StartLive asks it again for the same answer.
  ResolveLiveEffects(Options.TargetKind, Options.HasRegion, FZoomOnClick,
    FFollowMouse, LiveZoom, LiveFollow);
  Options.LiveSourceRect := LiveZoom or LiveFollow;
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

  // Before the capture opens, so the very first frame already has the
  // camera where the recording wants it — an animated slide into place
  // would be in the file for ever. Everything that could still refuse
  // the recording (the output path, the options, the border) has been
  // settled above; only StartCapture itself can still fail, and it
  // undocks below.
  DockCameraForPending;

  // Nothing should be animating a session that is about to be freed, and
  // the animator holds a bare pointer to it.
  StopLive;
  FreeAndNil(FSession);
  FSession := TRecordingSession.Create(Options);
  if not FSession.StartCapture(Error) then
  begin
    HideBorder;
    UndockCamera;
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

  // After the capture is running, because the animator needs the
  // session's own base rectangle and a stream to send updates to.
  //
  // "The border was excluded" is deliberately conservative and not a
  // count-above-zero test: the report says how many of the requested ids
  // resolved, not *which*, so the honest reading is "the border was among
  // the requests AND every request resolved". The moment a second
  // exclusion joins the list — the camera window is the obvious
  // candidate — a count test would call the border excluded because
  // something else was, and this one refuses Follow Mouse instead. That
  // is the right way round: the cost of being wrong is a recording with
  // its own frame sliding through it.
  StartLive(BorderWindowID, (BorderWindowID <> 0)
    and WindowIDRequested(Options.ExcludedWindowIDs, BorderWindowID)
    and (FSession.Report.ExcludedWindows
    = Length(Options.ExcludedWindowIDs)));

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
  // Transition refuses everything while a GIF export owns the main
  // thread. Without asking, the stop would queue stopPending: anyway —
  // and that one-shot fires inside the export's own run-loop slices,
  // re-entering a FinishRecording that pumps the run loop from under an
  // export that is already pumping it. The recording keeps running; one
  // more click once the export is done stops it.
  if not Transition(acStopRecording) then
    Exit;
  // Before the deferred finalisation: the animator's last act is one
  // more updateConfiguration:, and the stream has to still be running
  // for it.
  StopLive;
  StopElapsedTimer;
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
  PixelWidth, PixelHeight, Scale: Integer;
begin
  if FSession = nil then
    Exit;
  // Idempotent, and the backstop for the paths that do not come through
  // CommandStop — Quit, above all, which finalises inline.
  StopLive;
  // The frame goes first: it belongs to the recording, not to the
  // finalisation, and finishing the writer pumps the run loop.
  HideBorder;
  Path := FSession.Report.OutputPath;
  PixelWidth := FSession.Report.PixelWidth;
  PixelHeight := FSession.Report.PixelHeight;
  // Pixels per point, and so the divisor the one-click GIF export sizes
  // itself by: at 2x it turns the export into an exact halving.
  Scale := FSession.Report.Scale;
  Finished := FSession.FinishCapture(Error);
  if not Finished then
    RecordError(Error);
  // AFTER FinishCapture, never before. The undock eases the camera back
  // over a fifth of a second, and until FinishCapture returns the stream
  // is still running and the writer is still appending — the border can
  // go early because it is a static window being removed, but a window
  // *moving* would be in the last frames of every docked take. That is
  // the very artefact DockTo avoids by moving in one step at the start.
  // FinishCapture stops the stream before it finalises the writer
  // (Knips.Recording.FinishCapture, "Stream first, then writer"), so by
  // here there is nothing left for the movement to land in.
  UndockCamera;
  FreeAndNil(FSession);
  RefreshStatusItem;
  // Playing the clip back is the "done" signal, and the window is where
  // the GIF export lives; a window that cannot be made falls back to
  // revealing the file in Finder. On the way out there is no signal to
  // give: Quit finalises the file and terminates, and a window (or a
  // Finder window) flashing up on the last turn before terminate: is
  // noise, not information.
  if AShowPlayback and Finished and (Path <> '') then
    ShowPlayback(Path, PixelWidth, PixelHeight, Scale);
end;

procedure TAppController.CommandRevealRecordings;
var
  Directory: string;
begin
  if Busy then
    Exit;
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

// The one command that is legal in every state. It does not go through
// the transition table at all — there is no camera state to be in.
procedure TAppController.CommandToggleCamera;
begin
  // Legal in every STATE, but not while an export owns the main thread:
  // startRunning blocks for the better part of a second mid-frame.
  if Busy or (FCamera = nil) then
    Exit;
  FLastError := '';
  if FCamera.Visible then
  begin
    FCamera.Hide;
    TCameraPreview.RememberVisible(False);
    RefreshStatusItem;
    Exit;
  end;

  // Mid-recording, only an already-granted camera may be started. An
  // undecided status would put a system permission prompt over the very
  // thing being recorded, and asking for the camera is the one moment a
  // recording could plausibly be interrupted — measured not to kill this
  // binary (docs/spikes/0001, "Camera"), but a preview toggle has no
  // business being anywhere near that risk while a file is open.
  if (FState = asRecording) and not TCameraPreview.IsAuthorized then
  begin
    HandleCameraError('grant camera access before recording starts');
    Exit;
  end;

  // Persist the *user's* answer either way. Remembering True after a
  // refused Show would make every later launch re-attempt and re-fail —
  // a revoked grant would put an error in the menu on every start with
  // no way to stop it. One click always turns it back on.
  TCameraPreview.RememberVisible(FCamera.Show);
  RefreshStatusItem;
end;

// Also outside the transition table, and for the same reason: there is no
// camera state to be in. Unlike the toggle it never touches the capture
// session, so it is legal even where switching the camera *on* is not —
// a shape change cannot put a permission prompt over a recording.
procedure TAppController.CommandToggleCameraShape;
begin
  // Still not while an export owns the main thread: the switch resizes a
  // window and moves a layer, which is AppKit work in the middle of
  // AppKit work the export is already doing.
  if Busy or (FCamera = nil) then
    Exit;
  if FCamera.Shape = csCircle then
    FCamera.Shape := csRectangle
  else
    FCamera.Shape := csCircle;
  RefreshStatusItem;
end;

procedure TAppController.CommandRestoreCamera;
begin
  if Busy or (FCamera = nil) or FCamera.Visible then
    Exit;
  // Authorized only. A NotDetermined status here would fire a permission
  // prompt the user never asked for, seconds after login, and still not
  // restore anything. The stored preference stays on, so the camera comes
  // back by itself on the first launch after the grant is given.
  if not TCameraPreview.IsAuthorized then
    Exit;
  FCamera.Show;
  RefreshStatusItem;
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
  // Hide writes the window's position back to NSUserDefaults, so quitting
  // from the menu is what makes "where I left it" survive a relaunch.
  if (FCamera <> nil) and FCamera.Visible then
    FCamera.Hide;
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
  // Before the first AppKit call, not after: sharedApplication kills the
  // process outright when there is no window server to connect to, and
  // `knips app` over SSH is a plausible mistake. A message and exit 2 is
  // the same answer every other set-up failure gets.
  if not HasWindowServer then
  begin
    AError := 'no window server — the menu-bar app needs a graphical '
      + 'login session';
    Exit;
  end;
  Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
  try
    Application := NSApplication.sharedApplication;
    // Accessory: a menu-bar-only process — no Dock tile, no main menu,
    // and windows can still become key (the overlay needs that). This is
    // where the app lives; only the playback window promotes it, and only
    // for as long as it is open.
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

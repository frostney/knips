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
// Errors never open a dialog. The message goes to ~/Library/Logs/
// Knips.log (the channel that works from a Finder-launched bundle,
// where stderr is /dev/null and the unified log redacts NSLog to
// <private>), to NSLog for terminal runs, and to a disabled
// "Last error: …" menu item; the app returns to idle without
// retrying — a denied Screen Recording grant must not become a loop.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  BaseUnix,
  SysUtils,

  CocoaAll,
  Knips.App.Border,
  Knips.App.Camera,
  Knips.App.Camera.Blur,
  Knips.App.CameraRide,
  Knips.App.Hotkey,
  Knips.App.Live,
  Knips.App.Overlay,
  Knips.App.Playback,
  Knips.App.State,
  Knips.Capture.ShareableContent,
  Knips.Capture.Stream,
  Knips.Export.MovieWriter,
  Knips.Export.Render,
  Knips.ObjC.Runtime,
  Knips.Options,
  Knips.Recording,
  Knips.Recording.CursorMath,
  Knips.Recording.LiveMath,
  Knips.Recording.Recovery,
  Knips.Recording.Sidecar,
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

  RecordRegionSelector = 'recordRegion:';
  RecordDisplaySelector = 'recordDisplay:';
  RecordWindowSelector = 'recordWindow:';
  RecordLastRegionSelector = 'recordLastRegion:';
  ToggleSystemAudioSelector = 'toggleSystemAudio:';
  ToggleMicrophoneSelector = 'toggleMicrophone:';
  StopRecordingSelector = 'stopRecording:';
  CancelSelectionSelector = 'cancelSelection:';
  RevealRecordingsSelector = 'revealRecordings:';
  QuitSelector = 'quitKnips:';
  TimerFiredSelector = 'timerFired:';
  StartPendingSelector = 'startPending:';
  StopPendingSelector = 'stopPending:';
  ToggleCameraSelector = 'toggleCamera:';
  ToggleCameraShapeSelector = 'toggleCameraShape:';
  ToggleCameraBlurSelector = 'toggleCameraBlur:';
  RestoreCameraSelector = 'restoreCamera:';
  ToggleFollowMouseSelector = 'toggleFollowMouse:';
  RecoverTakesSelector = 'recoverTakes:';
  // The live animator's 30 Hz tick while a Follow Mouse recording is
  // running. On the same target as everything else, so the feature adds
  // no runtime-built class of its own.
  LiveTickSelector = 'liveTick:';
  // The camera ride's own tick, and only for a WINDOW recording. A region
  // recording rides on the live animator's tick instead, because the
  // thing that moves the region is the animator itself and the camera has
  // to move in the same turn as the frame around it. Nothing moves a
  // recorded *window* but the user, so that one is polled — see
  // Knips.App.CameraRide's CameraRideTickSeconds. The body forwards
  // straight into that unit; the selector stays registered here because
  // KnipsAppTarget is the app's one runtime-built class.
  CameraRideSelector = 'cameraRideTick:';
  // KnipsAppTarget doubles as the Record Window submenu's NSMenuDelegate;
  // the list is rebuilt when AppKit is about to show it, so it is never
  // stale and never costs a ScreenCaptureKit query the user did not ask
  // for. A separate delegate class would carry no extra information.
  MenuNeedsUpdateSelector = 'menuNeedsUpdate:';

  RecordRegionTitle = 'Record Region…';
  RecordDisplayTitle = 'Record Display';
  RecordWindowTitle = 'Record Window';
  RecordLastRegionTitle = 'Record Last Region';
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

  // NSUserDefaults keys — everything the app remembers between launches
  // lives under one of these (plus the camera's and the status item's
  // own keys declared where they are used).
  SystemAudioKey = SystemAudioDefaultsKey;
  MicrophoneKey = MicrophoneDefaultsKey;
  LegacySystemAudioKey = LegacySystemAudioDefaultsKey;
  ZoomOnClickKey = ZoomOnClickDefaultsKey;
  FollowMouseKey = FollowMouseDefaultsKey;
  // The three legacy keys, read once by the effect migration and never
  // written again — see Knips.App.State for what each became.
  BigCursorKey = BigCursorDefaultsKey;
  SmoothCursorKey = SmoothCursorDefaultsKey;
  EffectZoomKey = EffectZoomDefaultsKey;
  EffectCursorKey = EffectCursorDefaultsKey;
  LastRegionDisplayKey = 'KnipsLastRegionDisplay';
  LastRegionLeftKey = 'KnipsLastRegionLeft';
  LastRegionTopKey = 'KnipsLastRegionTop';
  LastRegionWidthKey = 'KnipsLastRegionWidth';
  LastRegionHeightKey = 'KnipsLastRegionHeight';

  // LogMessage's second channel; see the comment on it for why NSLog on
  // its own reaches nobody. Relative to the user's home directory.
  LogFileRelativePath = 'Library/Logs/Knips.log';
  // O_NOFOLLOW from the Darwin SDK's sys/fcntl.h. BaseUnix declares
  // O_CREAT, O_APPEND and the rest but not this one on this target.
  DarwinONoFollow = $100;
  LogFileMaxBytes = 1024 * 1024;

  ElapsedTimerSeconds = 1.0;
  // A zero-delay one-shot: the selection commits inside the overlay
  // view's mouseUp:, and starting ScreenCaptureKit there would pump a
  // nested run loop while AppKit is still dispatching that event. The
  // timer moves the start to the next turn, with the overlay already off
  // screen. Stopping is deferred the same way and for the same reason:
  // finishing the writer pumps the run loop too, and the stop arrives
  // from a status-item action.
  DeferredStartSeconds = 0.0;

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

  // How many SCShareableContent snapshots the recording frame gets to
  // turn up in before the recording gives up on excluding it. See
  // TAppController.ResolvePendingTarget: one query is normally enough,
  // and each further one costs about 50 ms on the start path — only when
  // the previous snapshot was taken too early to contain the window.
  BorderVisibilityAttempts = 3;

type
  // One line of the Record Window submenu, cached between hovers so the
  // framework query does not run on every one.
  TWindowMenuEntry = record
    WindowID: Cardinal;
    Title: string;
  end;

  // The host base class is the camera ride's whole view of this object:
  // six answers it asks for, and nothing else (Knips.App.CameraRide).
  // Descending from it rather than handing the ride a TAppController is
  // what lets the ride live in its own unit at all — this unit uses that
  // one, so that one cannot use this one back.
  TAppController = class(TCameraRideHost)
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
    // The Audio submenu and its two checkboxes.
    FAudioItem: NSMenuItem;
    FAudioMenu: NSMenu;
    FSystemAudioItem: NSMenuItem;
    FMicrophoneItem: NSMenuItem;
    // The one record-time effect left in the menu; see BuildMenu.
    FFollowMouseItem: NSMenuItem;
    FStopItem: NSMenuItem;
    FCancelItem: NSMenuItem;
    // The Camera submenu and its three checkboxes.
    FCameraItem: NSMenuItem;
    FCameraMenu: NSMenu;
    FCameraShowItem: NSMenuItem;
    FCameraShapeItem: NSMenuItem;
    FCameraBlurItem: NSMenuItem;
    FErrorItem: NSMenuItem;
    // The menu bar the process shows while it is a Regular app. Built on
    // the first promotion and kept — see PromoteForPlayback.
    FMainMenu: NSMenu;
    FTimer: NSTimer;
    // The recording's own thirty-hertz tick, alive for the whole of every
    // recording. Separate from FTimer, which ticks once a second to
    // rewrite the status item and would be a strange place to hang a
    // thirty-hertz animation.
    //
    // It used to belong to the live effects and start only when one was
    // switched on. The event sidecar changed that: every recording logs
    // where the pointer went (Knips.Recording.Sidecar), so every recording
    // needs the tick, and the animator is now one of the two things that
    // happen inside it rather than the reason it exists.
    FTickTimer: NSTimer;
    // The camera dock, the composited window recording and the 5 Hz poll
    // that keeps both on a recorded window that moves — everything that
    // has to know where that window currently is, with its own timer.
    // Owned here and created with the controller; the `cameraRideTick:`
    // selector stays on KnipsAppTarget and forwards into it.
    FCameraRide: TCameraRide;
    FLive: TLiveAnimator;
    FOverlay: TSelectionOverlay;
    FCamera: TCameraPreview;
    FBorder: TRecordingBorder;
    FPlayback: TPlaybackWindow;
    FSession: TRecordingSession;
    FHotKey: TStopHotKey;
    FStartedAt: TDateTime;
    FLastError: string;
    // The writer's death is noticed on a 30 Hz tick and the stop it asks
    // for takes a turn or two to land, so without this the same line
    // would be written to the log thirty times a second. Cleared when a
    // take's tick starts.
    FWriterFailureReported: Boolean;
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
    // Persisted preferences. The two audio checkboxes are independent
    // Booleans and compose to the one TAudioMode the recorder takes;
    // AudioModeFromToggles is the whole mapping.
    FSystemAudio: Boolean;
    FMicrophone: Boolean;
    // Whether this ScreenCaptureKit has captureMicrophone at all (macOS
    // 15+; the project floor is 13). Asked once at Setup — it allocates
    // an SCStreamConfiguration to ask — and it decides whether the
    // Microphone checkbox can be ticked at all.
    FSupportsMicrophone: Boolean;
    FFollowMouse: Boolean;
    // The saved effect defaults: what the render applies on every stop,
    // and what the playback window's Effects control comes up showing.
    // Persisted per key like every other preference
    // (Knips.App.State.EffectZoomDefaultsKey and its neighbour).
    FEffects: TExportEffects;
    // True while the deliverable is being rendered off the raw take on
    // the main thread. Part of the same global lockout the GIF export
    // uses: the render turns the run loop over so its progress can be
    // drawn, which is exactly when a menu click could otherwise arrive.
    FRendering: Boolean;
    // Whether this session has already explained why a window take is
    // being composited. Once per session: it is a standing consequence
    // of a setting, not an event, and repeating it every take would
    // make it noise. See Knips.App.State.WindowCompositingNote.
    FSaidWindowCompositing: Boolean;
    FRenderPercent: Integer;
    FHasLastRegion: Boolean;
    FLastRegionDisplayID: UInt32;
    FLastRegion: TCaptureRegion;
    // Where the deliverable will go once the raw take has been rendered.
    // Settled at the start rather than at the stop so the two names are
    // decided together and by one timestamp.
    FPendingDeliverablePath: string;
    // What StartPending will record. 0 selects the main display.
    FPendingDisplayID: UInt32;
    FPendingHasRegion: Boolean;
    FPendingRegion: TCaptureRegion;
    FPendingWindowID: Cardinal;
    function AddMenuItem(const ATitle, ASelector: string): NSMenuItem;
    procedure BuildMenu;
    procedure BuildWindowMenu;
    procedure BuildAudioMenu;
    procedure BuildCameraMenu;
    procedure AddInertItem(AMenu: NSMenu; const ATitle: string);
    function WindowEntriesFresh: Boolean;
    procedure RefreshWindowEntries;
    function ElapsedSeconds: Int64;
    procedure RecordError(const AMessage: string);
    // RecordError where several answers about one take compete for the
    // menu's single slot: the first keeps it, the rest go to the log.
    procedure NoteError(const AMessage: string);
    procedure LoadPreferences;
    procedure StoreSystemAudio;
    procedure StoreMicrophone;
    procedure StoreFollowMouse;
    // One writer per key, as everything else here has: the cursor is a
    // word and the zoom is a Boolean, and neither procedure touches the
    // other's key. See the note above StoreFollowMouse for the incident.
    procedure StoreEffectZoom;
    procedure StoreEffectCursor;
    // Renders the deliverable off the raw take with the saved effect
    // defaults, showing progress on the status item. False with the
    // reason when the render could not run; the raw take is then what the
    // playback window opens, because a take nobody can see is worse than
    // one that is missing its effects.
    function RenderDeliverable(const ARawPath, ADeliverablePath: string;
      out AError: string): Boolean;
    procedure HandleRenderProgress(AFramesDone, AFramesTotal: Int64);
    procedure HandleEffectsChanged(const AEffects: TExportEffects);
    procedure StoreLastRegion;
    procedure ClearPending;
    // Starts the live animator and its timer for the recording that has
    // just begun, if either effect applies to it. ABorderExcluded says
    // whether the frame around the region really did reach the content
    // filter — Follow Mouse is refused when it did not, because a frame
    // that pans with the region would then be composited into the file.
    // The recording's thirty-hertz tick. Started as soon as a capture is
    // running, whatever it is recording and whatever effects are on, and
    // stopped when the file is finalised — the event sidecar's sampler is
    // driven from it and has no timer of its own.
    procedure StartRecordingTick;
    procedure StopRecordingTick;
    procedure StartLive(ABorderWindowID: Cardinal; ABorderExcluded: Boolean);
    procedure StopLive;
    // Puts the frame on the region about to be recorded and returns the
    // window id the capture must exclude. 0 when there is no region or
    // the border could not be shown; the recording then runs without one.
    function ShowBorderForPending: Cardinal;
    procedure HideBorder;
    procedure ShowPlayback(const APath, ARawPath: string; APixelWidth,
      APixelHeight, AScale: Integer);
    procedure HandlePlaybackError(const AMessage: string);
    // The playback window is the only thing in this app that puts the
    // process in the Dock; these two are the whole of it.
    procedure PromoteForPlayback;
    procedure HandlePlaybackClosed;
    procedure ClosePlaybackForRecording;
    function Transition(ACommand: TAppCommand): Boolean;
    function ResolvePendingTarget(ADisplayID: UInt32;
      ABorderWindowID: Cardinal; out AIndex: Integer;
      out ABorderVisible: Boolean; out AError: string): Boolean;
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
  protected
    // The camera ride's six questions, answered. Session and camera are
    // read live rather than handed over once, because both are replaced
    // while the ride is running — see the note on TCameraRideHost.
    function RideSession: TRecordingSession; override;
    function RideCamera: TCameraPreview; override;
    function RideTimerTarget: id; override;
    function RideTimerSelector: SEL; override;
    function RideBusy: Boolean; override;
    procedure RideRecordError(const AMessage: string); override;
  public
    constructor Create;
    // The crash-recovery pass, run one turn after launch over the
    // recordings directory (Knips.Recording.Recovery). Public because the
    // deferred one-shot dispatches into it.
    procedure RecoverUnfinishedTakes;
    function TakeCanStillBeRendered(const ASidecarPath: string): Boolean;
    destructor Destroy; override;
    function Setup(out AError: string): Boolean;
    procedure RefreshStatusItem;
    procedure CommandRecordRegion;
    procedure CommandRecordDisplay;
    procedure CommandRecordWindow(AWindowID: Cardinal);
    procedure CommandRecordLastRegion;
    procedure CommandToggleSystemAudio;
    procedure CommandToggleMicrophone;
    procedure CommandToggleFollowMouse;
    // The playback window's Effects control, forwarded on. The window
    // owns the selection; the controller owns the saved default.
    procedure CommandToggleEffectZoom;
    procedure CommandToggleEffectSmoothCursor;
    procedure CommandToggleEffectBigCursor;
    procedure CommandReexport;
    procedure CommandStop;
    procedure CommandCancelSelection;
    // What to append to the Stop item's title: '' when no audio source is
    // on, and otherwise what the two tracks have delivered so far.
    function RecordingAudioNote: string;
    procedure CommandRevealRecordings;
    procedure CommandToggleCamera;
    procedure CommandToggleCameraShape;
    procedure CommandToggleCameraBlur;
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
    // One turn of the window ride; the 5 Hz timer's target, forwarded
    // to the ride itself (Knips.App.CameraRide).
    procedure CameraRideTick;
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

// Where LogMessage's lines land besides NSLog. `~/Library/Logs` is the
// standard place for an application's own log on macOS and exists on
// every account; Console.app lists it, and so does `tail`.
function LogFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetUserDir) + LogFileRelativePath;
end;

// Appends one timestamped line, and never raises: a diagnostic that can
// fail the thing it is diagnosing is worse than no diagnostic.
//
// The file is started over once it passes LogFileMaxBytes rather than
// rotated. A menu-bar app that runs for months has no business growing an
// unbounded file, and there is nothing here worth keeping two of.
procedure AppendToLogFile(const AMessage: string);
var
  Path, Line: string;
  Handle: THandle;
begin
  try
    Path := LogFilePath;
    // O_APPEND, so each write is atomic at the end of the file even when
    // two processes — the installed bundle and a development build both
    // answering to org.knips.app — log at once. A seek-then-write pair
    // is not: one process's truncation between another's seek and write
    // punches a NUL hole the size of the old file.
    // `&666` is FPC's OCTAL literal syntax, not a typo for 0666 or a
    // decimal 666: it is rw-rw-rw-, which umask then narrows to the
    // usual rw-r--r--. Spelled out because the ampersand form is rare
    // enough to read as a mistake.
    // O_NOFOLLOW: the log is opened by a fixed path in a directory
    // anything the user runs can write, and a symlink planted at that
    // path would have every diagnostic line appended to whatever it
    // points at. Refusing is the whole of the response — a menu-bar app
    // that cannot write its log is an app with no log, not a broken one.
    // Declared here rather than taken from BaseUnix, which does not
    // carry it on Darwin; verified against the platform SDK's
    // sys/fcntl.h (0x100).
    Handle := FpOpen(PAnsiChar(Path),
      O_WRONLY or O_APPEND or O_CREAT or DarwinONoFollow, &666);
    if Handle < 0 then
      Exit;
    if FpLseek(Handle, 0, SEEK_END) > LogFileMaxBytes then
    begin
      FileClose(Handle);
      // Reopened with the same O_NOFOLLOW, not with FileCreate: that
      // one follows a symlink, so the rotation branch handed back
      // exactly the write the open above had just refused — a link
      // planted at the log path would have been truncated and written
      // through the moment the file passed a megabyte.
      Handle := FpOpen(PAnsiChar(Path),
        O_WRONLY or O_CREAT or O_TRUNC or DarwinONoFollow, &666);
      if Handle < 0 then
        Exit;
    end;
    try
      Line := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' knips: '
        + AMessage + LineEnding;
      FileWrite(Handle, Line[1], Length(Line));
    finally
      FileClose(Handle);
    end;
  except
    // Nothing left to try, and nothing here is worth an exception.
  end;
end;

// Every refusal in this unit reports through here — why Follow Mouse was
// turned off for a recording, why the window list was empty — so a line
// that goes nowhere makes those failures undiagnosable, which is exactly
// what happened.
//
// NSLog alone is not enough, and the reason is measured on this machine
// rather than assumed. FPC hands NSLog a *dynamic* NSString as the format,
// so NSLog cannot take the compile-time os_log path; the unified log gets
// the line with its whole payload redacted, and `log show` prints
// `<private>` for every one of them — literal format strings included.
// NSLog's other half, a write to fd 2, does survive (checked: it reaches a
// redirected stderr, not only a terminal) — but a bundle launched from
// Finder has fd 2 on /dev/null, and the bundle is how the app is actually
// used. The file is therefore the channel that works in both, and NSLog
// stays for the terminal, where it is the convenient one.
procedure LogMessage(const AMessage: string);
begin
  NSLog(PascalToNSString('knips: %@'), PascalToNSString(AMessage));
  AppendToLogFile(AMessage);
end;

// Which half of the exclusion went wrong, for the message that reports it.
// ScreenCaptureKit not having the frame in its window list at all and
// ScreenCaptureKit having it and dropping it anyway are different faults
// with different fixes, and the line is the only place they can be told
// apart afterwards.
function BorderVisibleNote(ABorderVisible: Boolean): string;
begin
  if ABorderVisible then
    Result := ', though ScreenCaptureKit did list the frame'
  else
    Result := ', and ScreenCaptureKit never listed the frame';
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

procedure TargetToggleMicrophone(ASelf: id; ACommand: SEL;
  ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandToggleMicrophone;
  except
    on E: Exception do
      HandleBodyException(Controller, ToggleMicrophoneSelector, E);
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

// The crash-recovery pass, one run-loop turn after launch. Deferred and
// not inline: it lists a directory that only grows, and a status item
// that appears half a second late is exactly the kind of launch nobody
// can explain. Same shape as the deferred camera restore.
procedure TargetRecoverTakes(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.RecoverUnfinishedTakes;
  except
    on E: Exception do
      HandleBodyException(Controller, RecoverTakesSelector, E);
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

// The Effects control and Re-export, on the same one runtime-built
// target as everything else. Each forwards to the controller, which
// forwards to the playback window that owns the selection.
procedure TargetToggleEffectZoom(ASelf: id; ACommand: SEL;
  ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandToggleEffectZoom;
  except
    on E: Exception do
      HandleBodyException(Controller, ToggleEffectZoomSelector, E);
  end;
end;

procedure TargetToggleEffectSmoothCursor(ASelf: id; ACommand: SEL;
  ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandToggleEffectSmoothCursor;
  except
    on E: Exception do
      HandleBodyException(Controller, ToggleEffectSmoothCursorSelector, E);
  end;
end;

procedure TargetToggleEffectBigCursor(ASelf: id; ACommand: SEL;
  ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandToggleEffectBigCursor;
  except
    on E: Exception do
      HandleBodyException(Controller, ToggleEffectBigCursorSelector, E);
  end;
end;

procedure TargetReexport(ASelf: id; ACommand: SEL; ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandReexport;
  except
    on E: Exception do
      HandleBodyException(Controller, ReexportSelector, E);
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

// Five times a second while a window recording has a docked camera.
// Deliberately on the camera's error path rather than Fail's, exactly
// like the two camera menu bodies: the ride is cosmetic, and a window
// whose frame could not be read must not knock a live recording to idle.
procedure TargetCameraRideTick(ASelf: id; ACommand: SEL; ATimer: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CameraRideTick;
  except
    on E: Exception do
      HandleCameraBodyException(Controller, CameraRideSelector, E);
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

procedure TargetToggleCameraBlur(ASelf: id; ACommand: SEL;
  ASender: id); cdecl;
var
  Controller: TAppController;
begin
  Controller := nil;
  try
    Controller := ControllerOf(ASelf);
    if Controller <> nil then
      Controller.CommandToggleCameraBlur;
  except
    on E: Exception do
      HandleCameraBodyException(Controller, ToggleCameraBlurSelector, E);
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
  // And the camera's blur delegate, for the same reason: a video-data
  // output whose delegate is missing its one method is a preview that
  // goes black the moment Blur Background is ticked.
  EnsureCameraBlurClasses;
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
    AddTargetMethod(Builder, ToggleMicrophoneSelector, @TargetToggleMicrophone);
    AddTargetMethod(Builder, ToggleFollowMouseSelector,
      @TargetToggleFollowMouse);
    AddTargetMethod(Builder, ToggleEffectZoomSelector,
      @TargetToggleEffectZoom);
    AddTargetMethod(Builder, ToggleEffectSmoothCursorSelector,
      @TargetToggleEffectSmoothCursor);
    AddTargetMethod(Builder, ToggleEffectBigCursorSelector,
      @TargetToggleEffectBigCursor);
    AddTargetMethod(Builder, ReexportSelector, @TargetReexport);
    AddTargetMethod(Builder, RecoverTakesSelector, @TargetRecoverTakes);
    AddTargetMethod(Builder, LiveTickSelector, @TargetLiveTick);
    AddTargetMethod(Builder, CameraRideSelector, @TargetCameraRideTick);
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
    AddTargetMethod(Builder, ToggleCameraBlurSelector,
      @TargetToggleCameraBlur);
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
  // Before Setup, because the ride asks this object for the timer's
  // target rather than being handed one: it can exist from the start and
  // simply has nothing to do until a window recording begins.
  FCameraRide := TCameraRide.Create(Self);
end;

destructor TAppController.Destroy;
begin
  StopElapsedTimer;
  StopRecordingTick;
  StopLive;
  // Its destructor invalidates the poll's timer, which is what the
  // explicit stop here used to do; nothing below asks the ride anything.
  FreeAndNil(FCameraRide);
  // Before the target goes: the hotkey's handler talks to this object,
  // and a chord left registered by a process on its way out is a chord
  // the next Knips cannot have.
  FreeAndNil(FHotKey);
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
  if FAudioMenu <> nil then
  begin
    // The submenu retains its four items; this balances the alloc. The
    // items' target is the KnipsAppTarget released below, so the menu has
    // to go first — the same order the main menu is torn down in.
    FAudioMenu.release;
    FAudioMenu := nil;
  end;
  if FCameraMenu <> nil then
  begin
    // The same, for the camera submenu, and it was simply missed when
    // that menu was added: an alloc'd NSMenu with no matching release.
    // Same ordering rule, same reason.
    FCameraMenu.release;
    FCameraMenu := nil;
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

{ The Audio submenu: two independent checkboxes, System Audio and
  Microphone, which between them offer all four TAudioModes — neither is
  none, one is that one, both is both.

  *Record System Audio* was not wrong so much as incomplete. The recorder
  has captured the microphone since the CLI grew `--audio=mic`, and the
  app offered exactly one of the four modes, so a user who *spoke* into a
  take got a silent file and reasonably concluded that Knips does not
  record audio. Two checkboxes say what is on offer; a submenu is where
  they live because between them they are one setting — what the
  recording listens to.

  Built once, not rebuilt on every open: unlike the window list there is
  nothing here that can go stale except the checkmarks and the enabled
  flags, and RefreshStatusItem already rewrites those.

  Microphone is disabled where ScreenCaptureKit has no captureMicrophone
  — macOS 15, against a project floor of 13 — and carries the reason in
  the title *and* in a tooltip. A greyed-out line that does not say why
  is the thing users file bugs about. }

procedure TAppController.BuildAudioMenu;

  function AddAudioItem(const ATitle, ASelector: string): NSMenuItem;
  begin
    Result := NSMenuItem(NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
      PascalToNSString(ATitle), SelectorNamed(ASelector),
      PascalToNSString('')));
    Result.setTarget(FTarget);
    FAudioMenu.addItem(Result);
    Result.release;
  end;

begin
  FAudioMenu := NSMenu(NSMenu.alloc.initWithTitle(
    PascalToNSString(AudioMenuTitle)));
  // Same as the root menu: the controller decides what is legal, not
  // AppKit's own validation.
  FAudioMenu.setAutoenablesItems(False);
  FSystemAudioItem := AddAudioItem(SystemAudioMenuTitle,
    ToggleSystemAudioSelector);
  FMicrophoneItem := AddAudioItem(
    MicrophoneMenuItemTitle(FSupportsMicrophone),
    ToggleMicrophoneSelector);
  if not FSupportsMicrophone then
    FMicrophoneItem.setToolTip(PascalToNSString(
      'ScreenCaptureKit on this Mac has no microphone capture; it needs '
      + 'macOS 15 or newer'));
end;

{ The Camera submenu: the three settings that are all about the
  picture-in-picture window — whether it is up, what shape it is, and
  whether its background is blurred. The same argument that put the two
  audio sources behind one *Audio* item: between them they are one thing,
  and the root menu had grown to a dozen lines with four of them about a
  240-point window.

  All three are legal in every state, which is why none of them consults
  the transition table. The camera is a passive window — ScreenCaptureKit
  records it because it is on the display, and nothing in the recorder
  knows it exists — so switching it on, rounding it off or blurring
  behind it cannot fail a capture. Mid-recording is also exactly when a
  presenter wants them.

  Built once, like the Audio submenu: nothing here goes stale but the
  checkmarks, and RefreshStatusItem rewrites those. }

procedure TAppController.BuildCameraMenu;

  function AddCameraItem(const ATitle, ASelector: string): NSMenuItem;
  begin
    Result := NSMenuItem(NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
      PascalToNSString(ATitle), SelectorNamed(ASelector),
      PascalToNSString('')));
    Result.setTarget(FTarget);
    FCameraMenu.addItem(Result);
    Result.release;
  end;

begin
  FCameraMenu := NSMenu(NSMenu.alloc.initWithTitle(
    PascalToNSString(CameraMenuTitle)));
  FCameraMenu.setAutoenablesItems(False);
  FCameraShowItem := AddCameraItem(ShowCameraMenuTitle, ToggleCameraSelector);
  FCameraShapeItem := AddCameraItem(CircularCameraMenuTitle,
    ToggleCameraShapeSelector);
  FCameraBlurItem := AddCameraItem(BlurBackgroundMenuTitle,
    ToggleCameraBlurSelector);
  // The one line in this submenu that can be unavailable, and it says so
  // rather than being silently inert — the same rule the Microphone item
  // follows. Vision's person segmentation is macOS 12 against a project
  // floor of 13, so in practice this never fires; it is the honest
  // answer if some future macOS moves the frameworks.
  if not CameraBlurSupported then
    FCameraBlurItem.setToolTip(PascalToNSString(
      'background blur needs Vision and CoreImage, which this Mac does '
      + 'not have'));
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
  // Display only. The real trigger is the Carbon hotkey in
  // Knips.App.Hotkey, and it has to be, because while a recording runs
  // this menu is *detached* from the status item (a single click stops —
  // Kap's gesture) and a key equivalent on a menu nobody can open fires
  // for nobody. What this buys is the one place the shortcut can be
  // discovered: the item it belongs to.
  FStopItem.setKeyEquivalent(PascalToNSString(StopHotKeyKeyEquivalent));
  FStopItem.setKeyEquivalentModifierMask(NSCommandKeyMask or NSShiftKeyMask);
  // Only reachable when the overlay failed to come up — a live overlay
  // covers the menu bar, and inside it Esc or a stray click cancel.
  FCancelItem := AddMenuItem(CancelSelectionTitle, CancelSelectionSelector);
  FMenu.addItem(NSMenuItem.separatorItem);
  // Two submenus and one loose checkbox. Each submenu is a single
  // question — what the picture-in-picture does, what the recording
  // listens to — and a submenu item carries no action of its own, exactly
  // like Record Window; the checkboxes inside carry their own selectors.
  FCameraItem := AddMenuItem(CameraMenuTitle, '');
  BuildCameraMenu;
  FCameraItem.setSubmenu(FCameraMenu);
  // Where the Behaviour submenu used to be, and now a single checkbox.
  // Zoom on Click, Big Cursor and Smooth Cursor left it for the playback
  // window's Effects control — they are things done to a take, and a take
  // is the one thing the menu bar does not have in front of it. Follow
  // Mouse stays because it cannot leave: a pan decides which pixels are
  // read off the screen, so it has to be chosen before the reading
  // starts. One item is not a submenu, so it is not one any more.
  FFollowMouseItem := AddMenuItem(FollowMouseMenuTitle,
    ToggleFollowMouseSelector);
  FAudioItem := AddMenuItem(AudioMenuTitle, '');
  BuildAudioMenu;
  FAudioItem.setSubmenu(FAudioMenu);
  FMenu.addItem(NSMenuItem.separatorItem);
  // The returned items are dropped: nothing ever enables, disables,
  // renames or hides these two. AddMenuItem is called for its side
  // effect — the item is added to the menu and retained by it.
  AddMenuItem(RevealRecordingsTitle, RevealRecordingsSelector);
  FErrorItem := AddMenuItem(ErrorMenuTitle(''), '');
  FErrorItem.setEnabled(False);
  FErrorItem.setHidden(True);
  FMenu.addItem(NSMenuItem.separatorItem);
  AddMenuItem(QuitTitle, QuitSelector);
end;

function TAppController.WindowEntriesFresh: Boolean;
var
  Age: Double;
begin
  if not FWindowEntriesValid then
    Exit(False);
  Age := (Now - FWindowEntriesAt) * SecsPerDay;
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
var
  HotKeyError: string;
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
  // Before LoadPreferences, which needs it to decide whether a stored
  // microphone mode is still reachable on this Mac.
  FSupportsMicrophone := StreamSupportsMicrophone;
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

  // The global stop hotkey. A failure here is a Last error and nothing
  // more: the app is perfectly usable without it — one click on the
  // status item stops a recording — and refusing to start over a
  // keyboard shortcut would be absurd.
  FHotKey := TStopHotKey.Create;
  FHotKey.OnPressed := CommandStop;
  FHotKey.OnError := HandleOverlayError;
  if not FHotKey.Install(HotKeyError) then
    RecordError(HotKeyError);

  RefreshStatusItem;
  // A take whose process died is finished off on the next turn of the run
  // loop, not here: the scan lists a directory that only grows, and the
  // status item has to be in the menu bar first. Same reason the camera
  // restore below is deferred.
  ScheduleOneShot(RecoverTakesSelector);
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
  HasZoomKey, HasCursorKey: Boolean;
begin
  Defaults := NSUserDefaults.standardUserDefaults;
  // objectForKey: separates "never written" from a legitimate False,
  // which is the whole of the migration: only an absent KnipsAudioSystem
  // consults the Boolean this setting replaced, and once
  // StoreSystemAudio has written the new key the old one is never read
  // again. The old key is deliberately left where it is rather than
  // deleted; `defaults` is a public interface and a downgrade should
  // still find what it wrote.
  FSystemAudio := MigratedSystemAudio(
    Defaults.objectForKey(PascalToNSString(SystemAudioKey)) <> nil,
    Defaults.boolForKey(PascalToNSString(SystemAudioKey)),
    Defaults.boolForKey(PascalToNSString(LegacySystemAudioKey)));
  // No migration for the microphone: there was nothing to migrate from,
  // and False is what boolForKey: answers for a key never written.
  FMicrophone := Defaults.boolForKey(PascalToNSString(MicrophoneKey));
  // A stored microphone tick on a Mac whose ScreenCaptureKit has no
  // microphone capture would refuse every recording it started. Drop it
  // rather than let a checkbox that cannot work stay ticked; system
  // audio, which is macOS 13 like the project floor, is untouched.
  if not FSupportsMicrophone then
    FMicrophone := False;
  // Defaults to False, which is what boolForKey: answers for a key that
  // has never been written — no registerDefaults: needed.
  FFollowMouse := Defaults.boolForKey(PascalToNSString(FollowMouseKey));
  // The effect defaults, migrated once out of the three menu toggles they
  // replaced. objectForKey: separates "never written" from a legitimate
  // False, exactly as the audio migration does, and the old keys are read
  // rather than written: an upgrade keeps what was ticked, and a
  // downgrade still finds what it wrote.
  FEffects := DefaultAppEffects;
  HasZoomKey := Defaults.objectForKey(PascalToNSString(EffectZoomKey)) <> nil;
  HasCursorKey :=
    Defaults.objectForKey(PascalToNSString(EffectCursorKey)) <> nil;
  FEffects.ZoomOnClick := MigratedEffectZoom(HasZoomKey,
    Defaults.boolForKey(PascalToNSString(EffectZoomKey)),
    Defaults.boolForKey(PascalToNSString(ZoomOnClickKey)));
  FEffects.Cursor := MigratedEffectCursor(HasCursorKey,
    NSStringToPascal(Defaults.stringForKey(
    PascalToNSString(EffectCursorKey))),
    Defaults.boolForKey(PascalToNSString(BigCursorKey)),
    Defaults.boolForKey(PascalToNSString(SmoothCursorKey)));
  // Written through on the first launch that finds no new key, rather
  // than left to the first time the user changes something. The
  // migration is then over after one launch: the legacy keys are never
  // read again, and `defaults read` shows what the app is actually going
  // to do. They are still not *deleted* — a downgrade should find what it
  // wrote.
  if not HasZoomKey then
    StoreEffectZoom;
  if not HasCursorKey then
    StoreEffectCursor;
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

// One key each, and deliberately not one procedure writing both — see
// the note on StoreFollowMouse below for the incident that rule comes
// from. The Boolean these replaced is read exactly once, by the
// migration in LoadPreferences and only when KnipsAudioSystem has never
// been written, so writing it back here would be writing a value nothing
// reads in a shape that cannot express the microphone at all.
procedure TAppController.StoreSystemAudio;
begin
  NSUserDefaults.standardUserDefaults.setBool_forKey(ObjCBOOL(FSystemAudio),
    PascalToNSString(SystemAudioKey));
end;

procedure TAppController.StoreMicrophone;
begin
  NSUserDefaults.standardUserDefaults.setBool_forKey(ObjCBOOL(FMicrophone),
    PascalToNSString(MicrophoneKey));
end;

// One key each, and deliberately not one procedure writing both.
//
// The fields these come from are read once, at Setup, and never read
// again; writing the pair on every toggle therefore writes one value the
// user just chose and one that is however old this process is. Anything
// that changed the other key in the meantime — a second Knips (the
// installed app beside a development build both answer to
// org.knips.app), or the `defaults write` that LoadPreferences already
// treats as a public interface to these keys — is silently reverted by
// the next toggle of its neighbour, and what the user sees is a
// preference that would not stay switched on.
procedure TAppController.StoreFollowMouse;
begin
  NSUserDefaults.standardUserDefaults.setBool_forKey(ObjCBOOL(FFollowMouse),
    PascalToNSString(FollowMouseKey));
end;

// Its own key and its own writer, for the third time and for the same
// incident. Nothing here reads or writes any other preference.
// The effect defaults, one key each and one writer each — the fourth and
// fifth application of the rule, and the two that replaced Big Cursor and
// Smooth Cursor. The cursor is stored as a word rather than as a pair of
// Booleans because the three cursor effects are one setting, and two
// Booleans are exactly the shape that can hold a contradiction.
procedure TAppController.StoreEffectZoom;
begin
  NSUserDefaults.standardUserDefaults.setBool_forKey(
    ObjCBOOL(FEffects.ZoomOnClick), PascalToNSString(EffectZoomKey));
end;

procedure TAppController.StoreEffectCursor;
begin
  NSUserDefaults.standardUserDefaults.setObject_forKey(
    PascalToNSString(ExportCursorModeName(FEffects.Cursor)),
    PascalToNSString(EffectCursorKey));
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
  FPendingDeliverablePath := '';
  FPendingDisplayID := 0;
  FPendingHasRegion := False;
  FPendingRegion := Default(TCaptureRegion);
  FPendingWindowID := 0;
  FCameraRide.ClearComposited;
end;

function TAppController.ShowBorderForPending: Cardinal;
begin
  Result := 0;
  if (FBorder = nil) or not FPendingHasRegion or (FPendingDisplayID = 0) then
    Exit;
  // A composited window recording is a region capture underneath, but it
  // is a *window* recording to the user, and a window recording has
  // never had a frame drawn round it. Drawing one now would also put a
  // second window into a capture that — unlike a region's — really does
  // see everything in front of it.
  if FCameraRide.CompositedWindowID <> 0 then
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

{ The camera ride's back-reference, and the whole of it.

  The dock, the composited window recording and the 5 Hz poll live in
  Knips.App.CameraRide now — everything that has to know where a recorded
  window currently is, on a clock of its own. It reaches back into the
  controller through these six, which is why they are worth reading as a
  group: they are the entire coupling between the two objects.

  The camera and the session are questions rather than values because
  both change under the ride's feet. StartPending docks the camera —
  which starts the poll — and only then frees one recording session and
  creates the next, so a session pointer handed over at the start would
  be the dead one by the first tick; and the user is free to switch the
  camera off in the middle of a take. }

function TAppController.RideSession: TRecordingSession;
begin
  Result := FSession;
end;

function TAppController.RideCamera: TCameraPreview;
begin
  Result := FCamera;
end;

// The ride adds no runtime-built class of its own: `cameraRideTick:` is
// registered on the same KnipsAppTarget every other action goes through
// (ADR-0002), and TargetCameraRideTick forwards it.
function TAppController.RideTimerTarget: id;
begin
  Result := FTarget;
end;

function TAppController.RideTimerSelector: SEL;
begin
  Result := SelectorNamed(CameraRideSelector);
end;

function TAppController.RideBusy: Boolean;
begin
  Result := Busy;
end;

// RecordError plus the status-item refresh that has always followed it
// here: the ride says one thing, and it says it into the menu's single
// "Last error" slot.
procedure TAppController.RideRecordError(const AMessage: string);
begin
  RecordError(AMessage);
  RefreshStatusItem;
end;

// The 5 Hz timer fires into KnipsAppTarget like every other action, and
// this is the whole of what the controller still does with it.
procedure TAppController.CameraRideTick;
begin
  FCameraRide.Tick;
end;

procedure TAppController.ShowPlayback(const APath, ARawPath: string;
  APixelWidth, APixelHeight, AScale: Integer);
var
  Shown: Boolean;
begin
  if FPlayback = nil then
  begin
    FPlayback := TPlaybackWindow.Create;
    FPlayback.OnError := HandlePlaybackError;
    FPlayback.OnClosed := HandlePlaybackClosed;
    FPlayback.OnEffectsChanged := HandleEffectsChanged;
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
    Shown := FPlayback.Show(FTarget, APath, ARawPath, APixelWidth,
      APixelHeight, AScale, FEffects);
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
  Result := Trunc((Now - FStartedAt) * SecsPerDay);
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
  begin
    // The render happens after the state machine is back at idle, so the
    // idle glyph would be the honest answer and the wrong one: the app is
    // busy for several seconds with nothing to show for it. The
    // percentage is the only thing on screen that says so.
    if FRendering then
      Button.setTitle(PascalToNSString(RenderStatusItemTitle(FRenderPercent)))
    else
      Button.setTitle(PascalToNSString(StatusItemTitle(FState,
        ElapsedSeconds)));
  end;

  FRegionItem.setEnabled(IsCommandEnabled(FState, acRecordRegion));
  FDisplayItem.setEnabled(IsCommandEnabled(FState, acRecordDisplay));
  FWindowItem.setEnabled(IsCommandEnabled(FState, acRecordWindow));
  // The table says when the command could be legal; the region on file
  // says whether there is anything to repeat.
  FLastRegionItem.setEnabled(FHasLastRegion
    and IsCommandEnabled(FState, acRecordLastRegion));
  // The submenu's parent item, and then the two checkboxes inside it.
  // The parent is enabled while either child could be; the microphone
  // additionally needs this Mac to have microphone capture at all.
  FAudioItem.setEnabled(IsCommandEnabled(FState, acToggleSystemAudio)
    or IsCommandEnabled(FState, acToggleMicrophone));
  FSystemAudioItem.setEnabled(IsCommandEnabled(FState, acToggleSystemAudio));
  FSystemAudioItem.setState(MenuCheckState(FSystemAudio));
  FMicrophoneItem.setEnabled(IsCommandEnabled(FState, acToggleMicrophone)
    and FSupportsMicrophone);
  FMicrophoneItem.setState(MenuCheckState(FMicrophone));
  FFollowMouseItem.setEnabled(IsCommandEnabled(FState, acToggleFollowMouse));
  FFollowMouseItem.setState(MenuCheckState(FFollowMouse));
  FStopItem.setEnabled(IsCommandEnabled(FState, acStopRecording));
  // The audio assurance, and it lives here rather than in the menu bar on
  // purpose: a level indicator in the menu bar would be a second moving
  // thing beside the clock, and the question "is it actually hearing
  // anything?" is one people ask once, on the way to the Stop item. So
  // the answer is written on the Stop item, and is invisible until the
  // menu is open.
  FStopItem.setTitle(PascalToNSString(StopRecordingTitle
    + RecordingAudioNote));
  FCancelItem.setEnabled(IsCommandEnabled(FState, acCancelSelection));

  // Not part of the state machine — see BuildCameraMenu. The titles are
  // constant; the checkmarks are what say what the window is doing. The
  // submenu's own parent is never disabled, because all three of its
  // items are legal in every state.
  CameraVisible := (FCamera <> nil) and FCamera.Visible;
  FCameraShowItem.setState(CameraMenuState(CameraVisible));
  // All three items are read the same way, off nil-tolerant locals: a
  // camera that does not exist yet is not visible, is the default shape
  // and is not blurred.
  if FCamera <> nil then
    CameraShape := FCamera.Shape
  else
    CameraShape := csRectangle;
  FCameraShapeItem.setState(CameraShapeMenuState(CameraShape));
  FCameraBlurItem.setEnabled(CameraBlurSupported);
  FCameraBlurItem.setState(MenuCheckState((FCamera <> nil)
    and FCamera.BlurEnabled));

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

// The same, for a stretch of code that can produce SEVERAL things worth
// saying about one take — the stop, above all, which checks the
// finalisation, then system audio, then the microphone, then the render.
// The menu has one Last-error slot, so the last speaker used to win it
// and everything before was gone: a take whose file failed to finalise
// and whose microphone was also muted showed the microphone.
//
// First wins here instead, and the rest still reach the log, where
// nothing is lost. The pattern is StartLive's, where the same problem
// was answered the same way — see "Follow Mouse is off for this
// recording". It puts a burden on the ORDER of the checks, and that
// order is deliberate: the finish's most consequential answer, whether
// the movie was written at all, is asked first.
procedure TAppController.NoteError(const AMessage: string);
begin
  if FLastError = '' then
    RecordError(AMessage)
  else
    LogMessage(AMessage);
end;

// The hard stop: something raised, and the state machine is put back to
// idle with the frame, the camera and the animator taken down with it.
//
// **It assumes it is not called while Busy.** Transition(acCaptureFailed)
// is refused during an export or a render, so a Fail raised from inside
// one would log its message and leave the state machine exactly where it
// was — with the teardown below still having run. That is not a state
// anything here recovers from, and it is kept out by construction rather
// than by a guard: every caller of Fail is on a start or a stop path, and
// both of those are themselves refused while Busy (CommandStop's own
// comment says why). Anything new that can raise inside an export must
// report through RecordError, not through here.
procedure TAppController.Fail(const AMessage: string);
begin
  RecordError(AMessage);
  // Whatever raised left the state machine mid-move; anything but idle
  // would have no way back, since the failing command is the one the
  // user just tried.
  Transition(acCaptureFailed);
  // The animator holds a session that may be on its way out; it must not
  // outlive the recording it was animating — and neither must the tick
  // that samples the pointer into its sidecar.
  StopRecordingTick;
  StopLive;
  // A frame left on screen with no recording behind it is a lie about
  // what the app is doing.
  HideBorder;
  // And so is a camera window parked in the corner of a region nothing
  // is recording any more.
  FCameraRide.UndockCamera;
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
  // Three things own the main thread for seconds at a time and turn the
  // run loop over while they do it: the GIF export, the re-export from
  // the playback window (both FPlayback.Exporting), and the render that
  // follows every stop. All three have to lock every command out.
  Result := FRendering or ((FPlayback <> nil) and FPlayback.Exporting);
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

// Both questions ScreenCaptureKit has to answer before a recording can
// start, out of one query: which index the pending display sits at, and —
// when there is a frame around the region — whether that frame has
// reached the framework's window list yet.
//
// They are answered together because the query is the expensive part (40
// to 60 ms, measured on device) and because the second question is on a
// clock. The frame is a window created milliseconds earlier, and
// SCShareableContent hands back a snapshot: a window the window server
// has not published yet is simply absent from it, and an absent window
// cannot be turned into the SCWindow that
// SCContentFilter.initWithDisplay:excludingWindows: needs. That exclusion
// is rule 2 in Knips.App.Border, and it is the only thing that keeps a
// *panning* frame out of the file — proven by measurement: an unexcluded
// frame that pans puts its own edges through the picture as full-width
// red lines, while an unexcluded frame that stands still never does.
// Losing it therefore costs the user Follow Mouse for the whole
// recording, which is exactly how "Follow Mouse does nothing" is
// produced.
//
// So a first snapshot without the frame in it is retried rather than
// believed. The retry costs nothing in the ordinary case, where the
// answer comes back on the first attempt.
//
// ABorderWindowID may be 0 — a display recording has no frame — and
// ABorderVisible is then False and means nothing to anybody.
function TAppController.ResolvePendingTarget(ADisplayID: UInt32;
  ABorderWindowID: Cardinal; out AIndex: Integer;
  out ABorderVisible: Boolean; out AError: string): Boolean;
var
  Content: TShareableContent;
  Window: Pointer;
  Attempt: Integer;
begin
  Result := False;
  AIndex := -1;
  ABorderVisible := False;
  AError := '';
  for Attempt := 1 to BorderVisibilityAttempts do
  begin
    try
      Content := TShareableContent.Create;
    except
      on E: EShareableContent do
      begin
        // A later attempt only exists to look for the frame again; a
        // query that worked once and then failed must not turn a good
        // answer into an aborted recording. Keep what attempt 1 found.
        if AIndex >= 0 then
          Break;
        AError := E.Message;
        Exit;
      end;
    end;
    try
      // Latch the first resolution; a display that drops out of a LATER
      // snapshot (sleep, replug) stops the retries, not the recording.
      if AIndex < 0 then
        AIndex := Content.IndexOfDisplayID(ADisplayID);
      if AIndex < 0 then
      begin
        AError := Format('display %u is not capturable', [ADisplayID]);
        Exit;
      end;
      if ABorderWindowID <> 0 then
      begin
        Window := Pointer(Content.RetainWindow(ABorderWindowID));
        if Window <> nil then
        begin
          NSObject(Window).release;
          ABorderVisible := True;
        end;
      end;
    finally
      Content.Free;
    end;
    if (ABorderWindowID = 0) or ABorderVisible then
      Break;
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

procedure TAppController.CommandToggleMicrophone;
var
  Warning: string;
begin
  if not Transition(acToggleMicrophone) then
    Exit;
  // Switching the microphone *off* is always legal; switching it on needs
  // this Mac to have microphone capture at all. The item is disabled
  // without it, so the guard only ever catches an AppKit dispatch that
  // beat a refresh — but a recording that started and then had no
  // microphone would be a much worse way to find out.
  if FMicrophone or FSupportsMicrophone then
  begin
    FMicrophone := not FMicrophone;
    StoreMicrophone;
  end;
  // The privacy grant is worth a word, and *here* is the only place it
  // can be read. This is the moment the user asks for the microphone,
  // the app is idle, and the menu is attached — so the Last error line
  // is on screen. The same warning at StartPending would be written
  // while the menu is detached (a recording is running), which is to say
  // written where nobody can see it, and it would fire again after every
  // recording whose microphone had in fact worked.
  //
  // Advisory only: measured, ScreenCaptureKit captures the microphone
  // with this status reading undecided, so it is not the gate SCK goes
  // through. What actually proves a silent track is FinishRecording's
  // sample count.
  if FMicrophone then
  begin
    Warning := MicrophoneAccessMessage(MicrophoneAccess);
    if Warning <> '' then
      RecordError(Warning);
  end;
  RefreshStatusItem;
end;

// Idle-only for the same reason as the audio submenu: the pan moves the
// stream's sourceRect, and whether the stream has one at all is decided
// when the capture starts.
procedure TAppController.CommandToggleFollowMouse;
begin
  if not Transition(acToggleFollowMouse) then
    Exit;
  FFollowMouse := not FFollowMouse;
  StoreFollowMouse;
  RefreshStatusItem;
end;

// One turn of the render's progress onto the status item. Same shape as
// the playback window's: drain what is waiting, set the title, give the
// run loop one zero-timeout slice so the CoreAnimation commit that draws
// it actually runs. Everything it dispatches is inert behind Busy.
procedure TAppController.HandleRenderProgress(AFramesDone,
  AFramesTotal: Int64);
var
  Percent: Integer;
begin
  Percent := RenderPercent(AFramesDone, AFramesTotal);
  if Percent = FRenderPercent then
    Exit;
  FRenderPercent := Percent;
  RefreshStatusItem;
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, True);
end;

function TAppController.RenderDeliverable(const ARawPath,
  ADeliverablePath: string; out AError: string): Boolean;
var
  Session: TRenderSession;
  Pool: NSAutoreleasePool;
begin
  Result := False;
  AError := '';
  FRendering := True;
  FRenderPercent := -1;
  // Detached while the render owns the thread, for the same reason the
  // GIF export detaches it: opening an NSMenu starts a tracking loop
  // inside sendEvent that does not return until the menu is dismissed,
  // and this code turns the run loop over.
  RefreshStatusItem;
  try
    Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
    try
      Session := TRenderSession.Create(ARawPath, ADeliverablePath, FEffects);
      // The app renders on EVERY stop, and a take it can apply nothing
      // to still has to end up with a deliverable beside its raw take —
      // the pair is the app's whole model. So the app asks for the copy
      // explicitly whenever its own effects come to nothing, which is
      // the same request `--effects=none` makes on the CLI.
      Session.ExplicitCopy := not EffectsAskForAnything(FEffects);
      try
        // No console under an app bundle.
        Session.Verbose := False;
        Session.OnProgress := HandleRenderProgress;
        Result := Session.Run(AError);
        // An effect that was asked for and could not be applied is not a
        // failure — the deliverable is right without it — but it is the
        // only explanation the user will get for a Zoom on Click that
        // did nothing. Note is the summary of the render's three
        // (Knips.Options.EffectNoteSummary); the menu has one slot, and
        // the log below it has all three.
        if Result and (Session.Report.Note <> '') then
        begin
          NoteError(Session.Report.Note);
          if (Session.Report.CursorNote <> '')
            and (Session.Report.CursorNote <> Session.Report.Note) then
            LogMessage('render: '
              + EffectCursorNoteLine(Session.Report.CursorNote));
          if (Session.Report.ZoomNote <> '')
            and (Session.Report.ZoomNote <> Session.Report.Note) then
            LogMessage('render: '
              + EffectZoomNoteLine(Session.Report.ZoomNote));
        end;
        // What the sidecar loader could not use, whatever the notes
        // said. The log rather than the menu slot: it is a fact about
        // the file this render read, not an explanation of an effect
        // that did not happen, and the one slot belongs to the latter.
        if Result and (Session.Report.SidecarSkippedLines > 0) then
          LogMessage('render: '
            + SidecarSkippedLinesNote(Session.Report.SidecarSkippedLines));
      finally
        Session.Free;
      end;
    finally
      Pool.release;
    end;
  finally
    FRendering := False;
    RefreshStatusItem;
  end;
end;

// The playback window owns the selection while it is open; this is where
// it becomes the default the next recording renders with. One writer per
// key, so a change to the cursor never rewrites the zoom's key with a
// value this process happened to be holding.
procedure TAppController.HandleEffectsChanged(const AEffects: TExportEffects);
begin
  if FEffects.ZoomOnClick <> AEffects.ZoomOnClick then
  begin
    FEffects.ZoomOnClick := AEffects.ZoomOnClick;
    StoreEffectZoom;
  end;
  if FEffects.Cursor <> AEffects.Cursor then
  begin
    FEffects.Cursor := AEffects.Cursor;
    StoreEffectCursor;
  end;
end;

procedure TAppController.CommandToggleEffectZoom;
begin
  if FPlayback <> nil then
    FPlayback.CommandToggleEffectZoom;
end;

procedure TAppController.CommandToggleEffectSmoothCursor;
begin
  if FPlayback <> nil then
    FPlayback.CommandToggleEffectSmoothCursor;
end;

procedure TAppController.CommandToggleEffectBigCursor;
begin
  if FPlayback <> nil then
    FPlayback.CommandToggleEffectBigCursor;
end;

// The same menu-detaching dance CommandExportGif does, and for the same
// reason: the re-export owns the main thread and drains events, so an
// attached status menu would stall it indefinitely.
procedure TAppController.CommandReexport;
begin
  if FPlayback = nil then
    Exit;
  if FStatusItem <> nil then
    FStatusItem.setMenu(nil);
  try
    FPlayback.CommandReexport;
  finally
    RefreshStatusItem;
  end;
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
  // False for the zoom, always: it is a render-time effect now, so
  // nothing here may move the capture's own rectangle for it.
  if not ResolveLiveEffects(TargetKind, FPendingHasRegion, False,
    FFollowMouse, Zoom, Follow) then
    Exit;
  if not FSession.SupportsLiveUpdate then
  begin
    // RecordError rather than LogMessage, here and below: every one of
    // these three lines says "the effect you switched on is not going to
    // happen", and the user has no other way to find that out. None of
    // them touches the state machine — the recording is fine.
    RecordError('this ScreenCaptureKit has no updateConfiguration:, so '
      + 'Follow Mouse is off for this recording');
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
      // StartPending has just recorded the DETAILED exclusion message —
      // which snapshot half failed — and this generic line must not
      // overwrite it in the menu's single Last-error slot. Log it either
      // way; put it in the menu only when the slot is free.
      if FLastError = '' then
        RecordError('Follow Mouse is off for this recording: the frame '
          + 'around the region was not excluded from the capture, and a '
          + 'region that moves would record its own frame')
      else
        LogMessage('Follow Mouse is off for this recording: the frame '
          + 'around the region was not excluded from the capture');
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
    RecordError('the recorded display has no NSScreen, so Follow Mouse '
      + 'is off for this recording');
    Exit;
  end;

  Base := FSession.BaseSourceRect;
  if FLive = nil then
    FLive := TLiveAnimator.Create;
  // The camera goes in unconditionally: it is only ridden if a dock armed
  // one, and TCameraPreview answers that question itself. A camera that
  // is off, undocked, or docked into a rectangle nothing is panning costs
  // one call per tick and no window-server traffic at all.
  FLive.Start(FSession, Border, FCamera, ScreenFrame,
    LiveRect(Base.origin.x, Base.origin.y, Base.size.width,
    Base.size.height), Zoom, Follow);
end;

// Created unscheduled and added to the *common* modes, not scheduled and
// then added again: the camera window is draggable during a recording, and
// a drag puts the run loop in NSEventTrackingRunLoopMode, where a
// default-mode-only timer stops firing — a zoom would freeze half way and
// the pointer track would have a hole in it exactly where the user was
// doing something. NSRunLoopCommonModes already includes the default mode,
// so scheduling first would register the same timer twice and fire it at
// sixty hertz.
procedure TAppController.StartRecordingTick;
begin
  StopRecordingTick;
  FWriterFailureReported := False;
  FTickTimer := NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats(
    LiveTickSeconds, FTarget, SelectorNamed(LiveTickSelector), nil, True);
  if FTickTimer <> nil then
  begin
    FTickTimer.retain;
    NSRunLoop.currentRunLoop.addTimer_forMode(FTickTimer,
      NSRunLoopCommonModes);
  end;
end;

procedure TAppController.StopRecordingTick;
begin
  if FTickTimer = nil then
    Exit;
  FTickTimer.invalidate;
  FTickTimer.release;
  FTickTimer := nil;
end;

// Stops the animator and nothing else. The tick it used to own outlives
// it now: the sidecar sampler rides the same timer and has to keep
// sampling right up to FinishCapture, which is one turn later than every
// caller of this.
procedure TAppController.StopLive;
begin
  // Every caller is on the stopping path *before* FinishCapture: the
  // animator holds the session, and a tick that arrived after the writer
  // had been finalised would be talking to a freed object.
  if FLive <> nil then
    FLive.Stop;
end;

procedure TAppController.LiveTick;
begin
  // The sidecar sample comes first, and is deliberately outside the Busy
  // guard below: an export owns the main thread and drains events to draw
  // its progress, which is how a timer can fire in the middle of one, and
  // a recording really can still be running then (the stop is refused
  // while an export holds the thread). Writing a line to a file is safe
  // there in a way that sending updateConfiguration: is not.
  if (FSession <> nil) and FSession.Capturing then
  begin
    FSession.SampleMetadata;
    // One rejected buffer fails AVAssetWriter for good. The CLI's run
    // loop breaks on this and the MCP server stops the session on it;
    // the app used to do neither, so a writer that died mid-take — a
    // full disk is the ordinary way — left the status item showing ⏺
    // for as long as the user let it, and the whole take was lost at the
    // stop. Ask for the stop the way the menu item does, so the same
    // finalisation runs and whatever reached the file is kept.
    if FSession.LiveStatistics.WriterFailed then
    begin
      if not FWriterFailureReported then
      begin
        FWriterFailureReported := True;
        RecordError('the recording failed while writing and is being '
          + 'stopped; the disk may be full. Whatever reached the file is '
          + 'being finalised');
      end;
      // Refused while an export owns the main thread, exactly as a click
      // on Stop Recording is; the next tick asks again.
      CommandStop;
      Exit;
    end;
  end;
  if Busy or (FLive = nil) then
    Exit;
  // The animator switches itself off when the session stops capturing;
  // the tick goes on until the recording is finalised.
  if not FLive.Active then
    Exit;
  FLive.Tick;
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
  LiveZoom, LiveFollow, BorderVisible: Boolean;
begin
  if FState <> asRecording then
    Exit;
  // Before every other read of the pending request, because it rewrites
  // it: a WINDOW recording becomes a region recording on the display that
  // window is on, panned onto it by the poll, whenever there is anything
  // to be gained from it — a camera picture-in-picture to composite in,
  // or an effect for the render to apply. WindowTakeNeedsCompositing is
  // that question and carries the trade; a window take that wants
  // neither keeps ScreenCaptureKit's desktop-independent capture, which
  // is the cleaner picture.
  //
  // Said out loud, both ways. This one decision settles whether the take
  // is editable afterwards or is its own deliverable for ever, it is
  // taken from state the user cannot see all of at once (the effect
  // defaults plus whether the camera happens to be up), and it used to
  // leave no trace at all when it went the ordinary way — so a window
  // take that came back un-rendered looked like a bug in the render.
  if FPendingWindowID <> 0 then
  begin
    if WindowTakeNeedsCompositing(FEffects,
      (FCamera <> nil) and FCamera.Visible) then
    begin
      if FCameraRide.CompositeWindowForPending(FPendingWindowID,
        FPendingDisplayID, FPendingHasRegion, FPendingRegion) then
      begin
        LogMessage('recording this window through a rectangle of its '
          + 'display so the effects (and the camera, if it is up) reach '
          + 'the file; the take is raw and can be re-rendered');
        // And once per session where somebody will actually see it. The
        // log is not a user interface; the Last-error slot is the one
        // line this app has, and a window take that comes back with a
        // notification baked into it needs the sentence BEFORE it
        // happens, not in a file nobody opens. Once, because it is a
        // standing consequence of a setting rather than an event: said
        // on every take it would be noise, and noise is what gets
        // ignored.
        if not FSaidWindowCompositing then
        begin
          FSaidWindowCompositing := True;
          NoteError(WindowCompositingNote(FEffects,
            (FCamera <> nil) and FCamera.Visible));
        end;
      end
      else
        // A RecordError and not a log line: the user asked for effects
        // and is about to get a take that can never be given any. The
        // recording is still worth making, so this is not a Fail.
        RecordError('the recorded window''s frame or display could not '
          + 'be resolved, so the effects (and the camera, if it is up) '
          + 'will not reach the file; recording the window on its own '
          + 'instead, which cannot be re-rendered afterwards');
    end
    else
      LogMessage('recording this window on its own: nothing was asked '
        + 'for that would have to be composited in, so the take keeps '
        + 'ScreenCaptureKit''s desktop-independent capture — the '
        + 'cleaner picture, and the one kind of take nothing can be '
        + 'drawn into afterwards');
  end;
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
  // The frame goes up *before* the ScreenCaptureKit query rather than
  // after it, and the order is the fix for a real failure rather than
  // tidiness. Its window id is what StartCapture hands to
  // initWithDisplay:excludingWindows:, and the framework can only give
  // out an SCWindow for a window it has already seen. Putting the frame
  // up first means a whole query — tens of milliseconds, and a genuine
  // round trip through the window server — passes before the snapshot
  // that has to contain it is taken. ResolvePendingTarget then confirms
  // that it does.
  BorderWindowID := ShowBorderForPending;
  BorderVisible := False;
  if (FPendingDisplayID <> 0)
    and not ResolvePendingTarget(FPendingDisplayID, BorderWindowID,
    DisplayIndex, BorderVisible, Error) then
  begin
    HideBorder;
    Transition(acCaptureFailed);
    RecordError(Error);
    RefreshStatusItem;
    Exit;
  end;
  Options := DefaultRecordingOptions;
  // Known gap, accepted: this index was resolved against
  // ResolvePendingTarget's snapshot, and StartCapture resolves it again
  // on a fresh one ~100 ms later. An index that goes OUT of range in
  // between fails cleanly ("display N is not capturable"); one that
  // stays in range but now names a different display — displays [A,B],
  // A unplugged in that window — would record the wrong screen. Carrying
  // FPendingDisplayID through TRecordingOptions and re-resolving by ID
  // inside the session would close it; not worth the plumbing until a
  // display is ever hot-unplugged mid-click.
  Options.DisplayIndex := DisplayIndex;
  Options.HasRegion := FPendingHasRegion;
  Options.Region := FPendingRegion;
  if FPendingWindowID <> 0 then
  begin
    Options.TargetKind := ctkWindow;
    Options.WindowID := FPendingWindowID;
  end;
  Options.AudioMode := AudioModeFromToggles(FSystemAudio, FMicrophone);
  // Follow Mouse moves the stream's sourceRect, so the capture has to be
  // started with one even for a whole display, which otherwise goes
  // without. Asked for only when the effect is actually going to apply —
  // ResolveLiveEffects is the single place that decides, and StartLive
  // asks it again for the same answer.
  if FCameraRide.CompositedWindowID <> 0 then
  begin
    // A window recording gets neither effect — ResolveLiveEffects says so
    // for ctkWindow and the answer does not change because the capture
    // underneath is now a display. The source rectangle still has to be
    // live, because the poll pans it as the window moves; it simply has
    // one owner instead of two.
    LiveZoom := False;
    LiveFollow := False;
    Options.LiveSourceRect := True;
    // Nothing animates this one, but the poll pans the source rectangle
    // onto the window for the whole take, so the framing is every bit as
    // baked as a Follow Mouse take's.
    Options.LiveWindowFollow := True;
  end
  else
  begin
    // Zoom on Click is deliberately False here, not FEffects.ZoomOnClick:
    // it is a render-time effect now, and a capture that zoomed would
    // bake the crop into the pixels where nothing could take it out
    // again. Follow Mouse is the one live effect left, because a pan
    // decides which pixels are read off the screen at all.
    ResolveLiveEffects(Options.TargetKind, Options.HasRegion, False,
      FFollowMouse, LiveZoom, LiveFollow);
    Options.LiveSourceRect := LiveZoom or LiveFollow;
  end;
  // The RESOLVED answers, not the preferences: what goes into the event
  // sidecar's header is what the capture actually did, because that is
  // what decides which effects a later render can still apply. Both are
  // False for a zoom now — the app never runs one live — and
  // LiveFollowMouse is the one that can still be True.
  Options.LiveZoomOnClick := LiveZoom;
  Options.LiveFollowMouse := LiveFollow;
  // **Every take the app records is raw.** No pointer in the pixels, no
  // zoom in the framing: the movie is what the screen looked like, and
  // everything a viewer is meant to see is put in afterwards by the
  // render (Knips.Export.Render) from the event sidecar. That is what
  // makes the effects changeable for as long as the raw take is kept,
  // and it is why Big Cursor is never asked for here — the enlarged
  // pointer is drawn at render time now, from the same track.
  //
  // Resolved against the target the capture is actually opening, which
  // for a composited window recording is a DISPLAY: the pointer's screen
  // position maps onto its frames exactly, through the per-sample source
  // rectangles the poll writes into the sidecar, so the take is raw and
  // renderable like any other region take.
  //
  // This used to be pinned to ctkWindow so that *Record Window* meant
  // the same thing whether or not the camera happened to be up. It means
  // the same thing still — the decision is now
  // WindowTakeNeedsCompositing's, taken from the effects the user chose
  // rather than from the camera — and it is the answer the user asked
  // for rather than a refusal.
  Options.BigCursor := False;
  Options.SmoothCursor := ResolveSmoothCursor(Options.TargetKind, True);
  // A desktop-independent window capture is the one target that cannot
  // be raw: its frames have no fixed relationship to the screen the
  // pointer is measured against, so the pointer cannot be drawn back
  // into them and the system one has to stay. Reached only when the user
  // asked for no effects at all, or when the composite could not be set
  // up; said out loud either way, because it is the one case where the
  // deliverable is the take.
  if not Options.SmoothCursor then
    LogMessage('this recording keeps the system pointer and takes no '
      + 'effects: a desktop-independent window capture has no fixed '
      + 'relationship to the screen the pointer is measured against, so '
      + 'nothing can be drawn back in afterwards');
  // The frame is stroked outside the region either way, so a failed
  // exclusion still cannot reach the file while the region stands still;
  // it is a *moving* region that needs this list to have worked.
  if BorderWindowID <> 0 then
  begin
    SetLength(Options.ExcludedWindowIDs, 1);
    Options.ExcludedWindowIDs[0] := BorderWindowID;
  end;
  if not PrepareOutputPath(FPendingDeliverablePath, Error) then
  begin
    HideBorder;
    Transition(acCaptureFailed);
    RecordError(Error);
    RefreshStatusItem;
    Exit;
  end;
  // The capture writes the RAW take; the render writes the deliverable
  // beside it on the stop. The deliverable keeps the name the user will
  // see in Finder, and the raw take takes the suffix — see
  // Knips.Options.RawTakePathFor.
  //
  // Unless there is nothing to render, in which case the take IS the
  // deliverable and is written straight to its own name. That is a
  // window recording: its frames have no fixed relationship to the
  // screen its pointer was measured against, so the pointer cannot be
  // drawn back and the framing cannot be re-cropped — and splitting it
  // would leave two byte-identical movies and two sidecars on disk for
  // ever, which is a cost with no benefit at all. Options.SmoothCursor
  // is exactly that question already answered: ResolveSmoothCursor said
  // no for the one target that cannot be raw. FinishRecording reads the
  // same fact back off the path (IsRawTakePath) and skips the render.
  if Options.SmoothCursor then
    Options.OutputPath := RawTakePathFor(FPendingDeliverablePath)
  else
    Options.OutputPath := FPendingDeliverablePath;
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
  FCameraRide.DockCameraForPending(FPendingWindowID, FPendingDisplayID,
    FPendingHasRegion, FPendingRegion);

  // Nothing should be animating or sampling a session that is about to be
  // freed, and both hold a bare pointer to it.
  StopRecordingTick;
  StopLive;
  FreeAndNil(FSession);
  FSession := TRecordingSession.Create(Options);
  if not FSession.StartCapture(Error) then
  begin
    HideBorder;
    FCameraRide.UndockCamera;
    FreeAndNil(FSession);
    Transition(acCaptureFailed);
    // One shot: a denied Screen Recording grant fails the same way every
    // time, so the app goes back to idle and waits for the user.
    RecordError(Error);
    RefreshStatusItem;
    Exit;
  end;

  // The recording's own clock, started the moment the capture is running
  // and before anything that could fail: the event sidecar's pointer track
  // begins here, and every recording has one whether or not it has an
  // effect to animate.
  StartRecordingTick;

  // Reachable only from the CLI's own --big-cursor path today — the app
  // never asks the recorder to draw a pointer any more — and kept
  // because the session still can, and a sprite that could not be made
  // must not be silent if it ever is.
  if FSession.Report.BigCursorError <> '' then
    RecordError('Big Cursor is off for this recording: '
      + FSession.Report.BigCursorError);

  // The frame is drawn outside the recorded rectangle either way, so a
  // window ScreenCaptureKit did not resolve is not a failure — but it is
  // the first thing worth knowing if a border ever does turn up in a
  // file, and silence would make that unfindable.
  if Length(Options.ExcludedWindowIDs) > FSession.Report.ExcludedWindows then
  begin
    // RecordError, not LogMessage — but only when a live effect asked
    // for the exclusion: this is the one thing that turns Follow Mouse
    // off underneath a user who asked for it, and a message the user
    // cannot see is how that stayed a mystery. For a still recording the
    // frame is drawn outside the rectangle and nothing is wrong, so the
    // menu stays quiet and the line goes to the log alone. Never a Fail
    // either way.
    if LiveFollow then
      RecordError(Format('the recording frame was not excluded from the '
        + 'capture (%d of %d windows resolved%s); the frame is drawn '
        + 'outside the recorded region, so a still recording is unaffected',
        [FSession.Report.ExcludedWindows, Length(Options.ExcludedWindowIDs),
        BorderVisibleNote(BorderVisible)]))
    else
      LogMessage(Format('the recording frame was not excluded from the '
        + 'capture (%d of %d windows resolved%s); the frame is drawn '
        + 'outside the recorded region, so the file is unaffected',
        [FSession.Report.ExcludedWindows, Length(Options.ExcludedWindowIDs),
        BorderVisibleNote(BorderVisible)]));
  end;

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
  if FCameraRide.CompositedWindowID <> 0 then
    // The poll is the composited recording's only animator, and it is
    // started here rather than by the dock: it has to run even when the
    // camera is undocked or hidden mid-take, because it is what keeps
    // the capture on the window.
    FCameraRide.Start(FCameraRide.CompositedWindowID)
  else
    StartLive(BorderWindowID, (BorderWindowID <> 0)
      and WindowIDRequested(Options.ExcludedWindowIDs, BorderWindowID)
      and (FSession.Report.ExcludedWindows
      = Length(Options.ExcludedWindowIDs)));

  // Only once the capture is really running, so a repeat of a region that
  // no longer resolves does not become the region to repeat.
  //
  // And never for a COMPOSITED window recording. That path sets
  // FPendingHasRegion — it is a region capture underneath — but the
  // rectangle is a window's frame, not something the user drew, so
  // storing it would make *Record Last Region* repeat a rectangle nobody
  // chose, and would quietly overwrite the region they did choose. The
  // window recording is not repeatable by that command in the first
  // place: the window is named by id in a submenu that is rebuilt every
  // time it opens.
  if FPendingHasRegion and (FPendingDisplayID <> 0)
    and (FCameraRide.CompositedWindowID = 0) then
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
  Error, Path, RawPath, Deliverable, Silence, PlaybackNote: string;
  Finished, MicrophoneAsked, Rendered: Boolean;
  PixelWidth, PixelHeight, Scale: Integer;
begin
  PlaybackNote := '';
  if FSession = nil then
    Exit;
  // Idempotent, and the backstop for the paths that do not come through
  // CommandStop — Quit, above all, which finalises inline. The tick goes
  // with it: FinishCapture takes the recording's last pointer sample
  // itself, and everything after that pumps the run loop for the writer's
  // completion handler, which is no place for a timer to fire.
  StopRecordingTick;
  StopLive;
  // The frame goes first: it belongs to the recording, not to the
  // finalisation, and finishing the writer pumps the run loop.
  HideBorder;
  RawPath := FSession.Report.OutputPath;
  // The take is raw; the deliverable is what the render makes of it. A
  // recording whose output path is not a raw take at all — nothing
  // produces one today, but a future path might — is its own deliverable
  // and simply skips the render.
  Deliverable := FPendingDeliverablePath;
  if (Deliverable = '') or not IsRawTakePath(RawPath) then
  begin
    Deliverable := RawPath;
    RawPath := '';
  end;
  // Path is assigned where it is USED, after the render has decided
  // which file the playback window opens on (`Path := Deliverable`
  // below). It used to be seeded with the raw take's path here as well,
  // and nothing between the two reads it — a dead store that read as if
  // the playback window fell back to the take.
  PixelWidth := FSession.Report.PixelWidth;
  PixelHeight := FSession.Report.PixelHeight;
  // Pixels per point, and so the divisor the one-click GIF export sizes
  // itself by: at 2x it turns the export into an exact halving.
  Scale := FSession.Report.Scale;
  MicrophoneAsked := AudioModeCapturesMicrophone(FSession.Report.AudioMode);
  Finished := FSession.FinishCapture(Error);
  if not Finished then
    NoteError(Error);
  // One line per take about the idle heartbeat. The menu-bar app is the
  // front end most takes come through and it shows the user no counters
  // at all, so the log is the only place a refusal — the one number that
  // would say the heartbeat had stopped working — could ever be seen.
  // Written whatever the numbers are, because "0 refused" on a still take
  // is the reassuring reading and a log that only speaks up when things
  // are wrong cannot be checked. See docs/architecture.md, "The idle
  // heartbeat".
  if Finished then
    LogMessage(Format('idle heartbeat: %d of %d frames repeated, '
      + '%d refused, %d frames retimed; the movie spans %.3f s of a '
      + '%.3f s take', [FSession.Report.HeartbeatFrames,
      FSession.Report.AppendedFrames, FSession.Report.HeartbeatRefused,
      FSession.Report.RetimedFrames, FSession.Report.DurationSeconds,
      FSession.Report.StopHostSeconds
      - FSession.Report.AnchorHostSeconds]));
  // The backstop for the microphone. The grant is checked before the
  // capture opens, but a grant can be revoked mid-recording, a device can
  // be unplugged, and a future ScreenCaptureKit is free to refuse the
  // microphone in ways nothing here anticipates — and every one of those
  // produces the same thing: a finished file whose second audio track is
  // silence, with no error anywhere. Counting what actually arrived is
  // the one check that does not depend on knowing how the failure
  // happened. Never a Fail: the video is fine and on disk.
  // Silence on a track that was on. Separate from the count check below,
  // which is about nothing arriving at all: this one is about buffers
  // that arrived and carried no sound, which points at a muted source
  // rather than at a permission.
  if Finished then
  begin
    // Accumulated, never reassigned: a take whose system audio was silent
    // and whose microphone was fine used to reach the playback title with
    // the microphone's empty answer, and say nothing at all.
    Silence := AudioSilenceWarning('system audio',
      AudioModeCapturesSystem(FSession.Report.AudioMode),
      FSession.Report.AppendedAudioSamples, FSession.Report.AudioInspected,
      FSession.Report.AudioPeak);
    if Silence <> '' then
    begin
      NoteError(Silence);
      PlaybackNote := 'no system audio';
    end;
    // Only the silence case here; the "nothing arrived" case for the
    // microphone is the older, more detailed check below.
    if FSession.Report.AppendedMicrophoneSamples > 0 then
    begin
      Silence := AudioSilenceWarning('the microphone', MicrophoneAsked,
        FSession.Report.AppendedMicrophoneSamples,
        FSession.Report.MicrophoneInspected,
        FSession.Report.MicrophonePeak);
      if Silence <> '' then
      begin
        NoteError(Silence);
        if PlaybackNote = '' then
          PlaybackNote := 'no mic audio'
        else
          PlaybackNote := 'no audio';
      end;
    end;
    // The seam between Big Cursor and the idle heartbeat: a take of a
    // still screen is mostly repeated frames, and a repeat carries the
    // enlarged pointer where it was when that frame was captured. The
    // file is fine and nothing failed, so this is a note like the
    // silence above — but a still pointer looks like a bug and deserves
    // its own sentence. See Knips.Options.BigCursorIdleWarning.
    Silence := BigCursorIdleWarning(FSession.Report.BigCursor,
      FSession.Report.CursorFrames, FSession.Report.HeartbeatFrames,
      FSession.Report.AppendedFrames);
    if Silence <> '' then
      NoteError(Silence);
    // A stop ScreenCaptureKit never confirmed. To the log rather than
    // the menu: the take is on disk and playable, and the value of this
    // is that a take which comes back short has an explanation sitting
    // beside it.
    if FSession.Report.StopUnconfirmed then
      LogMessage('ScreenCaptureKit did not confirm the stop; the movie '
        + 'was finalised anyway and may be a frame or two short');
  end;
  if Finished and MicrophoneAsked
    and (FSession.Report.AppendedMicrophoneSamples = 0) then
  begin
    // Nothing was appended — but *why* decides what to tell the user, and
    // pointing at the privacy grant when the buffers were simply thrown
    // away would send them to System Settings for nothing. A take short
    // enough that every microphone buffer arrived before the first video
    // frame (they have no timeline to sit on and are counted as dropped
    // early), or one where the writer was not ready, is a timing story
    // and not a permission one.
    if (FSession.Report.DroppedMicrophoneEarly = 0)
      and (FSession.Report.DroppedMicrophoneStalled = 0)
      and (FSession.Report.FailedMicrophoneAppends = 0) then
      NoteError('the microphone delivered no audio for this recording — '
        + 'check System Settings › Privacy & Security › Microphone and the '
        + 'input device')
    else
      NoteError(Format('no microphone audio reached this recording: '
        + '%d samples arrived before the first video frame, %d while the '
        + 'writer was not ready, %d failed to append',
        [FSession.Report.DroppedMicrophoneEarly,
        FSession.Report.DroppedMicrophoneStalled,
        FSession.Report.FailedMicrophoneAppends]));
  end;
  // AFTER FinishCapture, never before. The undock eases the camera back
  // over a fifth of a second, and until FinishCapture returns the stream
  // is still running and the writer is still appending — the border can
  // go early because it is a static window being removed, but a window
  // *moving* would be in the last frames of every docked take. That is
  // the very artefact DockTo avoids by moving in one step at the start.
  // FinishCapture stops the stream before it finalises the writer
  // (Knips.Recording.FinishCapture, "Stream first, then writer"), so by
  // here there is nothing left for the movement to land in.
  FCameraRide.UndockCamera;
  FreeAndNil(FSession);
  RefreshStatusItem;
  // The render, and it is what turns the raw take into the file the user
  // asked for: the pointer drawn back, the zoom applied, the audio copied
  // across untouched. It runs on the main thread and takes seconds, so it
  // holds the Busy lockout and writes its progress onto the status item.
  //
  // A render that fails is not a lost recording: the raw take is on disk
  // and is a perfectly good movie (with no pointer in it), so the failure
  // is reported and the playback window opens on the take instead.
  //
  // Not on the way out. Quit finalises an open recording inline because
  // terminate: never comes back, and a render is seconds of work with a
  // dead status item in front of it — the app would look hung at exactly
  // the moment the user asked it to go away. The raw take and its sidecar
  // are on disk and `knips render` turns them into the deliverable
  // whenever anybody wants it, so nothing is lost by not doing it now.
  // AShowPlayback is the same flag: it is False for exactly the paths
  // that have nobody to show anything to.
  Rendered := False;
  if AShowPlayback and Finished and (RawPath <> '') then
  begin
    Rendered := RenderDeliverable(RawPath, Deliverable, Error);
    if not Rendered then
    begin
      NoteError('the deliverable could not be rendered (' + Error
        + '); the raw take is at ' + RawPath);
      Deliverable := RawPath;
    end;
  end;
  if not AShowPlayback and Finished and (RawPath <> '') then
    LogMessage('quitting with a take still to render; the raw take is at '
      + RawPath + ' and `knips render --in=' + RawPath + '` will finish it');
  Path := Deliverable;
  if not Rendered then
    // Nothing to re-export from: the window opens on the raw take
    // itself, and its Effects control says why it is off.
    RawPath := '';
  // Playing the clip back is the "done" signal, and the window is where
  // the GIF export lives; a window that cannot be made falls back to
  // revealing the file in Finder. On the way out there is no signal to
  // give: Quit finalises the file and terminates, and a window (or a
  // Finder window) flashing up on the last turn before terminate: is
  // noise, not information.
  if AShowPlayback and Finished and (Path <> '') then
  begin
    ShowPlayback(Path, RawPath, PixelWidth, PixelHeight, Scale);
    // The playback window has no message area of its own, and this is the
    // one moment the user is looking straight at the take: a silent track
    // goes on the window's title, beside the file name, where it cannot
    // be missed and costs no layout.
    if (PlaybackNote <> '') and (FPlayback <> nil) then
      FPlayback.SetTitleNote(PlaybackNote);
  end;
end;

function TAppController.RecordingAudioNote: string;
var
  Statistics: TMovieWriterStatistics;
  System, Microphone: string;
begin
  Result := '';
  if (FSession = nil) or not FSession.Capturing then
    Exit;
  Statistics := FSession.LiveStatistics;
  System := AudioLevelNote(AudioModeCapturesSystem(FSession.Report.AudioMode),
    Statistics.AppendedAudioSamples, Statistics.AudioInspected,
    Statistics.AudioPeak);
  Microphone := AudioLevelNote(
    AudioModeCapturesMicrophone(FSession.Report.AudioMode),
    Statistics.AppendedMicrophoneSamples, Statistics.MicrophoneInspected,
    Statistics.MicrophonePeak);
  if (System = '') and (Microphone = '') then
    Exit;
  if System = '' then
    Result := ' — mic: ' + Microphone
  else if Microphone = '' then
    Result := ' — audio: ' + System
  else
    Result := ' — audio: ' + System + ', mic: ' + Microphone;
end;

procedure TAppController.RecoverUnfinishedTakes;
var
  Takes: TRecoveredTakes;
  Summary: string;
  I, Recovered, Renderable, Swept: Integer;
begin
  try
    Recovered := RecoverOrphanedTakes(RecordingsDirectory(GetUserDir),
      Takes, Swept);
    // To the log whatever happened. A scratch file left behind is a
    // render that died, and the app is where renders run — this is the
    // only place that would ever notice a directory quietly filling up
    // with them.
    if Swept > 0 then
      LogMessage(Format('%d leftover render scratch file(s) removed',
        [Swept]));
    if Recovered = 0 then
      Exit;
  except
    // Never a reason to refuse to launch: the app's job is recording, and
    // tidying up after a crash is a courtesy.
    on E: Exception do
    begin
      LogMessage('recovering an unfinished recording: ' + E.Message);
      Exit;
    end;
  end;
  Summary := DescribeRecoveredTakes(Takes);
  if Summary <> '' then
    LogMessage(Summary);
  // How many of them a render could still do something with. A recovered
  // take is left RAW — the process died before the render — so the file
  // the user gets back is `…-raw.mp4`, and until this line the menu gave
  // them the raw name and no route from it to a deliverable. Nothing is
  // rendered here: a launch is the wrong moment to spend minutes on a
  // file nobody has asked for.
  Renderable := 0;
  for I := 0 to High(Takes) do
    if TakeCanStillBeRendered(Takes[I].SidecarPath) then
      Inc(Renderable);
  // RecordError, not LogMessage alone: a recording the user thought they
  // had lost is exactly the thing they should be told about, and the menu
  // is the only place this app can tell them.
  RecordError(RecoveredTakesNote(Length(Takes), Renderable,
    ExtractFileName(Takes[0].MoviePath)));
end;

// Whether an effect could still be applied to the take this sidecar
// belongs to — the same question `take_info` answers, asked here so the
// recovery note can say whether Re-export would do anything.
function TAppController.TakeCanStillBeRendered(
  const ASidecarPath: string): Boolean;
var
  Log: TSidecarLog;
  Available: TSidecarEffectAvailability;
  Error: string;
begin
  Result := False;
  Log := TSidecarLog.Create;
  try
    if not Log.LoadFromFile(ASidecarPath, Error) then
      Exit;
    Available := AvailableExportEffects(Log);
    Result := Available.CanDrawCursor or Available.CanZoomOnClick;
  finally
    Log.Free;
  end;
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

// The third camera setting, and outside the transition table like the
// other two. Switching it does not touch the capture session's *inputs*
// — it adds or removes an AVCaptureVideoDataOutput on a session that
// keeps running — so there is no warm-up, no permission path, and
// nothing a live recording could notice beyond the picture in the window
// it is already capturing.
procedure TAppController.CommandToggleCameraBlur;
begin
  // Not while an export owns the main thread: starting the pipeline
  // builds a CIContext and loads Vision's model, which is AppKit-adjacent
  // work measured in seconds on the first run.
  if Busy or (FCamera = nil) then
    Exit;
  if not CameraBlurSupported then
  begin
    HandleCameraError('background blur needs Vision and CoreImage, which '
      + 'this Mac does not have');
    Exit;
  end;
  FCamera.BlurEnabled := not FCamera.BlurEnabled;
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
  // An export or a render has the main thread and is only reachable here
  // because it turns the run loop over to draw its progress. Tearing the
  // process down underneath it would leave a half-written file; the user
  // gets a reason and can quit again when it is done.
  if Busy then
  begin
    if FRendering then
      RecordError('the recording is still being rendered; quit once it '
        + 'has finished')
    else
      RecordError('a GIF export is running; quit once it has finished');
    RefreshStatusItem;
    Exit;
  end;
  // The chord goes back to the system before anything else, so a stray
  // ⌘⇧2 landing between here and terminate: cannot reach a controller
  // that is half way out. terminate: does not return, so there is no
  // later moment to do this in — the destructor never runs.
  if FHotKey <> nil then
    FHotKey.Remove;
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

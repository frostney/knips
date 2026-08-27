unit Knips.App.State;

// The menu-bar app's state machine and the pure decisions around it:
// which command is legal in which state, what the status item reads, where
// a recording is written, and how a dragged rectangle becomes a region.
//
// Everything here is platform-neutral and unit-tested; Knips.App and
// Knips.App.Overlay hold the Cocoa objects and call into this unit for
// every decision that does not need a framework.

{$I Knips.inc}

interface

uses
  SysUtils,

  Knips.Options;

const
  // The one-click export's sendable-size cap for scale-1 recordings,
  // where no integer reduction exists to justify the full width.
  MaxAppGifWidth = 800;
  // Menu-bar glyphs. Both are drawn as the status item's plain title, so
  // they inherit the menu bar's foreground colour in light and dark mode.
  IdleGlyph = '◉';
  RecordingGlyph = '⏺';
  // ~/Movies/knips/knips-YYYYMMDD-HHMMSS.mp4
  MoviesFolderName = 'Movies';
  RecordingsFolderName = 'knips';
  RecordingFilePrefix = 'knips-';
  RecordingTimestampFormat = 'yyyymmdd-hhnnss';
  RecordingFileExtension = '.mp4';
  // Longer messages are elided in the menu; the full text goes to NSLog.
  MaxErrorTitleLength = 60;
  ErrorTitlePrefix = 'Last error: ';
  // The GIF a recording exports to sits beside it, under the same name.
  GifFileExtension = '.gif';
  // What the "Export as GIF…" button asks for. The CLI's own default
  // (the movie's own width) is the right answer for a hand-written
  // command and the wrong one for a one-click button: a Retina region
  // is captured at two pixels per point, and a GIF at that width is
  // both enormous and, at 256 colours, no sharper for it.
  AppGifFramesPerSecond = 20;
  // How much of the export's progress the palette pass is worth. It
  // reads every frame but only resamples every Nth, so it is the cheaper
  // of the two passes over the movie.
  PaletteProgressPercent = 25;
  // "Application — Window title", elided to keep the menu narrow.
  WindowMenuSeparator = ' — ';
  MaxWindowMenuTitleLength = 60;
  // Enough to find the window you meant, few enough to stay a menu.
  MaxWindowMenuEntries = 20;
  // Points. Below this a window is a tooltip, a shadow helper, or some
  // other thing nobody asked to record.
  MinRecordableWindowSize = 32;
  // Ordinary application windows; the menu bar, the Dock, and overlays
  // (this app's own included) sit on other layers.
  RecordableWindowLayer = 0;
  // Points. Larger than any display Apple ships, and the ceiling on
  // anything read back out of NSUserDefaults, which `defaults write` can
  // put anything at all into.
  MaxStoredRegionExtent = 32768;
  ExportingTitlePrefix = 'Exporting… ';

  // The camera picture-in-picture window. Points, not pixels: the window
  // is placed in screen coordinates and the layer scales itself.
  CameraWindowWidth = 240;
  CameraWindowHeight = 180;
  // The circular shape's window is *square*, and that is the whole of it:
  // a disc needs equal sides or it is an ellipse. Aspect-fill then crops
  // the camera's centre into it, exactly as it already crops a 16:9 feed
  // into the 4:3 rectangle. The side is the rectangle's height, so
  // switching shapes reads as a crop rather than a resize.
  CameraCircleSide = CameraWindowHeight;
  // Inset from the bottom-right corner of the main screen's visible frame
  // (so the Dock does not sit on top of the first placement), and the
  // same inset a released drag snaps to, and the same inset the window
  // takes from the edge of a region it is docked into.
  CameraWindowMargin = 24;
  CameraCornerRadius = 8;
  // How far the window has to have travelled before a released drag is
  // treated as a drag at all. Without it a bare *click* on the picture
  // snaps a window that was deliberately placed somewhere else — after a
  // shape change re-centred it, or on a position restored from before
  // snapping existed — and a click that teleports the window is a bug
  // report. Points, and generous: nobody drags two points on purpose.
  CameraDragThreshold = 3;
  // The snap ease: how many steps the window takes to travel to its
  // corner. The step *rate* is the camera unit's business (it owns the
  // timer); the count is here because the curve is.
  CameraSnapSteps = 12;
  // A restored position has to leave at least this much of the window on
  // a screen's *visible* frame, or it is thrown away — the display it was
  // dragged onto may be gone since the last launch, and a position under
  // the Dock is unreachable because the camera window floats at level 3
  // while the Dock sits at 20.
  MinVisibleCameraExtent = 40;
  // One stable title with a checkmark, not a verb that flips: "Hide
  // Camera ✓" reads as a contradiction, and a checked item already says
  // which way the toggle is.
  CameraMenuTitle = 'Camera';
  // The shape switch is a checkbox for the same reason: "Camera Shape:
  // Circle" has to be read twice to work out whether it *is* a circle or
  // would *become* one, where a checkmark next to one stable noun says it
  // once. Circle is the odd shape, so it is the one the box is named
  // after; unchecked is the rectangle the camera has always been.
  CircularCameraMenuTitle = 'Circular Camera';
  // NSControlStateValueOn / Off (NSCell.h). Spelled out rather than taken
  // from CocoaAll, which is where the wrong NSWindowLevel values live.
  MenuItemStateOn = 1;
  MenuItemStateOff = 0;
  // NSUserDefaults keys. Prefixed because a shell-run binary shares the
  // defaults domain with whatever launched it.
  CameraVisibleDefaultsKey = 'KnipsCameraVisible';
  CameraOriginXDefaultsKey = 'KnipsCameraOriginX';
  CameraOriginYDefaultsKey = 'KnipsCameraOriginY';
  CameraShapeDefaultsKey = 'KnipsCameraShape';

  // The two live recording effects. Both off by default, both
  // remembered, both checkmarks rather than verbs — the same shape as
  // the Audio sources and Camera.
  //
  // "Follow Mouse (region)" carries its qualifier in the title because
  // the state machine cannot express it: whether a recording is a region
  // or a whole display is not known until the command that starts it
  // runs, so the item cannot be greyed out ahead of time. What actually
  // applies to a given recording is decided by
  // Knips.Recording.LiveMath.ResolveLiveEffects.
  ZoomOnClickMenuTitle = 'Zoom on Click';
  FollowMouseMenuTitle = 'Follow Mouse (region)';
  ZoomOnClickDefaultsKey = 'KnipsZoomOnClick';
  FollowMouseDefaultsKey = 'KnipsFollowMouse';

  // The Audio submenu: two independent checkboxes, System Audio and
  // Microphone, in the same shape Record System Audio always had and the
  // same shape as Zoom on Click and Follow Mouse. They live behind one
  // *Audio* item rather than loose in the root menu because between them
  // they are one setting — what the recording listens to — and a submenu
  // says that where two adjacent lines in a list of nine do not.
  //
  // One checkbox was a regression in experience rather than a bug: the
  // recorder has captured the microphone since the CLI grew --audio=mic,
  // and the app offered exactly one of the four modes — so a user who
  // spoke into a take got silence and reasonably concluded that "it
  // doesn't record audio". Two checkboxes offer all four: neither ticked
  // is none, one is that one, both is both. There is nothing to pick in a
  // radio group that these two do not say more plainly.
  AudioMenuTitle = 'Audio';
  SystemAudioMenuTitle = 'System Audio';
  MicrophoneMenuTitle = 'Microphone';
  // Appended to the microphone item where this macOS has no
  // SCStreamConfiguration.captureMicrophone (it is macOS 15+, and the
  // project floor is 13). A disabled item that does not say why is a
  // support question.
  NoMicrophoneSuffix = ' — needs macOS 15';
  // One key per checkbox, and never one procedure writing both — the
  // reason is the cross-write incident recorded under "Each toggle writes
  // its own key" in docs/architecture.md.
  //
  // Migration is one-way and consults the old key only where the new one
  // is absent, so an upgrade keeps the box the user had ticked. The old
  // key is left where it is rather than deleted: `defaults` is a public
  // interface and a downgrade should still find it.
  SystemAudioDefaultsKey = 'KnipsAudioSystem';
  MicrophoneDefaultsKey = 'KnipsAudioMicrophone';
  LegacySystemAudioDefaultsKey = 'KnipsRecordSystemAudio';

  // The global stop hotkey, ⌘⇧2 (Knips.App.Hotkey registers it with
  // Carbon; this is only what the Stop Recording item *shows*). The key
  // equivalent has to be the lowercase character AppKit draws, and the
  // Shift in the modifier mask is what makes it read as ⌘⇧2.
  StopHotKeyKeyEquivalent = '2';
  // Carbon's own virtual key code and modifier bits for the same chord,
  // kept beside the display string so the two can never drift apart.
  // Verified against FPC 3.2.2's univint: kVK_ANSI_2 = 19, cmdKey = 256,
  // shiftKey = 512 (Events.pas / MacTypes; read back at run time by the
  // hotkey unit's own probe line).
  StopHotKeyVirtualCode = 19;
  StopHotKeyCarbonModifiers = 256 or 512;
  // What the menu, the log and the docs call it.
  StopHotKeyDisplay = '⌘⇧2';

  // Points. Below this the docked camera is already where the rectangle
  // it rides wants it, and moving a window is a trip to the window
  // server — the same reasoning as the border's BorderMoveEpsilon.
  CameraRideEpsilon = 0.5;

type
  // A window origin in AppKit's screen coordinates: bottom-left origin,
  // y growing upwards, the same space NSWindow.frame lives in. Nothing
  // here is flipped — unlike a capture region, the camera window is only
  // ever handed back to AppKit.
  TCameraOrigin = record
    X: Double;
    Y: Double;
  end;

  // What the camera window looks like. The rectangle is the original
  // 240x180; the circle is a square window with a half-side corner
  // radius, which is a disc and not a rounded square.
  TCameraShape = (csRectangle, csCircle);

  TCameraSize = record
    Width: Double;
    Height: Double;
  end;

  // A rectangle in the *same* space as TCameraOrigin — AppKit's global,
  // bottom-left screen points. Two things arrive as one: a screen's
  // visibleFrame, and the region a recording has just started on (which
  // reaches this unit already flipped, by RegionScreenRect below).
  TCameraRect = record
    X: Double;
    Y: Double;
    Width: Double;
    Height: Double;
  end;

  TAppState = (asIdle, asSelecting, asRecording);

  TAppCommand = (
    acRecordRegion,       // idle -> selecting: show the overlay
    acRecordDisplay,      // idle -> recording: whole main display
    // idle -> recording: one window picked from the Record Window submenu
    acRecordWindow,
    // idle -> recording: the region of the last region recording, which
    // survives a relaunch in NSUserDefaults. The controller additionally
    // requires a region to be on file; the table only says when the
    // command could ever be legal.
    acRecordLastRegion,
    // idle -> idle: the two checkboxes in the Audio submenu. Neither
    // changes any state, but neither must be reachable mid-recording —
    // the stream configuration is fixed once the capture has started, so
    // an audio source switched on mid-take would silently do nothing.
    acToggleSystemAudio,
    acToggleMicrophone,
    // idle -> idle: the two live-effect checkboxes (Zoom on Click and
    // Follow Mouse). Idle-only for the same reason as the audio
    // checkbox, though not quite the same mechanism: the effects move
    // the stream's sourceRect, which needs the capture to have been
    // started *with* one (TRecordingOptions.LiveSourceRect), and that is
    // decided when the recording begins. Switching them mid-recording
    // would work for a region and silently do nothing for a display, and
    // a toggle that sometimes does nothing is worse than one that is
    // greyed out.
    acToggleZoomOnClick,
    acToggleFollowMouse,
    acSelectionCommitted, // selecting -> recording: mouse released
    acSelectionCancelled, // selecting -> idle: Esc or an empty drag
    // selecting -> idle, asked for from the menu rather than from inside
    // the overlay. The overlay sits above the menu bar, so this is the
    // way out when the overlay did not come up at all.
    acCancelSelection,
    acStopRecording,      // recording -> idle: click or menu item
    acCaptureFailed);     // selecting/recording -> idle: framework error

// False when the command is not legal in the current state; ANext is then
// the unchanged current state. The controller never transitions any other
// way, so an illegal click is a no-op rather than a wedged status item.
function NextAppState(ACurrent: TAppState; ACommand: TAppCommand;
  out ANext: TAppState): Boolean;

// Whether the menu item for the command should be enabled in this state.
function IsCommandEnabled(AState: TAppState; ACommand: TAppCommand): Boolean;

// The status item's title: the idle glyph, or the recording glyph and the
// elapsed time.
function StatusItemTitle(AState: TAppState; AElapsedSeconds: Int64): string;

// M:SS below an hour, H:MM:SS from there. Negative input reads as 0:00.
function FormatElapsed(ASeconds: Int64): string;

function RecordingFileName(const AWhen: TDateTime): string;

// ~/Movies/knips/, with a trailing path delimiter.
function RecordingsDirectory(const AHomeDirectory: string): string;

// Two overlay corners into a region. Both points are already in the
// display's own top-left-origin point space (the overlay unit does the
// flip); the result is the enclosing rectangle with positive extent.
function NormalizeSelection(AAnchorX, AAnchorY, ACurrentX,
  ACurrentY: Double): TCaptureRegion;

// Keeps the region inside a display of the given size in points.
function ClampSelection(const ASelection: TCaptureRegion;
  ADisplayWidth, ADisplayHeight: Integer): TCaptureRegion;

// A region small enough to align to nothing is a stray click, not a drag.
function IsSelectionUsable(const ASelection: TCaptureRegion): Boolean;

function ErrorMenuTitle(const AMessage: string): string;

// NSControlStateValueOn / Off for a checkbox-shaped menu item.
function MenuCheckState(AChecked: Boolean): Integer;

// The camera item's checkmark: on when the window is up.
function CameraMenuState(AVisible: Boolean): Integer;

// The Circular Camera item's checkmark.
function CameraShapeMenuState(AShape: TCameraShape): Integer;

{ The Audio submenu: two checkboxes, and the TAudioMode they compose to. }

// The microphone item's title. AAvailable is False on a macOS with no
// ScreenCaptureKit microphone capture; the reason then rides in the
// title, because a greyed-out line with no explanation is the thing
// users file bugs about. (The same reason also goes on the item's
// tooltip, which is Knips.App's business.)
function MicrophoneMenuItemTitle(AAvailable: Boolean): string;

// The two checkboxes as the one mode the recorder takes. This is the
// whole mapping, and it is the natural product: neither is none, one is
// that one, both is both.
function AudioModeFromToggles(ASystem, AMicrophone: Boolean): TAudioMode;

// The one-way migration off the old Record System Audio checkbox: when
// KnipsAudioSystem has never been written, KnipsRecordSystemAudio
// decides — so an upgrade keeps the box the user had ticked. Once the
// new key exists it is the only answer, including when it says False,
// which is why the caller passes "has the key" separately.
function MigratedSystemAudio(AHasStoredValue, AStoredValue,
  ALegacySystemAudio: Boolean): Boolean;


// Constructors, so callers can write a rectangle or a size inline instead
// of filling four fields a statement at a time.
function CameraSize(AWidth, AHeight: Double): TCameraSize;
function CameraRect(AX, AY, AWidth, AHeight: Double): TCameraRect;

// The window's outside size for a shape, in points.
function CameraWindowSize(AShape: TCameraShape): TCameraSize;

// The preview layer's corner radius for a shape: the fixed 8 points for
// the rectangle, half the side for the circle — which is what turns a
// square layer into a disc.
function CameraCornerRadiusForShape(AShape: TCameraShape): Double;

// The shape as it goes into (and comes back out of) NSUserDefaults.
// `defaults write` is a public interface, so anything at all can be
// sitting under the key; anything that is not the circle reads as the
// rectangle the camera has always been.
function StoredCameraShape(AShape: TCameraShape): Integer;
function CameraShapeFromStored(AStored: Int64): TCameraShape;

// Bottom-right of the given visible frame, inset by CameraWindowMargin.
// The frame is a screen's visibleFrame, so the result already clears the
// menu bar and the Dock.
function DefaultCameraOrigin(const ASize: TCameraSize;
  const AVisible: TCameraRect): TCameraOrigin;

// Whether a restored origin still puts a usable amount of the window on
// the given screen's *visible* frame. The caller ORs this over every
// screen; a False everywhere means the saved position belonged to a
// display that is no longer attached — or to space the Dock has since
// taken — and the default placement is used instead.
function IsCameraOriginUsable(const AOrigin: TCameraOrigin;
  const ASize: TCameraSize; const AVisible: TCameraRect): Boolean;

// Where a released drag lands: the corner of AFrame nearest to where the
// window was let go, inset by AMargin. The four candidates form a 2x2
// grid, so "nearest corner" separates into "nearer edge on each axis"
// exactly — no distances to compare. A frame with no room for the window
// plus its margins (a region smaller than the camera) collapses to the
// frame's own origin rather than turning inside out, the same way the
// default placement clamps to the near edge of a tiny screen.
function NearestCameraCorner(const AOrigin: TCameraOrigin;
  const ASize: TCameraSize; const AFrame: TCameraRect;
  AMargin: Double): TCameraOrigin;

// Keeps the whole window inside AFrame, with no margin — what a shape
// change needs, where the window grows or shrinks in place and must not
// end up hanging off the screen. A window larger than the frame is
// aligned to the frame's origin.
function ClampCameraOrigin(const AOrigin: TCameraOrigin;
  const ASize: TCameraSize; const AFrame: TCameraRect): TCameraOrigin;

// The origin that keeps a window's centre where it was while its size
// changes. Switching shapes should look like the picture being re-cropped
// under the pointer, not like the window walking off to one side.
function RecenteredCameraOrigin(const AOrigin: TCameraOrigin;
  const AOld, ANew: TCameraSize): TCameraOrigin;

// A capture region — the display's own points, top-left origin — as a
// rectangle in AppKit's global bottom-left screen space, given the frame
// of the NSScreen that display is. The one flip the camera unit needs,
// and the same arithmetic Knips.App.Border does for the frame it draws
// (minus the outset, which is the border's own business).
function RegionScreenRect(const ARegion: TCaptureRegion;
  const AScreenFrame: TCameraRect): TCameraRect;

// ARect pulled in by AMargin on every side. An axis with no room to
// spare is left alone rather than turned inside out, which is the same
// give-up-on-the-margins rule NearestCameraCorner uses — so clamping into
// an inset region and snapping to its corners agree about where "as far
// in as it fits" is.
function InsetCameraRect(const ARect: TCameraRect;
  AMargin: Double): TCameraRect;

// Whether a released drag moved the window far enough to count as one.
// A bare click answers False and the window is left exactly where it is.
function IsCameraDragMovement(const AFrom, ATo: TCameraOrigin): Boolean;

// One step of the snap: the origin AStep steps into a smoothstep ease
// from AFrom to ATo. Step 0 is AFrom and step ASteps is ATo *exactly* —
// the ease must land on the corner, not near it. 3t² − 2t³ is the same
// curve Knips.Recording.LiveMath eases a zoom with; it is repeated here
// rather than borrowed because the camera has no business depending on
// the recording layer, and it is four operations.
function CameraSnapOrigin(const AFrom, ATo: TCameraOrigin; AStep,
  ASteps: Integer): TCameraOrigin;

{ Riding: a docked camera following the rectangle it was docked into
  while that rectangle travels. Two things move a recorded rectangle
  under a running capture — Follow Mouse panning a region, and the user
  dragging a recorded window — and both drive the same arithmetic. }

// The origin the docked camera takes when the rectangle it rides has
// moved from AFrom to ATo: the origin the dock landed on, displaced by
// exactly the rectangle's displacement.
//
// Deliberately *not* "the nearest corner of the new rectangle". That
// would make the picture-in-picture jump from one corner to another the
// moment the rectangle's midline crossed it, which is a teleport in the
// middle of a take; riding keeps the corner the dock chose for as long as
// the recording lasts. A rectangle that also changed *size* (a window
// resized mid-recording) is followed by its origin alone for the same
// reason — the camera keeps its offset rather than re-deciding a corner.
function CameraRideOrigin(const ADockedOrigin: TCameraOrigin;
  const AFrom, ATo: TCameraRect): TCameraOrigin;

// Whether the rectangle has moved far enough to be worth a setFrame:.
function IsCameraRideMovement(const AFrom, ATo: TCameraRect): Boolean;

// A CGWindowListCopyWindowInfo bounds rectangle as AppKit's global,
// bottom-left screen points. Window bounds arrive in Quartz's global
// space: points with the origin at the *top* left of the primary display
// and y growing downwards. APrimaryHeight is that display's height —
// NSMaxY of NSScreen.screens[0].frame, which is the screen whose origin
// is (0, 0) and therefore the one both spaces are anchored to.
//
// The same flip the overlay, the border and RegionScreenRect all do, one
// more time and in the one space this app had not needed yet.
function WindowBoundsScreenRect(AX, AY, AWidth, AHeight,
  APrimaryHeight: Double): TCameraRect;

// The GIF a recording exports to: same directory, same stem, .gif.
function GifPathForRecording(const ARecordingPath: string): string;

// The width a one-click GIF export asks for: the recording's own *point*
// size, which is its pixel width divided by the scale it was captured
// at. On the 2x display that is nearly every Mac, that makes the export
// an exact 2:1 integer box reduction — the resampling that keeps text
// legible — where any other width lands on a fractional ratio and
// softens it. Scale-1 recordings gain nothing from the point size (it
// IS the pixel size), so they keep the MaxAppGifWidth sendable-size cap;
// a too-wide point size is clamped to the exporter's maximum rather
// than falling back to something wider still.
//
// GifWidthFromSource (0) is the "keep the movie's own width" sentinel.
function AppGifWidth(ASourcePixelWidth, ASourceScale: Integer): Integer;

// "Application — Title" for the Record Window submenu, elided. A window
// with no title reads as its application alone.
function WindowMenuItemTitle(const AApplicationName,
  AWindowTitle: string): string;

// Whether a window belongs in the Record Window submenu at all: on
// screen, an ordinary application window (layer 0), big enough to be
// worth recording, titled, and not one of ours. AIsOwnProcess is decided
// by the caller from the owning process id — never from the application
// name, which is a display name and reads 'Knips' under the bundle and
// 'knips-bin' from the shell.
function IsWindowRecordable(AOnScreen: Boolean; ALayer, AWidth,
  AHeight: Integer; const AWindowTitle: string;
  AIsOwnProcess: Boolean): Boolean;

// One percentage for an export that makes two passes over the movie.
// Always between 0 and 100, and never goes backwards between stages.
function ExportPercent(AIsPalettePass: Boolean; AFramesDone,
  AFramesTotal: Int64): Integer;

// The playback window's title while an export is running.
function ExportProgressTitle(APercent: Integer): string;

// A region read back out of NSUserDefaults, made safe to hand to
// ScreenCaptureKit's sourceRect. `defaults write` is a public interface:
// anything at all can be sitting under those keys, and a negative origin
// or an absurd extent would go straight into the capture. False when
// nothing usable is left.
function SanitizeStoredRegion(const AStored: TCaptureRegion;
  out ARegion: TCaptureRegion): Boolean;

implementation

const
  Ellipsis = '…';

// Cuts a string to at most AMaxBytes bytes without splitting a UTF-8
// character. Titles come out of ScreenCaptureKit and out of framework
// error messages, so they carry non-ASCII routinely, and a Pascal string
// holding half a character makes NSString.stringWithUTF8String: return
// nil — which AppKit turns into an exception the moment it is set as a
// title. Cutting on a character boundary is what keeps that off the
// menu.
function ElideUtf8(const AText: string; AMaxBytes: Integer): string;
var
  Cut: Integer;
begin
  Result := AText;
  if Length(Result) <= AMaxBytes then
    Exit;
  Cut := AMaxBytes - Length(Ellipsis);
  if Cut < 0 then
    Cut := 0;
  // Continuation bytes are 10xxxxxx; back up until the cut lands on the
  // first byte of a character.
  while (Cut > 0) and (Ord(Result[Cut + 1]) and $C0 = $80) do
    Dec(Cut);
  Result := Copy(Result, 1, Cut) + Ellipsis;
end;

function NextAppState(ACurrent: TAppState; ACommand: TAppCommand;
  out ANext: TAppState): Boolean;
begin
  ANext := ACurrent;
  Result := True;
  case ACurrent of
    asIdle:
      case ACommand of
        acRecordRegion: ANext := asSelecting;
        acRecordDisplay, acRecordWindow, acRecordLastRegion:
          ANext := asRecording;
        acToggleSystemAudio, acToggleMicrophone, acToggleZoomOnClick,
          acToggleFollowMouse:
          ANext := asIdle;
      else
        Result := False;
      end;
    asSelecting:
      case ACommand of
        acSelectionCommitted: ANext := asRecording;
        acSelectionCancelled, acCancelSelection, acCaptureFailed:
          ANext := asIdle;
      else
        Result := False;
      end;
    asRecording:
      case ACommand of
        acStopRecording, acCaptureFailed: ANext := asIdle;
      else
        Result := False;
      end;
  else
    Result := False;
  end;
end;

function IsCommandEnabled(AState: TAppState; ACommand: TAppCommand): Boolean;
var
  Ignored: TAppState;
begin
  Result := NextAppState(AState, ACommand, Ignored);
end;

function FormatElapsed(ASeconds: Int64): string;
var
  Total, Hours, Minutes, Seconds: Int64;
begin
  Total := ASeconds;
  if Total < 0 then
    Total := 0;
  Hours := Total div 3600;
  Minutes := (Total div 60) mod 60;
  Seconds := Total mod 60;
  if Hours > 0 then
    Result := Format('%d:%.2d:%.2d', [Hours, Minutes, Seconds])
  else
    Result := Format('%d:%.2d', [Minutes, Seconds]);
end;

function StatusItemTitle(AState: TAppState; AElapsedSeconds: Int64): string;
begin
  if AState = asRecording then
    Result := RecordingGlyph + ' ' + FormatElapsed(AElapsedSeconds)
  else
    Result := IdleGlyph;
end;

function RecordingFileName(const AWhen: TDateTime): string;
begin
  Result := RecordingFilePrefix
    + FormatDateTime(RecordingTimestampFormat, AWhen)
    + RecordingFileExtension;
end;

function RecordingsDirectory(const AHomeDirectory: string): string;
begin
  Result := IncludeTrailingPathDelimiter(AHomeDirectory) + MoviesFolderName
    + PathDelim + RecordingsFolderName + PathDelim;
end;

function NormalizeSelection(AAnchorX, AAnchorY, ACurrentX,
  ACurrentY: Double): TCaptureRegion;
var
  Left, Top, Right, Bottom: Double;
begin
  if ACurrentX < AAnchorX then
  begin
    Left := ACurrentX;
    Right := AAnchorX;
  end
  else
  begin
    Left := AAnchorX;
    Right := ACurrentX;
  end;
  if ACurrentY < AAnchorY then
  begin
    Top := ACurrentY;
    Bottom := AAnchorY;
  end
  else
  begin
    Top := AAnchorY;
    Bottom := ACurrentY;
  end;
  Result.Left := Round(Left);
  Result.Top := Round(Top);
  Result.Width := Round(Right) - Result.Left;
  Result.Height := Round(Bottom) - Result.Top;
end;

function ClampSelection(const ASelection: TCaptureRegion;
  ADisplayWidth, ADisplayHeight: Integer): TCaptureRegion;
begin
  Result := ASelection;
  if Result.Left < 0 then
  begin
    Inc(Result.Width, Result.Left);
    Result.Left := 0;
  end;
  if Result.Top < 0 then
  begin
    Inc(Result.Height, Result.Top);
    Result.Top := 0;
  end;
  if Result.Left > ADisplayWidth then
    Result.Left := ADisplayWidth;
  if Result.Top > ADisplayHeight then
    Result.Top := ADisplayHeight;
  if Result.Left + Result.Width > ADisplayWidth then
    Result.Width := ADisplayWidth - Result.Left;
  if Result.Top + Result.Height > ADisplayHeight then
    Result.Height := ADisplayHeight - Result.Top;
  if Result.Width < 0 then
    Result.Width := 0;
  if Result.Height < 0 then
    Result.Height := 0;
end;

function IsSelectionUsable(const ASelection: TCaptureRegion): Boolean;
begin
  Result := (AlignDimension(ASelection.Width) >= DimensionAlignment)
    and (AlignDimension(ASelection.Height) >= DimensionAlignment);
end;

function ErrorMenuTitle(const AMessage: string): string;
var
  Text: string;
begin
  Text := Trim(AMessage);
  if Text = '' then
    Text := 'unknown error';
  Result := ErrorTitlePrefix + ElideUtf8(Text, MaxErrorTitleLength);
end;

function GifPathForRecording(const ARecordingPath: string): string;
begin
  if ARecordingPath = '' then
    Exit('');
  Result := ChangeFileExt(ARecordingPath, GifFileExtension);
  // ChangeFileExt on a name with no extension appends nothing in some
  // RTL versions; make sure the export never writes over the movie.
  if SameText(Result, ARecordingPath) then
    Result := ARecordingPath + GifFileExtension;
end;

function AppGifWidth(ASourcePixelWidth, ASourceScale: Integer): Integer;
var
  Points: Integer;
begin
  // Unknown width: leave the choice to the exporter.
  if ASourcePixelWidth <= 0 then
    Exit(GifWidthFromSource);
  // Scale 1: there is no integer reduction to land on, so the sharpness
  // argument for the point size does not apply — keep the sendable-size
  // cap the point-size default replaced for Retina recordings.
  if ASourceScale <= 1 then
  begin
    if ASourcePixelWidth > MaxAppGifWidth then
      Exit(MaxAppGifWidth);
    Exit(GifWidthFromSource);
  end;
  Points := ASourcePixelWidth div ASourceScale;
  if Points < MinGifWidth then
    Exit(GifWidthFromSource);
  // Never answer a too-wide request with something wider still: the
  // sentinel would resolve to the full pixel width.
  if Points > MaxGifWidth then
    Exit(MaxGifWidth);
  Result := Points;
end;

function WindowMenuItemTitle(const AApplicationName,
  AWindowTitle: string): string;
var
  Application, Title: string;
begin
  Application := Trim(AApplicationName);
  Title := Trim(AWindowTitle);
  if (Application <> '') and (Title <> '') then
    Result := Application + WindowMenuSeparator + Title
  else if Application <> '' then
    Result := Application
  else
    Result := Title;
  if Result = '' then
    Result := 'Untitled window';
  Result := ElideUtf8(Result, MaxWindowMenuTitleLength);
end;

function IsWindowRecordable(AOnScreen: Boolean; ALayer, AWidth,
  AHeight: Integer; const AWindowTitle: string;
  AIsOwnProcess: Boolean): Boolean;
begin
  Result := False;
  if not AOnScreen then
    Exit;
  if ALayer <> RecordableWindowLayer then
    Exit;
  if (AWidth < MinRecordableWindowSize)
    or (AHeight < MinRecordableWindowSize) then
    Exit;
  // An untitled window cannot be named in a menu, and a menu entry the
  // user cannot tell apart from the next one is worse than no entry.
  if Trim(AWindowTitle) = '' then
    Exit;
  // Recording ourselves is a hall of mirrors. The playback window is the
  // one of ours that reaches this far — it is titled and on layer 0,
  // unlike the overlay and the border.
  if AIsOwnProcess then
    Exit;
  Result := True;
end;

// The Boolean rather than the pipeline's own stage enumeration: this unit
// sits below the Darwin line and must not reach up into
// Knips.Export.GifPipeline for a type.
function ExportPercent(AIsPalettePass: Boolean; AFramesDone,
  AFramesTotal: Int64): Integer;
var
  Fraction: Double;
  Share, Base: Integer;
begin
  if AIsPalettePass then
  begin
    Base := 0;
    Share := PaletteProgressPercent;
  end
  else
  begin
    Base := PaletteProgressPercent;
    Share := 100 - PaletteProgressPercent;
  end;
  if AFramesTotal <= 0 then
    Fraction := 0
  else
    Fraction := AFramesDone / AFramesTotal;
  if Fraction < 0 then
    Fraction := 0;
  // The total is an estimate from the trim range and the target rate, so
  // the count can run past it; a bar that reads 118% is a bug report.
  if Fraction > 1 then
    Fraction := 1;
  Result := Base + Round(Fraction * Share);
  if Result < 0 then
    Result := 0;
  if Result > 100 then
    Result := 100;
end;

function SanitizeStoredRegion(const AStored: TCaptureRegion;
  out ARegion: TCaptureRegion): Boolean;
begin
  ARegion := AStored;
  // A negative origin is the dangerous one: it would reach sourceRect as
  // a rectangle starting off the display. Pull it in the same way a drag
  // that left the screen is pulled in, rather than growing the region.
  if ARegion.Left < 0 then
  begin
    Inc(ARegion.Width, ARegion.Left);
    ARegion.Left := 0;
  end;
  if ARegion.Top < 0 then
  begin
    Inc(ARegion.Height, ARegion.Top);
    ARegion.Top := 0;
  end;
  if (ARegion.Width <= 0) or (ARegion.Height <= 0) then
  begin
    ARegion := Default(TCaptureRegion);
    Exit(False);
  end;
  // Nothing beyond the largest display anyone ships is a real selection,
  // and ResolveFilter rejects a region past the display's own bounds
  // anyway — this only keeps the arithmetic in range until it gets there.
  if (ARegion.Left > MaxStoredRegionExtent)
    or (ARegion.Top > MaxStoredRegionExtent)
    or (ARegion.Width > MaxStoredRegionExtent)
    or (ARegion.Height > MaxStoredRegionExtent) then
  begin
    ARegion := Default(TCaptureRegion);
    Exit(False);
  end;
  Result := IsSelectionUsable(ARegion);
  if not Result then
    ARegion := Default(TCaptureRegion);
end;

function ExportProgressTitle(APercent: Integer): string;
var
  Percent: Integer;
begin
  Percent := APercent;
  if Percent < 0 then
    Percent := 0;
  if Percent > 100 then
    Percent := 100;
  Result := Format('%s%d%%', [ExportingTitlePrefix, Percent]);
end;

function MenuCheckState(AChecked: Boolean): Integer;
begin
  if AChecked then
    Result := MenuItemStateOn
  else
    Result := MenuItemStateOff;
end;

function CameraMenuState(AVisible: Boolean): Integer;
begin
  Result := MenuCheckState(AVisible);
end;

function CameraShapeMenuState(AShape: TCameraShape): Integer;
begin
  Result := MenuCheckState(AShape = csCircle);
end;

{ The Audio submenu. }

function MicrophoneMenuItemTitle(AAvailable: Boolean): string;
begin
  Result := MicrophoneMenuTitle;
  if not AAvailable then
    Result := Result + NoMicrophoneSuffix;
end;

function AudioModeFromToggles(ASystem, AMicrophone: Boolean): TAudioMode;
begin
  if ASystem and AMicrophone then
    Result := amBoth
  else if AMicrophone then
    Result := amMicrophone
  else if ASystem then
    Result := amSystem
  else
    Result := amNone;
end;

function MigratedSystemAudio(AHasStoredValue, AStoredValue,
  ALegacySystemAudio: Boolean): Boolean;
begin
  if AHasStoredValue then
    Result := AStoredValue
  else
    Result := ALegacySystemAudio;
end;


function CameraSize(AWidth, AHeight: Double): TCameraSize;
begin
  Result.Width := AWidth;
  Result.Height := AHeight;
end;

function CameraRect(AX, AY, AWidth, AHeight: Double): TCameraRect;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.Width := AWidth;
  Result.Height := AHeight;
end;

function CameraWindowSize(AShape: TCameraShape): TCameraSize;
begin
  if AShape = csCircle then
    Result := CameraSize(CameraCircleSide, CameraCircleSide)
  else
    Result := CameraSize(CameraWindowWidth, CameraWindowHeight);
end;

function CameraCornerRadiusForShape(AShape: TCameraShape): Double;
var
  Size: TCameraSize;
begin
  if AShape <> csCircle then
    Exit(CameraCornerRadius);
  // Half of the *shorter* side, so a window that is somehow not square
  // still comes out as a capsule rather than as a layer whose corners
  // overlap — Core Animation clamps that, but the intent should not
  // depend on the clamp.
  Size := CameraWindowSize(AShape);
  if Size.Width < Size.Height then
    Result := Size.Width / 2
  else
    Result := Size.Height / 2;
end;

function StoredCameraShape(AShape: TCameraShape): Integer;
begin
  Result := Ord(AShape);
end;

function CameraShapeFromStored(AStored: Int64): TCameraShape;
begin
  if AStored = Ord(csCircle) then
    Result := csCircle
  else
    Result := csRectangle;
end;

// The lowest and highest origin the window may take on one axis of a
// frame, inset by the margin. Shared by the default placement and by the
// snap, so the corner a drag lands on is the corner the camera started
// life in.
procedure CameraOriginRange(AFrameStart, AFrameExtent, AWindowExtent,
  AMargin: Double; out ALow, AHigh: Double);
begin
  ALow := AFrameStart + AMargin;
  AHigh := AFrameStart + AFrameExtent - AWindowExtent - AMargin;
  // No room for the window and both margins: give up on the margins
  // rather than on the frame, and put the window at the near edge.
  if AHigh < ALow then
  begin
    ALow := AFrameStart;
    AHigh := AFrameStart;
  end;
end;

function DefaultCameraOrigin(const ASize: TCameraSize;
  const AVisible: TCameraRect): TCameraOrigin;
var
  Low, High: Double;
begin
  CameraOriginRange(AVisible.X, AVisible.Width, ASize.Width,
    CameraWindowMargin, Low, High);
  Result.X := High;
  CameraOriginRange(AVisible.Y, AVisible.Height, ASize.Height,
    CameraWindowMargin, Low, High);
  Result.Y := Low;
end;

function IsCameraOriginUsable(const AOrigin: TCameraOrigin;
  const ASize: TCameraSize; const AVisible: TCameraRect): Boolean;
var
  OverlapWidth, OverlapHeight: Double;

  function Overlap(AStart, AExtent, AOtherStart, AOtherExtent: Double): Double;
  var
    Low, High: Double;
  begin
    Low := AStart;
    if AOtherStart > Low then
      Low := AOtherStart;
    High := AStart + AExtent;
    if AOtherStart + AOtherExtent < High then
      High := AOtherStart + AOtherExtent;
    Result := High - Low;
    if Result < 0 then
      Result := 0;
  end;

begin
  OverlapWidth := Overlap(AOrigin.X, ASize.Width, AVisible.X,
    AVisible.Width);
  OverlapHeight := Overlap(AOrigin.Y, ASize.Height, AVisible.Y,
    AVisible.Height);
  Result := (OverlapWidth >= MinVisibleCameraExtent)
    and (OverlapHeight >= MinVisibleCameraExtent);
end;

// Ties go to the low edge — left, and bottom — which only decides the
// exact centre of a frame and has to decide it somehow.
function NearerEdge(AValue, ALow, AHigh: Double): Double;
begin
  if Abs(AValue - ALow) <= Abs(AValue - AHigh) then
    Result := ALow
  else
    Result := AHigh;
end;

function NearestCameraCorner(const AOrigin: TCameraOrigin;
  const ASize: TCameraSize; const AFrame: TCameraRect;
  AMargin: Double): TCameraOrigin;
var
  Low, High: Double;
begin
  CameraOriginRange(AFrame.X, AFrame.Width, ASize.Width, AMargin, Low, High);
  Result.X := NearerEdge(AOrigin.X, Low, High);
  CameraOriginRange(AFrame.Y, AFrame.Height, ASize.Height, AMargin, Low,
    High);
  Result.Y := NearerEdge(AOrigin.Y, Low, High);
end;

function ClampCameraOrigin(const AOrigin: TCameraOrigin;
  const ASize: TCameraSize; const AFrame: TCameraRect): TCameraOrigin;

  function ClampAxis(AValue, AFrameStart, AFrameExtent,
    AWindowExtent: Double): Double;
  begin
    Result := AValue;
    if Result + AWindowExtent > AFrameStart + AFrameExtent then
      Result := AFrameStart + AFrameExtent - AWindowExtent;
    // Second, so a window larger than the frame ends up at the near edge
    // rather than pushed off it by the line above.
    if Result < AFrameStart then
      Result := AFrameStart;
  end;

begin
  Result.X := ClampAxis(AOrigin.X, AFrame.X, AFrame.Width, ASize.Width);
  Result.Y := ClampAxis(AOrigin.Y, AFrame.Y, AFrame.Height, ASize.Height);
end;

function RecenteredCameraOrigin(const AOrigin: TCameraOrigin;
  const AOld, ANew: TCameraSize): TCameraOrigin;
begin
  Result.X := AOrigin.X + (AOld.Width - ANew.Width) / 2;
  Result.Y := AOrigin.Y + (AOld.Height - ANew.Height) / 2;
end;

function RegionScreenRect(const ARegion: TCaptureRegion;
  const AScreenFrame: TCameraRect): TCameraRect;
begin
  Result := CameraRect(
    AScreenFrame.X + ARegion.Left,
    AScreenFrame.Y + AScreenFrame.Height - (ARegion.Top + ARegion.Height),
    ARegion.Width,
    ARegion.Height);
end;

function InsetCameraRect(const ARect: TCameraRect;
  AMargin: Double): TCameraRect;
begin
  Result := ARect;
  if Result.Width > 2 * AMargin then
  begin
    Result.X := Result.X + AMargin;
    Result.Width := Result.Width - 2 * AMargin;
  end;
  if Result.Height > 2 * AMargin then
  begin
    Result.Y := Result.Y + AMargin;
    Result.Height := Result.Height - 2 * AMargin;
  end;
end;

function IsCameraDragMovement(const AFrom, ATo: TCameraOrigin): Boolean;
begin
  // Either axis on its own: a purely horizontal nudge is a drag, and
  // squaring two numbers to find that out would be ceremony.
  Result := (Abs(ATo.X - AFrom.X) >= CameraDragThreshold)
    or (Abs(ATo.Y - AFrom.Y) >= CameraDragThreshold);
end;

function CameraSnapOrigin(const AFrom, ATo: TCameraOrigin; AStep,
  ASteps: Integer): TCameraOrigin;
var
  Time, Eased: Double;
begin
  // A degenerate step count is an arrival, not a division by zero.
  if (ASteps <= 0) or (AStep >= ASteps) then
    Exit(ATo);
  if AStep <= 0 then
    Exit(AFrom);
  Time := AStep / ASteps;
  Eased := Time * Time * (3 - 2 * Time);
  Result.X := AFrom.X + (ATo.X - AFrom.X) * Eased;
  Result.Y := AFrom.Y + (ATo.Y - AFrom.Y) * Eased;
end;

function CameraRideOrigin(const ADockedOrigin: TCameraOrigin;
  const AFrom, ATo: TCameraRect): TCameraOrigin;
begin
  Result.X := ADockedOrigin.X + (ATo.X - AFrom.X);
  Result.Y := ADockedOrigin.Y + (ATo.Y - AFrom.Y);
end;

function IsCameraRideMovement(const AFrom, ATo: TCameraRect): Boolean;
begin
  Result := (Abs(ATo.X - AFrom.X) >= CameraRideEpsilon)
    or (Abs(ATo.Y - AFrom.Y) >= CameraRideEpsilon);
end;

function WindowBoundsScreenRect(AX, AY, AWidth, AHeight,
  APrimaryHeight: Double): TCameraRect;
begin
  Result := CameraRect(AX, APrimaryHeight - AY - AHeight, AWidth, AHeight);
end;

end.

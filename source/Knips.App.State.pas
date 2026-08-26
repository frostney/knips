unit Knips.App.State;

// The menu-bar app's state machine and the pure decisions around it:
// which command is legal in which state, what the status item reads, where
// a recording is written, and how a dragged rectangle becomes a region.
//
// Everything here is platform-neutral and unit-tested; Knips.App and
// Knips.App.Overlay hold the Cocoa objects and call into this unit for
// every decision that does not need a framework.

{$I Shared.inc}

interface

uses
  SysUtils,

  Knips.Options;

const
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

  // The camera picture-in-picture window. Points, not pixels: the window
  // is placed in screen coordinates and the layer scales itself.
  CameraWindowWidth = 240;
  CameraWindowHeight = 180;
  // Inset from the bottom-right corner of the main screen's visible frame
  // (so the Dock does not sit on top of the first placement).
  CameraWindowMargin = 24;
  CameraCornerRadius = 8;
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
  // NSControlStateValueOn / Off (NSCell.h). Spelled out rather than taken
  // from CocoaAll, which is where the wrong NSWindowLevel values live.
  MenuItemStateOn = 1;
  MenuItemStateOff = 0;
  // NSUserDefaults keys. Prefixed because a shell-run binary shares the
  // defaults domain with whatever launched it.
  CameraVisibleDefaultsKey = 'KnipsCameraVisible';
  CameraOriginXDefaultsKey = 'KnipsCameraOriginX';
  CameraOriginYDefaultsKey = 'KnipsCameraOriginY';

type
  // A window origin in AppKit's screen coordinates: bottom-left origin,
  // y growing upwards, the same space NSWindow.frame lives in. Nothing
  // here is flipped — unlike a capture region, the camera window is only
  // ever handed back to AppKit.
  TCameraOrigin = record
    X: Double;
    Y: Double;
  end;

  TAppState = (asIdle, asSelecting, asRecording);

  TAppCommand = (
    acRecordRegion,       // idle -> selecting: show the overlay
    acRecordDisplay,      // idle -> recording: whole main display
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

// The camera item's checkmark: on when the window is up.
function CameraMenuState(AVisible: Boolean): Integer;

// Bottom-right of the given visible frame, inset by CameraWindowMargin.
// The frame is a screen's visibleFrame, so the result already clears the
// menu bar and the Dock.
function DefaultCameraOrigin(AVisibleX, AVisibleY, AVisibleWidth,
  AVisibleHeight: Double): TCameraOrigin;

// Whether a restored origin still puts a usable amount of the window on
// the given screen's *visible* frame. The caller ORs this over every
// screen; a False everywhere means the saved position belonged to a
// display that is no longer attached — or to space the Dock has since
// taken — and the default placement is used instead.
function IsCameraOriginUsable(const AOrigin: TCameraOrigin; AVisibleX,
  AVisibleY, AVisibleWidth, AVisibleHeight: Double): Boolean;

implementation

function NextAppState(ACurrent: TAppState; ACommand: TAppCommand;
  out ANext: TAppState): Boolean;
begin
  ANext := ACurrent;
  Result := True;
  case ACurrent of
    asIdle:
      case ACommand of
        acRecordRegion: ANext := asSelecting;
        acRecordDisplay: ANext := asRecording;
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
  if Length(Text) > MaxErrorTitleLength then
    Text := Copy(Text, 1, MaxErrorTitleLength - 1) + '…';
  Result := ErrorTitlePrefix + Text;
end;

function CameraMenuState(AVisible: Boolean): Integer;
begin
  if AVisible then
    Result := MenuItemStateOn
  else
    Result := MenuItemStateOff;
end;

function DefaultCameraOrigin(AVisibleX, AVisibleY, AVisibleWidth,
  AVisibleHeight: Double): TCameraOrigin;
begin
  Result.X := AVisibleX + AVisibleWidth - CameraWindowWidth
    - CameraWindowMargin;
  Result.Y := AVisibleY + CameraWindowMargin;
  // A screen narrower or shorter than the window plus its margins would
  // push the origin off the near edge instead of the far one.
  if Result.X < AVisibleX then
    Result.X := AVisibleX;
  if Result.Y + CameraWindowHeight > AVisibleY + AVisibleHeight then
    Result.Y := AVisibleY;
end;

function IsCameraOriginUsable(const AOrigin: TCameraOrigin; AVisibleX,
  AVisibleY, AVisibleWidth, AVisibleHeight: Double): Boolean;
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
  OverlapWidth := Overlap(AOrigin.X, CameraWindowWidth, AVisibleX,
    AVisibleWidth);
  OverlapHeight := Overlap(AOrigin.Y, CameraWindowHeight, AVisibleY,
    AVisibleHeight);
  Result := (OverlapWidth >= MinVisibleCameraExtent)
    and (OverlapHeight >= MinVisibleCameraExtent);
end;

end.

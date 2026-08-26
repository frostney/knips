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
  // The GIF a recording exports to sits beside it, under the same name.
  GifFileExtension = '.gif';
  // What the "Export as GIF…" button asks for. The CLI's own default
  // (the movie's own width) is the right answer for a hand-written
  // command and the wrong one for a one-click button: a Retina display
  // recording is 2560 px wide and makes a GIF nobody can send anywhere.
  AppGifFramesPerSecond = 20;
  MaxAppGifWidth = 800;
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

type
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
    // idle -> idle: the Record System Audio checkbox. It changes no
    // state, but it must not be reachable mid-recording — the stream
    // configuration is fixed once the capture has started.
    acToggleSystemAudio,
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

// The GIF a recording exports to: same directory, same stem, .gif.
function GifPathForRecording(const ARecordingPath: string): string;

// The width a one-click GIF export asks for: the recording's own, capped
// at MaxAppGifWidth. 0 in means 0 out — the exporter's "keep the source
// width" sentinel.
function AppGifWidth(ASourcePixelWidth: Integer): Integer;

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
        acToggleSystemAudio: ANext := asIdle;
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

function AppGifWidth(ASourcePixelWidth: Integer): Integer;
begin
  if (ASourcePixelWidth > 0) and (ASourcePixelWidth > MaxAppGifWidth) then
    Result := MaxAppGifWidth
  else
    // GifWidthFromSource: the exporter keeps the movie's own width, which
    // is also what an unknown source width has to fall back to.
    Result := GifWidthFromSource;
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

end.

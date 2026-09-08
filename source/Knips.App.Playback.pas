unit Knips.App.Playback;

// What a finished recording opens into: an ordinary titled window with an
// AVPlayerView playing the deliverable that was just rendered, an Effects
// control, and four buttons under it — Re-export, Export as GIF…, Reveal
// in Finder, Close.
//
// **Why the effects live here and not in the menu bar.** A recording is
// raw pixels and open metadata; the pointer and the zoom are put in at
// render time from the event sidecar (Knips.Export.Render). That means
// they are no longer promises made before a take — they are decisions
// about a take that already exists, and the only place to make a decision
// about a take is in front of it. Re-export re-renders the deliverable
// from the raw take beside it with whatever the control now says, as
// often as the user likes, because the raw take is still on disk.
//
// The control is asked of the sidecar rather than assumed: a take whose
// pointer is already in its pixels cannot have another drawn, and a take
// whose capture was already zooming cannot be zoomed again
// (Knips.Recording.Sidecar.AvailableExportEffects). An item that cannot
// apply is disabled and carries the reason as its tooltip.
//
// Standard chrome on purpose. The titlebar is AppKit's, the close button
// is AppKit's, the transport controls are AVKit's; the only thing this
// unit draws is a row of NSButtons. The window is brought forward with
// activateIgnoringOtherApps: the same way the selection overlay is — a
// titled window can become key even under the Accessory policy, a
// borderless one cannot, which is why the overlay needed a runtime class
// for it and this does not.
//
// This is also the one window that puts Knips in the Dock: the controller
// switches the process to the Regular policy around it, so it gets a Dock
// tile, a place in the app switcher and a menu bar. None of that is done
// here — Show and the close path only say what happened (OnClosed), and
// Knips.App owns the policy.
//
// The buttons' target is the app's own KnipsAppTarget (the selectors are
// declared below and registered by Knips.App), so there is exactly one
// runtime-built class in this unit: KnipsPlaybackDelegate, with two
// methods. windowWillClose: is where the player is paused and let go —
// the user closing the window is the only teardown path that does not
// come through this class's own API. windowShouldClose: is the veto that
// keeps a close the user asks for from landing in the middle of an
// export.
//
// The GIF export runs inline on the main thread. It has to: TMovieReader
// and the encoder are synchronous, and nothing here may pump a nested
// run loop (the same rule the recording start and stop obey by
// deferring). The window is therefore unresponsive between title
// updates, and the buttons are disabled before the first frame is read so
// a second click cannot re-enter the export.
//
// Everything runs on the main thread; the capture-queue rules do not
// apply here.

{$I Knips.inc}
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
  Knips.Export.Pipeline,
  Knips.Export.Render,
  Knips.Export.SizeEstimate,
  Knips.ObjC.Runtime,
  Knips.Options,
  Knips.Recording.Sidecar,
  MacOSAll;

const
  // Actions on KnipsAppTarget; Knips.App registers them and forwards each
  // to the matching command below.
  ExportGifSelector = 'exportGif:';
  RevealRecordingSelector = 'revealRecording:';
  ClosePlaybackSelector = 'closePlayback:';
  // The Effects control's three items and the button beside them. Same
  // shape as the three above: declared here, registered by Knips.App on
  // the one runtime-built target, forwarded to the command below.
  ToggleEffectZoomSelector = 'toggleEffectZoom:';
  ToggleEffectSmoothCursorSelector = 'toggleEffectSmoothCursor:';
  ToggleEffectBigCursorSelector = 'toggleEffectBigCursor:';
  ReexportSelector = 'reexportRecording:';

type
  // Reported from inside an Objective-C callback or a failed export; the
  // app puts it on the same NSLog + "Last error" path as everything else.
  TPlaybackErrorEvent = procedure(const AMessage: string) of object;

  // Fired when the user changes the Effects control. The window owns the
  // selection while it is open; the controller owns the saved default,
  // and this is how the two meet.
  TPlaybackEffectsEvent = procedure(const AEffects: TExportEffects) of object;

  // Fired once the window is really gone, whichever path took it down.
  // This unit never touches the activation policy itself — the controller
  // owns what having a window on screen means for the process, and this
  // is how it hears about it.
  TPlaybackClosedEvent = procedure of object;

  TPlaybackWindow = class
  private
    FWindow: NSWindow;
    // AVPlayer and AVPlayerView, held as id/NSView so the AVKit bindings
    // stay in the implementation section.
    FPlayer: id;
    FPlayerView: NSView;
    FDelegate: id;
    FExportButton: NSButton;
    FRevealButton: NSButton;
    FCloseButton: NSButton;
    FReexportButton: NSButton;
    // The Effects pull-down, its menu and the three items in it. A
    // pull-down rather than three checkboxes because it is one setting
    // with three parts and because the bar already carries four buttons;
    // a pull-down's item 0 is its title and is never selected.
    FEffectsButton: NSPopUpButton;
    FEffectsMenu: NSMenu;
    FZoomItem: NSMenuItem;
    FSmoothCursorItem: NSMenuItem;
    FBigCursorItem: NSMenuItem;
    // An inert last line naming why something above it is disabled.
    FReasonItem: NSMenuItem;
    FPath: string;
    // The raw take this deliverable was rendered from, and what a
    // re-export renders again. '' for a recording made before the raw
    // flow existed, or one whose raw take has been deleted — the Effects
    // control and Re-export are then both off, with the reason on show.
    FRawPath: string;
    FEffects: TExportEffects;
    FCanDrawCursor: Boolean;
    FCanZoom: Boolean;
    // One reason per effect, because a take can be refused each for a
    // different fact and a tooltip that names the other one is worse
    // than no tooltip. FEffectsReason is the summary, for the inert line
    // under them.
    FCursorReason: string;
    FZoomReason: string;
    FEffectsReason: string;
    FPixelWidth: Integer;
    FPixelHeight: Integer;
    FScale: Integer;
    FExporting: Boolean;
    FLastPercent: Integer;
    // The running export, borrowed for the length of Run so the progress
    // callback can read its pre-export size estimate. Not owned, and
    // cleared in the same finally that frees it — a stale pointer here
    // would be read from a timer.
    FEstimateSource: TExportSession;
    // A word appended to the window's title, for something about the take
    // the user should see while they are looking at it — a track that was
    // enabled and came out silent, above all. The window has no message
    // area, and inventing one for a single word would be worse.
    FTitleNote: string;
    FOnError: TPlaybackErrorEvent;
    FOnClosed: TPlaybackClosedEvent;
    FOnEffectsChanged: TPlaybackEffectsEvent;
    function AddButton(AContent: NSView; const ATitle, ASelector: string;
      ATarget: id; var ARight: Double): NSButton;
    procedure SetButtonsEnabled(AEnabled: Boolean);
    procedure HandleProgress(AStage: TGifExportStage;
      AFramesDone, AFramesTotal, ABytesWritten: Int64);
    procedure HandleRenderProgress(AFramesDone, AFramesTotal: Int64);
    function TitleWithNote: string;
    procedure ReleasePlayer;
    // The pull-down's menu is alloc'd here and retained by setMenu:, so
    // this object owns one reference to it. Released from both teardown
    // paths — windowWillClose: and the destructor — because a window
    // whose delegate could not be instantiated never gets the first one.
    procedure ReleaseEffectsMenu;
    procedure ReloadPlayer;
    // Asks the RAW take's sidecar which effects are still open. The
    // deliverable's own sidecar would answer "none of them", which is
    // true of the deliverable and beside the point: a re-export starts
    // from the raw take.
    procedure LoadAvailability;
    procedure BuildEffectsControl(AContent: NSView; ATarget: id;
      var ALeft: Double);
    procedure RefreshEffects;
    procedure ApplyCursorEffect(AWanted: TExportCursorMode);
  public
    destructor Destroy; override;
    // Sets the note beside the file name in the title. Safe before or
    // after the window exists; '' clears it.
    procedure SetTitleNote(const ANote: string);
    // Opens the window on APath. APixelWidth/Height come from the
    // recording's report and only set the initial aspect ratio; a zero
    // pair falls back to 16:9. AScale is the report's pixels per point,
    // and is what the GIF export's default width is derived from — it
    // is not used for the window's geometry at all. False when the
    // window could not be made. Raises EObjCRuntime when the delegate
    // class cannot be registered.
    // ARawPath is the raw take beside the deliverable, or '' when there
    // is none. AEffects is the caller's saved default and is what the
    // control comes up showing.
    function Show(ATarget: id; const APath, ARawPath: string;
      APixelWidth, APixelHeight, AScale: Integer;
      const AEffects: TExportEffects): Boolean;
    // Asks AppKit to close, which arrives back as windowWillClose:.
    procedure CommandClose;
    procedure CommandReveal;
    procedure CommandExportGif;
    // The Effects control. Each flips one member of the selection,
    // refreshes the menu, and reports the whole record so the caller can
    // save it as the new default.
    procedure CommandToggleEffectZoom;
    procedure CommandToggleEffectSmoothCursor;
    procedure CommandToggleEffectBigCursor;
    // Renders the deliverable again from the raw take with the current
    // selection, replacing it in place. Inline on the main thread, behind
    // the same Busy lockout the GIF export uses.
    procedure CommandReexport;
    // Called by the runtime-built delegate's method body.
    procedure HandleWindowWillClose;
    procedure ReportError(const AMessage: string);
    function Visible: Boolean;
    property Path: string read FPath;
    property Exporting: Boolean read FExporting;
    property Effects: TExportEffects read FEffects;
    property OnError: TPlaybackErrorEvent read FOnError write FOnError;
    property OnClosed: TPlaybackClosedEvent read FOnClosed write FOnClosed;
    property OnEffectsChanged: TPlaybackEffectsEvent read FOnEffectsChanged
      write FOnEffectsChanged;
  end;

// Registers KnipsPlaybackDelegate once per process. Exposed so
// `knips probe` can gate on registration alone.
procedure EnsurePlaybackClasses;

function PlaybackDelegateClassName: string;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  Knips.ObjC.TypeEncoding;

{$linkframework AVKit}
{$linkframework AVFoundation}

const
  DelegateClassName = 'KnipsPlaybackDelegate';
  DelegateSuperclassName = 'NSObject';
  WindowWillCloseSelector = 'windowWillClose:';
  WindowShouldCloseSelector = 'windowShouldClose:';

  ExportGifTitle = 'Export as GIF…';
  RevealTitle = 'Reveal in Finder';
  CloseTitle = 'Close';

  // Points. Wide enough that a Retina region recording is legible at 1:1
  // or better, narrow enough to sit next to what was recorded. Widened
  // from 720 when the bar gained the Effects control and Re-export: at
  // 720 the four buttons and the pull-down overlapped at the default
  // size, and a bar that only fits once the window has been dragged
  // wider is a bar that looks broken on first sight.
  ContentWidth = 860;
  MinContentWidth = 360;
  MinContentHeight = 240;
  BarHeight = 48;
  BarPadding = 12;
  ButtonGap = 8;
  // 16:9 when the report carried no pixel size.
  FallbackAspect = 9 / 16;
  // AVPlayerViewControlsStyleInline, from AVKit's AVPlayerView.h.
  AVPlayerViewControlsStyleInline = 1;

type
  AVPlayer = objcclass external (NSObject)
    class function PlayerWithURL(AURL: NSURL): id; message 'playerWithURL:';
    procedure Play; message 'play';
    procedure Pause; message 'pause';
    procedure ReplaceCurrentItemWithPlayerItem(AItem: id);
      message 'replaceCurrentItemWithPlayerItem:';
  end;

  AVPlayerView = objcclass external (NSView)
    procedure SetPlayer(APlayer: AVPlayer); message 'setPlayer:';
    procedure SetControlsStyle(AStyle: NSInteger); message 'setControlsStyle:';
    procedure SetShowsFullScreenToggleButton(AShows: ObjCBOOL);
      message 'setShowsFullScreenToggleButton:';
  end;

var
  GDelegateClass: pobjc_class = nil;

function PlaybackDelegateClassName: string;
begin
  Result := DelegateClassName;
end;

{ Runtime-built method body. Recovers the owning Pascal object from the
  knipsOwner ivar; a nil owner means the window has already been taken
  down. Wrapped in try..except like every other cdecl body in the app:
  AppKit's own frames sit above this one and cannot unwind a Pascal
  exception. }

function OwnerOf(ASelf: id): TPlaybackWindow; inline;
begin
  Result := TPlaybackWindow(GetPointerIvar(ASelf, OwnerIvarName));
end;

procedure PlaybackWindowWillClose(ASelf: id; ACommand: SEL;
  ANotification: id); cdecl;
var
  Owner: TPlaybackWindow;
begin
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if Owner <> nil then
      Owner.HandleWindowWillClose;
  except
    on E: Exception do
      try
        if Owner <> nil then
          Owner.ReportError(WindowWillCloseSelector + ': ' + E.Message);
      except
        // Nothing left to try; swallowing beats unwinding into AppKit.
      end;
  end;
end;

{ NSWindowDelegate's veto. AppKit asks before it closes a window on the
  user's behalf: the titlebar's close button, performClose: and so ⌘W all
  come through here. -close does *not*, which is exactly right — that is
  what CommandClose uses, and Show's replace-the-previous-window path must
  not be something a delegate can refuse.

  So this makes the export guard authoritative for every close the *user*
  can ask for, rather than leaving the export's nil-checks to cope with a
  window that vanished underneath it. The window stays up, the title keeps
  counting, and the click is simply ignored — the same answer the three
  buttons give while they are disabled. }

function PlaybackWindowShouldClose(ASelf: id; ACommand: SEL;
  ASender: id): ObjCBOOL; cdecl;
var
  Owner: TPlaybackWindow;
begin
  // A window with no owner is one this object has already let go of;
  // refusing to close that would be a window nobody can get rid of.
  Result := ObjCBOOL(True);
  Owner := nil;
  try
    Owner := OwnerOf(ASelf);
    if (Owner <> nil) and Owner.Exporting then
      Result := ObjCBOOL(False);
  except
    on E: Exception do
      try
        if Owner <> nil then
          Owner.ReportError(WindowShouldCloseSelector + ': ' + E.Message);
      except
        // Nothing left to try; swallowing beats unwinding into AppKit.
      end;
  end;
end;

procedure EnsurePlaybackClasses;
var
  Builder: TRuntimeClassBuilder;
begin
  if GDelegateClass <> nil then
    Exit;
  GDelegateClass := LookUpClass(DelegateClassName);
  if GDelegateClass <> nil then
    Exit;
  Builder := TRuntimeClassBuilder.Create(DelegateClassName,
    DelegateSuperclassName);
  try
    if not Builder.AddPointerIvar(OwnerIvarName) then
      raise EObjCRuntime.Create('class_addIvar failed for ' + OwnerIvarName);
    if not Builder.AddMethod(WindowWillCloseSelector,
      @PlaybackWindowWillClose, MethodTypeEncoding(otVoid, [otObject])) then
      raise EObjCRuntime.Create('class_addMethod failed for '
        + WindowWillCloseSelector);
    if not Builder.AddMethod(WindowShouldCloseSelector,
      @PlaybackWindowShouldClose, MethodTypeEncoding(otBool, [otObject])) then
      raise EObjCRuntime.Create('class_addMethod failed for '
        + WindowShouldCloseSelector);
    // AppKit only ever asks respondsToSelector:, so a missing protocol is
    // not an error; claiming it when the runtime has one is tidier.
    Builder.AddProtocol('NSWindowDelegate');
    GDelegateClass := Builder.Register;
  finally
    Builder.Free;
  end;
end;

procedure Reveal(const APath: string);
begin
  NSWorkspace.sharedWorkspace.selectFile_inFileViewerRootedAtPath(
    PascalToNSString(APath), PascalToNSString(''));
end;

{ TPlaybackWindow }

destructor TPlaybackWindow.Destroy;
begin
  // Closing runs the delegate, which does the real teardown; if the
  // window has already gone this is a no-op.
  CommandClose;
  ReleasePlayer;
  ReleaseEffectsMenu;
  inherited Destroy;
end;

procedure TPlaybackWindow.ReleaseEffectsMenu;
begin
  FZoomItem := nil;
  FSmoothCursorItem := nil;
  FBigCursorItem := nil;
  FReasonItem := nil;
  if FEffectsMenu = nil then
    Exit;
  FEffectsMenu.release;
  FEffectsMenu := nil;
end;

function TPlaybackWindow.Visible: Boolean;
begin
  Result := FWindow <> nil;
end;

// The Effects pull-down, built left-to-right at the far end of the bar
// from the buttons. A pull-down's item 0 supplies the title and is never
// chosen, so the three effects are items 1 to 3 and the reason — when
// there is one — is an inert item under them.
//
// autoenablesItems is off for the same reason the app's own menu turns it
// off: AppKit would enable every item whose target answers the selector,
// and whether an effect *applies to this take* is not a question the
// responder chain can answer.
procedure TPlaybackWindow.BuildEffectsControl(AContent: NSView; ATarget: id;
  var ALeft: Double);

  function AddEffectItem(const ATitle, ASelector: string): NSMenuItem;
  begin
    Result := NSMenuItem(NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
      PascalToNSString(ATitle), SelectorNamed(ASelector),
      PascalToNSString('')));
    Result.setTarget(ATarget);
    FEffectsMenu.addItem(Result);
    Result.release;
  end;

var
  Size: NSSize;
begin
  FEffectsButton := NSPopUpButton(NSPopUpButton.alloc.initWithFrame_pullsDown(
    NSMakeRect(ALeft, 0, 140, BarHeight - 2 * BarPadding), True));
  FEffectsMenu := NSMenu(NSMenu.alloc.initWithTitle(
    PascalToNSString(EffectsMenuTitle)));
  FEffectsMenu.setAutoenablesItems(False);
  // And on the control as well as on the menu. NSPopUpButton keeps an
  // autoenablesItems of its own on its cell, and a control that decides
  // for itself which items are live would undo every setEnabled: in
  // RefreshEffects — which is the whole of "this take cannot take that
  // effect". Whether it actually overrides the menu's could not be
  // confirmed on this machine (the control cannot be clicked here), so
  // this is set defensively: it is a no-op if the menu's already wins,
  // and the difference between a correct control and a lying one if it
  // does not.
  FEffectsButton.setAutoenablesItems(False);
  // Item 0: the button's own title, never selected and never actioned.
  AddEffectItem(EffectsMenuTitle, '');
  FZoomItem := AddEffectItem(ZoomOnClickMenuTitle, ToggleEffectZoomSelector);
  FSmoothCursorItem := AddEffectItem(SmoothCursorMenuTitle,
    ToggleEffectSmoothCursorSelector);
  FBigCursorItem := AddEffectItem(BigCursorMenuTitle,
    ToggleEffectBigCursorSelector);
  FReasonItem := AddEffectItem('', '');
  FReasonItem.setEnabled(False);
  FReasonItem.setHidden(True);
  FEffectsButton.setMenu(FEffectsMenu);
  FEffectsButton.sizeToFit;
  Size := FEffectsButton.frame.size;
  FEffectsButton.setFrame(NSMakeRect(ALeft, (BarHeight - Size.height) / 2,
    Size.width, Size.height));
  FEffectsButton.setAutoresizingMask(NSViewMaxXMargin or NSViewMaxYMargin);
  AContent.addSubview(FEffectsButton);
  // addSubview: retains; balance the alloc.
  FEffectsButton.release;
  ALeft := ALeft + Size.width + ButtonGap;
end;

// Which effects this take can still be given, and why not when it cannot.
// Asked of the raw take, because that is what a re-export renders.
procedure TPlaybackWindow.LoadAvailability;
var
  Log: TSidecarLog;
  Available: TSidecarEffectAvailability;
  Error: string;
begin
  FCanDrawCursor := False;
  FCanZoom := False;
  FCursorReason := '';
  FZoomReason := '';
  FEffectsReason := '';
  if FRawPath = '' then
  begin
    // True of an old recording, of a window take that was never split,
    // and of one whose render failed and left the raw take on screen:
    // in every case there is no SEPARATE take to re-render from.
    FEffectsReason := 'there is no separate raw take for this recording, '
      + 'so its effects cannot be changed';
    FCursorReason := FEffectsReason;
    FZoomReason := FEffectsReason;
    Exit;
  end;
  Log := TSidecarLog.Create;
  try
    if not Log.LoadFromFile(SidecarPathFor(FRawPath), Error) then
    begin
      // The loader's own reason, not a guess at it. A load can fail for
      // any of the reasons LoadFromFile lists — the file is not there,
      // reading it raised, it is longer than the reader will hold, it
      // was written by a newer knips (TooNew), or it is not a knips
      // sidecar at all (ForeignFormat) — and this used to report every
      // one of them as the first. The version refusal in particular
      // exists to be SEEN: telling somebody their sidecar is missing
      // when it is sitting right there is worse than saying nothing.
      FEffectsReason := Error;
      FCursorReason := FEffectsReason;
      FZoomReason := FEffectsReason;
      Exit;
    end;
    Available := AvailableExportEffects(Log);
    FCanDrawCursor := Available.CanDrawCursor;
    FCanZoom := Available.CanZoomOnClick;
    FCursorReason := Available.CursorReason;
    FZoomReason := Available.ZoomReason;
    if not (FCanDrawCursor and FCanZoom) then
      FEffectsReason := Available.Reason;
  finally
    Log.Free;
  end;
end;

procedure TPlaybackWindow.RefreshEffects;
var
  Reason: string;
begin
  if FEffectsMenu = nil then
    Exit;
  FZoomItem.setEnabled(FCanZoom and not FExporting);
  FZoomItem.setState(MenuCheckState(FEffects.ZoomOnClick and FCanZoom));
  FSmoothCursorItem.setEnabled(FCanDrawCursor and not FExporting);
  FSmoothCursorItem.setState(MenuCheckState((FEffects.Cursor = ecmSmooth)
    and FCanDrawCursor));
  FBigCursorItem.setEnabled(FCanDrawCursor and not FExporting);
  FBigCursorItem.setState(MenuCheckState((FEffects.Cursor = ecmBig)
    and FCanDrawCursor));
  // The reason goes on the items it explains *and* on a line of its own:
  // a tooltip is where somebody looks once they have wondered, and a
  // greyed-out list with no explanation at all is what makes them wonder.
  if not FCanZoom then
    FZoomItem.setToolTip(PascalToNSString(FZoomReason));
  if not FCanDrawCursor then
  begin
    FSmoothCursorItem.setToolTip(PascalToNSString(FCursorReason));
    FBigCursorItem.setToolTip(PascalToNSString(FCursorReason));
  end;
  Reason := EffectsUnavailableTitle(FEffectsReason);
  FReasonItem.setHidden(Reason = '');
  if Reason <> '' then
    FReasonItem.setTitle(PascalToNSString(Reason));
  if FReexportButton <> nil then
    FReexportButton.setEnabled((FRawPath <> '') and not FExporting);
end;

// Right to left, so the rightmost button is the first one added and each
// call moves the edge left by its own width. Returned buttons stick to
// the bottom-right corner as the window is resized.
function TPlaybackWindow.AddButton(AContent: NSView;
  const ATitle, ASelector: string; ATarget: id; var ARight: Double): NSButton;
var
  Size: NSSize;
begin
  Result := NSButton(NSButton.alloc.initWithFrame(NSMakeRect(0, 0, 100,
    BarHeight - 2 * BarPadding)));
  Result.setTitle(PascalToNSString(ATitle));
  Result.setBezelStyle(NSRoundedBezelStyle);
  Result.sizeToFit;
  Size := Result.frame.size;
  Result.setFrame(NSMakeRect(ARight - Size.width,
    (BarHeight - Size.height) / 2, Size.width, Size.height));
  Result.setAutoresizingMask(NSViewMinXMargin or NSViewMaxYMargin);
  Result.setTarget(ATarget);
  Result.setAction(SelectorNamed(ASelector));
  AContent.addSubview(Result);
  // addSubview: retains; balance the alloc.
  Result.release;
  ARight := ARight - Size.width - ButtonGap;
end;

function TPlaybackWindow.Show(ATarget: id; const APath, ARawPath: string;
  APixelWidth, APixelHeight, AScale: Integer;
  const AEffects: TExportEffects): Boolean;
var
  ContentHeight, VideoHeight, Right, Left: Double;
  ContentRect: NSRect;
  Content: NSView;
  PlayerView: AVPlayerView;
begin
  // One window at a time: a second recording replaces the first rather
  // than stacking up players holding files open.
  CommandClose;
  ReleasePlayer;
  Result := False;
  if APath = '' then
    Exit;
  EnsurePlaybackClasses;

  FPath := APath;
  FRawPath := ARawPath;
  if (FRawPath <> '') and not FileExists(FRawPath) then
    // A raw take the user has tidied away is the same thing as never
    // having had one, and saying so beats a Re-export that fails.
    FRawPath := '';
  FEffects := AEffects;
  // With the effects, and for the same reason: this window is reused
  // take after take, and a note belongs to the take it was written
  // about. Without this, "no mic audio" from one recording sat in the
  // title of the next one that had perfectly good audio, for as long as
  // the app ran.
  FTitleNote := '';
  FPixelWidth := APixelWidth;
  FPixelHeight := APixelHeight;
  FScale := AScale;
  FExporting := False;
  FLastPercent := -1;
  LoadAvailability;

  if (APixelWidth > 0) and (APixelHeight > 0) then
    VideoHeight := ContentWidth * APixelHeight / APixelWidth
  else
    VideoHeight := ContentWidth * FallbackAspect;
  ContentHeight := VideoHeight + BarHeight;
  ContentRect := NSMakeRect(0, 0, ContentWidth, ContentHeight);

  FWindow := NSWindow(NSWindow.alloc
    .initWithContentRect_styleMask_backing_defer(ContentRect,
    NSTitledWindowMask or NSClosableWindowMask or NSMiniaturizableWindowMask
    or NSResizableWindowMask, NSBackingStoreBuffered, False));
  if FWindow = nil then
    Exit;
  // AppKit would otherwise release the window when the user closes it,
  // out from under the reference this object still holds.
  FWindow.setReleasedWhenClosed(False);
  FWindow.setTitle(PascalToNSString(ExtractFileName(APath)));
  FWindow.setContentMinSize(NSMakeSize(MinContentWidth, MinContentHeight));
  FWindow.center;

  Content := NSView(NSView.alloc.initWithFrame(ContentRect));
  FWindow.setContentView(Content);
  Content.release;

  PlayerView := AVPlayerView(AVPlayerView.alloc.initWithFrame(
    NSMakeRect(0, BarHeight, ContentWidth, VideoHeight)));
  if PlayerView = nil then
  begin
    FWindow.release;
    FWindow := nil;
    Exit;
  end;
  PlayerView.setAutoresizingMask(NSViewWidthSizable or NSViewHeightSizable);
  PlayerView.SetControlsStyle(AVPlayerViewControlsStyleInline);
  PlayerView.SetShowsFullScreenToggleButton(ObjCBOOL(True));
  FPlayer := AVPlayer.PlayerWithURL(NSURL.fileURLWithPath(
    PascalToNSString(APath)));
  if FPlayer <> nil then
  begin
    // +playerWithURL: is autoreleased; this window outlives the pool.
    AVPlayer(FPlayer).retain;
    PlayerView.SetPlayer(AVPlayer(FPlayer));
  end;
  Content.addSubview(PlayerView);
  PlayerView.release;
  FPlayerView := PlayerView;

  Right := ContentWidth - BarPadding;
  FCloseButton := AddButton(Content, CloseTitle, ClosePlaybackSelector,
    ATarget, Right);
  FRevealButton := AddButton(Content, RevealTitle, RevealRecordingSelector,
    ATarget, Right);
  FExportButton := AddButton(Content, ExportGifTitle, ExportGifSelector,
    ATarget, Right);
  FReexportButton := AddButton(Content, ReexportTitle, ReexportSelector,
    ATarget, Right);
  Left := BarPadding;
  BuildEffectsControl(Content, ATarget, Left);
  RefreshEffects;

  FDelegate := InstantiateClass(GDelegateClass);
  if FDelegate <> nil then
  begin
    SetPointerIvar(FDelegate, OwnerIvarName, Self);
    FWindow.setDelegate(NSWindowDelegateProtocol(FDelegate));
  end;

  // Accessory processes are not activated by ordering a window front; the
  // overlay needs the same nudge to receive its first click.
  NSApp.activateIgnoringOtherApps(True);
  FWindow.makeKeyAndOrderFront(nil);
  Result := True;
end;

procedure TPlaybackWindow.ReleasePlayer;
begin
  if FPlayer = nil then
    Exit;
  AVPlayer(FPlayer).Pause;
  // Dropping the item first closes the file the player has open; the
  // GIF export reads the same path through its own AVAssetReader.
  AVPlayer(FPlayer).ReplaceCurrentItemWithPlayerItem(nil);
  AVPlayer(FPlayer).release;
  FPlayer := nil;
end;

procedure TPlaybackWindow.CommandClose;
begin
  if FWindow = nil then
    Exit;
  // Never mid-export: closing under a running export would free the
  // window the progress callback is still writing to. This is the guard
  // for the paths that come through here — the Close button, a recording
  // about to start, Quit, Show replacing the window. The paths AppKit
  // drives on the user's behalf (the titlebar's button, ⌘W) never reach
  // this method at all, and are refused in windowShouldClose: instead.
  if FExporting then
    Exit;
  // -close, not -performClose:. Both end in windowWillClose: and so in
  // the same teardown, but -close posts the notification synchronously,
  // and Show relies on that: it closes the previous window before
  // building the new one, and a deferred teardown would arrive with the
  // new window's fields in place and take them down instead.
  FWindow.close;
end;

// The single teardown path: the titlebar's close button, performClose:,
// and Destroy all arrive here.
procedure TPlaybackWindow.HandleWindowWillClose;
begin
  try
    if FPlayerView <> nil then
    begin
      AVPlayerView(FPlayerView).SetPlayer(nil);
      FPlayerView := nil;
    end;
    ReleasePlayer;
    FExportButton := nil;
    FRevealButton := nil;
    FCloseButton := nil;
    FReexportButton := nil;
    // The pull-down goes with the content view the window releases; the
    // reference does not, and neither does its menu, which this object
    // owns (setMenu: retains what BuildEffectsControl alloc'd). Both have
    // to be dropped HERE and not only in the destructor: the destructor
    // runs once, at quit, while this runs once per take — Show closes the
    // previous window and builds a new control, so a menu left behind
    // here is a menu leaked per recording.
    //
    // Nilling them is load-bearing for more than the leak. RefreshEffects
    // guards on `FEffectsMenu = nil`, and FEffectsButton and
    // FReexportButton would otherwise point into a view hierarchy that
    // has been deallocated.
    FEffectsButton := nil;
    ReleaseEffectsMenu;
    if FWindow <> nil then
    begin
      FWindow.setDelegate(nil);
      // Runs from inside AppKit's own close dispatch; the last release has
      // to wait for the pool, exactly as the overlay's windows do.
      FWindow.autorelease;
      FWindow := nil;
    end;
    if FDelegate <> nil then
    begin
      SetPointerIvar(FDelegate, OwnerIvarName, nil);
      // This runs *on* FDelegate, inside NSNotificationCenter's dispatch
      // of windowWillClose:. A plain release would free the receiver while
      // the frame below is still executing on it — the pool has to take
      // it, the same way the window two lines up is autoreleased.
      AutoreleaseInstance(FDelegate);
      FDelegate := nil;
    end;
  finally
    // In the finally, and last, so that a raise anywhere in the teardown
    // cannot skip it: the window is going either way, and the
    // process-level consequences of that — the Dock tile, the menu bar —
    // are the controller's to undo. It is also the only place they can be
    // undone from, so leaving them standing is the worse leak. By now
    // every field the handler could reach through is nil — the window,
    // the player, the delegate, all five buttons and the Effects control
    // — so it is free to ask Visible. (FPath, FRawPath and FEffects are
    // deliberately kept: they are what this object *is*, not what it
    // draws with.) Whatever it raises is caught by the cdecl body above
    // and reported like any other failure.
    if Assigned(FOnClosed) then
      FOnClosed;
  end;
end;

procedure TPlaybackWindow.CommandReveal;
begin
  if FPath <> '' then
    Reveal(FPath);
end;

procedure TPlaybackWindow.SetButtonsEnabled(AEnabled: Boolean);
begin
  if FExportButton <> nil then
    FExportButton.setEnabled(AEnabled);
  if FRevealButton <> nil then
    FRevealButton.setEnabled(AEnabled);
  if FCloseButton <> nil then
    FCloseButton.setEnabled(AEnabled);
  if FReexportButton <> nil then
    FReexportButton.setEnabled(AEnabled and (FRawPath <> ''));
  if FEffectsButton <> nil then
    FEffectsButton.setEnabled(AEnabled);
end;

// Dequeues and dispatches whatever events are already waiting, without
// ever blocking. Dispatching (not dropping) keeps window moves and the
// titlebar close button honest; commands are inert behind the Busy
// lockout.
procedure DrainPendingEvents;
var
  Event: NSEvent;
begin
  repeat
    Event := NSApp.nextEventMatchingMask_untilDate_inMode_dequeue(
      NSAnyEventMask, nil, NSDefaultRunLoopMode, True);
    if Event <> nil then
      NSApp.sendEvent(Event);
  until Event = nil;
end;

procedure TPlaybackWindow.HandleProgress(AStage: TGifExportStage;
  AFramesDone, AFramesTotal, ABytesWritten: Int64);
var
  Percent: Integer;
  Size: string;
begin
  // Service the event queue on EVERY frame, not just whole percents: the
  // window server shows the beachball when the app stops DEQUEUEING
  // events for a few seconds, and on a long export one percent can take
  // longer than that. untilDate nil never waits — this drains what is
  // pending and returns. The Busy lockout keeps anything it dispatches
  // from acting; the zero-timeout slice below is what lets the
  // CoreAnimation commit draw the new title. Deliberately BEFORE the
  // window check: closing the window mid-export must not stop the
  // draining, or the beachball returns for the rest of the export.
  DrainPendingEvents;
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, True);
  if FWindow = nil then
    Exit;
  Percent := ExportPercent(AStage = gesPalette, AFramesDone, AFramesTotal);
  // Only whole percents reach AppKit; a per-frame setTitle: on a long
  // recording is thousands of layout passes for the same string.
  if Percent = FLastPercent then
    Exit;
  FLastPercent := Percent;
  // The size the export is heading for. Before a byte is written that is
  // the pre-export estimate; from the first written frame on it is the
  // projection from what the encoder has actually produced, which is a
  // much better number and replaces the estimate rather than joining it.
  Size := '';
  if ABytesWritten > 0 then
    Size := FormatByteSize(ProjectExportSize(ABytesWritten, AFramesDone,
      AFramesTotal))
  else if (FEstimateSource <> nil)
    and (FEstimateSource.Report.EstimatedBytes > 0) then
    Size := FormatByteSize(FEstimateSource.Report.EstimatedBytes);
  FWindow.setTitle(PascalToNSString(ExportProgressTitleWithSize(Percent,
    Size)));
  // setTitle: alone only marks the titlebar dirty and pushes the string
  // to the window server; the *drawn* title comes from a CoreAnimation
  // commit, which runs as a run-loop observer. Without a turn of the run
  // loop the user sees the old title for the whole export — measured on
  // device: five window captures across a 4.2 s export were byte
  // identical while the window server's title property counted up.
  //
  // One slice, zero timeout, returning as soon as a source is handled:
  // enough for the kCFRunLoopExit observer that commits the transaction,
  // and as little event dispatch as this can be asked to do. It is still
  // event dispatch, which is why the controller locks every command out
  // while an export is running (TAppController.Transition).
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, True);
end;

procedure TPlaybackWindow.CommandExportGif;
var
  Options: TExportOptions;
  Session: TExportSession;
  Pool: NSAutoreleasePool;
  Error, Note: string;
  Succeeded: Boolean;
  WarnWidth, WarnHeight: Integer;
  WarnBytes: Int64;
begin
  if (FWindow = nil) or FExporting or (FPath = '') then
    Exit;
  Note := '';
  WarnWidth := 0;
  WarnHeight := 0;
  WarnBytes := 0;
  Options := DefaultExportOptions;
  // The GIF comes off the RAW take when there is one, with the same
  // effects the deliverable was rendered with. Exporting the deliverable
  // instead would draw the pointer a second time on top of the one
  // already in its pixels, and zoom a picture that is already zoomed —
  // its own sidecar says as much, and this is the other half of saying it.
  if FRawPath <> '' then
    Options.InputPath := FRawPath
  else
    Options.InputPath := FPath;
  Options.OutputPath := GifPathForRecording(FPath);
  Options.FramesPerSecond := AppGifFramesPerSecond;
  Options.Width := AppGifWidth(FPixelWidth, FScale);
  // The one selection, applied to all three sinks. Effects the take
  // cannot take are dropped here rather than left to fail quietly
  // downstream — the control already greys them out, and a saved default
  // from another take must not reach an export that cannot honour it.
  Options.Effects := FEffects;
  if not FCanZoom then
    Options.Effects.ZoomOnClick := False;
  if not FCanDrawCursor then
    Options.Effects.Cursor := ecmAsRecorded;
  if not ValidateExportOptions(Options, Error) then
  begin
    ReportError(Error);
    Exit;
  end;

  FExporting := True;
  FLastPercent := -1;
  SetButtonsEnabled(False);
  FWindow.setTitle(PascalToNSString(ExportProgressTitle(0)));
  // Stop playback before the reader opens the same file: two decoders on
  // one movie is work nobody watches.
  if FPlayer <> nil then
    AVPlayer(FPlayer).Pause;

  Succeeded := False;
  Error := '';
  // The buttons must come back and the flag must clear however this
  // ends. Without the finally, a raise anywhere in the pipeline leaves
  // the window disabled with no way back short of quitting.
  try
    // Each progress turn drains the run loop's own pool, but the export
    // between them does not; the per-frame autoreleases need this one.
    Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
    try
      Session := TExportSession.Create(Options);
      try
        // No console under an app bundle; the title is the progress
        // report.
        Session.Verbose := False;
        Session.OnProgress := HandleProgress;
        // Filled by the session as soon as the output size is settled,
        // which is before the first progress callback of the encode pass
        // and (for a GIF) before the palette pass has finished; reading
        // it from the report each time is what lets the title show the
        // estimate until there is a projection to replace it.
        FEstimateSource := Session;
        Succeeded := Session.Run(Error);
        if Succeeded then
        begin
          WarnWidth := Session.Report.PixelWidth;
          WarnHeight := Session.Report.PixelHeight;
          WarnBytes := Session.Report.OutputBytes;
          // Read before the session goes, exactly as the Re-export path
          // reads the render's. An export that SUCCEEDS can still have
          // failed to apply what was asked for — a zoom on a take whose
          // capture was already zooming, a pointer on a take that has
          // one in its pixels — and this button used to say nothing at
          // all about that while the button beside it said everything.
          Note := Session.Report.Note;
        end;
      finally
        FEstimateSource := nil;
        Session.Free;
      end;
    finally
      Pool.release;
    end;
  finally
    FExporting := False;
    SetButtonsEnabled(True);
    if FWindow <> nil then
      FWindow.setTitle(PascalToNSString(TitleWithNote));
  end;
  // After FExporting has been cleared, or SetTitleNote refuses to touch
  // the title. Same order, same two surfaces, as the Re-export path.
  SetTitleNote(Note);
  if Note <> '' then
    ReportError('export: ' + Note);
  if Succeeded then
  begin
    // The CLI prints this advice on stderr; the app has no stderr, so a
    // large result lands on the same "Last error" line everything else
    // uses — advisory, not failure, and the export did complete.
    Error := LargeExportWarning(efGif, WarnWidth, WarnHeight,
      Options.FramesPerSecond, WarnBytes);
    if Error <> '' then
      ReportError(Error);
    Reveal(Options.OutputPath);
  end
  else
    ReportError('GIF export: ' + Error);
end;

// One turn of the render's progress into the window's title. The same
// shape as the export's — drain, set, drain — and for the same reason:
// the window server shows the beachball when an app stops dequeueing
// events, and a render of a long take runs for seconds.
procedure TPlaybackWindow.HandleRenderProgress(AFramesDone,
  AFramesTotal: Int64);
var
  Percent: Integer;
begin
  DrainPendingEvents;
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, True);
  if FWindow = nil then
    Exit;
  Percent := RenderPercent(AFramesDone, AFramesTotal);
  if Percent = FLastPercent then
    Exit;
  FLastPercent := Percent;
  FWindow.setTitle(PascalToNSString(RenderProgressTitle(Percent)));
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, True);
end;

// The player is dropped before a re-export and rebuilt after it: the file
// under it is about to be replaced, and a player holding the old inode
// would go on showing a movie that is no longer there.
procedure TPlaybackWindow.ReloadPlayer;
begin
  ReleasePlayer;
  if (FPlayerView = nil) or (FPath = '') then
    Exit;
  FPlayer := AVPlayer.PlayerWithURL(NSURL.fileURLWithPath(
    PascalToNSString(FPath)));
  if FPlayer = nil then
    Exit;
  AVPlayer(FPlayer).retain;
  AVPlayerView(FPlayerView).SetPlayer(AVPlayer(FPlayer));
end;

procedure TPlaybackWindow.ApplyCursorEffect(AWanted: TExportCursorMode);
begin
  if (FWindow = nil) or FExporting or not FCanDrawCursor then
    Exit;
  FEffects.Cursor := ToggledEffectCursor(FEffects.Cursor, AWanted);
  RefreshEffects;
  if Assigned(FOnEffectsChanged) then
    FOnEffectsChanged(FEffects);
end;

procedure TPlaybackWindow.CommandToggleEffectZoom;
begin
  if (FWindow = nil) or FExporting or not FCanZoom then
    Exit;
  FEffects.ZoomOnClick := not FEffects.ZoomOnClick;
  RefreshEffects;
  if Assigned(FOnEffectsChanged) then
    FOnEffectsChanged(FEffects);
end;

procedure TPlaybackWindow.CommandToggleEffectSmoothCursor;
begin
  ApplyCursorEffect(ecmSmooth);
end;

procedure TPlaybackWindow.CommandToggleEffectBigCursor;
begin
  ApplyCursorEffect(ecmBig);
end;

// Re-render the deliverable from the raw take with what the control now
// says, in place. Inline on the main thread, exactly like the GIF export
// and for the same reason: the render pass is synchronous and nothing
// here may pump a nested run loop. FExporting is the same lockout, so a
// close, a second click and a new recording are all refused while it runs.
procedure TPlaybackWindow.CommandReexport;
var
  Session: TRenderSession;
  Pool: NSAutoreleasePool;
  Effects: TExportEffects;
  Error, Note: string;
  Succeeded: Boolean;
begin
  if (FWindow = nil) or FExporting or (FPath = '') then
    Exit;
  if FRawPath = '' then
  begin
    ReportError(FEffectsReason);
    Exit;
  end;
  Effects := FEffects;
  if not FCanZoom then
    Effects.ZoomOnClick := False;
  if not FCanDrawCursor then
    Effects.Cursor := ecmAsRecorded;

  FExporting := True;
  FLastPercent := -1;
  SetButtonsEnabled(False);
  RefreshEffects;
  FWindow.setTitle(PascalToNSString(RenderProgressTitle(0)));
  // The player has the file open and the render is about to replace it.
  ReleasePlayer;

  Succeeded := False;
  Error := '';
  Note := '';
  try
    Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
    try
      Session := TRenderSession.Create(FRawPath, FPath, Effects);
      // Effects turned all the way off in the pull-down is a request for
      // the raw pixels as the deliverable, exactly as `--effects=none`
      // is on the CLI — and the window must still end up with a file to
      // play.
      Session.ExplicitCopy := not EffectsAskForAnything(Effects);
      try
        // No console under an app bundle; the title is the report.
        Session.Verbose := False;
        Session.OnProgress := HandleRenderProgress;
        Succeeded := Session.Run(Error);
        // Read before the session goes. A render that SUCCEEDS can
        // still have failed to apply what was asked for — a zoom on a
        // take nobody clicked in, a pointer that was never in shot,
        // frames past the end of the track — and the whole point of
        // this window's Effects control is to say which. The report was
        // thrown away here, so the user pressed Re-export, watched a
        // progress title, and got a file with nothing changed in it and
        // not a word about why.
        if Succeeded then
          Note := Session.Report.Note;
      finally
        Session.Free;
      end;
    finally
      Pool.release;
    end;
  finally
    FExporting := False;
    SetButtonsEnabled(True);
    RefreshEffects;
    ReloadPlayer;
  end;
  if not Succeeded then
    ReportError('re-export: ' + Error);
  // After FExporting has been cleared, or SetTitleNote refuses to touch
  // the title. A render that applied everything asked for leaves this
  // empty, which clears whatever the previous one said.
  SetTitleNote(Note);
  if Note <> '' then
    ReportError('re-export: ' + Note);
end;

procedure TPlaybackWindow.SetTitleNote(const ANote: string);
begin
  FTitleNote := ANote;
  if (FWindow = nil) or FExporting or (FPath = '') then
    Exit;
  FWindow.setTitle(PascalToNSString(TitleWithNote));
end;

function TPlaybackWindow.TitleWithNote: string;
begin
  Result := ExtractFileName(FPath);
  if FTitleNote <> '' then
    Result := Result + ' · ' + FTitleNote;
end;

procedure TPlaybackWindow.ReportError(const AMessage: string);
begin
  if Assigned(FOnError) then
    FOnError(AMessage);
end;

{$ENDIF}

end.

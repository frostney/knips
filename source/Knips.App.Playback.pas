unit Knips.App.Playback;

// What a finished recording opens into: an ordinary titled window with an
// AVPlayerView playing the file that was just written, and three buttons
// under it — Export as GIF…, Reveal in Finder, Close.
//
// Standard chrome on purpose. The titlebar is AppKit's, the close button
// is AppKit's, the transport controls are AVKit's; the only thing this
// unit draws is a row of NSButtons. `knips app` stays an Accessory
// process, so the window is brought forward with
// activateIgnoringOtherApps: the same way the selection overlay is — a
// titled window can become key under that policy, a borderless one
// cannot, which is why the overlay needed a runtime class for it and this
// does not.
//
// The buttons' target is the app's own KnipsAppTarget (the selectors are
// declared below and registered by Knips.App), so there is exactly one
// runtime-built class in this unit: KnipsPlaybackDelegate, whose only
// method is windowWillClose:. That is where the player is paused and let
// go — the user closing the window is the only teardown path that does
// not come through this class's own API.
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

{$I Shared.inc}
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
  Knips.ObjC.Runtime,
  Knips.Options,
  MacOSAll;

const
  // Actions on KnipsAppTarget; Knips.App registers them and forwards each
  // to the matching command below.
  ExportGifSelector = 'exportGif:';
  RevealRecordingSelector = 'revealRecording:';
  ClosePlaybackSelector = 'closePlayback:';

type
  // Reported from inside an Objective-C callback or a failed export; the
  // app puts it on the same NSLog + "Last error" path as everything else.
  TPlaybackErrorEvent = procedure(const AMessage: string) of object;

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
    FPath: string;
    FPixelWidth: Integer;
    FPixelHeight: Integer;
    FExporting: Boolean;
    FLastPercent: Integer;
    FOnError: TPlaybackErrorEvent;
    function AddButton(AContent: NSView; const ATitle, ASelector: string;
      ATarget: id; var ARight: Double): NSButton;
    procedure SetButtonsEnabled(AEnabled: Boolean);
    procedure HandleProgress(AStage: TGifExportStage;
      AFramesDone, AFramesTotal: Int64);
    procedure ReleasePlayer;
  public
    destructor Destroy; override;
    // Opens the window on APath. APixelWidth/Height come from the
    // recording's report and only set the initial aspect ratio; a zero
    // pair falls back to 16:9. False when the window could not be made.
    // Raises EObjCRuntime when the delegate class cannot be registered.
    function Show(ATarget: id; const APath: string;
      APixelWidth, APixelHeight: Integer): Boolean;
    // Asks AppKit to close, which arrives back as windowWillClose:.
    procedure CommandClose;
    procedure CommandReveal;
    procedure CommandExportGif;
    // Called by the runtime-built delegate's method body.
    procedure HandleWindowWillClose;
    procedure ReportError(const AMessage: string);
    function Visible: Boolean;
    property Path: string read FPath;
    property Exporting: Boolean read FExporting;
    property OnError: TPlaybackErrorEvent read FOnError write FOnError;
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
  OwnerIvarName = 'knipsOwner';
  WindowWillCloseSelector = 'windowWillClose:';

  ExportGifTitle = 'Export as GIF…';
  RevealTitle = 'Reveal in Finder';
  CloseTitle = 'Close';

  // Points. Wide enough that a Retina region recording is legible at 1:1
  // or better, narrow enough to sit next to what was recorded.
  ContentWidth = 720;
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
  inherited Destroy;
end;

function TPlaybackWindow.Visible: Boolean;
begin
  Result := FWindow <> nil;
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

function TPlaybackWindow.Show(ATarget: id; const APath: string;
  APixelWidth, APixelHeight: Integer): Boolean;
var
  ContentHeight, VideoHeight, Right: Double;
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
  FPixelWidth := APixelWidth;
  FPixelHeight := APixelHeight;
  FExporting := False;
  FLastPercent := -1;

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
  // Never mid-export: the buttons are disabled, but the titlebar's close
  // button is AppKit's and stays live. Closing under a running export
  // would free the window the progress callback is still writing to.
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
  if FPlayerView <> nil then
  begin
    AVPlayerView(FPlayerView).SetPlayer(nil);
    FPlayerView := nil;
  end;
  ReleasePlayer;
  FExportButton := nil;
  FRevealButton := nil;
  FCloseButton := nil;
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
    // This runs *on* FDelegate, inside NSNotificationCenter's dispatch of
    // windowWillClose:. A plain release would free the receiver while the
    // frame below is still executing on it — the pool has to take it, the
    // same way the window two lines up is autoreleased.
    AutoreleaseInstance(FDelegate);
    FDelegate := nil;
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
end;

procedure TPlaybackWindow.HandleProgress(AStage: TGifExportStage;
  AFramesDone, AFramesTotal: Int64);
var
  Percent: Integer;
begin
  if FWindow = nil then
    Exit;
  Percent := ExportPercent(AStage = gesPalette, AFramesDone, AFramesTotal);
  // Only whole percents reach AppKit; a per-frame setTitle: on a long
  // recording is thousands of layout passes for the same string.
  if Percent = FLastPercent then
    Exit;
  FLastPercent := Percent;
  FWindow.setTitle(PascalToNSString(ExportProgressTitle(Percent)));
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
  Error: string;
  Succeeded: Boolean;
begin
  if (FWindow = nil) or FExporting or (FPath = '') then
    Exit;
  Options := DefaultExportOptions;
  Options.InputPath := FPath;
  Options.OutputPath := GifPathForRecording(FPath);
  Options.FramesPerSecond := AppGifFramesPerSecond;
  Options.Width := AppGifWidth(FPixelWidth);
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
        Succeeded := Session.Run(Error);
      finally
        Session.Free;
      end;
    finally
      Pool.release;
    end;
  finally
    FExporting := False;
    SetButtonsEnabled(True);
    if FWindow <> nil then
      FWindow.setTitle(PascalToNSString(ExtractFileName(FPath)));
  end;
  if Succeeded then
    Reveal(Options.OutputPath)
  else
    ReportError('GIF export: ' + Error);
end;

procedure TPlaybackWindow.ReportError(const AMessage: string);
begin
  if Assigned(FOnError) then
    FOnError(AMessage);
end;

{$ENDIF}

end.

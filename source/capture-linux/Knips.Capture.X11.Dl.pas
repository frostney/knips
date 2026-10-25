unit Knips.Capture.X11.Dl;

// MIT-SHM screen grabs through libX11 and libXext, loaded at run time.
//
// ADR-0006: the Linux recorder links no X11 library. FreePascal's own
// `xlib` and `xshm` units bind libX11 and libXext at link time, which
// would make `knips` and `knips mcp` refuse to start on a machine without
// X11 installed (and a Wayland-only machine is exactly that), so this unit
// declares the dozen entry points it needs itself and finds them with
// dlopen. A machine without X11 gets a one-line refusal from `knips
// record`, and everything else in the binary still runs.
//
// The grab itself is the spike's (Knips.Capture.X11): XShmGetImage into a
// System V segment both processes map, on the root window. What this unit
// adds is the part a recorder needs and a spike does not — a protocol
// error is a return value, a lost display is reported to a handler that
// can finish the file before the process ends, and nothing here is linked.
//
// Xlib is not thread-safe unless XInitThreads is called first, and the
// error handlers below are process-wide. The recorder calls into this unit
// from one thread only.

{$I Knips.inc}

interface

{$IFDEF LINUX}

uses
  ctypes,
  SysUtils;

type
  // What Xlib tells the IO error handler. It must not return: Xlib calls
  // exit() when it does.
  TX11IOErrorHandler = function(ADisplay: Pointer): cint; cdecl;

  {$PACKRECORDS C}
  // XShmSegmentInfo from <X11/extensions/XShm.h>.
  TX11SegmentInfo = record
    ShmSeg: culong;
    ShmId: cint;
    ShmAddr: PChar;
    ReadOnly: cint;
  end;
  {$PACKRECORDS DEFAULT}

  TX11Grabber = class
  private
    FDisplay: Pointer;
    FRoot: culong;
    FScreen: cint;
    FImage: Pointer;
    FSegmentId: cint;
    FSegmentAddress: Pointer;
    FSegmentInfo: TX11SegmentInfo;
    FAttached: Boolean;
    FWidth: Integer;
    FHeight: Integer;
    FLeft: Integer;
    FTop: Integer;
    FScreenWidth: Integer;
    FScreenHeight: Integer;
    FBytesPerLine: Integer;
    procedure ReleaseFrame;
  public
    constructor Create;
    destructor Destroy; override;
    // ADisplayName empty means $DISPLAY. Fails with a plain sentence if
    // libX11 or libXext is missing, the display cannot be opened, MIT-SHM
    // is absent, or the screen is not 24/32-bit little-endian BGRX.
    function Open(const ADisplayName: string; out AError: string): Boolean;
    // Allocates the shared image for the rectangle (ALeft, ATop, AWidth,
    // AHeight) of the screen. Call once; the rectangle is fixed.
    function Prepare(ALeft, ATop, AWidth, AHeight: Integer;
      out AError: string): Boolean;
    // Copies the prepared rectangle into the shared image. A protocol
    // error (BadMatch after a resize, a lost server) is a False and a
    // sentence, not an exit(1).
    function Grab(out AError: string): Boolean;
    // XSync: round-trips to the server, which is what makes a dead server
    // visible to the IO error handler.
    procedure Sync;
    // Fills the root window with a colour. For tests that need a known
    // pattern; the recorder never draws on the screen it records.
    function PaintRoot(ARed, AGreen, ABlue: Byte; out AError: string): Boolean;
    function Pixels: PByte;
    property ScreenWidth: Integer read FScreenWidth;
    property ScreenHeight: Integer read FScreenHeight;
    property FrameWidth: Integer read FWidth;
    property FrameHeight: Integer read FHeight;
    // Bytes from the start of one row of the shared image to the next.
    property BytesPerLine: Integer read FBytesPerLine;
  end;

// Makes Xlib call AHandler instead of exit() when the connection to the X
// server is lost. The handler runs on the thread that was inside Xlib, may
// do anything except call Xlib, and must end the process.
procedure SetX11IOErrorHandler(AHandler: TX11IOErrorHandler);

{$ENDIF}

implementation

{$IFDEF LINUX}

uses
  dynlibs,
  ipc;

const
  LibX11Names: array[0..1] of string = ('libX11.so.6', 'libX11.so');
  LibXextNames: array[0..1] of string = ('libXext.so.6', 'libXext.so');

  LSBFirst = 0;
  ZPixmap = 2;
  AllPlanes = culong(High(culong));
  IpcPrivate = 0;
  // 0600: the segment is private to this process and the X server's
  // mapping of it.
  SegmentPermissions = $180;

type
  {$PACKRECORDS C}
  // The first fields of Xlib's XImage, in the order <X11/Xlib.h> gives
  // them. XShmCreateImage allocates the structure; this unit only reads
  // through it, so the function-pointer table that follows is not
  // declared.
  PXImagePrefix = ^TXImagePrefix;
  TXImagePrefix = record
    Width: cint;
    Height: cint;
    XOffset: cint;
    Format: cint;
    Data: PChar;
    ByteOrder: cint;
    BitmapUnit: cint;
    BitmapBitOrder: cint;
    BitmapPad: cint;
    Depth: cint;
    BytesPerLine: cint;
    BitsPerPixel: cint;
    RedMask: culong;
    GreenMask: culong;
    BlueMask: culong;
  end;

  // XErrorEvent from <X11/Xlib.h>.
  PXErrorEvent = ^TXErrorEvent;
  TXErrorEvent = record
    EventType: cint;
    Display: Pointer;
    ResourceId: culong;
    Serial: culong;
    ErrorCode: cuchar;
    RequestCode: cuchar;
    MinorCode: cuchar;
  end;
  {$PACKRECORDS DEFAULT}

  TXErrorHandler = function(ADisplay: Pointer;
    AEvent: PXErrorEvent): cint; cdecl;

  TXOpenDisplay = function(AName: PChar): Pointer; cdecl;
  TXCloseDisplay = function(ADisplay: Pointer): cint; cdecl;
  TXDefaultScreen = function(ADisplay: Pointer): cint; cdecl;
  TXRootWindow = function(ADisplay: Pointer; AScreen: cint): culong; cdecl;
  TXDisplayDimension = function(ADisplay: Pointer; AScreen: cint): cint;
    cdecl;
  TXDefaultDepth = function(ADisplay: Pointer; AScreen: cint): cint; cdecl;
  TXDefaultVisual = function(ADisplay: Pointer; AScreen: cint): Pointer;
    cdecl;
  TXSync = function(ADisplay: Pointer; ADiscard: cint): cint; cdecl;
  TXSetErrorHandler = function(AHandler: TXErrorHandler): TXErrorHandler;
    cdecl;
  TXSetIOErrorHandler = function(
    AHandler: TX11IOErrorHandler): TX11IOErrorHandler; cdecl;
  TXGetErrorText = function(ADisplay: Pointer; ACode: cint; ABuffer: PChar;
    ALength: cint): cint; cdecl;
  TXDestroyImage = function(AImage: Pointer): cint; cdecl;
  TXShmQueryExtension = function(ADisplay: Pointer): cint; cdecl;
  TXShmQueryVersion = function(ADisplay: Pointer; AMajor, AMinor,
    APixmaps: pcint): cint; cdecl;
  TXShmCreateImage = function(ADisplay: Pointer; AVisual: Pointer;
    ADepth: cuint; AFormat: cint; AData: PChar; AInfo: Pointer;
    AWidth, AHeight: cuint): Pointer; cdecl;
  TXShmAttach = function(ADisplay: Pointer; AInfo: Pointer): cint; cdecl;
  TXShmDetach = function(ADisplay: Pointer; AInfo: Pointer): cint; cdecl;
  TXShmGetImage = function(ADisplay: Pointer; ADrawable: culong;
    AImage: Pointer; AX, AY: cint; APlaneMask: culong): cint; cdecl;
  // Core request used only by PaintRoot.
  TXCreateGC = function(ADisplay: Pointer; ADrawable: culong;
    AMask: culong; AValues: Pointer): Pointer; cdecl;
  TXFreeGC = function(ADisplay: Pointer; AContext: Pointer): cint; cdecl;
  TXSetForeground = function(ADisplay: Pointer; AContext: Pointer;
    AColour: culong): cint; cdecl;
  TXFillRectangle = function(ADisplay: Pointer; ADrawable: culong;
    AContext: Pointer; AX, AY: cint; AWidth, AHeight: cuint): cint; cdecl;

var
  LibX11: TLibHandle = NilHandle;
  LibXext: TLibHandle = NilHandle;
  LoadFailure: string = '';

  XOpenDisplay: TXOpenDisplay;
  XCloseDisplay: TXCloseDisplay;
  XDefaultScreen: TXDefaultScreen;
  XRootWindow: TXRootWindow;
  XDisplayWidth: TXDisplayDimension;
  XDisplayHeight: TXDisplayDimension;
  XDefaultDepth: TXDefaultDepth;
  XDefaultVisual: TXDefaultVisual;
  XSync: TXSync;
  XSetErrorHandler: TXSetErrorHandler;
  XSetIOErrorHandler: TXSetIOErrorHandler;
  XGetErrorText: TXGetErrorText;
  XDestroyImage: TXDestroyImage;
  XCreateGC: TXCreateGC;
  XFreeGC: TXFreeGC;
  XSetForeground: TXSetForeground;
  XFillRectangle: TXFillRectangle;
  XShmQueryExtension: TXShmQueryExtension;
  XShmQueryVersion: TXShmQueryVersion;
  XShmCreateImage: TXShmCreateImage;
  XShmAttach: TXShmAttach;
  XShmDetach: TXShmDetach;
  XShmGetImage: TXShmGetImage;

function LoadFirst(const ANames: array of string): TLibHandle;
var
  I: Integer;
begin
  Result := NilHandle;
  for I := 0 to High(ANames) do
  begin
    Result := LoadLibrary(ANames[I]);
    if Result <> NilHandle then
      Exit;
  end;
end;

// Stores the address of AName in AProc, which is any procedural variable.
// Untyped, so the variable itself is passed and not a call through it.
procedure Bind(ALibrary: TLibHandle; const AName: string; var AProc);
begin
  Pointer(AProc) := GetProcAddress(ALibrary, AName);
  if (Pointer(AProc) = nil) and (LoadFailure = '') then
    LoadFailure := 'libX11/libXext does not export ' + AName;
end;

// Loads both libraries and every entry point once. Failure is remembered,
// so a second call costs nothing and says the same thing.
function LoadXlib(out AError: string): Boolean;
begin
  AError := '';
  if LoadFailure <> '' then
  begin
    AError := LoadFailure;
    Exit(False);
  end;
  if LibXext <> NilHandle then
    Exit(True);
  LibX11 := LoadFirst(LibX11Names);
  if LibX11 = NilHandle then
    LoadFailure := 'libX11 is not installed, so there is no X11 screen to '
      + 'record (a Wayland-only session is not supported yet)'
  else
  begin
    LibXext := LoadFirst(LibXextNames);
    if LibXext = NilHandle then
      LoadFailure := 'libXext is not installed, so MIT-SHM screen capture '
        + 'is unavailable';
  end;
  if LoadFailure = '' then
  begin
    Bind(LibX11, 'XOpenDisplay', XOpenDisplay);
    Bind(LibX11, 'XCloseDisplay', XCloseDisplay);
    Bind(LibX11, 'XDefaultScreen', XDefaultScreen);
    Bind(LibX11, 'XRootWindow', XRootWindow);
    Bind(LibX11, 'XDisplayWidth', XDisplayWidth);
    Bind(LibX11, 'XDisplayHeight', XDisplayHeight);
    Bind(LibX11, 'XDefaultDepth', XDefaultDepth);
    Bind(LibX11, 'XDefaultVisual', XDefaultVisual);
    Bind(LibX11, 'XSync', XSync);
    Bind(LibX11, 'XSetErrorHandler', XSetErrorHandler);
    Bind(LibX11, 'XSetIOErrorHandler', XSetIOErrorHandler);
    Bind(LibX11, 'XGetErrorText', XGetErrorText);
    Bind(LibX11, 'XDestroyImage', XDestroyImage);
    Bind(LibX11, 'XCreateGC', XCreateGC);
    Bind(LibX11, 'XFreeGC', XFreeGC);
    Bind(LibX11, 'XSetForeground', XSetForeground);
    Bind(LibX11, 'XFillRectangle', XFillRectangle);
    Bind(LibXext, 'XShmQueryExtension', XShmQueryExtension);
    Bind(LibXext, 'XShmQueryVersion', XShmQueryVersion);
    Bind(LibXext, 'XShmCreateImage', XShmCreateImage);
    Bind(LibXext, 'XShmAttach', XShmAttach);
    Bind(LibXext, 'XShmDetach', XShmDetach);
    Bind(LibXext, 'XShmGetImage', XShmGetImage);
  end;
  AError := LoadFailure;
  Result := LoadFailure = '';
end;

procedure SetX11IOErrorHandler(AHandler: TX11IOErrorHandler);
var
  Error: string;
begin
  if LoadXlib(Error) then
    XSetIOErrorHandler(AHandler);
end;

// Xlib reports protocol errors asynchronously: a request the server
// rejects surfaces at the next XSync, not at the call that made it, and
// the default handler prints a message and calls exit(1). TrapXErrors
// plus UntrapXErrors turn that into a return value for the two calls
// that can reasonably fail (XShmAttach, XShmGetImage).
//
// XSetErrorHandler is per process, not per display, so this is not
// thread-safe and cannot be made so.
var
  XErrorTrapped: Boolean = False;
  XErrorCode: Byte = 0;
  XErrorRequest: Byte = 0;
  PreviousXErrorHandler: TXErrorHandler = nil;

function TrapXErrorHandler(ADisplay: Pointer;
  AEvent: PXErrorEvent): cint; cdecl;
begin
  XErrorTrapped := True;
  XErrorCode := AEvent^.ErrorCode;
  XErrorRequest := AEvent^.RequestCode;
  Result := 0;
end;

procedure TrapXErrors;
begin
  XErrorTrapped := False;
  XErrorCode := 0;
  XErrorRequest := 0;
  PreviousXErrorHandler := XSetErrorHandler(@TrapXErrorHandler);
end;

// Restores the previous handler and answers whether anything was caught,
// with Xlib's own text for the code. Call once per TrapXErrors, success
// path included, or the handler stays installed.
function UntrapXErrors(ADisplay: Pointer; out AError: string): Boolean;
var
  Text: array[0..255] of Char;
begin
  XSetErrorHandler(PreviousXErrorHandler);
  PreviousXErrorHandler := nil;
  AError := '';
  Result := XErrorTrapped;
  if not Result then
    Exit;
  Text[0] := #0;
  XGetErrorText(ADisplay, cint(XErrorCode), @Text[0], Length(Text));
  AError := Format('X error %d on request %d: %s',
    [XErrorCode, XErrorRequest, string(PChar(@Text[0]))]);
end;

{ TX11Grabber }

constructor TX11Grabber.Create;
begin
  inherited Create;
  FDisplay := nil;
  FImage := nil;
  FSegmentId := -1;
  FSegmentAddress := nil;
end;

destructor TX11Grabber.Destroy;
begin
  ReleaseFrame;
  if FDisplay <> nil then
  begin
    XCloseDisplay(FDisplay);
    FDisplay := nil;
  end;
  inherited Destroy;
end;

function SegmentInfo(AId: cint; AAddress: Pointer): TX11SegmentInfo;
begin
  Result.ShmSeg := 0;
  Result.ShmId := AId;
  Result.ShmAddr := PChar(AAddress);
  Result.ReadOnly := 0;
end;

procedure TX11Grabber.ReleaseFrame;
begin
  // Detach, unmap and destroy in the reverse order of Prepare. The
  // segment was marked IPC_RMID at creation, so the kernel reclaims it
  // when the last mapping goes, including if this process dies.
  // The segment info the server was given is not kept: XShmDetach needs
  // only the id and the address, which are rebuilt here.
  if FAttached and (FDisplay <> nil) then
  begin
    XShmDetach(FDisplay, @FSegmentInfo);
    XSync(FDisplay, 0);
  end;
  FAttached := False;
  if FImage <> nil then
  begin
    // XDestroyImage frees image->data with Xfree, and this image's data
    // is a shmat() address. Clearing the pointer first keeps that from
    // being a free() of foreign memory.
    PXImagePrefix(FImage)^.Data := nil;
    XDestroyImage(FImage);
    FImage := nil;
  end;
  if FSegmentAddress <> nil then
    shmdt(FSegmentAddress);
  FSegmentAddress := nil;
  FSegmentId := -1;
  FWidth := 0;
  FHeight := 0;
end;

function TX11Grabber.Open(const ADisplayName: string;
  out AError: string): Boolean;
var
  Name: PChar;
  Major, Minor, Pixmaps: cint;
  Depth: cint;
begin
  Result := False;
  if not LoadXlib(AError) then
    Exit;
  if FDisplay <> nil then
  begin
    AError := 'display already open';
    Exit;
  end;
  if ADisplayName = '' then
    Name := nil
  else
    Name := PChar(ADisplayName);
  FDisplay := XOpenDisplay(Name);
  if FDisplay = nil then
  begin
    if ADisplayName <> '' then
      AError := 'cannot open X display ' + ADisplayName
    else if GetEnvironmentVariable('DISPLAY') <> '' then
      AError := 'cannot open the X display ' + GetEnvironmentVariable('DISPLAY')
        + ' named by $DISPLAY'
    else if GetEnvironmentVariable('WAYLAND_DISPLAY') <> '' then
      AError := 'no X display ($DISPLAY is empty): this looks like a '
        + 'Wayland session, which knips cannot record yet'
    else
      AError := 'no X display: $DISPLAY is empty';
    Exit;
  end;
  FScreen := XDefaultScreen(FDisplay);
  FRoot := XRootWindow(FDisplay, FScreen);
  FScreenWidth := XDisplayWidth(FDisplay, FScreen);
  FScreenHeight := XDisplayHeight(FDisplay, FScreen);
  if XShmQueryExtension(FDisplay) = 0 then
  begin
    AError := 'the X server has no MIT-SHM extension';
    Exit;
  end;
  Major := 0;
  Minor := 0;
  Pixmaps := 0;
  if XShmQueryVersion(FDisplay, @Major, @Minor, @Pixmaps) = 0 then
  begin
    AError := 'MIT-SHM is present but refused a version query';
    Exit;
  end;
  Depth := XDefaultDepth(FDisplay, FScreen);
  if (Depth <> 24) and (Depth <> 32) then
  begin
    AError := Format('unsupported display depth %d (need 24 or 32)', [Depth]);
    Exit;
  end;
  Result := True;
end;

function TX11Grabber.Prepare(ALeft, ATop, AWidth, AHeight: Integer;
  out AError: string): Boolean;
var
  Size: PtrUInt;
  Accepted: Boolean;
  Refusal: string;
  Image: PXImagePrefix;
begin
  Result := False;
  AError := '';
  if FDisplay = nil then
  begin
    AError := 'no display open';
    Exit;
  end;
  if (AWidth <= 0) or (AHeight <= 0) or (ALeft < 0) or (ATop < 0)
    or (ALeft + AWidth > FScreenWidth) or (ATop + AHeight > FScreenHeight) then
  begin
    AError := Format('the %dx%d frame at (%d, %d) does not fit the %dx%d '
      + 'screen', [AWidth, AHeight, ALeft, ATop, FScreenWidth,
      FScreenHeight]);
    Exit;
  end;
  ReleaseFrame;
  // XShmCreateImage keeps this pointer (in the image's obdata) and
  // XShmGetImage reads the segment id Xlib allocates into it at attach
  // time, so it has to be the field that lives as long as the image does,
  // not a local.
  FSegmentInfo := SegmentInfo(-1, nil);
  FImage := XShmCreateImage(FDisplay, XDefaultVisual(FDisplay, FScreen),
    cuint(XDefaultDepth(FDisplay, FScreen)), ZPixmap, nil, @FSegmentInfo,
    cuint(AWidth), cuint(AHeight));
  if FImage = nil then
  begin
    AError := 'XShmCreateImage failed';
    Exit;
  end;
  Image := PXImagePrefix(FImage);
  if Image^.BitsPerPixel <> 32 then
  begin
    AError := Format('unsupported bits per pixel %d (need 32)',
      [Image^.BitsPerPixel]);
    ReleaseFrame;
    Exit;
  end;
  if (Image^.RedMask <> $00FF0000) or (Image^.GreenMask <> $0000FF00)
    or (Image^.BlueMask <> $000000FF) then
  begin
    AError := 'unsupported channel masks (need little-endian BGRX)';
    ReleaseFrame;
    Exit;
  end;
  // The masks describe a pixel value, not its bytes: an MSBFirst server
  // reports these masks and lays the pixel out reversed in memory.
  if Image^.ByteOrder <> LSBFirst then
  begin
    AError := 'unsupported image byte order (need LSBFirst)';
    ReleaseFrame;
    Exit;
  end;
  FBytesPerLine := Image^.BytesPerLine;
  Size := PtrUInt(Image^.BytesPerLine) * PtrUInt(AHeight);
  FSegmentId := shmget(IpcPrivate, Size, IPC_CREAT or SegmentPermissions);
  if FSegmentId < 0 then
  begin
    AError := 'shmget failed (System V shared memory is not available)';
    ReleaseFrame;
    Exit;
  end;
  FSegmentAddress := shmat(FSegmentId, nil, 0);
  // shmat reports failure as (void *) -1.
  if (FSegmentAddress = nil) or (PtrUInt(FSegmentAddress) = High(PtrUInt))
    then
  begin
    FSegmentAddress := nil;
    shmctl(FSegmentId, IPC_RMID, nil);
    FSegmentId := -1;
    AError := 'shmat failed';
    ReleaseFrame;
    Exit;
  end;
  Image^.Data := PChar(FSegmentAddress);
  FSegmentInfo.ShmId := FSegmentId;
  FSegmentInfo.ShmAddr := PChar(FSegmentAddress);
  FSegmentInfo.ReadOnly := 0;
  // Marked for destruction now: it survives while mapped and goes the
  // moment the last mapping does, even after a crash.
  shmctl(FSegmentId, IPC_RMID, nil);

  // XShmAttach is a request: a server that will not take the segment (a
  // remote display, a sandbox without System V IPC) answers BadAccess at
  // the XSync, and untrapped that is Xlib's exit(1).
  TrapXErrors;
  Accepted := XShmAttach(FDisplay, @FSegmentInfo) <> 0;
  XSync(FDisplay, 0);
  if UntrapXErrors(FDisplay, Refusal) or not Accepted then
  begin
    if Refusal <> '' then
      AError := 'the X server refused XShmAttach (' + Refusal
        + '): a display that is not local cannot share memory'
    else
      AError := 'XShmAttach failed (a remote X server cannot share memory)';
    ReleaseFrame;
    Exit;
  end;
  FAttached := True;
  FLeft := ALeft;
  FTop := ATop;
  FWidth := AWidth;
  FHeight := AHeight;
  Result := True;
end;

function TX11Grabber.Grab(out AError: string): Boolean;
var
  Got: Boolean;
  Refusal: string;
begin
  Result := False;
  AError := '';
  if (FImage = nil) or not FAttached then
  begin
    AError := 'no frame prepared';
    Exit;
  end;
  // What the bounds check in Prepare cannot know: a screen RandR resized
  // since Open turns the rectangle into a BadMatch.
  TrapXErrors;
  Got := XShmGetImage(FDisplay, FRoot, FImage, cint(FLeft), cint(FTop),
    AllPlanes) <> 0;
  XSync(FDisplay, 0);
  if UntrapXErrors(FDisplay, Refusal) or not Got then
  begin
    if Refusal <> '' then
      AError := 'XShmGetImage was refused (' + Refusal + ')'
    else
      AError := 'XShmGetImage failed';
    Exit;
  end;
  Result := True;
end;

procedure TX11Grabber.Sync;
begin
  if FDisplay <> nil then
    XSync(FDisplay, 0);
end;

function TX11Grabber.Pixels: PByte;
begin
  if FImage = nil then
    Result := nil
  else
    Result := PByte(FSegmentAddress);
end;

function TX11Grabber.PaintRoot(ARed, AGreen, ABlue: Byte;
  out AError: string): Boolean;
var
  Context: Pointer;
begin
  Result := False;
  AError := '';
  if FDisplay = nil then
  begin
    AError := 'no display open';
    Exit;
  end;
  Context := XCreateGC(FDisplay, FRoot, 0, nil);
  if Context = nil then
  begin
    AError := 'XCreateGC failed';
    Exit;
  end;
  try
    XSetForeground(FDisplay, Context, (culong(ARed) shl 16)
      or (culong(AGreen) shl 8) or culong(ABlue));
    XFillRectangle(FDisplay, FRoot, Context, 0, 0, cuint(FScreenWidth),
      cuint(FScreenHeight));
  finally
    XFreeGC(FDisplay, Context);
  end;
  XSync(FDisplay, 0);
  Result := True;
end;

{$ENDIF}

end.

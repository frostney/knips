unit Knips.Capture.X11;

// SPIKE, not production code. One MIT-SHM frame grab from an X11 screen,
// handed to the existing platform-neutral BGRA buffer.
//
// This exists to answer one question from a Mac: can a Linux capture path
// be built and regression-tested with no Linux machine? It can — the whole
// thing runs against Xvfb in the Linux container (see tools/linux-ci.sh and
// docs/ports.md). What it deliberately does not do is anything a recorder
// needs: no repeat grabs on a clock, no damage tracking, no cursor, no
// multi-monitor geometry, no XWayland detection. Those belong to
// Knips.Recording.Linux when milestone 3 opens.
//
// MIT-SHM rather than plain XGetImage because the copy is the whole cost of
// X11 capture: XGetImage round-trips every pixel through the X protocol,
// while XShmGetImage writes into a System V shared segment both processes
// have mapped. The trade is that it only works against a *local* display.
// A grabber that cannot attach says so; it does not silently fall back,
// because a silent fallback is how a recorder ends up shipping at 4 fps.
//
// Pixel format: an X11 TrueColor visual at depth 24/32 on a little-endian
// machine already lays a pixel out as B, G, R, X — which is exactly
// Knips.Export.Bitmap's BGRA. The masks and bits-per-pixel are checked
// rather than assumed, and an unexpected visual is an error, not a
// best-effort byte shuffle.

{$I Knips.inc}

interface

{$IFDEF LINUX}

uses
  ctypes,
  SysUtils,

  ipc,
  Knips.Export.Bitmap,
  x,
  xlib,
  xshm;

type
  TX11FrameGrabber = class
  private
    FDisplay: PDisplay;
    FScreen: cint;
    FRoot: TWindow;
    FImage: PXImage;
    FSegment: TXShmSegmentInfo;
    FAttached: Boolean;
    FMapped: Boolean;
    FWidth: Integer;
    FHeight: Integer;
    procedure ReleaseFrame;
    function CheckVisual(out AError: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    // ADisplayName empty means $DISPLAY.
    function Open(const ADisplayName: string; out AError: string): Boolean;
    // Allocates the shared image the grabs read into. Calling it again
    // with different dimensions replaces it.
    function PrepareFrame(AWidth, AHeight: Integer;
      out AError: string): Boolean;
    // Copies the rectangle at (ALeft, ATop) of the root window into
    // AFrame, resizing AFrame to the prepared dimensions.
    function Grab(ALeft, ATop: Integer; var AFrame: TBgraImage;
      out AError: string): Boolean;
    // Spike-only: fills a rectangle of the root window with a known
    // colour, so a headless grab has a pattern to be checked against
    // rather than the ambiguous all-black an empty Xvfb also produces.
    // A recorder would never draw on the screen it is recording.
    function PaintRoot(AWidth, AHeight: Integer; ARed, AGreen, ABlue: Byte;
      out AError: string): Boolean;
    function ScreenWidth: Integer;
    function ScreenHeight: Integer;
    property FrameWidth: Integer read FWidth;
    property FrameHeight: Integer read FHeight;
  end;

{$ENDIF}

implementation

{$IFDEF LINUX}

// Xlib reports protocol errors *asynchronously*: a request the server
// rejects surfaces at the next XSync, not at the call that made it, and
// the default handler prints a message and calls exit(1). That is fatal
// for the two cases this unit promises to report rather than die on — a
// display that is not local refusing XShmAttach, and a grab rectangle that
// no longer fits its drawable. These globals plus TrapXErrors /
// UntrapXErrors turn an asynchronous kill into a return value.
//
// XSetErrorHandler is per *process*, not per display, so this is not
// thread-safe and cannot be made so. That is acceptable here and worth
// stating: the spike is single-threaded, and a real backend has to confine
// its Xlib calls to one thread regardless.
var
  XErrorTrapped: Boolean = False;
  XErrorCode: Byte = 0;
  XErrorRequest: Byte = 0;
  PreviousXErrorHandler: TXErrorHandler = nil;

function TrapXErrorHandler(ADisplay: PDisplay;
  AEvent: PXErrorEvent): cint; cdecl;
begin
  XErrorTrapped := True;
  XErrorCode := AEvent^.error_code;
  XErrorRequest := AEvent^.request_code;
  // Non-zero is ignored by Xlib; returning 0 is the convention.
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
// with Xlib's own text for the code. Always call it once per TrapXErrors,
// including on the success path, or the handler stays installed.
function UntrapXErrors(ADisplay: PDisplay; out AError: string): Boolean;
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

{ TX11FrameGrabber }

constructor TX11FrameGrabber.Create;
begin
  inherited Create;
  FDisplay := nil;
  FImage := nil;
  FSegment.shmid := -1;
  FSegment.shmaddr := nil;
end;

destructor TX11FrameGrabber.Destroy;
begin
  ReleaseFrame;
  if FDisplay <> nil then
  begin
    XCloseDisplay(FDisplay);
    FDisplay := nil;
  end;
  inherited Destroy;
end;

// Detach, unmap and destroy in the reverse order of PrepareFrame. The
// segment was already marked IPC_RMID at creation, so the kernel reclaims
// it as soon as the last mapping goes — including if this process dies.
procedure TX11FrameGrabber.ReleaseFrame;
begin
  if FAttached and (FDisplay <> nil) then
  begin
    XShmDetach(FDisplay, @FSegment);
    // The detach is a request like any other. Waiting for the server to
    // process it is the canonical MIT-SHM teardown order: unmapping the
    // segment while the server still holds it is a use-after-free on the
    // other side of the socket.
    XSync(FDisplay, False);
  end;
  FAttached := False;
  if FImage <> nil then
  begin
    // Xlib's destroy_image calls Xfree() on image->data, and this image's
    // data is a shmat() address, not a malloc'd one. Clearing the pointer
    // first is what keeps that from being a free() of foreign memory —
    // the shared segment is released by shmdt below instead.
    FImage^.data := nil;
    FImage^.f.destroy_image(FImage);
    FImage := nil;
  end;
  if FMapped and (FSegment.shmaddr <> nil) then
    shmdt(Pointer(FSegment.shmaddr));
  FMapped := False;
  FSegment.shmaddr := nil;
  FSegment.shmid := -1;
  FWidth := 0;
  FHeight := 0;
end;

function TX11FrameGrabber.Open(const ADisplayName: string;
  out AError: string): Boolean;
var
  Name: PChar;
  Major: cint;
  Minor: cint;
  SharedPixmaps: TBool;
begin
  AError := '';
  Result := False;
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
    if ADisplayName = '' then
      AError := 'cannot open the X display named by $DISPLAY'
    else
      AError := 'cannot open X display ' + ADisplayName;
    Exit;
  end;
  FScreen := XDefaultScreen(FDisplay);
  FRoot := XRootWindow(FDisplay, FScreen);
  if not XShmQueryExtension(FDisplay) then
  begin
    AError := 'the X server has no MIT-SHM extension';
    Exit;
  end;
  Major := 0;
  Minor := 0;
  SharedPixmaps := 0;
  if not XShmQueryVersion(FDisplay, @Major, @Minor, @SharedPixmaps) then
  begin
    AError := 'MIT-SHM is present but refused a version query';
    Exit;
  end;
  if not CheckVisual(AError) then
    Exit;
  Result := True;
end;

// The default visual has to be the 32-bit little-endian BGRX layout the
// neutral bitmap code already speaks. Anything else is refused rather than
// converted: a spike that quietly handles 16-bit visuals teaches nothing.
function TX11FrameGrabber.CheckVisual(out AError: string): Boolean;
var
  Depth: cint;
begin
  AError := '';
  Result := False;
  Depth := XDefaultDepth(FDisplay, FScreen);
  if (Depth <> 24) and (Depth <> 32) then
  begin
    AError := Format('unsupported display depth %d (need 24 or 32)', [Depth]);
    Exit;
  end;
  Result := True;
end;

function TX11FrameGrabber.ScreenWidth: Integer;
begin
  if FDisplay = nil then
    Result := 0
  else
    Result := XDisplayWidth(FDisplay, FScreen);
end;

function TX11FrameGrabber.ScreenHeight: Integer;
begin
  if FDisplay = nil then
    Result := 0
  else
    Result := XDisplayHeight(FDisplay, FScreen);
end;

function TX11FrameGrabber.PrepareFrame(AWidth, AHeight: Integer;
  out AError: string): Boolean;
var
  Size: PtrUInt;
  Address: Pointer;
  Accepted: Boolean;
  Refusal: string;
begin
  AError := '';
  Result := False;
  if FDisplay = nil then
  begin
    AError := 'no display open';
    Exit;
  end;
  if (AWidth <= 0) or (AHeight <= 0) then
  begin
    AError := 'frame size must be positive';
    Exit;
  end;
  ReleaseFrame;

  FImage := XShmCreateImage(FDisplay, XDefaultVisual(FDisplay, FScreen),
    cuint(XDefaultDepth(FDisplay, FScreen)), ZPixmap, nil, @FSegment,
    cuint(AWidth), cuint(AHeight));
  if FImage = nil then
  begin
    AError := 'XShmCreateImage failed';
    Exit;
  end;
  if FImage^.bits_per_pixel <> 32 then
  begin
    AError := Format('unsupported bits per pixel %d (need 32)',
      [FImage^.bits_per_pixel]);
    ReleaseFrame;
    Exit;
  end;
  if (FImage^.red_mask <> $00FF0000) or (FImage^.green_mask <> $0000FF00)
    or (FImage^.blue_mask <> $000000FF) then
  begin
    AError := 'unsupported channel masks (need little-endian BGRX)';
    ReleaseFrame;
    Exit;
  end;
  // The masks describe a *pixel value*, not its bytes. An MSBFirst server
  // reports exactly these masks and then lays the pixel out reversed in
  // memory, so the straight Move in Grab would ship swapped channels while
  // the mask check above said everything was fine.
  if FImage^.byte_order <> LSBFirst then
  begin
    AError := 'unsupported image byte order (need LSBFirst; an MSBFirst '
      + 'server reports the same masks with the bytes reversed in memory)';
    ReleaseFrame;
    Exit;
  end;

  Size := PtrUInt(FImage^.bytes_per_line) * PtrUInt(AHeight);
  // $180 is octal 0600, owner read/write; the segment is private to this
  // process and whatever the X server maps through the SHM handshake.
  FSegment.shmid := shmget(IPC_PRIVATE, Size, IPC_CREAT or $180);
  if FSegment.shmid < 0 then
  begin
    AError := 'shmget failed (is the container allowed System V shared memory?)';
    ReleaseFrame;
    Exit;
  end;
  Address := shmat(FSegment.shmid, nil, 0);
  // shmat reports failure as (void *) -1, not nil.
  if (Address = nil) or (PtrUInt(Address) = High(PtrUInt)) then
  begin
    AError := 'shmat failed';
    shmctl(FSegment.shmid, IPC_RMID, nil);
    FSegment.shmid := -1;
    ReleaseFrame;
    Exit;
  end;
  FMapped := True;
  FSegment.shmaddr := PChar(Address);
  FSegment.readOnly := 0;
  FImage^.data := FSegment.shmaddr;
  // Mark for destruction now: the segment survives while it is mapped and
  // disappears the moment the last mapping goes, even if we crash.
  shmctl(FSegment.shmid, IPC_RMID, nil);

  // XShmAttach is a request, not a call: a server that will not take the
  // segment (a display that is not local, a sandbox without System V IPC)
  // answers with BadAccess at the XSync below. Untrapped, that reaches
  // Xlib's default handler, which exits the process — so the trap is what
  // makes this unit's "a grabber that cannot attach says so" true.
  TrapXErrors;
  Accepted := XShmAttach(FDisplay, @FSegment) <> 0;
  XSync(FDisplay, False);
  // FAttached is still False here, so the ReleaseFrame below will not try
  // to detach a segment the server never took.
  if UntrapXErrors(FDisplay, Refusal) or not Accepted then
  begin
    if Refusal <> '' then
      AError := 'the X server refused XShmAttach (' + Refusal
        + ') — a display that is not local cannot share memory'
    else
      AError := 'XShmAttach failed (a remote X server cannot share memory)';
    ReleaseFrame;
    Exit;
  end;
  FAttached := True;

  FWidth := AWidth;
  FHeight := AHeight;
  Result := True;
end;

function TX11FrameGrabber.PaintRoot(AWidth, AHeight: Integer;
  ARed, AGreen, ABlue: Byte; out AError: string): Boolean;
var
  Context: TGC;
begin
  AError := '';
  Result := False;
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
    // A depth-24 TrueColor pixel is 0x00RRGGBB, which is what the visual's
    // masks were checked to be in PrepareFrame.
    XSetForeground(FDisplay, Context,
      (culong(ARed) shl 16) or (culong(AGreen) shl 8) or culong(ABlue));
    XFillRectangle(FDisplay, FRoot, Context, 0, 0, cuint(AWidth),
      cuint(AHeight));
  finally
    XFreeGC(FDisplay, Context);
  end;
  XSync(FDisplay, False);
  Result := True;
end;

function TX11FrameGrabber.Grab(ALeft, ATop: Integer; var AFrame: TBgraImage;
  out AError: string): Boolean;
var
  Y: Integer;
  Source: PByte;
  Destination: PByte;
  RowBytes: Integer;
  Column: Integer;
  Got: Boolean;
  Refusal: string;
begin
  AError := '';
  Result := False;
  if (FImage = nil) or not FAttached then
  begin
    AError := 'no frame prepared';
    Exit;
  end;
  // Two layers, on purpose. This one answers the mistake a caller can
  // actually make — asking for a rectangle outside the root window — with
  // the numbers involved, rather than leaving them to decode a BadMatch.
  if (ALeft < 0) or (ATop < 0) or (ALeft + FWidth > ScreenWidth)
    or (ATop + FHeight > ScreenHeight) then
  begin
    AError := Format(
      'the %dx%d frame at (%d, %d) does not fit the %dx%d root window',
      [FWidth, FHeight, ALeft, ATop, ScreenWidth, ScreenHeight]);
    Exit;
  end;
  // And this one catches everything the bounds check cannot know about —
  // a root window RandR resized since Open, a display that went away —
  // which would otherwise be an asynchronous exit(1) mid-recording.
  TrapXErrors;
  Got := XShmGetImage(FDisplay, FRoot, FImage, cint(ALeft), cint(ATop),
    AllPlanes) <> 0;
  XSync(FDisplay, False);
  if UntrapXErrors(FDisplay, Refusal) or not Got then
  begin
    if Refusal <> '' then
      AError := 'XShmGetImage was refused (' + Refusal + ')'
    else
      AError := 'XShmGetImage failed';
    Exit;
  end;

  BgraImageResize(AFrame, FWidth, FHeight);
  RowBytes := FWidth * BgraBytesPerPixel;
  for Y := 0 to FHeight - 1 do
  begin
    Source := PByte(FImage^.data) + PtrUInt(Y) *
      PtrUInt(FImage^.bytes_per_line);
    Destination := BgraImageRow(AFrame, Y);
    Move(Source^, Destination^, RowBytes);
    // X leaves the fourth byte undefined on a depth-24 visual; the
    // neutral encoders expect an opaque alpha.
    for Column := 0 to FWidth - 1 do
      (Destination + Column * BgraBytesPerPixel + BgraAlphaOffset)^ := 255;
  end;
  Result := True;
end;

{$ENDIF}

end.

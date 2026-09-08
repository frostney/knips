unit Knips.Recording.CursorOverlay;

// Big Cursor: the enlarged pointer that is drawn *into* the recorded
// frames rather than captured with them.
//
// ScreenCaptureKit's own cursor is switched off for the recording
// (TStreamGeometry.ShowsCursor goes False, which the one configuration
// builder in Knips.Capture.Stream honours for the first configuration and
// every live update alike), and this object composites a scaled sprite
// into each frame's pixels on the way to the writer. Because it is baked
// into the movie, the GIF, APNG and passthrough-trim exports inherit it
// for nothing — they read the finished file.
//
// The arithmetic is all in Knips.Recording.CursorMath, below the Darwin
// line and unit-tested, and the sprite itself is all in
// Knips.Recording.CursorSprite, which the export's drawn pointer
// (Knips.Export.CursorEffect) renders from too — the two used to hold a
// copy each of the same Quartz routine. What is left here is the one
// thing neither of those can do: reaching the frame's bytes on the
// thread they arrive on.
//
// **Two threads, and the split between them is the whole design.**
//
// Prepare runs on the main thread, once, before the capture starts. It
// asks Knips.Recording.CursorSprite for the arrow at the recording's own
// scale, which is where AppKit is talked to and where the bytes end up
// in a GetMem block — deliberately not a dynamic array, so that nothing
// the capture queue touches is a managed type at all.
//
// DrawInto runs on ScreenCaptureKit's capture queue, where this program
// has no cthreads on Darwin (a Darwin-only rule — ADR-0005) and the
// rules are the ones in docs/architecture.md: no
// exceptions, no try..finally, no WriteLn, no managed writes. It makes no
// Objective-C call. The cursor position comes from CGEventCreate(nil) +
// CGEventGetLocation, which is plain C, thread-safe, and — measured on
// device — needs no privacy grant of any kind: it reads the pointer's
// position, it does not tap events and it injects nothing. (Injecting is
// forbidden here anyway; this is a recorder.)
//
// **The cursor's shape is fixed for the recording, on purpose.** The
// sprite is rendered once, from NSCursor.arrowCursor.
// +[NSCursor currentSystemCursor] does bind in FPC 3.2.2 and does return
// a cursor (both checked on device), and it was rejected rather than
// missed: rendering once means whatever shape is under the pointer at the
// instant the recording starts is frozen for the whole file, and an
// I-beam frozen over a five-minute screencast — which is exactly what
// `knips record --big-cursor` from a terminal would produce — is worse
// than an arrow that is occasionally the wrong shape. Following the live
// shape needs a main-thread re-render on shape change, which is a
// separate piece of work.
//
// **In place, not copied.** The blit goes straight into the
// CVPixelBuffer ScreenCaptureKit delivered, between
// CVPixelBufferLockBaseAddress(buffer, 0) and its unlock, before the
// writer appends it. The alternative — copy the frame, draw on the copy,
// append the copy — costs a full-frame memcpy plus a pool allocation per
// frame (about 20 MB at 2880x1800, 600 MB/s at 30 fps) and was not
// needed: on device, a recording with the pointer moved continuously
// across the whole screen played back clean, with no ghosting, no
// tearing and no CoreVideo complaint in the log. The specific risk that
// was looked for is stale sprites: ScreenCaptureKit recycles its
// surfaces and only recomposites what changed, so a sprite drawn into a
// recycled surface could in principle survive into a later frame where
// nothing under it moved. It does not, because SCK does not hand the
// same surface back while its previous frame is still referenced and
// recomposites the frame it does hand back. If that ever changes, the
// symptom is a trail of pointers standing still in the video and the fix
// is to composite into a copy.
//
// The counters exist for the same reason the writer's do: this runs on a
// thread that cannot report anything, so what it did is counted and the
// main thread prints the totals afterwards.

{$I Knips.inc}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  Knips.Capture.CoreMedia,
  Knips.Capture.PThreadMutex,
  Knips.Recording.CursorMath,
  Knips.Recording.CursorSprite,
  MacOSAll;

type
  TCursorOverlay = class
  private
    // The sprite, premultiplied BGRA, top row first, made once on the
    // main thread by Knips.Recording.CursorSprite. Raw memory rather than
    // a dynamic array: the capture queue reads it, and a managed type
    // there is exactly what the no-cthreads rules forbid — which is why
    // TCursorSprite is a record of integers and one PByte and nothing
    // else. Its Pixels being non-nil is what "ready" means; there is no
    // second flag to fall out of step with it.
    FSprite: TCursorSprite;
    // The recorded display's origin in the global point space
    // CGEventGetLocation answers in. Fixed for the recording; read on the
    // capture queue without a lock because nothing ever writes it again.
    FDisplayOriginX: Double;
    FDisplayOriginY: Double;
    // What the capture is currently reading. The live effects move it
    // from the main thread while the capture queue reads it, so it is the
    // one piece of shared mutable state and it sits under the mutex.
    FLock: TPThreadMutex;
    FMapping: TCursorFrameMapping;
    // Capture-queue counters, read by the main thread after the stop.
    // Under FLock like the mapping beside them: the read happens after
    // the stream has stopped and is safe in practice, but an Int64
    // written on one thread and read on another with no barrier is not
    // something to leave to practice — and the mutex is already taken
    // once per frame a few lines further down, so the cost is one more
    // uncontended lock on a path that takes one anyway.
    FComposited: Int64;
    FOffFrame: Int64;
    FRefused: Int64;
    // Capture-queue safe: no allocation, no exception, no managed type.
    procedure Count(var ACounter: Int64);
    function CounterValue(const ACounter: Int64): Int64;
  public
    constructor Create;
    destructor Destroy; override;
    // Main thread, before the capture starts. ADisplayID is the display
    // being recorded (its global origin is what turns a screen-space
    // cursor position into this display's own points), ABaseRect the
    // rectangle the recording was sized from in that display's top-left
    // points, and APixelWidth/APixelHeight the movie's dimensions.
    //
    // False with a message when the sprite cannot be made, which is not
    // a reason to fail a recording: the caller records without a big
    // cursor and says so.
    function Prepare(ADisplayID: UInt32; APixelWidth, APixelHeight: Integer;
      const ABaseRect: CGRect; out AError: string): Boolean;
    // Main thread. The rectangle ScreenCaptureKit was last *told* to
    // read, so that a zoom or a pan moves the drawn pointer with the
    // content instead of leaving it where the base rectangle put it.
    procedure SetSourceRect(const ARect: CGRect);
    // Capture queue. Draws the sprite into the frame's own bytes; does
    // nothing at all when the overlay is not ready, when the pointer is
    // outside the captured rectangle, or when the buffer is not the
    // 32BGRA the stream asked for.
    procedure DrawInto(APixelBuffer: CVPixelBufferRef);
    property SpriteWidth: Integer read FSprite.Width;
    property SpriteHeight: Integer read FSprite.Height;
    property HotSpotX: Integer read FSprite.HotSpotX;
    property HotSpotY: Integer read FSprite.HotSpotY;
    // Frames the sprite was drawn into, frames where the pointer was
    // outside the captured rectangle, and frames refused because the
    // buffer could not be locked or was not the expected layout. The
    // third is the only one that is ever a problem.
    function CompositedFrames: Int64;
    function OffFrameFrames: Int64;
    function RefusedFrames: Int64;
  end;

// Renders the sprite for the main display at its own backing scale and
// throws it away, reporting what it made. `knips probe` calls this: the
// one framework dependency Big Cursor has is NSCursor's image — now
// reached through Knips.Recording.CursorSprite — which is nil without an
// NSApplication and could go nil again on a future macOS, and a line
// printed before anything is recorded beats a recording that quietly
// comes out with no pointer at all. Going through the overlay rather than
// straight to the renderer is the point: it proves the scale arithmetic
// this unit does as well as the drawing the other one does.
function ProbeCursorSprite(out AWidth, AHeight, AHotSpotX,
  AHotSpotY: Integer; out AError: string): Boolean;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // The frame's own layout, checked before anything is written into it:
  // kCVPixelFormatType_32BGRA is four bytes to the pixel. The sprite's
  // side of the same fact belongs to Knips.Recording.CursorSprite, which
  // is what made it.
  BytesPerPixel = 4;

{ TCursorOverlay }

constructor TCursorOverlay.Create;
begin
  inherited Create;
  PThreadMutexInit(FLock);
end;

destructor TCursorOverlay.Destroy;
begin
  // The capture queue is long stopped by the time this runs: the session
  // stops the stream before it frees anything (Knips.Recording).
  ReleaseCursorSprite(FSprite);
  PThreadMutexDestroy(FLock);
  inherited Destroy;
end;

function TCursorOverlay.Prepare(ADisplayID: UInt32; APixelWidth,
  APixelHeight: Integer; const ABaseRect: CGRect;
  out AError: string): Boolean;
var
  Bounds: CGRect;
  PixelsPerPoint: Double;
begin
  Result := False;
  AError := '';
  if (APixelWidth <= 0) or (APixelHeight <= 0)
    or (ABaseRect.size.width <= 0) or (ABaseRect.size.height <= 0) then
  begin
    AError := 'the recording has no geometry to place a cursor in';
    Exit;
  end;

  Bounds := CGDisplayBounds(ADisplayID);
  FDisplayOriginX := Bounds.origin.x;
  FDisplayOriginY := Bounds.origin.y;

  // The recording's own pixels per point, from the rectangle it was
  // sized from. Not from the *live* rectangle: the sprite is rendered
  // once, at the size the base geometry implies, and keeps that size in
  // output pixels for the whole file (see the unit comment).
  PixelsPerPoint := APixelWidth / ABaseRect.size.width;
  // Big Cursor's fixed magnification, handed over as its own number: the
  // shared renderer multiplies the two together the way this unit's own
  // copy used to, and the export's caller folds its magnification in
  // differently for reasons of its own.
  ReleaseCursorSprite(FSprite);
  if not RenderArrowSprite(PixelsPerPoint, BigCursorMagnification, FSprite,
    AError) then
    Exit;

  PThreadMutexLock(FLock);
  FMapping := CursorFrameMapping(APixelWidth, APixelHeight,
    ABaseRect.origin.x, ABaseRect.origin.y, ABaseRect.size.width,
    ABaseRect.size.height);
  PThreadMutexUnlock(FLock);
  FComposited := 0;
  FOffFrame := 0;
  FRefused := 0;
  Result := True;
end;

procedure TCursorOverlay.SetSourceRect(const ARect: CGRect);
begin
  if (ARect.size.width <= 0) or (ARect.size.height <= 0) then
    Exit;
  PThreadMutexLock(FLock);
  FMapping.SourceX := ARect.origin.x;
  FMapping.SourceY := ARect.origin.y;
  FMapping.SourceWidth := ARect.size.width;
  FMapping.SourceHeight := ARect.size.height;
  PThreadMutexUnlock(FLock);
end;

procedure TCursorOverlay.DrawInto(APixelBuffer: CVPixelBufferRef);
var
  Event: CGEventRef;
  Location: CGPoint;
  Mapping: TCursorFrameMapping;
  Plan: TCursorBlitPlan;
  Base: Pointer;
  BytesPerRow: Integer;
begin
  // Capture-queue context. Nothing below raises, allocates a managed
  // type, or sends an Objective-C message; there is no try..finally, so
  // every early exit that has taken the pixel-buffer lock releases it by
  // hand.
  if (FSprite.Pixels = nil) or (APixelBuffer = nil) then
    Exit;

  // The pointer's position, in the global point space whose origin is the
  // main display's top-left corner — the same space CGDisplayBounds
  // answers in, which is why the display's origin is all it takes to get
  // into the recorded display's own points.
  Event := CGEventCreate(nil);
  if Event = nil then
  begin
    Count(FRefused);
    Exit;
  end;
  Location := CGEventGetLocation(Event);
  CFRelease(Event);

  PThreadMutexLock(FLock);
  Mapping := FMapping;
  PThreadMutexUnlock(FLock);

  Plan := PlanCursorBlit(Mapping, Location.x - FDisplayOriginX,
    Location.y - FDisplayOriginY, FSprite.Width, FSprite.Height,
    FSprite.HotSpotX, FSprite.HotSpotY);
  if not Plan.Visible then
  begin
    Count(FOffFrame);
    Exit;
  end;

  // Everything the plan promised is in range *of the mapping*; this is
  // where the buffer is checked to be the frame the mapping describes.
  // A mismatch means the frame is not what the configuration asked for,
  // and writing into it on that assumption is a write past the end.
  if CVPixelBufferIsPlanar(APixelBuffer)
    or (CVPixelBufferGetPixelFormatType(APixelBuffer)
    <> kCVPixelFormatType_32BGRA)
    or (Integer(CVPixelBufferGetWidth(APixelBuffer)) <> Mapping.PixelWidth)
    or (Integer(CVPixelBufferGetHeight(APixelBuffer))
    <> Mapping.PixelHeight) then
  begin
    Count(FRefused);
    Exit;
  end;

  // Flags 0, not kCVPixelBufferLock_ReadOnly: this writes.
  if CVPixelBufferLockBaseAddress(APixelBuffer, 0) <> kCVReturn_Success then
  begin
    Count(FRefused);
    Exit;
  end;
  Base := CVPixelBufferGetBaseAddress(APixelBuffer);
  BytesPerRow := Integer(CVPixelBufferGetBytesPerRow(APixelBuffer));
  if (Base <> nil) and (BytesPerRow >= Mapping.PixelWidth * BytesPerPixel) then
  begin
    BlitPremultipliedBgra(Base, BytesPerRow, FSprite.Pixels,
      FSprite.BytesPerRow, Plan);
    Count(FComposited);
  end
  else
    Count(FRefused);
  CVPixelBufferUnlockBaseAddress(APixelBuffer, 0);
end;

procedure TCursorOverlay.Count(var ACounter: Int64);
begin
  PThreadMutexLock(FLock);
  Inc(ACounter);
  PThreadMutexUnlock(FLock);
end;

function TCursorOverlay.CounterValue(const ACounter: Int64): Int64;
begin
  PThreadMutexLock(FLock);
  Result := ACounter;
  PThreadMutexUnlock(FLock);
end;

function TCursorOverlay.CompositedFrames: Int64;
begin
  Result := CounterValue(FComposited);
end;

function TCursorOverlay.OffFrameFrames: Int64;
begin
  Result := CounterValue(FOffFrame);
end;

function TCursorOverlay.RefusedFrames: Int64;
begin
  Result := CounterValue(FRefused);
end;

function ProbeCursorSprite(out AWidth, AHeight, AHotSpotX,
  AHotSpotY: Integer; out AError: string): Boolean;
var
  Overlay: TCursorOverlay;
  Bounds: CGRect;
  Mode: CGDisplayModeRef;
  PixelWidth: NativeUInt;
  Scale: Integer;
begin
  AWidth := 0;
  AHeight := 0;
  AHotSpotX := 0;
  AHotSpotY := 0;
  Bounds := CGDisplayBounds(CGMainDisplayID);
  // The *mode's* pixel width over the display's point width, which is
  // what Knips.Capture.ShareableContent.DisplayBackingScale computes for
  // a real recording — and specifically not CGDisplayPixelsWide, which
  // answers the point width on a scaled Retina mode and would report a
  // half-size sprite here. Reproduced rather than imported: this unit
  // sits below the capture layer and has no business depending on it.
  Scale := 1;
  Mode := CGDisplayCopyDisplayMode(CGMainDisplayID);
  if Mode <> nil then
  begin
    PixelWidth := CGDisplayModeGetPixelWidth(Mode);
    if (Bounds.size.width > 0) and (PixelWidth > 0) then
      Scale := Round(PixelWidth / Bounds.size.width);
    if Scale < 1 then
      Scale := 1;
    CGDisplayModeRelease(Mode);
  end;
  Overlay := TCursorOverlay.Create;
  try
    Result := Overlay.Prepare(CGMainDisplayID,
      Round(Bounds.size.width) * Scale, Round(Bounds.size.height) * Scale,
      CGRectMake(0, 0, Bounds.size.width, Bounds.size.height), AError);
    if not Result then
      Exit;
    AWidth := Overlay.SpriteWidth;
    AHeight := Overlay.SpriteHeight;
    AHotSpotX := Overlay.HotSpotX;
    AHotSpotY := Overlay.HotSpotY;
  finally
    Overlay.Free;
  end;
end;

{$ENDIF}

end.

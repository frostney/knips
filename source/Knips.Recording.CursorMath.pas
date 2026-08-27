unit Knips.Recording.CursorMath;

// Big Cursor's arithmetic: where the enlarged pointer sprite lands in one
// frame of the movie, and the source-over blit that puts it there.
//
// The feature itself is simple to state and easy to get wrong. The real
// pointer is switched off in the stream configuration
// (SCStreamConfiguration.showsCursor), and a sprite rendered once on the
// main thread is composited into every frame's pixels before the writer
// appends it. Baking it into the movie is what makes the GIF and APNG
// exports inherit it for nothing: they read the finished file.
//
// Everything below the Darwin line for two reasons. The first is the one
// Knips.Recording.LiveMath has — this is the only part of the feature
// that can be checked off-device, so it is the part that carries the
// tests. The second is stricter: the blit runs on ScreenCaptureKit's
// capture queue, where the Darwin build has no cthreads (ADR-0005: a
// Darwin-only rule; Linux uses cthreads, Windows the RTL's native
// manager) and an exception would take the process down
// (docs/architecture.md, "Threading model").
// Nothing here raises, allocates, or touches a managed type; the clipping
// is done in PlanCursorBlit, so BlitPremultipliedBgra is a pair of loops
// over memory that has already been proved to be in range.
//
// **The mapping.** A frame is APixelWidth by APixelHeight pixels showing
// the rectangle ScreenCaptureKit is currently reading, in the recorded
// display's own top-left points. That rectangle is not fixed: Zoom on
// Click and Follow Mouse move it thirty times a second, so the mapping is
// per-frame and not per-recording. A cursor at display point (x, y) is at
// frame pixel ((x - SourceX) / SourceWidth * PixelWidth, likewise for y),
// which handles the region offset, the Retina scale factor and a live
// zoom in one expression because all three are only ever ratios of the
// source rectangle to the output.
//
// **The sprite does not scale with the zoom, deliberately.** It is
// rendered once, at a size derived from the recording's *base* geometry,
// and stays that size in output pixels for the whole file. Scaling it
// with a live zoom would mean resampling it on the capture queue every
// frame; and a Big Cursor is an artificial pointer to begin with, so one
// that keeps its size while the content behind it zooms reads as
// deliberate rather than broken. Stated here because the alternative is
// the first thing anyone reaching for this code will wonder about.

{$I Knips.inc}

interface

uses
  Knips.Options;

const
  // How much bigger than the system pointer the drawn one is. 2.5 is the
  // step where the cursor is unmistakable in a clip scaled down for a
  // chat window without covering the thing it is pointing at.
  BigCursorMagnification = 2.5;
  // Sprite extent bounds, in pixels. The floor keeps a degenerate scale
  // from producing a sprite with no pixels; the ceiling bounds what a
  // corrupted magnification could ask the renderer to allocate.
  MinBigCursorExtent = 8;
  MaxBigCursorExtent = 512;

type
  // How one frame of the movie maps back onto the display it was read
  // from. Rebuilt per frame, because the live effects move SourceX/Y and
  // resize SourceWidth/Height while the recording runs.
  TCursorFrameMapping = record
    PixelWidth: Integer;
    PixelHeight: Integer;
    // The rectangle ScreenCaptureKit is reading, in the recorded
    // display's own top-left points — the space
    // SCStreamConfiguration.sourceRect and TCaptureRegion both use.
    SourceX: Double;
    SourceY: Double;
    SourceWidth: Double;
    SourceHeight: Double;
  end;

  // Where the sprite goes in one frame, already clipped to it. Every
  // field is in pixels and every one is in range once Visible is True:
  // this record is the whole of the bounds checking, so the blit itself
  // has none.
  TCursorBlitPlan = record
    Visible: Boolean;
    // Top-left of the copied area in the destination frame.
    DestinationX: Integer;
    DestinationY: Integer;
    // Top-left of the copied area inside the sprite. Non-zero exactly
    // when the sprite hangs off the frame's left or top edge.
    SpriteX: Integer;
    SpriteY: Integer;
    Width: Integer;
    Height: Integer;
  end;

function CursorFrameMapping(APixelWidth, APixelHeight: Integer;
  ASourceX, ASourceY, ASourceWidth, ASourceHeight: Double):
  TCursorFrameMapping;

// A point in the recorded display's own top-left points, in frame pixels.
// False — with both outputs zeroed — when the mapping is degenerate,
// which is the one case a caller must not blit through.
function CursorFramePoint(const AMapping: TCursorFrameMapping;
  ADisplayX, ADisplayY: Double; out AFrameX, AFrameY: Double): Boolean;

// The clipped placement of a sprite whose hot spot sits at the cursor's
// position. AHotSpotX/Y are in sprite pixels (the image's own hot spot,
// scaled by whatever the sprite was rendered at). Visible is False when
// the sprite falls entirely outside the frame, which is what a cursor
// outside a region — or outside a live zoom's crop — comes to.
function PlanCursorBlit(const AMapping: TCursorFrameMapping;
  ADisplayX, ADisplayY: Double; ASpriteWidth, ASpriteHeight,
  AHotSpotX, AHotSpotY: Integer): TCursorBlitPlan;

// Source-over of a premultiplied BGRA sprite onto a BGRA frame. Both
// buffers are top-row-first with four bytes per pixel; the row strides
// are given separately because a CVPixelBuffer's is padded and a
// CGBitmapContext's is not.
//
// Capture-queue code: no allocation, no exception, no managed type, and
// no bounds test — APlan is the bounds test, and a plan that did not come
// from PlanCursorBlit is a bug in the caller, not something checked here.
// A plan whose Visible is False draws nothing.
procedure BlitPremultipliedBgra(ADestination: Pointer;
  ADestinationBytesPerRow: Integer; ASource: Pointer;
  ASourceBytesPerRow: Integer; const APlan: TCursorBlitPlan);

// The pixel extent to render one axis of the sprite at: the image's
// measurement in points, times the recording's pixels per point, times
// the magnification, clamped. Rounded rather than truncated so a 28-point
// arrow at 2.5x on a 2x display is 140 and not 139.
function BigCursorSpriteExtent(AImagePoints, APixelsPerPoint,
  AMagnification: Double): Integer;

// The sprite's hot spot in sprite pixels: the image's own hot spot in
// points, at the same ratio the extent was scaled by. Clamped into the
// sprite, so a nonsense hot spot cannot put the drawn pointer somewhere
// the arithmetic does not say it is.
function BigCursorHotSpot(AHotSpotPoints, AImagePoints: Double;
  ASpriteExtent: Integer): Integer;

// Whether a given recording can have a Big Cursor at all, whatever the
// preference says — the same shape as
// Knips.Recording.LiveMath.ResolveLiveEffects, and refused in the same
// case and for a related reason. A window capture's frames show the
// window, whose position on screen changes under us with no way to find
// out from the capture queue, so a cursor position in screen points has
// nothing to be mapped against. A display capture, with or without a
// region, has a fixed relationship to the screen for the whole recording.
function ResolveBigCursor(ATargetKind: TCaptureTargetKind;
  ABigCursor: Boolean): Boolean;

implementation

function CursorFrameMapping(APixelWidth, APixelHeight: Integer;
  ASourceX, ASourceY, ASourceWidth, ASourceHeight: Double):
  TCursorFrameMapping;
begin
  Result.PixelWidth := APixelWidth;
  Result.PixelHeight := APixelHeight;
  Result.SourceX := ASourceX;
  Result.SourceY := ASourceY;
  Result.SourceWidth := ASourceWidth;
  Result.SourceHeight := ASourceHeight;
end;

function CursorFramePoint(const AMapping: TCursorFrameMapping;
  ADisplayX, ADisplayY: Double; out AFrameX, AFrameY: Double): Boolean;
begin
  AFrameX := 0;
  AFrameY := 0;
  Result := (AMapping.PixelWidth > 0) and (AMapping.PixelHeight > 0)
    and (AMapping.SourceWidth > 0) and (AMapping.SourceHeight > 0);
  if not Result then
    Exit;
  AFrameX := (ADisplayX - AMapping.SourceX) / AMapping.SourceWidth
    * AMapping.PixelWidth;
  AFrameY := (ADisplayY - AMapping.SourceY) / AMapping.SourceHeight
    * AMapping.PixelHeight;
end;

function PlanCursorBlit(const AMapping: TCursorFrameMapping;
  ADisplayX, ADisplayY: Double; ASpriteWidth, ASpriteHeight,
  AHotSpotX, AHotSpotY: Integer): TCursorBlitPlan;
var
  FrameX, FrameY: Double;
  Left, Top, Right, Bottom: Integer;
begin
  Result := Default(TCursorBlitPlan);
  if (ASpriteWidth <= 0) or (ASpriteHeight <= 0) then
    Exit;
  if not CursorFramePoint(AMapping, ADisplayX, ADisplayY, FrameX,
    FrameY) then
    Exit;

  // Round the *hot spot* to a pixel and hang the sprite off it, rather
  // than rounding the sprite's corner: the hot spot is the point the user
  // is actually aiming with, so it is the one that must not drift.
  Left := Round(FrameX) - AHotSpotX;
  Top := Round(FrameY) - AHotSpotY;
  Right := Left + ASpriteWidth;
  Bottom := Top + ASpriteHeight;

  // Clip against the frame, remembering how much came off the left and
  // top so the copy starts at the matching place inside the sprite.
  Result.SpriteX := 0;
  Result.SpriteY := 0;
  if Left < 0 then
  begin
    Result.SpriteX := -Left;
    Left := 0;
  end;
  if Top < 0 then
  begin
    Result.SpriteY := -Top;
    Top := 0;
  end;
  if Right > AMapping.PixelWidth then
    Right := AMapping.PixelWidth;
  if Bottom > AMapping.PixelHeight then
    Bottom := AMapping.PixelHeight;

  Result.DestinationX := Left;
  Result.DestinationY := Top;
  Result.Width := Right - Left;
  Result.Height := Bottom - Top;
  Result.Visible := (Result.Width > 0) and (Result.Height > 0);
  if not Result.Visible then
    Result := Default(TCursorBlitPlan);
end;

procedure BlitPremultipliedBgra(ADestination: Pointer;
  ADestinationBytesPerRow: Integer; ASource: Pointer;
  ASourceBytesPerRow: Integer; const APlan: TCursorBlitPlan);
var
  Row, Column, Channel, Alpha, Inverse, Value: Integer;
  SourceRow, DestinationRow, SourcePixel, DestinationPixel: PByte;
begin
  if not APlan.Visible or (ADestination = nil) or (ASource = nil) then
    Exit;
  if (ADestinationBytesPerRow <= 0) or (ASourceBytesPerRow <= 0) then
    Exit;
  for Row := 0 to APlan.Height - 1 do
  begin
    SourceRow := PByte(ASource);
    Inc(SourceRow, (APlan.SpriteY + Row) * ASourceBytesPerRow
      + APlan.SpriteX * 4);
    DestinationRow := PByte(ADestination);
    Inc(DestinationRow, (APlan.DestinationY + Row) * ADestinationBytesPerRow
      + APlan.DestinationX * 4);
    SourcePixel := SourceRow;
    DestinationPixel := DestinationRow;
    for Column := 0 to APlan.Width - 1 do
    begin
      Alpha := PByte(SourcePixel + 3)^;
      if Alpha = 255 then
      begin
        // The common case inside the arrow's black outline and white
        // body: a plain copy, alpha included, so the frame stays opaque.
        for Channel := 0 to 3 do
          PByte(DestinationPixel + Channel)^ := PByte(SourcePixel + Channel)^;
      end
      else if Alpha > 0 then
      begin
        Inverse := 255 - Alpha;
        for Channel := 0 to 3 do
        begin
          // Premultiplied source-over: dst = src + dst * (1 - a). The
          // +127 is round-to-nearest on the integer division, and the
          // clamp catches the one-unit overshoot it can produce.
          Value := PByte(SourcePixel + Channel)^
            + (PByte(DestinationPixel + Channel)^ * Inverse + 127) div 255;
          if Value > 255 then
            Value := 255;
          PByte(DestinationPixel + Channel)^ := Byte(Value);
        end;
      end;
      Inc(SourcePixel, 4);
      Inc(DestinationPixel, 4);
    end;
  end;
end;

function BigCursorSpriteExtent(AImagePoints, APixelsPerPoint,
  AMagnification: Double): Integer;
var
  Extent: Double;
begin
  Extent := AImagePoints * APixelsPerPoint * AMagnification;
  if Extent < MinBigCursorExtent then
    Exit(MinBigCursorExtent);
  if Extent > MaxBigCursorExtent then
    Exit(MaxBigCursorExtent);
  Result := Round(Extent);
  if Result < MinBigCursorExtent then
    Result := MinBigCursorExtent;
end;

function BigCursorHotSpot(AHotSpotPoints, AImagePoints: Double;
  ASpriteExtent: Integer): Integer;
begin
  if (AImagePoints <= 0) or (ASpriteExtent <= 0) then
    Exit(0);
  Result := Round(AHotSpotPoints / AImagePoints * ASpriteExtent);
  if Result < 0 then
    Result := 0;
  if Result > ASpriteExtent then
    Result := ASpriteExtent;
end;

function ResolveBigCursor(ATargetKind: TCaptureTargetKind;
  ABigCursor: Boolean): Boolean;
begin
  Result := ABigCursor and (ATargetKind <> ctkWindow);
end;

end.

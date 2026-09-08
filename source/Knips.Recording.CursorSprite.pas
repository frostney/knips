unit Knips.Recording.CursorSprite;

// The arrow sprite itself: the one Quartz routine that turns
// +[NSCursor arrowCursor] into a block of premultiplied BGRA bytes, and
// the release that gives them back.
//
// It exists because there were two of it. `TCursorOverlay.RenderSprite`
// (Knips.Recording.CursorOverlay, record time, the capture's scale) and
// `TExportCursor.RenderSprite` (Knips.Export.CursorEffect, export time,
// the output's scale) built the same sprite the same way — the same
// AppKit bootstrap, the same largest-representation pick, the same
// CGBitmapContextCreate at premultiplied BGRA over a GetMem block, the
// same CGContextDrawImage at the scaled extent, down to the wording of
// every error message. The difference was two arguments, and two
// arguments do not need two routines: what the caller decides is how
// many pixels a point is worth and how much bigger than life the
// pointer should be, and both of those are numbers.
//
// **Below both.** This unit knows nothing about a recording or an
// export; it depends on Knips.Recording.CursorMath (whose
// BigCursorSpriteExtent and BigCursorHotSpot decide the sprite's size
// and its hot spot), Knips.ObjC.Runtime (RespondsToSelector), and the
// two framework binding units. Both callers sit above it, exactly as
// they both already sit above Knips.Recording.CursorMath.
//
// **Raw memory, not a dynamic array.** The recording's blit runs on
// ScreenCaptureKit's capture queue, which this program's RTL never
// adopts (no cthreads on Darwin — ADR-0005), and a managed type there is
// what the rules in docs/architecture.md forbid. So TCursorSprite is a
// plain record of integers and one PByte from GetMem: reading every
// field of it on the capture queue is safe, and the record can be copied
// about with no reference counting anywhere. Only the main thread ever
// calls RenderArrowSprite or ReleaseCursorSprite.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  CocoaAll,
  Knips.ObjC.Runtime,
  Knips.Recording.CursorMath,
  MacOSAll;

type
  // One rendered arrow, premultiplied BGRA, top row first. Pixels is a
  // GetMem block of ByteCount bytes, or nil when nothing was rendered.
  TCursorSprite = record
    Pixels: PByte;
    ByteCount: PtrUInt;
    Width: Integer;
    Height: Integer;
    BytesPerRow: Integer;
    HotSpotX: Integer;
    HotSpotY: Integer;
  end;

// Renders the system arrow at APixelsPerPoint pixels to the point,
// AMagnification times life size, into a freshly allocated sprite. Main
// thread only: it brings AppKit up and sends Objective-C messages.
//
// The two numbers are kept apart rather than multiplied here because the
// callers disagree about where the magnification comes from — the
// recording folds Big Cursor's fixed 2.5 in at the call, the export has
// already folded the effect's own magnification into its pixels-per-point
// — and BigCursorSpriteExtent multiplies the three of them in one
// expression either way. Passing them through unchanged is what makes
// this routine bit-for-bit what both callers were doing before.
//
// ASprite is written over rather than freed, because `out` cannot free
// what it has never seen: a caller re-rendering into a sprite it already
// holds calls ReleaseCursorSprite on it first, which is what both of them
// do and what their own ReleasePixels used to do at the top of their own
// copy of this routine.
//
// False with a message when there is no sprite to be had, which is never
// a reason to fail the recording or the export around it: the caller
// carries on without a drawn pointer and says so. The record is empty in
// that case, so a caller that ignores the message and blits anyway blits
// nothing rather than reading a stale pointer.
function RenderArrowSprite(APixelsPerPoint, AMagnification: Double;
  out ASprite: TCursorSprite; out AError: string): Boolean;

// Frees the sprite's pixels and empties the record. Safe on a sprite
// that was never rendered, and safe twice.
procedure ReleaseCursorSprite(var ASprite: TCursorSprite);

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // NSApplicationActivationPolicyProhibited (NSApplication.h). See
  // EnsureAppKit below for why a recorder ever sets one.
  ActivationPolicyProhibited = 2;
  // CGBitmapContextCreate's flags for premultiplied BGRA: alpha first in
  // a little-endian 32-bit word is B, G, R, A in memory, which is the
  // layout kCVPixelFormatType_32BGRA names and the layout the blit
  // assumes on both sides.
  PremultipliedBgraFlags = kCGImageAlphaPremultipliedFirst
    or kCGBitmapByteOrder32Little;
  BitsPerComponent = 8;
  BytesPerPixel = 4;

{ AppKit has to be up before NSCursor answers anything: without an
  NSApplication, +[NSCursor arrowCursor] is nil (measured — it is not
  merely an image with no representations). The menu-bar app has one long
  before a recording or an export starts, so this only ever does anything
  for `knips record --big-cursor`, `knips render` and `knips export` from
  a shell, where it creates NSApp and immediately puts it in the
  Prohibited activation policy: the process registers with LaunchServices,
  as any AppKit client does, but takes no Dock tile and no menu bar. The
  policy is set only when this call is what created NSApp, so it can never
  overwrite the menu-bar app's own. }
procedure EnsureAppKit;
var
  Created: Boolean;
begin
  Created := NSApp = nil;
  NSApplication.sharedApplication;
  if Created and (NSApp <> nil) then
    NSApp.setActivationPolicy(ActivationPolicyProhibited);
end;

{ The largest bitmap representation the cursor image carries. macOS ships
  the arrow at 28x40 points with representations up to 280x400 pixels
  (measured), so a sprite at any scale this program asks for is a
  *downsample* of real pixels rather than a magnified 28x40 — which is
  the whole difference between a crisp big pointer and a blurry one.
  Representations that cannot produce a CGImage are skipped rather than
  cast blindly; NSImage's contents are whatever AppKit decided to put
  there. }
function LargestBitmapRepresentation(AImage: NSImage): NSBitmapImageRep;
var
  Representations: NSArray;
  Candidate: NSBitmapImageRep;
  I: Integer;
begin
  Result := nil;
  if AImage = nil then
    Exit;
  Representations := AImage.representations;
  if Representations = nil then
    Exit;
  for I := 0 to Integer(Representations.count) - 1 do
  begin
    if not RespondsToSelector(Representations.objectAtIndex(I), 'CGImage') then
      Continue;
    Candidate := NSBitmapImageRep(Representations.objectAtIndex(I));
    if (Result = nil) or (Candidate.pixelsWide > Result.pixelsWide) then
      Result := Candidate;
  end;
end;

procedure ReleaseCursorSprite(var ASprite: TCursorSprite);
begin
  if ASprite.Pixels <> nil then
    FreeMem(ASprite.Pixels);
  ASprite := Default(TCursorSprite);
end;

function RenderArrowSprite(APixelsPerPoint, AMagnification: Double;
  out ASprite: TCursorSprite; out AError: string): Boolean;
var
  Cursor: NSCursor;
  Image: NSImage;
  Representation: NSBitmapImageRep;
  Bitmap: CGImageRef;
  Space: CGColorSpaceRef;
  Context: CGContextRef;
  PointWidth, PointHeight: Double;
  // Built here and handed over only once it is complete. ASprite is the
  // caller's own field, and on the recording side the capture queue
  // reads that field's Pixels as "the sprite is ready": publishing the
  // pointer before the block is cleared and drawn would open a window in
  // which the queue could blit heap garbage.
  Sprite: TCursorSprite;
begin
  Result := False;
  AError := '';
  ASprite := Default(TCursorSprite);
  Sprite := Default(TCursorSprite);
  EnsureAppKit;

  Cursor := NSCursor.arrowCursor;
  if Cursor = nil then
  begin
    AError := 'AppKit has no arrow cursor to draw';
    Exit;
  end;
  Image := Cursor.image;
  Representation := LargestBitmapRepresentation(Image);
  if Representation = nil then
  begin
    AError := 'the arrow cursor has no bitmap representation';
    Exit;
  end;
  PointWidth := Image.size.width;
  PointHeight := Image.size.height;
  if (PointWidth <= 0) or (PointHeight <= 0) then
  begin
    AError := 'the arrow cursor has no size';
    Exit;
  end;

  Sprite.Width := BigCursorSpriteExtent(PointWidth, APixelsPerPoint,
    AMagnification);
  Sprite.Height := BigCursorSpriteExtent(PointHeight, APixelsPerPoint,
    AMagnification);
  // The hot spot is the image's own, at the ratio the extent was scaled
  // by — so it follows whatever size the two numbers above came to,
  // rather than being scaled a second time from the same inputs.
  Sprite.HotSpotX := BigCursorHotSpot(Cursor.hotSpot.x, PointWidth,
    Sprite.Width);
  Sprite.HotSpotY := BigCursorHotSpot(Cursor.hotSpot.y, PointHeight,
    Sprite.Height);
  Sprite.BytesPerRow := Sprite.Width * BytesPerPixel;
  Sprite.ByteCount := PtrUInt(Sprite.BytesPerRow) * PtrUInt(Sprite.Height);

  Sprite.Pixels := GetMem(Sprite.ByteCount);
  if Sprite.Pixels = nil then
  begin
    AError := 'could not allocate the cursor sprite';
    Exit;
  end;
  // Quartz does not clear a buffer it is handed, and the sprite is
  // mostly transparent; an uncleared one would blit whatever was on the
  // heap around the arrow.
  FillChar(Sprite.Pixels^, Sprite.ByteCount, 0);

  Space := CGColorSpaceCreateDeviceRGB;
  if Space = nil then
  begin
    AError := 'CGColorSpaceCreateDeviceRGB failed';
    ReleaseCursorSprite(Sprite);
    Exit;
  end;
  Context := CGBitmapContextCreate(Sprite.Pixels, Sprite.Width,
    Sprite.Height, BitsPerComponent, Sprite.BytesPerRow, Space,
    PremultipliedBgraFlags);
  CGColorSpaceRelease(Space);
  if Context = nil then
  begin
    AError := 'CGBitmapContextCreate failed for the cursor sprite';
    ReleaseCursorSprite(Sprite);
    Exit;
  end;

  // A bitmap context's memory is top row first even though its user space
  // has y growing up, so drawing the image into the whole context lands
  // it the right way up for a buffer that is read row 0 = top — which is
  // both what a CVPixelBuffer is and what the blit assumes.
  Bitmap := Representation.CGImage;
  if Bitmap <> nil then
  begin
    CGContextSetInterpolationQuality(Context, kCGInterpolationHigh);
    CGContextDrawImage(Context, CGRectMake(0, 0, Sprite.Width,
      Sprite.Height), Bitmap);
    CGContextFlush(Context);
  end;
  CGContextRelease(Context);
  if Bitmap = nil then
  begin
    AError := 'the arrow cursor representation has no CGImage';
    ReleaseCursorSprite(Sprite);
    Exit;
  end;

  ASprite := Sprite;
  Result := True;
end;

{$ENDIF}

end.

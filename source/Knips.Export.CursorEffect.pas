unit Knips.Export.CursorEffect;

// The cursor as a post-recording effect: the pointer drawn into a GIF or
// an APNG at **export** time, from the event sidecar, rather than captured
// with the screen.
//
// This is the first member of the export-effects set (TExportEffects in
// Knips.Options), and it is shaped as a member rather than as a feature so
// the next one does not have to unpick it: post-hoc Zoom on Click will
// drive a per-frame crop from the same sidecar's click track, and the
// pointer's position will have to be transformed by that crop. The seam is
// TCursorFrameMapping, which is already rebuilt per frame from whatever
// rectangle the frame shows — a crop is one more thing that decides that
// rectangle. Nothing here implements it.
//
// **What it is for.** A captured pointer is a captured pointer: it sits
// wherever the compositor put it in each frame, and at twenty frames a
// second in a GIF that reads as a stutter. The sidecar has the pointer's
// whole path at thirty samples a second, on the movie's own clock, so an
// export can put the pointer back — interpolated to each output frame's
// time and smoothed over a short window — and get a glide instead.
//
// **How it works.** `knips record --smooth-cursor` switches
// ScreenCaptureKit's own cursor off (the same suppression Big Cursor uses)
// and writes `"cursor":"smooth"` into the sidecar's header. The movie is
// then genuinely cursorless, which is stated out loud at record time
// because it is the one thing about this feature that can surprise
// somebody. On export, this object notices that header, renders one
// pointer sprite at the *output's* scale, and composites it into every
// scaled frame with the same premultiplied source-over Big Cursor uses
// (Knips.Recording.CursorMath).
//
// **Only GIF and APNG, in this version.** They are the two formats the
// pipeline re-encodes frame by frame, so they are the two that have a
// frame to draw into. A movie output of `knips export` is a passthrough
// trim — the same coded samples copied into a new container, no decode at
// all — and putting a pointer into that would mean re-encoding the video,
// which is a different feature with different costs. Nothing here does it,
// and both the recorder and the exporter say so rather than leaving
// somebody to find a cursorless MP4 later.
//
// **The smoothing.** A centred moving average over a short time window
// (DefaultCursorSmoothingSeconds), which is
// Knips.Recording.Sidecar.SmoothSidecarPath. Centred, not causal: a
// one-pole ease would put the drawn pointer permanently behind the real
// one, and this track is not live — the whole path is known before the
// first frame is written, so there is no reason to accept lag. The window
// is the shortest one that visibly removes the sample-to-sample staircase
// without rounding off a deliberate flick.
//
// **The sprite's size is a parameter, and the default is life size.**
// Putting back what the capture left out means putting it back at the size
// it would have had, so ecmSmooth draws at 1.0. ecmBig draws Big Cursor's
// 2.5x from the same track — the same look, decided at export instead of
// at record time, which is the whole point of doing this from a sidecar.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  CocoaAll,
  Knips.Export.Bitmap,
  Knips.ObjC.Runtime,
  Knips.Options,
  Knips.Recording.CursorMath,
  Knips.Recording.Sidecar,
  MacOSAll;

const
  // Full width of the smoothing window, in seconds. Five samples at the
  // sidecar's nominal thirty hertz. Chosen by eye against the same take
  // exported both ways: three samples still shows the staircase on a slow
  // drag, and nine rounds the corner off a deliberate flick.
  DefaultCursorSmoothingSeconds = 5 / 30;
  // The drawn pointer is the system pointer's own size. See the unit
  // comment.
  SmoothCursorMagnification = 1.0;

type
  TExportCursor = class
  private
    FLog: TSidecarLog;
    FSmoothed: TSidecarSampleArray;
    FSmoothedCount: Integer;
    FPixels: PByte;
    FSpriteWidth: Integer;
    FSpriteHeight: Integer;
    FSpriteBytesPerRow: Integer;
    FHotSpotX: Integer;
    FHotSpotY: Integer;
    FReady: Boolean;
    FAsked: Boolean;
    FDrawnFrames: Int64;
    FOffFrameFrames: Int64;
    procedure ReleasePixels;
    function RenderSprite(APixelsPerPoint: Double;
      out AError: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    // Loads the sidecar beside AMoviePath and gets ready to draw into
    // frames AOutputWidth by AOutputHeight pixels.
    //
    // AEffects decides what is drawn: ecmNone draws nothing, ecmSmooth
    // and ecmBig draw whatever the track says regardless of what the
    // recording asked for, and ecmAsRecorded — the default — draws only
    // for a take recorded with --smooth-cursor.
    //
    // False, with a message, whenever there is nothing to do: no sidecar,
    // no anchor, no samples, a window recording (whose samples cannot be
    // mapped into frame pixels at all), a movie whose pixels already carry
    // a pointer, or a mode that asks for none. The caller treats every one
    // of those as "export without a drawn pointer", not as a failure: the
    // animation is correct either way.
    function Prepare(const AMoviePath: string;
      const AEffects: TExportEffects; AOutputWidth, AOutputHeight: Integer;
      out AError: string): Boolean;
    // Draws the pointer into one scaled frame, at ASeconds on the movie's
    // own timeline (which is what TMovieReaderFrame.Seconds is). Does
    // nothing when the pointer was outside the captured rectangle at that
    // instant, which is a normal thing for it to have been.
    procedure DrawInto(var AImage: TBgraImage; ASeconds: Double);
    // Zeroes the frame counters. A GIF export walks the movie twice — the
    // palette has to be chosen before the first frame is written — and
    // both passes draw the pointer, so the encode pass calls this to make
    // the reported count the number of frames in the file rather than
    // twice it.
    procedure ResetCounters;
    property Ready: Boolean read FReady;
    // Whether the movie's sidecar asked for a synthetic pointer at all.
    // The difference between "no sidecar, nothing to do" and "the sidecar
    // asked and something went wrong" — the first is the ordinary case
    // for every movie ever recorded, the second is worth a line.
    property Asked: Boolean read FAsked;
    property SpriteWidth: Integer read FSpriteWidth;
    property SpriteHeight: Integer read FSpriteHeight;
    // Frames the pointer went into, and frames where it was off the
    // captured rectangle. Reported by the exporter, for the same reason
    // Big Cursor reports its own: a synthetic cursor that silently drew
    // nothing looks exactly like one that was never asked for.
    property DrawnFrames: Int64 read FDrawnFrames;
    property OffFrameFrames: Int64 read FOffFrameFrames;
  end;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  ActivationPolicyProhibited = 2;
  PremultipliedBgraFlags = kCGImageAlphaPremultipliedFirst
    or kCGBitmapByteOrder32Little;
  BitsPerComponent = 8;
  BytesPerPixel = 4;

// Same rule as Knips.Recording.CursorOverlay: +[NSCursor arrowCursor] is
// nil without an NSApplication. `knips export` from a shell has none, so
// one is made and immediately put in the Prohibited activation policy —
// no Dock tile, no menu bar. The menu-bar app already has NSApp long
// before an export starts, and the policy is set only when this call is
// what created it, so it can never overwrite the app's own.
procedure EnsureAppKit;
var
  Created: Boolean;
begin
  Created := NSApp = nil;
  NSApplication.sharedApplication;
  if Created and (NSApp <> nil) then
    NSApp.setActivationPolicy(ActivationPolicyProhibited);
end;

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

{ TExportCursor }

constructor TExportCursor.Create;
begin
  inherited Create;
end;

destructor TExportCursor.Destroy;
begin
  ReleasePixels;
  FreeAndNil(FLog);
  inherited Destroy;
end;

procedure TExportCursor.ReleasePixels;
begin
  FReady := False;
  if FPixels <> nil then
  begin
    FreeMem(FPixels);
    FPixels := nil;
  end;
end;

function TExportCursor.RenderSprite(APixelsPerPoint: Double;
  out AError: string): Boolean;
var
  Cursor: NSCursor;
  Image: NSImage;
  Representation: NSBitmapImageRep;
  Bitmap: CGImageRef;
  Space: CGColorSpaceRef;
  Context: CGContextRef;
  PointWidth, PointHeight: Double;
  ByteCount: PtrUInt;
begin
  Result := False;
  AError := '';
  ReleasePixels;
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

  // The magnification is already folded into APixelsPerPoint by Prepare,
  // which is the only caller: one number decides the sprite's size, so
  // there is nowhere for the two to disagree.
  FSpriteWidth := BigCursorSpriteExtent(PointWidth, APixelsPerPoint, 1);
  FSpriteHeight := BigCursorSpriteExtent(PointHeight, APixelsPerPoint, 1);
  FHotSpotX := BigCursorHotSpot(Cursor.hotSpot.x, PointWidth, FSpriteWidth);
  FHotSpotY := BigCursorHotSpot(Cursor.hotSpot.y, PointHeight,
    FSpriteHeight);
  FSpriteBytesPerRow := FSpriteWidth * BytesPerPixel;
  ByteCount := PtrUInt(FSpriteBytesPerRow) * PtrUInt(FSpriteHeight);

  FPixels := GetMem(ByteCount);
  if FPixels = nil then
  begin
    AError := 'could not allocate the cursor sprite';
    Exit;
  end;
  // Quartz does not clear a buffer it is handed and the sprite is mostly
  // transparent; an uncleared one would blit whatever was on the heap.
  FillChar(FPixels^, ByteCount, 0);

  Space := CGColorSpaceCreateDeviceRGB;
  if Space = nil then
  begin
    AError := 'CGColorSpaceCreateDeviceRGB failed';
    ReleasePixels;
    Exit;
  end;
  Context := CGBitmapContextCreate(FPixels, FSpriteWidth, FSpriteHeight,
    BitsPerComponent, FSpriteBytesPerRow, Space, PremultipliedBgraFlags);
  CGColorSpaceRelease(Space);
  if Context = nil then
  begin
    AError := 'CGBitmapContextCreate failed for the cursor sprite';
    ReleasePixels;
    Exit;
  end;
  Bitmap := Representation.CGImage;
  if Bitmap <> nil then
  begin
    CGContextSetInterpolationQuality(Context, kCGInterpolationHigh);
    CGContextDrawImage(Context, CGRectMake(0, 0, FSpriteWidth,
      FSpriteHeight), Bitmap);
    CGContextFlush(Context);
  end;
  CGContextRelease(Context);
  if Bitmap = nil then
  begin
    AError := 'the arrow cursor representation has no CGImage';
    ReleasePixels;
    Exit;
  end;

  FReady := True;
  Result := True;
end;

function TExportCursor.Prepare(const AMoviePath: string;
  const AEffects: TExportEffects; AOutputWidth, AOutputHeight: Integer;
  out AError: string): Boolean;
var
  Path: string;
  PixelsPerPoint, Magnification, Window: Double;
  Available: TSidecarEffectAvailability;
begin
  Result := False;
  FAsked := False;
  FDrawnFrames := 0;
  FOffFrameFrames := 0;
  if not EffectsDrawCursor(AEffects) then
  begin
    AError := 'no pointer was asked for';
    Exit;
  end;
  // An EXPLICIT --cursor=smooth|big is a request, and a request that
  // cannot be honoured has to be said out loud — including when there is
  // no sidecar at all, which is the most likely reason and was previously
  // the one case that stayed silent, because the load fails before
  // anything gets a chance to record that somebody asked.
  // ecmAsRecorded stays quiet: it is what every export has always done.
  FAsked := AEffects.Cursor <> ecmAsRecorded;
  Path := SidecarPathFor(AMoviePath);
  FreeAndNil(FLog);
  FLog := TSidecarLog.Create;
  if not FLog.LoadFromFile(Path, AError) then
  begin
    FreeAndNil(FLog);
    Exit;
  end;
  // ecmAsRecorded is the default and the quiet one: it draws only for a
  // take that was recorded expecting it. The two explicit modes draw for
  // any take that CAN take a pointer, which is what the playback window's
  // Effects control offers.
  if (AEffects.Cursor = ecmAsRecorded)
    and (FLog.Header.CursorRender <> scrSmooth) then
  begin
    AError := 'this recording was not made with a smooth cursor';
    FreeAndNil(FLog);
    Exit;
  end;
  // Past here the sidecar itself asked, so an as-recorded export is no
  // longer the quiet case either.
  FAsked := True;

  // One question, asked of the sidecar: everything about whether this
  // take can still have a pointer drawn into it lives there, so that the
  // Effects control and this object can never disagree about it.
  Available := AvailableExportEffects(FLog);
  if not Available.CanDrawCursor then
  begin
    AError := Available.Reason;
    if AError = '' then
      AError := 'this recording cannot have a pointer drawn into it';
    FreeAndNil(FLog);
    Exit;
  end;
  if (AOutputWidth <= 0) or (AOutputHeight <= 0)
    or (FLog.Header.BaseWidth <= 0) then
  begin
    AError := 'nothing to draw a pointer into';
    FreeAndNil(FLog);
    Exit;
  end;

  Window := AEffects.CursorSmoothingSeconds;
  if Window = 0 then
    Window := DefaultCursorSmoothingSeconds;
  // The whole track, smoothed once, before a frame is written. The
  // sidecar's own array is not touched: the raw path is still what
  // StateAt reads the source rectangle out of.
  FSmoothed := SmoothSidecarPath(FLog.RawSamples, FLog.SampleCount, Window);
  FSmoothedCount := Length(FSmoothed);

  Magnification := AEffects.CursorMagnification;
  if Magnification <= 0 then
  begin
    if AEffects.Cursor = ecmBig then
      Magnification := BigCursorMagnification
    else
      Magnification := SmoothCursorMagnification;
  end;
  // The OUTPUT's pixels per point, not the movie's: the sprite is drawn
  // into the scaled frame, so a 2x recording exported at half width wants
  // a one-times pointer and not a two-times one.
  //
  // Sized once, from the recording's BASE rectangle, and deliberately not
  // rescaled per frame on a take whose capture zoomed. Two reasons, and
  // they are the same two Big Cursor gives (Knips.Recording.CursorMath):
  // resampling the sprite every frame is real work in the inner loop, and
  // a drawn pointer that keeps its size while the content zooms under it
  // reads as deliberate rather than broken. The consequence is stated
  // rather than hidden: on a Zoom on Click take the drawn pointer is
  // smaller, relative to the content, than the real one would have been
  // at full zoom — by the zoom factor, so up to about 2x.
  PixelsPerPoint := AOutputWidth / FLog.Header.BaseWidth;
  if not RenderSprite(PixelsPerPoint * Magnification, AError) then
  begin
    FreeAndNil(FLog);
    Exit;
  end;
  Result := True;
end;

procedure TExportCursor.ResetCounters;
begin
  FDrawnFrames := 0;
  FOffFrameFrames := 0;
end;

procedure TExportCursor.DrawInto(var AImage: TBgraImage; ASeconds: Double);
var
  State: TSidecarSample;
  Mapping: TCursorFrameMapping;
  Plan: TCursorBlitPlan;
  X, Y: Double;
begin
  if not FReady or (FLog = nil) or (Length(AImage.Pixels) = 0) then
    Exit;
  // The source rectangle from the raw track — it is what the capture was
  // actually reading, and averaging two of them would name a rectangle
  // that was never read. The position from the smoothed one.
  if not FLog.StateAt(ASeconds, State) then
    Exit;
  if not InterpolatePath(FSmoothed, FSmoothedCount,
    FLog.AnchorHost + ASeconds, X, Y) then
    Exit;
  Mapping := CursorFrameMapping(AImage.Width, AImage.Height, State.SourceX,
    State.SourceY, State.SourceWidth, State.SourceHeight);
  Plan := PlanCursorBlit(Mapping, X, Y, FSpriteWidth, FSpriteHeight,
    FHotSpotX, FHotSpotY);
  if not Plan.Visible then
  begin
    Inc(FOffFrameFrames);
    Exit;
  end;
  BlitPremultipliedBgra(@AImage.Pixels[0], AImage.BytesPerRow, FPixels,
    FSpriteBytesPerRow, Plan);
  Inc(FDrawnFrames);
end;

{$ENDIF}

end.

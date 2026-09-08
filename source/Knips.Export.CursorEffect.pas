unit Knips.Export.CursorEffect;

// The cursor as a post-recording effect: the pointer drawn into a GIF or
// an APNG at **export** time, from the event sidecar, rather than captured
// with the screen.
//
// This is the first member of the export-effects set (TExportEffects in
// Knips.Options), and it was shaped as a member rather than as a feature
// so the next one would not have to unpick it. That paid off: post-hoc
// Zoom on Click (Knips.Export.ZoomTrack) now drives a per-frame crop
// from the same sidecar's click track, and the pointer is transformed by
// that crop through the seam this unit was built with —
// TCursorFrameMapping, rebuilt per frame from whatever rectangle the
// frame shows. `DrawIntoCropped` and `DrawIntoPixels` are that seam
// taken up; the crop is one more thing that decides the rectangle, and
// nothing about the placement had to change to admit it.
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
// **Not only GIF and APNG any more.** They were the first two, because
// they are the formats the export pipeline re-encodes frame by frame and
// so the two that have a frame to draw into. A movie output of `knips
// export` is still a passthrough trim — the same coded samples copied
// into a new container, no decode at all — and still cannot take a
// pointer, which the exporter says out loud rather than leaving somebody
// to find a cursorless MP4 later.
//
// The MP4 that CAN take one is the deliverable: `knips render`
// (Knips.Export.Render) decodes the raw take, draws the pointer through
// `DrawIntoPixels` straight into the writer's own CVPixelBuffer, and
// re-encodes. That is the third caller of this unit and the one the
// menu-bar app uses on every stop; the re-encode this comment called "a
// different feature with different costs" was built, and the costs are
// measured in that unit's own header.
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

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  Knips.Export.Bitmap,
  Knips.Options,
  Knips.Recording.CursorMath,
  Knips.Recording.CursorSprite,
  Knips.Recording.Sidecar;

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
    // Whether FLog is ours to free. A caller that has already loaded the
    // take's sidecar lends it rather than making this class parse the
    // same file a second time — which a render did, every time, at the
    // full cost of the parse.
    FOwnsLog: Boolean;
    FSmoothed: TSidecarSampleArray;
    FSmoothedCount: Integer;
    // The drawn pointer, premultiplied BGRA, made once by
    // Knips.Recording.CursorSprite at the OUTPUT's scale. Its Pixels
    // being non-nil is what "ready" means.
    FSprite: TCursorSprite;
    FAsked: Boolean;
    FDrawnFrames: Int64;
    FOffFrameFrames: Int64;
    procedure ForgetLog;
    function PlanAt(AWidth, AHeight: Integer; ASeconds: Double;
      AHasSource: Boolean; ASourceX, ASourceY, ASourceWidth,
      ASourceHeight: Double; out APlan: TCursorBlitPlan): Boolean;
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
    // ABorrowedLog is the caller's own already-loaded sidecar for this
    // movie, or nil to load one. Borrowed logs are not freed here.
    //
    // Both callers in this program lend: the render loads the sidecar to
    // decide whether the take can have anything at all, and the export
    // pipeline loads it once in LoadSidecar and does not call this when
    // that came back with nothing. The self-loading branch is the
    // fallback for a caller that has no log of its own — it is not a way
    // to retry a load that already failed, which is what it had become
    // on the export side: the same file parsed a second time, failing
    // the same way, for a message the caller then discarded.
    function Prepare(const AMoviePath: string;
      const AEffects: TExportEffects; AOutputWidth, AOutputHeight: Integer;
      ABorrowedLog: TSidecarLog; out AError: string): Boolean;
    // Draws the pointer into one scaled frame, at ASeconds on the movie's
    // own timeline (which is what TMovieReaderFrame.Seconds is). Does
    // nothing when the pointer was outside the captured rectangle at that
    // instant, which is a normal thing for it to have been.
    procedure DrawInto(var AImage: TBgraImage; ASeconds: Double);
    // The same, into a frame that shows a *crop* of the recorded
    // rectangle rather than the whole of it — which is what a post-hoc
    // Zoom on Click produces (Knips.Export.ZoomTrack). The rectangle is
    // in the recorded display's own top-left points, exactly like the
    // one the sidecar's samples carry, and it replaces the sample's own:
    // the frame no longer shows what the capture was reading, so the
    // pointer has to be placed against what it *does* show.
    procedure DrawIntoCropped(var AImage: TBgraImage; ASeconds: Double;
      ASourceX, ASourceY, ASourceWidth, ASourceHeight: Double);
    // The same again, straight into foreign memory — a locked
    // CVPixelBuffer in the MP4 render pass, which has no TBgraImage to
    // draw into and no reason to make one. AHasSource False takes the
    // rectangle the capture was reading, as DrawInto does.
    procedure DrawIntoPixels(APixels: Pointer; ABytesPerRow, AWidth,
      AHeight: Integer; ASeconds: Double; AHasSource: Boolean;
      ASourceX, ASourceY, ASourceWidth, ASourceHeight: Double);
    // Where the sprite would land, without drawing it: the top-left of
    // the copied area in output pixels, and False when nothing would be
    // drawn at all. The arguments are DrawIntoPixels', because it is the
    // same placement — this is that call with the blit taken off the
    // end.
    //
    // It exists for the render's frame synthesis
    // (Knips.Export.Cadence): deciding whether a frame between two
    // captured ones would be a *different picture* means asking where
    // the pointer lands at that instant, in the whole pixels the blit
    // uses, and asking it without paying for a blit that may not
    // happen.
    function SpritePlacement(AWidth, AHeight: Integer; ASeconds: Double;
      AHasSource: Boolean; ASourceX, ASourceY, ASourceWidth,
      ASourceHeight: Double; out AX, AY: Integer): Boolean;
    // Zeroes the frame counters. A GIF export walks the movie twice — the
    // palette has to be chosen before the first frame is written — and
    // both passes draw the pointer, so the encode pass calls this to make
    // the reported count the number of frames in the file rather than
    // twice it.
    procedure ResetCounters;
    // Whether the movie's sidecar asked for a synthetic pointer at all.
    // The difference between "no sidecar, nothing to do" and "the sidecar
    // asked and something went wrong" — the first is the ordinary case
    // for every movie ever recorded, the second is worth a line.
    property Asked: Boolean read FAsked;
    // True when the drawn pointer never moves: every sample of the
    // smoothed track holds exactly the position the first one does.
    //
    // Exact, not a tolerance, and asked of the RAW track. A pointer
    // nobody touched is sampled from CGEventGetLocation over and over
    // and comes back byte-identical — measured on a real take, 201
    // samples with exactly one distinct x (3013.867) and one distinct y
    // — so equality is the honest test and a threshold would only
    // invent a boundary to be wrong at.
    //
    // It exists for the frame-synthesis bound: a render fills a gap only
    // where the next instant would be a DIFFERENT picture, and with no
    // zoom in play the only thing that can make one different is the
    // pointer moving. A track that never moves therefore cannot produce
    // a single synthesised frame, which is a fact about the take and not
    // a guess about it. False when there is no track to answer from,
    // which keeps the caller on the generous bound.
    function TrackIsStationary: Boolean;
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

{ TExportCursor }

constructor TExportCursor.Create;
begin
  inherited Create;
end;

destructor TExportCursor.Destroy;
begin
  ReleaseCursorSprite(FSprite);
  ForgetLog;
  inherited Destroy;
end;

procedure TExportCursor.ForgetLog;
begin
  if FOwnsLog then
    FLog.Free;
  FLog := nil;
  FOwnsLog := False;
end;

function TExportCursor.Prepare(const AMoviePath: string;
  const AEffects: TExportEffects; AOutputWidth, AOutputHeight: Integer;
  ABorrowedLog: TSidecarLog; out AError: string): Boolean;
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
  ForgetLog;
  if ABorrowedLog <> nil then
    FLog := ABorrowedLog
  else
  begin
    Path := SidecarPathFor(AMoviePath);
    FLog := TSidecarLog.Create;
    FOwnsLog := True;
    if not FLog.LoadFromFile(Path, AError) then
    begin
      ForgetLog;
      Exit;
    end;
  end;
  // ecmAsRecorded is the default and the quiet one: it draws only for a
  // take that was recorded expecting it. The two explicit modes draw for
  // any take that CAN take a pointer, which is what the playback window's
  // Effects control offers.
  if (AEffects.Cursor = ecmAsRecorded)
    and (FLog.Header.CursorRender <> scrSmooth) then
  begin
    AError := 'this recording was not made with a smooth cursor';
    ForgetLog;
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
    // The CURSOR's own reason, not the summary. The two are the same
    // string whenever CanDrawCursor is False — a baked pointer is the
    // most limiting fact there is, so the summary carries it — but that
    // is a property of the ordering in AvailableExportEffects rather
    // than of this call site, and this call site is only ever asking
    // about the pointer.
    AError := Available.CursorReason;
    if AError = '' then
      AError := 'this recording cannot have a pointer drawn into it';
    ForgetLog;
    Exit;
  end;
  if (AOutputWidth <= 0) or (AOutputHeight <= 0)
    or (FLog.Header.BaseWidth <= 0) then
  begin
    AError := 'nothing to draw a pointer into';
    ForgetLog;
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
  // The magnification is folded into the pixels-per-point here rather
  // than handed to the renderer as its own factor, which is what this
  // call has always done: one number decides the sprite's size, so there
  // is nowhere for the two to disagree. (Big Cursor's own caller passes
  // the two apart, because its factor is a constant of the feature and
  // not a resolved option.)
  ReleaseCursorSprite(FSprite);
  if not RenderArrowSprite(PixelsPerPoint * Magnification, 1, FSprite,
    AError) then
  begin
    ForgetLog;
    Exit;
  end;
  Result := True;
end;

procedure TExportCursor.ResetCounters;
begin
  FDrawnFrames := 0;
  FOffFrameFrames := 0;
end;

// The placement, shared by the draw and by the query that only wants to
// know where the sprite would go. False when there is nothing to place.
function TExportCursor.PlanAt(AWidth, AHeight: Integer; ASeconds: Double;
  AHasSource: Boolean; ASourceX, ASourceY, ASourceWidth,
  ASourceHeight: Double; out APlan: TCursorBlitPlan): Boolean;
var
  State: TSidecarSample;
  Mapping: TCursorFrameMapping;
  X, Y: Double;
begin
  Result := False;
  APlan := Default(TCursorBlitPlan);
  if (FSprite.Pixels = nil) or (FLog = nil) then
    Exit;
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  // The source rectangle from the raw track — it is what the capture was
  // actually reading, and averaging two of them would name a rectangle
  // that was never read. The position from the smoothed one.
  if not FLog.StateAt(ASeconds, State) then
    Exit;
  // The take's own limit on how long a silence may be drawn through; see
  // Knips.Recording.Sidecar.InterpolatePath. A sparse track holds the
  // last known position rather than sliding the sprite across the screen
  // between two samples minutes apart.
  if not InterpolatePath(FSmoothed, FSmoothedCount,
    FLog.AnchorHost + ASeconds, FLog.MaxInterpolatedGap, X, Y) then
    Exit;
  if not AHasSource then
  begin
    ASourceX := State.SourceX;
    ASourceY := State.SourceY;
    ASourceWidth := State.SourceWidth;
    ASourceHeight := State.SourceHeight;
  end;
  Mapping := CursorFrameMapping(AWidth, AHeight, ASourceX, ASourceY,
    ASourceWidth, ASourceHeight);
  APlan := PlanCursorBlit(Mapping, X, Y, FSprite.Width, FSprite.Height,
    FSprite.HotSpotX, FSprite.HotSpotY);
  Result := True;
end;

procedure TExportCursor.DrawIntoPixels(APixels: Pointer; ABytesPerRow,
  AWidth, AHeight: Integer; ASeconds: Double; AHasSource: Boolean;
  ASourceX, ASourceY, ASourceWidth, ASourceHeight: Double);
var
  Plan: TCursorBlitPlan;
begin
  if APixels = nil then
    Exit;
  if not PlanAt(AWidth, AHeight, ASeconds, AHasSource, ASourceX, ASourceY,
    ASourceWidth, ASourceHeight, Plan) then
    Exit;
  if not Plan.Visible then
  begin
    Inc(FOffFrameFrames);
    Exit;
  end;
  BlitPremultipliedBgra(APixels, ABytesPerRow, FSprite.Pixels,
    FSprite.BytesPerRow, Plan);
  Inc(FDrawnFrames);
end;

function TExportCursor.TrackIsStationary: Boolean;
var
  I: Integer;
begin
  Result := False;
  if (FLog = nil) or (FLog.SampleCount <= 0) then
    Exit;
  // The RAW track, not the smoothed one, and that is the whole reason
  // this reads the log rather than FSmoothed. Smoothing a constant track
  // gives a constant track in arithmetic and not in floating point:
  // SmoothSidecarPath sums a window and divides by its width, the width
  // shrinks at both ends, and 3013.867 summed eleven times and divided
  // by eleven need not come back as the bits it started as — so exact
  // equality over the smoothed path answers False for a pointer that
  // demonstrably never moved. The raw samples are what CGEventGetLocation
  // actually returned, and a parked pointer returns them byte-identical.
  //
  // The implication runs the safe way, too: a raw track that never moves
  // cannot produce a smoothed one that does by more than the last bit of
  // a Double, and a sprite is blitted at a whole output pixel.
  for I := 1 to FLog.SampleCount - 1 do
    if (FLog.RawSamples[I].X <> FLog.RawSamples[0].X)
      or (FLog.RawSamples[I].Y <> FLog.RawSamples[0].Y) then
      Exit;
  Result := True;
end;

function TExportCursor.SpritePlacement(AWidth, AHeight: Integer;
  ASeconds: Double; AHasSource: Boolean; ASourceX, ASourceY, ASourceWidth,
  ASourceHeight: Double; out AX, AY: Integer): Boolean;
var
  Plan: TCursorBlitPlan;
begin
  AX := 0;
  AY := 0;
  Result := False;
  if not PlanAt(AWidth, AHeight, ASeconds, AHasSource, ASourceX, ASourceY,
    ASourceWidth, ASourceHeight, Plan) then
    Exit;
  if not Plan.Visible then
    Exit;
  AX := Plan.DestinationX;
  AY := Plan.DestinationY;
  Result := True;
end;

procedure TExportCursor.DrawInto(var AImage: TBgraImage; ASeconds: Double);
begin
  if Length(AImage.Pixels) = 0 then
    Exit;
  DrawIntoPixels(@AImage.Pixels[0], AImage.BytesPerRow, AImage.Width,
    AImage.Height, ASeconds, False, 0, 0, 0, 0);
end;

procedure TExportCursor.DrawIntoCropped(var AImage: TBgraImage;
  ASeconds: Double; ASourceX, ASourceY, ASourceWidth,
  ASourceHeight: Double);
begin
  if Length(AImage.Pixels) = 0 then
    Exit;
  DrawIntoPixels(@AImage.Pixels[0], AImage.BytesPerRow, AImage.Width,
    AImage.Height, ASeconds, True, ASourceX, ASourceY, ASourceWidth,
    ASourceHeight);
end;

{$ENDIF}

end.

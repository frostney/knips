unit Knips.Export.Pipeline;

// One export, start to finish: movie in, animated image out.
//
//   AVAssetReader -> decimate to the target rate -> optional downscale
//                 -> GIF  (median-cut palette, dither, LZW)
//                 -> APNG (no palette at all, zlib)
//
// The reader, the decimator and the scaler are shared; only the sink
// differs, so the two formats cannot drift apart on timing or on which
// frames they pick. A GIF needs two passes over the movie, because the
// palette has to be known before the first frame is written and
// AVAssetReader cannot rewind: the first pass walks the range, hands a
// spread of its frames to the quantiser on a schedule that thins itself
// as it goes (TGifPaletteSampler), and the second encodes. APNG has
// nothing to learn first, so it makes one pass.
//
// Only one decoded frame and one pending scaled frame are ever in
// memory, whichever format is being written.
//
// Frame delays come from the presentation stamps the reader hands back,
// snapped to the decimation grid by Knips.Export.Timing, so a recording
// that idles keeps its timing while a steady one gets a steady cadence.
//
// The third thing `knips export` can write — a trimmed movie — does not
// come through here at all: it decodes nothing. See
// Knips.Export.MovieTrim.

{$I Knips.inc}

interface

{$IFDEF DARWIN}
{$modeswitch objectivec2}

uses
  Math,
  SysUtils,

  CocoaAll,
  Knips.Capture.CoreMedia,
  Knips.Export.Apng,
  Knips.Export.Bitmap,
  Knips.Export.Cadence,
  Knips.Export.CursorEffect,
  Knips.Export.Gif,
  Knips.Export.MovieReader,
  Knips.Export.SizeEstimate,
  Knips.Export.Timing,
  Knips.Export.ZoomTrack,
  Knips.Options,
  Knips.Recording.LiveMath,
  Knips.Recording.Sidecar,
  MacOSAll;

const
  ProgressEveryFrames = 100;
  // How often the per-frame autorelease pool is drained. AVFoundation
  // autoreleases temporaries per decoded frame and this program has no
  // run loop to drain them.
  PoolDrainEveryFrames = 128;
  // Slack on the decimation grid, in slots: enough to absorb the last
  // bits of a presentation stamp, nowhere near a real frame interval.
  GridEpsilon = 1E-6;

type
  // Which of the export's passes over the movie is reporting. APNG makes
  // a single pass, so only gesEncode fires for it.
  TGifExportStage = (gesPalette, gesEncode);

  // Per-frame progress, for a caller that has a window to update. Runs on
  // the thread that called Run — the main thread, since AVAssetReader is
  // driven from there — so an AppKit setter is a legal thing to do in
  // one. AFramesTotal is an estimate during the palette pass (done can
  // overshoot it slightly) and the measured count during a GIF encode
  // pass, where done runs one behind until the trailing frame reports.
  // ABytesWritten is what the sink has put on disk so far — zero for the
  // whole palette pass, which writes nothing. It is here so a caller with
  // no console can show the projection (Knips.Export.SizeEstimate) rather
  // than only a percentage: an export whose percentage is crawling and
  // whose size is heading for 40 MB is one somebody wants to stop.
  TGifExportProgressEvent = procedure(AStage: TGifExportStage;
    AFramesDone, AFramesTotal, ABytesWritten: Int64) of object;

  TExportReport = record
    Format: TExportFormat;
    InputPath: string;
    OutputPath: string;
    SourceWidth: Integer;
    SourceHeight: Integer;
    PixelWidth: Integer;
    PixelHeight: Integer;
    FramesRead: Int64;
    FramesWritten: Int64;
    SampledFrames: Integer;
    // Zero for APNG, which quantises nothing.
    PaletteColors: Integer;
    // False when the colour histogram overflowed into its 6-bit
    // fallback, which costs palette accuracy and is worth saying.
    ExactPalette: Boolean;
    // Playback length: the sum of the frame delays.
    DurationSeconds: Double;
    OutputBytes: Int64;
    // The cursor effect (Knips.Export.CursorEffect): whether a pointer
    // was drawn into the frames from the event sidecar, and how many
    // frames got one. SmoothCursorNote says why it did not happen when
    // something asked for it and it could not — never a reason to fail an
    // export, and never silent either.
    SmoothCursor: Boolean;
    SmoothCursorFrames: Int64;
    SmoothCursorNote: string;
    // Post-hoc Zoom on Click (Knips.Export.ZoomTrack), applied to the
    // decoded frames before they are scaled — the same effect, from the
    // same click track, the MP4 render applies, so a GIF and the movie
    // beside it move together.
    ZoomOnClick: Boolean;
    ZoomedFrames: Int64;
    ZoomClicks: Integer;
    ZoomNote: string;
    // Frames the zoom could not be applied to because the sample track
    // had nothing to say about what they were showing. See the MP4
    // render's field of the same name.
    UnframedFrames: Int64;
    // Frames the capture never made, put back on the decimation grid
    // where an effect was animating and ScreenCaptureKit had delivered
    // nothing (Knips.Export.Cadence). Zero on a take whose frames
    // already arrived at the target rate.
    SynthesizedFrames: Int64;
    // What the size was expected to be before a byte was written, and how
    // many output frames that was over. Kept in the report so the caller
    // can say afterwards how close it came — which is the only way the
    // constants behind it ever get better.
    EstimatedBytes: Int64;
    EstimatedLowBytes: Int64;
    EstimatedHighBytes: Int64;
    EstimatedFrames: Int64;
  end;

  // What a pass of scaled frames is written into. The GIF and APNG
  // encoders have the same shape but no common ancestor — one is a
  // palette encoder and the other is not — so the pipeline gets one
  // here rather than two copies of the frame loop.
  TExportSink = class
  public
    function Open(const APath: string; out AError: string): Boolean;
      virtual; abstract;
    function AddFrame(const APixels: PByte; ABytesPerRow,
      ADelayTicks: Integer; out AError: string): Boolean; virtual; abstract;
    function Finish(out AError: string): Boolean; virtual; abstract;
    function FrameCount: Int64; virtual; abstract;
    function BytesWritten: Int64; virtual; abstract;
    function TicksPerSecond: Integer; virtual; abstract;
    function MinimumDelayTicks: Integer; virtual; abstract;
  end;

  TGifSink = class(TExportSink)
  private
    FEncoder: TGifEncoder;
  public
    constructor Create(AWidth, AHeight: Integer; const APalette: TGifPalette;
      ADither: Boolean);
    destructor Destroy; override;
    function Open(const APath: string; out AError: string): Boolean; override;
    function AddFrame(const APixels: PByte; ABytesPerRow,
      ADelayTicks: Integer; out AError: string): Boolean; override;
    function Finish(out AError: string): Boolean; override;
    function FrameCount: Int64; override;
    function BytesWritten: Int64; override;
    function TicksPerSecond: Integer; override;
    function MinimumDelayTicks: Integer; override;
  end;

  TApngSink = class(TExportSink)
  private
    FEncoder: TApngEncoder;
  public
    constructor Create(AWidth, AHeight: Integer);
    destructor Destroy; override;
    function Open(const APath: string; out AError: string): Boolean; override;
    function AddFrame(const APixels: PByte; ABytesPerRow,
      ADelayTicks: Integer; out AError: string): Boolean; override;
    function Finish(out AError: string): Boolean; override;
    function FrameCount: Int64; override;
    function BytesWritten: Int64; override;
    function TicksPerSecond: Integer; override;
    function MinimumDelayTicks: Integer; override;
  end;

  TExportSession = class
  private
    FOptions: TExportOptions;
    FReport: TExportReport;
    FReader: TMovieReader;
    FScaled: TBgraImage;
    FPending: TBgraImage;
    FScratch: TResampleScratch;
    // Nil unless the movie's sidecar says its pointer is waiting to be
    // drawn. Prepared once, when the output size is settled, and consulted
    // in ScaleFrame — which is on BOTH passes on purpose: a GIF's palette
    // is chosen from scaled frames, and a palette that had never seen the
    // pointer would quantise it into whatever was nearest.
    FCursorEffect: TExportCursor;
    // The post-hoc zoom's own state. The log is loaded a second time
    // rather than borrowed from FCursorEffect: the cursor effect is
    // absent whenever no pointer was asked for, and a zoom does not
    // depend on a pointer.
    FZoomLog: TSidecarLog;
    FZoomClicks: TZoomClickArray;
    FZoomWalker: TZoomWalker;
    FZoomBase: TLiveRect;
    // Whether the capture moved its own source rectangle during the
    // take, which decides whether the framing is per frame or fixed.
    FFramingPanned: Boolean;
    // The source movie's bytes per pixel-frame — H.264's own verdict on
    // how busy the content is, and the only content signal the size
    // estimate has that costs nothing to get
    // (Knips.Export.SizeEstimate). Zero when the file could not be
    // measured, which makes the estimate fall back to a flat prior and
    // say so.
    FSourceDensity: Double;
    FStartSeconds: Double;
    FRangeSeconds: Double;
    // The decimation grid, in whole slots of 1/fps counted from the
    // first emitted frame. Accumulating a floating-point deadline
    // instead loses frames when the source rate equals the target one:
    // a stamp that should land exactly on the grid lands a few parts in
    // 10^16 below it and the frame is skipped.
    FBaseSeconds: Double;
    FLastSlot: Int64;
    FEmitted: Int64;
    // The frame synthesis. FHeld is the last emitted frame's pixels,
    // retained past the reader's own lifetime for it; FPendingSource is
    // the next frame that passed the grid, read but not yet handed out,
    // because the slots between the two have to be filled first.
    FHeld: CVPixelBufferRef;
    FPendingSource: TMovieReaderFrame;
    FHasPendingSource: Boolean;
    FPendingSlot: Int64;
    FFillSlot: Int64;
    // One past the last slot this gap may be filled to. The bound is
    // Knips.Export.Cadence's own (MaxCadenceStepsPerGap), applied here
    // because this pass walks the decimation grid it already counts in
    // rather than calling CadenceTimes — the two must not be allowed to
    // disagree about how much one gap may cost.
    FFillLimit: Int64;
    FLastShape: TRenderedFrameShape;
    FHasLastShape: Boolean;
    // What the palette pass counted. Zero until it has run, and it never
    // runs for APNG.
    FMeasuredFrames: Int64;
    FVerbose: Boolean;
    FOnProgress: TGifExportProgressEvent;
    procedure Progress(AStage: TGifExportStage; AFramesDone,
      ABytesWritten: Int64);
    procedure BeginPass;
    function NextEmittedFrame(out AFrame: TMovieReaderFrame): Boolean;
    // What one output frame would come out as at ASeconds, given that
    // the pixels behind it do not change. See Knips.Export.Cadence.
    function EmittedFrameShape(ASourceWidth, ASourceHeight: Integer;
      ASeconds: Double): TRenderedFrameShape;
    procedure HoldFrame(const AFrame: TMovieReaderFrame);
    procedure ReleaseHeldFrame;
    // What the whole frame shows at ASeconds: the base rectangle for a
    // take whose framing never moved, the sample track's own for one
    // that panned. False when the track has nothing to say about that
    // instant, which is the one case a zoom must not crop through — see
    // Knips.Export.ZoomTrack.FramingRectAt.
    function FramingAt(ASeconds: Double; out ARect: TLiveRect): Boolean;
    procedure EnsureTargetSize(ASourceWidth, ASourceHeight: Integer);
    procedure PrepareSmoothCursor;
    procedure PrepareZoom;
    procedure NoteUnframedFrames;
    function ScaleFrame(const AFrame: TMovieReaderFrame;
      var ADestination: TBgraImage; out AError: string): Boolean;
    function RangeSeconds: Double;
    function ExpectedFrameCount: Integer;
    // Fills the report's estimate from the settings and the source
    // movie's density, and returns the line to print. '' when there is
    // nothing to estimate.
    function BuildEstimate: string;
    procedure MeasureSourceDensity;
    function ResolveRange(out AError: string): Boolean;
    function CollectPalette(out APalette: TGifPalette;
      out AError: string): Boolean;
    function WriteFrames(ASink: TExportSink; out AError: string): Boolean;
  public
    constructor Create(const AOptions: TExportOptions);
    destructor Destroy; override;
    // False with a one-line message on any failure; the partial output
    // file is removed.
    function Run(out AError: string): Boolean;
    property Report: TExportReport read FReport;
    // Progress on standard output, as the CLI wants it. The menu-bar app
    // has no console — under an app bundle standard output is not even a
    // terminal — so it turns this off and takes OnProgress instead.
    property Verbose: Boolean read FVerbose write FVerbose;
    property OnProgress: TGifExportProgressEvent read FOnProgress
      write FOnProgress;
  end;

{$ENDIF}

implementation

{$IFDEF DARWIN}

{ TGifSink }

constructor TGifSink.Create(AWidth, AHeight: Integer;
  const APalette: TGifPalette; ADither: Boolean);
begin
  inherited Create;
  FEncoder := TGifEncoder.Create(AWidth, AHeight, APalette, ADither);
end;

destructor TGifSink.Destroy;
begin
  FEncoder.Free;
  inherited Destroy;
end;

function TGifSink.Open(const APath: string; out AError: string): Boolean;
begin
  Result := FEncoder.Open(APath, AError);
end;

function TGifSink.AddFrame(const APixels: PByte; ABytesPerRow,
  ADelayTicks: Integer; out AError: string): Boolean;
begin
  Result := FEncoder.AddFrame(APixels, ABytesPerRow, ADelayTicks, AError);
end;

function TGifSink.Finish(out AError: string): Boolean;
begin
  Result := FEncoder.Finish(AError);
end;

function TGifSink.FrameCount: Int64;
begin
  Result := FEncoder.FrameCount;
end;

function TGifSink.BytesWritten: Int64;
begin
  Result := FEncoder.BytesWritten;
end;

function TGifSink.TicksPerSecond: Integer;
begin
  Result := GifDelayTicksPerSecond;
end;

function TGifSink.MinimumDelayTicks: Integer;
begin
  Result := GifMinimumDelayTicks;
end;

{ TApngSink }

constructor TApngSink.Create(AWidth, AHeight: Integer);
begin
  inherited Create;
  FEncoder := TApngEncoder.Create(AWidth, AHeight, ApngDelayTicksPerSecond);
end;

destructor TApngSink.Destroy;
begin
  FEncoder.Free;
  inherited Destroy;
end;

function TApngSink.Open(const APath: string; out AError: string): Boolean;
begin
  Result := FEncoder.Open(APath, AError);
end;

function TApngSink.AddFrame(const APixels: PByte; ABytesPerRow,
  ADelayTicks: Integer; out AError: string): Boolean;
begin
  Result := FEncoder.AddFrame(APixels, ABytesPerRow, ADelayTicks, AError);
end;

function TApngSink.Finish(out AError: string): Boolean;
begin
  Result := FEncoder.Finish(AError);
end;

function TApngSink.FrameCount: Int64;
begin
  Result := FEncoder.FrameCount;
end;

function TApngSink.BytesWritten: Int64;
begin
  Result := FEncoder.BytesWritten;
end;

function TApngSink.TicksPerSecond: Integer;
begin
  Result := ApngDelayTicksPerSecond;
end;

function TApngSink.MinimumDelayTicks: Integer;
begin
  Result := ApngMinimumDelayTicks;
end;

{ TExportSession }

constructor TExportSession.Create(const AOptions: TExportOptions);
begin
  inherited Create;
  FOptions := AOptions;
  FVerbose := True;
end;

procedure TExportSession.Progress(AStage: TGifExportStage; AFramesDone,
  ABytesWritten: Int64);
begin
  if Assigned(FOnProgress) then
    FOnProgress(AStage, AFramesDone, ExpectedFrameCount, ABytesWritten);
end;

destructor TExportSession.Destroy;
begin
  ReleaseHeldFrame;
  FreeAndNil(FReader);
  FreeAndNil(FCursorEffect);
  FreeAndNil(FZoomLog);
  inherited Destroy;
end;

function TExportSession.FramingAt(ASeconds: Double;
  out ARect: TLiveRect): Boolean;
var
  Stale: Boolean;
begin
  ARect := FZoomBase;
  if not FFramingPanned then
    Exit(True);
  ARect := FramingRectAt(FZoomLog, ASeconds, Stale);
  if (ARect.Width <= 0) or (ARect.Height <= 0) then
  begin
    ARect := FZoomBase;
    Exit(False);
  end;
  Result := not Stale;
end;

procedure TExportSession.ReleaseHeldFrame;
begin
  if FHeld <> nil then
  begin
    CVPixelBufferRelease(FHeld);
    FHeld := nil;
  end;
end;

// The reader's buffer is only valid until the next NextFrame, and a
// synthesised frame is made from the frame *before* the one that has
// just been read — so it is retained rather than borrowed.
procedure TExportSession.HoldFrame(const AFrame: TMovieReaderFrame);
begin
  ReleaseHeldFrame;
  FHeld := CVPixelBufferRetain(AFrame.PixelBuffer);
end;

function TExportSession.EmittedFrameShape(ASourceWidth,
  ASourceHeight: Integer; ASeconds: Double): TRenderedFrameShape;
var
  Crop: TZoomCrop;
  Source, Framing: TLiveRect;
  FramingKnown: Boolean;
begin
  Result := Default(TRenderedFrameShape);
  Crop := Default(TZoomCrop);
  Crop.Width := ASourceWidth;
  Crop.Height := ASourceHeight;
  Crop.Identity := True;
  FramingKnown := FramingAt(ASeconds, Framing);
  Source := Framing;
  if FReport.ZoomOnClick and FramingKnown then
  begin
    // The walk is monotonic and ScaleFrame advances it too; advancing to
    // a time it has already reached is a no-op, which is what makes
    // asking here safe.
    FZoomWalker := ZoomWalkerAdvance(FZoomWalker, FZoomClicks, ASeconds);
    Source := ZoomWalkerSourceRectIn(FZoomWalker, Framing);
    Crop := ZoomFrameCrop(ASourceWidth, ASourceHeight, Framing, Source);
  end;
  Result.CropX := Crop.X;
  Result.CropY := Crop.Y;
  Result.CropWidth := Crop.Width;
  Result.CropHeight := Crop.Height;
  if FCursorEffect <> nil then
    Result.HasCursor := FCursorEffect.SpritePlacement(FReport.PixelWidth,
      FReport.PixelHeight, ASeconds, FReport.ZoomOnClick, Source.X,
      Source.Y, Source.Width, Source.Height, Result.CursorX,
      Result.CursorY);
end;

procedure TExportSession.BeginPass;
begin
  FEmitted := 0;
  FBaseSeconds := 0;
  FLastSlot := 0;
  ReleaseHeldFrame;
  FHasPendingSource := False;
  FPendingSlot := 0;
  FFillSlot := 0;
  FFillLimit := 0;
  FHasLastShape := False;
  FReport.SynthesizedFrames := 0;
  // A GIF walks the movie twice and the walker only goes forwards, so
  // the second pass starts the zoom over. Without this the encode pass
  // would find the walk already at the end of the movie and every frame
  // would come out unzoomed — while the palette pass had seen the zoom.
  if FReport.ZoomOnClick then
    FZoomWalker := ZoomWalkerStart(FZoomBase, FOptions.Effects.ZoomFactor,
      FOptions.Effects.ZoomHoldSeconds);
end;

// The next frame the export should write, which is not always a frame
// the movie holds.
//
// Two things happen here. The first is the decimation that has always
// been here: a source stamp lands in a slot of the 1/fps grid and the
// first frame to reach each slot is the one that is kept.
//
// The second is the **fill**. ScreenCaptureKit delivers a frame only
// when the content changes, and a raw take has no pointer in its pixels
// — so a drawn pointer gliding over a still window, or a zoom easing
// over one, has nothing to be drawn into. The delay planner then does
// exactly what it should and holds one frame for the whole gap, which
// in a GIF is the same stutter this effect exists to remove. So an empty
// slot between two source frames is filled by re-presenting the earlier
// one with the effect evaluated at that slot's time — but only when it
// would come out a **different picture** (Knips.Export.Cadence), so a
// still stretch with nothing animating over it stays exactly as sparse
// as it was captured and costs the file nothing.
function TExportSession.NextEmittedFrame(
  out AFrame: TMovieReaderFrame): Boolean;
var
  Frame: TMovieReaderFrame;
  Shape: TRenderedFrameShape;
  Slot: Int64;
  FillSeconds: Double;
begin
  Result := False;
  AFrame := Default(TMovieReaderFrame);
  repeat
    if FHasPendingSource then
    begin
      // The slots between the last emitted frame and the one waiting,
      // up to the shared per-gap bound.
      if (FHeld <> nil) and (FFillSlot < FFillLimit)
        and (FReport.PixelWidth > 0) then
      begin
        FillSeconds := FBaseSeconds
          + FFillSlot / FOptions.FramesPerSecond;
        Inc(FFillSlot);
        Shape := EmittedFrameShape(Integer(CVPixelBufferGetWidth(FHeld)),
          Integer(CVPixelBufferGetHeight(FHeld)), FillSeconds);
        if FHasLastShape and not FrameShapesDiffer(Shape, FLastShape) then
          Continue;
        FLastShape := Shape;
        FHasLastShape := True;
        AFrame.PixelBuffer := FHeld;
        AFrame.Seconds := FillSeconds;
        AFrame.Time := CMTimeMakeWithSeconds(FillSeconds, TrimTimeScale);
        Inc(FEmitted);
        Inc(FReport.SynthesizedFrames);
        Exit(True);
      end;
      // Nothing left to fill: the frame that was waiting is next.
      FHasPendingSource := False;
      FLastSlot := FPendingSlot;
      Inc(FEmitted);
      AFrame := FPendingSource;
      HoldFrame(AFrame);
      if FReport.PixelWidth > 0 then
      begin
        FLastShape := EmittedFrameShape(
          Integer(CVPixelBufferGetWidth(AFrame.PixelBuffer)),
          Integer(CVPixelBufferGetHeight(AFrame.PixelBuffer)),
          AFrame.Seconds);
        FHasLastShape := True;
      end;
      Exit(True);
    end;

    if not FReader.NextFrame(Frame) then
      Exit(False);
    Inc(FReport.FramesRead);
    if FEmitted = 0 then
    begin
      FBaseSeconds := Frame.Seconds;
      FLastSlot := 0;
      Slot := 0;
    end
    else
    begin
      // Which slot of the grid this stamp falls in. GridEpsilon is far
      // larger than the rounding of a presentation stamp and far
      // smaller than any real gap, so a frame sitting on a slot
      // boundary always counts as having reached it. Advancing by slot
      // number also means a source slower than the target rate never
      // builds up a backlog of frames that are "due".
      // Qualified: MacOSAll carries a Floor of its own that returns a
      // float, and it wins the uses clause.
      Slot := Math.Floor((Frame.Seconds - FBaseSeconds)
        * FOptions.FramesPerSecond + GridEpsilon);
      if Slot <= FLastSlot then
        Continue;
    end;
    FPendingSource := Frame;
    FPendingSlot := Slot;
    FHasPendingSource := True;
    FFillSlot := FLastSlot + 1;
    // The shared bound, so a damaged movie with an hour between two
    // stamps cannot ask this export for a hundred thousand frames — and
    // so this path and the MP4 render's cannot disagree about what one
    // gap may cost.
    FFillLimit := CadenceFillLimit(FFillSlot, FPendingSlot);
  until False;
end;

procedure TExportSession.EnsureTargetSize(ASourceWidth,
  ASourceHeight: Integer);
var
  TargetWidth: Integer;
begin
  if FReport.PixelWidth > 0 then
    Exit;
  FReport.SourceWidth := ASourceWidth;
  FReport.SourceHeight := ASourceHeight;
  TargetWidth := FOptions.Width;
  // Upscaling a recording into an animation only costs bytes, so a width
  // above the source is treated as "as large as the source".
  if (TargetWidth = GifWidthFromSource) or (TargetWidth > ASourceWidth) then
    TargetWidth := ASourceWidth;
  FReport.PixelWidth := TargetWidth;
  FReport.PixelHeight := ScaledHeightForWidth(ASourceWidth, ASourceHeight,
    TargetWidth);
  BgraImageResize(FScaled, FReport.PixelWidth, FReport.PixelHeight);
  BgraImageResize(FPending, FReport.PixelWidth, FReport.PixelHeight);
  PrepareSmoothCursor;
  PrepareZoom;
end;

// The post-hoc zoom, when it was asked for and the take can take it.
// Every refusal is a note rather than a failure, exactly as the cursor's
// are: an export whose zoom could not be applied is still the right
// animation, and it is the crop that is missing.
procedure TExportSession.PrepareZoom;
var
  Available: TSidecarEffectAvailability;
  Error: string;
begin
  if not FOptions.Effects.ZoomOnClick or (FZoomLog <> nil) then
    Exit;
  FZoomLog := TSidecarLog.Create;
  if not FZoomLog.LoadFromFile(SidecarPathFor(FOptions.InputPath), Error) then
  begin
    FReport.ZoomNote := 'there is no event sidecar for this recording';
    FreeAndNil(FZoomLog);
    Exit;
  end;
  Available := AvailableExportEffects(FZoomLog);
  if not Available.CanZoomOnClick then
  begin
    // The zoom's own reason; see the same line in Knips.Export.Render.
    FReport.ZoomNote := Available.ZoomReason;
    FreeAndNil(FZoomLog);
    Exit;
  end;
  FZoomClicks := ZoomClicksFromLog(FZoomLog);
  FReport.ZoomClicks := Length(FZoomClicks);
  if FReport.ZoomClicks = 0 then
  begin
    FReport.ZoomNote := 'nothing was clicked inside the recorded '
      + 'rectangle, so there was nothing to zoom to';
    FreeAndNil(FZoomLog);
    Exit;
  end;
  FZoomBase := LiveRect(FZoomLog.Header.BaseX, FZoomLog.Header.BaseY,
    FZoomLog.Header.BaseWidth, FZoomLog.Header.BaseHeight);
  FFramingPanned := not HasUntouchedFraming(FZoomLog.Header);
  FReport.ZoomOnClick := True;
  FZoomWalker := ZoomWalkerStart(FZoomBase, FOptions.Effects.ZoomFactor,
    FOptions.Effects.ZoomHoldSeconds);
end;

// The synthetic pointer, if the movie is one that was recorded waiting for
// it. Every refusal below is the ordinary case, not a failure: almost no
// movie has a sidecar asking for this, and an export of one that does not
// simply has no pointer drawn. Only a sidecar that *did* ask and could not
// be honoured leaves a note, and even that never fails the export — the
// animation is correct, it is the pointer that is missing.
procedure TExportSession.PrepareSmoothCursor;
var
  Note: string;
begin
  if FCursorEffect <> nil then
    Exit;
  FCursorEffect := TExportCursor.Create;
  if FCursorEffect.Prepare(FOptions.InputPath, FOptions.Effects,
    FReport.PixelWidth, FReport.PixelHeight, Note) then
  begin
    FReport.SmoothCursor := True;
    Exit;
  end;
  // Told apart by whether the sidecar asked. A movie with no sidecar, or
  // one whose header says the pointer is already in the pixels, is not
  // something to report.
  if FCursorEffect.Asked then
    FReport.SmoothCursorNote := Note;
  FreeAndNil(FCursorEffect);
end;

// The note a run leaves behind about frames it could not place. Kept
// beside the zoom's own note rather than replacing it: "the zoom was
// refused" and "the zoom applied to all but the last thirty frames" are
// different facts and a caller with one line to show wants the first.
procedure TExportSession.NoteUnframedFrames;
begin
  if (FReport.UnframedFrames > 0) and (FReport.ZoomNote = '') then
    FReport.ZoomNote := Format('%d frame(s) run past the end of this '
      + 'recording''s pointer track, so what they were showing is not '
      + 'recorded; nothing was cropped for them and the pointer was '
      + 'placed from the last position the track holds',
      [FReport.UnframedFrames]);
end;

// A frame that cannot be read has to fail the export. Leaving the
// destination untouched would hand the encoder the previous frame
// again, or the quantiser the same frame twice, and still report
// success — a wrong animation is worse than none.
function TExportSession.ScaleFrame(const AFrame: TMovieReaderFrame;
  var ADestination: TBgraImage; out AError: string): Boolean;
var
  Base: Pointer;
  Stride, SourceWidth, SourceHeight: Integer;
  Status: CVReturn;
  Crop: TZoomCrop;
  Source, Framing: TLiveRect;
  HasCrop, FramingKnown: Boolean;
begin
  Result := False;
  AError := '';
  Status := CVPixelBufferLockBaseAddress(AFrame.PixelBuffer,
    kCVPixelBufferLock_ReadOnly);
  if Status <> kCVReturn_Success then
  begin
    AError := Format('could not read a decoded frame at %.2fs '
      + '(CVPixelBufferLockBaseAddress returned %d)',
      [AFrame.Seconds, Status]);
    Exit;
  end;
  try
    Base := CVPixelBufferGetBaseAddress(AFrame.PixelBuffer);
    Stride := Integer(CVPixelBufferGetBytesPerRow(AFrame.PixelBuffer));
    SourceWidth := Integer(CVPixelBufferGetWidth(AFrame.PixelBuffer));
    SourceHeight := Integer(CVPixelBufferGetHeight(AFrame.PixelBuffer));
    if Base = nil then
    begin
      AError := Format('a decoded frame at %.2fs has no pixels',
        [AFrame.Seconds]);
      Exit;
    end;
    HasCrop := False;
    Source := Default(TLiveRect);
    Crop := Default(TZoomCrop);
    // Inside what the frame SHOWS at this instant, which on a take whose
    // framing panned is not the base rectangle — the same composition
    // the MP4 render does, from the same track, so a GIF and the movie
    // beside it crop the same pixels. A frame the track cannot place is
    // passed through whole rather than cropped against a guess.
    FramingKnown := FramingAt(AFrame.Seconds, Framing);
    if FReport.ZoomOnClick and FramingKnown then
    begin
      FZoomWalker := ZoomWalkerAdvance(FZoomWalker, FZoomClicks,
        AFrame.Seconds);
      Source := ZoomWalkerSourceRectIn(FZoomWalker, Framing);
      Crop := ZoomFrameCrop(SourceWidth, SourceHeight, Framing, Source);
      HasCrop := True;
      if not Crop.Identity then
        Inc(FReport.ZoomedFrames);
    end;
    // Counted whether or not a zoom was asked for: a frame the track
    // cannot place is one whose pointer falls back to the last rectangle
    // the track holds (HasCrop stays False below, which is exactly that
    // fallback), and that is worth saying even with no crop in play.
    //
    // One asymmetry with the MP4 render, stated rather than hidden: this
    // pass only loads a sidecar for the ZOOM, so a cursor-only export of
    // a take whose movie outlasts its track gets the right pixels — the
    // fallback above is unconditional — but no note. The pixels are what
    // matter and they are correct; closing the note would mean loading
    // the log for the cursor path too, which the cursor effect already
    // does privately.
    if not FramingKnown then
      Inc(FReport.UnframedFrames);
    // The crop is applied by handing the resampler a smaller rectangle of
    // the same buffer: the stride is the frame's, the origin is the
    // crop's. One resample does the crop and the scale together, so a
    // zoomed export costs no more per frame than an unzoomed one.
    if HasCrop then
      BgraResample(PByte(Base) + PtrInt(Crop.Y) * Stride
        + PtrInt(Crop.X) * BgraBytesPerPixel, Stride, Crop.Width,
        Crop.Height, ADestination, FScratch)
    else
      BgraResample(PByte(Base), Stride, SourceWidth, SourceHeight,
        ADestination, FScratch);
    // After the resample, into the scaled frame: the sprite was rendered
    // at the OUTPUT's scale, so drawing it before would shrink it with
    // the picture and soften its edges twice over. With a crop in force
    // the frame no longer shows what the capture was reading, so the
    // pointer is placed against the crop instead.
    if FCursorEffect <> nil then
    begin
      if HasCrop then
        FCursorEffect.DrawIntoCropped(ADestination, AFrame.Seconds, Source.X,
          Source.Y, Source.Width, Source.Height)
      else
        FCursorEffect.DrawInto(ADestination, AFrame.Seconds);
    end;
    Result := True;
  finally
    CVPixelBufferUnlockBaseAddress(AFrame.PixelBuffer,
      kCVPixelBufferLock_ReadOnly);
  end;
end;

// How much of the movie the export covers: the trim if there is one,
// else what is left after the start. Zero when the reader could not say
// how long the movie is, which some containers cannot.
function TExportSession.RangeSeconds: Double;
begin
  Result := FRangeSeconds;
  if Result <= 0 then
    Result := FReader.DurationSeconds - FStartSeconds;
  if Result < 0 then
    Result := 0;
end;

// The number of frames the export will emit. Two callers want it — the
// progress a caller draws, and the stride the palette pass takes its
// sample frames on (see CollectPalette) — and it answers with two
// different kinds of number, so what each is worth is worth saying.
//
// After the palette pass it is a *count*. That pass walks the whole
// movie through the same decimator the encode pass will use, so the
// frames it emitted are the frames the encode pass will emit. Left as an
// estimate, the encode pass's total gave a bar that crawled at a third
// of its true rate and then stopped at 54%.
//
// Before that pass there is nothing to count, so it is a *bound*: the
// tightest honest upper bound available, which is what makes it a good
// seed for the palette pass's stride and an honest ceiling for a
// progress bar. It is no longer load-bearing for correctness. The
// palette schedule (TGifPaletteSampler) caps the stride it seeds from
// this and doubles it as the walk goes on, so an estimate that runs high
// cannot collapse the sample to one frame and an estimate that runs low
// cannot leave the tail of the movie out — the quantiser's counters are
// 64-bit and it has no sampling budget to run out of. Two bounds are
// available and the answer is the smaller.
//
// The range times the requested rate is the number of grid slots, and
// the decimator emits at most one frame a slot. On its own it is far too
// generous, because ScreenCaptureKit emits a frame when the screen
// changes: a recording that idles holds nothing like its length times
// the rate it was asked for. On a 220 s capture asked for at 20 fps this
// bound says 4412 frames against 1723 real ones, which put the palette's
// stride at 138 and built it from 13 frames rather than 32.
//
// The movie's own frame count is the other, and it bounds any part of
// the movie as surely as the whole. AVAssetTrack's nominalFrameRate is
// the average a variable-rate track really achieved — on the recordings
// measured here it agrees to four figures with the container's frame
// count over its duration — so the duration times that rate is how many
// frames exist at all. On the same capture it says 2428, and the palette
// gets 23 sample frames.
//
// Taking the *duration* rather than the range is what keeps this a bound
// and not a guess. A --trim over a busy stretch of an otherwise idle
// recording holds frames far denser than the movie's average, so the
// range times the average rate would sit below what that stretch really
// emits, and a seed that runs low costs the schedule a phase of thinning
// it did not need.
function TExportSession.ExpectedFrameCount: Integer;
var
  Seconds, Slots, SourceFrames: Double;
begin
  if FMeasuredFrames > 0 then
    Exit(Integer(FMeasuredFrames));
  Seconds := RangeSeconds;
  if Seconds <= 0 then
    Exit(1);
  Slots := Seconds * FOptions.FramesPerSecond;
  if (FReader.NominalFrameRate > 0) and (FReader.DurationSeconds > 0) then
  begin
    SourceFrames := FReader.DurationSeconds * FReader.NominalFrameRate;
    if SourceFrames < Slots then
      Slots := SourceFrames;
  end;
  // Ceil, never Round: this is a bound, and rounding a 32.4 down to 32
  // against 33 emitted frames would make it a guess.
  Result := Math.Ceil(Slots);
  if Result < 1 then
    Result := 1;
end;

// The movie's own size against its own pixels. Everything here is
// metadata plus one stat(2); nothing is decoded for it.
procedure TExportSession.MeasureSourceDensity;
var
  Handle: THandle;
  Bytes: Int64;
  Frames: Double;
begin
  FSourceDensity := 0;
  if (FReader.NominalFrameRate <= 0) or (FReader.DurationSeconds <= 0) then
    Exit;
  Handle := FileOpen(FOptions.InputPath, fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then
    Exit;
  Bytes := FileSeek(Handle, Int64(0), fsFromEnd);
  FileClose(Handle);
  Frames := FReader.DurationSeconds * FReader.NominalFrameRate;
  if Frames < 1 then
    Frames := 1;
  FSourceDensity := SourceBytesPerPixelFrame(Bytes, Round(Frames),
    FReader.PixelWidth, FReader.PixelHeight);
end;

function TExportSession.BuildEstimate: string;
var
  Estimate: TExportSizeEstimate;
begin
  FReport.EstimatedFrames := ExpectedFrameCount;
  Estimate := EstimateExportSize(FOptions.Format, FReport.PixelWidth,
    FReport.PixelHeight, FReport.EstimatedFrames, FOptions.Dither,
    FSourceDensity);
  FReport.EstimatedBytes := Estimate.Bytes;
  FReport.EstimatedLowBytes := Estimate.LowBytes;
  FReport.EstimatedHighBytes := Estimate.HighBytes;
  Result := DescribeEstimate(Estimate);
end;

function TExportSession.ResolveRange(out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  FStartSeconds := FOptions.TrimStartSeconds;
  if FOptions.HasTrimEnd then
    FRangeSeconds := FOptions.TrimEndSeconds - FStartSeconds
  else
    FRangeSeconds := 0;
  if (FReader.DurationSeconds > 0)
    and (FStartSeconds >= FReader.DurationSeconds) then
  begin
    AError := Format('--trim starts at %.2fs but the movie is %.2fs long',
      [FStartSeconds, FReader.DurationSeconds]);
    Exit;
  end;
  Result := True;
end;

// Which frames the palette is built from.
//
// The samples are spread over the frame *index* rather than over the
// clock, and that weighting is deliberate: every frame the encoder
// writes counts the same towards how the result looks, so a busy
// stretch, which produces more frames, has earned more of the palette
// than an idle stretch of the same length. Spreading the samples over
// *time* instead was tried and measured on a 220 s capture: 21 samples
// rather than 13, and 0.45 dB worse (39.40 -> 38.95 against the same
// clip exported as an APNG, which quantises nothing and so is exactly
// the pixels the scaler produced).
//
// Spacing them needs a frame count in advance, which is the one number
// this pass does not have. All that lives here is the plumbing —
// ExpectedFrameCount for the seed, and one "sample or skip?" question
// per emitted frame; the schedule that answers it, and the closed loop
// that keeps a wrong seed from mattering, is TGifPaletteSampler in
// Knips.Export.Gif, where it can be unit-tested off a Mac.
function TExportSession.CollectPalette(out APalette: TGifPalette;
  out AError: string): Boolean;
var
  Quantizer: TGifQuantizer;
  Sampler: TGifPaletteSampler;
  Frame: TMovieReaderFrame;
  Pool: NSAutoreleasePool;
  Index, EstimatedBeforePass: Integer;
begin
  Result := False;
  APalette := Default(TGifPalette);
  if not FReader.StartPass(FStartSeconds, FRangeSeconds, AError) then
    Exit;
  EstimatedBeforePass := ExpectedFrameCount;

  Sampler := nil;
  Quantizer := TGifQuantizer.Create;
  try
    Sampler := TGifPaletteSampler.Create(EstimatedBeforePass);
    Index := 0;
    Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
    try
      while NextEmittedFrame(Frame) do
      begin
        if Sampler.TakeFrame(Index) then
        begin
          EnsureTargetSize(Integer(CVPixelBufferGetWidth(Frame.PixelBuffer)),
            Integer(CVPixelBufferGetHeight(Frame.PixelBuffer)));
          if not ScaleFrame(Frame, FScaled, AError) then
            Exit;
          Quantizer.SampleFrame(@FScaled.Pixels[0], FScaled.BytesPerRow,
            FScaled.Width, FScaled.Height);
        end;
        Inc(Index);
        Progress(gesPalette, Index, 0);
        if Index mod PoolDrainEveryFrames = 0 then
        begin
          Pool.release;
          Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
        end;
      end;
    finally
      Pool.release;
    end;
    FReport.SampledFrames := Integer(Sampler.SampledFrames);
    FReader.StopPass;
    if FReader.LastError <> '' then
    begin
      AError := FReader.LastError;
      Exit;
    end;
    if Quantizer.IsEmpty then
    begin
      AError := 'the selected range holds no frames';
      Exit;
    end;
    FReport.ExactPalette := Quantizer.IsExactHistogram;
    // Observability only: the source-frame bound is an empirical
    // property of this recorder's own output, and a foreign movie whose
    // header under-reports its real average rate makes the seed run low.
    // The schedule absorbs that by doubling its stride as it goes, so
    // the palette still spans the whole movie — it just took more
    // samples than the target to get there. Worth saying, because it
    // means the header lied; not worth failing over.
    if FVerbose and (FEmitted > EstimatedBeforePass)
      and (EstimatedBeforePass > 0) then
    begin
      WriteLn(Format('  note: the movie held more frames than its '
        + 'header promised (%d vs %d); the palette schedule thinned '
        + 'itself to span it (%d sample frames)',
        [FEmitted, EstimatedBeforePass, FReport.SampledFrames]));
      Flush(Output);
    end;
    // Only now, after the pass has finished and its own progress has
    // been reported against the estimate: changing the total mid-pass
    // would walk the bar backwards.
    FMeasuredFrames := FEmitted;
    // One index of the 256 is reserved for "unchanged since the last
    // frame", so the palette is built one colour short of the maximum.
    APalette := Quantizer.BuildPalette(GifMaxOpaqueColors);
  finally
    Sampler.Free;
    Quantizer.Free;
  end;
  FReport.PaletteColors := APalette.Count;
  Result := True;
end;

function TExportSession.WriteFrames(ASink: TExportSink;
  out AError: string): Boolean;
var
  Planner: TFrameDelayPlanner;
  Frame: TMovieReaderFrame;
  Pool: NSAutoreleasePool;
  Swap: TBgraImage;
  BaseSeconds: Double;
  HasPending: Boolean;
begin
  Result := False;
  FReport.FramesRead := 0;
  // The palette pass has already drawn the pointer into every frame it
  // sampled, and cropped every frame it scaled; only this pass's frames
  // end up in the file, so both counters start again here.
  FReport.ZoomedFrames := 0;
  FReport.UnframedFrames := 0;
  if FCursorEffect <> nil then
    FCursorEffect.ResetCounters;
  if not FReader.StartPass(FStartSeconds, FRangeSeconds, AError) then
    Exit;

  Planner := TFrameDelayPlanner.Create(FOptions.FramesPerSecond,
    ASink.TicksPerSecond, ASink.MinimumDelayTicks);
  try
    if not ASink.Open(FOptions.OutputPath, AError) then
      Exit;
    HasPending := False;
    BaseSeconds := 0;
    Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
    try
      while NextEmittedFrame(Frame) do
      begin
        EnsureTargetSize(Integer(CVPixelBufferGetWidth(Frame.PixelBuffer)),
          Integer(CVPixelBufferGetHeight(Frame.PixelBuffer)));
        if not ScaleFrame(Frame, FScaled, AError) then
          Exit;
        if HasPending then
        begin
          // Whole ticks cannot express 30 fps at all, and the stamps of
          // a 30 fps source straddle every 20 fps slot; the planner is
          // what turns both into a smooth, drift-free run of delays
          // (Knips.Export.Timing).
          if not ASink.AddFrame(@FPending.Pixels[0], FPending.BytesPerRow,
            Planner.NextDelay(Frame.Seconds - BaseSeconds), AError) then
            Exit;
        end
        else
          BaseSeconds := Frame.Seconds;
        Swap := FPending;
        FPending := FScaled;
        FScaled := Swap;
        HasPending := True;
        Progress(gesEncode, ASink.FrameCount, ASink.BytesWritten);
        if FVerbose and (ASink.FrameCount > 0)
          and (ASink.FrameCount mod ProgressEveryFrames = 0) then
        begin
          // Bytes so far and where that is heading. The projection is
          // measured, not modelled: it is this encoder on this content,
          // so it replaces the estimate rather than repeating it.
          WriteLn(Format('  %d of ~%d frames, %s written, heading for %s',
            [ASink.FrameCount, FReport.EstimatedFrames,
            FormatByteSize(ASink.BytesWritten),
            FormatByteSize(ProjectExportSize(ASink.BytesWritten,
            ASink.FrameCount, FReport.EstimatedFrames))]));
          Flush(Output);
        end;
        if FEmitted mod PoolDrainEveryFrames = 0 then
        begin
          Pool.release;
          Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
        end;
      end;
    finally
      Pool.release;
    end;
    FReader.StopPass;
    if FReader.LastError <> '' then
    begin
      AError := FReader.LastError;
      Exit;
    end;
    if not HasPending then
    begin
      AError := 'the selected range holds no frames';
      Exit;
    end;
    // The last frame has no successor to measure against, so it is shown
    // for one interval of the requested rate.
    if not ASink.AddFrame(@FPending.Pixels[0], FPending.BytesPerRow,
      Planner.TrailingDelay, AError) then
      Exit;
    // The loop reported N-1 of N (the pending-frame hold lags the sink
    // by one); with the total now an exact count rather than a loose
    // estimate, this is the difference between a bar that finishes and
    // one that parks at 95% on a short export.
    Progress(gesEncode, ASink.FrameCount, ASink.BytesWritten);
    if not ASink.Finish(AError) then
      Exit;
    FReport.FramesWritten := ASink.FrameCount;
    FReport.OutputBytes := ASink.BytesWritten;
    FReport.DurationSeconds := Planner.SpentTicks / Planner.TicksPerSecond;
    NoteUnframedFrames;
    Result := True;
  finally
    Planner.Free;
  end;
end;

function TExportSession.Run(out AError: string): Boolean;
var
  Palette: TGifPalette;
  Sink: TExportSink;
  Written: Boolean;
  Preview: string;
begin
  Result := False;
  // A fresh run measures afresh; a stale count would make
  // ExpectedFrameCount lie before any pass has run.
  FMeasuredFrames := 0;
  AError := '';
  FReport := Default(TExportReport);
  FReport.Format := FOptions.Format;
  FReport.InputPath := FOptions.InputPath;
  FReport.OutputPath := FOptions.OutputPath;
  FReport.ExactPalette := True;

  FReader := TMovieReader.Create(FOptions.InputPath);
  if not FReader.Open(AError) then
    Exit;
  if not ResolveRange(AError) then
    Exit;
  MeasureSourceDensity;

  Palette := Default(TGifPalette);
  if FOptions.Format = efGif then
  begin
    BeginPass;
    if not CollectPalette(Palette, AError) then
      Exit;
  end
  else
    // APNG quantises nothing, so there is nothing to learn from a first
    // pass; the size comes from the track the reader already opened.
    EnsureTargetSize(FReader.PixelWidth, FReader.PixelHeight);

  if FVerbose then
  begin
    if FOptions.Format = efGif then
      // The sample count is worth printing now that it is decided while
      // the movie is walked rather than fixed in advance: it is the one
      // number that says how widely the palette actually looked.
      WriteLn(Format('exporting %dx%d at up to %d fps '
        + '(%d colours from %d sample frames) to %s',
        [FReport.PixelWidth, FReport.PixelHeight, FOptions.FramesPerSecond,
        FReport.PaletteColors, FReport.SampledFrames, FOptions.OutputPath]))
    else
      WriteLn(Format('exporting %dx%d at up to %d fps (truecolour) to %s',
        [FReport.PixelWidth, FReport.PixelHeight, FOptions.FramesPerSecond,
        FOptions.OutputPath]));
    Flush(Output);
  end;

  // Before a byte is written, so somebody watching a large export start
  // can stop it and pass --width or --fps instead of finding out three
  // minutes later. Computed whether or not anything is printed: the
  // menu-bar app has no console and takes the same numbers out of the
  // report to put in the playback window.
  Preview := BuildEstimate;
  if FVerbose and (Preview <> '') then
  begin
    WriteLn('  estimated size: ', Preview);
    Flush(Output);
  end;

  if FOptions.Format = efGif then
    Sink := TGifSink.Create(FReport.PixelWidth, FReport.PixelHeight, Palette,
      FOptions.Dither)
  else
    Sink := TApngSink.Create(FReport.PixelWidth, FReport.PixelHeight);
  Written := False;
  try
    BeginPass;
    Written := WriteFrames(Sink, AError);
  finally
    // The sink owns the output stream, so it has to go before the file
    // is removed: deleting a path a stream still holds open leaves the
    // partial file alive until the process exits on some volumes, and
    // the close would then write into a deleted inode.
    Sink.Free;
  end;
  if not Written then
  begin
    DeleteFile(FOptions.OutputPath);
    Exit;
  end;
  // Counted rather than assumed, for the same reason Big Cursor's frames
  // are: a pointer that was asked for and silently drawn into nothing
  // looks exactly like one that was never asked for.
  if FCursorEffect <> nil then
    FReport.SmoothCursorFrames := FCursorEffect.DrawnFrames;
  Result := True;
end;

{$ENDIF}

end.

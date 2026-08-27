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
// AVAssetReader cannot rewind: the first pass samples up to
// PaletteSampleFrames frames spread across the range and feeds their
// colours to the quantiser, the second encodes. APNG has nothing to
// learn first, so it makes one pass.
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
  Knips.Export.Gif,
  Knips.Export.MovieReader,
  Knips.Export.Timing,
  Knips.Options,
  MacOSAll;

const
  // Enough spread to catch a palette change halfway through a clip
  // without making the first pass expensive.
  PaletteSampleFrames = 32;
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
  TGifExportProgressEvent = procedure(AStage: TGifExportStage;
    AFramesDone, AFramesTotal: Int64) of object;

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
    // What the palette pass counted. Zero until it has run, and it never
    // runs for APNG.
    FMeasuredFrames: Int64;
    FVerbose: Boolean;
    FOnProgress: TGifExportProgressEvent;
    procedure Progress(AStage: TGifExportStage; AFramesDone: Int64);
    procedure BeginPass;
    function NextEmittedFrame(out AFrame: TMovieReaderFrame): Boolean;
    procedure EnsureTargetSize(ASourceWidth, ASourceHeight: Integer);
    function ScaleFrame(const AFrame: TMovieReaderFrame;
      var ADestination: TBgraImage; out AError: string): Boolean;
    function RangeSeconds: Double;
    function ExpectedFrameCount: Integer;
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

procedure TExportSession.Progress(AStage: TGifExportStage;
  AFramesDone: Int64);
begin
  if Assigned(FOnProgress) then
    FOnProgress(AStage, AFramesDone, ExpectedFrameCount);
end;

destructor TExportSession.Destroy;
begin
  FreeAndNil(FReader);
  inherited Destroy;
end;

procedure TExportSession.BeginPass;
begin
  FEmitted := 0;
  FBaseSeconds := 0;
  FLastSlot := 0;
end;

function TExportSession.NextEmittedFrame(
  out AFrame: TMovieReaderFrame): Boolean;
var
  Frame: TMovieReaderFrame;
  Slot: Int64;
begin
  Result := False;
  AFrame := Default(TMovieReaderFrame);
  while FReader.NextFrame(Frame) do
  begin
    Inc(FReport.FramesRead);
    if FEmitted = 0 then
    begin
      FBaseSeconds := Frame.Seconds;
      FLastSlot := 0;
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
      FLastSlot := Slot;
    end;
    Inc(FEmitted);
    AFrame := Frame;
    Exit(True);
  end;
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
    BgraResample(PByte(Base), Stride, SourceWidth, SourceHeight,
      ADestination, FScratch);
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
// Before that pass there is nothing to count, so it is a *bound*, and
// everything below turns on it being a bound and not a guess: too large
// a stride costs the palette samples, but too small a one would overrun
// the quantiser's sampled-pixel budget, and SampleFrame then ignores
// everything past the cap — leaving the tail of the movie out of the
// palette entirely, and silently. Two bounds are available and the
// answer is the smaller.
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
// emits — and an estimate that runs low is the one thing the palette's
// stride cannot survive.
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
  // Ceil, never Round: the invariant above is "never runs low", and a
  // 32.4 rounded down to 32 against 33 emitted frames is exactly the
  // one-lost-sample breach the whole design exists to prevent.
  Result := Math.Ceil(Slots);
  if Result < 1 then
    Result := 1;
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
// The pass wants PaletteSampleFrames frames spread evenly across the
// movie, and it takes them with a stride over the frame index rather
// than over the clock. That weighting is deliberate: every frame the
// encoder writes counts the same towards how the result looks, so a busy
// stretch, which produces more frames, has earned more of the palette
// than an idle stretch of the same length. Spreading the samples over
// *time* instead was tried and measured on a 220 s capture: 21 samples
// rather than 13, and 0.45 dB worse (39.40 -> 38.95 against the same
// clip exported as an APNG, which quantises nothing and so is exactly
// the pixels the scaler produced).
//
// A stride needs the frame count in advance, which is the one number
// this pass does not have; what it uses instead, and why that number has
// to be an upper bound, is ExpectedFrameCount's business.
function TExportSession.CollectPalette(out APalette: TGifPalette;
  out AError: string): Boolean;
var
  Quantizer: TGifQuantizer;
  Frame: TMovieReaderFrame;
  Pool: NSAutoreleasePool;
  Index, Stride, EstimatedBeforePass: Integer;
begin
  Result := False;
  APalette := Default(TGifPalette);
  if not FReader.StartPass(FStartSeconds, FRangeSeconds, AError) then
    Exit;
  EstimatedBeforePass := ExpectedFrameCount;
  Stride := (EstimatedBeforePass + PaletteSampleFrames - 1)
    div PaletteSampleFrames;
  if Stride < 1 then
    Stride := 1;

  Quantizer := TGifQuantizer.Create;
  try
    Index := 0;
    Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
    try
      while NextEmittedFrame(Frame) do
      begin
        if Index mod Stride = 0 then
        begin
          EnsureTargetSize(Integer(CVPixelBufferGetWidth(Frame.PixelBuffer)),
            Integer(CVPixelBufferGetHeight(Frame.PixelBuffer)));
          if not ScaleFrame(Frame, FScaled, AError) then
            Exit;
          Quantizer.SampleFrame(@FScaled.Pixels[0], FScaled.BytesPerRow,
            FScaled.Width, FScaled.Height);
          Inc(FReport.SampledFrames);
        end;
        Inc(Index);
        Progress(gesPalette, Index);
        if Index mod PoolDrainEveryFrames = 0 then
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
    if Quantizer.IsEmpty then
    begin
      AError := 'the selected range holds no frames';
      Exit;
    end;
    FReport.ExactPalette := Quantizer.IsExactHistogram;
    // The source-frame bound is an empirical property of this recorder's
    // own output; a foreign movie whose header under-reports its real
    // average rate makes the estimate run low, the stride run short, and
    // the tail of the movie contribute nothing to the palette — with no
    // signal from the quantiser when its pixel budget runs out early.
    // The evidence is the emitted count itself.
    if (FEmitted > EstimatedBeforePass) and (EstimatedBeforePass > 0) then
    begin
      if FVerbose then
      begin
        WriteLn(Format('  note: the movie held more frames than its '
          + 'header promised (%d vs %d); the palette was sampled from '
          + 'the first part only', [FEmitted, EstimatedBeforePass]));
        Flush(Output);
      end;
    end;
    // Only now, after the pass has finished and its own progress has
    // been reported against the estimate: changing the total mid-pass
    // would walk the bar backwards.
    FMeasuredFrames := FEmitted;
    // One index of the 256 is reserved for "unchanged since the last
    // frame", so the palette is built one colour short of the maximum.
    APalette := Quantizer.BuildPalette(GifMaxOpaqueColors);
  finally
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
        Progress(gesEncode, ASink.FrameCount);
        if FVerbose and (ASink.FrameCount > 0)
          and (ASink.FrameCount mod ProgressEveryFrames = 0) then
        begin
          WriteLn(Format('  %d frames, %d kB', [ASink.FrameCount,
            ASink.BytesWritten div 1024]));
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
    Progress(gesEncode, ASink.FrameCount);
    if not ASink.Finish(AError) then
      Exit;
    FReport.FramesWritten := ASink.FrameCount;
    FReport.OutputBytes := ASink.BytesWritten;
    FReport.DurationSeconds := Planner.SpentTicks / Planner.TicksPerSecond;
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
      WriteLn(Format('exporting %dx%d at up to %d fps (%d colours) to %s',
        [FReport.PixelWidth, FReport.PixelHeight, FOptions.FramesPerSecond,
        FReport.PaletteColors, FOptions.OutputPath]))
    else
      WriteLn(Format('exporting %dx%d at up to %d fps (truecolour) to %s',
        [FReport.PixelWidth, FReport.PixelHeight, FOptions.FramesPerSecond,
        FOptions.OutputPath]));
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
  Result := True;
end;

{$ENDIF}

end.

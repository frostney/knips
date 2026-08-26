unit Opname.Export.GifPipeline;

// One export, start to finish: movie in, animated GIF out.
//
//   AVAssetReader -> decimate to the target rate -> optional downscale
//                 -> median-cut palette -> LZW -> .gif
//
// Two passes over the movie, because the palette has to be known before
// the first frame is written and AVAssetReader cannot rewind: the first
// pass samples up to PaletteSampleFrames frames spread across the range
// and feeds their colours to the quantiser, the second encodes. Only one
// decoded frame and one pending scaled frame are ever in memory.
//
// Frame delays come from the presentation stamps the reader hands back,
// not from the requested rate, so a recording that idles keeps its
// timing instead of being stretched to a fixed cadence.

{$I Shared.inc}

interface

{$IFDEF DARWIN}
{$modeswitch objectivec2}

uses
  Math,
  SysUtils,

  CocoaAll,
  MacOSAll,
  Opname.Capture.CoreMedia,
  Opname.Export.Bitmap,
  Opname.Export.Gif,
  Opname.Export.MovieReader,
  Opname.Options;

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
  TGifExportReport = record
    InputPath: string;
    OutputPath: string;
    SourceWidth: Integer;
    SourceHeight: Integer;
    PixelWidth: Integer;
    PixelHeight: Integer;
    FramesRead: Int64;
    FramesWritten: Int64;
    SampledFrames: Integer;
    PaletteColors: Integer;
    // Playback length of the GIF: the sum of its frame delays.
    DurationSeconds: Double;
    OutputBytes: Int64;
  end;

  TGifExportSession = class
  private
    FOptions: TExportOptions;
    FReport: TGifExportReport;
    FReader: TMovieReader;
    FScaled: TBgraImage;
    FPending: TBgraImage;
    FScratch: TBgraImage;
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
    procedure BeginPass;
    function NextEmittedFrame(out AFrame: TMovieReaderFrame): Boolean;
    procedure EnsureTargetSize(ASourceWidth, ASourceHeight: Integer);
    function ScaleFrame(const AFrame: TMovieReaderFrame;
      var ADestination: TBgraImage; out AError: string): Boolean;
    function ExpectedFrameCount: Integer;
    function ResolveRange(out AError: string): Boolean;
    function CollectPalette(out APalette: TGifPalette;
      out AError: string): Boolean;
    function WriteFrames(const APalette: TGifPalette;
      out AError: string): Boolean;
  public
    constructor Create(const AOptions: TExportOptions);
    destructor Destroy; override;
    // False with a one-line message on any failure; the partial output
    // file is removed.
    function Run(out AError: string): Boolean;
    property Report: TGifExportReport read FReport;
  end;

{$ENDIF}

implementation

{$IFDEF DARWIN}

{ TGifExportSession }

constructor TGifExportSession.Create(const AOptions: TExportOptions);
begin
  inherited Create;
  FOptions := AOptions;
end;

destructor TGifExportSession.Destroy;
begin
  FreeAndNil(FReader);
  inherited Destroy;
end;

procedure TGifExportSession.BeginPass;
begin
  FEmitted := 0;
  FBaseSeconds := 0;
  FLastSlot := 0;
end;

function TGifExportSession.NextEmittedFrame(
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

procedure TGifExportSession.EnsureTargetSize(ASourceWidth,
  ASourceHeight: Integer);
var
  TargetWidth: Integer;
begin
  if FReport.PixelWidth > 0 then
    Exit;
  FReport.SourceWidth := ASourceWidth;
  FReport.SourceHeight := ASourceHeight;
  TargetWidth := FOptions.Width;
  // Upscaling a recording into a GIF only costs bytes, so a width above
  // the source is treated as "as large as the source".
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
// success — a wrong GIF is worse than no GIF.
function TGifExportSession.ScaleFrame(const AFrame: TMovieReaderFrame;
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

function TGifExportSession.ExpectedFrameCount: Integer;
var
  Seconds: Double;
begin
  Seconds := FRangeSeconds;
  if Seconds <= 0 then
    Seconds := FReader.DurationSeconds - FStartSeconds;
  if Seconds <= 0 then
    Exit(1);
  Result := Round(Seconds * FOptions.FramesPerSecond);
  if Result < 1 then
    Result := 1;
end;

function TGifExportSession.ResolveRange(out AError: string): Boolean;
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

function TGifExportSession.CollectPalette(out APalette: TGifPalette;
  out AError: string): Boolean;
var
  Quantizer: TGifQuantizer;
  Frame: TMovieReaderFrame;
  Pool: NSAutoreleasePool;
  Index, Stride: Integer;
begin
  Result := False;
  APalette := Default(TGifPalette);
  if not FReader.StartPass(FStartSeconds, FRangeSeconds, AError) then
    Exit;
  Stride := (ExpectedFrameCount + PaletteSampleFrames - 1)
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
    // One index of the 256 is reserved for "unchanged since the last
    // frame", so the palette is built one colour short of the maximum.
    APalette := Quantizer.BuildPalette(GifMaxOpaqueColors);
  finally
    Quantizer.Free;
  end;
  FReport.PaletteColors := APalette.Count;
  Result := True;
end;

function TGifExportSession.WriteFrames(const APalette: TGifPalette;
  out AError: string): Boolean;
var
  Encoder: TGifEncoder;
  Frame: TMovieReaderFrame;
  Pool: NSAutoreleasePool;
  Swap: TBgraImage;
  BaseSeconds: Double;
  SpentCentiseconds: Int64;
  LastDelay: Integer;
  HasPending: Boolean;
begin
  Result := False;
  FReport.FramesRead := 0;
  if not FReader.StartPass(FStartSeconds, FRangeSeconds, AError) then
    Exit;

  Encoder := TGifEncoder.Create(FReport.PixelWidth, FReport.PixelHeight,
    APalette, FOptions.Dither);
  try
    if not Encoder.Open(FOptions.OutputPath, AError) then
      Exit;
    HasPending := False;
    BaseSeconds := 0;
    SpentCentiseconds := 0;
    LastDelay := GifClampDelay(Round(100 / FOptions.FramesPerSecond));
    Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
    try
      while NextEmittedFrame(Frame) do
      begin
        if not ScaleFrame(Frame, FScaled, AError) then
          Exit;
        if HasPending then
        begin
          // Delays are whole centiseconds, which cannot express 30 fps
          // (3.33) at all. Rounding each gap on its own would lose 10%
          // of the running time, so each delay is measured against the
          // centisecond grid the first frame started on and the error
          // never accumulates.
          LastDelay := GifClampDelay(
            Round((Frame.Seconds - BaseSeconds) * 100) - SpentCentiseconds);
          if not Encoder.AddFrame(@FPending.Pixels[0], FPending.BytesPerRow,
            LastDelay, AError) then
            Exit;
          Inc(SpentCentiseconds, LastDelay);
        end
        else
          BaseSeconds := Frame.Seconds;
        Swap := FPending;
        FPending := FScaled;
        FScaled := Swap;
        HasPending := True;
        if (Encoder.FrameCount > 0)
          and (Encoder.FrameCount mod ProgressEveryFrames = 0) then
        begin
          WriteLn(Format('  %d frames, %d kB', [Encoder.FrameCount,
            Encoder.BytesWritten div 1024]));
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
    // The last frame has no successor to measure against, so it keeps
    // the delay of the one before it.
    if not Encoder.AddFrame(@FPending.Pixels[0], FPending.BytesPerRow,
      LastDelay, AError) then
      Exit;
    Inc(SpentCentiseconds, LastDelay);
    if not Encoder.Finish(AError) then
      Exit;
    FReport.FramesWritten := Encoder.FrameCount;
    FReport.OutputBytes := Encoder.BytesWritten;
    FReport.DurationSeconds := SpentCentiseconds / 100;
    Result := True;
  finally
    Encoder.Free;
  end;
end;

function TGifExportSession.Run(out AError: string): Boolean;
var
  Palette: TGifPalette;
begin
  Result := False;
  AError := '';
  FReport := Default(TGifExportReport);
  FReport.InputPath := FOptions.InputPath;
  FReport.OutputPath := FOptions.OutputPath;

  FReader := TMovieReader.Create(FOptions.InputPath);
  if not FReader.Open(AError) then
    Exit;
  if not ResolveRange(AError) then
    Exit;

  BeginPass;
  if not CollectPalette(Palette, AError) then
    Exit;

  WriteLn(Format('exporting %dx%d at up to %d fps (%d colours) to %s',
    [FReport.PixelWidth, FReport.PixelHeight, FOptions.FramesPerSecond,
    FReport.PaletteColors, FOptions.OutputPath]));
  Flush(Output);

  BeginPass;
  if not WriteFrames(Palette, AError) then
  begin
    DeleteFile(FOptions.OutputPath);
    Exit;
  end;
  Result := True;
end;

{$ENDIF}

end.

unit Knips.Export.SizeEstimate;

// How big the animation is going to be, said before it is written and
// refined while it is.
//
// **Why this is hard, and what is honest about it.** A GIF's size is what
// LZW makes of the content, and screen content varies enormously: measured
// on real knips takes, the same encoder at the same settings produced
// between 0.015 and 0.31 bytes per output pixel — a factor of twenty. So
// an estimate from the settings alone (size, frame rate, duration) is not
// an estimate, it is a number with the right units.
//
// What rescues it is that the answer is already on disk. The **source
// movie's own bytes per pixel-frame** is H.264's verdict on how busy the
// content is, and it is free to read: the file's size divided by its
// frames and its pixels. Measured across five takes — a nearly static
// desktop region, a busy one, a whole 4K-ish display, a small quiet region
// twice — the ratio of the GIF's bytes per pixel to the movie's spanned
// 9.0 to 27.7 rather than the raw twentyfold, which is a spread of about
// three rather than twenty.
//
// So the pre-export estimate is
//
//     bytes  ~=  outputFrames * outputWidth * outputHeight
//                * sourceBytesPerPixelFrame * K
//
// and it is reported as a **range**, not a number, because the residual
// spread is real. docs/architecture.md ("What an export is going to
// weigh") carries the calibration table.
//
// **There is deliberately no downscale term.** The obvious worry about
// the formula above is that downscaling concentrates detail into fewer
// output pixels, so a heavily reduced GIF should cost more per output
// pixel than the source density predicts. It was measured rather than
// assumed: sixteen exports, seven takes, each exported at up to three
// widths spanning a fourfold linear reduction. Per take the ratio barely
// moves —
//
//     take         1200-1280 px    600 px    300 px
//     busy region      27.6          27.7      28.0
//     quiet region     15.3          17.6      20.1
//     small region      8.8           9.1       9.1
//     whole display    21.9 (1512)   23.6      23.6
//
// — while BETWEEN takes it spans 6.8 to 28.0. Downscale contributes at
// most about +30 % in the worst take; content contributes fourfold. A
// fitted `(sourcePixels/outputPixels)^a` term comes out at a = 0, and
// forcing a positive one makes the fit strictly worse (worst-case error
// 2.19x at a = 0, 2.62x at a = 0.2, 3.70x at a = 0.4). So the term is not
// here, and this paragraph is why.
//
// **No pre-pass is added for this.** The numbers above are the file's own
// size and the reader's own metadata; nothing extra is decoded. A GIF
// export does already walk the movie twice — the palette has to be known
// before the first frame is written — but that pass exists for the
// palette and this borrows nothing from it.
//
// **During the export the guess is retired.** Once frames are being
// written, bytes-so-far over frames-done times frames-total is a
// projection from the actual encoder on the actual content. Measured at
// the halfway mark of five exports it ran from -5 % to +30 % of the final
// size, and by the last tenth it was inside 1 % — the overshoots are all
// takes whose content went quiet in the second half, which a linear
// projection cannot know about and does not pretend to.
//
// So the pre-export estimate only has to be good enough to answer "is
// this going to be enormous?" before anyone has waited for it, and the
// projection only has to be better than that, which it is from the first
// hundred frames on.
//
// Platform-neutral and tested: it is arithmetic over four numbers.

{$I Knips.inc}

interface

uses
  SysUtils,

  Knips.Options;

const
  // Bytes of GIF per byte of source movie, per pixel-frame. The geometric
  // mean of SIXTEEN measured exports over seven takes at four output
  // widths, whose per-take ratios span 6.8 to 28.0. Dithering is on,
  // which is the default.
  //
  // It was 15.67, fitted on five exports that all happened to be halvings
  // of the source. Widening the calibration set moved it by 5 % and,
  // more usefully, showed how little of the spread the fit can remove.
  GifBytesPerSourceByte = 14.9;
  // Floyd-Steinberg scatters the palette error into neighbouring pixels,
  // which is exactly the runs LZW lives on. Measured on two takes:
  // 0.525 and 0.694 of the dithered size.
  NoDitherFactor = 0.61;
  // APNG is truecolour zlib rather than palette LZW, and it lands much
  // higher — and much more consistently: six exports over five takes fit
  // within 1.5x of this, where the GIF ratios span four to one.
  //
  // It was 67.0, fitted on two exports. Six is not many either, but two
  // was few enough to be 14 % out.
  ApngBytesPerSourceByte = 59.0;
  // What the estimate is worth, as a multiplier either way.
  //
  // The worst residual across the sixteen calibration exports is 2.19x
  // (GIF) and 1.50x (APNG). Three, not two and a quarter: a band that
  // only just contains its own calibration set is a band fitted to it,
  // and the previous 2.0 — set from five exports — was exceeded the first
  // time somebody exported content that was not in those five.
  //
  // **This is a measured spread, not a bound.** Sixteen exports of one
  // person's screen is not the space of screen content, and an export of
  // something unlike any of them can land outside. The wording in
  // DescribeEstimate says "roughly" for that reason, and the in-flight
  // projection replaces the whole guess within the first hundred frames.
  EstimateBand = 3.0;
  // The fallback when the source movie's size is not known — a stream, a
  // file that vanished, a caller that has not measured it. Bytes per
  // output pixel, straight. The band on these is much wider than
  // EstimateBand and the caller is told so by AHasSource coming back
  // False.
  FallbackGifBytesPerPixel = 0.15;
  FallbackApngBytesPerPixel = 0.45;

type
  TExportSizeEstimate = record
    // Whether the source movie's own size was available, and so whether
    // this is the content-aware estimate or the flat prior.
    FromSource: Boolean;
    Bytes: Int64;
    LowBytes: Int64;
    HighBytes: Int64;
  end;

// The movie's bytes per pixel of decoded frame — H.264's own verdict on
// how busy the content is. Zero when any input is missing, which is what
// makes EstimateExportSize fall back.
function SourceBytesPerPixelFrame(AFileBytes: Int64; AFrames: Int64;
  APixelWidth, APixelHeight: Integer): Double;

// The pre-export estimate. AFrames is how many frames the export will
// write, AWidth/AHeight its pixel size, ASourceBytesPerPixelFrame what the
// function above returned (0 when unknown).
function EstimateExportSize(AFormat: TExportFormat; AWidth, AHeight: Integer;
  AFrames: Int64; ADither: Boolean;
  ASourceBytesPerPixelFrame: Double): TExportSizeEstimate;

// The in-flight projection: what the finished file will weigh, from what
// the encoder has actually written. Zero when nothing has been written or
// the total is not known yet.
function ProjectExportSize(ABytesWritten, AFramesDone,
  AFramesTotal: Int64): Int64;

// "812 kB", "14.5 MB". Two significant places past a megabyte, none
// below: nobody wants three decimals of kilobyte, and "0.8 MB" reads
// worse than "812 kB".
function FormatByteSize(ABytes: Int64): string;

// The whole estimate as one line, for the CLI's verbose output and the
// playback window's label. '' when there is nothing worth saying.
function DescribeEstimate(const AEstimate: TExportSizeEstimate): string;

implementation

const
  BytesPerKilobyte = 1024;
  BytesPerMegabyte = 1024 * 1024;

function SourceBytesPerPixelFrame(AFileBytes: Int64; AFrames: Int64;
  APixelWidth, APixelHeight: Integer): Double;
var
  // Widened through an assignment, never through Double(AFrames): in
  // FreePascal a typecast between two eight-byte types reinterprets the
  // bits, so Double(Int64(100)) is a denormal near zero and every product
  // built on it collapses. It compiles, it runs, and it answers 0.
  PixelFrames: Double;
begin
  Result := 0;
  if (AFileBytes <= 0) or (AFrames <= 0) or (APixelWidth <= 0)
    or (APixelHeight <= 0) then
    Exit;
  PixelFrames := AFrames;
  PixelFrames := PixelFrames * APixelWidth * APixelHeight;
  Result := AFileBytes / PixelFrames;
end;

function EstimateExportSize(AFormat: TExportFormat; AWidth, AHeight: Integer;
  AFrames: Int64; ADither: Boolean;
  ASourceBytesPerPixelFrame: Double): TExportSizeEstimate;
var
  Pixels, Bytes, Factor: Double;
begin
  Result := Default(TExportSizeEstimate);
  // A passthrough trim writes the source's own bytes; there is nothing to
  // model and nothing to warn about.
  if AFormat = efMovie then
    Exit;
  if (AWidth <= 0) or (AHeight <= 0) or (AFrames <= 0) then
    Exit;
  // See SourceBytesPerPixelFrame for why this is an assignment and not a
  // typecast.
  Pixels := AFrames;
  Pixels := Pixels * AWidth * AHeight;
  if ASourceBytesPerPixelFrame > 0 then
  begin
    Result.FromSource := True;
    if AFormat = efApng then
      Factor := ApngBytesPerSourceByte
    else
    begin
      Factor := GifBytesPerSourceByte;
      if not ADither then
        Factor := Factor * NoDitherFactor;
    end;
    Bytes := Pixels * ASourceBytesPerPixelFrame * Factor;
  end
  else
  begin
    if AFormat = efApng then
      Factor := FallbackApngBytesPerPixel
    else
    begin
      Factor := FallbackGifBytesPerPixel;
      if not ADither then
        Factor := Factor * NoDitherFactor;
    end;
    Bytes := Pixels * Factor;
  end;
  Result.Bytes := Round(Bytes);
  Result.LowBytes := Round(Bytes / EstimateBand);
  Result.HighBytes := Round(Bytes * EstimateBand);
end;

function ProjectExportSize(ABytesWritten, AFramesDone,
  AFramesTotal: Int64): Int64;
begin
  Result := 0;
  if (ABytesWritten <= 0) or (AFramesDone <= 0) or (AFramesTotal <= 0) then
    Exit;
  // Past the end of the estimate, the projection is simply the bytes.
  if AFramesDone >= AFramesTotal then
    Exit(ABytesWritten);
  Result := Round(ABytesWritten / AFramesDone * AFramesTotal);
end;

function FormatByteSize(ABytes: Int64): string;
begin
  if ABytes < 0 then
    Exit('0 kB');
  if ABytes >= BytesPerMegabyte then
    Exit(Format('%.1f MB', [ABytes / BytesPerMegabyte]));
  Result := Format('%d kB', [(ABytes + BytesPerKilobyte - 1)
    div BytesPerKilobyte]);
end;

function DescribeEstimate(const AEstimate: TExportSizeEstimate): string;
begin
  Result := '';
  if AEstimate.Bytes <= 0 then
    Exit;
  Result := Format('roughly %s (%s to %s)',
    [FormatByteSize(AEstimate.Bytes), FormatByteSize(AEstimate.LowBytes),
    FormatByteSize(AEstimate.HighBytes)]);
  if not AEstimate.FromSource then
    // Said out loud, because this one is a flat prior over content that
    // varies twentyfold and the band above does not cover it.
    Result := Result + ', very roughly — the source movie''s size is not '
      + 'known, so this is not measured against the content';
end;

end.

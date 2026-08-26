unit Knips.Export.Bitmap;

// A 32-bit BGRA frame in plain memory, plus the resampling the GIF
// exporter needs. Platform-neutral on purpose: the Darwin side locks a
// CVPixelBuffer and hands over its base address, and everything from
// there on is arithmetic that a Linux test runner can check.
//
// Downscaling a screen recording by more than 2x with any two-tap
// kernel aliases text badly, so a large reduction is done in two steps:
// an integer box average first — correct antialiasing for a >=2x
// reduction, and nothing else is — then a resample for the remainder.
//
// That remainder used to be bilinear, and bilinear is what made the
// GIFs look soft: two taps per axis is a triangle filter, which on
// screen text is a blur. The remainder is Catmull-Rom bicubic instead.
// Four taps per axis, two of them negative, so an edge comes out of the
// filter with its contrast intact rather than averaged away; the
// negative lobes overshoot on a hard black-on-white edge and the
// overshoot is clamped to [0, 255], which is exactly the sharpening
// that makes small text readable. Bilinear stays exported: it is the
// baseline the co-located suite measures the bicubic path against.

{$I Knips.inc}

interface

uses
  Math,
  SysUtils;

const
  // kCVPixelFormatType_32BGRA in little-endian memory: B, G, R, A.
  BgraBytesPerPixel = 4;
  BgraBlueOffset = 0;
  BgraGreenOffset = 1;
  BgraRedOffset = 2;
  BgraAlphaOffset = 3;
  // Below this reduction factor a box pre-pass costs more than it buys.
  BoxReduceThreshold = 2;

type
  TBgraImage = record
    Width: Integer;
    Height: Integer;
    BytesPerRow: Integer;
    Pixels: TBytes;
  end;

  // The buffers BgraResample reuses between frames, so a long export
  // allocates once rather than per frame: Reduced takes the integer box
  // pre-pass, Rows takes the bicubic's horizontal pass.
  TResampleScratch = record
    Reduced: TBgraImage;
    Rows: TBgraImage;
  end;

// Allocates (or resizes) the image; contents are undefined afterwards.
procedure BgraImageResize(var AImage: TBgraImage; AWidth, AHeight: Integer);

function BgraImageRow(const AImage: TBgraImage; AY: Integer): PByte;

function BgraImageIsEmpty(const AImage: TBgraImage): Boolean;

// Copies a foreign BGRA buffer — typically a locked CVPixelBuffer —
// into AImage, which is resized to match.
procedure BgraImageCopyFrom(var AImage: TBgraImage; const ASource: PByte;
  ASourceBytesPerRow, AWidth, AHeight: Integer);

// Bilinear resample between two BGRA buffers of any sizes. Samples are
// taken at pixel centres, so a 1:1 resize is an exact copy.
procedure BgraResizeBilinear(const ASource: PByte; ASourceBytesPerRow,
  ASourceWidth, ASourceHeight: Integer; const ADestination: PByte;
  ADestinationBytesPerRow, ADestinationWidth, ADestinationHeight: Integer);

// Catmull-Rom bicubic resample between two BGRA buffers of any sizes,
// separable: a horizontal pass into AScratch (destination width by
// source height), then a vertical pass onto the target. Samples are
// taken at pixel centres like the bilinear one, so a 1:1 resize is a
// byte-for-byte copy. Both passes clamp to [0, 255]; the kernel's
// negative lobes overshoot on hard edges by design, and the clamp is
// where the overshoot is cut rather than wrapped.
procedure BgraResizeBicubic(const ASource: PByte; ASourceBytesPerRow,
  ASourceWidth, ASourceHeight: Integer; const ADestination: PByte;
  ADestinationBytesPerRow, ADestinationWidth, ADestinationHeight: Integer;
  var AScratch: TBgraImage);

// Averages AFactorX x AFactorY source pixels into one destination pixel.
// The destination must be ASourceWidth div AFactorX wide.
procedure BgraBoxReduce(const ASource: PByte; ASourceBytesPerRow,
  ASourceWidth, ASourceHeight: Integer; const ADestination: PByte;
  ADestinationBytesPerRow, AFactorX, AFactorY: Integer);

// The resize the exporter actually calls: a box pre-pass for large
// reductions, then bicubic onto the target — skipped entirely when the
// box pass already landed on the target size, which is what the app's
// point-size GIF default arranges. AScratch is reused between frames so
// a long export allocates once.
procedure BgraResample(const ASource: PByte; ASourceBytesPerRow,
  ASourceWidth, ASourceHeight: Integer; var ADestination: TBgraImage;
  var AScratch: TResampleScratch);

// Height that keeps the source aspect ratio at ATargetWidth; never 0.
function ScaledHeightForWidth(ASourceWidth, ASourceHeight,
  ATargetWidth: Integer): Integer;

implementation

const
  // Bilinear weights are 0..FractionOne in fixed point.
  FractionBits = 8;
  FractionOne = 1 shl FractionBits;
  // Catmull-Rom weights are signed fixed point summing to WeightOne.
  // Ten bits: the largest partial sum a tap can reach is 255 * 1024 *
  // the kernel's L1 norm (5/4), nowhere near a 32-bit Integer, and
  // every weight is an integer so two runs of the same resize agree
  // bit for bit on any host — which a Double kernel would not.
  WeightBits = 10;
  WeightOne = 1 shl WeightBits;
  CubicTaps = 4;

type
  TSampleAxis = record
    Low: array of Integer;
    High: array of Integer;
    Fraction: array of Integer;
  end;

  // CubicTaps entries per destination index, laid out flat.
  TCubicAxis = record
    Tap: array of Integer;
    Weight: array of Integer;
  end;

procedure BgraImageResize(var AImage: TBgraImage; AWidth, AHeight: Integer);
begin
  if AWidth < 0 then
    AWidth := 0;
  if AHeight < 0 then
    AHeight := 0;
  AImage.Width := AWidth;
  AImage.Height := AHeight;
  AImage.BytesPerRow := AWidth * BgraBytesPerPixel;
  SetLength(AImage.Pixels, AImage.BytesPerRow * AHeight);
end;

function BgraImageRow(const AImage: TBgraImage; AY: Integer): PByte;
begin
  if (AY < 0) or (AY >= AImage.Height) or (Length(AImage.Pixels) = 0) then
    Result := nil
  else
    Result := @AImage.Pixels[AY * AImage.BytesPerRow];
end;

function BgraImageIsEmpty(const AImage: TBgraImage): Boolean;
begin
  Result := (AImage.Width <= 0) or (AImage.Height <= 0)
    or (Length(AImage.Pixels) = 0);
end;

procedure BgraImageCopyFrom(var AImage: TBgraImage; const ASource: PByte;
  ASourceBytesPerRow, AWidth, AHeight: Integer);
var
  Y, RowBytes: Integer;
begin
  BgraImageResize(AImage, AWidth, AHeight);
  if BgraImageIsEmpty(AImage) or (ASource = nil) then
    Exit;
  RowBytes := AWidth * BgraBytesPerPixel;
  for Y := 0 to AHeight - 1 do
    Move((ASource + Y * ASourceBytesPerRow)^,
      AImage.Pixels[Y * AImage.BytesPerRow], RowBytes);
end;

function ScaledHeightForWidth(ASourceWidth, ASourceHeight,
  ATargetWidth: Integer): Integer;
begin
  if (ASourceWidth <= 0) or (ASourceHeight <= 0) or (ATargetWidth <= 0) then
    Exit(0);
  Result := Round(ASourceHeight * (ATargetWidth / ASourceWidth));
  if Result < 1 then
    Result := 1;
end;

// Pixel-centre mapping: destination centre (I + 0.5) lands on source
// coordinate (I + 0.5) * Source / Destination - 0.5, clamped at the
// edges so the outermost destination pixels replicate rather than wrap.
procedure BuildSampleAxis(ASourceLength, ADestinationLength: Integer;
  out AAxis: TSampleAxis);
var
  I, Whole, Fraction: Integer;
  Position: Double;
begin
  SetLength(AAxis.Low, ADestinationLength);
  SetLength(AAxis.High, ADestinationLength);
  SetLength(AAxis.Fraction, ADestinationLength);
  for I := 0 to ADestinationLength - 1 do
  begin
    Position := (I + 0.5) * ASourceLength / ADestinationLength - 0.5;
    if Position < 0 then
      Position := 0;
    Whole := Trunc(Position);
    if Whole > ASourceLength - 1 then
      Whole := ASourceLength - 1;
    Fraction := Round((Position - Whole) * FractionOne);
    if Fraction < 0 then
      Fraction := 0;
    if Fraction > FractionOne then
      Fraction := FractionOne;
    AAxis.Low[I] := Whole;
    if Whole + 1 <= ASourceLength - 1 then
      AAxis.High[I] := Whole + 1
    else
    begin
      AAxis.High[I] := Whole;
      Fraction := 0;
    end;
    AAxis.Fraction[I] := Fraction;
  end;
end;

procedure BgraResizeBilinear(const ASource: PByte; ASourceBytesPerRow,
  ASourceWidth, ASourceHeight: Integer; const ADestination: PByte;
  ADestinationBytesPerRow, ADestinationWidth, ADestinationHeight: Integer);
var
  Horizontal, Vertical: TSampleAxis;
  X, Y, Channel, FractionX, FractionY, Top, Bottom: Integer;
  TopLeft, TopRight, BottomLeft, BottomRight: PByte;
  Target: PByte;
  Upper, Lower: Integer;
begin
  if (ASource = nil) or (ADestination = nil) or (ASourceWidth <= 0)
    or (ASourceHeight <= 0) or (ADestinationWidth <= 0)
    or (ADestinationHeight <= 0) then
    Exit;
  BuildSampleAxis(ASourceWidth, ADestinationWidth, Horizontal);
  BuildSampleAxis(ASourceHeight, ADestinationHeight, Vertical);
  for Y := 0 to ADestinationHeight - 1 do
  begin
    Top := Vertical.Low[Y] * ASourceBytesPerRow;
    Bottom := Vertical.High[Y] * ASourceBytesPerRow;
    FractionY := Vertical.Fraction[Y];
    Target := ADestination + Y * ADestinationBytesPerRow;
    for X := 0 to ADestinationWidth - 1 do
    begin
      FractionX := Horizontal.Fraction[X];
      TopLeft := ASource + Top + Horizontal.Low[X] * BgraBytesPerPixel;
      TopRight := ASource + Top + Horizontal.High[X] * BgraBytesPerPixel;
      BottomLeft := ASource + Bottom + Horizontal.Low[X] * BgraBytesPerPixel;
      BottomRight := ASource + Bottom + Horizontal.High[X] * BgraBytesPerPixel;
      for Channel := 0 to BgraBytesPerPixel - 1 do
      begin
        Upper := (TopLeft + Channel)^ * (FractionOne - FractionX)
          + (TopRight + Channel)^ * FractionX;
        Lower := (BottomLeft + Channel)^ * (FractionOne - FractionX)
          + (BottomRight + Channel)^ * FractionX;
        (Target + Channel)^ := Byte((Upper * (FractionOne - FractionY)
          + Lower * FractionY + (FractionOne * FractionOne div 2))
          shr (FractionBits * 2));
      end;
      Inc(Target, BgraBytesPerPixel);
    end;
  end;
end;

// Same pixel-centre mapping as BuildSampleAxis, but over four taps at
// Floor(Position) - 1 .. + 2, replicated at the edges. The weights are
// rounded to fixed point and the rounding residue is handed to the
// heaviest tap, so every destination pixel's weights sum to exactly
// WeightOne: a flat area comes back unchanged and a 1:1 resize is the
// identity, neither of which survives naive per-weight rounding.
procedure BuildCubicAxis(ASourceLength, ADestinationLength: Integer;
  out AAxis: TCubicAxis);
var
  I, K, Base, Tap, Sum, Heaviest, HeaviestWeight, Rounded: Integer;
  Position, T: Double;
  Weights: array[0..CubicTaps - 1] of Double;
begin
  SetLength(AAxis.Tap, ADestinationLength * CubicTaps);
  SetLength(AAxis.Weight, ADestinationLength * CubicTaps);
  for I := 0 to ADestinationLength - 1 do
  begin
    Position := (I + 0.5) * ASourceLength / ADestinationLength - 0.5;
    Base := Floor(Position);
    T := Position - Base;
    // Catmull-Rom, the a = -1/2 member of the cubic family: it passes
    // through its samples (so t = 0 is the identity) and its two
    // negative lobes are what put the contrast back into an edge.
    Weights[0] := ((-0.5 * T + 1.0) * T - 0.5) * T;
    Weights[1] := (1.5 * T - 2.5) * T * T + 1.0;
    Weights[2] := ((-1.5 * T + 2.0) * T + 0.5) * T;
    Weights[3] := (0.5 * T - 0.5) * T * T;
    Sum := 0;
    Heaviest := 0;
    HeaviestWeight := Low(Integer);
    for K := 0 to CubicTaps - 1 do
    begin
      Tap := Base - 1 + K;
      if Tap < 0 then
        Tap := 0;
      if Tap > ASourceLength - 1 then
        Tap := ASourceLength - 1;
      AAxis.Tap[I * CubicTaps + K] := Tap;
      Rounded := Round(Weights[K] * WeightOne);
      AAxis.Weight[I * CubicTaps + K] := Rounded;
      Inc(Sum, Rounded);
      if Rounded > HeaviestWeight then
      begin
        HeaviestWeight := Rounded;
        Heaviest := K;
      end;
    end;
    Inc(AAxis.Weight[I * CubicTaps + Heaviest], WeightOne - Sum);
  end;
end;

// Fixed point back to a byte, rounded and clamped. The clamp is not
// defensive: Catmull-Rom genuinely overshoots both ends on a hard edge,
// and cutting the overshoot is the crispness. `shr` is only ever
// reached on a non-negative value — on a signed Integer it is not an
// arithmetic shift.
function CubicToByte(AValue: Integer): Byte; inline;
begin
  if AValue <= 0 then
    Exit(0);
  AValue := (AValue + WeightOne div 2) shr WeightBits;
  if AValue > 255 then
    Result := 255
  else
    Result := Byte(AValue);
end;

procedure BgraResizeBicubic(const ASource: PByte; ASourceBytesPerRow,
  ASourceWidth, ASourceHeight: Integer; const ADestination: PByte;
  ADestinationBytesPerRow, ADestinationWidth, ADestinationHeight: Integer;
  var AScratch: TBgraImage);
var
  Horizontal, Vertical: TCubicAxis;
  X, Y, K, Channel, Base, Total: Integer;
  Taps: array[0..CubicTaps - 1] of PByte;
  Weights: array[0..CubicTaps - 1] of Integer;
  Source, Target: PByte;
begin
  if (ASource = nil) or (ADestination = nil) or (ASourceWidth <= 0)
    or (ASourceHeight <= 0) or (ADestinationWidth <= 0)
    or (ADestinationHeight <= 0) then
    Exit;
  // The horizontal pass narrows first, so the vertical pass reads the
  // smaller of the two intermediates on a downscale.
  BgraImageResize(AScratch, ADestinationWidth, ASourceHeight);
  if BgraImageIsEmpty(AScratch) then
    Exit;
  BuildCubicAxis(ASourceWidth, ADestinationWidth, Horizontal);
  BuildCubicAxis(ASourceHeight, ADestinationHeight, Vertical);

  for Y := 0 to ASourceHeight - 1 do
  begin
    Source := ASource + Y * ASourceBytesPerRow;
    Target := @AScratch.Pixels[Y * AScratch.BytesPerRow];
    for X := 0 to ADestinationWidth - 1 do
    begin
      Base := X * CubicTaps;
      for K := 0 to CubicTaps - 1 do
      begin
        Taps[K] := Source + Horizontal.Tap[Base + K] * BgraBytesPerPixel;
        Weights[K] := Horizontal.Weight[Base + K];
      end;
      for Channel := 0 to BgraBytesPerPixel - 1 do
      begin
        Total := 0;
        for K := 0 to CubicTaps - 1 do
          Inc(Total, (Taps[K] + Channel)^ * Weights[K]);
        (Target + Channel)^ := CubicToByte(Total);
      end;
      Inc(Target, BgraBytesPerPixel);
    end;
  end;

  for Y := 0 to ADestinationHeight - 1 do
  begin
    Base := Y * CubicTaps;
    for K := 0 to CubicTaps - 1 do
    begin
      Taps[K] := @AScratch.Pixels[Vertical.Tap[Base + K]
        * AScratch.BytesPerRow];
      Weights[K] := Vertical.Weight[Base + K];
    end;
    Target := ADestination + Y * ADestinationBytesPerRow;
    for X := 0 to ADestinationWidth - 1 do
    begin
      for Channel := 0 to BgraBytesPerPixel - 1 do
      begin
        Total := 0;
        for K := 0 to CubicTaps - 1 do
          Inc(Total, (Taps[K] + Channel)^ * Weights[K]);
        (Target + Channel)^ := CubicToByte(Total);
      end;
      for K := 0 to CubicTaps - 1 do
        Inc(Taps[K], BgraBytesPerPixel);
      Inc(Target, BgraBytesPerPixel);
    end;
  end;
end;

procedure BgraBoxReduce(const ASource: PByte; ASourceBytesPerRow,
  ASourceWidth, ASourceHeight: Integer; const ADestination: PByte;
  ADestinationBytesPerRow, AFactorX, AFactorY: Integer);
var
  DestinationWidth, DestinationHeight: Integer;
  X, Y, StepX, StepY, Channel, Divisor: Integer;
  Totals: array[0..BgraBytesPerPixel - 1] of Integer;
  Cell, Target: PByte;
begin
  if (ASource = nil) or (ADestination = nil) or (AFactorX < 1)
    or (AFactorY < 1) then
    Exit;
  DestinationWidth := ASourceWidth div AFactorX;
  DestinationHeight := ASourceHeight div AFactorY;
  Divisor := AFactorX * AFactorY;
  for Y := 0 to DestinationHeight - 1 do
  begin
    Target := ADestination + Y * ADestinationBytesPerRow;
    for X := 0 to DestinationWidth - 1 do
    begin
      for Channel := 0 to BgraBytesPerPixel - 1 do
        Totals[Channel] := 0;
      for StepY := 0 to AFactorY - 1 do
      begin
        Cell := ASource + (Y * AFactorY + StepY) * ASourceBytesPerRow
          + X * AFactorX * BgraBytesPerPixel;
        for StepX := 0 to AFactorX - 1 do
        begin
          for Channel := 0 to BgraBytesPerPixel - 1 do
            Inc(Totals[Channel], (Cell + Channel)^);
          Inc(Cell, BgraBytesPerPixel);
        end;
      end;
      for Channel := 0 to BgraBytesPerPixel - 1 do
        (Target + Channel)^ := Byte((Totals[Channel] + Divisor div 2)
          div Divisor);
      Inc(Target, BgraBytesPerPixel);
    end;
  end;
end;

procedure BgraResample(const ASource: PByte; ASourceBytesPerRow,
  ASourceWidth, ASourceHeight: Integer; var ADestination: TBgraImage;
  var AScratch: TResampleScratch);
var
  FactorX, FactorY: Integer;
begin
  if BgraImageIsEmpty(ADestination) or (ASource = nil) then
    Exit;
  if (ADestination.Width = ASourceWidth)
    and (ADestination.Height = ASourceHeight) then
  begin
    BgraImageCopyFrom(ADestination, ASource, ASourceBytesPerRow,
      ASourceWidth, ASourceHeight);
    Exit;
  end;

  FactorX := ASourceWidth div ADestination.Width;
  FactorY := ASourceHeight div ADestination.Height;
  if (FactorX >= BoxReduceThreshold) and (FactorY >= BoxReduceThreshold) then
  begin
    BgraImageResize(AScratch.Reduced, ASourceWidth div FactorX,
      ASourceHeight div FactorY);
    if BgraImageIsEmpty(AScratch.Reduced) then
      Exit;
    BgraBoxReduce(ASource, ASourceBytesPerRow, ASourceWidth, ASourceHeight,
      @AScratch.Reduced.Pixels[0], AScratch.Reduced.BytesPerRow,
      FactorX, FactorY);
    // An integer reduction that lands on the target is already the
    // answer, and it is the exact answer — a 2x Retina recording
    // exported at its own point size is this case, and it is the whole
    // reason the app asks for point size. Resampling it again would
    // only put back the softness the box pass just avoided.
    if (AScratch.Reduced.Width = ADestination.Width)
      and (AScratch.Reduced.Height = ADestination.Height) then
    begin
      Move(AScratch.Reduced.Pixels[0], ADestination.Pixels[0],
        Length(ADestination.Pixels));
      Exit;
    end;
    BgraResizeBicubic(@AScratch.Reduced.Pixels[0],
      AScratch.Reduced.BytesPerRow, AScratch.Reduced.Width,
      AScratch.Reduced.Height, @ADestination.Pixels[0],
      ADestination.BytesPerRow, ADestination.Width, ADestination.Height,
      AScratch.Rows);
    Exit;
  end;

  BgraResizeBicubic(ASource, ASourceBytesPerRow, ASourceWidth,
    ASourceHeight, @ADestination.Pixels[0], ADestination.BytesPerRow,
    ADestination.Width, ADestination.Height, AScratch.Rows);
end;

end.

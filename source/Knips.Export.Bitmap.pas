unit Knips.Export.Bitmap;

// A 32-bit BGRA frame in plain memory, plus the resampling the GIF
// exporter needs. Platform-neutral on purpose: the Darwin side locks a
// CVPixelBuffer and hands over its base address, and everything from
// there on is arithmetic that a Linux test runner can check.
//
// Downscaling a screen recording by more than 2x with bilinear alone
// aliases text badly, so a large reduction is done in two steps: an
// integer box average first, then bilinear for the remainder.

{$I Knips.inc}

interface

uses
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

// Averages AFactorX x AFactorY source pixels into one destination pixel.
// The destination must be ASourceWidth div AFactorX wide.
procedure BgraBoxReduce(const ASource: PByte; ASourceBytesPerRow,
  ASourceWidth, ASourceHeight: Integer; const ADestination: PByte;
  ADestinationBytesPerRow, AFactorX, AFactorY: Integer);

// The resize the exporter actually calls: a box pre-pass for large
// reductions, then bilinear onto the target. AScratch is reused between
// frames so a long export allocates once.
procedure BgraResample(const ASource: PByte; ASourceBytesPerRow,
  ASourceWidth, ASourceHeight: Integer; var ADestination: TBgraImage;
  var AScratch: TBgraImage);

// Height that keeps the source aspect ratio at ATargetWidth; never 0.
function ScaledHeightForWidth(ASourceWidth, ASourceHeight,
  ATargetWidth: Integer): Integer;

implementation

const
  // Bilinear weights are 0..FractionOne in fixed point.
  FractionBits = 8;
  FractionOne = 1 shl FractionBits;

type
  TSampleAxis = record
    Low: array of Integer;
    High: array of Integer;
    Fraction: array of Integer;
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
  var AScratch: TBgraImage);
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
    BgraImageResize(AScratch, ASourceWidth div FactorX,
      ASourceHeight div FactorY);
    BgraBoxReduce(ASource, ASourceBytesPerRow, ASourceWidth, ASourceHeight,
      @AScratch.Pixels[0], AScratch.BytesPerRow, FactorX, FactorY);
    BgraResizeBilinear(@AScratch.Pixels[0], AScratch.BytesPerRow,
      AScratch.Width, AScratch.Height, @ADestination.Pixels[0],
      ADestination.BytesPerRow, ADestination.Width, ADestination.Height);
    Exit;
  end;

  BgraResizeBilinear(ASource, ASourceBytesPerRow, ASourceWidth,
    ASourceHeight, @ADestination.Pixels[0], ADestination.BytesPerRow,
    ADestination.Width, ADestination.Height);
end;

end.

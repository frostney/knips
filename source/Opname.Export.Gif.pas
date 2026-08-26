unit Opname.Export.Gif;

// Animated GIF89a in pure Pascal: median-cut quantisation, optional
// Floyd-Steinberg dithering, LZW, and a NETSCAPE2.0 loop extension.
// Nothing here knows about macOS, so `lwpt test` exercises the whole
// encoder on any host — which is the point, since this is the one part
// of the export path that cannot be checked by looking at a file size.
//
// Memory shape: the encoder never holds more than the current frame's
// palette indices and the previous frame's, so a long movie streams.
// The quantiser holds one fixed 6-bits-per-channel histogram (4 MB) and
// nothing else.
//
// Frames are written full-canvas the first time and as the changed
// rectangle afterwards, with disposal left at "leave in place". A
// rectangle alone is not enough on a real recording — H.264's noise
// floor moves a few scattered pixels in every corner of the frame, so
// the rectangle is usually the whole canvas — so each frame is also
// compressed a second time with the pixels that did not actually change
// written as the transparent index, and whichever came out shorter is
// what reaches the file. Between them that is where almost all of the
// size win on screen recordings comes from.
//
// Reserving the transparent index costs one palette slot, so the encoder
// works with at most GifMaxColors - 1 real colours.

{$I Shared.inc}

interface

uses
  Classes,
  Math,
  SysUtils,

  Opname.Export.Bitmap;

const
  GifMaxColors = 256;
  // One index is reserved to mean "unchanged since the last frame", so
  // this is what a palette for an animation may actually hold.
  GifMaxOpaqueColors = GifMaxColors - 1;
  // 6 bits per channel: colours within 4/255 of each other share a
  // histogram cell, far below what 256 palette slots can resolve.
  GifHistogramBits = 6;
  GifHistogramLevels = 1 shl GifHistogramBits;
  GifHistogramCells = GifHistogramLevels * GifHistogramLevels
    * GifHistogramLevels;
  // The histogram sums 8-bit channels into 32-bit counters, so the total
  // number of sampled pixels has to stay below 2^32 / 255.
  GifMaxSampledPixels = 8000000;
  GifMaxSampledPixelsPerFrame = 250000;
  // Browsers clamp 0 and 1 centisecond delays to 10; 2 is the smallest
  // delay that is honoured everywhere.
  GifMinDelayCentiseconds = 2;
  GifMaxDelayCentiseconds = 65535;
  // Disposal 1 = leave the frame in place, which is what lets the next
  // frame repaint only the rectangle that changed.
  GifDisposalLeaveInPlace = 1;
  GifLzwMaxCodeSize = 12;
  GifLzwMaxCode = 1 shl GifLzwMaxCodeSize;

type
  TGifColor = record
    Red: Byte;
    Green: Byte;
    Blue: Byte;
  end;

  TGifPalette = record
    Colors: array[0..GifMaxColors - 1] of TGifColor;
    Count: Integer;
  end;

  TGifHistogramCell = record
    Count: UInt32;
    SumRed: UInt32;
    SumGreen: UInt32;
    SumBlue: UInt32;
  end;

  // Colour statistics over a set of frames, reduced to a palette by
  // median cut. Sampling and reduction are separate so the pipeline can
  // feed it a spread of frames from a first pass over the movie.
  TGifQuantizer = class
  private
    FCells: array of TGifHistogramCell;
    FOrder: array of Int32;
    FSampledPixels: Int64;
    FDistinctCells: Integer;
    procedure SortRange(AFirst, ALast, AChannel: Integer);
    procedure RangeStatistics(AFirst, ALast: Integer; out ACount: Int64;
      out ASumRed, ASumGreen, ASumBlue: Int64;
      out ASpanRed, ASpanGreen, ASpanBlue: Integer);
  public
    constructor Create;
    procedure Reset;
    // Accumulates one frame's colours. Sub-samples internally, so the
    // accumulator stays in range whatever the frame size.
    procedure SampleFrame(const APixels: PByte; ABytesPerRow, AWidth,
      AHeight: Integer);
    // Median cut down to at most AMaxColors representatives. Each one is
    // the count-weighted mean of the exact colours in its box, so the
    // histogram's 6-bit cells only decide membership, never precision.
    function BuildPalette(AMaxColors: Integer): TGifPalette;
    function IsEmpty: Boolean;
    property DistinctCells: Integer read FDistinctCells;
    property SampledPixels: Int64 read FSampledPixels;
  end;

  // Streams one GIF89a file. Open, then AddFrame per frame with the
  // delay that frame should be shown for, then Finish.
  TGifEncoder = class
  private
    FWidth: Integer;
    FHeight: Integer;
    FPalette: TGifPalette;
    FDither: Boolean;
    FTableBits: Integer;
    FTableEntries: Integer;
    FTransparentIndex: Integer;
    FMinCodeSize: Integer;
    FOutput: TFileStream;
    FBuffer: TBytes;
    FBufferLength: Integer;
    // Each frame's image data is compressed into these twice — once
    // opaque, once with the unchanged pixels transparent — and the
    // shorter one is what reaches the file.
    FTrial: array[0..1] of TBytes;
    FTrialLength: array[0..1] of Integer;
    FTrialSlot: Integer;
    FCapturing: Boolean;
    FBytesWritten: Int64;
    FFrameCount: Int64;
    FIndices: TBytes;
    FPrevious: TBytes;
    FHasPrevious: Boolean;
    FLookup: array of SmallInt;
    FErrorCurrent: array of Integer;
    FErrorNext: array of Integer;
    FBlock: array[0..254] of Byte;
    FBlockLength: Integer;
    FBitBuffer: UInt32;
    FBitCount: Integer;
    FCodeSize: Integer;
    FMaxCode: Integer;
    FNextCode: Integer;
    FClearCode: Integer;
    FEndCode: Integer;
    FHashKey: array of Int32;
    FHashValue: array of Int32;
    procedure Emit(const AData; ALength: Integer);
    procedure BeginTrial(ASlot: Integer);
    procedure EndTrial;
    procedure EmitByte(AValue: Byte);
    procedure EmitWord(AValue: Integer);
    procedure EmitText(const AText: string);
    procedure FlushBuffer;
    procedure WriteHeader;
    procedure WriteLoopExtension;
    procedure WriteGraphicControl(ADelayCentiseconds: Integer;
      ATransparent: Boolean);
    procedure WriteImageDescriptor(ALeft, ATop, AWidth, AHeight: Integer);
    function NearestIndex(ARed, AGreen, ABlue: Integer): Integer;
    procedure QuantizeFrame(const APixels: PByte; ABytesPerRow: Integer);
    function ChangedRectangle(out ALeft, ATop, ARight,
      ABottom: Integer): Boolean;
    procedure ResetHash;
    function HashLookup(APrefix, ASuffix: Integer): Integer;
    procedure HashInsert(APrefix, ASuffix, ACode: Integer);
    procedure AppendCodeByte(AValue: Byte);
    procedure FlushBlock;
    procedure EmitCode(ACode: Integer);
    procedure CompressRectangle(ALeft, ATop, AWidth, AHeight: Integer;
      ATransparent: Boolean);
  public
    constructor Create(AWidth, AHeight: Integer; const APalette: TGifPalette;
      ADither: Boolean);
    destructor Destroy; override;
    function Open(const APath: string; out AError: string): Boolean;
    // APixels is a BGRA buffer of the encoder's own width and height.
    function AddFrame(const APixels: PByte; ABytesPerRow,
      ADelayCentiseconds: Integer; out AError: string): Boolean;
    function Finish(out AError: string): Boolean;
    property FrameCount: Int64 read FFrameCount;
    property BytesWritten: Int64 read FBytesWritten;
    // Colour table entries actually written (a power of two).
    property TableEntries: Integer read FTableEntries;
    // The reserved "unchanged" index, one past the last real colour.
    property TransparentIndex: Integer read FTransparentIndex;
  end;

// The 8-bit value a GifHistogramBits-wide level stands for, by bit
// replication: the level's own bits shifted up and the top bits folded
// into the gap. That maps the top level to 255 and level zero to 0, and
// puts every other level on the low corner of its cell.
function GifExpandLevel(ALevel: Integer): Byte; inline;

// Histogram cell index for an 8-bit colour.
function GifCellIndex(ARed, AGreen, ABlue: Integer): Integer; inline;

function GifClampDelay(ACentiseconds: Integer): Integer;

implementation

const
  OutputBufferSize = 32768;
  HashSlots = 8192;
  HashMask = HashSlots - 1;
  // Floyd-Steinberg weights, as sixteenths.
  DitherRight = 7;
  DitherDownLeft = 3;
  DitherDown = 5;
  DitherDownRight = 1;
  DitherTotal = 16;

function GifExpandLevel(ALevel: Integer): Byte;
begin
  Result := Byte((ALevel shl (8 - GifHistogramBits))
    or (ALevel shr (2 * GifHistogramBits - 8)));
end;

function GifCellIndex(ARed, AGreen, ABlue: Integer): Integer;
begin
  Result := ((ARed shr (8 - GifHistogramBits)) shl (2 * GifHistogramBits))
    or ((AGreen shr (8 - GifHistogramBits)) shl GifHistogramBits)
    or (ABlue shr (8 - GifHistogramBits));
end;

function GifClampDelay(ACentiseconds: Integer): Integer;
begin
  Result := ACentiseconds;
  if Result < GifMinDelayCentiseconds then
    Result := GifMinDelayCentiseconds;
  if Result > GifMaxDelayCentiseconds then
    Result := GifMaxDelayCentiseconds;
end;

function ClampByte(AValue: Integer): Integer; inline;
begin
  if AValue < 0 then
    Result := 0
  else if AValue > 255 then
    Result := 255
  else
    Result := AValue;
end;

function BitsForCount(ACount: Integer): Integer;
begin
  Result := 1;
  while (1 shl Result) < ACount do
    Inc(Result);
  if Result > 8 then
    Result := 8;
end;

{ TGifQuantizer }

constructor TGifQuantizer.Create;
begin
  inherited Create;
  SetLength(FCells, GifHistogramCells);
  Reset;
end;

procedure TGifQuantizer.Reset;
begin
  FillChar(FCells[0], Length(FCells) * SizeOf(TGifHistogramCell), 0);
  SetLength(FOrder, 0);
  FSampledPixels := 0;
  FDistinctCells := 0;
end;

function TGifQuantizer.IsEmpty: Boolean;
begin
  Result := FDistinctCells = 0;
end;

procedure TGifQuantizer.SampleFrame(const APixels: PByte; ABytesPerRow,
  AWidth, AHeight: Integer);
var
  X, Y, Stride, Start, Cell: Integer;
  Source: PByte;
begin
  if (APixels = nil) or (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  if FSampledPixels >= GifMaxSampledPixels then
    Exit;
  Stride := 1;
  while (AWidth * AHeight) div Stride > GifMaxSampledPixelsPerFrame do
    Inc(Stride);
  for Y := 0 to AHeight - 1 do
  begin
    // Rotate the row's starting column so a strided sample does not
    // degenerate into a handful of columns on a flat UI.
    Start := (Y * 7) mod Stride;
    Source := APixels + Y * ABytesPerRow;
    X := Start;
    while X < AWidth do
    begin
      Cell := GifCellIndex((Source + X * BgraBytesPerPixel
        + BgraRedOffset)^, (Source + X * BgraBytesPerPixel
        + BgraGreenOffset)^, (Source + X * BgraBytesPerPixel
        + BgraBlueOffset)^);
      if FCells[Cell].Count = 0 then
        Inc(FDistinctCells);
      Inc(FCells[Cell].Count);
      Inc(FCells[Cell].SumRed, (Source + X * BgraBytesPerPixel
        + BgraRedOffset)^);
      Inc(FCells[Cell].SumGreen, (Source + X * BgraBytesPerPixel
        + BgraGreenOffset)^);
      Inc(FCells[Cell].SumBlue, (Source + X * BgraBytesPerPixel
        + BgraBlueOffset)^);
      Inc(FSampledPixels);
      Inc(X, Stride);
    end;
  end;
end;

procedure TGifQuantizer.SortRange(AFirst, ALast, AChannel: Integer);
var
  Low, High, Swap: Integer;
  Pivot: Integer;
  Shift, Mask: Integer;
begin
  Shift := (2 - AChannel) * GifHistogramBits;
  Mask := GifHistogramLevels - 1;
  // Recurse into the smaller half and loop on the larger, so the stack
  // stays logarithmic however the cells happen to be ordered.
  while AFirst < ALast do
  begin
    Low := AFirst;
    High := ALast;
    Pivot := (FOrder[(AFirst + ALast) div 2] shr Shift) and Mask;
    repeat
      while ((FOrder[Low] shr Shift) and Mask) < Pivot do
        Inc(Low);
      while ((FOrder[High] shr Shift) and Mask) > Pivot do
        Dec(High);
      if Low <= High then
      begin
        Swap := FOrder[Low];
        FOrder[Low] := FOrder[High];
        FOrder[High] := Swap;
        Inc(Low);
        Dec(High);
      end;
    until Low > High;
    if (High - AFirst) < (ALast - Low) then
    begin
      SortRange(AFirst, High, AChannel);
      AFirst := Low;
    end
    else
    begin
      SortRange(Low, ALast, AChannel);
      ALast := High;
    end;
  end;
end;

procedure TGifQuantizer.RangeStatistics(AFirst, ALast: Integer;
  out ACount: Int64; out ASumRed, ASumGreen, ASumBlue: Int64;
  out ASpanRed, ASpanGreen, ASpanBlue: Integer);
var
  I, Cell, Red, Green, Blue: Integer;
  LowRed, HighRed, LowGreen, HighGreen, LowBlue, HighBlue: Integer;
begin
  ACount := 0;
  ASumRed := 0;
  ASumGreen := 0;
  ASumBlue := 0;
  LowRed := GifHistogramLevels;
  LowGreen := GifHistogramLevels;
  LowBlue := GifHistogramLevels;
  HighRed := -1;
  HighGreen := -1;
  HighBlue := -1;
  for I := AFirst to ALast do
  begin
    Cell := FOrder[I];
    Inc(ACount, FCells[Cell].Count);
    Inc(ASumRed, FCells[Cell].SumRed);
    Inc(ASumGreen, FCells[Cell].SumGreen);
    Inc(ASumBlue, FCells[Cell].SumBlue);
    Red := Cell shr (2 * GifHistogramBits);
    Green := (Cell shr GifHistogramBits) and (GifHistogramLevels - 1);
    Blue := Cell and (GifHistogramLevels - 1);
    LowRed := Min(LowRed, Red);
    HighRed := Max(HighRed, Red);
    LowGreen := Min(LowGreen, Green);
    HighGreen := Max(HighGreen, Green);
    LowBlue := Min(LowBlue, Blue);
    HighBlue := Max(HighBlue, Blue);
  end;
  ASpanRed := HighRed - LowRed;
  ASpanGreen := HighGreen - LowGreen;
  ASpanBlue := HighBlue - LowBlue;
end;

function TGifQuantizer.BuildPalette(AMaxColors: Integer): TGifPalette;
type
  TBox = record
    First: Integer;
    Last: Integer;
    Count: Int64;
    SumRed: Int64;
    SumGreen: Int64;
    SumBlue: Int64;
    SpanRed: Integer;
    SpanGreen: Integer;
    SpanBlue: Integer;
  end;
var
  Boxes: array of TBox;
  BoxCount, Filled, Chosen, Channel, Split, I: Integer;
  Priority, BestPriority: Int64;
  Running, Half: Int64;
  Left, Right: TBox;
begin
  Result := Default(TGifPalette);
  AMaxColors := Max(1, Min(AMaxColors, GifMaxColors));
  if FDistinctCells = 0 then
  begin
    Result.Count := 1;
    Exit;
  end;

  SetLength(FOrder, FDistinctCells);
  Filled := 0;
  for I := 0 to GifHistogramCells - 1 do
    if FCells[I].Count > 0 then
    begin
      FOrder[Filled] := I;
      Inc(Filled);
    end;

  SetLength(Boxes, AMaxColors);
  BoxCount := 1;
  Boxes[0].First := 0;
  Boxes[0].Last := High(FOrder);
  RangeStatistics(Boxes[0].First, Boxes[0].Last, Boxes[0].Count,
    Boxes[0].SumRed, Boxes[0].SumGreen, Boxes[0].SumBlue, Boxes[0].SpanRed,
    Boxes[0].SpanGreen, Boxes[0].SpanBlue);

  while BoxCount < AMaxColors do
  begin
    Chosen := -1;
    BestPriority := 0;
    for I := 0 to BoxCount - 1 do
    begin
      if Boxes[I].Last <= Boxes[I].First then
        Continue;
      // Population first, then population weighted by colour spread:
      // the early splits should follow where the pixels are, the later
      // ones where the remaining error is.
      if BoxCount * 2 <= AMaxColors then
        Priority := Boxes[I].Count
      else
        Priority := Boxes[I].Count * (1 + Boxes[I].SpanRed
          + Boxes[I].SpanGreen + Boxes[I].SpanBlue);
      if Priority > BestPriority then
      begin
        BestPriority := Priority;
        Chosen := I;
      end;
    end;
    if Chosen < 0 then
      Break;

    if (Boxes[Chosen].SpanRed >= Boxes[Chosen].SpanGreen)
      and (Boxes[Chosen].SpanRed >= Boxes[Chosen].SpanBlue) then
      Channel := 0
    else if Boxes[Chosen].SpanGreen >= Boxes[Chosen].SpanBlue then
      Channel := 1
    else
      Channel := 2;
    SortRange(Boxes[Chosen].First, Boxes[Chosen].Last, Channel);

    Half := Boxes[Chosen].Count div 2;
    Running := 0;
    Split := Boxes[Chosen].First;
    for I := Boxes[Chosen].First to Boxes[Chosen].Last - 1 do
    begin
      Inc(Running, FCells[FOrder[I]].Count);
      Split := I;
      if Running >= Half then
        Break;
    end;

    Left.First := Boxes[Chosen].First;
    Left.Last := Split;
    Right.First := Split + 1;
    Right.Last := Boxes[Chosen].Last;
    RangeStatistics(Left.First, Left.Last, Left.Count, Left.SumRed,
      Left.SumGreen, Left.SumBlue, Left.SpanRed, Left.SpanGreen,
      Left.SpanBlue);
    RangeStatistics(Right.First, Right.Last, Right.Count, Right.SumRed,
      Right.SumGreen, Right.SumBlue, Right.SpanRed, Right.SpanGreen,
      Right.SpanBlue);
    Boxes[Chosen] := Left;
    Boxes[BoxCount] := Right;
    Inc(BoxCount);
  end;

  Result.Count := BoxCount;
  for I := 0 to BoxCount - 1 do
    if Boxes[I].Count > 0 then
    begin
      Result.Colors[I].Red := Byte((Boxes[I].SumRed + Boxes[I].Count div 2)
        div Boxes[I].Count);
      Result.Colors[I].Green := Byte((Boxes[I].SumGreen
        + Boxes[I].Count div 2) div Boxes[I].Count);
      Result.Colors[I].Blue := Byte((Boxes[I].SumBlue + Boxes[I].Count div 2)
        div Boxes[I].Count);
    end;
end;

{ TGifEncoder }

constructor TGifEncoder.Create(AWidth, AHeight: Integer;
  const APalette: TGifPalette; ADither: Boolean);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FPalette := APalette;
  if FPalette.Count < 1 then
    FPalette.Count := 1;
  // The last index is the transparent one, so one real colour has to go
  // if the caller handed over a full 256.
  if FPalette.Count > GifMaxOpaqueColors then
    FPalette.Count := GifMaxOpaqueColors;
  FTransparentIndex := FPalette.Count;
  FDither := ADither;
  FTableBits := BitsForCount(FPalette.Count + 1);
  FTableEntries := 1 shl FTableBits;
  FMinCodeSize := Max(2, FTableBits);
  FClearCode := 1 shl FMinCodeSize;
  FEndCode := FClearCode + 1;
  SetLength(FBuffer, OutputBufferSize);
  SetLength(FIndices, FWidth * FHeight);
  SetLength(FPrevious, FWidth * FHeight);
  SetLength(FLookup, GifHistogramCells);
  FillChar(FLookup[0], Length(FLookup) * SizeOf(SmallInt), $FF);
  SetLength(FErrorCurrent, (FWidth + 2) * 3);
  SetLength(FErrorNext, (FWidth + 2) * 3);
  SetLength(FHashKey, HashSlots);
  SetLength(FHashValue, HashSlots);
end;

destructor TGifEncoder.Destroy;
begin
  FreeAndNil(FOutput);
  inherited Destroy;
end;

procedure TGifEncoder.FlushBuffer;
begin
  if (FBufferLength > 0) and (FOutput <> nil) then
  begin
    FOutput.WriteBuffer(FBuffer[0], FBufferLength);
    Inc(FBytesWritten, FBufferLength);
  end;
  FBufferLength := 0;
end;

procedure TGifEncoder.BeginTrial(ASlot: Integer);
begin
  FTrialSlot := ASlot;
  FTrialLength[ASlot] := 0;
  FCapturing := True;
end;

procedure TGifEncoder.EndTrial;
begin
  FCapturing := False;
end;

procedure TGifEncoder.Emit(const AData; ALength: Integer);
var
  Source: PByte;
  Chunk: Integer;
begin
  Source := @AData;
  if FCapturing then
  begin
    if FTrialLength[FTrialSlot] + ALength > Length(FTrial[FTrialSlot]) then
      SetLength(FTrial[FTrialSlot],
        (FTrialLength[FTrialSlot] + ALength) * 2);
    Move(Source^, FTrial[FTrialSlot][FTrialLength[FTrialSlot]], ALength);
    Inc(FTrialLength[FTrialSlot], ALength);
    Exit;
  end;
  while ALength > 0 do
  begin
    if FBufferLength = OutputBufferSize then
      FlushBuffer;
    Chunk := Min(ALength, OutputBufferSize - FBufferLength);
    Move(Source^, FBuffer[FBufferLength], Chunk);
    Inc(FBufferLength, Chunk);
    Inc(Source, Chunk);
    Dec(ALength, Chunk);
  end;
end;

procedure TGifEncoder.EmitByte(AValue: Byte);
begin
  Emit(AValue, 1);
end;

procedure TGifEncoder.EmitWord(AValue: Integer);
var
  Pair: array[0..1] of Byte;
begin
  Pair[0] := Byte(AValue and $FF);
  Pair[1] := Byte((AValue shr 8) and $FF);
  Emit(Pair[0], 2);
end;

procedure TGifEncoder.EmitText(const AText: string);
begin
  if AText <> '' then
    Emit(AText[1], Length(AText));
end;

procedure TGifEncoder.WriteHeader;
var
  I: Integer;
  Entry: array[0..2] of Byte;
begin
  EmitText('GIF89a');
  EmitWord(FWidth);
  EmitWord(FHeight);
  // Global colour table present, 8 bits of colour resolution, unsorted.
  EmitByte(Byte($80 or ($07 shl 4) or (FTableBits - 1)));
  EmitByte(0);
  EmitByte(0);
  for I := 0 to FTableEntries - 1 do
  begin
    if I < FPalette.Count then
    begin
      Entry[0] := FPalette.Colors[I].Red;
      Entry[1] := FPalette.Colors[I].Green;
      Entry[2] := FPalette.Colors[I].Blue;
    end
    else
      FillChar(Entry, SizeOf(Entry), 0);
    Emit(Entry[0], 3);
  end;
end;

procedure TGifEncoder.WriteLoopExtension;
begin
  EmitByte($21);
  EmitByte($FF);
  EmitByte($0B);
  EmitText('NETSCAPE2.0');
  EmitByte($03);
  EmitByte($01);
  EmitWord(0);
  EmitByte($00);
end;

procedure TGifEncoder.WriteGraphicControl(ADelayCentiseconds: Integer;
  ATransparent: Boolean);
var
  Flags: Integer;
begin
  Flags := GifDisposalLeaveInPlace shl 2;
  if ATransparent then
    Flags := Flags or $01;
  EmitByte($21);
  EmitByte($F9);
  EmitByte($04);
  EmitByte(Byte(Flags));
  EmitWord(GifClampDelay(ADelayCentiseconds));
  if ATransparent then
    EmitByte(Byte(FTransparentIndex))
  else
    EmitByte(0);
  EmitByte(0);
end;

procedure TGifEncoder.WriteImageDescriptor(ALeft, ATop, AWidth,
  AHeight: Integer);
begin
  EmitByte($2C);
  EmitWord(ALeft);
  EmitWord(ATop);
  EmitWord(AWidth);
  EmitWord(AHeight);
  EmitByte(0);
end;

function TGifEncoder.NearestIndex(ARed, AGreen, ABlue: Integer): Integer;
var
  Key, I, Best, Distance, BestDistance: Integer;
  Red, Green, Blue, DeltaRed, DeltaGreen, DeltaBlue: Integer;
begin
  Key := GifCellIndex(ARed, AGreen, ABlue);
  Result := FLookup[Key];
  if Result >= 0 then
    Exit;
  // Match the colour the cell key expands back to — bit replication,
  // so the cell's low corner — rather than whichever pixel happened to
  // reach the cell first. The answer is then a property of the cell,
  // which is what keeps the memo from making the output depend on the
  // order pixels arrive in; the up-to-3-per-channel offset from the
  // querying pixel is far below the spacing of a 256-colour palette.
  Red := GifExpandLevel(Key shr (2 * GifHistogramBits));
  Green := GifExpandLevel((Key shr GifHistogramBits)
    and (GifHistogramLevels - 1));
  Blue := GifExpandLevel(Key and (GifHistogramLevels - 1));
  Best := 0;
  BestDistance := MaxInt;
  for I := 0 to FPalette.Count - 1 do
  begin
    DeltaRed := Red - FPalette.Colors[I].Red;
    DeltaGreen := Green - FPalette.Colors[I].Green;
    DeltaBlue := Blue - FPalette.Colors[I].Blue;
    Distance := DeltaRed * DeltaRed + DeltaGreen * DeltaGreen
      + DeltaBlue * DeltaBlue;
    if Distance < BestDistance then
    begin
      BestDistance := Distance;
      Best := I;
      if Distance = 0 then
        Break;
    end;
  end;
  FLookup[Key] := SmallInt(Best);
  Result := Best;
end;

procedure TGifEncoder.QuantizeFrame(const APixels: PByte;
  ABytesPerRow: Integer);
var
  X, Y, Base, Index: Integer;
  Red, Green, Blue: Integer;
  ErrorRed, ErrorGreen, ErrorBlue: Integer;
  Source: PByte;
  Swap: array of Integer;
begin
  if FDither then
    FillChar(FErrorCurrent[0], Length(FErrorCurrent) * SizeOf(Integer), 0);
  for Y := 0 to FHeight - 1 do
  begin
    if FDither then
      FillChar(FErrorNext[0], Length(FErrorNext) * SizeOf(Integer), 0);
    Source := APixels + Y * ABytesPerRow;
    for X := 0 to FWidth - 1 do
    begin
      Blue := (Source + BgraBlueOffset)^;
      Green := (Source + BgraGreenOffset)^;
      Red := (Source + BgraRedOffset)^;
      Base := (X + 1) * 3;
      if FDither then
      begin
        Red := ClampByte(Red + FErrorCurrent[Base] div DitherTotal);
        Green := ClampByte(Green + FErrorCurrent[Base + 1] div DitherTotal);
        Blue := ClampByte(Blue + FErrorCurrent[Base + 2] div DitherTotal);
      end;
      Index := NearestIndex(Red, Green, Blue);
      FIndices[Y * FWidth + X] := Byte(Index);
      if FDither then
      begin
        ErrorRed := Red - FPalette.Colors[Index].Red;
        ErrorGreen := Green - FPalette.Colors[Index].Green;
        ErrorBlue := Blue - FPalette.Colors[Index].Blue;
        Inc(FErrorCurrent[Base + 3], ErrorRed * DitherRight);
        Inc(FErrorCurrent[Base + 4], ErrorGreen * DitherRight);
        Inc(FErrorCurrent[Base + 5], ErrorBlue * DitherRight);
        Inc(FErrorNext[Base - 3], ErrorRed * DitherDownLeft);
        Inc(FErrorNext[Base - 2], ErrorGreen * DitherDownLeft);
        Inc(FErrorNext[Base - 1], ErrorBlue * DitherDownLeft);
        Inc(FErrorNext[Base], ErrorRed * DitherDown);
        Inc(FErrorNext[Base + 1], ErrorGreen * DitherDown);
        Inc(FErrorNext[Base + 2], ErrorBlue * DitherDown);
        Inc(FErrorNext[Base + 3], ErrorRed * DitherDownRight);
        Inc(FErrorNext[Base + 4], ErrorGreen * DitherDownRight);
        Inc(FErrorNext[Base + 5], ErrorBlue * DitherDownRight);
      end;
      Inc(Source, BgraBytesPerPixel);
    end;
    if FDither then
    begin
      Swap := FErrorCurrent;
      FErrorCurrent := FErrorNext;
      FErrorNext := Swap;
    end;
  end;
end;

function TGifEncoder.ChangedRectangle(out ALeft, ATop, ARight,
  ABottom: Integer): Boolean;
var
  X, Y, RowBase: Integer;
begin
  ALeft := FWidth;
  ATop := FHeight;
  ARight := -1;
  ABottom := -1;
  for Y := 0 to FHeight - 1 do
  begin
    RowBase := Y * FWidth;
    for X := 0 to FWidth - 1 do
      if FIndices[RowBase + X] <> FPrevious[RowBase + X] then
      begin
        if X < ALeft then
          ALeft := X;
        if X > ARight then
          ARight := X;
        if Y < ATop then
          ATop := Y;
        ABottom := Y;
      end;
  end;
  Result := ARight >= 0;
end;

procedure TGifEncoder.ResetHash;
begin
  FillChar(FHashKey[0], Length(FHashKey) * SizeOf(Int32), $FF);
end;

function TGifEncoder.HashLookup(APrefix, ASuffix: Integer): Integer;
var
  Key, Slot: Integer;
begin
  Key := (APrefix shl 8) or ASuffix;
  Slot := ((Key shr 12) xor Key) and HashMask;
  while FHashKey[Slot] <> -1 do
  begin
    if FHashKey[Slot] = Key then
      Exit(FHashValue[Slot]);
    Slot := (Slot + 1) and HashMask;
  end;
  Result := -1;
end;

procedure TGifEncoder.HashInsert(APrefix, ASuffix, ACode: Integer);
var
  Key, Slot: Integer;
begin
  Key := (APrefix shl 8) or ASuffix;
  Slot := ((Key shr 12) xor Key) and HashMask;
  while FHashKey[Slot] <> -1 do
    Slot := (Slot + 1) and HashMask;
  FHashKey[Slot] := Key;
  FHashValue[Slot] := ACode;
end;

procedure TGifEncoder.FlushBlock;
begin
  if FBlockLength = 0 then
    Exit;
  EmitByte(Byte(FBlockLength));
  Emit(FBlock[0], FBlockLength);
  FBlockLength := 0;
end;

procedure TGifEncoder.AppendCodeByte(AValue: Byte);
begin
  FBlock[FBlockLength] := AValue;
  Inc(FBlockLength);
  if FBlockLength = 255 then
    FlushBlock;
end;

procedure TGifEncoder.EmitCode(ACode: Integer);
begin
  FBitBuffer := FBitBuffer or (UInt32(ACode) shl FBitCount);
  Inc(FBitCount, FCodeSize);
  while FBitCount >= 8 do
  begin
    AppendCodeByte(Byte(FBitBuffer and $FF));
    FBitBuffer := FBitBuffer shr 8;
    Dec(FBitCount, 8);
  end;
  // The width grows only after a code has been written at the old
  // width; that is what keeps encoder and decoder in step.
  while (FNextCode >= FMaxCode) and (FCodeSize < GifLzwMaxCodeSize) do
  begin
    FMaxCode := FMaxCode shl 1;
    Inc(FCodeSize);
  end;
end;

procedure TGifEncoder.CompressRectangle(ALeft, ATop, AWidth,
  AHeight: Integer; ATransparent: Boolean);
var
  X, Y, Offset, Pixel, Prefix, Code: Integer;
begin
  EmitByte(Byte(FMinCodeSize));
  FBlockLength := 0;
  FBitBuffer := 0;
  FBitCount := 0;
  FCodeSize := FMinCodeSize + 1;
  FMaxCode := 1 shl FCodeSize;
  FNextCode := FEndCode + 1;
  ResetHash;
  EmitCode(FClearCode);

  Prefix := -1;
  for Y := ATop to ATop + AHeight - 1 do
    for X := ALeft to ALeft + AWidth - 1 do
    begin
      Offset := Y * FWidth + X;
      // Everything inside the rectangle that did not move is written as
      // the transparent index, which LZW turns into long runs.
      if ATransparent and (FIndices[Offset] = FPrevious[Offset]) then
        Pixel := FTransparentIndex
      else
        Pixel := FIndices[Offset];
      if Prefix < 0 then
      begin
        Prefix := Pixel;
        Continue;
      end;
      Code := HashLookup(Prefix, Pixel);
      if Code >= 0 then
      begin
        Prefix := Code;
        Continue;
      end;
      EmitCode(Prefix);
      // Clearing at 4095 rather than 4096 gives up one dictionary slot
      // and keeps the encoder inside the 12-bit code space with a slot
      // to spare, which is what giflib does; a decoder cannot tell the
      // difference, since a clear code is always legal.
      if FNextCode >= GifLzwMaxCode - 1 then
      begin
        EmitCode(FClearCode);
        ResetHash;
        FCodeSize := FMinCodeSize + 1;
        FMaxCode := 1 shl FCodeSize;
        FNextCode := FEndCode + 1;
      end
      else
      begin
        HashInsert(Prefix, Pixel, FNextCode);
        Inc(FNextCode);
      end;
      Prefix := Pixel;
    end;

  if Prefix >= 0 then
    EmitCode(Prefix);
  EmitCode(FEndCode);
  if FBitCount > 0 then
  begin
    AppendCodeByte(Byte(FBitBuffer and $FF));
    FBitBuffer := 0;
    FBitCount := 0;
  end;
  FlushBlock;
  EmitByte(0);
end;

function TGifEncoder.Open(const APath: string; out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  if (FWidth <= 0) or (FHeight <= 0) then
  begin
    AError := 'the GIF canvas is empty';
    Exit;
  end;
  if (FWidth > 65535) or (FHeight > 65535) then
  begin
    AError := 'a GIF canvas cannot exceed 65535 pixels on a side';
    Exit;
  end;
  try
    FOutput := TFileStream.Create(APath, fmCreate);
  except
    on E: EStreamError do
    begin
      AError := 'cannot write ' + APath + ': ' + E.Message;
      Exit;
    end;
  end;
  try
    WriteHeader;
    WriteLoopExtension;
    Result := True;
  except
    on E: Exception do
      AError := 'writing ' + APath + ': ' + E.Message;
  end;
end;

function TGifEncoder.AddFrame(const APixels: PByte; ABytesPerRow,
  ADelayCentiseconds: Integer; out AError: string): Boolean;
var
  Left, Top, Right, Bottom: Integer;
  Transparent: Boolean;
begin
  Result := False;
  AError := '';
  if FOutput = nil then
  begin
    AError := 'the GIF is not open';
    Exit;
  end;
  try
    QuantizeFrame(APixels, ABytesPerRow);
    if FHasPrevious then
    begin
      if not ChangedRectangle(Left, Top, Right, Bottom) then
      begin
        // Nothing moved. Repaint one pixel with the colour already on
        // the canvas so the frame still carries its delay.
        Left := 0;
        Top := 0;
        Right := 0;
        Bottom := 0;
      end;
    end
    else
    begin
      Left := 0;
      Top := 0;
      Right := FWidth - 1;
      Bottom := FHeight - 1;
    end;
    // Whether transparency pays depends on what the unchanged pixels
    // look like — a varied background collapses into one long run, a
    // rectangle already tight around real movement only fragments. So
    // both are compressed and the shorter one wins; ties stay opaque.
    BeginTrial(0);
    CompressRectangle(Left, Top, Right - Left + 1, Bottom - Top + 1, False);
    EndTrial;
    Transparent := False;
    if FHasPrevious then
    begin
      BeginTrial(1);
      CompressRectangle(Left, Top, Right - Left + 1, Bottom - Top + 1, True);
      EndTrial;
      Transparent := FTrialLength[1] < FTrialLength[0];
    end;
    WriteGraphicControl(ADelayCentiseconds, Transparent);
    WriteImageDescriptor(Left, Top, Right - Left + 1, Bottom - Top + 1);
    if Transparent then
      Emit(FTrial[1][0], FTrialLength[1])
    else
      Emit(FTrial[0][0], FTrialLength[0]);
    Move(FIndices[0], FPrevious[0], Length(FIndices));
    FHasPrevious := True;
    Inc(FFrameCount);
    Result := True;
  except
    on E: Exception do
      AError := 'writing a GIF frame: ' + E.Message;
  end;
end;

function TGifEncoder.Finish(out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  if FOutput = nil then
  begin
    AError := 'the GIF is not open';
    Exit;
  end;
  try
    EmitByte($3B);
    FlushBuffer;
    FreeAndNil(FOutput);
    Result := True;
  except
    on E: Exception do
    begin
      AError := 'finishing the GIF: ' + E.Message;
      FreeAndNil(FOutput);
    end;
  end;
end;

end.

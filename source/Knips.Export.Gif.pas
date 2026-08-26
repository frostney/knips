unit Knips.Export.Gif;

// Animated GIF89a in pure Pascal: median-cut quantisation, optional
// Floyd-Steinberg dithering, LZW, and a NETSCAPE2.0 loop extension.
// Nothing here knows about macOS, so `lwpt test` exercises the whole
// encoder on any host — which is the point, since this is the one part
// of the export path that cannot be checked by looking at a file size.
//
// Memory shape: the encoder never holds more than the current frame's
// palette indices and the previous frame's, so a long movie streams.
// The quantiser holds one sparse histogram of *exact* colours (a 16 MB
// open-addressed table capped at 2^20 distinct colours, plus 8 MB while
// median cut sorts them) and falls back to a fixed 6-bits-per-channel
// histogram (4 MB) if a source ever exceeds the cap. The encoder adds a
// 6 MB nearest-colour memo. None of it grows with the length of the
// movie.
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

  Knips.Export.Bitmap;

const
  GifMaxColors = 256;
  // One index is reserved to mean "unchanged since the last frame", so
  // this is what a palette for an animation may actually hold.
  GifMaxOpaqueColors = GifMaxColors - 1;
  // The fallback histogram: 6 bits per channel, so colours within 4/255
  // of each other share a cell. Only reached when a source holds more
  // distinct colours than the exact table may hold.
  GifHistogramBits = 6;
  GifHistogramLevels = 1 shl GifHistogramBits;
  GifHistogramCells = GifHistogramLevels * GifHistogramLevels
    * GifHistogramLevels;
  // The exact histogram: an open-addressed table keyed by the packed
  // 24-bit colour. Half-full at the cap, which is what keeps the linear
  // probe short.
  GifExactTableBits = 21;
  GifExactTableSlots = 1 shl GifExactTableBits;
  GifExactMaxColors = 1 shl 20;
  // Direct-mapped memo for nearest-colour queries: an exact key per
  // slot, so a collision costs a search and never an answer.
  GifMemoBits = 20;
  GifMemoSlots = 1 shl GifMemoBits;
  // Both histograms sum 8-bit channels into 32-bit counters, so the
  // total number of sampled pixels has to stay below 2^32 / 255.
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
  //
  // Colours are counted exactly — one hash-table entry per distinct
  // 24-bit colour — so median cut splits boxes at real medians rather
  // than at the corners of a 4-unit lattice. A source that exceeds
  // GifExactMaxColors distinct colours folds what it has collected into
  // the 6-bit histogram and carries on there; screen recordings sit two
  // orders of magnitude below the cap, photographic noise does not.
  TGifQuantizer = class
  private
    FExactKeys: array of Int32;
    FExactCounts: array of UInt32;
    FExactColors: Integer;
    FExact: Boolean;
    FCells: array of TGifHistogramCell;
    FDistinctCells: Integer;
    FSampledPixels: Int64;
    // The histogram compacted into a sortable list: one key per distinct
    // colour (exact mode) or per occupied cell (fallback), with its
    // count alongside. FLevelBits says how wide a channel is in a key.
    FKeys: array of Int32;
    FCounts: array of UInt32;
    FEntries: Integer;
    FLevelBits: Integer;
    procedure EnsureExactTable;
    procedure EnsureCells;
    procedure AddExact(AKey: Int32);
    procedure AddCell(ARed, AGreen, ABlue: Integer);
    procedure FoldExactIntoCells;
    procedure BuildEntries;
    procedure SortRange(AFirst, ALast, AChannel: Integer);
    procedure RangeStatistics(AFirst, ALast: Integer; out ACount: Int64;
      out ASumRed, ASumGreen, ASumBlue: Int64;
      out AErrorRed, AErrorGreen, AErrorBlue: Double);
    function GetDistinctColors: Integer;
  public
    constructor Create;
    procedure Reset;
    // Accumulates one frame's colours. Sub-samples internally, so the
    // accumulator stays in range whatever the frame size.
    procedure SampleFrame(const APixels: PByte; ABytesPerRow, AWidth,
      AHeight: Integer);
    // Median cut down to at most AMaxColors representatives. Each one is
    // the count-weighted mean of the exact colours in its box.
    function BuildPalette(AMaxColors: Integer): TGifPalette;
    function IsEmpty: Boolean;
    // Distinct histogram entries: exact colours, or occupied 6-bit cells
    // once the exact table has overflowed.
    property DistinctColors: Integer read GetDistinctColors;
    // False once the exact table overflowed and the 6-bit fallback took
    // over — the pipeline reports it, because it changes the quality.
    property IsExactHistogram: Boolean read FExact;
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
    // Exact nearest-colour memo, direct-mapped: the key is the colour
    // itself, so a hit is the answer and a miss is a search.
    FMemoKey: array of Int32;
    FMemoValue: array of SmallInt;
    // Palette indices ordered by green, which is what lets the search
    // stop as soon as the green difference alone is too large.
    FByGreen: array of SmallInt;
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
    procedure BuildGreenOrder;
    function GreenLowerBound(AGreen: Integer): Integer;
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

// The packed 24-bit key an 8-bit colour has in the exact histogram and
// in the encoder's nearest-colour memo.
function GifColorKey(ARed, AGreen, ABlue: Integer): Integer; inline;

// Histogram cell index for an 8-bit colour (the 6-bit fallback).
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

function GifColorKey(ARed, AGreen, ABlue: Integer): Integer;
begin
  Result := (ARed shl 16) or (AGreen shl 8) or ABlue;
end;

// Fibonacci hashing on the packed colour, kept in 64-bit so no product
// ever wraps: the top bits of a 24-bit key alone would put every shade
// of one hue in the same run of slots.
function GifHashSlot(AKey: Integer; ABits, AShift: Integer): Integer; inline;
begin
  Result := Integer((Int64(AKey) * 2654435761) shr AShift)
    and ((1 shl ABits) - 1);
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
  Reset;
end;

procedure TGifQuantizer.Reset;
begin
  // Both tables are allocated on first use: a quantiser that is created
  // and never sampled — the empty-range path — costs nothing.
  if Length(FExactKeys) > 0 then
    FillChar(FExactKeys[0], Length(FExactKeys) * SizeOf(Int32), $FF);
  if Length(FCells) > 0 then
    FillChar(FCells[0], Length(FCells) * SizeOf(TGifHistogramCell), 0);
  SetLength(FKeys, 0);
  SetLength(FCounts, 0);
  FEntries := 0;
  FLevelBits := 8;
  FExact := True;
  FExactColors := 0;
  FSampledPixels := 0;
  FDistinctCells := 0;
end;

procedure TGifQuantizer.EnsureExactTable;
begin
  if Length(FExactKeys) > 0 then
    Exit;
  SetLength(FExactKeys, GifExactTableSlots);
  SetLength(FExactCounts, GifExactTableSlots);
  FillChar(FExactKeys[0], Length(FExactKeys) * SizeOf(Int32), $FF);
end;

procedure TGifQuantizer.EnsureCells;
begin
  if Length(FCells) > 0 then
    Exit;
  SetLength(FCells, GifHistogramCells);
  FillChar(FCells[0], Length(FCells) * SizeOf(TGifHistogramCell), 0);
end;

function TGifQuantizer.GetDistinctColors: Integer;
begin
  if FExact then
    Result := FExactColors
  else
    Result := FDistinctCells;
end;

procedure TGifQuantizer.AddCell(ARed, AGreen, ABlue: Integer);
var
  Cell: Integer;
begin
  Cell := GifCellIndex(ARed, AGreen, ABlue);
  if FCells[Cell].Count = 0 then
    Inc(FDistinctCells);
  Inc(FCells[Cell].Count);
  Inc(FCells[Cell].SumRed, UInt32(ARed));
  Inc(FCells[Cell].SumGreen, UInt32(AGreen));
  Inc(FCells[Cell].SumBlue, UInt32(ABlue));
end;

procedure TGifQuantizer.AddExact(AKey: Int32);
var
  Slot: Integer;
begin
  Slot := GifHashSlot(AKey, GifExactTableBits, 20);
  while FExactKeys[Slot] <> -1 do
  begin
    if FExactKeys[Slot] = AKey then
    begin
      Inc(FExactCounts[Slot]);
      Exit;
    end;
    Slot := (Slot + 1) and (GifExactTableSlots - 1);
  end;
  if FExactColors >= GifExactMaxColors then
  begin
    // One colour past the cap: everything counted so far moves into the
    // 6-bit histogram, and so does this pixel.
    FoldExactIntoCells;
    AddCell((AKey shr 16) and $FF, (AKey shr 8) and $FF, AKey and $FF);
    Exit;
  end;
  FExactKeys[Slot] := AKey;
  FExactCounts[Slot] := 1;
  Inc(FExactColors);
end;

// Exact counts fold into 6-bit cells without loss: the cell keeps the
// real 8-bit channel sums, so the palette a folded histogram produces is
// the one sampling in 6-bit mode from the start would have produced.
procedure TGifQuantizer.FoldExactIntoCells;
var
  I, Cell, Red, Green, Blue: Integer;
  Count: UInt32;
begin
  EnsureCells;
  for I := 0 to GifExactTableSlots - 1 do
    if FExactKeys[I] <> -1 then
    begin
      Count := FExactCounts[I];
      Red := (FExactKeys[I] shr 16) and $FF;
      Green := (FExactKeys[I] shr 8) and $FF;
      Blue := FExactKeys[I] and $FF;
      Cell := GifCellIndex(Red, Green, Blue);
      if FCells[Cell].Count = 0 then
        Inc(FDistinctCells);
      Inc(FCells[Cell].Count, Count);
      Inc(FCells[Cell].SumRed, UInt32(Red) * Count);
      Inc(FCells[Cell].SumGreen, UInt32(Green) * Count);
      Inc(FCells[Cell].SumBlue, UInt32(Blue) * Count);
    end;
  SetLength(FExactKeys, 0);
  SetLength(FExactCounts, 0);
  FExactColors := 0;
  FExact := False;
end;

procedure TGifQuantizer.SampleFrame(const APixels: PByte; ABytesPerRow,
  AWidth, AHeight: Integer);
var
  X, Y, Stride, Start: Integer;
  Red, Green, Blue: Integer;
  Source, Pixel: PByte;
begin
  if (APixels = nil) or (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  if FSampledPixels >= GifMaxSampledPixels then
    Exit;
  if FExact then
    EnsureExactTable
  else
    EnsureCells;
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
      Pixel := Source + X * BgraBytesPerPixel;
      Red := (Pixel + BgraRedOffset)^;
      Green := (Pixel + BgraGreenOffset)^;
      Blue := (Pixel + BgraBlueOffset)^;
      if FExact then
        AddExact(GifColorKey(Red, Green, Blue))
      else
        AddCell(Red, Green, Blue);
      Inc(FSampledPixels);
      Inc(X, Stride);
    end;
  end;
end;

function TGifQuantizer.IsEmpty: Boolean;
begin
  Result := DistinctColors = 0;
end;

// Compacts whichever histogram is live into the parallel key/count
// arrays median cut sorts. Channels sit at FLevelBits each in the key,
// which is the one thing that differs between the two modes.
procedure TGifQuantizer.BuildEntries;
var
  I, Filled: Integer;
begin
  Filled := 0;
  if FExact then
  begin
    SetLength(FKeys, FExactColors);
    SetLength(FCounts, FExactColors);
    for I := 0 to GifExactTableSlots - 1 do
      if FExactKeys[I] <> -1 then
      begin
        FKeys[Filled] := FExactKeys[I];
        FCounts[Filled] := FExactCounts[I];
        Inc(Filled);
      end;
    FLevelBits := 8;
  end
  else
  begin
    SetLength(FKeys, FDistinctCells);
    SetLength(FCounts, FDistinctCells);
    for I := 0 to GifHistogramCells - 1 do
      if FCells[I].Count > 0 then
      begin
        FKeys[Filled] := I;
        FCounts[Filled] := FCells[I].Count;
        Inc(Filled);
      end;
    FLevelBits := GifHistogramBits;
  end;
  FEntries := Filled;
end;

procedure TGifQuantizer.SortRange(AFirst, ALast, AChannel: Integer);
var
  Low, High, Swap: Integer;
  Pivot: Integer;
  Shift, Mask: Integer;
  SwapCount: UInt32;
begin
  Shift := (2 - AChannel) * FLevelBits;
  Mask := (1 shl FLevelBits) - 1;
  // Recurse into the smaller half and loop on the larger, so the stack
  // stays logarithmic however the entries happen to be ordered.
  while AFirst < ALast do
  begin
    Low := AFirst;
    High := ALast;
    Pivot := (FKeys[(AFirst + ALast) div 2] shr Shift) and Mask;
    repeat
      while ((FKeys[Low] shr Shift) and Mask) < Pivot do
        Inc(Low);
      while ((FKeys[High] shr Shift) and Mask) > Pivot do
        Dec(High);
      if Low <= High then
      begin
        Swap := FKeys[Low];
        FKeys[Low] := FKeys[High];
        FKeys[High] := Swap;
        SwapCount := FCounts[Low];
        FCounts[Low] := FCounts[High];
        FCounts[High] := SwapCount;
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

// Sums for a run of entries, plus the squared error each channel would
// still carry if the whole run collapsed onto its own mean. That error
// is what the export is judged on, so it is also what decides which box
// to split next and along which channel — the span-based heuristic this
// replaced spent slots on wide boxes that almost nothing lived in.
procedure TGifQuantizer.RangeStatistics(AFirst, ALast: Integer;
  out ACount: Int64; out ASumRed, ASumGreen, ASumBlue: Int64;
  out AErrorRed, AErrorGreen, AErrorBlue: Double);
var
  I, Key, Red, Green, Blue: Integer;
  Count: Int64;
  SquareRed, SquareGreen, SquareBlue: Double;
begin
  ACount := 0;
  ASumRed := 0;
  ASumGreen := 0;
  ASumBlue := 0;
  SquareRed := 0;
  SquareGreen := 0;
  SquareBlue := 0;
  for I := AFirst to ALast do
  begin
    Key := FKeys[I];
    Count := FCounts[I];
    Inc(ACount, Count);
    if FExact then
    begin
      Red := (Key shr 16) and $FF;
      Green := (Key shr 8) and $FF;
      Blue := Key and $FF;
      Inc(ASumRed, Int64(Red) * Count);
      Inc(ASumGreen, Int64(Green) * Count);
      Inc(ASumBlue, Int64(Blue) * Count);
    end
    else
    begin
      // The cell's own 8-bit sums, so a fallback palette entry is still
      // the mean of the real colours rather than of cell corners. The
      // squares treat the cell as a point mass at that mean, which is
      // accurate enough for a choice between boxes.
      Inc(ASumRed, FCells[Key].SumRed);
      Inc(ASumGreen, FCells[Key].SumGreen);
      Inc(ASumBlue, FCells[Key].SumBlue);
      Red := (FCells[Key].SumRed + Count div 2) div Count;
      Green := (FCells[Key].SumGreen + Count div 2) div Count;
      Blue := (FCells[Key].SumBlue + Count div 2) div Count;
    end;
    SquareRed := SquareRed + Int64(Red) * Red * Count;
    SquareGreen := SquareGreen + Int64(Green) * Green * Count;
    SquareBlue := SquareBlue + Int64(Blue) * Blue * Count;
  end;
  if ACount > 0 then
  begin
    AErrorRed := Max(0, SquareRed - (ASumRed / ACount) * ASumRed);
    AErrorGreen := Max(0, SquareGreen - (ASumGreen / ACount) * ASumGreen);
    AErrorBlue := Max(0, SquareBlue - (ASumBlue / ACount) * ASumBlue);
  end
  else
  begin
    AErrorRed := 0;
    AErrorGreen := 0;
    AErrorBlue := 0;
  end;
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
    ErrorRed: Double;
    ErrorGreen: Double;
    ErrorBlue: Double;
  end;
var
  Boxes: array of TBox;
  BoxCount, Chosen, Channel, Split, I: Integer;
  Priority, BestPriority: Double;
  Running, Half: Int64;
  Left, Right: TBox;
begin
  Result := Default(TGifPalette);
  AMaxColors := Max(1, Min(AMaxColors, GifMaxColors));
  if IsEmpty then
  begin
    Result.Count := 1;
    Exit;
  end;

  BuildEntries;

  SetLength(Boxes, AMaxColors);
  BoxCount := 1;
  Boxes[0].First := 0;
  Boxes[0].Last := FEntries - 1;
  RangeStatistics(Boxes[0].First, Boxes[0].Last, Boxes[0].Count,
    Boxes[0].SumRed, Boxes[0].SumGreen, Boxes[0].SumBlue, Boxes[0].ErrorRed,
    Boxes[0].ErrorGreen, Boxes[0].ErrorBlue);

  while BoxCount < AMaxColors do
  begin
    Chosen := -1;
    BestPriority := 0;
    for I := 0 to BoxCount - 1 do
    begin
      if Boxes[I].Last <= Boxes[I].First then
        Continue;
      // Split wherever the most squared error is still sitting. A box
      // that holds one colour has none, so a palette smaller than the
      // limit means the source genuinely had fewer colours.
      Priority := Boxes[I].ErrorRed + Boxes[I].ErrorGreen
        + Boxes[I].ErrorBlue;
      if Priority > BestPriority then
      begin
        BestPriority := Priority;
        Chosen := I;
      end;
    end;
    if Chosen < 0 then
      Break;

    if (Boxes[Chosen].ErrorRed >= Boxes[Chosen].ErrorGreen)
      and (Boxes[Chosen].ErrorRed >= Boxes[Chosen].ErrorBlue) then
      Channel := 0
    else if Boxes[Chosen].ErrorGreen >= Boxes[Chosen].ErrorBlue then
      Channel := 1
    else
      Channel := 2;
    SortRange(Boxes[Chosen].First, Boxes[Chosen].Last, Channel);

    Half := Boxes[Chosen].Count div 2;
    Running := 0;
    Split := Boxes[Chosen].First;
    for I := Boxes[Chosen].First to Boxes[Chosen].Last - 1 do
    begin
      Inc(Running, FCounts[I]);
      Split := I;
      if Running >= Half then
        Break;
    end;

    Left.First := Boxes[Chosen].First;
    Left.Last := Split;
    Right.First := Split + 1;
    Right.Last := Boxes[Chosen].Last;
    RangeStatistics(Left.First, Left.Last, Left.Count, Left.SumRed,
      Left.SumGreen, Left.SumBlue, Left.ErrorRed, Left.ErrorGreen,
      Left.ErrorBlue);
    RangeStatistics(Right.First, Right.Last, Right.Count, Right.SumRed,
      Right.SumGreen, Right.SumBlue, Right.ErrorRed, Right.ErrorGreen,
      Right.ErrorBlue);
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
  SetLength(FMemoKey, GifMemoSlots);
  SetLength(FMemoValue, GifMemoSlots);
  FillChar(FMemoKey[0], Length(FMemoKey) * SizeOf(Int32), $FF);
  BuildGreenOrder;
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

// Insertion sort over at most 255 entries, once per encoder.
procedure TGifEncoder.BuildGreenOrder;
var
  I, J, Value: Integer;
begin
  SetLength(FByGreen, FPalette.Count);
  for I := 0 to FPalette.Count - 1 do
  begin
    Value := I;
    J := I - 1;
    while (J >= 0)
      and (FPalette.Colors[FByGreen[J]].Green > FPalette.Colors[Value].Green) do
    begin
      FByGreen[J + 1] := FByGreen[J];
      Dec(J);
    end;
    FByGreen[J + 1] := SmallInt(Value);
  end;
end;

// First position in FByGreen whose palette entry is at least AGreen.
function TGifEncoder.GreenLowerBound(AGreen: Integer): Integer;
var
  Low, High, Middle: Integer;
begin
  Low := 0;
  High := FPalette.Count;
  while Low < High do
  begin
    Middle := (Low + High) div 2;
    if FPalette.Colors[FByGreen[Middle]].Green < AGreen then
      Low := Middle + 1
    else
      High := Middle;
  end;
  Result := Low;
end;

// The exact nearest palette entry for a colour, memoised on the colour
// itself. The old memo was keyed by 6-bit cell and answered for the
// cell's corner rather than for the pixel, which put a floor of a couple
// of units per channel under every mapped pixel — visible as banding on
// gradients and, once dithering added its own error on top, as the
// difference between a 37 dB and a 44 dB export.
//
// Exact keys mean far more distinct queries, so the scan they fall back
// to walks the palette outwards from the entry closest in green and
// stops as soon as the green difference alone exceeds the best distance
// found. That is the same answer a full scan gives, for a fraction of
// the comparisons.
function TGifEncoder.NearestIndex(ARed, AGreen, ABlue: Integer): Integer;
var
  Key, Slot, Position, I, Index, Best: Integer;
  Distance, BestDistance: Integer;
  DeltaRed, DeltaGreen, DeltaBlue: Integer;
begin
  Key := GifColorKey(ARed, AGreen, ABlue);
  Slot := GifHashSlot(Key, GifMemoBits, 17);
  if FMemoKey[Slot] = Key then
    Exit(FMemoValue[Slot]);

  Best := 0;
  BestDistance := MaxInt;
  Position := GreenLowerBound(AGreen);
  I := Position;
  while I < FPalette.Count do
  begin
    Index := FByGreen[I];
    DeltaGreen := FPalette.Colors[Index].Green - AGreen;
    if DeltaGreen * DeltaGreen >= BestDistance then
      Break;
    DeltaRed := ARed - FPalette.Colors[Index].Red;
    DeltaBlue := ABlue - FPalette.Colors[Index].Blue;
    Distance := DeltaRed * DeltaRed + DeltaGreen * DeltaGreen
      + DeltaBlue * DeltaBlue;
    if Distance < BestDistance then
    begin
      BestDistance := Distance;
      Best := Index;
    end;
    Inc(I);
  end;
  I := Position - 1;
  while I >= 0 do
  begin
    Index := FByGreen[I];
    DeltaGreen := AGreen - FPalette.Colors[Index].Green;
    if DeltaGreen * DeltaGreen >= BestDistance then
      Break;
    DeltaRed := ARed - FPalette.Colors[Index].Red;
    DeltaBlue := ABlue - FPalette.Colors[Index].Blue;
    Distance := DeltaRed * DeltaRed + DeltaGreen * DeltaGreen
      + DeltaBlue * DeltaBlue;
    if Distance < BestDistance then
    begin
      BestDistance := Distance;
      Best := Index;
    end;
    Dec(I);
  end;

  FMemoKey[Slot] := Key;
  FMemoValue[Slot] := SmallInt(Best);
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

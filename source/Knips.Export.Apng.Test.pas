program Knips.Export.Apng.Test;

// The APNG encoder is checked against a decoder written here: every test
// encodes synthetic frames, walks the chunk stream back out, verifies
// every CRC, inflates the frame data, unfilters it and composites the
// subframes onto a canvas. Truecolour means the round trip has to be
// exact — unlike the GIF path there is no palette to hide behind, so a
// single wrong filter byte shows up as a wrong pixel.

{$I Knips.inc}

uses
  Classes,
  Math,
  SysUtils,

  Knips.Export.Apng,
  Knips.Export.Bitmap,
  TestingPascalLibrary,
  ZStream;

type
  TDecodedApngFrame = record
    Sequence: Integer;
    Left: Integer;
    Top: Integer;
    Width: Integer;
    Height: Integer;
    DelayNumerator: Integer;
    DelayDenominator: Integer;
    DisposeOp: Integer;
    BlendOp: Integer;
    // The whole canvas as RGB after this frame was composited.
    Canvas: TBytes;
  end;

  TDecodedApng = record
    SignatureOk: Boolean;
    Width: Integer;
    Height: Integer;
    BitDepth: Integer;
    ColorType: Integer;
    NumFrames: Integer;
    NumPlays: Integer;
    CrcOk: Boolean;
    SequencesOk: Boolean;
    ControlBeforeData: Boolean;
    DataChunks: Integer;
    FirstDataIsIdat: Boolean;
    ChunkOrder: string;
    Frames: array of TDecodedApngFrame;
  end;

  TApngStructureTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSignatureHeaderAndControl;
    procedure TestEveryChunkCrcIsValid;
    procedure TestSequenceNumbersAreContiguous;
    procedure TestFirstFrameCoversTheCanvas;
    procedure TestDisposeAndBlendAreNoneAndSource;
    procedure TestDelaysReachTheFile;
    procedure TestOversizedCanvasesAreRefusedBeforeAllocating;
  end;

  TApngPixelTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTruecolorRoundTripsExactly;
    procedure TestGradientSurvivesWithoutQuantisation;
    procedure TestChangedRectangleIsTight;
    procedure TestUnchangedFrameShrinksToOnePixel;
    procedure TestSubframesCompositeOntoTheCanvas;
  end;

var
  GScratchDirectory: string;

{ ---------------------------------------------------------------- helpers }

function ScratchPath(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GScratchDirectory) + AName;
end;

// Every test deletes the fixture it wrote, but a failed one leaves its
// file behind and an empty directory would survive either way: sweep
// what is left and take the directory with it, the way
// Knips.Recording.Recovery.Test's suites close theirs. One level deep,
// because no fixture here nests a directory.
procedure RemoveScratchDirectory;
var
  Directory: string;
  Search: TSearchRec;
begin
  if GScratchDirectory = '' then
    Exit;
  Directory := IncludeTrailingPathDelimiter(GScratchDirectory);
  if FindFirst(Directory + '*', faAnyFile, Search) = 0 then
    try
      repeat
        if (Search.Attr and faDirectory) = 0 then
          DeleteFile(Directory + Search.Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
  RemoveDir(Directory);
  GScratchDirectory := '';
end;

function LoadFile(const APath: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure FillSolid(var AImage: TBgraImage; ARed, AGreen, ABlue: Byte);
var
  I: Integer;
begin
  I := 0;
  while I < Length(AImage.Pixels) do
  begin
    AImage.Pixels[I + BgraBlueOffset] := ABlue;
    AImage.Pixels[I + BgraGreenOffset] := AGreen;
    AImage.Pixels[I + BgraRedOffset] := ARed;
    AImage.Pixels[I + BgraAlphaOffset] := 255;
    Inc(I, BgraBytesPerPixel);
  end;
end;

procedure SetPixel(var AImage: TBgraImage; AX, AY: Integer;
  ARed, AGreen, ABlue: Byte);
var
  Base: Integer;
begin
  Base := AY * AImage.BytesPerRow + AX * BgraBytesPerPixel;
  AImage.Pixels[Base + BgraBlueOffset] := ABlue;
  AImage.Pixels[Base + BgraGreenOffset] := AGreen;
  AImage.Pixels[Base + BgraRedOffset] := ARed;
  AImage.Pixels[Base + BgraAlphaOffset] := 255;
end;

// Far more distinct colours than any palette could hold, which is what
// makes the exact round trip worth asserting.
procedure FillGradient(var AImage: TBgraImage; ASeed: Integer);
var
  X, Y: Integer;
begin
  for Y := 0 to AImage.Height - 1 do
    for X := 0 to AImage.Width - 1 do
      SetPixel(AImage, X, Y, Byte((X * 5 + ASeed) and $FF),
        Byte((Y * 7 + ASeed * 3) and $FF), Byte((X * Y + ASeed * 11) and $FF));
end;

function ReadBigEndian32(const AData: TBytes; AOffset: Integer): Integer;
begin
  Result := (AData[AOffset] shl 24) or (AData[AOffset + 1] shl 16)
    or (AData[AOffset + 2] shl 8) or AData[AOffset + 3];
end;

function ReadBigEndian16(const AData: TBytes; AOffset: Integer): Integer;
begin
  Result := (AData[AOffset] shl 8) or AData[AOffset + 1];
end;

function Inflate(const ASource: TBytes; AOffset, ALength: Integer): TBytes;
var
  Input: TMemoryStream;
  Decompressor: TDecompressionStream;
  Chunk: TBytes;
  Read, Total: Integer;
begin
  Result := nil;
  Total := 0;
  Input := TMemoryStream.Create;
  try
    if ALength > 0 then
      Input.WriteBuffer(ASource[AOffset], ALength);
    Input.Position := 0;
    Decompressor := TDecompressionStream.Create(Input);
    try
      SetLength(Chunk, 65536);
      repeat
        Read := Decompressor.Read(Chunk[0], Length(Chunk));
        if Read > 0 then
        begin
          SetLength(Result, Total + Read);
          Move(Chunk[0], Result[Total], Read);
          Inc(Total, Read);
        end;
      until Read <= 0;
    finally
      Decompressor.Free;
    end;
  finally
    Input.Free;
  end;
end;

function Paeth(ALeft, AAbove, AAboveLeft: Integer): Integer;
var
  Estimate, DistanceLeft, DistanceAbove, DistanceAboveLeft: Integer;
begin
  Estimate := ALeft + AAbove - AAboveLeft;
  DistanceLeft := Abs(Estimate - ALeft);
  DistanceAbove := Abs(Estimate - AAbove);
  DistanceAboveLeft := Abs(Estimate - AAboveLeft);
  if (DistanceLeft <= DistanceAbove)
    and (DistanceLeft <= DistanceAboveLeft) then
    Result := ALeft
  else if DistanceAbove <= DistanceAboveLeft then
    Result := AAbove
  else
    Result := AAboveLeft;
end;

// PNG's own unfiltering, written from the specification rather than from
// the encoder, so a shared misunderstanding cannot pass the test.
function Unfilter(const ARaw: TBytes; AWidth, AHeight: Integer): TBytes;
var
  X, Y, Stride, Source, Row: Integer;
  FilterType, Left, Above, AboveLeft, Predicted: Integer;
begin
  // A managed result is not initialised on entry; SetLength on it is a
  // read of whatever the caller's variable held.
  Result := nil;
  Stride := AWidth * ApngBytesPerPixel;
  SetLength(Result, Stride * AHeight);
  Source := 0;
  for Y := 0 to AHeight - 1 do
  begin
    FilterType := ARaw[Source];
    Inc(Source);
    Row := Y * Stride;
    for X := 0 to Stride - 1 do
    begin
      if X >= ApngBytesPerPixel then
        Left := Result[Row + X - ApngBytesPerPixel]
      else
        Left := 0;
      if Y > 0 then
        Above := Result[Row - Stride + X]
      else
        Above := 0;
      if (Y > 0) and (X >= ApngBytesPerPixel) then
        AboveLeft := Result[Row - Stride + X - ApngBytesPerPixel]
      else
        AboveLeft := 0;
      case FilterType of
        1: Predicted := Left;
        2: Predicted := Above;
        3: Predicted := (Left + Above) div 2;
        4: Predicted := Paeth(Left, Above, AboveLeft);
      else
        Predicted := 0;
      end;
      Result[Row + X] := Byte((ARaw[Source] + Predicted) and $FF);
      Inc(Source);
    end;
  end;
end;

function DecodeApng(const APath: string): TDecodedApng;
var
  Data, Payload, Pixels, Canvas: TBytes;
  Offset, Length_, I, X, Y, DataOffset, DataLength: Integer;
  ChunkType: string;
  Crc: Cardinal;
  Expected: Cardinal;
  Pending: TDecodedApngFrame;
  HasPending: Boolean;
  NextSequence: Integer;
  Signature: array[0..7] of Byte;
  Frame: TDecodedApngFrame;
begin
  Result := Default(TDecodedApng);
  Result.CrcOk := True;
  Result.SequencesOk := True;
  Data := LoadFile(APath);
  Signature[0] := $89;
  Signature[1] := $50;
  Signature[2] := $4E;
  Signature[3] := $47;
  Signature[4] := $0D;
  Signature[5] := $0A;
  Signature[6] := $1A;
  Signature[7] := $0A;
  Result.SignatureOk := Length(Data) > 8;
  for I := 0 to 7 do
    if Data[I] <> Signature[I] then
      Result.SignatureOk := False;

  HasPending := False;
  NextSequence := 0;
  Pending := Default(TDecodedApngFrame);
  Offset := 8;
  while Offset + 8 <= Length(Data) do
  begin
    Length_ := ReadBigEndian32(Data, Offset);
    SetString(ChunkType, PAnsiChar(@Data[Offset + 4]), 4);
    Result.ChunkOrder := Result.ChunkOrder + ChunkType + ' ';
    // The CRC covers the type and the data, not the length.
    Crc := ApngCrc32(Data[Offset + 4], Length_ + 4);
    Expected := Cardinal(ReadBigEndian32(Data, Offset + 8 + Length_));
    if Crc <> Expected then
      Result.CrcOk := False;

    if ChunkType = 'IHDR' then
    begin
      Result.Width := ReadBigEndian32(Data, Offset + 8);
      Result.Height := ReadBigEndian32(Data, Offset + 12);
      Result.BitDepth := Data[Offset + 16];
      Result.ColorType := Data[Offset + 17];
      SetLength(Canvas, Result.Width * Result.Height * ApngBytesPerPixel);
    end
    else if ChunkType = 'acTL' then
    begin
      Result.NumFrames := ReadBigEndian32(Data, Offset + 8);
      Result.NumPlays := ReadBigEndian32(Data, Offset + 12);
      Result.ControlBeforeData := Result.DataChunks = 0;
    end
    else if ChunkType = 'fcTL' then
    begin
      Pending.Sequence := ReadBigEndian32(Data, Offset + 8);
      if Pending.Sequence <> NextSequence then
        Result.SequencesOk := False;
      Inc(NextSequence);
      Pending.Width := ReadBigEndian32(Data, Offset + 12);
      Pending.Height := ReadBigEndian32(Data, Offset + 16);
      Pending.Left := ReadBigEndian32(Data, Offset + 20);
      Pending.Top := ReadBigEndian32(Data, Offset + 24);
      Pending.DelayNumerator := ReadBigEndian16(Data, Offset + 28);
      Pending.DelayDenominator := ReadBigEndian16(Data, Offset + 30);
      Pending.DisposeOp := Data[Offset + 32];
      Pending.BlendOp := Data[Offset + 33];
      HasPending := True;
    end
    else if (ChunkType = 'IDAT') or (ChunkType = 'fdAT') then
    begin
      if Result.DataChunks = 0 then
        Result.FirstDataIsIdat := ChunkType = 'IDAT';
      Inc(Result.DataChunks);
      DataOffset := Offset + 8;
      DataLength := Length_;
      if ChunkType = 'fdAT' then
      begin
        if ReadBigEndian32(Data, DataOffset) <> NextSequence then
          Result.SequencesOk := False;
        Inc(NextSequence);
        Inc(DataOffset, 4);
        Dec(DataLength, 4);
      end;
      Payload := Inflate(Data, DataOffset, DataLength);
      Pixels := Unfilter(Payload, Pending.Width, Pending.Height);
      // dispose NONE + blend SOURCE: the canvas persists and the
      // subframe's pixels simply replace what is under them.
      for Y := 0 to Pending.Height - 1 do
        for X := 0 to Pending.Width * ApngBytesPerPixel - 1 do
          Canvas[((Pending.Top + Y) * Result.Width + Pending.Left)
            * ApngBytesPerPixel + X] := Pixels[Y * Pending.Width
            * ApngBytesPerPixel + X];
      Frame := Pending;
      SetLength(Frame.Canvas, Length(Canvas));
      if Length(Canvas) > 0 then
        Move(Canvas[0], Frame.Canvas[0], Length(Canvas));
      SetLength(Result.Frames, Length(Result.Frames) + 1);
      Result.Frames[High(Result.Frames)] := Frame;
      HasPending := False;
    end;

    Inc(Offset, 12 + Length_);
    if ChunkType = 'IEND' then
      Break;
  end;
  if HasPending then
    Result.SequencesOk := False;
end;

// Writes AImages as an APNG with ADelays and returns the path.
function EncodeImages(const AName: string; const AImages: array of TBgraImage;
  const ADelays: array of Integer; ADenominator: Integer): string;
var
  Encoder: TApngEncoder;
  Error: string;
  I: Integer;
begin
  Result := ScratchPath(AName);
  Encoder := TApngEncoder.Create(AImages[0].Width, AImages[0].Height,
    ADenominator);
  try
    if not Encoder.Open(Result, Error) then
      raise Exception.Create(Error);
    for I := 0 to High(AImages) do
      if not Encoder.AddFrame(@AImages[I].Pixels[0], AImages[I].BytesPerRow,
        ADelays[I], Error) then
        raise Exception.Create(Error);
    if not Encoder.Finish(Error) then
      raise Exception.Create(Error);
  finally
    Encoder.Free;
  end;
end;

function CanvasByte(const AApng: TDecodedApng; AFrame, AX, AY,
  AChannel: Integer): Integer;
begin
  Result := AApng.Frames[AFrame].Canvas[(AY * AApng.Width + AX)
    * ApngBytesPerPixel + AChannel];
end;

{ TApngStructureTests }

procedure TApngStructureTests.SetupTests;
begin
  Test('the file is a PNG whose header and acTL come before any frame',
    TestSignatureHeaderAndControl);
  Test('every chunk carries a valid CRC', TestEveryChunkCrcIsValid);
  Test('fcTL and fdAT share one contiguous sequence',
    TestSequenceNumbersAreContiguous);
  Test('the first frame covers the whole canvas',
    TestFirstFrameCoversTheCanvas);
  Test('frames dispose NONE and blend SOURCE',
    TestDisposeAndBlendAreNoneAndSource);
  Test('per-frame delays reach the file with their denominator',
    TestDelaysReachTheFile);
  Test('an impossible canvas is refused rather than allocated',
    TestOversizedCanvasesAreRefusedBeforeAllocating);
end;

procedure TApngStructureTests.TestSignatureHeaderAndControl;
var
  First, Second: TBgraImage;
  Apng: TDecodedApng;
  Path: string;
begin
  BgraImageResize(First, 8, 6);
  BgraImageResize(Second, 8, 6);
  FillSolid(First, 255, 0, 0);
  FillSolid(Second, 0, 0, 255);
  Path := EncodeImages('header.apng', [First, Second], [5, 5], 100);
  try
    Apng := DecodeApng(Path);
    Expect<Boolean>(Apng.SignatureOk).ToBe(True);
    Expect<Integer>(Apng.Width).ToBe(8);
    Expect<Integer>(Apng.Height).ToBe(6);
    Expect<Integer>(Apng.BitDepth).ToBe(8);
    Expect<Integer>(Apng.ColorType).ToBe(2);
    Expect<Integer>(Apng.NumFrames).ToBe(2);
    Expect<Integer>(Apng.NumPlays).ToBe(0);
    Expect<Boolean>(Apng.ControlBeforeData).ToBe(True);
    Expect<Boolean>(Apng.FirstDataIsIdat).ToBe(True);
    Expect<Integer>(Apng.DataChunks).ToBe(2);
    Expect<string>(Trim(Apng.ChunkOrder))
      .ToBe('IHDR acTL fcTL IDAT fcTL fdAT IEND');
  finally
    DeleteFile(Path);
  end;
end;

procedure TApngStructureTests.TestEveryChunkCrcIsValid;
var
  Images: array[0..2] of TBgraImage;
  Apng: TDecodedApng;
  Path: string;
  I: Integer;
begin
  for I := 0 to 2 do
  begin
    BgraImageResize(Images[I], 24, 18);
    FillGradient(Images[I], I * 9);
  end;
  Path := EncodeImages('crc.apng', Images, [5, 5, 5], 100);
  try
    Apng := DecodeApng(Path);
    // acTL is patched after the fact, so its CRC is the one most likely
    // to be wrong; the check covers every chunk anyway.
    Expect<Boolean>(Apng.CrcOk).ToBe(True);
    Expect<Integer>(Apng.NumFrames).ToBe(3);
  finally
    DeleteFile(Path);
  end;
end;

procedure TApngStructureTests.TestSequenceNumbersAreContiguous;
var
  Images: array[0..3] of TBgraImage;
  Apng: TDecodedApng;
  Path: string;
  I: Integer;
begin
  for I := 0 to 3 do
  begin
    BgraImageResize(Images[I], 16, 16);
    FillGradient(Images[I], I * 20);
  end;
  Path := EncodeImages('sequence.apng', Images, [5, 5, 5, 5], 100);
  try
    Apng := DecodeApng(Path);
    Expect<Boolean>(Apng.SequencesOk).ToBe(True);
    Expect<Integer>(Apng.Frames[0].Sequence).ToBe(0);
    Expect<Integer>(Apng.Frames[1].Sequence).ToBe(1);
    Expect<Integer>(Apng.Frames[2].Sequence).ToBe(3);
    Expect<Integer>(Apng.Frames[3].Sequence).ToBe(5);
  finally
    DeleteFile(Path);
  end;
end;

procedure TApngStructureTests.TestFirstFrameCoversTheCanvas;
var
  First, Second: TBgraImage;
  Apng: TDecodedApng;
  Path: string;
begin
  BgraImageResize(First, 20, 12);
  BgraImageResize(Second, 20, 12);
  FillSolid(First, 10, 20, 30);
  FillSolid(Second, 10, 20, 30);
  SetPixel(Second, 8, 5, 200, 100, 50);
  Path := EncodeImages('first.apng', [First, Second], [5, 5], 100);
  try
    Apng := DecodeApng(Path);
    Expect<Integer>(Apng.Frames[0].Left).ToBe(0);
    Expect<Integer>(Apng.Frames[0].Top).ToBe(0);
    Expect<Integer>(Apng.Frames[0].Width).ToBe(20);
    Expect<Integer>(Apng.Frames[0].Height).ToBe(12);
  finally
    DeleteFile(Path);
  end;
end;

procedure TApngStructureTests.TestDisposeAndBlendAreNoneAndSource;
var
  Images: array[0..2] of TBgraImage;
  Apng: TDecodedApng;
  Path: string;
  I: Integer;
begin
  for I := 0 to 2 do
  begin
    BgraImageResize(Images[I], 12, 9);
    FillGradient(Images[I], I * 30);
  end;
  Path := EncodeImages('ops.apng', Images, [5, 5, 5], 100);
  try
    Apng := DecodeApng(Path);
    for I := 0 to 2 do
    begin
      Expect<Integer>(Apng.Frames[I].DisposeOp).ToBe(ApngDisposeOpNone);
      Expect<Integer>(Apng.Frames[I].BlendOp).ToBe(ApngBlendOpSource);
    end;
  finally
    DeleteFile(Path);
  end;
end;

procedure TApngStructureTests.TestDelaysReachTheFile;
var
  Images: array[0..2] of TBgraImage;
  Apng: TDecodedApng;
  Path: string;
  I: Integer;
begin
  for I := 0 to 2 do
  begin
    BgraImageResize(Images[I], 8, 8);
    FillSolid(Images[I], Byte(20 * I), 40, 60);
  end;
  Path := EncodeImages('delays.apng', Images, [50, 33, 1000], 1000);
  try
    Apng := DecodeApng(Path);
    Expect<Integer>(Apng.Frames[0].DelayNumerator).ToBe(50);
    Expect<Integer>(Apng.Frames[1].DelayNumerator).ToBe(33);
    Expect<Integer>(Apng.Frames[2].DelayNumerator).ToBe(1000);
    for I := 0 to 2 do
      Expect<Integer>(Apng.Frames[I].DelayDenominator).ToBe(1000);
  finally
    DeleteFile(Path);
  end;
end;

// Create allocates nothing, so a canvas the encoder could never hold is
// refused by Open with a message rather than by SetLength computing
// width x height x 3 in 32-bit arithmetic first.
procedure TApngStructureTests.TestOversizedCanvasesAreRefusedBeforeAllocating;
var
  Encoder: TApngEncoder;
  Error: string;
  Path: string;
begin
  Path := ScratchPath('oversize.apng');
  Encoder := TApngEncoder.Create(ApngMaxDimension + 1, 8, 100);
  try
    Expect<Boolean>(Encoder.Open(Path, Error)).ToBe(False);
    Expect<Boolean>(Pos('pixels on a side', Error) > 0).ToBe(True);
  finally
    Encoder.Free;
  end;
  // Inside the per-side bound, but 32767 x 32767 x 3 overflows a 32-bit
  // index: the byte budget catches it in Int64 before anything is sized.
  Encoder := TApngEncoder.Create(ApngMaxDimension, ApngMaxDimension, 100);
  try
    Expect<Boolean>(Encoder.Open(Path, Error)).ToBe(False);
    Expect<Boolean>(Pos('MB a frame', Error) > 0).ToBe(True);
  finally
    Encoder.Free;
  end;
  Encoder := TApngEncoder.Create(0, 0, 100);
  try
    Expect<Boolean>(Encoder.Open(Path, Error)).ToBe(False);
    Expect<Boolean>(Pos('empty', Error) > 0).ToBe(True);
  finally
    Encoder.Free;
  end;
  Expect<Boolean>(FileExists(Path)).ToBe(False);
end;

{ TApngPixelTests }

procedure TApngPixelTests.SetupTests;
begin
  Test('solid frames decode back to their exact colours',
    TestTruecolorRoundTripsExactly);
  Test('a gradient survives byte for byte, with no palette in the way',
    TestGradientSurvivesWithoutQuantisation);
  Test('a changed frame repaints exactly the changed rectangle',
    TestChangedRectangleIsTight);
  Test('an unchanged frame is written as a single pixel',
    TestUnchangedFrameShrinksToOnePixel);
  Test('subframes composite onto the canvas without disturbing it',
    TestSubframesCompositeOntoTheCanvas);
end;

procedure TApngPixelTests.TestTruecolorRoundTripsExactly;
var
  Images: array[0..2] of TBgraImage;
  Apng: TDecodedApng;
  Path: string;
  I, X, Y: Integer;
  Red, Green, Blue: array[0..2] of Byte;
begin
  Red[0] := 255; Green[0] := 0; Blue[0] := 0;
  Red[1] := 0; Green[1] := 255; Blue[1] := 0;
  Red[2] := 3; Green[2] := 7; Blue[2] := 251;
  for I := 0 to 2 do
  begin
    BgraImageResize(Images[I], 5, 3);
    FillSolid(Images[I], Red[I], Green[I], Blue[I]);
  end;
  Path := EncodeImages('solid.apng', Images, [5, 5, 5], 100);
  try
    Apng := DecodeApng(Path);
    Expect<Integer>(Length(Apng.Frames)).ToBe(3);
    for I := 0 to 2 do
      for Y := 0 to 2 do
        for X := 0 to 4 do
        begin
          Expect<Integer>(CanvasByte(Apng, I, X, Y, 0)).ToBe(Red[I]);
          Expect<Integer>(CanvasByte(Apng, I, X, Y, 1)).ToBe(Green[I]);
          Expect<Integer>(CanvasByte(Apng, I, X, Y, 2)).ToBe(Blue[I]);
        end;
  finally
    DeleteFile(Path);
  end;
end;

procedure TApngPixelTests.TestGradientSurvivesWithoutQuantisation;
var
  Images: array[0..1] of TBgraImage;
  Apng: TDecodedApng;
  Path: string;
  I, X, Y, Base, Worst: Integer;
begin
  for I := 0 to 1 do
  begin
    BgraImageResize(Images[I], 40, 30);
    FillGradient(Images[I], I * 17);
  end;
  Path := EncodeImages('gradient.apng', Images, [5, 5], 100);
  try
    Apng := DecodeApng(Path);
    Worst := 0;
    for I := 0 to 1 do
      for Y := 0 to 29 do
        for X := 0 to 39 do
        begin
          Base := Y * Images[I].BytesPerRow + X * BgraBytesPerPixel;
          Worst := Max(Worst, Abs(CanvasByte(Apng, I, X, Y, 0)
            - Images[I].Pixels[Base + BgraRedOffset]));
          Worst := Max(Worst, Abs(CanvasByte(Apng, I, X, Y, 1)
            - Images[I].Pixels[Base + BgraGreenOffset]));
          Worst := Max(Worst, Abs(CanvasByte(Apng, I, X, Y, 2)
            - Images[I].Pixels[Base + BgraBlueOffset]));
        end;
    // This is the whole reason APNG is here: no quantisation at all.
    Expect<Integer>(Worst).ToBe(0);
  finally
    DeleteFile(Path);
  end;
end;

procedure TApngPixelTests.TestChangedRectangleIsTight;
var
  First, Second: TBgraImage;
  Apng: TDecodedApng;
  Path: string;
  X, Y: Integer;
begin
  BgraImageResize(First, 16, 12);
  FillSolid(First, 0, 0, 0);
  BgraImageResize(Second, 16, 12);
  FillSolid(Second, 0, 0, 0);
  for Y := 4 to 6 do
    for X := 3 to 9 do
      SetPixel(Second, X, Y, 255, 255, 255);
  Path := EncodeImages('rect.apng', [First, Second], [5, 5], 100);
  try
    Apng := DecodeApng(Path);
    Expect<Integer>(Apng.Frames[1].Left).ToBe(3);
    Expect<Integer>(Apng.Frames[1].Top).ToBe(4);
    Expect<Integer>(Apng.Frames[1].Width).ToBe(7);
    Expect<Integer>(Apng.Frames[1].Height).ToBe(3);
    Expect<Integer>(CanvasByte(Apng, 1, 3, 4, 0)).ToBe(255);
    Expect<Integer>(CanvasByte(Apng, 1, 9, 6, 0)).ToBe(255);
    Expect<Integer>(CanvasByte(Apng, 1, 2, 4, 0)).ToBe(0);
    Expect<Integer>(CanvasByte(Apng, 1, 10, 6, 0)).ToBe(0);
  finally
    DeleteFile(Path);
  end;
end;

procedure TApngPixelTests.TestUnchangedFrameShrinksToOnePixel;
var
  First, Second: TBgraImage;
  Apng: TDecodedApng;
  Path: string;
begin
  BgraImageResize(First, 16, 16);
  FillSolid(First, 10, 20, 30);
  BgraImageResize(Second, 16, 16);
  FillSolid(Second, 10, 20, 30);
  Path := EncodeImages('static.apng', [First, Second], [5, 5], 100);
  try
    Apng := DecodeApng(Path);
    Expect<Integer>(Apng.Frames[0].Width).ToBe(16);
    Expect<Integer>(Apng.Frames[1].Width).ToBe(1);
    Expect<Integer>(Apng.Frames[1].Height).ToBe(1);
    // The canvas must be exactly where it was.
    Expect<Integer>(CanvasByte(Apng, 1, 15, 15, 2)).ToBe(30);
    Expect<Integer>(CanvasByte(Apng, 1, 0, 0, 1)).ToBe(20);
  finally
    DeleteFile(Path);
  end;
end;

// Three frames, each moving a small block, all composited onto a canvas
// that is never cleared: the trail every earlier block left has to still
// be there, which is what dispose NONE means.
procedure TApngPixelTests.TestSubframesCompositeOntoTheCanvas;
var
  Images: array[0..2] of TBgraImage;
  Apng: TDecodedApng;
  Path: string;
  I, X, Y: Integer;
begin
  for I := 0 to 2 do
  begin
    BgraImageResize(Images[I], 30, 10);
    FillSolid(Images[I], 5, 5, 5);
    for Y := 0 to 9 do
      for X := 0 to I * 8 + 3 do
        SetPixel(Images[I], X, Y, 250, 240, 230);
  end;
  Path := EncodeImages('composite.apng', Images, [5, 5, 5], 100);
  try
    Apng := DecodeApng(Path);
    // The last frame's rectangle only covers what it changed.
    Expect<Integer>(Apng.Frames[2].Left).ToBe(12);
    Expect<Integer>(Apng.Frames[2].Width).ToBe(8);
    for Y := 0 to 9 do
      for X := 0 to 29 do
        if X <= 19 then
          Expect<Integer>(CanvasByte(Apng, 2, X, Y, 0)).ToBe(250)
        else
          Expect<Integer>(CanvasByte(Apng, 2, X, Y, 0)).ToBe(5);
  finally
    DeleteFile(Path);
  end;
end;

begin
  // Pid-qualified, like Knips.Recording.Recovery.Test's directory: two
  // runs of this suite at once otherwise write the same fixture paths
  // and read each other's half-written files.
  GScratchDirectory := IncludeTrailingPathDelimiter(GetTempDir)
    + 'knips-apng-test-' + IntToStr(GetProcessID);
  ForceDirectories(GScratchDirectory);
  try
    TestRunnerProgram.AddSuite(TApngStructureTests.Create('APNG structure'));
    TestRunnerProgram.AddSuite(TApngPixelTests.Create('APNG pixels'));
    TestRunnerProgram.Run;
  finally
    RemoveScratchDirectory;
  end;
  ExitCode := TestResultToExitCode;
end.

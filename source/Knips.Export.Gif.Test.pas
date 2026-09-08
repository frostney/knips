program Knips.Export.Gif.Test;

// The GIF encoder is checked against a decoder written here rather than
// against golden bytes: every test encodes synthetic frames, parses the
// blocks back out, LZW-decodes them and composites them onto a canvas.
// That is the only way to prove the LZW code-width dance and the
// changed-rectangle frames without a real GIF viewer in the loop.

{$I Knips.inc}

uses
  Classes,
  Math,
  SysUtils,
  Types,

  Knips.Export.Bitmap,
  Knips.Export.Gif,
  TestingPascalLibrary;

type
  TDecodedFrame = record
    Left: Integer;
    Top: Integer;
    Width: Integer;
    Height: Integer;
    DelayCentiseconds: Integer;
    Disposal: Integer;
    HasTransparency: Boolean;
    TransparentIndex: Integer;
    // Pixels inside the rectangle left untouched because they carried
    // the transparent index.
    TransparentPixels: Integer;
    HasLocalTable: Boolean;
    MinCodeSize: Integer;
    // The whole canvas as palette indices after this frame was drawn.
    Canvas: TBytes;
  end;

  TDecodedGif = record
    Signature: string;
    Width: Integer;
    Height: Integer;
    TableEntries: Integer;
    Palette: array[0..255] of TGifColor;
    HasLoopExtension: Boolean;
    LoopCount: Integer;
    Frames: array of TDecodedFrame;
  end;

  TGifQuantizerTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEmptyQuantizerYieldsOneColor;
    procedure TestSolidColorYieldsExactlyThatColor;
    procedure TestFourColorsSurviveIntact;
    procedure TestManyColorsAreCappedAtTheLimit;
    procedure TestSmallLimitIsHonoured;
    procedure TestOrdinaryContentStaysExact;
    procedure TestOverflowFallsBackToTheCellHistogram;
    procedure TestLateFrameStillReachesThePalette;
    procedure TestCellSumsSurviveAThirtyTwoBitOverflow;
  end;

  TGifPaletteSamplerTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestFirstFrameIsAlwaysSampled;
    procedure TestHonestEstimateHitsTheSampleTarget;
    procedure TestLyingEstimateStillSpreadsOverAShortStream;
    procedure TestStrideDoublesOncePerPhase;
    procedure TestLongStreamIsThinnedNotTruncated;
    procedure TestMissingEstimateStartsDenseAndThins;
  end;

  TGifStructureTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestHeaderAndLoopExtension;
    procedure TestColorTableIsAPowerOfTwo;
    procedure TestMinimumCodeSizeIsAtLeastTwo;
    procedure TestDelaysAreClampedAndWritten;
  end;

  TGifPixelTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSolidFramesRoundTripExactly;
    procedure TestUnchangedFrameShrinksToOnePixel;
    procedure TestChangedRectangleCoversTheChange;
    procedure TestDenseChangesStayOpaque;
    procedure TestScatteredChangesLeaveTheRestTransparent;
    procedure TestGradientStaysCloseToTheSource;
    procedure TestLargeFrameSurvivesADictionaryReset;
  end;

var
  GScratchDirectory: string;

{ ---------------------------------------------------------------- helpers }

function ScratchPath(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GScratchDirectory) + AName;
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

// Fills a BGRA image with one colour.
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

// A gradient with far more than 256 distinct colours.
procedure FillGradient(var AImage: TBgraImage);
var
  X, Y: Integer;
begin
  for Y := 0 to AImage.Height - 1 do
    for X := 0 to AImage.Width - 1 do
      SetPixel(AImage, X, Y, Byte(X * 255 div Max(1, AImage.Width - 1)),
        Byte(Y * 255 div Max(1, AImage.Height - 1)),
        Byte((X + Y) * 255 div Max(1, AImage.Width + AImage.Height - 2)));
end;

{ ---------------------------------------------------------------- decoder }

type
  TBitReader = record
    Data: TBytes;
    Position: Integer;
    Bits: UInt32;
    Count: Integer;
  end;

function ReadCode(var AReader: TBitReader; ASize: Integer): Integer;
begin
  while AReader.Count < ASize do
  begin
    if AReader.Position >= Length(AReader.Data) then
      Exit(-1);
    AReader.Bits := AReader.Bits
      or (UInt32(AReader.Data[AReader.Position]) shl AReader.Count);
    Inc(AReader.Position);
    Inc(AReader.Count, 8);
  end;
  Result := Integer(AReader.Bits and ((UInt32(1) shl ASize) - 1));
  AReader.Bits := AReader.Bits shr ASize;
  Dec(AReader.Count, ASize);
end;

// Decodes the LZW stream of one image block into APixels (AWidth *
// AHeight palette indices). Raises on a malformed stream so a broken
// encoder shows up as a failing test rather than silent zeros.
procedure DecodeLzw(const AData: TBytes; AMinCodeSize: Integer;
  var APixels: TBytes; AExpected: Integer);
var
  Reader: TBitReader;
  Prefix: array[0..4095] of Integer;
  Suffix: array[0..4095] of Byte;
  FirstByte: array[0..4095] of Byte;
  Stack: array[0..4095] of Byte;
  ClearCode, EndCode, CodeSize, NextCode, Code, OldCode, Current: Integer;
  StackTop, Written, I: Integer;
  Character: Byte;
begin
  SetLength(APixels, AExpected);
  Reader.Data := AData;
  Reader.Position := 0;
  Reader.Bits := 0;
  Reader.Count := 0;
  ClearCode := 1 shl AMinCodeSize;
  EndCode := ClearCode + 1;
  for I := 0 to ClearCode - 1 do
  begin
    Prefix[I] := -1;
    Suffix[I] := Byte(I);
    FirstByte[I] := Byte(I);
  end;
  CodeSize := AMinCodeSize + 1;
  NextCode := EndCode + 1;
  OldCode := -1;
  Written := 0;
  Character := 0;
  repeat
    Code := ReadCode(Reader, CodeSize);
    if Code < 0 then
      raise Exception.Create('LZW stream ended without an end code');
    if Code = EndCode then
      Break;
    if Code = ClearCode then
    begin
      CodeSize := AMinCodeSize + 1;
      NextCode := EndCode + 1;
      OldCode := -1;
      Continue;
    end;
    if OldCode < 0 then
    begin
      if Code >= ClearCode then
        raise Exception.Create('first LZW code is not a literal');
      if Written >= AExpected then
        raise Exception.Create('LZW stream is longer than the image');
      APixels[Written] := Byte(Code);
      Inc(Written);
      Character := Byte(Code);
      OldCode := Code;
      Continue;
    end;

    StackTop := 0;
    if Code < NextCode then
      Current := Code
    else if Code = NextCode then
    begin
      Stack[StackTop] := FirstByte[OldCode];
      Inc(StackTop);
      Current := OldCode;
    end
    else
      raise Exception.Create('LZW code is past the end of the table');
    while Current >= ClearCode do
    begin
      Stack[StackTop] := Suffix[Current];
      Inc(StackTop);
      Current := Prefix[Current];
    end;
    Stack[StackTop] := Byte(Current);
    Inc(StackTop);
    Character := Byte(Current);
    for I := StackTop - 1 downto 0 do
    begin
      if Written >= AExpected then
        raise Exception.Create('LZW stream is longer than the image');
      APixels[Written] := Stack[I];
      Inc(Written);
    end;

    if NextCode < 4096 then
    begin
      Prefix[NextCode] := OldCode;
      Suffix[NextCode] := Character;
      FirstByte[NextCode] := FirstByte[OldCode];
      Inc(NextCode);
      if (NextCode >= (1 shl CodeSize)) and (CodeSize < 12) then
        Inc(CodeSize);
    end;
    OldCode := Code;
  until False;
  if Written <> AExpected then
    raise Exception.CreateFmt('LZW produced %d of %d pixels',
      [Written, AExpected]);
end;

function DecodeGif(const APath: string): TDecodedGif;
var
  Data: TBytes;
  Position, I, Flags, BlockId, BlockLength, ExtensionLabel: Integer;
  PendingDelay, PendingDisposal, PendingTransparent: Integer;
  PendingHasTransparency: Boolean;
  Canvas: TBytes;
  Frame: TDecodedFrame;
  Payload, Pixels: TBytes;
  PayloadLength, X, Y: Integer;
  Identifier: string;

  function ReadByte: Integer;
  begin
    if Position >= Length(Data) then
      raise Exception.Create('GIF ended early');
    Result := Data[Position];
    Inc(Position);
  end;

  function ReadWord: Integer;
  begin
    Result := ReadByte;
    Result := Result or (ReadByte shl 8);
  end;

begin
  Result := Default(TDecodedGif);
  Data := LoadFile(APath);
  if Length(Data) < 13 then
    raise Exception.Create('GIF is too short to hold a header');
  SetString(Result.Signature, PAnsiChar(@Data[0]), 6);
  Position := 6;
  Result.Width := ReadWord;
  Result.Height := ReadWord;
  Flags := ReadByte;
  ReadByte;
  ReadByte;
  if (Flags and $80) <> 0 then
  begin
    Result.TableEntries := 2 shl (Flags and $07);
    for I := 0 to Result.TableEntries - 1 do
    begin
      Result.Palette[I].Red := Byte(ReadByte);
      Result.Palette[I].Green := Byte(ReadByte);
      Result.Palette[I].Blue := Byte(ReadByte);
    end;
  end;

  SetLength(Canvas, Result.Width * Result.Height);
  PendingDelay := 0;
  PendingDisposal := 0;
  PendingTransparent := -1;
  PendingHasTransparency := False;
  repeat
    BlockId := ReadByte;
    case BlockId of
      $3B:
        Break;
      $21:
        begin
          ExtensionLabel := ReadByte;
          if ExtensionLabel = $F9 then
          begin
            BlockLength := ReadByte;
            if BlockLength <> 4 then
              raise Exception.Create('graphic control block is not 4 bytes');
            Flags := ReadByte;
            PendingDisposal := (Flags shr 2) and $07;
            PendingHasTransparency := (Flags and $01) <> 0;
            PendingDelay := ReadWord;
            PendingTransparent := ReadByte;
            if ReadByte <> 0 then
              raise Exception.Create('graphic control block is not terminated');
          end
          else if ExtensionLabel = $FF then
          begin
            BlockLength := ReadByte;
            SetString(Identifier, PAnsiChar(@Data[Position]), BlockLength);
            Inc(Position, BlockLength);
            repeat
              BlockLength := ReadByte;
              if BlockLength = 0 then
                Break;
              if (Identifier = 'NETSCAPE2.0') and (BlockLength = 3)
                and (Data[Position] = 1) then
              begin
                Result.HasLoopExtension := True;
                Result.LoopCount := Data[Position + 1]
                  or (Data[Position + 2] shl 8);
              end;
              Inc(Position, BlockLength);
            until False;
          end
          else
            repeat
              BlockLength := ReadByte;
              Inc(Position, BlockLength);
            until BlockLength = 0;
        end;
      $2C:
        begin
          Frame := Default(TDecodedFrame);
          Frame.Left := ReadWord;
          Frame.Top := ReadWord;
          Frame.Width := ReadWord;
          Frame.Height := ReadWord;
          Flags := ReadByte;
          Frame.HasLocalTable := (Flags and $80) <> 0;
          if Frame.HasLocalTable then
            Inc(Position, 3 * (2 shl (Flags and $07)));
          Frame.MinCodeSize := ReadByte;
          Frame.DelayCentiseconds := PendingDelay;
          Frame.Disposal := PendingDisposal;
          Frame.HasTransparency := PendingHasTransparency;
          Frame.TransparentIndex := PendingTransparent;
          SetLength(Payload, 0);
          PayloadLength := 0;
          repeat
            BlockLength := ReadByte;
            if BlockLength = 0 then
              Break;
            SetLength(Payload, PayloadLength + BlockLength);
            Move(Data[Position], Payload[PayloadLength], BlockLength);
            Inc(PayloadLength, BlockLength);
            Inc(Position, BlockLength);
          until False;
          DecodeLzw(Payload, Frame.MinCodeSize, Pixels,
            Frame.Width * Frame.Height);
          // Disposal 1 leaves the canvas in place and a transparent
          // pixel leaves what was already there, so compositing is just
          // "write everything that is not the transparent index".
          for Y := 0 to Frame.Height - 1 do
            for X := 0 to Frame.Width - 1 do
              if Frame.HasTransparency
                and (Pixels[Y * Frame.Width + X] = Frame.TransparentIndex) then
                Inc(Frame.TransparentPixels)
              else
                Canvas[(Frame.Top + Y) * Result.Width + Frame.Left + X] :=
                  Pixels[Y * Frame.Width + X];
          SetLength(Frame.Canvas, Length(Canvas));
          if Length(Canvas) > 0 then
            Move(Canvas[0], Frame.Canvas[0], Length(Canvas));
          SetLength(Result.Frames, Length(Result.Frames) + 1);
          Result.Frames[High(Result.Frames)] := Frame;
          PendingDelay := 0;
          PendingDisposal := 0;
          PendingTransparent := -1;
          PendingHasTransparency := False;
        end;
    else
      raise Exception.CreateFmt('unexpected GIF block 0x%.2x at %d',
        [BlockId, Position - 1]);
    end;
  until False;
end;

function CanvasColor(const AGif: TDecodedGif; AFrame, AX,
  AY: Integer): TGifColor;
begin
  Result := AGif.Palette[AGif.Frames[AFrame].Canvas[AY * AGif.Width + AX]];
end;

{ ------------------------------------------------------------- encode-all }

// Encodes a list of images with one delay each, using a palette built
// from every image. Returns the path it wrote.
function EncodeImages(const AName: string; const AImages: array of TBgraImage;
  const ADelays: array of Integer; ADither: Boolean;
  AMaxColors: Integer): string;
var
  Quantizer: TGifQuantizer;
  Palette: TGifPalette;
  Encoder: TGifEncoder;
  I: Integer;
  Error: string;
begin
  Result := ScratchPath(AName);
  Quantizer := TGifQuantizer.Create;
  try
    for I := 0 to High(AImages) do
      Quantizer.SampleFrame(@AImages[I].Pixels[0], AImages[I].BytesPerRow,
        AImages[I].Width, AImages[I].Height);
    Palette := Quantizer.BuildPalette(AMaxColors);
  finally
    Quantizer.Free;
  end;
  Encoder := TGifEncoder.Create(AImages[0].Width, AImages[0].Height, Palette,
    ADither);
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

{ TGifQuantizerTests }

procedure TGifQuantizerTests.SetupTests;
begin
  Test('an unsampled quantiser still yields a usable palette',
    TestEmptyQuantizerYieldsOneColor);
  Test('one solid colour becomes exactly one palette entry',
    TestSolidColorYieldsExactlyThatColor);
  Test('four distinct colours survive median cut intact',
    TestFourColorsSurviveIntact);
  Test('a gradient is capped at 256 colours',
    TestManyColorsAreCappedAtTheLimit);
  Test('a frame of ordinary content is counted colour by colour',
    TestOrdinaryContentStaysExact);
  Test('past the cap the histogram falls back to 6-bit cells',
    TestOverflowFallsBackToTheCellHistogram);
  Test('a smaller colour limit is honoured', TestSmallLimitIsHonoured);
  Test('a colour that first appears after 8 M sampled pixels still '
    + 'reaches the palette', TestLateFrameStillReachesThePalette);
  Test('a cell past 2^32 in its channel sums still averages correctly',
    TestCellSumsSurviveAThirtyTwoBitOverflow);
end;

procedure TGifQuantizerTests.TestEmptyQuantizerYieldsOneColor;
var
  Quantizer: TGifQuantizer;
  Palette: TGifPalette;
begin
  Quantizer := TGifQuantizer.Create;
  try
    Expect<Boolean>(Quantizer.IsEmpty).ToBe(True);
    Palette := Quantizer.BuildPalette(GifMaxColors);
    Expect<Integer>(Palette.Count).ToBe(1);
  finally
    Quantizer.Free;
  end;
end;

procedure TGifQuantizerTests.TestSolidColorYieldsExactlyThatColor;
var
  Image: TBgraImage;
  Quantizer: TGifQuantizer;
  Palette: TGifPalette;
begin
  BgraImageResize(Image, 8, 8);
  FillSolid(Image, 17, 200, 91);
  Quantizer := TGifQuantizer.Create;
  try
    Quantizer.SampleFrame(@Image.Pixels[0], Image.BytesPerRow, Image.Width,
      Image.Height);
    Expect<Integer>(Quantizer.DistinctColors).ToBe(1);
    Palette := Quantizer.BuildPalette(GifMaxColors);
    Expect<Integer>(Palette.Count).ToBe(1);
    Expect<Integer>(Palette.Colors[0].Red).ToBe(17);
    Expect<Integer>(Palette.Colors[0].Green).ToBe(200);
    Expect<Integer>(Palette.Colors[0].Blue).ToBe(91);
  finally
    Quantizer.Free;
  end;
end;

procedure TGifQuantizerTests.TestFourColorsSurviveIntact;
var
  Image: TBgraImage;
  Quantizer: TGifQuantizer;
  Palette: TGifPalette;
begin
  BgraImageResize(Image, 2, 2);
  SetPixel(Image, 0, 0, 255, 0, 0);
  SetPixel(Image, 1, 0, 0, 255, 0);
  SetPixel(Image, 0, 1, 0, 0, 255);
  SetPixel(Image, 1, 1, 255, 255, 255);
  Quantizer := TGifQuantizer.Create;
  try
    Quantizer.SampleFrame(@Image.Pixels[0], Image.BytesPerRow, Image.Width,
      Image.Height);
    Expect<Integer>(Quantizer.DistinctColors).ToBe(4);
    Palette := Quantizer.BuildPalette(GifMaxColors);
    Expect<Integer>(Palette.Count).ToBe(4);
  finally
    Quantizer.Free;
  end;
end;

procedure TGifQuantizerTests.TestManyColorsAreCappedAtTheLimit;
var
  Image: TBgraImage;
  Quantizer: TGifQuantizer;
  Palette: TGifPalette;
begin
  BgraImageResize(Image, 64, 64);
  FillGradient(Image);
  Quantizer := TGifQuantizer.Create;
  try
    Quantizer.SampleFrame(@Image.Pixels[0], Image.BytesPerRow, Image.Width,
      Image.Height);
    Expect<Boolean>(Quantizer.DistinctColors > GifMaxColors).ToBe(True);
    Palette := Quantizer.BuildPalette(GifMaxColors);
    Expect<Integer>(Palette.Count).ToBe(GifMaxColors);
  finally
    Quantizer.Free;
  end;
end;

procedure TGifQuantizerTests.TestSmallLimitIsHonoured;
var
  Image: TBgraImage;
  Quantizer: TGifQuantizer;
  Palette: TGifPalette;
begin
  BgraImageResize(Image, 64, 64);
  FillGradient(Image);
  Quantizer := TGifQuantizer.Create;
  try
    Quantizer.SampleFrame(@Image.Pixels[0], Image.BytesPerRow, Image.Width,
      Image.Height);
    Palette := Quantizer.BuildPalette(16);
    Expect<Integer>(Palette.Count).ToBe(16);
  finally
    Quantizer.Free;
  end;
end;

procedure TGifQuantizerTests.TestOrdinaryContentStaysExact;
var
  Image: TBgraImage;
  Quantizer: TGifQuantizer;
  Palette: TGifPalette;
begin
  BgraImageResize(Image, 64, 64);
  FillGradient(Image);
  Quantizer := TGifQuantizer.Create;
  try
    Quantizer.SampleFrame(@Image.Pixels[0], Image.BytesPerRow, Image.Width,
      Image.Height);
    Expect<Boolean>(Quantizer.IsExactHistogram).ToBe(True);
    Palette := Quantizer.BuildPalette(GifMaxOpaqueColors);
    Expect<Integer>(Palette.Count).ToBe(GifMaxOpaqueColors);
  finally
    Quantizer.Free;
  end;
end;

// The graceful-degradation path: more distinct colours than the exact
// table may hold folds everything into the 6-bit histogram and carries
// on, rather than failing or growing without bound. Five frames of
// 500x500 all-distinct colours is 1.25 M, past the 2^20 cap.
procedure TGifQuantizerTests.TestOverflowFallsBackToTheCellHistogram;
var
  Image: TBgraImage;
  Quantizer: TGifQuantizer;
  Palette: TGifPalette;
  Frame, X, Y, Value: Integer;
begin
  BgraImageResize(Image, 500, 500);
  Quantizer := TGifQuantizer.Create;
  try
    for Frame := 0 to 4 do
    begin
      for Y := 0 to 499 do
        for X := 0 to 499 do
        begin
          Value := Frame * 250000 + Y * 500 + X;
          SetPixel(Image, X, Y, Byte((Value shr 16) and $FF),
            Byte((Value shr 8) and $FF), Byte(Value and $FF));
        end;
      Quantizer.SampleFrame(@Image.Pixels[0], Image.BytesPerRow, Image.Width,
        Image.Height);
    end;
    Expect<Boolean>(Quantizer.IsExactHistogram).ToBe(False);
    // Everything now lives in the 64^3 cells, so the distinct count is
    // bounded by them rather than by the colours that arrived.
    Expect<Boolean>(Quantizer.DistinctColors <= GifHistogramCells)
      .ToBe(True);
    Expect<Boolean>(Quantizer.DistinctColors > GifMaxColors).ToBe(True);
    Palette := Quantizer.BuildPalette(GifMaxOpaqueColors);
    Expect<Integer>(Palette.Count).ToBe(GifMaxOpaqueColors);
  finally
    Quantizer.Free;
  end;
end;

// Whether APalette holds exactly this colour.
function PaletteHolds(const APalette: TGifPalette;
  ARed, AGreen, ABlue: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to APalette.Count - 1 do
    if (APalette.Colors[I].Red = ARed)
      and (APalette.Colors[I].Green = AGreen)
      and (APalette.Colors[I].Blue = ABlue) then
      Exit(True);
end;

// The regression the old global sampled-pixel budget caused. It stood at
// 8 000 000 pixels, and past it SampleFrame returned without doing
// anything at all — so a colour that first appeared later in a movie was
// invisible to the palette, silently. 33 frames of 500x500 is 8.25 M
// pixels; the colour that arrives after them has to land all the same.
procedure TGifQuantizerTests.TestLateFrameStillReachesThePalette;
var
  Early, Late: TBgraImage;
  Quantizer: TGifQuantizer;
  Palette: TGifPalette;
  Frame: Integer;
begin
  BgraImageResize(Early, 500, 500);
  FillSolid(Early, 10, 20, 30);
  BgraImageResize(Late, 8, 8);
  FillSolid(Late, 240, 130, 60);
  Quantizer := TGifQuantizer.Create;
  try
    for Frame := 0 to 32 do
      Quantizer.SampleFrame(@Early.Pixels[0], Early.BytesPerRow, Early.Width,
        Early.Height);
    Expect<Boolean>(Quantizer.SampledPixels > 8000000).ToBe(True);
    Expect<Integer>(Quantizer.DistinctColors).ToBe(1);
    Quantizer.SampleFrame(@Late.Pixels[0], Late.BytesPerRow, Late.Width,
      Late.Height);
    Expect<Integer>(Quantizer.DistinctColors).ToBe(2);
    Palette := Quantizer.BuildPalette(GifMaxOpaqueColors);
    Expect<Integer>(Palette.Count).ToBe(2);
    Expect<Boolean>(PaletteHolds(Palette, 240, 130, 60)).ToBe(True);
    Expect<Boolean>(PaletteHolds(Palette, 10, 20, 30)).ToBe(True);
  finally
    Quantizer.Free;
  end;
end;

// The arithmetic the budget used to protect. Only the 6-bit cells carry
// channel sums, so this starts the way the fallback test does — five
// frames of 500x500 all-distinct colours, past the 2^20 exact cap — and
// then piles 76 frames of one bright colour into a single cell: 19 M
// samples, a red sum of 4.75e9, past 2^32 (4.29e9). As UInt32 that wraps
// to 4.55e8 and the palette entry comes out at red 23 instead of 250.
//
// It lands in a box of its own, so the entry is that cell's exact mean:
// the scattered colours are packed from a counter below 2^20, so none of
// them has a red above 19, and red is the channel holding the most
// squared error. Sorted on it the bright cell is last and alone, and the
// weighted-median split cannot reach it — the scattered colours together
// are 1.25 M against its 19 M.
procedure TGifQuantizerTests.TestCellSumsSurviveAThirtyTwoBitOverflow;
var
  Scattered, Bright: TBgraImage;
  Quantizer: TGifQuantizer;
  Palette: TGifPalette;
  Frame, X, Y, Value: Integer;
begin
  BgraImageResize(Scattered, 500, 500);
  BgraImageResize(Bright, 500, 500);
  FillSolid(Bright, 250, 250, 250);
  Quantizer := TGifQuantizer.Create;
  try
    for Frame := 0 to 4 do
    begin
      for Y := 0 to 499 do
        for X := 0 to 499 do
        begin
          Value := Frame * 250000 + Y * 500 + X;
          SetPixel(Scattered, X, Y, Byte((Value shr 16) and $FF),
            Byte((Value shr 8) and $FF), Byte(Value and $FF));
        end;
      Quantizer.SampleFrame(@Scattered.Pixels[0], Scattered.BytesPerRow,
        Scattered.Width, Scattered.Height);
    end;
    Expect<Boolean>(Quantizer.IsExactHistogram).ToBe(False);
    for Frame := 0 to 75 do
      Quantizer.SampleFrame(@Bright.Pixels[0], Bright.BytesPerRow,
        Bright.Width, Bright.Height);
    Expect<Int64>(Quantizer.SampledPixels).ToBe(20250000);
    Palette := Quantizer.BuildPalette(GifMaxOpaqueColors);
    Expect<Boolean>(PaletteHolds(Palette, 250, 250, 250)).ToBe(True);
  finally
    Quantizer.Free;
  end;
end;

{ TGifPaletteSamplerTests }

procedure TGifPaletteSamplerTests.SetupTests;
begin
  Test('the first frame is always sampled', TestFirstFrameIsAlwaysSampled);
  Test('an honest estimate lands on the sample target',
    TestHonestEstimateHitsTheSampleTarget);
  Test('an estimate far above the truth still spreads over the stream',
    TestLyingEstimateStillSpreadsOverAShortStream);
  Test('the stride doubles once per phase of samples',
    TestStrideDoublesOncePerPhase);
  Test('a stream far longer than its estimate is thinned, not truncated',
    TestLongStreamIsThinnedNotTruncated);
  Test('a missing estimate starts dense and thins itself',
    TestMissingEstimateStartsDenseAndThins);
end;

// Every index a sampler seeded with AExpectedFrames asks for while a
// stream of ALength frames is walked past it.
function SampledIndices(AExpectedFrames, ALength: Int64): TInt64DynArray;
var
  Sampler: TGifPaletteSampler;
  Index: Int64;
  Filled: Integer;
begin
  Result := nil;
  Filled := 0;
  Sampler := TGifPaletteSampler.Create(AExpectedFrames);
  try
    Index := 0;
    while Index < ALength do
    begin
      if Sampler.TakeFrame(Index) then
      begin
        if Filled = Length(Result) then
          SetLength(Result, Max(16, Filled * 2));
        Result[Filled] := Index;
        Inc(Filled);
      end;
      Inc(Index);
    end;
  finally
    Sampler.Free;
  end;
  SetLength(Result, Filled);
end;

procedure TGifPaletteSamplerTests.TestFirstFrameIsAlwaysSampled;
var
  Indices: TInt64DynArray;
begin
  Indices := SampledIndices(1000000000, 1);
  Expect<Integer>(Length(Indices)).ToBe(1);
  Expect<Int64>(Indices[0]).ToBe(0);
end;

// The mainstream case, and the one the seed exists for: a stream whose
// estimate is right is sampled exactly GifPaletteSampleFrames times, at
// an even stride, with no doubling reached.
procedure TGifPaletteSamplerTests.TestHonestEstimateHitsTheSampleTarget;
var
  Indices: TInt64DynArray;
  I: Integer;
begin
  Indices := SampledIndices(640, 640);
  Expect<Integer>(Length(Indices)).ToBe(GifPaletteSampleFrames);
  for I := 0 to High(Indices) do
    Expect<Int64>(Indices[I]).ToBe(I * 20);
end;

// The first of the two open-loop failures: a container whose duration
// metadata lies high, or a --trim past the end of one, used to yield a
// stride longer than the movie and a palette built from a single frame.
// The seed cap is what stops it — 500 frames against an estimate of a
// billion still gets eight samples, spread across the whole stream.
procedure TGifPaletteSamplerTests.TestLyingEstimateStillSpreadsOverAShortStream;
const
  Frames = 500;
var
  Indices: TInt64DynArray;
begin
  Indices := SampledIndices(1000000000, Frames);
  Expect<Boolean>(Length(Indices) > 1).ToBe(True);
  // Both: the exact count this input produces, and the derivation that
  // says WHY it is that. The derived bound alone is nearly a tautology
  // — it recomputes the implementation's own arithmetic — and a
  // schedule that quietly stopped capping the seed stride would satisfy
  // it while returning something else entirely.
  Expect<Integer>(Length(Indices)).ToBe(8);
  Expect<Integer>(Length(Indices))
    .ToBe((Frames + GifPaletteMaxSeedStride - 1)
    div GifPaletteMaxSeedStride);
  Expect<Int64>(Indices[0]).ToBe(0);
  // And the contract this test is named for: the samples reach the END
  // of the stream, within one stride of it.
  Expect<Boolean>(Indices[High(Indices)]
    >= Frames - GifPaletteMaxSeedStride).ToBe(True);
end;

procedure TGifPaletteSamplerTests.TestStrideDoublesOncePerPhase;
var
  Sampler: TGifPaletteSampler;
  Index: Integer;
begin
  Sampler := TGifPaletteSampler.Create(GifPaletteSampleFrames);
  try
    Expect<Int64>(Sampler.Stride).ToBe(1);
    for Index := 0 to GifPaletteSampleFrames - 1 do
      Expect<Boolean>(Sampler.TakeFrame(Index)).ToBe(True);
    Expect<Int64>(Sampler.SampledFrames).ToBe(GifPaletteSampleFrames);
    Expect<Int64>(Sampler.Stride).ToBe(2);
    Index := GifPaletteSampleFrames - 1;
    while Sampler.SampledFrames < 2 * GifPaletteSampleFrames do
    begin
      Inc(Index);
      Sampler.TakeFrame(Index);
    end;
    Expect<Int64>(Sampler.Stride).ToBe(4);
  finally
    Sampler.Free;
  end;
end;

// The second open-loop failure: an estimate that runs low used to sample
// the head of the movie densely and, once the quantiser's pixel budget
// was spent, the tail not at all. Now the stride doubles as the walk goes
// on, so the samples still reach the end of the stream and their number
// grows with its logarithm rather than with its length — 263 samples for
// 10 000 frames seeded at one, where an unthinned stride of one would
// have taken all 10 000.
procedure TGifPaletteSamplerTests.TestLongStreamIsThinnedNotTruncated;
var
  Indices: TInt64DynArray;
  I: Integer;
begin
  Indices := SampledIndices(GifPaletteSampleFrames, 10000);
  // Logarithmic, not linear — and the exact number, beside the two
  // bounds that say what "logarithmic" MEANS. The bounds alone let the
  // schedule change shape completely without a single test moving,
  // which is the opposite of what a schedule test is for; 263 is what
  // this schedule produces for this input, and a change to it should
  // have to be looked at.
  Expect<Integer>(Length(Indices)).ToBe(263);
  Expect<Boolean>(Length(Indices) > GifPaletteSampleFrames).ToBe(True);
  Expect<Boolean>(Length(Indices) < 10000 div 4).ToBe(True);
  Expect<Int64>(Indices[0]).ToBe(0);
  // The tail of the stream is represented: the last sample sits within
  // one final stride (256) of the end.
  Expect<Boolean>(Indices[High(Indices)] > 10000 - 256).ToBe(True);
  // Monotonically thinning: no gap is ever shorter than the one before.
  for I := 2 to High(Indices) do
    Expect<Boolean>((Indices[I] - Indices[I - 1])
      >= (Indices[I - 1] - Indices[I - 2])).ToBe(True);
end;

// What ExpectedFrameCount returns when the container will not say how
// long the movie is. A seed of one frame is dense to begin with and the
// doubling is the only thing keeping the sample count down, which is the
// case with no seed to lean on at all.
procedure TGifPaletteSamplerTests.TestMissingEstimateStartsDenseAndThins;
const
  Frames = 200;
var
  Indices: TInt64DynArray;
  I: Integer;
begin
  Indices := SampledIndices(1, Frames);
  // The first phase is every frame, which is what a seed of one means.
  for I := 0 to GifPaletteSampleFrames - 1 do
    Expect<Int64>(Indices[I]).ToBe(I);
  // Then it thins: more than the dense first phase, far fewer than every
  // frame. The transcribed 90 said only what a particular run did.
  Expect<Boolean>(Length(Indices) > GifPaletteSampleFrames).ToBe(True);
  Expect<Boolean>(Length(Indices) < Frames div 2).ToBe(True);
  // The last frame of the stream is reached, which is the contract the
  // doubling exists to keep.
  Expect<Int64>(Indices[High(Indices)]).ToBe(Frames - 1);
end;

{ TGifStructureTests }

procedure TGifStructureTests.SetupTests;
begin
  Test('the file starts GIF89a and loops for ever',
    TestHeaderAndLoopExtension);
  Test('the global colour table is a power of two',
    TestColorTableIsAPowerOfTwo);
  Test('the LZW minimum code size is never below two',
    TestMinimumCodeSizeIsAtLeastTwo);
  Test('per-frame delays reach the file, clamped at the low end',
    TestDelaysAreClampedAndWritten);
end;

procedure TGifStructureTests.TestHeaderAndLoopExtension;
var
  First, Second: TBgraImage;
  Gif: TDecodedGif;
  Path: string;
begin
  BgraImageResize(First, 8, 6);
  BgraImageResize(Second, 8, 6);
  FillSolid(First, 255, 0, 0);
  FillSolid(Second, 0, 0, 255);
  Path := EncodeImages('header.gif', [First, Second], [10, 10], True,
    GifMaxColors);
  try
    Gif := DecodeGif(Path);
    Expect<string>(Gif.Signature).ToBe('GIF89a');
    Expect<Integer>(Gif.Width).ToBe(8);
    Expect<Integer>(Gif.Height).ToBe(6);
    Expect<Boolean>(Gif.HasLoopExtension).ToBe(True);
    Expect<Integer>(Gif.LoopCount).ToBe(0);
    Expect<Integer>(Length(Gif.Frames)).ToBe(2);
    Expect<Boolean>(Gif.Frames[0].HasLocalTable).ToBe(False);
  finally
    DeleteFile(Path);
  end;
end;

procedure TGifStructureTests.TestColorTableIsAPowerOfTwo;
var
  Image: TBgraImage;
  Gif: TDecodedGif;
  Path: string;
begin
  BgraImageResize(Image, 32, 32);
  FillGradient(Image);
  Path := EncodeImages('table.gif', [Image], [10], True, GifMaxColors);
  try
    Gif := DecodeGif(Path);
    Expect<Integer>(Gif.TableEntries).ToBe(256);
    Expect<Integer>(Gif.Frames[0].MinCodeSize).ToBe(8);
  finally
    DeleteFile(Path);
  end;
end;

procedure TGifStructureTests.TestMinimumCodeSizeIsAtLeastTwo;
var
  Image: TBgraImage;
  Gif: TDecodedGif;
  Path: string;
  X, Y: Integer;
begin
  BgraImageResize(Image, 4, 4);
  FillSolid(Image, 12, 34, 56);
  Path := EncodeImages('single.gif', [Image], [10], True, GifMaxColors);
  try
    Gif := DecodeGif(Path);
    // One colour needs a two-entry table, but GIF forbids a code size
    // below two whatever the table holds.
    Expect<Integer>(Gif.TableEntries).ToBe(2);
    Expect<Integer>(Gif.Frames[0].MinCodeSize).ToBe(2);
    for Y := 0 to 3 do
      for X := 0 to 3 do
        Expect<Integer>(CanvasColor(Gif, 0, X, Y).Green).ToBe(34);
  finally
    DeleteFile(Path);
  end;
end;

procedure TGifStructureTests.TestDelaysAreClampedAndWritten;
var
  First, Second, Third: TBgraImage;
  Gif: TDecodedGif;
  Path: string;
begin
  BgraImageResize(First, 4, 4);
  BgraImageResize(Second, 4, 4);
  BgraImageResize(Third, 4, 4);
  FillSolid(First, 255, 0, 0);
  FillSolid(Second, 0, 255, 0);
  FillSolid(Third, 0, 0, 255);
  Path := EncodeImages('delays.gif', [First, Second, Third], [0, 5, 33], True,
    GifMaxColors);
  try
    Gif := DecodeGif(Path);
    Expect<Integer>(Gif.Frames[0].DelayCentiseconds)
      .ToBe(GifMinDelayCentiseconds);
    Expect<Integer>(Gif.Frames[1].DelayCentiseconds).ToBe(5);
    Expect<Integer>(Gif.Frames[2].DelayCentiseconds).ToBe(33);
    Expect<Integer>(Gif.Frames[0].Disposal).ToBe(GifDisposalLeaveInPlace);
  finally
    DeleteFile(Path);
  end;
end;

{ TGifPixelTests }

procedure TGifPixelTests.SetupTests;
begin
  Test('solid frames decode back to their exact colours',
    TestSolidFramesRoundTripExactly);
  Test('an unchanged frame is written as a single pixel',
    TestUnchangedFrameShrinksToOnePixel);
  Test('a changed frame repaints exactly the changed rectangle',
    TestChangedRectangleCoversTheChange);
  Test('a frame that changed everywhere is written without transparency',
    TestDenseChangesStayOpaque);
  Test('unchanged pixels inside the rectangle are written as transparent',
    TestScatteredChangesLeaveTheRestTransparent);
  Test('a 256-colour gradient decodes close to the source',
    TestGradientStaysCloseToTheSource);
  Test('a frame long enough to exhaust the LZW table still decodes',
    TestLargeFrameSurvivesADictionaryReset);
end;

procedure TGifPixelTests.TestSolidFramesRoundTripExactly;
var
  Images: array[0..2] of TBgraImage;
  Gif: TDecodedGif;
  Path: string;
  I, X, Y: Integer;
  Expected: array[0..2] of TGifColor;
  Color: TGifColor;
begin
  Expected[0].Red := 255;
  Expected[0].Green := 0;
  Expected[0].Blue := 0;
  Expected[1].Red := 0;
  Expected[1].Green := 255;
  Expected[1].Blue := 0;
  Expected[2].Red := 0;
  Expected[2].Green := 0;
  Expected[2].Blue := 255;
  for I := 0 to 2 do
  begin
    BgraImageResize(Images[I], 5, 3);
    FillSolid(Images[I], Expected[I].Red, Expected[I].Green,
      Expected[I].Blue);
  end;
  Path := EncodeImages('solid.gif', Images, [10, 10, 10], True,
    GifMaxColors);
  try
    Gif := DecodeGif(Path);
    Expect<Integer>(Length(Gif.Frames)).ToBe(3);
    for I := 0 to 2 do
      for Y := 0 to 2 do
        for X := 0 to 4 do
        begin
          Color := CanvasColor(Gif, I, X, Y);
          Expect<Integer>(Color.Red).ToBe(Expected[I].Red);
          Expect<Integer>(Color.Green).ToBe(Expected[I].Green);
          Expect<Integer>(Color.Blue).ToBe(Expected[I].Blue);
        end;
  finally
    DeleteFile(Path);
  end;
end;

procedure TGifPixelTests.TestUnchangedFrameShrinksToOnePixel;
var
  First, Second: TBgraImage;
  Gif: TDecodedGif;
  Path: string;
begin
  BgraImageResize(First, 16, 16);
  FillSolid(First, 10, 20, 30);
  BgraImageResize(Second, 16, 16);
  FillSolid(Second, 10, 20, 30);
  Path := EncodeImages('static.gif', [First, Second], [10, 10], True,
    GifMaxColors);
  try
    Gif := DecodeGif(Path);
    Expect<Integer>(Gif.Frames[0].Width).ToBe(16);
    Expect<Integer>(Gif.Frames[0].Height).ToBe(16);
    Expect<Integer>(Gif.Frames[1].Width).ToBe(1);
    Expect<Integer>(Gif.Frames[1].Height).ToBe(1);
    // Whether that pixel is transparent or a repaint of the colour
    // already there is the encoder's choice; either way the frame only
    // carries the delay and the canvas must not move.
    Expect<Integer>(CanvasColor(Gif, 1, 15, 15).Blue).ToBe(30);
    Expect<Integer>(CanvasColor(Gif, 1, 0, 0).Green).ToBe(20);
  finally
    DeleteFile(Path);
  end;
end;

procedure TGifPixelTests.TestChangedRectangleCoversTheChange;
var
  First, Second: TBgraImage;
  Gif: TDecodedGif;
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
  Path := EncodeImages('rect.gif', [First, Second], [10, 10], True,
    GifMaxColors);
  try
    Gif := DecodeGif(Path);
    Expect<Integer>(Gif.Frames[1].Left).ToBe(3);
    Expect<Integer>(Gif.Frames[1].Top).ToBe(4);
    Expect<Integer>(Gif.Frames[1].Width).ToBe(7);
    Expect<Integer>(Gif.Frames[1].Height).ToBe(3);
    Expect<Integer>(CanvasColor(Gif, 1, 3, 4).Red).ToBe(255);
    Expect<Integer>(CanvasColor(Gif, 1, 9, 6).Red).ToBe(255);
    Expect<Integer>(CanvasColor(Gif, 1, 2, 4).Red).ToBe(0);
    Expect<Integer>(CanvasColor(Gif, 1, 10, 6).Red).ToBe(0);
    Expect<Integer>(CanvasColor(Gif, 1, 0, 0).Red).ToBe(0);
  finally
    DeleteFile(Path);
  end;
end;

procedure TGifPixelTests.TestDenseChangesStayOpaque;
var
  First, Second: TBgraImage;
  Gif: TDecodedGif;
  Path: string;
begin
  BgraImageResize(First, 8, 8);
  FillSolid(First, 255, 0, 0);
  BgraImageResize(Second, 8, 8);
  FillSolid(Second, 0, 0, 255);
  Path := EncodeImages('opaque.gif', [First, Second], [10, 10], True,
    GifMaxColors);
  try
    Gif := DecodeGif(Path);
    // The first frame paints the whole canvas, so nothing about it may
    // be transparent.
    Expect<Boolean>(Gif.Frames[0].HasTransparency).ToBe(False);
    Expect<Integer>(Gif.Frames[0].TransparentPixels).ToBe(0);
    // The second frame changed every pixel, so a transparent index
    // would only fragment the runs LZW is about to find.
    Expect<Boolean>(Gif.Frames[1].HasTransparency).ToBe(False);
    Expect<Integer>(Gif.Frames[1].TransparentPixels).ToBe(0);
    // The slot stays reserved either way: two real colours plus the
    // transparent index round up to a four-entry table.
    Expect<Integer>(Gif.TableEntries).ToBe(4);
    Expect<Integer>(CanvasColor(Gif, 1, 4, 4).Blue).ToBe(255);
    Expect<Integer>(CanvasColor(Gif, 1, 4, 4).Red).ToBe(0);
  finally
    DeleteFile(Path);
  end;
end;

procedure TGifPixelTests.TestScatteredChangesLeaveTheRestTransparent;
var
  First, Second: TBgraImage;
  Gif: TDecodedGif;
  Path: string;
  I, Changed: Integer;
begin
  // Two pixels move in opposite corners of a varied background. The
  // rectangle has to span them, but re-encoding the gradient between
  // them costs far more than one long run of the transparent index, so
  // this is the case where transparency has to win — and it is the
  // shape a real recording takes once its codec noise is quantised.
  BgraImageResize(First, 32, 24);
  FillGradient(First);
  BgraImageResize(Second, 32, 24);
  FillGradient(Second);
  SetPixel(Second, 3, 2, 255, 255, 255);
  SetPixel(Second, 28, 20, 255, 255, 255);
  Path := EncodeImages('scatter.gif', [First, Second], [10, 10], False,
    GifMaxColors);
  try
    Gif := DecodeGif(Path);
    Expect<Integer>(Gif.Frames[1].Left).ToBe(3);
    Expect<Integer>(Gif.Frames[1].Top).ToBe(2);
    Expect<Integer>(Gif.Frames[1].Width).ToBe(26);
    Expect<Integer>(Gif.Frames[1].Height).ToBe(19);
    Expect<Boolean>(Gif.Frames[1].HasTransparency).ToBe(True);
    // 26 x 19 = 494 pixels in the rectangle, two of which actually
    // moved; everything else is left standing.
    Expect<Integer>(Gif.Frames[1].TransparentPixels).ToBe(492);
    // The composited canvas differs from the previous frame in exactly
    // the two pixels that changed.
    Changed := 0;
    for I := 0 to Length(Gif.Frames[1].Canvas) - 1 do
      if Gif.Frames[1].Canvas[I] <> Gif.Frames[0].Canvas[I] then
        Inc(Changed);
    Expect<Integer>(Changed).ToBe(2);
    // Quantisation folds the two white pixels in with the palest
    // gradient colours, so they come back near white rather than exact.
    Expect<Boolean>(CanvasColor(Gif, 1, 3, 2).Red > 240).ToBe(True);
    Expect<Boolean>(CanvasColor(Gif, 1, 28, 20).Red > 240).ToBe(True);
  finally
    DeleteFile(Path);
  end;
end;

procedure TGifPixelTests.TestGradientStaysCloseToTheSource;
var
  Image: TBgraImage;
  Gif: TDecodedGif;
  Path: string;
  X, Y, Base, WorstError, Error: Integer;
  TotalError: Int64;
  Color: TGifColor;
begin
  BgraImageResize(Image, 48, 48);
  FillGradient(Image);
  // Dithering trades per-pixel accuracy for a better average, so the
  // bound checked here is the mean, with a loose per-pixel ceiling.
  Path := EncodeImages('gradient.gif', [Image], [10], True, GifMaxColors);
  try
    Gif := DecodeGif(Path);
    WorstError := 0;
    TotalError := 0;
    for Y := 0 to 47 do
      for X := 0 to 47 do
      begin
        Color := CanvasColor(Gif, 0, X, Y);
        Base := Y * Image.BytesPerRow + X * BgraBytesPerPixel;
        Error := Abs(Color.Red - Image.Pixels[Base + BgraRedOffset])
          + Abs(Color.Green - Image.Pixels[Base + BgraGreenOffset])
          + Abs(Color.Blue - Image.Pixels[Base + BgraBlueOffset]);
        Inc(TotalError, Error);
        if Error > WorstError then
          WorstError := Error;
      end;
    Expect<Boolean>(TotalError div (48 * 48) < 45).ToBe(True);
    Expect<Boolean>(WorstError < 300).ToBe(True);
  finally
    DeleteFile(Path);
  end;
end;

procedure TGifPixelTests.TestLargeFrameSurvivesADictionaryReset;
var
  Image: TBgraImage;
  Gif: TDecodedGif;
  Path: string;
  X, Y: Integer;
begin
  // 256x256 of pseudo-random indices is far more than the 4096-entry
  // LZW table holds, so the encoder has to emit at least one clear code
  // mid-frame and the decoder has to follow it.
  BgraImageResize(Image, 256, 256);
  for Y := 0 to 255 do
    for X := 0 to 255 do
      SetPixel(Image, X, Y, Byte((X * 37 + Y * 11) and $FF),
        Byte((X * 5 + Y * 61) and $FF), Byte((X xor Y) and $FF));
  Path := EncodeImages('large.gif', [Image], [10], False, GifMaxColors);
  try
    Gif := DecodeGif(Path);
    Expect<Integer>(Gif.Width).ToBe(256);
    Expect<Integer>(Length(Gif.Frames)).ToBe(1);
    Expect<Integer>(Gif.Frames[0].Width).ToBe(256);
    Expect<Integer>(Length(Gif.Frames[0].Canvas)).ToBe(256 * 256);
  finally
    DeleteFile(Path);
  end;
end;

begin
  // Pid-qualified, like Knips.Recording.Recovery.Test's directory: two
  // runs of this suite at once otherwise write the same fixture paths
  // and read each other's half-written files.
  GScratchDirectory := IncludeTrailingPathDelimiter(GetTempDir)
    + 'knips-gif-test-' + IntToStr(GetProcessID);
  ForceDirectories(GScratchDirectory);
  TestRunnerProgram.AddSuite(TGifQuantizerTests.Create('TGifQuantizer'));
  TestRunnerProgram.AddSuite(
    TGifPaletteSamplerTests.Create('TGifPaletteSampler'));
  TestRunnerProgram.AddSuite(TGifStructureTests.Create('GIF89a structure'));
  TestRunnerProgram.AddSuite(TGifPixelTests.Create('GIF pixels'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

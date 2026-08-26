unit Knips.Export.Apng;

// Animated PNG in pure Pascal: 8-bit truecolour, so no palette and no
// quantisation at all. That is the whole point of the format here — a
// screen recording exported as APNG is exactly the pixels the scaler
// produced, where the GIF path has to fit them into 255 colours first.
//
// The file is a PNG whose IDAT is the first frame, plus the three
// animation chunks: acTL up front with the frame count, an fcTL before
// every frame, and fdAT carrying the frames after the first.
//
//   signature IHDR acTL  fcTL#0 IDAT  fcTL#1 fdAT#2  fcTL#3 fdAT#4 ... IEND
//
// Frames after the first are written as the rectangle that actually
// changed, at its own offset, with dispose_op NONE and blend_op SOURCE:
// the canvas is never cleared between frames and the subframe's pixels
// replace what is under them. With no alpha channel SOURCE is also the
// only blend that means anything, and the pair is what makes a
// changed-rectangle frame composite exactly rather than approximately.
// A frame identical to its predecessor becomes a 1x1 rectangle that only
// carries the delay, the same trick the GIF encoder uses.
//
// Memory shape: the current frame's RGB, the previous frame's, and one
// frame's worth of compressed bytes. Nothing accumulates with the length
// of the movie. acTL's frame count is the one thing that cannot be known
// while streaming, so it is written as zero and patched in Finish — four
// bytes and a CRC, at a known offset.
//
// Compression is the RTL's own paszlib (`ZStream`), which is part of
// FreePascal and needs no external library.
//
// Nothing here knows about macOS: `lwpt test` decodes the encoder's own
// output on any host.

{$I Knips.inc}

interface

uses
  Classes,
  Math,
  SysUtils,

  Knips.Export.Bitmap,
  ZStream;

const
  // dispose_op / blend_op values from the APNG specification.
  ApngDisposeOpNone = 0;
  ApngDisposeOpBackground = 1;
  ApngDisposeOpPrevious = 2;
  ApngBlendOpSource = 0;
  ApngBlendOpOver = 1;
  // Colour type 2: truecolour, three 8-bit channels, no alpha.
  ApngColorTypeTruecolor = 2;
  ApngBitDepth = 8;
  ApngBytesPerPixel = 3;
  // PNG dimensions are 31-bit, but a frame this program can hold in
  // memory is nowhere near that; the bound keeps the arithmetic honest.
  ApngMaxDimension = 32767;
  // ...and even inside that bound, width x height x 3 can overflow a
  // 32-bit index long before it runs out of memory, so the buffers have
  // a budget of their own, checked in Int64 before anything is
  // allocated. 256 MB is two 8K frames plus the filter scratch.
  ApngMaxFrameBytes = Int64(256) * 1024 * 1024;
  // num_plays = 0 means loop forever, the same as GIF's NETSCAPE2.0.
  ApngLoopForever = 0;

type
  // Streams one APNG. Open, then AddFrame per frame with the delay that
  // frame should be shown for, then Finish.
  TApngEncoder = class
  private
    FWidth: Integer;
    FHeight: Integer;
    FDelayDenominator: Integer;
    FOutput: TFileStream;
    FSequence: Cardinal;
    FFrameCount: Int64;
    FBytesWritten: Int64;
    FFrameCountOffset: Int64;
    FHasPrevious: Boolean;
    FCurrent: TBytes;
    FPrevious: TBytes;
    // Filtered scanlines for one subframe, and the two candidate lines
    // the filter choice compares.
    FRaw: TBytes;
    FCandidate: TBytes;
    FBest: TBytes;
    procedure Emit(const AData; ALength: Integer);
    procedure EmitBigEndian32(AValue: Cardinal);
    procedure WriteChunk(const AType: string; const AData; ALength: Integer);
    procedure WriteSignature;
    procedure WriteHeaderChunk;
    procedure WriteAnimationControl;
    procedure WriteFrameControl(ALeft, ATop, AWidth, AHeight,
      ADelayTicks: Integer);
    procedure CaptureFrame(const APixels: PByte; ABytesPerRow: Integer);
    function ChangedRectangle(out ALeft, ATop, ARight,
      ABottom: Integer): Boolean;
    function ScoreFilter(AFilter, ARow, AAbove, AStride: Integer): Integer;
    function FilterRectangle(ALeft, ATop, AWidth, AHeight: Integer): Integer;
    function Deflate(const ASource: TBytes; ALength: Integer): TBytes;
    procedure WriteFrameData(const ACompressed: TBytes);
  public
    // ADelayDenominator is the fcTL delay_den every frame is written
    // with: 1000 for milliseconds, 100 for centiseconds.
    constructor Create(AWidth, AHeight, ADelayDenominator: Integer);
    destructor Destroy; override;
    function Open(const APath: string; out AError: string): Boolean;
    // APixels is a BGRA buffer of the encoder's own width and height.
    function AddFrame(const APixels: PByte; ABytesPerRow,
      ADelayTicks: Integer; out AError: string): Boolean;
    function Finish(out AError: string): Boolean;
    property FrameCount: Int64 read FFrameCount;
    property BytesWritten: Int64 read FBytesWritten;
  end;

// PNG's CRC-32: the IEEE polynomial, seeded and finalised with all ones.
// Exposed because the test parses the encoder's output and checks it.
function ApngCrc32(const AData; ALength: Integer): Cardinal;

implementation

const
  CrcPolynomial = $EDB88320;

var
  GCrcTable: array[0..255] of Cardinal;
  GCrcTableReady: Boolean = False;

procedure EnsureCrcTable;
var
  I, Bit: Integer;
  Value: Cardinal;
begin
  if GCrcTableReady then
    Exit;
  for I := 0 to 255 do
  begin
    Value := Cardinal(I);
    for Bit := 0 to 7 do
      if (Value and 1) <> 0 then
        Value := CrcPolynomial xor (Value shr 1)
      else
        Value := Value shr 1;
    GCrcTable[I] := Value;
  end;
  GCrcTableReady := True;
end;

function CrcUpdate(ACrc: Cardinal; const AData; ALength: Integer): Cardinal;
var
  Source: PByte;
  I: Integer;
begin
  EnsureCrcTable;
  Result := ACrc;
  Source := @AData;
  for I := 0 to ALength - 1 do
  begin
    Result := GCrcTable[(Result xor Cardinal((Source + I)^)) and $FF]
      xor (Result shr 8);
  end;
end;

function ApngCrc32(const AData; ALength: Integer): Cardinal;
begin
  Result := CrcUpdate($FFFFFFFF, AData, ALength) xor $FFFFFFFF;
end;

// The five PNG line filters, applied per byte with a bytes-per-pixel
// offset. AbsoluteSum is the standard heuristic for picking between
// them: the filter whose output has the smallest sum of signed
// magnitudes is almost always the one that deflates smallest.
function PaethPredictor(ALeft, AAbove, AAboveLeft: Integer): Integer;
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

{ TApngEncoder }

// Nothing is allocated here. The buffers are sized from the canvas, and
// the canvas is only known to be sane once Open has checked it — sizing
// them first would compute FHeight * (1 + FWidth * 3) in 32-bit
// arithmetic for a canvas that Open is about to refuse.
constructor TApngEncoder.Create(AWidth, AHeight, ADelayDenominator: Integer);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FDelayDenominator := Max(1, ADelayDenominator);
end;

destructor TApngEncoder.Destroy;
begin
  FreeAndNil(FOutput);
  inherited Destroy;
end;

procedure TApngEncoder.Emit(const AData; ALength: Integer);
begin
  if (ALength <= 0) or (FOutput = nil) then
    Exit;
  FOutput.WriteBuffer(AData, ALength);
  Inc(FBytesWritten, ALength);
end;

procedure TApngEncoder.EmitBigEndian32(AValue: Cardinal);
var
  Quad: array[0..3] of Byte;
begin
  Quad[0] := Byte((AValue shr 24) and $FF);
  Quad[1] := Byte((AValue shr 16) and $FF);
  Quad[2] := Byte((AValue shr 8) and $FF);
  Quad[3] := Byte(AValue and $FF);
  Emit(Quad[0], 4);
end;

// length, type, data, CRC over type and data.
procedure TApngEncoder.WriteChunk(const AType: string; const AData;
  ALength: Integer);
var
  Crc: Cardinal;
begin
  EmitBigEndian32(Cardinal(ALength));
  Crc := CrcUpdate($FFFFFFFF, AType[1], 4);
  if ALength > 0 then
    Crc := CrcUpdate(Crc, AData, ALength);
  Emit(AType[1], 4);
  Emit(AData, ALength);
  EmitBigEndian32(Crc xor $FFFFFFFF);
end;

procedure TApngEncoder.WriteSignature;
const
  Signature: array[0..7] of Byte = ($89, $50, $4E, $47, $0D, $0A, $1A, $0A);
begin
  Emit(Signature[0], SizeOf(Signature));
end;

procedure TApngEncoder.WriteHeaderChunk;
var
  Data: array[0..12] of Byte;
begin
  Data[0] := Byte((FWidth shr 24) and $FF);
  Data[1] := Byte((FWidth shr 16) and $FF);
  Data[2] := Byte((FWidth shr 8) and $FF);
  Data[3] := Byte(FWidth and $FF);
  Data[4] := Byte((FHeight shr 24) and $FF);
  Data[5] := Byte((FHeight shr 16) and $FF);
  Data[6] := Byte((FHeight shr 8) and $FF);
  Data[7] := Byte(FHeight and $FF);
  Data[8] := ApngBitDepth;
  Data[9] := ApngColorTypeTruecolor;
  Data[10] := 0;
  Data[11] := 0;
  Data[12] := 0;
  WriteChunk('IHDR', Data[0], SizeOf(Data));
end;

procedure TApngEncoder.WriteAnimationControl;
var
  Data: array[0..7] of Byte;
begin
  // num_frames is not known while streaming; Finish patches these four
  // bytes and the chunk's CRC once the last frame has gone out.
  FillChar(Data, SizeOf(Data), 0);
  Data[7] := ApngLoopForever;
  // The chunk's data starts eight bytes into the chunk (length + type).
  FFrameCountOffset := FBytesWritten + 8;
  WriteChunk('acTL', Data[0], SizeOf(Data));
end;

procedure TApngEncoder.WriteFrameControl(ALeft, ATop, AWidth, AHeight,
  ADelayTicks: Integer);
var
  Data: array[0..25] of Byte;

  procedure PutBigEndian32(AOffset: Integer; AValue: Cardinal);
  begin
    Data[AOffset] := Byte((AValue shr 24) and $FF);
    Data[AOffset + 1] := Byte((AValue shr 16) and $FF);
    Data[AOffset + 2] := Byte((AValue shr 8) and $FF);
    Data[AOffset + 3] := Byte(AValue and $FF);
  end;

begin
  PutBigEndian32(0, FSequence);
  Inc(FSequence);
  PutBigEndian32(4, Cardinal(AWidth));
  PutBigEndian32(8, Cardinal(AHeight));
  PutBigEndian32(12, Cardinal(ALeft));
  PutBigEndian32(16, Cardinal(ATop));
  Data[20] := Byte((ADelayTicks shr 8) and $FF);
  Data[21] := Byte(ADelayTicks and $FF);
  Data[22] := Byte((FDelayDenominator shr 8) and $FF);
  Data[23] := Byte(FDelayDenominator and $FF);
  Data[24] := ApngDisposeOpNone;
  Data[25] := ApngBlendOpSource;
  WriteChunk('fcTL', Data[0], SizeOf(Data));
end;

// BGRA in, RGB out; alpha is dropped because the canvas has none.
procedure TApngEncoder.CaptureFrame(const APixels: PByte;
  ABytesPerRow: Integer);
var
  X, Y, Target: Integer;
  Source: PByte;
begin
  Target := 0;
  for Y := 0 to FHeight - 1 do
  begin
    Source := APixels + Y * ABytesPerRow;
    for X := 0 to FWidth - 1 do
    begin
      FCurrent[Target] := (Source + BgraRedOffset)^;
      FCurrent[Target + 1] := (Source + BgraGreenOffset)^;
      FCurrent[Target + 2] := (Source + BgraBlueOffset)^;
      Inc(Target, ApngBytesPerPixel);
      Inc(Source, BgraBytesPerPixel);
    end;
  end;
end;

function TApngEncoder.ChangedRectangle(out ALeft, ATop, ARight,
  ABottom: Integer): Boolean;
var
  X, Y, Base: Integer;
begin
  ALeft := FWidth;
  ATop := FHeight;
  ARight := -1;
  ABottom := -1;
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
    begin
      Base := (Y * FWidth + X) * ApngBytesPerPixel;
      if (FCurrent[Base] <> FPrevious[Base])
        or (FCurrent[Base + 1] <> FPrevious[Base + 1])
        or (FCurrent[Base + 2] <> FPrevious[Base + 2]) then
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

// Filters one scanline into FCandidate and returns its sum of signed
// magnitudes — the standard heuristic for which filter will deflate
// smallest.
//
// A subframe is unfiltered on its own, so "the byte to the left" and
// "the byte above" are the subframe's, not the canvas's: outside it they
// are zero, which is exactly what PNG says about the edges of an image.
// AAbove < 0 means there is no line above inside this subframe.
//
// One loop per filter, written out. Selecting the predictor per byte
// instead — one loop with a `case` in it — measured about a third of the
// encoder's whole frame time, because this runs over every byte of every
// line five times over.
function TApngEncoder.ScoreFilter(AFilter, ARow, AAbove,
  AStride: Integer): Integer;
var
  X, Pixel, Value, Total, Left, Up, UpLeft, First: Integer;
begin
  Total := 0;
  Pixel := ApngBytesPerPixel;
  case AFilter of
    1:
      begin
        // Sub. The first pixel of a line has nothing to its left, so it
        // is written through; after that the loop needs no bounds test.
        First := Min(Pixel, AStride);
        for X := 0 to First - 1 do
        begin
          Value := FCurrent[ARow + X];
          FCandidate[X] := Byte(Value);
          if Value < 128 then
            Inc(Total, Value)
          else
            Inc(Total, 256 - Value);
        end;
        for X := First to AStride - 1 do
        begin
          Value := (FCurrent[ARow + X] - FCurrent[ARow + X - Pixel]) and $FF;
          FCandidate[X] := Byte(Value);
          if Value < 128 then
            Inc(Total, Value)
          else
            Inc(Total, 256 - Value);
        end;
      end;
    2:
      // Up. On the subframe's first line there is nothing above, which
      // makes this filter None; the branch is hoisted out of the loop.
      if AAbove < 0 then
        for X := 0 to AStride - 1 do
        begin
          Value := FCurrent[ARow + X];
          FCandidate[X] := Byte(Value);
          if Value < 128 then
            Inc(Total, Value)
          else
            Inc(Total, 256 - Value);
        end
      else
        for X := 0 to AStride - 1 do
        begin
          Value := (FCurrent[ARow + X] - FCurrent[AAbove + X]) and $FF;
          FCandidate[X] := Byte(Value);
          if Value < 128 then
            Inc(Total, Value)
          else
            Inc(Total, 256 - Value);
        end;
    3:
      // Average.
      for X := 0 to AStride - 1 do
      begin
        if X >= Pixel then
          Left := FCurrent[ARow + X - Pixel]
        else
          Left := 0;
        if AAbove >= 0 then
          Up := FCurrent[AAbove + X]
        else
          Up := 0;
        Value := (FCurrent[ARow + X] - (Left + Up) div 2) and $FF;
        FCandidate[X] := Byte(Value);
        if Value < 128 then
          Inc(Total, Value)
        else
          Inc(Total, 256 - Value);
      end;
    4:
      // Paeth.
      for X := 0 to AStride - 1 do
      begin
        if X >= Pixel then
          Left := FCurrent[ARow + X - Pixel]
        else
          Left := 0;
        if AAbove >= 0 then
          Up := FCurrent[AAbove + X]
        else
          Up := 0;
        if (AAbove >= 0) and (X >= Pixel) then
          UpLeft := FCurrent[AAbove + X - Pixel]
        else
          UpLeft := 0;
        Value := (FCurrent[ARow + X] - PaethPredictor(Left, Up, UpLeft))
          and $FF;
        FCandidate[X] := Byte(Value);
        if Value < 128 then
          Inc(Total, Value)
        else
          Inc(Total, 256 - Value);
      end;
  else
    // None.
    for X := 0 to AStride - 1 do
    begin
      Value := FCurrent[ARow + X];
      FCandidate[X] := Byte(Value);
      if Value < 128 then
        Inc(Total, Value)
      else
        Inc(Total, 256 - Value);
    end;
  end;
  Result := Total;
end;

// Fills FRaw with the subframe's filtered scanlines and returns how many
// bytes of it are used. Every line tries all five filters and keeps the
// smallest, which is the difference between an APNG twice the size of
// the movie and one that is a fraction of it.
function TApngEncoder.FilterRectangle(ALeft, ATop, AWidth,
  AHeight: Integer): Integer;
var
  Y, Filter, Stride, Row, Above, BestFilter, Score, BestScore: Integer;
begin
  Stride := AWidth * ApngBytesPerPixel;
  Result := 0;
  for Y := 0 to AHeight - 1 do
  begin
    Row := ((ATop + Y) * FWidth + ALeft) * ApngBytesPerPixel;
    if Y = 0 then
      Above := -1
    else
      Above := ((ATop + Y - 1) * FWidth + ALeft) * ApngBytesPerPixel;
    BestFilter := 0;
    BestScore := MaxInt;
    for Filter := 0 to 4 do
    begin
      Score := ScoreFilter(Filter, Row, Above, Stride);
      if Score < BestScore then
      begin
        BestScore := Score;
        BestFilter := Filter;
        Move(FCandidate[0], FBest[0], Stride);
      end;
    end;
    FRaw[Result] := Byte(BestFilter);
    Inc(Result);
    Move(FBest[0], FRaw[Result], Stride);
    Inc(Result, Stride);
  end;
end;

function TApngEncoder.Deflate(const ASource: TBytes; ALength: Integer): TBytes;
var
  Buffer: TMemoryStream;
  Compressor: TCompressionStream;
begin
  Result := nil;
  Buffer := TMemoryStream.Create;
  try
    // clDefault, not clMax: measured on a real recording, level 9 cost
    // 63% more encoding time for 0.8% fewer bytes.
    Compressor := TCompressionStream.Create(clDefault, Buffer);
    try
      if ALength > 0 then
        Compressor.WriteBuffer(ASource[0], ALength);
    finally
      // The zlib trailer is only written when the stream is destroyed.
      Compressor.Free;
    end;
    SetLength(Result, Buffer.Size);
    if Buffer.Size > 0 then
    begin
      Buffer.Position := 0;
      Buffer.ReadBuffer(Result[0], Buffer.Size);
    end;
  finally
    Buffer.Free;
  end;
end;

// The first frame's pixels are the PNG's own image, so they go in IDAT;
// every later frame goes in an fdAT that carries the next sequence
// number ahead of the same zlib stream.
procedure TApngEncoder.WriteFrameData(const ACompressed: TBytes);
var
  Payload: TBytes;
begin
  if FFrameCount = 0 then
  begin
    WriteChunk('IDAT', ACompressed[0], Length(ACompressed));
    Exit;
  end;
  SetLength(Payload, Length(ACompressed) + 4);
  Payload[0] := Byte((FSequence shr 24) and $FF);
  Payload[1] := Byte((FSequence shr 16) and $FF);
  Payload[2] := Byte((FSequence shr 8) and $FF);
  Payload[3] := Byte(FSequence and $FF);
  Inc(FSequence);
  if Length(ACompressed) > 0 then
    Move(ACompressed[0], Payload[4], Length(ACompressed));
  WriteChunk('fdAT', Payload[0], Length(Payload));
end;

function TApngEncoder.Open(const APath: string; out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  if (FWidth <= 0) or (FHeight <= 0) then
  begin
    AError := 'the APNG canvas is empty';
    Exit;
  end;
  if (FWidth > ApngMaxDimension) or (FHeight > ApngMaxDimension) then
  begin
    AError := Format('an APNG canvas cannot exceed %d pixels on a side',
      [ApngMaxDimension]);
    Exit;
  end;
  // In Int64, before a single SetLength: a canvas inside the per-side
  // bound can still ask for a buffer no 32-bit index reaches.
  if Int64(FHeight) * (1 + Int64(FWidth) * ApngBytesPerPixel)
    > ApngMaxFrameBytes then
  begin
    AError := Format('a %dx%d APNG canvas needs more than %d MB a frame',
      [FWidth, FHeight, ApngMaxFrameBytes div (1024 * 1024)]);
    Exit;
  end;
  SetLength(FCurrent, FWidth * FHeight * ApngBytesPerPixel);
  SetLength(FPrevious, FWidth * FHeight * ApngBytesPerPixel);
  // One filter byte per line plus the line itself, for the largest
  // subframe there can be.
  SetLength(FRaw, FHeight * (1 + FWidth * ApngBytesPerPixel));
  SetLength(FCandidate, FWidth * ApngBytesPerPixel);
  SetLength(FBest, FWidth * ApngBytesPerPixel);
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
    WriteSignature;
    WriteHeaderChunk;
    WriteAnimationControl;
    Result := True;
  except
    on E: Exception do
      AError := 'writing ' + APath + ': ' + E.Message;
  end;
end;

function TApngEncoder.AddFrame(const APixels: PByte; ABytesPerRow,
  ADelayTicks: Integer; out AError: string): Boolean;
var
  Left, Top, Right, Bottom, RawLength: Integer;
  Compressed: TBytes;
begin
  Result := False;
  AError := '';
  if FOutput = nil then
  begin
    AError := 'the APNG is not open';
    Exit;
  end;
  if FFrameCount >= High(Cardinal) div 2 then
  begin
    AError := 'too many APNG frames';
    Exit;
  end;
  try
    CaptureFrame(APixels, ABytesPerRow);
    if FHasPrevious then
    begin
      if not ChangedRectangle(Left, Top, Right, Bottom) then
      begin
        // Nothing moved: one pixel of the colour already on the canvas,
        // carrying only the delay.
        Left := 0;
        Top := 0;
        Right := 0;
        Bottom := 0;
      end;
    end
    else
    begin
      // APNG requires the first frame to cover the whole image.
      Left := 0;
      Top := 0;
      Right := FWidth - 1;
      Bottom := FHeight - 1;
    end;
    RawLength := FilterRectangle(Left, Top, Right - Left + 1,
      Bottom - Top + 1);
    Compressed := Deflate(FRaw, RawLength);
    WriteFrameControl(Left, Top, Right - Left + 1, Bottom - Top + 1,
      ADelayTicks);
    WriteFrameData(Compressed);
    Move(FCurrent[0], FPrevious[0], Length(FCurrent));
    FHasPrevious := True;
    Inc(FFrameCount);
    Result := True;
  except
    on E: Exception do
      AError := 'writing an APNG frame: ' + E.Message;
  end;
end;

function TApngEncoder.Finish(out AError: string): Boolean;
var
  Data: array[0..7] of Byte;
  Crc: Cardinal;
  Header: array[0..3] of AnsiChar;
begin
  Result := False;
  AError := '';
  if FOutput = nil then
  begin
    AError := 'the APNG is not open';
    Exit;
  end;
  if FFrameCount = 0 then
  begin
    AError := 'the APNG holds no frames';
    FreeAndNil(FOutput);
    Exit;
  end;
  try
    FillChar(Data, SizeOf(Data), 0);
    WriteChunk('IEND', Data[0], 0);
    // Patch acTL now that the frame count is known: its four data bytes
    // and the chunk's CRC, which covers the type and the data.
    FOutput.Position := FFrameCountOffset;
    Data[0] := Byte((FFrameCount shr 24) and $FF);
    Data[1] := Byte((FFrameCount shr 16) and $FF);
    Data[2] := Byte((FFrameCount shr 8) and $FF);
    Data[3] := Byte(FFrameCount and $FF);
    Data[4] := 0;
    Data[5] := 0;
    Data[6] := 0;
    Data[7] := ApngLoopForever;
    FOutput.WriteBuffer(Data[0], SizeOf(Data));
    Header[0] := 'a';
    Header[1] := 'c';
    Header[2] := 'T';
    Header[3] := 'L';
    Crc := CrcUpdate($FFFFFFFF, Header[0], 4);
    Crc := CrcUpdate(Crc, Data[0], SizeOf(Data)) xor $FFFFFFFF;
    Data[0] := Byte((Crc shr 24) and $FF);
    Data[1] := Byte((Crc shr 16) and $FF);
    Data[2] := Byte((Crc shr 8) and $FF);
    Data[3] := Byte(Crc and $FF);
    FOutput.WriteBuffer(Data[0], 4);
    FreeAndNil(FOutput);
    Result := True;
  except
    on E: Exception do
    begin
      AError := 'finishing the APNG: ' + E.Message;
      FreeAndNil(FOutput);
    end;
  end;
end;

end.

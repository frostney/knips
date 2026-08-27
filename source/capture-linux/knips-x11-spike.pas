program KnipsX11Spike;

// SPIKE runner for Knips.Capture.X11. Grabs one frame from an X display
// and hands it straight to the platform-neutral GIF encoder, so the proof
// covers the whole width of a Linux recording path in miniature:
//
//   X11 root window -> MIT-SHM -> TBgraImage -> TGifQuantizer -> a .gif
//
// It is run headless against Xvfb by tools/ci/linux-gate.sh. Exit 0 means
// the frame arrived, its dimensions matched, and a real GIF came out the
// other end; anything else prints why and exits 1.
//
//   knips-x11-spike [--display=:99] [--size=WxH] [--out=frame.gif]
//                   [--paint=RRGGBB]
//
// --paint fills the root window with a known colour first and then checks
// that every captured pixel came back as that colour. That is the part
// worth having: "not black" would pass on a frame with the channels
// swapped, and BGRA-vs-RGBA is exactly the mistake a capture path makes.
//
// Not part of the shipped binary: it lives outside lwpt's [build] entries
// and is compiled by the gate with `fpc @lwpt.cfg` plus this directory.

{$I Knips.inc}

uses
  SysUtils,

  {$IFDEF LINUX}
  Knips.Capture.X11,
  Knips.Export.Bitmap,
  Knips.Export.Gif,
  {$ENDIF}
  Classes;

{$IFDEF LINUX}

const
  DefaultWidth = 320;
  DefaultHeight = 200;

function ArgumentValue(const AName: string; const ADefault: string): string;
var
  Index: Integer;
  Prefix: string;
begin
  Result := ADefault;
  Prefix := '--' + AName + '=';
  for Index := 1 to ParamCount do
    if Copy(ParamStr(Index), 1, Length(Prefix)) = Prefix then
      Result := Copy(ParamStr(Index), Length(Prefix) + 1, MaxInt);
end;

function ParseSize(const AText: string; out AWidth, AHeight: Integer): Boolean;
var
  Separator: Integer;
begin
  Result := False;
  Separator := Pos('x', LowerCase(AText));
  if Separator < 2 then
    Exit;
  Result := TryStrToInt(Copy(AText, 1, Separator - 1), AWidth)
    and TryStrToInt(Copy(AText, Separator + 1, MaxInt), AHeight)
    and (AWidth > 0) and (AHeight > 0);
end;

// How much of the frame is not pure black, as a crude "did anything
// actually get captured" signal. Xvfb's default root is black, so the gate
// paints something onto it first.
function NonBlackPixels(const AFrame: TBgraImage): Int64;
var
  Y: Integer;
  X: Integer;
  Row: PByte;
begin
  Result := 0;
  for Y := 0 to AFrame.Height - 1 do
  begin
    Row := BgraImageRow(AFrame, Y);
    for X := 0 to AFrame.Width - 1 do
    begin
      if ((Row + BgraBlueOffset)^ <> 0) or ((Row + BgraGreenOffset)^ <> 0)
        or ((Row + BgraRedOffset)^ <> 0) then
        Inc(Result);
      Inc(Row, BgraBytesPerPixel);
    end;
  end;
end;

function ParseColor(const AText: string; out ARed, AGreen,
  ABlue: Byte): Boolean;
var
  Value: Integer;
begin
  Result := (Length(AText) = 6) and TryStrToInt('$' + AText, Value);
  if not Result then
    Exit;
  ARed := Byte(Value shr 16);
  AGreen := Byte(Value shr 8);
  ABlue := Byte(Value);
end;

// How many pixels are not exactly the painted colour, opaque. Zero is the
// only acceptable answer for a solid fill: it proves the channel order and
// the alpha fill-in as well as the transport.
function MismatchedPixels(const AFrame: TBgraImage;
  ARed, AGreen, ABlue: Byte): Int64;
var
  Y: Integer;
  X: Integer;
  Row: PByte;
begin
  Result := 0;
  for Y := 0 to AFrame.Height - 1 do
  begin
    Row := BgraImageRow(AFrame, Y);
    for X := 0 to AFrame.Width - 1 do
    begin
      if ((Row + BgraBlueOffset)^ <> ABlue)
        or ((Row + BgraGreenOffset)^ <> AGreen)
        or ((Row + BgraRedOffset)^ <> ARed)
        or ((Row + BgraAlphaOffset)^ <> 255) then
        Inc(Result);
      Inc(Row, BgraBytesPerPixel);
    end;
  end;
end;

function WriteGif(const AFrame: TBgraImage; const APath: string;
  out AError: string): Boolean;
var
  Quantizer: TGifQuantizer;
  Encoder: TGifEncoder;
  Palette: TGifPalette;
begin
  Result := False;
  AError := '';
  Encoder := nil;
  Quantizer := TGifQuantizer.Create;
  try
    Quantizer.SampleFrame(BgraImageRow(AFrame, 0), AFrame.BytesPerRow,
      AFrame.Width, AFrame.Height);
    Palette := Quantizer.BuildPalette(256);
    Encoder := TGifEncoder.Create(AFrame.Width, AFrame.Height, Palette, True);
    if not Encoder.Open(APath, AError) then
      Exit;
    if not Encoder.AddFrame(BgraImageRow(AFrame, 0), AFrame.BytesPerRow,
      10, AError) then
      Exit;
    if not Encoder.Finish(AError) then
      Exit;
    WriteLn(Format('gif:     %s, %d byte(s), %d colour(s)',
      [APath, Encoder.BytesWritten, Encoder.TableEntries]));
    Result := True;
  finally
    Encoder.Free;
    Quantizer.Free;
  end;
end;

function Run: Integer;
var
  Grabber: TX11FrameGrabber;
  Frame: TBgraImage;
  Error: string;
  DisplayName: string;
  OutputPath: string;
  Width: Integer;
  Height: Integer;
  Painted: Boolean;
  Red: Byte;
  Green: Byte;
  Blue: Byte;
  Mismatches: Int64;
begin
  Result := 1;
  DisplayName := ArgumentValue('display', '');
  OutputPath := ArgumentValue('out', '');
  Painted := ParseColor(ArgumentValue('paint', ''), Red, Green, Blue);
  Width := DefaultWidth;
  Height := DefaultHeight;
  if not ParseSize(ArgumentValue('size', ''), Width, Height) then
  begin
    Width := DefaultWidth;
    Height := DefaultHeight;
  end;

  Grabber := TX11FrameGrabber.Create;
  try
    if not Grabber.Open(DisplayName, Error) then
    begin
      WriteLn('x11-spike: ', Error);
      Exit;
    end;
    WriteLn(Format('display: %dx%d',
      [Grabber.ScreenWidth, Grabber.ScreenHeight]));
    if Width > Grabber.ScreenWidth then
      Width := Grabber.ScreenWidth;
    if Height > Grabber.ScreenHeight then
      Height := Grabber.ScreenHeight;

    if Painted then
    begin
      if not Grabber.PaintRoot(Grabber.ScreenWidth, Grabber.ScreenHeight,
        Red, Green, Blue, Error) then
      begin
        WriteLn('x11-spike: ', Error);
        Exit;
      end;
      WriteLn(Format('painted: #%.2x%.2x%.2x', [Red, Green, Blue]));
    end;

    if not Grabber.PrepareFrame(Width, Height, Error) then
    begin
      WriteLn('x11-spike: ', Error);
      Exit;
    end;
    if not Grabber.Grab(0, 0, Frame, Error) then
    begin
      WriteLn('x11-spike: ', Error);
      Exit;
    end;
    if (Frame.Width <> Width) or (Frame.Height <> Height) then
    begin
      WriteLn(Format('x11-spike: got %dx%d, wanted %dx%d',
        [Frame.Width, Frame.Height, Width, Height]));
      Exit;
    end;
    WriteLn(Format('frame:   %dx%d, %d byte(s) per row, %d non-black pixel(s)',
      [Frame.Width, Frame.Height, Frame.BytesPerRow, NonBlackPixels(Frame)]));

    if Painted then
    begin
      Mismatches := MismatchedPixels(Frame, Red, Green, Blue);
      WriteLn(Format('checked: %d pixel(s) differ from the painted colour',
        [Mismatches]));
      if Mismatches <> 0 then
        Exit;
    end;

    if OutputPath <> '' then
      if not WriteGif(Frame, OutputPath, Error) then
      begin
        WriteLn('x11-spike: ', Error);
        Exit;
      end;
  finally
    Grabber.Free;
  end;
  WriteLn('x11-spike: ok');
  Result := 0;
end;

{$ENDIF}

begin
  {$IFDEF LINUX}
  ExitCode := Run;
  {$ELSE}
  WriteLn('x11-spike: Linux only');
  ExitCode := 3;
  {$ENDIF}
end.

program Knips.Export.Bitmap.Test;

{$I Knips.inc}

uses
  SysUtils,

  Knips.Export.Bitmap,
  TestingPascalLibrary;

type
  TAspectTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestKeepsAspectRatio;
    procedure TestNeverCollapsesToZero;
    procedure TestRejectsEmptyInput;
  end;

  TCopyTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestCopiesAcrossAPaddedStride;
  end;

  TResizeTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSameSizeIsAnExactCopy;
    procedure TestUpscaleReplicatesTheCorners;
    procedure TestSolidColourSurvivesDownscaling;
    procedure TestBoxReduceAveragesTheBlock;
    procedure TestResampleHitsTheRequestedSize;
    procedure TestCheckerboardAveragesToTheMiddle;
    procedure TestExactHalvingIsTheBoxAverageAlone;
  end;

  TBicubicTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSameSizeIsTheIdentity;
    procedure TestSolidColourSurvivesAnyRatio;
    procedure TestImpulseResponseIsSymmetric;
    procedure TestOvershootIsClampedNotWrapped;
    procedure TestKeepsMoreEdgeContrastThanBilinear;
  end;

{ ---------------------------------------------------------------- helpers }

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

function RedAt(const AImage: TBgraImage; AX, AY: Integer): Integer;
begin
  Result := AImage.Pixels[AY * AImage.BytesPerRow + AX * BgraBytesPerPixel
    + BgraRedOffset];
end;

function GreenAt(const AImage: TBgraImage; AX, AY: Integer): Integer;
begin
  Result := AImage.Pixels[AY * AImage.BytesPerRow + AX * BgraBytesPerPixel
    + BgraGreenOffset];
end;

function BlueAt(const AImage: TBgraImage; AX, AY: Integer): Integer;
begin
  Result := AImage.Pixels[AY * AImage.BytesPerRow + AX * BgraBytesPerPixel
    + BgraBlueOffset];
end;

procedure FillSolid(var AImage: TBgraImage; ARed, AGreen, ABlue: Byte);
var
  X, Y: Integer;
begin
  for Y := 0 to AImage.Height - 1 do
    for X := 0 to AImage.Width - 1 do
      SetPixel(AImage, X, Y, ARed, AGreen, ABlue);
end;

// Hard-edged squares of ACell pixels — the stand-in for what a screen
// recording is mostly made of, and the pattern a soft kernel destroys.
procedure FillCheckerboard(var AImage: TBgraImage; ACell: Integer;
  ADark, ALight: Byte);
var
  X, Y: Integer;
begin
  for Y := 0 to AImage.Height - 1 do
    for X := 0 to AImage.Width - 1 do
      if (((X div ACell) + (Y div ACell)) and 1) = 0 then
        SetPixel(AImage, X, Y, ADark, ADark, ADark)
      else
        SetPixel(AImage, X, Y, ALight, ALight, ALight);
end;

// Total absolute difference between neighbouring pixels, both axes: the
// blunt measure of how much edge a resample left standing.
function EdgeContrast(const AImage: TBgraImage): Int64;
var
  X, Y: Integer;
begin
  Result := 0;
  for Y := 0 to AImage.Height - 1 do
    for X := 0 to AImage.Width - 1 do
    begin
      if X > 0 then
        Inc(Result, Abs(RedAt(AImage, X, Y) - RedAt(AImage, X - 1, Y)));
      if Y > 0 then
        Inc(Result, Abs(RedAt(AImage, X, Y) - RedAt(AImage, X, Y - 1)));
    end;
end;

{ TAspectTests }

procedure TAspectTests.SetupTests;
begin
  Test('the target height follows the source aspect ratio',
    TestKeepsAspectRatio);
  Test('a very wide source never scales to a zero height',
    TestNeverCollapsesToZero);
  Test('an empty source or target yields zero', TestRejectsEmptyInput);
end;

procedure TAspectTests.TestKeepsAspectRatio;
begin
  Expect<Integer>(ScaledHeightForWidth(1920, 1080, 960)).ToBe(540);
  Expect<Integer>(ScaledHeightForWidth(1920, 1080, 480)).ToBe(270);
  Expect<Integer>(ScaledHeightForWidth(800, 600, 400)).ToBe(300);
end;

procedure TAspectTests.TestNeverCollapsesToZero;
begin
  Expect<Integer>(ScaledHeightForWidth(4000, 10, 100)).ToBe(1);
end;

procedure TAspectTests.TestRejectsEmptyInput;
begin
  Expect<Integer>(ScaledHeightForWidth(0, 100, 50)).ToBe(0);
  Expect<Integer>(ScaledHeightForWidth(100, 100, 0)).ToBe(0);
end;

{ TCopyTests }

procedure TCopyTests.SetupTests;
begin
  Test('a padded source stride is honoured',
    TestCopiesAcrossAPaddedStride);
end;

procedure TCopyTests.TestCopiesAcrossAPaddedStride;
var
  Source: TBytes;
  Target: TBgraImage;
  X, Y, Stride: Integer;
begin
  // CoreVideo pads rows out to its own alignment, so the copy has to
  // walk the source by its stride rather than by width * 4.
  Stride := 3 * BgraBytesPerPixel + 16;
  SetLength(Source, Stride * 2);
  for Y := 0 to 1 do
    for X := 0 to 2 do
    begin
      Source[Y * Stride + X * BgraBytesPerPixel + BgraRedOffset] :=
        Byte(10 * Y + X);
      Source[Y * Stride + X * BgraBytesPerPixel + BgraAlphaOffset] := 255;
    end;
  BgraImageCopyFrom(Target, @Source[0], Stride, 3, 2);
  Expect<Integer>(Target.Width).ToBe(3);
  Expect<Integer>(Target.Height).ToBe(2);
  Expect<Integer>(Target.BytesPerRow).ToBe(12);
  Expect<Integer>(RedAt(Target, 0, 0)).ToBe(0);
  Expect<Integer>(RedAt(Target, 2, 0)).ToBe(2);
  Expect<Integer>(RedAt(Target, 0, 1)).ToBe(10);
  Expect<Integer>(RedAt(Target, 2, 1)).ToBe(12);
end;

{ TResizeTests }

procedure TResizeTests.SetupTests;
begin
  Test('resizing to the same size copies pixel for pixel',
    TestSameSizeIsAnExactCopy);
  Test('an upscale replicates the corner pixels',
    TestUpscaleReplicatesTheCorners);
  Test('a solid colour survives a downscale untouched',
    TestSolidColourSurvivesDownscaling);
  Test('the box reduction averages each block',
    TestBoxReduceAveragesTheBlock);
  Test('resampling lands on the requested size',
    TestResampleHitsTheRequestedSize);
  Test('a checkerboard halves to the average of its two colours',
    TestCheckerboardAveragesToTheMiddle);
  Test('an exact 2:1 reduction is the box average and nothing after it',
    TestExactHalvingIsTheBoxAverageAlone);
end;

procedure TResizeTests.TestSameSizeIsAnExactCopy;
var
  Source, Target: TBgraImage;
  X, Y: Integer;
begin
  BgraImageResize(Source, 4, 3);
  BgraImageResize(Target, 4, 3);
  for Y := 0 to 2 do
    for X := 0 to 3 do
      SetPixel(Source, X, Y, Byte(X * 60), Byte(Y * 80), Byte(X + Y));
  BgraResizeBilinear(@Source.Pixels[0], Source.BytesPerRow, 4, 3,
    @Target.Pixels[0], Target.BytesPerRow, 4, 3);
  for Y := 0 to 2 do
    for X := 0 to 3 do
    begin
      Expect<Integer>(RedAt(Target, X, Y)).ToBe(RedAt(Source, X, Y));
      Expect<Integer>(GreenAt(Target, X, Y)).ToBe(GreenAt(Source, X, Y));
      Expect<Integer>(BlueAt(Target, X, Y)).ToBe(BlueAt(Source, X, Y));
    end;
end;

procedure TResizeTests.TestUpscaleReplicatesTheCorners;
var
  Source, Target: TBgraImage;
begin
  BgraImageResize(Source, 2, 2);
  BgraImageResize(Target, 4, 4);
  SetPixel(Source, 0, 0, 200, 0, 0);
  SetPixel(Source, 1, 0, 0, 200, 0);
  SetPixel(Source, 0, 1, 0, 0, 200);
  SetPixel(Source, 1, 1, 100, 100, 100);
  BgraResizeBilinear(@Source.Pixels[0], Source.BytesPerRow, 2, 2,
    @Target.Pixels[0], Target.BytesPerRow, 4, 4);
  Expect<Integer>(RedAt(Target, 0, 0)).ToBe(200);
  Expect<Integer>(GreenAt(Target, 3, 0)).ToBe(200);
  Expect<Integer>(BlueAt(Target, 0, 3)).ToBe(200);
  Expect<Integer>(RedAt(Target, 3, 3)).ToBe(100);
end;

procedure TResizeTests.TestSolidColourSurvivesDownscaling;
var
  Source, Target: TBgraImage;
  X, Y: Integer;
begin
  BgraImageResize(Source, 17, 11);
  BgraImageResize(Target, 5, 3);
  FillSolid(Source, 33, 77, 210);
  BgraResizeBilinear(@Source.Pixels[0], Source.BytesPerRow, 17, 11,
    @Target.Pixels[0], Target.BytesPerRow, 5, 3);
  for Y := 0 to 2 do
    for X := 0 to 4 do
    begin
      Expect<Integer>(RedAt(Target, X, Y)).ToBe(33);
      Expect<Integer>(GreenAt(Target, X, Y)).ToBe(77);
      Expect<Integer>(BlueAt(Target, X, Y)).ToBe(210);
    end;
end;

procedure TResizeTests.TestBoxReduceAveragesTheBlock;
var
  Source, Target: TBgraImage;
begin
  BgraImageResize(Source, 4, 4);
  BgraImageResize(Target, 2, 2);
  // Each 2x2 block holds 0, 10, 20 and 30, so every output is 15.
  SetPixel(Source, 0, 0, 0, 0, 0);
  SetPixel(Source, 1, 0, 10, 10, 10);
  SetPixel(Source, 0, 1, 20, 20, 20);
  SetPixel(Source, 1, 1, 30, 30, 30);
  SetPixel(Source, 2, 0, 0, 0, 0);
  SetPixel(Source, 3, 0, 10, 10, 10);
  SetPixel(Source, 2, 1, 20, 20, 20);
  SetPixel(Source, 3, 1, 30, 30, 30);
  SetPixel(Source, 0, 2, 0, 0, 0);
  SetPixel(Source, 1, 2, 10, 10, 10);
  SetPixel(Source, 0, 3, 20, 20, 20);
  SetPixel(Source, 1, 3, 30, 30, 30);
  SetPixel(Source, 2, 2, 0, 0, 0);
  SetPixel(Source, 3, 2, 10, 10, 10);
  SetPixel(Source, 2, 3, 20, 20, 20);
  SetPixel(Source, 3, 3, 30, 30, 30);
  BgraBoxReduce(@Source.Pixels[0], Source.BytesPerRow, 4, 4,
    @Target.Pixels[0], Target.BytesPerRow, 2, 2);
  Expect<Integer>(RedAt(Target, 0, 0)).ToBe(15);
  Expect<Integer>(GreenAt(Target, 1, 0)).ToBe(15);
  Expect<Integer>(BlueAt(Target, 1, 1)).ToBe(15);
end;

procedure TResizeTests.TestResampleHitsTheRequestedSize;
var
  Source, Target: TBgraImage;
  Scratch: TResampleScratch;
  X, Y: Integer;
begin
  BgraImageResize(Source, 64, 48);
  FillSolid(Source, 90, 140, 240);
  BgraImageResize(Target, 12, ScaledHeightForWidth(64, 48, 12));
  Expect<Integer>(Target.Height).ToBe(9);
  BgraResample(@Source.Pixels[0], Source.BytesPerRow, 64, 48, Target,
    Scratch);
  for Y := 0 to Target.Height - 1 do
    for X := 0 to Target.Width - 1 do
    begin
      Expect<Integer>(RedAt(Target, X, Y)).ToBe(90);
      Expect<Integer>(BlueAt(Target, X, Y)).ToBe(240);
    end;
end;

procedure TResizeTests.TestCheckerboardAveragesToTheMiddle;
var
  Source, Target: TBgraImage;
  Scratch: TResampleScratch;
  X, Y: Integer;
begin
  BgraImageResize(Source, 16, 16);
  for Y := 0 to 15 do
    for X := 0 to 15 do
      if ((X + Y) and 1) = 0 then
        SetPixel(Source, X, Y, 0, 0, 0)
      else
        SetPixel(Source, X, Y, 200, 200, 200);
  BgraImageResize(Target, 8, 8);
  BgraResample(@Source.Pixels[0], Source.BytesPerRow, 16, 16, Target,
    Scratch);
  // A 2x2 box over a checkerboard is always two black and two light
  // pixels, so the reduction is flat at half the light value.
  for Y := 0 to 7 do
    for X := 0 to 7 do
      Expect<Integer>(RedAt(Target, X, Y)).ToBe(100);
end;

procedure TResizeTests.TestExactHalvingIsTheBoxAverageAlone;
var
  Source, Target, Reference: TBgraImage;
  Scratch: TResampleScratch;
  X, Y: Integer;
begin
  // The app's one-click GIF asks for the recording's point size, which
  // on a 2x display is exactly this: BgraResample must stop after the
  // box pass rather than resample its own output a second time.
  BgraImageResize(Source, 32, 20);
  FillCheckerboard(Source, 3, 20, 230);
  BgraImageResize(Target, 16, 10);
  BgraResample(@Source.Pixels[0], Source.BytesPerRow, 32, 20, Target,
    Scratch);
  BgraImageResize(Reference, 16, 10);
  BgraBoxReduce(@Source.Pixels[0], Source.BytesPerRow, 32, 20,
    @Reference.Pixels[0], Reference.BytesPerRow, 2, 2);
  for Y := 0 to 9 do
    for X := 0 to 15 do
      Expect<Integer>(RedAt(Target, X, Y)).ToBe(RedAt(Reference, X, Y));
end;

{ TBicubicTests }

procedure TBicubicTests.SetupTests;
begin
  Test('resizing to the same size is byte-for-byte the identity',
    TestSameSizeIsTheIdentity);
  Test('a solid colour comes back unchanged at any ratio',
    TestSolidColourSurvivesAnyRatio);
  Test('the impulse response is symmetric about the impulse',
    TestImpulseResponseIsSymmetric);
  Test('the negative lobes clamp instead of wrapping',
    TestOvershootIsClampedNotWrapped);
  Test('a checkerboard keeps more edge contrast than bilinear leaves',
    TestKeepsMoreEdgeContrastThanBilinear);
end;

procedure TBicubicTests.TestSameSizeIsTheIdentity;
var
  Source, Target, Scratch: TBgraImage;
  X, Y: Integer;
begin
  BgraImageResize(Source, 9, 7);
  BgraImageResize(Target, 9, 7);
  for Y := 0 to 6 do
    for X := 0 to 8 do
      SetPixel(Source, X, Y, Byte(X * 28), Byte(Y * 36), Byte(255 - X * 20));
  BgraResizeBicubic(@Source.Pixels[0], Source.BytesPerRow, 9, 7,
    @Target.Pixels[0], Target.BytesPerRow, 9, 7, Scratch);
  for Y := 0 to 6 do
    for X := 0 to 8 do
    begin
      Expect<Integer>(RedAt(Target, X, Y)).ToBe(RedAt(Source, X, Y));
      Expect<Integer>(GreenAt(Target, X, Y)).ToBe(GreenAt(Source, X, Y));
      Expect<Integer>(BlueAt(Target, X, Y)).ToBe(BlueAt(Source, X, Y));
    end;
end;

procedure TBicubicTests.TestSolidColourSurvivesAnyRatio;
var
  Source, Target, Scratch: TBgraImage;
  X, Y: Integer;
begin
  // Only holds because the weights are normalised to sum to exactly
  // one after rounding; per-weight rounding alone drifts by a count.
  BgraImageResize(Source, 23, 19);
  FillSolid(Source, 41, 200, 137);
  BgraImageResize(Target, 13, 29);
  BgraResizeBicubic(@Source.Pixels[0], Source.BytesPerRow, 23, 19,
    @Target.Pixels[0], Target.BytesPerRow, 13, 29, Scratch);
  for Y := 0 to 28 do
    for X := 0 to 12 do
    begin
      Expect<Integer>(RedAt(Target, X, Y)).ToBe(41);
      Expect<Integer>(GreenAt(Target, X, Y)).ToBe(200);
      Expect<Integer>(BlueAt(Target, X, Y)).ToBe(137);
    end;
end;

procedure TBicubicTests.TestImpulseResponseIsSymmetric;
var
  Source, Target, Scratch: TBgraImage;
  X, Y: Integer;
begin
  // A lone bright pixel dead centre of an odd-sized field, scaled by an
  // odd integer: the response has to mirror in both axes, or the
  // sampling grid is off by a fraction of a pixel and every export is
  // shifted as well as filtered.
  BgraImageResize(Source, 7, 7);
  FillSolid(Source, 0, 0, 0);
  SetPixel(Source, 3, 3, 240, 240, 240);
  BgraImageResize(Target, 21, 21);
  BgraResizeBicubic(@Source.Pixels[0], Source.BytesPerRow, 7, 7,
    @Target.Pixels[0], Target.BytesPerRow, 21, 21, Scratch);
  for Y := 0 to 20 do
    for X := 0 to 20 do
    begin
      Expect<Integer>(RedAt(Target, X, Y)).ToBe(RedAt(Target, 20 - X, Y));
      Expect<Integer>(RedAt(Target, X, Y)).ToBe(RedAt(Target, X, 20 - Y));
    end;
  // And the impulse is still the brightest thing in the picture.
  Expect<Integer>(RedAt(Target, 10, 10)).ToBe(240);
end;

procedure TBicubicTests.TestOvershootIsClampedNotWrapped;
var
  Source, Target, Scratch: TBgraImage;
  X, Y, Value: Integer;
begin
  // A step from black to white overshoots at both ends. Clamped, the
  // dark side of the step stays dark; shifted rather than clamped, the
  // undershoot wraps and puts a bright halo against the black.
  BgraImageResize(Source, 16, 4);
  for Y := 0 to 3 do
    for X := 0 to 15 do
      if X < 8 then
        SetPixel(Source, X, Y, 0, 0, 0)
      else
        SetPixel(Source, X, Y, 255, 255, 255);
  BgraImageResize(Target, 40, 10);
  BgraResizeBicubic(@Source.Pixels[0], Source.BytesPerRow, 16, 4,
    @Target.Pixels[0], Target.BytesPerRow, 40, 10, Scratch);
  for Y := 0 to 9 do
    for X := 0 to 39 do
    begin
      Value := RedAt(Target, X, Y);
      // Everything well inside the dark half is black, everything well
      // inside the light half is white: no wrapped lobe either side.
      if X < 16 then
        Expect<Integer>(Value).ToBe(0);
      if X > 23 then
        Expect<Integer>(Value).ToBe(255);
    end;
end;

procedure TBicubicTests.TestKeepsMoreEdgeContrastThanBilinear;
var
  Source, Bicubic, Bilinear, Scratch: TBgraImage;
  BicubicContrast, BilinearContrast: Int64;
begin
  // The fractional step is where the softness lived: 48 -> 36 is 4:3,
  // the same shape as an 800 px cap applied to a 900 px point size.
  BgraImageResize(Source, 48, 48);
  FillCheckerboard(Source, 4, 16, 240);
  BgraImageResize(Bicubic, 36, 36);
  BgraImageResize(Bilinear, 36, 36);
  BgraResizeBicubic(@Source.Pixels[0], Source.BytesPerRow, 48, 48,
    @Bicubic.Pixels[0], Bicubic.BytesPerRow, 36, 36, Scratch);
  BgraResizeBilinear(@Source.Pixels[0], Source.BytesPerRow, 48, 48,
    @Bilinear.Pixels[0], Bilinear.BytesPerRow, 36, 36);
  BicubicContrast := EdgeContrast(Bicubic);
  BilinearContrast := EdgeContrast(Bilinear);
  Expect<Boolean>(BicubicContrast > BilinearContrast).ToBe(True);
  // Not a hair's breadth of a difference either: measured 210848
  // against 177408, a factor of 1.19, so 1.15 is the floor to defend.
  Expect<Boolean>(BicubicContrast * 20 > BilinearContrast * 23).ToBe(True);
end;

begin
  TestRunnerProgram.AddSuite(TAspectTests.Create('ScaledHeightForWidth'));
  TestRunnerProgram.AddSuite(TCopyTests.Create('BgraImageCopyFrom'));
  TestRunnerProgram.AddSuite(TResizeTests.Create('resampling'));
  TestRunnerProgram.AddSuite(TBicubicTests.Create('BgraResizeBicubic'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

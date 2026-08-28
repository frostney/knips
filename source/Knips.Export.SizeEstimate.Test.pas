program Knips.Export.SizeEstimate.Test;

// The export size estimate, checked on the properties the CLI and the
// playback window rely on:
//
//   - the estimate scales with what it should scale with — frames, area,
//     and the source movie's own bytes per pixel-frame — and does not
//     scale with anything else;
//   - the reported band really brackets the estimate, and the five real
//     exports the constants were fitted from all land inside it;
//   - --no-dither is cheaper than dithering and APNG is dearer than GIF,
//     which is the direction both really go;
//   - a passthrough trim gets no estimate at all, because it writes the
//     source's own bytes;
//   - the fallback says it is a fallback;
//   - the in-flight projection is linear in frames, is exact once every
//     frame is written, and refuses to answer before it has anything to
//     answer with;
//   - the byte formatter's units switch where they are meant to.
//
// The measured-exports test is the one that matters most: it is the whole
// justification for the constants, written down as an assertion so that
// changing one of them without re-measuring fails here.

{$I Knips.inc}

uses
  SysUtils,

  Knips.Export.SizeEstimate,
  Knips.Options,
  TestingPascalLibrary;

type
  TEstimateTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestScalesWithFramesAndArea;
    procedure TestScalesWithTheSourceMovieDensity;
    procedure TestBandBracketsTheEstimate;
    procedure TestNoDitherIsCheaper;
    procedure TestApngIsDearerThanGif;
    procedure TestApngHasItsOwnWiderBand;
    procedure TestATrimGetsNoEstimate;
    procedure TestDegenerateInputsGiveNothing;
  end;

  TFallbackTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestWithoutASourceSizeItSaysSo;
    procedure TestFallbackStillScales;
  end;

  TMeasuredTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheFiveMeasuredExportsLandInsideTheBand;
  end;

  TProjectionTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestProjectionIsLinearInFrames;
    procedure TestProjectionIsExactAtTheEnd;
    procedure TestProjectionRefusesWithoutData;
  end;

  TFormattingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestKilobytesBelowAMegabyte;
    procedure TestMegabytesAbove;
    procedure TestDescribeCarriesTheBand;
  end;

{ ---------------------------------------------------------------- helpers }

// The source density of a middling take: a.mp4 in the measured set.
const
  MiddlingDensity = 0.00948;

function GifEstimate(AWidth, AHeight: Integer; AFrames: Int64;
  ADensity: Double): TExportSizeEstimate;
begin
  Result := EstimateExportSize(efGif, AWidth, AHeight, AFrames, True,
    ADensity);
end;

procedure ExpectRatio(AActual, AExpected, ATolerance: Double;
  const AWhat: string);
var
  Shown: Double;
begin
  Shown := AActual;
  if Abs(AActual - AExpected) <= ATolerance then
    Shown := AExpected;
  Expect<string>(Format('%s = %.4f', [AWhat, Shown]))
    .ToBe(Format('%s = %.4f', [AWhat, AExpected]));
end;

{ --------------------------------------------------------------- estimate }

procedure TEstimateTests.SetupTests;
begin
  Test('twice the frames and twice the area is four times the bytes',
    TestScalesWithFramesAndArea);
  Test('a busier source movie means a bigger animation',
    TestScalesWithTheSourceMovieDensity);
  Test('the band brackets the estimate both ways',
    TestBandBracketsTheEstimate);
  Test('--no-dither estimates smaller than dithering',
    TestNoDitherIsCheaper);
  Test('APNG estimates larger than GIF for the same movie',
    TestApngIsDearerThanGif);
  Test('APNG carries its own, wider band', TestApngHasItsOwnWiderBand);
  Test('a passthrough trim has nothing to estimate',
    TestATrimGetsNoEstimate);
  Test('no frames, no size, no answer', TestDegenerateInputsGiveNothing);
end;

procedure TEstimateTests.TestScalesWithFramesAndArea;
var
  One, Four: TExportSizeEstimate;
begin
  One := GifEstimate(600, 400, 100, MiddlingDensity);
  Four := GifEstimate(600, 800, 200, MiddlingDensity);
  Expect<Boolean>(One.Bytes > 0).ToBe(True);
  ExpectRatio(Four.Bytes / One.Bytes, 4, 1E-6, 'four times');
end;

procedure TEstimateTests.TestScalesWithTheSourceMovieDensity;
var
  Quiet, Busy: TExportSizeEstimate;
begin
  Quiet := GifEstimate(600, 300, 130, 0.00171);
  Busy := GifEstimate(600, 300, 130, 0.01116);
  Expect<Boolean>(Busy.Bytes > Quiet.Bytes * 6).ToBe(True);
  ExpectRatio(Busy.Bytes / Quiet.Bytes, 0.01116 / 0.00171, 1E-3,
    'density ratio');
end;

procedure TEstimateTests.TestBandBracketsTheEstimate;
var
  Estimate: TExportSizeEstimate;
begin
  Estimate := GifEstimate(600, 400, 205, MiddlingDensity);
  Expect<Boolean>(Estimate.LowBytes < Estimate.Bytes).ToBe(True);
  Expect<Boolean>(Estimate.HighBytes > Estimate.Bytes).ToBe(True);
  ExpectRatio(Estimate.HighBytes / Estimate.Bytes, GifEstimateBand, 1E-3,
    'high');
  ExpectRatio(Estimate.Bytes / Estimate.LowBytes, GifEstimateBand, 1E-3,
    'low');
  Expect<Boolean>(Estimate.FromSource).ToBe(True);
end;

// APNG's band is its own and is wider, because its residuals are: the
// same content signal that predicts a GIF to within about 2x predicts an
// APNG to within about 13x (see ApngBytesPerSourceByte). A single band
// over both would be a claim about APNG that nothing measured supports.
procedure TEstimateTests.TestApngHasItsOwnWiderBand;
var
  Estimate: TExportSizeEstimate;
begin
  Estimate := EstimateExportSize(efApng, 600, 400, 205, True,
    MiddlingDensity);
  ExpectRatio(Estimate.HighBytes / Estimate.Bytes, ApngEstimateBand, 1E-3,
    'apng high');
  ExpectRatio(Estimate.Bytes / Estimate.LowBytes, ApngEstimateBand, 1E-3,
    'apng low');
  Expect<Boolean>(ApngEstimateBand > GifEstimateBand).ToBe(True);
end;

procedure TEstimateTests.TestNoDitherIsCheaper;
var
  Dithered, Plain: TExportSizeEstimate;
begin
  Dithered := EstimateExportSize(efGif, 600, 400, 100, True, MiddlingDensity);
  Plain := EstimateExportSize(efGif, 600, 400, 100, False, MiddlingDensity);
  Expect<Boolean>(Plain.Bytes < Dithered.Bytes).ToBe(True);
  ExpectRatio(Plain.Bytes / Dithered.Bytes, NoDitherFactor, 1E-3, 'dither');
end;

procedure TEstimateTests.TestApngIsDearerThanGif;
var
  Gif, Apng: TExportSizeEstimate;
begin
  Gif := EstimateExportSize(efGif, 600, 400, 100, True, MiddlingDensity);
  Apng := EstimateExportSize(efApng, 600, 400, 100, True, MiddlingDensity);
  Expect<Boolean>(Apng.Bytes > Gif.Bytes).ToBe(True);
  // Dither is meaningless for a truecolour format and must not move it.
  Expect<Int64>(EstimateExportSize(efApng, 600, 400, 100, False,
    MiddlingDensity).Bytes).ToBe(Apng.Bytes);
end;

procedure TEstimateTests.TestATrimGetsNoEstimate;
var
  Estimate: TExportSizeEstimate;
begin
  Estimate := EstimateExportSize(efMovie, 600, 400, 100, True,
    MiddlingDensity);
  Expect<Int64>(Estimate.Bytes).ToBe(Int64(0));
  Expect<string>(DescribeEstimate(Estimate)).ToBe('');
end;

procedure TEstimateTests.TestDegenerateInputsGiveNothing;
begin
  Expect<Int64>(GifEstimate(0, 400, 100, MiddlingDensity).Bytes)
    .ToBe(Int64(0));
  Expect<Int64>(GifEstimate(600, 0, 100, MiddlingDensity).Bytes)
    .ToBe(Int64(0));
  Expect<Int64>(GifEstimate(600, 400, 0, MiddlingDensity).Bytes)
    .ToBe(Int64(0));
  ExpectRatio(SourceBytesPerPixelFrame(0, 100, 600, 400), 0, 1E-12,
    'no bytes');
  ExpectRatio(SourceBytesPerPixelFrame(1000, 0, 600, 400), 0, 1E-12,
    'no frames');
  ExpectRatio(SourceBytesPerPixelFrame(1000, 100, 0, 400), 0, 1E-12,
    'no width');
end;

{ --------------------------------------------------------------- fallback }

procedure TFallbackTests.SetupTests;
begin
  Test('without the movie''s size the estimate says it is a guess',
    TestWithoutASourceSizeItSaysSo);
  Test('the fallback still scales with frames and area',
    TestFallbackStillScales);
end;

procedure TFallbackTests.TestWithoutASourceSizeItSaysSo;
var
  Estimate: TExportSizeEstimate;
begin
  Estimate := GifEstimate(600, 400, 100, 0);
  Expect<Boolean>(Estimate.Bytes > 0).ToBe(True);
  Expect<Boolean>(Estimate.FromSource).ToBe(False);
  Expect<Boolean>(Pos('very roughly', DescribeEstimate(Estimate)) > 0)
    .ToBe(True);
end;

procedure TFallbackTests.TestFallbackStillScales;
begin
  ExpectRatio(GifEstimate(600, 400, 200, 0).Bytes
    / GifEstimate(600, 400, 100, 0).Bytes, 2, 1E-6, 'frames');
  Expect<Int64>(GifEstimate(600, 400, 100, 0).Bytes)
    .ToBe(Round(100 * 600 * 400 * FallbackGifBytesPerPixel));
end;

{ --------------------------------------------------------------- measured
  The five exports the constants were fitted from. Source size, source
  frames and source pixels give the density; the output size and frame
  count give what the estimate has to bracket. Every one of them must
  land inside the reported band, and this is what stops a constant being
  changed without the measurements being redone. }

procedure TMeasuredTests.SetupTests;
begin
  Test('every measured export lands inside the reported band',
    TestTheFiveMeasuredExportsLandInsideTheBand);
end;

procedure TMeasuredTests.TestTheFiveMeasuredExportsLandInsideTheBand;
type
  TMeasured = record
    Name: string;
    SourceBytes: Int64;
    SourceFrames: Int64;
    SourceWidth: Integer;
    SourceHeight: Integer;
    OutWidth: Integer;
    OutHeight: Integer;
    OutFrames: Int64;
    ActualBytes: Int64;
  end;
const
  // Sixteen exports over seven takes at four output widths. The
  // native-size and quarter-size rows are the ones that matter most: an
  // earlier version of this model was calibrated only on halvings, and a
  // reviewer's heavily downscaled exports fell straight out of its band.
  Measured: array[0..15] of TMeasured = (
    (Name: 'quiet region, native'; SourceBytes: 1408314; SourceFrames: 145;
     SourceWidth: 1280; SourceHeight: 800; OutWidth: 1280; OutHeight: 800;
     OutFrames: 100; ActualBytes: 14866103),
    (Name: 'quiet region, half'; SourceBytes: 1408314; SourceFrames: 145;
     SourceWidth: 1280; SourceHeight: 800; OutWidth: 600; OutHeight: 375;
     OutFrames: 100; ActualBytes: 3752695),
    (Name: 'quiet region, quarter'; SourceBytes: 1408314; SourceFrames: 145;
     SourceWidth: 1280; SourceHeight: 800; OutWidth: 300; OutHeight: 188;
     OutFrames: 100; ActualBytes: 1076850),
    (Name: 'busy region, native'; SourceBytes: 3021255; SourceFrames: 282;
     SourceWidth: 1200; SourceHeight: 800; OutWidth: 1200; OutHeight: 800;
     OutFrames: 205; ActualBytes: 60592528),
    (Name: 'busy region, half'; SourceBytes: 3021255; SourceFrames: 282;
     SourceWidth: 1200; SourceHeight: 800; OutWidth: 600; OutHeight: 400;
     OutFrames: 205; ActualBytes: 15203378),
    (Name: 'busy region, quarter'; SourceBytes: 3021255; SourceFrames: 282;
     SourceWidth: 1200; SourceHeight: 800; OutWidth: 300; OutHeight: 200;
     OutFrames: 205; ActualBytes: 3840808),
    (Name: 'small region, native'; SourceBytes: 286270; SourceFrames: 189;
     SourceWidth: 1200; SourceHeight: 600; OutWidth: 1200; OutHeight: 600;
     OutFrames: 131; ActualBytes: 1742519),
    (Name: 'small region, half'; SourceBytes: 286270; SourceFrames: 189;
     SourceWidth: 1200; SourceHeight: 600; OutWidth: 600; OutHeight: 300;
     OutFrames: 131; ActualBytes: 453772),
    (Name: 'small region, quarter'; SourceBytes: 286270; SourceFrames: 189;
     SourceWidth: 1200; SourceHeight: 600; OutWidth: 300; OutHeight: 150;
     OutFrames: 131; ActualBytes: 112640),
    (Name: 'cursorless region, native'; SourceBytes: 236630;
     SourceFrames: 192; SourceWidth: 1200; SourceHeight: 600;
     OutWidth: 1200; OutHeight: 600; OutFrames: 132; ActualBytes: 1413875),
    (Name: 'cursorless region, third'; SourceBytes: 236630;
     SourceFrames: 192; SourceWidth: 1200; SourceHeight: 600;
     OutWidth: 400; OutHeight: 200; OutFrames: 132; ActualBytes: 184320),
    (Name: 'fragmented take, half'; SourceBytes: 165256; SourceFrames: 165;
     SourceWidth: 1200; SourceHeight: 600; OutWidth: 600; OutHeight: 300;
     OutFrames: 114; ActualBytes: 270336),
    (Name: 'take with audio, third'; SourceBytes: 297529; SourceFrames: 89;
     SourceWidth: 1200; SourceHeight: 600; OutWidth: 400; OutHeight: 200;
     OutFrames: 63; ActualBytes: 205824),
    (Name: 'whole display, half'; SourceBytes: 99383361; SourceFrames: 1787;
     SourceWidth: 3024; SourceHeight: 1964; OutWidth: 1512; OutHeight: 982;
     OutFrames: 200; ActualBytes: 60964864),
    (Name: 'whole display, fifth'; SourceBytes: 99383361;
     SourceFrames: 1787; SourceWidth: 3024; SourceHeight: 1964;
     OutWidth: 600; OutHeight: 390; OutFrames: 200; ActualBytes: 10333247),
    (Name: 'whole display, tenth'; SourceBytes: 99383361;
     SourceFrames: 1787; SourceWidth: 3024; SourceHeight: 1964;
     OutWidth: 300; OutHeight: 195; OutFrames: 200; ActualBytes: 2585600));
var
  I: Integer;
  Density: Double;
  Estimate: TExportSizeEstimate;
  Inside: Boolean;
begin
  for I := Low(Measured) to High(Measured) do
  begin
    Density := SourceBytesPerPixelFrame(Measured[I].SourceBytes,
      Measured[I].SourceFrames, Measured[I].SourceWidth,
      Measured[I].SourceHeight);
    Estimate := GifEstimate(Measured[I].OutWidth, Measured[I].OutHeight,
      Measured[I].OutFrames, Density);
    Inside := (Measured[I].ActualBytes >= Estimate.LowBytes)
      and (Measured[I].ActualBytes <= Estimate.HighBytes);
    // Compared as strings so a failure carries the three numbers rather
    // than just "expected True".
    if Inside then
      Expect<string>(Format('%s: inside', [Measured[I].Name]))
        .ToBe(Format('%s: inside', [Measured[I].Name]))
    else
      Expect<string>(Format('%s: %d not in [%d, %d]', [Measured[I].Name,
        Measured[I].ActualBytes, Estimate.LowBytes, Estimate.HighBytes]))
        .ToBe(Format('%s: inside', [Measured[I].Name]));
  end;
end;

{ ------------------------------------------------------------- projection
  The half of this feature that is not a guess. }

procedure TProjectionTests.SetupTests;
begin
  Test('the projection is bytes-so-far scaled by frames',
    TestProjectionIsLinearInFrames);
  Test('at the last frame the projection is the file',
    TestProjectionIsExactAtTheEnd);
  Test('nothing written yet, nothing projected',
    TestProjectionRefusesWithoutData);
end;

procedure TProjectionTests.TestProjectionIsLinearInFrames;
begin
  Expect<Int64>(ProjectExportSize(1000, 10, 100)).ToBe(Int64(10000));
  Expect<Int64>(ProjectExportSize(3333, 33, 99)).ToBe(Int64(9999));
end;

procedure TProjectionTests.TestProjectionIsExactAtTheEnd;
begin
  Expect<Int64>(ProjectExportSize(12345, 100, 100)).ToBe(Int64(12345));
  // An estimate that undercounted the total must not shrink the answer
  // below what has already been written.
  Expect<Int64>(ProjectExportSize(12345, 120, 100)).ToBe(Int64(12345));
end;

procedure TProjectionTests.TestProjectionRefusesWithoutData;
begin
  Expect<Int64>(ProjectExportSize(0, 10, 100)).ToBe(Int64(0));
  Expect<Int64>(ProjectExportSize(1000, 0, 100)).ToBe(Int64(0));
  Expect<Int64>(ProjectExportSize(1000, 10, 0)).ToBe(Int64(0));
end;

{ -------------------------------------------------------------- formatting }

procedure TFormattingTests.SetupTests;
begin
  Test('below a megabyte it is whole kilobytes',
    TestKilobytesBelowAMegabyte);
  Test('above a megabyte it is one decimal', TestMegabytesAbove);
  Test('the description carries both ends of the band',
    TestDescribeCarriesTheBand);
end;

procedure TFormattingTests.TestKilobytesBelowAMegabyte;
begin
  Expect<string>(FormatByteSize(0)).ToBe('0 kB');
  Expect<string>(FormatByteSize(1)).ToBe('1 kB');
  Expect<string>(FormatByteSize(1024)).ToBe('1 kB');
  Expect<string>(FormatByteSize(1025)).ToBe('2 kB');
  Expect<string>(FormatByteSize(-5)).ToBe('0 kB');
end;

procedure TFormattingTests.TestMegabytesAbove;
begin
  Expect<string>(FormatByteSize(1024 * 1024)).ToBe('1.0 MB');
  Expect<string>(FormatByteSize(Round(1.5 * 1024 * 1024))).ToBe('1.5 MB');
  Expect<string>(FormatByteSize(Round(14.53 * 1024 * 1024))).ToBe('14.5 MB');
  Expect<string>(FormatByteSize(1024 * 1024 - 1)).ToBe('1024 kB');
end;

procedure TFormattingTests.TestDescribeCarriesTheBand;
var
  Text: string;
begin
  Text := DescribeEstimate(GifEstimate(600, 400, 205, MiddlingDensity));
  Expect<Boolean>(Pos('roughly', Text) > 0).ToBe(True);
  Expect<Boolean>(Pos(' to ', Text) > 0).ToBe(True);
  Expect<Boolean>(Pos('very roughly', Text) > 0).ToBe(False);
end;

begin
  TestRunnerProgram.AddSuite(TEstimateTests.Create(
    'estimating before a byte is written'));
  TestRunnerProgram.AddSuite(TFallbackTests.Create(
    'the estimate without a source movie to measure'));
  TestRunnerProgram.AddSuite(TMeasuredTests.Create(
    'the real exports the constants came from'));
  TestRunnerProgram.AddSuite(TProjectionTests.Create(
    'projecting from what has been written'));
  TestRunnerProgram.AddSuite(TFormattingTests.Create('saying it in bytes'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

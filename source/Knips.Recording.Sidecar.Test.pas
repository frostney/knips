program Knips.Recording.Sidecar.Test;

// The event sidecar's format, checked on the promises docs/event-sidecar.md
// makes to anybody who reads one of these files:
//
//   - what the writer wrote is what the reader reads back, field for
//     field, through a real file on disk;
//   - the decimal point is a dot whatever the host locale is — this is a
//     machine format and a comma would make it unparseable everywhere
//     else;
//   - an omitted source rectangle means "unchanged", and the reader
//     carries the last one forward from the header's base rectangle;
//   - a file whose last line was cut off mid-write still loads, with
//     everything before the cut intact — the property the whole
//     one-object-per-line shape exists for;
//   - a record kind this version does not know is skipped, not fatal;
//   - movie time is host time minus the anchor, exactly;
//   - interpolation lands between the bracketing samples and clamps at
//     both ends;
//   - the smoothing is centred, so a straight run of samples comes back
//     unchanged and a single spike is pulled in without the path being
//     delayed.
//
// Everything here is platform-neutral and runs on Linux CI as well as
// macOS: a file format is exactly the part of this feature that has
// nothing to do with ScreenCaptureKit.

{$I Knips.inc}

uses
  Classes,
  SysUtils,

  Knips.Options,
  Knips.Recording.Sidecar,
  TestingPascalLibrary;

type
  TRoundTripTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestHeaderSurvivesAFileRoundTrip;
    procedure TestSamplesSurviveAFileRoundTrip;
    procedure TestButtonEventsSurvive;
    procedure TestTrailerSurvives;
    procedure TestNumbersUseADotWhateverTheLocale;
    procedure TestSidecarPathReplacesTheMovieExtension;
    procedure TestQuotingEscapesWhatJsonRequires;
    procedure TestAwkwardMovieNameSurvives;
  end;

  TSourceRectTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAnUnchangedRectangleIsNotRewritten;
    procedure TestTheReaderCarriesTheRectangleForward;
    procedure TestTheFirstRectangleComesFromTheHeader;
  end;

  TResilienceTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestATruncatedLastLineStillLoads;
    procedure TestAnUnknownKindIsSkipped;
    procedure TestBlankLinesAreIgnored;
    procedure TestAMissingFileIsAnError;
    procedure TestANewerFormatVersionIsRefused;
  end;

  TTimelineTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestMovieTimeIsHostTimeMinusTheAnchor;
    procedure TestCursorInterpolatesBetweenSamples;
    procedure TestCursorClampsAtBothEnds;
    procedure TestStateCarriesTheSourceRectangleOfTheEarlierSample;
    procedure TestNoAnchorMeansNoAnswer;
  end;

  TAvailabilityTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestACursorlessDisplayTakeCanHaveOneDrawn;
    procedure TestABakedCursorClosesTheChoice;
    procedure TestAWindowTakeCanHaveNothing;
    procedure TestZoomNeedsClicksAndAnUnzoomedCapture;
    procedure TestZoomRefusesEveryPannedFraming;
    procedure TestABakedPointerDoesNotCloseTheZoom;
    procedure TestNoLogAtAllIsAnswerable;
    procedure TestARawTakeIsFullyRenderable;
    procedure TestACompositedWindowPanCountsAsBaked;
  end;

  TSmoothingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAStraightRunIsUnchanged;
    procedure TestASpikeIsPulledIn;
    procedure TestSmoothingDoesNotDelayTheRamp;
    procedure TestAZeroWindowIsTheIdentity;
    procedure TestInterpolatePathClampsAndBlends;
  end;

{ ---------------------------------------------------------------- helpers }

const
  Epsilon = 1E-6;
  // A host clock reading with a realistic magnitude: uptime seconds, not
  // seconds since some test's zero. It is what catches a writer that
  // rounds times to too few decimals.
  Anchor = 119370.094809;

procedure ExpectNear(AActual, AExpected, ATolerance: Double;
  const AWhat: string);
var
  Shown: Double;
begin
  Shown := AActual;
  if Abs(AActual - AExpected) <= ATolerance then
    Shown := AExpected;
  Expect<string>(Format('%s = %.9f', [AWhat, Shown]))
    .ToBe(Format('%s = %.9f', [AWhat, AExpected]));
end;

function TempSidecarPath(const AStem: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) + 'knips-sidecar-test-'
    + AStem + SidecarExtension;
end;

function SampleHeader: TSidecarHeader;
begin
  Result := Default(TSidecarHeader);
  Result.Version := SidecarFormatVersion;
  Result.KnipsVersion := KnipsVersion;
  Result.MovieName := 'demo.mp4';
  Result.CreatedUtc := '2026-08-27T09:15:00Z';
  Result.ProcessID := 4242;
  Result.PixelWidth := 2880;
  Result.PixelHeight := 1800;
  Result.Scale := 2;
  Result.FramesPerSecond := 30;
  Result.SampleHz := 30;
  Result.DisplayID := 69733382;
  Result.DisplayWidth := 1440;
  Result.DisplayHeight := 900;
  Result.BaseX := 100;
  Result.BaseY := 50;
  Result.BaseWidth := 640;
  Result.BaseHeight := 400;
  // A notched Mac's real menu-bar band, which is the number the field
  // exists for and is not the 22 anybody would guess.
  Result.MenuBarInset := 39;
  Result.CursorRender := scrBaked;
  Result.BakedZoomOnClick := True;
  Result.BakedFollowMouse := False;
  Result.AudioMode := amSystem;
end;

function MakeSample(ATime, AX, AY: Double; AButtons: Integer;
  const AHeader: TSidecarHeader): TSidecarSample;
begin
  Result := Default(TSidecarSample);
  Result.Time := ATime;
  Result.X := AX;
  Result.Y := AY;
  Result.Buttons := AButtons;
  Result.SourceX := AHeader.BaseX;
  Result.SourceY := AHeader.BaseY;
  Result.SourceWidth := AHeader.BaseWidth;
  Result.SourceHeight := AHeader.BaseHeight;
end;

// Writes a whole little sidecar and hands back its path. The caller
// deletes it.
function WriteFixture(const AStem: string; ASampleCount: Integer;
  out AHeader: TSidecarHeader): string;
var
  Writer: TSidecarWriter;
  Sample: TSidecarSample;
  Trailer: TSidecarTrailer;
  I: Integer;
begin
  AHeader := SampleHeader;
  Result := TempSidecarPath(AStem);
  Writer := TSidecarWriter.Create(Result);
  try
    Writer.WriteHeader(AHeader);
    Writer.WriteAnchor(Anchor);
    for I := 0 to ASampleCount - 1 do
    begin
      Sample := MakeSample(Anchor + I / 30, 200 + I * 4, 300 - I * 2, 0,
        AHeader);
      Writer.WriteSample(Sample);
    end;
    Trailer := Default(TSidecarTrailer);
    Trailer.Time := Anchor + ASampleCount / 30;
    Trailer.Frames := ASampleCount;
    Trailer.DurationSeconds := ASampleCount / 30;
    Trailer.Samples := ASampleCount;
    Writer.WriteTrailer(Trailer);
  finally
    Writer.Free;
  end;
end;

function LoadText(const AText: string): TSidecarLog;
var
  Error: string;
begin
  Result := TSidecarLog.Create;
  Result.LoadFromText(AText, Error);
end;

// The smallest well-formed prefix a text fixture needs: a header and an
// anchor, with the base rectangle the samples below are measured in.
const
  FixtureHeader =
    '{"k":"header","format":"knips-events","version":1,"knips":"0.1.0",'
    + '"movie":"demo.mp4","created":"2026-08-27T09:15:00Z",'
    + '"target":"display","pid":0,'
    + '"pixelWidth":1280,"pixelHeight":800,"scale":2,"fps":30,'
    + '"sampleHz":30,"displayId":1,"displayWidth":1440,"displayHeight":900,'
    + '"baseX":10,"baseY":20,"baseWidth":640,"baseHeight":400,'
    + '"cursor":"none","bakedZoomOnClick":false,"bakedFollowMouse":true,'
    + '"audio":"none"}';
  FixtureAnchor = '{"k":"anchor","host":100.0}';

{ ------------------------------------------------------------- round trip }

procedure TRoundTripTests.SetupTests;
begin
  Test('the header comes back field for field',
    TestHeaderSurvivesAFileRoundTrip);
  Test('every sample comes back in order', TestSamplesSurviveAFileRoundTrip);
  Test('button edges come back with their positions',
    TestButtonEventsSurvive);
  Test('the trailer comes back', TestTrailerSurvives);
  Test('numbers are written with a dot whatever the locale is',
    TestNumbersUseADotWhateverTheLocale);
  Test('demo.mp4 gets demo.knips.jsonl beside it',
    TestSidecarPathReplacesTheMovieExtension);
  Test('quoting escapes everything JSON forbids in a string',
    TestQuotingEscapesWhatJsonRequires);
  Test('a movie name with a quote in it round trips',
    TestAwkwardMovieNameSurvives);
end;

procedure TRoundTripTests.TestHeaderSurvivesAFileRoundTrip;
var
  Path, Error: string;
  Written: TSidecarHeader;
  Log: TSidecarLog;
begin
  Path := WriteFixture('header', 3, Written);
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromFile(Path, Error)).ToBe(True);
    Expect<Integer>(Log.Header.Version).ToBe(SidecarFormatVersion);
    Expect<string>(Log.Header.MovieName).ToBe('demo.mp4');
    Expect<string>(Log.Header.CreatedUtc).ToBe('2026-08-27T09:15:00Z');
    Expect<Integer>(Log.Header.PixelWidth).ToBe(2880);
    Expect<Integer>(Log.Header.PixelHeight).ToBe(1800);
    Expect<Integer>(Log.Header.Scale).ToBe(2);
    Expect<Integer>(Log.Header.FramesPerSecond).ToBe(30);
    Expect<Cardinal>(Log.Header.DisplayID).ToBe(Cardinal(69733382));
    ExpectNear(Log.Header.BaseX, 100, Epsilon, 'baseX');
    ExpectNear(Log.Header.BaseWidth, 640, Epsilon, 'baseWidth');
    ExpectNear(Log.Header.MenuBarInset, 39, Epsilon, 'menuBarInset');
    Expect<string>(SidecarCursorRenderName(Log.Header.CursorRender))
      .ToBe('baked');
    Expect<Boolean>(Log.Header.BakedZoomOnClick).ToBe(True);
    Expect<Boolean>(Log.Header.BakedFollowMouse).ToBe(False);
    Expect<Integer>(Log.Header.ProcessID).ToBe(4242);
    Expect<string>(AudioModeName(Log.Header.AudioMode)).ToBe('system');
    Expect<Boolean>(Log.HasAnchor).ToBe(True);
    ExpectNear(Log.AnchorHost, Anchor, Epsilon, 'anchor');
  finally
    Log.Free;
    DeleteFile(Path);
  end;
end;

procedure TRoundTripTests.TestSamplesSurviveAFileRoundTrip;
var
  Path, Error: string;
  Written: TSidecarHeader;
  Log: TSidecarLog;
begin
  Path := WriteFixture('samples', 5, Written);
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromFile(Path, Error)).ToBe(True);
    Expect<Integer>(Log.SampleCount).ToBe(5);
    ExpectNear(Log.Sample(0).Time, Anchor, Epsilon, 'sample 0 time');
    ExpectNear(Log.Sample(0).X, 200, Epsilon, 'sample 0 x');
    ExpectNear(Log.Sample(4).X, 216, Epsilon, 'sample 4 x');
    ExpectNear(Log.Sample(4).Y, 292, Epsilon, 'sample 4 y');
    ExpectNear(Log.Sample(4).Time, Anchor + 4 / 30, Epsilon,
      'sample 4 time');
  finally
    Log.Free;
    DeleteFile(Path);
  end;
end;

procedure TRoundTripTests.TestButtonEventsSurvive;
var
  Path, Error: string;
  Header: TSidecarHeader;
  Writer: TSidecarWriter;
  Event: TSidecarButtonEvent;
  Log: TSidecarLog;
begin
  Header := SampleHeader;
  Path := TempSidecarPath('buttons');
  Writer := TSidecarWriter.Create(Path);
  try
    Writer.WriteHeader(Header);
    Writer.WriteAnchor(Anchor);
    Event := Default(TSidecarButtonEvent);
    Event.Time := Anchor + 1.5;
    Event.X := 321.5;
    Event.Y := 654.25;
    Event.Button := 0;
    Event.Down := True;
    Writer.WriteButton(Event);
    Event.Time := Anchor + 1.62;
    Event.Down := False;
    Writer.WriteButton(Event);
  finally
    Writer.Free;
  end;
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromFile(Path, Error)).ToBe(True);
    Expect<Integer>(Log.ButtonCount).ToBe(2);
    Expect<Boolean>(Log.ButtonEvent(0).Down).ToBe(True);
    Expect<Boolean>(Log.ButtonEvent(1).Down).ToBe(False);
    ExpectNear(Log.ButtonEvent(0).X, 321.5, Epsilon, 'button x');
    ExpectNear(Log.ButtonEvent(0).Y, 654.25, Epsilon, 'button y');
    ExpectNear(Log.ButtonEvent(1).Time, Anchor + 1.62, Epsilon,
      'button up time');
  finally
    Log.Free;
    DeleteFile(Path);
  end;
end;

procedure TRoundTripTests.TestTrailerSurvives;
var
  Path, Error: string;
  Written: TSidecarHeader;
  Log: TSidecarLog;
begin
  Path := WriteFixture('trailer', 9, Written);
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromFile(Path, Error)).ToBe(True);
    Expect<Boolean>(Log.HasTrailer).ToBe(True);
    Expect<Int64>(Log.Trailer.Frames).ToBe(Int64(9));
    Expect<Int64>(Log.Trailer.Samples).ToBe(Int64(9));
    ExpectNear(Log.Trailer.DurationSeconds, 9 / 30, Epsilon, 'duration');
  finally
    Log.Free;
    DeleteFile(Path);
  end;
end;

procedure TRoundTripTests.TestNumbersUseADotWhateverTheLocale;
var
  Path: string;
  Header: TSidecarHeader;
  Writer: TSidecarWriter;
  Lines: TStringList;
  Saved: Char;
begin
  // The unit takes its own invariant settings once, at initialisation, so
  // this is checking the promise rather than the mechanism: a host that
  // decimal-separates with a comma must still produce parseable JSON.
  Saved := DefaultFormatSettings.DecimalSeparator;
  DefaultFormatSettings.DecimalSeparator := ',';
  try
    Header := SampleHeader;
    Path := TempSidecarPath('locale');
    Writer := TSidecarWriter.Create(Path);
    try
      Writer.WriteHeader(Header);
      Writer.WriteAnchor(1.5);
      Writer.WriteSample(MakeSample(2.25, 3.5, 4.75, 1, Header));
    finally
      Writer.Free;
    end;
    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(Path);
      // A comma is a legal JSON separator, so the check is on the numbers
      // themselves: dot as the decimal point, and no comma inside one.
      Expect<Boolean>(Pos('"host":1.5', Lines[1]) > 0).ToBe(True);
      Expect<Boolean>(Pos('1,5', Lines[1]) > 0).ToBe(False);
      Expect<Boolean>(Pos('"x":3.500', Lines[2]) > 0).ToBe(True);
      Expect<Boolean>(Pos('"y":4.750', Lines[2]) > 0).ToBe(True);
      Expect<Boolean>(Pos('4,75', Lines[2]) > 0).ToBe(False);
    finally
      Lines.Free;
      DeleteFile(Path);
    end;
  finally
    DefaultFormatSettings.DecimalSeparator := Saved;
  end;
end;

procedure TRoundTripTests.TestSidecarPathReplacesTheMovieExtension;
begin
  Expect<string>(SidecarPathFor('demo.mp4')).ToBe('demo' + SidecarExtension);
  Expect<string>(SidecarPathFor('/tmp/a b/take.mov'))
    .ToBe('/tmp/a b/take' + SidecarExtension);
  Expect<string>(SidecarPathFor('')).ToBe('');
end;

// A movie's file name goes into the header as a JSON string, and a file
// name may legally contain a quote, a backslash, or a control character.
// One unescaped quote makes the whole header unparseable, which costs the
// take its anchor and its recovery.
procedure TRoundTripTests.TestQuotingEscapesWhatJsonRequires;
begin
  Expect<string>(QuoteJsonString('plain')).ToBe('"plain"');
  Expect<string>(QuoteJsonString('say "hi"')).ToBe('"say \"hi\""');
  Expect<string>(QuoteJsonString('back\slash')).ToBe('"back\\slash"');
  Expect<string>(QuoteJsonString('tab' + #9 + 'end')).ToBe('"tab\tend"');
  Expect<string>(QuoteJsonString('a' + #10 + 'b')).ToBe('"a\nb"');
  Expect<string>(QuoteJsonString('a' + #13 + 'b')).ToBe('"a\rb"');
  Expect<string>(QuoteJsonString(#8 + #12)).ToBe('"\b\f"');
  // Anything else below space goes out as \u00xx rather than raw.
  Expect<string>(QuoteJsonString(#1)).ToBe('"\u0001"');
  Expect<string>(QuoteJsonString(#31)).ToBe('"\u001f"');
  Expect<string>(QuoteJsonString('')).ToBe('""');
end;

procedure TRoundTripTests.TestAwkwardMovieNameSurvives;
var
  Path, Error: string;
  Header: TSidecarHeader;
  Writer: TSidecarWriter;
  Log: TSidecarLog;
begin
  Header := SampleHeader;
  Header.MovieName := 'a "quoted" name' + #9 + 'with a tab.mp4';
  Path := TempSidecarPath('awkward');
  Writer := TSidecarWriter.Create(Path);
  try
    Writer.WriteHeader(Header);
    Writer.WriteAnchor(Anchor);
  finally
    Writer.Free;
  end;
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromFile(Path, Error)).ToBe(True);
    Expect<string>(Log.Header.MovieName).ToBe(Header.MovieName);
    Expect<Integer>(Log.SkippedLines).ToBe(0);
  finally
    Log.Free;
    DeleteFile(Path);
  end;
end;

{ ------------------------------------------------------- source rectangle }

procedure TSourceRectTests.SetupTests;
begin
  Test('a rectangle that has not moved is written once',
    TestAnUnchangedRectangleIsNotRewritten);
  Test('the reader carries the last rectangle forward',
    TestTheReaderCarriesTheRectangleForward);
  Test('the first rectangle is the header''s base rectangle',
    TestTheFirstRectangleComesFromTheHeader);
end;

procedure TSourceRectTests.TestAnUnchangedRectangleIsNotRewritten;
var
  Path: string;
  Header: TSidecarHeader;
  Writer: TSidecarWriter;
  Sample: TSidecarSample;
  Lines: TStringList;
begin
  Header := SampleHeader;
  Path := TempSidecarPath('unchanged');
  Writer := TSidecarWriter.Create(Path);
  try
    Writer.WriteHeader(Header);
    Writer.WriteAnchor(Anchor);
    Writer.WriteSample(MakeSample(Anchor, 1, 2, 0, Header));
    Sample := MakeSample(Anchor + 0.1, 3, 4, 0, Header);
    Sample.SourceX := Header.BaseX + 8;
    Writer.WriteSample(Sample);
    Writer.WriteSample(Sample);
  finally
    Writer.Free;
  end;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    // Line 2 matches the header's base rectangle, so it carries none;
    // line 3 moved and carries one; line 4 did not move again.
    Expect<Boolean>(Pos('"sx"', Lines[2]) > 0).ToBe(False);
    Expect<Boolean>(Pos('"sx"', Lines[3]) > 0).ToBe(True);
    Expect<Boolean>(Pos('"sx"', Lines[4]) > 0).ToBe(False);
  finally
    Lines.Free;
    DeleteFile(Path);
  end;
end;

procedure TSourceRectTests.TestTheReaderCarriesTheRectangleForward;
var
  Log: TSidecarLog;
begin
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}' + LineEnding
    + '{"k":"cursor","t":100.1,"x":3,"y":4,"b":0,'
    + '"sx":50,"sy":60,"sw":320,"sh":200}' + LineEnding
    + '{"k":"cursor","t":100.2,"x":5,"y":6,"b":0}');
  try
    Expect<Integer>(Log.SampleCount).ToBe(3);
    ExpectNear(Log.Sample(1).SourceX, 50, Epsilon, 'moved sx');
    ExpectNear(Log.Sample(2).SourceX, 50, Epsilon, 'carried sx');
    ExpectNear(Log.Sample(2).SourceWidth, 320, Epsilon, 'carried sw');
    ExpectNear(Log.Sample(2).SourceHeight, 200, Epsilon, 'carried sh');
  finally
    Log.Free;
  end;
end;

procedure TSourceRectTests.TestTheFirstRectangleComesFromTheHeader;
var
  Log: TSidecarLog;
begin
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}');
  try
    ExpectNear(Log.Sample(0).SourceX, 10, Epsilon, 'base sx');
    ExpectNear(Log.Sample(0).SourceY, 20, Epsilon, 'base sy');
    ExpectNear(Log.Sample(0).SourceWidth, 640, Epsilon, 'base sw');
    ExpectNear(Log.Sample(0).SourceHeight, 400, Epsilon, 'base sh');
  finally
    Log.Free;
  end;
end;

{ -------------------------------------------------------------- tolerance }

procedure TResilienceTests.SetupTests;
begin
  Test('a file cut off mid-line loads everything before the cut',
    TestATruncatedLastLineStillLoads);
  Test('a record kind this version does not know is skipped',
    TestAnUnknownKindIsSkipped);
  Test('blank lines are not records', TestBlankLinesAreIgnored);
  Test('a missing file is an error with a message',
    TestAMissingFileIsAnError);
  Test('a file from a newer knips is refused rather than half-read',
    TestANewerFormatVersionIsRefused);
end;

procedure TResilienceTests.TestATruncatedLastLineStillLoads;
var
  Log: TSidecarLog;
begin
  // Exactly the shape a kill -9 leaves behind: the last write did not
  // finish, so the file ends in the middle of an object.
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}' + LineEnding
    + '{"k":"cursor","t":100.1,"x":3,"y":');
  try
    Expect<Integer>(Log.SampleCount).ToBe(1);
    Expect<Boolean>(Log.HasAnchor).ToBe(True);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
  finally
    Log.Free;
  end;
end;

procedure TResilienceTests.TestAnUnknownKindIsSkipped;
var
  Log: TSidecarLog;
begin
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"keystroke","t":100.05,"code":36}' + LineEnding
    + '{"k":"cursor","t":100.1,"x":3,"y":4,"b":1}');
  try
    Expect<Integer>(Log.SampleCount).ToBe(1);
    Expect<Integer>(Log.Sample(0).Buttons).ToBe(1);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
  finally
    Log.Free;
  end;
end;

procedure TResilienceTests.TestBlankLinesAreIgnored;
var
  Log: TSidecarLog;
begin
  Log := LoadText(FixtureHeader + LineEnding + LineEnding + FixtureAnchor
    + LineEnding + LineEnding);
  try
    Expect<Integer>(Log.SkippedLines).ToBe(0);
    Expect<Boolean>(Log.HasAnchor).ToBe(True);
  finally
    Log.Free;
  end;
end;

procedure TResilienceTests.TestAMissingFileIsAnError;
var
  Log: TSidecarLog;
  Error: string;
begin
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromFile(
      IncludeTrailingPathDelimiter(GetTempDir) + 'knips-no-such-sidecar.jsonl',
      Error)).ToBe(False);
    Expect<Boolean>(Error <> '').ToBe(True);
  finally
    Log.Free;
  end;
end;

// A new record KIND is skippable and needs no version bump, so a version
// that has moved means something a version-1 reader would MISREAD rather
// than merely miss. Declining the file is the only safe answer.
procedure TResilienceTests.TestANewerFormatVersionIsRefused;
var
  Log: TSidecarLog;
  Error: string;
begin
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(StringReplace(FixtureHeader,
      '"version":1', '"version":2', []) + LineEnding + FixtureAnchor
      + LineEnding + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}',
      Error)).ToBe(False);
    Expect<Boolean>(Log.TooNew).ToBe(True);
    Expect<Boolean>(Pos('version 2', Error) > 0).ToBe(True);
  finally
    Log.Free;
  end;
  // The current version still loads, and so does one from an older writer.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor, Error)).ToBe(True);
    Expect<Boolean>(Log.TooNew).ToBe(False);
  finally
    Log.Free;
  end;
end;

{ --------------------------------------------------------------- timeline }

procedure TTimelineTests.SetupTests;
begin
  Test('movie time is host time minus the anchor',
    TestMovieTimeIsHostTimeMinusTheAnchor);
  Test('the cursor is interpolated between the bracketing samples',
    TestCursorInterpolatesBetweenSamples);
  Test('before the first and after the last sample the path is clamped',
    TestCursorClampsAtBothEnds);
  Test('the source rectangle is the earlier sample''s, not a blend',
    TestStateCarriesTheSourceRectangleOfTheEarlierSample);
  Test('without an anchor there is no movie time to answer in',
    TestNoAnchorMeansNoAnswer);
end;

procedure TTimelineTests.TestMovieTimeIsHostTimeMinusTheAnchor;
var
  Log: TSidecarLog;
begin
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor);
  try
    ExpectNear(Log.MovieSeconds(100.0), 0, Epsilon, 'at the anchor');
    ExpectNear(Log.MovieSeconds(102.5), 2.5, Epsilon, 'two and a half in');
    ExpectNear(Log.MovieSeconds(99.5), -0.5, Epsilon, 'before the anchor');
  finally
    Log.Free;
  end;
end;

procedure TTimelineTests.TestCursorInterpolatesBetweenSamples;
var
  Log: TSidecarLog;
  X, Y: Double;
begin
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":0,"y":0,"b":0}' + LineEnding
    + '{"k":"cursor","t":101.0,"x":100,"y":200,"b":0}');
  try
    Expect<Boolean>(Log.CursorAt(0.25, X, Y)).ToBe(True);
    ExpectNear(X, 25, Epsilon, 'x a quarter in');
    ExpectNear(Y, 50, Epsilon, 'y a quarter in');
    Log.CursorAt(0.75, X, Y);
    ExpectNear(X, 75, Epsilon, 'x three quarters in');
  finally
    Log.Free;
  end;
end;

procedure TTimelineTests.TestCursorClampsAtBothEnds;
var
  Log: TSidecarLog;
  X, Y: Double;
begin
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":10,"y":20,"b":0}' + LineEnding
    + '{"k":"cursor","t":101.0,"x":110,"y":220,"b":0}');
  try
    Log.CursorAt(-5, X, Y);
    ExpectNear(X, 10, Epsilon, 'before the first sample');
    Log.CursorAt(50, X, Y);
    ExpectNear(X, 110, Epsilon, 'after the last sample');
  finally
    Log.Free;
  end;
end;

procedure TTimelineTests.TestStateCarriesTheSourceRectangleOfTheEarlierSample;
var
  Log: TSidecarLog;
  State: TSidecarSample;
begin
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":0,"y":0,"b":0,'
    + '"sx":0,"sy":0,"sw":100,"sh":100}' + LineEnding
    + '{"k":"cursor","t":101.0,"x":10,"y":10,"b":0,'
    + '"sx":50,"sy":50,"sw":200,"sh":200}');
  try
    Expect<Boolean>(Log.StateAt(0.5, State)).ToBe(True);
    ExpectNear(State.X, 5, Epsilon, 'x half way');
    ExpectNear(State.SourceX, 0, Epsilon, 'sx is the earlier sample''s');
    ExpectNear(State.SourceWidth, 100, Epsilon,
      'sw is the earlier sample''s');
  finally
    Log.Free;
  end;
end;

procedure TTimelineTests.TestNoAnchorMeansNoAnswer;
var
  Log: TSidecarLog;
  X, Y: Double;
begin
  Log := LoadText(FixtureHeader + LineEnding
    + '{"k":"cursor","t":100.0,"x":0,"y":0,"b":0}');
  try
    Expect<Boolean>(Log.HasAnchor).ToBe(False);
    Expect<Boolean>(Log.CursorAt(0, X, Y)).ToBe(False);
    ExpectNear(Log.MovieSeconds(500), 0, Epsilon, 'no anchor, no time');
  finally
    Log.Free;
  end;
end;

// The composited window recording is a display capture whose source
// rectangle is polled onto a window: no live effect is running, so
// neither of the other two flags is set, and without this one such a take
// would claim its framing was never touched.
procedure TAvailabilityTests.TestACompositedWindowPanCountsAsBaked;
var
  Header: TSidecarHeader;
  Log: TSidecarLog;
begin
  Header := Default(TSidecarHeader);
  Header.CursorRender := scrSmooth;
  Header.BakedWindowFollow := True;
  Expect<Boolean>(IsRawTake(Header)).ToBe(False);
  Log := LoadText(StringReplace(StringReplace(FixtureHeader,
    '"bakedFollowMouse":true', '"bakedFollowMouse":false', []),
    '"audio":"none"', '"bakedWindowFollow":true,"audio":"none"', [])
    + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}');
  try
    Expect<Boolean>(AvailableExportEffects(Log).CanDrawCursor).ToBe(True);
    Expect<Boolean>(AvailableExportEffects(Log).FullyRenderable).ToBe(False);
    Expect<Boolean>(Pos('panned by the capture',
      AvailableExportEffects(Log).Reason) > 0).ToBe(True);
  finally
    Log.Free;
  end;
end;

// The question a render-the-deliverable pipeline asks first: is anything
// already in these pixels that it would have to work around?
procedure TAvailabilityTests.TestARawTakeIsFullyRenderable;
var
  Header: TSidecarHeader;
  Log: TSidecarLog;
begin
  Header := Default(TSidecarHeader);
  Header.CursorRender := scrSmooth;
  Expect<Boolean>(IsRawTake(Header)).ToBe(True);
  Header.CursorRender := scrNone;
  Expect<Boolean>(IsRawTake(Header)).ToBe(True);
  // Any one of the three closes it.
  Header.CursorRender := scrSystem;
  Expect<Boolean>(IsRawTake(Header)).ToBe(False);
  Header.CursorRender := scrBaked;
  Expect<Boolean>(IsRawTake(Header)).ToBe(False);
  Header.CursorRender := scrNone;
  Header.BakedZoomOnClick := True;
  Expect<Boolean>(IsRawTake(Header)).ToBe(False);
  Header.BakedZoomOnClick := False;
  Header.BakedFollowMouse := True;
  Expect<Boolean>(IsRawTake(Header)).ToBe(False);

  // And through the loaded-log answer. The fixture header pans
  // (bakedFollowMouse:true), so it is NOT fully renderable even though
  // its pointer can still be drawn.
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}');
  try
    Expect<Boolean>(AvailableExportEffects(Log).CanDrawCursor).ToBe(True);
    Expect<Boolean>(AvailableExportEffects(Log).FullyRenderable).ToBe(False);
  finally
    Log.Free;
  end;
  Log := LoadText(StringReplace(FixtureHeader, '"bakedFollowMouse":true',
    '"bakedFollowMouse":false', []) + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}');
  try
    Expect<Boolean>(AvailableExportEffects(Log).FullyRenderable).ToBe(True);
  finally
    Log.Free;
  end;
end;

{ -------------------------------------------------------------- smoothing }

procedure TSmoothingTests.SetupTests;
begin
  Test('a path already straight comes back unchanged',
    TestAStraightRunIsUnchanged);
  Test('a single-sample spike is averaged away', TestASpikeIsPulledIn);
  Test('a centred window does not delay a steady ramp',
    TestSmoothingDoesNotDelayTheRamp);
  Test('a window of zero is the identity', TestAZeroWindowIsTheIdentity);
  Test('the free interpolator clamps and blends the same way',
    TestInterpolatePathClampsAndBlends);
end;

// Samples every 1/30 s along a straight line, with one optional spike.
function Ramp(ACount: Integer; ASpikeIndex: Integer;
  ASpikeOffset: Double): TSidecarSampleArray;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
  begin
    Result[I] := Default(TSidecarSample);
    Result[I].Time := I / 30;
    Result[I].X := I * 10;
    Result[I].Y := 100;
    if I = ASpikeIndex then
      Result[I].Y := 100 + ASpikeOffset;
  end;
end;

procedure TSmoothingTests.TestAStraightRunIsUnchanged;
var
  Path, Smoothed: TSidecarSampleArray;
begin
  Path := Ramp(21, -1, 0);
  Smoothed := SmoothSidecarPath(Path, Length(Path), 5 / 30);
  ExpectNear(Smoothed[10].X, Path[10].X, 1E-9, 'middle x');
  ExpectNear(Smoothed[10].Y, 100, 1E-9, 'middle y');
  // The ends see a half window, and a straight line averaged over a
  // half window through its own endpoint is not the endpoint — so the
  // property that holds everywhere is the constant coordinate.
  ExpectNear(Smoothed[0].Y, 100, 1E-9, 'first y');
  ExpectNear(Smoothed[20].Y, 100, 1E-9, 'last y');
end;

procedure TSmoothingTests.TestASpikeIsPulledIn;
var
  Path, Smoothed: TSidecarSampleArray;
begin
  // One sample 60 points off the line, the sort of thing a single missed
  // poll produces. A window covering five samples divides it by five.
  Path := Ramp(21, 10, 60);
  Smoothed := SmoothSidecarPath(Path, Length(Path), 4.5 / 30);
  ExpectNear(Smoothed[10].Y, 112, 1E-9, 'the spike itself');
  ExpectNear(Smoothed[4].Y, 100, 1E-9, 'well before the spike');
  Expect<Boolean>(Smoothed[10].Y < Path[10].Y).ToBe(True);
end;

procedure TSmoothingTests.TestSmoothingDoesNotDelayTheRamp;
var
  Path, Smoothed: TSidecarSampleArray;
begin
  // The reason the filter is centred rather than causal: a constant
  // velocity path must come back with the same position, not one lagging
  // behind it. An exponential ease would fail this by construction.
  Path := Ramp(21, -1, 0);
  Smoothed := SmoothSidecarPath(Path, Length(Path), 4.5 / 30);
  ExpectNear(Smoothed[10].X, 100, 1E-9, 'no lag at sample 10');
  ExpectNear(Smoothed[15].X, 150, 1E-9, 'no lag at sample 15');
end;

procedure TSmoothingTests.TestAZeroWindowIsTheIdentity;
var
  Path, Smoothed: TSidecarSampleArray;
begin
  Path := Ramp(5, 2, 40);
  Smoothed := SmoothSidecarPath(Path, Length(Path), 0);
  ExpectNear(Smoothed[2].Y, 140, 1E-9, 'the spike survives');
  Expect<Integer>(Length(SmoothSidecarPath(Path, 0, 1))).ToBe(0);
end;

procedure TSmoothingTests.TestInterpolatePathClampsAndBlends;
var
  Path: TSidecarSampleArray;
  X, Y: Double;
begin
  Path := Ramp(3, -1, 0);
  Expect<Boolean>(InterpolatePath(Path, 3, 1 / 60, X, Y)).ToBe(True);
  ExpectNear(X, 5, 1E-9, 'half a sample in');
  InterpolatePath(Path, 3, -1, X, Y);
  ExpectNear(X, 0, 1E-9, 'clamped at the start');
  InterpolatePath(Path, 3, 99, X, Y);
  ExpectNear(X, 20, 1E-9, 'clamped at the end');
  Expect<Boolean>(InterpolatePath(Path, 0, 0, X, Y)).ToBe(False);
end;

{ ----------------------------------------------------------- availability }

procedure TAvailabilityTests.SetupTests;
begin
  Test('a cursorless display take can have a pointer drawn',
    TestACursorlessDisplayTakeCanHaveOneDrawn);
  Test('a pointer already in the pixels closes the choice',
    TestABakedCursorClosesTheChoice);
  Test('a window take can have nothing drawn into it',
    TestAWindowTakeCanHaveNothing);
  Test('post-hoc zoom needs clicks and a capture that was not zooming',
    TestZoomNeedsClicksAndAnUnzoomedCapture);
  Test('post-hoc zoom is refused for every way the framing could pan',
    TestZoomRefusesEveryPannedFraming);
  Test('a pointer already in the pixels does not close the zoom',
    TestABakedPointerDoesNotCloseTheZoom);
  Test('no sidecar at all still answers', TestNoLogAtAllIsAnswerable);
  Test('a take with nothing baked into it is fully renderable',
    TestARawTakeIsFullyRenderable);
  Test('a composited window recording''s pan counts as baked framing',
    TestACompositedWindowPanCountsAsBaked);
end;

// The header fixture above says cursor:"none", target display, and
// bakedFollowMouse:true — a take whose capture panned but did not zoom.
procedure TAvailabilityTests.TestACursorlessDisplayTakeCanHaveOneDrawn;
var
  Log: TSidecarLog;
  Available: TSidecarEffectAvailability;
begin
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}' + LineEnding
    + '{"k":"button","t":100.1,"x":1,"y":2,"n":0,"d":true}');
  try
    Available := AvailableExportEffects(Log);
    Expect<Boolean>(Available.CanDrawCursor).ToBe(True);
    Expect<Boolean>(Available.CursorAlreadyBaked).ToBe(False);
    // The fixture header pans (bakedFollowMouse). The pointer can still
    // be drawn — every sample carries the rectangle the capture was
    // reading at that instant, so the mapping follows the pan — but the
    // crop cannot, because it is taken against the fixed base rectangle.
    Expect<Boolean>(Available.CanZoomOnClick).ToBe(False);
    Expect<Boolean>(Available.FullyRenderable).ToBe(False);
    Expect<Boolean>(Pos('panned by the capture', Available.Reason) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('panned by the capture', Available.ZoomReason) > 0)
      .ToBe(True);
    Expect<string>(Available.CursorReason).ToBe('');
  finally
    Log.Free;
  end;
  // And a take with nothing baked at all: everything open, no reason.
  Log := LoadText(StringReplace(FixtureHeader, '"bakedFollowMouse":true',
    '"bakedFollowMouse":false', []) + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}' + LineEnding
    + '{"k":"button","t":100.1,"x":1,"y":2,"n":0,"d":true}');
  try
    Available := AvailableExportEffects(Log);
    Expect<Boolean>(Available.FullyRenderable).ToBe(True);
    Expect<string>(Available.Reason).ToBe('');
  finally
    Log.Free;
  end;
end;

// A header with exactly the four fields these tests vary, so a scenario
// reads as what it is rather than as three nested StringReplaces.
function AvailabilityHeader(const ACursor: string; AZoom, AFollow,
  AWindowFollow: Boolean): string;
begin
  Result := '{"k":"header","format":"knips-events","version":1,'
    + '"knips":"0.1.0","movie":"demo.mp4",'
    + '"created":"2026-08-27T09:15:00Z","target":"display","pid":0,'
    + '"pixelWidth":1280,"pixelHeight":800,"scale":2,"fps":30,'
    + '"sampleHz":30,"displayId":1,"displayWidth":1440,'
    + '"displayHeight":900,"baseX":10,"baseY":20,"baseWidth":640,'
    + '"baseHeight":400,"cursor":"' + ACursor + '",'
    + '"bakedZoomOnClick":' + BoolToStr(AZoom, 'true', 'false')
    + ',"bakedFollowMouse":' + BoolToStr(AFollow, 'true', 'false')
    + ',"bakedWindowFollow":' + BoolToStr(AWindowFollow, 'true', 'false')
    + ',"audio":"none"}';
end;

// One sample and one click, which is the least a take needs before the
// availability question is about the framing rather than about the track.
function AvailabilityBody: string;
begin
  Result := LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}' + LineEnding
    + '{"k":"button","t":100.1,"x":1,"y":2,"n":0,"d":true}';
end;

// The regression this exists for: the crop is computed against the
// recording's BASE rectangle, so a capture that moved its own source
// rectangle shows something else in every frame and the crop lands on a
// rectangle the pixels are not showing. All three ways of moving it are
// pinned, because only the first was checked before and the other two
// rendered silently wrong — measured, 36 mis-cropped frames on a Follow
// Mouse take.
procedure TAvailabilityTests.TestZoomRefusesEveryPannedFraming;
var
  Log: TSidecarLog;

  procedure ExpectRefused(const AWhat, AHeader: string);
  var
    Log: TSidecarLog;
    Available: TSidecarEffectAvailability;
  begin
    Log := LoadText(AHeader + AvailabilityBody);
    try
      Available := AvailableExportEffects(Log);
      Expect<string>(AWhat + ' -> zoom '
        + BoolToStr(Available.CanZoomOnClick, 'offered', 'refused'))
        .ToBe(AWhat + ' -> zoom refused');
      Expect<Boolean>(Available.ZoomReason <> '').ToBe(True);
    finally
      Log.Free;
    end;
  end;

begin
  ExpectRefused('bakedZoomOnClick',
    AvailabilityHeader('smooth', True, False, False));
  ExpectRefused('bakedFollowMouse',
    AvailabilityHeader('smooth', False, True, False));
  ExpectRefused('bakedWindowFollow',
    AvailabilityHeader('smooth', False, False, True));
  // And the control: nothing panned, so the zoom is offered.
  Log := LoadText(AvailabilityHeader('smooth', False, False, False)
    + AvailabilityBody);
  try
    Expect<Boolean>(AvailableExportEffects(Log).CanZoomOnClick).ToBe(True);
  finally
    Log.Free;
  end;
end;

// The other half of the same rule, and the reason this is
// HasUntouchedFraming rather than IsRawTake: a pointer that is already in
// the pixels is part of the picture and scales with the crop exactly as
// the live effect's would have. An ordinary `knips record` take can still
// be zoomed after the fact.
procedure TAvailabilityTests.TestABakedPointerDoesNotCloseTheZoom;
var
  Log: TSidecarLog;
  Available: TSidecarEffectAvailability;
begin
  Log := LoadText(AvailabilityHeader('system', False, False, False)
    + AvailabilityBody);
  try
    Available := AvailableExportEffects(Log);
    Expect<Boolean>(Available.CanDrawCursor).ToBe(False);
    Expect<Boolean>(Available.CanZoomOnClick).ToBe(True);
    Expect<string>(Available.ZoomReason).ToBe('');
    Expect<Boolean>(Available.CursorReason <> '').ToBe(True);
    // The summary carries the most limiting fact, which here is the
    // pointer; the per-effect reason is what a zoom caller must read.
    Expect<string>(Available.Reason).ToBe(Available.CursorReason);
  finally
    Log.Free;
  end;
end;

procedure TAvailabilityTests.TestABakedCursorClosesTheChoice;
var
  Log: TSidecarLog;
  Available: TSidecarEffectAvailability;
begin
  Log := LoadText(StringReplace(FixtureHeader, '"cursor":"none"',
    '"cursor":"baked"', []) + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}');
  try
    Available := AvailableExportEffects(Log);
    Expect<Boolean>(Available.CursorAlreadyBaked).ToBe(True);
    Expect<Boolean>(Available.CanDrawCursor).ToBe(False);
    Expect<Boolean>(Pos('already in this recording', Available.Reason) > 0)
      .ToBe(True);
  finally
    Log.Free;
  end;
end;

procedure TAvailabilityTests.TestAWindowTakeCanHaveNothing;
var
  Log: TSidecarLog;
  Available: TSidecarEffectAvailability;
begin
  Log := LoadText(StringReplace(FixtureHeader, '"target":"display"',
    '"target":"window"', []) + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}');
  try
    Available := AvailableExportEffects(Log);
    Expect<Boolean>(Available.CanDrawCursor).ToBe(False);
    Expect<Boolean>(Available.CanZoomOnClick).ToBe(False);
    Expect<Boolean>(Pos('window recording', Available.Reason) > 0).ToBe(True);
  finally
    Log.Free;
  end;
end;

procedure TAvailabilityTests.TestZoomNeedsClicksAndAnUnzoomedCapture;
var
  Log: TSidecarLog;
  Available: TSidecarEffectAvailability;
begin
  // No clicks: nothing to zoom to. The header is the fixture's with its
  // pan cleared, so that "nothing was clicked" is the ONLY thing left to
  // say — the reason chain reports a baked framing ahead of it, and this
  // test is about the last link rather than that one.
  Log := LoadText(StringReplace(FixtureHeader, '"bakedFollowMouse":true',
    '"bakedFollowMouse":false', []) + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}');
  try
    Available := AvailableExportEffects(Log);
    Expect<Boolean>(Available.CanZoomOnClick).ToBe(False);
    Expect<Boolean>(Pos('nothing was clicked', Available.Reason) > 0)
      .ToBe(True);
  finally
    Log.Free;
  end;
  // Clicks, but the capture was already zooming: doing it again would
  // compound two zooms nobody chose.
  Log := LoadText(StringReplace(FixtureHeader, '"bakedZoomOnClick":false',
    '"bakedZoomOnClick":true', []) + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}' + LineEnding
    + '{"k":"button","t":100.1,"x":1,"y":2,"n":0,"d":true}');
  try
    Available := AvailableExportEffects(Log);
    Expect<Boolean>(Available.CanZoomOnClick).ToBe(False);
    Expect<Boolean>(Pos('already zooms', Available.Reason) > 0).ToBe(True);
  finally
    Log.Free;
  end;
end;

procedure TAvailabilityTests.TestNoLogAtAllIsAnswerable;
var
  Available: TSidecarEffectAvailability;
begin
  Available := AvailableExportEffects(nil);
  Expect<Boolean>(Available.CanDrawCursor).ToBe(False);
  Expect<Boolean>(Available.CanZoomOnClick).ToBe(False);
  Expect<Boolean>(Available.Reason <> '').ToBe(True);
end;

begin
  TestRunnerProgram.AddSuite(TRoundTripTests.Create(
    'writing and reading a sidecar back'));
  TestRunnerProgram.AddSuite(TSourceRectTests.Create(
    'the source rectangle, written only when it moves'));
  TestRunnerProgram.AddSuite(TResilienceTests.Create(
    'a file that was cut off, or came from a newer knips'));
  TestRunnerProgram.AddSuite(TTimelineTests.Create(
    'placing events on the movie''s timeline'));
  TestRunnerProgram.AddSuite(TAvailabilityTests.Create(
    'which post-recording effects a take can still have'));
  TestRunnerProgram.AddSuite(TSmoothingTests.Create(
    'smoothing a sampled pointer path'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

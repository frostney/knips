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
    procedure TestTheStampRuleIsANamedPredicate;
    procedure TestANonAdvancingStampIsDropped;
    procedure TestADroppedRecordStillMovesTheRectangle;
  end;

  TResilienceTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestATruncatedLastLineStillLoads;
    procedure TestAnUnknownKindIsSkipped;
    procedure TestBlankLinesAreIgnored;
    procedure TestAMissingFileIsAnError;
    procedure TestANewerFormatVersionIsRefused;
    procedure TestAForeignFormatIsRefused;
    procedure TestASecondLoadKeepsNothingOfTheFirst;
  end;

  // A sidecar is a file in a directory knips scans without being asked —
  // the recovery pass runs over ~/Movies/knips at every `knips record`
  // and at every launch of the menu-bar app. So it reads files nobody
  // vetted, and the only acceptable answer to a bad one is a skipped
  // line.
  THostileFileTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestADeeplyNestedLineIsSkippedNotFatal;
    procedure TestBracketsInsideAStringDoNotCountAsNesting;
    procedure TestAnEnormousLineIsSkipped;
    procedure TestANonFiniteHeaderIsSkipped;
    procedure TestANonFiniteSampleIsDropped;
    procedure TestANonFiniteAnchorIsDropped;
    procedure TestANonFiniteButtonIsDropped;
    procedure TestANonFiniteTrailerIsDropped;
    procedure TestANonFiniteIntegerFieldIsDropped;
    procedure TestAnOutOfRangeIntegerFieldIsDropped;
    procedure TestUnbalancedBracketsAreNotNesting;
    procedure TestAMovieNameThatIsAPathIsNotBare;
    procedure TestAnOrdinaryMovieNameIsBare;
  end;

  TTimelineTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestMovieTimeIsHostTimeMinusTheAnchor;
    procedure TestCursorInterpolatesBetweenSamples;
    procedure TestASilenceIsHeldRatherThanBlended;
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
    procedure TestZoomComposesWithAPannedFraming;
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
    procedure TestALongSilenceIsNotDrawnThrough;
    procedure TestTheLogNamesItsOwnGapLimit;
    procedure TestTheGapLimitIsCappedAndFloored;
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
  // Pid-qualified, like Knips.Recording.Recovery.Test's directory: two
  // runs of this suite at once — a `lwpt test` and an editor's, or two
  // worktrees — otherwise write the same fixture path and read each
  // other's half-written file.
  Result := IncludeTrailingPathDelimiter(GetTempDir) + 'knips-sidecar-test-'
    + IntToStr(GetProcessID) + '-' + AStem + SidecarExtension;
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
  Test('a stamp advances only when it is strictly later',
    TestTheStampRuleIsANamedPredicate);
  Test('a sample whose stamp does not advance is skipped',
    TestANonAdvancingStampIsDropped);
  Test('a dropped record''s rectangle still reaches the next sample',
    TestADroppedRecordStillMovesTheRectangle);
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

procedure TSourceRectTests.TestTheStampRuleIsANamedPredicate;
begin
  // The rule the format states, asked of the function that states it
  // rather than of a comparison buried in ReadObject. Strictly later,
  // so an equal stamp is a contradiction and not a tie.
  Expect<Boolean>(SidecarSampleTimeAdvances(100.0, 100.1)).ToBe(True);
  Expect<Boolean>(SidecarSampleTimeAdvances(100.0, 100.0)).ToBe(False);
  Expect<Boolean>(SidecarSampleTimeAdvances(100.1, 100.0)).ToBe(False);
  // The smallest advance a Double can express still advances: the rule
  // is about order, not about a minimum interval.
  Expect<Boolean>(SidecarSampleTimeAdvances(100.0, 100.0 + 1E-9))
    .ToBe(True);
end;

procedure TSourceRectTests.TestANonAdvancingStampIsDropped;
var
  Log: TSidecarLog;
begin
  // Kept, dropped, kept — and the drop is a skipped line, not an error.
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}' + LineEnding
    + '{"k":"cursor","t":100.0,"x":3,"y":4,"b":0}' + LineEnding
    + '{"k":"cursor","t":99.9,"x":5,"y":6,"b":0}' + LineEnding
    + '{"k":"cursor","t":100.1,"x":7,"y":8,"b":0}');
  try
    Expect<Integer>(Log.SampleCount).ToBe(2);
    Expect<Integer>(Log.SkippedLines).ToBe(2);
    ExpectNear(Log.Sample(0).X, 1, Epsilon, 'first kept');
    ExpectNear(Log.Sample(1).X, 7, Epsilon, 'last kept');
  finally
    Log.Free;
  end;
end;

procedure TSourceRectTests.TestADroppedRecordStillMovesTheRectangle;
var
  Clean, Duplicate: TSidecarLog;
  I: Integer;
begin
  // Two sidecars identical but for one duplicate stamp, and the
  // duplicate lands on the ONE record that carries a rectangle. sx/sy/
  // sw/sh are delta-encoded, so that record is the only place the new
  // framing is written down; drop it and take the carried rectangle off
  // the last ACCEPTED sample and every later sample silently reverts to
  // the header's base rectangle — two files a byte apart rendering to
  // different pictures, with nothing but SkippedLines to say so.
  Clean := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}' + LineEnding
    + '{"k":"cursor","t":100.1,"x":3,"y":4,"b":0,'
    + '"sx":50,"sy":60,"sw":320,"sh":200}' + LineEnding
    + '{"k":"cursor","t":100.2,"x":5,"y":6,"b":0}' + LineEnding
    + '{"k":"cursor","t":100.3,"x":7,"y":8,"b":0}');
  Duplicate := LoadText(FixtureHeader + LineEnding + FixtureAnchor
    + LineEnding + '{"k":"cursor","t":100.0,"x":1,"y":2,"b":0}' + LineEnding
    + '{"k":"cursor","t":100.0,"x":3,"y":4,"b":0,'
    + '"sx":50,"sy":60,"sw":320,"sh":200}' + LineEnding
    + '{"k":"cursor","t":100.2,"x":5,"y":6,"b":0}' + LineEnding
    + '{"k":"cursor","t":100.3,"x":7,"y":8,"b":0}');
  try
    Expect<Integer>(Clean.SampleCount).ToBe(4);
    Expect<Integer>(Clean.SkippedLines).ToBe(0);
    // One line fewer, and the count says exactly that.
    Expect<Integer>(Duplicate.SampleCount).ToBe(3);
    Expect<Integer>(Duplicate.SkippedLines).ToBe(1);
    // The framing the two agree on: the last two samples of each are the
    // same two positions and must be read through the same rectangle.
    for I := 0 to 1 do
    begin
      ExpectNear(Duplicate.Sample(I + 1).SourceX,
        Clean.Sample(I + 2).SourceX, Epsilon, 'same sx');
      ExpectNear(Duplicate.Sample(I + 1).SourceY,
        Clean.Sample(I + 2).SourceY, Epsilon, 'same sy');
      ExpectNear(Duplicate.Sample(I + 1).SourceWidth,
        Clean.Sample(I + 2).SourceWidth, Epsilon, 'same sw');
      ExpectNear(Duplicate.Sample(I + 1).SourceHeight,
        Clean.Sample(I + 2).SourceHeight, Epsilon, 'same sh');
    end;
    // …and it is the rectangle the dropped record announced, not the
    // header's base one, which is what the bug produced.
    ExpectNear(Duplicate.Sample(1).SourceX, 50, Epsilon, 'moved sx');
    ExpectNear(Duplicate.Sample(1).SourceWidth, 320, Epsilon, 'moved sw');
  finally
    Clean.Free;
    Duplicate.Free;
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
  Test('a file whose format is not knips-events is refused outright',
    TestAForeignFormatIsRefused);
  Test('loading a second file keeps nothing of the first, header included',
    TestASecondLoadKeepsNothingOfTheFirst);
end;

procedure TResilienceTests.TestAForeignFormatIsRefused;
var
  Log: TSidecarLog;
  Error: string;
begin
  // The doc's blunter refusal: this is not one of these files at all, so
  // nothing in it can be trusted to mean what this reader would take it
  // to mean. It used to be skipped silently and the load came back True
  // with a default header, which is the shape of a half-read file.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(StringReplace(FixtureHeader,
      '"format":"knips-events"', '"format":"someone-elses-events"', [])
      + LineEnding + FixtureAnchor, Error)).ToBe(False);
    Expect<Boolean>(Log.ForeignFormat).ToBe(True);
    Expect<Boolean>(Pos('someone-elses-events', Error) > 0).ToBe(True);
  finally
    Log.Free;
  end;
end;

procedure TResilienceTests.TestASecondLoadKeepsNothingOfTheFirst;
var
  Log: TSidecarLog;
  Error: string;
begin
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor + LineEnding
      + '{"k":"cursor","t":100.5,"x":1,"y":2,"b":0}', Error)).ToBe(True);
    Expect<string>(Log.Header.MovieName).ToBe('demo.mp4');
    Expect<Boolean>(Log.HasAnchor).ToBe(True);
    // A file with no header at all: everything the first one said must
    // be gone, or this take would claim the previous take's movie, its
    // base rectangle and its baked-effect flags.
    Expect<Boolean>(Log.LoadFromText(
      '{"k":"cursor","t":5.0,"x":1,"y":2,"b":0}', Error)).ToBe(True);
    Expect<string>(Log.Header.MovieName).ToBe('');
    Expect<Double>(Log.Header.BaseX).ToBe(0);
    Expect<Double>(Log.Header.BaseWidth).ToBe(0);
    Expect<Boolean>(Log.Header.BakedFollowMouse).ToBe(False);
    Expect<Boolean>(Log.HasAnchor).ToBe(False);
    Expect<Integer>(Log.SampleCount).ToBe(1);
  finally
    Log.Free;
  end;
end;

{ ------------------------------------------------------ a hostile file }

procedure THostileFileTests.SetupTests;
begin
  Test('a line nested past the depth limit is skipped, not a crash',
    TestADeeplyNestedLineIsSkippedNotFatal);
  Test('brackets inside a JSON string are not nesting',
    TestBracketsInsideAStringDoNotCountAsNesting);
  Test('a line past the length limit is skipped',
    TestAnEnormousLineIsSkipped);
  Test('a header carrying an infinity is skipped whole',
    TestANonFiniteHeaderIsSkipped);
  Test('a sample carrying an infinity is dropped',
    TestANonFiniteSampleIsDropped);
  Test('an anchor carrying an infinity is dropped',
    TestANonFiniteAnchorIsDropped);
  Test('a button carrying an infinity is dropped',
    TestANonFiniteButtonIsDropped);
  Test('a trailer carrying an infinity is dropped',
    TestANonFiniteTrailerIsDropped);
  Test('every INTEGER field carrying an infinity is dropped, not fatal',
    TestANonFiniteIntegerFieldIsDropped);
  Test('an integer field too large for its type is dropped',
    TestAnOutOfRangeIntegerFieldIsDropped);
  Test('more closing brackets than opening ones is not negative nesting',
    TestUnbalancedBracketsAreNotNesting);
  Test('a `movie` that is a path, or a directory, is not a bare name',
    TestAMovieNameThatIsAPathIsNotBare);
  Test('the names a recorder actually writes are bare',
    TestAnOrdinaryMovieNameIsBare);
end;

function DeepLine(ADepth: Integer): string;
var
  I: Integer;
begin
  Result := '{"k":"cursor","t":100.5,"x":1,"y":2,"b":0,"deep":';
  for I := 1 to ADepth do
    Result := Result + '[';
  for I := 1 to ADepth do
    Result := Result + ']';
  Result := Result + '}';
end;

procedure THostileFileTests.TestADeeplyNestedLineIsSkippedNotFatal;
var
  Log: TSidecarLog;
  Error: string;
begin
  // fpjson's parser recurses, so this line used to be a stack overflow
  // — a signal, not an exception, which the per-line try cannot catch.
  // Measured before the fix: `knips record` in a directory holding one
  // of these exited 139, silently, every time.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor + LineEnding + DeepLine(50000) + LineEnding
      + '{"k":"cursor","t":101.0,"x":7,"y":8,"b":0}', Error)).ToBe(True);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
    // Everything either side of it is still there: this is a skipped
    // line, exactly like an unknown kind.
    Expect<Integer>(Log.SampleCount).ToBe(1);
    Expect<Double>(Log.Sample(0).X).ToBe(7);
  finally
    Log.Free;
  end;
  // And a line just inside the limit still parses.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor + LineEnding + DeepLine(MaxSidecarLineDepth - 1),
      Error)).ToBe(True);
    Expect<Integer>(Log.SkippedLines).ToBe(0);
    Expect<Integer>(Log.SampleCount).ToBe(1);
  finally
    Log.Free;
  end;
end;

procedure THostileFileTests.TestBracketsInsideAStringDoNotCountAsNesting;
var
  Log: TSidecarLog;
  Error: string;
  Movie: string;
  I: Integer;
begin
  // A movie called `[[[[….mp4` is a legal file name, and the depth scan
  // must not read its brackets as structure.
  Movie := '';
  for I := 1 to 200 do
    Movie := Movie + '[';
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(StringReplace(FixtureHeader,
      '"movie":"demo.mp4"', '"movie":"' + Movie + '\".mp4"', []), Error))
      .ToBe(True);
    Expect<Integer>(Log.SkippedLines).ToBe(0);
    Expect<string>(Log.Header.MovieName).ToBe(Movie + '".mp4');
  finally
    Log.Free;
  end;
end;

procedure THostileFileTests.TestAnEnormousLineIsSkipped;
var
  Log: TSidecarLog;
  Error: string;
  Padding: string;
begin
  Padding := StringOfChar('x', MaxSidecarLineBytes + 1);
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor + LineEnding
      + '{"k":"cursor","t":100.5,"x":1,"y":2,"b":0,"pad":"' + Padding
      + '"}', Error)).ToBe(True);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
    Expect<Integer>(Log.SampleCount).ToBe(0);
  finally
    Log.Free;
  end;
end;

procedure THostileFileTests.TestANonFiniteHeaderIsSkipped;
var
  Log: TSidecarLog;
  Error: string;
  I: Integer;
  Fields: array[0..5] of string;
begin
  // `1e999` is legal JSON and parses to +Inf. Two infinities subtracted
  // are a NaN, and a NaN walked through the staleness test and the edge
  // snap came out as a render silently 217 frames short.
  Fields[0] := '"baseWidth":640';
  Fields[1] := '"baseHeight":400';
  Fields[2] := '"baseX":10';
  Fields[3] := '"baseY":20';
  Fields[4] := '"displayWidth":1440';
  Fields[5] := '"sampleHz":30';
  for I := Low(Fields) to High(Fields) do
  begin
    Log := TSidecarLog.Create;
    try
      Expect<Boolean>(Log.LoadFromText(StringReplace(FixtureHeader,
        Fields[I], Copy(Fields[I], 1, Pos(':', Fields[I])) + '1e999', [])
        + LineEnding + FixtureAnchor, Error)).ToBe(True);
      Expect<Integer>(Log.SkippedLines).ToBe(1);
      // Nothing of the poisoned header was applied: not even the fields
      // that were fine.
      Expect<string>(Log.Header.MovieName).ToBe('');
      Expect<Double>(Log.Header.BaseWidth).ToBe(0);
    finally
      Log.Free;
    end;
  end;
end;

procedure THostileFileTests.TestANonFiniteSampleIsDropped;
var
  Log: TSidecarLog;
  Error: string;
  I: Integer;
  Lines: array[0..6] of string;
begin
  Lines[0] := '{"k":"cursor","t":1e999,"x":1,"y":2,"b":0}';
  Lines[1] := '{"k":"cursor","t":100.5,"x":1e999,"y":2,"b":0}';
  Lines[2] := '{"k":"cursor","t":100.5,"x":1,"y":-1e999,"b":0}';
  Lines[3] := '{"k":"cursor","t":100.5,"x":1,"y":2,"b":0,"sx":1e999}';
  Lines[4] := '{"k":"cursor","t":100.5,"x":1,"y":2,"b":0,"sy":1e999}';
  Lines[5] := '{"k":"cursor","t":100.5,"x":1,"y":2,"b":0,"sw":1e999}';
  Lines[6] := '{"k":"cursor","t":100.5,"x":1,"y":2,"b":0,"sh":1e999}';
  for I := Low(Lines) to High(Lines) do
  begin
    Log := TSidecarLog.Create;
    try
      Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
        + FixtureAnchor + LineEnding + Lines[I] + LineEnding
        + '{"k":"cursor","t":101.0,"x":5,"y":6,"b":0}', Error)).ToBe(True);
      Expect<Integer>(Log.SkippedLines).ToBe(1);
      Expect<Integer>(Log.SampleCount).ToBe(1);
      // And the good sample after it did not inherit an infinite
      // rectangle from the one that was dropped.
      Expect<Double>(Log.Sample(0).SourceWidth).ToBe(640);
    finally
      Log.Free;
    end;
  end;
end;

procedure THostileFileTests.TestANonFiniteAnchorIsDropped;
var
  Log: TSidecarLog;
  Error: string;
begin
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + '{"k":"anchor","host":1e999}' + LineEnding
      + '{"k":"cursor","t":100.5,"x":1,"y":2,"b":0}', Error)).ToBe(True);
    Expect<Boolean>(Log.HasAnchor).ToBe(False);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
  finally
    Log.Free;
  end;
end;

procedure THostileFileTests.TestANonFiniteButtonIsDropped;
var
  Log: TSidecarLog;
  Error: string;
begin
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor + LineEnding
      + '{"k":"button","t":1e999,"x":1,"y":2,"n":0,"d":true}' + LineEnding
      + '{"k":"button","t":100.5,"x":1,"y":1e999,"n":0,"d":false}',
      Error)).ToBe(True);
    Expect<Integer>(Log.ButtonCount).ToBe(0);
    Expect<Integer>(Log.SkippedLines).ToBe(2);
  finally
    Log.Free;
  end;
end;

// The integer half of the same rule, and the one that used to be fatal
// rather than merely wrong.
//
// `TJSONObject.Get(name, Integer)` coerces whatever is under the name,
// and coercing a +Inf RAISES — outside the per-line `try`, which used to
// wrap only the parse. So a line with `"fps":1e999` in it did not skip:
// it killed the process, exit 217, taking the whole load with it. On
// macOS the raise is masked (MacOSAll masks invalidOp at unit init, and
// the value comes back as -1 instead — a `"version":-1` that walks
// straight past the TooNew test, and a `"pid":-1` that reads as alive),
// which is why it was invisible on device and live everywhere else: this
// suite, Linux CI, Wine, and any third-party reader of a format whose
// documentation now promises that a bad line is never fatal.
procedure THostileFileTests.TestANonFiniteIntegerFieldIsDropped;
var
  Log: TSidecarLog;
  Error: string;
  I: Integer;
  Fields: array[0..6] of string;
begin
  // Every integer field of the header, one at a time. The header is
  // skipped whole, so nothing of the poisoned line is applied.
  Fields[0] := '"version":1';
  Fields[1] := '"pid":0';
  Fields[2] := '"pixelWidth":1280';
  Fields[3] := '"pixelHeight":800';
  Fields[4] := '"scale":2';
  Fields[5] := '"fps":30';
  Fields[6] := '"displayId":1';
  for I := Low(Fields) to High(Fields) do
  begin
    Log := TSidecarLog.Create;
    try
      Expect<Boolean>(Log.LoadFromText(StringReplace(FixtureHeader,
        Fields[I], Copy(Fields[I], 1, Pos(':', Fields[I])) + '1e999', [])
        + LineEnding + FixtureAnchor + LineEnding
        + '{"k":"cursor","t":100.5,"x":1,"y":2,"b":0}', Error)).ToBe(True);
      Expect<Integer>(Log.SkippedLines).ToBe(1);
      Expect<string>(Log.Header.MovieName).ToBe('');
      // And in particular the version did not come back as something
      // that slipped past the refusal.
      Expect<Boolean>(Log.TooNew).ToBe(False);
      Expect<Integer>(Log.Header.Version).ToBe(SidecarFormatVersion);
      // The rest of the file still loaded, which is the promise.
      Expect<Integer>(Log.SampleCount).ToBe(1);
    finally
      Log.Free;
    end;
  end;
  // The trailer's two, the button's index and the sample's mask.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor + LineEnding
      + '{"k":"trailer","t":200.0,"frames":1e999,"duration":1.0,'
      + '"samples":10,"recovered":false}', Error)).ToBe(True);
    Expect<Boolean>(Log.HasTrailer).ToBe(False);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
  finally
    Log.Free;
  end;
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor + LineEnding
      + '{"k":"trailer","t":200.0,"frames":10,"duration":1.0,'
      + '"samples":-1e999,"recovered":false}', Error)).ToBe(True);
    Expect<Boolean>(Log.HasTrailer).ToBe(False);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
  finally
    Log.Free;
  end;
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor + LineEnding
      + '{"k":"button","t":100.5,"x":1,"y":2,"n":1e999,"d":true}'
      + LineEnding + '{"k":"cursor","t":100.6,"x":1,"y":2,"b":1e999}',
      Error)).ToBe(True);
    Expect<Integer>(Log.ButtonCount).ToBe(0);
    Expect<Integer>(Log.SampleCount).ToBe(0);
    Expect<Integer>(Log.SkippedLines).ToBe(2);
  finally
    Log.Free;
  end;
end;

// A number that is finite and still cannot be the field it is in. The
// old read truncated silently — `"scale":5000000000` came back as some
// other number entirely — which is the same class of quiet wrongness the
// infinities were, without the crash.
procedure THostileFileTests.TestAnOutOfRangeIntegerFieldIsDropped;
var
  Log: TSidecarLog;
  Error: string;
begin
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(StringReplace(FixtureHeader,
      '"scale":2', '"scale":5000000000', []) + LineEnding + FixtureAnchor,
      Error)).ToBe(True);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
    Expect<string>(Log.Header.MovieName).ToBe('');
  finally
    Log.Free;
  end;
  // A negative display id cannot be a CGDirectDisplayID either.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(StringReplace(FixtureHeader,
      '"displayId":1', '"displayId":-1', []) + LineEnding + FixtureAnchor,
      Error)).ToBe(True);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
  finally
    Log.Free;
  end;
  // And the ordinary values still load, which is the other half of a
  // range check being worth anything.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor, Error)).ToBe(True);
    Expect<Integer>(Log.SkippedLines).ToBe(0);
    Expect<Integer>(Log.Header.Scale).ToBe(2);
    Expect<Integer>(Log.Header.FramesPerSecond).ToBe(30);
  finally
    Log.Free;
  end;
end;

procedure THostileFileTests.TestUnbalancedBracketsAreNotNesting;
var
  Log: TSidecarLog;
  Error: string;
  Closers: string;
  I: Integer;
begin
  // A line with more closers than openers drives a naive depth counter
  // negative, and a negative counter buys the rest of the line an
  // allowance it did not earn. The floor is defence in depth rather
  // than a case anybody has met — an unbalanced line is not valid JSON,
  // so the parser refuses it whichever way the counter went — and what
  // is pinned here is the outcome either way: skipped, nothing loaded,
  // and the load itself still succeeds.
  Closers := '';
  for I := 1 to 100 do
    Closers := Closers + ']';
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor + LineEnding + Closers + DeepLine(50000),
      Error)).ToBe(True);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
    Expect<Integer>(Log.SampleCount).ToBe(0);
  finally
    Log.Free;
  end;
end;

procedure THostileFileTests.TestANonFiniteTrailerIsDropped;
var
  Log: TSidecarLog;
  Error: string;
begin
  // This one matters twice over: a trailer is what tells the recovery
  // pass a take is finished, and an infinite duration in it would be
  // read back as the movie's own length.
  Log := TSidecarLog.Create;
  try
    Expect<Boolean>(Log.LoadFromText(FixtureHeader + LineEnding
      + FixtureAnchor + LineEnding
      + '{"k":"trailer","t":200.0,"frames":10,"duration":1e999,'
      + '"samples":10,"recovered":false}', Error)).ToBe(True);
    Expect<Boolean>(Log.HasTrailer).ToBe(False);
    Expect<Integer>(Log.SkippedLines).ToBe(1);
  finally
    Log.Free;
  end;
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
  Test('a silence too long to believe is held rather than blended',
    TestASilenceIsHeldRatherThanBlended);
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
  // 0.4 s apart, which is a long gap for a 30 Hz track and still well
  // inside the silence this reader will draw a line through. A second
  // apart — which this fixture used to be — is past it, and the reader
  // holds instead of blending; see
  // TestALongSilenceIsNotDrawnThrough for that half of the rule.
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":0,"y":0,"b":0}' + LineEnding
    + '{"k":"cursor","t":100.4,"x":100,"y":200,"b":0}');
  try
    Expect<Boolean>(Log.CursorAt(0.1, X, Y)).ToBe(True);
    ExpectNear(X, 25, Epsilon, 'x a quarter in');
    ExpectNear(Y, 50, Epsilon, 'y a quarter in');
    Log.CursorAt(0.3, X, Y);
    ExpectNear(X, 75, Epsilon, 'x three quarters in');
  finally
    Log.Free;
  end;
end;

// The reader's half of the silence rule. Same fixture shape, one second
// apart instead of four tenths: past the limit the earlier sample's
// position stands rather than a line being drawn through it.
procedure TTimelineTests.TestASilenceIsHeldRatherThanBlended;
var
  Log: TSidecarLog;
  X, Y: Double;
begin
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor + LineEnding
    + '{"k":"cursor","t":100.0,"x":0,"y":0,"b":0}' + LineEnding
    + '{"k":"cursor","t":101.0,"x":100,"y":200,"b":0}');
  try
    Expect<Boolean>(Log.CursorAt(0.25, X, Y)).ToBe(True);
    ExpectNear(X, 0, Epsilon, 'held rather than a quarter across');
    ExpectNear(Y, 0, Epsilon, 'held rather than a quarter down');
    Log.CursorAt(0.99, X, Y);
    ExpectNear(X, 0, Epsilon, 'still held at the far end');
    Log.CursorAt(1.0, X, Y);
    ExpectNear(X, 100, Epsilon, 'and snaps when the track speaks again');
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
    + '{"k":"cursor","t":100.4,"x":10,"y":10,"b":0,'
    + '"sx":50,"sy":50,"sw":200,"sh":200}');
  try
    Expect<Boolean>(Log.StateAt(0.2, State)).ToBe(True);
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
  Test('a silence too long to believe is held, not drawn through',
    TestALongSilenceIsNotDrawnThrough);
  Test('a take names its own limit on that silence',
    TestTheLogNamesItsOwnGapLimit);
  Test('that limit is capped and floored against a hostile header',
    TestTheGapLimitIsCappedAndFloored);
end;

// Samples every 1/30 s along a straight line, with one optional spike.
function Ramp(ACount: Integer; ASpikeIndex: Integer;
  ASpikeOffset: Double): TSidecarSampleArray;
var
  I: Integer;
begin
  // A managed result is not initialised on entry; SetLength on it is a
  // read of whatever the caller's variable held.
  Result := nil;
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
  Expect<Boolean>(InterpolatePath(Path, 3, 1 / 60, 0, X, Y)).ToBe(True);
  ExpectNear(X, 5, 1E-9, 'half a sample in');
  InterpolatePath(Path, 3, -1, 0, X, Y);
  ExpectNear(X, 0, 1E-9, 'clamped at the start');
  InterpolatePath(Path, 3, 99, 0, X, Y);
  ExpectNear(X, 20, 1E-9, 'clamped at the end');
  Expect<Boolean>(InterpolatePath(Path, 0, 0, 0, X, Y)).ToBe(False);
end;

// The sparse track, which is the one this rule exists for. An MCP
// recording gets a sample at the start, one per `record_status` call and
// one at the stop, so two samples can be minutes apart — and a lerp
// between them draws a pointer gliding across the screen for a minute,
// which is a thing that never happened. It is also what would make the
// render's frame synthesis fill that minute in, every instant "a
// different picture".
procedure TSmoothingTests.TestALongSilenceIsNotDrawnThrough;
var
  Path: TSidecarSampleArray;
  X, Y: Double;
begin
  // Two samples a hundred seconds apart, the pointer at opposite ends of
  // a display.
  SetLength(Path, 2);
  Path[0] := Default(TSidecarSample);
  Path[0].Time := 1000;
  Path[0].X := 0;
  Path[0].Y := 0;
  Path[1] := Default(TSidecarSample);
  Path[1].Time := 1100;
  Path[1].X := 1000;
  Path[1].Y := 800;
  // With no limit asked for, the old answer: half way across the screen.
  InterpolatePath(Path, 2, 1050, 0, X, Y);
  ExpectNear(X, 500, 1E-9, 'unlimited interpolation still slides');
  // With the limit a real take carries, the last thing actually known.
  InterpolatePath(Path, 2, 1050, MinInterpolatedGapSeconds, X, Y);
  ExpectNear(X, 0, 1E-9, 'the held x');
  ExpectNear(Y, 0, 1E-9, 'the held y');
  // Held all the way, not eased — so the shape stops changing and the
  // render stops filling.
  InterpolatePath(Path, 2, 1099.9, MinInterpolatedGapSeconds, X, Y);
  ExpectNear(X, 0, 1E-9, 'still held at the far end of the silence');
  // And it snaps to the next sample when the track speaks again.
  InterpolatePath(Path, 2, 1100, MinInterpolatedGapSeconds, X, Y);
  ExpectNear(X, 1000, 1E-9, 'the snap at the next sample');
  // An ordinary 30 Hz gap is nowhere near the limit and still blends.
  Path := Ramp(3, -1, 0);
  InterpolatePath(Path, 3, 1 / 60, MinInterpolatedGapSeconds, X, Y);
  ExpectNear(X, 5, 1E-9, 'an ordinary gap is still interpolated');
end;

// The reader's own limit, taken from the header rather than from a
// constant a caller had to know.
procedure TSmoothingTests.TestTheLogNamesItsOwnGapLimit;
var
  Log: TSidecarLog;
begin
  Log := LoadText(FixtureHeader + LineEnding + FixtureAnchor);
  try
    // 30 Hz in the fixture's header: fifteen intervals is half a
    // second, and the floor is the same, so the answer is the floor.
    // Both spellings, because comparing the floor with itself is a
    // tautology that would survive the floor moving to anything at all.
    ExpectNear(Log.MaxInterpolatedGap, 0.5, 1E-9,
      'the limit at 30 Hz, in seconds');
    ExpectNear(Log.MaxInterpolatedGap, MinInterpolatedGapSeconds, 1E-9,
      'the limit at 30 Hz');
  finally
    Log.Free;
  end;
end;

// `sampleHz` is a number in a file, and this format is public — so the
// two ways a file can be unhelpful about it are pinned rather than
// assumed. Neither is a hypothetical: a slow rate is what a tool writing
// one sample a call would honestly declare, and a missing one is what an
// older writer leaves.
procedure TSmoothingTests.TestTheGapLimitIsCappedAndFloored;
var
  Log: TSidecarLog;
begin
  // A header claiming one sample every twenty seconds. Fifteen of those
  // is five minutes, which would hand a straight line the whole take.
  Log := LoadText(StringReplace(FixtureHeader, '"sampleHz":30',
    '"sampleHz":0.05', []) + LineEnding + FixtureAnchor);
  try
    ExpectNear(Log.MaxInterpolatedGap, MaxInterpolatedGapSeconds, 1E-9,
      'an absurdly slow rate is capped');
  finally
    Log.Free;
  end;
  // A rate between the two bounds is honoured as written: five hertz is
  // three seconds of interval-multiple, capped to two.
  Log := LoadText(StringReplace(FixtureHeader, '"sampleHz":30',
    '"sampleHz":5', []) + LineEnding + FixtureAnchor);
  try
    ExpectNear(Log.MaxInterpolatedGap, MaxInterpolatedGapSeconds, 1E-9,
      'five hertz reaches the cap');
  finally
    Log.Free;
  end;
  // Ten hertz is 1.5 s, which is inside both bounds and comes through.
  Log := LoadText(StringReplace(FixtureHeader, '"sampleHz":30',
    '"sampleHz":10', []) + LineEnding + FixtureAnchor);
  try
    ExpectNear(Log.MaxInterpolatedGap, 1.5, 1E-9,
      'a rate between the bounds is honoured');
  finally
    Log.Free;
  end;
  // A rate of zero is not a slow sampler, it is a damaged number — and
  // this reader divides by it. The floor, not a division.
  Log := LoadText(StringReplace(FixtureHeader, '"sampleHz":30',
    '"sampleHz":0', []) + LineEnding + FixtureAnchor);
  try
    ExpectNear(Log.MaxInterpolatedGap, MinInterpolatedGapSeconds, 1E-9,
      'a zero rate falls back to the floor');
  finally
    Log.Free;
  end;
  // A header with no sampleHz field at all reads as the documented
  // default of 30 Hz. This assertion is here because it did NOT: the
  // reader's fallback went through `TJSONFloat(30)`, which in Delphi
  // mode reinterprets the integer's bits as a Double and produced a
  // denormal of about 1.5E-322 — a header claiming three hundred
  // sextillionths of a sample a second. Nothing noticed until something
  // divided by it.
  Log := LoadText(StringReplace(FixtureHeader, '"sampleHz":30,', '', [])
    + LineEnding + FixtureAnchor);
  try
    ExpectNear(Log.Header.SampleHz, 30, 1E-9,
      'a missing rate is the documented default');
    ExpectNear(Log.MaxInterpolatedGap, MinInterpolatedGapSeconds, 1E-9,
      'and yields the ordinary limit');
  finally
    Log.Free;
  end;
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
  Test('post-hoc zoom composes with a panned framing and is refused only '
    + 'by a baked zoom', TestZoomComposesWithAPannedFraming);
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
    // The fixture header pans (bakedFollowMouse). Both effects are open:
    // every sample carries the rectangle the capture was reading at that
    // instant, so the pointer's mapping follows the pan and the crop is
    // composed inside it. What the pan closes is only the claim that
    // NOTHING is baked — the pan itself is, for good.
    Expect<Boolean>(Available.CanZoomOnClick).ToBe(True);
    Expect<Boolean>(Available.FullyRenderable).ToBe(False);
    Expect<Boolean>(Pos('panned by the capture', Available.Reason) > 0)
      .ToBe(True);
    Expect<string>(Available.ZoomReason).ToBe('');
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

// The rule, and the change it went through. A capture that ZOOMED itself
// still closes the post-hoc zoom, because a crop applied to a crop
// compounds and nothing can take the first one out again. A capture that
// merely PANNED — Follow Mouse, or a composited window recording's poll —
// does not: the crop is composed inside the rectangle the capture was
// reading at that instant (Knips.Export.ZoomTrack.ZoomWalkerSourceRectIn),
// which is exactly where the live effect puts it.
//
// It used to be refused for all three, and for the code that existed the
// refusal was right: the crop was taken against the recording's base
// rectangle, so a panned take rendered against a rectangle its pixels
// were not showing — measured, 36 mis-cropped frames on a Follow Mouse
// take. Both halves are pinned here so neither can come back.
procedure TAvailabilityTests.TestZoomComposesWithAPannedFraming;
var
  Log: TSidecarLog;

  procedure ExpectOffered(const AWhat, AHeader: string; AOffered: Boolean);
  var
    Log: TSidecarLog;
    Available: TSidecarEffectAvailability;
  begin
    Log := LoadText(AHeader + AvailabilityBody);
    try
      Available := AvailableExportEffects(Log);
      Expect<string>(AWhat + ' -> zoom '
        + BoolToStr(Available.CanZoomOnClick, 'offered', 'refused'))
        .ToBe(AWhat + ' -> zoom '
        + BoolToStr(AOffered, 'offered', 'refused'));
      Expect<Boolean>(Available.ZoomReason <> '').ToBe(not AOffered);
    finally
      Log.Free;
    end;
  end;

begin
  ExpectOffered('bakedZoomOnClick',
    AvailabilityHeader('smooth', True, False, False), False);
  ExpectOffered('bakedFollowMouse',
    AvailabilityHeader('smooth', False, True, False), True);
  ExpectOffered('bakedWindowFollow',
    AvailabilityHeader('smooth', False, False, True), True);
  // And the control: nothing panned, so the zoom is offered.
  Log := LoadText(AvailabilityHeader('smooth', False, False, False)
    + AvailabilityBody);
  try
    Expect<Boolean>(AvailableExportEffects(Log).CanZoomOnClick).ToBe(True);
  finally
    Log.Free;
  end;
  // A panned take is still not FULLY renderable — the pan is in its
  // pixels for good — and the summary says so even though both effects
  // are open.
  Log := LoadText(AvailabilityHeader('smooth', False, True, False)
    + AvailabilityBody);
  try
    Expect<Boolean>(AvailableExportEffects(Log).FullyRenderable).ToBe(False);
    Expect<Boolean>(Pos('panned by the capture',
      AvailableExportEffects(Log).Reason) > 0).ToBe(True);
  finally
    Log.Free;
  end;
end;

// The other half of the same rule: a pointer that is already in the
// pixels is part of the picture and scales with the crop exactly as the
// live effect's would have. An ordinary `knips record` take can still be
// zoomed after the fact.
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

procedure THostileFileTests.TestAMovieNameThatIsAPathIsNotBare;
begin
  // The reproduction this predicate exists for: a sidecar planted in a
  // recording directory naming `../B/victim.mp4` made the recovery pass
  // re-mux and replace a movie in a DIFFERENT directory. The format has
  // always said `movie` is a file name and not a path; this is the
  // question that says it in code.
  Expect<Boolean>(SidecarMovieNameIsBare('../victim.mp4')).ToBe(False);
  Expect<Boolean>(SidecarMovieNameIsBare('../B/victim.mp4')).ToBe(False);
  Expect<Boolean>(SidecarMovieNameIsBare('/tmp/victim.mp4')).ToBe(False);
  Expect<Boolean>(SidecarMovieNameIsBare('sub/take.mp4')).ToBe(False);
  // A backslash is this host's separator on Windows and a legal file
  // name character on macOS, where the recorder writes `a\b.mp4`
  // verbatim (Knips.Recording.OpenSidecar) — so the answer follows
  // PathDelim rather than being refused everywhere, or a legal name would
  // silently never be recovered.
  Expect<Boolean>(SidecarMovieNameIsBare('a\b.mp4')).ToBe(PathDelim = '/');
  // The two names that are a directory rather than a movie. Joined to
  // the scan's own directory they name the directory itself.
  Expect<Boolean>(SidecarMovieNameIsBare('.')).ToBe(False);
  Expect<Boolean>(SidecarMovieNameIsBare('..')).ToBe(False);
  Expect<Boolean>(SidecarMovieNameIsBare('')).ToBe(False);
end;

procedure THostileFileTests.TestAnOrdinaryMovieNameIsBare;
begin
  // Everything a real take is called, including the shapes the app and
  // the MCP face write. A predicate that refused one of these would
  // silently stop recovering ordinary recordings.
  Expect<Boolean>(SidecarMovieNameIsBare('demo.mp4')).ToBe(True);
  Expect<Boolean>(SidecarMovieNameIsBare('Knips 2026-09-08 at 12.01.02-raw.mp4'))
    .ToBe(True);
  Expect<Boolean>(SidecarMovieNameIsBare('say "hi".mov')).ToBe(True);
  Expect<Boolean>(SidecarMovieNameIsBare('..hidden.mp4')).ToBe(True);
end;

begin
  TestRunnerProgram.AddSuite(TRoundTripTests.Create(
    'writing and reading a sidecar back'));
  TestRunnerProgram.AddSuite(TSourceRectTests.Create(
    'the source rectangle, written only when it moves'));
  TestRunnerProgram.AddSuite(TResilienceTests.Create(
    'a file that was cut off, or came from a newer knips'));
  TestRunnerProgram.AddSuite(THostileFileTests.Create(
    'a file nobody vetted, in a directory knips scans unasked'));
  TestRunnerProgram.AddSuite(TTimelineTests.Create(
    'placing events on the movie''s timeline'));
  TestRunnerProgram.AddSuite(TAvailabilityTests.Create(
    'which post-recording effects a take can still have'));
  TestRunnerProgram.AddSuite(TSmoothingTests.Create(
    'smoothing a sampled pointer path'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

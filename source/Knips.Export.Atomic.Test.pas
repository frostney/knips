program Knips.Export.Atomic.Test;

// Filesystem ownership and writer failures must leave an existing output
// intact. AVAssetWriter runs here without opening a capture stream.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

uses
  {$IFDEF DARWIN}
  cmem,
  Knips.ThreadManager,
  {$ENDIF}
  Classes,
  SysUtils,

  {$IFDEF DARWIN}
  BaseUnix,
  CocoaAll,
  Knips.Export.Atomic,
  Knips.Export.MovieWriter,
  {$ENDIF}
  Knips.Options,
  TestingPascalLibrary;

type
  {$IFDEF DARWIN}
  TAtomicTests = class(TTestSuite)
  private
    FDirectory: string;
    procedure OpenDirectory;
    procedure CloseDirectory;
    procedure WriteFile(const APath, AText: string);
    function ReadFile(const APath: string): string;
  public
    procedure SetupTests; override;
    procedure TestClaimsDoNotShareOrSweepOtherFiles;
    procedure TestBackslashInTemporaryName;
    procedure TestCommitFailureRetainsOutputAndClaim;
    procedure TestCommitReplacesOutput;
    procedure TestPreserveReleasesClaimWithoutDeletingFragments;
    procedure TestSymlinkOutputIsRefused;
    procedure TestWriterCancelPreservesOutput;
    procedure TestWriterWithoutFramesPreservesOutput;
  end;
  {$ELSE}
  TPortableTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestUniqueTemporaryRetainsRecoverySuffix;
  end;
  {$ENDIF}

{$IFDEF DARWIN}

procedure TAtomicTests.SetupTests;
begin
  Test('claims are unique and unowned sweeps cannot delete scratch',
    TestClaimsDoNotShareOrSweepOtherFiles);
  Test('a backslash in a Unix basename stays in the same parent directory',
    TestBackslashInTemporaryName);
  Test('a failed commit retains the previous output and its owner marker',
    TestCommitFailureRetainsOutputAndClaim);
  Test('a successful commit replaces the output and releases its claim',
    TestCommitReplacesOutput);
  Test('preserving fragments releases ownership without deleting them',
    TestPreserveReleasesClaimWithoutDeletingFragments);
  Test('a symlink output is refused without changing its target',
    TestSymlinkOutputIsRefused);
  Test('cancelling a movie writer preserves the previous output',
    TestWriterCancelPreservesOutput);
  Test('finishing without frames preserves the previous output',
    TestWriterWithoutFramesPreservesOutput);
end;

procedure TAtomicTests.OpenDirectory;
var
  Token: TGUID;
begin
  if CreateGUID(Token) <> 0 then
    raise Exception.Create('cannot create test directory name');
  FDirectory := IncludeTrailingPathDelimiter(GetTempDir(False))
    + 'knips-atomic-test-' + Copy(GUIDToString(Token), 2, 36) + PathDelim;
  if not CreateDir(FDirectory) then
    raise Exception.Create('cannot create test directory');
end;

procedure TAtomicTests.CloseDirectory;
var
  Entries: PDir;
  Entry: PDirent;
begin
  Entries := FpOpenDir(PChar(FDirectory));
  if Entries <> nil then
    try
      Entry := FpReadDir(Entries^);
      while Entry <> nil do
      begin
        DeleteFile(FDirectory + StrPas(@Entry^.d_name[0]));
        Entry := FpReadDir(Entries^);
      end;
    finally
      FpCloseDir(Entries^);
    end;
  RemoveDir(FDirectory);
end;

procedure TAtomicTests.WriteFile(const APath, AText: string);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if AText <> '' then
      Stream.WriteBuffer(AText[1], Length(AText));
  finally
    Stream.Free;
  end;
end;

function TAtomicTests.ReadFile(const APath: string): string;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Result <> '' then
      Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure TAtomicTests.TestClaimsDoNotShareOrSweepOtherFiles;
var
  Template, First, Second, Error: string;
begin
  OpenDirectory;
  First := '';
  Second := '';
  try
    Template := RenderTemporaryPathFor(FDirectory + 'take.mp4');
    WriteFile(Template, 'unowned scratch');
    First := Template;
    Expect<Boolean>(ClaimTemporary(First, Error)).ToBe(True);
    WriteFile(First, 'first operation');
    Second := Template;
    Expect<Boolean>(ClaimTemporary(Second, Error)).ToBe(True);
    WriteFile(Second, 'second operation');
    Expect<Boolean>(First <> Second).ToBe(True);
    Expect<Boolean>(First <> Template).ToBe(True);
    Expect<Boolean>(Second <> Template).ToBe(True);
    SweepTemporary(Template);
    Expect<string>(ReadFile(Template)).ToBe('unowned scratch');
    Expect<string>(ReadFile(First)).ToBe('first operation');
    Expect<string>(ReadFile(Second)).ToBe('second operation');
    Expect<Boolean>(FileExists(RenderTemporaryOwnerPathFor(First))).ToBe(True);
    Expect<Boolean>(FileExists(RenderTemporaryOwnerPathFor(Second))).ToBe(True);
    Expect<Boolean>(CommitTemporary(Template, FDirectory + 'out.mp4',
      Error)).ToBe(False);
    Expect<string>(ReadFile(Template)).ToBe('unowned scratch');
    SweepTemporary(First);
    Expect<Boolean>(FileExists(First)).ToBe(False);
    Expect<string>(ReadFile(Second)).ToBe('second operation');
  finally
    SweepTemporary(First);
    SweepTemporary(Second);
    CloseDirectory;
  end;
end;

procedure TAtomicTests.TestBackslashInTemporaryName;
var
  Template, Temporary, Error, Name: string;
begin
  OpenDirectory;
  Temporary := '';
  try
    Name := 'literal\take.mp4' + RenderTemporarySuffix;
    Template := FDirectory + Name;
    Temporary := Template;
    Expect<Boolean>(ClaimTemporary(Temporary, Error)).ToBe(True);
    Expect<string>(Copy(Temporary, 1, Length(FDirectory))).ToBe(FDirectory);
    Expect<Integer>(LastDelimiter('/', Temporary)).ToBe(Length(FDirectory));
    Expect<string>(Copy(Temporary, Length(Temporary) - Length(Name) + 1,
      Length(Name))).ToBe(Name);
    WriteFile(Temporary, 'literal backslash');
    WriteFile(Temporary + RenderTemporaryShadowPrefix + 'test', 'shadow');
    SweepTemporary(Temporary);
    Expect<Boolean>(FileExists(Temporary)).ToBe(False);
    if FileExists(Temporary + RenderTemporaryShadowPrefix + 'test') then
      raise Exception.Create('sweep left the backslash-named sandbox shadow');
    Expect<Boolean>(FileExists(RenderTemporaryOwnerPathFor(Temporary))).ToBe(False);
  finally
    SweepTemporary(Temporary);
    CloseDirectory;
  end;
end;

procedure TAtomicTests.TestCommitFailureRetainsOutputAndClaim;
var
  Temporary, Output, Error: string;
begin
  OpenDirectory;
  Temporary := '';
  try
    Output := FDirectory + 'take.mp4';
    WriteFile(Output, 'previous take');
    Temporary := RenderTemporaryPathFor(Output);
    Expect<Boolean>(ClaimTemporary(Temporary, Error)).ToBe(True);
    // No temporary was written: exercising the actual rename failure
    // also checks that a failed commit does not relinquish ownership.
    Expect<Boolean>(CommitTemporary(Temporary, Output, Error)).ToBe(False);
    Expect<Boolean>(Error <> '').ToBe(True);
    Expect<string>(ReadFile(Output)).ToBe('previous take');
    Expect<Boolean>(FileExists(RenderTemporaryOwnerPathFor(Temporary))).ToBe(True);
    WriteFile(Temporary, 'completed later');
    Expect<Boolean>(CommitTemporary(Temporary, Output, Error)).ToBe(True);
    Expect<string>(ReadFile(Output)).ToBe('completed later');
  finally
    SweepTemporary(Temporary);
    CloseDirectory;
  end;
end;

procedure TAtomicTests.TestCommitReplacesOutput;
var
  Temporary, Output, Error: string;
begin
  OpenDirectory;
  Temporary := '';
  try
    Output := FDirectory + 'take.mp4';
    WriteFile(Output, 'previous take');
    Temporary := RenderTemporaryPathFor(Output);
    Expect<Boolean>(ClaimTemporary(Temporary, Error)).ToBe(True);
    WriteFile(Temporary, 'finished take');
    Expect<Boolean>(CommitTemporary(Temporary, Output, Error)).ToBe(True);
    Expect<string>(ReadFile(Output)).ToBe('finished take');
    Expect<Boolean>(FileExists(Temporary)).ToBe(False);
    Expect<Boolean>(FileExists(RenderTemporaryOwnerPathFor(Temporary))).ToBe(False);
    // A later file at that name no longer belongs to the finished writer.
    WriteFile(Temporary, 'another owner');
    SweepTemporary(Temporary);
    Expect<string>(ReadFile(Temporary)).ToBe('another owner');
  finally
    SweepTemporary(Temporary);
    CloseDirectory;
  end;
end;

procedure TAtomicTests.TestPreserveReleasesClaimWithoutDeletingFragments;
var
  Temporary, Error: string;
begin
  OpenDirectory;
  Temporary := '';
  try
    Temporary := RenderTemporaryPathFor(FDirectory + 'take.mp4');
    Expect<Boolean>(ClaimTemporary(Temporary, Error)).ToBe(True);
    WriteFile(Temporary, 'recoverable fragments');
    PreserveTemporary(Temporary);
    Expect<Boolean>(FileExists(RenderTemporaryOwnerPathFor(Temporary))).ToBe(False);
    SweepTemporary(Temporary);
    Expect<string>(ReadFile(Temporary)).ToBe('recoverable fragments');
    Expect<Boolean>(CommitTemporary(Temporary, FDirectory + 'take.mp4',
      Error)).ToBe(False);
  finally
    SweepTemporary(Temporary);
    CloseDirectory;
  end;
end;

procedure TAtomicTests.TestSymlinkOutputIsRefused;
var
  Temporary, Output, Target, Error: string;
  Writer: TMovieWriter;
begin
  OpenDirectory;
  Temporary := '';
  try
    Target := FDirectory + 'valuable.mp4';
    Output := FDirectory + 'link.mp4';
    WriteFile(Target, 'valuable take');
    Expect<Integer>(FpSymlink(PChar(Target), PChar(Output))).ToBe(0);
    Temporary := RenderTemporaryPathFor(Output);
    Expect<Boolean>(ClaimTemporary(Temporary, Error)).ToBe(True);
    WriteFile(Temporary, 'replacement');
    Expect<Boolean>(CommitTemporary(Temporary, Output, Error)).ToBe(False);
    Expect<Boolean>(OutputPathRefusal(Output) <> '').ToBe(True);
    Expect<string>(ReadFile(Target)).ToBe('valuable take');
    Expect<string>(ReadFile(Temporary)).ToBe('replacement');
    Expect<Boolean>(FileExists(RenderTemporaryOwnerPathFor(Temporary))).ToBe(True);
    Writer := TMovieWriter.Create(Output, ocMPEG4, 64, 64, 30, 1000000);
    try
      Expect<Boolean>(Writer.Open(Error)).ToBe(False);
    finally
      Writer.Free;
    end;
    Expect<Boolean>(OutputPathRefusal(Output) <> '').ToBe(True);
    Expect<string>(ReadFile(Target)).ToBe('valuable take');
  finally
    SweepTemporary(Temporary);
    CloseDirectory;
  end;
end;

procedure TAtomicTests.TestWriterCancelPreservesOutput;
var
  Output, Temporary, Error: string;
  Writer: TMovieWriter;
begin
  OpenDirectory;
  try
    Output := FDirectory + 'take.mp4';
    WriteFile(Output, 'previous take');
    Writer := TMovieWriter.Create(Output, ocMPEG4, 64, 64, 30, 1000000);
    try
      Expect<Boolean>(Writer.Open(Error)).ToBe(True);
      Temporary := Writer.TemporaryPath;
      Expect<Boolean>(Temporary <> Output).ToBe(True);
      Expect<string>(ReadFile(Output)).ToBe('previous take');
      Writer.Cancel;
      Expect<string>(ReadFile(Output)).ToBe('previous take');
    finally
      Writer.Free;
    end;
    Expect<string>(ReadFile(Output)).ToBe('previous take');
    Expect<Boolean>(FileExists(RenderTemporaryOwnerPathFor(Temporary))).ToBe(False);
  finally
    CloseDirectory;
  end;
end;

procedure TAtomicTests.TestWriterWithoutFramesPreservesOutput;
var
  Output, Temporary, Error: string;
  Writer: TMovieWriter;
begin
  OpenDirectory;
  try
    Output := FDirectory + 'take.mp4';
    WriteFile(Output, 'previous take');
    Writer := TMovieWriter.Create(Output, ocMPEG4, 64, 64, 30, 1000000);
    try
      Expect<Boolean>(Writer.Open(Error)).ToBe(True);
      Temporary := Writer.TemporaryPath;
      Expect<Boolean>(Writer.Finish(Error)).ToBe(False);
      Expect<string>(Error).ToBe('no frames were captured');
      Expect<string>(ReadFile(Output)).ToBe('previous take');
    finally
      Writer.Free;
    end;
    Expect<string>(ReadFile(Output)).ToBe('previous take');
    Expect<Boolean>(FileExists(RenderTemporaryOwnerPathFor(Temporary))).ToBe(False);
  finally
    CloseDirectory;
  end;
end;

{$ELSE}

procedure TPortableTests.SetupTests;
begin
  Test('unique temporary names remain recognizable to recovery',
    TestUniqueTemporaryRetainsRecoverySuffix);
end;

procedure TPortableTests.TestUniqueTemporaryRetainsRecoverySuffix;
var
  Name: string;
begin
  Expect<Boolean>(ClassifyRenderTemporary('unique-take.mp4'
    + RenderTemporarySuffix, Name) = rtkTemporary).ToBe(True);
  Expect<Boolean>(ClassifyRenderTemporary('take.mp4', Name)
    = rtkNotOurs).ToBe(True);
end;

{$ENDIF}

{$IFDEF DARWIN}
var
  Pool: NSAutoreleasePool;
{$ENDIF}

begin
  {$IFDEF DARWIN}
  IsMultiThread := True;
  Pool := NSAutoreleasePool.alloc.init;
  try
    TestRunnerProgram.AddSuite(TAtomicTests.Create('atomic output ownership'));
    TestRunnerProgram.Run;
    ExitCode := TestResultToExitCode;
  finally
    Pool.release;
  end;
  {$ELSE}
  TestRunnerProgram.AddSuite(TPortableTests.Create('atomic output naming'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
  {$ENDIF}
end.

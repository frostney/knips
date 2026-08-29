program Knips.Recording.Recovery.Test;

// The two parts of the recovery pass that are answerable without a
// recording: the sweep that removes what a killed *render* left behind,
// and the pid test that decides whether an unfinished take belongs to a
// process that is still running.
//
// **Why this suite is Darwin-only when nothing in it is about
// ScreenCaptureKit.** Knips.Recording.Recovery compiles to nothing off
// Darwin — its whole interface is inside `{$IFDEF DARWIN}`, because the
// re-mux it exists to perform is AVAssetExportSession. The two functions
// tested here are ordinary filesystem and POSIX work and would run
// anywhere; they are simply not reachable from a Linux build. So the
// suite has a Darwin body and an off-Darwin one that says so, rather
// than being absent from the Linux run and leaving a hole nobody can
// see. (See AGENTS.md, "Testing": Darwin units are gated by `knips
// probe` and a real recording, and this is the sliver of one that a
// unit test can still reach on the machine that has it.)
//
// Nothing here records, and nothing here touches ~/Movies: every test
// works in a directory of its own under the system temporary one and
// removes it again.

{$I Knips.inc}

uses
  SysUtils,

  {$IFDEF DARWIN}
  BaseUnix,
  Knips.Options,
  Knips.Recording.Recovery,
  {$ENDIF}
  TestingPascalLibrary;

type
  {$IFDEF DARWIN}
  TSweepTests = class(TTestSuite)
  private
    FDirectory: string;
    procedure MakeFile(const AName: string);
    function Exists(const AName: string): Boolean;
    procedure OpenDirectory;
    procedure CloseDirectory;
  public
    procedure SetupTests; override;
    procedure TestRemovesTemporariesAndCountsThem;
    procedure TestLeavesRealTakesAlone;
    procedure TestSandboxShadowFilesGoToo;
    procedure TestAnAbsentDirectoryIsNotAnError;
  end;

  TProcessTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestThisProcessIsAlive;
    procedure TestAnAbsentPidIsNotAlive;
    procedure TestPidZeroAndBelowAreTreatedAsAlive;
  end;
  {$ELSE}
  TUnsupportedTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRecoveryIsDarwinOnly;
  end;
  {$ENDIF}

{$IFDEF DARWIN}

{ TSweepTests }

procedure TSweepTests.SetupTests;
begin
  Test('every render scratch file goes, and the count is returned',
    TestRemovesTemporariesAndCountsThem);
  Test('a take, its sidecar and its deliverable are left alone',
    TestLeavesRealTakesAlone);
  Test('the sandbox shadow file beside a temporary goes with it',
    TestSandboxShadowFilesGoToo);
  Test('a directory that is not there is not an error',
    TestAnAbsentDirectoryIsNotAnError);
end;

procedure TSweepTests.OpenDirectory;
begin
  FDirectory := IncludeTrailingPathDelimiter(GetTempDir)
    + 'knips-recovery-test-' + IntToStr(FpGetPid) + '-'
    + IntToStr(Random(1000000)) + PathDelim;
  ForceDirectories(FDirectory);
end;

procedure TSweepTests.CloseDirectory;
var
  Search: TSearchRec;
begin
  if FDirectory = '' then
    Exit;
  if FindFirst(FDirectory + '*', faAnyFile, Search) = 0 then
    try
      repeat
        if (Search.Attr and faDirectory) = 0 then
          DeleteFile(FDirectory + Search.Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
  RemoveDir(FDirectory);
  FDirectory := '';
end;

procedure TSweepTests.MakeFile(const AName: string);
var
  Handle: THandle;
begin
  Handle := FileCreate(FDirectory + AName);
  if Handle <> THandle(-1) then
  begin
    FileWrite(Handle, AName[1], Length(AName));
    FileClose(Handle);
  end;
end;

function TSweepTests.Exists(const AName: string): Boolean;
begin
  Result := FileExists(FDirectory + AName);
end;

procedure TSweepTests.TestRemovesTemporariesAndCountsThem;
begin
  OpenDirectory;
  try
    MakeFile('one.mp4' + RenderTemporarySuffix);
    MakeFile('two.mp4' + RenderTemporarySuffix);
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(2);
    Expect<Boolean>(Exists('one.mp4' + RenderTemporarySuffix)).ToBe(False);
    Expect<Boolean>(Exists('two.mp4' + RenderTemporarySuffix)).ToBe(False);
    // And a second pass over the same directory finds nothing, which is
    // the state every ordinary start is in.
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(0);
  finally
    CloseDirectory;
  end;
end;

procedure TSweepTests.TestLeavesRealTakesAlone;
begin
  OpenDirectory;
  try
    MakeFile('take-raw.mp4');
    MakeFile('take-raw.knips.jsonl');
    MakeFile('take.mp4');
    MakeFile('take.knips.jsonl');
    MakeFile('take.mp4' + RenderTemporarySuffix);
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(1);
    // The four that matter. A sweep that took a raw take with it would
    // destroy the one file that makes a render repeatable, which is the
    // whole reason the directory keeps it.
    Expect<Boolean>(Exists('take-raw.mp4')).ToBe(True);
    Expect<Boolean>(Exists('take-raw.knips.jsonl')).ToBe(True);
    Expect<Boolean>(Exists('take.mp4')).ToBe(True);
    Expect<Boolean>(Exists('take.knips.jsonl')).ToBe(True);
  finally
    CloseDirectory;
  end;
end;

procedure TSweepTests.TestSandboxShadowFilesGoToo;
begin
  OpenDirectory;
  try
    // AVAssetWriter under the sandbox writes `<output>.sb-<token>`
    // beside its output, so a killed render leaves two files and the
    // pattern has to have a trailing wildcard as well as a leading one.
    MakeFile('x.mp4' + RenderTemporarySuffix);
    MakeFile('x.mp4' + RenderTemporarySuffix + '.sb-1a2b3c');
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(2);
    Expect<Boolean>(Exists('x.mp4' + RenderTemporarySuffix
      + '.sb-1a2b3c')).ToBe(False);
  finally
    CloseDirectory;
  end;
end;

procedure TSweepTests.TestAnAbsentDirectoryIsNotAnError;
begin
  Expect<Integer>(SweepRenderTemporaries('')).ToBe(0);
  Expect<Integer>(SweepRenderTemporaries(
    IncludeTrailingPathDelimiter(GetTempDir)
    + 'knips-no-such-directory-at-all')).ToBe(0);
end;

{ TProcessTests }

procedure TProcessTests.SetupTests;
begin
  Test('the process asking is alive', TestThisProcessIsAlive);
  Test('a pid nothing owns is not', TestAnAbsentPidIsNotAlive);
  Test('a pid the header did not carry is treated as alive',
    TestPidZeroAndBelowAreTreatedAsAlive);
end;

procedure TProcessTests.TestThisProcessIsAlive;
begin
  Expect<Boolean>(ProcessIsAlive(FpGetPid)).ToBe(True);
  // The parent too, which is a process this one may not signal — EPERM
  // rather than success, and the answer has to be "alive" all the same.
  // That arm is the one worth having: reading EPERM as "gone" would let
  // recovery re-mux a movie another user's recorder is still writing.
  Expect<Boolean>(ProcessIsAlive(FpGetPPid)).ToBe(True);
end;

procedure TProcessTests.TestAnAbsentPidIsNotAlive;
var
  Candidate: Integer;
begin
  // Walk down from a high pid until one is genuinely unused, so the test
  // does not depend on a particular number being free. Anything the
  // kernel hands out is below this on macOS.
  Candidate := 99999;
  while (Candidate > 90000) and ProcessIsAlive(Candidate) do
    Dec(Candidate);
  Expect<Boolean>(Candidate > 90000).ToBe(True);
  Expect<Boolean>(ProcessIsAlive(Candidate)).ToBe(False);
end;

procedure TProcessTests.TestPidZeroAndBelowAreTreatedAsAlive;
begin
  // No pid in the header — an older sidecar, or one written by something
  // else. The conservative direction is the only safe one: a take that
  // might belong to a running recorder is left alone.
  Expect<Boolean>(ProcessIsAlive(0)).ToBe(True);
  Expect<Boolean>(ProcessIsAlive(-1)).ToBe(True);
end;

{$ELSE}

{ TUnsupportedTests }

procedure TUnsupportedTests.SetupTests;
begin
  Test('the recovery pass is not built on this host',
    TestRecoveryIsDarwinOnly);
end;

procedure TUnsupportedTests.TestRecoveryIsDarwinOnly;
begin
  // Knips.Recording.Recovery has no interface off Darwin: the re-mux it
  // exists to perform is AVAssetExportSession. The suite says so out
  // loud rather than being absent, so a Linux run's suite count matches
  // a macOS run's and nobody has to work out which one is missing.
  Expect<Boolean>(True).ToBe(True);
end;

{$ENDIF}

begin
  {$IFDEF DARWIN}
  Randomize;
  TestRunnerProgram.AddSuite(TSweepTests.Create(
    'sweeping up after a killed render'));
  TestRunnerProgram.AddSuite(TProcessTests.Create(
    'is the process that wrote this sidecar still there?'));
  {$ELSE}
  TestRunnerProgram.AddSuite(TUnsupportedTests.Create(
    'the recovery pass, which this host does not build'));
  {$ENDIF}
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

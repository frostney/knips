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

  Knips.Options,
  {$IFDEF DARWIN}
  BaseUnix,
  Knips.Recording.Recovery,
  Knips.Recording.Sidecar,
  {$ENDIF}
  TestingPascalLibrary;

type
  {$IFDEF DARWIN}
  TSweepTests = class(TTestSuite)
  private
    FDirectory: string;
    procedure MakeFile(const AName: string);
    // A temporary nobody owns any more: the file plus an owner marker
    // naming a pid that is gone. That is what the sweep is FOR, and
    // since the pid gate landed it is also the only shape it removes on
    // sight — a bare temporary with no marker is inside its grace
    // period and is somebody's live render until proved otherwise.
    procedure MakeAbandonedTemporary(const AName: string);
    function Exists(const AName: string): Boolean;
    procedure OpenDirectory;
    procedure CloseDirectory;
  public
    procedure SetupTests; override;
    procedure TestRemovesTemporariesAndCountsThem;
    procedure TestLeavesRealTakesAlone;
    procedure TestSandboxShadowFilesGoToo;
    procedure TestALiveRendersTemporaryIsLeftAlone;
    procedure TestAnUnmarkedTemporaryIsLeftAlone;
    procedure TestAnUnmarkedTemporaryPastTheGraceIsSwept;
    procedure TestAFileThatMerelyContainsTheSuffixIsLeftAlone;
    procedure TestAnAbsentDirectoryIsNotAnError;
    procedure TestBackslashNamesAreNotConfusedWithNeighbours;
  end;

  TProcessTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestThisProcessIsAlive;
    procedure TestAnAbsentPidIsNotAlive;
    procedure TestPidZeroAndBelowAreTreatedAsAlive;
  end;

  // What the pass is allowed to reach. A sidecar is a file in a
  // directory knips scans without being asked, and the movie it names is
  // the file the pass REPLACES with a re-mux — so the name has to be
  // the bare one the format promises, and the path it makes has to be a
  // real file rather than a link to somebody else's.
  TMovieNameTests = class(TTestSuite)
  private
    FParent: string;
    FChild: string;
    procedure OpenDirectories;
    procedure CloseDirectories;
    procedure RemoveEverythingIn(const ADirectory: string);
    // A take that is unfinished in every way the pass looks at: a header
    // naming AMovieName and a pid that is gone, an anchor below the host
    // clock, and no trailer. Everything except the name is exactly what
    // a crashed recording leaves.
    procedure PlantSidecar(const APath, AMovieName: string);
    procedure MakeFile(const APath: string);
  public
    procedure SetupTests; override;
    procedure TestASidecarNamingAPathOutsideTheDirectoryIsIgnored;
    procedure TestASidecarNamingASymlinkIsIgnored;
  end;
  {$ELSE}
  TUnsupportedTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTheSweepsNamingRulesAreStillNeutral;
  end;
  {$ENDIF}

{$IFDEF DARWIN}

// Walk down from a high pid until one is genuinely unused, so nothing
// here depends on a particular number being free. Anything the kernel
// hands out on macOS is below this.
function DeadPid: Integer;
begin
  Result := 99999;
  while (Result > 90000) and ProcessIsAlive(Result) do
    Dec(Result);
end;

{ TSweepTests }

procedure TSweepTests.SetupTests;
begin
  Test('every render scratch file goes, and the count is returned',
    TestRemovesTemporariesAndCountsThem);
  Test('a take, its sidecar and its deliverable are left alone',
    TestLeavesRealTakesAlone);
  Test('the sandbox shadow file beside a temporary goes with it',
    TestSandboxShadowFilesGoToo);
  Test('a temporary whose owning render is still running survives',
    TestALiveRendersTemporaryIsLeftAlone);
  Test('a temporary with no owner marker is inside its grace period',
    TestAnUnmarkedTemporaryIsLeftAlone);
  Test('an unmarked temporary older than the grace period is swept',
    TestAnUnmarkedTemporaryPastTheGraceIsSwept);
  Test('an ordinary file that merely contains the suffix is not ours',
    TestAFileThatMerelyContainsTheSuffixIsLeftAlone);
  Test('literal backslash scratch is distinct from a live neighbour',
    TestBackslashNamesAreNotConfusedWithNeighbours);
  Test('a directory that is not there is not an error',
    TestAnAbsentDirectoryIsNotAnError);
end;

procedure TSweepTests.TestBackslashNamesAreNotConfusedWithNeighbours;
const
  Pending = 'literal\take.mp4' + RenderTemporarySuffix;
  Neighbour = 'take.mp4' + RenderTemporarySuffix;
begin
  OpenDirectory;
  try
    MakeAbandonedTemporary(Pending);
    MakeFile(Neighbour);
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(1);
    Expect<Boolean>(Exists(Pending)).ToBe(False);
    Expect<Boolean>(Exists(RenderTemporaryOwnerPathFor(Pending))).ToBe(False);
    Expect<Boolean>(Exists(Neighbour)).ToBe(True);
  finally
    DeleteFile(FDirectory + Pending);
    DeleteFile(FDirectory + RenderTemporaryOwnerPathFor(Pending));
    CloseDirectory;
  end;
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

procedure TSweepTests.MakeAbandonedTemporary(const AName: string);
var
  Marker: TextFile;
begin
  MakeFile(AName);
  AssignFile(Marker, FDirectory + RenderTemporaryOwnerPathFor(AName));
  Rewrite(Marker);
  try
    WriteLn(Marker, DeadPid);
  finally
    CloseFile(Marker);
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
    MakeAbandonedTemporary('one.mp4' + RenderTemporarySuffix);
    MakeAbandonedTemporary('two.mp4' + RenderTemporarySuffix);
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(2);
    Expect<Boolean>(Exists('one.mp4' + RenderTemporarySuffix)).ToBe(False);
    Expect<Boolean>(Exists('two.mp4' + RenderTemporarySuffix)).ToBe(False);
    // The owner markers go with the temporaries they named, or the next
    // pass would find a directory of markers naming nothing.
    Expect<Boolean>(Exists(RenderTemporaryOwnerPathFor('one.mp4'
      + RenderTemporarySuffix))).ToBe(False);
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
    MakeAbandonedTemporary('take.mp4' + RenderTemporarySuffix);
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
    MakeAbandonedTemporary('x.mp4' + RenderTemporarySuffix);
    MakeFile('x.mp4' + RenderTemporarySuffix + '.sb-1a2b3c');
    // One, not two: the count is temporaries removed, not files. A
    // caller told "2 leftover render scratch file(s) removed" about one
    // dead render is being told a number that means nothing.
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(1);
    Expect<Boolean>(Exists('x.mp4' + RenderTemporarySuffix
      + '.sb-1a2b3c')).ToBe(False);
    Expect<Boolean>(Exists('x.mp4' + RenderTemporarySuffix)).ToBe(False);
  finally
    CloseDirectory;
  end;
end;

procedure TSweepTests.TestALiveRendersTemporaryIsLeftAlone;
var
  Marker: TextFile;
begin
  OpenDirectory;
  try
    // The reproducer that made the pid gate necessary: the sweep runs at
    // every `knips record` and every app launch, and it used to delete
    // whatever matched — including the temporary a render running in
    // another process was at that moment writing into.
    MakeFile('live.mp4' + RenderTemporarySuffix);
    MakeFile('live.mp4' + RenderTemporarySuffix + '.sb-9f9f9f');
    AssignFile(Marker, FDirectory
      + RenderTemporaryOwnerPathFor('live.mp4' + RenderTemporarySuffix));
    Rewrite(Marker);
    try
      WriteLn(Marker, FpGetPid);
    finally
      CloseFile(Marker);
    end;
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(0);
    Expect<Boolean>(Exists('live.mp4' + RenderTemporarySuffix)).ToBe(True);
    // The whole family survives together, marker and shadow included: a
    // live render that lost its scratch is a render that fails at the
    // rename.
    Expect<Boolean>(Exists('live.mp4' + RenderTemporarySuffix
      + '.sb-9f9f9f')).ToBe(True);
    Expect<Boolean>(Exists(RenderTemporaryOwnerPathFor('live.mp4'
      + RenderTemporarySuffix))).ToBe(True);
  finally
    CloseDirectory;
  end;
end;

procedure TSweepTests.TestAnUnmarkedTemporaryIsLeftAlone;
begin
  OpenDirectory;
  try
    // No marker at all — a render from a build before markers existed,
    // or one whose marker could not be written. Judged by age instead,
    // and one made a moment ago is inside the grace period.
    MakeFile('unmarked.mp4' + RenderTemporarySuffix);
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(0);
    Expect<Boolean>(Exists('unmarked.mp4'
      + RenderTemporarySuffix)).ToBe(True);
  finally
    CloseDirectory;
  end;
end;

procedure TSweepTests.TestAnUnmarkedTemporaryPastTheGraceIsSwept;
var
  Path: string;
begin
  OpenDirectory;
  try
    // The other half of the age rule, and the half nothing exercised:
    // an unmarked temporary is judged by its modification time, and one
    // older than TemporaryGraceMinutes is scratch nobody is writing
    // into. Without this the grace period could be any length at all —
    // including forever — and the suite would still be green.
    //
    // Backdated rather than waited for. FileSetDate is the only way to
    // reach the branch in a test that has to finish, and an hour is far
    // enough past the ten-minute grace to survive a slow machine and a
    // clock that is not quite the filesystem's.
    MakeFile('stale.mp4' + RenderTemporarySuffix);
    Path := FDirectory + 'stale.mp4' + RenderTemporarySuffix;
    Expect<Integer>(FileSetDate(Path, DateTimeToFileDate(Now - 1 / 24)))
      .ToBe(0);
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(1);
    Expect<Boolean>(Exists('stale.mp4'
      + RenderTemporarySuffix)).ToBe(False);
  finally
    CloseDirectory;
  end;
end;

procedure TSweepTests.TestAFileThatMerelyContainsTheSuffixIsLeftAlone;
begin
  OpenDirectory;
  try
    // The file that was actually destroyed by the old `*<suffix>*`
    // pattern. Three shapes are ours and a fourth is somebody's notes.
    MakeFile('notes' + RenderTemporarySuffix + '.txt');
    MakeFile(RenderTemporarySuffix);
    Expect<Integer>(SweepRenderTemporaries(FDirectory)).ToBe(0);
    Expect<Boolean>(Exists('notes' + RenderTemporarySuffix
      + '.txt')).ToBe(True);
    // A name that is nothing BUT the suffix has no deliverable in front
    // of it, so it names no render either.
    Expect<Boolean>(Exists(RenderTemporarySuffix)).ToBe(True);
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
  // The parent too. It is usually the same uid, so the kernel answers
  // success and the EPERM arm is not what runs here — a shell's child
  // may signal its shell. The arm is still the one worth having, and
  // this assertion is not what proves it: reading EPERM as "gone" would
  // let recovery re-mux a movie another USER's recorder is still
  // writing, and no test on this machine can produce that answer
  // without a second account.
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

{ TMovieNameTests }

procedure TMovieNameTests.SetupTests;
begin
  Test('a `movie` that climbs out of the directory is never touched',
    TestASidecarNamingAPathOutsideTheDirectoryIsIgnored);
  Test('a `movie` that is a symbolic link is never written through',
    TestASidecarNamingASymlinkIsIgnored);
end;

procedure TMovieNameTests.OpenDirectories;
begin
  FParent := IncludeTrailingPathDelimiter(GetTempDir)
    + 'knips-recovery-name-' + IntToStr(FpGetPid) + '-'
    + IntToStr(Random(1000000)) + PathDelim;
  FChild := FParent + 'takes' + PathDelim;
  ForceDirectories(FChild);
end;

procedure TMovieNameTests.RemoveEverythingIn(const ADirectory: string);
var
  Search: TSearchRec;
begin
  if FindFirst(ADirectory + '*', faAnyFile, Search) = 0 then
    try
      repeat
        if (Search.Attr and faDirectory) = 0 then
          DeleteFile(ADirectory + Search.Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
  RemoveDir(ADirectory);
end;

procedure TMovieNameTests.CloseDirectories;
begin
  if FParent = '' then
    Exit;
  RemoveEverythingIn(FChild);
  RemoveEverythingIn(FParent);
  FParent := '';
  FChild := '';
end;

procedure TMovieNameTests.MakeFile(const APath: string);
var
  Handle: THandle;
  Payload: string;
begin
  Payload := 'not a movie, but a file somebody would miss';
  Handle := FileCreate(APath);
  if Handle <> THandle(-1) then
  begin
    FileWrite(Handle, Payload[1], Length(Payload));
    FileClose(Handle);
  end;
end;

procedure TMovieNameTests.PlantSidecar(const APath, AMovieName: string);
var
  Writer: TSidecarWriter;
  Header: TSidecarHeader;
begin
  Header := Default(TSidecarHeader);
  Header.Version := SidecarFormatVersion;
  Header.KnipsVersion := 'planted';
  Header.MovieName := AMovieName;
  Header.CreatedUtc := '2026-09-08T00:00:00Z';
  Header.ProcessID := DeadPid;
  Header.TargetKind := ctkDisplay;
  Header.PixelWidth := 640;
  Header.PixelHeight := 360;
  Header.Scale := 1;
  Header.FramesPerSecond := 30;
  Header.SampleHz := 30;
  Header.BaseWidth := 640;
  Header.BaseHeight := 360;
  Writer := TSidecarWriter.Create(APath);
  try
    Writer.WriteHeader(Header);
    // One second on the host clock: always below a running machine's
    // reading, so the "written before the last reboot" refusal is not
    // what this take is stopped by. No trailer, which is what makes it
    // an unfinished take.
    Writer.WriteAnchor(1.0);
  finally
    Writer.Free;
  end;
end;

procedure TMovieNameTests.TestASidecarNamingAPathOutsideTheDirectoryIsIgnored;
var
  Takes: TRecoveredTakes;
  Swept: Integer;
  Victim, Sidecar: string;
  SizeBefore, SidecarBefore: Int64;
begin
  OpenDirectories;
  try
    // The reproduction. `movie` is documented as a file name and was
    // joined to the sidecar's directory unchecked, so a sidecar planted
    // in a recording directory could name a movie in ANOTHER one — and
    // the pass re-muxed over it, replacing the file (measured: the
    // victim's inode changed) and appending a recovered trailer to the
    // planted sidecar.
    Victim := FParent + 'victim.mp4';
    MakeFile(Victim);
    Sidecar := FChild + 'take' + SidecarExtension;
    PlantSidecar(Sidecar, '..' + PathDelim + 'victim.mp4');
    SizeBefore := FileSizeOf(Victim);
    SidecarBefore := FileSizeOf(Sidecar);

    Expect<Integer>(RecoverOrphanedTakes(FChild, Takes, Swept)).ToBe(0);
    Expect<Integer>(Length(Takes)).ToBe(0);
    // The file in the other directory is the one that was there. The
    // count above is what actually proves it: without the guard the pass
    // reports the planted take, and a re-mux would replace the file.
    Expect<Boolean>(FileExists(Victim)).ToBe(True);
    Expect<Int64>(FileSizeOf(Victim)).ToBe(SizeBefore);
    // And nothing was written back into the sidecar either. A take this
    // pass refuses to act on must not be closed off, or one planted
    // file would permanently disable recovery for the name it carries.
    Expect<Int64>(FileSizeOf(Sidecar)).ToBe(SidecarBefore);
  finally
    CloseDirectories;
  end;
end;

procedure TMovieNameTests.TestASidecarNamingASymlinkIsIgnored;
var
  Takes: TRecoveredTakes;
  Swept: Integer;
  Target, Link, Sidecar: string;
  SizeBefore, SidecarBefore: Int64;
begin
  OpenDirectories;
  try
    // A bare name, so the rule above lets it through — and a symbolic
    // link, which the re-mux would rename over, silently replacing the
    // link with a movie. Every other writer in knips refuses a link at
    // a path it writes (Knips.Export.Atomic.OutputPathRefusal); this
    // pass is a writer too and had no such refusal.
    Target := FParent + 'elsewhere.mp4';
    MakeFile(Target);
    Link := FChild + 'take.mp4';
    Expect<Integer>(FpSymlink(PAnsiChar(Target), PAnsiChar(Link))).ToBe(0);
    Sidecar := FChild + 'take' + SidecarExtension;
    PlantSidecar(Sidecar, 'take.mp4');
    SizeBefore := FileSizeOf(Target);
    SidecarBefore := FileSizeOf(Sidecar);

    Expect<Integer>(RecoverOrphanedTakes(FChild, Takes, Swept)).ToBe(0);
    Expect<Int64>(FileSizeOf(Target)).ToBe(SizeBefore);
    Expect<Int64>(FileSizeOf(Sidecar)).ToBe(SidecarBefore);
    // The link itself is still a link: refused by name, never followed
    // and never replaced.
    Expect<Boolean>(FpReadLink(Link) = Target).ToBe(True);
  finally
    CloseDirectories;
  end;
end;

{$ELSE}

{ TUnsupportedTests }

procedure TUnsupportedTests.SetupTests;
begin
  Test('the sweep''s naming rules are neutral and still hold here',
    TestTheSweepsNamingRulesAreStillNeutral);
end;

procedure TUnsupportedTests.TestTheSweepsNamingRulesAreStillNeutral;
var
  Name: string;
begin
  // Knips.Recording.Recovery has no interface off Darwin: the re-mux it
  // exists to perform is AVAssetExportSession. The suite says so out
  // loud rather than being absent, so a Linux run's suite count matches
  // a macOS run's and nobody has to work out which one is missing.
  //
  // It used to say it with `Expect(True).ToBe(True)`, which is a test
  // that cannot fail. There IS something here worth asserting on every
  // host: the naming rules the sweep turns on live in Knips.Options and
  // are neutral, so a Linux run can still pin the one decision that
  // stops the pass deleting somebody's file.
  Expect<Boolean>(ClassifyRenderTemporary('demo.mp4'
    + RenderTemporarySuffix, Name) = rtkTemporary).ToBe(True);
  Expect<Boolean>(ClassifyRenderTemporary('notes'
    + RenderTemporarySuffix + '.txt', Name) = rtkNotOurs).ToBe(True);
end;

{$ENDIF}

begin
  {$IFDEF DARWIN}
  Randomize;
  TestRunnerProgram.AddSuite(TSweepTests.Create(
    'sweeping up after a killed render'));
  TestRunnerProgram.AddSuite(TProcessTests.Create(
    'is the process that wrote this sidecar still there?'));
  TestRunnerProgram.AddSuite(TMovieNameTests.Create(
    'which movie a sidecar is allowed to name'));
  {$ELSE}
  TestRunnerProgram.AddSuite(TUnsupportedTests.Create(
    'the recovery pass, which this host does not build'));
  {$ENDIF}
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.

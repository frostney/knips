unit Knips.Recording.Recovery;

// Never lose a take: what happens to a recording whose process died.
//
// **The half that is not here.** Most of the answer lives in
// Knips.Export.MovieWriter, which sets AVAssetWriter's
// movieFragmentInterval so the movie is flushed to disk every two seconds
// instead of being held for one moov atom at the end. Before that, a
// kill -9 left a file of zero bytes; after it, the same kill leaves a
// playable movie ending at the last flushed fragment (measured: 483 kB,
// 117 frames, 4.0 s from a six-second take). The most a crash can now cost
// is the fragment in flight.
//
// **What is here** is the tidying up, at the next start. A recording that
// ended properly wrote a trailer into its event sidecar
// (Knips.Recording.Sidecar); one that did not, did not. So an orphaned
// take is a `*.knips.jsonl` with a header, an anchor and no trailer — no
// extra marker file, no lock, nothing to leave behind in its own turn.
//
// Three things then have to be true before anything is touched:
//
//   1. the sidecar names a movie that exists, is not empty, is inside
//      this directory rather than reachable from it — the name is a bare
//      file name by the format's own rule, enforced here because the
//      file it lands on is the one this pass replaces — and is not a
//      symbolic link;
//   2. its process is gone. A sidecar with no trailer is also exactly
//      what a recording *in progress* looks like, and the pid in the
//      header is what tells the two apart. `kill(pid, 0)` is the test —
//      it sends nothing and only asks whether the process is there;
//   3. the movie opens. A fragment-less stub from a crash before the
//      first flush is not recoverable and is left alone rather than
//      renamed or deleted.
//
// **Finishing it off** is a passthrough re-mux (Knips.Export.MovieTrim,
// which is AVAssetExportSession at the passthrough preset): the same coded
// samples, copied into an ordinary non-fragmented container with a proper
// index. Nothing is decoded and nothing is re-encoded, so the recovered
// file is bit-for-bit the frames the recorder captured. The re-muxed file
// replaces the original, and the sidecar gets its trailer with
// `"recovered":true` so the take is never picked up twice.
//
// A re-mux that fails is not a failure of recovery: the fragmented file
// plays perfectly well, and the caller is told which of the two it has.
//
// Nothing here ever deletes a movie. The worst case is a take that is
// reported and left exactly as it was found.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  BaseUnix,
  Classes,
  DateUtils,
  SysUtils,

  Knips.Capture.CoreMedia,
  Knips.Export.Atomic,
  Knips.Export.MovieReader,
  Knips.Export.MovieTrim,
  Knips.ObjC.Runtime,
  Knips.Options,
  Knips.Recording.Sidecar;

type
  TRecoveredTake = record
    MoviePath: string;
    SidecarPath: string;
    DurationSeconds: Double;
    Bytes: Int64;
    // True when the passthrough re-mux ran and replaced the file. False
    // means the movie was left as the fragmented file the crash produced
    // — still playable, and Note says why it was not re-muxed.
    Remuxed: Boolean;
    Note: string;
  end;

  TRecoveredTakes = array of TRecoveredTake;

// Every unfinished take in ADirectory, recovered. Returns how many were
// found and dealt with; ATakes carries one entry each. Never raises: a
// directory that cannot be read, a sidecar that cannot be parsed and a
// movie that cannot be opened are all "nothing to recover here".
//
// Safe to call when nothing is wrong, which is the usual case — it is one
// directory listing and, for each unfinished sidecar, one parse.
// ASweptTemporaries answers how many scratch files a killed render left
// behind and this pass removed — a number that used to be computed and
// thrown away at the one production call. It is worth a line: a
// directory that keeps producing them is a render that keeps dying, and
// nothing else in knips would ever say so.
function RecoverOrphanedTakes(const ADirectory: string;
  out ATakes: TRecoveredTakes;
  out ASweptTemporaries: Integer): Integer;

// One line per recovered take, for a console or a log. '' when nothing
// was recovered.
function DescribeRecoveredTakes(const ATakes: TRecoveredTakes): string;

// Removes the scratch files a killed render left in ADirectory, and
// answers how many temporaries were removed. The render pass renames
// its temporary into place as its last act (Knips.Export.Render), so
// one still sitting there is one that died and nothing will ever finish
// it — UNLESS it is still being written, which is the whole reason this
// is not a delete of everything that matches.
//
// Two gates, both of which used to be missing:
//
//   1. the NAME has to be one of the three shapes a temporary's family
//      takes (Knips.Options.ClassifyRenderTemporary). The old pattern
//      was `*<suffix>*` and deleted an ordinary user file called
//      `notes.knips-render-tmp.txt`;
//   2. the OWNER has to be gone — the marker's pid, tested exactly as
//      an unfinished sidecar's is, or failing that the temporary's own
//      age. The old sweep ran unconditionally at every `record` and
//      every app launch, and deleted a live render's temporary out from
//      under it.
//
// Exposed so it can be asked for and tested on its own;
// RecoverOrphanedTakes runs it first.
function SweepRenderTemporaries(const ADirectory: string): Integer;

// Whether a process with this pid exists — `kill(pid, 0)`, which sends
// no signal and only asks. True for a pid of zero or below: a sidecar
// with no pid in its header is treated as still being written, which is
// the conservative direction.
//
// Exposed because it is the single decision the whole recovery contract
// turns on, and its limits are documented for third-party tools
// (docs/event-sidecar.md, *Recovery*; docs/architecture.md, "Never lose
// a take"). A rule anybody else is invited to implement is a rule worth
// having tested here rather than only exercised through a re-mux.
function ProcessIsAlive(APid: Integer): Boolean;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // How old a temporary with no owner marker has to be before it counts
  // as abandoned. Long enough that no render in progress is ever inside
  // it — the two-minute FinishTimeoutSlices bound in
  // Knips.Export.Render is the longest a render can legitimately sit
  // still — and short enough that a directory does not carry scratch
  // around for a session.
  TemporaryGraceMinutes = 10;

// kill(pid, 0) sends no signal; it asks whether the process exists and
// whether this user could signal it. ESRCH means gone, which is the only
// answer that lets a take be touched. EPERM means it is there and belongs
// to somebody else, which is emphatically not a take to finish off.
function ProcessIsAlive(APid: Integer): Boolean;
begin
  if APid <= 0 then
    // No pid in the header: an older sidecar, or one this version did not
    // write. Treated as alive, which is the conservative direction — the
    // take is left alone rather than re-muxed under a running recorder.
    Exit(True);
  if FpKill(APid, 0) = 0 then
    Exit(True);
  Result := fpgeterrno <> ESysESRCH;
end;

// The scratch name a re-mux writes into. Beside the original rather than
// in the temporary directory so the replace is a rename within one
// volume: a cross-device copy of a gigabyte, half way through, is exactly
// the failure this unit exists to avoid.
function RecoveringPathFor(const AMoviePath: string): string;
begin
  Result := ChangeFileExt(AMoviePath, '.recovering'
    + ExtractFileExt(AMoviePath));
end;

// The passthrough re-mux, into a neighbour file and then over the top.
function RemuxInPlace(const AMoviePath: string; ADurationSeconds: Double;
  out AError: string): Boolean;
var
  Options: TExportOptions;
  Session: TMovieTrimSession;
  Temporary: string;
begin
  Result := False;
  AError := '';
  Temporary := RecoveringPathFor(AMoviePath);
  // A previous recovery that itself died leaves one of these behind. It
  // is ours by construction — nothing else in the program writes that
  // name — and it is a partial copy of a movie that still exists, so it
  // is removed rather than kept.
  DeleteFile(Temporary);
  Options := DefaultExportOptions;
  Options.InputPath := AMoviePath;
  Options.OutputPath := Temporary;
  Options.HasTrim := True;
  Options.TrimStartSeconds := 0;
  Options.HasTrimEnd := True;
  // A hair past the end: the range is clamped to the asset, and asking
  // for exactly the duration leaves the last sample's inclusion up to a
  // rounding this code cannot see.
  Options.TrimEndSeconds := ADurationSeconds + 1;
  if not ValidateExportOptions(Options, AError) then
    Exit;
  Session := TMovieTrimSession.Create(Options);
  try
    if not Session.Run(AError) then
    begin
      DeleteFile(Temporary);
      Exit;
    end;
  finally
    Session.Free;
  end;
  // RenameFile over an existing path is rename(2), which is atomic within
  // a volume: at no instant is there no movie at AMoviePath.
  if not RenameFile(Temporary, AMoviePath) then
  begin
    AError := 'could not replace ' + AMoviePath;
    DeleteFile(Temporary);
    Exit;
  end;
  Result := True;
end;

// Closes the sidecar off so this take is never picked up again. The
// numbers are the recovered movie's own, read back from the file: the
// recorder's counters died with it.
procedure CloseSidecar(const ASidecarPath: string; const ALog: TSidecarLog;
  ADurationSeconds: Double);
var
  Writer: TSidecarWriter;
  Trailer: TSidecarTrailer;
begin
  Writer := TSidecarWriter.Create(ASidecarPath, True);
  try
    Trailer := Default(TSidecarTrailer);
    Trailer.Time := HostClockSeconds;
    Trailer.DurationSeconds := ADurationSeconds;
    Trailer.Samples := ALog.SampleCount;
    // Frames are not counted: doing it honestly means decoding the whole
    // movie, and a recovery pass at start-up must not do that. The
    // duration and the sample count say what survived.
    Trailer.Frames := 0;
    Trailer.Recovered := True;
    Writer.WriteTrailer(Trailer);
  finally
    Writer.Free;
  end;
end;

// A cheap "was this take finished?" that reads the end of the file and
// nothing else.
//
// It exists because the scan runs at every start over a directory that
// only grows. Parsing every sidecar to find the one that has no trailer
// cost 5.12 s over fifty finished takes and would go on climbing; the
// trailer is by construction the last record, so a few kilobytes of tail
// answers for every take that is fine, and only the rare unfinished one
// is parsed in full.
//
// Deliberately a substring test rather than a parse — and its direction
// matters: a tail that looks finished is SKIPPED OUTRIGHT, so a false
// positive here means a take is silently never recovered. That is safe
// today only because QuoteJsonString escapes every quote in a movie
// name, so no name can fake a `"k":"trailer"` match. Anyone relaxing
// this test must keep that property; the safe failure direction is the
// false NEGATIVE, which merely costs the full parse below.
function TailLooksFinished(const APath: string): Boolean;
const
  TailBytes = 4096;
var
  Handle: THandle;
  Size, Start: Int64;
  Buffer: array[0..TailBytes] of AnsiChar;
  Read: Integer;
  Tail: string;
begin
  Result := False;
  Handle := FileOpen(APath, fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then
    Exit;
  try
    Size := FileSeek(Handle, Int64(0), fsFromEnd);
    if Size <= 0 then
      Exit;
    Start := Size - TailBytes;
    if Start < 0 then
      Start := 0;
    FileSeek(Handle, Start, fsFromBeginning);
    Read := FileRead(Handle, Buffer, TailBytes);
    if Read <= 0 then
      Exit;
    SetString(Tail, PAnsiChar(@Buffer[0]), Read);
  finally
    FileClose(Handle);
  end;
  Result := Pos('"k":"trailer"', Tail) > 0;
end;

function RecoverOne(const ASidecarPath: string;
  out ATake: TRecoveredTake): Boolean;
var
  Log: TSidecarLog;
  Reader: TMovieReader;
  Error: string;
  MoviePath: string;
  Duration: Double;
begin
  Result := False;
  ATake := Default(TRecoveredTake);
  // Before anything is parsed: the overwhelmingly common case is a
  // directory of finished takes, and this answers for each of them in one
  // seek and one read.
  if TailLooksFinished(ASidecarPath) then
    Exit;
  Log := TSidecarLog.Create;
  try
    if not Log.LoadFromFile(ASidecarPath, Error) then
      Exit;
    // A finished take, or one whose recording never got a first frame and
    // so has no movie worth anything.
    if Log.HasTrailer or not Log.HasAnchor then
      Exit;
    // A sidecar written before the last reboot. The host clock counts
    // from boot, so an anchor in the future is a clock that has been
    // reset under it — and its pid means nothing, because pids are reused
    // across a boot. Nothing is touched: a take from a previous boot is
    // either already fine or was lost long ago, and re-muxing a movie on
    // the strength of a pid that now belongs to somebody else is exactly
    // the mistake worth refusing.
    if Log.AnchorHost > HostClockSeconds then
      Exit;
    // The name is joined to this directory and the file it lands on is
    // REPLACED by a re-mux, so the format's "a bare file name, not a
    // path" rule has to be enforced here and not merely documented. A
    // planted sidecar naming `../B/victim.mp4` made `knips record`
    // re-mux a movie in a different directory — the victim's inode
    // changed and the planted sidecar came back with a recovered
    // trailer. Nothing is touched and no trailer is written: a sidecar
    // this pass will not act on must also not be closed off, or a
    // planted one would silently disable recovery for the take it names.
    if not SidecarMovieNameIsBare(Log.Header.MovieName) then
      Exit;
    if ProcessIsAlive(Log.Header.ProcessID) then
      Exit;
    MoviePath := IncludeTrailingPathDelimiter(
      ExtractFileDir(ASidecarPath)) + Log.Header.MovieName;
    // The refusal every writer gives its output, from the unit that
    // owns it (Knips.Export.Atomic): the re-mux renames a file onto
    // this path, and a symlink there would be silently replaced. Knips
    // does not write through one, and recovery is a writer like the
    // rest.
    if OutputPathRefusal(MoviePath) <> '' then
      Exit;
    if not FileExists(MoviePath) then
      Exit;
    ATake.MoviePath := MoviePath;
    ATake.SidecarPath := ASidecarPath;
    ATake.Bytes := FileSizeOf(MoviePath);
    if ATake.Bytes <= 0 then
    begin
      // The crash beat the first fragment. Nothing to finish, and the
      // sidecar is closed so the next start does not look again.
      ATake.Note := 'the movie is empty — the recording died before its '
        + 'first fragment reached disk';
      CloseSidecar(ASidecarPath, Log, 0);
      Exit(True);
    end;

    Reader := TMovieReader.Create(MoviePath);
    try
      if not Reader.Open(Error) then
      begin
        ATake.Note := 'the movie could not be opened (' + Error
          + '); it has been left exactly as it was found';
        CloseSidecar(ASidecarPath, Log, 0);
        Exit(True);
      end;
      Duration := Reader.DurationSeconds;
    finally
      Reader.Free;
    end;
    ATake.DurationSeconds := Duration;
    if Duration <= 0 then
    begin
      ATake.Note := 'the movie opens but has no duration; it has been '
        + 'left exactly as it was found';
      CloseSidecar(ASidecarPath, Log, 0);
      Exit(True);
    end;

    // The reader is gone by here: AVAssetExportSession must not be handed
    // a file another AVAsset still has open for reading.
    if RemuxInPlace(MoviePath, Duration, Error) then
    begin
      ATake.Remuxed := True;
      ATake.Bytes := FileSizeOf(MoviePath);
    end
    else
      ATake.Note := 'left as the fragmented file the crash produced, '
        + 'which plays: the re-mux failed (' + Error + ')';
    CloseSidecar(ASidecarPath, Log, Duration);
    Result := True;
  finally
    Log.Free;
  end;
end;

function RecoverOrphanedTakes(const ADirectory: string;
  out ATakes: TRecoveredTakes;
  out ASweptTemporaries: Integer): Integer;
var
  Search: TSearchRec;
  Take: TRecoveredTake;
  Directory: string;
  Pool: Pointer;
begin
  SetLength(ATakes, 0);
  Result := 0;
  ASweptTemporaries := 0;
  if ADirectory = '' then
    Exit;
  Directory := IncludeTrailingPathDelimiter(ADirectory);
  if not DirectoryExists(Directory) then
    Exit;
  // Before the takes: the scratch files a killed *render* leaves behind.
  // They are not takes and nothing will ever finish them — the render
  // pass renames its temporary into place as its last act, so one that
  // is still here is one that died (Knips.Export.Render). Swept rather
  // than reported: a render can always be run again from the raw take,
  // which is the file this directory keeps for exactly that reason.
  ASweptTemporaries := SweepRenderTemporaries(Directory);
  if FindFirst(Directory + '*' + SidecarExtension, faAnyFile, Search) <> 0 then
    Exit;
  try
    repeat
      if (Search.Attr and faDirectory) <> 0 then
        Continue;
      // One bad sidecar must not stop the pass: the next one might be the
      // take somebody actually wants back.
      // One pool per take. A directory of ten orphans is ten
      // AVAssetExportSessions and ten AVURLAssets, every one of them
      // autoreleased by its factory, and this pass is the one place in
      // the CLI that runs more than one framework session in a process
      // (Knips.ObjC.Runtime.BeginAutoreleasePool).
      Pool := BeginAutoreleasePool;
      try
        try
          if not RecoverOne(Directory + Search.Name, Take) then
            Continue;
        except
          on Exception do
            Continue;
        end;
      finally
        EndAutoreleasePool(Pool);
      end;
      SetLength(ATakes, Result + 1);
      ATakes[Result] := Take;
      Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

// Whether a temporary at APath belongs to a render that is still
// running. The owner marker is the answer where there is one — the same
// `kill(pid, 0)` test an unfinished sidecar gets — and a temporary with
// no marker is judged by its age, because a render that claimed one
// before markers existed, or one whose marker could not be written,
// must not be swept out from under itself either.
function TemporaryIsLive(const APath: string): Boolean;
var
  Marker: TStringList;
  MarkerPath: string;
  Pid: Integer;
  Written: TDateTime;
begin
  MarkerPath := RenderTemporaryOwnerPathFor(APath);
  if FileExists(MarkerPath) then
  begin
    Marker := TStringList.Create;
    try
      try
        Marker.LoadFromFile(MarkerPath);
      except
        on Exception do
          Exit(True);
      end;
      if (Marker.Count > 0) and TryStrToInt(Trim(Marker[0]), Pid) then
        Exit(ProcessIsAlive(Pid));
    finally
      Marker.Free;
    end;
    // A marker that says nothing readable is a marker somebody is
    // half way through writing.
    Exit(True);
  end;
  if not FileAge(APath, Written) then
    Exit(False);
  Result := (Now - Written) * MinsPerDay < TemporaryGraceMinutes;
end;

function SweepRenderTemporaries(const ADirectory: string): Integer;
var
  Search: TSearchRec;
  Directory, TemporaryName: string;
  Kind: TRenderTemporaryKind;
  Live, Found: TStringList;
  I: Integer;
begin
  Result := 0;
  if ADirectory = '' then
    Exit;
  Directory := IncludeTrailingPathDelimiter(ADirectory);
  if not DirectoryExists(Directory) then
    Exit;
  Live := TStringList.Create;
  Found := TStringList.Create;
  try
    Live.Sorted := True;
    Live.Duplicates := dupIgnore;
    // Two passes, because a temporary's family — the file itself, its
    // owner marker, and AVAssetWriter's `.sb-<token>` shadow of it — has
    // to be judged as one thing, and the directory may well list the
    // shadow before the marker. The first pass decides which
    // temporaries are somebody's live work; the second deletes only
    // what is left.
    if FindFirst(Directory + '*' + RenderTemporarySuffix + '*', faAnyFile,
      Search) <> 0 then
      Exit;
    try
      repeat
        if (Search.Attr and faDirectory) <> 0 then
          Continue;
        // The tightened rule. `*<suffix>*` used to match — and delete —
        // an ordinary user file called `notes.knips-render-tmp.txt`.
        Kind := ClassifyRenderTemporary(Search.Name, TemporaryName);
        if Kind = rtkNotOurs then
          Continue;
        Found.AddObject(Search.Name, TObject(PtrInt(Ord(Kind))));
        if (Live.IndexOf(TemporaryName) < 0)
          and TemporaryIsLive(Directory + TemporaryName) then
          Live.Add(TemporaryName);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
    for I := 0 to Found.Count - 1 do
    begin
      ClassifyRenderTemporary(Found[I], TemporaryName);
      if Live.IndexOf(TemporaryName) >= 0 then
        Continue;
      // Only the temporary itself is counted. Its marker and its shadow
      // are bookkeeping, and a caller told "3 leftover render scratch
      // file(s) removed" about one dead render would be told a number
      // that means nothing.
      if DeleteFile(Directory + Found[I])
        and (TRenderTemporaryKind(PtrInt(Found.Objects[I])) = rtkTemporary)
        then
        Inc(Result);
    end;
  finally
    Found.Free;
    Live.Free;
  end;
end;

function DescribeRecoveredTakes(const ATakes: TRecoveredTakes): string;
var
  I: Integer;
  Line: string;
begin
  Result := '';
  for I := 0 to High(ATakes) do
  begin
    if ATakes[I].Remuxed then
      Line := Format('recovered %s: %.1fs, %d kB',
        [ATakes[I].MoviePath, ATakes[I].DurationSeconds,
        ATakes[I].Bytes div 1024])
    else
      Line := Format('recovered %s: %s',
        [ATakes[I].MoviePath, ATakes[I].Note]);
    if Result <> '' then
      Result := Result + LineEnding;
    Result := Result + Line;
  end;
end;

{$ENDIF}

end.

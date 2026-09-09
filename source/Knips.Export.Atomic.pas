unit Knips.Export.Atomic;

// How knips replaces a file somebody already has.
//
// Every writer here can be asked to produce a file that already exists,
// and the previous one is usually the thing the user cares about most:
// the deliverable they were about to send. So none of them writes onto
// the output's own name. Each builds into a neighbour called
// `<unique>-<output>.knips-render-tmp` and renames that onto the output as its
// last act, because rename(2) replaces the destination atomically
// within one filesystem. Until the rename, the old file is untouched;
// after it, the new one is complete. There is no instant in between.
//
// This used to be the MP4 render's private arrangement. It is shared
// now because the other two writers did not have it and paid for that:
// `knips export` opened its GIF sink directly on the output path — the
// GIF's two passes truncated a good animation at the start of pass two,
// and a Ctrl-C in the middle destroyed it — and the passthrough trim
// deleted its output before asking AVAssetExportSession to write a new
// one, which a timeout then left as nothing at all.
//
// **The owner marker.** A temporary alone cannot say whether it belongs
// to a render still running or one that died, and the crash sweep
// (Knips.Recording.Recovery) has to tell those apart. So a writer that
// claims a temporary writes its pid beside it, and the sweep leaves any
// temporary whose owner still answers `kill(pid, 0)`.
//
// **Symbolic links.** No writer here follows one. An `--out` that is a
// symlink used to mean two different disasters depending on the writer:
// `export` opened the path and wrote THROUGH the link, destroying
// whatever it pointed at while reporting success against the link's own
// name, and `render` renamed over the link, silently replacing it. One
// policy for all of them: a symlink at the output is refused by name.
// A user who means the target can pass the target.
//
// Everything here runs on the main thread.

{$I Knips.inc}

interface

{$IFDEF DARWIN}
{$modeswitch objectivec2}

uses
  BaseUnix,
  Classes,
  SysUtils,

  Knips.Options,
  MacOSAll;

// Why APath cannot be written, or '' when it can. Refuses a symbolic
// link, whatever it points at and whether or not the target exists.
// Asked by `record`, `render`, `export` and the trim, on both faces.
function OutputPathRefusal(const APath: string): string;

// Reserves a unique sibling of ATempPath with an exclusive owner marker.
// Returns its actual name through ATempPath. Existing scratch is never
// removed: another operation (or a crashed recording) may still need it.
function ClaimTemporary(var ATempPath: string;
  out AError: string): Boolean;

// Gives up this process's reservation without deleting the file. Used
// for a failed recording whose flushed fragments are still recoverable.
procedure PreserveTemporary(const ATempPath: string);

// The one instant at which the old output stops being the answer.
//
// rename(2) replaces the destination atomically within one filesystem,
// so there is deliberately no DeleteFile first: deleting and then
// renaming would open exactly the window this exists to close.
//
// **It is retried, and the retry is a wait rather than a hope.**
// AVAssetWriter's completion handler having fired does not mean the
// file at ATempPath has stopped moving: for a fast-start output the
// framework assembles the movie from its own scratch and puts it at
// that path with a replace of its own, and under the macOS sandbox that
// replace goes through a shim (the `.sb-<token>` neighbour). Measured
// on the release build: one render in twelve came back `could not
// replace …` — the temporary was momentarily not there to rename. Half
// a second of twenty-five-millisecond turns covers it; a temporary that
// is still missing after that is genuinely missing, and the error then
// says so with the errno and whether the file exists, because those two
// facts are the whole diagnosis.
function CommitTemporary(const ATempPath, AOutputPath: string;
  out AError: string): Boolean;

// Removes only a temporary successfully claimed by this process.
// An unclaimed template or another operation's scratch is left alone.
procedure SweepTemporary(const ATempPath: string);

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // How long CommitTemporary will wait for the temporary to settle
  // before giving up on the rename, and how long one wait is.
  CommitAttempts = 20;
  CommitSettleSeconds = 0.025;

function OutputPathRefusal(const APath: string): string;
var
  Info: Stat;
begin
  Result := '';
  if APath = '' then
    Exit;
  // lstat, never stat: the whole question is what the NAME is, not what
  // it leads to.
  if FpLStat(APath, Info) <> 0 then
    Exit;
  if FpS_ISLNK(Info.st_mode) then
    Result := APath + ' is a symbolic link; knips will not write through '
      + 'one — pass the file it points at instead';
end;

var
  OwnedTemporaries: TStringList;

function OwnsTemporary(const APath: string): Boolean;
begin
  Result := (OwnedTemporaries <> nil)
    and (OwnedTemporaries.IndexOf(APath) >= 0);
end;

function ClaimTemporary(var ATempPath: string;
  out AError: string): Boolean;
var
  Token: TGUID;
  Candidate, MarkerText: string;
  Handle, Separator: Integer;
  Info: Stat;
begin
  Result := False;
  AError := OutputPathRefusal(ATempPath);
  if AError <> '' then
    Exit;
  if ATempPath = '' then
  begin
    AError := 'no temporary path to build into';
    Exit;
  end;
  if CreateGUID(Token) <> 0 then
  begin
    AError := 'could not allocate a temporary name';
    Exit;
  end;
  Separator := LastDelimiter('/', ATempPath);
  Candidate := Copy(ATempPath, 1, Separator)
    + Copy(GUIDToString(Token), 2, 36) + '-'
    + Copy(ATempPath, Separator + 1, MaxInt);
  Handle := FpOpen(RenderTemporaryOwnerPathFor(Candidate),
    O_WRONLY or O_CREAT or O_EXCL, &600);
  if Handle < 0 then
  begin
    AError := 'cannot reserve temporary for ' + ATempPath + ': '
      + SysErrorMessage(fpgeterrno);
    Exit;
  end;
  MarkerText := IntToStr(FpGetPid) + LineEnding;
  Result := FpWrite(Handle, MarkerText[1], Length(MarkerText))
    = Length(MarkerText);
  FpClose(Handle);
  // The framework creates the movie itself. Never hand it an existing
  // name, including a dangling link or a directory.
  if FpLStat(Candidate, Info) = 0 then
    Result := False;
  if not Result then
  begin
    DeleteFile(RenderTemporaryOwnerPathFor(Candidate));
    AError := 'cannot reserve temporary for ' + ATempPath;
    Exit;
  end;
  if OwnedTemporaries = nil then
    OwnedTemporaries := TStringList.Create;
  OwnedTemporaries.Add(Candidate);
  ATempPath := Candidate;
end;

procedure PreserveTemporary(const ATempPath: string);
var
  Index: Integer;
begin
  if not OwnsTemporary(ATempPath) then
    Exit;
  Index := OwnedTemporaries.IndexOf(ATempPath);
  DeleteFile(RenderTemporaryOwnerPathFor(ATempPath));
  OwnedTemporaries.Delete(Index);
end;

function CommitTemporary(const ATempPath, AOutputPath: string;
  out AError: string): Boolean;
var
  Attempt: Integer;
begin
  AError := '';
  Result := False;
  if not OwnsTemporary(ATempPath) then
  begin
    AError := 'temporary is not owned by this operation: ' + ATempPath;
    Exit;
  end;
  AError := OutputPathRefusal(AOutputPath);
  if AError <> '' then
    Exit;
  for Attempt := 1 to CommitAttempts do
  begin
    if RenameFile(ATempPath, AOutputPath) then
    begin
      SweepTemporary(ATempPath);
      Exit(True);
    end;
    // A run-loop turn rather than a sleep: this is the main thread, and
    // whatever the frameworks have left to do may want it.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, CommitSettleSeconds, False);
  end;
  AError := Format('the output was written but could not replace %s after '
    + '%.2fs (errno %d, temporary %s)', [AOutputPath,
    CommitAttempts * CommitSettleSeconds, fpgeterrno,
    BoolToStr(FileExists(ATempPath), 'present', 'gone')]);
end;

procedure SweepTemporary(const ATempPath: string);
var
  Entries: PDir;
  Entry: PDirent;
  Directory, Pattern, Ours, Name: string;
begin
  if not OwnsTemporary(ATempPath) then
    Exit;
  DeleteFile(ATempPath);
  PreserveTemporary(ATempPath);
  Directory := Copy(ATempPath, 1, LastDelimiter('/', ATempPath));
  Ours := Copy(ATempPath, Length(Directory) + 1, MaxInt);
  if Directory = '' then
    Directory := './';
  Pattern := Ours + RenderTemporaryShadowPrefix;
  // Read the literal Unix entry: TSearchRec.Name strips a backslash as
  // though it were a directory separator, losing part of valid names.
  Entries := FpOpenDir(PChar(Directory));
  if Entries = nil then
    Exit;
  try
    Entry := FpReadDir(Entries^);
    while Entry <> nil do
    begin
      Name := StrPas(@Entry^.d_name[0]);
      if Copy(Name, 1, Length(Pattern)) = Pattern then
        DeleteFile(Directory + Name);
      Entry := FpReadDir(Entries^);
    end;
  finally
    FpCloseDir(Entries^);
  end;
end;

finalization
  OwnedTemporaries.Free;

{$ENDIF}

end.

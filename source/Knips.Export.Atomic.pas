unit Knips.Export.Atomic;

// How knips replaces a file somebody already has.
//
// Every writer here can be asked to produce a file that already exists,
// and the previous one is usually the thing the user cares about most:
// the deliverable they were about to send. So none of them writes onto
// the output's own name. Each builds into a neighbour called
// `<output>.knips-render-tmp` and renames that onto the output as its
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
  SysUtils,

  Knips.Options,
  MacOSAll;

// Why APath cannot be written, or '' when it can. Refuses a symbolic
// link, whatever it points at and whether or not the target exists.
// Asked by `record`, `render`, `export` and the trim, on both faces.
function OutputPathRefusal(const APath: string): string;

// Clears any previous temporary at ATempPath and writes the owner
// marker naming this process. False with a message when the stale
// temporary cannot be removed, which is the one case a writer must not
// proceed through: it would be appending to somebody else's file.
function ClaimTemporary(const ATempPath: string;
  out AError: string): Boolean;

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

// Removes ATempPath, its owner marker and any sandbox shadow of it.
// Safe to call when there is nothing there, which is the usual case.
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

function ClaimTemporary(const ATempPath: string;
  out AError: string): Boolean;
var
  Marker: TextFile;
begin
  AError := '';
  Result := False;
  if ATempPath = '' then
  begin
    AError := 'no temporary path to build into';
    Exit;
  end;
  // A temporary is never a symlink of ours; one sitting there that is
  // has been planted, and following it is exactly what this unit exists
  // not to do.
  if OutputPathRefusal(ATempPath) <> '' then
  begin
    AError := OutputPathRefusal(ATempPath);
    Exit;
  end;
  SweepTemporary(ATempPath);
  if FileExists(ATempPath) then
  begin
    AError := 'cannot replace ' + ATempPath;
    Exit;
  end;
  // Best effort: a marker that cannot be written costs the sweep its
  // pid gate for this one temporary and nothing else, and refusing to
  // render over it would be the worse trade.
  AssignFile(Marker, RenderTemporaryOwnerPathFor(ATempPath));
  try
    Rewrite(Marker);
    try
      WriteLn(Marker, FpGetPid);
    finally
      CloseFile(Marker);
    end;
  except
    on Exception do
      ;
  end;
  Result := True;
end;

function CommitTemporary(const ATempPath, AOutputPath: string;
  out AError: string): Boolean;
var
  Attempt: Integer;
begin
  AError := '';
  Result := False;
  DeleteFile(RenderTemporaryOwnerPathFor(ATempPath));
  for Attempt := 1 to CommitAttempts do
  begin
    if RenameFile(ATempPath, AOutputPath) then
      Exit(True);
    // A run-loop turn rather than a sleep: this is the main thread, and
    // whatever the frameworks have left to do may want it.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, CommitSettleSeconds, False);
  end;
  AError := Format('the output was written but could not replace %s after '
    + '%.2fs (errno %d, temporary %s)', [AOutputPath,
    CommitAttempts * CommitSettleSeconds, fpgeterrno,
    BoolToStr(FileExists(ATempPath), 'present', 'gone')]);
  SweepTemporary(ATempPath);
end;

procedure SweepTemporary(const ATempPath: string);
var
  Search: TSearchRec;
  Directory, Pattern, Ours: string;
begin
  if ATempPath = '' then
    Exit;
  DeleteFile(ATempPath);
  DeleteFile(RenderTemporaryOwnerPathFor(ATempPath));
  Directory := ExtractFilePath(ATempPath);
  Ours := ExtractFileName(ATempPath);
  // The sandbox shadows, which carry a token nothing here can predict.
  Pattern := Ours + RenderTemporaryShadowPrefix + '*';
  if FindFirst(Directory + Pattern, faAnyFile, Search) <> 0 then
    Exit;
  try
    repeat
      if (Search.Attr and faDirectory) <> 0 then
        Continue;
      DeleteFile(Directory + Search.Name);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

{$ENDIF}

end.

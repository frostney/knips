unit Knips.Recording.Sidecar;

// The event sidecar: what the pointer did while a recording was running,
// written next to the movie as a plain text file anybody can read.
//
// **Why it exists.** A screen recording is pixels. Where the pointer was,
// when a button went down, which rectangle the capture was reading at that
// instant — all of it is known while the recording runs and none of it
// survives into the file. Knips writes it down instead. `demo.mp4` gets
// `demo.knips.jsonl` beside it, and everything downstream (the synthetic
// cursor at export time, and whatever anybody else wants to build) reads
// that rather than guessing from the video.
//
// **The format is public and documented** — docs/event-sidecar.md is the
// specification, this unit is the implementation of it, and
// Knips.Recording.Sidecar.Test.pas is the proof the two agree. JSON Lines:
// one JSON object per line, no enclosing array, so a truncated file (the
// process was killed mid-recording) is still readable up to its last
// complete line. Every line carries a `"k"` naming its kind, and a reader
// that meets a kind it does not know is required to skip it — that is the
// whole of the forward-compatibility story, and it is why new event kinds
// will not need a version bump.
//
// **The clock is the point.** An event time that cannot be placed on the
// movie's own timeline is decoration. Every time in this file — `"t"` on a
// sample, `"host"` on the anchor — is seconds on ScreenCaptureKit's host
// clock (CMClockGetHostTimeClock), which is the same clock the frames'
// presentation stamps come from. The anchor record carries the presentation
// stamp AVAssetWriter started the movie's session at, so
//
//     movie time of an event = event."t" - anchor."host"
//
// is exact by construction: two readings of one monotonic clock, subtracted.
// No wall clock is involved anywhere, so an NTP correction or a DST change
// mid-recording cannot move an event by a frame. `MovieSeconds` below is
// that subtraction and nothing more.
//
// The anchor is written as soon as the first frame has been appended,
// rather than at the end, so a recording that dies still has it.
//
// **Coordinates.** `x`/`y` are in the recorded display's own points, from
// its top-left corner — the space SCStreamConfiguration.sourceRect and
// TCaptureRegion both live in, and the space
// Knips.Recording.CursorMath maps into frame pixels. `sx`/`sy`/`sw`/`sh`
// are the rectangle the capture was reading at that instant, which the
// live effects move thirty times a second; they are written only when they
// changed since the previous sample, and a reader carries the last value
// forward (the header's base rectangle is the value before the first one).
//
// Platform-neutral on purpose: this is a file format, and the parts of a
// file format worth testing are exactly the parts that have nothing to do
// with macOS. The Darwin side (Knips.Recording) samples the pointer and
// hands records to TSidecarWriter; the export side (Knips.Export.Pipeline)
// reads them back through TSidecarLog.

{$I Knips.inc}

interface

uses
  Classes,
  Math,
  SysUtils,

  fpjson,
  jsonparser,
  Knips.Options;

const
  // The format's own name and version, written into the header. Bumped
  // only for a change a version-1 reader could misread; a new record kind
  // or a new header field is not one (see the unit comment).
  SidecarFormatName = 'knips-events';
  SidecarFormatVersion = 1;
  // What `demo.mp4` gets beside it. The double extension is deliberate:
  // it keeps the movie's stem, so a directory of takes sorts with each
  // sidecar under its movie, and `.jsonl` still says what the file is.
  SidecarExtension = '.knips.jsonl';
  // How long a silence in the pointer track a reader may draw a straight
  // line through, as a multiple of the header's own target sample
  // interval and with a floor under it.
  //
  // Fifteen intervals is half a second at the usual 30 Hz — fifteen
  // times the spacing the sampler achieves and far past any stall a busy
  // run loop produces, so it never fires on an ordinary take. What it
  // does fire on is the case the format already documents as the sparse
  // one: an MCP recording, whose stdio transport blocks between tool
  // calls, gets a sample at the start, one per `record_status` and one at
  // the stop. Two of those can be minutes apart, and a lerp between them
  // is a pointer gliding across the screen for a minute — a thing that
  // never happened. See InterpolatePath.
  //
  // The floor matters because the multiple alone would make a take that
  // *claimed* a very high sample rate refuse gaps a viewer would never
  // notice.
  InterpolatedGapSamples = 15;
  MinInterpolatedGapSeconds = 0.5;
  // And a ceiling, because `sampleHz` is a number in a file somebody
  // else may have written. A third-party sidecar declaring 0.05 Hz would
  // otherwise buy itself a five-minute licence to interpolate, which is
  // exactly the sweep this rule exists to stop. Two seconds is longer
  // than any silence a real recorder produces and short enough that the
  // worst a bad header can do is two seconds of drawn line.
  MaxInterpolatedGapSeconds = 2.0;
  // Below this a `sampleHz` is not a slow sampler, it is a damaged
  // number: one sample a minute is 0.0167 Hz, and this reader divides by
  // the value.
  MinBelievableSampleHz = 0.01;
  // The two limits a line has to be inside before it is handed to the
  // JSON parser at all.
  //
  // They are here because the per-line `try` below is not the safety net
  // it looks like. fpjson's parser is RECURSIVE: a line of fifty
  // thousand `[` characters is fifty thousand stack frames, and the
  // process dies of a stack overflow — a signal, not an exception, so
  // nothing above can catch it. And the one thing that reads sidecars
  // nobody has vetted is the recovery scan, which runs before anything
  // else: the menu-bar app over ~/Movies/knips at every launch, and
  // `knips record` over whatever directory its `--out` points at — so
  // the CLI's exposure is not one blessed folder but any directory
  // somebody records into. One poisoned file in either would kill knips
  // at every start, silently, for ever.
  //
  // So the shape is measured first and a line outside these limits is
  // counted in SkippedLines — which is exactly what the format already
  // promises for a line this reader cannot make sense of. Sixty-four
  // levels is far past anything the format writes (its deepest line is
  // one object of scalars: depth 1) and past any plausible extension of
  // it, and a megabyte is a thousand times its longest line.
  MaxSidecarLineDepth = 64;
  MaxSidecarLineBytes = 1024 * 1024;
  // And a bound on the whole file, checked before a byte of it is read.
  // A sidecar is one short line per sample: an hour at 30 Hz is about
  // 11 MB, so 64 MB is six hours of continuous sampling and nothing a
  // recording produces. Past it the file is refused rather than loaded,
  // because the load is what costs the memory — there is no way to be
  // careful about a file already in a string.
  MaxSidecarBytes = Int64(64) * 1024 * 1024;
  // 2^53: the largest integer a Double still represents exactly, and so
  // the point past which an integer field read through one stops being
  // a number and starts being an approximation. Every count this format
  // carries is many orders of magnitude below it.
  MaxExactIntegerInDouble = 9007199254740992.0;
  // Bit 0 of a sample's button mask. Only the left button is sampled —
  // see the sampler's own comment for why the others are not.
  SidecarLeftButton = 1;
  // What the sampler aims for, in hertz. Recorded in the header rather
  // than assumed by readers: it is the resolution of every edge in the
  // file, and a reader that interpolates should know what it is
  // interpolating between.
  DefaultSidecarSampleHz = 30;

type
  // How the pointer got into the movie's pixels, if it did. The sidecar
  // records this because it is the one thing a reader cannot recover from
  // the video: a frame with no pointer in it looks the same whether the
  // user asked for that or whether something went wrong.
  TSidecarCursorRender = (
    // ScreenCaptureKit drew the system pointer into the frames.
    scrSystem,
    // Nothing drew a pointer and nothing is meant to: the movie is
    // cursorless on purpose. This is what --no-cursor records.
    scrNone,
    // Knips composited its enlarged sprite into the frames (Big Cursor).
    scrBaked,
    // Nothing drew a pointer *yet*: the movie is cursorless because the
    // pointer is to be drawn at export time from the track in this file
    // (Smooth Cursor). The distinction from scrNone is the whole reason
    // this is a field and not a boolean — one says "no pointer wanted",
    // the other says "the pointer is in here, put it back".
    scrSmooth);

  // How much of a sidecar a load needs. slmWholeTrack is every line;
  // slmHeaderOnly stops at the header, and leaves SampleCount at zero.
  TSidecarLoadMode = (slmWholeTrack, slmHeaderOnly);

  TSidecarHeader = record
    // The format version the file was written at. A reader must refuse
    // anything above its own SidecarFormatVersion — see TSidecarLog's
    // TooNew.
    Version: Integer;
    // The movie this file belongs to, as a bare file name — not a path.
    // A sidecar travels with its movie, and an absolute path baked into
    // it would be wrong the moment the pair was moved.
    MovieName: string;
    // ISO 8601, UTC, seconds resolution. Human orientation only: nothing
    // in the format is computed from it (see "The clock is the point").
    CreatedUtc: string;
    KnipsVersion: string;
    // The process that wrote this file. It is here for exactly one
    // purpose: a sidecar with no trailer is a recording that did not
    // finish, and the next start has to tell "the process was killed" from
    // "another knips is recording right now"
    // (Knips.Recording.Recovery). Zero when the writer did not say.
    ProcessID: Integer;
    // What was recorded. A window capture's frames are a picture of
    // something that moves under the recorder with no way to find out, so
    // its samples cannot be mapped into frame pixels at all — they are
    // still written (where the pointer was is worth knowing either way),
    // and this field is how a reader knows not to try. Display captures,
    // with or without a region, map exactly.
    TargetKind: TCaptureTargetKind;
    PixelWidth: Integer;
    PixelHeight: Integer;
    // Pixels per point of the recording.
    Scale: Integer;
    FramesPerSecond: Integer;
    SampleHz: Double;
    // The recorded display, and its size in its own points.
    DisplayID: Cardinal;
    DisplayWidth: Double;
    DisplayHeight: Double;
    // The rectangle the recording was sized from, in the display's own
    // top-left points: the region, or the whole display. Also the source
    // rectangle in force before the first sample that carries one.
    BaseX: Double;
    BaseY: Double;
    BaseWidth: Double;
    BaseHeight: Double;
    // How much of the top of the recorded display belongs to the menu
    // bar, in that display's own points. Zero when it was not measured,
    // and zero for a window target.
    //
    // It is here because a click is not always content. The live Zoom on
    // Click already carves this band out — the click that stops a
    // recording is a click on Knips's own status item, and without the
    // rule every full-screen take would end by zooming into the top
    // corner — and a post-recording zoom driven by this file's click
    // track has to carve out exactly the same band or the two effects
    // stop agreeing. The number cannot be recovered from the samples: a
    // notched Mac reports 39 points where an unnotched one reports 22,
    // and an auto-hiding menu bar reports 0.
    MenuBarInset: Double;
    // What is already in the movie's pixels, and therefore what an export
    // can no longer choose. These three plus CursorRender are the whole
    // "what was baked" record, and they exist for one consumer: the
    // playback window's Effects control, which has to know which
    // post-recording effects are still open for a given take. A baked
    // effect is baked — nothing downstream can take it out again.
    CursorRender: TSidecarCursorRender;
    // Zoom on Click was applied to the capture: ScreenCaptureKit's
    // sourceRect really was moved, so the movie's framing already zooms
    // and an export must not zoom it again. Not derivable from the
    // samples — a take where nobody clicked looks exactly like one with
    // the effect off.
    BakedZoomOnClick: Boolean;
    // Follow Mouse likewise: the captured rectangle panned, and the
    // sample track's own sx/sy/sw/sh are the record of where it went.
    BakedFollowMouse: Boolean;
    // The composited window recording pans too, and by a different owner:
    // it is a DISPLAY capture underneath whose source rectangle is polled
    // onto a window as the user drags it. Neither of the two flags above
    // is true for one — no live effect is running — and without this
    // third one such a take would claim its framing was never touched.
    BakedWindowFollow: Boolean;
    AudioMode: TAudioMode;
  end;

  // Which post-recording effects are still open for a take, for the
  // playback window's Effects control and for anything else that offers a
  // choice. Every one of these is "no" for a reason the caller can show.
  TSidecarEffectAvailability = record
    // The pointer can be drawn at export time: the movie has no pointer
    // in it, the samples can be mapped into its frames, and there is a
    // track with an anchor to read them against.
    CanDrawCursor: Boolean;
    // The movie already has a pointer in its pixels — the system one or
    // Big Cursor's sprite — so drawing another would show two.
    CursorAlreadyBaked: Boolean;
    // A crop driven by the click track can still be applied: there are
    // clicks, the samples map, and the capture was not already zooming
    // itself — a crop applied to a crop compounds into a zoom nobody
    // asked for.
    //
    // A take whose framing *panned* (Follow Mouse, or a composited
    // window recording's poll) shows a different rectangle in every
    // frame, and the crop is composed inside that rectangle rather than
    // against the base one. Computing it against the base was the bug
    // this used to be refused over — measured, 36 silently mis-cropped
    // frames on a Follow Mouse take — and the composition is the fix.
    CanZoomOnClick: Boolean;
    // Nothing at all was baked into this take's pixels: no pointer, no
    // zoom, no pan. Such a movie is a *raw* take, and everything about it
    // can still be decided at render time — which is the question a
    // render-the-deliverable pipeline asks first, and the reason the
    // baked flags are recorded rather than inferred.
    //
    // A take that is not fully renderable is not useless: CanDrawCursor
    // and CanZoomOnClick say exactly which parts of it are still open.
    FullyRenderable: Boolean;
    // Why not, when not. '' when everything above is True.
    //
    // Reason is the SUMMARY — the most limiting fact, for a caller that
    // has one line to show. The two below are per effect, and they are
    // what a caller offering one effect must show: a take with a baked
    // pointer and a panned framing has two different reasons, and the
    // summary can only carry one of them. '' when that effect is
    // available.
    Reason: string;
    CursorReason: string;
    ZoomReason: string;
  end;

  TSidecarSample = record
    // Host-clock seconds; see the unit comment.
    Time: Double;
    // The pointer, in the recorded display's own top-left points.
    X: Double;
    Y: Double;
    // Bitmask; SidecarLeftButton is bit 0.
    Buttons: Integer;
    // The rectangle the capture was reading at this instant, in the same
    // space as X/Y. Always filled in by the reader, which carries the
    // last written value forward.
    SourceX: Double;
    SourceY: Double;
    SourceWidth: Double;
    SourceHeight: Double;
  end;

  TSidecarButtonEvent = record
    Time: Double;
    X: Double;
    Y: Double;
    // Bit index, not a mask: 0 is the left button.
    Button: Integer;
    Down: Boolean;
  end;

  TSidecarTrailer = record
    // Host-clock seconds at the stop.
    Time: Double;
    Frames: Int64;
    // Seconds between the movie's first and last appended frame.
    DurationSeconds: Double;
    Samples: Int64;
    // True when this trailer was written by the recovery pass rather than
    // by the recording itself: the process died, and a later start
    // finished the take off. The numbers are then the recovered movie's,
    // read back off the file, not the recorder's own counters.
    Recovered: Boolean;
  end;

  TSidecarSampleArray = array of TSidecarSample;
  TSidecarButtonEventArray = array of TSidecarButtonEvent;

  // The writing half. Append-only, one open file, main thread only —
  // nothing here may be called from a capture queue (it allocates, it
  // raises, and it writes to disk).
  //
  // Every method that could fail records the reason and turns the writer
  // off rather than raising: a sidecar is worth having and never worth
  // losing a recording over. Failed says whether anything went wrong, and
  // LastError says what.
  TSidecarWriter = class
  private
    FStream: TFileStream;
    FPath: string;
    FBuffer: string;
    FFailed: Boolean;
    FLastError: string;
    FAnchorWritten: Boolean;
    FSamples: Int64;
    // The source rectangle the last written sample carried, so an
    // unchanged one is not written again.
    FLastSourceX: Double;
    FLastSourceY: Double;
    FLastSourceWidth: Double;
    FLastSourceHeight: Double;
    FHasSource: Boolean;
    procedure Emit(const ALine: string);
    // After seeking to the end of an existing file: if the last byte is
    // not a newline, the file was cut off mid-record and the next thing
    // written would FUSE with the half-line already there. One
    // unparseable line is not in itself a problem — the reader skips it —
    // but the line being fused onto is the trailer, and a trailer that
    // cannot be parsed means the take is found unfinished again at every
    // start, for ever. So the buffer starts with a line break.
    procedure PrimeAppend;
    procedure FlushBuffer;
    procedure NoteFailure(const AMessage: string);
  public
    // Creates (or replaces) the file. A failure here is not raised: the
    // writer comes back Failed and every later call is a no-op.
    // AAppend keeps whatever is already in the file and writes after it.
    // That is how recovery closes a take off: the header and the anchor
    // and every sample the dead process managed to flush are still
    // exactly right, and all that is missing is the trailer.
    constructor Create(const APath: string; AAppend: Boolean = False);
    destructor Destroy; override;
    procedure WriteHeader(const AHeader: TSidecarHeader);
    // The movie's first frame presentation stamp, in host-clock seconds.
    // Idempotent: only the first call writes anything, because the anchor
    // is by definition the *first* frame's.
    procedure WriteAnchor(AHostSeconds: Double);
    procedure WriteSample(const ASample: TSidecarSample);
    procedure WriteButton(const AEvent: TSidecarButtonEvent);
    procedure WriteTrailer(const ATrailer: TSidecarTrailer);
    // Flushes and closes. Safe to call twice; the destructor calls it.
    procedure Close;
    property Path: string read FPath;
    property Failed: Boolean read FFailed;
    property LastError: string read FLastError;
    property AnchorWritten: Boolean read FAnchorWritten;
    property SampleCount: Int64 read FSamples;
  end;

  // The reading half. Loads the whole file: a sidecar is a few hundred
  // kilobytes for a long take, and every consumer so far wants random
  // access to the track rather than a stream of it.
  TSidecarLog = class
  private
    FHeader: TSidecarHeader;
    FHasAnchor: Boolean;
    FAnchorHost: Double;
    FHasTrailer: Boolean;
    FTrailer: TSidecarTrailer;
    FSamples: TSidecarSampleArray;
    FSampleCount: Integer;
    FButtons: TSidecarButtonEventArray;
    FButtonCount: Integer;
    // The source rectangle in force, carried across records rather than
    // read back off the last accepted sample. See ReadObject: sx/sy/sw/sh
    // are delta-encoded, and a record can announce a new rectangle and
    // still be dropped.
    FCarrySourceX: Double;
    FCarrySourceY: Double;
    FCarrySourceWidth: Double;
    FCarrySourceHeight: Double;
    FHasCarrySource: Boolean;
    FSkippedLines: Integer;
    FTooNew: Boolean;
    FHasHeader: Boolean;
    FForeignFormat: Boolean;
    FForeignFormatName: string;
    procedure BeginLoad;
    function ConsumeLine(const ALine: string;
      AMode: TSidecarLoadMode): Boolean;
    function FinishLoad(out AError: string): Boolean;
    procedure AddSample(const ASample: TSidecarSample);
    procedure AddButton(const AEvent: TSidecarButtonEvent);
    function ReadObject(AObject: TJSONObject): Boolean;
  public
    constructor Create;
    // False with a message when the file cannot be read at all, which is
    // FOUR cases:
    //
    //   1. there is no file at APath;
    //   2. reading it raised — a permission, a device, a directory
    //      where a file was expected;
    //   3. it is longer than MaxSidecarBytes;
    //   4. LoadFromText refused what was in it (see there: a foreign
    //      format, or a version above this reader's).
    //
    // This comment used to say "two cases and only two", naming just the
    // last pair, which is a dangerous thing for it to have said: a
    // reader who believed it would drop the FileExists guard as
    // redundant. Knips.App.Playback made the same claim with a
    // different number.
    //
    // Every call resets this object completely, header included: a
    // TSidecarLog loaded twice must not carry anything of the first
    // file into the second.
    function LoadFromFile(const APath: string;
      out AError: string): Boolean; overload;
    // The same, reading only as much of the file as AMode needs. A
    // header-only load stops after line one, which is what a caller
    // asking one header field wants: `knips export` used to parse a
    // whole track — hundreds of thousands of samples — to find out
    // whether a movie's pointer was in its sidecar.
    function LoadFromFile(const APath: string; AMode: TSidecarLoadMode;
      out AError: string): Boolean; overload;
    // False with a message in two cases and only two: a header naming a
    // format that is not knips-events (ForeignFormat), and one naming a
    // version above this reader's (TooNew).
    //
    // Everything else is survivable and survived. A file whose *last*
    // line is half-written still loads: the truncated line is counted in
    // SkippedLines and everything before it is kept, which is the whole
    // reason the format is one object per line. So does a line too
    // deeply nested or too long to hand to the parser
    // (MaxSidecarLineDepth), one whose numbers are not finite, and one
    // whose timestamp does not advance on the sample before it — all of
    // them skipped, none of them fatal.
    function LoadFromText(const AText: string; out AError: string): Boolean;
    // Seconds on the movie's own timeline for a host-clock time. Only
    // meaningful when HasAnchor; 0 otherwise.
    function MovieSeconds(AHostSeconds: Double): Double;
    // Where the pointer was at AMovieSeconds, linearly interpolated
    // between the two samples that bracket it and clamped to the ends.
    // False when there are no samples at all, or when the log has no
    // anchor to measure movie time against.
    function CursorAt(AMovieSeconds: Double; out AX, AY: Double): Boolean;
    // The same, with the source rectangle in force at that instant. The
    // rectangle is taken from the earlier of the two bracketing samples
    // rather than interpolated: it is what the capture was actually
    // reading, and a rectangle half way between two of them was never
    // read at all.
    function StateAt(AMovieSeconds: Double; out ASample: TSidecarSample):
      Boolean;
    // The longest silence in this take's own pointer track that a reader
    // may draw a straight line through, from the header's target rate —
    // so the rule scales with how fast the take said it was sampling and
    // a reader never has to guess it. Floored and CAPPED: the rate is a
    // number in a file, and a file that claims a very slow one must not
    // be able to talk this reader into a five-minute straight line, and
    // a rate below MinBelievableSampleHz is not believed at all. See
    // InterpolatePath for why the limit exists; a caller drawing a
    // pointer from this track should pass this to it.
    function MaxInterpolatedGap: Double;
    property Header: TSidecarHeader read FHeader;
    property HasAnchor: Boolean read FHasAnchor;
    property AnchorHost: Double read FAnchorHost;
    property HasTrailer: Boolean read FHasTrailer;
    property Trailer: TSidecarTrailer read FTrailer;
    // Whether a header line was read and accepted. False for a file that
    // had none, which is a file every other field of this object is
    // guessing about.
    property HasHeader: Boolean read FHasHeader;
    property SampleCount: Integer read FSampleCount;
    function Sample(AIndex: Integer): TSidecarSample;
    // The samples as one array, for a caller that wants to run the whole
    // track through SmoothSidecarPath rather than ask for one at a time.
    // Longer than SampleCount — it grows in blocks — so every consumer
    // takes the count as a second argument, which is why those functions
    // are shaped the way they are.
    property RawSamples: TSidecarSampleArray read FSamples;
    property ButtonCount: Integer read FButtonCount;
    function ButtonEvent(AIndex: Integer): TSidecarButtonEvent;
    // Lines that were not understood: a truncated tail, or a record kind
    // this version does not know. Never an error on its own.
    property SkippedLines: Integer read FSkippedLines;
    // The file says it was written at a format version above this one.
    // A NEW KIND of record is skippable and needs no version bump, so a
    // version that has moved means something a version-1 reader would
    // MISREAD rather than merely miss — and the only safe answer is to
    // decline the file. LoadFromFile fails with a message when this is
    // set; nothing is half-read.
    property TooNew: Boolean read FTooNew;
    // The file has a header and its `format` is not knips-events. That
    // is refused more bluntly than a version that has moved: this is not
    // one of these files at all, so nothing in it can be trusted to mean
    // what this reader would take it to mean. LoadFromFile fails with a
    // message, exactly as for TooNew.
    property ForeignFormat: Boolean read FForeignFormat;
  end;

// Whether a candidate sample's stamp may join a track whose last stamp
// is APreviousTime. The track is a time series and every reader
// downstream — StateAt's binary search, InterpolatePath's walk,
// SmoothSidecarPath's sliding window — depends on that; a stamp that
// does not advance is not a later position, it is a contradiction. A
// named question rather than one inline comparison because it is the
// rule the FORMAT states (docs/event-sidecar.md, *Sampling*) and a
// reader of this unit should be able to find and test it by name.
function SidecarSampleTimeAdvances(APreviousTime,
  ACandidateTime: Double): Boolean;

// `demo.mp4` -> `demo.knips.jsonl`. The movie's own extension is replaced,
// so `.mov` and `.mp4` recordings of the same stem would collide — which
// is exactly right: they are the same take written twice, and the second
// one's sidecar should replace the first's.
function SidecarPathFor(const AMoviePath: string): string;

// Whether a header's `movie` is what the format says it is: the movie's
// file name, and not a path (docs/event-sidecar.md, *The header*). The
// rule was documented and never enforced, and the one thing that reads
// sidecars nobody wrote is the recovery pass — which joins this name to
// the sidecar's own directory and then REPLACES the file it lands on
// with a re-mux. A planted sidecar naming `../B/victim.mp4` made
// `knips record` re-mux a movie in a different directory (measured: the
// victim's inode changed and the planted sidecar came back with a
// recovered trailer).
//
// So: no `/`, no separator of the host this reader runs on where that
// differs from `/`, and neither of the two names that mean a directory.
// A backslash is deliberately NOT refused on macOS: it is a legal
// character in a file name there, and the recorder writes such a name
// verbatim for exactly that reason (Knips.Recording.OpenSidecar's
// LastDelimiter('/')), so refusing it would silently leave a take called
// `a\b.mp4` unrecovered for ever. A sidecar written on Windows and read
// here can name `..\x.mp4`, and that is caught downstream: the joined
// path names no file in this directory. The cost of refusing a
// legal-but-odd name is one take not recovered — the safe direction,
// since nothing is then touched at all.
function SidecarMovieNameIsBare(const AMovieName: string): Boolean;

// JSON string escaping, exposed because it is the one place a file name
// can break the format: a movie called `say "hi".mp4` is a legal file
// name and an illegal JSON string until this has run over it.
function QuoteJsonString(const AText: string): string;

function SidecarCursorRenderName(ARender: TSidecarCursorRender): string;

// True when the capture never moved its own source rectangle: no live
// zoom, no Follow Mouse pan, no composited window follow. This is the
// exact precondition for anything that treats the recording's base
// rectangle as what every frame shows, which is why it is a named
// question rather than three `and not`s at each call site.
//
// It is NOT the precondition for a post-recording zoom any more. A crop
// composed against the framing the samples record works on a panned take
// too (Knips.Export.ZoomTrack.ZoomWalkerSourceRectIn); what this answers
// for a render is the cheaper question of whether the framing has to be
// looked up per frame at all.
function HasUntouchedFraming(const AHeader: TSidecarHeader): Boolean;

// True when nothing was baked into this take's pixels — no pointer, no
// zoom, no pan. The header alone answers it, so a caller with only the
// first line of a sidecar can ask.
function IsRawTake(const AHeader: TSidecarHeader): Boolean;

// Which post-recording effects a loaded take can still be given. The one
// question the playback window's Effects control has to answer before it
// offers anything, and it is asked of the sidecar rather than of the
// movie because the movie cannot say what was done to it.
function AvailableExportEffects(
  const ALog: TSidecarLog): TSidecarEffectAvailability;

// Smoothing for a synthetic cursor drawn from this track. A sampled
// pointer path is a staircase — thirty positions a second, each held for a
// frame — and drawing a sprite straight onto it reproduces the staircase.
// This is a centred moving average over a time window, which is the
// smoothing that does not lag: a causal filter (an exponential ease, say)
// would put the drawn pointer permanently behind the real one, and this
// track is not live, so there is no reason to accept that.
//
// AWindowSeconds is the full width of the window. Zero or less returns the
// input unchanged. Endpoints use whatever part of the window exists, so
// the path is not pulled toward its own start and end.
//
// Linear in the number of samples: prefix sums and a window whose two
// ends only move forward. It assumes the stamps ADVANCE, which is what
// the loader guarantees — a sample whose time does not is dropped as a
// skipped line. The walk this replaced re-scanned the window per
// sample, which on a track of identical stamps was quadratic; the
// measured before and after are in docs/event-sidecar.md, *Sampling*,
// stated once there rather than restated at every site that would
// otherwise have to be kept in step with it.
function SmoothSidecarPath(const ASamples: TSidecarSampleArray;
  ACount: Integer; AWindowSeconds: Double): TSidecarSampleArray;

// Linear interpolation of a smoothed (or raw) path at one time on the
// same clock the samples carry. False when there is nothing to read.
//
// **A gap longer than AMaxGapSeconds is not interpolated across.** The
// last known position is held instead, and the path snaps to the next
// sample when it arrives. That is not a rounding decision, it is a
// truthfulness one: an MCP recording gets a sample at the start, one per
// `record_status` call and one at the stop (docs/event-sidecar.md,
// *Sampling*), so two samples can be minutes apart — and a straight lerp
// between them draws a pointer gliding smoothly across the screen for a
// minute, which is a thing that never happened. Holding claims only what
// the track actually says: the pointer was here, and later it was there.
// The snap at the far end is visible and is the honest shape of "nobody
// was watching in between".
//
// It also bounds the render's frame synthesis, which asks this function
// whether the next instant would look different: a held position stops
// changing, so a quiet stretch stops being filled in
// (Knips.Export.Cadence).
//
// Zero or less means no limit, which is what a caller measuring the raw
// interpolation wants and is never what a renderer wants.
function InterpolatePath(const ASamples: TSidecarSampleArray;
  ACount: Integer; ATime, AMaxGapSeconds: Double;
  out AX, AY: Double): Boolean;

implementation

type
  // A forward line reader over a stream, so a sidecar is walked rather
  // than held. See TSidecarLog.LoadFromFile for what it replaced.
  TSidecarLineReader = class
  private
    FStream: TStream;
    FBuffer: TBytes;
    FFilled: Integer;
    FCursor: Integer;
    function Fill: Boolean;
    function Segment(AStart, ACount: Integer): string;
  public
    constructor Create(AStream: TStream);
    function NextLine(out ALine: string): Boolean;
  end;

const
  // 64 kB a read: past the point where syscall overhead matters and far
  // inside any cache.
  ReadBlockBytes = 64 * 1024;

const
  // How many decimals each kind of number is written with. Times are
  // host-clock seconds and want microseconds; positions are points and
  // want rather less. Both are chosen so a round trip through the reader
  // is exact to well inside a pixel.
  TimeDecimals = 6;
  PointDecimals = 3;
  // Small on purpose. This is not an I/O optimisation, it is the bound
  // on how much of the pointer track a kill -9 can take with it: at
  // thirty samples a second a sample is about seventy bytes, so two
  // kilobytes is under a second of track and about one write per second.
  // Sixteen kilobytes, tried first, lost seven seconds of a killed take.
  BufferFlushBytes = 2 * 1024;

var
  GInvariant: TFormatSettings;

function InvariantSettings: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

// A JSON number, with the host locale kept out of it: this is a machine
// format, and a comma decimal point would make it unreadable by every
// other JSON parser on the planet.
function Number(AValue: Double; ADecimals: Integer): string;
begin
  Result := FloatToStrF(AValue, ffFixed, 15, ADecimals, GInvariant);
end;

function Bool(AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

// A number this reader is willing to carry. `1e999` is legal JSON and
// parses to +Inf; two of those subtracted are a NaN, and a NaN walked
// through the staleness test, the interpolation and the edge snap comes
// out the other side as a frame count silently wrong (measured: a render
// reporting 40 frames where the take had 257) — or, in a plain FPC build
// with the FPU exceptions unmasked, as an EAccessViolation in somebody
// else's reader. Neither is a thing to pass on, so a record carrying one
// is skipped like any other line this reader cannot make sense of.
function IsFiniteNumber(const AValue: Double): Boolean;
begin
  Result := not IsNan(AValue) and not IsInfinite(AValue);
end;

function AllFinite(const AValues: array of Double): Boolean;
var
  I: Integer;
begin
  for I := Low(AValues) to High(AValues) do
    if not IsFiniteNumber(AValues[I]) then
      Exit(False);
  Result := True;
end;

// One integer field, read the long way round because the short way
// raises.
//
// `TJSONObject.Get(name, Integer)` finds the number and calls AsInteger
// on it, and AsInteger on a `1e999` — legal JSON, parsed to +Inf —
// rounds an infinity into an integer. On a plain FPC build that is an
// exception from inside the read; on macOS it is worse, because
// MacOSAll masks the invalid-operation trap at unit initialisation and
// the same read comes back as -1 with nothing said at all. A
// `"version":-1` then walks straight past the too-new refusal and a
// `"pid":-1` reads as a live process. Neither answer is one to build a
// recovery decision on.
//
// So the value is taken as a Double, which cannot raise, and only
// converted once it is known to be a real number inside the range of
// the field it is going into. Out of range is a SKIP and not a clamp:
// a `"scale":5000000000` is not a scale that needs rounding down, it is
// a number that cannot have come from a recorder.
//
// Absent, or present as something that is not a number at all, gives
// ADefault and True — which is exactly what Get(name, default) did,
// because it looks the name up as jtNumber and falls back otherwise.
function ReadIntegerField(AObject: TJSONObject; const AName: string;
  ADefault, AMinimum, AMaximum: Int64; out AValue: Int64): Boolean;
var
  Item: TJSONData;
  Number: Double;
begin
  AValue := ADefault;
  Result := True;
  Item := AObject.Find(AName);
  if (Item = nil) or (Item.JSONType <> jtNumber) then
    Exit;
  Number := Item.AsFloat;
  if not IsFiniteNumber(Number) then
    Exit(False);
  // Beyond 2^53 a Double no longer represents consecutive integers, so
  // a number that large is not a count of anything — and the comparison
  // against the field's own bounds below would itself be inexact.
  if Abs(Number) > MaxExactIntegerInDouble then
    Exit(False);
  if (Number < AMinimum) or (Number > AMaximum) then
    Exit(False);
  AValue := Round(Number);
end;

{ TSidecarLineReader }

constructor TSidecarLineReader.Create(AStream: TStream);
begin
  inherited Create;
  FStream := AStream;
  SetLength(FBuffer, ReadBlockBytes);
  FFilled := 0;
  FCursor := 0;
end;

function TSidecarLineReader.Fill: Boolean;
begin
  FFilled := FStream.Read(FBuffer[0], Length(FBuffer));
  FCursor := 0;
  Result := FFilled > 0;
end;

// One segment of the buffer as a string, byte for byte. NOT through
// TEncoding: a sidecar is UTF-8 and these strings hold UTF-8, so a
// conversion would be a re-encode of bytes that are already right — and
// a measurably expensive one over a million lines.
function TSidecarLineReader.Segment(AStart, ACount: Integer): string;
begin
  SetString(Result, PAnsiChar(@FBuffer[AStart]), ACount);
end;

function TSidecarLineReader.NextLine(out ALine: string): Boolean;
var
  Start: Integer;
  Character: AnsiChar;
begin
  ALine := '';
  Result := False;
  repeat
    if FCursor >= FFilled then
      if not Fill then
        Exit(ALine <> '');
    Start := FCursor;
    while FCursor < FFilled do
    begin
      Character := AnsiChar(FBuffer[FCursor]);
      if (Character = #10) or (Character = #13) then
      begin
        if FCursor > Start then
          if ALine = '' then
            ALine := Segment(Start, FCursor - Start)
          else
            ALine := ALine + Segment(Start, FCursor - Start);
        Inc(FCursor);
        // A line is a line even when it is empty; the caller skips
        // blanks. Returning here rather than looping keeps a CRLF from
        // costing a line, because the second terminator produces an
        // empty one.
        Exit(True);
      end;
      Inc(FCursor);
    end;
    if FCursor > Start then
      if ALine = '' then
        ALine := Segment(Start, FCursor - Start)
      else
        ALine := ALine + Segment(Start, FCursor - Start);
    // A single line longer than the whole file is possible in principle
    // and refused in practice by SidecarLineWithinLimits; the guard is
    // here so a pathological file cannot grow this string without bound
    // before that check ever runs.
    if Length(ALine) > MaxSidecarLineBytes then
      Exit(True);
  until False;
end;

// Whether a line is shallow and short enough to hand to fpjson at all —
// see MaxSidecarLineDepth for why this is measured before the parse
// rather than caught after it. Quoted strings are skipped over, escapes
// included, so a bracket inside a file name does not count.
function SidecarLineWithinLimits(const ALine: string): Boolean;
var
  I, Depth: Integer;
  InString, Escaped: Boolean;
begin
  Result := False;
  if Length(ALine) > MaxSidecarLineBytes then
    Exit;
  Depth := 0;
  InString := False;
  Escaped := False;
  for I := 1 to Length(ALine) do
  begin
    if InString then
    begin
      if Escaped then
        Escaped := False
      else if ALine[I] = '\' then
        Escaped := True
      else if ALine[I] = '"' then
        InString := False;
      Continue;
    end;
    case ALine[I] of
      '"':
        InString := True;
      '[', '{':
        begin
          Inc(Depth);
          if Depth > MaxSidecarLineDepth then
            Exit;
        end;
      ']', '}':
        // Floored. An unbalanced line cannot be valid JSON and the
        // parser refuses it anyway, so this is defence in depth rather
        // than a case anybody has met — but a counter allowed to go
        // negative is a counter that hands the rest of the line an
        // allowance it did not earn, and the floor costs one compare.
        if Depth > 0 then
          Dec(Depth);
    end;
  end;
  Result := True;
end;

// JSON string escaping, for the two string fields the header has. Both
// come from a file name and a version constant, so this is a guard rather
// than a workhorse — but a file name really can contain a quote.
function QuoteJsonString(const AText: string): string;
var
  I: Integer;
  Ch: Char;
begin
  Result := '"';
  for I := 1 to Length(AText) do
  begin
    Ch := AText[I];
    case Ch of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if Ch < ' ' then
        Result := Result + '\u00' + LowerCase(IntToHex(Ord(Ch), 2))
      else
        Result := Result + Ch;
    end;
  end;
  Result := Result + '"';
end;

function SidecarSampleTimeAdvances(APreviousTime,
  ACandidateTime: Double): Boolean;
begin
  Result := ACandidateTime > APreviousTime;
end;

function SidecarPathFor(const AMoviePath: string): string;
begin
  if AMoviePath = '' then
    Exit('');
  Result := ChangeFileExt(AMoviePath, SidecarExtension);
end;

function SidecarMovieNameIsBare(const AMovieName: string): Boolean;
begin
  if AMovieName = '' then
    Exit(False);
  if (AMovieName = '.') or (AMovieName = '..') then
    Exit(False);
  Result := (Pos('/', AMovieName) = 0) and (Pos(PathDelim, AMovieName) = 0);
end;

// The header's `target` word. Implementation-only: WriteHeader is the
// only writer of it, and a reader wanting the enum has Header.TargetKind
// already parsed for it.
function SidecarTargetName(ATarget: TCaptureTargetKind): string;
begin
  if ATarget = ctkWindow then
    Result := 'window'
  else
    Result := 'display';
end;

function SidecarCursorRenderName(ARender: TSidecarCursorRender): string;
begin
  case ARender of
    scrNone: Result := 'none';
    scrBaked: Result := 'baked';
    scrSmooth: Result := 'smooth';
  else
    Result := 'system';
  end;
end;

// The inverse of SidecarCursorRenderName, which stays public because a
// caller reporting on a loaded take needs the word for it. This one is
// the reader's own and has no caller outside it.
function ParseSidecarCursorRender(const AText: string;
  out ARender: TSidecarCursorRender): Boolean;
var
  Normalized: string;
begin
  Result := True;
  ARender := scrSystem;
  Normalized := LowerCase(Trim(AText));
  if Normalized = 'system' then
    ARender := scrSystem
  else if Normalized = 'none' then
    ARender := scrNone
  else if Normalized = 'baked' then
    ARender := scrBaked
  else if Normalized = 'smooth' then
    ARender := scrSmooth
  else
    Result := False;
end;

{ TSidecarWriter }

constructor TSidecarWriter.Create(const APath: string;
  AAppend: Boolean = False);
begin
  inherited Create;
  FPath := APath;
  if APath = '' then
  begin
    NoteFailure('no sidecar path');
    Exit;
  end;
  try
    if AAppend and FileExists(APath) then
    begin
      FStream := TFileStream.Create(APath, fmOpenReadWrite or
        fmShareDenyWrite);
      FStream.Seek(Int64(0), soEnd);
      PrimeAppend;
    end
    else
      FStream := TFileStream.Create(APath, fmCreate);
  except
    on E: Exception do
      NoteFailure(E.Message);
  end;
end;

destructor TSidecarWriter.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TSidecarWriter.PrimeAppend;
var
  Last: AnsiChar;
begin
  if (FStream = nil) or (FStream.Size <= 0) then
    Exit;
  FStream.Seek(Int64(-1), soEnd);
  if FStream.Read(Last, 1) <> 1 then
  begin
    FStream.Seek(Int64(0), soEnd);
    Exit;
  end;
  FStream.Seek(Int64(0), soEnd);
  // #10 covers both LF and CRLF: the last byte of a CRLF is the LF.
  if Last <> #10 then
    FBuffer := LineEnding;
end;

procedure TSidecarWriter.NoteFailure(const AMessage: string);
begin
  FFailed := True;
  if FLastError = '' then
    FLastError := AMessage;
end;

procedure TSidecarWriter.FlushBuffer;
begin
  if (FBuffer = '') or (FStream = nil) then
    Exit;
  try
    FStream.WriteBuffer(FBuffer[1], Length(FBuffer));
  except
    on E: Exception do
      NoteFailure(E.Message);
  end;
  FBuffer := '';
end;

// Buffered, and flushed by size rather than by record: at thirty samples a
// second a write per sample is ninety syscalls in three seconds for no
// reason. The cost of the buffer is what a killed process loses — at most
// BufferFlushBytes, about half a second of samples — and that is why the
// anchor is flushed the moment it is written rather than waiting its turn.
procedure TSidecarWriter.Emit(const ALine: string);
begin
  if FFailed or (FStream = nil) then
    Exit;
  FBuffer := FBuffer + ALine + LineEnding;
  if Length(FBuffer) >= BufferFlushBytes then
    FlushBuffer;
end;

procedure TSidecarWriter.WriteHeader(const AHeader: TSidecarHeader);
begin
  Emit('{"k":"header","format":' + QuoteJsonString(SidecarFormatName)
    + ',"version":' + IntToStr(SidecarFormatVersion)
    + ',"knips":' + QuoteJsonString(AHeader.KnipsVersion)
    + ',"movie":' + QuoteJsonString(AHeader.MovieName)
    + ',"created":' + QuoteJsonString(AHeader.CreatedUtc)
    + ',"pid":' + IntToStr(AHeader.ProcessID)
    + ',"target":' + QuoteJsonString(SidecarTargetName(AHeader.TargetKind))
    + ',"pixelWidth":' + IntToStr(AHeader.PixelWidth)
    + ',"pixelHeight":' + IntToStr(AHeader.PixelHeight)
    + ',"scale":' + IntToStr(AHeader.Scale)
    + ',"fps":' + IntToStr(AHeader.FramesPerSecond)
    + ',"sampleHz":' + Number(AHeader.SampleHz, PointDecimals)
    + ',"displayId":' + IntToStr(AHeader.DisplayID)
    + ',"displayWidth":' + Number(AHeader.DisplayWidth, PointDecimals)
    + ',"displayHeight":' + Number(AHeader.DisplayHeight, PointDecimals)
    + ',"baseX":' + Number(AHeader.BaseX, PointDecimals)
    + ',"baseY":' + Number(AHeader.BaseY, PointDecimals)
    + ',"baseWidth":' + Number(AHeader.BaseWidth, PointDecimals)
    + ',"baseHeight":' + Number(AHeader.BaseHeight, PointDecimals)
    + ',"menuBarInset":' + Number(AHeader.MenuBarInset, PointDecimals)
    + ',"cursor":' + QuoteJsonString(SidecarCursorRenderName(AHeader.CursorRender))
    + ',"bakedZoomOnClick":' + Bool(AHeader.BakedZoomOnClick)
    + ',"bakedFollowMouse":' + Bool(AHeader.BakedFollowMouse)
    + ',"bakedWindowFollow":' + Bool(AHeader.BakedWindowFollow)
    + ',"audio":' + QuoteJsonString(AudioModeName(AHeader.AudioMode)) + '}');
  // The base rectangle is the source rectangle until a sample says
  // otherwise, so the writer starts from it and omits an unchanged one.
  FLastSourceX := AHeader.BaseX;
  FLastSourceY := AHeader.BaseY;
  FLastSourceWidth := AHeader.BaseWidth;
  FLastSourceHeight := AHeader.BaseHeight;
  FHasSource := True;
  FlushBuffer;
end;

procedure TSidecarWriter.WriteAnchor(AHostSeconds: Double);
begin
  if FAnchorWritten then
    Exit;
  FAnchorWritten := True;
  Emit('{"k":"anchor","host":' + Number(AHostSeconds, TimeDecimals) + '}');
  // Straight to disk: this one record is what makes every other one
  // meaningful, and a recording that ends in a kill -9 must still have it.
  FlushBuffer;
end;

procedure TSidecarWriter.WriteSample(const ASample: TSidecarSample);
var
  Line: string;
begin
  Line := '{"k":"cursor","t":' + Number(ASample.Time, TimeDecimals)
    + ',"x":' + Number(ASample.X, PointDecimals)
    + ',"y":' + Number(ASample.Y, PointDecimals)
    + ',"b":' + IntToStr(ASample.Buttons);
  if (not FHasSource) or (ASample.SourceX <> FLastSourceX)
    or (ASample.SourceY <> FLastSourceY)
    or (ASample.SourceWidth <> FLastSourceWidth)
    or (ASample.SourceHeight <> FLastSourceHeight) then
  begin
    Line := Line + ',"sx":' + Number(ASample.SourceX, PointDecimals)
      + ',"sy":' + Number(ASample.SourceY, PointDecimals)
      + ',"sw":' + Number(ASample.SourceWidth, PointDecimals)
      + ',"sh":' + Number(ASample.SourceHeight, PointDecimals);
    FLastSourceX := ASample.SourceX;
    FLastSourceY := ASample.SourceY;
    FLastSourceWidth := ASample.SourceWidth;
    FLastSourceHeight := ASample.SourceHeight;
    FHasSource := True;
  end;
  Emit(Line + '}');
  Inc(FSamples);
end;

procedure TSidecarWriter.WriteButton(const AEvent: TSidecarButtonEvent);
begin
  Emit('{"k":"button","t":' + Number(AEvent.Time, TimeDecimals)
    + ',"x":' + Number(AEvent.X, PointDecimals)
    + ',"y":' + Number(AEvent.Y, PointDecimals)
    + ',"n":' + IntToStr(AEvent.Button)
    + ',"d":' + Bool(AEvent.Down) + '}');
  // A click is the thing a reader is most likely to be looking for and
  // the thing least likely to be repeated; it does not wait in a buffer.
  FlushBuffer;
end;

procedure TSidecarWriter.WriteTrailer(const ATrailer: TSidecarTrailer);
begin
  Emit('{"k":"trailer","t":' + Number(ATrailer.Time, TimeDecimals)
    + ',"frames":' + IntToStr(ATrailer.Frames)
    + ',"duration":' + Number(ATrailer.DurationSeconds, TimeDecimals)
    + ',"samples":' + IntToStr(ATrailer.Samples)
    + ',"recovered":' + Bool(ATrailer.Recovered) + '}');
  FlushBuffer;
end;

procedure TSidecarWriter.Close;
begin
  FlushBuffer;
  FreeAndNil(FStream);
end;

{ TSidecarLog }

constructor TSidecarLog.Create;
begin
  inherited Create;
  FHeader.Version := SidecarFormatVersion;
  FHeader.SampleHz := DefaultSidecarSampleHz;
end;

function TSidecarLog.Sample(AIndex: Integer): TSidecarSample;
begin
  if (AIndex < 0) or (AIndex >= FSampleCount) then
    Exit(Default(TSidecarSample));
  Result := FSamples[AIndex];
end;

function TSidecarLog.ButtonEvent(AIndex: Integer): TSidecarButtonEvent;
begin
  if (AIndex < 0) or (AIndex >= FButtonCount) then
    Exit(Default(TSidecarButtonEvent));
  Result := FButtons[AIndex];
end;

procedure TSidecarLog.AddSample(const ASample: TSidecarSample);
begin
  if FSampleCount = Length(FSamples) then
    SetLength(FSamples, 64 + Length(FSamples) * 2);
  FSamples[FSampleCount] := ASample;
  Inc(FSampleCount);
end;

procedure TSidecarLog.AddButton(const AEvent: TSidecarButtonEvent);
begin
  if FButtonCount = Length(FButtons) then
    SetLength(FButtons, 16 + Length(FButtons) * 2);
  FButtons[FButtonCount] := AEvent;
  Inc(FButtonCount);
end;

function TSidecarLog.ReadObject(AObject: TJSONObject): Boolean;
var
  Kind: string;
  Sample: TSidecarSample;
  Button: TSidecarButtonEvent;
  Trailer: TSidecarTrailer;
  Render: TSidecarCursorRender;
  Mode: TAudioMode;
  DefaultHz: TJSONFloat;
  Candidate: TSidecarHeader;
  Anchor: Double;
  Whole: Int64;
begin
  Result := False;
  Kind := AObject.Get('k', '');
  if Kind = 'header' then
  begin
    if AObject.Get('format', '') <> SidecarFormatName then
    begin
      // Not one of these files. Recorded rather than skipped, because
      // the answer is to refuse the whole file with a reason and not to
      // carry on reading lines out of it — see ForeignFormat, and
      // docs/event-sidecar.md, which promises the blunter refusal.
      FForeignFormat := True;
      FForeignFormatName := AObject.Get('format', '');
      Exit(True);
    end;
    Candidate := Default(TSidecarHeader);
    if not ReadIntegerField(AObject, 'version', 0, Low(Integer),
      High(Integer), Whole) then
      Exit(False);
    Candidate.Version := Integer(Whole);
    if Candidate.Version > SidecarFormatVersion then
    begin
      FHeader.Version := Candidate.Version;
      FTooNew := True;
      Exit(True);
    end;
    Candidate.KnipsVersion := AObject.Get('knips', '');
    Candidate.MovieName := AObject.Get('movie', '');
    Candidate.CreatedUtc := AObject.Get('created', '');
    if not ReadIntegerField(AObject, 'pid', 0, Low(Integer),
      High(Integer), Whole) then
      Exit(False);
    Candidate.ProcessID := Integer(Whole);
    if AObject.Get('target', 'display') = 'window' then
      Candidate.TargetKind := ctkWindow
    else
      Candidate.TargetKind := ctkDisplay;
    if not ReadIntegerField(AObject, 'pixelWidth', 0, Low(Integer),
      High(Integer), Whole) then
      Exit(False);
    Candidate.PixelWidth := Integer(Whole);
    if not ReadIntegerField(AObject, 'pixelHeight', 0, Low(Integer),
      High(Integer), Whole) then
      Exit(False);
    Candidate.PixelHeight := Integer(Whole);
    if not ReadIntegerField(AObject, 'scale', 0, Low(Integer),
      High(Integer), Whole) then
      Exit(False);
    Candidate.Scale := Integer(Whole);
    if not ReadIntegerField(AObject, 'fps', 0, Low(Integer),
      High(Integer), Whole) then
      Exit(False);
    Candidate.FramesPerSecond := Integer(Whole);
    // Through a typed local, and that is not a style choice. In Delphi
    // mode `TJSONFloat(DefaultSidecarSampleHz)` REINTERPRETS the integer
    // constant's bits as a Double rather than converting them —
    // measured, 30 comes out as $000000000000001E, a denormal of about
    // 1.5E-322. Every other fallback here casts a literal 0, whose bit
    // pattern happens to be 0.0 either way, which is why this was the
    // one that was wrong and why it stayed hidden: a sidecar with no
    // `sampleHz` field came back claiming a sample rate of 1.5E-322
    // instead of the documented 30. An assignment converts.
    DefaultHz := DefaultSidecarSampleHz;
    Candidate.SampleHz := AObject.Get('sampleHz', DefaultHz);
    if not ReadIntegerField(AObject, 'displayId', 0, 0,
      Int64(High(Cardinal)), Whole) then
      Exit(False);
    Candidate.DisplayID := Cardinal(Whole);
    Candidate.DisplayWidth := AObject.Get('displayWidth', TJSONFloat(0));
    Candidate.DisplayHeight := AObject.Get('displayHeight', TJSONFloat(0));
    Candidate.BaseX := AObject.Get('baseX', TJSONFloat(0));
    Candidate.BaseY := AObject.Get('baseY', TJSONFloat(0));
    Candidate.BaseWidth := AObject.Get('baseWidth', TJSONFloat(0));
    Candidate.BaseHeight := AObject.Get('baseHeight', TJSONFloat(0));
    // Absent in a sidecar written before the field existed, which reads
    // as "not measured" and is exactly what a zero means anyway.
    Candidate.MenuBarInset := AObject.Get('menuBarInset', TJSONFloat(0));
    if ParseSidecarCursorRender(AObject.Get('cursor', 'system'), Render) then
      Candidate.CursorRender := Render;
    Candidate.BakedZoomOnClick := AObject.Get('bakedZoomOnClick', False);
    Candidate.BakedFollowMouse := AObject.Get('bakedFollowMouse', False);
    Candidate.BakedWindowFollow := AObject.Get('bakedWindowFollow', False);
    if ParseAudioMode(AObject.Get('audio', 'none'), Mode) then
      Candidate.AudioMode := Mode;
    // The header is committed only once every number in it is a real
    // one — see IsFiniteNumber. A half-applied header would be worse
    // than none: BaseWidth seeds every sample's carried-forward source
    // rectangle, and MaxInterpolatedGap divides by SampleHz.
    if not AllFinite([Candidate.SampleHz, Candidate.DisplayWidth,
      Candidate.DisplayHeight, Candidate.BaseX, Candidate.BaseY,
      Candidate.BaseWidth, Candidate.BaseHeight,
      Candidate.MenuBarInset]) then
      Exit(False);
    FHeader := Candidate;
    FHasHeader := True;
    Exit(True);
  end;
  if Kind = 'anchor' then
  begin
    Anchor := AObject.Get('host', TJSONFloat(0));
    if not IsFiniteNumber(Anchor) then
      Exit(False);
    FAnchorHost := Anchor;
    FHasAnchor := True;
    Exit(True);
  end;
  if Kind = 'cursor' then
  begin
    Sample.Time := AObject.Get('t', TJSONFloat(0));
    Sample.X := AObject.Get('x', TJSONFloat(0));
    Sample.Y := AObject.Get('y', TJSONFloat(0));
    if not ReadIntegerField(AObject, 'b', 0, Low(Integer),
      High(Integer), Whole) then
      Exit(False);
    Sample.Buttons := Integer(Whole);
    // The source rectangle is DELTA-ENCODED: WriteSample emits
    // sx/sy/sw/sh only on a sample that moves them, so a record naming
    // none inherits the one in force. That state is kept in FCarrySource*
    // and NOT read back off the last accepted sample, because a record
    // can carry a new rectangle and still be dropped — the stamp rule
    // below refuses one whose time does not advance — and the rectangle
    // it announced is still what the capture was reading from that
    // moment on. Read it off FSamples and one dropped line silently
    // reframes the whole rest of the take: two files differing only in a
    // duplicate stamp rendered to different pictures.
    if not FHasCarrySource then
    begin
      // Seeded from the header the first time a cursor record is read,
      // which is where the base rectangle is: it IS the source rectangle
      // until a sample says otherwise, exactly as the writer assumes.
      FCarrySourceX := FHeader.BaseX;
      FCarrySourceY := FHeader.BaseY;
      FCarrySourceWidth := FHeader.BaseWidth;
      FCarrySourceHeight := FHeader.BaseHeight;
      FHasCarrySource := True;
    end;
    Sample.SourceX := AObject.Get('sx', TJSONFloat(FCarrySourceX));
    Sample.SourceY := AObject.Get('sy', TJSONFloat(FCarrySourceY));
    Sample.SourceWidth := AObject.Get('sw', TJSONFloat(FCarrySourceWidth));
    Sample.SourceHeight := AObject.Get('sh',
      TJSONFloat(FCarrySourceHeight));
    // A sample with an infinity in it poisons everything downstream: the
    // binary search in StateAt, the interpolation across it, and the
    // source rectangle every later sample carries forward from it. It is
    // dropped, and the drop is a skipped line like any other — and the
    // carried rectangle is left exactly as it was, because an infinite
    // one is the single thing that must never be carried.
    if not AllFinite([Sample.Time, Sample.X, Sample.Y, Sample.SourceX,
      Sample.SourceY, Sample.SourceWidth, Sample.SourceHeight]) then
      Exit(False);
    // Folded in BEFORE the stamp rule, and that order is the point: a
    // dropped record's rectangle is still a fact about the capture.
    FCarrySourceX := Sample.SourceX;
    FCarrySourceY := Sample.SourceY;
    FCarrySourceWidth := Sample.SourceWidth;
    FCarrySourceHeight := Sample.SourceHeight;
    // The track is a TIME SERIES, and every reader downstream depends on
    // that: StateAt binary-searches it, InterpolatePath walks it, and
    // SmoothSidecarPath slides one window along it. A sample whose stamp
    // does not advance is not a later position, it is a contradiction —
    // and a file full of them made the smoothing quadratic; the measured
    // before and after are in docs/event-sidecar.md, *Sampling*, which
    // is the one place they are stated. Dropped as a skipped line, like
    // any other line the reader cannot use, so the count still says how
    // much of the file was not believed.
    if (FSampleCount > 0)
      and not SidecarSampleTimeAdvances(FSamples[FSampleCount - 1].Time,
      Sample.Time) then
      Exit(False);
    AddSample(Sample);
    Exit(True);
  end;
  if Kind = 'button' then
  begin
    Button.Time := AObject.Get('t', TJSONFloat(0));
    Button.X := AObject.Get('x', TJSONFloat(0));
    Button.Y := AObject.Get('y', TJSONFloat(0));
    if not ReadIntegerField(AObject, 'n', 0, Low(Integer),
      High(Integer), Whole) then
      Exit(False);
    Button.Button := Integer(Whole);
    Button.Down := AObject.Get('d', False);
    if not AllFinite([Button.Time, Button.X, Button.Y]) then
      Exit(False);
    AddButton(Button);
    Exit(True);
  end;
  if Kind = 'trailer' then
  begin
    Trailer.Time := AObject.Get('t', TJSONFloat(0));
    if not ReadIntegerField(AObject, 'frames', 0, 0,
      Round(MaxExactIntegerInDouble), Whole) then
      Exit(False);
    Trailer.Frames := Whole;
    Trailer.DurationSeconds := AObject.Get('duration', TJSONFloat(0));
    if not ReadIntegerField(AObject, 'samples', 0, 0,
      Round(MaxExactIntegerInDouble), Whole) then
      Exit(False);
    Trailer.Samples := Whole;
    Trailer.Recovered := AObject.Get('recovered', False);
    if not AllFinite([Trailer.Time, Trailer.DurationSeconds]) then
      Exit(False);
    FTrailer := Trailer;
    FHasTrailer := True;
    Exit(True);
  end;
end;

// The three parts every load is made of, so a load from a file and a
// load from a string in memory are the same reader driven by two
// different sources rather than two readers that have to agree.
procedure TSidecarLog.BeginLoad;
begin
  // Every scrap of per-load state, and the header with it. A TSidecarLog
  // is loaded more than once in a couple of places, and a header left
  // standing from the previous file is the worst kind of stale: it names
  // the wrong movie, it seeds the wrong base rectangle into every sample
  // that does not carry one, and a file with no header at all would
  // silently inherit the last one's baked-effect flags.
  FHeader := Default(TSidecarHeader);
  FHeader.Version := SidecarFormatVersion;
  FHeader.SampleHz := DefaultSidecarSampleHz;
  FSampleCount := 0;
  FButtonCount := 0;
  FCarrySourceX := 0;
  FCarrySourceY := 0;
  FCarrySourceWidth := 0;
  FCarrySourceHeight := 0;
  FHasCarrySource := False;
  FSkippedLines := 0;
  FHasAnchor := False;
  FAnchorHost := 0;
  FHasTrailer := False;
  FTrailer := Default(TSidecarTrailer);
  FTooNew := False;
  FHasHeader := False;
  FForeignFormat := False;
  FForeignFormatName := '';
end;

// One line. False when there is no point reading any more of the file:
// a header-only load has its header, or the header itself was refused.
function TSidecarLog.ConsumeLine(const ALine: string;
  AMode: TSidecarLoadMode): Boolean;
var
  Line: string;
  Data: TJSONData;
begin
  Result := True;
  Line := Trim(ALine);
  if Line = '' then
    Exit;
  // Measured before the parser is allowed near it: fpjson recurses,
  // and a deep enough line is a stack overflow rather than an
  // exception. See MaxSidecarLineDepth.
  if not SidecarLineWithinLimits(Line) then
  begin
    Inc(FSkippedLines);
    Exit;
  end;
  Data := nil;
  // The guard covers the READ as well as the parse, and that is the
  // structural half of this rule rather than a belt on a brace.
  //
  // It used to wrap `GetJSON` alone, on the reasoning that parsing is
  // where a malformed line bites. It is not: fpjson hands back a
  // document happily and the coercions in ReadObject are where a
  // number that is not a number raises — measured, an
  // EAccessViolation out of `Get('fps', 0)` on a `1e999`, escaping
  // LoadFromFile, killing the process and leaking the document with
  // it. Every field is checked below now, but the checks are a list
  // and lists go stale; this is the rule that does not. Anything
  // that raises anywhere in a line's reading is a skipped line, for
  // ever, including whatever a future record kind does.
  try
    try
      Data := GetJSON(Line);
      if (Data <> nil) and (Data is TJSONObject) then
      begin
        if not ReadObject(TJSONObject(Data)) then
          Inc(FSkippedLines);
      end
      else
        Inc(FSkippedLines);
    except
      // A half-written last line, a line from a newer writer this
      // parser cannot make sense of, or a value that blew up on the
      // way out. Counted, never fatal — that is the whole reason the
      // format is one object per line.
      on Exception do
        Inc(FSkippedLines);
    end;
  finally
    // In a finally, not after the read: the read can now be left
    // early by an exception, and the document is ours either way.
    Data.Free;
  end;
  // A header-only load stops at the header, which is the first line of
  // every sidecar this program writes. That is the whole point of it:
  // `knips export` asks one header field of a movie's sidecar before a
  // trim, and used to parse the entire track — hundreds of thousands of
  // samples — to read one word out of line one.
  if AMode = slmHeaderOnly then
    Result := not (FHasHeader or FForeignFormat or FTooNew);
end;

function TSidecarLog.FinishLoad(out AError: string): Boolean;
begin
  AError := '';
  // The blunter refusal first: a file that is not one of these at all
  // has no version worth reporting.
  if FForeignFormat then
  begin
    if FForeignFormatName = '' then
      AError := 'this is not a knips event sidecar: its header names no '
        + 'format at all, and this reader wants "' + SidecarFormatName + '"'
    else
      AError := Format('this is not a knips event sidecar: its header '
        + 'says format "%s", not "%s"',
        [FForeignFormatName, SidecarFormatName]);
    Exit(False);
  end;
  if FTooNew then
  begin
    AError := Format('this event sidecar is version %d and this knips '
      + 'reads version %d', [FHeader.Version, SidecarFormatVersion]);
    Exit(False);
  end;
  Result := True;
end;

function TSidecarLog.LoadFromText(const AText: string;
  out AError: string): Boolean;
var
  Lines: TStringList;
  I: Integer;
begin
  BeginLoad;
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for I := 0 to Lines.Count - 1 do
      if not ConsumeLine(Lines[I], slmWholeTrack) then
        Break;
  finally
    Lines.Free;
  end;
  Result := FinishLoad(AError);
end;

function TSidecarLog.LoadFromFile(const APath: string;
  out AError: string): Boolean;
begin
  Result := LoadFromFile(APath, slmWholeTrack, AError);
end;

function TSidecarLog.LoadFromFile(const APath: string;
  AMode: TSidecarLoadMode; out AError: string): Boolean;
var
  Stream: TFileStream;
  Reader: TSidecarLineReader;
  Line: string;
begin
  Result := False;
  AError := '';
  if not FileExists(APath) then
  begin
    AError := 'no event sidecar at ' + APath;
    Exit;
  end;
  Stream := nil;
  try
    try
      Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    except
      on E: Exception do
      begin
        AError := E.Message;
        Exit;
      end;
    end;
    if Stream.Size > MaxSidecarBytes then
    begin
      AError := Format('%s is %d MB; this reader will not load an event '
        + 'sidecar past %d MB', [APath, Stream.Size div (1024 * 1024),
        MaxSidecarBytes div (1024 * 1024)]);
      Exit;
    end;
    BeginLoad;
    // One line at a time, off the stream. It used to be a TStringList
    // loaded from the file, then `.Text` (a second whole copy), then a
    // SECOND TStringList parsed out of that — three passes and about ten
    // times the file's size resident, for a format that is read strictly
    // forwards one line at a time.
    Reader := TSidecarLineReader.Create(Stream);
    try
      try
        while Reader.NextLine(Line) do
          if not ConsumeLine(Line, AMode) then
            Break;
      except
        on E: Exception do
        begin
          AError := E.Message;
          Exit;
        end;
      end;
    finally
      Reader.Free;
    end;
    Result := FinishLoad(AError);
  finally
    Stream.Free;
  end;
end;

function TSidecarLog.MovieSeconds(AHostSeconds: Double): Double;
begin
  if not FHasAnchor then
    Exit(0);
  Result := AHostSeconds - FAnchorHost;
end;

function TSidecarLog.StateAt(AMovieSeconds: Double;
  out ASample: TSidecarSample): Boolean;
var
  Low, High, Middle: Integer;
  Target, Span, Fraction: Double;
begin
  ASample := Default(TSidecarSample);
  Result := (FSampleCount > 0) and FHasAnchor;
  if not Result then
    Exit;
  Target := FAnchorHost + AMovieSeconds;
  if Target <= FSamples[0].Time then
  begin
    ASample := FSamples[0];
    Exit;
  end;
  if Target >= FSamples[FSampleCount - 1].Time then
  begin
    ASample := FSamples[FSampleCount - 1];
    Exit;
  end;
  // The samples are written in time order by construction, so this is a
  // binary search rather than a scan: an export asks once per output
  // frame and a long take has tens of thousands of samples.
  Low := 0;
  High := FSampleCount - 1;
  while High - Low > 1 do
  begin
    Middle := (Low + High) div 2;
    if FSamples[Middle].Time <= Target then
      Low := Middle
    else
      High := Middle;
  end;
  ASample := FSamples[Low];
  Span := FSamples[High].Time - FSamples[Low].Time;
  // The same refusal InterpolatePath makes, for the same reason: a gap
  // this reader has no business drawing a line through leaves the
  // earlier sample's position standing. The source rectangle was never
  // interpolated in the first place — it is what the capture was
  // reading, and a rectangle half way between two of them was never
  // read at all.
  if (Span > 0) and (Span <= MaxInterpolatedGap) then
  begin
    Fraction := (Target - FSamples[Low].Time) / Span;
    ASample.X := FSamples[Low].X
      + (FSamples[High].X - FSamples[Low].X) * Fraction;
    ASample.Y := FSamples[Low].Y
      + (FSamples[High].Y - FSamples[Low].Y) * Fraction;
  end;
  ASample.Time := Target;
end;

function TSidecarLog.MaxInterpolatedGap: Double;
begin
  // A header with no sample rate in it — an older writer, or a file from
  // something else — gets the floor rather than a division.
  //
  // The guard is a FLOOR on the rate and not merely `> 0`, because this
  // number came out of a file: one sample a minute is 0.0167 Hz, and
  // anything below that is not a claim about sampling but a damaged or
  // hostile header. Dividing by a denormal overflows before the cap
  // below ever sees the answer (measured, when a parser bug fed this a
  // rate of 1.5E-322: an access violation, not a large number).
  Result := MinInterpolatedGapSeconds;
  if FHeader.SampleHz >= MinBelievableSampleHz then
    Result := Max(Result, InterpolatedGapSamples / FHeader.SampleHz);
  Result := Min(MaxInterpolatedGapSeconds, Result);
end;

function TSidecarLog.CursorAt(AMovieSeconds: Double;
  out AX, AY: Double): Boolean;
var
  Found: TSidecarSample;
begin
  AX := 0;
  AY := 0;
  Result := StateAt(AMovieSeconds, Found);
  if not Result then
    Exit;
  AX := Found.X;
  AY := Found.Y;
end;

function InterpolatePath(const ASamples: TSidecarSampleArray;
  ACount: Integer; ATime, AMaxGapSeconds: Double;
  out AX, AY: Double): Boolean;
var
  Low, High, Middle: Integer;
  Span, Fraction: Double;
begin
  AX := 0;
  AY := 0;
  Result := ACount > 0;
  if not Result then
    Exit;
  if ATime <= ASamples[0].Time then
  begin
    AX := ASamples[0].X;
    AY := ASamples[0].Y;
    Exit;
  end;
  if ATime >= ASamples[ACount - 1].Time then
  begin
    AX := ASamples[ACount - 1].X;
    AY := ASamples[ACount - 1].Y;
    Exit;
  end;
  Low := 0;
  High := ACount - 1;
  while High - Low > 1 do
  begin
    Middle := (Low + High) div 2;
    if ASamples[Middle].Time <= ATime then
      Low := Middle
    else
      High := Middle;
  end;
  Span := ASamples[High].Time - ASamples[Low].Time;
  // Too long a silence to draw a line through — see the header. The
  // earlier sample is the last thing the track actually knows.
  if (Span <= 0) or ((AMaxGapSeconds > 0) and (Span > AMaxGapSeconds)) then
  begin
    AX := ASamples[Low].X;
    AY := ASamples[Low].Y;
    Exit;
  end;
  Fraction := (ATime - ASamples[Low].Time) / Span;
  AX := ASamples[Low].X + (ASamples[High].X - ASamples[Low].X) * Fraction;
  AY := ASamples[Low].Y + (ASamples[High].Y - ASamples[Low].Y) * Fraction;
end;

function HasUntouchedFraming(const AHeader: TSidecarHeader): Boolean;
begin
  Result := not AHeader.BakedZoomOnClick and not AHeader.BakedFollowMouse
    and not AHeader.BakedWindowFollow;
end;

function IsRawTake(const AHeader: TSidecarHeader): Boolean;
begin
  Result := (AHeader.CursorRender in [scrNone, scrSmooth])
    and HasUntouchedFraming(AHeader);
end;

function AvailableExportEffects(
  const ALog: TSidecarLog): TSidecarEffectAvailability;
var
  Mappable: Boolean;
begin
  Result := Default(TSidecarEffectAvailability);
  if ALog = nil then
  begin
    Result.Reason := 'there is no event sidecar for this recording';
    Exit;
  end;
  Result.CursorAlreadyBaked :=
    ALog.Header.CursorRender in [scrSystem, scrBaked];
  // A window capture's frames are a picture of something that moved under
  // the recorder, so no sample can be placed in them at all. Everything
  // below needs the mapping.
  Mappable := (ALog.Header.TargetKind <> ctkWindow)
    and ALog.HasAnchor and (ALog.SampleCount > 0)
    and (ALog.Header.BaseWidth > 0) and (ALog.Header.BaseHeight > 0);
  if not Mappable then
  begin
    // A window take reaches this only when it was captured the
    // desktop-independent way, and the app does that only when the user
    // asked for no effects at all — so the actionable half of the truth
    // is what to do about it, not the framework detail behind it. The
    // detail is still there, because somebody reading a sidecar by hand
    // needs to know why the samples cannot be placed.
    if ALog.Header.TargetKind = ctkWindow then
      Result.Reason := 'this window recording was made with the effects '
        + 'switched off, so it was captured as the window alone — which '
        + 'is the cleaner picture, and the one kind of take nothing can '
        + 'be drawn into afterwards (its frames have no fixed '
        + 'relationship to the screen the pointer was measured against). '
        + 'Record it again with an effect switched on for one that can '
        + 'be edited'
    else if not ALog.HasAnchor then
      Result.Reason := 'the event sidecar has no anchor, so its times '
        + 'cannot be placed on the movie'
    else if ALog.SampleCount = 0 then
      Result.Reason := 'the event sidecar has no pointer samples'
    else
      // The rectangle the recording was sized from is what every point
      // in the file is measured against, and the mapping in
      // docs/event-sidecar.md divides by its width and height. A zero
      // one is a header that cannot place its own samples — an older
      // or third-party writer that left the fields out, or a window
      // take's header being read past the arm above.
      Result.Reason := 'the event sidecar records no recorded rectangle '
        + '(its base width or height is zero), so its samples cannot be '
        + 'mapped into the movie''s pixels';
    Exit;
  end;
  Result.CanDrawCursor := not Result.CursorAlreadyBaked;
  Result.FullyRenderable := IsRawTake(ALog.Header);
  // A live zoom is the one thing that closes this, because a crop
  // applied to a crop compounds into a zoom nobody asked for and nothing
  // can take the first one out again.
  //
  // A **panned** framing does not close it any more, and that is a
  // change worth being explicit about. It used to, and for the code that
  // existed the refusal was right: the crop was computed against the
  // recording's base rectangle, so a Follow Mouse take rendered
  // mis-cropped frames (measured: 36 of them). The answer is the
  // composition rather than the refusal — the crop is taken inside the
  // rectangle the capture was reading at that instant, which every
  // sample records, exactly as the live effect composes zoom inside
  // follow (Knips.Recording.LiveMath). See
  // Knips.Export.ZoomTrack.ZoomWalkerSourceRectIn.
  //
  // A pointer already baked into the pixels does not close it either:
  // that pointer is part of the picture and scales with the crop exactly
  // as the live effect's would have. So an ordinary `knips record` take
  // can still be zoomed, and so can a Follow Mouse take and a
  // composited window recording.
  Result.CanZoomOnClick := (ALog.ButtonCount > 0)
    and not ALog.Header.BakedZoomOnClick;

  // Per effect first, because each has exactly one answer.
  if not Result.CanDrawCursor then
    Result.CursorReason := 'the pointer is already in this recording''s '
      + 'pixels';
  if ALog.Header.BakedZoomOnClick then
    Result.ZoomReason := 'this recording already zooms: the capture '
      + 'itself followed the clicks'
  else if ALog.ButtonCount = 0 then
    Result.ZoomReason := 'nothing was clicked during this recording';

  // Then the summary, ordered by consequence, most limiting first,
  // because one string can only carry one fact. A pointer already in the
  // pixels closes the most; a framing the capture baked in closes the
  // next; "nothing was clicked" is last because it is a fact about the
  // CONTENT rather than a limit on what may be done to it — a take with
  // no clicks is otherwise completely open.
  if Result.CursorReason <> '' then
    Result.Reason := Result.CursorReason
  else if ALog.Header.BakedZoomOnClick then
    Result.Reason := Result.ZoomReason
  else if not Result.FullyRenderable then
    // Reachable on its own: a take whose pointer can still be drawn and
    // whose clicks are still usable, but whose framing was panned by the
    // capture. That pan is in the pixels for good — it decided which
    // pixels were read off the screen at all — so the take is not
    // *fully* renderable even though both effects are open; a zoom is
    // composed inside the pan rather than replacing it.
    Result.Reason := 'this recording''s framing was panned by the capture, '
      + 'so the pan is in its pixels for good; a zoom is composed inside '
      + 'it rather than replacing it'
  else
    Result.Reason := Result.ZoomReason;
end;

function SmoothSidecarPath(const ASamples: TSidecarSampleArray;
  ACount: Integer; AWindowSeconds: Double): TSidecarSampleArray;
var
  I, Low, High: Integer;
  Half: Double;
  PrefixX, PrefixY: array of Double;
  Used: Integer;
begin
  // Assigned rather than SetLength'd to zero, so the compiler can see
  // the managed result initialised on every path — the one
  // project-owned warning left in the build after the hotkey guard
  // became a compile-time check.
  Result := nil;
  if ACount <= 0 then
    Exit;
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := ASamples[I];
  if AWindowSeconds <= 0 then
    Exit;
  Half := AWindowSeconds / 2;
  // Prefix sums, so a window of any width costs two subtractions
  // rather than a walk. Written this way because the walk was
  // quadratic on a track whose stamps do not advance — see the
  // monotonicity gate in ReadObject, which is what makes the two
  // pointers below sound.
  SetLength(PrefixX, ACount + 1);
  SetLength(PrefixY, ACount + 1);
  PrefixX[0] := 0;
  PrefixY[0] := 0;
  for I := 0 to ACount - 1 do
  begin
    PrefixX[I + 1] := PrefixX[I] + ASamples[I].X;
    PrefixY[I + 1] := PrefixY[I] + ASamples[I].Y;
  end;
  Low := 0;
  High := 0;
  for I := 0 to ACount - 1 do
  begin
    // Both bounds only ever move forward, which is what makes the whole
    // pass linear: on a track whose stamps advance, the window for
    // sample I + 1 starts no earlier and ends no earlier than I's. Low
    // needs no catch-up clamp of its own — the loop below only advances
    // it while it is still behind I, so it can never pass I — and the
    // one that stood here was dead code claiming otherwise.
    while (Low < I) and (ASamples[I].Time - ASamples[Low].Time > Half) do
      Inc(Low);
    if High < I then
      High := I;
    while (High + 1 < ACount)
      and (ASamples[High + 1].Time - ASamples[I].Time <= Half) do
      Inc(High);
    Used := High - Low + 1;
    if Used > 0 then
    begin
      Result[I].X := (PrefixX[High + 1] - PrefixX[Low]) / Used;
      Result[I].Y := (PrefixY[High + 1] - PrefixY[Low]) / Used;
    end;
  end;
end;

initialization
  GInvariant := InvariantSettings;

end.

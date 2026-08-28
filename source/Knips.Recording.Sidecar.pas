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
    FSkippedLines: Integer;
    FTooNew: Boolean;
    procedure AddSample(const ASample: TSidecarSample);
    procedure AddButton(const AEvent: TSidecarButtonEvent);
    function ReadObject(AObject: TJSONObject): Boolean;
  public
    constructor Create;
    // False with a message when the file cannot be read at all. A file
    // whose *last* line is half-written still loads: the truncated line is
    // counted in SkippedLines and everything before it is kept, which is
    // the whole reason the format is one object per line.
    function LoadFromFile(const APath: string; out AError: string): Boolean;
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
    // be able to talk this reader into a five-minute straight line. See InterpolatePath for why the
    // limit exists at all; a caller drawing a pointer from this track
    // should pass this to it.
    function MaxInterpolatedGap: Double;
    property Header: TSidecarHeader read FHeader;
    property HasAnchor: Boolean read FHasAnchor;
    property AnchorHost: Double read FAnchorHost;
    property HasTrailer: Boolean read FHasTrailer;
    property Trailer: TSidecarTrailer read FTrailer;
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
  end;

// `demo.mp4` -> `demo.knips.jsonl`. The movie's own extension is replaced,
// so `.mov` and `.mp4` recordings of the same stem would collide — which
// is exactly right: they are the same take written twice, and the second
// one's sidecar should replace the first's.
function SidecarPathFor(const AMoviePath: string): string;

function SidecarTargetName(ATarget: TCaptureTargetKind): string;

// JSON string escaping, exposed because it is the one place a file name
// can break the format: a movie called `say "hi".mp4` is a legal file
// name and an illegal JSON string until this has run over it.
function QuoteJsonString(const AText: string): string;

function SidecarCursorRenderName(ARender: TSidecarCursorRender): string;

function ParseSidecarCursorRender(const AText: string;
  out ARender: TSidecarCursorRender): Boolean;

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

function SidecarPathFor(const AMoviePath: string): string;
begin
  if AMoviePath = '' then
    Exit('');
  Result := ChangeFileExt(AMoviePath, SidecarExtension);
end;

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
  Render: TSidecarCursorRender;
  Mode: TAudioMode;
  DefaultHz: TJSONFloat;
begin
  Result := False;
  Kind := AObject.Get('k', '');
  if Kind = 'header' then
  begin
    if AObject.Get('format', '') <> SidecarFormatName then
      Exit;
    FHeader.Version := AObject.Get('version', 0);
    if FHeader.Version > SidecarFormatVersion then
    begin
      FTooNew := True;
      Exit(True);
    end;
    FHeader.KnipsVersion := AObject.Get('knips', '');
    FHeader.MovieName := AObject.Get('movie', '');
    FHeader.CreatedUtc := AObject.Get('created', '');
    FHeader.ProcessID := AObject.Get('pid', 0);
    if AObject.Get('target', 'display') = 'window' then
      FHeader.TargetKind := ctkWindow
    else
      FHeader.TargetKind := ctkDisplay;
    FHeader.PixelWidth := AObject.Get('pixelWidth', 0);
    FHeader.PixelHeight := AObject.Get('pixelHeight', 0);
    FHeader.Scale := AObject.Get('scale', 0);
    FHeader.FramesPerSecond := AObject.Get('fps', 0);
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
    FHeader.SampleHz := AObject.Get('sampleHz', DefaultHz);
    FHeader.DisplayID := Cardinal(AObject.Get('displayId', Int64(0)));
    FHeader.DisplayWidth := AObject.Get('displayWidth', TJSONFloat(0));
    FHeader.DisplayHeight := AObject.Get('displayHeight', TJSONFloat(0));
    FHeader.BaseX := AObject.Get('baseX', TJSONFloat(0));
    FHeader.BaseY := AObject.Get('baseY', TJSONFloat(0));
    FHeader.BaseWidth := AObject.Get('baseWidth', TJSONFloat(0));
    FHeader.BaseHeight := AObject.Get('baseHeight', TJSONFloat(0));
    // Absent in a sidecar written before the field existed, which reads
    // as "not measured" and is exactly what a zero means anyway.
    FHeader.MenuBarInset := AObject.Get('menuBarInset', TJSONFloat(0));
    if ParseSidecarCursorRender(AObject.Get('cursor', 'system'), Render) then
      FHeader.CursorRender := Render;
    FHeader.BakedZoomOnClick := AObject.Get('bakedZoomOnClick', False);
    FHeader.BakedFollowMouse := AObject.Get('bakedFollowMouse', False);
    FHeader.BakedWindowFollow := AObject.Get('bakedWindowFollow', False);
    if ParseAudioMode(AObject.Get('audio', 'none'), Mode) then
      FHeader.AudioMode := Mode;
    Exit(True);
  end;
  if Kind = 'anchor' then
  begin
    FAnchorHost := AObject.Get('host', TJSONFloat(0));
    FHasAnchor := True;
    Exit(True);
  end;
  if Kind = 'cursor' then
  begin
    Sample.Time := AObject.Get('t', TJSONFloat(0));
    Sample.X := AObject.Get('x', TJSONFloat(0));
    Sample.Y := AObject.Get('y', TJSONFloat(0));
    Sample.Buttons := AObject.Get('b', 0);
    // Carried forward from the last sample that named one; the header's
    // base rectangle seeded that in LoadFromText.
    Sample.SourceX := AObject.Get('sx', TJSONFloat(FHeader.BaseX));
    Sample.SourceY := AObject.Get('sy', TJSONFloat(FHeader.BaseY));
    Sample.SourceWidth := AObject.Get('sw', TJSONFloat(FHeader.BaseWidth));
    Sample.SourceHeight := AObject.Get('sh', TJSONFloat(FHeader.BaseHeight));
    if FSampleCount > 0 then
    begin
      if AObject.Find('sx') = nil then
        Sample.SourceX := FSamples[FSampleCount - 1].SourceX;
      if AObject.Find('sy') = nil then
        Sample.SourceY := FSamples[FSampleCount - 1].SourceY;
      if AObject.Find('sw') = nil then
        Sample.SourceWidth := FSamples[FSampleCount - 1].SourceWidth;
      if AObject.Find('sh') = nil then
        Sample.SourceHeight := FSamples[FSampleCount - 1].SourceHeight;
    end;
    AddSample(Sample);
    Exit(True);
  end;
  if Kind = 'button' then
  begin
    Button.Time := AObject.Get('t', TJSONFloat(0));
    Button.X := AObject.Get('x', TJSONFloat(0));
    Button.Y := AObject.Get('y', TJSONFloat(0));
    Button.Button := AObject.Get('n', 0);
    Button.Down := AObject.Get('d', False);
    AddButton(Button);
    Exit(True);
  end;
  if Kind = 'trailer' then
  begin
    FTrailer.Time := AObject.Get('t', TJSONFloat(0));
    FTrailer.Frames := AObject.Get('frames', Int64(0));
    FTrailer.DurationSeconds := AObject.Get('duration', TJSONFloat(0));
    FTrailer.Samples := AObject.Get('samples', Int64(0));
    FTrailer.Recovered := AObject.Get('recovered', False);
    FHasTrailer := True;
    Exit(True);
  end;
end;

function TSidecarLog.LoadFromText(const AText: string;
  out AError: string): Boolean;
var
  Lines: TStringList;
  I: Integer;
  Line: string;
  Data: TJSONData;
begin
  AError := '';
  FSampleCount := 0;
  FButtonCount := 0;
  FSkippedLines := 0;
  FHasAnchor := False;
  FHasTrailer := False;
  FTooNew := False;
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if Line = '' then
        Continue;
      Data := nil;
      try
        Data := GetJSON(Line);
      except
        // A half-written last line, or a line from a newer writer that
        // this parser cannot make sense of. Counted, never fatal — that
        // is the whole reason the format is one object per line.
        on Exception do
          Data := nil;
      end;
      if (Data <> nil) and (Data is TJSONObject) then
      begin
        if not ReadObject(TJSONObject(Data)) then
          Inc(FSkippedLines);
      end
      else
        Inc(FSkippedLines);
      Data.Free;
    end;
  finally
    Lines.Free;
  end;
  if FTooNew then
  begin
    AError := Format('this event sidecar is version %d and this knips '
      + 'reads version %d', [FHeader.Version, SidecarFormatVersion]);
    Exit(False);
  end;
  Result := True;
end;

function TSidecarLog.LoadFromFile(const APath: string;
  out AError: string): Boolean;
var
  Text: TStringList;
begin
  Result := False;
  AError := '';
  if not FileExists(APath) then
  begin
    AError := 'no event sidecar at ' + APath;
    Exit;
  end;
  Text := TStringList.Create;
  try
    try
      Text.LoadFromFile(APath);
    except
      on E: Exception do
      begin
        AError := E.Message;
        Exit;
      end;
    end;
    Result := LoadFromText(Text.Text, AError);
  finally
    Text.Free;
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
    else
      Result.Reason := 'the event sidecar has no pointer samples';
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
  I, J: Integer;
  Half, SumX, SumY: Double;
  Used: Integer;
begin
  SetLength(Result, 0);
  if ACount <= 0 then
    Exit;
  SetLength(Result, ACount);
  if AWindowSeconds <= 0 then
  begin
    for I := 0 to ACount - 1 do
      Result[I] := ASamples[I];
    Exit;
  end;
  Half := AWindowSeconds / 2;
  for I := 0 to ACount - 1 do
  begin
    Result[I] := ASamples[I];
    SumX := 0;
    SumY := 0;
    Used := 0;
    // Walk out from I in both directions until the window runs out. The
    // samples are evenly spaced in practice, so this is a handful of
    // steps; it is written as a walk rather than a fixed index offset
    // because a stalled run loop leaves real gaps in the track and a
    // fixed offset would then average over a much wider time than asked.
    J := I;
    while (J >= 0) and (ASamples[I].Time - ASamples[J].Time <= Half) do
    begin
      SumX := SumX + ASamples[J].X;
      SumY := SumY + ASamples[J].Y;
      Inc(Used);
      Dec(J);
    end;
    J := I + 1;
    while (J < ACount) and (ASamples[J].Time - ASamples[I].Time <= Half) do
    begin
      SumX := SumX + ASamples[J].X;
      SumY := SumY + ASamples[J].Y;
      Inc(Used);
      Inc(J);
    end;
    if Used > 0 then
    begin
      Result[I].X := SumX / Used;
      Result[I].Y := SumY / Used;
    end;
  end;
end;

initialization
  GInvariant := InvariantSettings;

end.

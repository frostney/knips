unit Knips.Options;

// Recording and export options as the CLI hands them to the recorder
// and the exporter: what to capture, at what rate, into which
// container; and which movie to turn into which GIF. Everything here is
// platform-neutral and unit-tested; the macOS layer only consumes the
// validated records.

{$I Knips.inc}

interface

uses
  SysUtils;

const
  DefaultFramesPerSecond = 30;
  MinFramesPerSecond = 1;
  MaxFramesPerSecond = 120;
  // H.264 needs even dimensions; the capture size is rounded down to them.
  DimensionAlignment = 2;
  // Bits per pixel per frame the auto bit-rate budgets. 0.09 lands near
  // 12 Mbit/s for a 2560x1440 Retina-halved capture at 30 fps.
  AutoBitsPerPixelPerFrame = 0.09;
  MinBitRate = 1000000;
  MaxBitRate = 60000000;
  // 0 = detect the display's backing scale factor at capture time.
  ScaleAuto = 0;
  // The same number as text, and the compile-time check that keeps the
  // two together, so the refusal below can be a CONSTANT sentence — the
  // MCP rewriter's table is a const array and cannot call Format, and
  // it used to carry the number as a literal of its own.
  ScaleAutoText = '0';
  // The refusal --scale produces, without the offending value. Both the
  // producer and Knips.Mcp.Params's rewrite table name this, so they
  // cannot say different things about the same flag.
  ScaleRefusal = '--scale must be 1, 2, or ' + ScaleAutoText + ' for auto';
  // What --display means when it was not given: whichever display the
  // system calls the main one. The one negative index that means
  // anything, which is why it has a name.
  MainDisplayIndex = -1;
  MaxScale = 2;
  // Audio defaults. ScreenCaptureKit delivers system audio at whatever
  // sample rate and channel count the stream configuration asks for;
  // 48 kHz stereo is what the mixer runs at, so nothing is resampled.
  // The microphone output ignores these and arrives in the device's own
  // native format; they are the AAC track's format, and AVAssetWriter's
  // encoder converts into it.
  DefaultAudioSampleRate = 48000;
  MinAudioSampleRate = 8000;
  MaxAudioSampleRate = 192000;
  DefaultAudioChannelCount = 2;
  MinAudioChannelCount = 1;
  MaxAudioChannelCount = 2;
  // 128 kbit/s AAC: transparent enough for narration and interface sound.
  DefaultAudioBitRate = 128000;
  MinAudioBitRate = 32000;
  MaxAudioBitRate = 320000;
  // Bumped once per release that changes the CLI surface.
  KnipsVersion = '0.1.0';

  // What the raw take beside a deliverable is called. A recording writes
  // `<name>-raw.mp4` and the render writes `<name>.mp4` beside it; the
  // sidecar's own extension rule then puts `<name>-raw.knips.jsonl` and
  // `<name>.knips.jsonl` under each of them, so a directory of takes
  // still sorts into pairs.
  RawTakeSuffix = '-raw';
  // What a render in progress is called before it is renamed onto the
  // deliverable's name. Here rather than in the render unit because two
  // units have to agree on it: the one that writes it, and the crash
  // recovery pass that sweeps the ones a killed render left behind.
  //
  // Every writer that can replace a file the user already has builds
  // through one of these — the MP4 render, the GIF and APNG exports and
  // the passthrough trim — so a Ctrl-C can never leave the previous
  // good file half-overwritten.
  RenderTemporarySuffix = '.knips-render-tmp';

  // The four extensions this program reads and writes.
  //
  // Here rather than higher up because this is the unit that DECIDES
  // what an extension means — ContainerForPath and ExportFormatForPath
  // are both below — and the literals were repeated there while named
  // constants for two of them sat in units this one cannot see
  // (Knips.App.State's GifFileExtension, Knips.Mcp.Params's
  // ApngFileExtension). Those two now name these.
  Mpeg4FileExtension = '.mp4';
  QuickTimeFileExtension = '.mov';
  GifFileExtension = '.gif';
  ApngFileExtension = '.apng';
  // What is written beside a temporary to say which process owns it:
  // one line, the pid. The sweep reads it and leaves a temporary whose
  // owner is still running alone — before this existed the sweep at
  // every `record` and every app launch deleted a LIVE render's
  // temporary out from under it.
  RenderTemporaryOwnerSuffix = '.pid';
  // AVAssetWriter's fast-start scratch under the macOS sandbox arrives
  // as `<file>.sb-<token>`. A shadow of one of our temporaries is ours;
  // a shadow of anything else is not.
  RenderTemporaryShadowPrefix = '.sb-';

  // One turn of a run loop being pumped for a framework answer.
  //
  // A millisecond is short enough that the wait never shows up in a
  // measurement and long enough not to be a spin. Five units had a
  // private copy of it — two capture units, the movie writer, the trim
  // and the render, under two different names — about one thing: how
  // finely this program is willing to poll something asynchronous.
  //
  // The recorder's own loop is NOT this: it turns at the sidecar's
  // sample rate, because there the slice is the sampling clock.
  FrameworkSliceSeconds = 0.001;
  // How long a caller waits for a framework completion that an earlier,
  // timed-out attempt abandoned before refusing to start another. Both
  // the capture start (Knips.Capture.Stream) and the shareable-content
  // query (Knips.Capture.ShareableContent) drain on this budget; it lives
  // here because both units import this one and neither may import the
  // other. Short, because it only ever runs after a timeout and the
  // caller must not freeze on the retry. A 1 ms slice costs nearer
  // 1.7 ms of wall clock (measured), so this is about 1.8 s, not one
  // second.
  StalePendingSlices = 1000;

  // What counts as silence, as a sample magnitude in 0..1. About -60 dBFS.
  // Chosen so a muted source and a source recording a quiet room are told
  // apart: a real room floor measures well above this, and a track that
  // never crosses it carried nothing anybody will hear.
  AudioSilenceThreshold = 0.001;

  // Above this share of a take's frames being idle heartbeats, the
  // repeats *are* the take, and anything the capture queue composited
  // into a frame is standing still for most of the movie. Half is chosen
  // rather than tuned: below it the note would fire on ordinary takes
  // that merely paused, and it is a note about a whole recording, not
  // about a moment in one.
  BigCursorIdleShare = 0.5;

  // GIF delays are whole centiseconds, so anything above 50 fps cannot
  // be represented and 20 is what Kap-sized clips actually want. APNG
  // could go faster, but sharing the bound keeps one --fps rule.
  DefaultGifFramesPerSecond = 20;
  MinGifFramesPerSecond = 1;
  MaxGifFramesPerSecond = 50;
  // 0 = keep the movie's own width.
  GifWidthFromSource = 0;
  MinGifWidth = 16;
  MaxGifWidth = 4096;
  // What counts as a big animation. The area is 1280x720, past which a
  // GIF stops being something to paste into a chat window; the byte
  // ceiling catches a small canvas that simply ran too long.
  LargeExportAreaPixels = 1280 * 720;
  LargeExportBytes = Int64(20) * 1024 * 1024;
  // What the advice offers instead. Both are what a chat-window clip
  // usually wants anyway.
  SuggestedNarrowWidth = 800;
  SuggestedSlowFramesPerSecond = 15;

type
  // See ClassifyRenderTemporary.
  TRenderTemporaryKind = (rtkNotOurs, rtkTemporary, rtkOwnerMarker,
    rtkSandboxShadow);

  TCaptureRegion = record
    Left: Integer;
    Top: Integer;
    Width: Integer;
    Height: Integer;
  end;

  TCaptureTargetKind = (ctkDisplay, ctkWindow);

  TOutputContainer = (ocMPEG4, ocQuickTime);

  // What, if anything, is recorded onto the movie's audio tracks.
  // amSystem is the audio ScreenCaptureKit mixes for the captured
  // content; amMicrophone is SCK's separate microphone output (macOS 15).
  // amBoth keeps them apart, as two tracks — nothing here mixes them.
  TAudioMode = (amNone, amSystem, amMicrophone, amBoth);

  TRecordingOptions = record
    TargetKind: TCaptureTargetKind;
    // Index into the enumerated displays; -1 = the main display.
    DisplayIndex: Integer;
    // CGWindowID of the window to record when TargetKind = ctkWindow.
    WindowID: Cardinal;
    HasRegion: Boolean;
    // Region in display points, relative to the display's origin.
    Region: TCaptureRegion;
    // CGWindowIDs to keep out of a display capture — the menu-bar app
    // puts its own recording-border window here so the frame it draws
    // around the region never reaches the file. Display targets only: a
    // window target's filter is built from the window itself and has
    // nowhere to hang an exclusion list.
    ExcludedWindowIDs: array of Cardinal;
    // Ask ScreenCaptureKit for an explicit sourceRect even when the whole
    // target is being recorded, so the menu-bar app's live effects (Zoom
    // on Click, Follow Mouse) have a rectangle to move. A stream started
    // without one captures its whole content and cannot be given one
    // later without changing what the output means halfway through the
    // file. Off for the CLI: the effects are app-only, and an unnecessary
    // sourceRect is one more thing between the display and the encoder.
    LiveSourceRect: Boolean;
    FramesPerSecond: Integer;
    // Pixels per point: 1, 2, or ScaleAuto.
    Scale: Integer;
    ShowsCursor: Boolean;
    // Draw an enlarged pointer into the recorded frames instead of
    // capturing the system one. ScreenCaptureKit's own cursor is
    // switched off for the recording and a scaled sprite is composited
    // into each frame (Knips.Recording.CursorOverlay), so the exports
    // inherit it. Display targets only — a window's frames have no fixed
    // relationship to the screen the pointer is measured against, which
    // is the same reason the live effects refuse one.
    BigCursor: Boolean;
    // Leave the pointer out of the recording and draw it back at export
    // time from the event sidecar's track, smoothed
    // (Knips.Export.CursorEffect). ScreenCaptureKit's own cursor is
    // switched off exactly as Big Cursor switches it off, so the movie
    // itself is genuinely cursorless — the pointer only appears in a GIF
    // or an APNG exported from it. Display targets only, and mutually
    // exclusive with BigCursor: both suppress the real pointer, and a
    // recording cannot be waiting for a pointer it already has.
    SmoothCursor: Boolean;
    // Which live effects the caller has switched on. Nothing in the
    // capture path reads these: they are carried so the event sidecar's
    // header can say what the recording was doing, which is the one thing
    // a reader cannot work out from the samples (a Follow Mouse take
    // where the mouse never moved looks exactly like one with it off).
    LiveZoomOnClick: Boolean;
    LiveFollowMouse: Boolean;
    // The composited window recording's own pan: a display capture whose
    // source rectangle is polled onto a window as the user drags it. Not
    // a live effect — nothing animates it — but it moves the framing just
    // as much, so a take that had one is not a raw take.
    LiveWindowFollow: Boolean;
    // 0 = derive from the capture size and frame rate.
    BitRate: Integer;
    OutputPath: string;
    Container: TOutputContainer;
    AudioMode: TAudioMode;
    // 0 = derive the default when audio is on; ignored when it is off.
    AudioSampleRate: Integer;
    AudioChannelCount: Integer;
    AudioBitRate: Integer;
  end;

  // What `knips export` writes. efMovie is not a re-encode: it is the
  // passthrough trim, where the same coded samples are copied into a new
  // container between two stamps.
  TExportFormat = (efGif, efApng, efMovie);

  // What the pointer does in the exported animation.
  //
  // The four are a list rather than a boolean because this is the first
  // member of a set that is going to grow: the playback window's Effects
  // control offers post-recording effects applied at export time from the
  // event sidecar's track, and the cursor is one of them. Everything here
  // needs a movie whose pixels do NOT already carry a pointer — a take
  // recorded with --smooth-cursor, or with --no-cursor — because nothing
  // can take a baked pointer out again.
  TExportCursorMode = (
    // Whatever the recording decided. A take recorded with
    // --smooth-cursor gets its pointer drawn back; every other take is
    // exported exactly as it was captured. The default, and the only
    // mode a caller that has not thought about it can get.
    ecmAsRecorded,
    // No pointer, even if the sidecar asked for one.
    ecmNone,
    // The pointer, at its ordinary size, from the smoothed track.
    ecmSmooth,
    // The same, enlarged — Big Cursor's look, decided at export instead
    // of at record time.
    ecmBig);

  // The post-recording effects a render or an export applies, read from
  // the event sidecar (Knips.Recording.Sidecar) rather than from the
  // pixels.
  //
  // One record rather than a handful of flags on TExportOptions, because
  // the set is open and because the same record has to reach three
  // different sinks: the MP4 render (Knips.Export.Render), the GIF
  // encoder and the APNG encoder (Knips.Export.Pipeline). A caller
  // chooses effects once and every output agrees. Which effects a given
  // take can still have is the sidecar's own question; see
  // Knips.Recording.Sidecar.AvailableExportEffects.
  TExportEffects = record
    Cursor: TExportCursorMode;
    // How much bigger than the system pointer ecmBig draws. Ignored by
    // every other mode. 0 takes the feature's own default.
    CursorMagnification: Double;
    // Full width of the smoothing window over the pointer track, in
    // seconds. 0 takes the default; negative is treated as 0, which is
    // no smoothing at all.
    CursorSmoothingSeconds: Double;
    // Post-recording Zoom on Click: the sidecar's click track drives a
    // per-frame crop of the decoded frame, scaled back up to the output's
    // own size, with the same easing, hold and factor the live effect
    // uses (Knips.Export.ZoomTrack). Refused for a take whose capture was
    // already zooming — nothing can take a baked crop out again.
    ZoomOnClick: Boolean;
    // How far in the crop goes at a click. 0 takes the live effect's own
    // LiveClickZoom, which is what makes the two feel the same.
    ZoomFactor: Double;
    // Seconds the zoom holds after the *last* click before easing back.
    // 0 takes the live effect's LiveZoomHoldSeconds.
    ZoomHoldSeconds: Double;
  end;

  TExportOptions = record
    InputPath: string;
    OutputPath: string;
    Format: TExportFormat;
    // The container the input is read from, filled by validation.
    InputContainer: TOutputContainer;
    // The container the output is written to when Format is efMovie;
    // meaningless otherwise. Also filled by validation.
    OutputContainer: TOutputContainer;
    FramesPerSecond: Integer;
    // Target width in pixels; GifWidthFromSource keeps the movie's own.
    Width: Integer;
    // Whether --trim was given at all. A passthrough trim with no range
    // is a copy, which is not what the command is for.
    HasTrim: Boolean;
    TrimStartSeconds: Double;
    // False runs to the end of the movie. A separate flag rather than a
    // sentinel value, so an explicit --trim=3,0 is an empty range and
    // gets rejected instead of quietly meaning "to the end".
    HasTrimEnd: Boolean;
    TrimEndSeconds: Double;
    Dither: Boolean;
    // Post-recording effects, applied from the event sidecar while the
    // frames are re-encoded. Meaningless for efMovie, which decodes
    // nothing — validation says so rather than ignoring it.
    Effects: TExportEffects;
  end;

  // What a finished render actually did, flattened out of
  // Knips.Export.Render's TRenderReport so the sentence describing it
  // can live below the Darwin line. See RenderAppliedSummary.
  // The export's counterpart to TRenderAppliedFacts: everything a
  // finished GIF or APNG can say about what reached its pixels, as
  // plain scalars, because TExportReport lives behind the Darwin line
  // and this has to be reachable from everywhere.
  //
  // It exists because the render round's shared-wording work never
  // reached this side: `knips export` composed its own sentence, the
  // MCP export tools composed a shorter and differently-ordered one,
  // and neither mentioned the palette, the synthesised frames or the
  // frames the pointer track could not place.
  TExportAppliedFacts = record
    Format: TExportFormat;
    // GIF only; zero for APNG, which quantises nothing.
    PaletteColors: Integer;
    ExactPalette: Boolean;
    SampledFrames: Integer;
    SmoothCursor: Boolean;
    SmoothCursorFrames: Int64;
    SmoothCursorOffFrame: Int64;
    ZoomOnClick: Boolean;
    ZoomedFrames: Int64;
    ZoomClicks: Integer;
    SynthesizedFrames: Int64;
    SynthesisFramesPerSecond: Integer;
    UnframedFrames: Int64;
  end;

  TRenderAppliedFacts = record
    ZoomApplied: Boolean;
    ZoomedFrames: Int64;
    FramesWritten: Int64;
    UsableClicks: Integer;
    CursorDrawn: Boolean;
    CursorFrames: Int64;
    CursorOffFrameFrames: Int64;
    // Frames the capture never made, and the cadence they were made at.
    SynthesizedFrames: Int64;
    SynthesisFramesPerSecond: Integer;
    AudioTracks: Integer;
    // Stated rather than assumed, because it is the one claim about the
    // file a listener cannot check: a track that had been through AAC
    // twice sounds like a track that had not, until it does not.
    AudioPassthrough: Boolean;
    AudioSamples: Int64;
  end;

function DefaultRecordingOptions: TRecordingOptions;

// "left,top,width,height" in points. Rejects anything else.
function ParseCaptureRegion(const AText: string;
  out ARegion: TCaptureRegion): Boolean;

// "none", "system", "mic", or "both", case-insensitively. False for
// anything else.
function ParseAudioMode(const AText: string; out AMode: TAudioMode): Boolean;

function AudioModeName(AMode: TAudioMode): string;

// Which of ScreenCaptureKit's two audio outputs the mode asks for. Every
// layer below the CLI asks these rather than comparing the enum, so a
// future mode joins in one place.
function AudioModeCapturesSystem(AMode: TAudioMode): Boolean;

function AudioModeCapturesMicrophone(AMode: TAudioMode): Boolean;

// The live note for a menu while a recording runs: '' when the source is
// off, and otherwise one of three words for what has arrived so far. Kept
// to a few characters on purpose — this hangs off a menu item, not a
// meter.
//
// AInspected is how many buffers the peak was actually measured over. Zero
// means the format could not be read, and then the honest answer is that
// samples are arriving and nothing can be said about their level.
function AudioLevelNote(AEnabled: Boolean; ASamples, AInspected: Int64;
  APeak: Double): string;

// What to say after the stop when an enabled source produced nothing
// audible. '' when there is nothing to say, which is the usual case.
// ASourceName is the human word for the track ('system audio', 'the
// microphone').
//
// The distinction this draws is the whole point: no samples at all is a
// plumbing failure and points at permissions and devices; samples that
// were all silence is a mixer or a muted input and points somewhere else
// entirely. Telling somebody to check System Settings when the microphone
// was simply muted wastes their afternoon.
function AudioSilenceWarning(const ASourceName: string; AEnabled: Boolean;
  ASamples, AInspected: Int64; APeak: Double): string;

// What to say after the stop when Big Cursor met the idle heartbeat.
// '' when there is nothing to say, which is the usual case.
//
// The two features cross at a seam neither of them owns. Big Cursor
// composites its sprite into a frame **on the capture queue, as that
// frame arrives**; the idle heartbeat repeats the last delivered frame
// about twice a second while nothing changes, and a repeat is the same
// pixels — pointer included, at the position it had when that frame was
// captured. So on a take of a still screen the enlarged pointer is
// frozen for the whole idle stretch even though the sidecar's track
// shows it moving. Measured: a 7.6 s take came back with 16 frames, 15
// of them heartbeats, and the sprite composited into none of them.
//
// Nothing is wrong with the file and nothing failed, which is why this
// is a note and not an error — but somebody who asked for an enlarged
// pointer and got a still one deserves to be told which of the two
// features produced it, and that the raw-take route does not have the
// problem. See docs/architecture.md, "Big Cursor" and "The idle
// heartbeat".
function BigCursorIdleWarning(AEnabled: Boolean;
  ACursorFrames, AHeartbeatFrames, AAppendedFrames: Int64): string;

// One line for a caller that has one line, out of the three separate
// answers a render or an export can come back with.
//
// The three are kept apart in the reports because they are about
// different things and a caller offering one effect wants that effect's
// own reason. This is the summary for the places that cannot show three
// — the menu's Last-error slot, the playback window's title — and the
// ORDER is the whole content of the function:
//
//   1. the framing note, because it is the only one of the three about
//      the PIXELS being other than they should be. The other two say an
//      effect did not happen; this one says some frames show something
//      the take could not account for.
//   2. the cursor, because a missing pointer is what somebody looking at
//      the file will notice first.
//   3. the zoom.
//
// It used to be first-writer-wins over a single field, which made the
// order an accident of which check ran first: a take whose zoom was
// refused for a cosmetic reason could hide the framing note entirely.
function EffectNoteSummary(const AFramingNote, ACursorNote,
  AZoomNote: string): string;

// The two effect notes with the words that say what they are notes
// ABOUT. '' for an empty note, so a caller can concatenate without
// asking twice.
//
// They are here rather than at each call site because there are now two
// call sites — `knips render` printing to stderr and the MCP render tool
// composing a result — and a note that reads "no cursor drawn (…)" on a
// console and "the cursor was skipped (…)" over JSON would be two
// different claims about one field. The framing note has no such
// wrapper: it is not about an effect that did not happen, it is about
// the pixels, and it is said in the report's own words.
function EffectCursorNoteLine(const ACursorNote: string): string;

function EffectZoomNoteLine(const AZoomNote: string): string;

// The third wrapper, and it exists for symmetry rather than for words:
// the framing note is not about an effect that did not happen, it is
// about the pixels, so it is said in the report's own words and this
// only passes it through. Having all three means a caller composes the
// same way whichever note it is holding.
function EffectFramingNoteLine(const AFramingNote: string): string;

// The framing note itself: what a run leaves behind about frames whose
// framing the pointer track cannot account for. One sentence, because
// there were two — the MP4 render said "this take's pointer track" and
// the animation export said "this recording's", about the same fact,
// from two copies of the same Format call.
function UnframedFramesNote(AFrames: Int64): string;

// What a load of an event sidecar could not use, in words; '' when the
// whole file was believed. TSidecarLog survives a line it cannot read —
// a truncated tail, a number that is not finite, a stamp that does not
// advance — and counts it in SkippedLines, and until this existed that
// count was reachable only from inside the loader. It matters because a
// skipped cursor record is a hole in the pointer track a render draws
// from: the deliverable is correct and it is thinner than the file
// looks. One sentence, in one place, so `knips render`, `knips export`,
// the MCP payloads and the menu-bar app's log all say it the same way.
function SidecarSkippedLinesNote(ASkippedLines: Integer): string;

// Everything a finished render can say about what it DID, in one clause
// list — ", zoom on 34 of 100 frames from 1 clicks, pointer on 100
// frames (0 off frame)" — or '' when nothing applied.
//
// A plain record of scalars rather than TRenderReport, because that
// record lives in Knips.Export.Render behind the Darwin line and this
// has to be reachable from here, which everything reaches. Both the CLI
// and the MCP tool fill it from the same report and get the same
// sentence; they used to hold a byte-identical 25-line copy each, which
// is exactly the kind of duplication that drifts the first time one of
// the four clauses is reworded.
//
// The FILLING is Knips.Export.Render.RenderFactsOf, for the same
// reason: the two faces each held the same fourteen assignments out of
// the report, which is where the duplication came back. This is the
// empty record they start from — Default- like every other "the value
// before anybody has said anything" function here.
function DefaultRenderAppliedFacts: TRenderAppliedFacts;

// The export's own pair, filled by Knips.Export.Pipeline.ExportFactsOf
// and composed here so `knips export`, the MCP export tools and the
// playback window all say the same thing in the same order.
function DefaultExportAppliedFacts: TExportAppliedFacts;

// Everything a finished export applied, in one clause list — " (255
// colours), export cursor on 145 frames (0 off frame), zoom on 35
// frames from 1 clicks, 12 frames filled in at 20 fps where the capture
// had none". Never '': the palette clause is always there, because it
// is what the format IS.
function ExportAppliedSummary(const AFacts: TExportAppliedFacts): string;

// The line a finished export reports: the animation, its shape, and
// AApplied.
function ExportSummaryLine(const APath: string; APixelWidth,
  APixelHeight: Integer; AFrames: Int64; ADurationSeconds: Double;
  AOutputBytes: Int64; const AApplied: string): string;

function RenderAppliedSummary(const AFacts: TRenderAppliedFacts): string;

// The line a finished render reports: the deliverable, its shape, and
// AApplied. A render that applied nothing copied the take byte for byte
// rather than re-encoding it to produce the same movie, and says so
// instead of claiming work it did not do.
function RenderSummaryLine(const APath: string; APixelWidth,
  APixelHeight: Integer; AFrames: Int64; ADurationSeconds: Double;
  AOutputBytes: Int64; ACopied: Boolean; const AApplied: string): string;

// The line a finished passthrough trim reports: the movie, the range it
// kept out of the movie it came from, and the size — and the fact that
// matters most about it, which is that nothing was decoded. One
// function because `knips export --trim` and the MCP export_trim tool
// held the same Format call each.
function TrimSummaryLine(const APath: string; AStartSeconds, AEndSeconds,
  ASourceDurationSeconds: Double; AOutputBytes: Int64): string;

// Whether a render may write APath. Only the two movie containers, for
// the reason the tool descriptions and `--out=demo.mp4` already give:
// this pass re-encodes H.264 into a QuickTime-family container and can
// write nothing else. It used to accept any name at all, so
// `--out=demo.gif` produced an MP4 called demo.gif and reported success
// — a file whose extension lies, which is worse than a refusal. Asked by
// `knips render` and by the MCP render tool, in one place, so the two
// cannot disagree.
function ValidateRenderOutputPath(const APath: string;
  out AError: string): Boolean;

// What a file name found beside a deliverable IS, as far as the crash
// sweep is concerned. The sweep used to match `*<suffix>*` and delete
// whatever came back, which took an ordinary user file called
// `notes.knips-render-tmp.txt` with it and, worse, took a LIVE render's
// temporary. Three shapes are ours and nothing else is:
//
//   `demo.mp4.knips-render-tmp`         the temporary itself
//   `demo.mp4.knips-render-tmp.pid`     its owner marker
//   `demo.mp4.knips-render-tmp.sb-abc`  AVAssetWriter's sandbox shadow
//
// ATemporaryName comes back as the temporary all three belong to, so a
// caller can decide once per temporary and act on its whole family.
function ClassifyRenderTemporary(const AFileName: string;
  out ATemporaryName: string): TRenderTemporaryKind;

// `demo.mp4` -> `demo.mp4.knips-render-tmp`.
function RenderTemporaryPathFor(const AOutputPath: string): string;

// `demo.mp4.knips-render-tmp` -> `demo.mp4.knips-render-tmp.pid`.
function RenderTemporaryOwnerPathFor(const ATemporaryPath: string): string;

// Container from the output path's extension; False for unknown ones.
function ContainerForPath(const APath: string;
  out AContainer: TOutputContainer): Boolean;

// `demo.mp4` -> `demo-raw.mp4`: where the raw take of a deliverable
// lives. The deliverable keeps the name the user chose and the raw take
// takes the suffix, rather than the other way round, because the
// deliverable is the file that gets opened, moved and sent — see
// docs/architecture.md.
function RawTakePathFor(const ADeliverablePath: string): string;

// The inverse: `demo-raw.mp4` -> `demo.mp4`. Returns APath unchanged when
// it does not name a raw take.
function DeliverablePathFor(const ARawTakePath: string): string;

// True when APath names a raw take rather than a deliverable.
function IsRawTakePath(const APath: string): Boolean;

// Checks ranges and cross-field rules; fills derived fields (Container,
// the audio format when audio is on).
// Returns False with a one-line human message when the options can't
// start a recording.
function ValidateRecordingOptions(var AOptions: TRecordingOptions;
  out AError: string): Boolean;

// Rounds a capture dimension down to the encoder's alignment.
function AlignDimension(AValue: Integer): Integer; inline;

// The average bit rate to request when the user gave none.
function SuggestedBitRate(APixelWidth, APixelHeight,
  AFramesPerSecond: Integer): Integer;

function DefaultExportEffects: TExportEffects;

function DefaultExportOptions: TExportOptions;

// Whether this effects record asks for a pointer to be drawn at all.
function EffectsDrawCursor(const AEffects: TExportEffects): Boolean;

// Whether it asks for ANYTHING — a pointer or a zoom. False is the
// record `--effects=none` produces, and the one a render is allowed to
// honour by copying its input.
function EffectsAskForAnything(const AEffects: TExportEffects): Boolean;

function ExportCursorModeName(AMode: TExportCursorMode): string;

// "as-recorded", "none", "smooth", or "big", case-insensitively.
//
// The empty string is NOT one of them, and used to be: it parsed as
// as-recorded, so a caller that had nothing to parse got a real answer
// back and could not tell the difference. The two places that bit are
// both about a value somebody else supplied — a saved effect default
// whose `cursor` key is not a string at all
// (Knips.App.State.MigratedEffectCursor, which then silently discarded
// the legacy keys it was meant to migrate) and an MCP `"cursor": ""`.
// A caller with nothing to parse should not be calling this; `knips
// export` checks its flag was given first.
function ParseExportCursorMode(const AText: string;
  out AMode: TExportCursorMode): Boolean;

// The effects as a comma-separated list, which is both what --effects
// takes and what a report prints back.
//
// The default describes itself as `as-recorded` and NOT as `none`, which
// is what it used to say and was actively misleading: `--effects=none`
// means *no pointer and no zoom*, while the default means *whatever the
// recording decided*, which for a raw take is a pointer. A `knips render`
// that printed "with none" and then drew a pointer was telling the user
// the opposite of what it did. Describe and Parse are inverses, so
// `as-recorded` is a word Parse takes too.
function DescribeExportEffects(const AEffects: TExportEffects): string;

// The inverse: a comma-separated list of `zoom`, `as-recorded`,
// `smooth-cursor`, `big-cursor`, `no-cursor` and `none`,
// case-insensitively, applied on top of AEffects. False with a one-line
// message naming the offending word.
//
// The four cursor words are mutually exclusive because they are one
// setting; naming two of them is a mistake rather than a last-one-wins.
function ParseExportEffects(const AText: string;
  var AEffects: TExportEffects; out AError: string): Boolean;

// The same, and it also says whether the list NAMED the cursor member —
// which is not the same question as whether the member ended up
// different, because a list may name the value it already had.
//
// It exists for the one surface that has two ways to set the same
// setting: `knips export` takes `--cursor` and `--effects`, and
// `--cursor=big --effects=smooth-cursor` used to apply the list and
// throw the flag away without a word. See ParseExportEffects's own
// refusal for naming two cursor words inside one list — this is that
// rule across the two spellings.
function ParseExportEffectsNaming(const AText: string;
  var AEffects: TExportEffects; out ACursorNamed: Boolean;
  out AError: string): Boolean;

// `--cursor` and `--effects` together, which is the one surface that has
// two spellings of one setting.
//
// ACursorText is what `--cursor` was given, '' when it was not passed at
// all; AEffectsText is `--effects`. Both are applied to AEffects, in
// that order, and the pair is refused when they name the pointer and
// disagree — `--cursor=big --effects=smooth-cursor` used to apply the
// list and throw the flag away without a word. Agreeing is fine:
// `--cursor=none --effects=no-cursor` says one thing twice.
//
// Here rather than in `knips.pas` so the rule is testable without a
// command line, which it was not: neither the flag's own refusal nor the
// disagreement had a single assertion behind it.
function ReconcileCursorAndEffects(const ACursorText, AEffectsText: string;
  var AEffects: TExportEffects; out AError: string): Boolean;

// Whether an --effects list asks, in so many words, for a copy: the
// word `none`, which means no pointer and no zoom. It is the one
// request a render honours by applying nothing (see
// Knips.Export.Render's ExplicitCopy), so a render that applies nothing
// WITHOUT it is a duplicate rather than a deliverable and is refused.
function ExportEffectsRequestCopy(const AText: string): Boolean;

// Export format from the output path's extension; False for unknown ones.
function ExportFormatForPath(const APath: string;
  out AFormat: TExportFormat): Boolean;

function ExportFormatName(AFormat: TExportFormat): string;

// One line of advice when an export is going to be awkwardly large, or
// '' when it is not. Both triggers are checked: the canvas alone (known
// before a byte is written) and the size the file actually reached. The
// advice only names knobs that would actually move — telling someone to
// pass --width=800 when they already did is noise.
function LargeExportWarning(AFormat: TExportFormat; APixelWidth,
  APixelHeight, AFramesPerSecond: Integer; AOutputBytes: Int64): string;

// "start,end" in seconds with an optional decimal part; either side may
// be left empty ("2," keeps everything from 2 s on, ",5" keeps the first
// five seconds). AHasEnd distinguishes an omitted end from an explicit
// zero. Always reads '.' as the decimal point, whatever the host locale
// says.
function ParseTrimRange(const AText: string;
  out AStartSeconds, AEndSeconds: Double; out AHasEnd: Boolean): Boolean;

// Checks ranges and cross-field rules; fills derived fields
// (Format, InputContainer). One-line human message on failure.
function ValidateExportOptions(var AOptions: TExportOptions;
  out AError: string): Boolean;

// Bytes on disk, or 0 when the file cannot be opened. SysUtils has no
// path-taking FileSize, so every writer that wanted to report what it
// had produced grew its own open-seek-close — five of them, byte for
// byte the same. Here because every layer already reaches this unit and
// this unit reaches nothing: a size is arithmetic about a path, not a
// framework call, and the recovery pass wants it on a host with no
// frameworks at all.
function FileSizeOf(const APath: string): Int64;

// What a writer says when StopRequested cut it short. One sentence for
// every face and every writer, so a Ctrl-C reads the same whether it
// landed in a render, an export or a trim — and says the thing that
// actually matters, which is that the file the user already had is
// still there.
function ExportCancelledMessage: string;

// The process-wide "stop what you are doing" flag: set from the
// program's SIGINT/SIGTERM handler, polled by every long-running loop
// there is — the recorder's run loop, the render's frame walk, the
// export's two passes, the trim's wait.
//
// Here, in the one unit every layer reaches and which reaches nothing,
// because it used to live in Knips.Recording and only the RECORDER
// polled it. `knips export` did not even install the handler, so a
// Ctrl-C during an export was the default disposition — die instantly,
// leaving a truncated animation where a good one had been.
//
// A Boolean written from a signal handler and read from the main thread
// is the whole of the synchronisation, deliberately: the handler does
// one aligned store of a word and nothing else, which is what makes it
// async-signal-safe.
var
  StopRequested: Boolean = False;

implementation

function DefaultRecordingOptions: TRecordingOptions;
begin
  Result := Default(TRecordingOptions);
  Result.TargetKind := ctkDisplay;
  Result.DisplayIndex := MainDisplayIndex;
  Result.FramesPerSecond := DefaultFramesPerSecond;
  Result.Scale := ScaleAuto;
  Result.ShowsCursor := True;
  Result.Container := ocMPEG4;
  Result.AudioMode := amNone;
end;

function ParseAudioMode(const AText: string; out AMode: TAudioMode): Boolean;
var
  Normalized: string;
begin
  Result := True;
  AMode := amNone;
  Normalized := LowerCase(Trim(AText));
  if Normalized = 'none' then
    AMode := amNone
  else if Normalized = 'system' then
    AMode := amSystem
  else if Normalized = 'mic' then
    AMode := amMicrophone
  else if Normalized = 'both' then
    AMode := amBoth
  else
    Result := False;
end;

function AudioModeName(AMode: TAudioMode): string;
begin
  case AMode of
    amSystem: Result := 'system';
    amMicrophone: Result := 'mic';
    amBoth: Result := 'both';
  else
    Result := 'none';
  end;
end;

function AudioModeCapturesSystem(AMode: TAudioMode): Boolean;
begin
  Result := AMode in [amSystem, amBoth];
end;

function AudioModeCapturesMicrophone(AMode: TAudioMode): Boolean;
begin
  Result := AMode in [amMicrophone, amBoth];
end;

function AudioLevelNote(AEnabled: Boolean; ASamples, AInspected: Int64;
  APeak: Double): string;
begin
  Result := '';
  if not AEnabled then
    Exit;
  if ASamples <= 0 then
    Exit('waiting');
  if AInspected <= 0 then
    // Arriving, but in a format this build does not read. Saying "sound"
    // would be a claim; saying "silent" would be a lie.
    Exit('arriving');
  if APeak < AudioSilenceThreshold then
    Exit('silent');
  Result := 'sound';
end;

function AudioSilenceWarning(const ASourceName: string; AEnabled: Boolean;
  ASamples, AInspected: Int64; APeak: Double): string;
begin
  Result := '';
  if not AEnabled then
    Exit;
  if ASamples <= 0 then
    Exit(ASourceName + ' was on but delivered nothing at all to this '
      + 'recording — check the privacy grant and the input device');
  if AInspected <= 0 then
    // Not a warning: nothing went wrong that can be shown.
    Exit;
  if APeak >= AudioSilenceThreshold then
    Exit;
  Result := ASourceName + ' was on and arrived, but every sample was '
    + 'silence — check that the source is not muted';
end;

function BigCursorIdleWarning(AEnabled: Boolean;
  ACursorFrames, AHeartbeatFrames, AAppendedFrames: Int64): string;
begin
  Result := '';
  if not AEnabled then
    Exit;
  if (AAppendedFrames <= 0) or (AHeartbeatFrames <= 0) then
    Exit;
  if AHeartbeatFrames < AAppendedFrames * BigCursorIdleShare then
    Exit;
  Result := Format('the enlarged pointer is in %d of this recording''s '
    + '%d frames: %d of them are idle heartbeats, which repeat the last '
    + 'captured frame — enlarged pointer and all — so it stands still '
    + 'wherever the screen did. The event sidecar beside the movie has '
    + 'the real track; recording with --smooth-cursor and running '
    + '`knips render` over the take draws a pointer that keeps moving',
    [ACursorFrames, AAppendedFrames, AHeartbeatFrames]);
end;

function EffectNoteSummary(const AFramingNote, ACursorNote,
  AZoomNote: string): string;
begin
  if AFramingNote <> '' then
    Exit(AFramingNote);
  if ACursorNote <> '' then
    Exit(ACursorNote);
  Result := AZoomNote;
end;

function EffectCursorNoteLine(const ACursorNote: string): string;
begin
  Result := '';
  if ACursorNote <> '' then
    Result := 'no cursor drawn (' + ACursorNote + ')';
end;

function EffectZoomNoteLine(const AZoomNote: string): string;
begin
  Result := '';
  if AZoomNote <> '' then
    Result := 'no zoom applied (' + AZoomNote + ')';
end;

function EffectFramingNoteLine(const AFramingNote: string): string;
begin
  Result := AFramingNote;
end;

function UnframedFramesNote(AFrames: Int64): string;
begin
  Result := '';
  if AFrames <= 0 then
    Exit;
  Result := Format('%d frame(s) run past the end of this take''s pointer '
    + 'track, so what they were showing is not recorded; nothing was '
    + 'cropped for them and the pointer was placed from the last '
    + 'position the track holds', [AFrames]);
end;

function SidecarSkippedLinesNote(ASkippedLines: Integer): string;
begin
  Result := '';
  if ASkippedLines <= 0 then
    Exit;
  if ASkippedLines = 1 then
    Result := '1 line of this take''s event sidecar could not be read '
      + 'and was skipped; the pointer track is that much thinner than '
      + 'the file looks'
  else
    Result := Format('%d lines of this take''s event sidecar could not '
      + 'be read and were skipped; the pointer track is that much '
      + 'thinner than the file looks', [ASkippedLines]);
end;

function DefaultRenderAppliedFacts: TRenderAppliedFacts;
begin
  Result := Default(TRenderAppliedFacts);
end;

function DefaultExportAppliedFacts: TExportAppliedFacts;
begin
  Result := Default(TExportAppliedFacts);
  Result.ExactPalette := True;
end;

function ExportAppliedSummary(const AFacts: TExportAppliedFacts): string;
begin
  Result := '';
  // The palette first, because it is what the format IS: a GIF's
  // colours, or the fact that an APNG has none to lose.
  if AFacts.Format = efGif then
  begin
    Result := Format(' (%d colours', [AFacts.PaletteColors]);
    // Worth saying: the histogram overflowed into its 6-bit fallback,
    // which costs palette accuracy, and a GIF that looks banded should
    // not have to be guessed at.
    if not AFacts.ExactPalette then
      Result := Result + ', 6-bit histogram';
    Result := Result + ')';
  end
  else
    Result := ' (truecolour)';
  // Then the pointer, then the zoom — the same order the notes are
  // printed in and the render's own summary uses.
  if AFacts.SmoothCursor then
    Result := Result + Format(', export cursor on %d frames '
      + '(%d off frame)',
      [AFacts.SmoothCursorFrames, AFacts.SmoothCursorOffFrame]);
  if AFacts.ZoomOnClick then
    Result := Result + Format(', zoom on %d frames from %d clicks',
      [AFacts.ZoomedFrames, AFacts.ZoomClicks]);
  if AFacts.SynthesizedFrames > 0 then
    Result := Result + Format(', %d frames filled in at %d fps where the '
      + 'capture had none',
      [AFacts.SynthesizedFrames, AFacts.SynthesisFramesPerSecond]);
end;

function ExportSummaryLine(const APath: string; APixelWidth,
  APixelHeight: Integer; AFrames: Int64; ADurationSeconds: Double;
  AOutputBytes: Int64; const AApplied: string): string;
begin
  Result := Format('wrote %s: %dx%d, %d frames, %.1fs, %d kB%s',
    [APath, APixelWidth, APixelHeight, AFrames, ADurationSeconds,
    AOutputBytes div 1024, AApplied]);
end;

function RenderAppliedSummary(const AFacts: TRenderAppliedFacts): string;
begin
  Result := '';
  if AFacts.ZoomApplied then
    Result := Format(', zoom on %d of %d frames from %d clicks',
      [AFacts.ZoomedFrames, AFacts.FramesWritten, AFacts.UsableClicks]);
  if AFacts.CursorDrawn then
    Result := Result + Format(', pointer on %d frames (%d off frame)',
      [AFacts.CursorFrames, AFacts.CursorOffFrameFrames]);
  // Frames the capture never made. Said out loud rather than folded into
  // the total, because it is the difference between a deliverable that
  // animates and one that jumps, and because it is what the file grew
  // for.
  if AFacts.SynthesizedFrames > 0 then
    Result := Result + Format(', %d frames filled in at %d fps where the '
      + 'capture had none',
      [AFacts.SynthesizedFrames, AFacts.SynthesisFramesPerSecond]);
  // The render pass has no re-encoding path and would rather fail than
  // take one, so the word is always "copied" — and if that ever stops
  // being true, the summary says so on the take where it happened
  // rather than in a comment.
  if AFacts.AudioTracks > 0 then
    if AFacts.AudioPassthrough then
      Result := Result + Format(
        ', %d audio track(s) copied (%d samples, not re-encoded)',
        [AFacts.AudioTracks, AFacts.AudioSamples])
    else
      Result := Result + Format(
        ', %d audio track(s) RE-ENCODED (%d samples)',
        [AFacts.AudioTracks, AFacts.AudioSamples]);
end;

function RenderSummaryLine(const APath: string; APixelWidth,
  APixelHeight: Integer; AFrames: Int64; ADurationSeconds: Double;
  AOutputBytes: Int64; ACopied: Boolean; const AApplied: string): string;
begin
  if ACopied then
    Exit(Format('wrote %s: nothing to render, so the take was copied '
      + 'unchanged (%d kB)', [APath, AOutputBytes div 1024]));
  Result := Format('wrote %s: %dx%d, %d frames, %.1fs, %d kB%s',
    [APath, APixelWidth, APixelHeight, AFrames, ADurationSeconds,
    AOutputBytes div 1024, AApplied]);
end;

function TrimSummaryLine(const APath: string; AStartSeconds, AEndSeconds,
  ASourceDurationSeconds: Double; AOutputBytes: Int64): string;
begin
  Result := Format('wrote %s: %.2fs–%.2fs of %.2fs, %d kB (streams copied)',
    [APath, AStartSeconds, AEndSeconds, ASourceDurationSeconds,
    AOutputBytes div 1024]);
end;

function ValidateRenderOutputPath(const APath: string;
  out AError: string): Boolean;
var
  Container: TOutputContainer;
begin
  AError := '';
  Result := False;
  if APath = '' then
  begin
    AError := 'an output path is required (--out=demo.mp4)';
    Exit;
  end;
  if not ContainerForPath(APath, Container) then
  begin
    // The same sentence ValidateRecordingOptions gives for the same
    // mistake, because it IS the same mistake and a caller should not
    // have to learn two spellings of it.
    AError := 'unsupported output extension "' + ExtractFileExt(APath)
      + '" (use .mp4 or .mov)';
    Exit;
  end;
  Result := True;
end;

function FileSizeOf(const APath: string): Int64;
var
  Handle: THandle;
begin
  Result := 0;
  Handle := FileOpen(APath, fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then
    Exit;
  try
    Result := FileSeek(Handle, Int64(0), fsFromEnd);
    // A seek that failed answers -1, which is not a size; a caller
    // formatting it would print a negative number of bytes.
    if Result < 0 then
      Result := 0;
  finally
    FileClose(Handle);
  end;
end;

function ExportCancelledMessage: string;
begin
  Result := 'stopped before it finished; nothing was written and any '
    + 'file that was already there is untouched';
end;

function ClassifyRenderTemporary(const AFileName: string;
  out ATemporaryName: string): TRenderTemporaryKind;
var
  Cut: Integer;
  Tail: string;
begin
  ATemporaryName := '';
  Result := rtkNotOurs;
  Cut := Pos(RenderTemporarySuffix, AFileName);
  if Cut <= 1 then
    Exit;
  ATemporaryName := Copy(AFileName, 1,
    Cut + Length(RenderTemporarySuffix) - 1);
  Tail := Copy(AFileName, Cut + Length(RenderTemporarySuffix), MaxInt);
  if Tail = '' then
    Exit(rtkTemporary);
  if Tail = RenderTemporaryOwnerSuffix then
    Exit(rtkOwnerMarker);
  // `.sb-` and at least one character of token; a bare `.sb-` is not a
  // name the framework produces and is not worth claiming.
  if (Length(Tail) > Length(RenderTemporaryShadowPrefix))
    and (Copy(Tail, 1, Length(RenderTemporaryShadowPrefix))
    = RenderTemporaryShadowPrefix) then
    Exit(rtkSandboxShadow);
  ATemporaryName := '';
end;

function RenderTemporaryPathFor(const AOutputPath: string): string;
begin
  Result := AOutputPath + RenderTemporarySuffix;
end;

function RenderTemporaryOwnerPathFor(const ATemporaryPath: string): string;
begin
  Result := ATemporaryPath + RenderTemporaryOwnerSuffix;
end;

function ParseCaptureRegion(const AText: string;
  out ARegion: TCaptureRegion): Boolean;
var
  Parts: TStringArray;
  Values: array[0..3] of Integer;
  I: Integer;
begin
  Result := False;
  ARegion := Default(TCaptureRegion);
  Parts := AText.Split([',']);
  if Length(Parts) <> 4 then
    Exit;
  for I := 0 to 3 do
    if not TryStrToInt(Trim(Parts[I]), Values[I]) then
      Exit;
  if (Values[2] <= 0) or (Values[3] <= 0) then
    Exit;
  if (Values[0] < 0) or (Values[1] < 0) then
    Exit;
  ARegion.Left := Values[0];
  ARegion.Top := Values[1];
  ARegion.Width := Values[2];
  ARegion.Height := Values[3];
  Result := True;
end;

function ContainerForPath(const APath: string;
  out AContainer: TOutputContainer): Boolean;
var
  Extension: string;
begin
  Result := True;
  Extension := LowerCase(ExtractFileExt(APath));
  if Extension = Mpeg4FileExtension then
    AContainer := ocMPEG4
  else if Extension = QuickTimeFileExtension then
    AContainer := ocQuickTime
  else
  begin
    AContainer := ocMPEG4;
    Result := False;
  end;
end;

function RawTakePathFor(const ADeliverablePath: string): string;
begin
  if ADeliverablePath = '' then
    Exit('');
  Result := ChangeFileExt(ADeliverablePath, '') + RawTakeSuffix
    + ExtractFileExt(ADeliverablePath);
end;

function IsRawTakePath(const APath: string): Boolean;
var
  Stem: string;
begin
  Stem := ChangeFileExt(ExtractFileName(APath), '');
  Result := (Length(Stem) > Length(RawTakeSuffix))
    and (Copy(Stem, Length(Stem) - Length(RawTakeSuffix) + 1,
    Length(RawTakeSuffix)) = RawTakeSuffix);
end;

function DeliverablePathFor(const ARawTakePath: string): string;
var
  Extension: string;
begin
  Result := ARawTakePath;
  if not IsRawTakePath(ARawTakePath) then
    Exit;
  Extension := ExtractFileExt(ARawTakePath);
  Result := Copy(ARawTakePath, 1, Length(ARawTakePath) - Length(Extension)
    - Length(RawTakeSuffix)) + Extension;
end;

function AlignDimension(AValue: Integer): Integer;
begin
  Result := AValue - (AValue mod DimensionAlignment);
end;

function SuggestedBitRate(APixelWidth, APixelHeight,
  AFramesPerSecond: Integer): Integer;
var
  Budget: Double;
begin
  // Int64 before the Double, and that is not belt and braces: three
  // Integers multiplied together wrap. 6016 x 3384 at 120 fps is
  // 2,442,977,280, past High(Integer) — it came out negative, fell
  // through the low clamp, and a 6K 120 fps recording was encoded at
  // 1 Mbit/s. The Double at the end never saw the real number.
  Budget := Int64(APixelWidth) * Int64(APixelHeight) * Int64(AFramesPerSecond)
    * AutoBitsPerPixelPerFrame;
  if Budget < MinBitRate then
    Budget := MinBitRate
  else if Budget > MaxBitRate then
    Budget := MaxBitRate;
  Result := Round(Budget);
end;

function ValidateRecordingOptions(var AOptions: TRecordingOptions;
  out AError: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  AError := '';
  if AOptions.OutputPath = '' then
  begin
    AError := 'an output path is required (--out=demo.mp4)';
    Exit;
  end;
  if not ContainerForPath(AOptions.OutputPath, AOptions.Container) then
  begin
    AError := 'unsupported output extension "'
      + ExtractFileExt(AOptions.OutputPath) + '" (use .mp4 or .mov)';
    Exit;
  end;
  // -1 is "the main display" and is the only negative that means
  // anything. Every other one used to be accepted and silently treated
  // as -1, so `--display=-5` recorded the main display and said nothing
  // — a typed index that quietly became a different index.
  if (AOptions.TargetKind = ctkDisplay)
    and (AOptions.DisplayIndex < MainDisplayIndex) then
  begin
    AError := Format('--display must be 0 or more, or %d for the main '
      + 'display (given %d; see `knips displays`)',
      [MainDisplayIndex, AOptions.DisplayIndex]);
    Exit;
  end;
  if (AOptions.FramesPerSecond < MinFramesPerSecond)
    or (AOptions.FramesPerSecond > MaxFramesPerSecond) then
  begin
    AError := Format('--fps must be between %d and %d',
      [MinFramesPerSecond, MaxFramesPerSecond]);
    Exit;
  end;
  if (AOptions.Scale < ScaleAuto) or (AOptions.Scale > MaxScale) then
  begin
    AError := Format(ScaleRefusal + ' (given %d)', [AOptions.Scale]);
    Exit;
  end;
  if AOptions.BitRate < 0 then
  begin
    AError := Format('--bitrate must be a positive number of bits per '
      + 'second (given %d)', [AOptions.BitRate]);
    Exit;
  end;
  if (AOptions.TargetKind = ctkWindow) and AOptions.HasRegion then
  begin
    AError := '--window and --rect are mutually exclusive';
    Exit;
  end;
  if (AOptions.TargetKind = ctkWindow) and (AOptions.WindowID = 0) then
  begin
    AError := '--window needs a non-zero window id (see `knips windows`)';
    Exit;
  end;
  if AOptions.SmoothCursor and AOptions.BigCursor then
  begin
    // Both switch the real pointer off, and they mean opposite things
    // about what is supposed to happen next: one bakes a big pointer into
    // the movie, the other leaves the movie cursorless so an export can
    // draw a smooth one. Refusing beats picking.
    AError := '--big-cursor and --smooth-cursor are mutually exclusive: '
      + 'one bakes an enlarged pointer into the movie and the other '
      + 'leaves the movie cursorless for a later render';
    Exit;
  end;
  if AOptions.SmoothCursor and not AOptions.ShowsCursor then
  begin
    AError := '--no-cursor and --smooth-cursor are mutually exclusive: '
      + 'one asks for no pointer at all and the other leaves the movie '
      + 'cursorless so that a render can draw one back in';
    Exit;
  end;
  if (AOptions.TargetKind = ctkWindow) and AOptions.SmoothCursor then
  begin
    // Same reason as the big cursor below: the drawn pointer is placed by
    // mapping a screen position into the frame, and a window's frames
    // move under the recorder with no way to find out.
    AError := 'a smooth cursor applies to display recordings only';
    Exit;
  end;
  if AOptions.BigCursor and not AOptions.ShowsCursor then
  begin
    // The reason, not only the fact. Guessing which was meant would
    // silently give the caller the opposite of one of the two flags it
    // passed — and the MCP rewriter used to bolt this explanation on for
    // an agent while the person at the command line got the bare
    // sentence.
    AError := '--no-cursor and --big-cursor are mutually exclusive: one '
      + 'asks for no pointer and the other for a bigger one. Pass '
      + 'exactly one of them';
    Exit;
  end;
  if (AOptions.TargetKind = ctkWindow) and AOptions.BigCursor then
  begin
    // The drawn pointer is placed by mapping a screen position into the
    // frame, and a window's frames are a picture of something that moves
    // under us with no way to find out from the capture queue. Refusing
    // beats recording with a pointer somewhere plausible but wrong.
    AError := 'a big cursor applies to display recordings only';
    Exit;
  end;
  if (AOptions.TargetKind = ctkWindow)
    and (Length(AOptions.ExcludedWindowIDs) > 0) then
  begin
    // SCContentFilter's window initialiser takes no exclusion list, so
    // honouring these is impossible; failing beats ignoring them and
    // recording the border the caller asked to keep out.
    AError := 'excluded windows apply to display recordings only';
    Exit;
  end;
  for I := 0 to High(AOptions.ExcludedWindowIDs) do
    if AOptions.ExcludedWindowIDs[I] = 0 then
    begin
      AError := 'an excluded window id must be non-zero';
      Exit;
    end;
  if AOptions.HasRegion and ((AlignDimension(AOptions.Region.Width) = 0)
    or (AlignDimension(AOptions.Region.Height) = 0)) then
  begin
    AError := Format('--rect must be at least %dx%d points',
      [DimensionAlignment, DimensionAlignment]);
    Exit;
  end;
  if AOptions.AudioMode <> amNone then
  begin
    if AOptions.AudioSampleRate = 0 then
      AOptions.AudioSampleRate := DefaultAudioSampleRate;
    if AOptions.AudioChannelCount = 0 then
      AOptions.AudioChannelCount := DefaultAudioChannelCount;
    if AOptions.AudioBitRate = 0 then
      AOptions.AudioBitRate := DefaultAudioBitRate;
    if (AOptions.AudioSampleRate < MinAudioSampleRate)
      or (AOptions.AudioSampleRate > MaxAudioSampleRate) then
    begin
      AError := Format('audio sample rate must be between %d and %d Hz',
        [MinAudioSampleRate, MaxAudioSampleRate]);
      Exit;
    end;
    if (AOptions.AudioChannelCount < MinAudioChannelCount)
      or (AOptions.AudioChannelCount > MaxAudioChannelCount) then
    begin
      AError := Format('audio channel count must be %d or %d',
        [MinAudioChannelCount, MaxAudioChannelCount]);
      Exit;
    end;
    if (AOptions.AudioBitRate < MinAudioBitRate)
      or (AOptions.AudioBitRate > MaxAudioBitRate) then
    begin
      AError := Format('audio bit rate must be between %d and %d bits/s',
        [MinAudioBitRate, MaxAudioBitRate]);
      Exit;
    end;
  end;
  Result := True;
end;

function DefaultExportEffects: TExportEffects;
begin
  Result := Default(TExportEffects);
  Result.Cursor := ecmAsRecorded;
end;

function EffectsDrawCursor(const AEffects: TExportEffects): Boolean;
begin
  Result := AEffects.Cursor in [ecmAsRecorded, ecmSmooth, ecmBig];
end;

// Whether it asks for anything at all beyond what the recording already
// decided. A render with nothing to apply is a copy, and this is the
// question that says so. Implementation-only: the one caller is the
// validation below.
function EffectsAskForAnything(const AEffects: TExportEffects): Boolean;
begin
  Result := AEffects.ZoomOnClick or EffectsDrawCursor(AEffects);
end;

function EffectsAreDefault(const AEffects: TExportEffects): Boolean;
begin
  Result := (AEffects.Cursor = ecmAsRecorded) and not AEffects.ZoomOnClick;
end;

function ExportCursorModeName(AMode: TExportCursorMode): string;
begin
  case AMode of
    ecmNone: Result := 'none';
    ecmSmooth: Result := 'smooth';
    ecmBig: Result := 'big';
  else
    Result := 'as-recorded';
  end;
end;

function ParseExportCursorMode(const AText: string;
  out AMode: TExportCursorMode): Boolean;
var
  Normalized: string;
begin
  Result := True;
  AMode := ecmAsRecorded;
  Normalized := LowerCase(Trim(AText));
  if Normalized = 'as-recorded' then
    AMode := ecmAsRecorded
  else if Normalized = 'none' then
    AMode := ecmNone
  else if Normalized = 'smooth' then
    AMode := ecmSmooth
  else if Normalized = 'big' then
    AMode := ecmBig
  else
    Result := False;
end;

function ExportEffectsRequestCopy(const AText: string): Boolean;
var
  Part: string;
begin
  Result := False;
  for Part in AText.Split([',']) do
    if LowerCase(Trim(Part)) = 'none' then
      Exit(True);
end;

function ReconcileCursorAndEffects(const ACursorText, AEffectsText: string;
  var AEffects: TExportEffects; out AError: string): Boolean;
var
  FromFlag: TExportCursorMode;
  FlagGiven, CursorNamed: Boolean;
begin
  Result := False;
  AError := '';
  FlagGiven := Trim(ACursorText) <> '';
  if FlagGiven then
  begin
    if not ParseExportCursorMode(ACursorText, AEffects.Cursor) then
    begin
      AError := '--cursor must be as-recorded, none, smooth, or big';
      Exit;
    end;
  end;
  FromFlag := AEffects.Cursor;
  if not ParseExportEffectsNaming(AEffectsText, AEffects, CursorNamed,
    AError) then
    Exit;
  if FlagGiven and CursorNamed and (AEffects.Cursor <> FromFlag) then
  begin
    AError := '--cursor and --effects both name the pointer and disagree '
      + '(--cursor=' + Trim(ACursorText) + ' against --effects='
      + Trim(AEffectsText) + '); pass one of them';
    Exit;
  end;
  Result := True;
end;

function DescribeExportEffects(const AEffects: TExportEffects): string;
begin
  Result := '';
  if AEffects.ZoomOnClick then
    Result := 'zoom';
  case AEffects.Cursor of
    ecmNone: Result := Result + ',no-cursor';
    ecmSmooth: Result := Result + ',smooth-cursor';
    ecmBig: Result := Result + ',big-cursor';
  else
    Result := Result + ',as-recorded';
  end;
  if (Result <> '') and (Result[1] = ',') then
    Delete(Result, 1, 1);
end;

function ParseExportEffects(const AText: string;
  var AEffects: TExportEffects; out AError: string): Boolean;
var
  CursorNamed: Boolean;
begin
  Result := ParseExportEffectsNaming(AText, AEffects, CursorNamed, AError);
end;

function ParseExportEffectsNaming(const AText: string;
  var AEffects: TExportEffects; out ACursorNamed: Boolean;
  out AError: string): Boolean;
var
  Parts: TStringArray;
  Tokens: TStringArray;
  Token: string;
  I, Count: Integer;
  CursorNamed: Boolean;
begin
  Result := False;
  AError := '';
  CursorNamed := False;
  ACursorNamed := False;
  // The non-empty words, gathered first. Counting Parts instead was
  // wrong in a way nothing noticed: `--effects=none,` splits into two
  // parts, the second of which is nothing at all, and the "none cannot
  // be combined" rule fired on a list that combined it with nothing.
  Parts := AText.Split([',']);
  SetLength(Tokens, Length(Parts));
  Count := 0;
  for I := 0 to High(Parts) do
  begin
    Token := LowerCase(Trim(Parts[I]));
    if Token = '' then
      Continue;
    Tokens[Count] := Token;
    Inc(Count);
  end;

  for I := 0 to Count - 1 do
  begin
    Token := Tokens[I];
    if Token = 'none' then
    begin
      // Not a word among words: it is the whole answer, and mixing it
      // with a request would say two opposite things at once.
      if Count > 1 then
      begin
        AError := '--effects=none cannot be combined with another effect';
        Exit;
      end;
      AEffects.ZoomOnClick := False;
      AEffects.Cursor := ecmNone;
      // `none` names the cursor as surely as `no-cursor` does — it
      // means no pointer AND no zoom — so a --cursor beside it is a
      // contradiction the caller wants to hear about.
      ACursorNamed := True;
      Exit(True);
    end
    else if Token = 'zoom' then
      AEffects.ZoomOnClick := True
    else if (Token = 'as-recorded') or (Token = 'smooth-cursor')
      or (Token = 'big-cursor') or (Token = 'no-cursor') then
    begin
      if CursorNamed then
      begin
        AError := 'the cursor effects are one setting; name only one of '
          + 'as-recorded, smooth-cursor, big-cursor, no-cursor';
        Exit;
      end;
      CursorNamed := True;
      ACursorNamed := True;
      if Token = 'smooth-cursor' then
        AEffects.Cursor := ecmSmooth
      else if Token = 'big-cursor' then
        AEffects.Cursor := ecmBig
      else if Token = 'no-cursor' then
        AEffects.Cursor := ecmNone
      else
        AEffects.Cursor := ecmAsRecorded;
    end
    else
    begin
      AError := 'unknown effect "' + Token + '" (use zoom, as-recorded, '
        + 'smooth-cursor, big-cursor, no-cursor, or none)';
      Exit;
    end;
  end;
  Result := True;
end;

function DefaultExportOptions: TExportOptions;
begin
  Result := Default(TExportOptions);
  Result.Effects := DefaultExportEffects;
  Result.Format := efGif;
  Result.InputContainer := ocMPEG4;
  Result.OutputContainer := ocMPEG4;
  Result.FramesPerSecond := DefaultGifFramesPerSecond;
  Result.Width := GifWidthFromSource;
  Result.HasTrim := False;
  Result.TrimStartSeconds := 0;
  Result.HasTrimEnd := False;
  Result.TrimEndSeconds := 0;
  Result.Dither := True;
end;

function ExportFormatForPath(const APath: string;
  out AFormat: TExportFormat): Boolean;
var
  Extension: string;
begin
  Result := True;
  AFormat := efGif;
  Extension := LowerCase(ExtractFileExt(APath));
  if Extension = GifFileExtension then
    AFormat := efGif
  else if Extension = ApngFileExtension then
    AFormat := efApng
  else if (Extension = Mpeg4FileExtension)
    or (Extension = QuickTimeFileExtension) then
    AFormat := efMovie
  else
    Result := False;
end;

function ExportFormatName(AFormat: TExportFormat): string;
begin
  case AFormat of
    efApng: Result := 'APNG';
    efMovie: Result := 'movie';
  else
    Result := 'GIF';
  end;
end;

function LargeExportWarning(AFormat: TExportFormat; APixelWidth,
  APixelHeight, AFramesPerSecond: Integer; AOutputBytes: Int64): string;
var
  Reason, Advice: string;
begin
  Result := '';
  // A passthrough trim writes whatever the source already weighed;
  // there is no --width or --fps to suggest.
  if AFormat = efMovie then
    Exit;
  if Int64(APixelWidth) * APixelHeight >= LargeExportAreaPixels then
    Reason := Format('%dx%d is a large canvas for %s',
      [APixelWidth, APixelHeight, ExportFormatName(AFormat)])
  else if AOutputBytes >= LargeExportBytes then
    Reason := Format('%d MB is a large %s',
      [AOutputBytes div (1024 * 1024), ExportFormatName(AFormat)])
  else
    Exit;
  Advice := '';
  if APixelWidth > SuggestedNarrowWidth then
    Advice := Format('--width=%d', [SuggestedNarrowWidth]);
  if AFramesPerSecond > SuggestedSlowFramesPerSecond then
  begin
    if Advice <> '' then
      Advice := Advice + ' or ';
    Advice := Advice + Format('--fps=%d', [SuggestedSlowFramesPerSecond]);
  end;
  if Advice = '' then
    Advice := 'a shorter --trim';
  Result := Reason + ' — consider ' + Advice;
end;

// A fixed decimal point: --trim is a machine-readable flag, not a
// number typed into a form, so the host locale must not change it.
function InvariantSettings: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

function ParseTrimRange(const AText: string;
  out AStartSeconds, AEndSeconds: Double; out AHasEnd: Boolean): Boolean;
var
  Parts: TStringArray;
  Settings: TFormatSettings;
begin
  Result := False;
  AStartSeconds := 0;
  AEndSeconds := 0;
  AHasEnd := False;
  Parts := AText.Split([',']);
  if Length(Parts) <> 2 then
    Exit;
  Settings := InvariantSettings;
  if Trim(Parts[0]) <> '' then
    if not TryStrToFloat(Trim(Parts[0]), AStartSeconds, Settings) then
      Exit;
  if Trim(Parts[1]) <> '' then
  begin
    if not TryStrToFloat(Trim(Parts[1]), AEndSeconds, Settings) then
      Exit;
    AHasEnd := True;
  end;
  Result := True;
end;

function ValidateExportOptions(var AOptions: TExportOptions;
  out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  if AOptions.InputPath = '' then
  begin
    AError := 'an input movie is required (--in=demo.mp4)';
    Exit;
  end;
  if not ContainerForPath(AOptions.InputPath, AOptions.InputContainer) then
  begin
    AError := 'unsupported input extension "'
      + ExtractFileExt(AOptions.InputPath) + '" (use .mp4 or .mov)';
    Exit;
  end;
  if AOptions.OutputPath = '' then
  begin
    AError := 'an output path is required (--out=demo.gif)';
    Exit;
  end;
  if not ExportFormatForPath(AOptions.OutputPath, AOptions.Format) then
  begin
    AError := 'unsupported output extension "'
      + ExtractFileExt(AOptions.OutputPath)
      + '" (use .gif, .apng, .mp4, or .mov)';
    Exit;
  end;
  if SameText(ExpandFileName(AOptions.InputPath),
    ExpandFileName(AOptions.OutputPath)) then
  begin
    AError := '--in and --out are the same file';
    Exit;
  end;
  if (AOptions.Format = efMovie)
    and not EffectsAreDefault(AOptions.Effects) then
  begin
    // The scope limit, refused rather than ignored. A passthrough trim
    // copies coded samples; drawing or cropping anything in them would
    // mean decoding and re-encoding the whole video, which is the one
    // thing this output format exists not to do — and is exactly what
    // `knips render` is for.
    AError := 'export effects apply to .gif and .apng only, not to a '
      + 'passthrough trim; use `knips render` for an MP4 with effects';
    Exit;
  end;
  if AOptions.Format = efMovie then
  begin
    // A movie out of `export` is the passthrough trim and nothing else:
    // the coded samples are copied, so there is no rate to change and no
    // frame to scale, and without a range it would only be a copy.
    ContainerForPath(AOptions.OutputPath, AOptions.OutputContainer);
    if not AOptions.HasTrim then
    begin
      AError := 'a movie output is a passthrough trim, so --trim is '
        + 'required (--trim=1.5,3.5)';
      Exit;
    end;
    // `--trim=0,` parses, and it is a range — of the whole movie. It
    // would satisfy the rule above while being exactly the file copy the
    // rule exists to refuse, so it is named as such rather than run.
    if (AOptions.TrimStartSeconds <= 0) and not AOptions.HasTrimEnd then
    begin
      AError := 'that --trim is the whole movie, which would only copy '
        + 'the file; give an end (--trim=0,3.5) or a later start';
      Exit;
    end;
  end;
  if (AOptions.FramesPerSecond < MinGifFramesPerSecond)
    or (AOptions.FramesPerSecond > MaxGifFramesPerSecond) then
  begin
    AError := Format('--fps must be between %d and %d',
      [MinGifFramesPerSecond, MaxGifFramesPerSecond]);
    Exit;
  end;
  if (AOptions.Width <> GifWidthFromSource)
    and ((AOptions.Width < MinGifWidth) or (AOptions.Width > MaxGifWidth)) then
  begin
    AError := Format('--width must be between %d and %d pixels',
      [MinGifWidth, MaxGifWidth]);
    Exit;
  end;
  // Both of these name the ONE side at fault and echo it, which is what
  // lets the MCP rewriter turn them into something useful: a
  // token-for-token rewrite of "--trim cannot start before zero"
  // produced "trim_start/trim_end cannot start before zero", which
  // names both arguments and blames neither.
  if AOptions.TrimStartSeconds < 0 then
  begin
    AError := Format('--trim cannot start before zero (given %.2f)',
      [AOptions.TrimStartSeconds]);
    Exit;
  end;
  if AOptions.HasTrimEnd
    and (AOptions.TrimEndSeconds <= AOptions.TrimStartSeconds) then
  begin
    AError := Format('--trim must end after it starts (given %.2f to '
      + '%.2f)', [AOptions.TrimStartSeconds, AOptions.TrimEndSeconds]);
    Exit;
  end;
  Result := True;
end;

end.

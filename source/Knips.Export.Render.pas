unit Knips.Export.Render;

// The render pass: a raw take plus its event sidecar in, the deliverable
// MP4 out.
//
// **The product model this implements.** A recording is raw pixels and
// open metadata. The capture keeps the real pointer out of the frames and
// leaves the framing alone; everything a viewer is meant to see — the
// pointer, the zoom that answers a click — is put in afterwards, from the
// sidecar, by this unit. The raw take stays on disk beside the
// deliverable, so the same recording can be rendered again with different
// effects for as long as it is kept. That is the whole reason the sidecar
// exists (docs/event-sidecar.md) and the reason the recorder stopped
// baking things in.
//
// **What a render is made of.** AVAssetReader decodes the video track to
// BGRA (Knips.Export.MovieReader); each frame is cropped and scaled by
// the post-hoc zoom (Knips.Export.ZoomTrack) and has the pointer
// composited into it (Knips.Export.CursorEffect); AVAssetWriter encodes
// H.264 through an AVAssetWriterInputPixelBufferAdaptor. Every source
// frame keeps its own presentation stamp exactly, so the rendered file's
// timeline is the raw take's timeline and the sidecar's clock anchor is
// still exact for it.
//
// **Frames the capture never made.** ScreenCaptureKit delivers a frame
// when the content changes and not otherwise, and a raw take has no
// pointer in its pixels — so moving the mouse over a still window
// produces no frames at all. Measured on a real 8.10 s take, on the
// recorder as it stands today: 152 frames, 18.8 a second against a
// nominal 30, and **one** frame inside the 0.30 s the zoom takes to ease
// in. A doubling eased across one frame is a jump-cut, and that is what
// a janky zoom and a teleporting drawn pointer are.
//
// So the render *interleaves*. Between two source frames it re-presents
// the earlier one — the same pixels, which is honest, because nothing on
// screen changed or there would have been a frame — with the effect
// evaluated at the intervening instant, on a grid of the take's own
// nominal frame interval. A synthesised frame is only made when it would
// be a **different picture** from the one before it
// (Knips.Export.Cadence), so a zoom's hold costs nothing, a still
// stretch with nothing animating over it stays exactly as sparse as it
// was captured, and only the moving stretches are filled in. Source
// frames are never moved, never dropped and never re-timed, and a render
// with nothing to apply is still a byte copy.
//
// **It fills only BETWEEN captured frames.** There is no later frame to
// interleave towards at the end of a movie, and nothing here can invent
// one.
//
// That used to mean a take whose screen went static lost its tail —
// measured, before the fix: 17.54 s of recording, 88 frames, a movie
// 4.26 s long, with three of its four clicks past the end of the file.
// The fix was never in this pass. It shipped on the recorder side as the
// **idle heartbeat** (Knips.Recording.Heartbeat), which re-presents the
// last frame about twice a second while ScreenCaptureKit is idle and
// once more at the stop, so a movie now spans its take whatever the
// screen did — measured, 13.972 s of movie against 13.972 s of elapsed
// host time. This pass fills the gaps inside that movie; the two halves
// are separate on purpose and neither replaces the other.
//
// **Audio is copied, not re-encoded.** Every audio track of the source
// gets its own AVAssetReaderTrackOutput with *nil* output settings (the
// samples come back in the format they are stored in) feeding an
// AVAssetWriterInput with nil output settings and the source track's own
// format description as its sourceFormatHint. AVAssetWriterInput.h is
// explicit that this is passthrough, and equally explicit that writing
// passthrough into anything other than a QuickTime movie *requires* the
// hint — which is why the hint is read off the track rather than left
// nil. So a rendered take's AAC is bit-for-bit the take's own: no
// generation loss, no quality question to measure, and no reason for a
// render to make a recording sound worse.
//
// **The drawn pointer does not grow with the zoom.** The sprite is sized
// once, from the recording's base geometry, and stays that size in output
// pixels for the whole file — so at full zoom it is half the relative
// size the *real* pointer had in a live-zoom take. That is the trade
// Knips.Recording.CursorMath already states for Big Cursor, kept here for
// the same two reasons (resampling a sprite in the inner loop, and a
// drawn pointer that keeps its size reading as deliberate), and it is
// stated rather than hidden because it is the one thing about a rendered
// zoom that does not match the live one exactly.
//
// **When nothing is asked for, nothing is done.** A render with no
// effects that apply is a byte copy of the raw take. That is not an
// optimisation so much as a correctness rule: re-encoding a movie in
// order to produce the same movie is a generation of loss for nothing.
// A take that can take *no* effect at all is refused outright rather
// than duplicated — see Run.
//
// **The output is replaced atomically.** Everything is written to
// `<out>.knips-render-tmp` and renamed into place only once the movie is
// complete, because the interesting failure is not a render that returns
// an error — it is a render that is *killed*. Writing straight to the
// deliverable meant deleting a good file, opening AVAssetWriter on the
// name, and dying: measured, that left a zero-byte unplayable file where
// the recording used to be, and crash recovery never finds it because
// recovery scans sidecars and this one had none. A same-directory
// rename(2) on APFS is atomic, so the deliverable is either the old one
// or the new one and never a stub. The sidecar is written *after* the
// rename, for the same reason and in the same order.
//
// **Threading.** All main thread. There is no capture queue here and none
// of its rules apply; the two frameworks' completion handlers are global
// cdecl procedures that set a flag, and the main thread pumps
// CFRunLoopRunInMode until it turns — the same shape TMovieWriter.Finish
// and TMovieTrimSession use.

{$I Knips.inc}

interface

{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cblocks}
{$modeswitch cvar}

uses
  BaseUnix,
  Classes,
  ctypes,
  Math,
  SysUtils,

  CocoaAll,
  Knips.Capture.CoreMedia,
  Knips.Export.Atomic,
  Knips.Export.Bitmap,
  Knips.Export.Cadence,
  Knips.Export.CursorEffect,
  Knips.Export.MovieReader,
  Knips.Export.MovieWriter,
  Knips.Export.ZoomTrack,
  Knips.Options,
  Knips.Recording.LiveMath,
  Knips.Recording.Sidecar,
  MacOSAll;

{$linkframework AVFoundation}
{$linkframework CoreMedia}
{$linkframework CoreVideo}
{$linkframework Accelerate}

type
  TRenderReport = record
    InputPath: string;
    OutputPath: string;
    // The sidecar written beside the deliverable, or '' when none was.
    SidecarPath: string;
    PixelWidth: Integer;
    PixelHeight: Integer;
    FramesRead: Int64;
    FramesWritten: Int64;
    // Audio tracks carried across, and the coded samples copied into
    // them. Passthrough is always True when there is audio at all: this
    // unit has no re-encoding path, and would rather fail than quietly
    // put a recording through AAC twice.
    AudioTracks: Integer;
    AudioSamples: Int64;
    AudioPassthrough: Boolean;
    // Which effects actually reached the pixels, as opposed to which
    // were asked for. Effects that could not apply are never a reason to
    // fail a render — the deliverable is correct without them — so
    // these and the notes below are how a caller finds out.
    CursorDrawn: Boolean;
    CursorFrames: Int64;
    // Frames where the pointer was outside the rectangle the movie
    // shows, so nothing was drawn into them. Not a fault — the pointer
    // was somewhere this take does not show — but the difference
    // between "the pointer was drawn on 0 frames" and "the pointer was
    // off screen for the whole take", which is a question the count
    // alone cannot answer. Mirrors Big Cursor's CursorOffFrame.
    CursorOffFrameFrames: Int64;
    // Frames that were never captured, made by re-presenting the last
    // source frame with the effect evaluated at a new instant
    // (Knips.Export.Cadence). Zero when every effect window in the take
    // already had frames at the nominal rate — which a busy screen
    // produces and a still one does not.
    SynthesizedFrames: Int64;
    // The cadence they were made at, in frames per second: the take's
    // own configured rate. Zero when nothing was synthesised.
    SynthesisFramesPerSecond: Integer;
    ZoomApplied: Boolean;
    // Frames whose crop was not the whole frame; zero on a take where
    // nothing was clicked even with the zoom switched on.
    ZoomedFrames: Int64;
    // Frames the zoom was asked for and could not be applied to, because
    // the sample track had nothing to say about what they were showing —
    // a take whose movie runs past its own sidecar. Passed through whole
    // rather than cropped against a stale rectangle; never zero without
    // FramingNote saying so.
    UnframedFrames: Int64;
    UsableClicks: Integer;
    // The three notes, kept apart because they are three different
    // facts and a caller offering ONE effect must be able to show that
    // effect's own reason — the shape TExportReport already had.
    //
    // FramingNote is about the pixels rather than about an effect: some
    // frames of this deliverable show something the take could not
    // account for. It is the one that must never be crowded out, which
    // is why it is its own field and comes first in the summary.
    FramingNote: string;
    CursorNote: string;
    ZoomNote: string;
    // The three above through Knips.Options.EffectNoteSummary, for a
    // caller with one line — the menu's Last-error slot, the playback
    // title. Derived at the end of Run; never assigned directly.
    Note: string;
    // True when the render was a byte copy because nothing applied.
    Copied: Boolean;
    SourceDurationSeconds: Double;
    // Wall clock, and what it comes to per second of take. The number
    // that decides whether this can run on every stop or has to be
    // something the user asks for.
    ElapsedSeconds: Double;
    RealtimeFactor: Double;
    OutputBytes: Int64;
    // Lines of the take's event sidecar the loader could not use. Never
    // a failure — the loader is deliberately tolerant — but a hole in
    // the track this render drew from, so it is reported rather than
    // left inside TSidecarLog (Knips.Options.SidecarSkippedLinesNote).
    SidecarSkippedLines: Integer;
  end;

  // Per-frame progress for a caller with a window to update. Runs on the
  // thread that called Run, which is the main thread.
  TRenderProgressEvent = procedure(AFramesDone, AFramesTotal: Int64) of object;

  TRenderSession = class
  private
    FInputPath: string;
    FOutputPath: string;
    FEffects: TExportEffects;
    FReport: TRenderReport;
    FVerbose: Boolean;
    FOnProgress: TRenderProgressEvent;
    FLog: TSidecarLog;
    FReader: TMovieReader;
    FCursor: TExportCursor;
    FClicks: TZoomClickArray;
    FWalker: TZoomWalker;
    FBase: TLiveRect;
    // Whether the capture moved its own source rectangle during the
    // take (Follow Mouse, or a composited window recording's poll).
    // Decides whether the framing has to be looked up per frame or is
    // the base rectangle for the whole file.
    FFramingPanned: Boolean;
    // The audio side: one asset, one reader, one output and one input per
    // audio track of the source.
    FAudioAsset: AVAsset;
    FAudioReader: AVAssetReader;
    FAudioOutputs: array of AVAssetReaderTrackOutput;
    FAudioInputs: array of AVAssetWriterInput;
    FAudioFinished: array of Boolean;
    FWriter: AVAssetWriter;
    FVideoInput: AVAssetWriterInput;
    FAdaptor: id;
    FEstimatedFrames: Int64;
    // Where the movie is built before it is renamed onto FOutputPath.
    FTempPath: string;
    // Whether the caller asked, in so many words, for a copy —
    // `--effects=none` on the CLI, cursor "none" with zoom off over
    // MCP. It is the one request a render honours by applying nothing,
    // and without it a render that applies nothing is refused.
    FExplicitCopy: Boolean;
    // vImage's own scratch for the high-quality scaler, held across the
    // whole render rather than allocated per frame. Grown to fit,
    // never shrunk; freed in Destroy.
    FScaleScratch: Pointer;
    FScaleScratchSize: clong;
    // The frame synthesis (Knips.Export.Cadence). FHeldBuffer is the
    // last source frame, retained past the reader's own lifetime for it
    // — the reader's buffer is only valid until the next NextFrame, and
    // a synthesised frame is made from the frame *before* the one that
    // has just been read.
    FCadenceSeconds: Double;
    FHeldBuffer: CVPixelBufferRef;
    FHeldSeconds: Double;
    FHeldTimeScale: Int32;
    FLastValue: Int64;
    FLastShape: TRenderedFrameShape;
    FHasLastShape: Boolean;
    // Why the sidecar could not be read, when it could not. Kept so the
    // refusal below can say "this sidecar is version 2 and this knips
    // reads version 1" instead of "there is no event sidecar", which is
    // what AvailableExportEffects(nil) answers and is a different fact.
    FSidecarLoadError: string;
    function LoadSidecar: Boolean;
    procedure PrepareEffects;
    // The shape one frame would come out as at ASeconds, given that the
    // pixels behind it do not change: the crop and where the pointer
    // lands. Advances the zoom walk, which is monotonic, so it must be
    // called in increasing time order — which is what the frame loop
    // does.
    function ShapeAt(ASourceWidth, ASourceHeight: Integer;
      ASeconds: Double): TRenderedFrameShape;
    // What the whole frame shows at ASeconds, in the display's own
    // top-left points: the base rectangle for a take whose framing never
    // moved, and the sample track's own rectangle for one that panned.
    // False when the track has nothing to say about that instant, which
    // is the one case a zoom must not crop through — see FramingRectAt.
    function FramingAt(ASeconds: Double; out ARect: TLiveRect): Boolean;
    procedure HoldFrame(const AFrame: TMovieReaderFrame);
    procedure ReleaseHeldFrame;
    // The frames that belong between the held one and the next source
    // frame, if any do.
    function SynthesizeUpTo(ANextSeconds: Double;
      out AError: string): Boolean;
    // Blocks until the encoder will take another frame, moving audio
    // while it waits. False only when the writer has failed.
    function AwaitVideoInput: Boolean;
    function CopyRawTake(out AError: string): Boolean;
    // Renames the finished temporary onto the deliverable's name. The one
    // instant at which the old file stops being the answer.
    function CommitOutput(out AError: string): Boolean;
    // Removes the temporary AND anything the frameworks left beside it,
    // which is the scratch AVAssetWriter writes for a fast-start file.
    // Scoped to this render's own temporary name, so it can never match
    // the deliverable or a take. Called on every exit path there is: at
    // the start (a previous render's leftovers), after a successful
    // rename (the scratch), and after every failure (both).
    procedure SweepTemporaries;
    function OpenWriter(out AError: string): Boolean;
    function AddAudioTracks(out AError: string): Boolean;
    function RenderFrames(out AError: string): Boolean;
    function RenderOneFrame(APixelBuffer: CVPixelBufferRef;
      const ATime: CMTime; ASeconds: Double;
      out AError: string): Boolean;
    function PumpAudio: Boolean;
    function FinishWriter(out AError: string): Boolean;
    procedure Teardown;
    procedure WriteDeliverableSidecar;
    procedure MeasureOutput;
    procedure Progress(AFramesDone: Int64);
  public
    constructor Create(const AInputPath, AOutputPath: string;
      const AEffects: TExportEffects);
    destructor Destroy; override;
    // False with a one-line message on any failure; a partial output is
    // removed. An effect that could not be applied is not a failure —
    // see TRenderReport.Note.
    function Run(out AError: string): Boolean;
    property Report: TRenderReport read FReport;
    // Set before Run when the caller asked for a copy in so many words:
    // `--effects=none`, or MCP's cursor "none" with zoom off. Without
    // it, a render that would apply nothing is refused rather than
    // writing a duplicate of its input and calling it a deliverable.
    property ExplicitCopy: Boolean read FExplicitCopy write FExplicitCopy;
    property Verbose: Boolean read FVerbose write FVerbose;
    property OnProgress: TRenderProgressEvent read FOnProgress
      write FOnProgress;
  end;

// A finished report as the neutral facts Knips.Options composes the
// wording from. It is here rather than at each front end because both
// of them held the same fourteen assignments, in the same order, and a
// field added to TRenderReport had to be remembered in two places or
// silently vanish from one face's summary.
function RenderFactsOf(const AReport: TRenderReport): TRenderAppliedFacts;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // The render's writer is not a recorder: it is fed as fast as the
  // encoder will take frames, and when it will not the loop has nothing
  // to do but wait. A millisecond is short enough that the wait never
  // shows up in the render time and long enough not to be a spin.
  // Two minutes of idle slices. It bounds every wait in this unit, not
  // only the finish: a render runs on the app's MAIN thread, so a
  // framework that stops answering does not slow a render down, it hangs
  // the menu bar with no way out but Force Quit. Failing loudly after two
  // minutes costs a render that was going to fail anyway and gives the
  // user their app back.
  //
  // Counted in slices where nothing moved, so a render that is simply
  // slow — a long take, a busy encoder — never reaches it however long
  // it takes.
  FinishTimeoutSlices = 120000;
  // How often progress is reported and the autorelease pool drained.
  ProgressEveryFrames = 30;
  // How much of a `--effects=none` take is copied between two looks at
  // the stop flag. See CopyRawTake.
  CopyChunkBytes = 1024 * 1024;
  PoolDrainEveryFrames = 128;
  // vImage_Flags. kvImageHighQualityResampling (32) picks the more
  // expensive Lanczos path; a zoom is an *upscale* of screen content,
  // where the cheap kernel's ringing on text is the first thing anybody
  // notices. kvImageNoFlags is 0 and is what the temp-buffer query takes.
  kvImageNoFlags = 0;
  kvImageHighQualityResampling = 32;
  // Ask for the scratch size instead of doing the work. vImage returns
  // the number of bytes its kernel wants rather than scaling anything.
  kvImageGetTempBufferSize = 128;

type
  vImagePixelCount = culong;

  vImage_Buffer = record
    data: Pointer;
    height: vImagePixelCount;
    width: vImagePixelCount;
    rowBytes: csize_t;
  end;
  PvImage_Buffer = ^vImage_Buffer;

  CVPixelBufferPoolRef = Pointer;

  // AVAssetWriterInputPixelBufferAdaptor: the supported way to hand
  // AVAssetWriter frames this program has made rather than frames a
  // capture delivered. Its pool vends IOSurface-backed buffers of exactly
  // the shape the encoder wants, which is why the render allocates
  // through it rather than with CVPixelBufferCreate.
  AVAssetWriterInputPixelBufferAdaptor = objcclass external (NSObject)
    class function AssetWriterInputPixelBufferAdaptorWithAssetWriterInput_sourcePixelBufferAttributes(
      AInput: AVAssetWriterInput; AAttributes: NSDictionary): id;
      message 'assetWriterInputPixelBufferAdaptorWithAssetWriterInput:sourcePixelBufferAttributes:';
    function PixelBufferPool: CVPixelBufferPoolRef; message 'pixelBufferPool';
    function AppendPixelBuffer_withPresentationTime(
      APixelBuffer: CVPixelBufferRef; APresentationTime: CMTime): ObjCBOOL;
      message 'appendPixelBuffer:withPresentationTime:';
  end;

  // The two framework calls the units this one builds on did not need.
  // Both are declared as categories rather than as second copies of the
  // class: a category is a binding onto the class the other unit already
  // declares, so there is one AVAssetWriterInput in the program and not
  // two that happen to have the same selectors (ADR-0002 allows exactly
  // this kind of external binding).
  KnipsWriterInputPassthrough = objccategory external (AVAssetWriterInput)
    // Passthrough into an MP4 needs the source's own format description;
    // see the unit comment.
    class function AssetWriterInputWithMediaType_outputSettings_sourceFormatHint(
      AMediaType: NSString; AOutputSettings: NSDictionary;
      ASourceFormatHint: CMFormatDescriptionRef): id;
      message 'assetWriterInputWithMediaType:outputSettings:sourceFormatHint:';
  end;

  KnipsAssetTrackFormats = objccategory external (AVAssetTrack)
    function FormatDescriptions: NSArray; message 'formatDescriptions';
  end;

var
  kCVPixelBufferWidthKey: CFStringRef;
    external name '_kCVPixelBufferWidthKey';
  kCVPixelBufferHeightKey: CFStringRef;
    external name '_kCVPixelBufferHeightKey';

function CVPixelBufferPoolCreatePixelBuffer(AAllocator: CFAllocatorRef;
  APool: CVPixelBufferPoolRef; APixelBufferOut: Pointer): CVReturn;
  external name '_CVPixelBufferPoolCreatePixelBuffer';

function vImageScale_ARGB8888(ASource: PvImage_Buffer;
  ADestination: PvImage_Buffer; ATempBuffer: Pointer;
  AFlags: cuint32): clong; external name '_vImageScale_ARGB8888';

var
  // Set from AVAssetWriter's completion queue; polled by the main thread.
  GRenderFinishReady: Boolean = False;

procedure RenderFinishHandler; cdecl;
begin
  GRenderFinishReady := True;
end;

{ TRenderSession }

constructor TRenderSession.Create(const AInputPath, AOutputPath: string;
  const AEffects: TExportEffects);
begin
  inherited Create;
  FInputPath := AInputPath;
  FOutputPath := AOutputPath;
  FEffects := AEffects;
  FVerbose := True;
end;

destructor TRenderSession.Destroy;
begin
  Teardown;
  FreeAndNil(FCursor);
  FreeAndNil(FReader);
  FreeAndNil(FLog);
  if FScaleScratch <> nil then
  begin
    FreeMem(FScaleScratch);
    FScaleScratch := nil;
    FScaleScratchSize := 0;
  end;
  inherited Destroy;
end;

procedure TRenderSession.Teardown;
var
  I: Integer;
begin
  ReleaseHeldFrame;
  for I := 0 to High(FAudioOutputs) do
    if FAudioOutputs[I] <> nil then
    begin
      FAudioOutputs[I].release;
      FAudioOutputs[I] := nil;
    end;
  for I := 0 to High(FAudioInputs) do
    if FAudioInputs[I] <> nil then
    begin
      FAudioInputs[I].release;
      FAudioInputs[I] := nil;
    end;
  if FAudioReader <> nil then
  begin
    if FAudioReader.status = AVAssetReaderStatusReading then
      FAudioReader.cancelReading;
    FAudioReader.release;
    FAudioReader := nil;
  end;
  if FAudioAsset <> nil then
  begin
    FAudioAsset.release;
    FAudioAsset := nil;
  end;
  if FAdaptor <> nil then
  begin
    AVAssetWriterInputPixelBufferAdaptor(FAdaptor).release;
    FAdaptor := nil;
  end;
  if FVideoInput <> nil then
  begin
    FVideoInput.release;
    FVideoInput := nil;
  end;
  if FWriter <> nil then
  begin
    FWriter.release;
    FWriter := nil;
  end;
end;

procedure TRenderSession.Progress(AFramesDone: Int64);
begin
  if Assigned(FOnProgress) then
    FOnProgress(AFramesDone, FEstimatedFrames);
end;

function TRenderSession.LoadSidecar: Boolean;
var
  Error: string;
begin
  FreeAndNil(FLog);
  FLog := TSidecarLog.Create;
  Result := FLog.LoadFromFile(SidecarPathFor(FInputPath), Error);
  if Result then
    FReport.SidecarSkippedLines := FLog.SkippedLines;
  if not Result then
  begin
    FSidecarLoadError := Error;
    FreeAndNil(FLog);
  end;
  // There used to be a note set here — "no event sidecar beside this
  // take, so nothing could be rendered into it" — and nothing could ever
  // read it. Run asks AvailableExportEffects(nil) next, which answers
  // "there is no event sidecar for this recording", and a take that can
  // take no effect at all is REFUSED with that reason rather than
  // rendered. The render returns False and the report is never looked
  // at. The refusal carries the message; a second copy of it here only
  // looked like it did.
end;

// What actually applies, decided once. Every "no" here is answered rather
// than raised: a take that cannot take an effect still renders, and the
// note says which one it lost.
procedure TRenderSession.PrepareEffects;
var
  Available: TSidecarEffectAvailability;
  Note: string;
begin
  if FLog = nil then
    Exit;
  Available := AvailableExportEffects(FLog);
  FBase := LiveRect(FLog.Header.BaseX, FLog.Header.BaseY,
    FLog.Header.BaseWidth, FLog.Header.BaseHeight);
  FFramingPanned := not HasUntouchedFraming(FLog.Header);

  if FEffects.ZoomOnClick then
  begin
    if not Available.CanZoomOnClick then
    begin
      // The ZOOM's own reason, not the summary: a take with a baked
      // pointer and a panned framing has two, and the summary carries
      // the pointer's — which is not why the zoom was refused.
      FReport.ZoomNote := Available.ZoomReason;
    end
    else
    begin
      FClicks := ZoomClicksFromLog(FLog);
      FReport.UsableClicks := Length(FClicks);
      if FReport.UsableClicks = 0 then
        FReport.ZoomNote := 'nothing was clicked inside the recorded '
          + 'rectangle, so there was nothing to zoom to'
      else
      begin
        FReport.ZoomApplied := True;
        FWalker := ZoomWalkerStart(FBase, FEffects.ZoomFactor,
          FEffects.ZoomHoldSeconds);
      end;
    end;
  end;

  if EffectsDrawCursor(FEffects) then
  begin
    FCursor := TExportCursor.Create;
    // The render's own log, lent rather than loaded again: this pass
    // used to parse the take's sidecar TWICE, once here and once inside
    // TExportCursor, at the full cost of the parse each time.
    if FCursor.Prepare(FInputPath, FEffects, FReader.PixelWidth,
      FReader.PixelHeight, FLog, Note) then
      FReport.CursorDrawn := True
    else
    begin
      if FCursor.Asked then
        FReport.CursorNote := Note;
      FreeAndNil(FCursor);
    end;
  end;
end;

// A render with nothing to apply. Copied rather than re-encoded: the two
// files would be the same picture and one of them would have been through
// H.264 twice. Into the temporary like everything else, so a copy that is
// killed half way cannot leave a truncated movie under the deliverable's
// name either.
function TRenderSession.CopyRawTake(out AError: string): Boolean;
var
  Source, Destination: TFileStream;
  Remaining: Int64;
  Chunk: Int64;
begin
  Result := False;
  AError := '';
  Source := nil;
  Destination := nil;
  try
    try
      if not ClaimTemporary(FTempPath, AError) then
        Exit;
      Source := TFileStream.Create(FInputPath, fmOpenRead or fmShareDenyNone);
      Destination := TFileStream.Create(FTempPath, fmCreate);
      // In chunks rather than one CopyFrom(Source, 0), for two reasons.
      // Ctrl-C: a whole-file copy is a single call nothing can
      // interrupt, so a stop during a multi-gigabyte `--effects=none`
      // was noticed only once the copy had finished — the same wait the
      // rendering path does not make anybody sit through, since it asks
      // between frames (RenderFrames). And truncation: CopyFrom with a
      // count of 0 loops on a plain Read and ENDS QUIETLY on a short one
      // (FPC 3.2.2 streams.inc), so a take that could not be read whole
      // was committed as a shorter deliverable with nothing said;
      // CopyFrom with a count uses ReadBuffer, which raises, and the
      // except below turns that into a failure and a swept temporary. A
      // megabyte is small enough that the stop answers promptly and
      // large enough that the poll costs nothing next to the I/O.
      //
      // The failure is handed on exactly as a cancelled render's is:
      // the caller sweeps the temporary and the previous deliverable
      // was never touched.
      Remaining := Source.Size;
      while Remaining > 0 do
      begin
        if StopRequested then
        begin
          AError := ExportCancelledMessage;
          Exit;
        end;
        Chunk := Remaining;
        if Chunk > CopyChunkBytes then
          Chunk := CopyChunkBytes;
        Destination.CopyFrom(Source, Chunk);
        Dec(Remaining, Chunk);
      end;
      Result := True;
    except
      on E: Exception do
        AError := 'could not copy the take: ' + E.Message;
    end;
  finally
    Destination.Free;
    Source.Free;
  end;
  FReport.Copied := Result;
end;

// Both are Knips.Export.Atomic's, which every writer that can replace a
// file the user already has now shares. They stay as methods because the
// temporary's path is this session's, and because the render calls them
// from six places.
function RenderFactsOf(const AReport: TRenderReport): TRenderAppliedFacts;
begin
  Result := DefaultRenderAppliedFacts;
  Result.ZoomApplied := AReport.ZoomApplied;
  Result.ZoomedFrames := AReport.ZoomedFrames;
  Result.FramesWritten := AReport.FramesWritten;
  Result.UsableClicks := AReport.UsableClicks;
  Result.CursorDrawn := AReport.CursorDrawn;
  Result.CursorFrames := AReport.CursorFrames;
  Result.CursorOffFrameFrames := AReport.CursorOffFrameFrames;
  Result.SynthesizedFrames := AReport.SynthesizedFrames;
  Result.SynthesisFramesPerSecond := AReport.SynthesisFramesPerSecond;
  Result.AudioTracks := AReport.AudioTracks;
  Result.AudioPassthrough := AReport.AudioPassthrough;
  Result.AudioSamples := AReport.AudioSamples;
end;

function TRenderSession.CommitOutput(out AError: string): Boolean;
begin
  Result := CommitTemporary(FTempPath, FOutputPath, AError);
end;

procedure TRenderSession.SweepTemporaries;
begin
  SweepTemporary(FTempPath);
end;

function TRenderSession.OpenWriter(out AError: string): Boolean;
var
  URL: NSURL;
  Error: NSError;
  Container: TOutputContainer;
  FileType: NSString;
  Settings: NSDictionary;
  Attributes: NSMutableDictionary;
  Rate, BitRate: Integer;
begin
  Result := False;
  AError := '';
  // The one place the frame size this pass will allocate against is
  // settled, so the one place to ask whether it is allocatable. The
  // reader has already refused a picture bigger than the canvas budget
  // — twice, once on the header's claim and once on the decoded picture
  // — and this asks again at the moment the pixel-buffer pool and the
  // vImage scratch are about to be sized from it. Cheap, and the last
  // thing standing between a hostile movie and a multi-gigabyte
  // allocation.
  if not BgraCanvasFits(FReader.PixelWidth, FReader.PixelHeight) then
  begin
    AError := Format('%s decodes to a %dx%d picture: %s',
      [FInputPath, FReader.PixelWidth, FReader.PixelHeight,
      BgraCanvasRefusal(FReader.PixelWidth, FReader.PixelHeight)]);
    Exit;
  end;
  // The TEMPORARY is what is opened and what is replaced; the
  // deliverable is not touched until the rename in CommitOutput. The
  // claim also writes the owner marker beside it, which is what stops
  // the next `knips record` sweeping this render's scratch out from
  // under it.
  if not ClaimTemporary(FTempPath, AError) then
    Exit;
  if not ContainerForPath(FOutputPath, Container) then
    Container := ocMPEG4;
  if Container = ocQuickTime then
    FileType := AVFileTypeQuickTimeMovie
  else
    FileType := AVFileTypeMPEG4;

  // stringWithUTF8String:, never NSSTR — the same non-ASCII path trap the
  // recorder's writer documents.
  URL := NSURL.fileURLWithPath(
    NSString.stringWithUTF8String(PAnsiChar(FTempPath)));
  Error := nil;
  FWriter := AVAssetWriter(AVAssetWriter.assetWriterWithURL_fileType_error(
    URL, FileType, @Error));
  if FWriter = nil then
  begin
    if Error <> nil then
      AError := 'AVAssetWriter: '
        + string(Error.localizedDescription.UTF8String)
    else
      AError := 'AVAssetWriter could not be created';
    Exit;
  end;
  FWriter.retain;
  // A deliverable is a finished file rather than a recording in progress:
  // no movie fragments to survive a crash with, and the index in front
  // where a player streaming it over a network wants it.
  //
  // **This flag is what makes the render leave scratch behind**, and the
  // trade was measured both ways on the same take rather than assumed.
  // AVAssetWriter cannot know how big `moov` will be until the media is
  // written, so to put it FIRST it writes the media to a scratch file
  // beside the output and assembles the final file afterwards. Under the
  // macOS sandbox that scratch is named `<output>.sb-<token>` with a
  // fresh token each time, and nothing deletes it:
  //
  //   flag ON   ftyp moov mdat  (fast start)   + one 3.7 MB shadow per
  //                                              render, accumulating —
  //                                              11.1 MB after three
  //   flag OFF  ftyp mdat moov  (no fast start) + no shadow at all
  //
  // It stays ON. The deliverable is the file people upload and send, and
  // a front-loaded index is a real property of it; the scratch is
  // deterministic, named after a path this unit chose, and swept the
  // instant the rename succeeds (SweepTemporaries). Fixing the leak is
  // one glob in a code path that has to exist anyway for killed renders,
  // and it is not the sort of fix that can rot: the proof is that three
  // successive renders leave an empty directory.
  //
  // To go the other way — if peak disk during a render ever matters more
  // than fast start — this one line is the whole change, and the file
  // stays perfectly playable either way.
  FWriter.setShouldOptimizeForNetworkUse(ObjCBOOL(True));

  // The rate this file is CONFIGURED for, which is the take's own and
  // not the average the raw file came out at. `nominalFrameRate` is
  // total frames over duration, and a take of a still screen is carried
  // by the idle heartbeat rather than by capture: measured 6.3 fps on a
  // 1280x720 take the recorder itself encoded at 30 fps and
  // 2.49 Mbit/s. Configured from that average, this pass asked for
  // SuggestedBitRate at 6 fps — which is the 1 Mbit/s floor — and a
  // keyframe every 24 frames instead of every 120, and then synthesised
  // frames at the take's real 30 fps into it: exactly the stretches
  // where the zoom and the pointer are moving got a fraction of the
  // budget. FReport.SynthesisFramesPerSecond is the sidecar header's own
  // rate, resolved in Run before this is called, and it is the rate the
  // frames are actually produced at.
  // Already resolved and clamped into 1..120 by Run, from the header
  // where there is one and from the reader's nominal rate where there is
  // not; this is the one place it is read for the writer.
  Rate := FReport.SynthesisFramesPerSecond;
  BitRate := SuggestedBitRate(FReport.PixelWidth, FReport.PixelHeight, Rate);
  // The recorder's own settings builder, called with this pass's
  // numbers: the two used to be a dictionary each, built key for key the
  // same, and a drift between them is a worse file that nothing reports.
  Settings := BuildH264OutputSettings(FReport.PixelWidth,
    FReport.PixelHeight, Rate, BitRate);

  FVideoInput := AVAssetWriterInput(
    AVAssetWriterInput.assetWriterInputWithMediaType_outputSettings(
    AVMediaTypeVideo, Settings));
  if FVideoInput = nil then
  begin
    AError := 'the render''s video input could not be created';
    Exit;
  end;
  FVideoInput.retain;
  // False, unlike the recorder's: this input is fed from a decoder as
  // fast as it will take frames, and real-time mode would have it drop
  // what it could not keep up with. A render drops nothing.
  FVideoInput.setExpectsMediaDataInRealTime(ObjCBOOL(False));
  if not FWriter.canAddInput(FVideoInput) then
  begin
    AError := 'AVAssetWriter rejected the render''s video input';
    Exit;
  end;
  FWriter.addInput(FVideoInput);

  Attributes := NSMutableDictionary.dictionaryWithCapacity(3);
  Attributes.setObject_forKey(
    NSNumber.numberWithInt(Integer(kCVPixelFormatType_32BGRA)),
    id(kCVPixelBufferPixelFormatTypeKey));
  Attributes.setObject_forKey(NSNumber.numberWithInt(FReport.PixelWidth),
    id(kCVPixelBufferWidthKey));
  Attributes.setObject_forKey(NSNumber.numberWithInt(FReport.PixelHeight),
    id(kCVPixelBufferHeightKey));
  FAdaptor := AVAssetWriterInputPixelBufferAdaptor.AssetWriterInputPixelBufferAdaptorWithAssetWriterInput_sourcePixelBufferAttributes(
    FVideoInput, Attributes);
  if FAdaptor = nil then
  begin
    AError := 'the render''s pixel buffer adaptor could not be created';
    Exit;
  end;
  AVAssetWriterInputPixelBufferAdaptor(FAdaptor).retain;

  if not AddAudioTracks(AError) then
    Exit;

  if not FWriter.startWriting then
  begin
    AError := 'startWriting failed for the render';
    if FWriter.error <> nil then
      AError := AError + ': '
        + string(FWriter.error.localizedDescription.UTF8String);
    Exit;
  end;
  Result := True;
end;

// One passthrough input and one passthrough reader output per audio track
// the source has. Nothing is decoded and nothing is encoded; see the unit
// comment for why the format hint is not optional.
function TRenderSession.AddAudioTracks(out AError: string): Boolean;
var
  URL: NSURL;
  Error: NSError;
  Tracks: NSArray;
  Track: AVAssetTrack;
  Formats: NSArray;
  Hint: CMFormatDescriptionRef;
  I, Count: Integer;
begin
  Result := False;
  AError := '';
  URL := NSURL.fileURLWithPath(
    NSString.stringWithUTF8String(PAnsiChar(FInputPath)));
  FAudioAsset := AVAsset(AVURLAsset.URLAssetWithURL_options(URL, nil));
  if FAudioAsset = nil then
  begin
    AError := 'AVURLAsset could not open ' + FInputPath + ' for its audio';
    Exit;
  end;
  FAudioAsset.retain;
  Tracks := FAudioAsset.tracksWithMediaType(AVMediaTypeAudio);
  if Tracks = nil then
    Exit(True);
  Count := Integer(Tracks.count);
  if Count = 0 then
    Exit(True);

  Error := nil;
  FAudioReader := AVAssetReader(AVAssetReader.assetReaderWithAsset_error(
    FAudioAsset, @Error));
  if FAudioReader = nil then
  begin
    AError := 'AVAssetReader could not be created for the audio';
    Exit;
  end;
  FAudioReader.retain;

  SetLength(FAudioOutputs, Count);
  SetLength(FAudioInputs, Count);
  SetLength(FAudioFinished, Count);
  for I := 0 to Count - 1 do
  begin
    Track := AVAssetTrack(Tracks.objectAtIndex(I));
    Formats := Track.FormatDescriptions;
    if (Formats = nil) or (Formats.count = 0) then
    begin
      AError := 'an audio track of ' + FInputPath + ' does not say what '
        + 'format it is in, so it cannot be copied without re-encoding';
      Exit;
    end;
    Hint := CMFormatDescriptionRef(Formats.objectAtIndex(0));
    // nil output settings on both sides: the samples come out coded and
    // go in coded.
    FAudioOutputs[I] := AVAssetReaderTrackOutput(
      AVAssetReaderTrackOutput.assetReaderTrackOutputWithTrack_outputSettings(
      Track, nil));
    if FAudioOutputs[I] = nil then
    begin
      AError := 'an audio reader output could not be created';
      Exit;
    end;
    FAudioOutputs[I].retain;
    if not FAudioReader.canAddOutput(FAudioOutputs[I]) then
    begin
      AError := 'AVAssetReader rejected an audio output';
      Exit;
    end;
    FAudioReader.addOutput(FAudioOutputs[I]);

    FAudioInputs[I] := AVAssetWriterInput(
      AVAssetWriterInput.AssetWriterInputWithMediaType_outputSettings_sourceFormatHint(
      AVMediaTypeAudio, nil, Hint));
    if FAudioInputs[I] = nil then
    begin
      AError := 'a passthrough audio input could not be created';
      Exit;
    end;
    FAudioInputs[I].retain;
    FAudioInputs[I].setExpectsMediaDataInRealTime(ObjCBOOL(False));
    if not FWriter.canAddInput(FAudioInputs[I]) then
    begin
      AError := 'AVAssetWriter refused to copy an audio track without '
        + 're-encoding it';
      Exit;
    end;
    FWriter.addInput(FAudioInputs[I]);
  end;
  if not FAudioReader.startReading then
  begin
    AError := 'startReading failed for the audio';
    Exit;
  end;
  FReport.AudioTracks := Count;
  FReport.AudioPassthrough := True;
  Result := True;
end;

// One decoded frame into one encoded frame. The crop is settled in whole
// pixels by ZoomFrameCrop, and a crop that is the whole frame is copied
// rather than resampled — a scale from a size to itself is not free and
// is not lossless either.
//
// The pixels and the stamp are separate arguments rather than one
// TMovieReaderFrame because a synthesised frame is the *held* frame's
// pixels at a stamp of the render's own choosing; everything below is
// the same either way, which is the property that makes the two kinds of
// frame indistinguishable in the output.
function TRenderSession.RenderOneFrame(APixelBuffer: CVPixelBufferRef;
  const ATime: CMTime; ASeconds: Double;
  out AError: string): Boolean;
var
  Status: CVReturn;
  Destination: CVPixelBufferRef;
  SourceBase, DestinationBase: Pointer;
  SourceStride, DestinationStride, SourceWidth, SourceHeight, Y: Integer;
  Crop: TZoomCrop;
  Source, Framing: TLiveRect;
  FramingKnown: Boolean;
  From, Onto: vImage_Buffer;
  Needed: clong;
  ScaleError: clong;
  Pool: CVPixelBufferPoolRef;
begin
  Result := False;
  AError := '';
  Destination := nil;
  Pool := AVAssetWriterInputPixelBufferAdaptor(FAdaptor).PixelBufferPool;
  if Pool = nil then
  begin
    AError := 'the render''s pixel buffer pool is not available';
    Exit;
  end;
  Status := CVPixelBufferPoolCreatePixelBuffer(nil, Pool, @Destination);
  if (Status <> kCVReturn_Success) or (Destination = nil) then
  begin
    AError := Format('could not allocate a frame to render into '
      + '(CVPixelBufferPoolCreatePixelBuffer returned %d)', [Status]);
    Exit;
  end;
  try
    Status := CVPixelBufferLockBaseAddress(APixelBuffer,
      kCVPixelBufferLock_ReadOnly);
    if Status <> kCVReturn_Success then
    begin
      AError := Format('could not read the frame at %.2fs '
        + '(CVPixelBufferLockBaseAddress returned %d)',
        [ASeconds, Status]);
      Exit;
    end;
    try
      if CVPixelBufferLockBaseAddress(Destination, 0)
        <> kCVReturn_Success then
      begin
        AError := 'could not lock the frame to render into';
        Exit;
      end;
      try
        SourceBase := CVPixelBufferGetBaseAddress(APixelBuffer);
        SourceStride := Integer(CVPixelBufferGetBytesPerRow(
          APixelBuffer));
        SourceWidth := Integer(CVPixelBufferGetWidth(APixelBuffer));
        SourceHeight := Integer(CVPixelBufferGetHeight(APixelBuffer));
        DestinationBase := CVPixelBufferGetBaseAddress(Destination);
        DestinationStride := Integer(CVPixelBufferGetBytesPerRow(
          Destination));
        if (SourceBase = nil) or (DestinationBase = nil) then
        begin
          AError := Format('a frame at %.2fs has no pixels',
            [ASeconds]);
          Exit;
        end;

        Crop := Default(TZoomCrop);
        Crop.Width := SourceWidth;
        Crop.Height := SourceHeight;
        Crop.Identity := True;
        // The whole frame shows the rectangle the capture was READING at
        // this instant, which on a panned take is not the base one. The
        // zoom crops inside it — the live effect's own composition, base
        // then window then source (Knips.Recording.LiveMath).
        //
        // When the track cannot say what this frame was showing, the
        // frame is passed through WHOLE rather than cropped against a
        // guess: a crop is only as good as the rectangle it is measured
        // from, and showing everything that was captured is the one
        // answer that cannot be wrong.
        //
        // The POINTER is handed the same verdict, and that is the part
        // that is easy to get wrong. Past the end of the track the only
        // rectangle this function can name is the header's base one —
        // which for a panned take is not what the frame shows, and
        // forcing it on the sprite lands the pointer somewhere it never
        // was (measured on a truncated take: 257 x 241 output pixels
        // out). So the sprite is placed with AHasSource False, which
        // falls back to the last rectangle the SAMPLE TRACK actually
        // holds — the same "hold the last thing known" the interpolator
        // does with position, and the same answer the GIF and APNG
        // pipeline reaches by leaving its crop off.
        FramingKnown := FramingAt(ASeconds, Framing);
        Source := Framing;
        if FReport.ZoomApplied and FramingKnown then
        begin
          FWalker := ZoomWalkerAdvance(FWalker, FClicks, ASeconds);
          Source := ZoomWalkerSourceRectIn(FWalker, Framing);
          Crop := ZoomFrameCrop(SourceWidth, SourceHeight, Framing,
            Source);
        end;
        // Counted whether or not a zoom was asked for. A frame that
        // could not be placed is a frame that could not be placed, and
        // under the app's own defaults — pointer on, zoom off — this was
        // the one path that mis-drew in silence.
        if not FramingKnown then
          Inc(FReport.UnframedFrames);

        if Crop.Identity then
        begin
          // The identity path copies the WHOLE source frame into the
          // whole destination, so the two have to be the same size —
          // and it used to take that on trust from the track's
          // dimensions, which is fine for a knips take and not fine for
          // the input surface this command actually has: `knips render`
          // takes any MP4 anybody names. A frame smaller than the track
          // claims made this read past the end of the decoded buffer,
          // one row at a time.
          //
          // Refused rather than clipped. Clipping would leave part of
          // every output frame holding whatever the pool's buffer had in
          // it, which is a worse answer than a message: a movie whose
          // frames are not the size its track says is not something this
          // render can turn into a deliverable.
          if (SourceWidth <> FReport.PixelWidth)
            or (SourceHeight <> FReport.PixelHeight) then
          begin
            AError := Format('the frame at %.2fs is %dx%d but this '
              + 'movie''s video track says %dx%d; a render cannot mix '
              + 'frame sizes', [ASeconds, SourceWidth, SourceHeight,
              FReport.PixelWidth, FReport.PixelHeight]);
            Exit;
          end;
          // Row by row, because a CVPixelBuffer's stride is padded and
          // the two need not agree.
          for Y := 0 to FReport.PixelHeight - 1 do
            Move((PByte(SourceBase) + PtrInt(Y) * SourceStride)^,
              (PByte(DestinationBase) + PtrInt(Y) * DestinationStride)^,
              FReport.PixelWidth * 4);
        end
        else
        begin
          From.data := PByte(SourceBase) + PtrInt(Crop.Y) * SourceStride
            + PtrInt(Crop.X) * 4;
          From.width := Crop.Width;
          From.height := Crop.Height;
          From.rowBytes := SourceStride;
          Onto.data := DestinationBase;
          Onto.width := FReport.PixelWidth;
          Onto.height := FReport.PixelHeight;
          Onto.rowBytes := DestinationStride;
          // The scratch buffer, ours rather than vImage's. Passing nil
          // makes it allocate and free a Lanczos workspace per frame —
          // measured at 111 MB of reclaimable churn over one render.
          // The size is asked for first, because a zoom's crop changes
          // shape between frames and an undersized scratch is not a
          // slow render, it is a corrupted one; the buffer only ever
          // grows, so after the first few frames the query is all that
          // happens.
          Needed := vImageScale_ARGB8888(@From, @Onto, nil,
            kvImageGetTempBufferSize or kvImageHighQualityResampling);
          if Needed > FScaleScratchSize then
          begin
            ReAllocMem(FScaleScratch, Needed);
            FScaleScratchSize := Needed;
          end;
          ScaleError := vImageScale_ARGB8888(@From, @Onto, FScaleScratch,
            kvImageHighQualityResampling);
          if ScaleError <> 0 then
          begin
            AError := Format('scaling the frame at %.2fs failed '
              + '(vImageScale_ARGB8888 returned %d)',
              [ASeconds, Int64(ScaleError)]);
            Exit;
          end;
          Inc(FReport.ZoomedFrames);
        end;

        // After the crop and the scale: the sprite is drawn at the
        // output's own scale, and the pointer belongs on top of the
        // picture rather than inside it.
        if FCursor <> nil then
          FCursor.DrawIntoPixels(DestinationBase, DestinationStride,
            FReport.PixelWidth, FReport.PixelHeight, ASeconds,
            FramingKnown, Source.X, Source.Y, Source.Width,
            Source.Height);
      finally
        CVPixelBufferUnlockBaseAddress(Destination, 0);
      end;
    finally
      CVPixelBufferUnlockBaseAddress(APixelBuffer,
        kCVPixelBufferLock_ReadOnly);
    end;

    // The container's own stamp, not one rebuilt from seconds: this is
    // what makes the deliverable's timeline the raw take's timeline
    // exactly, and so what keeps the sidecar's clock anchor valid for it.
    if not AVAssetWriterInputPixelBufferAdaptor(FAdaptor)
      .AppendPixelBuffer_withPresentationTime(Destination,
      ATime) then
    begin
      AError := Format('the encoder refused the frame at %.2fs',
        [ASeconds]);
      if FWriter.error <> nil then
        AError := AError + ': '
          + string(FWriter.error.localizedDescription.UTF8String);
      Exit;
    end;
    Inc(FReport.FramesWritten);
    Result := True;
  finally
    CVPixelBufferRelease(Destination);
  end;
end;

// What one frame would come out as at ASeconds, reduced to the integers
// that decide it. The zoom walk is advanced here and again in
// RenderOneFrame; advancing to a time it has already reached is a no-op,
// which is what makes calling it twice safe and what makes this a query
// rather than a second copy of the effect.
function TRenderSession.ShapeAt(ASourceWidth, ASourceHeight: Integer;
  ASeconds: Double): TRenderedFrameShape;
var
  Crop: TZoomCrop;
  Source, Framing: TLiveRect;
  FramingKnown: Boolean;
begin
  Result := Default(TRenderedFrameShape);
  Crop := Default(TZoomCrop);
  Crop.Width := ASourceWidth;
  Crop.Height := ASourceHeight;
  Crop.Identity := True;
  FramingKnown := FramingAt(ASeconds, Framing);
  Source := Framing;
  if FReport.ZoomApplied and FramingKnown then
  begin
    FWalker := ZoomWalkerAdvance(FWalker, FClicks, ASeconds);
    Source := ZoomWalkerSourceRectIn(FWalker, Framing);
    Crop := ZoomFrameCrop(ASourceWidth, ASourceHeight, Framing, Source);
  end;
  Result.CropX := Crop.X;
  Result.CropY := Crop.Y;
  Result.CropWidth := Crop.Width;
  Result.CropHeight := Crop.Height;
  // The same AHasSource the draw will use, or the dedupe would agree
  // with a frame nobody is going to render.
  if FCursor <> nil then
    Result.HasCursor := FCursor.SpritePlacement(FReport.PixelWidth,
      FReport.PixelHeight, ASeconds, FramingKnown, Source.X, Source.Y,
      Source.Width, Source.Height, Result.CursorX, Result.CursorY);
end;

function TRenderSession.FramingAt(ASeconds: Double;
  out ARect: TLiveRect): Boolean;
var
  Stale: Boolean;
begin
  ARect := FBase;
  // A take whose framing never moved shows the base rectangle for the
  // whole file, which the header states outright — there is no track to
  // run past and nothing to go stale.
  if not FFramingPanned then
    Exit(True);
  ARect := FramingRectAt(FLog, ASeconds, Stale);
  if (ARect.Width <= 0) or (ARect.Height <= 0) then
  begin
    ARect := FBase;
    Exit(False);
  end;
  Result := not Stale;
end;

procedure TRenderSession.ReleaseHeldFrame;
begin
  if FHeldBuffer <> nil then
  begin
    CVPixelBufferRelease(FHeldBuffer);
    FHeldBuffer := nil;
  end;
end;

// The reader's buffer is only valid until the next NextFrame, and a
// synthesised frame is made from the frame *before* the one that has
// just been read — so it is retained here rather than borrowed. The
// decoder vends from a pool and would otherwise recycle it under us.
procedure TRenderSession.HoldFrame(const AFrame: TMovieReaderFrame);
begin
  ReleaseHeldFrame;
  FHeldBuffer := CVPixelBufferRetain(AFrame.PixelBuffer);
  FHeldSeconds := AFrame.Seconds;
  FHeldTimeScale := AFrame.Time.timescale;
  FLastValue := AFrame.Time.value;
end;

function TRenderSession.AwaitVideoInput: Boolean;
var
  Idle: Integer;
begin
  Idle := 0;
  while not FVideoInput.isReadyForMoreMediaData do
  begin
    if FWriter.status = AVAssetWriterStatusFailed then
      Exit(False);
    if PumpAudio then
      // Moving audio is progress, so the stall counter starts over: an
      // encoder that is taking one track and not the other is busy, not
      // stuck.
      Idle := 0
    else
    begin
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
      Inc(Idle);
      // See FinishTimeoutSlices. This used to be `while not ready`, with
      // nothing to end it: an input that never came back ready hung the
      // app's main thread for ever.
      if Idle >= FinishTimeoutSlices then
        Exit(False);
    end;
  end;
  Result := True;
end;

// The frames that belong between the held source frame and the next one.
// Nothing is emitted for an instant whose picture would be identical to
// the frame before it, which is what keeps a still stretch sparse and a
// zoom's hold free.
function TRenderSession.SynthesizeUpTo(ANextSeconds: Double;
  out AError: string): Boolean;
var
  Times: TCadenceTimes;
  Shape: TRenderedFrameShape;
  Stamp: CMTime;
  Value: Int64;
  Width, Height, I: Integer;
begin
  Result := True;
  AError := '';
  if (FCadenceSeconds <= 0) or (FHeldBuffer = nil)
    or (FHeldTimeScale <= 0) then
    Exit;
  Times := CadenceTimes(FHeldSeconds, ANextSeconds, FCadenceSeconds);
  if Length(Times) = 0 then
    Exit;
  Width := Integer(CVPixelBufferGetWidth(FHeldBuffer));
  Height := Integer(CVPixelBufferGetHeight(FHeldBuffer));
  for I := 0 to High(Times) do
  begin
    Shape := ShapeAt(Width, Height, Times[I]);
    if FHasLastShape and not FrameShapesDiffer(Shape, FLastShape) then
      Continue;
    // The stamp on the source's own timescale, and strictly after the
    // last one written: the encoder takes presentation stamps in
    // increasing order, and a grid instant that rounds onto a stamp
    // already used would be refused rather than merely close.
    Value := Round(Times[I] * FHeldTimeScale);
    if Value <= FLastValue then
      Value := FLastValue + 1;
    if Value >= Round(ANextSeconds * FHeldTimeScale) then
      Break;
    Stamp := CMTimeMake(Value, FHeldTimeScale);
    if not AwaitVideoInput then
    begin
      AError := 'the encoder stopped accepting frames during the render';
      Exit(False);
    end;
    if not RenderOneFrame(FHeldBuffer, Stamp, Times[I], AError) then
      Exit(False);
    FLastValue := Value;
    FLastShape := Shape;
    FHasLastShape := True;
    Inc(FReport.SynthesizedFrames);
  end;
end;

// Moves whatever coded audio the writer will take right now. True when it
// took something, so the frame loop knows whether it made progress.
function TRenderSession.PumpAudio: Boolean;
var
  I: Integer;
  Sample: CMSampleBufferRef;
begin
  Result := False;
  for I := 0 to High(FAudioInputs) do
  begin
    if FAudioFinished[I] or (FAudioInputs[I] = nil) then
      Continue;
    if not FAudioInputs[I].isReadyForMoreMediaData then
      Continue;
    Sample := FAudioOutputs[I].copyNextSampleBuffer;
    if Sample = nil then
    begin
      FAudioInputs[I].markAsFinished;
      FAudioFinished[I] := True;
      Result := True;
      Continue;
    end;
    if FAudioInputs[I].appendSampleBuffer(Sample) then
      Inc(FReport.AudioSamples);
    CMSampleBufferRelease(Sample);
    Result := True;
  end;
end;

// The pull loop. Both frameworks are asynchronous underneath and both
// answer "not now" through isReadyForMoreMediaData; a pass that moved
// nothing waits a millisecond rather than spinning. Nothing is dropped:
// this is an offline render, so a busy encoder is a reason to wait and
// never a reason to lose a frame.
function TRenderSession.RenderFrames(out AError: string): Boolean;
var
  Frame: TMovieReaderFrame;
  Pool: NSAutoreleasePool;
  VideoDone, Moved, AudioDone: Boolean;
  I, Idle: Integer;
  Started: Boolean;
begin
  Result := False;
  AError := '';
  VideoDone := False;
  Started := False;
  Idle := 0;
  Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
  try
    repeat
      // Ctrl-C between two frames rather than at whatever instruction
      // the signal happened to land on. The temporary is swept by the
      // caller's failure path and the previous deliverable is never
      // touched, so a cancelled render costs the render and nothing
      // else.
      if StopRequested then
      begin
        AError := ExportCancelledMessage;
        Exit;
      end;
      Moved := False;
      if not VideoDone and FVideoInput.isReadyForMoreMediaData then
      begin
        if FReader.NextFrame(Frame) then
        begin
          Inc(FReport.FramesRead);
          if not Started then
          begin
            // The session starts at the first frame's own stamp, exactly
            // as the recorder's writer does, so the rendered file's
            // timeline is the raw take's and the sidecar's anchor is
            // still exact for it.
            FWriter.startSessionAtSourceTime(Frame.Time);
            Started := True;
          end
          else if not SynthesizeUpTo(Frame.Seconds, AError) then
            Exit;
          // The readiness the loop tested before reading may have been
          // spent by the synthesised frames just written, so it is
          // tested again here rather than assumed — appending to an
          // input that is not ready is an exception, not a False.
          if not AwaitVideoInput then
          begin
            AError := 'the encoder stopped accepting frames during the '
              + 'render';
            Exit;
          end;
          if not RenderOneFrame(Frame.PixelBuffer, Frame.Time,
            Frame.Seconds, AError) then
            Exit;
          FLastShape := ShapeAt(
            Integer(CVPixelBufferGetWidth(Frame.PixelBuffer)),
            Integer(CVPixelBufferGetHeight(Frame.PixelBuffer)),
            Frame.Seconds);
          FHasLastShape := True;
          HoldFrame(Frame);
          if FReport.FramesWritten mod ProgressEveryFrames = 0 then
            Progress(FReport.FramesWritten);
          if FReport.FramesRead mod PoolDrainEveryFrames = 0 then
          begin
            Pool.release;
            Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
          end;
        end
        else
        begin
          if FReader.LastError <> '' then
          begin
            AError := FReader.LastError;
            Exit;
          end;
          FVideoInput.markAsFinished;
          VideoDone := True;
        end;
        Moved := True;
      end;
      // Audio only once the session has a start time to place it on.
      if Started and PumpAudio then
        Moved := True;
      AudioDone := True;
      for I := 0 to High(FAudioFinished) do
        if not FAudioFinished[I] then
          AudioDone := False;
      if Moved then
        Idle := 0
      else
      begin
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
        Inc(Idle);
        // The same bound AwaitVideoInput has, on the same reasoning:
        // neither input coming back ready is indistinguishable from a
        // hung app, and this loop owns the main thread.
        if Idle >= FinishTimeoutSlices then
        begin
          AError := 'the render made no progress for two minutes; '
            + 'the encoder stopped taking frames';
          Exit;
        end;
      end;
    until VideoDone and AudioDone;
  finally
    Pool.release;
  end;
  FReader.StopPass;
  if not Started then
  begin
    AError := 'the take holds no frames to render';
    Exit;
  end;
  Progress(FReport.FramesWritten);
  Result := True;
end;

function TRenderSession.FinishWriter(out AError: string): Boolean;
var
  WaitCount: Integer;
begin
  Result := False;
  AError := '';
  GRenderFinishReady := False;
  FWriter.finishWritingWithCompletionHandler(RenderFinishHandler);
  WaitCount := 0;
  while (not GRenderFinishReady) and (WaitCount < FinishTimeoutSlices) do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, FrameworkSliceSeconds, False);
    Inc(WaitCount);
  end;
  if not GRenderFinishReady then
  begin
    AError := 'timed out finishing the rendered movie';
    Exit;
  end;
  if FWriter.status <> AVAssetWriterStatusCompleted then
  begin
    AError := 'the render finished with status ' + IntToStr(FWriter.status);
    if FWriter.error <> nil then
      AError := AError + ': '
        + string(FWriter.error.localizedDescription.UTF8String);
    Exit;
  end;
  Result := True;
end;

// The deliverable's own sidecar.
//
// **Why a copy and not the raw take's.** A sidecar names its movie and
// travels with it (docs/event-sidecar.md), so one file cannot describe
// two movies; and the two movies no longer say the same thing about
// themselves. The raw take has nothing baked in and everything still
// open; the deliverable has the pointer in its pixels and the crop in its
// framing, and must say so — otherwise a second render of the
// deliverable would draw a second pointer and zoom an already zoomed
// picture. AvailableExportEffects reads exactly these fields, so writing
// them honestly is what makes the deliverable safe to hand back to knips.
//
// Everything else is carried across unchanged. The anchor is still valid
// because the render copies presentation stamps rather than re-timing
// them, so a host-clock event time maps onto the deliverable exactly as
// it maps onto the raw take. The samples' source rectangles are rewritten
// where a zoom was applied — a sample says what the capture was reading,
// and what the deliverable's frames show at that instant is the crop.
procedure TRenderSession.WriteDeliverableSidecar;
var
  Writer: TSidecarWriter;
  Header: TSidecarHeader;
  Sample: TSidecarSample;
  Walker: TZoomWalker;
  Source: TLiveRect;
  Trailer: TSidecarTrailer;
  I: Integer;
begin
  if FLog = nil then
    Exit;
  Writer := TSidecarWriter.Create(SidecarPathFor(FOutputPath));
  try
    if Writer.Failed then
      Exit;
    Header := FLog.Header;
    Header.MovieName := Copy(FOutputPath,
      LastDelimiter('/', FOutputPath) + 1, MaxInt);
    Header.KnipsVersion := KnipsVersion;
    // This process, not the recorder's. The field is documented as "the
    // process that wrote the file" and recovery tests it with kill(pid,
    // 0); carrying the recorder's pid across would name a process that
    // has nothing to do with this file and, on a pid that had since been
    // reused, would name a live one.
    Header.ProcessID := FpGetPid;
    if FReport.CursorDrawn then
      Header.CursorRender := scrBaked;
    if FReport.ZoomApplied then
      Header.BakedZoomOnClick := True;
    Writer.WriteHeader(Header);
    if FLog.HasAnchor then
      Writer.WriteAnchor(FLog.AnchorHost);
    Walker := ZoomWalkerStart(FBase, FEffects.ZoomFactor,
      FEffects.ZoomHoldSeconds);
    for I := 0 to FLog.SampleCount - 1 do
    begin
      Sample := FLog.Sample(I);
      if FReport.ZoomApplied and FLog.HasAnchor then
      begin
        Walker := ZoomWalkerAdvance(Walker, FClicks,
          Sample.Time - FLog.AnchorHost);
        // Composed inside the rectangle the capture was reading at that
        // instant — which is the sample's own, the one about to be
        // overwritten — so a panned take's rewritten track says where
        // the crop actually sat rather than where it would have sat if
        // the framing had never moved.
        Source := ZoomWalkerSourceRectIn(Walker,
          LiveRect(Sample.SourceX, Sample.SourceY, Sample.SourceWidth,
          Sample.SourceHeight));
        Sample.SourceX := Source.X;
        Sample.SourceY := Source.Y;
        Sample.SourceWidth := Source.Width;
        Sample.SourceHeight := Source.Height;
      end;
      Writer.WriteSample(Sample);
    end;
    for I := 0 to FLog.ButtonCount - 1 do
      Writer.WriteButton(FLog.ButtonEvent(I));
    Trailer := FLog.Trailer;
    Trailer.Frames := FReport.FramesWritten;
    Trailer.Samples := FLog.SampleCount;
    Writer.WriteTrailer(Trailer);
    FReport.SidecarPath := Writer.Path;
  finally
    Writer.Free;
  end;
end;

procedure TRenderSession.MeasureOutput;
var
  Handle: THandle;
begin
  Handle := FileOpen(FOutputPath, fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then
    Exit;
  FReport.OutputBytes := FileSeek(Handle, Int64(0), fsFromEnd);
  FileClose(Handle);
end;

function TRenderSession.Run(out AError: string): Boolean;
var
  StartedAt: TDateTime;
  Rendered: Boolean;
  Available: TSidecarEffectAvailability;
begin
  Result := False;
  AError := '';
  FReport := Default(TRenderReport);
  FReport.InputPath := FInputPath;
  FReport.OutputPath := FOutputPath;
  // Every per-run field, not just the report. A TRenderSession is built,
  // run once and freed everywhere today, which is exactly why this was
  // missing — but the class does not say so anywhere, TExportSession
  // resets its own (see "A fresh run measures afresh" in
  // Knips.Export.Pipeline), and a second Run over these would carry the
  // first take's click track, zoom walk and held frame into it. The
  // pointers are cleared rather than freed: they belong to the previous
  // run's own teardown, and a nil here would hide a leak rather than
  // cause one — Cleanup is what frees them, and it runs before this can.
  FBase := Default(TLiveRect);
  FFramingPanned := False;
  FWalker := Default(TZoomWalker);
  SetLength(FClicks, 0);
  FEstimatedFrames := 0;
  FCadenceSeconds := 0;
  FHeldSeconds := 0;
  FHeldTimeScale := 0;
  FLastValue := 0;
  FLastShape := Default(TRenderedFrameShape);
  FHasLastShape := False;
  FSidecarLoadError := '';
  if SameText(ExpandFileName(FInputPath), ExpandFileName(FOutputPath)) then
  begin
    AError := 'the take and the deliverable are the same file';
    Exit;
  end;
  AError := OutputPathRefusal(FOutputPath);
  if AError <> '' then
    Exit;
  FTempPath := RenderTemporaryPathFor(FOutputPath);
  // The same refusal the output gets, and it has to come BEFORE the
  // sweep below. SweepTemporaries unlinks the temporary path outright,
  // so a symlink planted at that name was removed by the pre-run sweep
  // and the lstat guard inside ClaimTemporary then had nothing left to
  // refuse — no data was lost either way, but the unit promises not to
  // touch a link at a path it writes and this order was the one place
  // it did. `export` refuses in the same words at the same point.
  AError := OutputPathRefusal(FTempPath);
  if AError <> '' then
    Exit;
  // A temporary left by a render that was killed. Removed rather than
  // reused: nothing here knows how far the dead one got.
  SweepTemporaries;
  StartedAt := Now;

  FReader := TMovieReader.Create(FInputPath);
  if not FReader.Open(AError) then
    Exit;
  FReport.PixelWidth := FReader.PixelWidth;
  FReport.PixelHeight := FReader.PixelHeight;
  FReport.SourceDurationSeconds := FReader.DurationSeconds;
  // What the file holds. Enough for the paths that only copy it, and
  // raised below to allow for synthesis once the take's own rate is
  // known.
  FEstimatedFrames := Max(Int64(1),
    Round(FReader.DurationSeconds * Max(1.0, FReader.NominalFrameRate)));

  if LoadSidecar then
    PrepareEffects;

  // A render that would apply NOTHING is refused rather than copied.
  // Copying produces a byte-identical second movie and a second sidecar
  // beside the first, for ever, and calls that a render — which is not a
  // service, it is a duplicate the user then has to find and delete.
  //
  // The question is what ACTUALLY applied, not what the take could take
  // in principle. Asking availability let a take through whose sidecar
  // had a button event the zoom could not use — CanZoomOnClick is true
  // for any click at all, and the render then drops the right-button
  // ones, the menu-bar ones and the ones outside the rectangle — so
  // `render --effects=zoom` on a take with no usable click reported
  // success and wrote the duplicate.
  //
  // `--effects=none` is the exception and the only one: a real request
  // for the raw pixels as the deliverable, which is a copy on purpose.
  Available := AvailableExportEffects(FLog);
  if not (FReport.ZoomApplied or FReport.CursorDrawn or FExplicitCopy) then
  begin
    AError := 'nothing this render was asked for can be applied to this '
      + 'take';
    // The loader's reason wins where there is one: a sidecar refused for
    // its VERSION is a different problem from one that is not there, and
    // the refusal is the only place either is ever said out loud.
    if FSidecarLoadError <> '' then
      AError := AError + ' (' + FSidecarLoadError + ')'
    else if FReport.ZoomNote <> '' then
      AError := AError + ' (' + FReport.ZoomNote + ')'
    else if FReport.CursorNote <> '' then
      AError := AError + ' (' + FReport.CursorNote + ')'
    else if Available.Reason <> '' then
      AError := AError + ' (' + Available.Reason + ')';
    AError := AError + '; it is already the deliverable';
    Exit;
  end;

  if not FReport.ZoomApplied and not FReport.CursorDrawn then
  begin
    // Only reachable through FExplicitCopy now: the caller asked for the
    // raw pixels as the deliverable. The take is copied byte for byte
    // rather than re-encoded to produce the same picture.
    if not CopyRawTake(AError) then
    begin
      SweepTemporaries;
      Exit;
    end;
    if not CommitOutput(AError) then
      Exit;
    SweepTemporaries;
    MeasureOutput;
    FReport.ElapsedSeconds := (Now - StartedAt) * SecsPerDay;
    if FReport.SourceDurationSeconds > 0 then
      FReport.RealtimeFactor := FReport.ElapsedSeconds
        / FReport.SourceDurationSeconds;
    // The copy path has its own exit, so it composes its own summary.
    // Nothing was framed here, so there is no framing note to lead with
    // — but there are usually two reasons why nothing applied, and this
    // is the path they matter most on.
    FReport.Note := EffectNoteSummary('', FReport.CursorNote,
      FReport.ZoomNote);
    WriteDeliverableSidecar;
    Exit(True);
  end;

  // The cadence to fill effect windows in at. The sidecar's header is
  // what the capture was CONFIGURED for; the reader's nominalFrameRate
  // is what the file came out at, which on a sparse take is the average
  // and not the rate anybody asked for (measured: 18.8 against 30). So
  // the header wins where there is one.
  if (FLog <> nil) and (FLog.Header.FramesPerSecond > 0) then
    FReport.SynthesisFramesPerSecond := FLog.Header.FramesPerSecond
  else
    FReport.SynthesisFramesPerSecond := Max(1,
      Round(FReader.NominalFrameRate));
  // Clamped where it is STORED, not only where it is used. CadenceInterval
  // clamps its argument into 1..120 anyway, so the render already fills at
  // a sane rate whatever the header says — but the report is what the CLI
  // prints and what the app shows, and a sidecar claiming 100000 fps would
  // otherwise have knips announce "filled in at 100000 fps" about a file
  // filled in at 120.
  FReport.SynthesisFramesPerSecond := Max(1,
    Min(MaxCadenceFramesPerSecond, FReport.SynthesisFramesPerSecond));
  FCadenceSeconds := CadenceInterval(FReport.SynthesisFramesPerSecond);
  // The progress denominator has to allow for the frames this pass is
  // about to MAKE. The take's own configured rate is what it fills at,
  // and the movie's nominalFrameRate on a sparse take is the average it
  // came out at — 2.2 on the 8.4 s still-screen take measured here, whose
  // render wrote 246 frames. Against the old bound of 19 the app's status
  // item read "Rendering… 100%" for 93% of the work.
  //
  // Raised only when something can actually animate, and that is a fact
  // rather than a guess: a gap is filled only where the next instant
  // would be a different picture, and with no zoom applied the only
  // thing that can make one different is the pointer moving. A track
  // that never moves fills nothing, so the file's own frame count is
  // still the bound and raising it would leave the bar stuck near the
  // bottom for the whole render. See
  // Knips.Export.CursorEffect.TrackIsStationary and the same rule in
  // Knips.Export.Pipeline.SynthesisPossible.
  if FReport.ZoomApplied or (FCursor = nil)
    or not FCursor.TrackIsStationary then
    FEstimatedFrames := Max(FEstimatedFrames, Max(Int64(1),
      Round(FReader.DurationSeconds * FReport.SynthesisFramesPerSecond)));

  if not FReader.StartPass(0, 0, AError) then
    Exit;
  if not OpenWriter(AError) then
  begin
    Teardown;
    SweepTemporaries;
    Exit;
  end;
  if FVerbose then
  begin
    WriteLn(Format('rendering %dx%d with %s to %s',
      [FReport.PixelWidth, FReport.PixelHeight,
      DescribeExportEffects(FEffects), FOutputPath]));
    Flush(Output);
  end;

  Rendered := RenderFrames(AError);
  if Rendered then
    Rendered := FinishWriter(AError)
  else
    FWriter.cancelWriting;
  Teardown;
  if not Rendered then
  begin
    SweepTemporaries;
    Exit;
  end;
  // Only here does the old deliverable stop being the answer.
  if not CommitOutput(AError) then
    Exit;
  // The rename took the temporary; this takes the scratch beside it. It
  // has to happen on the SUCCESS path too, and that is the whole of this
  // fix: the launch-time sweep in Knips.Recording.Recovery only runs when
  // the app starts or a CLI recording begins, so an app that re-exports
  // five times, or a `knips render` workflow that never records at all,
  // accumulated a full-sized shadow per render until something else
  // happened to clean up.
  SweepTemporaries;

  if FCursor <> nil then
  begin
    FReport.CursorFrames := FCursor.DrawnFrames;
    FReport.CursorOffFrameFrames := FCursor.OffFrameFrames;
  end;
  // "The pointer was drawn on 0 frames" with no explanation is the one
  // report that reads as a bug and is usually not one: the pointer was
  // outside the rectangle this take shows, for the whole of it. Said
  // here rather than counted silently, and only when the count really
  // is nothing — a pointer that came and went needs no sentence.
  if FReport.CursorDrawn and (FReport.CursorFrames = 0)
    and (FReport.CursorOffFrameFrames > 0) then
    FReport.CursorNote := Format('the pointer was outside the rectangle '
      + 'this recording shows for all %d of its frames, so none of them '
      + 'has one drawn into it',
      [FReport.CursorOffFrameFrames]);
  if FReport.SynthesizedFrames = 0 then
    FReport.SynthesisFramesPerSecond := 0;
  // Said out loud rather than counted silently: a stretch of a take with
  // no zoom in it looks exactly like a stretch nobody clicked in. Its
  // own field, never sharing one with the zoom's or the cursor's reason
  // — this is the only note of the three about the PIXELS being other
  // than the take could account for, and a cosmetic note about an effect
  // must not be able to hide it.
  FReport.FramingNote := UnframedFramesNote(FReport.UnframedFrames);
  FReport.Note := EffectNoteSummary(FReport.FramingNote,
    FReport.CursorNote, FReport.ZoomNote);
  MeasureOutput;
  FReport.ElapsedSeconds := (Now - StartedAt) * SecsPerDay;
  if FReport.SourceDurationSeconds > 0 then
    FReport.RealtimeFactor := FReport.ElapsedSeconds
      / FReport.SourceDurationSeconds;
  // After the movie is in place, never before: a sidecar naming a movie
  // that is not there yet is exactly the state recovery cannot read.
  WriteDeliverableSidecar;
  Result := True;
end;

{$ENDIF}

end.

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
// H.264 through an AVAssetWriterInputPixelBufferAdaptor. Presentation
// stamps are copied across unchanged, so the rendered file's timeline is
// the raw take's timeline and the sidecar's clock anchor is still exact
// for it.
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
    // fail a render — the deliverable is correct without them — so this
    // and Note are how a caller finds out.
    CursorDrawn: Boolean;
    CursorFrames: Int64;
    ZoomApplied: Boolean;
    // Frames whose crop was not the whole frame; zero on a take where
    // nothing was clicked even with the zoom switched on.
    ZoomedFrames: Int64;
    UsableClicks: Integer;
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
    function LoadSidecar: Boolean;
    procedure PrepareEffects;
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
    function RenderOneFrame(const AFrame: TMovieReaderFrame;
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
    property Verbose: Boolean read FVerbose write FVerbose;
    property OnProgress: TRenderProgressEvent read FOnProgress
      write FOnProgress;
  end;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // The render's writer is not a recorder: it is fed as fast as the
  // encoder will take frames, and when it will not the loop has nothing
  // to do but wait. A millisecond is short enough that the wait never
  // shows up in the render time and long enough not to be a spin.
  IdleSliceSeconds = 0.001;
  FinishTimeoutSlices = 120000;
  // How long CommitOutput will wait for the temporary to settle before
  // giving up on the rename, and how long one wait is. Half a second in
  // twenty-five-millisecond turns; see CommitOutput for what it is
  // waiting FOR.
  CommitAttempts = 20;
  CommitSettleSeconds = 0.025;
  // Keyframe every four seconds, as the recorder does.
  KeyframeIntervalSeconds = 4;
  // How often progress is reported and the autorelease pool drained.
  ProgressEveryFrames = 30;
  PoolDrainEveryFrames = 128;
  // vImage_Flags. kvImageHighQualityResampling (32) picks the more
  // expensive Lanczos path; a zoom is an *upscale* of screen content,
  // where the cheap kernel's ringing on text is the first thing anybody
  // notices. kvImageNoFlags is 0 and is what the temp-buffer query takes.
  kvImageNoFlags = 0;
  kvImageHighQualityResampling = 32;

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
  inherited Destroy;
end;

procedure TRenderSession.Teardown;
var
  I: Integer;
begin
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
  if not Result then
  begin
    FreeAndNil(FLog);
    FReport.Note := 'no event sidecar beside this take, so nothing could '
      + 'be rendered into it';
  end;
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

  if FEffects.ZoomOnClick then
  begin
    if not Available.CanZoomOnClick then
    begin
      // The ZOOM's own reason, not the summary: a take with a baked
      // pointer and a panned framing has two, and the summary carries
      // the pointer's — which is not why the zoom was refused.
      if FReport.Note = '' then
        FReport.Note := Available.ZoomReason;
    end
    else
    begin
      FClicks := ZoomClicksFromLog(FLog);
      FReport.UsableClicks := Length(FClicks);
      if FReport.UsableClicks = 0 then
      begin
        if FReport.Note = '' then
          FReport.Note := 'nothing was clicked inside the recorded '
            + 'rectangle, so there was nothing to zoom to';
      end
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
    if FCursor.Prepare(FInputPath, FEffects, FReader.PixelWidth,
      FReader.PixelHeight, Note) then
      FReport.CursorDrawn := True
    else
    begin
      if FCursor.Asked and (FReport.Note = '') then
        FReport.Note := Note;
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
begin
  Result := False;
  AError := '';
  Source := nil;
  Destination := nil;
  try
    try
      Source := TFileStream.Create(FInputPath, fmOpenRead or fmShareDenyNone);
      Destination := TFileStream.Create(FTempPath, fmCreate);
      Destination.CopyFrom(Source, 0);
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

// The one instant at which the old deliverable stops being the answer.
//
// rename(2) replaces the destination atomically within one filesystem, so
// there is deliberately no DeleteFile first: deleting and then renaming
// would open exactly the window this exists to close.
//
// **It is retried, and the retry is a wait rather than a hope.**
// AVAssetWriter's completion handler having fired does not mean the file
// at FTempPath has stopped moving: for a fast-start output the framework
// assembles the movie from its own scratch and puts it at that path with
// a replace of its own, and under the macOS sandbox that replace goes
// through a shim (the `.sb-<token>` neighbour). Measured on the release
// build: one render in twelve came back `could not replace …` — the
// temporary was momentarily not there to rename. Half a second of
// twenty-five-millisecond turns covers it; a temporary that is still
// missing after that is genuinely missing, and the error then says so
// with the errno and whether the file exists, because those two facts
// are the whole diagnosis.
function TRenderSession.CommitOutput(out AError: string): Boolean;
var
  Attempt: Integer;
begin
  AError := '';
  Result := False;
  for Attempt := 1 to CommitAttempts do
  begin
    if RenameFile(FTempPath, FOutputPath) then
      Exit(True);
    // A run-loop turn rather than a sleep: this is the main thread, and
    // whatever the frameworks have left to do may want it.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, CommitSettleSeconds, False);
  end;
  AError := Format('the render finished but could not replace %s after '
    + '%.2fs (errno %d, temporary %s)', [FOutputPath,
    CommitAttempts * CommitSettleSeconds, fpgeterrno,
    BoolToStr(FileExists(FTempPath), 'present', 'gone')]);
  SweepTemporaries;
end;

procedure TRenderSession.SweepTemporaries;
var
  Search: TSearchRec;
  Directory, Pattern: string;
begin
  if FTempPath = '' then
    Exit;
  Directory := ExtractFilePath(FTempPath);
  // The temporary itself and every neighbour whose name begins with it —
  // AVAssetWriter's fast-start scratch arrives as
  // `<temporary>.sb-<token>` under the sandbox. The pattern carries the
  // whole temporary name, which ends in RenderTemporarySuffix, so it
  // cannot match the deliverable (which never contains that suffix) or
  // any take.
  Pattern := ExtractFileName(FTempPath) + '*';
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

function TRenderSession.OpenWriter(out AError: string): Boolean;
var
  URL: NSURL;
  Error: NSError;
  Container: TOutputContainer;
  FileType: NSString;
  Settings, Compression, Attributes: NSMutableDictionary;
  Rate, BitRate: Integer;
begin
  Result := False;
  AError := '';
  // The TEMPORARY is what is opened and what is replaced; the
  // deliverable is not touched until the rename in CommitOutput.
  if FileExists(FTempPath) and not DeleteFile(FTempPath) then
  begin
    AError := 'cannot replace ' + FTempPath;
    Exit;
  end;
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

  Rate := Round(FReader.NominalFrameRate);
  if Rate < MinFramesPerSecond then
    Rate := DefaultFramesPerSecond;
  if Rate > MaxFramesPerSecond then
    Rate := MaxFramesPerSecond;
  BitRate := SuggestedBitRate(FReport.PixelWidth, FReport.PixelHeight, Rate);

  Compression := NSMutableDictionary.dictionaryWithCapacity(5);
  Compression.setObject_forKey(NSNumber.numberWithInt(BitRate),
    id(AVVideoAverageBitRateKey));
  Compression.setObject_forKey(
    NSNumber.numberWithInt(Rate * KeyframeIntervalSeconds),
    id(AVVideoMaxKeyFrameIntervalKey));
  Compression.setObject_forKey(NSNumber.numberWithInt(Rate),
    id(AVVideoExpectedSourceFrameRateKey));
  Compression.setObject_forKey(NSNumber.numberWithBool(ObjCBOOL(False)),
    id(AVVideoAllowFrameReorderingKey));
  Compression.setObject_forKey(id(AVVideoProfileLevelH264HighAutoLevel),
    id(AVVideoProfileLevelKey));

  Settings := NSMutableDictionary.dictionaryWithCapacity(4);
  Settings.setObject_forKey(id(AVVideoCodecTypeH264), id(AVVideoCodecKey));
  Settings.setObject_forKey(NSNumber.numberWithInt(FReport.PixelWidth),
    id(AVVideoWidthKey));
  Settings.setObject_forKey(NSNumber.numberWithInt(FReport.PixelHeight),
    id(AVVideoHeightKey));
  Settings.setObject_forKey(Compression, id(AVVideoCompressionPropertiesKey));

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
function TRenderSession.RenderOneFrame(const AFrame: TMovieReaderFrame;
  out AError: string): Boolean;
var
  Status: CVReturn;
  Destination: CVPixelBufferRef;
  SourceBase, DestinationBase: Pointer;
  SourceStride, DestinationStride, SourceWidth, SourceHeight, Y: Integer;
  Crop: TZoomCrop;
  Source: TLiveRect;
  From, Onto: vImage_Buffer;
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
    Status := CVPixelBufferLockBaseAddress(AFrame.PixelBuffer,
      kCVPixelBufferLock_ReadOnly);
    if Status <> kCVReturn_Success then
    begin
      AError := Format('could not read the frame at %.2fs '
        + '(CVPixelBufferLockBaseAddress returned %d)',
        [AFrame.Seconds, Status]);
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
        SourceBase := CVPixelBufferGetBaseAddress(AFrame.PixelBuffer);
        SourceStride := Integer(CVPixelBufferGetBytesPerRow(
          AFrame.PixelBuffer));
        SourceWidth := Integer(CVPixelBufferGetWidth(AFrame.PixelBuffer));
        SourceHeight := Integer(CVPixelBufferGetHeight(AFrame.PixelBuffer));
        DestinationBase := CVPixelBufferGetBaseAddress(Destination);
        DestinationStride := Integer(CVPixelBufferGetBytesPerRow(
          Destination));
        if (SourceBase = nil) or (DestinationBase = nil) then
        begin
          AError := Format('a frame at %.2fs has no pixels',
            [AFrame.Seconds]);
          Exit;
        end;

        Crop := Default(TZoomCrop);
        Crop.Width := SourceWidth;
        Crop.Height := SourceHeight;
        Crop.Identity := True;
        Source := FBase;
        if FReport.ZoomApplied then
        begin
          FWalker := ZoomWalkerAdvance(FWalker, FClicks, AFrame.Seconds);
          Source := ZoomWalkerSourceRect(FWalker);
          Crop := ZoomFrameCrop(SourceWidth, SourceHeight, FBase, Source);
        end;

        if Crop.Identity then
        begin
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
          ScaleError := vImageScale_ARGB8888(@From, @Onto, nil,
            kvImageHighQualityResampling);
          if ScaleError <> 0 then
          begin
            AError := Format('scaling the frame at %.2fs failed '
              + '(vImageScale_ARGB8888 returned %d)',
              [AFrame.Seconds, Int64(ScaleError)]);
            Exit;
          end;
          Inc(FReport.ZoomedFrames);
        end;

        // After the crop and the scale: the sprite is drawn at the
        // output's own scale, and the pointer belongs on top of the
        // picture rather than inside it.
        if FCursor <> nil then
          FCursor.DrawIntoPixels(DestinationBase, DestinationStride,
            FReport.PixelWidth, FReport.PixelHeight, AFrame.Seconds,
            FReport.ZoomApplied, Source.X, Source.Y, Source.Width,
            Source.Height);
      finally
        CVPixelBufferUnlockBaseAddress(Destination, 0);
      end;
    finally
      CVPixelBufferUnlockBaseAddress(AFrame.PixelBuffer,
        kCVPixelBufferLock_ReadOnly);
    end;

    // The container's own stamp, not one rebuilt from seconds: this is
    // what makes the deliverable's timeline the raw take's timeline
    // exactly, and so what keeps the sidecar's clock anchor valid for it.
    if not AVAssetWriterInputPixelBufferAdaptor(FAdaptor)
      .AppendPixelBuffer_withPresentationTime(Destination,
      AFrame.Time) then
    begin
      AError := Format('the encoder refused the frame at %.2fs',
        [AFrame.Seconds]);
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
  I: Integer;
  Started: Boolean;
begin
  Result := False;
  AError := '';
  VideoDone := False;
  Started := False;
  Pool := NSAutoreleasePool(NSAutoreleasePool.alloc.init);
  try
    repeat
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
          end;
          if not RenderOneFrame(Frame, AError) then
            Exit;
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
      if not Moved then
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, IdleSliceSeconds, False);
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
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, IdleSliceSeconds, False);
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
        Source := ZoomWalkerSourceRect(Walker);
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
  if SameText(ExpandFileName(FInputPath), ExpandFileName(FOutputPath)) then
  begin
    AError := 'the take and the deliverable are the same file';
    Exit;
  end;
  FTempPath := FOutputPath + RenderTemporarySuffix;
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
  FEstimatedFrames := Max(Int64(1),
    Round(FReader.DurationSeconds * Max(1.0, FReader.NominalFrameRate)));

  if LoadSidecar then
    PrepareEffects;

  // A take that can take NO effect at all is refused rather than copied.
  // Copying it would produce a byte-identical second movie and a second
  // sidecar beside the first, for ever, and call that a render — which
  // is not a service, it is a duplicate the user then has to find and
  // delete. A take that CAN be rendered and was simply asked for nothing
  // is a different thing and still copies: `--effects=none` is a real
  // request for the raw pixels as the deliverable.
  Available := AvailableExportEffects(FLog);
  if not (Available.CanDrawCursor or Available.CanZoomOnClick) then
  begin
    AError := 'nothing in this take can be applied after the fact';
    if Available.Reason <> '' then
      AError := AError + ' (' + Available.Reason + ')';
    AError := AError + '; it is already the deliverable';
    Exit;
  end;

  if not FReport.ZoomApplied and not FReport.CursorDrawn then
  begin
    // Nothing was asked for that applies. The deliverable is the take.
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
    WriteDeliverableSidecar;
    Exit(True);
  end;

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
    FReport.CursorFrames := FCursor.DrawnFrames;
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

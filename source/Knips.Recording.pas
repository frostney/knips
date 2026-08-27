unit Knips.Recording;

// One recording, start to finish: resolve what to capture, size the
// stream in pixels, open the movie, run the ScreenCaptureKit stream into
// it until a stop is requested, then finalise the file.
//
// The main thread owns everything except HandleSample, which the capture
// queue calls; it forwards the buffer to the writer (whose counters are
// mutex-guarded) and, with Big Cursor on, draws the enlarged pointer into
// the frame's own pixels first (Knips.Recording.CursorOverlay, whose
// sprite was made on the main thread before the capture started). Stop
// arrives through a signal-safe flag set by the program's SIGINT/SIGTERM
// handler.

{$I Knips.inc}

interface

{$IFDEF DARWIN}
{$modeswitch objectivec2}

uses
  BaseUnix,
  DateUtils,
  SysUtils,

  CocoaAll,
  Knips.Capture.CoreMedia,
  Knips.Capture.ScreenCaptureKit,
  Knips.Capture.ShareableContent,
  Knips.Capture.Stream,
  Knips.Export.MovieWriter,
  Knips.Options,
  Knips.Recording.CursorMath,
  Knips.Recording.CursorOverlay,
  Knips.Recording.LiveMath,
  Knips.Recording.Sidecar,
  MacOSAll;

type
  TRecordingReport = record
    OutputPath: string;
    PixelWidth: Integer;
    PixelHeight: Integer;
    Scale: Integer;
    FramesPerSecond: Integer;
    BitRate: Integer;
    AppendedFrames: Int64;
    DroppedFrames: Int64;
    FailedAppends: Int64;
    AudioMode: TAudioMode;
    // How many of the requested ExcludedWindowIDs were still on screen
    // and made it into the content filter.
    ExcludedWindows: Integer;
    AppendedAudioSamples: Int64;
    DroppedAudioEarly: Int64;
    DroppedAudioStalled: Int64;
    FailedAudioAppends: Int64;
    AppendedMicrophoneSamples: Int64;
    DroppedMicrophoneEarly: Int64;
    DroppedMicrophoneStalled: Int64;
    FailedMicrophoneAppends: Int64;
    // Was there actually any sound? The loudest sample on each track and
    // the number of buffers that was measured over
    // (Knips.Export.MovieWriter). A track that was enabled, arrived, and
    // was silence throughout is the failure that is invisible until the
    // take cannot be repeated — Knips.Options.AudioSilenceWarning turns
    // these into the sentence to show.
    AudioPeak: Double;
    AudioInspected: Int64;
    MicrophonePeak: Double;
    MicrophoneInspected: Int64;
    // Live source-rectangle updates (Zoom on Click / Follow Mouse): how
    // many were handed to ScreenCaptureKit, how many it completed, how
    // many it refused, and the last NSError code it refused with. All
    // zero for a recording with no live effects.
    LiveUpdatesSent: Int64;
    LiveUpdatesCompleted: Int64;
    LiveUpdatesFailed: Int64;
    LiveUpdateErrorCode: NSInteger;
    // Big Cursor. Whether the recording drew its own pointer at all, and
    // then what the capture queue did with it: frames the sprite went
    // into, frames where the pointer was off the captured rectangle, and
    // frames refused because the buffer was not what the configuration
    // asked for. The third is the only one that is ever a problem, and
    // it is the reason these are counted rather than assumed — the
    // compositor runs on a thread with nowhere to report anything.
    BigCursor: Boolean;
    // Whether this recording deliberately left the pointer out for an
    // export to draw back (Knips.Export.CursorEffect). Mutually exclusive
    // with BigCursor, and the reason the sidecar's header says "smooth"
    // rather than "none": the movie is cursorless on purpose and the
    // pointer is waiting in the sidecar.
    SmoothCursor: Boolean;
    // Why the drawn pointer was given up on, when it was; '' otherwise.
    // Never a reason to fail the recording — the file is written with
    // the ordinary system cursor instead.
    BigCursorError: string;
    CursorFrames: Int64;
    CursorOffFrame: Int64;
    CursorRefused: Int64;
    DurationSeconds: Double;
    // The event sidecar (Knips.Recording.Sidecar): where it went, how many
    // pointer samples reached it, and why it was given up on if it was.
    // A sidecar failure is never a reason to fail a recording — the movie
    // is the deliverable and the sidecar is the note beside it — so the
    // reason is reported rather than raised.
    SidecarPath: string;
    SidecarSamples: Int64;
    SidecarError: string;
    // Host-clock seconds of the movie's first frame, and of the stop. The
    // two together are what an alignment check measures drift against:
    // the movie's own duration (last PTS minus first PTS) and the elapsed
    // host time between these must agree, because they are the same clock.
    AnchorHostSeconds: Double;
    StopHostSeconds: Double;
  end;

  TRecordingSession = class
  private
    FOptions: TRecordingOptions;
    FWriter: TMovieWriter;
    FStream: TScreenStream;
    FFilter: SCContentFilter;
    FGeometry: TStreamGeometry;
    FReport: TRecordingReport;
    FCapturing: Boolean;
    // Big Cursor. Nil unless the recording actually draws its own
    // pointer; HandleSample checks for that on every frame, which is one
    // pointer test on the capture queue.
    FCursorOverlay: TCursorOverlay;
    // The rectangle the recording was sized from, in the recorded
    // display's own top-left points — the region, or the whole display
    // when there is no region. Unlike FGeometry.SourceRect this is filled
    // in even when the stream was started without a sourceRect, because
    // it is what the cursor's position is measured against either way.
    FBaseRect: CGRect;
    FDisplayID: UInt32;
    // The event sidecar and the state SampleMetadata needs between ticks.
    // All main-thread: the capture queue never sees any of it.
    FSidecar: TSidecarWriter;
    FSidecarButtons: Integer;
    FHasSidecarButtons: Boolean;
    // The recorded display's origin in the global point space
    // CGEventGetLocation answers in, so a pointer position becomes this
    // display's own points by subtraction. Both zero for a window target,
    // where the samples stay in global points (see the sidecar header's
    // "target" field).
    FDisplayOriginX: Double;
    FDisplayOriginY: Double;
    procedure HandleSample(ASampleBuffer: CMSampleBufferRef;
      AKind: TSampleKind);
    procedure OpenSidecar;
    procedure CloseSidecar;
    // The rectangle ScreenCaptureKit is reading right now, in the recorded
    // display's own top-left points: what the live effects last got
    // through, or the base rectangle when nothing has moved it.
    function CurrentSourceRect: CGRect;
    function ResolveFilter(const AContent: TShareableContent;
      out AFilter: SCContentFilter; out AGeometry: TStreamGeometry;
      out AError: string): Boolean;
    // The SCWindow objects behind FOptions.ExcludedWindowIDs, as the
    // autoreleased array SCContentFilter wants. Empty when nothing was
    // asked for, which is the array the filter took before.
    function ExcludedWindows(const AContent: TShareableContent): NSArray;
    procedure ReleaseFilter;
    procedure RunUntilStopped;
  public
    constructor Create(const AOptions: TRecordingOptions);
    destructor Destroy; override;
    // Opens the writer and starts the stream, then returns: the caller
    // owns the run loop from there. The CLI's Run and the menu-bar app
    // share this; the app needs NSApp's own run loop to keep turning, so
    // nothing here may block.
    function StartCapture(out AError: string): Boolean;
    // Stops the stream and finalises the file, in that order. Both the
    // stream's stop handler and the writer's completion handler are
    // awaited by pumping CFRunLoopRunInMode slices on the calling thread,
    // which must be the same main thread that called StartCapture.
    function FinishCapture(out AError: string): Boolean;
    // Blocks until StopRequested is set. False with a message on any
    // failure before or after capture.
    function Run(out AError: string): Boolean;
    // The writer's counters as they stand right now, for a caller that
    // wants progress without stopping — `knips mcp`'s record_status,
    // which answers while the capture queue is still appending. The
    // counters are mutex-guarded inside the writer, so reading them
    // from the main thread mid-recording is safe; all-zero before
    // StartCapture and after the writer is gone.
    function LiveStatistics: TMovieWriterStatistics;
    // Moves the rectangle ScreenCaptureKit reads from the screen without
    // touching the file's dimensions — the one primitive Zoom on Click
    // and Follow Mouse are built out of. Points, in the display's own
    // top-left space, the same space TRecordingOptions.Region is in.
    //
    // Only meaningful when the session was started with
    // TRecordingOptions.LiveSourceRect (or with a region, which implies
    // one); False otherwise, and False rather than an exception when the
    // stream is not running. Fire-and-forget — see
    // TScreenStream.UpdateSourceRect.
    function UpdateSourceRect(const ARect: CGRect): Boolean;
    // Whether this recording can move its source rectangle at all: the
    // stream is running, the framework has updateConfiguration:, and it
    // has not refused enough updates in a row for the stream to give up.
    // A caller that animates must watch this: when it goes False the
    // capture has stopped following, and LiveUpdateError says why.
    function SupportsLiveUpdate: Boolean;
    // Why the live effects stopped, when they did. Empty otherwise. This
    // is never a reason to fail the recording — the file is unaffected
    // and keeps being written at whatever rectangle last took.
    function LiveUpdateError: string;
    // The rectangle the recording was sized from, which is what the live
    // effects pan and crop inside. Empty when the session is not running.
    function BaseSourceRect: CGRect;
    // How many source-rectangle updates have reached ScreenCaptureKit so
    // far. The report carries the same number once the recording is over;
    // this is the mid-recording view, which is what tells a caller whether
    // its rectangles are getting through at all.
    function LiveUpdatesSent: Int64;
    // One pointer sample into the event sidecar. Main thread only, and
    // called by whoever owns the run loop while the recording runs: the
    // CLI's own loop, and the menu-bar app's 30 Hz timer. Cheap enough to
    // call at that rate and harmless to call at any other — the samples
    // carry their own times, so a slow or irregular caller produces a
    // sparser track rather than a wrong one.
    //
    // Deliberately not driven from inside the session by a timer of its
    // own: this program has one main thread and two very different run
    // loops on it, and a third timer would be a third thing to invalidate
    // on every failure path.
    procedure SampleMetadata;
    // Where the event sidecar is being written, or '' when there is none.
    function SidecarPath: string;

    // True between a successful StartCapture and FinishCapture.
    property Capturing: Boolean read FCapturing;
    property Geometry: TStreamGeometry read FGeometry;
    property Report: TRecordingReport read FReport;
  end;

// Set from a signal handler; polled by the run loop.
var
  StopRequested: Boolean = False;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // The CLI's run loop turns at the sidecar's sample rate rather than the
  // quarter-second it used before a recording had events to record. The
  // slice is the sampling clock, so it is the sampling rate that sets it;
  // the progress line still lands every two seconds, counted in slices.
  RunLoopSliceSeconds = 1 / DefaultSidecarSampleHz;
  ProgressEverySlices = 2 * DefaultSidecarSampleHz;

{ TRecordingSession }

constructor TRecordingSession.Create(const AOptions: TRecordingOptions);
begin
  inherited Create;
  FOptions := AOptions;
end;

destructor TRecordingSession.Destroy;
begin
  // The stream goes first, so the capture queue has stopped calling
  // HandleSample before the overlay it composites through is freed.
  FreeAndNil(FStream);
  FreeAndNil(FCursorOverlay);
  FreeAndNil(FWriter);
  // After the stream, for the same reason and one more: a session freed
  // without FinishCapture (a failed start, a quit) still gets its sidecar
  // flushed and closed rather than losing the last buffer.
  CloseSidecar;
  ReleaseFilter;
  inherited Destroy;
end;

// The filter is alloc'd by ResolveFilter and retained again by
// TScreenStream; this releases only this class's own reference.
procedure TRecordingSession.ReleaseFilter;
begin
  if FFilter <> nil then
  begin
    FFilter.release;
    FFilter := nil;
  end;
end;

procedure TRecordingSession.HandleSample(ASampleBuffer: CMSampleBufferRef;
  AKind: TSampleKind);
begin
  // Capture-queue context: no exceptions, no WriteLn, no managed types.
  // Video, system audio and microphone arrive on three separate queues;
  // the writer's mutex is what keeps the appends from overlapping.
  if FWriter = nil then
    Exit;
  if AKind = skVideo then
  begin
    // Before the append, and only before: the frame's pixels are ours
    // until AVAssetWriter is handed the buffer, and not afterwards.
    if FCursorOverlay <> nil then
      FCursorOverlay.DrawInto(CMSampleBufferGetImageBuffer(ASampleBuffer));
    FWriter.AppendVideoSample(ASampleBuffer);
  end
  else if AKind = skAudio then
    FWriter.AppendAudioSample(ASampleBuffer)
  else if AKind = skMicrophone then
    FWriter.AppendMicrophoneSample(ASampleBuffer);
end;

// A requested id that no longer names an on-screen window is skipped
// rather than failing the recording: the window it stood for is gone, so
// nothing of it can reach the capture anyway. The count that did make it
// goes into the report, which is what the exclusion proof reads.
function TRecordingSession.ExcludedWindows(
  const AContent: TShareableContent): NSArray;
var
  Excluded: NSMutableArray;
  Window: SCWindow;
  I: Integer;
begin
  Excluded := NSMutableArray.arrayWithCapacity(
    Length(FOptions.ExcludedWindowIDs));
  FReport.ExcludedWindows := 0;
  for I := 0 to High(FOptions.ExcludedWindowIDs) do
  begin
    Window := AContent.RetainWindow(FOptions.ExcludedWindowIDs[I]);
    if Window = nil then
      Continue;
    // addObject: retains; this balances RetainWindow's own retain.
    Excluded.addObject(id(Window));
    Window.release;
    Inc(FReport.ExcludedWindows);
  end;
  Result := Excluded;
end;

function TRecordingSession.ResolveFilter(const AContent: TShareableContent;
  out AFilter: SCContentFilter; out AGeometry: TStreamGeometry;
  out AError: string): Boolean;
var
  Display: SCDisplay;
  Window: SCWindow;
  Frame: CGRect;
  PointWidth, PointHeight, Scale: Integer;
begin
  Result := False;
  AFilter := nil;
  AGeometry := Default(TStreamGeometry);
  AError := '';

  case FOptions.TargetKind of
    ctkWindow:
      begin
        Window := AContent.RetainWindow(FOptions.WindowID);
        if Window = nil then
        begin
          AError := Format('no on-screen window with id %d (see `knips windows`)',
            [FOptions.WindowID]);
          Exit;
        end;
        try
          Frame := Window.frame;
          PointWidth := Round(Frame.size.width);
          PointHeight := Round(Frame.size.height);
          Scale := FOptions.Scale;
          if Scale = ScaleAuto then
            Scale := DisplayBackingScale(CGMainDisplayID);
          AFilter := SCContentFilter(
            SCContentFilter.alloc.initWithDesktopIndependentWindow(Window));
        finally
          Window.release;
        end;
      end;
  else
    begin
      Display := AContent.RetainDisplay(FOptions.DisplayIndex);
      if Display = nil then
      begin
        AError := Format('no display at index %d (see `knips displays`)',
          [FOptions.DisplayIndex]);
        Exit;
      end;
      try
        Scale := FOptions.Scale;
        if Scale = ScaleAuto then
          Scale := DisplayBackingScale(Display.displayID);
        FDisplayID := Display.displayID;
        if FOptions.HasRegion then
        begin
          PointWidth := FOptions.Region.Width;
          PointHeight := FOptions.Region.Height;
          if (FOptions.Region.Left + PointWidth > Integer(Display.width))
            or (FOptions.Region.Top + PointHeight > Integer(Display.height)) then
          begin
            AError := Format('--rect exceeds the display (%dx%d points)',
              [Integer(Display.width), Integer(Display.height)]);
            // The enclosing finally releases Display.
            Exit;
          end;
          AGeometry.HasSourceRect := True;
          AGeometry.SourceRect := CGRectMake(FOptions.Region.Left,
            FOptions.Region.Top, PointWidth, PointHeight);
          FBaseRect := AGeometry.SourceRect;
        end
        else
        begin
          PointWidth := Integer(Display.width);
          PointHeight := Integer(Display.height);
          // The whole display is the base rectangle whether or not the
          // stream is given a sourceRect to move.
          FBaseRect := CGRectMake(0, 0, PointWidth, PointHeight);
          // A whole-display capture normally goes without a sourceRect,
          // which is what "capture everything" means to SCK. The
          // menu-bar app's live effects need a rectangle to move, so it
          // asks for one covering the display: the same pixels, and the
          // same output size, but now something updateConfiguration: can
          // shrink around a click. Nothing changes for the CLI, which
          // never sets the flag.
          if FOptions.LiveSourceRect then
          begin
            AGeometry.HasSourceRect := True;
            AGeometry.SourceRect := CGRectMake(0, 0, PointWidth,
              PointHeight);
          end;
        end;
        AFilter := SCContentFilter(
          SCContentFilter.alloc.initWithDisplay_excludingWindows(Display,
          ExcludedWindows(AContent)));
      finally
        Display.release;
      end;
    end;
  end;

  if AFilter = nil then
  begin
    AError := 'SCContentFilter init failed';
    Exit;
  end;

  AGeometry.PixelWidth := AlignDimension(PointWidth * Scale);
  AGeometry.PixelHeight := AlignDimension(PointHeight * Scale);
  AGeometry.FramesPerSecond := FOptions.FramesPerSecond;
  // Big Cursor draws the pointer itself, so ScreenCaptureKit must not
  // draw it too — two pointers in one frame, one of them the wrong size.
  // Setting it here rather than at the configuration is deliberate: the
  // one configuration builder in Knips.Capture.Stream reads the geometry
  // for the first configuration *and* for every live update, so a zoom
  // cannot quietly bring the system cursor back mid-recording.
  FReport.BigCursor := ResolveBigCursor(FOptions.TargetKind,
    FOptions.BigCursor);
  // Smooth Cursor suppresses the pointer for the opposite reason: nothing
  // draws it here, and the export puts it back from the sidecar's track.
  // The two are refused together by validation, so this can only turn the
  // pointer off on top of a Big Cursor that is already off.
  FReport.SmoothCursor := ResolveSmoothCursor(FOptions.TargetKind,
    FOptions.SmoothCursor);
  AGeometry.ShowsCursor := FOptions.ShowsCursor and not FReport.BigCursor
    and not FReport.SmoothCursor;
  AGeometry.CapturesAudio := AudioModeCapturesSystem(FOptions.AudioMode);
  AGeometry.AudioSampleRate := FOptions.AudioSampleRate;
  AGeometry.AudioChannelCount := FOptions.AudioChannelCount;
  AGeometry.CapturesMicrophone :=
    AudioModeCapturesMicrophone(FOptions.AudioMode);
  if (AGeometry.PixelWidth <= 0) or (AGeometry.PixelHeight <= 0) then
  begin
    AError := 'capture size is empty';
    AFilter.release;
    AFilter := nil;
    Exit;
  end;

  FReport.PixelWidth := AGeometry.PixelWidth;
  FReport.PixelHeight := AGeometry.PixelHeight;
  FReport.Scale := Scale;
  Result := True;
end;

procedure TRecordingSession.RunUntilStopped;
var
  Slice: Integer;
  Statistics: TMovieWriterStatistics;
begin
  Slice := 0;
  while not StopRequested do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, RunLoopSliceSeconds, False);
    Inc(Slice);
    // The CLI's event logger. The menu-bar app calls the same method from
    // its own 30 Hz timer; neither has a timer of its own for it.
    SampleMetadata;
    // One rejected buffer fails AVAssetWriter for good; keeping the
    // stream running would record minutes into a dead file. Abort as
    // soon as the capture threads have flagged it.
    if FWriter.Statistics.WriterFailed then
    begin
      WriteLn('writer failed — stopping');
      Flush(Output);
      Break;
    end;
    if Slice mod ProgressEverySlices = 0 then
    begin
      Statistics := FWriter.Statistics;
      WriteLn(Format('  %6.1fs  %d frames  %d dropped', [Statistics.Duration,
        Statistics.AppendedFrames, Statistics.DroppedFrames]));
      Flush(Output);
    end;
  end;
end;

function TRecordingSession.StartCapture(out AError: string): Boolean;
var
  Content: TShareableContent;
begin
  Result := False;
  AError := '';
  if FCapturing then
  begin
    AError := 'this session is already recording';
    Exit;
  end;
  // A session records once. Restarting one that has already finished
  // would strand the previous writer and stream behind the new fields;
  // the app makes a fresh TRecordingSession per recording.
  if (FWriter <> nil) or (FStream <> nil) or (FFilter <> nil) then
  begin
    AError := 'this session has already been used; create a new one';
    Exit;
  end;
  FReport := Default(TRecordingReport);
  FReport.OutputPath := FOptions.OutputPath;
  FReport.FramesPerSecond := FOptions.FramesPerSecond;
  FReport.AudioMode := FOptions.AudioMode;

  try
    Content := TShareableContent.Create;
  except
    on E: EShareableContent do
    begin
      AError := E.Message;
      Exit;
    end;
  end;
  try
    if not ResolveFilter(Content, FFilter, FGeometry, AError) then
      Exit;
  finally
    Content.Free;
  end;

  FReport.BitRate := FOptions.BitRate;
  if FReport.BitRate = 0 then
    FReport.BitRate := SuggestedBitRate(FGeometry.PixelWidth,
      FGeometry.PixelHeight, FGeometry.FramesPerSecond);

  FReport.AudioMode := FOptions.AudioMode;
  FWriter := TMovieWriter.Create(FOptions.OutputPath, FOptions.Container,
    FGeometry.PixelWidth, FGeometry.PixelHeight, FGeometry.FramesPerSecond,
    FReport.BitRate);
  if FGeometry.CapturesAudio or FGeometry.CapturesMicrophone then
    FWriter.EnableAudioTracks(FGeometry.CapturesAudio,
      FGeometry.CapturesMicrophone, FOptions.AudioSampleRate,
      FOptions.AudioChannelCount, FOptions.AudioBitRate);
  if not FWriter.Open(AError) then
  begin
    FreeAndNil(FWriter);
    ReleaseFilter;
    Exit;
  end;

  // The sprite is made here, on the main thread, before a single frame
  // can arrive — nothing on the capture queue may ask AppKit for
  // anything. A failure is not a reason to lose the recording: the file
  // is written without a drawn pointer and the report says so, which is
  // the same shape as a refused live update.
  if FReport.BigCursor then
  begin
    FCursorOverlay := TCursorOverlay.Create;
    if not FCursorOverlay.Prepare(FDisplayID, FGeometry.PixelWidth,
      FGeometry.PixelHeight, FBaseRect, FReport.BigCursorError) then
    begin
      FreeAndNil(FCursorOverlay);
      FReport.BigCursor := False;
      // Put the system pointer back. ResolveFilter switched it off for a
      // drawn one that is not going to exist, and the configuration is
      // built from this geometry a few lines below — so the choice is
      // still open, and a recording with the ordinary cursor beats one
      // with no cursor at all.
      FGeometry.ShowsCursor := FOptions.ShowsCursor;
    end;
  end;

  FStream := TScreenStream.Create(FFilter, FGeometry);
  FStream.OnSample := HandleSample;
  if not FStream.Start then
  begin
    AError := FStream.LastError;
    FWriter.Cancel;
    FreeAndNil(FStream);
    FreeAndNil(FWriter);
    ReleaseFilter;
    Exit;
  end;

  FCapturing := True;
  // Last, once the capture is really running: a start that failed leaves
  // no half-written sidecar next to a movie that does not exist, and the
  // header can be filled from a geometry nothing will change again.
  OpenSidecar;
  // The first sample before the caller's first tick, so a recording
  // stopped almost immediately still has a track rather than an empty one.
  SampleMetadata;
  Result := True;
end;

function TRecordingSession.CurrentSourceRect: CGRect;
begin
  if (FStream <> nil) and FStream.HasSentRect then
    Result := FStream.LastSentRect
  else
    Result := FBaseRect;
end;

function TRecordingSession.SidecarPath: string;
begin
  if FSidecar = nil then
    Result := ''
  else
    Result := FSidecar.Path;
end;

// The header is everything about the recording that the samples cannot
// say for themselves. Written once, before the first frame can arrive; the
// anchor that makes the times mean anything follows as soon as the writer
// has started the movie's session (SampleMetadata).
procedure TRecordingSession.OpenSidecar;
var
  Header: TSidecarHeader;
  Bounds: CGRect;
begin
  FSidecar := TSidecarWriter.Create(SidecarPathFor(FOptions.OutputPath));
  FReport.SidecarPath := FSidecar.Path;
  if FSidecar.Failed then
  begin
    FReport.SidecarError := FSidecar.LastError;
    FreeAndNil(FSidecar);
    FReport.SidecarPath := '';
    Exit;
  end;

  // Global point space, as CGEventGetLocation answers in. Zero for a
  // window target, whose FDisplayID was never resolved: those samples stay
  // global on purpose, and the header says so.
  FDisplayOriginX := 0;
  FDisplayOriginY := 0;
  Header := Default(TSidecarHeader);
  if FDisplayID <> 0 then
  begin
    Bounds := CGDisplayBounds(FDisplayID);
    FDisplayOriginX := Bounds.origin.x;
    FDisplayOriginY := Bounds.origin.y;
    Header.DisplayWidth := Bounds.size.width;
    Header.DisplayHeight := Bounds.size.height;
  end;
  Header.Version := SidecarFormatVersion;
  Header.KnipsVersion := KnipsVersion;
  // Darwin-only separator: FPC's ExtractFileName also treats a backslash
  // as one, so a movie legitimately called `a\b.mp4` would be recorded in
  // the sidecar as `b.mp4` and recovery would look for a file that does
  // not exist.
  Header.MovieName := Copy(FOptions.OutputPath,
    LastDelimiter('/', FOptions.OutputPath) + 1, MaxInt);
  Header.CreatedUtc := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
  // The one field the recovery pass needs: a sidecar with no trailer is
  // both a crashed take and a take in progress, and this is what tells
  // them apart (Knips.Recording.Recovery).
  Header.ProcessID := FpGetPid;
  Header.TargetKind := FOptions.TargetKind;
  Header.PixelWidth := FGeometry.PixelWidth;
  Header.PixelHeight := FGeometry.PixelHeight;
  Header.Scale := FReport.Scale;
  Header.FramesPerSecond := FGeometry.FramesPerSecond;
  Header.SampleHz := DefaultSidecarSampleHz;
  Header.DisplayID := FDisplayID;
  Header.BaseX := FBaseRect.origin.x;
  Header.BaseY := FBaseRect.origin.y;
  Header.BaseWidth := FBaseRect.size.width;
  Header.BaseHeight := FBaseRect.size.height;
  // Three states, and the movie looks different in each: Big Cursor drew
  // its own pointer, ScreenCaptureKit drew the system one, or nothing did.
  if FReport.BigCursor then
    Header.CursorRender := scrBaked
  else if FReport.SmoothCursor then
    Header.CursorRender := scrSmooth
  else if FGeometry.ShowsCursor then
    Header.CursorRender := scrSystem
  else
    Header.CursorRender := scrNone;
  // What the capture itself did, which is what an export can no longer
  // choose: the live effects move ScreenCaptureKit's own source
  // rectangle, so a take that zoomed is zoomed in its pixels.
  //
  // Resolved here as well as by the caller, so the invariant "these are
  // what the capture DID" is local to this unit and cannot be broken by a
  // caller passing its preferences straight through. ResolveLiveEffects
  // is the same function the app asks, and it answers the same way.
  ResolveLiveEffects(FOptions.TargetKind, FOptions.HasRegion,
    FOptions.LiveZoomOnClick, FOptions.LiveFollowMouse,
    Header.BakedZoomOnClick, Header.BakedFollowMouse);
  Header.BakedWindowFollow := FOptions.LiveWindowFollow;
  Header.AudioMode := FOptions.AudioMode;
  FSidecar.WriteHeader(Header);
end;

procedure TRecordingSession.CloseSidecar;
begin
  if FSidecar = nil then
    Exit;
  FSidecar.Close;
  FReport.SidecarSamples := FSidecar.SampleCount;
  if FSidecar.Failed and (FReport.SidecarError = '') then
    FReport.SidecarError := FSidecar.LastError;
  FreeAndNil(FSidecar);
end;

procedure TRecordingSession.SampleMetadata;
var
  Event: CGEventRef;
  Location: CGPoint;
  Moment: Double;
  Statistics: TMovieWriterStatistics;
  Sample: TSidecarSample;
  Edge: TSidecarButtonEvent;
  Source: CGRect;
  Buttons: Integer;
begin
  // Main thread. Nothing here may be reached from the capture queue: it
  // allocates, it writes to a file, and it sends no Objective-C message
  // only by luck rather than by rule.
  if (FSidecar = nil) or not FCapturing then
    Exit;

  // The anchor, as soon as there is one. AVAssetWriter starts the movie's
  // session at the first appended frame's presentation stamp, so until a
  // frame has arrived there is no timeline for an event to sit on — and
  // once one has, this never changes again.
  if not FSidecar.AnchorWritten and (FWriter <> nil) then
  begin
    Statistics := FWriter.Statistics;
    if Statistics.SessionStarted then
    begin
      FSidecar.WriteAnchor(Statistics.FirstSampleSeconds);
      FReport.AnchorHostSeconds := Statistics.FirstSampleSeconds;
    end;
  end;

  // The clock first, then the position: the sample's time is then at or a
  // few microseconds before the instant the position was read, which is
  // the direction that makes an interpolation between two samples cover
  // the movement rather than fall short of it.
  Moment := HostClockSeconds;
  Event := CGEventCreate(nil);
  if Event = nil then
    Exit;
  Location := CGEventGetLocation(Event);
  CFRelease(Event);

  // CGEventSourceButtonState, not an event tap: a tap would need the
  // Input Monitoring grant, and this recorder asks for Screen Recording
  // and (for the camera) Camera and nothing else. The cost is stated
  // rather than hidden — a press and release inside one sample period,
  // about 33 ms, is not seen at all, and the edge times this produces are
  // accurate to one period. Only the left button is read: the right one
  // opens a context menu, which is not a gesture anybody wants recorded
  // as a click on the content.
  Buttons := 0;
  if CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,
    kCGMouseButtonLeft) <> 0 then
    Buttons := SidecarLeftButton;

  Source := CurrentSourceRect;
  Sample := Default(TSidecarSample);
  Sample.Time := Moment;
  Sample.X := Location.x - FDisplayOriginX;
  Sample.Y := Location.y - FDisplayOriginY;
  Sample.Buttons := Buttons;
  Sample.SourceX := Source.origin.x;
  Sample.SourceY := Source.origin.y;
  Sample.SourceWidth := Source.size.width;
  Sample.SourceHeight := Source.size.height;
  FSidecar.WriteSample(Sample);

  // Edge-triggered, and written as its own record: a reader looking for
  // clicks should not have to diff a thousand samples to find three of
  // them. The level is in every sample as well, so both readings are
  // available. The first tick establishes the level without inventing an
  // edge — whatever the button was doing when the recording started is
  // not a click into it.
  if FHasSidecarButtons and (Buttons <> FSidecarButtons) then
  begin
    Edge := Default(TSidecarButtonEvent);
    Edge.Time := Moment;
    Edge.X := Sample.X;
    Edge.Y := Sample.Y;
    Edge.Button := 0;
    Edge.Down := (Buttons and SidecarLeftButton) <> 0;
    FSidecar.WriteButton(Edge);
  end;
  FSidecarButtons := Buttons;
  FHasSidecarButtons := True;
end;

function TRecordingSession.UpdateSourceRect(const ARect: CGRect): Boolean;
begin
  Result := FCapturing and (FStream <> nil)
    and FStream.UpdateSourceRect(ARect);
  // From the stream's own record of what it sent, not from ARect: an
  // update inside the epsilon, or one dropped because another was still
  // in flight, never reached ScreenCaptureKit, and placing the drawn
  // pointer by a rectangle the capture is not reading would put it a few
  // pixels off for as long as the animation ran. Gated on Result: after
  // a refusal the stream's record is a rectangle it never adopted, and
  // the epsilon/coalesce paths return True with the record unchanged,
  // so the gate loses nothing.
  if Result and (FCursorOverlay <> nil) and (FStream <> nil)
    and FStream.HasSentRect then
    FCursorOverlay.SetSourceRect(FStream.LastSentRect);
end;

function TRecordingSession.SupportsLiveUpdate: Boolean;
begin
  Result := FCapturing and (FStream <> nil) and FStream.SupportsLiveUpdate;
end;

function TRecordingSession.LiveUpdateError: string;
begin
  if FStream = nil then
    Result := ''
  else
    Result := FStream.LastError;
end;

function TRecordingSession.BaseSourceRect: CGRect;
begin
  if FGeometry.HasSourceRect then
    Result := FGeometry.SourceRect
  else
    Result := CGRectMake(0, 0, 0, 0);
end;

function TRecordingSession.LiveUpdatesSent: Int64;
begin
  if FStream = nil then
    Result := FReport.LiveUpdatesSent
  else
    Result := FStream.LiveUpdatesSent;
end;

function TRecordingSession.FinishCapture(out AError: string): Boolean;
var
  Statistics: TMovieWriterStatistics;
  Trailer: TSidecarTrailer;
begin
  Result := False;
  AError := '';
  if not FCapturing then
  begin
    AError := 'no recording is running';
    Exit;
  end;
  // One last pointer sample while the recording is still running, so the
  // track reaches the end of the movie rather than stopping at the
  // caller's last tick.
  SampleMetadata;
  FCapturing := False;

  // Stream first, then writer: an append must never race the finish.
  if FStream <> nil then
    FStream.Stop;

  // After the stop, not before: Stop waits out the last live update, so
  // reading here counts it rather than reporting one fewer than was sent.
  if FStream <> nil then
  begin
    FReport.LiveUpdatesSent := FStream.LiveUpdatesSent;
    FReport.LiveUpdatesCompleted := FStream.LiveUpdatesCompleted;
    FReport.LiveUpdatesFailed := FStream.LiveUpdatesFailed;
    FReport.LiveUpdateErrorCode := FStream.LiveUpdateErrorCode;
  end;

  // The compositor's own totals, read after the stream has stopped so
  // the capture queue is no longer incrementing them.
  if FCursorOverlay <> nil then
  begin
    FReport.CursorFrames := FCursorOverlay.CompositedFrames;
    FReport.CursorOffFrame := FCursorOverlay.OffFrameFrames;
    FReport.CursorRefused := FCursorOverlay.RefusedFrames;
  end;

  Statistics := FWriter.Statistics;
  FReport.AppendedFrames := Statistics.AppendedFrames;
  FReport.DroppedFrames := Statistics.DroppedFrames;
  FReport.FailedAppends := Statistics.FailedAppends;
  FReport.AppendedAudioSamples := Statistics.AppendedAudioSamples;
  FReport.DroppedAudioEarly := Statistics.DroppedAudioEarly;
  FReport.DroppedAudioStalled := Statistics.DroppedAudioStalled;
  FReport.FailedAudioAppends := Statistics.FailedAudioAppends;
  FReport.AppendedMicrophoneSamples := Statistics.AppendedMicrophoneSamples;
  FReport.DroppedMicrophoneEarly := Statistics.DroppedMicrophoneEarly;
  FReport.DroppedMicrophoneStalled := Statistics.DroppedMicrophoneStalled;
  FReport.FailedMicrophoneAppends := Statistics.FailedMicrophoneAppends;
  FReport.AudioPeak := Statistics.AudioPeak;
  FReport.AudioInspected := Statistics.AudioInspected;
  FReport.MicrophonePeak := Statistics.MicrophonePeak;
  FReport.MicrophoneInspected := Statistics.MicrophoneInspected;
  FReport.DurationSeconds := Statistics.Duration;

  // The trailer, and the second half of the drift measurement: the host
  // time at the stop against the movie's own duration. Both come from the
  // clock ScreenCaptureKit stamps frames with, so the two must agree to
  // within the gap between the last frame and this line.
  FReport.StopHostSeconds := HostClockSeconds;

  Result := FWriter.Finish(AError);
  // The trailer goes AFTER the finish, and only when it succeeded. The
  // trailer is what says "this take is complete"; writing it before the
  // movie was actually finalised would mark a take that then failed to
  // finish as one recovery must never look at again.
  if Result and (FSidecar <> nil) then
  begin
    Trailer := Default(TSidecarTrailer);
    Trailer.Time := FReport.StopHostSeconds;
    Trailer.Frames := Statistics.AppendedFrames;
    Trailer.DurationSeconds := Statistics.Duration;
    Trailer.Samples := FSidecar.SampleCount;
    FSidecar.WriteTrailer(Trailer);
  end;
  CloseSidecar;
  ReleaseFilter;
end;

function TRecordingSession.LiveStatistics: TMovieWriterStatistics;
begin
  if FWriter = nil then
    Result := Default(TMovieWriterStatistics)
  else
    Result := FWriter.Statistics;
end;

function TRecordingSession.Run(out AError: string): Boolean;
var
  AudioNote: string;
begin
  Result := False;
  if not StartCapture(AError) then
    Exit;

  if FReport.BigCursorError <> '' then
  begin
    WriteLn('big cursor: ', FReport.BigCursorError,
      ' — recording the system pointer instead');
    Flush(Output);
  end;

  if FGeometry.CapturesAudio or FGeometry.CapturesMicrophone then
    AudioNote := Format(' + %s audio (AAC %d kHz, %d ch)',
      [AudioModeName(FOptions.AudioMode),
      FOptions.AudioSampleRate div 1000, FOptions.AudioChannelCount])
  else
    AudioNote := '';
  WriteLn(Format('recording %dx%d @ %d fps (%d kbit/s)%s to %s — Ctrl-C to stop',
    [FGeometry.PixelWidth, FGeometry.PixelHeight, FGeometry.FramesPerSecond,
    FReport.BitRate div 1000, AudioNote, FOptions.OutputPath]));
  Flush(Output);

  RunUntilStopped;

  Result := FinishCapture(AError);
end;

{$ENDIF}

end.

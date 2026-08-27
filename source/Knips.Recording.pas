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
    // Why the drawn pointer was given up on, when it was; '' otherwise.
    // Never a reason to fail the recording — the file is written with
    // the ordinary system cursor instead.
    BigCursorError: string;
    CursorFrames: Int64;
    CursorOffFrame: Int64;
    CursorRefused: Int64;
    DurationSeconds: Double;
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
    procedure HandleSample(ASampleBuffer: CMSampleBufferRef;
      AKind: TSampleKind);
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
  RunLoopSliceSeconds = 0.25;
  ProgressEverySlices = 8;

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
  AGeometry.ShowsCursor := FOptions.ShowsCursor and not FReport.BigCursor;
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
  Result := True;
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
begin
  Result := False;
  AError := '';
  if not FCapturing then
  begin
    AError := 'no recording is running';
    Exit;
  end;
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
  FReport.DurationSeconds := Statistics.Duration;

  Result := FWriter.Finish(AError);
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

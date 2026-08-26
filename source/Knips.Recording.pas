unit Knips.Recording;

// One recording, start to finish: resolve what to capture, size the
// stream in pixels, open the movie, run the ScreenCaptureKit stream into
// it until a stop is requested, then finalise the file.
//
// The main thread owns everything except HandleSample, which the capture
// queue calls; it only forwards the buffer to the writer (whose counters
// are mutex-guarded). Stop arrives through a signal-safe flag set by the
// program's SIGINT/SIGTERM handler.

{$I Shared.inc}

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
    AppendedAudioSamples: Int64;
    DroppedAudioEarly: Int64;
    DroppedAudioStalled: Int64;
    FailedAudioAppends: Int64;
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
    procedure HandleSample(ASampleBuffer: CMSampleBufferRef;
      AKind: TSampleKind);
    function ResolveFilter(const AContent: TShareableContent;
      out AFilter: SCContentFilter; out AGeometry: TStreamGeometry;
      out AError: string): Boolean;
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
  FreeAndNil(FStream);
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
  // Video and audio arrive on separate queues; the writer's mutex is what
  // keeps the two appends from overlapping.
  if FWriter = nil then
    Exit;
  if AKind = skVideo then
    FWriter.AppendVideoSample(ASampleBuffer)
  else if AKind = skAudio then
    FWriter.AppendAudioSample(ASampleBuffer);
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
        end
        else
        begin
          PointWidth := Integer(Display.width);
          PointHeight := Integer(Display.height);
        end;
        AFilter := SCContentFilter(
          SCContentFilter.alloc.initWithDisplay_excludingWindows(Display,
          NSArray.array_));
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
  AGeometry.ShowsCursor := FOptions.ShowsCursor;
  AGeometry.CapturesAudio := FOptions.AudioMode <> amNone;
  AGeometry.AudioSampleRate := FOptions.AudioSampleRate;
  AGeometry.AudioChannelCount := FOptions.AudioChannelCount;
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
  if FGeometry.CapturesAudio then
    FWriter.EnableAudio(FOptions.AudioSampleRate,
      FOptions.AudioChannelCount, FOptions.AudioBitRate);
  if not FWriter.Open(AError) then
  begin
    FreeAndNil(FWriter);
    ReleaseFilter;
    Exit;
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

  Statistics := FWriter.Statistics;
  FReport.AppendedFrames := Statistics.AppendedFrames;
  FReport.DroppedFrames := Statistics.DroppedFrames;
  FReport.FailedAppends := Statistics.FailedAppends;
  FReport.AppendedAudioSamples := Statistics.AppendedAudioSamples;
  FReport.DroppedAudioEarly := Statistics.DroppedAudioEarly;
  FReport.DroppedAudioStalled := Statistics.DroppedAudioStalled;
  FReport.FailedAudioAppends := Statistics.FailedAudioAppends;
  FReport.DurationSeconds := Statistics.Duration;

  Result := FWriter.Finish(AError);
  ReleaseFilter;
end;

function TRecordingSession.Run(out AError: string): Boolean;
var
  AudioNote: string;
begin
  Result := False;
  if not StartCapture(AError) then
    Exit;

  if FGeometry.CapturesAudio then
    AudioNote := Format(' + %s audio (%d kHz, %d ch)',
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

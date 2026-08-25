unit Opname.Recording;

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
  MacOSAll,
  Opname.Capture.CoreMedia,
  Opname.Capture.ScreenCaptureKit,
  Opname.Capture.ShareableContent,
  Opname.Capture.Stream,
  Opname.Export.MovieWriter,
  Opname.Options;

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
    DurationSeconds: Double;
  end;

  TRecordingSession = class
  private
    FOptions: TRecordingOptions;
    FWriter: TMovieWriter;
    FStream: TScreenStream;
    FReport: TRecordingReport;
    procedure HandleSample(ASampleBuffer: CMSampleBufferRef;
      AKind: TSampleKind);
    function ResolveFilter(const AContent: TShareableContent;
      out AFilter: SCContentFilter; out AGeometry: TStreamGeometry;
      out AError: string): Boolean;
    procedure RunUntilStopped;
  public
    constructor Create(const AOptions: TRecordingOptions);
    destructor Destroy; override;
    // Blocks until StopRequested is set. False with a message on any
    // failure before or after capture.
    function Run(out AError: string): Boolean;
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
  inherited Destroy;
end;

procedure TRecordingSession.HandleSample(ASampleBuffer: CMSampleBufferRef;
  AKind: TSampleKind);
begin
  // Capture-queue context: no exceptions, no WriteLn, no managed types.
  if (AKind = skVideo) and (FWriter <> nil) then
    FWriter.AppendVideoSample(ASampleBuffer);
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
          AError := Format('no on-screen window with id %d (see `opname windows`)',
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
        AError := Format('no display at index %d (see `opname displays`)',
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
            Display.release;
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
    if Slice mod ProgressEverySlices = 0 then
    begin
      Statistics := FWriter.Statistics;
      WriteLn(Format('  %6.1fs  %d frames  %d dropped', [Statistics.Duration,
        Statistics.AppendedFrames, Statistics.DroppedFrames]));
      Flush(Output);
    end;
  end;
end;

function TRecordingSession.Run(out AError: string): Boolean;
var
  Content: TShareableContent;
  Filter: SCContentFilter;
  Geometry: TStreamGeometry;
  Statistics: TMovieWriterStatistics;
  FinishError: string;
begin
  Result := False;
  AError := '';
  FReport := Default(TRecordingReport);
  FReport.OutputPath := FOptions.OutputPath;
  FReport.FramesPerSecond := FOptions.FramesPerSecond;

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
    if not ResolveFilter(Content, Filter, Geometry, AError) then
      Exit;
  finally
    Content.Free;
  end;

  try
    FReport.BitRate := FOptions.BitRate;
    if FReport.BitRate = 0 then
      FReport.BitRate := SuggestedBitRate(Geometry.PixelWidth,
        Geometry.PixelHeight, Geometry.FramesPerSecond);

    FWriter := TMovieWriter.Create(FOptions.OutputPath, FOptions.Container,
      Geometry.PixelWidth, Geometry.PixelHeight, Geometry.FramesPerSecond,
      FReport.BitRate);
    if not FWriter.Open(AError) then
      Exit;

    FStream := TScreenStream.Create(Filter, Geometry);
    FStream.OnSample := HandleSample;
    if not FStream.Start then
    begin
      AError := FStream.LastError;
      FWriter.Cancel;
      Exit;
    end;

    WriteLn(Format('recording %dx%d @ %d fps (%d kbit/s) to %s — Ctrl-C to stop',
      [Geometry.PixelWidth, Geometry.PixelHeight, Geometry.FramesPerSecond,
      FReport.BitRate div 1000, FOptions.OutputPath]));
    Flush(Output);

    RunUntilStopped;

    FStream.Stop;
    Statistics := FWriter.Statistics;
    FReport.AppendedFrames := Statistics.AppendedFrames;
    FReport.DroppedFrames := Statistics.DroppedFrames;
    FReport.FailedAppends := Statistics.FailedAppends;
    FReport.DurationSeconds := Statistics.Duration;

    if not FWriter.Finish(FinishError) then
    begin
      AError := FinishError;
      Exit;
    end;
    Result := True;
  finally
    Filter.release;
  end;
end;

{$ENDIF}

end.

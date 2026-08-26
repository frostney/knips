unit Opname.Export.MovieReader;

// The movie source: AVAssetReader decodes an .mp4/.mov video track and
// hands back BGRA CVPixelBuffers with their presentation stamps — the
// mirror image of Opname.Export.MovieWriter, and declared in the same
// style (external objcclass bindings, no runtime-built classes needed
// because nothing here is a delegate).
//
// A reader cannot seek backwards, so a pass is one forward walk over a
// CMTimeRange. StartPass may be called again to make a second reader
// over the same range; that is how the GIF pipeline samples colours
// first and encodes second without holding frames in memory.
//
// Everything here runs on the main thread, so exceptions and WriteLn
// would be legal; failures are still reported as strings because the
// caller has to turn them into an exit code.

{$I Shared.inc}

interface

{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cvar}

uses
  SysUtils,

  CocoaAll,
  MacOSAll,
  Opname.Capture.CoreMedia;

{$linkframework AVFoundation}
{$linkframework CoreMedia}
{$linkframework CoreVideo}

const
  // AVAssetReaderStatus
  AVAssetReaderStatusUnknown = 0;
  AVAssetReaderStatusReading = 1;
  AVAssetReaderStatusCompleted = 2;
  AVAssetReaderStatusFailed = 3;
  AVAssetReaderStatusCancelled = 4;
  // Timescale for the trim range: 1/600 s is finer than any frame rate
  // a screen recording uses and is QuickTime's own convention.
  TrimTimeScale = 600;

type
  CMTimeRange = record
    start: CMTime;
    duration: CMTime;
  end;

  AVAssetTrack = objcclass external (NSObject)
    function NaturalSize: CGSize; message 'naturalSize';
    function NominalFrameRate: Single; message 'nominalFrameRate';
    // Identity unless the recording was made sideways or mirrored.
    function PreferredTransform: CGAffineTransform;
      message 'preferredTransform';
  end;

  AVAsset = objcclass external (NSObject)
    function Tracks: NSArray; message 'tracks';
    function TracksWithMediaType(AMediaType: NSString): NSArray;
      message 'tracksWithMediaType:';
    function Duration: CMTime; message 'duration';
  end;

  AVURLAsset = objcclass external (AVAsset)
    class function URLAssetWithURL_options(AURL: NSURL;
      AOptions: NSDictionary): id; message 'URLAssetWithURL:options:';
  end;

  AVAssetReaderOutput = objcclass external (NSObject)
    procedure SetAlwaysCopiesSampleData(ACopies: ObjCBOOL);
      message 'setAlwaysCopiesSampleData:';
    // Returns a retained buffer; the caller releases it.
    function CopyNextSampleBuffer: CMSampleBufferRef;
      message 'copyNextSampleBuffer';
  end;

  AVAssetReaderTrackOutput = objcclass external (AVAssetReaderOutput)
    class function AssetReaderTrackOutputWithTrack_outputSettings(
      ATrack: AVAssetTrack; AOutputSettings: NSDictionary): id;
      message 'assetReaderTrackOutputWithTrack:outputSettings:';
  end;

  AVAssetReader = objcclass external (NSObject)
    class function AssetReaderWithAsset_error(AAsset: AVAsset;
      AOutError: NSErrorPtr): id; message 'assetReaderWithAsset:error:';
    procedure SetTimeRange(ATimeRange: CMTimeRange); message 'setTimeRange:';
    function CanAddOutput(AOutput: AVAssetReaderOutput): ObjCBOOL;
      message 'canAddOutput:';
    procedure AddOutput(AOutput: AVAssetReaderOutput); message 'addOutput:';
    function StartReading: ObjCBOOL; message 'startReading';
    procedure CancelReading; message 'cancelReading';
    function Status: NSInteger; message 'status';
    function Error: NSError; message 'error';
  end;

var
  AVMediaTypeVideo: NSString; cvar; external;
  // The reader's range needs an end even when the caller has none and
  // the asset will not say how long it is.
  kCMTimePositiveInfinity: CMTime;
    external name '_kCMTimePositiveInfinity';

function CMTimeMakeWithSeconds(ASeconds: Float64;
  APreferredTimescale: Int32): CMTime;
  external name '_CMTimeMakeWithSeconds';

type
  TMovieReaderFrame = record
    // Valid until the next NextFrame, StopPass or Free; never retained
    // by the caller.
    PixelBuffer: CVPixelBufferRef;
    Seconds: Double;
  end;

  TMovieReader = class
  private
    FInputPath: string;
    FAsset: AVAsset;
    FTrack: AVAssetTrack;
    FReader: AVAssetReader;
    FOutput: AVAssetReaderTrackOutput;
    FSample: CMSampleBufferRef;
    FPixelWidth: Integer;
    FPixelHeight: Integer;
    FDurationSeconds: Double;
    FNominalFrameRate: Double;
    FLastError: string;
    procedure ReleaseSample;
    function BuildOutputSettings: NSDictionary;
    function ReaderError(const APrefix: string): string;
  public
    constructor Create(const AInputPath: string);
    destructor Destroy; override;
    // Loads the asset and its first video track. False with a message
    // when the file is missing, unreadable, or has no video.
    function Open(out AError: string): Boolean;
    // Starts a decode pass over [AStartSeconds, AStartSeconds +
    // ADurationSeconds). ADurationSeconds <= 0 reads to the end. Calling
    // it again replaces the reader and rewinds to the start of the range.
    function StartPass(AStartSeconds, ADurationSeconds: Double;
      out AError: string): Boolean;
    // False at the end of the pass. LastError is set when the pass ended
    // because the reader failed rather than because it ran out.
    function NextFrame(out AFrame: TMovieReaderFrame): Boolean;
    procedure StopPass;
    property PixelWidth: Integer read FPixelWidth;
    property PixelHeight: Integer read FPixelHeight;
    property DurationSeconds: Double read FDurationSeconds;
    property NominalFrameRate: Double read FNominalFrameRate;
    property LastError: string read FLastError;
  end;

{$ENDIF}

implementation

{$IFDEF DARWIN}

// A video track's preferredTransform carries rotation and mirroring;
// only the 2x2 part can turn the picture, so a pure translation (which
// no recorder emits on its own) is not worth refusing over.
function IsIdentityTransform(const ATransform: CGAffineTransform): Boolean;
const
  Tolerance = 1E-6;
begin
  Result := (Abs(ATransform.a - 1) < Tolerance)
    and (Abs(ATransform.b) < Tolerance)
    and (Abs(ATransform.c) < Tolerance)
    and (Abs(ATransform.d - 1) < Tolerance);
end;

{ TMovieReader }

constructor TMovieReader.Create(const AInputPath: string);
begin
  inherited Create;
  FInputPath := AInputPath;
end;

destructor TMovieReader.Destroy;
begin
  StopPass;
  if FTrack <> nil then
    FTrack.release;
  if FAsset <> nil then
    FAsset.release;
  inherited Destroy;
end;

procedure TMovieReader.ReleaseSample;
begin
  if FSample <> nil then
  begin
    CMSampleBufferRelease(FSample);
    FSample := nil;
  end;
end;

function TMovieReader.ReaderError(const APrefix: string): string;
var
  Error: NSError;
begin
  Result := APrefix;
  if FReader = nil then
    Exit;
  Error := FReader.error;
  if Error <> nil then
    Result := APrefix + ': ' + string(Error.localizedDescription.UTF8String);
end;

function TMovieReader.Open(out AError: string): Boolean;
var
  URL: NSURL;
  Tracks: NSArray;
  Size: CGSize;
begin
  Result := False;
  AError := '';
  if not FileExists(FInputPath) then
  begin
    AError := 'no such file: ' + FInputPath;
    Exit;
  end;

  URL := NSURL.fileURLWithPath(NSSTR(PAnsiChar(FInputPath)));
  FAsset := AVAsset(AVURLAsset.URLAssetWithURL_options(URL, nil));
  if FAsset = nil then
  begin
    AError := 'AVURLAsset could not open ' + FInputPath;
    Exit;
  end;
  FAsset.retain;

  Tracks := FAsset.tracksWithMediaType(AVMediaTypeVideo);
  if (Tracks = nil) or (Tracks.count = 0) then
  begin
    // An asset with no tracks at all was never parsed as a movie; one
    // with tracks but no video really is an audio-only file. Saying
    // "no video track" for a truncated download sends people looking
    // in the wrong place.
    if (FAsset.tracks = nil) or (FAsset.tracks.count = 0) then
      AError := FInputPath + ' could not be read as a movie (it may be '
        + 'truncated, or not a movie at all)'
    else
      AError := FInputPath + ' has no video track';
    Exit;
  end;
  FTrack := AVAssetTrack(Tracks.objectAtIndex(0));
  FTrack.retain;

  if not IsIdentityTransform(FTrack.preferredTransform) then
  begin
    // Honouring the transform means a rotation pass over every frame;
    // exporting sideways silently would be worse than saying no.
    AError := FInputPath + ' is a rotated or mirrored recording; '
      + 'rotated sources are not supported yet';
    Exit;
  end;

  Size := FTrack.naturalSize;
  FPixelWidth := Round(Abs(Size.width));
  FPixelHeight := Round(Abs(Size.height));
  if (FPixelWidth <= 0) or (FPixelHeight <= 0) then
  begin
    AError := FInputPath + ' reports an empty video size';
    Exit;
  end;
  FDurationSeconds := CMTimeGetSeconds(FAsset.duration);
  if not (FDurationSeconds > 0) then
    FDurationSeconds := 0;
  FNominalFrameRate := FTrack.nominalFrameRate;
  Result := True;
end;

function TMovieReader.BuildOutputSettings: NSDictionary;
var
  Settings: NSMutableDictionary;
begin
  Settings := NSMutableDictionary.dictionaryWithCapacity(1);
  // kCVPixelFormatType_32BGRA fits in a signed 32-bit integer, so the
  // NSNumber the writer already uses everywhere works here too.
  Settings.setObject_forKey(
    NSNumber.numberWithInt(Integer(kCVPixelFormatType_32BGRA)),
    id(kCVPixelBufferPixelFormatTypeKey));
  Result := Settings;
end;

function TMovieReader.StartPass(AStartSeconds, ADurationSeconds: Double;
  out AError: string): Boolean;
var
  Error: NSError;
  Range: CMTimeRange;
begin
  Result := False;
  AError := '';
  FLastError := '';
  StopPass;
  if FAsset = nil then
  begin
    AError := 'the movie is not open';
    Exit;
  end;
  if AStartSeconds < 0 then
    AStartSeconds := 0;
  if ADurationSeconds <= 0 then
  begin
    if FDurationSeconds > AStartSeconds then
      ADurationSeconds := FDurationSeconds - AStartSeconds
    else
      ADurationSeconds := 0;
  end;

  Error := nil;
  FReader := AVAssetReader(AVAssetReader.assetReaderWithAsset_error(FAsset,
    @Error));
  if FReader = nil then
  begin
    if Error <> nil then
      AError := 'AVAssetReader: '
        + string(Error.localizedDescription.UTF8String)
    else
      AError := 'AVAssetReader could not be created';
    Exit;
  end;
  FReader.retain;

  // The range has to be set before reading starts; the framework throws
  // once the status has moved past Unknown. It is set even when the end
  // is open, because otherwise an asset that will not report its own
  // duration would quietly ignore the trim's start as well.
  Range.start := CMTimeMakeWithSeconds(AStartSeconds, TrimTimeScale);
  if ADurationSeconds > 0 then
    Range.duration := CMTimeMakeWithSeconds(ADurationSeconds, TrimTimeScale)
  else
    Range.duration := kCMTimePositiveInfinity;
  FReader.setTimeRange(Range);

  FOutput := AVAssetReaderTrackOutput(
    AVAssetReaderTrackOutput.assetReaderTrackOutputWithTrack_outputSettings(
    FTrack, BuildOutputSettings));
  if FOutput = nil then
  begin
    AError := 'AVAssetReaderTrackOutput could not be created';
    Exit;
  end;
  FOutput.retain;
  // Nothing writes into the decoded buffers, so the extra copy the
  // framework would otherwise make is pure cost.
  FOutput.setAlwaysCopiesSampleData(ObjCBOOL(False));

  if not FReader.canAddOutput(FOutput) then
  begin
    AError := 'AVAssetReader rejected the video output';
    Exit;
  end;
  FReader.addOutput(FOutput);

  if not FReader.startReading then
  begin
    AError := ReaderError('startReading failed');
    Exit;
  end;
  Result := True;
end;

function TMovieReader.NextFrame(out AFrame: TMovieReaderFrame): Boolean;
var
  Image: CVPixelBufferRef;
begin
  Result := False;
  AFrame := Default(TMovieReaderFrame);
  if (FReader = nil) or (FOutput = nil) then
    Exit;
  ReleaseSample;
  repeat
    FSample := FOutput.copyNextSampleBuffer;
    if FSample = nil then
    begin
      if FReader.status = AVAssetReaderStatusFailed then
        FLastError := ReaderError('reading the movie failed');
      Exit;
    end;
    // With output settings in place the framework can still hand back
    // marker-only buffers; those carry no image and are skipped.
    Image := CMSampleBufferGetImageBuffer(FSample);
    if Image <> nil then
      Break;
    ReleaseSample;
  until False;
  AFrame.PixelBuffer := Image;
  AFrame.Seconds := CMTimeGetSeconds(
    CMSampleBufferGetPresentationTimeStamp(FSample));
  Result := True;
end;

procedure TMovieReader.StopPass;
begin
  ReleaseSample;
  if FReader <> nil then
  begin
    if FReader.status = AVAssetReaderStatusReading then
      FReader.cancelReading;
    FReader.release;
    FReader := nil;
  end;
  if FOutput <> nil then
  begin
    FOutput.release;
    FOutput := nil;
  end;
end;

{$ENDIF}

end.

unit Knips.Recording.LinuxPlan;

// The decisions the Linux recorder makes before and between frames, with
// no X11, no clock and no file in them, so `lwpt test` checks them on any
// host. The part that needs a display (Knips.Recording.Linux) reads the
// clock and the screen once and then asks this unit.
//
// Four questions live here:
//
//   - Which of the recorder's switches can Linux honour at all? The macOS
//     options record is shared, so every switch parses everywhere; this is
//     where Linux says no, by name, rather than ignoring one
//     (LinuxRecordingRefusal).
//   - Which pixels is the recording of (ResolveLinuxCaptureRect)?
//   - When is the next frame due, and how long was the last one shown
//     (NextFrameIndex, DelayMilliseconds)? The APNG stores a delay per
//     frame, so the delay has to be measured, not assumed to be
//     1/fps.
//   - What is the temporary file called while the take is being written
//     (LinuxTemporaryPath)?
//
// ADR-0006 is the policy behind the refusals: Linux writes APNG (GIF
// follows), never MP4 or MOV, and records no audio.

{$I Knips.inc}

interface

uses
  SysUtils,

  Knips.Export.Bitmap,
  Knips.Options;

const
  // Whether `--out=x.gif` is accepted. GIF on Linux is produced from the
  // APNG take by the reader that follows this recorder; until it exists
  // the extension is refused by name rather than writing something else.
  LinuxGifOutputAvailable = False;

  // The APNG's delay unit: a frame's fcTL delay is a count of
  // milliseconds.
  LinuxDelayDenominator = 1000;
  // fcTL's delay numerator is 16 bits. A frame held longer than this is
  // written as the longest the format can say; the recorder grabs every
  // frame interval, so reaching it needs a stall of more than a minute.
  LinuxMaxDelayMilliseconds = 65535;

  LinuxTemporaryMarker = '.knips-recording-';
  LinuxTemporarySuffix = '.tmp';

// '' when Linux can record what was asked for; otherwise the reason it
// cannot, which the caller reports with the unsupported exit code. Looks
// only at fields the validation has already made well formed.
function LinuxRecordingRefusal(const AOptions: TRecordingOptions): string;

// The pixels to record: the whole X screen, or the requested region.
// A region outside the screen is refused with the numbers rather than
// clamped, because a recording of a different rectangle than the one
// asked for is the quiet failure.
function ResolveLinuxCaptureRect(const AOptions: TRecordingOptions;
  AScreenWidth, AScreenHeight: Integer; out ARegion: TCaptureRegion;
  out AError: string): Boolean;

// Microseconds between grabs at AFramesPerSecond (rounded down).
function FrameIntervalMicros(AFramesPerSecond: Integer): Int64;

// The instant frame AIndex is due, in microseconds on the recorder's
// clock. Frame 0 is due at AStartUs.
function FrameDeadlineMicros(AStartUs, AIntervalUs, AIndex: Int64): Int64;

// The index of the next frame to grab after ALastIndex, given the clock.
// Normally ALastIndex + 1. If the clock is already past that frame's
// deadline (the encoder was slow) the frames whose deadlines have passed
// are skipped, not grabbed in a burst, and the count of skipped frames is
// returned in ADropped. A burst would play back faster than real time;
// a skip plays back at real time with fewer frames.
function NextFrameIndex(AStartUs, AIntervalUs, ALastIndex, ANowUs: Int64;
  out ADropped: Int64): Int64;

// Whole milliseconds a frame grabbed at AFromUs was on screen before the
// one grabbed at AToUs, rounded to nearest and kept between 1 and
// LinuxMaxDelayMilliseconds. A frame is never given a zero delay: players
// treat that as "as fast as possible".
function DelayMilliseconds(AFromUs, AToUs: Int64): Integer;

// Where a take is written until it is whole: beside the finished file so
// the final rename never crosses a filesystem, named so that nobody mistakes
// it for a finished take. `demo.apng` -> `demo.apng.knips-recording-1234-ab12.tmp`.
function LinuxTemporaryPath(const AOutputPath: string; APid: Integer;
  const ANonce: string): string;

// True when APath looks like a temporary this recorder leaves behind.
function IsLinuxTemporaryPath(const APath: string): Boolean;

// Achieved frames per second over the whole take; 0 for an empty one.
function AchievedFramesPerSecond(AFrames: Int64;
  ADurationSeconds: Double): Double;

implementation

function LinuxRecordingRefusal(const AOptions: TRecordingOptions): string;
var
  Kind: TRecordingOutputKind;
begin
  Result := '';
  if RecordingOutputKindForPath(AOptions.OutputPath, rpLinux, Kind) then
    case Kind of
      rokMovie:
        Exit('Linux records GIF or APNG, not MP4 or MOV; write '
          + '--out=demo.apng (see docs/adr/0006-linux-gif-apng-and-dlopen-x11.md)');
      rokGif:
        if not LinuxGifOutputAvailable then
          Exit('--out=*.gif is not available on Linux yet; write '
            + '--out=demo.apng, which is lossless');
    end;
  if AOptions.AudioMode <> amNone then
    Exit('--audio is not available on Linux: knips records no audio there '
      + '(docs/adr/0006-linux-gif-apng-and-dlopen-x11.md)');
  if AOptions.BitRate <> 0 then
    Exit('--bitrate does not apply on Linux: APNG is lossless and has no '
      + 'bit rate');
  if AOptions.Scale > 1 then
    Exit('--scale=2 is not available on Linux: X11 has no points-to-pixels '
      + 'factor, so --scale is auto or 1 and the recording is in screen pixels');
  if AOptions.TargetKind = ctkWindow then
    Exit('--window is not available on Linux yet: only a display or a '
      + '--rect of it can be recorded');
  if AOptions.BigCursor then
    Exit('--big-cursor is not available on Linux yet: the pointer is not '
      + 'drawn into Linux recordings');
  if AOptions.SmoothCursor then
    Exit('--smooth-cursor is not available on Linux yet: it needs the '
      + 'pointer track, which Linux does not record yet');
  if (AOptions.TargetKind = ctkDisplay) and (AOptions.DisplayIndex > 0) then
    Result := Format('--display=%d is not available on Linux yet: the whole '
      + 'X screen is display 0 (monitor listing needs RandR)',
      [AOptions.DisplayIndex]);
end;

function ResolveLinuxCaptureRect(const AOptions: TRecordingOptions;
  AScreenWidth, AScreenHeight: Integer; out ARegion: TCaptureRegion;
  out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  ARegion := Default(TCaptureRegion);
  if (AScreenWidth <= 0) or (AScreenHeight <= 0) then
  begin
    AError := 'the X screen reports no size';
    Exit;
  end;
  if AOptions.HasRegion then
  begin
    ARegion := AOptions.Region;
    if (ARegion.Width <= 0) or (ARegion.Height <= 0) or (ARegion.Left < 0)
      or (ARegion.Top < 0) then
    begin
      AError := '--rect must be left,top,width,height with a positive size';
      Exit;
    end;
    if (Int64(ARegion.Left) + ARegion.Width > AScreenWidth)
      or (Int64(ARegion.Top) + ARegion.Height > AScreenHeight) then
    begin
      AError := Format('--rect=%d,%d,%d,%d does not fit the %dx%d screen',
        [ARegion.Left, ARegion.Top, ARegion.Width, ARegion.Height,
        AScreenWidth, AScreenHeight]);
      Exit;
    end;
  end
  else
  begin
    ARegion.Left := 0;
    ARegion.Top := 0;
    ARegion.Width := AScreenWidth;
    ARegion.Height := AScreenHeight;
  end;
  AError := BgraCanvasRefusal(ARegion.Width, ARegion.Height);
  Result := AError = '';
end;

function FrameIntervalMicros(AFramesPerSecond: Integer): Int64;
begin
  if AFramesPerSecond < 1 then
    AFramesPerSecond := 1;
  Result := 1000000 div AFramesPerSecond;
end;

function FrameDeadlineMicros(AStartUs, AIntervalUs, AIndex: Int64): Int64;
begin
  Result := AStartUs + AIndex * AIntervalUs;
end;

function NextFrameIndex(AStartUs, AIntervalUs, ALastIndex, ANowUs: Int64;
  out ADropped: Int64): Int64;
var
  Due: Int64;
begin
  ADropped := 0;
  Result := ALastIndex + 1;
  if (AIntervalUs <= 0) or (ANowUs <= AStartUs) then
    Exit;
  // The latest frame whose deadline has already passed. Anything between
  // the plain next frame and that one is late and is skipped.
  Due := (ANowUs - AStartUs) div AIntervalUs;
  if Due > Result then
  begin
    ADropped := Due - Result;
    Result := Due;
  end;
end;

function DelayMilliseconds(AFromUs, AToUs: Int64): Integer;
var
  Milliseconds: Int64;
begin
  Milliseconds := (AToUs - AFromUs + 500) div 1000;
  if Milliseconds < 1 then
    Milliseconds := 1;
  if Milliseconds > LinuxMaxDelayMilliseconds then
    Milliseconds := LinuxMaxDelayMilliseconds;
  Result := Integer(Milliseconds);
end;

function LinuxTemporaryPath(const AOutputPath: string; APid: Integer;
  const ANonce: string): string;
begin
  Result := AOutputPath + LinuxTemporaryMarker + IntToStr(APid) + '-'
    + ANonce + LinuxTemporarySuffix;
end;

function IsLinuxTemporaryPath(const APath: string): Boolean;
begin
  Result := (Pos(LinuxTemporaryMarker, APath) > 0)
    and (Copy(APath, Length(APath) - Length(LinuxTemporarySuffix) + 1,
    Length(LinuxTemporarySuffix)) = LinuxTemporarySuffix);
end;

function AchievedFramesPerSecond(AFrames: Int64;
  ADurationSeconds: Double): Double;
begin
  if (AFrames <= 0) or (ADurationSeconds <= 0) then
    Exit(0);
  Result := AFrames / ADurationSeconds;
end;

end.

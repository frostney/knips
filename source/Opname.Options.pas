unit Opname.Options;

// Recording and export options as the CLI hands them to the recorder
// and the exporter: what to capture, at what rate, into which
// container; and which movie to turn into which GIF. Everything here is
// platform-neutral and unit-tested; the macOS layer only consumes the
// validated records.

{$I Shared.inc}

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
  MaxScale = 2;
  // Bumped once per release that changes the CLI surface.
  OpnameVersion = '0.1.0';

  // GIF delays are whole centiseconds, so anything above 50 fps cannot
  // be represented and 20 is what Kap-sized clips actually want.
  DefaultGifFramesPerSecond = 20;
  MinGifFramesPerSecond = 1;
  MaxGifFramesPerSecond = 50;
  // 0 = keep the movie's own width.
  GifWidthFromSource = 0;
  MinGifWidth = 16;
  MaxGifWidth = 4096;

type
  TCaptureRegion = record
    Left: Integer;
    Top: Integer;
    Width: Integer;
    Height: Integer;
  end;

  TCaptureTargetKind = (ctkDisplay, ctkWindow);

  TOutputContainer = (ocMPEG4, ocQuickTime);

  TRecordingOptions = record
    TargetKind: TCaptureTargetKind;
    // Index into the enumerated displays; -1 = the main display.
    DisplayIndex: Integer;
    // CGWindowID of the window to record when TargetKind = ctkWindow.
    WindowID: Cardinal;
    HasRegion: Boolean;
    // Region in display points, relative to the display's origin.
    Region: TCaptureRegion;
    FramesPerSecond: Integer;
    // Pixels per point: 1, 2, or ScaleAuto.
    Scale: Integer;
    ShowsCursor: Boolean;
    // 0 = derive from the capture size and frame rate.
    BitRate: Integer;
    OutputPath: string;
    Container: TOutputContainer;
  end;

  // GIF is the only export in this milestone; APNG and WebM join the
  // enumeration rather than the record when they arrive.
  TExportFormat = (efGif);

  TExportOptions = record
    InputPath: string;
    OutputPath: string;
    Format: TExportFormat;
    // The container the input is read from, filled by validation.
    InputContainer: TOutputContainer;
    FramesPerSecond: Integer;
    // Target width in pixels; GifWidthFromSource keeps the movie's own.
    Width: Integer;
    TrimStartSeconds: Double;
    // False runs to the end of the movie. A separate flag rather than a
    // sentinel value, so an explicit --trim=3,0 is an empty range and
    // gets rejected instead of quietly meaning "to the end".
    HasTrimEnd: Boolean;
    TrimEndSeconds: Double;
    Dither: Boolean;
  end;

function DefaultRecordingOptions: TRecordingOptions;

// "left,top,width,height" in points. Rejects anything else.
function ParseCaptureRegion(const AText: string;
  out ARegion: TCaptureRegion): Boolean;

// Container from the output path's extension; False for unknown ones.
function ContainerForPath(const APath: string;
  out AContainer: TOutputContainer): Boolean;

// Checks ranges and cross-field rules; fills derived fields (Container).
// Returns False with a one-line human message when the options can't
// start a recording.
function ValidateRecordingOptions(var AOptions: TRecordingOptions;
  out AError: string): Boolean;

// Rounds a capture dimension down to the encoder's alignment.
function AlignDimension(AValue: Integer): Integer; inline;

// The average bit rate to request when the user gave none.
function SuggestedBitRate(APixelWidth, APixelHeight,
  AFramesPerSecond: Integer): Integer;

function ContainerFileType(AContainer: TOutputContainer): string;

function DefaultExportOptions: TExportOptions;

// Export format from the output path's extension; False for unknown ones.
function ExportFormatForPath(const APath: string;
  out AFormat: TExportFormat): Boolean;

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

implementation

function DefaultRecordingOptions: TRecordingOptions;
begin
  Result := Default(TRecordingOptions);
  Result.TargetKind := ctkDisplay;
  Result.DisplayIndex := -1;
  Result.FramesPerSecond := DefaultFramesPerSecond;
  Result.Scale := ScaleAuto;
  Result.ShowsCursor := True;
  Result.Container := ocMPEG4;
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
  if Extension = '.mp4' then
    AContainer := ocMPEG4
  else if Extension = '.mov' then
    AContainer := ocQuickTime
  else
  begin
    AContainer := ocMPEG4;
    Result := False;
  end;
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
  Budget := APixelWidth * APixelHeight * AFramesPerSecond
    * AutoBitsPerPixelPerFrame;
  if Budget < MinBitRate then
    Budget := MinBitRate
  else if Budget > MaxBitRate then
    Budget := MaxBitRate;
  Result := Round(Budget);
end;

function ContainerFileType(AContainer: TOutputContainer): string;
begin
  case AContainer of
    ocQuickTime: Result := 'QuickTime movie';
  else
    Result := 'MPEG-4';
  end;
end;

function ValidateRecordingOptions(var AOptions: TRecordingOptions;
  out AError: string): Boolean;
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
  if (AOptions.FramesPerSecond < MinFramesPerSecond)
    or (AOptions.FramesPerSecond > MaxFramesPerSecond) then
  begin
    AError := Format('--fps must be between %d and %d',
      [MinFramesPerSecond, MaxFramesPerSecond]);
    Exit;
  end;
  if (AOptions.Scale < ScaleAuto) or (AOptions.Scale > MaxScale) then
  begin
    AError := Format('--scale must be 1, 2, or %d for auto', [ScaleAuto]);
    Exit;
  end;
  if AOptions.BitRate < 0 then
  begin
    AError := '--bitrate must be a positive number of bits per second';
    Exit;
  end;
  if (AOptions.TargetKind = ctkWindow) and AOptions.HasRegion then
  begin
    AError := '--window and --rect are mutually exclusive';
    Exit;
  end;
  if (AOptions.TargetKind = ctkWindow) and (AOptions.WindowID = 0) then
  begin
    AError := '--window needs a non-zero window id (see `opname windows`)';
    Exit;
  end;
  if AOptions.HasRegion and ((AlignDimension(AOptions.Region.Width) = 0)
    or (AlignDimension(AOptions.Region.Height) = 0)) then
  begin
    AError := Format('--rect must be at least %dx%d points',
      [DimensionAlignment, DimensionAlignment]);
    Exit;
  end;
  Result := True;
end;

function DefaultExportOptions: TExportOptions;
begin
  Result := Default(TExportOptions);
  Result.Format := efGif;
  Result.InputContainer := ocMPEG4;
  Result.FramesPerSecond := DefaultGifFramesPerSecond;
  Result.Width := GifWidthFromSource;
  Result.TrimStartSeconds := 0;
  Result.HasTrimEnd := False;
  Result.TrimEndSeconds := 0;
  Result.Dither := True;
end;

function ExportFormatForPath(const APath: string;
  out AFormat: TExportFormat): Boolean;
begin
  AFormat := efGif;
  Result := LowerCase(ExtractFileExt(APath)) = '.gif';
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
      + ExtractFileExt(AOptions.OutputPath) + '" (use .gif)';
    Exit;
  end;
  if SameText(ExpandFileName(AOptions.InputPath),
    ExpandFileName(AOptions.OutputPath)) then
  begin
    AError := '--in and --out are the same file';
    Exit;
  end;
  if (AOptions.FramesPerSecond < MinGifFramesPerSecond)
    or (AOptions.FramesPerSecond > MaxGifFramesPerSecond) then
  begin
    AError := Format('--fps must be between %d and %d for a GIF',
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
  if AOptions.TrimStartSeconds < 0 then
  begin
    AError := '--trim cannot start before zero';
    Exit;
  end;
  if AOptions.HasTrimEnd
    and (AOptions.TrimEndSeconds <= AOptions.TrimStartSeconds) then
  begin
    AError := '--trim must end after it starts';
    Exit;
  end;
  Result := True;
end;

end.

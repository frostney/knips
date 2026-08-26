unit Knips.Export.Timing;

// Presentation stamps in, whole-tick frame delays out. GIF counts a
// frame's delay in centiseconds and APNG in whatever denominator the
// file declares, so both containers face the same problem: the interval
// a frame rate asks for is almost never a whole tick.
//
// Two things have to hold at once, and the obvious implementations only
// manage one each:
//
//   * The delays must not drift. Rounding each gap on its own loses ten
//     percent of the running time at 30 fps, because 3.33 cs becomes 3.
//   * The delays must not alternate. Rounding each frame's *stamp*
//     against the centisecond grid keeps the total honest but turns a
//     30 fps source decimated to 20 fps into 7, 3, 7, 3 — the source's
//     frames land on 1/30 s boundaries, and the two nearest ones to each
//     1/20 s slot are 3.3 cs apart. That is visible judder.
//
// So a stamp is first snapped to the decimation grid the exporter is
// already counting in — the nearest whole 1/fps slot — and the delay is
// the difference between that slot's ideal tick count and the ticks
// already spent. Snapping removes the alternation (every slot is one
// interval wide), taking the ideal from the slot rather than from a
// running sum removes the drift, and measuring against ticks already
// spent means a clamped delay is repaid by the frames after it rather
// than lost.
//
// A gap longer than one slot keeps its length: an idle stretch of two
// seconds is forty slots at 20 fps, so it stays two seconds. That is
// what keeps a screen recording's own timing instead of stretching it
// to a fixed cadence. The one exception is a gap longer than a two-byte
// delay field can express, which is emitted at the ceiling with the
// remainder forgiven rather than owed — see NextDelay.
//
// Platform-neutral and unit-tested, like everything else that decides
// what the exported file looks like.

{$I Knips.inc}

interface

uses
  Math,
  SysUtils;

const
  // GIF's graphic control block counts delays in centiseconds.
  GifDelayTicksPerSecond = 100;
  // APNG carries its own denominator; milliseconds cost nothing and let
  // 20 fps come out exact.
  ApngDelayTicksPerSecond = 1000;
  // Browsers silently turn GIF delays of 0 and 1 into 10.
  GifMinimumDelayTicks = 2;
  // fcTL's delay_num is two bytes, and so is GIF's delay field. In
  // centiseconds that ceiling is 655 s of idle, which no screen
  // recording reaches; in APNG's milliseconds it is 65.5 s, which one
  // left running over lunch does.
  MaximumDelayTicks = 65535;
  ApngMinimumDelayTicks = 1;

type
  TFrameDelayPlanner = class
  private
    FFramesPerSecond: Integer;
    FTicksPerSecond: Integer;
    FMinimumTicks: Integer;
    FLastSlot: Int64;
    FSpentTicks: Int64;
    FForgivenTicks: Int64;
    function Clamp(ATicks: Int64): Integer;
  public
    constructor Create(AFramesPerSecond, ATicksPerSecond,
      AMinimumTicks: Integer);
    procedure Reset;
    // The delay to write for the frame still pending, given how far past
    // the first emitted frame the *next* one sits. Callers hold one
    // frame back for exactly this reason.
    function NextDelay(ASecondsSinceFirst: Double): Integer;
    // The delay for the last frame, which has no successor to measure
    // against: one interval of the requested rate.
    function TrailingDelay: Integer;
    // Every delay handed out so far, which is the file's playback length.
    property SpentTicks: Int64 read FSpentTicks;
    // Ticks of idle that no delay field could express and that were
    // dropped rather than owed. Non-zero only past MaximumDelayTicks.
    property ForgivenTicks: Int64 read FForgivenTicks;
    property TicksPerSecond: Integer read FTicksPerSecond;
  end;

// The whole-tick interval a rate asks for, rounded to nearest.
function FrameIntervalTicks(AFramesPerSecond,
  ATicksPerSecond: Integer): Integer;

// Ticks the ASlot'th grid slot sits at, rounded to nearest. Exposed
// because it is the property the duration tests are written against.
function SlotTicks(ASlot: Int64; AFramesPerSecond,
  ATicksPerSecond: Integer): Int64;

implementation

function FrameIntervalTicks(AFramesPerSecond,
  ATicksPerSecond: Integer): Integer;
begin
  if AFramesPerSecond < 1 then
    AFramesPerSecond := 1;
  Result := Integer(SlotTicks(1, AFramesPerSecond, ATicksPerSecond));
end;

function SlotTicks(ASlot: Int64; AFramesPerSecond,
  ATicksPerSecond: Integer): Int64;
begin
  if AFramesPerSecond < 1 then
    AFramesPerSecond := 1;
  // Round(ASlot * ATicksPerSecond / AFramesPerSecond) in integers, so
  // the same slot always yields the same tick count on every host.
  Result := (ASlot * (Int64(ATicksPerSecond) * 2) + AFramesPerSecond)
    div (Int64(AFramesPerSecond) * 2);
end;

{ TFrameDelayPlanner }

constructor TFrameDelayPlanner.Create(AFramesPerSecond, ATicksPerSecond,
  AMinimumTicks: Integer);
begin
  inherited Create;
  FFramesPerSecond := Max(1, AFramesPerSecond);
  FTicksPerSecond := Max(1, ATicksPerSecond);
  FMinimumTicks := Max(0, AMinimumTicks);
  Reset;
end;

procedure TFrameDelayPlanner.Reset;
begin
  FLastSlot := 0;
  FSpentTicks := 0;
  FForgivenTicks := 0;
end;

function TFrameDelayPlanner.Clamp(ATicks: Int64): Integer;
begin
  if ATicks < FMinimumTicks then
    ATicks := FMinimumTicks;
  if ATicks > MaximumDelayTicks then
    ATicks := MaximumDelayTicks;
  Result := Integer(ATicks);
end;

// The two clamps are not symmetric, and that asymmetry is the whole
// design:
//
//   * A delay pushed *up* to the minimum is **owed**. The frames after
//     it come out a tick shorter until the debt is paid, so a burst of
//     frames closer together than the floor allows still ends where it
//     should. Nothing is lost, only redistributed.
//   * A delay pushed *down* to the ceiling is **forgiven**. An idle gap
//     longer than a two-byte delay field can express is emitted as one
//     maximum-length delay and the remainder is struck off the debt
//     rather than carried. Owing it instead would smear the excess over
//     the frames that come *after* the gap: a 300 s pause at APNG's
//     millisecond scale left the next four motion frames each held for
//     65 535 ticks, turning the moment the recording came back to life
//     into a slideshow. Forgiving it costs nothing but the idle time
//     past the ceiling — the pause plays for 65.5 s instead of 300 s —
//     and every frame after it gets its true delay.
//
// In centiseconds the ceiling is 655 s, so a GIF only meets this after
// eleven minutes of a perfectly still screen; in practice it is an APNG
// concern.
function TFrameDelayPlanner.NextDelay(ASecondsSinceFirst: Double): Integer;
var
  Slot, Wanted: Int64;
begin
  Slot := Round(ASecondsSinceFirst * FFramesPerSecond);
  // Two frames can round onto the same slot when the decimator's own
  // floor put them on consecutive ones; a delay of zero would be clamped
  // away, so the grid advances instead and the next frame's snap pulls
  // the total back.
  if Slot <= FLastSlot then
    Slot := FLastSlot + 1;
  FLastSlot := Slot;
  Wanted := SlotTicks(Slot, FFramesPerSecond, FTicksPerSecond)
    - (FSpentTicks + FForgivenTicks);
  if Wanted > MaximumDelayTicks then
  begin
    Inc(FForgivenTicks, Wanted - MaximumDelayTicks);
    Wanted := MaximumDelayTicks;
  end;
  Result := Clamp(Wanted);
  Inc(FSpentTicks, Result);
end;

function TFrameDelayPlanner.TrailingDelay: Integer;
begin
  Result := Clamp(FrameIntervalTicks(FFramesPerSecond, FTicksPerSecond));
  Inc(FSpentTicks, Result);
end;

end.

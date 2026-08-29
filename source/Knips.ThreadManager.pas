unit Knips.ThreadManager;

// Minimal pthread-backed RTL thread manager for the no-cthreads build.
//
// knips cannot use cthreads: its adoption of the RTL signal handlers
// intercepts a benign SIGSEGV raised inside CoreMedia's XPC
// deserialisation of SCK sample buffers (docs/architecture.md, the
// vendored Knips.Capture.PThreadMutex header). But without any thread
// manager, FPC's NoThreadManager stubs hard-error (RTE 232) for critical
// sections and events as soon as IsMultiThread is True — and knips sets
// IsMultiThread at startup so managed-type refcounts use locked
// instructions. Off-device type checking could not catch this; the first
// on-device run did.
//
// This unit installs real pthread implementations of the lock and event
// primitives only. Thread creation, suspension, and threadvar handling
// keep the NoThreadManager stubs: the RTL still never creates or adopts
// threads, and ScreenCaptureKit's GCD capture queue stays foreign, which
// is the ADR-0003 invariant this unit preserves.
//
// It must appear in the program uses clause immediately after cmem —
// before Classes and SysUtils — so every RTL critical section in unit
// initialization is created through it.

{$I Knips.inc}

interface

// **This unit has no public surface, and that is the point.** It installs
// itself from its own initialization section, which is why `knips.pas`
// lists it second in the uses clause — right after cmem — and why
// nothing ever calls into it. See the note above that clause, and
// docs/architecture.md.

implementation

{$IFDEF DARWIN}

uses
  ctypes;

const
  // Generous opaque sizes: pthread_mutex_t is 64 bytes on darwin/arm64,
  // pthread_cond_t 48, pthread_mutexattr_t 16 (the same headroom rule as
  // the vendored Knips.Capture.PThreadMutex).
  MutexOpaqueSize = 128;
  CondOpaqueSize = 64;
  AttrOpaqueSize = 32;
  DarwinMutexRecursive = 2; // PTHREAD_MUTEX_RECURSIVE (pthread/pthread.h)
  InfiniteTimeout = Cardinal($FFFFFFFF);

  // Every one of Apple's opaque pthread types leads with a `long __sig`
  // (sys/_pthread/*.h), so all three are 8-byte aligned, and libsystem
  // reaches that word with `casa` — an atomic that faults with SIGBUS on
  // an unaligned address. Byte storage claims alignment 1 and so lets
  // the compiler put the type anywhere; the release build (-O4) turns on
  // ORDERFIELDS, which reorders *class* fields by alignment and did
  // exactly that to Knips.Capture.PThreadMutex, killing `knips probe`
  // (docs/porting-notes.md, "pthread opaque storage is 8-byte aligned").
  // Nothing here is a class field today — these are a stack local and a
  // GetMem'd record, neither of which FPC reorders — but the declaration
  // was wrong in the same way, and a correct one costs nothing.
  MutexOpaqueQWords = MutexOpaqueSize div 8;
  CondOpaqueQWords = CondOpaqueSize div 8;
  AttrOpaqueQWords = AttrOpaqueSize div 8;

{$IF ((MutexOpaqueSize mod 8) <> 0) or ((CondOpaqueSize mod 8) <> 0)
  or ((AttrOpaqueSize mod 8) <> 0)}
  {$ERROR opaque sizes must be multiples of 8: div 8 above would silently shrink the storage}
{$ENDIF}

type
  TRawAttr = array[0..AttrOpaqueQWords - 1] of QWord;

  TDarwinTimespec = record
    tv_sec: clong;
    tv_nsec: clong;
  end;

  TDarwinTimeval = record
    tv_sec: clong;
    tv_usec: cint32;
  end;

  // One state record backs both RTL events and basic events.
  PEventRec = ^TEventRec;
  TEventRec = record
    Mutex: array[0..MutexOpaqueQWords - 1] of QWord;
    Cond: array[0..CondOpaqueQWords - 1] of QWord;
    IsSet: Boolean;
    ManualReset: Boolean;
  end;

function Pthread_mutexattr_init(AAttr: Pointer): cint; cdecl;
  external 'c' name 'pthread_mutexattr_init';
function Pthread_mutexattr_settype(AAttr: Pointer; AKind: cint): cint; cdecl;
  external 'c' name 'pthread_mutexattr_settype';
function Pthread_mutexattr_destroy(AAttr: Pointer): cint; cdecl;
  external 'c' name 'pthread_mutexattr_destroy';
function Pthread_mutex_init(AMutex: Pointer; AAttr: Pointer): cint; cdecl;
  external 'c' name 'pthread_mutex_init';
function Pthread_mutex_destroy(AMutex: Pointer): cint; cdecl;
  external 'c' name 'pthread_mutex_destroy';
function Pthread_mutex_lock(AMutex: Pointer): cint; cdecl;
  external 'c' name 'pthread_mutex_lock';
function Pthread_mutex_trylock(AMutex: Pointer): cint; cdecl;
  external 'c' name 'pthread_mutex_trylock';
function Pthread_mutex_unlock(AMutex: Pointer): cint; cdecl;
  external 'c' name 'pthread_mutex_unlock';
function Pthread_cond_init(ACond: Pointer; AAttr: Pointer): cint; cdecl;
  external 'c' name 'pthread_cond_init';
function Pthread_cond_destroy(ACond: Pointer): cint; cdecl;
  external 'c' name 'pthread_cond_destroy';
function Pthread_cond_signal(ACond: Pointer): cint; cdecl;
  external 'c' name 'pthread_cond_signal';
function Pthread_cond_broadcast(ACond: Pointer): cint; cdecl;
  external 'c' name 'pthread_cond_broadcast';
function Pthread_cond_wait(ACond: Pointer; AMutex: Pointer): cint; cdecl;
  external 'c' name 'pthread_cond_wait';
function Pthread_cond_timedwait(ACond: Pointer; AMutex: Pointer;
  AAbsTime: Pointer): cint; cdecl;
  external 'c' name 'pthread_cond_timedwait';
function Pthread_self: Pointer; cdecl;
  external 'c' name 'pthread_self';
function Darwin_gettimeofday(ATime: Pointer; ATimezone: Pointer): cint; cdecl;
  external 'c' name 'gettimeofday';

// --- critical sections -------------------------------------------------
//
// The handler receives the caller's TRTLCriticalSection as an untyped
// var. Its layout differs per thread manager, so only its first
// pointer-sized slot is used: it holds a heap-allocated recursive
// pthread mutex. A nil slot in Done/Enter/Leave is tolerated — it means
// the section was created before this manager installed (there are none
// in a correctly ordered uses clause) or already destroyed.

procedure TMInitCriticalSection(var ACS);
var
  Mutex: Pointer;
  Attr: TRawAttr;
begin
  GetMem(Mutex, MutexOpaqueSize);
  FillChar(Mutex^, MutexOpaqueSize, 0);
  FillChar(Attr, SizeOf(Attr), 0);
  Pthread_mutexattr_init(@Attr);
  Pthread_mutexattr_settype(@Attr, DarwinMutexRecursive);
  Pthread_mutex_init(Mutex, @Attr);
  Pthread_mutexattr_destroy(@Attr);
  PPointer(@ACS)^ := Mutex;
end;

procedure TMDoneCriticalSection(var ACS);
var
  Mutex: Pointer;
begin
  Mutex := PPointer(@ACS)^;
  if Mutex = nil then
    Exit;
  PPointer(@ACS)^ := nil;
  Pthread_mutex_destroy(Mutex);
  FreeMem(Mutex);
end;

procedure TMEnterCriticalSection(var ACS);
var
  Mutex: Pointer;
begin
  Mutex := PPointer(@ACS)^;
  if Mutex <> nil then
    Pthread_mutex_lock(Mutex);
end;

function TMTryEnterCriticalSection(var ACS): LongInt;
var
  Mutex: Pointer;
begin
  Mutex := PPointer(@ACS)^;
  if (Mutex <> nil) and (Pthread_mutex_trylock(Mutex) = 0) then
    Result := 1
  else
    Result := 0;
end;

procedure TMLeaveCriticalSection(var ACS);
var
  Mutex: Pointer;
begin
  Mutex := PPointer(@ACS)^;
  if Mutex <> nil then
    Pthread_mutex_unlock(Mutex);
end;

// --- events ------------------------------------------------------------

function NewEventRec(AManualReset, AInitialState: Boolean): PEventRec;
begin
  GetMem(Result, SizeOf(TEventRec));
  FillChar(Result^, SizeOf(TEventRec), 0);
  Pthread_mutex_init(@Result^.Mutex, nil);
  Pthread_cond_init(@Result^.Cond, nil);
  Result^.IsSet := AInitialState;
  Result^.ManualReset := AManualReset;
end;

procedure FreeEventRec(AEvent: PEventRec);
begin
  if AEvent = nil then
    Exit;
  Pthread_cond_destroy(@AEvent^.Cond);
  Pthread_mutex_destroy(@AEvent^.Mutex);
  FreeMem(AEvent);
end;

procedure EventSet(AEvent: PEventRec);
begin
  Pthread_mutex_lock(@AEvent^.Mutex);
  AEvent^.IsSet := True;
  Pthread_cond_broadcast(@AEvent^.Cond);
  Pthread_mutex_unlock(@AEvent^.Mutex);
end;

procedure EventReset(AEvent: PEventRec);
begin
  Pthread_mutex_lock(@AEvent^.Mutex);
  AEvent^.IsSet := False;
  Pthread_mutex_unlock(@AEvent^.Mutex);
end;

function DeadlineFromNow(ATimeoutMs: Cardinal): TDarwinTimespec;
var
  Now: TDarwinTimeval;
begin
  Now.tv_sec := 0;
  Now.tv_usec := 0;
  Darwin_gettimeofday(@Now, nil);
  Result.tv_sec := Now.tv_sec + clong(ATimeoutMs div 1000);
  Result.tv_nsec := clong(Now.tv_usec) * 1000 +
    clong(ATimeoutMs mod 1000) * 1000000;
  if Result.tv_nsec >= 1000000000 then
  begin
    Inc(Result.tv_sec);
    Dec(Result.tv_nsec, 1000000000);
  end;
end;

// Waits until the event is set; auto-reset consumes it. Returns True if
// signalled, False on timeout. InfiniteTimeout blocks forever.
function EventWait(AEvent: PEventRec; ATimeoutMs: Cardinal;
  AAutoReset: Boolean): Boolean;
var
  Deadline: TDarwinTimespec;
  TimedOut: Boolean;
begin
  TimedOut := False;
  Pthread_mutex_lock(@AEvent^.Mutex);
  if ATimeoutMs = InfiniteTimeout then
  begin
    while not AEvent^.IsSet do
      Pthread_cond_wait(@AEvent^.Cond, @AEvent^.Mutex);
  end
  else
  begin
    Deadline := DeadlineFromNow(ATimeoutMs);
    while (not AEvent^.IsSet) and (not TimedOut) do
      if Pthread_cond_timedwait(@AEvent^.Cond, @AEvent^.Mutex,
        @Deadline) <> 0 then
        TimedOut := True;
  end;
  Result := AEvent^.IsSet;
  if Result and AAutoReset then
    AEvent^.IsSet := False;
  Pthread_mutex_unlock(@AEvent^.Mutex);
end;

function TMRTLEventCreate: PRTLEvent;
begin
  Result := PRTLEvent(NewEventRec(False, False));
end;

procedure TMRTLEventDestroy(AEvent: PRTLEvent);
begin
  FreeEventRec(PEventRec(AEvent));
end;

procedure TMRTLEventSetEvent(AEvent: PRTLEvent);
begin
  EventSet(PEventRec(AEvent));
end;

procedure TMRTLEventResetEvent(AEvent: PRTLEvent);
begin
  EventReset(PEventRec(AEvent));
end;

procedure TMRTLEventWaitFor(AEvent: PRTLEvent);
begin
  EventWait(PEventRec(AEvent), InfiniteTimeout, True);
end;

procedure TMRTLEventWaitForTimeout(AEvent: PRTLEvent; ATimeout: LongInt);
begin
  // A negative timeout must not wrap into InfiniteTimeout via the
  // Cardinal cast; treat it as "check once, then give up", as cthreads
  // does.
  if ATimeout < 0 then
    ATimeout := 0;
  EventWait(PEventRec(AEvent), Cardinal(ATimeout), True);
end;

function TMBasicEventCreate(AEventAttributes: Pointer;
  AManualReset, AInitialState: Boolean;
  const AName: AnsiString): PEventState;
begin
  Result := PEventState(NewEventRec(AManualReset, AInitialState));
end;

procedure TMBasicEventDestroy(AState: PEventState);
begin
  FreeEventRec(PEventRec(AState));
end;

procedure TMBasicEventResetEvent(AState: PEventState);
begin
  EventReset(PEventRec(AState));
end;

procedure TMBasicEventSetEvent(AState: PEventState);
begin
  EventSet(PEventRec(AState));
end;

// 0 = signalled, 1 = timed out — the wrSignaled/wrTimeout mapping used
// by TEventObject.WaitFor.
function TMBasicEventWaitFor(ATimeout: Cardinal;
  AState: PEventState): LongInt;
begin
  if EventWait(PEventRec(AState), ATimeout,
    not PEventRec(AState)^.ManualReset) then
    Result := 0
  else
    Result := 1;
end;

function TMGetCurrentThreadId: TThreadID;
begin
  Result := TThreadID(Pthread_self);
end;

// Not exported: the initialization below is the only caller, and a
// second install from anywhere else would replace a manager the RTL is
// already using.
procedure InstallKnipsThreadManager;
var
  Manager: TThreadManager;
begin
  GetThreadManager(Manager);
  Manager.InitCriticalSection := TMInitCriticalSection;
  Manager.DoneCriticalSection := TMDoneCriticalSection;
  Manager.EnterCriticalSection := TMEnterCriticalSection;
  Manager.TryEnterCriticalSection := TMTryEnterCriticalSection;
  Manager.LeaveCriticalSection := TMLeaveCriticalSection;
  Manager.RTLEventCreate := TMRTLEventCreate;
  Manager.RTLEventDestroy := TMRTLEventDestroy;
  Manager.RTLEventSetEvent := TMRTLEventSetEvent;
  Manager.RTLEventResetEvent := TMRTLEventResetEvent;
  Manager.RTLEventWaitFor := TMRTLEventWaitFor;
  Manager.RTLEventWaitForTimeout := TMRTLEventWaitForTimeout;
  Manager.BasicEventCreate := TMBasicEventCreate;
  Manager.BasicEventDestroy := TMBasicEventDestroy;
  Manager.BasicEventResetEvent := TMBasicEventResetEvent;
  Manager.BasicEventSetEvent := TMBasicEventSetEvent;
  Manager.BasicEventWaitFor := TMBasicEventWaitFor;
  Manager.GetCurrentThreadId := TMGetCurrentThreadId;
  SetThreadManager(Manager);
end;

initialization
  InstallKnipsThreadManager;

{$ENDIF}

end.

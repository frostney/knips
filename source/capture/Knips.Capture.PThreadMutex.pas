unit Knips.Capture.PThreadMutex;

{ Direct pthread_mutex wrapper for macOS.

  We cannot use cthreads because its signal handler intercepts SIGSEGV
  from CoreMedia's XPC deserialization (ScreenCaptureKit sends CMSampleBuffers
  via XPC, and CoreMedia uses signals internally during deserialization).
  FPC's signal handler converts this to EAccessViolation and kills the process.

  Without cthreads, FPC's TRTLCriticalSection is a no-op on Unix.
  This unit provides real pthread_mutex locking via direct C calls. }

{$mode objfpc}{$H+}

interface

{$IFDEF DARWIN}
uses
  ctypes;

const
  { sizeof(pthread_mutex_t) on macOS ARM64 = 64 bytes,
    but we use 128 to be safe across platforms/versions }
  PTHREAD_MUTEX_OPAQUE_SIZE = 128;

  { The storage is declared in QWords rather than Bytes because
    pthread_mutex_t is 8-byte aligned: Apple's _opaque_pthread_mutex_t
    (sys/_pthread/_pthread_types.h) leads with `long __sig`, and
    libsystem_pthread reaches that word with `casa`, an atomic that
    faults with SIGBUS on an unaligned address. A record whose fields are
    Bytes has alignment 1, so a class holding one may put it at any
    offset — and `lwpt build --mode release` (-O4) enables ORDERFIELDS,
    which reorders class fields by alignment and therefore parks an
    alignment-1 field wherever the padding is. That is what killed
    `knips probe` in pthread_mutex_destroy, at a TCameraBlur.FLock offset
    of 231. QWord storage gives the record alignment 8 in every mode, so
    no placement can produce an address libsystem cannot use. See
    docs/porting-notes.md, "pthread opaque storage is 8-byte aligned". }
  { knips change: QWord storage (was Byte); see the comment above }
  PTHREAD_MUTEX_OPAQUE_QWORDS = PTHREAD_MUTEX_OPAQUE_SIZE div 8;

{$IF (PTHREAD_MUTEX_OPAQUE_SIZE mod 8) <> 0}
  {$ERROR PTHREAD_MUTEX_OPAQUE_SIZE must be a multiple of 8: div 8 below would silently shrink the storage}
{$ENDIF}

type
  TPThreadMutex = record
    { knips change: QWord storage (was Byte); see the comment above }
    _opaque: array[0..PTHREAD_MUTEX_OPAQUE_QWORDS - 1] of QWord;
  end;
  PPThreadMutex = ^TPThreadMutex;

procedure PThreadMutexInit(out Mutex: TPThreadMutex);
procedure PThreadMutexDestroy(var Mutex: TPThreadMutex);
procedure PThreadMutexLock(var Mutex: TPThreadMutex);
procedure PThreadMutexUnlock(var Mutex: TPThreadMutex);

{$ENDIF}

implementation

{$IFDEF DARWIN}

function _pthread_mutex_init(mutex: Pointer; attr: Pointer): cint; cdecl; external 'c' name 'pthread_mutex_init';
function _pthread_mutex_destroy(mutex: Pointer): cint; cdecl; external 'c' name 'pthread_mutex_destroy';
function _pthread_mutex_lock(mutex: Pointer): cint; cdecl; external 'c' name 'pthread_mutex_lock';
function _pthread_mutex_unlock(mutex: Pointer): cint; cdecl; external 'c' name 'pthread_mutex_unlock';

procedure PThreadMutexInit(out Mutex: TPThreadMutex);
begin
  FillChar(Mutex, SizeOf(Mutex), 0);
  _pthread_mutex_init(@Mutex, nil);  { nil attr = default (non-recursive) mutex }
end;

procedure PThreadMutexDestroy(var Mutex: TPThreadMutex);
begin
  _pthread_mutex_destroy(@Mutex);
end;

procedure PThreadMutexLock(var Mutex: TPThreadMutex);
begin
  _pthread_mutex_lock(@Mutex);
end;

procedure PThreadMutexUnlock(var Mutex: TPThreadMutex);
begin
  _pthread_mutex_unlock(@Mutex);
end;

{$ENDIF}

end.

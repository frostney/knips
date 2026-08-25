unit Opname.Capture.PThreadMutex;

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

type
  TPThreadMutex = record
    _opaque: array[0..PTHREAD_MUTEX_OPAQUE_SIZE - 1] of Byte;
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

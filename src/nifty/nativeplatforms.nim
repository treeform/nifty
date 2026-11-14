## Native synchronization and thread startup for Windows and POSIX hosts.
when defined(windows):
  import std/locks

  type
    NativeMutex* = Lock
    NativeCondition* = Cond
    ThreadHandle* = object
      value: pointer
    NativeThreadStart* = proc(argument: pointer): uint32 {.stdcall.}
    BrokenPipeHandler* = pointer

  proc beginThread(security: pointer, stackBytes: cuint,
      start: NativeThreadStart, argument: pointer, flags: cuint,
      identifier: ptr cuint): uint
      {.cdecl, importc: "_beginthreadex", header: "<process.h>".}
  proc waitForThread(handle: pointer, milliseconds: uint32): uint32
      {.stdcall, importc: "WaitForSingleObject", header: "<windows.h>".}
  proc closeThread(handle: pointer): int32
      {.stdcall, importc: "CloseHandle", header: "<windows.h>".}

  proc initMutex*(mutex: ptr NativeMutex): cint =
    ## Initializes a native critical section before threads start.
    initLock(mutex[])
    0

  proc destroyMutex*(mutex: ptr NativeMutex): cint =
    ## Releases a native critical section after all threads finish.
    deinitLock(mutex[])
    0

  proc lockMutex*(mutex: ptr NativeMutex): cint =
    ## Acquires one runtime mutex.
    acquire(mutex[])
    0

  proc unlockMutex*(mutex: ptr NativeMutex): cint =
    ## Releases one runtime mutex.
    release(mutex[])
    0

  proc initCondition*(condition: ptr NativeCondition): cint =
    ## Initializes a native condition variable.
    initCond(condition[])
    0

  proc destroyCondition*(condition: ptr NativeCondition): cint =
    ## Releases a condition variable after all waiters finish.
    deinitCond(condition[])
    0

  proc signalCondition*(condition: ptr NativeCondition): cint =
    ## Wakes one channel waiter.
    signal(condition[])
    0

  proc broadcastCondition*(condition: ptr NativeCondition): cint =
    ## Wakes every worker waiting for the startup decision.
    broadcast(condition[])
    0

  proc waitCondition*(condition: ptr NativeCondition,
      mutex: ptr NativeMutex): cint =
    ## Atomically releases the mutex and waits for a channel notification.
    wait(condition[], mutex[])
    0

  proc startNativeThread*(handle: var ThreadHandle,
      start: NativeThreadStart, argument: pointer): cint =
    ## Starts a Windows thread with initialized C runtime thread state.
    handle.value = cast[pointer](beginThread(nil, 0, start, argument, 0, nil))
    if handle.value == nil: 1 else: 0

  proc joinNativeThread*(handle: ThreadHandle): cint =
    ## Waits for a Windows thread and releases its kernel handle.
    let status = waitForThread(handle.value, high(uint32))
    let closed = closeThread(handle.value)
    if status == 0 and closed != 0: 0 else: 1

  proc ignoreBrokenPipe*(): BrokenPipeHandler =
    ## Windows reports closed stdout through C stream errors.
    nil

  proc restoreBrokenPipe*(handler: BrokenPipeHandler) =
    ## Windows has no SIGPIPE handler to restore.
    discard

  proc brokenPipeSetupFailed*(handler: BrokenPipeHandler): bool =
    ## Windows needs no signal disposition change.
    false
else:
  import std/posix

  type
    NativeMutex* {.importc: "pthread_mutex_t", header: "<pthread.h>",
      bycopy.} = object
    NativeCondition* {.importc: "pthread_cond_t", header: "<pthread.h>",
      bycopy.} = object
    ThreadHandle* = object
      value: Pthread
    NativeThreadStart* = proc(argument: pointer): pointer {.noconv.}
    BrokenPipeHandler* = proc(signal: cint) {.noconv.}

  proc mutexInit(mutex: ptr NativeMutex, attributes: pointer): cint
      {.importc: "pthread_mutex_init", header: "<pthread.h>".}
  proc conditionInit(condition: ptr NativeCondition, attributes: pointer): cint
      {.importc: "pthread_cond_init", header: "<pthread.h>".}
  proc destroyMutex*(mutex: ptr NativeMutex): cint
      {.importc: "pthread_mutex_destroy", header: "<pthread.h>".}
  proc lockMutex*(mutex: ptr NativeMutex): cint
      {.importc: "pthread_mutex_lock", header: "<pthread.h>".}
  proc unlockMutex*(mutex: ptr NativeMutex): cint
      {.importc: "pthread_mutex_unlock", header: "<pthread.h>".}
  proc destroyCondition*(condition: ptr NativeCondition): cint
      {.importc: "pthread_cond_destroy", header: "<pthread.h>".}
  proc signalCondition*(condition: ptr NativeCondition): cint
      {.importc: "pthread_cond_signal", header: "<pthread.h>".}
  proc broadcastCondition*(condition: ptr NativeCondition): cint
      {.importc: "pthread_cond_broadcast", header: "<pthread.h>".}
  proc waitCondition*(condition: ptr NativeCondition,
      mutex: ptr NativeMutex): cint
      {.importc: "pthread_cond_wait", header: "<pthread.h>".}

  proc initMutex*(mutex: ptr NativeMutex): cint =
    ## Initializes a POSIX mutex with default attributes.
    mutexInit(mutex, nil)

  proc initCondition*(condition: ptr NativeCondition): cint =
    ## Initializes a POSIX condition variable with default attributes.
    conditionInit(condition, nil)

  proc startNativeThread*(handle: var ThreadHandle,
      start: NativeThreadStart, argument: pointer): cint =
    ## Starts a POSIX thread using runtime-owned startup arguments.
    pthread_create(addr handle.value, nil, start, argument)

  proc joinNativeThread*(handle: ThreadHandle): cint =
    ## Waits for a POSIX thread and releases its thread resources.
    pthread_join(handle.value, nil)

  proc ignoreBrokenPipe*(): BrokenPipeHandler =
    ## Makes a closed stdout pipe report a write error instead of a signal.
    signal(SIGPIPE, SIG_IGN)

  proc restoreBrokenPipe*(handler: BrokenPipeHandler) =
    ## Restores the caller's SIGPIPE disposition after program execution.
    discard signal(SIGPIPE, handler)

  proc brokenPipeSetupFailed*(handler: BrokenPipeHandler): bool =
    ## Detects a failed POSIX signal disposition change.
    handler == SIG_ERR

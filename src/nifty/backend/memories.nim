import common

const
  Arm64Supported* = defined(arm64) and
    (defined(macosx) or defined(linux)) and not defined(nimkeyNoNative)
  Amd64Supported* = defined(amd64) and
    (defined(windows) or defined(linux) or defined(macosx)) and
    not defined(nimkeyNoNative)
  NativeSupported* = Arm64Supported or Amd64Supported
  MaxNativeBytes* = 64 * 1024 * 1024

type
  CodeBuffer* = object
    memory: pointer
    size: int

when NativeSupported and defined(windows):
  type WindowsDword {.importc: "DWORD", header: "<windows.h>".} =
    distinct uint32

  proc virtualAlloc(address: pointer, size: csize_t,
      allocation, protection: uint32): pointer
    {.stdcall, importc: "VirtualAlloc", header: "<windows.h>", raises: [].}

  proc virtualFree(address: pointer, size: csize_t, kind: uint32): int32
    {.stdcall, importc: "VirtualFree", header: "<windows.h>", raises: [].}

  proc virtualProtect(address: pointer, size: csize_t, protection: uint32,
      previous: ptr WindowsDword): int32
    {.stdcall, importc: "VirtualProtect", header: "<windows.h>", raises: [].}

  proc flushInstructionCache(process, address: pointer, size: csize_t): int32
    {.stdcall, importc: "FlushInstructionCache", header: "<windows.h>",
      raises: [].}

  proc getCurrentProcess(): pointer
    {.stdcall, importc: "GetCurrentProcess", header: "<windows.h>", raises: [].}
elif NativeSupported:
  proc mmap(address: pointer, length: csize_t, protection, flags,
      handle: cint, offset: int64): pointer
    {.importc, header: "<sys/mman.h>", raises: [].}

  proc munmap(address: pointer, length: csize_t): cint
    {.importc, header: "<sys/mman.h>", raises: [].}

  when defined(macosx) and defined(arm64):
    proc protect(enabled: cint)
      {.importc: "pthread_jit_write_protect_np", header: "<pthread.h>",
        raises: [].}

    proc invalidate(address: pointer, length: csize_t)
      {.importc: "sys_icache_invalidate", header: "<libkern/OSCacheControl.h>",
        raises: [].}
  else:
    proc mprotect(address: pointer, length: csize_t, protection: cint): cint
      {.importc, header: "<sys/mman.h>", raises: [].}

    proc clearCache(start, stop: pointer)
      {.importc: "__builtin___clear_cache", nodecl, raises: [].}

proc `=copy`*(destination: var CodeBuffer, source: CodeBuffer) {.error:
  "Executable memory has one owner and cannot be copied.".}

proc `=destroy`*(buffer: CodeBuffer) {.raises: [].} =
  ## Releases executable mappings when their sole owner is destroyed.
  when NativeSupported:
    if buffer.memory != nil:
      when defined(windows):
        discard virtualFree(buffer.memory, 0, 0x8000)
      else:
        discard munmap(buffer.memory, buffer.size.csize_t)

proc release*(buffer: var CodeBuffer) {.raises: [].} =
  ## Releases executable pages explicitly and permits repeated cleanup.
  `=destroy`(buffer)
  buffer.memory = nil
  buffer.size = 0

proc entry*(buffer: CodeBuffer): pointer {.raises: [].} =
  ## Returns the sealed executable entry point or nil after release.
  return buffer.memory

proc initCodeBuffer*(bytes: openArray[byte]): CodeBuffer
    {.raises: [BackendError].} =
  ## Copies machine code into owned pages and seals them before execution.
  if bytes.len == 0 or bytes.len > MaxNativeBytes:
    raise newException(BackendError, "Native code size exceeds limits")
  when not NativeSupported:
    raise newException(BackendError, "In-memory native execution is unavailable")
  elif defined(windows):
    let memory = virtualAlloc(nil, bytes.len.csize_t, 0x3000, 0x04)
    if memory == nil:
      raise newException(BackendError, "Executable memory allocation failed")
    result.memory = memory
    result.size = bytes.len
    copyMem(memory, bytes[0].unsafeAddr, bytes.len)
    var previous: WindowsDword
    if virtualProtect(memory, bytes.len.csize_t, 0x20, previous.addr) == 0 or
        flushInstructionCache(getCurrentProcess(), memory,
          bytes.len.csize_t) == 0:
        result.release()
        raise newException(BackendError, "Executable memory sealing failed")
  else:
    let size = bytes.len
    when defined(macosx) and defined(arm64):
      const
        Protection = 1 or 2 or 4
        Flags = 0x2 or 0x1000 or 0x800
    elif defined(macosx):
      const
        Protection = 1 or 2
        Flags = 0x2 or 0x1000
    else:
      const
        Protection = 1 or 2
        Flags = 0x2 or 0x20
    let memory = mmap(nil, size.csize_t, Protection, Flags, -1, 0)
    if memory == cast[pointer](-1):
      raise newException(BackendError, "Executable memory allocation failed")
    result.memory = memory
    result.size = size
    when defined(macosx) and defined(arm64):
      protect(0)
      copyMem(memory, bytes[0].unsafeAddr, size)
      protect(1)
      invalidate(memory, size.csize_t)
    else:
      copyMem(memory, bytes[0].unsafeAddr, size)
      if mprotect(memory, size.csize_t, 1 or 4) != 0:
        result.release()
        raise newException(BackendError, "Executable memory sealing failed")
      clearCache(memory, cast[pointer](cast[uint](memory) + size.uint))

proc initCodeBuffer*(words: openArray[uint32]): CodeBuffer
    {.raises: [BackendError].} =
  ## Seals ARM64 instruction words only on a compatible execution host.
  if words.len == 0 or words.len > MaxNativeBytes div 4:
    raise newException(BackendError, "Native code size exceeds limits")
  when not Arm64Supported:
    raise newException(BackendError, "In-memory ARM64 execution is unavailable")
  else:
    let bytes = cast[ptr UncheckedArray[byte]](words[0].unsafeAddr)
    return initCodeBuffer(bytes.toOpenArray(0, words.len * 4 - 1))

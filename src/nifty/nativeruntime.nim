## Executes native code against bounded startup storage and host services.
import std/[dynlib, os, posix]
import common, types, nativefiles, nativecontainers, nativebundles
import backend/[context, memories]
export nativefiles, nativebundles, nativecontainers

type
  NativeEntry = proc(context, args, output, arena: pointer) {.cdecl.}
  NativeMutex {.importc: "pthread_mutex_t", header: "<pthread.h>",
    bycopy.} = object
  NativeCondition {.importc: "pthread_cond_t", header: "<pthread.h>",
    bycopy.} = object
  NativeChannel = object
    address: pointer
    mutex: NativeMutex
    available, vacant: NativeCondition
  NativeContext = object
    prefix: RuntimeContext
    plan: ptr NativePlan
    memory: NativeMemory
    channels: ptr UncheckedArray[NativeChannel]
    channelCount: int
  ThreadHandle = object
    value: Pthread
  NativeThread = object
    entry: NativeEntry
    context: ptr NativeContext
    arena: pointer

proc pthread_mutex_init(mutex: ptr NativeMutex, attributes: pointer): cint
    {.importc, header: "<pthread.h>".}
proc pthread_mutex_destroy(mutex: ptr NativeMutex): cint
    {.importc, header: "<pthread.h>".}
proc pthread_mutex_lock(mutex: ptr NativeMutex): cint
    {.importc, header: "<pthread.h>".}
proc pthread_mutex_unlock(mutex: ptr NativeMutex): cint
    {.importc, header: "<pthread.h>".}
proc pthread_cond_init(condition: ptr NativeCondition, attributes: pointer): cint
    {.importc, header: "<pthread.h>".}
proc pthread_cond_destroy(condition: ptr NativeCondition): cint
    {.importc, header: "<pthread.h>".}
proc pthread_cond_signal(condition: ptr NativeCondition): cint
    {.importc, header: "<pthread.h>".}
proc pthread_cond_wait(condition: ptr NativeCondition,
    mutex: ptr NativeMutex): cint {.importc, header: "<pthread.h>".}

var cStdout {.importc: "stdout", header: "<stdio.h>".}: File

proc flockfile(file: File) {.importc, header: "<stdio.h>".}
proc funlockfile(file: File) {.importc, header: "<stdio.h>".}
proc printf(format: cstring): cint {.importc, varargs, header: "<stdio.h>".}
proc fwrite(data: pointer, size, count: csize_t, file: File): csize_t
    {.importc, header: "<stdio.h>".}

proc offset(address: pointer, bytes: int): pointer {.inline.} =
  ## Returns a byte offset within a validated runtime allocation.
  cast[pointer](cast[uint](address) + uint(bytes))

proc loadInt(address: pointer, layout: NativeLayout): int64 =
  ## Loads a hardware integer using its signedness and physical width.
  case layout.bytes
  of 1:
    if layout.lower < 0: int64(cast[ptr int8](address)[])
    else: int64(cast[ptr uint8](address)[])
  of 2:
    if layout.lower < 0: int64(cast[ptr int16](address)[])
    else: int64(cast[ptr uint16](address)[])
  of 4:
    if layout.lower < 0: int64(cast[ptr int32](address)[])
    else: int64(cast[ptr uint32](address)[])
  else:
    cast[ptr int64](address)[]

proc executeEcho(host: NativeHost, layouts: seq[NativeLayout],
    args: pointer) =
  ## Writes one echo statement under the same libc stream lock as printf.
  flockfile(cStdout)
  for i, typ in host.paramTypes:
    template layout: untyped = layouts[typ]
    let argument = args.offset(host.paramOffsets[i])
    case layout.kind
    of IntType:
      if layout.display == "char":
        discard printf("%c", cint(loadInt(argument, layout)))
      else:
        discard printf("%lld", clonglong(loadInt(argument, layout)))
    of BoolType:
      discard printf("%s", if cast[ptr byte](argument)[] != 0:
        "true".cstring else: "false".cstring)
    of FloatType:
      let value = if layout.bytes == 4:
        float64(cast[ptr float32](argument)[])
      else:
        cast[ptr float64](argument)[]
      discard printf("%g", value)
    of StringType, StringLitType:
      let data = if layout.dynamic:
          cast[ptr pointer](argument.offset(16))[]
        else:
          argument.offset(layout.dataOffset)
      let count = cast[ptr int64](argument)[]
      if count > 0:
        discard fwrite(data, 1, csize_t(count), cStdout)
    else:
      discard
  discard printf("\n")
  funlockfile(cStdout)

proc executeChannel(context: ptr NativeContext, host: NativeHost,
    receiver, args, output: pointer) =
  ## Blocks a bounded channel using startup initialized synchronization.
  var channel: ptr NativeChannel
  for i in 0 ..< context.channelCount:
    if context.channels[i].address == receiver:
      channel = addr context.channels[i]
      break
  if channel == nil:
    quit("nifty: channel has no startup synchronization", 1)
  template layout: untyped = context.plan.layouts[host.receiverType]
  template element: untyped = context.plan.layouts[layout.elem]
  let
    length = cast[ptr int64](receiver)
    head = cast[ptr int64](receiver.offset(8))
  discard pthread_mutex_lock(addr channel.mutex)
  if host.operation == "send":
    while length[] >= layout.capacity:
      discard pthread_cond_wait(addr channel.vacant, addr channel.mutex)
    let index = (head[] + length[]) mod layout.capacity
    copyValue(receiver.offset(layout.dataOffset + int(index * element.bytes)),
      args.offset(host.paramOffsets[0]), element,
      context.plan.layouts[host.paramTypes[0]])
    inc length[]
    discard pthread_cond_signal(addr channel.available)
  else:
    while length[] == 0:
      discard pthread_cond_wait(addr channel.available, addr channel.mutex)
    copyMem(output,
      receiver.offset(layout.dataOffset + int(head[] * element.bytes)),
      int(element.bytes))
    head[] = (head[] + 1) mod layout.capacity
    dec length[]
    discard pthread_cond_signal(addr channel.vacant)
  discard pthread_mutex_unlock(addr channel.mutex)

proc dispatch(context: pointer, hostId: int64,
    receiver, args, output: pointer) {.cdecl.} =
  ## Dispatches fixed host descriptors without allocating program storage.
  let runtime = cast[ptr NativeContext](context)
  template host: untyped = runtime.plan.hosts[int(hostId)]
  case host.kind
  of EchoHost:
    executeEcho(host, runtime.plan.layouts, args)
  of LockHost:
    let mutex = cast[ptr ptr NativeMutex](receiver)[]
    if host.operation == "lock":
      discard pthread_mutex_lock(mutex)
    else:
      discard pthread_mutex_unlock(mutex)
  of ContainerHost:
    if runtime.plan.layouts[host.receiverType].kind == ChannelType:
      executeChannel(runtime, host, receiver, args, output)
    else:
      executeContainer(host, runtime.plan.layouts, receiver, args,
        output, runtime.memory)
  of ExternHost:
    quit("nifty: extern requires a direct ABI call", 1)

proc threadStart(argument: pointer): pointer {.noconv.} =
  ## Enters one native thread with its own preallocated arena.
  let thread = cast[ptr NativeThread](argument)
  thread.entry(thread.context, nil, nil, thread.arena)
  nil

proc resolveExtern(host: NativeHost, libraries: var seq[LibHandle]): pointer =
  ## Resolves C symbols once before any program thread is started.
  if host.library == "libc":
    let library = loadLib()
    if library == nil:
      raise newException(NiftyError, "cannot open native process symbols")
    libraries.add library
    result = symAddr(library, host.symbol.cstring)
  else:
    let names = when defined(macosx):
      @["lib" & host.library & ".dylib", host.library]
    else:
      @["lib" & host.library & ".so", host.library]
    var library: LibHandle
    for name in names:
      library = loadLib(name)
      if library != nil:
        break
    if library == nil:
      raise newException(NiftyError, "cannot load native library: " & host.library)
    libraries.add library
    result = symAddr(library, host.symbol.cstring)
  if result == nil:
    raise newException(NiftyError, "cannot resolve native symbol: " & host.symbol)

proc runNative*(program: NativeProgram,
    memory = NativeMemory()) =
  ## Runs machine code with scoped allocation hooks for owned storage.
  program.validateNative()
  if program.platform != NativeHostPlatform:
    raise newException(NiftyError,
      "native image operating system ABI does not match runtime")
  when defined(arm64):
    const HostTarget = Arm64Target
  elif defined(amd64):
    const HostTarget = Amd64Target
  else:
    raise newException(NiftyError, "native runtime unavailable on this CPU")
  when defined(arm64) or defined(amd64):
    if program.image.target != HostTarget:
      raise newException(NiftyError, "native image CPU does not match runtime")
  var
    code = initCodeBuffer(program.image.bytes)
    plan = program.plan
    globals = newSeq[byte](max(16, plan.globalBytes))
    hosts = newSeq[pointer](plan.hosts.len)
    mutexes = newSeq[NativeMutex](plan.lockOffsets.len)
    channels = newSeq[NativeChannel](plan.channelOffsets.len)
    libraries: seq[LibHandle]
  defer:
    for library in libraries:
      unloadLib(library)
  for i, host in plan.hosts:
    hosts[i] = if host.kind == ExternHost:
      resolveExtern(host, libraries)
    else:
      cast[pointer](dispatch)
  if plan.initialData.len > 0:
    copyMem(addr globals[0], addr plan.initialData[0], plan.initialData.len)
  defer:
    for i in countdown(plan.ownedGlobals.high, 0):
      let owned = plan.ownedGlobals[i]
      dropOwned(plan.layouts, owned.layout,
        addr globals[owned.offset], memory)
  var initializedLocks = 0
  var initializedChannels = 0
  defer:
    for i in 0 ..< initializedLocks:
      discard pthread_mutex_destroy(addr mutexes[i])
    for i in 0 ..< initializedChannels:
      discard pthread_cond_destroy(addr channels[i].available)
      discard pthread_cond_destroy(addr channels[i].vacant)
      discard pthread_mutex_destroy(addr channels[i].mutex)
  for i, location in plan.lockOffsets:
    if pthread_mutex_init(addr mutexes[i], nil) != 0:
      raise newException(NiftyError, "cannot initialize native lock")
    inc initializedLocks
    cast[ptr pointer](addr globals[location])[] = addr mutexes[i]
  for i, location in plan.channelOffsets:
    channels[i].address = addr globals[location]
    if pthread_mutex_init(addr channels[i].mutex, nil) != 0:
      raise newException(NiftyError, "cannot initialize native channel mutex")
    if pthread_cond_init(addr channels[i].available, nil) != 0:
      discard pthread_mutex_destroy(addr channels[i].mutex)
      raise newException(NiftyError, "cannot initialize native channel condition")
    if pthread_cond_init(addr channels[i].vacant, nil) != 0:
      discard pthread_cond_destroy(addr channels[i].available)
      discard pthread_mutex_destroy(addr channels[i].mutex)
      raise newException(NiftyError, "cannot initialize native channel condition")
    inc initializedChannels
  var runtime = NativeContext(
    prefix: RuntimeContext(globals: addr globals[0],
      hosts: if hosts.len > 0: addr hosts[0] else: nil),
    plan: addr plan, memory: memory, channelCount: channels.len,
    channels: if channels.len > 0:
      cast[ptr UncheckedArray[NativeChannel]](addr channels[0]) else: nil)
  var count = 0
  var arenaBytes = 0
  for thread in plan.threads:
    count += thread.count
    arenaBytes += thread.count * ((thread.arenaBytes + 15) div 16 * 16)
  var
    arenas = newSeq[byte](max(16, arenaBytes + 16))
    entries = newSeq[NativeThread](count)
    threads = newSeq[ThreadHandle](count)
    index = 0
    arenaOffset = 0
  for thread in plan.threads:
    for instance in 0 ..< thread.count:
      entries[index] = NativeThread(
        entry: cast[NativeEntry](code.entry.offset(
          program.image.offsets[thread.functionIndex])),
        context: addr runtime, arena: addr arenas[arenaOffset])
      arenaOffset += (thread.arenaBytes + 15) div 16 * 16
      inc index
  var started = 0
  for i in 0 ..< count:
    let status = pthread_create(addr threads[i].value, nil,
      threadStart, addr entries[i])
    if status != 0:
      for j in 0 ..< started:
        discard pthread_join(threads[j].value, nil)
      raise newException(NiftyError, "cannot start native thread: " & $status)
    inc started
  for i in 0 ..< started:
    if pthread_join(threads[i].value, nil) != 0:
      raise newException(NiftyError, "cannot join native thread")

proc tryRunEmbedded*(): bool =
  ## Runs an embedded native image before processing compiler arguments.
  let data = embeddedImage(readFile(getAppFilename()))
  if data.len == 0:
    return false
  runNative(decodeNative(data))
  true

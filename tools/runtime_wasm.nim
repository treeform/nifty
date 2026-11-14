## Precompiled memory64 startup and shared container ownership services.
import nifty/[common, nativeplans, nativecontainers, wasmmetadata]

var metadata {.importc: "nifty_metadata".}: byte

type
  WasmContext = object
    globals, hosts: pointer
    plan: ptr NativePlan
    memory: NativeMemory
  WasmEntry = proc(context, arena: pointer) {.cdecl.}

proc getEntry(): pointer {.importc: "nf_get_entry", cdecl, raises: [].}
  ## Loads the entry through a retained pointer after module rewriting.
proc emit(fd: uint32, data: pointer, size: int)
    {.importc: "nf_emit", cdecl, raises: [].}
  ## Emits a full-width memory span through staged WASI output.
proc exit(status: uint32)
    {.importc: "nf_exit", cdecl, noreturn, raises: [].}
  ## Terminates a standalone WASM invocation with its failure status.

proc dispatch(context: pointer, hostId: int64,
    receiver, args, output: pointer)
    {.cdecl, exportc: "nifty_dispatch".} =
  ## Dispatches shared container helpers and single-thread lock operations.
  let runtime = cast[ptr WasmContext](context)
  if hostId < 0 or hostId >= runtime.plan.hosts.len:
    raise newException(NiftyError, "invalid WASM host index")
  let host = runtime.plan.hosts[int(hostId)]
  case host.kind
  of ContainerHost:
    executeContainer(host, runtime.plan.layouts, receiver, args, output,
      runtime.memory)
  of LockHost:
    discard
  of ReservedHost, ExternHost:
    raise newException(NiftyError, "invalid WASM dispatched host")

proc stackFailure() {.cdecl, exportc: "nifty_stack_failure", noreturn.} =
  ## Reports a generated program's checked stack exhaustion.
  const Message = "nifty: WASM stack exhausted\n"
  emit(2, cast[pointer](Message.cstring), Message.len)
  exit(1)

proc execute(plan: var NativePlan) =
  ## Initializes globals and an arena and releases all program-owned storage.
  var
    globals = newSeq[byte](max(16, plan.globalBytes))
    arena = newSeq[byte](max(16, plan.threads[0].arenaBytes))
    runtime = WasmContext(globals: addr globals[0], plan: addr plan)
  if plan.initialData.len > 0:
    copyMem(addr globals[0], addr plan.initialData[0], plan.initialData.len)
  defer:
    for i in countdown(plan.ownedGlobals.high, 0):
      let owned = plan.ownedGlobals[i]
      dropOwned(plan.layouts, owned.layout, addr globals[owned.offset],
        runtime.memory)
  cast[WasmEntry](getEntry())(addr runtime, addr arena[0])

try:
  let
    data = cast[ptr UncheckedArray[byte]](addr metadata)
    size = wasmMetadataSize(data.toOpenArray(0, WasmMetadataHeader - 1))
  var bytes = newString(size)
  copyMem(addr bytes[0], addr metadata, size)
  var plan = deserializeWasmMetadata(bytes)
  execute(plan)
except CatchableError as failure:
  let message = "nifty: " & failure.msg & "\n"
  emit(2, cast[pointer](message.cstring), message.len)
  exit(1)

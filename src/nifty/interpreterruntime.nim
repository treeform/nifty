## Executes optimized IR with the shared native storage and host services.
import common, nativefiles, nativeruntime, interpreterffi
import backend/[context, irinterpreters]
export nativefiles

type InterpreterRuntime = object
  plan: ptr NativePlan
  interpreter: IrInterpreterPlan
  foreign: seq[ForeignCall]

proc prepareRuntime(context, user: pointer) =
  ## Resolves each foreign call before any program worker starts.
  let
    runtime = cast[ptr InterpreterRuntime](user)
    prefix = cast[ptr RuntimeContext](context)
    addresses = cast[ptr UncheckedArray[pointer]](prefix.hosts)
  runtime.foreign = newSeq[ForeignCall](runtime.plan.module.hosts.len)
  for i, host in runtime.plan.module.hosts:
    let binding = int(host.binding)
    if runtime.plan.hosts[binding].kind == ExternHost:
      runtime.foreign[i] = prepareForeign(host.signature, addresses[binding])

proc executeHost(context: pointer, hostIndex: int,
    arguments: openArray[uint64], returns: var openArray[uint64])
    {.nimcall, gcsafe.} =
  ## Calls the shared runtime dispatcher or a prepared foreign ABI bridge.
  let runtime = cast[ptr InterpreterRuntime](context)
  let binding = int(runtime.plan.module.hosts[hostIndex].binding)
  if runtime.plan.hosts[binding].kind == ExternHost:
    callForeign(addr runtime.foreign[hostIndex], arguments, returns)
  else:
    {.cast(gcsafe).}:
      dispatchRuntime(cast[pointer](arguments[0]), int64(arguments[1]),
        cast[pointer](arguments[2]), cast[pointer](arguments[3]),
        cast[pointer](arguments[4]))

proc executeEntry(context: pointer, functionIndex: int,
    arena, user: pointer) {.nimcall, gcsafe.} =
  ## Runs a worker with its independently allocated interpreter call frames.
  let runtime = cast[ptr InterpreterRuntime](user)
  discard interpret(addr runtime.interpreter, functionIndex,
    [cast[uint64](context), 0'u64, 0'u64, cast[uint64](arena)],
    executeHost, user)

proc runInterpreted*(plan: NativePlan, optimization = SpeedOptimization,
    memory = NativeMemory()) =
  ## Optimizes and interprets existing IR without creating native code.
  var optimized = optimizeNative(plan, optimization)
  validateNativePlan(optimized, optimized.module.functions.len)
  for host in optimized.module.hosts:
    if host.binding < 0 or int(host.binding) >= optimized.hosts.len:
      raise newException(NiftyError, "invalid interpreter host binding")
  var runtime = InterpreterRuntime(plan: addr optimized,
    interpreter: prepareInterpreter(optimized.module))
  runRuntime(optimized, executor = executeEntry, user = addr runtime,
    prepare = prepareRuntime, memory = memory)

proc interpreterReport*(plan: NativePlan, moduleName: string,
    optimization = SpeedOptimization): string =
  ## Reports actual IR and bounded startup resources without machine code.
  let optimized = optimizeNative(plan, optimization)
  validateNativePlan(optimized, optimized.module.functions.len)
  var instructions, blocks, workers, arenas: int
  for function in optimized.module.functions:
    instructions += function.instructions.len
    blocks += function.blocks.len
  for thread in optimized.threads:
    workers += thread.count
    arenas += thread.count * ((thread.arenaBytes + 15) div 16 * 16)
  result = "interpreter report: " & moduleName & "\n" &
    "IR functions: " & $optimized.module.functions.len & "\n" &
    "IR blocks: " & $blocks & "\n" &
    "IR instructions: " & $instructions & "\n" &
    "IR hosts: " & $optimized.module.hosts.len & "\n" &
    "global bytes: " & $optimized.globalBytes & "\n" &
    "thread instances: " & $workers & "\n" &
    "thread arena bytes: " & $arenas & "\n"

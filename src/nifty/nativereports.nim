## Reports generated code and bounded compiler-owned native storage.
import std/strutils
import common, nativeplans, backend/[engine, irs]

type
  StackBounds = object
    bytes: seq[int64]
    next: seq[int]

proc invalid(message: string) {.noreturn, raises: [NiftyError].} =
  ## Rejects metadata that cannot support an honest resource bound.
  raise newException(NiftyError, "native report: " & message)

proc addBytes(a, b: int64): int64 {.raises: [NiftyError].} =
  ## Adds nonnegative resource quantities without wrapping.
  if a < 0 or b < 0 or a > high(int64) - b:
    invalid("resource byte count exceeds the report range")
  a + b

proc multiplyBytes(bytes: int64, count: int): int64
    {.raises: [NiftyError].} =
  ## Multiplies a per-instance resource bound without wrapping.
  if bytes < 0 or count < 0 or
      (count > 0 and bytes > high(int64) div int64(count)):
    invalid("resource byte count exceeds the report range")
  bytes * int64(count)

proc stackBounds(plan: NativePlan, image: NativeImage): StackBounds
    {.raises: [NiftyError].} =
  ## Resolves direct-call stack bounds in callee-first order.
  let count = plan.module.functions.len
  if image.frameBytes.len != count:
    invalid("native frame table does not match the function table")
  if image.wrapperFrameBytes < 0:
    invalid("negative wrapper frame size")
  var
    callers = newSeq[seq[int]](count)
    remaining = newSeq[int](count)
    ready: seq[int]
  result.bytes = newSeq[int64](count)
  result.next = newSeq[int](count)
  for i, function in plan.module.functions:
    if image.frameBytes[i] < 0:
      invalid("negative frame size for " & function.name)
    result.bytes[i] = int64(image.frameBytes[i])
    result.next[i] = -1
    var
      targets: seq[int]
      callsHost = false
    for instruction in function.instructions:
      case instruction.op
      of CallOp:
        targets.add(int(instruction.target))
      of HostCallOp:
        callsHost = true
      of IndirectCallOp:
        invalid("indirect call prevents a static stack bound in " &
          function.name)
      else:
        discard
    for blk in function.blocks:
      case blk.terminator.kind
      of InvokeTerminator:
        targets.add(int(blk.terminator.callee))
      of InvokeHostTerminator:
        callsHost = true
      else:
        discard
    if callsHost and image.target == Amd64Target:
      # CALL pushes a return address before the unknown host body runs.
      result.bytes[i] = addBytes(result.bytes[i], 8)
    for target in targets:
      if target < 0 or target >= count:
        invalid("invalid call target in " & function.name)
      callers[target].add(i)
      inc remaining[i]
    if remaining[i] == 0:
      ready.add(i)
  var cursor = 0
  while cursor < ready.len:
    let callee = ready[cursor]
    inc cursor
    for caller in callers[callee]:
      let bound = addBytes(int64(image.frameBytes[caller]),
        result.bytes[callee])
      if bound > result.bytes[caller] or
          (bound == result.bytes[caller] and
          (result.next[caller] < 0 or callee < result.next[caller])):
        result.bytes[caller] = bound
        result.next[caller] = callee
      dec remaining[caller]
      if remaining[caller] == 0:
        ready.add(caller)
  if ready.len != count:
    invalid("recursive native call graph has no finite stack bound")

proc chain(plan: NativePlan, bounds: StackBounds, entry: int): string
    {.raises: [].} =
  ## Names the direct-call chain responsible for a thread's stack bound.
  var current = entry
  while current >= 0:
    if result.len > 0:
      result.add(" -> ")
    let name = plan.module.functions[current].name
    result.add(if name.len > 0: name else: "function " & $current)
    current = bounds.next[current]

proc nativeReport*(plan: NativePlan, image: NativeImage,
    source: string): string {.raises: [NiftyError].} =
  ## Reports generated sizes while excluding unknown host/runtime memory.
  if plan.globalBytes < 0:
    invalid("negative global storage size")
  let
    bounds = stackBounds(plan, image)
    target = case image.target
      of Arm64Target: "arm64"
      of Amd64Target: "amd64"
  var readonlyBytes = 0'i64
  for global in plan.module.globals:
    if global.bytes.count < 0:
      invalid("negative global payload size")
    if global.readonly:
      readonlyBytes = addBytes(readonlyBytes, int64(global.bytes.count))
  var lines = @["nifty native report: " & source & " (" & target & ")",
    "", "generated storage:",
    "  machine code: " & $image.bytes.len & " bytes (including wrapper)",
    "  global storage: " & $plan.globalBytes & " bytes",
    "  initialization payload: " & $plan.initialData.len &
      " bytes (initial contents; not additional runtime globals)"]
  lines.add("  read-only global payload: " & $readonlyBytes & " bytes")
  lines.add("")
  lines.add("native frame sizes (including spills, saves and ABI space):")
  for i, function in plan.module.functions:
    lines.add("  " & function.name & ": " & $image.frameBytes[i] & " bytes")
  lines.add("  entry wrapper: " & $image.wrapperFrameBytes &
    " bytes (unused by thread entries)")
  lines.add("")
  lines.add("compiler-controlled stack, worst-case bound per thread:")
  var
    instances = 0'i64
    stackTotal = 0'i64
    arenaTotal = 0'i64
  for thread in plan.threads:
    if thread.functionIndex < 0 or
        thread.functionIndex >= plan.module.functions.len:
      invalid("invalid entry function for thread " & thread.name)
    if thread.count <= 0:
      invalid("thread instance count must be positive for " & thread.name)
    if thread.arenaBytes < 0:
      invalid("negative arena size for thread " & thread.name)
    let
      bytes = bounds.bytes[thread.functionIndex]
      total = multiplyBytes(bytes, thread.count)
      label = thread.name & " x" & $thread.count
    instances = addBytes(instances, int64(thread.count))
    stackTotal = addBytes(stackTotal, total)
    arenaTotal = addBytes(arenaTotal,
      multiplyBytes(int64(thread.arenaBytes), thread.count))
    lines.add("  " & label & ": " & $bytes & " bytes each, " & $total &
      " bytes all instances (" & chain(plan, bounds, thread.functionIndex) &
      ")")
  lines.add("  total: " & $stackTotal & " bytes across " & $instances &
    " thread instances")
  lines.add("")
  lines.add("arena storage per thread (allocated up front):")
  for thread in plan.threads:
    lines.add("  " & thread.name & " x" & $thread.count & ": " &
      $thread.arenaBytes & " bytes each, " &
      $multiplyBytes(int64(thread.arenaBytes), thread.count) &
      " bytes all instances")
  lines.add("  total: " & $arenaTotal & " bytes")
  lines.add("")
  lines.add("accounted storage (globals + stack bounds + arenas): " &
    $addBytes(int64(plan.globalBytes), addBytes(stackTotal, arenaTotal)) &
    " bytes")
  lines.add("Host calls, runtime/PThread synchronization bookkeeping, startup " &
    "metadata, OS stack reservations, and allocator overhead are excluded; " &
    "their memory and stack use are unknown here.")
  lines.add("Stack bounds sum generated frames along the deepest direct-call " &
    "chain, including AMD64 host-call return addresses; external host " &
    "stack is excluded.")
  lines.add("Abstract operation bounds remain source-level; use the C/source " &
    "report. They are not native instruction counts or wall-time promises.")
  lines.join("\n") & "\n"

## Executes verified optimized IR directly, without executable code generation.
import std/math
import irs, irchecks, common, context, floatroundings

const
  ScalarWidths = block:
    var widths: array[IrType, int]
    for kind in IrType:
      widths[kind] = int(byteCount(kind, 8))
      doAssert widths[kind] in [1, 2, 4, 8]
    widths
  ScalarMasks = block:
    var masks: array[IrType, uint64]
    for kind in IrType:
      masks[kind] =
        if kind == BoolType: 1'u64
        elif ScalarWidths[kind] == 8: high(uint64)
        else: (1'u64 shl (ScalarWidths[kind] * 8)) - 1
    masks
  ScalarShifts = block:
    var shifts: array[IrType, int]
    for kind in IrType:
      shifts[kind] = 64 - ScalarWidths[kind] * 8
    shifts

type
  ExecutionLimitError* = object of CatchableError
  ExecutionBudget* = object
    ## Logical VM resources; host callback allocations are outside this budget.
    maxWork*, maxMemory*: int64
    maxDepth*: int
    work*, memory*, peakMemory*: int64
  IrHostCallback* = proc(context: pointer, hostIndex: int,
    arguments: openArray[uint64], returns: var openArray[uint64])
    {.nimcall, gcsafe.}
  InterpreterFramePlan = object
    offsets: seq[int]
    bytes, alignment, scratch: int
  IrInterpreterPlan* = object
    module: IrModule
    frames: seq[InterpreterFramePlan]
  InterpreterFrame = object
    function, blockIndex, instruction: int
    registers, scratch: seq[uint64]
    memory: seq[byte]
    base: uint64
    destination: Span
    invoke: bool
    pendingFailure: string
    chargedBytes: int64

proc spend*(budget: ptr ExecutionBudget, units = 1'i64) =
  if budget != nil:
    if units < 0 or units > budget.maxWork - budget.work:
      raise newException(ExecutionLimitError, "script work limit exceeded")
    budget.work += units

proc acquire*(budget: ptr ExecutionBudget, bytes: int64) =
  if budget != nil:
    if bytes < 0 or bytes > budget.maxMemory - budget.memory:
      raise newException(ExecutionLimitError, "script memory limit exceeded")
    budget.memory += bytes
    budget.peakMemory = max(budget.peakMemory, budget.memory)

proc release*(budget: ptr ExecutionBudget, bytes: int64) =
  if budget != nil: budget.memory -= bytes

proc interpreterFunctionAddress*(index: int): uint64 =
  ## Encodes a VM function reference for indirect calls.
  uint64(index + 1)

proc normalize(value: uint64, kind: IrType): uint64 {.inline.} =
  ## Keeps the bit representation canonical at scalar boundaries.
  value and ScalarMasks[kind]

proc signed(kind: IrType): bool =
  ## Identifies signed integer types.
  kind in {Int8Type, Int16Type, Int32Type, Int64Type}

proc signedValue(value: uint64, kind: IrType): int64 {.inline.} =
  ## Sign extends a scalar bit pattern.
  let shift = ScalarShifts[kind]
  cast[int64](value shl shift) shr shift

proc loadScalar(address: uint64, kind: IrType): uint64 {.inline.} =
  ## Copies an unaligned scalar with a constant-sized native transfer.
  result = 0
  case ScalarWidths[kind]
  of 1: copyMem(addr result, cast[pointer](address), 1)
  of 2: copyMem(addr result, cast[pointer](address), 2)
  of 4: copyMem(addr result, cast[pointer](address), 4)
  else: copyMem(addr result, cast[pointer](address), 8)
  if kind == BoolType:
    result = result and 1

proc storeScalar(address, value: uint64, kind: IrType) {.inline.} =
  ## Writes only the scalar's bytes, including at unaligned addresses.
  var bits = value
  case ScalarWidths[kind]
  of 1: copyMem(cast[pointer](address), addr bits, 1)
  of 2: copyMem(cast[pointer](address), addr bits, 2)
  of 4: copyMem(cast[pointer](address), addr bits, 4)
  else: copyMem(cast[pointer](address), addr bits, 8)

proc prepareInterpreter*(module: IrModule): IrInterpreterPlan =
  ## Verifies IR and prepares stable, aligned slot layouts.
  verifyIr(module)
  if module.pointerBytes != 8:
    error("IR interpreter requires 64-bit pointers")
  result.module = module
  for function in module.functions:
    var frame = InterpreterFramePlan(alignment: 8)
    for slot in function.slots:
      frame.alignment = max(frame.alignment, int(slot.alignment))
      frame.bytes = aligned(frame.bytes, int(slot.alignment))
      frame.offsets.add(frame.bytes)
      frame.bytes += int(slot.byteCount)
    for edge in function.edges:
      frame.scratch = max(frame.scratch, int(edge.arguments.count))
    for instruction in function.instructions:
      frame.scratch = max(frame.scratch,
        int(instruction.arguments.count + instruction.results.count))
    for data in function.blocks:
      frame.scratch = max(frame.scratch,
        int(data.terminator.arguments.count + data.terminator.results.count))
    result.frames.add(frame)

proc compare[T](a, b: T, comparison: IrComparison): bool {.inline.} =
  ## Evaluates scalar comparisons with the host's ordered float semantics.
  case comparison
  of EqualComparison: a == b
  of NotEqualComparison: a != b
  of LessComparison: a < b
  of LessEqualComparison: a <= b
  of GreaterComparison: a > b
  of GreaterEqualComparison: a >= b

proc scalar(op: IrOpcode, a, b: uint64, kind: IrType): uint64 =
  ## Evaluates scalar arithmetic while preserving float32 rounding.
  template floating(T: typedesc, U: typedesc): untyped =
    let x = cast[T](U(a))
    let y = cast[T](U(b))
    var z: T
    case op
    of AddOp: z = x + y
    of SubtractOp: z = x - y
    of MultiplyOp: z = x * y
    of DivideOp: z = x / y
    of NegateOp: z = -x
    of SqrtOp: z = T(sqrt(x))
    of FloorOp: z = T(floor(x))
    of RoundOp:
      when T is float32: z = roundSingle(x)
      else: z = round(x)
    else: error("Unsupported floating IR operation: " & $op)
    return uint64(cast[U](z))
  if kind == Float32Type:
    floating(float32, uint32)
  if kind == Float64Type:
    floating(float64, uint64)
  case op
  of AddOp: result = a + b
  of SubtractOp: result = a - b
  of MultiplyOp: result = a * b
  of MultiplyHighOp: result = multiplyHigh(a, b)
  of NegateOp: result = 0'u64 - a
  of AndOp: result = a and b
  of OrOp: result = a or b
  of XorOp: result = a xor b
  of NotOp: result = not a
  of ShiftLeftOp: result = a shl int(b and 63'u64)
  of ShiftRightOp: result = a shr int(b and 63'u64)
  of ArithmeticRightOp:
    result = cast[uint64](signedValue(a, kind) shr
      int(b and 63'u64))
  of DivideOp, RemainderOp:
    if b == 0: error("IR interpreter division by zero")
    if signed(kind):
      let x = signedValue(a, kind)
      let y = signedValue(b, kind)
      if x == low(int64) and y == -1:
        result = if op == DivideOp: a else: 0
      elif op == DivideOp: result = cast[uint64](x div y)
      else: result = cast[uint64](x mod y)
    elif op == DivideOp: result = a div b
    else: result = a mod b
  else: error("Unsupported integer IR operation: " & $op)
  result = normalize(result, kind)

proc convert(value: uint64, source, target: IrType,
    conversion: IrConversion): uint64 =
  ## Converts scalar registers with explicit signedness and float widths.
  case conversion
  of BitcastConversion, TruncateConversion, ZeroExtendConversion:
    result = value
  of SignExtendConversion:
    result = cast[uint64](signedValue(value, source))
  of IntegerFloatConversion:
    if target == Float32Type:
      let number = if signed(source): float32(signedValue(value, source))
        else: float32(value)
      result = uint64(cast[uint32](number))
    else:
      let number = if signed(source): float64(signedValue(value, source))
        else: float64(value)
      result = cast[uint64](number)
  of FloatWidthConversion:
    if target == Float32Type:
      result = uint64(cast[uint32](float32(cast[float64](value))))
    else: result = cast[uint64](float64(cast[float32](uint32(value))))
  of FloatIntegerConversion:
    let original = if source == Float32Type:
        float64(cast[float32](uint32(value)))
      else: cast[float64](value)
    let number = trunc(original)
    let bits = ScalarWidths[target] * 8
    if classify(number) in {fcNan, fcInf, fcNegInf}:
      error("IR interpreter invalid float to integer conversion")
    if signed(target):
      let bound = pow(2.0, float64(bits - 1))
      if number < -bound or number >= bound:
        error("IR interpreter float to integer overflow")
      result = cast[uint64](int64(number))
    else:
      if number < 0 or number >= pow(2.0, float64(bits)):
        error("IR interpreter float to integer overflow")
      result = uint64(number)
  result = normalize(result, target)

proc interpret*(plan: ptr IrInterpreterPlan, entry: int,
    arguments: openArray[uint64], host: IrHostCallback,
    context: pointer = nil, budget: ptr ExecutionBudget = nil): seq[uint64] =
  ## Runs a function using an explicit VM stack and invocation-local memory.
  if plan == nil or entry < 0 or entry >= plan.module.functions.len:
    error("IR interpreter entry is invalid")
  var frames: seq[InterpreterFrame]
  var chargedFrames = 0'i64
  defer: budget.release(chargedFrames)
  proc push(target: int, args: openArray[uint64], destination: Span,
      invoke = false) =
    ## Allocates one stable activation and binds its entry parameters.
    let function = addr plan.module.functions[target]
    if args.len != function.signature.parameters.len:
      error("IR interpreter argument arity mismatch")
    let layout = addr plan.frames[target]
    if budget != nil and frames.len >= budget.maxDepth:
      raise newException(ExecutionLimitError, "script call depth limit exceeded")
    let charged = int64(max(1, layout.bytes + layout.alignment)) +
      int64(function.values.len + max(1, layout.scratch)) * 8 + 256
    budget.acquire(charged)
    chargedFrames += charged
    var frame = InterpreterFrame(function: target,
      chargedBytes: charged,
      destination: destination, invoke: invoke,
      registers: newSeq[uint64](function.values.len),
      scratch: newSeq[uint64](max(1, layout.scratch)),
      memory: newSeq[byte](max(1, layout.bytes + layout.alignment)))
    frame.base = uint64(aligned(cast[int](addr frame.memory[0]),
      layout.alignment))
    for i, value in args:
      frame.registers[int(function.blocks[0].parameters.first) + i] =
        normalize(value, function.signature.parameters[i])
    frames.add(frame)
  proc edge(frame: var InterpreterFrame, index: int) =
    ## Applies branch parameters as one parallel assignment.
    let function = addr plan.module.functions[frame.function]
    let jump = function.edges[index]
    let parameters = function.blocks[int32(jump.target)].parameters
    for i in 0 ..< int(jump.arguments.count):
      frame.scratch[i] = frame.registers[int32(function.operands[
        int(jump.arguments.first) + i])]
    for i in 0 ..< int(parameters.count):
      frame.registers[int(parameters.first) + i] = frame.scratch[i]
    frame.blockIndex = int(int32(jump.target))
    frame.instruction = 0
  proc propagate(message: string) =
    ## Unwinds activations to the nearest explicit failure continuation.
    while frames.len > 0:
      let invoked = frames[^1].invoke
      budget.release(frames[^1].chargedBytes)
      chargedFrames -= frames[^1].chargedBytes
      frames.setLen(frames.len - 1)
      if invoked and frames.len > 0:
        let caller = addr frames[^1]
        let terminal = plan.module.functions[caller.function].blocks[
          caller.blockIndex].terminator
        caller.pendingFailure = message
        edge(caller[], int(terminal.edges.first) + 1)
        return
    error(message)
  push(entry, arguments, Span())
  while frames.len > 0:
    budget.spend()
    let frame = addr frames[^1]
    let function = addr plan.module.functions[frame.function]
    let data = function.blocks[frame.blockIndex]
    template operand(span: Span, index: int): uint64 =
      frame.registers[int32(function.operands[int(span.first) + index])]
    template operandKind(span: Span, index: int): IrType =
      function.values[int32(function.operands[int(span.first) + index])].valueType
    if frame.instruction < int(data.instructions.count):
      let item = function.instructions[int(data.instructions.first) + frame.instruction]
      inc frame.instruction
      let destination = int(item.results.first)
      let kind = if item.results.count > 0:
          function.values[destination].valueType
        else: UInt64Type
      let a = if item.arguments.count > 0: operand(item.arguments, 0) else: 0'u64
      let b = if item.arguments.count > 1: operand(item.arguments, 1) else: 0'u64
      var value: uint64
      case item.op
      of ConstantOp: value = normalize(item.bits, kind)
      of FrameSizeOp: value = uint64(plan.frames[frame.function].bytes)
      of SlotAddressOp:
        value = frame.base + uint64(plan.frames[frame.function].offsets[item.target])
      of GlobalAddressOp:
        let parameters = function.blocks[0].parameters
        if parameters.count == 0 or frame.registers[parameters.first] == 0:
          error("IR interpreter global access requires a runtime context")
        let runtime = cast[ptr RuntimeContext](frame.registers[parameters.first])
        value = cast[uint64](runtime.globals) +
          cast[uint64](plan.module.globals[item.target].offset)
      of OffsetAddressOp:
        value = a + b + cast[uint64](item.offset)
      of FieldAddressOp:
        value = a + uint64(plan.module.fields[item.target].offset) +
          cast[uint64](item.offset)
      of LoadOp:
        let address = a + cast[uint64](item.offset)
        if address == 0: error("IR interpreter null load")
        value = loadScalar(address, kind)
      of StoreOp:
        let address = a + cast[uint64](item.offset)
        if address == 0: error("IR interpreter null store")
        storeScalar(address, b, operandKind(item.arguments, 1))
      of MoveBytesOp, ClearBytesOp:
        budget.spend(int64(item.byteCount))
        if item.byteCount > 0:
          if a == 0 or (item.op == MoveBytesOp and b == 0):
            error("IR interpreter null byte operation")
          if item.op == MoveBytesOp:
            moveMem(cast[pointer](a), cast[pointer](b), int(item.byteCount))
          else: zeroMem(cast[pointer](a), int(item.byteCount))
      of SelectOp:
        value = if a != 0: b else: operand(item.arguments, 2)
      of ConvertOp:
        value = convert(a, operandKind(item.arguments, 0), kind, item.conversion)
      of CompareOp:
        let input = operandKind(item.arguments, 0)
        var matched: bool
        if input == Float32Type:
          matched = compare(cast[float32](uint32(a)),
            cast[float32](uint32(b)), item.comparison)
        elif input == Float64Type:
          matched = compare(cast[float64](a), cast[float64](b), item.comparison)
        elif signed(input):
          matched = compare(signedValue(a, input), signedValue(b, input),
            item.comparison)
        else: matched = compare(a, b, item.comparison)
        value = uint64(matched)
      of PackOp: value = (a and 0xffffffff'u64) or (b shl 32)
      of ExtractOp: value = (a shr (int(item.target) * 32)) and 0xffffffff'u64
      of VectorSumOp:
        value = scalar(AddOp, a and 0xffffffff'u64, a shr 32, Float32Type)
      of VectorAddOp, VectorSubtractOp, VectorMultiplyOp, VectorDivideOp:
        let operation = case item.op
          of VectorAddOp: AddOp
          of VectorSubtractOp: SubtractOp
          of VectorMultiplyOp: MultiplyOp
          else: DivideOp
        value = scalar(operation, a and 0xffffffff'u64,
          b and 0xffffffff'u64, Float32Type) or
          (scalar(operation, a shr 32, b shr 32, Float32Type) shl 32)
      of CallOp, HostCallOp, IndirectCallOp:
        let skip = if item.op == IndirectCallOp: 1 else: 0
        let count = int(item.arguments.count) - skip
        for i in 0 ..< count:
          frame.scratch[i] = operand(item.arguments, i + skip)
        if item.op == HostCallOp:
          if host == nil: error("IR interpreter has no host callback")
          host(context, int(item.target), frame.scratch.toOpenArray(0, count - 1),
            frame.registers.toOpenArray(destination,
              destination + int(item.results.count) - 1))
          for i in 0 ..< int(item.results.count):
            frame.registers[destination + i] = normalize(
              frame.registers[destination + i],
              function.values[destination + i].valueType)
        else:
          var target = int(item.target)
          if item.op == IndirectCallOp:
            if a == 0 or a > uint64(plan.module.functions.len):
              error("IR interpreter invalid indirect function address")
            target = int(a - 1)
            if plan.module.functions[target].signature !=
                plan.module.signatures[item.target]:
              error("IR interpreter indirect signature mismatch")
          push(target, frame.scratch.toOpenArray(0, count - 1), item.results)
        continue
      else: value = scalar(item.op, a, b, kind)
      if item.results.count > 0:
        frame.registers[destination] = value
    else:
      let terminal = data.terminator
      case terminal.kind
      of JumpTerminator: edge(frame[], int(terminal.edges.first))
      of BranchTerminator:
        edge(frame[], int(terminal.edges.first) +
          (if operand(terminal.arguments, 0) != 0: 0 else: 1))
      of ReturnTerminator:
        let destination = frame.destination
        let invoked = frame.invoke
        let count = int(terminal.arguments.count)
        for i in 0 ..< count:
          frame.scratch[i] = operand(terminal.arguments, i)
        if frames.len == 1:
          result = newSeq[uint64](count)
          for i in 0 ..< count: result[i] = frame.scratch[i]
          return
        for i in 0 ..< count:
          frames[^2].registers[int(destination.first) + i] = frame.scratch[i]
        budget.release(frame.chargedBytes)
        chargedFrames -= frame.chargedBytes
        frames.setLen(frames.len - 1)
        if invoked:
          let caller = addr frames[^1]
          let continuation = plan.module.functions[caller.function].blocks[
            caller.blockIndex].terminator
          edge(caller[], int(continuation.edges.first))
      of InvokeTerminator, InvokeHostTerminator:
        let count = int(terminal.arguments.count)
        for i in 0 ..< count:
          frame.scratch[i] = operand(terminal.arguments, i)
        if terminal.kind == InvokeTerminator:
          push(int(terminal.callee), frame.scratch.toOpenArray(0, count - 1),
            terminal.results, true)
        else:
          if host == nil: error("IR interpreter has no host callback")
          try:
            host(context, int(terminal.callee),
              frame.scratch.toOpenArray(0, count - 1),
              frame.registers.toOpenArray(int(terminal.results.first),
                int(terminal.results.first + terminal.results.count) - 1))
            for i in terminal.results.indices:
              frame.registers[i] = normalize(frame.registers[i],
                function.values[i].valueType)
            edge(frame[], int(terminal.edges.first))
          except BackendError as failure:
            frame.pendingFailure = failure.msg
            edge(frame[], int(terminal.edges.first) + 1)
      of FailTerminator:
        propagate("IR interpreter failure: " & $terminal.failure &
          " at location " & $int32(terminal.location))
      of PropagateTerminator:
        propagate(if frame.pendingFailure.len > 0: frame.pendingFailure
          else: "IR interpreter propagated failure")
      of UnreachableTerminator, UnsetTerminator:
        error("IR interpreter reached an unreachable block")

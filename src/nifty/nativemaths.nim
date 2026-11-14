## Specializes standard libm calls without changing exceptional arguments.
import nativeplans, backend/irs

type MathOperation = enum
  NoMath, SqrtMath, FloorMath, RoundMath

proc standardMath(plan: NativePlan,
    instruction: IrInstruction): MathOperation =
  ## Recognizes exact standard prototypes validated against platform libm.
  if instruction.op != HostCallOp or instruction.results.count != 1 or
      instruction.arguments.count != 1:
    return NoMath
  let index = int(instruction.target)
  if index < 0 or index >= plan.module.hosts.len:
    return NoMath
  let host = plan.module.hosts[index]
  if host.failureMode != NoFailCall or host.binding < 0 or
      int(host.binding) >= plan.hosts.len:
    return NoMath
  let native = plan.hosts[host.binding]
  if native.kind != ExternHost or native.library != "m":
    return NoMath
  var kind = Float64Type
  case native.symbol
  of "sqrt":
    result = SqrtMath
  of "sqrtf":
    kind = Float32Type
    result = SqrtMath
  of "floor", "round":
    # Other platforms retain libm until their exception flags are validated.
    when defined(macosx):
      result = if native.symbol == "floor": FloorMath else: RoundMath
    else:
      return NoMath
  else:
    return NoMath
  if host.signature.parameters != @[kind] or
      host.signature.returns != @[kind]:
    result = NoMath

proc arguments(function: var IrFunction,
    values: openArray[ValueId]): Span =
  ## Appends explicit operands without changing existing SSA references.
  result = Span(first: int32(function.operands.len), count: int32(values.len))
  function.operands.add(values)

proc value(function: var IrFunction, kind: IrType): ValueId =
  ## Reserves a fresh typed SSA result.
  result = ValueId(function.values.len)
  function.values.add(IrValue(valueType: kind))

proc emit(function: var IrFunction, blockIndex: int,
    instruction: IrInstruction) =
  ## Adds one instruction to a contiguous block body.
  if function.blocks[blockIndex].instructions.count == 0:
    function.blocks[blockIndex].instructions.first =
      int32(function.instructions.len)
  function.instructions.add(instruction)
  inc function.blocks[blockIndex].instructions.count

proc emitValue(function: var IrFunction, blockIndex: int,
    op: IrOpcode, kind: IrType, values: openArray[ValueId],
    location: LocationId, bits = 0'u64,
    comparison = EqualComparison): ValueId =
  ## Appends a typed operation with the original call's source location.
  result = function.value(kind)
  function.emit(blockIndex, IrInstruction(op: op,
    results: Span(first: int32(result), count: 1),
    arguments: function.arguments(values), bits: bits,
    comparison: comparison, conversion: BitcastConversion,
    location: location))

proc edge(function: var IrFunction, target: int,
    values: openArray[ValueId] = []): int32 =
  ## Creates one explicit successor and its parameter transfer.
  result = int32(function.edges.len)
  function.edges.add(IrEdge(target: BlockId(target),
    arguments: function.arguments(values)))

proc safeArgument(function: var IrFunction, blockIndex: int,
    argument: ValueId, kind: IrType, operation: MathOperation,
    location: LocationId): ValueId =
  ## Classifies exceptional arguments without changing floating flags.
  let
    single = kind == Float32Type
    integer = if single: UInt32Type else: UInt64Type
    bits = function.emitValue(blockIndex, ConvertOp, integer,
      [argument], location)
    infinity = function.emitValue(blockIndex, ConstantOp, integer,
      [], location, if single: 0x7f800000'u64
        else: 0x7ff0000000000000'u64)
  if operation == SqrtMath:
    let
      negativeZero = function.emitValue(blockIndex, ConstantOp, integer,
        [], location, if single: 0x80000000'u64
          else: 0x8000000000000000'u64)
      positive = function.emitValue(blockIndex, CompareOp, BoolType,
        [bits, infinity], location, comparison = LessEqualComparison)
      zero = function.emitValue(blockIndex, CompareOp, BoolType,
        [bits, negativeZero], location)
    return function.emitValue(blockIndex, OrOp, BoolType,
      [positive, zero], location)
  let
    mask = function.emitValue(blockIndex, ConstantOp, integer,
      [], location, 0x7fffffffffffffff'u64)
    magnitude = function.emitValue(blockIndex, AndOp, integer,
      [bits, mask], location)
  function.emitValue(blockIndex, CompareOp, BoolType,
    [magnitude, infinity], location, comparison = LessEqualComparison)

proc specializeNativeMaths*(plan: var NativePlan): int =
  ## Guards libm operations with exact paths for supported numeric arguments.
  for functionIndex in 0 ..< plan.module.functions.len:
    let original = plan.module.functions[functionIndex]
    var found = false
    for instruction in original.instructions:
      if plan.standardMath(instruction) != NoMath:
        found = true
        break
    if not found:
      continue
    var function = original
    function.instructions = @[]
    for blockIndex, oldBlock in original.blocks:
      var current = blockIndex
      function.blocks[current].instructions = Span()
      for index in oldBlock.instructions.indices:
        let instruction = original.instructions[index]
        let operation = plan.standardMath(instruction)
        if operation == NoMath:
          function.emit(current, instruction)
          continue
        inc result
        let
          argument = original.operands[instruction.arguments.first]
          output = instruction.results.first
          kind = original.values[output].valueType
          location = instruction.location
          safe = function.safeArgument(current, argument, kind,
            operation, location)
          fast = function.blocks.len
          fallback = fast + 1
          join = fast + 2
        # Integer classification leaves NaN exception handling to libm.
        function.blocks.add(IrBlock())
        function.blocks.add(IrBlock())
        function.blocks.add(IrBlock(parameters: instruction.results))
        let first = function.edge(fast)
        discard function.edge(fallback)
        function.blocks[current].terminator = IrTerminator(
          kind: BranchTerminator,
          arguments: function.arguments([safe]),
          edges: Span(first: first, count: 2), location: location)
        let opcode = case operation
          of SqrtMath: SqrtOp
          of FloorMath: FloorOp
          of RoundMath: RoundOp
          of NoMath: SqrtOp
        let root = function.emitValue(fast, opcode, kind,
          [argument], location)
        function.blocks[fast].terminator = IrTerminator(
          kind: JumpTerminator,
          edges: Span(first: function.edge(join, [root]), count: 1),
          location: location)
        var call = instruction
        let returned = function.value(kind)
        call.results = Span(first: int32(returned), count: 1)
        function.emit(fallback, call)
        function.blocks[fallback].terminator = IrTerminator(
          kind: JumpTerminator,
          edges: Span(first: function.edge(join, [returned]), count: 1),
          location: location)
        current = join
      function.blocks[current].terminator = oldBlock.terminator
    plan.module.functions[functionIndex] = function

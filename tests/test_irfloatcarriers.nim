import nifty/backend/[context, engine, ircarriers, irchecks, memories]

proc arguments(function: var IrFunction,
    values: openArray[ValueId]): Span =
  ## Appends an ordered test operand list.
  result = Span(first: int32(function.operands.len), count: int32(values.len))
  function.operands.add(values)

proc instruction(function: var IrFunction, op: IrOpcode,
    values: openArray[ValueId], kind = UInt64Type, bits = 0'u64,
    offset = 0'i64, count = 1): ValueId =
  ## Appends one explicitly typed operation in the current block.
  result = ValueId(function.values.len)
  let span = function.arguments(values)
  for i in 0 ..< count:
    function.values.add(IrValue(valueType: kind))
  function.instructions.add(IrInstruction(op: op, bits: bits, offset: offset,
    conversion: BitcastConversion, alignment: 1,
    results: Span(first: int32(result), count: int32(count)), arguments: span))
  inc function.blocks[^1].instructions.count

proc newBlock(function: var IrFunction,
    kinds: openArray[IrType] = []): seq[ValueId] =
  ## Defines consecutive SSA parameters at the start of a test block.
  let first = int32(function.values.len)
  for kind in kinds:
    result.add(ValueId(function.values.len))
    function.values.add(IrValue(valueType: kind))
  function.blocks.add(IrBlock(parameters:
    Span(first: first, count: int32(kinds.len)),
    instructions: Span(first: int32(function.instructions.len))))

proc function(name: string): IrFunction =
  ## Creates a storage ABI routine whose inputs contain exact float payloads.
  result = IrFunction(name: name, failureMode: NoFailCall,
    signature: IrSignature(parameters:
      @[AddressType, AddressType, AddressType, AddressType]))
  discard result.newBlock(result.signature.parameters)

proc edge(function: var IrFunction, target: int,
    values: openArray[ValueId] = []): int32 =
  ## Appends an explicit transfer into a successor's SSA parameters.
  result = int32(function.edges.len)
  function.edges.add(IrEdge(target: BlockId(target),
    arguments: function.arguments(values)))

proc jump(function: var IrFunction, target: int,
    values: openArray[ValueId] = []) =
  ## Ends the current block with an ordered parameterized jump.
  function.blocks[^1].terminator = IrTerminator(kind: JumpTerminator,
    edges: Span(first: function.edge(target, values), count: 1))

proc branch(function: var IrFunction, condition: ValueId, yes, no: int) =
  ## Ends the current block with two parameterless successors.
  let first = function.edge(yes)
  discard function.edge(no)
  function.blocks[^1].terminator = IrTerminator(kind: BranchTerminator,
    arguments: function.arguments([condition]),
    edges: Span(first: first, count: 2))

proc finish(function: var IrFunction) =
  ## Ends a storage ABI routine without a scalar return.
  function.blocks[^1].terminator.kind = ReturnTerminator

proc joined(kind: IrType, observe = false): IrFunction =
  ## Merges a binary64 payload with a literal and optionally observes its bits.
  result = function("joined")
  let
    value = result.instruction(LoadOp, [ValueId(1)], Float64Type)
    carried = result.instruction(ConvertOp, [value], kind)
    flag = result.instruction(LoadOp, [ValueId(1)], BoolType, offset = 8)
  result.branch(flag, 1, 2)
  discard result.newBlock()
  result.jump(3, [carried])
  discard result.newBlock()
  let literal = result.instruction(ConstantOp, [], kind,
    bits = 0x8000000000000000'u64)
  result.jump(3, [literal])
  let parameter = result.newBlock([kind])[0]
  var payload = parameter
  if observe:
    let zero = result.instruction(ConstantOp, [], kind)
    payload = result.instruction(AddOp, [parameter, zero], kind)
  let floating = result.instruction(ConvertOp, [payload], Float64Type)
  discard result.instruction(StoreOp, [ValueId(2), floating], count = 0)
  result.finish()

proc loop(): IrFunction =
  ## Carries a binary64 payload through a loop alongside an integer counter.
  result = function("loop")
  let
    input = result.instruction(LoadOp, [ValueId(1)], Float64Type)
    carried = result.instruction(ConvertOp, [input])
    zero = result.instruction(ConstantOp, [], Int64Type)
    one = result.instruction(ConstantOp, [], Int64Type, bits = 1)
    limit = result.instruction(ConstantOp, [], Int64Type, bits = 3)
  result.jump(1, [carried, zero])
  let parameters = result.newBlock([UInt64Type, Int64Type])
  let
    value = result.instruction(ConvertOp, [parameters[0]], Float64Type)
    next = result.instruction(AddOp, [parameters[1], one], Int64Type)
    condition = result.instruction(CompareOp, [next, limit], BoolType)
  result.instructions[^1].comparison = LessComparison
  discard result.instruction(StoreOp, [ValueId(2), value], count = 0)
  result.branch(condition, 2, 3)
  discard result.newBlock()
  let bits = result.instruction(ConvertOp, [value])
  result.jump(1, [bits, next])
  discard result.newBlock()
  result.finish()

proc execute(module: IrModule) =
  ## Emits both targets and checks exact binary payloads on the host target.
  verifyIr(module)
  for target in NativeTarget:
    let image = emitNative(module, target)
    when defined(arm64) or defined(amd64):
      let nativeTarget = when defined(arm64): Arm64Target else: Amd64Target
      if target == nativeTarget:
        var
          buffer = initCodeBuffer(image.bytes)
          ctx: RuntimeContext
        type Entry = proc(ctx, input, output, reserved: pointer)
          {.cdecl, raises: [].}
        for bits in [0'u64, 0x8000000000000000'u64, 1'u64,
            0x7ff0000000000000'u64, 0xfff0000000000000'u64,
            0x7ff8000000001234'u64, 0x7ff0000000001234'u64,
            0xfff8000000001234'u64, 0xffffffffffffffff'u64]:
          for flag in [0'u64, 1'u64]:
            for index in 0 ..< module.functions.len:
              var
                input = [bits, flag]
                output = 0'u64
              let entry = cast[Entry](cast[uint](buffer.entry()) +
                uint(image.offsets[index]))
              entry(ctx.addr, input.addr, output.addr, nil)
              let expected = if index == 3 or flag != 0: bits
                else: 0x8000000000000000'u64
              doAssert output == expected
        buffer.release()

var module = IrModule(pointerBytes: 8,
  functions: @[joined(UInt64Type), joined(Int64Type),
    joined(UInt64Type, true), loop()])
module.execute()
for index, function in module.functions.mpairs:
  let changed = function.preserveFloatParameters()
  doAssert changed == (index != 2)
verifyIr(module)
doAssert module.functions[0].values[
  module.functions[0].blocks[3].parameters.first].valueType == Float64Type
doAssert module.functions[1].values[
  module.functions[1].blocks[3].parameters.first].valueType == Float64Type
doAssert module.functions[2].values[
  module.functions[2].blocks[3].parameters.first].valueType == UInt64Type
doAssert module.functions[3].values[
  module.functions[3].blocks[1].parameters.first].valueType == Float64Type
doAssert module.functions[3].values[
  module.functions[3].blocks[1].parameters.first + 1].valueType == Int64Type
module.execute()
echo "Float64 carrier joins, loops, and exact payloads passed"

import nifty/backend/[context, engine, irchecks, iroptimizations, memories]

proc arguments(function: var IrFunction,
    values: openArray[ValueId]): Span =
  ## Appends an ordered test operand list.
  result = Span(first: int32(function.operands.len), count: int32(values.len))
  function.operands.add(values)

proc instruction(function: var IrFunction, op: IrOpcode,
    values: openArray[ValueId], kind = Int64Type, bits = 0'u64,
    offset = 0'i64, count = 1): ValueId =
  ## Appends one explicitly typed operation in the active block.
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
  ## Defines consecutive SSA parameters at a new test block.
  let first = int32(function.values.len)
  for kind in kinds:
    result.add(ValueId(function.values.len))
    function.values.add(IrValue(valueType: kind))
  function.blocks.add(IrBlock(parameters:
    Span(first: first, count: int32(kinds.len)),
    instructions: Span(first: int32(function.instructions.len))))

proc function(name: string): IrFunction =
  ## Creates a storage ABI routine with exact payload inputs and outputs.
  result = IrFunction(name: name, failureMode: NoFailCall,
    signature: IrSignature(parameters:
      @[AddressType, AddressType, AddressType, AddressType]))
  discard result.newBlock(result.signature.parameters)

proc edge(function: var IrFunction, target: int,
    values: openArray[ValueId] = []): int32 =
  ## Appends a transfer into a successor's SSA parameters.
  result = int32(function.edges.len)
  function.edges.add(IrEdge(target: BlockId(target),
    arguments: function.arguments(values)))

proc jump(function: var IrFunction, target: int,
    values: openArray[ValueId] = []) =
  ## Ends the active block with an ordered parameterized jump.
  function.blocks[^1].terminator = IrTerminator(kind: JumpTerminator,
    edges: Span(first: function.edge(target, values), count: 1))

proc branch(function: var IrFunction, condition: ValueId, yes, no: int,
    yesValues: openArray[ValueId] = [], noValues: openArray[ValueId] = []) =
  ## Ends the active block with two explicit parameterized successors.
  let first = function.edge(yes, yesValues)
  discard function.edge(no, noValues)
  function.blocks[^1].terminator = IrTerminator(kind: BranchTerminator,
    arguments: function.arguments([condition]),
    edges: Span(first: first, count: 2))

proc finish(function: var IrFunction, value: ValueId) =
  ## Stores one exact payload before returning from a storage ABI routine.
  discard function.instruction(StoreOp, [ValueId(2), value], count = 0)
  function.blocks[^1].terminator.kind = ReturnTerminator

proc selected(function: IrFunction): int =
  ## Counts live typed choices after optimization and CFG cleanup.
  for data in function.blocks:
    for index in data.instructions.indices:
      if function.instructions[index].op == SelectOp:
        inc result

proc payloads(kind: IrType, parameters: bool): IrFunction =
  ## Merges exact floating payloads with optional parameterized diamond arms.
  result = function("payloads")
  let
    condition = result.instruction(LoadOp, [ValueId(1)], BoolType)
    yes = result.instruction(LoadOp, [ValueId(1)], kind, offset = 8)
    no = result.instruction(LoadOp, [ValueId(1)], kind, offset = 16)
  if parameters:
    result.branch(condition, 1, 2, [yes], [no])
    let left = result.newBlock([kind])[0]
    result.jump(3, [left])
    let right = result.newBlock([kind])[0]
    result.jump(3, [right])
    let joined = result.newBlock([kind])[0]
    result.finish(joined)
  else:
    result.branch(condition, 1, 1, [yes], [no])
    let joined = result.newBlock([kind])[0]
    result.finish(joined)

var integer = function("integer")
let
  integerCondition = integer.instruction(LoadOp, [ValueId(1)], BoolType)
  integerInput = integer.instruction(LoadOp, [ValueId(1)], offset = 8)
integer.branch(integerCondition, 1, 2)
discard integer.newBlock()
let
  bias = integer.instruction(ConstantOp, [], bits = 3)
  sum = integer.instruction(AddOp, [integerInput, bias])
integer.jump(3, [sum])
discard integer.newBlock()
let
  factor = integer.instruction(ConstantOp, [], bits = 2)
  product = integer.instruction(MultiplyOp, [integerInput, factor])
integer.jump(3, [product])
let integerResult = integer.newBlock([Int64Type])[0]
integer.finish(integerResult)

var calls: int64
proc observe(value: int64): int64 {.cdecl, raises: [].} =
  ## Records whether an originally conditional host call was executed.
  calls += value
  value

proc guarded(op: IrOpcode): IrFunction =
  ## Retains an unsafe operation behind its original conditional arm.
  result = function("guarded" & $op)
  let
    condition = result.instruction(LoadOp, [ValueId(1)], BoolType)
    seven = result.instruction(ConstantOp, [], bits = 7)
    zero = result.instruction(ConstantOp, [], bits = 0)
    nilAddress = result.instruction(ConstantOp, [], AddressType)
  result.branch(condition, 1, 2)
  discard result.newBlock()
  result.jump(3, [seven])
  discard result.newBlock()
  let value = case op
    of HostCallOp:
      result.instruction(HostCallOp, [seven])
    of LoadOp:
      result.instruction(LoadOp, [nilAddress])
    of DivideOp:
      result.instruction(DivideOp, [seven, zero])
    else:
      let floating = result.instruction(ConstantOp, [], Float64Type,
        bits = 0x7ff8000000001234'u64)
      let converted = result.instruction(ConvertOp, [floating])
      result.instructions[^1].conversion = FloatIntegerConversion
      converted
  result.jump(3, [value])
  let joined = result.newBlock([Int64Type])[0]
  result.finish(joined)

proc execute(module: IrModule, optimized: bool) =
  ## Emits both targets and executes exact payload and speculation checks.
  verifyIr(module)
  for target in NativeTarget:
    let image = emitNative(module, target)
    when defined(arm64) or defined(amd64):
      let nativeTarget = when defined(arm64): Arm64Target else: Amd64Target
      if target == nativeTarget:
        var
          buffer = initCodeBuffer(image.bytes)
          hosts = [cast[pointer](observe)]
          ctx = RuntimeContext(hosts: hosts.addr)
        type Entry = proc(ctx, input, output, reserved: pointer)
          {.cdecl, raises: [].}
        proc run(index: int, condition, yes, no: uint64): uint64 =
          ## Calls a single routine with three explicitly initialized inputs.
          var input = [condition, yes, no]
          let entry = cast[Entry](cast[uint](buffer.entry()) +
            uint(image.offsets[index]))
          entry(ctx.addr, input.addr, result.addr, nil)
        for flag in [0'u64, 1'u64]:
          doAssert run(0, flag, 10, 0) == (if flag == 1: 13'u64 else: 20'u64)
          for index in 1 .. 4:
            let single = index in [1, 2]
            for bits in [0'u64, 0x8000000000000000'u64,
                0x7fc01234'u64, 0x7f801234'u64,
                0x7ff8000000001234'u64, 0x7ff0000000001234'u64,
                0xffffffffffffffff'u64]:
              let
                yes = if single: bits and 0xffffffff'u64 else: bits
                no = if single: 0x80000000'u64 else: 0x8000000000000000'u64
              doAssert run(index, flag, yes, no) ==
                (if flag == 1: yes else: no)
        calls = 0
        doAssert run(5, 1, 0, 0) == 7
        doAssert calls == 0
        doAssert run(5, 0, 0, 0) == 7
        doAssert calls == 7
        for index in 6 .. 8:
          doAssert run(index, 1, 0, 0) == 7
        buffer.release()
  if optimized:
    doAssert module.functions[0].selected() > 0
    for index in 1 .. 4:
      doAssert module.functions[index].selected() > 0
    for index in 5 .. 8:
      doAssert module.functions[index].selected() == 0

var module = IrModule(pointerBytes: 8, functions: @[
  integer, payloads(Float32Type, false), payloads(Float32Type, true),
  payloads(Float64Type, false), payloads(Float64Type, true),
  guarded(HostCallOp), guarded(LoadOp), guarded(DivideOp), guarded(ConvertOp)],
  hosts: @[IrHost(name: "observe", failureMode: NoFailCall,
    signature: IrSignature(parameters: @[Int64Type], returns: @[Int64Type]))])
module.execute(false)
optimizeIr(module, DefaultIrOptimizations + {SelectIrValues})
module.execute(true)
echo "IR select predication and exact payloads passed"

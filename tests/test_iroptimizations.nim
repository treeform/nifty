import nifty/backend/[irs, irchecks, iroptimizations, irreturns, context,
  irmachines, iramds, memories]

proc routine(name: string): IrFunction =
  ## Creates an externally callable test routine with the native entry ABI.
  result = IrFunction(name: name, failureMode: NoFailCall,
    signature: IrSignature(parameters: @[
      AddressType, AddressType, AddressType, AddressType]))
  for i in 0 ..< 4:
    result.values.add(IrValue(valueType: AddressType))
  result.blocks.add(IrBlock(parameters: Span(count: 4)))

proc emit(function: var IrFunction, op: IrOpcode,
    arguments: openArray[ValueId], kind = Int64Type, bits = 0'u64,
    target = 0'i32, offset = 0'i64, storage = 0'i32): ValueId =
  ## Appends one typed instruction to the last block.
  result = NoValue
  var item = IrInstruction(op: op, bits: bits, target: target,
    offset: offset, alignment: 1, location: NoLocation,
    arguments: Span(first: int32(function.operands.len),
      count: int32(arguments.len)))
  function.operands.add(arguments)
  if op notin {StoreOp, MoveBytesOp, ClearBytesOp, HostCallOp, CallOp}:
    result = ValueId(function.values.len)
    function.values.add(IrValue(valueType: kind, storage: storage))
    item.results = Span(first: int32(result), count: 1)
  function.instructions.add(item)
  inc function.blocks[^1].instructions.count

proc finish(function: var IrFunction) =
  ## Returns normally from a test function with no SSA return values.
  function.blocks[^1].terminator = IrTerminator(kind: ReturnTerminator,
    location: NoLocation)

proc nextBlock(function: var IrFunction) =
  ## Starts a block without parameters at the current instruction boundary.
  function.blocks.add(IrBlock(instructions:
    Span(first: int32(function.instructions.len))))

proc jump(function: var IrFunction, target: int32) =
  ## Ends the current block with an unconditional forward or backward edge.
  function.blocks[^1].terminator = IrTerminator(kind: JumpTerminator,
    edges: Span(first: int32(function.edges.len), count: 1))
  function.edges.add(IrEdge(target: BlockId(target)))

proc branch(function: var IrFunction, condition: ValueId,
    yes, no: int32) =
  ## Ends the current block with two explicitly ordered edges.
  function.blocks[^1].terminator = IrTerminator(kind: BranchTerminator,
    arguments: Span(first: int32(function.operands.len), count: 1),
    edges: Span(first: int32(function.edges.len), count: 2))
  function.operands.add(condition)
  function.edges.add([IrEdge(target: BlockId(yes)),
    IrEdge(target: BlockId(no))])

proc count(module: IrModule, op: IrOpcode): int =
  ## Counts active instructions after graph rebuilding.
  for function in module.functions:
    for item in function.instructions:
      if item.op == op:
        inc result

proc execute(module: IrModule, arguments, returned: pointer,
    bindings: pointer = nil) =
  ## Checks both emitters and executes the native target's first routine.
  verifyIr(module)
  let
    arm = emitArm64Ir(module, MaxNativeBytes)
    amd = emitAmd64Ir(module, MaxNativeBytes)
  doAssert arm.words.len > 0 and amd.bytes.len > 0
  doAssert arm.offsets.len == module.functions.len
  doAssert amd.offsets.len == module.functions.len
  when defined(arm64) or defined(amd64):
    var bytes: seq[byte]
    when defined(arm64):
      for word in arm.words:
        for shift in [0, 8, 16, 24]:
          bytes.add(byte((word shr shift) and 255))
      let offset = arm.offsets[0]
    else:
      bytes = amd.bytes
      let offset = amd.offsets[0]
    var
      buffer = initCodeBuffer(bytes)
      ctx = RuntimeContext(hosts: bindings)
    type Entry = proc(ctx, arguments, returned, reserved: pointer)
      {.cdecl, raises: [].}
    let entry = cast[Entry](cast[uint](buffer.entry()) + uint(offset))
    entry(ctx.addr, arguments, returned, nil)
    buffer.release()

proc mutate(address: ptr int64) {.cdecl, raises: [].} =
  ## Changes memory through an explicitly unknown host binding.
  address[] = 91

echo "Testing constants and private scalar slots"
block:
  var function = routine("constants")
  function.slots.add(IrSlot(byteCount: 8, alignment: 8))
  let
    address = function.emit(SlotAddressOp, [], AddressType)
    a = function.emit(ConstantOp, [], bits = 6)
    b = function.emit(ConstantOp, [], bits = 7)
    value = function.emit(MultiplyOp, [a, b])
  discard function.emit(StoreOp, [address, value])
  let loaded = function.emit(LoadOp, [address])
  discard function.emit(StoreOp, [ValueId(2), loaded])
  function.finish()
  var module = IrModule(pointerBytes: 8, functions: @[function])
  optimizeIr(module)
  doAssert module.count(MultiplyOp) == 0
  doAssert module.count(LoadOp) == 0
  doAssert module.functions[0].slots.len == 0
  var answer = 0'i64
  execute(module, nil, answer.addr)
  doAssert answer == 42

echo "Testing immediate offsets in aggregate scalarization"
block:
  var function = routine("interiorFields")
  function.slots.add(IrSlot(byteCount: 24, alignment: 8))
  let
    root = function.emit(SlotAddressOp, [], AddressType)
    zero = function.emit(ConstantOp, [])
    four = function.emit(ConstantOp, [], bits = 4)
    second = function.emit(OffsetAddressOp, [root, four],
      AddressType, offset = 4)
    third = function.emit(OffsetAddressOp, [root, zero],
      AddressType, offset = 16)
    secondAgain = function.emit(OffsetAddressOp, [third, zero],
      AddressType, offset = -8)
    a = function.emit(ConstantOp, [], bits = 1)
    b = function.emit(ConstantOp, [], bits = 22)
    c = function.emit(ConstantOp, [], bits = 300)
  discard function.emit(StoreOp, [root, a])
  discard function.emit(StoreOp, [second, b])
  discard function.emit(StoreOp, [third, c])
  let
    loadedA = function.emit(LoadOp, [root])
    loadedB = function.emit(LoadOp, [secondAgain])
    loadedC = function.emit(LoadOp, [third])
    partial = function.emit(AddOp, [loadedA, loadedB])
    sum = function.emit(AddOp, [partial, loadedC])
  discard function.emit(StoreOp, [ValueId(2), sum])
  function.finish()
  var module = IrModule(pointerBytes: 8, functions: @[function])
  optimizeIr(module)
  var answer = 0'i64
  execute(module, nil, answer.addr)
  doAssert answer == 323

echo "Testing scalar promotion through loop backedges"
block:
  var function = routine("sum")
  function.slots = @[IrSlot(byteCount: 8, alignment: 8),
    IrSlot(byteCount: 8, alignment: 8)]
  let
    counter = function.emit(SlotAddressOp, [], AddressType)
    accumulator = function.emit(SlotAddressOp, [], AddressType, target = 1)
    zero = function.emit(ConstantOp, [], bits = 0)
    one = function.emit(ConstantOp, [], bits = 1)
    limit = function.emit(LoadOp, [ValueId(1)])
  discard function.emit(StoreOp, [counter, one])
  discard function.emit(StoreOp, [accumulator, zero])
  function.jump(1)
  function.nextBlock()
  let
    index = function.emit(LoadOp, [counter])
    condition = function.emit(CompareOp, [index, limit], BoolType)
  function.instructions[^1].comparison = LessEqualComparison
  function.branch(condition, 2, 3)
  function.nextBlock()
  let
    previous = function.emit(LoadOp, [accumulator])
    sum = function.emit(AddOp, [previous, index])
    next = function.emit(AddOp, [index, one])
  discard function.emit(StoreOp, [counter, next])
  discard function.emit(StoreOp, [accumulator, sum])
  function.jump(1)
  function.nextBlock()
  let value = function.emit(LoadOp, [accumulator])
  discard function.emit(StoreOp, [ValueId(2), value])
  function.finish()
  var module = IrModule(pointerBytes: 8, functions: @[function])
  optimizeIr(module)
  doAssert module.functions[0].slots.len == 0
  doAssert module.count(LoadOp) == 1
  var input = 10'i64
  var answer = 0'i64
  execute(module, input.addr, answer.addr)
  doAssert answer == 55
  input = 0
  execute(module, input.addr, answer.addr)
  doAssert answer == 0

echo "Testing host barriers independent of NoFailCall annotations"
block:
  var function = routine("barrier")
  let initial = function.emit(ConstantOp, [], bits = 12)
  discard function.emit(StoreOp, [ValueId(1), initial])
  discard function.emit(HostCallOp, [ValueId(1)])
  let loaded = function.emit(LoadOp, [ValueId(1)])
  discard function.emit(StoreOp, [ValueId(2), loaded])
  function.finish()
  var module = IrModule(pointerBytes: 8, functions: @[function],
    hosts: @[IrHost(name: "mutate", binding: 0, failureMode: NoFailCall,
      signature: IrSignature(parameters: @[AddressType]))])
  optimizeIr(module)
  doAssert module.count(HostCallOp) == 1
  doAssert module.count(LoadOp) == 1
  var
    input = 0'i64
    answer = 0'i64
    hosts = [cast[pointer](mutate)]
  execute(module, input.addr, answer.addr, hosts.addr)
  doAssert answer == 91 and input == 91

echo "Testing volatile, unchecked reads and potentially trapping work"
block:
  var function = routine("observable")
  discard function.emit(LoadOp, [ValueId(1)])
  discard function.emit(LoadOp, [ValueId(1)])
  function.instructions[^1].volatile = true
  let
    dividend = function.emit(LoadOp, [ValueId(1)])
    divisor = function.emit(LoadOp, [ValueId(1)], offset = 8)
  discard function.emit(DivideOp, [dividend, divisor])
  discard function.emit(RemainderOp, [dividend, divisor])
  let floating = function.emit(LoadOp, [ValueId(1)], Float64Type, offset = 16)
  discard function.emit(ConvertOp, [floating])
  function.instructions[^1].conversion = FloatIntegerConversion
  function.finish()
  var module = IrModule(pointerBytes: 8, functions: @[function])
  optimizeIr(module, {RemoveIrDeadValues})
  doAssert module.count(LoadOp) == 5
  doAssert module.count(DivideOp) == 1
  doAssert module.count(RemainderOp) == 1
  doAssert module.count(ConvertOp) == 1

echo "Testing floating point evaluation order and signed zero"
block:
  var function = routine("floatOrder")
  let
    a = function.emit(LoadOp, [ValueId(1)], Float32Type)
    b = function.emit(LoadOp, [ValueId(1)], Float32Type, offset = 4)
    c = function.emit(LoadOp, [ValueId(1)], Float32Type, offset = 8)
    first = function.emit(AddOp, [a, b], Float32Type)
    second = function.emit(AddOp, [first, c], Float32Type)
  discard function.emit(StoreOp, [ValueId(2), second])
  function.finish()
  var module = IrModule(pointerBytes: 8, functions: @[function])
  optimizeIr(module)
  doAssert module.count(AddOp) == 2
  var
    inputs = [1.0e20'f, -1.0e20'f, 3.25'f]
    answer = 0.0'f
  execute(module, inputs.addr, answer.addr)
  doAssert answer == 3.25'f
  inputs = [cast[float32](0x80000000'u32),
    cast[float32](0x80000000'u32), cast[float32](0x80000000'u32)]
  execute(module, inputs.addr, answer.addr)
  doAssert cast[uint32](answer) == 0x80000000'u32

echo "Testing bounded large moves and overlapping sources"
block:
  var function = routine("largeMove")
  discard function.emit(MoveBytesOp, [ValueId(2), ValueId(1)])
  function.instructions[^1].byteCount = 4096
  function.finish()
  var module = IrModule(pointerBytes: 8, functions: @[function])
  optimizeIr(module)
  doAssert module.count(MoveBytesOp) == 1
  doAssert module.functions[0].instructions.len == 1
  var data, expected: array[8192, byte]
  for i in 0 ..< data.len:
    data[i] = byte(i mod 251)
  expected = data
  moveMem(expected[17].addr, expected[0].addr, 4096)
  execute(module, data[0].addr, data[17].addr)
  doAssert data == expected
  moveMem(expected[0].addr, expected[17].addr, 4096)
  execute(module, data[17].addr, data[0].addr)
  doAssert data == expected

proc returnedModule(): IrModule =
  ## Builds a private scalar result routine and an externally callable caller.
  result.pointerBytes = 8
  result.storageTypes.add(IrStorage(kind: ScalarStorage,
    scalar: Int64Type, byteCount: 8, alignment: 8))
  var caller = routine("caller")
  caller.slots.add(IrSlot(byteCount: 8, alignment: 8, storage: 1))
  let destination = caller.emit(SlotAddressOp, [], AddressType, storage = 1)
  discard caller.emit(CallOp,
    [ValueId(0), ValueId(1), destination, ValueId(3)], target = 1)
  let value = caller.emit(LoadOp, [destination])
  discard caller.emit(StoreOp, [ValueId(2), value])
  caller.finish()
  var callee = routine("privateResult")
  callee.directOnly = true
  callee.signature.parameterStorage = @[0'i32, 0, 1, 0]
  callee.signature.passing = @[
    DirectPassing, DirectPassing, MutablePassing, DirectPassing]
  callee.values[2].storage = 1
  let output = callee.emit(ConstantOp, [], bits = 1234)
  discard callee.emit(StoreOp, [ValueId(2), output])
  callee.finish()
  result.functions = @[caller, callee]

echo "Testing complete private return promotion and stable entries"
block:
  var module = returnedModule()
  verifyIr(module)
  doAssert promoteReturns(module)
  verifyIr(module)
  doAssert module.functions.len == 2
  doAssert module.functions[0].signature.parameters.len == 4
  doAssert module.functions[1].signature.returns == @[Int64Type]
  optimizeIr(module)
  var answer = 0'i64
  execute(module, nil, answer.addr)
  doAssert answer == 1234

echo "Testing NoFailCall does not establish complete result stores"
block:
  var module = returnedModule()
  module.functions[1].instructions.setLen(1)
  module.functions[1].blocks[0].instructions.count = 1
  doAssert not promoteReturns(module)
  doAssert module.functions[1].signature.returns.len == 0
block:
  var module = returnedModule()
  module.hosts.add(IrHost(name: "observer", binding: 0,
    failureMode: NoFailCall, signature: IrSignature()))
  discard module.functions[1].emit(HostCallOp, [])
  doAssert not promoteReturns(module)
  doAssert module.functions[1].signature.returns.len == 0

echo "Generic IR optimization regressions passed"

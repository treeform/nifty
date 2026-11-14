import std/strutils
import nifty/backend/[common, context, irs, irinterpreters]

proc operands(function: var IrFunction, values: openArray[ValueId]): Span =
  ## Appends an ordered operand list.
  result = Span(first: int32(function.operands.len), count: int32(values.len))
  function.operands.add(values)

proc blockParameters(function: var IrFunction,
    kinds: openArray[IrType]): seq[ValueId] =
  ## Starts a block with consecutive SSA parameters.
  let first = int32(function.values.len)
  for kind in kinds:
    result.add(ValueId(function.values.len))
    function.values.add(IrValue(valueType: kind))
  function.blocks.add(IrBlock(parameters:
    Span(first: first, count: int32(kinds.len)),
    instructions: Span(first: int32(function.instructions.len))))

proc routine(parameters, returns: openArray[IrType]): IrFunction =
  ## Creates a direct test routine with an explicit scalar ABI.
  result = IrFunction(name: "conformance", failureMode: NoFailCall,
    signature: IrSignature(parameters: @parameters, returns: @returns))
  discard result.blockParameters(parameters)

proc emit(function: var IrFunction, op: IrOpcode,
    inputs: openArray[ValueId], kind: IrType, bits = 0'u64,
    target = 0'i32, count = 1): ValueId =
  ## Appends a typed instruction without constant folding.
  result = ValueId(function.values.len)
  let arguments = function.operands(inputs)
  for i in 0 ..< count:
    function.values.add(IrValue(valueType: kind))
  function.instructions.add(IrInstruction(op: op, arguments: arguments,
    results: Span(first: int32(result), count: int32(count)), bits: bits,
    target: target, alignment: 1))
  inc function.blocks[^1].instructions.count

proc finish(function: var IrFunction, values: openArray[ValueId]) =
  ## Returns exact value payloads from the active block.
  function.blocks[^1].terminator = IrTerminator(kind: ReturnTerminator,
    arguments: function.operands(values))

proc run(function: IrFunction, arguments: openArray[uint64]): seq[uint64] =
  ## Prepares verified IR and runs it with raw register payloads.
  var plan = prepareInterpreter(IrModule(pointerBytes: 8,
    functions: @[function]))
  interpret(plan.addr, 0, arguments, nil)

proc binary(op: IrOpcode, kind: IrType, a, b: uint64): uint64 =
  ## Evaluates one operation on runtime inputs.
  var function = routine([kind, kind], [kind])
  let value = function.emit(op, [ValueId(0), ValueId(1)], kind)
  function.finish([value])
  function.run([a, b])[0]

proc conversion(source, destination: IrType, mode: IrConversion,
    bits: uint64): uint64 =
  ## Evaluates one explicit conversion on a runtime input.
  var function = routine([source], [destination])
  let value = function.emit(ConvertOp, [ValueId(0)], destination)
  function.instructions[^1].conversion = mode
  function.finish([value])
  function.run([bits])[0]


proc comparison(kind: IrType, mode: IrComparison, a, b: uint64): bool =
  ## Compares raw payloads using the operand signedness.
  var function = routine([kind, kind], [BoolType])
  let value = function.emit(CompareOp, [ValueId(0), ValueId(1)], BoolType)
  function.instructions[^1].comparison = mode
  function.finish([value])
  function.run([a, b])[0] != 0

for kind in [Int8Type, UInt8Type]:
  doAssert binary(AddOp, kind, 255, 2) == 1
  doAssert binary(SubtractOp, kind, 0, 1) == 255
  doAssert binary(MultiplyOp, kind, 129, 2) == 2
for kind in [Int16Type, UInt16Type]:
  doAssert binary(AddOp, kind, 65535, 2) == 1
for kind in [Int32Type, UInt32Type]:
  doAssert binary(AddOp, kind, 0xffffffff'u64, 2) == 1
doAssert binary(AddOp, UInt64Type, high(uint64), 2) == 1
doAssert binary(ArithmeticRightOp, Int8Type, 128, 7) == 255
doAssert binary(ShiftRightOp, UInt64Type, high(uint64), 63) == 1
doAssert comparison(Int64Type, LessComparison,
  0x8000000000000000'u64, 0x7fffffffffffffff'u64)
doAssert comparison(UInt64Type, GreaterComparison,
  high(uint64), 0x7fffffffffffffff'u64)
doAssert comparison(Int8Type, LessComparison, 255, 0)
doAssert comparison(UInt8Type, GreaterComparison, 255, 0)
doAssert binary(DivideOp, UInt64Type, high(uint64), 3) ==
  6148914691236517205'u64
doAssert binary(RemainderOp, UInt64Type, high(uint64), 7) == 1
doAssert binary(DivideOp, Int8Type, 128, 255) == 128
doAssert binary(RemainderOp, Int8Type, 128, 255) == 0
doAssert binary(DivideOp, Int64Type, 0x8000000000000000'u64,
  high(uint64)) == 0x8000000000000000'u64
doAssert binary(RemainderOp, Int64Type, 0x8000000000000000'u64,
  high(uint64)) == 0
doAssert conversion(Int8Type, Int64Type, SignExtendConversion, 128) ==
  0xffffffffffffff80'u64
doAssert conversion(UInt8Type, UInt64Type, ZeroExtendConversion, 255) == 255
doAssert conversion(UInt64Type, UInt16Type, TruncateConversion,
  0x123456789abcdef0'u64) == 0xdef0
# The halfway integer rounds to the even binary32 significand.
doAssert conversion(UInt64Type, Float32Type, IntegerFloatConversion,
  16777217) == 0x4b800000'u64
# Converting through binary64 would round this to the wrong binary32 tie.
doAssert conversion(UInt64Type, Float32Type, IntegerFloatConversion,
  0x8000008000000001'u64) == 0x5f000001'u64
doAssert conversion(Float64Type, Int8Type, FloatIntegerConversion,
  cast[uint64](-128.5)) == 128
doAssert conversion(Float64Type, UInt8Type, FloatIntegerConversion,
  cast[uint64](-0.5)) == 0
doAssert conversion(Float64Type, Float32Type, FloatWidthConversion,
  cast[uint64](16777217.0)) == 0x4b800000'u64
doAssert binary(AddOp, Float32Type, 0x4b800000, 0x3f800000) == 0x4b800000

block:
  var function = routine([Float64Type, Float64Type], [BoolType])
  let value = function.emit(CompareOp, [ValueId(0), ValueId(1)], BoolType)
  function.finish([value])
  doAssert function.run([0x7ff8000000001234'u64, 0'u64]) == @[0'u64]
  doAssert function.run([0x8000000000000000'u64, 0'u64]) == @[1'u64]
  function.instructions[0].comparison = NotEqualComparison
  doAssert function.run([0x7ff8000000001234'u64, 0'u64]) == @[1'u64]

block:
  # Select preserves payloads even for NaNs and negative zero.
  var function = routine([BoolType, Float64Type, Float64Type], [Float64Type])
  let value = function.emit(SelectOp,
    [ValueId(0), ValueId(1), ValueId(2)], Float64Type)
  function.finish([value])
  doAssert function.run([1'u64, 0x7ff8000000001234'u64, 0]) ==
    @[0x7ff8000000001234'u64]
  doAssert function.run([0'u64, 0, 0x8000000000000000'u64]) ==
    @[0x8000000000000000'u64]

block:
  # A back edge swaps two live parameters simultaneously.
  var function = routine([UInt64Type, UInt64Type], [UInt64Type])
  let zero = function.emit(ConstantOp, [], UInt64Type)
  function.edges.add(IrEdge(target: BlockId(1),
    arguments: function.operands([ValueId(0), ValueId(1), zero])))
  function.blocks[^1].terminator = IrTerminator(kind: JumpTerminator,
    edges: Span(first: 0, count: 1))
  let parameters = function.blockParameters(
    [UInt64Type, UInt64Type, UInt64Type])
  let
    one = function.emit(ConstantOp, [], UInt64Type, bits = 1)
    next = function.emit(AddOp, [parameters[2], one], UInt64Type)
    limit = function.emit(ConstantOp, [], UInt64Type, bits = 3)
    more = function.emit(CompareOp, [next, limit], BoolType)
  function.instructions[^1].comparison = LessComparison
  function.edges.add(IrEdge(target: BlockId(1),
    arguments: function.operands([parameters[1], parameters[0], next])))
  function.edges.add(IrEdge(target: BlockId(2),
    arguments: function.operands([parameters[0]])))
  function.blocks[^1].terminator = IrTerminator(kind: BranchTerminator,
    arguments: function.operands([more]), edges: Span(first: 1, count: 2))
  let output = function.blockParameters([UInt64Type])[0]
  function.finish([output])
  doAssert function.run([17'u64, 29]) == @[17'u64]

block:
  # Two independently rounded lanes are packed and reduced.
  var function = routine([Float32Type, Float32Type], [Float32Type])
  let
    packed = function.emit(PackOp, [ValueId(0), ValueId(1)], Float32x2Type)
    squared = function.emit(VectorMultiplyOp, [packed, packed], Float32x2Type)
    value = function.emit(VectorSumOp, [squared], Float32Type)
  function.finish([value])
  doAssert function.run([0x40400000'u64, 0x40800000]) == @[0x41c80000'u64]

block:
  # A large slot must remain aligned after a preceding odd-sized slot.
  var function = routine([], [UInt64Type])
  function.slots = @[IrSlot(byteCount: 3, alignment: 1),
    IrSlot(byteCount: 64, alignment: 64)]
  let
    address = function.emit(SlotAddressOp, [], AddressType, target = 1)
    bits = function.emit(ConvertOp, [address], UInt64Type)
    mask = function.emit(ConstantOp, [], UInt64Type, bits = 63)
    remainder = function.emit(AndOp, [bits, mask], UInt64Type)
  function.instructions[1].conversion = BitcastConversion
  function.finish([remainder])
  doAssert function.run([]) == @[0'u64]

block:
  # Forward overlap must use memmove semantics on valid local storage.
  var function = routine([AddressType], [UInt64Type])
  let
    offset = function.emit(ConstantOp, [], UInt64Type, bits = 1)
    destination = function.emit(OffsetAddressOp,
      [ValueId(0), offset], AddressType)
  discard function.emit(MoveBytesOp, [destination, ValueId(0)], UInt64Type,
    count = 0)
  function.instructions[^1].byteCount = 7
  let value = function.emit(LoadOp, [ValueId(0)], UInt64Type)
  function.finish([value])
  var bytes = [1'u8, 2, 3, 4, 5, 6, 7, 8]
  discard function.run([cast[uint64](bytes.addr)])
  doAssert bytes == [1'u8, 1, 2, 3, 4, 5, 6, 7]

proc host(context: pointer, id: int, arguments: openArray[uint64],
    returns: var openArray[uint64]) {.nimcall, gcsafe.} =
  ## Records the host index and uses the caller context in a result.
  let calls = cast[ptr int](context)
  inc calls[]
  doAssert id == 0
  doAssert arguments.len == 2 and returns.len == 1
  returns[0] = arguments[0] * 10 + arguments[1]

block:
  var function = routine([UInt64Type, UInt64Type], [UInt64Type])
  let value = function.emit(HostCallOp,
    [ValueId(0), ValueId(1)], UInt64Type)
  function.finish([value])
  var
    plan = prepareInterpreter(IrModule(pointerBytes: 8,
      functions: @[function], hosts: @[IrHost(name: "callback", binding: 73,
      failureMode: NoFailCall, signature: function.signature)]))
    calls = 0
  doAssert interpret(plan.addr, 0, [4'u64, 2], host, calls.addr) == @[42'u64]
  doAssert calls == 1

block:
  # Private direct calls retain every return lane and its order.
  var callee = routine([Float64Type, Float64Type],
    [Float64Type, Float64Type])
  callee.directOnly = true
  callee.finish([ValueId(1), ValueId(0)])
  var caller = routine([Float64Type, Float64Type], [Float64Type])
  let
    pair = caller.emit(CallOp, [ValueId(0), ValueId(1)], Float64Type,
      target = 1, count = 2)
    difference = caller.emit(SubtractOp,
      [pair, ValueId(int32(pair) + 1)], Float64Type)
  caller.finish([difference])
  var plan = prepareInterpreter(IrModule(pointerBytes: 8,
    functions: @[caller, callee]))
  doAssert interpret(plan.addr, 0,
    [cast[uint64](2.0), cast[uint64](9.0)], nil) == @[cast[uint64](7.0)]

block:
  # An indirect call resolves a function token using the declared signature.
  var callee = routine([UInt64Type, UInt64Type], [UInt64Type])
  let difference = callee.emit(SubtractOp,
    [ValueId(0), ValueId(1)], UInt64Type)
  callee.finish([difference])
  var caller = routine([AddressType, UInt64Type, UInt64Type], [UInt64Type])
  let value = caller.emit(IndirectCallOp,
    [ValueId(0), ValueId(1), ValueId(2)], UInt64Type)
  caller.finish([value])
  var plan = prepareInterpreter(IrModule(pointerBytes: 8,
    functions: @[caller, callee], signatures: @[callee.signature]))
  doAssert interpret(plan.addr, 0,
    [interpreterFunctionAddress(1), 90'u64, 48], nil) == @[42'u64]

block:
  # Invalid pooled indices fail at preparation rather than during execution.
  var function = routine([], [UInt64Type])
  let value = function.emit(ConstantOp, [], UInt64Type)
  function.finish([value])
  function.blocks[0].terminator.arguments.first = high(int32)
  var rejected = false
  try:
    discard prepareInterpreter(IrModule(pointerBytes: 8,
      functions: @[function]))
  except BackendError:
    rejected = true
  doAssert rejected

block:
  var function = routine([], [UInt64Type])
  let address = function.emit(SlotAddressOp, [], AddressType, target = 7)
  let value = function.emit(ConvertOp, [address], UInt64Type)
  function.instructions[^1].conversion = BitcastConversion
  function.finish([value])
  var rejected = false
  try:
    discard prepareInterpreter(IrModule(pointerBytes: 8,
      functions: @[function]))
  except BackendError:
    rejected = true
  doAssert rejected

block:
  var function = routine([Float32Type, Float32Type], [Float32Type])
  let
    vector = function.emit(PackOp, [ValueId(0), ValueId(1)], Float32x2Type)
    lane = function.emit(ExtractOp, [vector], Float32Type, target = 2)
  function.finish([lane])
  var rejected = false
  try:
    discard prepareInterpreter(IrModule(pointerBytes: 8,
      functions: @[function]))
  except BackendError:
    rejected = true
  doAssert rejected

proc invoke(function: var IrFunction, kind: IrTerminatorKind,
    callee: int32) =
  ## Invokes a zero-argument callee with success and failure successors.
  let first = int32(function.edges.len)
  function.edges.add(IrEdge(target: BlockId(1)))
  function.edges.add(IrEdge(target: BlockId(2)))
  function.blocks[^1].terminator = IrTerminator(kind: kind, callee: callee,
    edges: Span(first: first, count: 2))

proc recovery(kind: IrTerminatorKind, callee: int32): IrFunction =
  ## Distinguishes normal completion from the explicit failure continuation.
  result = routine([], [UInt64Type])
  result.invoke(kind, callee)
  discard result.blockParameters([])
  let success = result.emit(ConstantOp, [], UInt64Type, bits = 10)
  result.finish([success])
  discard result.blockParameters([])
  let failure = result.emit(ConstantOp, [], UInt64Type, bits = 42)
  result.finish([failure])

proc failureHost(context: pointer, id: int, arguments: openArray[uint64],
    returns: var openArray[uint64]) {.nimcall, gcsafe.} =
  ## Signals a recoverable host failure through the backend error boundary.
  raise newException(BackendError, "deliberate host failure")

block:
  # Successful invokes bind their results before copying continuation arguments.
  var callee = routine([UInt64Type], [UInt64Type])
  callee.failureMode = MayFailCall
  callee.finish([ValueId(0)])
  var caller = routine([UInt64Type], [UInt64Type])
  let returned = ValueId(caller.values.len)
  caller.values.add(IrValue(valueType: UInt64Type))
  caller.edges.add(IrEdge(target: BlockId(1),
    arguments: caller.operands([returned])))
  caller.edges.add(IrEdge(target: BlockId(2)))
  caller.blocks[0].terminator = IrTerminator(kind: InvokeTerminator,
    callee: 1, arguments: caller.operands([ValueId(0)]),
    results: Span(first: int32(returned), count: 1),
    edges: Span(first: 0, count: 2))
  let value = caller.blockParameters([UInt64Type])[0]
  caller.finish([value])
  discard caller.blockParameters([])
  let failure = caller.emit(ConstantOp, [], UInt64Type)
  caller.finish([failure])
  var plan = prepareInterpreter(IrModule(pointerBytes: 8,
    functions: @[caller, callee]))
  doAssert interpret(plan.addr, 0, [42'u64], nil) == @[42'u64]

block:
  # A failed direct invocation must enter its explicit recovery successor.
  var failed = routine([], [])
  failed.failureMode = MayFailCall
  failed.blocks[0].terminator = IrTerminator(kind: FailTerminator,
    failure: BoundsFailure, location: LocationId(0))
  var plan = prepareInterpreter(IrModule(pointerBytes: 8,
    functions: @[recovery(InvokeTerminator, 1), failed],
    files: @["conformance.nifty"],
    locations: @[IrSource(file: 0, line: 12, column: 7)]))
  doAssert interpret(plan.addr, 0, [], nil) == @[42'u64]
  var unhandled = false
  try:
    discard interpret(plan.addr, 1, [], nil)
  except BackendError as exception:
    unhandled = true
    doAssert "BoundsFailure" in exception.msg
  doAssert unhandled

block:
  # A propagating intermediate frame preserves the original failure.
  var
    failed = routine([], [])
    middle = routine([], [])
  failed.failureMode = MayFailCall
  failed.blocks[0].terminator = IrTerminator(kind: FailTerminator,
    failure: ConversionFailure, location: LocationId(0))
  middle.failureMode = MayFailCall
  middle.invoke(InvokeTerminator, 2)
  discard middle.blockParameters([])
  middle.finish([])
  discard middle.blockParameters([])
  middle.blocks[^1].terminator.kind = PropagateTerminator
  var plan = prepareInterpreter(IrModule(pointerBytes: 8,
    functions: @[recovery(InvokeTerminator, 1), middle, failed],
    files: @["conformance.nifty"],
    locations: @[IrSource(file: 0, line: 23, column: 4)]))
  doAssert interpret(plan.addr, 0, [], nil) == @[42'u64]
  var unhandled = false
  try:
    discard interpret(plan.addr, 1, [], nil)
  except BackendError as exception:
    unhandled = true
    doAssert "ConversionFailure" in exception.msg
    doAssert "location 0" in exception.msg
  doAssert unhandled

block:
  # A callee's recovered failure must not replace its caller's pending failure.
  var
    outer = routine([], [])
    original = routine([], [])
    unrelated = routine([], [])
  outer.failureMode = MayFailCall
  outer.invoke(InvokeTerminator, 1)
  discard outer.blockParameters([])
  outer.finish([])
  discard outer.blockParameters([])
  discard outer.emit(CallOp, [], UInt64Type, target = 2)
  outer.blocks[^1].terminator.kind = PropagateTerminator
  original.failureMode = MayFailCall
  original.blocks[0].terminator = IrTerminator(kind: FailTerminator,
    failure: ConversionFailure, location: LocationId(0))
  unrelated.failureMode = MayFailCall
  unrelated.blocks[0].terminator = IrTerminator(kind: FailTerminator,
    failure: BoundsFailure, location: LocationId(1))
  var plan = prepareInterpreter(IrModule(pointerBytes: 8,
    functions: @[outer, original, recovery(InvokeTerminator, 3), unrelated],
    files: @["conformance.nifty"], locations: @[
      IrSource(file: 0, line: 31, column: 2),
      IrSource(file: 0, line: 37, column: 5)]))
  var unhandled = false
  try:
    discard interpret(plan.addr, 0, [], nil)
  except BackendError as exception:
    unhandled = true
    doAssert "ConversionFailure" in exception.msg
    doAssert "location 0" in exception.msg
    doAssert "BoundsFailure" notin exception.msg
  doAssert unhandled

block:
  # The host callback's backend failure follows the host invoke failure edge.
  var plan = prepareInterpreter(IrModule(pointerBytes: 8,
    functions: @[recovery(InvokeHostTerminator, 0)],
    hosts: @[IrHost(name: "failure", failureMode: MayFailCall,
      signature: IrSignature())]))
  doAssert interpret(plan.addr, 0, [], failureHost) == @[42'u64]

block:
  # Runtime globals are based on context storage and honor global offsets.
  var function = routine([AddressType], [UInt64Type])
  let
    address = function.emit(GlobalAddressOp, [], AddressType)
    value = function.emit(LoadOp, [address], UInt64Type)
  function.finish([value])
  var
    globals = [11'u64, 123456789'u64]
    runtime = RuntimeContext(globals: globals.addr)
    plan = prepareInterpreter(IrModule(pointerBytes: 8,
      functions: @[function], globals: @[IrGlobal(name: "second",
        alignment: 8, offset: 8)]))
  doAssert interpret(plan.addr, 0, [cast[uint64](runtime.addr)], nil) ==
    @[123456789'u64]

block:
  # Typed struct field addressing resolves the field's declared offset.
  var function = routine([AddressType], [UInt64Type])
  function.signature.parameterStorage = @[2'i32]
  function.values[0].storage = 2
  let field = function.emit(FieldAddressOp, [ValueId(0)], AddressType,
    target = 1)
  function.values[int32(field)].storage = 1
  let value = function.emit(LoadOp, [field], UInt64Type)
  function.finish([value])
  var
    storage = [17'u64, 42'u64]
    plan = prepareInterpreter(IrModule(pointerBytes: 8,
      functions: @[function], storageTypes: @[
        IrStorage(name: "u64", kind: ScalarStorage, byteCount: 8,
          alignment: 8, scalar: UInt64Type),
        IrStorage(name: "pair", kind: StructStorage, byteCount: 16,
          alignment: 8, fields: Span(first: 0, count: 2))],
      fields: @[IrField(name: "left", storage: 1, offset: 0),
        IrField(name: "right", storage: 1, offset: 8)]))
  doAssert interpret(plan.addr, 0, [cast[uint64](storage.addr)], nil) ==
    @[42'u64]

block:
  # Reported frame storage includes required padding between local slots.
  var function = routine([], [UInt64Type])
  function.slots = @[IrSlot(byteCount: 3, alignment: 1),
    IrSlot(byteCount: 8, alignment: 8)]
  let size = function.emit(FrameSizeOp, [], UInt64Type)
  function.finish([size])
  doAssert function.run([]) == @[16'u64]

for kind in [Float32Type, Float64Type]:
  let nan = if kind == Float32Type: 0x7fc01234'u64
    else: 0x7ff8000000001234'u64
  for predicate in IrComparison:
    doAssert comparison(kind, predicate, nan, 0) ==
      (predicate == NotEqualComparison)
    doAssert comparison(kind, predicate, 0, nan) ==
      (predicate == NotEqualComparison)
doAssert binary(DivideOp, Int64Type, cast[uint64](-7'i64), 3) ==
  cast[uint64](-2'i64)
doAssert binary(RemainderOp, Int64Type, cast[uint64](-7'i64), 3) ==
  cast[uint64](-1'i64)
doAssert binary(DivideOp, Int64Type, 7, cast[uint64](-3'i64)) ==
  cast[uint64](-2'i64)

echo "Direct IR interpreter conformance passed"

import nifty/backend/[engine, context, memories, irchecks, irbuilders]

proc instruction(function: var IrFunction, op: IrOpcode,
    arguments: openArray[ValueId], kind = Int64Type, bits = 0'u64,
    target = 0'i32, offset = 0'i64, resultCount = 1): ValueId =
  ## Appends one explicitly typed instruction to the active test block.
  result = ValueId(function.values.len)
  let argumentsSpan = Span(first: int32(function.operands.len),
    count: int32(arguments.len))
  function.operands.add(arguments)
  for i in 0 ..< resultCount:
    function.values.add(IrValue(valueType: kind))
  function.instructions.add(IrInstruction(op: op, bits: bits,
    target: target, offset: offset, alignment: 1,
    results: Span(first: int32(result), count: int32(resultCount)),
    arguments: argumentsSpan))
  inc function.blocks[^1].instructions.count

proc newFunction(name: string): IrFunction =
  ## Creates a routine using the four-address native ABI.
  result.name = name
  result.failureMode = NoFailCall
  result.signature.parameters = @[
    AddressType, AddressType, AddressType, AddressType]
  for i in 0 ..< 4:
    result.values.add(IrValue(valueType: AddressType))
  result.blocks.add(IrBlock(parameters: Span(first: 0, count: 4)))

proc finish(function: var IrFunction) =
  ## Ends a test routine without a native scalar return.
  function.blocks[^1].terminator = IrTerminator(kind: ReturnTerminator)

proc integerHost(value: int64, scale: float64, bias: float32): int64
    {.cdecl, raises: [].} =
  ## Exercises mixed native integer and floating C argument banks.
  value * int64(scale) + int64(bias)

proc floatHost(value: float32, scale: int32): float32
    {.cdecl, raises: [].} =
  ## Exercises a narrow integer argument and binary32 C return value.
  value * float32(scale)

proc stackedHost(i0, i1, i2, i3, i4, i5, i6, i7: int64,
    f0, f1, f2, f3, f4, f5, f6, f7: float32,
    small: int8, extra: float32, medium: int32, wide: float64,
    last: int64): float64 {.cdecl, raises: [].} =
  ## Exercises both overflow argument banks and compact mixed stack slots.
  float64(i0 + i1 + i2 + i3 + i4 + i5 + i6 + i7) +
    float64(f0 + f1 + f2 + f3 + f4 + f5 + f6 + f7) +
    float64(small) + float64(extra) + float64(medium) + wide + float64(last)

var module = IrModule(pointerBytes: 8)
module.hosts = @[
  IrHost(name: "integerHost", binding: 0, failureMode: NoFailCall,
    signature: IrSignature(parameters: @[Int64Type, Float64Type, Float32Type],
      returns: @[Int64Type])),
  IrHost(name: "floatHost", binding: 1, failureMode: NoFailCall,
    signature: IrSignature(parameters: @[Float32Type, Int32Type],
      returns: @[Float32Type]))
]
module.globals = @[IrGlobal(name: "value", bytes: Span(first: 0, count: 8),
  alignment: 8, offset: 0)]
module.data = newSeq[byte](8)
var stackedParameters: seq[IrType]
for i in 0 ..< 8:
  stackedParameters.add(Int64Type)
for i in 0 ..< 8:
  stackedParameters.add(Float32Type)
stackedParameters.add(@[Int8Type, Float32Type, Int32Type, Float64Type, Int64Type])
module.hosts.add(IrHost(name: "stackedHost", binding: 2,
  failureMode: NoFailCall, signature: IrSignature(parameters: stackedParameters,
    returns: @[Float64Type])))

var integer = newFunction("integer")
let
  a = integer.instruction(LoadOp, [ValueId(1)])
  b = integer.instruction(ConstantOp, [], bits = 2)
  sum = integer.instruction(AddOp, [a, b])
discard integer.instruction(StoreOp, [ValueId(2), sum], resultCount = 0)
integer.finish()
module.functions.add(integer)

var host = newFunction("mixedHost")
let
  h1 = host.instruction(ConstantOp, [], bits = 13)
  h2 = host.instruction(ConstantOp, [], Float64Type,
    bits = cast[uint64](3.0))
  h3 = host.instruction(ConstantOp, [], Float32Type,
    bits = uint64(cast[uint32](2.0'f)))
  hostValue = host.instruction(HostCallOp, [h1, h2, h3], target = 0)
discard host.instruction(StoreOp, [ValueId(2), hostValue], resultCount = 0)
host.finish()
module.functions.add(host)

var floating = newFunction("floatHost")
let
  f1 = floating.instruction(ConstantOp, [], Float32Type,
    bits = uint64(cast[uint32](3.5'f)))
  f2 = floating.instruction(ConstantOp, [], Int32Type, bits = 2)
  floatValue = floating.instruction(HostCallOp, [f1, f2], Float32Type,
    target = 1)
discard floating.instruction(StoreOp, [ValueId(2), floatValue], resultCount = 0)
floating.finish()
module.functions.add(floating)

var direct = newFunction("direct")
discard direct.instruction(CallOp,
  [ValueId(0), ValueId(1), ValueId(2), ValueId(3)],
  target = 0, resultCount = 0)
direct.finish()
module.functions.add(direct)

var global = newFunction("global")
let
  address = global.instruction(GlobalAddressOp, [], AddressType, target = 0)
  globalValue = global.instruction(LoadOp, [address])
discard global.instruction(StoreOp, [ValueId(2), globalValue], resultCount = 0)
global.finish()
module.functions.add(global)

var loop = newFunction("loop")
let
  limit = loop.instruction(LoadOp, [ValueId(1)])
  zero = loop.instruction(ConstantOp, [], bits = 0)
  one = loop.instruction(ConstantOp, [], bits = 1)
loop.edges.add(IrEdge(target: BlockId(1),
  arguments: Span(first: int32(loop.operands.len), count: 2)))
loop.operands.add(@[one, zero])
loop.blocks[0].terminator = IrTerminator(kind: JumpTerminator,
  edges: Span(first: 0, count: 1))
loop.values.add(@[IrValue(valueType: Int64Type), IrValue(valueType: Int64Type)])
let
  index = ValueId(7)
  accumulator = ValueId(8)
loop.blocks.add(IrBlock(parameters: Span(first: 7, count: 2),
  instructions: Span(first: int32(loop.instructions.len))))
let condition = loop.instruction(CompareOp, [index, limit], BoolType)
loop.instructions[^1].comparison = LessEqualComparison
let branchArguments = Span(first: int32(loop.operands.len), count: 1)
loop.operands.add(condition)
loop.edges.add(@[IrEdge(target: BlockId(2)), IrEdge(target: BlockId(3))])
loop.blocks[1].terminator = IrTerminator(kind: BranchTerminator,
  arguments: branchArguments, edges: Span(first: 1, count: 2))
loop.blocks.add(IrBlock(instructions: Span(first: int32(loop.instructions.len))))
let
  accumulated = loop.instruction(AddOp, [accumulator, index])
  nextIndex = loop.instruction(AddOp, [index, one])
loop.edges.add(IrEdge(target: BlockId(1),
  arguments: Span(first: int32(loop.operands.len), count: 2)))
loop.operands.add(@[nextIndex, accumulated])
loop.blocks[2].terminator = IrTerminator(kind: JumpTerminator,
  edges: Span(first: 3, count: 1))
loop.blocks.add(IrBlock(instructions: Span(first: int32(loop.instructions.len))))
discard loop.instruction(StoreOp, [ValueId(2), accumulator], resultCount = 0)
loop.finish()
module.functions.add(loop)

var stacked = newFunction("stackedHost")
var stackArguments: seq[ValueId]
for i in 1 .. 8:
  stackArguments.add(stacked.instruction(ConstantOp, [], Int64Type,
    bits = uint64(i)))
for i in 1 .. 8:
  stackArguments.add(stacked.instruction(ConstantOp, [], Float32Type,
    bits = uint64(cast[uint32](float32(i)))))
stackArguments.add(stacked.instruction(ConstantOp, [], Int8Type,
  bits = cast[uint64](-3'i64)))
stackArguments.add(stacked.instruction(ConstantOp, [], Float32Type,
  bits = uint64(cast[uint32](0.5'f))))
stackArguments.add(stacked.instruction(ConstantOp, [], Int32Type, bits = 40))
stackArguments.add(stacked.instruction(ConstantOp, [], Float64Type,
  bits = cast[uint64](1.25)))
stackArguments.add(stacked.instruction(ConstantOp, [], Int64Type, bits = 100))
let stackedValue = stacked.instruction(HostCallOp, stackArguments,
  Float64Type, target = 2)
discard stacked.instruction(StoreOp, [ValueId(2), stackedValue], resultCount = 0)
stacked.finish()
module.functions.add(stacked)

for operation in [MoveBytesOp, ClearBytesOp]:
  var memory = newFunction($operation)
  if operation == MoveBytesOp:
    discard memory.instruction(operation, [ValueId(2), ValueId(1)],
      resultCount = 0)
  else:
    discard memory.instruction(operation, [ValueId(1)], resultCount = 0)
  memory.instructions[^1].byteCount = 1024
  memory.finish()
  module.functions.add(memory)
var empty = newFunction("emptyMove")
discard empty.instruction(MoveBytesOp, [ValueId(2), ValueId(1)], resultCount = 0)
empty.finish()
module.functions.add(empty)

var builder = IrBuilder(module: IrModule(pointerBytes: 8))
let builderLabel = builder.label()
builder.declareFunctions(["builder"], [builderLabel])
builder.beginFunction(0, builderLabel)
builder.loadImmediate(Word64, X3, 123)
builder.storeDouble(X3, X1)
builder.finishFunction(0)
verifyIr(builder.module)
for target in NativeTarget:
  doAssert emitNative(builder.module, target).bytes.len > 0

verifyIr(module)
for target in NativeTarget:
  let image = emitNative(module, target)
  doAssert image.target == target
  doAssert image.bytes.len > 0
  doAssert image.offsets.len == module.functions.len
  doAssert image.frameBytes.len == module.functions.len
  doAssert image.wrapperFrameBytes ==
    (if target == Arm64Target: 32 else: 112)
  for frame in image.frameBytes:
    doAssert frame >= 0
    if target == Arm64Target:
      doAssert frame mod 16 == 0
    else:
      doAssert frame mod 16 == 0
  for i, offset in image.offsets:
    doAssert offset > 0 and offset < image.bytes.len
    if i > 0:
      doAssert offset > image.offsets[i - 1]
  when defined(arm64) or defined(amd64):
    let nativeTarget = when defined(arm64): Arm64Target else: Amd64Target
    if target == nativeTarget:
      var buffer = initCodeBuffer(image.bytes)
      var
        globalData = 91'i64
        hosts = [cast[pointer](integerHost), cast[pointer](floatHost),
          cast[pointer](stackedHost)]
        ctx = RuntimeContext(globals: globalData.addr, hosts: hosts.addr)
        argument = 40'i64
        answer = 0'i64
        floatAnswer = 0.0'f
        doubleAnswer = 0.0
      type Entry = proc(ctx, arguments, returned, reserved: pointer)
        {.cdecl, raises: [].}
      proc entry(index: int): Entry =
        ## Resolves a routine offset independently of the leading wrapper.
        cast[Entry](cast[uint](buffer.entry()) + uint(image.offsets[index]))
      entry(0)(ctx.addr, argument.addr, answer.addr, nil)
      doAssert answer == 42
      entry(1)(ctx.addr, nil, answer.addr, nil)
      doAssert answer == 41
      entry(2)(ctx.addr, nil, floatAnswer.addr, nil)
      doAssert floatAnswer == 7.0'f
      entry(3)(ctx.addr, argument.addr, answer.addr, nil)
      doAssert answer == 42
      entry(4)(ctx.addr, nil, answer.addr, nil)
      doAssert answer == 91
      argument = 10
      entry(5)(ctx.addr, argument.addr, answer.addr, nil)
      doAssert answer == 55
      argument = 0
      entry(5)(ctx.addr, argument.addr, answer.addr, nil)
      doAssert answer == 0
      entry(6)(ctx.addr, nil, doubleAnswer.addr, nil)
      doAssert doubleAnswer == 210.75
      var data, expected: array[2048, byte]
      for i in 0 ..< data.len:
        data[i] = byte(i mod 251)
      expected = data
      moveMem(expected[13].addr, expected[0].addr, 1024)
      entry(7)(ctx.addr, data[0].addr, data[13].addr, nil)
      doAssert data == expected
      moveMem(expected[0].addr, expected[13].addr, 1024)
      entry(7)(ctx.addr, data[13].addr, data[0].addr, nil)
      doAssert data == expected
      entry(7)(ctx.addr, data[0].addr, data[0].addr, nil)
      doAssert data == expected
      zeroMem(expected[100].addr, 1024)
      entry(8)(ctx.addr, data[100].addr, nil, nil)
      doAssert data == expected
      entry(9)(ctx.addr, nil, nil, nil)
      buffer.release()
      doAssert buffer.entry() == nil

echo "Native IR emission and execution passed"

## Exercises call-local volatile floating preservation under ABI clobbering.
import nifty/backend/[context, engine, irmachines, irchecks, irlifetimes,
  memories]

proc `==`(a, b: ValueId): bool =
  ## Compares opaque SSA identifiers for liveness assertions.
  int32(a) == int32(b)

proc operands(function: var IrFunction, values: openArray[ValueId]): Span =
  ## Appends one ordered list of typed SSA uses.
  result = Span(first: int32(function.operands.len), count: int32(values.len))
  function.operands.add(values)

proc instruction(function: var IrFunction, op: IrOpcode,
    values: openArray[ValueId], kind = Float64Type, offset = 0'i64,
    target = 0'i32, count = 1): ValueId =
  ## Adds a definition or side effect to the current block.
  result = ValueId(function.values.len)
  for i in 0 ..< count:
    function.values.add(IrValue(valueType: kind))
  function.instructions.add(IrInstruction(op: op, alignment: 1,
    offset: offset, target: target,
    arguments: function.operands(values),
    results: Span(first: int32(result), count: int32(count))))
  inc function.blocks[^1].instructions.count

proc blockValues(function: var IrFunction,
    kinds: openArray[IrType] = []): seq[ValueId] =
  ## Allocates independent block parameters and a new active block.
  let first = int32(function.values.len)
  for kind in kinds:
    result.add(ValueId(function.values.len))
    function.values.add(IrValue(valueType: kind))
  function.blocks.add(IrBlock(parameters:
    Span(first: first, count: int32(kinds.len)),
    instructions: Span(first: int32(function.instructions.len))))

proc storageFunction(name: string): IrFunction =
  ## Creates a callable storage entry with four pointer arguments.
  result = IrFunction(name: name, failureMode: NoFailCall,
    signature: IrSignature(parameters:
      @[AddressType, AddressType, AddressType, AddressType]))
  discard result.blockValues(result.signature.parameters)

proc edge(function: var IrFunction, target: int,
    arguments: openArray[ValueId] = []): int32 =
  ## Creates one explicit CFG edge into a successor.
  result = int32(function.edges.len)
  function.edges.add(IrEdge(target: BlockId(target),
    arguments: function.operands(arguments)))

proc jump(function: var IrFunction, target: int,
    arguments: openArray[ValueId] = []) =
  ## Ends the current block with a typed parameter transfer.
  function.blocks[^1].terminator = IrTerminator(kind: JumpTerminator,
    edges: Span(first: function.edge(target, arguments), count: 1))

proc finish(function: var IrFunction, returned: openArray[ValueId] = []) =
  ## Returns an optional scalar bundle through the private ABI.
  function.blocks[^1].terminator = IrTerminator(kind: ReturnTerminator,
    arguments: function.operands(returned))

var hostCalls = 0
proc clobberHost(a, b, extra: float64): float64
    {.cdecl, raises: [], noinline.} =
  ## Destroys every volatile vector register while returning ordered math.
  inc hostCalls
  result = a - b + extra
  when defined(arm64):
    {.emit: """__asm__ volatile(
      "movi v0.16b, #0x5a\n"
      "movi v1.16b, #0x5a\n"
      "movi v2.16b, #0x5a\n"
      "movi v3.16b, #0x5a\n"
      "movi v4.16b, #0x5a\n"
      "movi v5.16b, #0x5a\n"
      "movi v6.16b, #0x5a\n"
      "movi v7.16b, #0x5a\n"
      "movi v16.16b, #0x5a\n"
      "movi v17.16b, #0x5a\n"
      "movi v18.16b, #0x5a\n"
      "movi v19.16b, #0x5a\n"
      "movi v20.16b, #0x5a\n"
      "movi v21.16b, #0x5a\n"
      "movi v22.16b, #0x5a\n"
      "movi v23.16b, #0x5a\n"
      "movi v24.16b, #0x5a\n"
      "movi v25.16b, #0x5a\n"
      "movi v26.16b, #0x5a\n"
      "movi v27.16b, #0x5a\n"
      "movi v28.16b, #0x5a\n"
      "movi v29.16b, #0x5a\n"
      "movi v30.16b, #0x5a\n"
      "movi v31.16b, #0x5a\n"
      : : : "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
      "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
      "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31");""".}

var module = IrModule(pointerBytes: 8)
module.hosts.add(IrHost(name: "clobber", binding: 0,
  failureMode: NoFailCall, signature: IrSignature(
    parameters: @[Float64Type, Float64Type, Float64Type],
    returns: @[Float64Type])))
var entry = storageFunction("entry")
entry.finish()
module.functions.add(entry)

var host = storageFunction("conditionalHost")
var values: seq[ValueId]
for i in 0 ..< 36:
  values.add(host.instruction(LoadOp, [ValueId(1)],
    offset = int64(i * 8)))
let
  dying = host.instruction(LoadOp, [ValueId(1)], offset = 36 * 8)
  condition = host.instruction(LoadOp, [ValueId(1)], BoolType, offset = 37 * 8)
  first = host.edge(1)
discard host.edge(2)
host.blocks[^1].terminator = IrTerminator(kind: BranchTerminator,
  arguments: host.operands([condition]),
  edges: Span(first: first, count: 2))
discard host.blockValues()
let
  callIndex = host.instructions.len
  called = host.instruction(HostCallOp, [values[1], values[0], dying])
host.jump(3, [called])
discard host.blockValues()
let
  difference = host.instruction(SubtractOp, [values[1], values[0]])
  uncalled = host.instruction(AddOp, [difference, dying])
host.jump(3, [uncalled])
let joined = host.blockValues([Float64Type])[0]
for i, value in values:
  discard host.instruction(StoreOp, [ValueId(2), value],
    offset = int64(i * 8), count = 0)
discard host.instruction(StoreOp, [ValueId(2), joined],
  offset = 36 * 8, count = 0)
host.finish()
let live = liveThroughCalls(host, analyzeLiveness(host))
doAssert dying notin live[callIndex]
doAssert called notin live[callIndex]
for value in values:
  doAssert value in live[callIndex]
module.functions.add(host)

let signature = IrSignature(
  parameters: @[AddressType, Float64Type, Float64Type, Float64Type],
  returns: @[Float64Type, Float64Type])
var callee = IrFunction(name: "bundle", failureMode: NoFailCall,
  directOnly: true, signature: signature)
discard callee.blockValues(signature.parameters)
let returned = callee.instruction(HostCallOp,
  [ValueId(2), ValueId(1), ValueId(3)])
callee.finish([returned, ValueId(1)])
module.functions.add(callee)
var scalarSignature = signature
scalarSignature.returns = @[Float64Type]
module.signatures.add(scalarSignature)
var scalarCallee = IrFunction(name: "scalar", failureMode: NoFailCall,
  directOnly: true, signature: scalarSignature)
discard scalarCallee.blockValues(scalarSignature.parameters)
let scalarReturned = scalarCallee.instruction(HostCallOp,
  [ValueId(2), ValueId(1), ValueId(3)])
scalarCallee.finish([scalarReturned])
module.functions.add(scalarCallee)

for operation in [CallOp, IndirectCallOp]:
  var caller = storageFunction($operation)
  var retained: seq[ValueId]
  for i in 0 ..< 36:
    retained.add(caller.instruction(LoadOp, [ValueId(1)],
      offset = int64(i * 8)))
  let extra = caller.instruction(LoadOp, [ValueId(1)], offset = 36 * 8)
  let arguments = if operation == CallOp:
      @[ValueId(0), retained[0], retained[1], extra]
    else: @[ValueId(3), ValueId(0), retained[0], retained[1], extra]
  let answer = caller.instruction(operation, arguments,
    target = (if operation == CallOp: 2'i32 else: 0'i32),
    count = (if operation == CallOp: 2 else: 1))
  for i, value in retained:
    discard caller.instruction(StoreOp, [ValueId(2), value],
      offset = int64(i * 8), count = 0)
  for i in 0 ..< (if operation == CallOp: 2 else: 1):
    discard caller.instruction(StoreOp,
      [ValueId(2), ValueId(int32(answer) + int32(i))],
      offset = int64((36 + i) * 8), count = 0)
  caller.finish()
  module.functions.add(caller)

for kind in [Float32Type, Float32x2Type]:
  var caller = storageFunction($kind)
  var retained: seq[ValueId]
  for i in 0 ..< 36:
    retained.add(caller.instruction(LoadOp, [ValueId(1)], kind,
      offset = int64(i * 8)))
  let extra = caller.instruction(LoadOp, [ValueId(1)], offset = 36 * 8)
  discard caller.instruction(HostCallOp, [extra, extra, extra])
  for i, value in retained:
    discard caller.instruction(StoreOp, [ValueId(2), value],
      offset = int64(i * 8), count = 0)
  caller.finish()
  module.functions.add(caller)

verifyIr(module)
for useSaves in [false, true]:
  let image = emitArm64Ir(module, MaxNativeBytes, callSaves = useSaves)
  for bytes in image.frameBytes:
    doAssert bytes mod 16 == 0
  when defined(arm64):
    var bytes: seq[byte]
    for word in image.words:
      for shift in [0, 8, 16, 24]:
        bytes.add(byte((word shr shift) and 255))
    var buffer = initCodeBuffer(bytes)
    var hosts = [cast[pointer](clobberHost)]
    var ctx = RuntimeContext(hosts: hosts.addr)
    type Entry = proc(ctx, arguments, returned, reserved: pointer)
      {.cdecl, raises: [].}
    var input: array[38, uint64]
    var output: array[38, uint64]
    for i in 0 ..< input.len:
      input[i] = cast[uint64](float64(i) + 0.25)
    input[9] = 0x8000000000000000'u64
    input[27] = 0x7ff8000000001234'u64
    let expected = cast[uint64](cast[float64](input[1]) -
      cast[float64](input[0]) + cast[float64](input[36]))
    for flag in [0'u64, 1'u64]:
      input[37] = flag
      hostCalls = 0
      let call = cast[Entry](cast[uint](buffer.entry()) +
        uint(image.offsets[1]))
      call(ctx.addr, input.addr, output.addr, nil)
      doAssert hostCalls == int(flag)
      for i in 0 ..< 36:
        doAssert output[i] == input[i]
      doAssert output[36] == expected
    for index in [4, 5]:
      hostCalls = 0
      let call = cast[Entry](cast[uint](buffer.entry()) +
        uint(image.offsets[index]))
      let target = cast[pointer](cast[uint](buffer.entry()) +
        uint(image.offsets[3]))
      call(ctx.addr, input.addr, output.addr, target)
      doAssert hostCalls == 1
      for i in 0 ..< 36:
        doAssert output[i] == input[i]
      doAssert output[36] == expected
      if index == 4:
        doAssert output[37] == input[0]
    for index in [6, 7]:
      hostCalls = 0
      let call = cast[Entry](cast[uint](buffer.entry()) +
        uint(image.offsets[index]))
      call(ctx.addr, input.addr, output.addr, nil)
      doAssert hostCalls == 1
      for i in 0 ..< 36:
        if index == 6:
          doAssert uint32(output[i]) == uint32(input[i])
        else:
          doAssert output[i] == input[i]
    buffer.release()

echo "ARM call-local volatile floating preservation passed"

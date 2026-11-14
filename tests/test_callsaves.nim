## Keep many floating payloads live across cold calls and CFG joins.
import nifty/backend/[irs, irchecks, iramds, amds, memories, context]

proc instruction(function: var IrFunction, op: IrOpcode,
    arguments: openArray[ValueId], kind: IrType, count = 1,
    target = 0, offset = 0): ValueId =
  ## Appends a typed instruction to the currently active block.
  result = ValueId(function.values.len)
  let first = function.operands.len
  function.operands.add(arguments)
  for i in 0 ..< count:
    function.values.add(IrValue(valueType: kind))
  function.instructions.add(IrInstruction(op: op,
    arguments: Span(first: int32(first), count: int32(arguments.len)),
    results: Span(first: int32(result), count: int32(count)),
    alignment: 1, target: int32(target), offset: int64(offset)))
  inc function.blocks[^1].instructions.count

proc finish(function: var IrFunction, kind: IrTerminatorKind,
    arguments: openArray[ValueId], targets: openArray[int]) =
  ## Ends a block and records its control-flow transfer arguments.
  let first = function.operands.len
  function.operands.add(arguments)
  function.blocks[^1].terminator = IrTerminator(kind: kind,
    arguments: Span(first: int32(first), count: int32(arguments.len)),
    edges: Span(first: int32(function.edges.len), count: int32(targets.len)))
  for target in targets:
    function.edges.add(IrEdge(target: BlockId(target)))

proc beginBlock(function: var IrFunction) =
  ## Starts an empty basic block after the preceding instruction range.
  function.blocks.add(IrBlock(instructions: Span(
    first: int32(function.instructions.len))))

var module = IrModule(pointerBytes: 8)
let hostSignature = IrSignature(parameters: newSeq[IrType](12),
  returns: @[Float64Type])
module.hosts.add(IrHost(name: "clobber", binding: 0,
  failureMode: NoFailCall, signature: hostSignature))
for kind in module.hosts[0].signature.parameters.mitems:
  kind = Float64Type
module.signatures.add(module.hosts[0].signature)

for operation in [HostCallOp, IndirectCallOp, CallOp]:
  var function = IrFunction(name: $operation, failureMode: NoFailCall)
  function.signature.parameters = @[
    AddressType, AddressType, AddressType, AddressType]
  for i in 0 ..< 4:
    function.values.add(IrValue(valueType: AddressType))
  function.beginBlock()
  function.blocks[0].parameters = Span(first: 0, count: 4)
  var payloads: seq[ValueId]
  for i in 0 ..< 36:
    payloads.add(function.instruction(LoadOp, [ValueId(1)], Float64Type,
      offset = i * 8))
  let condition = function.instruction(LoadOp, [ValueId(3)], BoolType)
  function.finish(BranchTerminator, [condition], [1, 2])
  function.beginBlock()
  var arguments: seq[ValueId]
  if operation == IndirectCallOp:
    arguments.add(function.instruction(LoadOp, [ValueId(3)], AddressType,
      offset = 8))
  elif operation == CallOp:
    arguments.add(ValueId(0))
  for i in 0 ..< 12:
    arguments.add(payloads[11 - i])
  let answer = function.instruction(operation, arguments, Float64Type,
    count = if operation == CallOp: 4 else: 1,
    target = if operation == CallOp: 3 else: 0)
  if operation == CallOp:
    for i in 1 .. 3:
      discard function.instruction(StoreOp,
        [ValueId(2), ValueId(int32(answer) + int32(i))], Float64Type,
        count = 0, offset = (36 + i) * 8)
  function.finish(JumpTerminator, [], [3])
  function.edges[^1].arguments = Span(first: int32(function.operands.len),
    count: 1)
  function.operands.add(answer)
  function.beginBlock()
  let hot = function.instruction(ConstantOp, [], Float64Type)
  function.instructions[^1].bits = cast[uint64](2.25)
  function.finish(JumpTerminator, [], [3])
  function.edges[^1].arguments = Span(first: int32(function.operands.len),
    count: 1)
  function.operands.add(hot)
  function.beginBlock()
  let joined = ValueId(function.values.len)
  function.values.add(IrValue(valueType: Float64Type))
  function.blocks[^1].parameters = Span(first: int32(joined), count: 1)
  for i, value in payloads:
    discard function.instruction(StoreOp, [ValueId(2), value], Float64Type,
      count = 0, offset = i * 8)
  discard function.instruction(StoreOp, [ValueId(2), joined], Float64Type,
    count = 0, offset = 36 * 8)
  function.finish(ReturnTerminator, [], [])
  module.functions.add(function)

var callee = IrFunction(name: "private", directOnly: true,
  failureMode: NoFailCall)
callee.signature.parameters = @[AddressType]
callee.signature.parameters.add(module.hosts[0].signature.parameters)
callee.signature.returns = @[Float64Type, Float64Type,
  Float64Type, Float64Type]
for kind in callee.signature.parameters:
  callee.values.add(IrValue(valueType: kind))
callee.beginBlock()
callee.blocks[0].parameters = Span(first: 0, count: 13)
var arguments: seq[ValueId]
for i in 1 .. 12:
  arguments.add(ValueId(i))
let answer = callee.instruction(HostCallOp, arguments, Float64Type)
callee.finish(ReturnTerminator,
  [answer, ValueId(1), ValueId(2), ValueId(3)], [])
module.functions.add(callee)
verifyIr(module)
let image = emitAmd64Ir(module, MaxNativeBytes)
echo "AMD64 call-save image: ", image.bytes.len, " bytes; frames ",
  image.frameBytes

when defined(amd64):
  # This host destroys every volatile vector register, independent of C choices.
  var assembler: XAssembler
  when defined(windows):
    const Volatile = 6
  else:
    const Volatile = 16
  for register in 0 ..< Volatile:
    assembler.vectorBinary(0x57, register, register)
  assembler.loadImmediate(Rax, cast[int64](2.25))
  assembler.bitsToFloat(0, Rax)
  assembler.returnToCaller()
  var
    host = initCodeBuffer(assembler.code)
    buffer = initCodeBuffer(image.bytes)
    hosts = [host.entry()]
    ctx = RuntimeContext(hosts: hosts.addr)
    input: array[36, uint64]
    output: array[40, uint64]
    controls = [0'u64, cast[uint64](host.entry())]
  for i in 0 ..< input.len:
    input[i] = cast[uint64](float64(i + 1) / 7.0)
  input[0] = 0x8000000000000000'u64
  input[35] = 0x7ff8000000001234'u64
  type Entry = proc(ctx, source, destination, control: pointer)
    {.cdecl, raises: [].}
  for index in 0 ..< 3:
    let entry = cast[Entry](cast[uint](buffer.entry()) +
      uint(image.offsets[index]))
    for cold in [0'u64, 1'u64]:
      controls[0] = cold
      entry(ctx.addr, input.addr, output.addr, controls.addr)
      for i in 0 ..< input.len:
        doAssert output[i] == input[i], $index & " payload " & $i
      doAssert output[36] == cast[uint64](2.25)
      if index == 2 and cold != 0:
        for i in 1 .. 3:
          doAssert output[36 + i] == input[12 - i]
  echo "AMD64 host, indirect and private call saves passed"

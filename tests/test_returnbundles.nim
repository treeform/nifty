## Exercise uniform private floating result bundles on both native targets.
import nifty/backend/[engine, irmachines, iramds, memories, context, irchecks]

proc instruction(function: var IrFunction, op: IrOpcode,
    arguments: openArray[ValueId], kind: IrType, count = 1,
    target = 0, offset = 0): ValueId =
  ## Appends a typed instruction, including simultaneous call results.
  result = ValueId(function.values.len)
  let first = function.operands.len
  function.operands.add(arguments)
  for i in 0 ..< count:
    function.values.add(IrValue(valueType: kind))
  function.instructions.add(IrInstruction(op: op,
    arguments: Span(first: int32(first), count: int32(arguments.len)),
    results: Span(first: int32(result), count: int32(count)),
    alignment: 1, target: int32(target), offset: int64(offset)))
  inc function.blocks[0].instructions.count

var module = IrModule(pointerBytes: 8)
for kind in [Float32Type, Float64Type]:
  for lanes in 2 .. 4:
    var caller = IrFunction(name: "caller", failureMode: NoFailCall)
    caller.signature.parameters = @[
      AddressType, AddressType, AddressType, AddressType]
    for i in 0 ..< 4:
      caller.values.add(IrValue(valueType: AddressType))
    caller.blocks.add(IrBlock(parameters: Span(first: 0, count: 4),
      terminator: IrTerminator(kind: ReturnTerminator)))
    var arguments = @[ValueId(0)]
    let width = int(byteCount(kind, 8))
    for i in 0 ..< lanes:
      arguments.add(caller.instruction(LoadOp, [ValueId(1)], kind,
        offset = i * width))
    let returned = caller.instruction(CallOp, arguments, kind, lanes,
      target = module.functions.len + 1)
    for i in 0 ..< lanes:
      discard caller.instruction(StoreOp,
        [ValueId(2), ValueId(int32(returned) + int32(i))], kind,
        count = 0, offset = i * width)
    module.functions.add(caller)
    var callee = IrFunction(name: "bundle", directOnly: true,
      failureMode: NoFailCall)
    callee.signature.parameters = @[AddressType]
    callee.values.add(IrValue(valueType: AddressType))
    for i in 0 ..< lanes:
      callee.signature.parameters.add(kind)
      callee.signature.returns.add(kind)
      callee.values.add(IrValue(valueType: kind))
      # Rotation forces simultaneous result copies rather than numeric moves.
      callee.operands.add(ValueId((i + 1) mod lanes + 1))
    callee.blocks.add(IrBlock(parameters: Span(first: 0,
      count: int32(lanes + 1)), terminator: IrTerminator(
        kind: ReturnTerminator, arguments: Span(first: 0, count: int32(lanes)))))
    module.functions.add(callee)
verifyIr(module)
verifyReturnAbi(module)
for target in NativeTarget:
  var bytes: seq[byte]
  var offsets: seq[int]
  if target == Arm64Target:
    let image = emitArm64Ir(module, MaxNativeBytes)
    offsets = image.offsets
    for word in image.words:
      for shift in [0, 8, 16, 24]:
        bytes.add(byte((word shr shift) and 255))
  else:
    let image = emitAmd64Ir(module, MaxNativeBytes)
    offsets = image.offsets
    bytes = image.bytes
  when defined(arm64) or defined(amd64):
    const Native = when defined(arm64): Arm64Target else: Amd64Target
    if target != Native:
      continue
    var
      buffer = initCodeBuffer(bytes)
      ctx: RuntimeContext
      input = [0x8000000000000000'u64, 0x7ff8000000001234'u64,
        0x400921fb54442d18'u64, 0xbff0000000000000'u64]
      input32 = [0x80000000'u32, 0x7fc01234'u32,
        0x40490fdb'u32, 0xbf800000'u32]
      output: array[4, uint64]
      output32: array[4, uint32]
    type Entry = proc(ctx, source, destination, reserved: pointer)
      {.cdecl, raises: [].}
    for lanes in 2 .. 4:
      let
        narrow = cast[Entry](cast[uint](buffer.entry()) +
          uint(offsets[(lanes - 2) * 2]))
        wide = cast[Entry](cast[uint](buffer.entry()) +
          uint(offsets[6 + (lanes - 2) * 2]))
      narrow(ctx.addr, input32.addr, output32.addr, nil)
      wide(ctx.addr, input.addr, output.addr, nil)
      for i in 0 ..< lanes:
        doAssert output32[i] == input32[(i + 1) mod lanes]
        doAssert output[i] == input[(i + 1) mod lanes]
    echo target, " private float32/float64 result bundles passed"

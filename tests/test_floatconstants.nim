## Checks every ARM floating immediate and exact fallback constant payloads.
import nifty/backend/[engine, arms, context, memories, irchecks]

var patterns: seq[uint64]
for immediate in 0 .. 255:
  let
    single = cast[float32](floatImmediateBits(uint8(immediate)))
    double = floatImmediateBits64(uint8(immediate))
  doAssert cast[uint64](float64(single)) == double
  patterns.add(double)
patterns.add([0'u64, 0x8000000000000000'u64, 1'u64,
  0x8000000000000001'u64, 0x7ff0000000000000'u64,
  0xfff0000000000000'u64, 0x7ff8000000001234'u64,
  0x7ff0000000000001'u64, 0xfff8000000005678'u64,
  0x400921fb54442d18'u64, 0xffffffffffffffff'u64])
var function = IrFunction(name: "constants", failureMode: NoFailCall,
  signature: IrSignature(parameters:
    @[AddressType, AddressType, AddressType, AddressType]))
for i in 0 ..< 4:
  function.values.add(IrValue(valueType: AddressType))
for i, bits in patterns:
  let value = int32(function.values.len)
  function.values.add(IrValue(valueType: Float64Type))
  function.instructions.add(IrInstruction(op: ConstantOp, bits: bits,
    results: Span(first: value, count: 1)))
  let first = int32(function.operands.len)
  function.operands.add([ValueId(2), ValueId(value)])
  function.instructions.add(IrInstruction(op: StoreOp,
    arguments: Span(first: first, count: 2), offset: int64(i * 8),
    alignment: 1))
function.blocks.add(IrBlock(parameters: Span(first: 0, count: 4),
  instructions: Span(first: 0, count: int32(function.instructions.len)),
  terminator: IrTerminator(kind: ReturnTerminator)))
let module = IrModule(pointerBytes: 8, functions: @[function])
verifyIr(module)
for target in NativeTarget:
  let emitted = emitNative(module, target)
  when defined(arm64) or defined(amd64):
    const Native = when defined(arm64): Arm64Target else: Amd64Target
    if target == Native:
      var
        buffer = initCodeBuffer(emitted.bytes)
        ctx: RuntimeContext
        output = newSeq[uint64](patterns.len)
      type Entry = proc(ctx, arguments, returned, arena: pointer)
        {.cdecl, raises: [].}
      let entry = cast[Entry](cast[uint](buffer.entry()) +
        uint(emitted.offsets[0]))
      entry(ctx.addr, nil, output[0].addr, nil)
      doAssert output == patterns
      buffer.release()
echo "Exact floating constants passed"

## Focused arithmetic check for AMD64 reciprocal division and remainders.
import nifty/backend/[engine, memories]

when defined(amd64):
  type Entry = proc(context, arguments, returned, reserved: pointer) {.cdecl.}

  proc emit(f: var IrFunction, op: IrOpcode, args: openArray[ValueId],
      kind = Int64Type, bits = 0'u64, offset = 0'i64, count = 1): ValueId =
    result = ValueId(f.values.len)
    let operands = Span(first: int32(f.operands.len), count: int32(args.len))
    f.operands.add(args)
    for i in 0 ..< count: f.values.add(IrValue(valueType: kind))
    f.instructions.add(IrInstruction(op: op, bits: bits, offset: offset,
      alignment: 1, arguments: operands,
      results: Span(first: int32(result), count: int32(count))))
    inc f.blocks[0].instructions.count

  var seed = 619'u64
  var inputs = @[0'u64, 1, 2, 3, 6, 7, 10, uint64.high,
    uint64.high - 1, 0x8000000000000000'u64, 0x7fffffffffffffff'u64]
  for i in 0 ..< 128:
    seed = seed * 6364136223846793005'u64 + 1442695040888963407'u64
    inputs.add(seed)
  var checks = 0
  for kind in [Int64Type, UInt64Type]:
    for divisor in [3'u64, 5, 7, 10, 1000000007, 0x7fffffffffffffff'u64,
        0x8000000000000001'u64, uint64.high - 2, uint64.high]:
      var f = IrFunction(name: "constant-divide", failureMode: NoFailCall,
        signature: IrSignature(parameters: @[AddressType, AddressType, AddressType, AddressType]))
      for i in 0 ..< 4: f.values.add(IrValue(valueType: AddressType))
      f.blocks.add(IrBlock(parameters: Span(first: 0, count: 4)))
      let input = f.emit(LoadOp, [ValueId(1)], kind)
      let d = f.emit(ConstantOp, [], kind, divisor)
      let quotient = f.emit(DivideOp, [input, d], kind)
      let remainder = f.emit(RemainderOp, [input, d], kind)
      discard f.emit(StoreOp, [ValueId(2), quotient], count = 0)
      discard f.emit(StoreOp, [ValueId(2), remainder], offset = 8, count = 0)
      f.blocks[0].terminator = IrTerminator(kind: ReturnTerminator)
      let image = emitNative(IrModule(pointerBytes: 8, functions: @[f]), Amd64Target)
      var memory = initCodeBuffer(image.bytes)
      let entry = cast[Entry](cast[uint](memory.entry()) + uint(image.offsets[0]))
      for bits in inputs:
        var input = bits
        var output: array[2, uint64]
        entry(nil, addr input, addr output, nil)
        if kind == UInt64Type:
          doAssert output == [bits div divisor, bits mod divisor]
        else:
          let n = cast[int64](bits)
          let d = cast[int64](divisor)
          if n == low(int64) and d == -1:
            doAssert output == [bits, 0'u64]
          else:
            doAssert output == [cast[uint64](n div d), cast[uint64](n mod d)]
        inc checks
  echo "AMD64 constant division/remainder checks: ", checks
else:
  echo "SKIP AMD64 arithmetic execution on this host"

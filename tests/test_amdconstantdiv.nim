## Shared reciprocal division agrees with hardware division across uint64.
import std/sequtils
import nifty/backend/[engine, memories, iroptimizations, irinterpreters, irconstants]

when defined(amd64) or defined(arm64):
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
    for divisor in [1'u64, 2, 3, 5, 7, 10, 16, 1000000007, 0x7fffffffffffffff'u64,
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
      if kind == UInt64Type:
        let upper = f.emit(MultiplyHighOp, [input, d], kind)
        discard f.emit(StoreOp, [ValueId(2), upper], offset = 16, count = 0)
      f.blocks[0].terminator = IrTerminator(kind: ReturnTerminator)
      var module = IrModule(pointerBytes: 8, functions: @[f])
      if kind == UInt64Type and divisor == 3:
        var portable = module
        optimizeIr(portable)
        doAssert portable.functions[0].instructions.anyIt(it.op == DivideOp)
      optimizeIr(module, fastMultiplyHigh = true)
      if kind == UInt64Type:
        doAssert not module.functions[0].instructions.anyIt(it.op in {DivideOp, RemainderOp})
      # Cross-emit too; execute the current CPU and the portable interpreter.
      discard emitNative(module, Arm64Target)
      let target = when defined(amd64): Amd64Target else: Arm64Target
      let image = emitNative(module, target)
      var interpreter = prepareInterpreter(module)
      var memory = initCodeBuffer(image.bytes)
      let entry = cast[Entry](cast[uint](memory.entry()) + uint(image.offsets[0]))
      for bits in inputs:
        var input = bits
        var output: array[3, uint64]
        entry(nil, addr input, addr output, nil)
        if kind == UInt64Type:
          doAssert output == [bits div divisor, bits mod divisor, multiplyHigh(bits, divisor)]
        else:
          let n = cast[int64](bits)
          let d = cast[int64](divisor)
          if n == low(int64) and d == -1:
            doAssert output == [bits, 0'u64, 0'u64]
          else:
            doAssert output == [cast[uint64](n div d), cast[uint64](n mod d), 0'u64]
        if checks mod 16 == 0:
          var interpreted: array[3, uint64]
          discard interpret(addr interpreter, 0,
            [0'u64, cast[uint64](addr input), cast[uint64](addr interpreted), 0'u64], nil)
          doAssert interpreted == output
        inc checks
      memory.release()
  doAssert multiplyHigh(uint64.high, uint64.high) == uint64.high - 1
  doAssert multiplyHigh(0x8000000000000000'u64, 2) == 1
  var folded = IrFunction(blocks: @[IrBlock()])
  let maximum = folded.emit(ConstantOp, [], UInt64Type, uint64.high)
  let upper = folded.emit(MultiplyHighOp, [maximum, maximum], UInt64Type)
  let constants = folded.constantValues()
  doAssert constants.known[int32(upper)]
  doAssert constants.bits[int32(upper)] == uint64.high - 1
  echo "Shared constant division/remainder and multiply-high checks: ", checks
else:
  echo "SKIP native arithmetic execution on this host"

## Logical shifts use the declared bit width, not a signed 64-bit carrier.
import nifty/backend/[engine, memories, irconstants]

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

proc routine(): IrFunction =
  result = IrFunction(name: "narrow-shift", failureMode: NoFailCall,
    signature: IrSignature(parameters: @[AddressType, AddressType, AddressType, AddressType]))
  for i in 0 ..< 4: result.values.add(IrValue(valueType: AddressType))
  result.blocks.add(IrBlock(parameters: Span(first: 0, count: 4)))

type Entry = proc(context, arguments, returned, reserved: pointer) {.cdecl.}

proc runtimeChecks(kind: IrType, width, shift: int, variable: bool): int =
  var f = routine()
  let input = f.emit(LoadOp, [ValueId(1)], kind)
  let amount = if variable:
      f.emit(LoadOp, [ValueId(1)], kind, offset = 8)
    else: f.emit(ConstantOp, [], kind, uint64(shift))
  let logical = f.emit(ShiftRightOp, [input, amount], kind)
  let arithmetic = f.emit(ArithmeticRightOp, [input, amount], kind)
  discard f.emit(StoreOp, [ValueId(2), logical], count = 0)
  discard f.emit(StoreOp, [ValueId(2), arithmetic], offset = 8, count = 0)
  f.blocks[0].terminator = IrTerminator(kind: ReturnTerminator)
  let module = IrModule(pointerBytes: 8, functions: @[f])
  # Both selector paths must also remain valid when cross-emitting.
  discard emitNative(module, Amd64Target)
  discard emitNative(module, Arm64Target)
  when defined(amd64) or defined(arm64):
    let image = emitNative(module,
      when defined(amd64): Amd64Target else: Arm64Target)
    var memory = initCodeBuffer(image.bytes)
    defer: memory.release()
    let entry = cast[Entry](cast[uint](memory.entry()) + uint(image.offsets[0]))
    let mask = (1'u64 shl width) - 1
    for bits in [1'u64 shl (width - 1), mask, mask shr 1]:
      var input = [bits, uint64(shift)]
      var output: array[2, uint64]
      entry(nil, addr input, addr output, nil)
      let expected = bits shr shift
      doAssert output[0] == expected,
        $kind & " logical right shift " & $shift & ": " & $output[0] & " != " & $expected
      let signed = cast[int64](bits shl (64 - width)) shr (64 - width)
      doAssert output[1] == (cast[uint64](signed shr shift) and mask)
      inc result

var checks = 0
for kind in [Int8Type, Int16Type, Int32Type]:
  let
    width = case kind
      of Int8Type: 8
      of Int16Type: 16
      else: 32
    mask = (1'u64 shl width) - 1
  for shift in [1, width - 1]:
    for variable in [false, true]:
      checks += runtimeChecks(kind, width, shift, variable)
    # Constant folding must agree with the exact same declared-width operation.
    var folded = routine()
    let bits = 1'u64 shl (width - 1)
    let a = folded.emit(ConstantOp, [], kind, bits)
    let b = folded.emit(ConstantOp, [], kind, uint64(shift))
    let value = folded.emit(ShiftRightOp, [a, b], kind)
    folded.blocks[0].terminator = IrTerminator(kind: ReturnTerminator)
    let facts = constantValues(folded)
    doAssert facts.known[int32(value)]
    doAssert (facts.bits[int32(value)] and mask) == bits shr shift
    inc checks

echo "Narrow logical/arithmetic shift checks: ", checks

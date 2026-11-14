## Verifies direct floating conversion operands against declared-width results.
import nifty/backend/[context, engine, irchecks, memories]

proc instruction(function: var IrFunction, op: IrOpcode,
    arguments: openArray[ValueId], kind: IrType, offset = 0'i64,
    conversion = IntegerFloatConversion): ValueId =
  ## Appends a typed conversion fixture operation.
  result = ValueId(function.values.len)
  let span = Span(first: int32(function.operands.len),
    count: int32(arguments.len))
  function.operands.add(arguments)
  let count = if op == StoreOp: 0'i32 else: 1'i32
  if count > 0:
    function.values.add(IrValue(valueType: kind))
  function.instructions.add(IrInstruction(op: op, arguments: span,
    results: Span(first: int32(result), count: count), alignment: 1,
    offset: offset, conversion: conversion))
  inc function.blocks[0].instructions.count

type Conversion = tuple[source, destination: IrType, operation: IrConversion]
var conversions: seq[Conversion]
for source in [Int8Type, UInt8Type, Int16Type, UInt16Type,
    Int32Type, UInt32Type, Int64Type, UInt64Type]:
  for destination in [Float32Type, Float64Type]:
    conversions.add((source, destination, IntegerFloatConversion))
conversions.add((Float64Type, Int64Type, FloatIntegerConversion))
conversions.add((Float64Type, Float32Type, FloatWidthConversion))
conversions.add((Float32Type, Float64Type, FloatWidthConversion))

var module = IrModule(pointerBytes: 8)
for index, conversion in conversions:
  var function = IrFunction(name: "convert" & $index,
    failureMode: NoFailCall, signature: IrSignature(parameters:
      @[AddressType, AddressType, AddressType, AddressType]))
  for i in 0 ..< 4:
    function.values.add(IrValue(valueType: AddressType))
  function.blocks.add(IrBlock(parameters: Span(first: 0, count: 4),
    terminator: IrTerminator(kind: ReturnTerminator)))
  let
    input = function.instruction(LoadOp, [ValueId(1)], conversion.source)
    output = function.instruction(ConvertOp, [input], conversion.destination,
      conversion = conversion.operation)
  discard function.instruction(StoreOp, [ValueId(2), output],
    conversion.destination)
  discard function.instruction(StoreOp, [ValueId(2), input],
    conversion.source, offset = 8)
  module.functions.add(function)

proc signed(bits: uint64, kind: IrType): int64 =
  ## Reconstructs the source's signed declared width without overflow.
  case kind
  of Int8Type: int64(cast[int8](uint8(bits and 255)))
  of Int16Type: int64(cast[int16](uint16(bits and 65535)))
  of Int32Type: int64(cast[int32](uint32(bits and 0xffffffff'u64)))
  else: cast[int64](bits)

proc unsigned(bits: uint64, kind: IrType): uint64 =
  ## Reconstructs the source's unsigned declared width.
  case kind
  of UInt8Type: bits and 255
  of UInt16Type: bits and 65535
  of UInt32Type: bits and 0xffffffff'u64
  else: bits

proc expected(bits: uint64, conversion: Conversion): uint64 =
  ## Computes the same single conversion with the host compiler.
  case conversion.operation
  of IntegerFloatConversion:
    if conversion.source in {Int8Type, Int16Type, Int32Type, Int64Type}:
      let input = signed(bits, conversion.source)
      if conversion.destination == Float32Type:
        uint64(cast[uint32](float32(input)))
      else: cast[uint64](float64(input))
    else:
      let input = unsigned(bits, conversion.source)
      if conversion.destination == Float32Type:
        uint64(cast[uint32](float32(input)))
      else: cast[uint64](float64(input))
  of FloatIntegerConversion:
    let input = cast[float64](bits)
    if input != input: 0'u64
    elif input >= 9223372036854775808.0: uint64(high(int64))
    elif input <= -9223372036854775808.0: cast[uint64](low(int64))
    else: cast[uint64](int64(input))
  of FloatWidthConversion:
    if conversion.source == Float32Type:
      cast[uint64](float64(cast[float32](uint32(bits and 0xffffffff'u64))))
    else: uint64(cast[uint32](float32(cast[float64](bits))))
  else: 0'u64

let inputs = [0'u64, 1'u64, uint64.high, 0x8000000000000000'u64,
  0x7fffffffffffffff'u64, 0x0020000000000001'u64, 0x01000001'u64,
  0x3ff8000000000000'u64, 0xbff8000000000000'u64,
  0x43e0000000000000'u64, 0xc3e0000000000000'u64,
  0x7ff0000000000000'u64, 0xfff0000000000000'u64,
  0x7ff8000000001234'u64, 0x7ff0000000001234'u64,
  0x000000007fc01234'u64, 0x000000007f801234'u64,
  0x0000000080000000'u64, 0x000000003f800001'u64]

for target in NativeTarget:
  let image = emitNative(module, target)
  doAssert image.bytes.len > 0
  when defined(arm64):
    if target == Arm64Target:
      var buffer = initCodeBuffer(image.bytes)
      var ctx: RuntimeContext
      type Entry = proc(ctx, arguments, returned, reserved: pointer)
        {.cdecl, raises: [].}
      for index, conversion in conversions:
        let call = cast[Entry](cast[uint](buffer.entry()) +
          uint(image.offsets[index]))
        for bits in inputs:
          var input = bits
          var output: array[2, uint64]
          call(ctx.addr, input.addr, output.addr, nil)
          doAssert output[0] == expected(bits, conversion)
          let width = byteCount(conversion.source, 8)
          let mask = if width == 8: high(uint64)
            else: (1'u64 shl (int(width) * 8)) - 1
          doAssert output[1] == (bits and mask)
      buffer.release()

echo "Direct native floating conversions passed"

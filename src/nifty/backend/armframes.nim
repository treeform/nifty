import common, arms, irs, ircopies

const
  DefaultArmPairedSaves* = not defined(nimkeyNoArmPairedSaves)
  DefaultArmLeafFrames* = defined(nimkeyArmLeafFrames) and
    not defined(nimkeyNoArmLeafFrames)

proc leafFrame*(function: IrFunction): bool {.raises: [].} =
  ## Proves that no call, globals binding, or frame observation needs a header.
  for data in function.blocks:
    for index in data.instructions.indices:
      if function.instructions[index].op in
        {CallOp, HostCallOp, IndirectCallOp, GlobalAddressOp, FrameSizeOp}:
          return false
  true

proc leafScratch*(function: IrFunction, incoming, locations: openArray[int],
    floatBits: bool, unusedCopies = DefaultIrUnusedCopies): int {.raises: [].} =
  ## Reserves one payload only for actual copy cycles or memory bit transfers.
  for item in scheduleCopies(parameterCopies(function, incoming, locations,
      unusedCopies)):
    if item.destination == CopyScratch:
      return 8
  for data in function.blocks:
    if data.terminator.kind == ReturnTerminator and
      data.terminator.arguments.count > 1:
        var copies: seq[IrCopy]
        for i in 0 ..< int(data.terminator.arguments.count):
          let value = function.operands[
            data.terminator.arguments.first + int32(i)]
          copies.add(IrCopy(source: locations[int32(value)],
            destination: FloatCopyBase + i, valueType: Float32Type))
        for item in scheduleCopies(copies):
          if item.destination == CopyScratch:
            return 8
    for index in data.terminator.edges.indices:
      for item in scheduleCopies(edgeCopies(function, index, locations)):
        if item.destination == CopyScratch:
          return 8
    for index in data.instructions.indices:
      let item = function.instructions[index]
      if item.results.count != 1:
        continue
      let kind = function.values[item.results.first].valueType
      if item.op == ConstantOp and kind in
        {Float32Type, Float64Type, Float32x2Type}:
          if kind == Float32Type and not defined(nimkeyNoArmFloatConstants):
            continue
          if kind == Float32x2Type and not defined(nimkeyNoArmVectorConstants):
            continue
          return 8
      if item.op == ConvertOp and item.conversion notin
        {IntegerFloatConversion, FloatIntegerConversion, FloatWidthConversion}:
          let source = function.values[
            int32(function.operands[item.arguments.first])].valueType
          if source notin {Float32Type, Float64Type, Float32x2Type} and
            kind notin {Float32Type, Float64Type, Float32x2Type}:
              continue
          if floatBits and item.conversion == BitcastConversion and
            ((source == Float32Type and kind in {Int32Type, UInt32Type}) or
              (source in {Int32Type, UInt32Type} and kind == Float32Type)):
                continue
          return 8
  0

proc preserveRegisters*(code: var Assembler, floats, integers: openArray[int],
    restore: bool, paired = DefaultArmPairedSaves)
    {.raises: [BackendError].} =
  ## Transfers allocated preserved registers through adjacent frame slots.
  ## The fixed frame header occupies the first 32 bytes; each value uses eight.
  var i = 0
  while i < floats.len:
    let offset = 32 + i * 8
    if paired and DefaultArmPairedSaves and i + 1 < floats.len:
      if restore:
        code.loadFloatPair(floats[i], floats[i + 1], StackPointer, offset)
      else:
        code.storeFloatPair(floats[i], floats[i + 1], StackPointer, offset)
      i += 2
    else:
      if restore:
        code.loadFloat(floats[i], StackPointer, offset)
      else:
        code.storeFloat(floats[i], StackPointer, offset)
      inc i
  i = 0
  while i < integers.len:
    let offset = 32 + (floats.len + i) * 8
    if paired and DefaultArmPairedSaves and i + 1 < integers.len:
      if restore:
        code.loadPair(
          Register(integers[i]),
          Register(integers[i + 1]),
          StackPointer,
          offset
        )
      else:
        code.storePair(
          Register(integers[i]),
          Register(integers[i + 1]),
          StackPointer,
          offset
        )
      i += 2
    else:
      if restore:
        code.loadDouble(Register(integers[i]), StackPointer, offset)
      else:
        code.storeDouble(Register(integers[i]), StackPointer, offset)
      inc i

## Emits ARM64 exclusively from verified scalar and memory IR.
import
  common, context,
  irs as ir, irchecks, irallocations, irlifetimes, ircopies, ircontexts, irbranches,
  armplans, armframes, irprocedures, arms as machine

const
  DefaultArmAbiFloats* = not defined(nimkeyNoArmAbiFloats) and
    not defined(nimkeyNoIrAllocation)
  DefaultArmVectorSpills* = not defined(nimkeyNoArmVectorSpills)
  DefaultArmFloatBits* = not defined(nimkeyNoArmFloatBits)
  DefaultArmFloatZeros* = not defined(nimkeyNoArmFloatZeros)
  DefaultArmFloatLoads* = not defined(nimkeyNoArmFloatLoads)
  DefaultArmGlobalBindings* = defined(nimkeyArmGlobalBindings) and
    not defined(nimkeyNoArmGlobalBindings)
  DefaultArmUnsignedWords* = defined(nimkeyArmUnsignedWords) and
    not defined(nimkeyNoArmUnsignedWords)

type
  ValuePlace = object
    register: int
    offset: int

  IrMachineImage* = object
    words*: seq[uint32]
    offsets*: seq[int]
    frameBytes*: seq[int]
    wrapperFrameBytes*: int

  ArgumentLayout = object
    locations: seq[int]
    stackBytes: int

proc argumentLayout(kinds: openArray[ir.IrType], stackBase = 0,
    host = false):
    ArgumentLayout {.raises: [].} =
  ## Assigns private scalar arguments to eight registers per bank, then slots.
  var integers, floats = 0
  for kind in kinds:
    let register = if kind.floating(): floats else: integers
    if kind.floating():
      inc floats
    else:
      inc integers
    if register < 8:
      result.locations.add(copyLocation(kind, register, 0))
    else:
      let width = int(byteCount(kind, 8))
      when defined(macosx):
        if host:
          result.stackBytes = aligned(result.stackBytes, width)
      result.locations.add(copyLocation(kind, -1,
        stackBase + result.stackBytes))
      when defined(macosx):
        result.stackBytes += (if host: width else: 8)
      else:
        result.stackBytes += 8

proc comparisonCondition(comparison: ir.IrComparison,
    kind: ir.IrType): machine.Condition {.raises: [].} =
  ## Uses the same ordered floating predicates for booleans and direct branches.
  let
    floating = kind in {ir.Float32Type, ir.Float64Type}
    unsigned = kind in {ir.UInt8Type, ir.UInt16Type, ir.UInt32Type,
      ir.UInt64Type, ir.AddressType, ir.BoolType}
  case comparison
  of ir.EqualComparison: EqualCondition
  of ir.NotEqualComparison: NotEqualCondition
  of ir.LessComparison:
    if unsigned or floating: CarryClearCondition else: LessCondition
  of ir.LessEqualComparison:
    if unsigned or floating: UnsignedLessEqualCondition else: LessEqualCondition
  of ir.GreaterComparison:
    if unsigned: UnsignedGreaterCondition else: GreaterCondition
  of ir.GreaterEqualComparison:
    if unsigned: CarrySetCondition else: GreaterEqualCondition

proc memorySnapshot(code: var machine.Assembler, bytes: int,
    firstFloat, secondFloat: int, baseOffset = 0) =
  ## Loads every source byte before storing, preserving arbitrary overlap.
  # X12..X17 and the selected float pair are excluded from allocation.
  doAssert bytes in 1 .. 48
  let vectors = min(bytes div 16, 2)
  if vectors == 2:
    code.vectorPair(firstFloat, secondFloat, X13, baseOffset, false)
  elif vectors == 1:
    code.vectorMemory(firstFloat, X13, baseOffset, false)
  var
    offset = baseOffset + vectors * 16
    parts: seq[tuple[offset, width: int, register: machine.Register]]
    next = 0
  const Registers = [X14, X15, X16, X17]
  if bytes + baseOffset - offset == 16:
    code.loadPair(X14, X15, X13, offset)
    parts.add((offset, 16, X14))
    offset += 16
  for width in [8, 4, 2, 1]:
    if bytes + baseOffset - offset >= width:
      let register = Registers[next]
      inc next
      case width
      of 8: code.loadDouble(register, X13, offset)
      of 4: code.loadWord(register, X13, offset)
      of 2: code.loadHalf(register, X13, offset)
      else: code.loadByte(register, X13, offset)
      parts.add((offset, width, register))
      offset += width
  if vectors == 2:
    code.vectorPair(firstFloat, secondFloat, X12, baseOffset, true)
  elif vectors == 1:
    code.vectorMemory(firstFloat, X12, baseOffset, true)
  for part in parts:
    case part.width
    of 16: code.storePair(X14, X15, X12, part.offset)
    of 8: code.storeDouble(part.register, X12, part.offset)
    of 4: code.storeWord(part.register, X12, part.offset)
    of 2: code.storeHalf(part.register, X12, part.offset)
    else: code.storeByte(part.register, X12, part.offset)

proc clearMemory(code: var machine.Assembler, bytes: int) =
  ## Clears exact bounds using paired words and a narrow final remainder.
  var remaining = bytes
  if remaining > 128:
    let repeat = code.label()
    code.loadImmediate(Word64, X14, int64(remaining div 32))
    code.place(repeat)
    code.storePair(ZeroRegister, ZeroRegister, X12, 0)
    code.storePair(ZeroRegister, ZeroRegister, X12, 16)
    code.addImmediate(Word64, X12, X12, 32)
    code.subtractImmediate(Word64, X14, X14, 1)
    code.branchIfNotZero(Word64, X14, repeat)
    remaining = remaining mod 32
  var offset = 0
  while remaining >= 16:
    code.storePair(ZeroRegister, ZeroRegister, X12, offset)
    offset += 16
    remaining -= 16
  for width in [8, 4, 2, 1]:
    if remaining >= width:
      case width
      of 8: code.storeDouble(ZeroRegister, X12, offset)
      of 4: code.storeWord(ZeroRegister, X12, offset)
      of 2: code.storeHalf(ZeroRegister, X12, offset)
      else: code.storeByte(ZeroRegister, X12, offset)
      offset += width
      remaining -= width

proc moveMemory(code: var machine.Assembler, bytes: int,
    firstFloat, secondFloat: int) =
  ## Moves exact bounds with snapshots or directional 32-byte iterations.
  let finished = code.label()
  code.compareRegister(Word64, X12, X13)
  code.branchIf(EqualCondition, finished)
  if bytes <= 48:
    code.memorySnapshot(bytes, firstFloat, secondFloat)
  elif bytes <= 128:
    let
      backward = code.label()
      tail = bytes mod 32
      head = bytes - tail
    code.branchIf(UnsignedGreaterCondition, backward)
    for offset in countup(0, head - 32, 32):
      code.vectorPair(firstFloat, secondFloat, X13, offset, false)
      code.vectorPair(firstFloat, secondFloat, X12, offset, true)
    if tail > 0:
      code.memorySnapshot(tail, firstFloat, secondFloat, head)
    code.branch(finished)
    code.place(backward)
    if tail > 0:
      code.memorySnapshot(tail, firstFloat, secondFloat, head)
    for offset in countdown(head - 32, 0, 32):
      code.vectorPair(firstFloat, secondFloat, X13, offset, false)
      code.vectorPair(firstFloat, secondFloat, X12, offset, true)
  else:
    let
      backward = code.label()
      forward = code.label()
      repeat = code.label()
      tail = bytes mod 32
    code.branchIf(UnsignedGreaterCondition, backward)
    code.loadImmediate(Word64, X14, int64(bytes div 32))
    code.place(forward)
    code.vectorPair(firstFloat, secondFloat, X13, 0, false)
    code.vectorPair(firstFloat, secondFloat, X12, 0, true)
    code.addImmediate(Word64, X12, X12, 32)
    code.addImmediate(Word64, X13, X13, 32)
    code.subtractImmediate(Word64, X14, X14, 1)
    code.branchIfNotZero(Word64, X14, forward)
    if tail > 0:
      code.memorySnapshot(tail, firstFloat, secondFloat)
    code.branch(finished)
    code.place(backward)
    code.loadImmediate(Word64, X14, int64(bytes - tail))
    code.addRegister(Word64, X12, X12, X14)
    code.addRegister(Word64, X13, X13, X14)
    if tail > 0:
      code.memorySnapshot(tail, firstFloat, secondFloat)
    code.loadImmediate(Word64, X14, int64(bytes div 32))
    code.place(repeat)
    code.subtractImmediate(Word64, X12, X12, 32)
    code.subtractImmediate(Word64, X13, X13, 32)
    code.vectorPair(firstFloat, secondFloat, X13, 0, false)
    code.vectorPair(firstFloat, secondFloat, X12, 0, true)
    code.subtractImmediate(Word64, X14, X14, 1)
    code.branchIfNotZero(Word64, X14, repeat)
  code.place(finished)

proc emitArm64Ir*(module: ir.IrModule,
    maxBytes: int, pairedSaves = DefaultArmPairedSaves,
    floatColors = DefaultIrFloatColors,
    vectorSpills = DefaultArmVectorSpills,
    floatBits = DefaultArmFloatBits,
    unsignedWords = DefaultArmUnsignedWords,
    globalBindings = DefaultArmGlobalBindings,
    floatZeros = DefaultArmFloatZeros,
    floatLoads = DefaultArmFloatLoads,
    leafFrames = DefaultArmLeafFrames,
    abiFloats = DefaultArmAbiFloats,
    unusedCopies = DefaultIrUnusedCopies,
    branchPairs = DefaultArmBranchPairs): IrMachineImage
    {.raises: [BackendError].} =
  ## Assigns physical locations only after the complete IR module is verified.
  let
    useAbiFloats = abiFloats and not defined(nimkeyNoArmAbiFloats) and
      not defined(nimkeyNoIrAllocation)
    scratchFloat = if useAbiFloats: 6 else: 0
    scratchFloat2 = if useAbiFloats: 7 else: 1
    volatileFloats = if useAbiFloats: 22 else: 16
  verifyIr(module)
  verifyReturnAbi(module)
  if module.functions.len == 0 or maxBytes < 1:
    error("ARM64 IR requires an entry procedure and a positive code limit")
  for index, function in module.functions:
    if function.signature.parameters.len == 0 or
        function.signature.parameters[0] != ir.AddressType or
        (index == 0 and function.signature.parameters !=
          @[ir.AddressType, ir.AddressType, ir.AddressType, ir.AddressType]) or
        (index == 0 and function.signature.returns.len != 0):
        error("ARM64 IR requires a context argument and a storage entry ABI")
  var
    code: machine.Assembler
    entries: seq[machine.Label]
  for function in module.functions:
    entries.add(code.label())
  let entryBytes = if globalBindings: 16 else: 32
  result.wrapperFrameBytes = entryBytes
  result.frameBytes = newSeq[int](module.functions.len)
  code.storePair(FramePointer, LinkRegister, StackPointer, -entryBytes, true)
  if not globalBindings:
    code.storePair(X19, X20, StackPointer, 16)
    code.moveRegister(Word64, X19, X0)
    code.loadDouble(X20, X19, offsetOf(RuntimeContext, globals))
    code.moveRegister(Word64, X0, X19)
  code.loadImmediate(Word64, X1, 0)
  code.loadImmediate(Word64, X2, 0)
  code.loadImmediate(Word64, X3, 0)
  code.branchLink(entries[0])
  if not globalBindings:
    code.loadPair(X19, X20, StackPointer, 16)
  code.loadPair(FramePointer, LinkRegister, StackPointer, entryBytes, true)
  code.returnToCaller()
  for index, function in module.functions:
    if function.trapBody():
      code.place(entries[index])
      code.trap()
      if code.position() > maxBytes div 4:
        error("Native code size exceeds limits")
      continue
    let
      leaf = leafFrames and not defined(nimkeyNoArmLeafFrames) and
        leafFrame(function)
      contextRegister = if leaf: X0 else: X19
    var needsGlobals = not globalBindings and not leaf
    if not leaf:
      for item in function.instructions:
        needsGlobals = needsGlobals or item.op == ir.GlobalAddressOp
    let
      contexts = contextAliases(function, module.pointerBytes)
      branches = branchComparisons(function)
      bits = bitBranches(function, branches)
      selections = selectFlags(function)
      immediates = integerImmediates(function)
      zeros = floatZeroComparisons(function, floatZeros)
    var fixed = newSeq[bool](function.values.len)
    for value in 0 ..< fixed.len:
      fixed[value] = contexts[value] or branches.conditions[value] or
        bits.omitted[value] or selections.conditions[value] or
        immediates.omitted[value] or zeros.omitted[value]
    const ArgumentHeaderBytes = 32
    var allocation: IrAllocation
    when defined(nimkeyNoIrAllocation):
      allocation.registers = newSeq[int32](function.values.len)
      for register in allocation.registers.mitems:
        register = -1
    else:
      var preservedFloats, integerMask: uint64
      when not defined(nimkeyNoArmPreservedFloats) or
        not defined(nimkeyNoArmPreservedIntegers):
        let crossing = liveAcrossCalls(function, analyzeLiveness(function))
        var constants = newSeq[bool](function.values.len)
        for item in function.instructions:
          if item.op in {ir.ConstantOp, ir.FrameSizeOp}:
            constants[item.results.first] = true
        for value, crosses in crossing:
          if not crosses or constants[value] or fixed[value]:
            continue
          when not defined(nimkeyNoArmPreservedFloats):
            if function.values[value].valueType in
                {ir.Float32Type, ir.Float64Type, ir.Float32x2Type}:
              preservedFloats = 0xff'u64 shl volatileFloats
          when not defined(nimkeyNoArmPreservedIntegers):
            if not function.values[value].valueType.floating():
              integerMask = 0x3fc0'u64
      let preferences = if useAbiFloats: floatAbiPreferences(function)
        else: @[]
      allocation = allocateRegisters(
        function,
        integers = (if integerMask != 0: 14 else: 6),
        floats = volatileFloats + (if preservedFloats != 0: 8 else: 0),
        preservedFloats = preservedFloats,
        preservedIntegers = integerMask,
        fixedValues = fixed,
        floatColors = floatColors,
        preferredRegisters = preferences
      )
    let loadPairs = floatLoadPairs(function, allocation.registers,
      floatLoads and DefaultArmFloatLoads)
    var preserved, preservedIntegers: seq[int]
    for register in volatileFloats ..< volatileFloats + 8:
      if int32(register) in allocation.registers:
        preserved.add(register - volatileFloats + 8)
    for register in 6 ..< 14:
      for value, assigned in allocation.registers:
        if assigned == int32(register) and
          not function.values[value].valueType.floating():
            preservedIntegers.add(register + 15)
            break
    let
      integerHeader = ArgumentHeaderBytes + preserved.len * 8
      headerBytes = if leaf: 0
        else: aligned(integerHeader + preservedIntegers.len * 8, 16)
    if leaf:
      doAssert preserved.len == 0 and preservedIntegers.len == 0
    var outgoingBytes = 0
    for item in function.instructions:
      if item.op notin {ir.CallOp, ir.HostCallOp, ir.IndirectCallOp}:
        continue
      var kinds: seq[ir.IrType]
      let first = ord(item.op == ir.IndirectCallOp)
      for i in first ..< int(item.arguments.count):
        kinds.add(function.values[int32(function.operands[
          item.arguments.first + int32(i)])].valueType)
      let layout = argumentLayout(kinds, host = item.op == ir.HostCallOp)
      outgoingBytes = max(outgoingBytes, layout.stackBytes)
    var
      places = newSeq[ValuePlace](function.values.len)
      slots: seq[int]
      locations: seq[int]
      frameBytes = aligned(outgoingBytes, 16)
      labels: seq[machine.Label]
    for slot in function.slots:
      frameBytes = aligned(frameBytes, int(slot.alignment))
      slots.add(frameBytes)
      frameBytes += int(slot.byteCount)
    frameBytes = aligned(frameBytes, 8)
    for value in 0 ..< function.values.len:
      if branches.conditions[value] or bits.omitted[value] or
        selections.conditions[value] or immediates.omitted[value] or
        zeros.omitted[value]:
          locations.add(-1)
          continue
      let register = int(allocation.registers[value])
      if contexts[value]:
        places[value].register = contextRegister.ord + 1
      elif register >= 0:
        places[value].register =
          if function.values[value].valueType.floating():
            (if useAbiFloats:
              if register < 6: register + 1
              elif register < 22: register + 11
              else: register - 13
            else:
              if register < 16: register + 17 else: register - 7)
          else:
            (if register < 6: register + 4 else: register + 16)
      else:
        places[value].offset = frameBytes
        frameBytes += 8
      locations.add(copyLocation(function.values[value].valueType,
        if places[value].register > 0: places[value].register - 1 else: -1,
        places[value].offset))
    let callArea = frameBytes
    var maxArguments = 8
    for data in function.blocks:
      maxArguments = max(maxArguments, int(data.parameters.count))
      labels.add(code.label())
    let scratchBytes = if leaf:
        leafScratch(
          function,
          argumentLayout(function.signature.parameters, frameBytes).locations,
          locations,
          floatBits,
          unusedCopies
        )
      else: maxArguments * 8
    frameBytes = aligned(frameBytes + scratchBytes, 16)
    when defined(nimkeyNoArmEntryCopies):
      let entryArea = frameBytes
      frameBytes = aligned(
        frameBytes + function.signature.parameters.len * 8,
        16
      )
    if frameBytes > MaxFrameBytes:
      error("IR native frame exceeds limits")
    result.frameBytes[index] = frameBytes + headerBytes
    proc address(code: var machine.Assembler, destination: machine.Register,
        offset: int) =
      ## Computes an arbitrarily sized concrete frame displacement.
      if offset <= 4095:
        code.addImmediate(Word64, destination, StackPointer, offset)
      else:
        code.addImmediate(Word64, destination, StackPointer, 0)
        code.loadImmediate(Word64, X17, offset)
        code.addRegister(Word64, destination, destination, X17)
    proc integer(code: var machine.Assembler, value: ir.ValueId,
        destination: machine.Register) =
      ## Reads one assigned integer register or typed spill.
      doAssert not branches.conditions[int32(value)] and
        not selections.conditions[int32(value)] and
        not immediates.omitted[int32(value)]
      let place = places[int32(value)]
      if place.register > 0:
        code.moveRegister(Word64, destination,
          machine.Register(place.register - 1))
      else:
        code.address(X15, place.offset)
        code.loadDouble(destination, X15)
    proc floatFrameOperand(code: var machine.Assembler, offset: int,
        scratch: machine.Register, kind: ir.IrType):
        tuple[base: machine.Register, offset: int] =
      ## Encodes scalar or packed floating stack displacements directly.
      if vectorSpills and kind == ir.Float32x2Type and
        offset >= 0 and offset mod 8 == 0 and offset div 8 <= 4095:
          return (StackPointer, offset)
      when not defined(nimkeyNoArmFloatSpills):
        let width = if kind == ir.Float32Type: 4 else: 8
        if kind in {ir.Float32Type, ir.Float64Type} and offset >= 0 and
          offset mod width == 0 and offset div width <= 4095:
            return (StackPointer, offset)
      code.address(scratch, offset)
      (scratch, 0)
    proc floating(code: var machine.Assembler, value: ir.ValueId,
        destination: int) =
      ## Reads a floating value at its declared precision.
      doAssert not zeros.omitted[int32(value)]
      let
        place = places[int32(value)]
        kind = function.values[int32(value)].valueType
        single = kind == ir.Float32Type
      if place.register > 0:
        if place.register - 1 != destination:
          code.floatUnary(0, destination, place.register - 1, single)
      else:
        let memory = code.floatFrameOperand(place.offset, X15, kind)
        code.loadFloat(destination, memory.base, memory.offset, single)
    proc integerOperand(code: var machine.Assembler, value: ir.ValueId,
        scratch: machine.Register): machine.Register =
      ## Uses an allocated general register directly and loads only spills.
      when not defined(nimkeyNoArmGeneralOperands):
        if places[int32(value)].register > 0:
          return machine.Register(places[int32(value)].register - 1)
      code.integer(value, scratch)
      scratch
    proc integerDestination(value: int): machine.Register =
      ## Selects the assigned general result register or the usual scratch.
      when not defined(nimkeyNoArmGeneralOperands):
        if places[value].register > 0:
          return machine.Register(places[value].register - 1)
      X12
    proc floatOperand(code: var machine.Assembler, value: ir.ValueId,
        scratch: int): int =
      ## Reads floating values directly from registers, loading only spills.
      when not defined(nimkeyNoArmFloatOperands):
        if function.values[int32(value)].valueType in
            {ir.Float32Type, ir.Float64Type, ir.Float32x2Type} and
            places[int32(value)].register > 0:
            return places[int32(value)].register - 1
      code.floating(value, scratch)
      scratch
    proc floatOperand(code: var machine.Assembler, value: ir.ValueId,
        scratch: int, previous: ir.ValueId, previousRegister: int): int =
      ## Reuses one floating input read twice by the same instruction.
      when not defined(nimkeyNoArmSharedFloatOperands):
        if int32(value) == int32(previous) and
          function.values[int32(value)].valueType in
          {ir.Float32Type, ir.Float64Type, ir.Float32x2Type}:
            return previousRegister
      code.floatOperand(value, scratch)
    proc floatDestination(value: int): int =
      ## Selects an allocated floating result or the normal scratch register.
      when not defined(nimkeyNoArmFloatOperands):
        if function.values[value].valueType in
            {ir.Float32Type, ir.Float64Type, ir.Float32x2Type} and
            places[value].register > 0:
            return places[value].register - 1
      scratchFloat
    proc putInteger(code: var machine.Assembler, value: int,
        source = X12) =
      ## Stores one scalar definition into its assigned physical location.
      let place = places[value]
      if place.register > 0:
        when not defined(nimkeyNoArmGeneralOperands):
          if place.register - 1 == source.ord:
            return
        code.moveRegister(Word64, machine.Register(place.register - 1), source)
      else:
        code.address(X15, place.offset)
        code.storeDouble(source, X15)
    proc putFloat(code: var machine.Assembler, value: int, source: int) =
      ## Stores a floating definition without widening its value.
      let
        place = places[value]
        kind = function.values[value].valueType
        single = kind == ir.Float32Type
      if place.register > 0:
        when not defined(nimkeyNoArmFloatOperands):
          if kind.floating() and place.register - 1 == source:
            return
        code.floatUnary(0, place.register - 1, source, single)
      else:
        let memory = code.floatFrameOperand(place.offset, X15, kind)
        code.storeFloat(source, memory.base, memory.offset, single)
    proc normalize(code: var machine.Assembler, kind: ir.IrType,
        destination = X12) =
      ## Enforces declared integer wrapping widths after arithmetic.
      if unsignedWords and kind == ir.UInt32Type:
        code.moveRegister(Word32, destination, destination)
        return
      case kind
      of ir.Int8Type: code.signExtend(destination, destination, 8)
      of ir.Int16Type: code.signExtend(destination, destination, 16)
      of ir.Int32Type: code.signExtendWord(destination, destination)
      of ir.BoolType, ir.CharType, ir.UInt8Type, ir.UInt16Type, ir.UInt32Type:
        let mask = case kind
          of ir.BoolType: 1'i64
          of ir.CharType, ir.UInt8Type: 255'i64
          of ir.UInt16Type: 65535'i64
          else: 0xffffffff'i64
        when not defined(nimkeyArmIntegerImmediates) or
          defined(nimkeyNoArmIntegerImmediates):
          code.loadImmediate(Word64, X14, mask)
          code.andRegister(Word64, destination, destination, X14)
        else:
          code.logicalImmediate(
            Word64, AndOperation, destination, destination, uint64(mask)
          )
      else: discard
    proc emitCopies(code: var machine.Assembler, copies: openArray[IrCopy]) =
      ## Encodes shared register and spill transfers without blanket staging.
      for item in scheduleCopies(copies):
        let
          source = if item.source == CopyScratch: StackCopyBase + callArea
            else: item.source
          destination = if item.destination == CopyScratch:
              StackCopyBase + callArea
            else: item.destination
          single = item.valueType == ir.Float32Type
        if source >= StackCopyBase and destination >= StackCopyBase:
          let input = code.floatFrameOperand(
            source - StackCopyBase,
            X13,
            item.valueType
          )
          if single:
            code.loadWord(X12, input.base, input.offset)
          else:
            code.loadDouble(X12, input.base, input.offset)
          let output = code.floatFrameOperand(
            destination - StackCopyBase,
            X13,
            item.valueType
          )
          if single:
            code.storeWord(X12, output.base, output.offset)
          else:
            code.storeDouble(X12, output.base, output.offset)
        elif item.valueType.floating():
          if source >= StackCopyBase:
            let memory = code.floatFrameOperand(
              source - StackCopyBase,
              X13,
              item.valueType
            )
            code.loadFloat(
              destination - FloatCopyBase,
              memory.base,
              memory.offset,
              single
            )
          elif destination >= StackCopyBase:
            let memory = code.floatFrameOperand(
              destination - StackCopyBase,
              X13,
              item.valueType
            )
            code.storeFloat(
              source - FloatCopyBase,
              memory.base,
              memory.offset,
              single
            )
          else:
            code.floatUnary(0, destination - FloatCopyBase,
              source - FloatCopyBase, single)
        elif source >= StackCopyBase:
          code.address(X13, source - StackCopyBase)
          code.loadDouble(machine.Register(destination), X13)
        elif destination >= StackCopyBase:
          code.address(X13, destination - StackCopyBase)
          code.storeDouble(machine.Register(source), X13)
        else:
          code.moveRegister(Word64, machine.Register(destination),
            machine.Register(source))
    proc emitEdge(code: var machine.Assembler, edgeIndex: int) =
      ## Transfers block arguments using the same plan as other native targets.
      code.emitCopies(edgeCopies(function, edgeIndex, locations))
      code.branch(labels[int32(function.edges[edgeIndex].target)])
    code.place(entries[index])
    if not leaf:
      code.storePair(
        FramePointer,
        LinkRegister,
        StackPointer,
        -headerBytes,
        true
      )
      code.storePair(X19, X20, StackPointer, 16)
      code.preserveRegisters(preserved, preservedIntegers, false, pairedSaves)
      code.addImmediate(Word64, FramePointer, StackPointer, 0)
      code.moveRegister(Word64, X19, X0)
    if needsGlobals:
      code.loadDouble(X20, X19, offsetOf(RuntimeContext, globals))
    code.stackAdjustment(frameBytes, true)
    let entry = function.blocks[0].parameters
    var incoming = argumentLayout(function.signature.parameters,
      frameBytes + headerBytes).locations
    if contexts[int(entry.first)]:
      incoming[0] = contextRegister.ord
    when defined(nimkeyNoArmEntryCopies):
      var staged: seq[IrCopy]
      for i, kind in function.signature.parameters:
        let destination = StackCopyBase + entryArea + i * 8
        staged.add(IrCopy(source: incoming[i], destination: destination,
          valueType: kind))
        incoming[i] = destination
      code.emitCopies(staged)
    code.emitCopies(parameterCopies(function, incoming, locations,
      unusedCopies))
    let finish = code.label()
    for owner, data in function.blocks:
      code.place(labels[owner])
      for instructionIndex in data.instructions.indices:
        if bits.skipped[instructionIndex]:
          continue
        if instructionIndex > data.instructions.first and
          loadPairs[instructionIndex - 1]:
            continue
        let item = function.instructions[instructionIndex]
        if loadPairs[instructionIndex]:
          let
            second = function.instructions[instructionIndex + 1]
            base = code.integerOperand(
              function.operands[item.arguments.first], X13)
          code.loadFloatPair(
            places[item.results.first].register - 1,
            places[second.results.first].register - 1,
            base,
            int(item.offset),
            single = function.values[item.results.first].valueType ==
              ir.Float32Type
          )
          continue
        let resultId = int(item.results.first)
        if item.results.count == 1 and
          (immediates.omitted[resultId] or zeros.omitted[resultId]):
            continue
        let resultKind = if item.results.count > 0:
            function.values[resultId].valueType
          else: ir.UInt64Type
        let single = resultKind == ir.Float32Type
        var
          floatResult = scratchFloat
          integerResult = X12
        proc operand(i: int): ir.ValueId =
          ## Resolves one explicit operand of the current instruction.
          function.operands[int(item.arguments.first) + i]
        proc operandKind(i: int): ir.IrType =
          ## Reads the concrete type before selecting a target instruction.
          function.values[int32(operand(i))].valueType
        case item.op
        of ir.ConstantOp, ir.FrameSizeOp:
          const
            DirectConstants = not defined(nimkeyNoArmFloatConstants)
            DirectVectors = not defined(nimkeyNoArmVectorConstants)
          if DirectConstants and single and item.op == ir.ConstantOp:
            floatResult = floatDestination(resultId)
            let bits = uint32(item.bits and 0xffffffff'u64)
            if bits == 0:
              code.bitsToFloat(floatResult, ZeroRegister, single = true)
            elif not code.floatImmediate(floatResult, bits):
              code.loadImmediate(Word32, X12, int64(bits))
              code.bitsToFloat(floatResult, X12, single = true)
          elif DirectConstants and resultKind == ir.Float64Type and
              item.op == ir.ConstantOp:
            floatResult = floatDestination(resultId)
            if item.bits == 0:
              code.bitsToFloat(floatResult, ZeroRegister)
            elif not code.floatImmediate(floatResult, item.bits):
              code.loadImmediate(Word64, X12, cast[int64](item.bits))
              code.bitsToFloat(floatResult, X12)
          elif DirectVectors and resultKind == ir.Float32x2Type and
            item.op == ir.ConstantOp:
              floatResult = floatDestination(resultId)
              let bits = uint32(item.bits and 0xffffffff'u64)
              if item.bits == 0:
                code.bitsToFloat(floatResult, ZeroRegister)
              elif uint32(item.bits shr 32) == bits and
                code.floatImmediate(floatResult, bits, paired = true):
                  discard
              else:
                code.loadImmediate(Word64, X12, cast[int64](item.bits))
                code.bitsToFloat(floatResult, X12)
          else:
            if not resultKind.floating():
              integerResult = integerDestination(resultId)
            let word = unsignedWords and resultKind == ir.UInt32Type
            code.loadImmediate(if word: Word32 else: Word64, integerResult,
              if item.op == ir.FrameSizeOp: int64(frameBytes + headerBytes)
              else: cast[int64](item.bits))
            if resultKind.floating():
              floatResult = floatDestination(resultId)
              code.address(X15, callArea)
              code.storeDouble(X12, X15)
              code.loadFloat(floatResult, X15, single = single)
            elif not word:
              code.normalize(resultKind, integerResult)
        of ir.SlotAddressOp:
          integerResult = integerDestination(resultId)
          code.address(integerResult, slots[item.target])
        of ir.GlobalAddressOp:
          integerResult = integerDestination(resultId)
          let offset = module.globals[item.target].offset
          code.loadImmediate(Word64, X13, offset)
          code.addRegister(Word64, integerResult, X20, X13)
        of ir.OffsetAddressOp, ir.FieldAddressOp:
          let left = code.integerOperand(operand(0), X12)
          var right = X13
          integerResult = integerDestination(resultId)
          if item.op == ir.FieldAddressOp:
            code.loadImmediate(Word64, X13, module.fields[item.target].offset)
          else:
            right = code.integerOperand(operand(1), X13)
          code.addRegister(Word64, integerResult, left, right)
          if item.offset != 0:
            code.loadImmediate(Word64, X13, item.offset)
            code.addRegister(Word64, integerResult, integerResult, X13)
        of ir.MoveBytesOp, ir.ClearBytesOp:
          if item.byteCount == 0 or
              (item.op == ir.MoveBytesOp and int32(operand(0)) == int32(operand(1))):
            continue
          code.integer(operand(0), X12)
          if item.op == ir.MoveBytesOp:
            code.integer(operand(1), X13)
            code.moveMemory(int(item.byteCount), scratchFloat, scratchFloat2)
          else:
            code.clearMemory(int(item.byteCount))
          continue
        of ir.LoadOp, ir.StoreOp:
          var base = code.integerOperand(operand(0), X13)
          let kind = if item.op == ir.LoadOp: resultKind else: operandKind(1)
          var displacement = 0
          when not defined(nimkeyNoArmAddresses):
            let width = byteCount(kind, module.pointerBytes)
            if item.offset >= 0 and item.offset mod width == 0 and
                item.offset div width <= 4095:
                displacement = int(item.offset)
          if item.offset != displacement:
            code.loadImmediate(Word64, X14, item.offset)
            code.addRegister(Word64, X13, base, X14)
            base = X13
          var
            floatSource = 0
            integerSource = X12
          if item.op == ir.LoadOp and not kind.floating():
            integerResult = integerDestination(resultId)
          if item.op == ir.StoreOp:
            if kind.floating():
              floatSource = code.floatOperand(operand(1), scratchFloat)
            else:
              integerSource = code.integerOperand(operand(1), X12)
          case kind
          of ir.Float32Type, ir.Float64Type, ir.Float32x2Type:
            if item.op == ir.LoadOp:
              floatResult = floatDestination(resultId)
              code.loadFloat(
                floatResult,
                base,
                displacement,
                kind == ir.Float32Type
              )
            else:
              code.storeFloat(
                floatSource,
                base,
                displacement,
                kind == ir.Float32Type
              )
          of ir.BoolType, ir.CharType, ir.UInt8Type, ir.Int8Type:
            if item.op == ir.LoadOp:
              code.loadByte(integerResult, base, displacement)
            else:
              code.storeByte(integerSource, base, displacement)
          of ir.UInt16Type, ir.Int16Type:
            if item.op == ir.LoadOp:
              code.loadHalf(integerResult, base, displacement)
            else:
              code.storeHalf(integerSource, base, displacement)
          of ir.UInt32Type, ir.Int32Type:
            if item.op == ir.LoadOp:
              code.loadWord(integerResult, base, displacement)
            else:
              code.storeWord(integerSource, base, displacement)
          else:
            if item.op == ir.LoadOp:
              code.loadDouble(integerResult, base, displacement)
            else:
              code.storeDouble(integerSource, base, displacement)
          if item.op == ir.LoadOp and not kind.floating() and
            not (unsignedWords and kind == ir.UInt32Type):
              code.normalize(kind, integerResult)
        of ir.ConvertOp:
          if contexts[resultId] and contexts[int32(operand(0))]:
            continue
          let sourceKind = operandKind(0)
          case item.conversion
          of ir.IntegerFloatConversion:
            let source = code.integerOperand(operand(0), X12)
            code.integerToFloat(scratchFloat, source, single,
              sourceKind in {ir.UInt8Type, ir.UInt16Type, ir.UInt32Type,
                ir.UInt64Type})
          of ir.FloatIntegerConversion:
            integerResult = integerDestination(resultId)
            if sourceKind == ir.Float32Type and defined(nimkeyArmFloatCasts) and
              not defined(nimkeyNoArmFloatCasts):
                let source = code.floatOperand(operand(0), scratchFloat)
                code.floatToInteger(integerResult, source, single = true)
            else:
              code.floating(operand(0), scratchFloat)
              if sourceKind == ir.Float32Type:
                code.floatConvert(scratchFloat, scratchFloat, false)
              code.floatToInteger(integerResult, scratchFloat)
            code.normalize(resultKind, integerResult)
          of ir.FloatWidthConversion:
            code.floating(operand(0), scratchFloat)
            code.floatConvert(scratchFloat, scratchFloat, single)
          else:
            if floatBits and item.conversion == ir.BitcastConversion and
              ((sourceKind == ir.Float32Type and
                resultKind in {ir.Int32Type, ir.UInt32Type}) or
               (sourceKind == ir.Float64Type and
                resultKind in {ir.Int64Type, ir.UInt64Type})):
                integerResult = integerDestination(resultId)
                let source = code.floatOperand(operand(0), scratchFloat)
                code.floatToBits(integerResult, source,
                  single = sourceKind == ir.Float32Type)
                if resultKind == ir.Int32Type:
                  code.signExtendWord(integerResult, integerResult)
            elif floatBits and item.conversion == ir.BitcastConversion and
              ((sourceKind in {ir.Int32Type, ir.UInt32Type} and
                resultKind == ir.Float32Type) or
               (sourceKind in {ir.Int64Type, ir.UInt64Type} and
                resultKind == ir.Float64Type)):
                floatResult = floatDestination(resultId)
                let source = code.integerOperand(operand(0), X12)
                code.bitsToFloat(floatResult, source,
                  single = resultKind == ir.Float32Type)
            elif sourceKind.floating() or resultKind.floating():
              code.address(X13, callArea)
              if sourceKind.floating():
                code.floating(operand(0), scratchFloat)
                code.storeFloat(
                  scratchFloat,
                  X13,
                  single = sourceKind == ir.Float32Type
                )
                if sourceKind == ir.Float32Type: code.loadWord(X12, X13)
                else: code.loadDouble(X12, X13)
                if resultKind in {ir.Int8Type, ir.Int16Type, ir.Int32Type,
                    ir.BoolType, ir.CharType, ir.UInt8Type, ir.UInt16Type} or
                    (resultKind == ir.UInt32Type and
                    sourceKind == ir.Float64Type):
                      code.normalize(resultKind, X12)
              else:
                code.integer(operand(0), X12)
                code.storeDouble(X12, X13)
                code.loadFloat(scratchFloat, X13, single = single)
            else:
              integerResult = integerDestination(resultId)
              code.integer(operand(0), integerResult)
              code.normalize(resultKind, integerResult)
        of ir.CallOp, ir.HostCallOp, ir.IndirectCallOp:
          let first = if item.op == ir.IndirectCallOp: 1 else: 0
          if item.op == ir.IndirectCallOp:
            code.integer(operand(0), X16)
          var kinds: seq[ir.IrType]
          for i in first ..< int(item.arguments.count):
            kinds.add(operandKind(i))
          let layout = argumentLayout(kinds, host = item.op == ir.HostCallOp)
          var copies: seq[IrCopy]
          for i in first ..< int(item.arguments.count):
            let destination = layout.locations[i - first]
            if item.op == ir.HostCallOp and destination >= StackCopyBase:
              # Host stack slots use C widths, including Darwin compact slots.
              let kind = operandKind(i)
              if kind.floating():
                code.floating(operand(i), scratchFloat)
                code.address(X13, destination - StackCopyBase)
                code.storeFloat(scratchFloat, X13,
                  single = kind == ir.Float32Type)
              else:
                code.integer(operand(i), X12)
                code.address(X13, destination - StackCopyBase)
                case byteCount(kind, 8)
                of 1: code.storeByte(X12, X13)
                of 2: code.storeHalf(X12, X13)
                of 4: code.storeWord(X12, X13)
                else: code.storeDouble(X12, X13)
            else:
              copies.add(IrCopy(source: locations[int32(operand(i))],
                destination: destination, valueType: operandKind(i)))
          code.emitCopies(copies)
          case item.op
          of ir.CallOp: code.branchLink(entries[item.target])
          of ir.IndirectCallOp: code.callRegister(X16)
          else:
            code.loadDouble(X16, X19, offsetOf(RuntimeContext, hosts))
            code.loadDouble(X16, X16, module.hosts[item.target].binding * 8)
            code.callRegister(X16)
          if item.results.count > 1:
            var returned: seq[IrCopy]
            for i in 0 ..< int(item.results.count):
              let value = int(item.results.first) + i
              returned.add(IrCopy(source: FloatCopyBase + i,
                destination: locations[value],
                valueType: function.values[value].valueType))
            code.emitCopies(returned)
          elif item.results.count > 0:
            if resultKind.floating(): code.putFloat(resultId, 0)
            else: code.putInteger(resultId, X0)
          continue
        of ir.PackOp, ir.VectorAddOp, ir.VectorSubtractOp,
            ir.VectorMultiplyOp, ir.VectorDivideOp:
          let
            left = code.floatOperand(operand(0), scratchFloat)
            right = code.floatOperand(
              operand(1),
              scratchFloat2,
              operand(0),
              left
            )
            operation = case item.op
              of ir.VectorAddOp: 0
              of ir.VectorSubtractOp: 1
              of ir.VectorMultiplyOp: 2
              of ir.VectorDivideOp: 4
              else: 3
          floatResult = floatDestination(resultId)
          code.vectorBinary(operation, floatResult, left, right)
        of ir.VectorSumOp:
          let source = code.floatOperand(operand(0), scratchFloat)
          floatResult = floatDestination(resultId)
          code.vectorSum(floatResult, source)
        of ir.ExtractOp:
          let source = code.floatOperand(operand(0), scratchFloat)
          floatResult = floatDestination(resultId)
          code.vectorExtract(floatResult, source, int(item.target))
        of ir.SelectOp:
          let comparison = selections.comparisons[instructionIndex]
          var
            condition = NotEqualCondition
            materialized = X14
          if comparison >= 0:
            let
              predicate = function.instructions[comparison]
              kind = function.values[int32(
                function.operands[predicate.arguments.first])].valueType
            condition = comparisonCondition(predicate.comparison, kind)
          else:
            materialized = code.integerOperand(operand(0), X14)
          if resultKind.floating():
            let
              yes = code.floatOperand(operand(1), scratchFloat)
              no = code.floatOperand(
                operand(2),
                scratchFloat2,
                operand(1),
                yes
              )
            floatResult = floatDestination(resultId)
            if comparison < 0:
              code.compareImmediate(Word64, materialized, 0)
            code.selectFloat(floatResult, yes, no, condition, single)
          else:
            let
              yes = code.integerOperand(operand(1), X12)
              no = code.integerOperand(operand(2), X13)
            integerResult = integerDestination(resultId)
            if comparison < 0:
              code.compareImmediate(Word64, materialized, 0)
            code.selectRegister(Word64, integerResult, yes, no, condition)
        of ir.CompareOp:
          let floating = operandKind(0).floating()
          if floating:
            let left = code.floatOperand(operand(0), scratchFloat)
            if zeros.comparisons[instructionIndex]:
              code.compareFloatZero(left,
                single = operandKind(0) == ir.Float32Type)
            else:
              let right = code.floatOperand(
                operand(1),
                scratchFloat2,
                operand(0),
                left
              )
              code.compareFloat(left, right, operandKind(0) == ir.Float32Type)
          else:
            let
              left = code.integerOperand(operand(0), X12)
              right = code.integerOperand(operand(1), X13)
            code.compareRegister(Word64, left, right)
          if branches.conditions[resultId] or selections.conditions[resultId]:
            continue
          integerResult = integerDestination(resultId)
          code.setBoolean(Word64, integerResult,
            comparisonCondition(item.comparison, operandKind(0)))
        of ir.AddOp, ir.SubtractOp, ir.MultiplyOp, ir.DivideOp,
            ir.RemainderOp, ir.AndOp, ir.OrOp, ir.XorOp, ir.NotOp,
            ir.NegateOp, ir.SqrtOp, ir.FloorOp, ir.RoundOp,
            ir.ShiftLeftOp, ir.ShiftRightOp,
            ir.ArithmeticRightOp:
          if resultKind.floating():
            let left = code.floatOperand(operand(0), scratchFloat)
            floatResult = floatDestination(resultId)
            if item.arguments.count == 2:
              let right = code.floatOperand(
                operand(1),
                scratchFloat2,
                operand(0),
                left
              )
              let operation = case item.op
                of ir.AddOp: 0
                of ir.SubtractOp: 1
                of ir.MultiplyOp: 2
                of ir.DivideOp: 3
                else: -1
              if operation < 0:
                error("Unsupported floating IR arithmetic")
              code.floatBinary(operation, floatResult, left, right, single)
            else:
              let operation = case item.op
                of ir.SqrtOp: 3
                of ir.FloorOp: 4
                of ir.RoundOp: 5
                else: 1
              code.floatUnary(operation, floatResult, left, single)
          elif immediates.sides[instructionIndex] >= 0:
            let
              side = immediates.sides[instructionIndex]
              literal = immediates.bits[instructionIndex]
              source = code.integerOperand(operand(1 - side), X12)
            integerResult = integerDestination(resultId)
            case item.op
            of ir.AndOp, ir.OrOp, ir.XorOp:
              let operation = case item.op
                of ir.AndOp: AndOperation
                of ir.OrOp: OrOperation
                else: XorOperation
              code.logicalImmediate(
                Word64, operation, integerResult, source, literal
              )
            of ir.ShiftLeftOp:
              code.shiftLeftImmediate(
                Word64, integerResult, source, int(literal)
              )
            of ir.ShiftRightOp:
              code.shiftRightImmediate(
                Word64, integerResult, source, int(literal)
              )
            of ir.ArithmeticRightOp:
              code.arithmeticShiftRight(
                Word64, integerResult, source, int(literal)
              )
            else:
              error("Invalid ARM64 immediate operand plan")
            code.normalize(resultKind, integerResult)
          else:
            let
              left = code.integerOperand(operand(0), X12)
              word = unsignedWords and resultKind == ir.UInt32Type and
                item.op in {ir.AddOp, ir.SubtractOp, ir.MultiplyOp,
                  ir.AndOp, ir.OrOp, ir.XorOp, ir.NotOp, ir.NegateOp}
              width = if word: Word32 else: Word64
            var right = X13
            if item.arguments.count == 2:
              right = code.integerOperand(operand(1), X13)
            integerResult = integerDestination(resultId)
            case item.op
            of ir.AddOp:
              code.addRegister(width, integerResult, left, right)
            of ir.SubtractOp:
              code.subtractRegister(width, integerResult, left, right)
            of ir.MultiplyOp:
              code.multiply(width, integerResult, left, right)
            of ir.DivideOp, ir.RemainderOp:
              let quotient =
                when defined(nimkeyNoArmGeneralOperands):
                  X14
                else:
                  if item.op == ir.RemainderOp: X14 else: integerResult
              if resultKind in {ir.UInt8Type, ir.UInt16Type, ir.UInt32Type,
                  ir.UInt64Type}:
                code.unsignedDivide(quotient, left, right)
              else:
                code.signedDivide(Word64, quotient, left, right)
              if item.op == ir.RemainderOp:
                code.multiplySubtract(Word64, integerResult,
                  quotient, right, left)
              elif quotient.ord != integerResult.ord:
                code.moveRegister(Word64, integerResult, quotient)
            of ir.AndOp:
              code.andRegister(width, integerResult, left, right)
            of ir.OrOp:
              code.orRegister(width, integerResult, left, right)
            of ir.XorOp:
              code.xorRegister(width, integerResult, left, right)
            of ir.NotOp:
              code.loadImmediate(width, X13, -1)
              code.xorRegister(width, integerResult, left, X13)
            of ir.NegateOp:
              code.negate(width, integerResult, left)
            of ir.ShiftLeftOp, ir.ShiftRightOp, ir.ArithmeticRightOp:
              code.shiftRegister(integerResult, left, right,
                if item.op == ir.ShiftLeftOp: 0
                elif item.op == ir.ShiftRightOp: 1 else: 2)
            else: error("Unsupported integer IR arithmetic")
            if not word:
              code.normalize(resultKind, integerResult)
        if item.results.count > 0:
          if resultKind.floating(): code.putFloat(resultId, floatResult)
          else: code.putInteger(resultId, integerResult)
      let terminator = data.terminator
      case terminator.kind
      of ir.JumpTerminator:
        code.emitEdge(int(terminator.edges.first))
      of ir.BranchTerminator:
        let no = code.label()
        if int32(bits.inputs[owner]) >= 0:
          code.branchBit(
            code.integerOperand(bits.inputs[owner], X12),
            bits.bits[owner],
            no,
            whenSet = bits.whenSet[owner]
          )
        elif branches.comparisons[owner] >= 0:
          let
            item = function.instructions[branches.comparisons[owner]]
            kind = function.values[int32(
              function.operands[item.arguments.first])].valueType
            condition = comparisonCondition(item.comparison, kind)
          code.branchIf(machine.Condition(condition.ord xor 1), no)
        else:
          let condition = code.integerOperand(
            function.operands[terminator.arguments.first], X12)
          code.branchIfZero(Word64, condition, no)
        code.emitEdge(int(terminator.edges.first))
        code.place(no)
        code.emitEdge(int(terminator.edges.first) + 1)
      of ir.UnreachableTerminator:
        code.trap()
      of ir.ReturnTerminator:
        if terminator.arguments.count > 1:
          var returned: seq[IrCopy]
          for i in 0 ..< int(terminator.arguments.count):
            let value = function.operands[terminator.arguments.first + int32(i)]
            returned.add(IrCopy(source: locations[int32(value)],
              destination: FloatCopyBase + i,
              valueType: function.values[int32(value)].valueType))
          code.emitCopies(returned)
        elif terminator.arguments.count > 0:
          let value = function.operands[terminator.arguments.first]
          if function.values[int32(value)].valueType.floating():
            code.floating(value, 0)
          else:
            code.integer(value, X0)
        code.branch(finish)
      else:
        error("Unsupported complete ARM64 IR terminator")
    code.place(finish)
    code.stackAdjustment(frameBytes, false)
    if not leaf:
      code.preserveRegisters(preserved, preservedIntegers, true, pairedSaves)
      code.loadPair(X19, X20, StackPointer, 16)
      code.loadPair(FramePointer, LinkRegister, StackPointer, headerBytes, true)
    code.returnToCaller()
    if code.position() > maxBytes div 4:
      error("Native code size exceeds limits")
  code.resolve()
  when not defined(nimkeyNoArmCleanup):
    code.cleanup(entries, branchPairs)
  for entry in entries:
    result.offsets.add(code.offsetOf(entry) * 4)
  result.words = move(code.code)

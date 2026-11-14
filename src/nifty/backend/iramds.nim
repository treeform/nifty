## Emits AMD64 exclusively from verified scalar and memory IR.
import
  common, context, memories, amds,
  irs as ir, irchecks, irallocations, ircopies, ircontexts, irbranches,
  irprocedures

const
  IntegerRegisters = [R10, R11, R13, R14, R15, Rsi, Rdi]
  PreservedIntegers = when defined(windows): 0b1111100'u64
    else: 0b0011100'u64
  FloatRegisters = when defined(nimkeyNoAmdFloatRegisters): 4 else: 14
  PreservedFloats = when defined(windows) and
      not defined(nimkeyNoAmdFloatRegisters): 0x3ff0'u64 else: 0'u64
  SavedRegisters = [Rbx, R12, R13, R14, R15, Rsi, Rdi]
  Arguments = when defined(windows): [Rcx, Rdx, R8, R9]
    else: [Rdi, Rsi, Rdx, Rcx, R8, R9]
  UnsignedTypes = {ir.BoolType, ir.CharType, ir.UInt8Type, ir.UInt16Type,
    ir.UInt32Type, ir.UInt64Type, ir.AddressType}

type
  ValuePlace = object
    register: int
    offset: int
    context: bool

  IrAmd64Image* = object
    bytes*: seq[byte]
    offsets*: seq[int]
    frameBytes*: seq[int]
    wrapperFrameBytes*: int

proc memorySnapshot(code: var XAssembler, bytes: int, baseOffset = 0) =
  ## Loads all source bytes before stores, including overlapping end chunks.
  # R8/R9, RAX/RCX/RDX and XMM0/XMM1 are excluded from allocation.
  doAssert bytes in 1 .. 48
  let vectors = min(bytes div 16, 2)
  for i in 0 ..< vectors:
    code.vectorMemory(i, R9, baseOffset + i * 16, false)
  let
    offset = vectors * 16
    remaining = bytes - offset
    width = if remaining >= 8: 8 elif remaining >= 4: 4
      elif remaining >= 2: 2 else: 1
  if remaining > 0:
    code.loadSized(Rax, R9, baseOffset + offset, width)
    if remaining > width:
      code.loadSized(Rdx, R9, baseOffset + bytes - width, width)
  for i in 0 ..< vectors:
    code.vectorMemory(i, R8, baseOffset + i * 16, true)
  if remaining > 0:
    code.storeSized(Rax, R8, baseOffset + offset, width)
    if remaining > width:
      code.storeSized(Rdx, R8, baseOffset + bytes - width, width)

proc clearMemory(code: var XAssembler, bytes: int) =
  ## Clears exact bounds with one vector zero and a narrow remainder.
  if bytes >= 16:
    code.vectorBinary(0x57, 0, 0)
  var remaining = bytes
  if remaining > 128:
    let repeat = code.label()
    code.loadImmediate(Rcx, int64(remaining div 32))
    code.place(repeat)
    code.vectorMemory(0, R8, 0, true)
    code.vectorMemory(0, R8, 16, true)
    code.addImmediate(R8, 32)
    code.addImmediate(Rcx, -1)
    code.jumpIf(NotEqual, repeat)
    remaining = remaining mod 32
  var offset = 0
  while remaining >= 16:
    code.vectorMemory(0, R8, offset, true)
    offset += 16
    remaining -= 16
  if remaining > 0:
    code.loadImmediate(Rax, 0)
    for width in [8, 4, 2, 1]:
      if remaining >= width:
        code.storeSized(Rax, R8, offset, width)
        offset += width
        remaining -= width

proc moveMemory(code: var XAssembler, bytes: int) =
  ## Moves exact bounds with snapshots or directional 32-byte iterations.
  let finished = code.label()
  code.compare(R8, R9)
  code.jumpIf(Equal, finished)
  if bytes <= 48:
    code.memorySnapshot(bytes)
  elif bytes <= 128:
    let
      backward = code.label()
      tail = bytes mod 32
      head = bytes - tail
    code.jumpIf(Above, backward)
    for offset in countup(0, head - 32, 32):
      code.vectorMemory(0, R9, offset, false)
      code.vectorMemory(1, R9, offset + 16, false)
      code.vectorMemory(0, R8, offset, true)
      code.vectorMemory(1, R8, offset + 16, true)
    if tail > 0:
      code.memorySnapshot(tail, head)
    code.jump(finished)
    code.place(backward)
    if tail > 0:
      code.memorySnapshot(tail, head)
    for offset in countdown(head - 32, 0, 32):
      code.vectorMemory(0, R9, offset, false)
      code.vectorMemory(1, R9, offset + 16, false)
      code.vectorMemory(0, R8, offset, true)
      code.vectorMemory(1, R8, offset + 16, true)
  else:
    let
      backward = code.label()
      forward = code.label()
      repeat = code.label()
      tail = bytes mod 32
    code.jumpIf(Above, backward)
    code.loadImmediate(Rcx, int64(bytes div 32))
    code.place(forward)
    code.vectorMemory(0, R9, 0, false)
    code.vectorMemory(1, R9, 16, false)
    code.vectorMemory(0, R8, 0, true)
    code.vectorMemory(1, R8, 16, true)
    code.addImmediate(R8, 32)
    code.addImmediate(R9, 32)
    code.addImmediate(Rcx, -1)
    code.jumpIf(NotEqual, forward)
    if tail > 0:
      code.memorySnapshot(tail)
    code.jump(finished)
    code.place(backward)
    code.loadImmediate(Rcx, int64(bytes - tail))
    code.add(R8, Rcx)
    code.add(R9, Rcx)
    if tail > 0:
      code.memorySnapshot(tail)
    code.loadImmediate(Rcx, int64(bytes div 32))
    code.place(repeat)
    code.addImmediate(R8, -32)
    code.addImmediate(R9, -32)
    code.vectorMemory(0, R9, 0, false)
    code.vectorMemory(1, R9, 16, false)
    code.vectorMemory(0, R8, 0, true)
    code.vectorMemory(1, R8, 16, true)
    code.addImmediate(Rcx, -1)
    code.jumpIf(NotEqual, repeat)
  code.place(finished)

proc copyFloat(code: var XAssembler, destination, source: int,
    single: bool) =
  ## Copies scalar payloads without depending on dead upper destination bits.
  when defined(nimkeyNoAmdFloatCopies):
    code.scalar(0x10, destination, source, single)
  else:
    # Each allocated XMM location owns one value; its upper bits are unused.
    code.vectorBinary(0x28, destination, source)

proc argumentLocations(kinds: openArray[ir.IrType], privateBanks: bool,
    stackBase: int): seq[int] =
  ## Assigns native calls or private Windows calls to explicit ABI locations.
  var integers, floats, stacked = 0
  for position, kind in kinds:
    let floating = kind.floating()
    when defined(windows):
      let
        register = if privateBanks:
            (if floating: floats else: integers)
          else: position
        limit = if privateBanks and floating: 6 else: Arguments.len
    else:
      let
        register = if floating: floats else: integers
        limit = if floating: 8 else: Arguments.len
    if register < limit:
      # Prefer the allocator's volatile registers before its scratch pair.
      let physical =
        when defined(windows):
          if privateBanks and floating: (register + 2) mod 6
          else: register
        else: register
      result.add(copyLocation(kind,
        if floating: physical else: Arguments[register].ord, 0))
      if floating:
        inc floats
      else:
        inc integers
    else:
      result.add(StackCopyBase + stackBase + stacked * 8)
      inc stacked

proc prologue(code: var XAssembler, parameters: openArray[ir.IrType],
    saved: openArray[XRegister] = SavedRegisters, privateBanks = false) =
  ## Saves nonvolatile registers and keeps the native stack aligned.
  code.push(Rbp)
  code.move(Rbp, Rsp)
  for register in saved:
    code.push(register)
  when not defined(nimkeyNoAmdEntryCopies):
    if saved.len mod 2 != 0:
      code.addImmediate(Rsp, -8)
  else:
    code.addImmediate(Rsp, int32(-88 - aligned(max(0,
      parameters.len - 4) * 8, 16)))
    let incoming = argumentLocations(parameters, privateBanks,
      when defined(windows): 48 else: 16)
    for i, source in incoming:
      if source >= StackCopyBase:
        code.load(Rax, Rbp, source - StackCopyBase)
        code.store(Rax, Rbp, -64 - i * 8)
      elif parameters[i].floating():
        code.scalarMemory(source - FloatCopyBase, Rbp, -64 - i * 8,
          parameters[i] == ir.Float32Type, true)
      else:
        code.store(XRegister(source), Rbp, -64 - i * 8)

proc epilogue(code: var XAssembler,
    saved: openArray[XRegister] = SavedRegisters) =
  ## Restores nonvolatile state and the caller's original stack pointer.
  code.move(Rsp, Rbp)
  code.addImmediate(Rsp, int32(-saved.len * 8))
  for i in countdown(saved.high, 0):
    code.pop(saved[i])
  code.pop(Rbp)
  code.returnToCaller()

proc allocateStack(code: var XAssembler, bytes: int) =
  ## Touches each newly allocated stack page before crossing its guard.
  var remaining = bytes
  while remaining > 4096:
    code.addImmediate(Rsp, -4096)
    code.load(Rax, Rsp)
    remaining -= 4096
  if remaining > 0:
    code.addImmediate(Rsp, int32(-remaining))
    code.load(Rax, Rsp)

proc normalize(code: var XAssembler, kind: ir.IrType, destination = Rax) =
  ## Retains signed extension and wrapping at the declared integer width.
  when not defined(nimkeyNoAmdIntegerExtensions):
    case kind
    of ir.Int8Type, ir.Int16Type, ir.Int32Type, ir.CharType,
        ir.UInt8Type, ir.UInt16Type, ir.UInt32Type:
      code.extendInteger(destination, destination, byteCount(kind, 8),
        kind in {ir.Int8Type, ir.Int16Type, ir.Int32Type})
      return
    else: discard
  case kind
  of ir.Int8Type, ir.Int16Type, ir.Int32Type:
    let shift = 64 - byteCount(kind, 8) * 8
    code.shift(destination, shift, left = true)
    code.shift(destination, shift, arithmetic = true)
  of ir.BoolType, ir.CharType, ir.UInt8Type, ir.UInt16Type, ir.UInt32Type:
    let mask = case kind
      of ir.BoolType: 1'i64
      of ir.CharType, ir.UInt8Type: 255'i64
      of ir.UInt16Type: 65535'i64
      else: 0xffffffff'i64
    code.loadImmediate(R8, mask)
    code.binary(0x21, destination, R8)
  else: discard

proc signedFloat(code: var XAssembler, single: bool) =
  ## Converts RAX directly to the requested SSE floating precision.
  code.emit(if single: 0xf3'u8 else: 0xf2'u8)
  code.rex(true, 0, Rax.ord)
  code.emit(0x0f, 0x2a)
  code.registers(0, Rax.ord)

proc integerFloat(code: var XAssembler, single, unsigned: bool) =
  ## Rounds high unsigned integers without a signed or double-rounding detour.
  if unsigned:
    let
      ordinary = code.label()
      finish = code.label()
    code.loadImmediate(R8, 0)
    code.compare(Rax, R8)
    code.jumpIf(NoSign, ordinary)
    code.move(Rdx, Rax)
    code.loadImmediate(R8, 1)
    code.binary(0x21, Rdx, R8)
    code.shift(Rax, 1)
    code.binary(0x09, Rax, Rdx)
    code.signedFloat(single)
    code.scalar(0x58, 0, 0, single)
    code.jump(finish)
    code.place(ordinary)
    code.signedFloat(single)
    code.place(finish)
  else:
    code.signedFloat(single)

proc compareFloat(code: var XAssembler, single: bool, left = 0, right = 1) =
  ## Sets ordered and unordered flags directly from allocated SSE operands.
  if not single:
    code.emit(0x66)
  if left >= 8 or right >= 8:
    code.rex(false, left, right)
  code.emit(0x0f, 0x2e)
  code.registers(left, right)

proc roundBitsFloat32(code: var XAssembler) =
  ## Rounds the binary32 significand exactly without integer conversions.
  let
    small = code.label()
    large = code.label()
    signed = code.label()
    finish = code.label()
  code.floatToBits(Rdx, 0)
  code.move(R8, Rdx)
  code.loadImmediate(Rcx, 0x7fffffff)
  code.binary(0x21, R8, Rcx)
  code.loadImmediate(Rcx, 0x4b000000)
  code.compare(R8, Rcx)
  code.jumpIf(AboveEqual, large)
  code.loadImmediate(Rcx, 0x3f800000)
  code.compare(R8, Rcx)
  code.jumpIf(Below, small)
  code.move(Rcx, R8)
  code.shift(Rcx, 23)
  code.negate(Rcx)
  code.addImmediate(Rcx, 150)
  code.loadImmediate(Rax, 1)
  code.rex(true, 4, Rax.ord)
  code.emit(0xd3)
  code.registers(4, Rax.ord)
  code.move(R9, Rax)
  code.shift(Rax, 1)
  code.add(R8, Rax)
  code.negate(R9)
  code.binary(0x21, R8, R9)
  code.jump(signed)
  code.place(small)
  code.loadImmediate(Rcx, 0x3f000000)
  code.compare(R8, Rcx)
  code.loadImmediate(Rax, 0)
  code.loadImmediate(R8, 0x3f800000)
  code.conditionalMove(R8, Rax, Below)
  code.place(signed)
  code.loadImmediate(Rcx, 0x80000000)
  code.binary(0x21, Rdx, Rcx)
  code.binary(0x09, R8, Rdx)
  code.bitsToFloat(0, R8)
  code.jump(finish)
  code.place(large)
  # Addition retains integral values and quiets signaling NaNs.
  code.loadImmediate(Rax, 0)
  code.bitsToFloat(1, Rax)
  code.scalar(0x58, 0, 1, true)
  code.place(finish)

proc roundFloat32(code: var XAssembler, away: bool) =
  ## Rounds XMM0 with SSE2 while retaining signed zero and large float32 values.
  when not defined(nimkeyNoAmdBitRounding):
    if away:
      code.roundBitsFloat32()
      return
  let
    large = code.label()
    rounded = code.label()
    finish = code.label()
  code.floatToBits(Rdx, 0)
  code.move(R8, Rdx)
  code.loadImmediate(Rcx, 0x7fffffff)
  code.binary(0x21, R8, Rcx)
  code.loadImmediate(Rcx, 0x4b000000)
  code.compare(R8, Rcx)
  code.jumpIf(AboveEqual, large)
  code.copyFloat(1, 0, true)
  code.emit(0xf3)
  code.rex(true, Rax.ord, 0)
  code.emit(0x0f, 0x2c)
  code.registers(Rax.ord, 0)
  code.signedFloat(true)
  if away:
    let negative = code.label()
    code.scalar(0x5c, 1, 0, true)
    code.floatToBits(R8, 1)
    code.loadImmediate(Rcx, 0x7fffffff)
    code.binary(0x21, R8, Rcx)
    code.loadImmediate(Rcx, 0x3f000000)
    code.compare(R8, Rcx)
    code.jumpIf(Below, rounded)
    code.move(R8, Rdx)
    code.loadImmediate(Rcx, 0x80000000)
    code.binary(0x21, R8, Rcx)
    code.loadImmediate(Rcx, 0)
    code.compare(R8, Rcx)
    code.jumpIf(NotEqual, negative)
    code.addImmediate(Rax, 1)
    code.jump(rounded)
    code.place(negative)
    code.addImmediate(Rax, -1)
  else:
    code.compareFloat(true)
    code.jumpIf(BelowEqual, rounded)
    code.addImmediate(Rax, -1)
  code.place(rounded)
  code.signedFloat(true)
  code.loadImmediate(Rcx, 0x80000000)
  code.binary(0x21, Rdx, Rcx)
  code.floatToBits(R8, 0)
  code.binary(0x09, R8, Rdx)
  code.bitsToFloat(0, R8)
  code.jump(finish)
  code.place(large)
  # Addition preserves large integers and infinities and quiets signaling NaNs.
  code.loadImmediate(Rax, 0)
  code.bitsToFloat(1, Rax)
  code.scalar(0x58, 0, 1, true)
  code.place(finish)

proc comparisonCondition(comparison: ir.IrComparison,
    unsigned, floating: bool): XCondition =
  ## Selects the common flag predicate before applying NaN parity handling.
  case comparison
  of ir.EqualComparison: Equal
  of ir.NotEqualComparison: NotEqual
  of ir.LessComparison: (if unsigned or floating: Below else: Less)
  of ir.LessEqualComparison:
    (if unsigned or floating: BelowEqual else: LessEqual)
  of ir.GreaterComparison: (if unsigned or floating: Above else: Greater)
  of ir.GreaterEqualComparison:
    (if unsigned or floating: AboveEqual else: GreaterEqual)

proc condition(code: var XAssembler, comparison: ir.IrComparison,
    unsigned, floating: bool) =
  ## Materializes comparisons with IEEE unordered behavior for NaNs.
  code.setCondition(Rax, comparisonCondition(comparison, unsigned, floating))
  if floating:
    code.setCondition(Rdx,
      if comparison == ir.NotEqualComparison: Parity else: NoParity)
    code.binary(if comparison == ir.NotEqualComparison: 0x09 else: 0x21,
      Rax, Rdx)

proc quotient(code: var XAssembler, unsigned, remainder: bool) =
  ## Avoids the AMD64 signed-overflow trap while preserving wrapping division.
  let
    ordinary = code.label()
    finish = code.label()
  if not unsigned:
    code.loadImmediate(R8, int64.low)
    code.compare(Rax, R8)
    code.jumpIf(NotEqual, ordinary)
    code.loadImmediate(R8, -1)
    code.compare(Rcx, R8)
    code.jumpIf(NotEqual, ordinary)
    if remainder:
      code.loadImmediate(Rax, 0)
    code.jump(finish)
  code.place(ordinary)
  code.divide(Rcx, not unsigned)
  if remainder:
    code.move(Rax, Rdx)
  code.place(finish)

proc emitAmd64Ir*(module: ir.IrModule, maxBytes: int,
    floatColors = DefaultAmdIrFloatColors,
    unusedCopies = DefaultIrUnusedCopies): IrAmd64Image
    {.raises: [BackendError].} =
  ## Allocates and emits the complete module after checking its IR contract.
  verifyIr(module)
  verifyReturnAbi(module)
  if module.pointerBytes != 8:
    error("AMD64 IR requires 64-bit pointers")
  if module.functions.len == 0 or maxBytes < 1 or maxBytes > MaxNativeBytes:
    error("AMD64 IR requires an entry procedure and a valid code limit")
  for index, function in module.functions:
    if function.signature.parameters.len == 0 or
        function.signature.parameters[0] != ir.AddressType or
        (index == 0 and function.signature.parameters !=
          @[ir.AddressType, ir.AddressType, ir.AddressType, ir.AddressType]) or
        (index == 0 and function.signature.returns.len != 0):
        error("AMD64 IR requires a context argument and a storage entry ABI")
  var
    code: XAssembler
    entries: seq[XLabel]
    privateBanks: seq[bool]
  for index, function in module.functions:
    entries.add(code.label())
    privateBanks.add(when defined(windows) and
        not defined(nimkeyNoAmdArgumentBanks):
      index > 0 and function.directOnly
    else: false)
  result.frameBytes = newSeq[int](module.functions.len)
  result.wrapperFrameBytes = when defined(nimkeyNoAmdEntryCopies): 160
    else: 16 + aligned(SavedRegisters.len * 8, 16) + 32
  code.prologue([ir.AddressType, ir.AddressType, ir.AddressType, ir.AddressType])
  when not defined(nimkeyNoAmdEntryCopies):
    code.allocateStack(32)
  for i in 1 ..< 4:
    code.loadImmediate(Arguments[i], 0)
  code.call(entries[0])
  code.epilogue()
  for index, function in module.functions:
    let contexts = contextAliases(function, module.pointerBytes)
    if function.trapBody():
      result.frameBytes[index] = 8
      code.place(entries[index])
      code.trap()
      if code.position() > maxBytes:
        error("AMD64 code size exceeds limits")
      continue
    let branches = branchComparisons(function)
    var usesGlobalBase = false
    for item in function.instructions:
      if item.op == ir.GlobalAddressOp:
        usesGlobalBase = true
        break
    when defined(nimkeyNoAmdGlobalBase):
      usesGlobalBase = true
    var fixed = newSeq[bool](function.values.len)
    for value in 0 ..< fixed.len:
      fixed[value] = contexts[value] or branches.conditions[value]
    var allocation: IrAllocation
    when defined(nimkeyNoIrAllocation):
      allocation.registers = newSeq[int32](function.values.len)
      for register in allocation.registers.mitems:
        register = -1
    else:
      allocation = allocateRegisters(function, IntegerRegisters.len,
        FloatRegisters, preservedIntegers = PreservedIntegers,
        preservedFloats = PreservedFloats, fixedValues = fixed,
        floatColors = floatColors)
    var savedIntegers: seq[XRegister]
    for register in SavedRegisters:
      when defined(nimkeyNoAmdSelectiveSaves) or
          defined(nimkeyNoAmdEntryCopies):
        savedIntegers.add(register)
      else:
        var used = register == Rbx or (register == R12 and usesGlobalBase)
        for value, assigned in allocation.registers:
          if assigned >= 0 and not contexts[value] and
              not function.values[value].valueType.floating() and
              IntegerRegisters[assigned] == register:
            used = true
            break
        if used:
          savedIntegers.add(register)
    let frameOverhead = when defined(nimkeyNoAmdEntryCopies):
        160 +
          aligned(max(0, function.signature.parameters.len - 4) * 8, 16)
      else: 16 + aligned(savedIntegers.len * 8, 16)
    var
      places = newSeq[ValuePlace](function.values.len)
      slots: seq[int]
      locations: seq[int]
      labels: seq[XLabel]
      maxArguments = 8
    for data in function.blocks:
      maxArguments = max(maxArguments, int(data.parameters.count))
      labels.add(code.label())
    for item in function.instructions:
      if item.op in {ir.CallOp, ir.HostCallOp, ir.IndirectCallOp}:
        maxArguments = max(maxArguments, int(item.arguments.count))
    # Reserve outgoing stack arguments separately from saved operand values.
    var frameBytes = aligned(maxArguments * 8, 16)
    for slot in function.slots:
      frameBytes = aligned(frameBytes, int(slot.alignment))
      slots.add(frameBytes)
      frameBytes += int(slot.byteCount)
    frameBytes = aligned(frameBytes, 8)
    for value in 0 ..< function.values.len:
      if branches.conditions[value]:
        locations.add(-1)
        continue
      places[value].register = int(allocation.registers[value])
      places[value].context = contexts[value]
      if places[value].register < 0 and not contexts[value]:
        places[value].offset = frameBytes
        frameBytes += 8
      let
        kind = function.values[value].valueType
        register = places[value].register
        physical = if contexts[value]: Rbx.ord
          elif register < 0: -1
          elif kind.floating(): register + 2
          else: IntegerRegisters[register].ord
      locations.add(copyLocation(kind, physical, places[value].offset))
    let
      callArea = frameBytes
      targetArea = callArea + maxArguments * 8
    frameBytes = aligned(targetArea + 8, 16)
    let floatSaveArea = frameBytes
    var savedFloats: seq[int]
    when defined(windows):
      for register in 4 ..< FloatRegisters:
        var used = false
        for value, place in places:
          if function.values[value].valueType.floating() and
              place.register == register:
            used = true
            break
        if used:
          savedFloats.add(register + 2)
      frameBytes += savedFloats.len * 16
    if frameBytes > MaxFrameBytes:
      error("IR native frame exceeds limits")
    result.frameBytes[index] = frameBytes + frameOverhead
    proc integer(code: var XAssembler, value: ir.ValueId,
        destination = Rax) =
      ## Reads an allocated integer without clobbering another live value.
      doAssert not branches.conditions[int32(value)]
      let place = places[int32(value)]
      if place.context:
        if destination != Rbx:
          code.move(destination, Rbx)
      elif place.register >= 0:
        let source = IntegerRegisters[place.register]
        if destination != source:
          code.move(destination, source)
      else:
        code.load(destination, Rsp, place.offset)
    proc floating(code: var XAssembler, value: ir.ValueId,
        destination = 0) =
      ## Reads an allocated scalar with its exact floating precision.
      let
        place = places[int32(value)]
        single = function.values[int32(value)].valueType == ir.Float32Type
      if place.register >= 0:
        if destination != place.register + 2:
          if function.values[int32(value)].valueType == ir.Float32x2Type:
            code.scalar(0x7e, destination, place.register + 2, true)
          else:
            code.copyFloat(destination, place.register + 2, single)
      else:
        code.scalarMemory(destination, Rsp, place.offset, single, false)
    proc integerOperand(code: var XAssembler, value: ir.ValueId,
        scratch = Rax): XRegister =
      ## Reads spills into scratch while retaining allocated input registers.
      doAssert not branches.conditions[int32(value)]
      let place = places[int32(value)]
      if place.context:
        return Rbx
      if place.register >= 0:
        return IntegerRegisters[place.register]
      code.load(scratch, Rsp, place.offset)
      scratch
    proc floatOperand(code: var XAssembler, value: ir.ValueId,
        scratch = 0): int =
      ## Uses an allocated SSE source without copying through another register.
      let place = places[int32(value)]
      if place.register >= 0:
        return place.register + 2
      code.floating(value, scratch)
      scratch
    proc integerResult(value: int): XRegister =
      ## Chooses the allocated destination or the integer spill scratch.
      if places[value].context:
        return Rbx
      let register = places[value].register
      if register >= 0: IntegerRegisters[register] else: Rax
    proc floatResult(value: int): int =
      ## Chooses the allocated destination or the floating spill scratch.
      let register = places[value].register
      if register >= 0: register + 2 else: 0
    proc putInteger(code: var XAssembler, value: int, source = Rax) =
      ## Writes a result only when its final location differs from its source.
      let place = places[value]
      if place.context:
        if source != Rbx:
          code.move(Rbx, source)
      elif place.register >= 0:
        if IntegerRegisters[place.register] != source:
          code.move(IntegerRegisters[place.register], source)
      else:
        code.store(source, Rsp, place.offset)
    proc putFloat(code: var XAssembler, value: int, source = 0) =
      ## Stores the SSE result without changing its declared precision.
      let
        place = places[value]
        single = function.values[value].valueType == ir.Float32Type
      if place.register >= 0:
        if place.register + 2 != source:
          if function.values[value].valueType == ir.Float32x2Type:
            code.scalar(0x7e, place.register + 2, source, true)
          else:
            code.copyFloat(place.register + 2, source, single)
      else:
        code.scalarMemory(source, Rsp, place.offset, single, true)
    proc emitCopies(code: var XAssembler, copies: openArray[IrCopy]) =
      ## Encodes shared parallel-copy plans with storage only for real cycles.
      for item in scheduleCopies(copies):
        let
          source = if item.source == CopyScratch: StackCopyBase + callArea
            else: item.source
          destination = if item.destination == CopyScratch:
              StackCopyBase + callArea
            else: item.destination
          single = item.valueType == ir.Float32Type
        if source >= StackCopyBase and destination >= StackCopyBase:
          let bytes = if single: 4 else: 8
          code.loadSized(Rax, Rsp, source - StackCopyBase, bytes)
          code.storeSized(Rax, Rsp, destination - StackCopyBase, bytes)
        elif item.valueType.floating():
          if source >= StackCopyBase:
            code.scalarMemory(destination - FloatCopyBase, Rsp,
              source - StackCopyBase, single, false)
          elif destination >= StackCopyBase:
            code.scalarMemory(source - FloatCopyBase, Rsp,
              destination - StackCopyBase, single, true)
          else:
            if item.valueType == ir.Float32x2Type:
              code.scalar(0x7e, destination - FloatCopyBase,
                source - FloatCopyBase, true)
            else:
              code.copyFloat(destination - FloatCopyBase,
                source - FloatCopyBase, single)
        elif source >= StackCopyBase:
          code.load(XRegister(destination), Rsp, source - StackCopyBase)
        elif destination >= StackCopyBase:
          code.store(XRegister(source), Rsp, destination - StackCopyBase)
        else:
          code.move(XRegister(destination), XRegister(source))
    proc emitEdge(code: var XAssembler, edgeIndex: int, nextBlock = -1) =
      ## Transfers SSA block arguments through the shared location scheduler.
      code.emitCopies(edgeCopies(function, edgeIndex, locations))
      let target = int32(function.edges[edgeIndex].target)
      when defined(nimkeyNoAmdBranches):
        code.jump(labels[target])
      else:
        if target != nextBlock:
          code.jump(labels[target])
    when not defined(nimkeyNoAmdBranches):
      proc needsCopies(edgeIndex: int): bool =
        ## Detects edges whose allocated values need real transfer instructions.
        for item in edgeCopies(function, edgeIndex, locations):
          if item.source != item.destination:
            return true
    proc emitCondition(code: var XAssembler, owner: int, yes, no: XLabel,
        takeTrue: bool) =
      ## Branches in either direction while preserving unordered comparisons.
      var selected = NotEqual
      if branches.comparisons[owner] >= 0:
        let
          item = function.instructions[branches.comparisons[owner]]
          kind = function.values[int32(
            function.operands[item.arguments.first])].valueType
          floating = kind.floating()
        selected = comparisonCondition(item.comparison,
          kind in UnsignedTypes, floating)
        if floating:
          if item.comparison == ir.NotEqualComparison:
            code.jumpIf(Parity, yes)
          elif item.comparison in {ir.EqualComparison,
              ir.LessComparison, ir.LessEqualComparison}:
            code.jumpIf(Parity, no)
      else:
        let terminator = function.blocks[owner].terminator
        code.integer(function.operands[terminator.arguments.first])
        code.loadImmediate(Rcx, 0)
        code.compare(Rax, Rcx)
      if takeTrue:
        code.jumpIf(selected, yes)
      else:
        code.jumpIf(XCondition(selected.ord xor 1), no)
    while code.position() mod 4 != 0:
      code.emit(0x90)
    code.place(entries[index])
    code.prologue(function.signature.parameters, savedIntegers,
      privateBanks[index])
    when defined(nimkeyNoAmdEntryCopies):
      code.load(Rbx, Rbp, -64)
    else:
      code.move(Rbx, Arguments[0])
    if usesGlobalBase:
      code.load(R12, Rbx, offsetOf(RuntimeContext, globals))
    code.allocateStack(frameBytes)
    for i, register in savedFloats:
      code.vectorMemory(register, Rsp, floatSaveArea + i * 16, true)
    let entry = function.blocks[0].parameters
    var incoming: seq[int]
    when defined(nimkeyNoAmdEntryCopies):
      for i in 0 ..< int(entry.count):
        incoming.add(StackCopyBase + frameBytes + frameOverhead - 80 - i * 8)
    else:
      incoming = argumentLocations(function.signature.parameters,
        privateBanks[index], frameBytes + frameOverhead - 16 +
        (when defined(windows): 48 else: 16))
    if contexts[int(entry.first)]:
      incoming[0] = Rbx.ord
    code.emitCopies(parameterCopies(function, incoming, locations,
      unusedCopies))
    let finish = code.label()
    for owner, data in function.blocks:
      code.place(labels[owner])
      for instructionIndex in data.instructions.indices:
        let
          item = function.instructions[instructionIndex]
          resultId = int(item.results.first)
          resultKind = if item.results.count > 0:
              function.values[resultId].valueType
            else: ir.UInt64Type
          single = resultKind == ir.Float32Type
        proc operand(i: int): ir.ValueId =
          ## Resolves the explicit operand of the current instruction.
          function.operands[int(item.arguments.first) + i]
        proc operandKind(i: int): ir.IrType =
          ## Reads an operand type before choosing a machine operation.
          function.values[int32(operand(i))].valueType
        case item.op
        of ir.ConstantOp, ir.FrameSizeOp:
          when not defined(nimkeyNoAmdZeroConstants):
            if item.op == ir.ConstantOp and resultKind.floating() and
              item.bits == 0:
                let target = floatResult(resultId)
                code.xorFloat(target, target)
                code.putFloat(resultId, target)
                continue
          let destination = if resultKind.floating(): Rax
            else: integerResult(resultId)
          code.loadImmediate(destination,
            if item.op == ir.FrameSizeOp: int64(frameBytes + frameOverhead)
            else: cast[int64](item.bits))
          if resultKind.floating():
            let target = floatResult(resultId)
            code.bitsToFloat(target, Rax)
            code.putFloat(resultId, target)
          else:
            code.normalize(resultKind, destination)
            code.putInteger(resultId, destination)
          continue
        of ir.SlotAddressOp:
          code.move(Rax, Rsp)
          code.addImmediate(Rax, int32(slots[item.target]))
        of ir.GlobalAddressOp:
          code.loadImmediate(Rax, module.globals[item.target].offset)
          code.add(Rax, R12)
        of ir.OffsetAddressOp, ir.FieldAddressOp:
          code.integer(operand(0))
          if item.op == ir.FieldAddressOp:
            code.loadImmediate(Rcx, module.fields[item.target].offset)
          else:
            code.integer(operand(1), Rcx)
          code.add(Rax, Rcx)
          if item.offset != 0:
            code.loadImmediate(Rcx, item.offset)
            code.add(Rax, Rcx)
        of ir.MoveBytesOp, ir.ClearBytesOp:
          if item.byteCount == 0 or
              (item.op == ir.MoveBytesOp and int32(operand(0)) == int32(operand(1))):
            continue
          code.integer(operand(0), R8)
          if item.op == ir.MoveBytesOp:
            code.integer(operand(1), R9)
            code.moveMemory(int(item.byteCount))
          else:
            code.clearMemory(int(item.byteCount))
          continue
        of ir.LoadOp, ir.StoreOp:
          var
            base = code.integerOperand(operand(0), Rcx)
            offset = item.offset
          if offset < int32.low or offset > int32.high:
            if base != Rcx:
              code.move(Rcx, base)
            code.loadImmediate(R8, item.offset)
            code.add(Rcx, R8)
            base = Rcx
            offset = 0
          let kind = if item.op == ir.LoadOp: resultKind else: operandKind(1)
          if kind.floating():
            let register = if item.op == ir.StoreOp:
                code.floatOperand(operand(1))
              else: floatResult(resultId)
            code.scalarMemory(register, base, int(offset), kind == ir.Float32Type,
              item.op == ir.StoreOp)
            if item.op == ir.LoadOp:
              code.putFloat(resultId, register)
          elif item.op == ir.LoadOp:
            let register = integerResult(resultId)
            code.loadSized(register, base, int(offset), byteCount(kind, 8))
            code.normalize(kind, register)
            code.putInteger(resultId, register)
          else:
            let register = code.integerOperand(operand(1))
            code.storeSized(register, base, int(offset), byteCount(kind, 8))
          continue
        of ir.ConvertOp:
          if contexts[resultId] and contexts[int32(operand(0))]:
            continue
          let sourceKind = operandKind(0)
          case item.conversion
          of ir.IntegerFloatConversion:
            code.integer(operand(0))
            code.integerFloat(single, sourceKind in UnsignedTypes)
          of ir.FloatIntegerConversion:
            code.floating(operand(0))
            code.emit(if sourceKind == ir.Float32Type: 0xf3'u8 else: 0xf2'u8)
            code.rex(true, Rax.ord, 0)
            code.emit(0x0f, 0x2c)
            code.registers(Rax.ord, 0)
            code.normalize(resultKind)
          of ir.FloatWidthConversion:
            let
              source = code.floatOperand(operand(0))
              target = floatResult(resultId)
            code.scalar(0x5a, target, source, sourceKind == ir.Float32Type)
            code.putFloat(resultId, target)
            continue
          else:
            if sourceKind.floating() and resultKind.floating():
              let target = floatResult(resultId)
              code.floating(operand(0), target)
              code.putFloat(resultId, target)
            elif sourceKind.floating():
              let
                source = code.floatOperand(operand(0))
                target = integerResult(resultId)
              code.floatToBits(target, source)
              code.normalize(resultKind, target)
              code.putInteger(resultId, target)
            elif resultKind.floating():
              let
                source = code.integerOperand(operand(0))
                target = floatResult(resultId)
              code.bitsToFloat(target, source)
              code.putFloat(resultId, target)
            else:
              let target = integerResult(resultId)
              code.integer(operand(0), target)
              code.normalize(resultKind, target)
              code.putInteger(resultId, target)
            continue
        of ir.CallOp, ir.HostCallOp, ir.IndirectCallOp:
          let first = if item.op == ir.IndirectCallOp: 1 else: 0
          if item.op == ir.IndirectCallOp:
            code.integer(operand(0))
            code.store(Rax, Rsp, targetArea)
          var kinds: seq[ir.IrType]
          for i in first ..< int(item.arguments.count):
            kinds.add(operandKind(i))
          let destinations = argumentLocations(kinds,
            item.op == ir.CallOp and privateBanks[item.target],
            when defined(windows): 32 else: 0)
          var copies: seq[IrCopy]
          for i in first ..< int(item.arguments.count):
            copies.add(IrCopy(source: locations[int32(operand(i))],
              destination: destinations[i - first], valueType: kinds[i - first]))
          code.emitCopies(copies)
          case item.op
          of ir.CallOp:
            code.call(entries[item.target])
          of ir.IndirectCallOp:
            code.load(Rax, Rsp, targetArea)
            code.call(Rax)
          else:
            code.load(Rax, Rbx, offsetOf(RuntimeContext, hosts))
            code.load(Rax, Rax, module.hosts[item.target].binding * 8)
            code.call(Rax)
          if item.results.count > 1:
            var returned: seq[IrCopy]
            for i in 0 ..< int(item.results.count):
              let value = int(item.results.first) + i
              returned.add(IrCopy(source: FloatCopyBase + i,
                destination: locations[value], valueType: ir.Float32Type))
            code.emitCopies(returned)
          elif item.results.count > 0:
            if resultKind.floating(): code.putFloat(resultId)
            else: code.putInteger(resultId)
          continue
        of ir.PackOp, ir.VectorAddOp, ir.VectorSubtractOp,
            ir.VectorMultiplyOp, ir.VectorDivideOp:
          let target = floatResult(resultId)
          var right = code.floatOperand(operand(1), 1)
          if right == target and
              places[int32(operand(0))].register + 2 != target:
            code.scalar(0x7e, 1, right, true)
            right = 1
          code.floating(operand(0), target)
          let operation = case item.op
            of ir.VectorAddOp: 0x58'u8
            of ir.VectorSubtractOp: 0x5c'u8
            of ir.VectorMultiplyOp: 0x59'u8
            of ir.VectorDivideOp: 0x5e'u8
            else: 0x14'u8
          code.vectorBinary(operation, target, right)
          if item.op == ir.PackOp:
            code.scalar(0x7e, target, target, true)
          code.putFloat(resultId, target)
          continue
        of ir.VectorSumOp:
          let
            source = code.floatOperand(operand(0))
            target = floatResult(resultId)
          code.vectorExtract(1, source, 1)
          if target != source:
            code.scalar(0x7e, target, source, true)
          code.scalar(0x58, target, 1, true)
          code.putFloat(resultId, target)
          continue
        of ir.ExtractOp:
          let
            source = code.floatOperand(operand(0))
            target = floatResult(resultId)
          code.vectorExtract(target, source, int(item.target))
          code.putFloat(resultId, target)
          continue
        of ir.SelectOp:
          code.integer(operand(0), Rdx)
          code.loadImmediate(Rax, 0)
          code.compare(Rdx, Rax)
          if resultKind.floating():
            let
              yes = code.floatOperand(operand(1), 0)
              no = code.floatOperand(operand(2), 1)
            code.floatToBits(Rcx, yes)
            code.floatToBits(Rax, no)
            code.conditionalMove(Rax, Rcx, NotEqual)
            let target = floatResult(resultId)
            code.bitsToFloat(target, Rax)
            code.putFloat(resultId, target)
          else:
            code.integer(operand(1), Rcx)
            code.integer(operand(2), Rax)
            code.conditionalMove(Rax, Rcx, NotEqual)
            code.putInteger(resultId)
          continue
        of ir.CompareOp:
          let floating = operandKind(0).floating()
          if floating:
            let
              a = code.floatOperand(operand(0))
              b = code.floatOperand(operand(1), 1)
            code.compareFloat(operandKind(0) == ir.Float32Type, a, b)
          else:
            let
              a = code.integerOperand(operand(0))
              b = code.integerOperand(operand(1), Rcx)
            code.compare(a, b)
          if branches.conditions[resultId]:
            continue
          code.condition(item.comparison, operandKind(0) in UnsignedTypes,
            floating)
        of ir.AddOp, ir.SubtractOp, ir.MultiplyOp, ir.DivideOp,
            ir.RemainderOp, ir.AndOp, ir.OrOp, ir.XorOp, ir.NotOp,
            ir.NegateOp, ir.SqrtOp, ir.FloorOp, ir.RoundOp,
            ir.ShiftLeftOp, ir.ShiftRightOp,
            ir.ArithmeticRightOp:
          if resultKind.floating():
            if item.arguments.count == 2:
              let target = floatResult(resultId)
              var right = code.floatOperand(operand(1), 1)
              if right == target and
                  places[int32(operand(0))].register + 2 != target:
                code.copyFloat(1, right, single)
                right = 1
              code.floating(operand(0), target)
              let operation = case item.op
                of ir.AddOp: 0x58'u8
                of ir.SubtractOp: 0x5c'u8
                of ir.MultiplyOp: 0x59'u8
                of ir.DivideOp: 0x5e'u8
                else: 0'u8
              if operation == 0:
                error("Unsupported floating AMD64 IR arithmetic")
              code.scalar(operation, target, right, single)
              code.putFloat(resultId, target)
              continue
            elif item.op in {ir.FloorOp, ir.RoundOp}:
              code.floating(operand(0))
              code.roundFloat32(item.op == ir.RoundOp)
            elif item.op == ir.SqrtOp:
              let
                source = code.floatOperand(operand(0))
                target = floatResult(resultId)
              code.scalar(0x51, target, source, single)
              code.putFloat(resultId, target)
              continue
            else:
              when defined(nimkeyNoAmdFloatNegation):
                code.floating(operand(0))
                code.floatToBits(Rax, 0)
                code.loadImmediate(Rcx,
                  if single: 0x80000000'i64 else: int64.low)
                code.binary(0x31, Rax, Rcx)
                code.bitsToFloat(0, Rax)
              else:
                let target = floatResult(resultId)
                code.floating(operand(0), target)
                code.loadImmediate(Rcx,
                  if single: 0x80000000'i64 else: int64.low)
                code.bitsToFloat(1, Rcx)
                code.xorFloat(target, 1)
                code.putFloat(resultId, target)
                continue
          else:
            if item.op in {ir.AddOp, ir.SubtractOp, ir.MultiplyOp,
                ir.AndOp, ir.OrOp, ir.XorOp}:
              let target = integerResult(resultId)
              var right = code.integerOperand(operand(1), Rcx)
              if right == target:
                code.move(Rcx, right)
                right = Rcx
              code.integer(operand(0), target)
              case item.op
              of ir.AddOp: code.add(target, right)
              of ir.SubtractOp: code.subtract(target, right)
              of ir.MultiplyOp: code.multiply(target, right)
              of ir.AndOp: code.binary(0x21, target, right)
              of ir.OrOp: code.binary(0x09, target, right)
              else: code.binary(0x31, target, right)
              code.normalize(resultKind, target)
              code.putInteger(resultId, target)
              continue
            code.integer(operand(0))
            if item.arguments.count == 2:
              code.integer(operand(1), Rcx)
            case item.op
            of ir.AddOp: code.add(Rax, Rcx)
            of ir.SubtractOp: code.subtract(Rax, Rcx)
            of ir.MultiplyOp: code.multiply(Rax, Rcx)
            of ir.DivideOp, ir.RemainderOp:
              code.quotient(resultKind in UnsignedTypes,
                item.op == ir.RemainderOp)
            of ir.AndOp: code.binary(0x21, Rax, Rcx)
            of ir.OrOp: code.binary(0x09, Rax, Rcx)
            of ir.XorOp: code.binary(0x31, Rax, Rcx)
            of ir.NotOp:
              code.loadImmediate(Rcx, -1)
              code.binary(0x31, Rax, Rcx)
            of ir.NegateOp: code.negate(Rax)
            of ir.ShiftLeftOp, ir.ShiftRightOp, ir.ArithmeticRightOp:
              let group = if item.op == ir.ShiftLeftOp: 4
                elif item.op == ir.ShiftRightOp: 5 else: 7
              code.rex(true, group, Rax.ord)
              code.emit(0xd3)
              code.registers(group, Rax.ord)
            else:
              error("Unsupported integer AMD64 IR arithmetic")
            code.normalize(resultKind)
        if item.results.count > 0:
          if resultKind.floating(): code.putFloat(resultId)
          else: code.putInteger(resultId)
      let terminator = data.terminator
      case terminator.kind
      of ir.JumpTerminator:
        code.emitEdge(int(terminator.edges.first), owner + 1)
      of ir.BranchTerminator:
        let
          first = int(terminator.edges.first)
          second = first + 1
        when defined(nimkeyNoAmdBranches):
          let
            yes = code.label()
            no = code.label()
          code.emitCondition(owner, yes, no, false)
          code.place(yes)
          code.emitEdge(first)
          code.place(no)
          code.emitEdge(second)
        else:
          let
            firstTarget = int32(function.edges[first].target)
            secondTarget = int32(function.edges[second].target)
            firstCopies = needsCopies(first)
            secondCopies = needsCopies(second)
            yes = if firstCopies: code.label() else: labels[firstTarget]
            no = if secondCopies: code.label() else: labels[secondTarget]
          if not firstCopies and not secondCopies:
            let takeTrue = secondTarget == owner + 1
            code.emitCondition(owner, yes, no, takeTrue)
            if not takeTrue and firstTarget != owner + 1:
              code.jump(yes)
          else:
            code.emitCondition(owner, yes, no, false)
            if firstCopies:
              code.place(yes)
            code.emitEdge(first, if secondCopies: -1 else: owner + 1)
            if secondCopies:
              code.place(no)
              code.emitEdge(second, owner + 1)
      of ir.UnreachableTerminator:
        code.trap()
      of ir.ReturnTerminator:
        if terminator.arguments.count > 1:
          var returned: seq[IrCopy]
          for i in 0 ..< int(terminator.arguments.count):
            let value = function.operands[terminator.arguments.first + int32(i)]
            returned.add(IrCopy(source: locations[int32(value)],
              destination: FloatCopyBase + i, valueType: ir.Float32Type))
          code.emitCopies(returned)
        elif terminator.arguments.count > 0:
          let value = function.operands[terminator.arguments.first]
          if function.values[int32(value)].valueType.floating():
            code.floating(value)
          else:
            code.integer(value)
        when defined(nimkeyNoAmdBranches):
          code.jump(finish)
        else:
          if owner != function.blocks.high:
            code.jump(finish)
      else:
        error("Unsupported complete AMD64 IR terminator")
    code.place(finish)
    for i, register in savedFloats:
      code.vectorMemory(register, Rsp, floatSaveArea + i * 16, false)
    code.epilogue(savedIntegers)
    if code.position() > maxBytes:
      error("Native code size exceeds limits")
  code.resolve()
  for entry in entries:
    result.offsets.add(code.offsetOf(entry))
  result.bytes = move(code.code)

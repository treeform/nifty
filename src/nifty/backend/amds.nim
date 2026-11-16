## Encodes baseline AMD64 integer and SSE2 instructions without AVX.
import common

type
  XRegister* = enum
    Rax, Rcx, Rdx, Rbx, Rsp, Rbp, Rsi, Rdi,
    R8, R9, R10, R11, R12, R13, R14, R15

  XCondition* = enum
    Overflow, NoOverflow, Below, AboveEqual, Equal, NotEqual,
    BelowEqual, Above, Sign, NoSign, Parity, NoParity,
    Less, GreaterEqual, LessEqual, Greater

  XLabel* = distinct int

  XFixup = object
    offset: int
    target: int

  XAssembler* = object
    code*: seq[byte]
    targets: seq[int]
    fixups: seq[XFixup]

proc emit*(assembler: var XAssembler, bytes: varargs[byte]) {.raises: [].} =
  ## Appends instruction bytes in encoding order.
  assembler.code.add(bytes)

proc immediate*(assembler: var XAssembler, value: uint64, count: int)
    {.raises: [].} =
  ## Emits the requested low bytes in little endian order.
  for i in 0 ..< count:
    assembler.code.add(byte((value shr (i * 8)) and 255))

proc rex*(assembler: var XAssembler, wide: bool, reg, base: int)
    {.raises: [].} =
  ## Selects operand width and the high halves of both register fields.
  assembler.emit(byte(0x40 or (ord(wide) shl 3) or
    ((reg shr 3) shl 2) or (base shr 3)))

proc registers*(assembler: var XAssembler, reg, base: int) {.raises: [].} =
  ## Encodes a register operand in ModRM form.
  assembler.emit(byte(0xC0 or ((reg and 7) shl 3) or (base and 7)))

proc memory*(assembler: var XAssembler, reg: int, base: XRegister,
    offset: int) {.raises: [].} =
  ## Uses the smallest legal displacement, including RBP and SIB exceptions.
  doAssert offset >= int32.low.int and offset <= int32.high.int
  let count =
    if offset == 0 and (base.ord and 7) != 5: 0
    elif offset in -128 .. 127: 1
    else: 4
  let mode = if count == 0: 0 elif count == 1: 0x40 else: 0x80
  assembler.emit(byte(mode or ((reg and 7) shl 3) or (base.ord and 7)))
  if (base.ord and 7) == 4:
    assembler.emit(0x24)
  assembler.immediate(cast[uint64](offset.int64), count)

proc label*(assembler: var XAssembler): XLabel {.raises: [].} =
  ## Reserves a forward or backward branch destination.
  result = XLabel(assembler.targets.len)
  assembler.targets.add(-1)

proc place*(assembler: var XAssembler, target: XLabel) {.raises: [].} =
  ## Binds one label to the current byte offset.
  doAssert int(target) in 0 ..< assembler.targets.len
  doAssert assembler.targets[int(target)] == -1
  assembler.targets[int(target)] = assembler.code.len

proc displacement*(assembler: var XAssembler, target: XLabel)
    {.raises: [].} =
  ## Reserves the signed relative displacement after a branch opcode.
  assembler.fixups.add(XFixup(offset: assembler.code.len, target: int(target)))
  assembler.immediate(0, 4)

proc jump*(assembler: var XAssembler, target: XLabel) {.raises: [].} =
  ## Emits a near relative jump.
  assembler.emit(0xE9)
  assembler.displacement(target)

proc jumpIf*(assembler: var XAssembler, condition: XCondition,
    target: XLabel) {.raises: [].} =
  ## Emits a near conditional branch using the current flags.
  assembler.emit(0x0F, byte(0x80 + condition.ord))
  assembler.displacement(target)

proc resolve*(assembler: var XAssembler) {.raises: [BackendError].} =
  ## Resolves every relative branch after instruction sizes are known.
  for fixup in assembler.fixups:
    if fixup.target notin 0 ..< assembler.targets.len or
        assembler.targets[fixup.target] < 0:
        raise newException(BackendError, "AMD64 label was never placed")
    let distance = assembler.targets[fixup.target] - fixup.offset - 4
    if distance < int32.low.int or distance > int32.high.int:
      raise newException(BackendError, "AMD64 branch is out of range")
    for i in 0 ..< 4:
      assembler.code[fixup.offset + i] =
        byte((cast[uint64](distance.int64) shr (i * 8)) and 255)
  assembler.fixups.setLen(0)

proc push*(assembler: var XAssembler, register: XRegister) {.raises: [].} =
  ## Saves one callee-saved register on the native stack.
  if register.ord >= 8:
    assembler.emit(0x41)
  assembler.emit(byte(0x50 + (register.ord and 7)))

proc pop*(assembler: var XAssembler, register: XRegister) {.raises: [].} =
  ## Restores one saved register from the native stack.
  if register.ord >= 8:
    assembler.emit(0x41)
  assembler.emit(byte(0x58 + (register.ord and 7)))

proc move*(assembler: var XAssembler, destination, source: XRegister)
    {.raises: [].} =
  ## Copies all 64 bits between general purpose registers.
  assembler.rex(true, source.ord, destination.ord)
  assembler.emit(0x89)
  assembler.registers(source.ord, destination.ord)

proc conditionalMove*(assembler: var XAssembler, destination,
    source: XRegister, condition: XCondition) {.raises: [].} =
  ## Replaces a payload only when the current comparison condition holds.
  assembler.rex(true, destination.ord, source.ord)
  assembler.emit(0x0F, byte(0x40 + condition.ord))
  assembler.registers(destination.ord, source.ord)

proc extendInteger*(assembler: var XAssembler, destination,
    source: XRegister, bytes: int, signed: bool) {.raises: [].} =
  ## Normalizes a narrow register with one sign or zero extension.
  doAssert bytes in [1, 2, 4]
  # REX also selects SPL, BPL, SIL, and DIL instead of legacy high bytes.
  assembler.rex(signed, destination.ord, source.ord)
  if bytes == 4:
    assembler.emit(if signed: 0x63'u8 else: 0x8b'u8)
  else:
    assembler.emit(0x0f,
      byte((if signed: 0xbe else: 0xb6) + ord(bytes == 2)))
  assembler.registers(destination.ord, source.ord)

proc loadImmediate*(assembler: var XAssembler, destination: XRegister,
    value: int64) {.raises: [].} =
  ## Selects zero extending, sign extending, or full width constant loads.
  if value >= 0 and value <= uint32.high.int64:
    if destination.ord >= 8:
      assembler.emit(0x41)
    assembler.emit(byte(0xB8 + (destination.ord and 7)))
    assembler.immediate(value.uint64, 4)
  elif value >= int32.low.int64 and value <= int32.high.int64:
    assembler.rex(true, 0, destination.ord)
    assembler.emit(0xC7)
    assembler.registers(0, destination.ord)
    assembler.immediate(cast[uint64](value), 4)
  else:
    assembler.rex(true, 0, destination.ord)
    assembler.emit(byte(0xB8 + (destination.ord and 7)))
    assembler.immediate(cast[uint64](value), 8)

proc load*(assembler: var XAssembler, destination, base: XRegister,
    offset = 0) {.raises: [].} =
  ## Reads one 64-bit word from an arbitrary frame displacement.
  assembler.rex(true, destination.ord, base.ord)
  assembler.emit(0x8B)
  assembler.memory(destination.ord, base, offset)

proc store*(assembler: var XAssembler, source, base: XRegister,
    offset = 0) {.raises: [].} =
  ## Writes one 64-bit word to an arbitrary frame displacement.
  assembler.rex(true, source.ord, base.ord)
  assembler.emit(0x89)
  assembler.memory(source.ord, base, offset)

proc binary*(assembler: var XAssembler, opcode: byte,
    destination, source: XRegister) {.raises: [].} =
  ## Encodes a two-register ALU operation with the destination in ModRM.rm.
  assembler.rex(true, source.ord, destination.ord)
  assembler.emit(opcode)
  assembler.registers(source.ord, destination.ord)

proc add*(assembler: var XAssembler, destination, source: XRegister)
    {.raises: [].} =
  ## Adds modulo 2 to the power of 64.
  assembler.binary(0x01, destination, source)

proc subtract*(assembler: var XAssembler, destination, source: XRegister)
    {.raises: [].} =
  ## Subtracts modulo 2 to the power of 64.
  assembler.binary(0x29, destination, source)

proc compare*(assembler: var XAssembler, left, right: XRegister)
    {.raises: [].} =
  ## Sets signed and unsigned comparison flags without changing operands.
  assembler.binary(0x39, left, right)

proc multiply*(assembler: var XAssembler, destination, source: XRegister)
    {.raises: [].} =
  ## Retains the low 64 bits of a signed or unsigned product.
  assembler.rex(true, destination.ord, source.ord)
  assembler.emit(0x0F, 0xAF)
  assembler.registers(destination.ord, source.ord)

proc multiplyWide*(assembler: var XAssembler, source: XRegister)
    {.raises: [].} =
  ## Produces the unsigned 128-bit RDX:RAX product of RAX and source.
  assembler.rex(true, 4, source.ord)
  assembler.emit(0xF7)
  assembler.registers(4, source.ord)

proc addImmediate*(assembler: var XAssembler, destination: XRegister,
    value: int32) {.raises: [].} =
  ## Adds a sign-extended 32-bit immediate.
  assembler.rex(true, 0, destination.ord)
  let compact = value in -128 .. 127
  assembler.emit(if compact: 0x83'u8 else: 0x81'u8)
  assembler.registers(0, destination.ord)
  assembler.immediate(cast[uint32](value).uint64, if compact: 1 else: 4)

proc shift*(assembler: var XAssembler, destination: XRegister,
    count: int, arithmetic = false, left = false) {.raises: [].} =
  ## Shifts a payload for signed extension or unsigned truncation.
  doAssert count in 0 .. 63
  let group = if left: 4 elif arithmetic: 7 else: 5
  assembler.rex(true, group, destination.ord)
  assembler.emit(0xC1)
  assembler.registers(group, destination.ord)
  assembler.emit(byte(count))

proc negate*(assembler: var XAssembler, destination: XRegister)
    {.raises: [].} =
  ## Negates a two's complement integer with wrapping overflow.
  assembler.rex(true, 3, destination.ord)
  assembler.emit(0xF7)
  assembler.registers(3, destination.ord)

proc divide*(assembler: var XAssembler, divisor: XRegister, signed: bool)
    {.raises: [].} =
  ## Divides RDX:RAX after callers guard zero and signed overflow.
  if signed:
    assembler.emit(0x48, 0x99)
  else:
    assembler.binary(0x31, Rdx, Rdx)
  let group = if signed: 7 else: 6
  assembler.rex(true, group, divisor.ord)
  assembler.emit(0xF7)
  assembler.registers(group, divisor.ord)

proc setCondition*(assembler: var XAssembler, destination: XRegister,
    condition: XCondition) {.raises: [].} =
  ## Materializes a condition as a zero-extended Boolean payload.
  assembler.rex(false, 0, destination.ord)
  assembler.emit(0x0F, byte(0x90 + condition.ord))
  assembler.registers(0, destination.ord)
  assembler.rex(false, destination.ord, destination.ord)
  assembler.emit(0x0F, 0xB6)
  assembler.registers(destination.ord, destination.ord)

proc bitsToFloat*(assembler: var XAssembler, destination: int,
    source: XRegister) {.raises: [].} =
  ## Moves a double's raw bits into an SSE2 register.
  doAssert destination in 0 .. 15
  assembler.emit(0x66)
  assembler.rex(true, destination, source.ord)
  assembler.emit(0x0F, 0x6E)
  assembler.registers(destination, source.ord)

proc floatToBits*(assembler: var XAssembler, destination: XRegister,
    source: int) {.raises: [].} =
  ## Moves the low double's raw bits back to an integer register.
  doAssert source in 0 .. 15
  assembler.emit(0x66)
  assembler.rex(true, source, destination.ord)
  assembler.emit(0x0F, 0x7E)
  assembler.registers(source, destination.ord)

proc floatBinary*(assembler: var XAssembler, operation, destination,
    source: int) {.raises: [].} =
  ## Emits scalar double addition, subtraction, multiplication, or division.
  const Opcodes = [0x58'u8, 0x5C'u8, 0x59'u8, 0x5E'u8]
  doAssert operation in 0 .. 3
  doAssert destination in 0 .. 15 and source in 0 .. 15
  assembler.emit(0xF2)
  assembler.rex(false, destination, source)
  assembler.emit(0x0F, Opcodes[operation])
  assembler.registers(destination, source)

proc xorFloat*(assembler: var XAssembler, destination, source: int)
    {.raises: [].} =
  ## Xors all floating register bits without numeric conversion.
  doAssert destination in 0 .. 15 and source in 0 .. 15
  assembler.rex(false, destination, source)
  assembler.emit(0x0F, 0x57)
  assembler.registers(destination, source)

proc call*(assembler: var XAssembler, register: XRegister) {.raises: [].} =
  ## Calls an absolute address using the current platform ABI.
  assembler.rex(false, 2, register.ord)
  assembler.emit(0xFF)
  assembler.registers(2, register.ord)

proc jump*(assembler: var XAssembler, register: XRegister) {.raises: [].} =
  ## Transfers control to another already compiled instruction block.
  assembler.rex(false, 4, register.ord)
  assembler.emit(0xFF)
  assembler.registers(4, register.ord)

proc returnToCaller*(assembler: var XAssembler) {.raises: [].} =
  ## Returns after the caller's nonvolatile state has been restored.
  assembler.emit(0xC3)

proc trap*(assembler: var XAssembler) {.raises: [].} =
  ## Stops execution if an unreachable instruction is reached.
  assembler.emit(0x0F)
  assembler.emit(0x0B)

proc position*(assembler: XAssembler): int {.raises: [].} =
  ## Returns the next machine code byte offset.
  assembler.code.len

proc offsetOf*(assembler: XAssembler, target: XLabel): int {.raises: [].} =
  ## Returns the resolved byte offset of a label.
  assembler.targets[int(target)]

proc call*(assembler: var XAssembler, target: XLabel) {.raises: [].} =
  ## Calls a procedure in the same position independent code image.
  assembler.emit(0xE8)
  assembler.displacement(target)

proc loadSized*(assembler: var XAssembler, destination, base: XRegister,
    offset, bytes: int) {.raises: [].} =
  ## Loads a scalar and zero extends bytes narrower than a machine word.
  assembler.rex(bytes == 8, destination.ord, base.ord)
  case bytes
  of 1: assembler.emit(0x0F, 0xB6)
  of 2: assembler.emit(0x0F, 0xB7)
  else: assembler.emit(0x8B)
  assembler.memory(destination.ord, base, offset)

proc storeSized*(assembler: var XAssembler, source, base: XRegister,
    offset, bytes: int) {.raises: [].} =
  ## Stores exactly the declared scalar width.
  if bytes == 2:
    assembler.emit(0x66)
  assembler.rex(bytes == 8, source.ord, base.ord)
  assembler.emit(if bytes == 1: 0x88'u8 else: 0x89'u8)
  assembler.memory(source.ord, base, offset)

proc scalar*(assembler: var XAssembler, opcode: byte,
    destination, source: int, single = false) {.raises: [].} =
  ## Encodes a scalar SSE operation between registers.
  assembler.emit(if single: 0xF3'u8 else: 0xF2'u8)
  assembler.rex(false, destination, source)
  assembler.emit(0x0F, opcode)
  assembler.registers(destination, source)

proc vectorBinary*(assembler: var XAssembler, opcode: byte,
    destination, source: int) {.raises: [].} =
  ## Encodes packed float32 arithmetic or an interleave between XMM registers.
  doAssert destination in 0 .. 15 and source in 0 .. 15
  assembler.rex(false, destination, source)
  assembler.emit(0x0f, opcode)
  assembler.registers(destination, source)

proc vectorExtract*(assembler: var XAssembler, destination, source,
    lane: int) {.raises: [].} =
  ## Shuffles one float32 lane to the scalar low position without arithmetic.
  doAssert destination in 0 .. 15 and source in 0 .. 15 and lane in 0 .. 1
  assembler.emit(0x66)
  assembler.rex(false, destination, source)
  assembler.emit(0x0f, 0x70)
  assembler.registers(destination, source)
  assembler.emit(byte(lane))

proc scalarMemory*(assembler: var XAssembler, register: int,
    base: XRegister, offset: int, single, store: bool) {.raises: [].} =
  ## Transfers a scalar SSE value to or from concrete storage.
  assembler.emit(if single: 0xF3'u8 else: 0xF2'u8)
  assembler.rex(false, register, base.ord)
  assembler.emit(0x0F, if store: 0x11'u8 else: 0x10'u8)
  assembler.memory(register, base, offset)

proc vectorMemory*(assembler: var XAssembler, register: int,
    base: XRegister, offset: int, store: bool) {.raises: [].} =
  ## Preserves all 128 XMM bits without requiring aligned memory.
  doAssert register in 0 .. 15
  assembler.emit(0xF3)
  assembler.rex(false, register, base.ord)
  assembler.emit(0x0F, if store: 0x7F'u8 else: 0x6F'u8)
  assembler.memory(register, base, offset)

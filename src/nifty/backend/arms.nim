## Encodes AArch64 instructions, adapted from treeform/bassy under MIT.
## Every instruction is one 32-bit word, so labels patch in place.
## Encodings follow the Arm Architecture Reference Manual field layouts.

import common

type
  Register* = distinct uint32

  Width* = enum
    ## Selects the 32-bit W or 64-bit X view of a register.
    Word32,
    Word64

  LogicalOperation* = enum
    AndOperation, OrOperation, XorOperation

  Condition* = enum
    ## Branch and select conditions, in architectural encoding order.
    EqualCondition,
    NotEqualCondition,
    CarrySetCondition,
    CarryClearCondition,
    NegativeCondition,
    PositiveCondition,
    OverflowCondition,
    NoOverflowCondition,
    UnsignedGreaterCondition,
    UnsignedLessEqualCondition,
    GreaterEqualCondition,
    LessCondition,
    GreaterCondition,
    LessEqualCondition,
    AlwaysCondition

  Label* = distinct int

  FixupKind = enum
    Branch26Fixup,
    Branch19Fixup,
    BranchBitFixup

  Fixup = object
    kind: FixupKind
    at: int
    label: int

  Assembler* = object
    ## Collects instruction words plus unresolved label references.
    code*: seq[uint32]
    targets: seq[int]
    fixups: seq[Fixup]

const
  X0* = Register(0)
  X1* = Register(1)
  X2* = Register(2)
  X3* = Register(3)
  X4* = Register(4)
  X5* = Register(5)
  X6* = Register(6)
  X7* = Register(7)
  X8* = Register(8)
  X9* = Register(9)
  X10* = Register(10)
  X11* = Register(11)
  X12* = Register(12)
  X13* = Register(13)
  X14* = Register(14)
  X15* = Register(15)
  X16* = Register(16)
  X17* = Register(17)
  X19* = Register(19)
  X20* = Register(20)
  X21* = Register(21)
  X22* = Register(22)
  X23* = Register(23)
  X24* = Register(24)
  X25* = Register(25)
  X26* = Register(26)
  X27* = Register(27)
  X28* = Register(28)
  FramePointer* = Register(29)
  LinkRegister* = Register(30)
  ZeroRegister* = Register(31)
  StackPointer* = Register(31)

proc number(register: Register): uint32 {.inline, raises: [].} =
  ## Returns the five-bit encoding of a register.
  uint32(register) and 31'u32

proc sizeBit(width: Width): uint32 {.inline, raises: [].} =
  ## Returns the sf field that selects the 64-bit form.
  if width == Word64: 1'u32 shl 31 else: 0'u32

proc fail(message: string) {.noreturn, raises: [BackendError].} =
  ## Reports a controlled encoding failure.
  raise newException(BackendError, message)

proc emit(assembler: var Assembler, word: uint32) {.inline, raises: [].} =
  ## Appends one encoded instruction.
  assembler.code.add(word)

proc position*(assembler: Assembler): int {.inline, raises: [].} =
  ## Returns the index of the next instruction word.
  assembler.code.len

proc label*(assembler: var Assembler): Label {.raises: [].} =
  ## Reserves an unplaced branch target.
  assembler.targets.add(-1)
  Label(assembler.targets.len - 1)

proc place*(assembler: var Assembler, target: Label) {.raises: [].} =
  ## Fixes a label at the current instruction position.
  assembler.targets[int(target)] = assembler.code.len

proc resolve*(assembler: var Assembler) {.raises: [BackendError].} =
  ## Patches every recorded branch once all labels are placed.
  for fixup in assembler.fixups:
    let destination = assembler.targets[fixup.label]
    if destination < 0:
      fail("assembler label was never placed")
    let distance = destination - fixup.at
    case fixup.kind
    of Branch26Fixup:
      if distance < -(1 shl 25) or distance >= (1 shl 25):
        fail("assembler branch is out of range")
      assembler.code[fixup.at] = assembler.code[fixup.at] or
        (uint32(distance) and 0x03FFFFFF'u32)
    of Branch19Fixup:
      if distance < -(1 shl 18) or distance >= (1 shl 18):
        fail("assembler branch is out of range")
      assembler.code[fixup.at] = assembler.code[fixup.at] or
        ((uint32(distance) and 0x0007FFFF'u32) shl 5)
    of BranchBitFixup:
      if distance >= -(1 shl 13) and distance < (1 shl 13):
        assembler.code[fixup.at] = assembler.code[fixup.at] or
          ((uint32(distance) and 0x3FFF'u32) shl 5)
      else:
        let jump = distance - 1
        if jump < -(1 shl 25) or jump >= (1 shl 25):
          fail("assembler bit branch is out of range")
        assembler.code[fixup.at] =
          (assembler.code[fixup.at] xor 0x01000000'u32) or (2'u32 shl 5)
        assembler.code[fixup.at + 1] =
          0x14000000'u32 or (uint32(jump) and 0x03FFFFFF'u32)
  assembler.fixups.setLen(0)

proc moveZero*(assembler: var Assembler, width: Width, destination: Register,
    value: uint16, shift = 0) {.raises: [].} =
  ## Writes a 16-bit field and zeroes the rest of the register.
  let base = if width == Word64: 0xD2800000'u32 else: 0x52800000'u32
  assembler.emit(
    base or (uint32(shift div 16) shl 21) or (uint32(value) shl 5) or
      destination.number
  )

proc moveNot*(assembler: var Assembler, width: Width, destination: Register,
    value: uint16, shift = 0) {.raises: [].} =
  ## Writes the inverse of a 16-bit field into a cleared register.
  let base = if width == Word64: 0x92800000'u32 else: 0x12800000'u32
  assembler.emit(
    base or (uint32(shift div 16) shl 21) or (uint32(value) shl 5) or
      destination.number
  )

proc moveKeep*(assembler: var Assembler, width: Width, destination: Register,
    value: uint16, shift = 0) {.raises: [].} =
  ## Overwrites one 16-bit field and keeps the others.
  let base = if width == Word64: 0xF2800000'u32 else: 0x72800000'u32
  assembler.emit(
    base or (uint32(shift div 16) shl 21) or (uint32(value) shl 5) or
      destination.number
  )

proc logical(assembler: var Assembler, base: uint32, width: Width,
    destination, left, right: Register, shift: int) {.inline, raises: [].} =
  ## Encodes one shifted-register logical instruction.
  assembler.emit(
    base or width.sizeBit or (right.number shl 16) or
      (uint32(shift) shl 10) or (left.number shl 5) or destination.number
  )

proc moveRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Copies one register into another through ORR with the zero register.
  assembler.logical(
    0x2A000000'u32, width, destination, ZeroRegister, source, 0
  )

proc loadImmediate*(assembler: var Assembler, width: Width,
    destination: Register, value: int64) {.raises: [].} =
  ## Materializes any constant using the fewest wide moves.
  let
    bits =
      if width == Word64: cast[uint64](value)
      else: cast[uint64](value) and 0xFFFFFFFF'u64
    fields = if width == Word64: 4 else: 2
  var negated = not bits
  if width == Word32:
    negated = negated and 0xFFFFFFFF'u64
  var zeroCount = 0
  var onesCount = 0
  for index in 0 ..< fields:
    let field = uint16((bits shr (index * 16)) and 0xFFFF'u64)
    if field == 0:
      inc zeroCount
    if field == 0xFFFF'u16:
      inc onesCount
  if onesCount > zeroCount:
    var first = true
    for index in 0 ..< fields:
      let field = uint16((negated shr (index * 16)) and 0xFFFF'u64)
      if first:
        assembler.moveNot(width, destination, field, index * 16)
        first = false
      elif field != 0:
        let keep = uint16((bits shr (index * 16)) and 0xFFFF'u64)
        assembler.moveKeep(width, destination, keep, index * 16)
  else:
    var first = true
    for index in 0 ..< fields:
      let field = uint16((bits shr (index * 16)) and 0xFFFF'u64)
      if field == 0 and not first:
        continue
      if first:
        assembler.moveZero(width, destination, field, index * 16)
        first = false
      else:
        assembler.moveKeep(width, destination, field, index * 16)

proc arithmeticImmediate(assembler: var Assembler, base: uint32, width: Width,
    destination, source: Register, value: int) {.raises: [BackendError].} =
  ## Encodes an add or subtract with a 12-bit unsigned immediate.
  if value < 0 or value > 4095:
    fail("assembler immediate is out of range")
  assembler.emit(
    base or width.sizeBit or (uint32(value) shl 10) or
      (source.number shl 5) or destination.number
  )

proc addImmediate*(assembler: var Assembler, width: Width,
    destination, source: Register, value: int) {.raises: [BackendError].} =
  ## Adds a small unsigned constant.
  assembler.arithmeticImmediate(
    0x11000000'u32, width, destination, source, value
  )

proc subtractImmediate*(assembler: var Assembler, width: Width,
    destination, source: Register, value: int) {.raises: [BackendError].} =
  ## Subtracts a small unsigned constant.
  assembler.arithmeticImmediate(
    0x51000000'u32, width, destination, source, value
  )

proc compareImmediate*(assembler: var Assembler, width: Width,
    source: Register, value: int) {.raises: [BackendError].} =
  ## Sets flags from a subtraction, discarding the difference.
  assembler.arithmeticImmediate(
    0x71000000'u32, width, ZeroRegister, source, value
  )

proc arithmeticRegister(assembler: var Assembler, base: uint32, width: Width,
    destination, left, right: Register, shift: int) {.inline, raises: [].} =
  ## Encodes an add or subtract of an optionally shifted register.
  assembler.emit(
    base or width.sizeBit or (right.number shl 16) or
      (uint32(shift) shl 10) or (left.number shl 5) or destination.number
  )

proc addRegister*(assembler: var Assembler, width: Width,
    destination, left, right: Register, shift = 0) {.raises: [].} =
  ## Adds two registers, optionally shifting the second left.
  assembler.arithmeticRegister(
    0x0B000000'u32, width, destination, left, right, shift
  )

proc subtractRegister*(assembler: var Assembler, width: Width,
    destination, left, right: Register, shift = 0) {.raises: [].} =
  ## Subtracts the second register from the first.
  assembler.arithmeticRegister(
    0x4B000000'u32, width, destination, left, right, shift
  )

proc compareRegister*(assembler: var Assembler, width: Width,
    left, right: Register) {.raises: [].} =
  ## Sets flags from the difference of two registers.
  assembler.arithmeticRegister(
    0x6B000000'u32, width, ZeroRegister, left, right, 0
  )

proc negate*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Writes the two's complement negation of a register.
  assembler.arithmeticRegister(
    0x4B000000'u32, width, destination, ZeroRegister, source, 0
  )

proc multiplyAdd*(assembler: var Assembler, width: Width,
    destination, left, right, addend: Register) {.raises: [].} =
  ## Computes addend plus the product of two registers.
  assembler.emit(
    0x1B000000'u32 or width.sizeBit or (right.number shl 16) or
      (addend.number shl 10) or (left.number shl 5) or destination.number
  )

proc multiplySubtract*(assembler: var Assembler, width: Width,
    destination, left, right, minuend: Register) {.raises: [].} =
  ## Subtracts the product of two registers from a third.
  assembler.emit(
    0x1B008000'u32 or width.sizeBit or (right.number shl 16) or
      (minuend.number shl 10) or (left.number shl 5) or destination.number
  )

proc multiply*(assembler: var Assembler, width: Width,
    destination, left, right: Register) {.raises: [].} =
  ## Multiplies two registers.
  assembler.multiplyAdd(width, destination, left, right, ZeroRegister)

proc signedDivide*(assembler: var Assembler, width: Width,
    destination, left, right: Register) {.raises: [].} =
  ## Divides with truncation toward zero, yielding zero on a zero divisor.
  assembler.emit(
    0x1AC00C00'u32 or width.sizeBit or (right.number shl 16) or
      (left.number shl 5) or destination.number
  )

proc andRegister*(assembler: var Assembler, width: Width,
    destination, left, right: Register, shift = 0) {.raises: [].} =
  ## Computes a bitwise conjunction.
  assembler.logical(0x0A000000'u32, width, destination, left, right, shift)

proc orRegister*(assembler: var Assembler, width: Width,
    destination, left, right: Register, shift = 0) {.raises: [].} =
  ## Computes a bitwise disjunction.
  assembler.logical(0x2A000000'u32, width, destination, left, right, shift)

proc xorRegister*(assembler: var Assembler, width: Width,
    destination, left, right: Register, shift = 0) {.raises: [].} =
  ## Computes a bitwise exclusive disjunction.
  assembler.logical(0x4A000000'u32, width, destination, left, right, shift)

proc notRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Writes the bitwise complement of a register.
  assembler.logical(
    0x2A200000'u32, width, destination, ZeroRegister, source, 0
  )

proc setOnCondition*(assembler: var Assembler, width: Width,
    destination: Register, condition: Condition) {.raises: [].} =
  ## Writes negative one when the condition holds and zero otherwise.
  let inverted = uint32(ord(condition)) xor 1'u32
  assembler.emit(
    0x5A800000'u32 or width.sizeBit or (ZeroRegister.number shl 16) or
      (inverted shl 12) or (ZeroRegister.number shl 5) or destination.number
  )

proc setBoolean*(assembler: var Assembler, width: Width,
    destination: Register, condition: Condition) {.raises: [].} =
  ## Writes canonical one when the condition holds and zero otherwise.
  let inverted = uint32(ord(condition)) xor 1'u32
  assembler.emit(
    0x1A800400'u32 or width.sizeBit or (ZeroRegister.number shl 16) or
      (inverted shl 12) or (ZeroRegister.number shl 5) or destination.number
  )

proc selectRegister*(assembler: var Assembler, width: Width,
    destination, yes, no: Register, condition: Condition) {.raises: [].} =
  ## Selects one integer payload using the current comparison flags.
  assembler.emit(0x1A800000'u32 or width.sizeBit or
    (no.number shl 16) or (uint32(condition) shl 12) or
    (yes.number shl 5) or destination.number)

proc selectFloat*(assembler: var Assembler, destination, yes, no: int,
    condition: Condition, single = false) {.raises: [BackendError].} =
  ## Selects exact floating bits without arithmetic or NaN canonicalization.
  if destination notin 0 .. 31 or yes notin 0 .. 31 or no notin 0 .. 31:
    fail("Invalid floating-point select register")
  let base = if single: 0x1E200C00'u32 else: 0x1E600C00'u32
  assembler.emit(base or (uint32(no) shl 16) or
    (uint32(condition) shl 12) or (uint32(yes) shl 5) or uint32(destination))

proc scaledOffset(offset, scale: int): uint32 {.raises: [BackendError].} =
  ## Converts a byte offset into the scaled 12-bit immediate field.
  if offset < 0 or offset mod scale != 0 or (offset div scale) > 4095:
    fail("assembler memory offset is out of range")
  uint32(offset div scale)

proc loadByte*(assembler: var Assembler, destination, base: Register,
    offset = 0) {.raises: [BackendError].} =
  ## Loads one byte, zero-extending into the destination.
  assembler.emit(
    0x39400000'u32 or (scaledOffset(offset, 1) shl 10) or
      (base.number shl 5) or destination.number
  )

proc storeByte*(assembler: var Assembler, source, base: Register,
    offset = 0) {.raises: [BackendError].} =
  ## Stores the low byte of a register.
  assembler.emit(
    0x39000000'u32 or (scaledOffset(offset, 1) shl 10) or
      (base.number shl 5) or source.number
  )

proc loadWord*(assembler: var Assembler, destination, base: Register,
    offset = 0) {.raises: [BackendError].} =
  ## Loads 32 bits, zero-extending into the destination.
  assembler.emit(
    0xB9400000'u32 or (scaledOffset(offset, 4) shl 10) or
      (base.number shl 5) or destination.number
  )

proc storeWord*(assembler: var Assembler, source, base: Register,
    offset = 0) {.raises: [BackendError].} =
  ## Stores the low 32 bits of a register.
  assembler.emit(
    0xB9000000'u32 or (scaledOffset(offset, 4) shl 10) or
      (base.number shl 5) or source.number
  )

proc loadDouble*(assembler: var Assembler, destination, base: Register,
    offset = 0) {.raises: [BackendError].} =
  ## Loads 64 bits.
  assembler.emit(
    0xF9400000'u32 or (scaledOffset(offset, 8) shl 10) or
      (base.number shl 5) or destination.number
  )

proc storeDouble*(assembler: var Assembler, source, base: Register,
    offset = 0) {.raises: [BackendError].} =
  ## Stores 64 bits.
  assembler.emit(
    0xF9000000'u32 or (scaledOffset(offset, 8) shl 10) or
      (base.number shl 5) or source.number
  )

proc storePair*(assembler: var Assembler, first, second, base: Register,
    offset: int, preIndex = false) {.raises: [BackendError].} =
  ## Stores two 64-bit registers, optionally updating the base first.
  if offset mod 8 != 0 or offset div 8 < -64 or offset div 8 > 63:
    fail("assembler memory offset is out of range")
  let base32 = if preIndex: 0xA9800000'u32 else: 0xA9000000'u32
  assembler.emit(
    base32 or ((uint32(offset div 8) and 0x7F'u32) shl 15) or
      (second.number shl 10) or (base.number shl 5) or first.number
  )

proc loadPair*(assembler: var Assembler, first, second, base: Register,
    offset: int, postIndex = false) {.raises: [BackendError].} =
  ## Loads two 64-bit registers, optionally updating the base afterward.
  if offset mod 8 != 0 or offset div 8 < -64 or offset div 8 > 63:
    fail("assembler memory offset is out of range")
  let base32 = if postIndex: 0xA8C00000'u32 else: 0xA9400000'u32
  assembler.emit(
    base32 or ((uint32(offset div 8) and 0x7F'u32) shl 15) or
      (second.number shl 10) or (base.number shl 5) or first.number
  )

proc storeFloatPair*(assembler: var Assembler, first, second: int,
    base: Register, offset: int) {.raises: [BackendError].} =
  ## Stores the lower 64 bits of two floating registers without writeback.
  if first notin 0 .. 31 or second notin 0 .. 31 or
    offset mod 8 != 0 or offset div 8 < -64 or offset div 8 > 63:
      fail("assembler floating pair operand is out of range")
  assembler.emit(
    0x6D000000'u32 or ((uint32(offset div 8) and 0x7F'u32) shl 15) or
      (uint32(second) shl 10) or (base.number shl 5) or uint32(first)
  )

proc loadFloatPair*(assembler: var Assembler, first, second: int,
    base: Register, offset: int, single = false) {.raises: [BackendError].} =
  ## Loads two scalar floating registers at their width without writeback.
  let width = if single: 4 else: 8
  if first notin 0 .. 31 or second notin 0 .. 31 or first == second or
    offset mod width != 0 or offset div width < -64 or
    offset div width > 63:
      fail("assembler floating pair operand is out of range")
  let opcode = if single: 0x2D400000'u32 else: 0x6D400000'u32
  assembler.emit(
    opcode or ((uint32(offset div width) and 0x7F'u32) shl 15) or
      (uint32(second) shl 10) or (base.number shl 5) or uint32(first)
  )

proc vectorMemory*(assembler: var Assembler, register: int,
    base: Register, offset: int, store: bool) {.raises: [BackendError].} =
  ## Transfers 128 bits without requiring an aligned base address.
  if register notin 0 .. 31:
    fail("assembler vector register is out of range")
  let opcode = if store: 0x3D800000'u32 else: 0x3DC00000'u32
  assembler.emit(opcode or (scaledOffset(offset, 16) shl 10) or
    (base.number shl 5) or uint32(register))

proc vectorPair*(assembler: var Assembler, first, second: int,
    base: Register, offset: int, store: bool) {.raises: [BackendError].} =
  ## Transfers two unaligned 128-bit vectors without base writeback.
  if first notin 0 .. 31 or second notin 0 .. 31 or
      first == second or offset mod 16 != 0 or
      offset div 16 notin -64 .. 63:
    fail("assembler vector pair operand is out of range")
  let opcode = if store: 0xAD000000'u32 else: 0xAD400000'u32
  assembler.emit(opcode or
    ((uint32(offset div 16) and 0x7F'u32) shl 15) or
    (uint32(second) shl 10) or (base.number shl 5) or uint32(first))

proc branch*(assembler: var Assembler, target: Label) {.raises: [].} =
  ## Jumps unconditionally to a label.
  assembler.fixups.add(
    Fixup(kind: Branch26Fixup, at: assembler.code.len, label: int(target))
  )
  assembler.emit(0x14000000'u32)

proc branchIf*(assembler: var Assembler, condition: Condition,
    target: Label) {.raises: [].} =
  ## Jumps to a label when the condition holds.
  assembler.fixups.add(
    Fixup(kind: Branch19Fixup, at: assembler.code.len, label: int(target))
  )
  assembler.emit(0x54000000'u32 or uint32(ord(condition)))

proc branchIfZero*(assembler: var Assembler, width: Width, source: Register,
    target: Label) {.raises: [].} =
  ## Jumps to a label when a register holds zero.
  assembler.fixups.add(
    Fixup(kind: Branch19Fixup, at: assembler.code.len, label: int(target))
  )
  assembler.emit(0x34000000'u32 or width.sizeBit or source.number)

proc branchIfNotZero*(assembler: var Assembler, width: Width,
    source: Register, target: Label) {.raises: [].} =
  ## Jumps to a label when a register holds anything but zero.
  assembler.fixups.add(
    Fixup(kind: Branch19Fixup, at: assembler.code.len, label: int(target))
  )
  assembler.emit(0x35000000'u32 or width.sizeBit or source.number)

proc branchBit*(assembler: var Assembler, source: Register, bit: int,
    target: Label, whenSet = false) {.raises: [BackendError].} =
  ## Tests one bit, reserving a second word for an out-of-range branch.
  if bit < 0 or bit >= 64:
    fail("assembler bit index must be in 0 ..< 64")
  assembler.fixups.add(Fixup(
    kind: BranchBitFixup,
    at: assembler.code.len,
    label: int(target)
  ))
  assembler.emit(
    0x36000000'u32 or (uint32(bit shr 5) shl 31) or
      (uint32(bit and 31) shl 19) or
      (if whenSet: 0x01000000'u32 else: 0'u32) or source.number
  )
  assembler.emit(0xD503201F'u32)

proc callRegister*(assembler: var Assembler, target: Register)
    {.raises: [].} =
  ## Calls the address held in a register, setting the link register.
  assembler.emit(0xD63F0000'u32 or (target.number shl 5))

proc jumpRegister*(assembler: var Assembler, target: Register)
    {.raises: [].} =
  ## Jumps to the address held in a register without linking.
  assembler.emit(0xD61F0000'u32 or (target.number shl 5))

proc returnToCaller*(assembler: var Assembler) {.raises: [].} =
  ## Returns through the link register.
  assembler.emit(0xD65F03C0'u32)

proc trap*(assembler: var Assembler) {.raises: [].} =
  ## Stops execution if an unreachable instruction is reached.
  assembler.emit(0xD4200000'u32)

proc testLowBits*(assembler: var Assembler, width: Width, source: Register,
    count: int) {.raises: [BackendError].} =
  ## Sets flags from the lowest bits of a register, leaving the result
  ## nowhere. The logical immediate for a run of ones starting at bit zero
  ## is simply its length minus one.
  if count < 1 or count > (if width == Word64: 63 else: 31):
    fail("assembler bit count is out of range")
  assembler.emit(
    0x72000000'u32 or width.sizeBit or
      (if width == Word64: 1'u32 shl 22 else: 0'u32) or
      (uint32(count - 1) shl 10) or (source.number shl 5) or 31'u32
  )

proc logicalEncoding*(width: Width, bits: uint64): int32 {.raises: [].} =
  ## Finds canonical N, immr and imms fields, or declines an invalid mask.
  let
    size = if width == Word64: 64 else: 32
    full = if size == 64: uint64.high else: 0xffffffff'u64
  if bits == 0 or bits == full or (bits and not full) != 0:
    return -1
  for length in [2, 4, 8, 16, 32, 64]:
    if length > size:
      break
    let
      mask = if length == 64: uint64.high else: (1'u64 shl length) - 1
      element = bits and mask
    if element == 0 or element == mask:
      continue
    var repeated = element
    for offset in countup(length, size - 1, length):
      repeated = repeated or (element shl offset)
    if repeated != bits:
      continue
    for rotation in 0 ..< length:
      let low = if rotation == 0: element
        else: ((element shl rotation) or
          (element shr (length - rotation))) and mask
      if (low and (low + 1)) != 0:
        continue
      var
        ones = 0
        remaining = low
      while remaining != 0:
        inc ones
        remaining = remaining shr 1
      return int32(
        (if length == 64: 1'u32 shl 22 else: 0'u32) or
        (uint32(rotation) shl 16) or
        (uint32(((-2 * length) or (ones - 1)) and 63) shl 10)
      )
  -1

proc logicalImmediate*(assembler: var Assembler, width: Width,
    operation: LogicalOperation, destination, source: Register, bits: uint64)
    {.raises: [BackendError].} =
  ## Emits one logical mask without using a scratch integer register.
  let fields = logicalEncoding(width, bits)
  if fields < 0:
    fail("Logical immediate mask is not encodable")
  assembler.emit(
    0x12000000'u32 or width.sizeBit or
    (uint32(ord(operation)) shl 29) or uint32(fields) or
    (source.number shl 5) or destination.number
  )

proc signedMultiplyLong*(assembler: var Assembler,
    destination, left, right: Register) {.raises: [].} =
  ## Multiplies two 32-bit registers into a full 64-bit result.
  assembler.emit(
    0x9B207C00'u32 or (right.number shl 16) or (left.number shl 5) or
      destination.number
  )

proc arithmeticShiftRight*(assembler: var Assembler, width: Width,
    destination, source: Register, count: int) {.raises: [BackendError].} =
  ## Shifts right, keeping the sign, by a constant.
  let last = if width == Word64: 63 else: 31
  if count < 0 or count > last:
    fail("assembler shift count is out of range")
  let base =
    if width == Word64: 0x9340_0000'u32 else: 0x1300_0000'u32
  assembler.emit(
    base or (uint32(count) shl 16) or (uint32(last) shl 10) or
      (source.number shl 5) or destination.number
  )

proc offsetOf*(assembler: Assembler, target: Label): int {.raises: [].} =
  ## Returns where a label ended up, in instruction words.
  assembler.targets[int(target)]

proc signExtendWord*(assembler: var Assembler,
    destination, source: Register) {.raises: [].} =
  ## Widens a 32-bit register into a 64-bit one, keeping the sign.
  assembler.emit(
    0x93407C00'u32 or (source.number shl 5) or destination.number
  )

proc shiftLeftImmediate*(assembler: var Assembler, width: Width,
    destination, source: Register, count: int) {.raises: [BackendError].} =
  ## Shifts left by a constant, which is a bitfield move underneath.
  let size = if width == Word64: 64 else: 32
  if count < 0 or count >= size:
    fail("assembler shift count is out of range")
  let base = if width == Word64: 0xD3400000'u32 else: 0x53000000'u32
  assembler.emit(
    base or (uint32((size - count) mod size) shl 16) or
      (uint32(size - 1 - count) shl 10) or (source.number shl 5) or
      destination.number
  )

proc shiftRightImmediate*(assembler: var Assembler, width: Width,
    destination, source: Register, count: int) {.raises: [BackendError].} =
  ## Shifts right without keeping the sign, by a constant.
  let size = if width == Word64: 64 else: 32
  if count < 0 or count >= size:
    fail("assembler shift count is out of range")
  let base = if width == Word64: 0xD3400000'u32 else: 0x53000000'u32
  assembler.emit(
    base or (uint32(count) shl 16) or (uint32(size - 1) shl 10) or
      (source.number shl 5) or destination.number
  )

proc branchLink*(assembler: var Assembler, target: Label) {.raises: [].} =
  ## Calls a label, leaving the return address in the link register.
  assembler.fixups.add(
    Fixup(kind: Branch26Fixup, at: assembler.code.len, label: int(target))
  )
  assembler.emit(0x94000000'u32)

proc loadFloat*(assembler: var Assembler, destination: int, base: Register,
    offset = 0, single = false) {.raises: [BackendError].} =
  ## Loads one binary32 or binary64 floating-point register from memory.
  if destination notin 0 .. 31:
    fail("Invalid floating-point register")
  let opcode = if single: 0xBD400000'u32 else: 0xFD400000'u32
  assembler.emit(opcode or
    (scaledOffset(offset, if single: 4 else: 8) shl 10) or
    (base.number shl 5) or destination.uint32)

proc storeFloat*(assembler: var Assembler, source: int, base: Register,
    offset = 0, single = false) {.raises: [BackendError].} =
  ## Stores one binary32 or binary64 floating-point register to memory.
  if source notin 0 .. 31:
    fail("Invalid floating-point register")
  let opcode = if single: 0xBD000000'u32 else: 0xFD000000'u32
  assembler.emit(opcode or
    (scaledOffset(offset, if single: 4 else: 8) shl 10) or
    (base.number shl 5) or source.uint32)

proc floatBinary*(assembler: var Assembler, operation: int,
    destination, left, right: int, single = false)
    {.raises: [BackendError].} =
  ## Encodes floating addition, subtraction, multiplication, or division.
  if operation notin 0 .. 3 or destination notin 0 .. 31 or
      left notin 0 .. 31 or right notin 0 .. 31:
      fail("Invalid floating-point operation")
  const Bases = [0x1E602800'u32, 0x1E603800'u32,
    0x1E600800'u32, 0x1E601800'u32]
  let base = Bases[operation] and (if single: not 0x00400000'u32 else:
    uint32.high)
  assembler.emit(base or (right.uint32 shl 16) or
    (left.uint32 shl 5) or destination.uint32)

proc vectorBinary*(assembler: var Assembler, operation: int,
    destination, left, right: int) {.raises: [BackendError].} =
  ## Encodes independent two-lane float32 arithmetic or lane packing.
  if operation notin 0 .. 4 or destination notin 0 .. 31 or
      left notin 0 .. 31 or right notin 0 .. 31:
      fail("Invalid two-lane float32 operation")
  const Bases = [0x0e20d400'u32, 0x0ea0d400'u32,
    0x2e20dc00'u32, 0x0e803800'u32, 0x2e20fc00'u32]
  assembler.emit(Bases[operation] or (right.uint32 shl 16) or
    (left.uint32 shl 5) or destination.uint32)

proc vectorExtract*(assembler: var Assembler, destination, source,
    lane: int) {.raises: [BackendError].} =
  ## Copies one float32 lane without converting its representation.
  if destination notin 0 .. 31 or source notin 0 .. 31 or lane notin 0 .. 1:
    fail("Invalid two-lane float32 extraction")
  assembler.emit(0x5e040400'u32 or (lane.uint32 shl 19) or
    (source.uint32 shl 5) or destination.uint32)

proc vectorSum*(assembler: var Assembler, destination, source: int)
    {.raises: [BackendError].} =
  ## Adds lane zero to lane one with one ordinary float32 rounding step.
  if destination notin 0 .. 31 or source notin 0 .. 31:
    fail("Invalid two-lane float32 sum")
  assembler.emit(0x7e30d800'u32 or
    (source.uint32 shl 5) or destination.uint32)

proc compareFloatZero*(assembler: var Assembler, source: int, single = false)
    {.raises: [BackendError].} =
  ## Sets floating-point comparison flags against positive zero.
  if source notin 0 .. 31:
    fail("Invalid floating-point register")
  let base = if single: 0x1E202008'u32 else: 0x1E602008'u32
  assembler.emit(base or (source.uint32 shl 5))

proc compareFloat*(assembler: var Assembler, left, right: int, single = false)
    {.raises: [BackendError].} =
  ## Sets ordered and unordered flags from two double operands.
  if left notin 0 .. 31 or right notin 0 .. 31:
    fail("Invalid floating-point register")
  let base = if single: 0x1E202000'u32 else: 0x1E602000'u32
  assembler.emit(base or (right.uint32 shl 16) or
    (left.uint32 shl 5))

proc floatUnary*(assembler: var Assembler, operation: int,
    destination, source: int, single = false) {.raises: [BackendError].} =
  ## Encodes floating copies, signs, square root, floor, and ties-away rounding.
  if operation notin 0 .. 5 or destination notin 0 .. 31 or
      source notin 0 .. 31:
      fail("Invalid floating-point operation")
  const Bases = [0x1E604000'u32, 0x1E614000'u32,
    0x1E60C000'u32, 0x1E61C000'u32, 0x1E654000'u32, 0x1E664000'u32]
  let base = Bases[operation] and (if single: not 0x00400000'u32 else:
    uint32.high)
  assembler.emit(base or (source.uint32 shl 5) or
    destination.uint32)

proc integerToFloat*(assembler: var Assembler, destination: int,
    source: Register, single = false, unsigned = false)
    {.raises: [BackendError].} =
  ## Converts a signed or unsigned integer to the requested floating precision.
  if destination notin 0 .. 31:
    fail("Invalid floating-point register")
  let base = (if single: 0x9E220000'u32 else: 0x9E620000'u32) or
    (if unsigned: 0x00010000'u32 else: 0'u32)
  assembler.emit(base or (source.number shl 5) or destination.uint32)

proc floatToInteger*(assembler: var Assembler, destination: Register,
    source: int, single = false) {.raises: [BackendError].} =
  ## Truncates the requested floating precision to a signed 64-bit integer.
  if source notin 0 .. 31:
    fail("Invalid floating-point register")
  let base = if single: 0x9E380000'u32 else: 0x9E780000'u32
  assembler.emit(base or (source.uint32 shl 5) or destination.number)

proc bitsToFloat*(assembler: var Assembler, destination: int,
    source: Register, single = false) {.raises: [BackendError].} =
  ## Copies integer bits into a floating register without numeric conversion.
  if destination notin 0 .. 31:
    fail("Invalid floating-point register")
  let base = if single: 0x1E270000'u32 else: 0x9E670000'u32
  assembler.emit(base or (source.number shl 5) or
    destination.uint32)

proc floatToBits*(assembler: var Assembler, destination: Register,
    source: int, single = false) {.raises: [BackendError].} =
  ## Copies floating bits into a general register without numeric conversion.
  if source notin 0 .. 31:
    fail("Invalid floating-point register")
  let base = if single: 0x1E260000'u32 else: 0x9E660000'u32
  assembler.emit(base or (source.uint32 shl 5) or destination.number)

proc floatImmediateBits*(immediate: uint8): uint32 {.raises: [].} =
  ## Expands the ARM64 binary32 floating immediate into its exact IEEE bits.
  let
    value = uint32(immediate)
    repeated = (value shr 6) and 1
  ((value and 0x80) shl 24) or ((1 - repeated) shl 30) or
    ((repeated * 31) shl 25) or ((value and 0x30) shl 19) or
    ((value and 15) shl 19)

proc floatImmediate*(assembler: var Assembler, destination: int,
    bits: uint32, paired = false): bool {.raises: [BackendError].} =
  ## Emits an exact binary32 immediate in one or two lanes, or changes nothing.
  if destination notin 0 .. 31:
    fail("Invalid floating-point register")
  let immediate = uint8(((bits shr 24) and 0x80) or
    (((bits shr 29) and 1) shl 6) or ((bits shr 19) and 0x3f))
  if floatImmediateBits(immediate) != bits:
    return false
  if paired:
    assembler.emit(0x0F00F400'u32 or
      ((uint32(immediate) and 0xe0) shl 11) or
      ((uint32(immediate) and 0x1f) shl 5) or uint32(destination))
  else:
    assembler.emit(0x1E201000'u32 or (uint32(immediate) shl 13) or
      uint32(destination))
  true

proc floatImmediateBits64*(immediate: uint8): uint64 {.raises: [].} =
  ## Expands the ARM64 binary64 immediate into its exact IEEE representation.
  let
    value = uint64(immediate)
    repeated = (value shr 6) and 1
  ((value and 0x80) shl 56) or ((1 - repeated) shl 62) or
    ((repeated * 255) shl 54) or ((value and 0x3f) shl 48)

proc floatImmediate*(assembler: var Assembler, destination: int,
    bits: uint64): bool {.raises: [BackendError].} =
  ## Emits an exact binary64 immediate or leaves the instruction stream intact.
  if destination notin 0 .. 31:
    fail("Invalid floating-point register")
  let immediate = uint8(((bits shr 56) and 0x80) or
    (((bits shr 61) and 1) shl 6) or ((bits shr 48) and 0x3f))
  if floatImmediateBits64(immediate) != bits:
    return false
  assembler.emit(0x1E601000'u32 or (uint32(immediate) shl 13) or
    uint32(destination))
  true

proc stackAdjustment*(assembler: var Assembler, bytes: int,
    subtract: bool) {.raises: [BackendError].} =
  ## Adjusts SP with two fixed-size immediate instructions for patching.
  if bytes < 0 or bytes > 0xFFFFFF or bytes mod 16 != 0:
    fail("Invalid native stack adjustment")
  let base = if subtract: 0xD10003FF'u32 else: 0x910003FF'u32
  assembler.emit(base or (1'u32 shl 22) or
    (uint32(bytes shr 12) shl 10))
  assembler.emit(base or (uint32(bytes and 4095) shl 10))

proc loadHalf*(assembler: var Assembler, destination, base: Register,
    offset = 0) {.raises: [BackendError].} =
  ## Loads an unsigned halfword from concrete native storage.
  assembler.emit(0x79400000'u32 or (scaledOffset(offset, 2) shl 10) or
    (base.number shl 5) or destination.number)

proc storeHalf*(assembler: var Assembler, source, base: Register,
    offset = 0) {.raises: [BackendError].} =
  ## Stores the low halfword of a register into concrete native storage.
  assembler.emit(0x79000000'u32 or (scaledOffset(offset, 2) shl 10) or
    (base.number shl 5) or source.number)

proc signExtend*(assembler: var Assembler, destination, source: Register,
    bits: int) {.raises: [BackendError].} =
  ## Sign extends a low byte, halfword, or word to 64 bits.
  if bits notin [8, 16, 32]:
    fail("Invalid native integer extension")
  assembler.emit(0x93400000'u32 or ((bits - 1).uint32 shl 10) or
    (source.number shl 5) or destination.number)

proc unsignedDivide*(assembler: var Assembler, destination, a, b: Register)
    {.raises: [].} =
  ## Divides two unsigned 64-bit integer registers.
  assembler.emit(0x9AC00800'u32 or (b.number shl 16) or
    (a.number shl 5) or destination.number)

proc shiftRegister*(assembler: var Assembler, destination, value,
    count: Register, operation: int) {.raises: [BackendError].} =
  ## Emits a variable left, logical right, or arithmetic right shift.
  if operation notin 0 .. 2:
    fail("Invalid native shift operation")
  assembler.emit(0x9AC02000'u32 or (operation.uint32 shl 10) or
    (count.number shl 16) or (value.number shl 5) or destination.number)

proc floatConvert*(assembler: var Assembler, destination, source: int,
    toSingle: bool) {.raises: [BackendError].} =
  ## Converts between binary32 and binary64 floating register views.
  if destination notin 0 .. 31 or source notin 0 .. 31:
    fail("Invalid floating-point register")
  let base = if toSingle: 0x1E624000'u32 else: 0x1E22C000'u32
  assembler.emit(base or (source.uint32 shl 5) or destination.uint32)

include armcleans

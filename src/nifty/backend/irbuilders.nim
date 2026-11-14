## Lowers concrete operations into SSA values and explicit memory state.
## Temporary names are frontend handles, never assigned machine registers.
import common, irs

const TemporaryCount = 64

type
  Register* = distinct uint32

  Width* = enum
    ## Selects the concrete integer width during lowering.
    Word32,
    Word64

  Condition* = enum
    ## Names logical conditions before they become explicit SSA booleans.
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

  Temporary = object
    value: ValueId
    known: bool
    dirty: bool

  Target = object
    function: int
    blockId: int

  IrBuilder* = object
    module*: IrModule
    function*: int
    current: int
    targets: seq[Target]
    temporaries: array[TemporaryCount, Temporary]
    addresses: array[TemporaryCount, ValueId]
    frame: ValueId
    zero: ValueId
    context: ValueId
    comparisonLeft, comparisonRight: ValueId
    floatingComparison: bool

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

proc `==`(a, b: Register): bool {.borrow.}
  ## Compares frontend temporary handles without a target register assignment.

proc parameters(builder: var IrBuilder, values: openArray[ValueId]): Span =
  ## Appends explicit operands into the current function's pool.
  result = Span(first: int32(builder.module.functions[builder.function].
    operands.len), count: int32(values.len))
  builder.module.functions[builder.function].operands.add(values)

proc newBlock(builder: var IrBuilder): int =
  ## Allocates a control flow block without choosing an instruction layout.
  result = builder.module.functions[builder.function].blocks.len
  builder.module.functions[builder.function].blocks.add(IrBlock())

proc enter(builder: var IrBuilder, index: int) =
  ## Starts a block with independently loaded mutable temporary state.
  builder.current = index
  builder.temporaries = default(array[TemporaryCount, Temporary])

proc emit(builder: var IrBuilder, instruction: IrInstruction,
    values: openArray[ValueId], kind = UInt64Type): ValueId =
  ## Defines one SSA value or appends one explicit effect instruction.
  if builder.current < 0:
    builder.enter(builder.newBlock())
  let fn = builder.function
  var item = instruction
  item.arguments = builder.parameters(values)
  if item.op notin {StoreOp, MoveBytesOp, ClearBytesOp, CallOp,
      HostCallOp, IndirectCallOp} or item.results.count > 0:
    result = ValueId(builder.module.functions[fn].values.len)
    item.results = Span(first: int32(result), count: 1)
    builder.module.functions[fn].values.add(IrValue(valueType: kind))
  else:
    result = NoValue
  var data = addr builder.module.functions[fn].blocks[builder.current]
  if data.instructions.count == 0:
    data.instructions.first = int32(builder.module.functions[fn].
      instructions.len)
  inc data.instructions.count
  builder.module.functions[fn].instructions.add(item)

proc constant(builder: var IrBuilder, bits: uint64,
    kind = UInt64Type): ValueId =
  ## Creates a typed literal without emitting native instructions.
  builder.emit(IrInstruction(op: ConstantOp, bits: bits), [], kind)

proc kind(builder: IrBuilder, value: ValueId): IrType =
  ## Reads the concrete type of one virtual register.
  builder.module.functions[builder.function].values[int32(value)].valueType

proc convert(builder: var IrBuilder, value: ValueId, kind: IrType,
    conversion = BitcastConversion): ValueId =
  ## Makes widths, signedness, and pointer interpretations explicit.
  if builder.kind(value) == kind:
    return value
  builder.emit(IrInstruction(op: ConvertOp, conversion: conversion),
    [value], kind)

proc binary(builder: var IrBuilder, op: IrOpcode, a, b: ValueId): ValueId =
  ## Defines one typed arithmetic or bit operation.
  builder.emit(IrInstruction(op: op), [a, b], builder.kind(a))

proc read(builder: var IrBuilder, index: int): ValueId =
  ## Reads a mutable frontend temporary into an unbounded SSA register.
  if not builder.temporaries[index].known:
    let value = builder.emit(IrInstruction(op: LoadOp, alignment: 8),
      [builder.addresses[index]])
    builder.temporaries[index] = Temporary(value: value, known: true)
  builder.temporaries[index].value

proc write(builder: var IrBuilder, index: int, value: ValueId) =
  ## Assigns a frontend temporary without choosing a physical register.
  let bits = builder.convert(value, UInt64Type,
    if builder.kind(value) in {BoolType, UInt8Type, UInt16Type, UInt32Type}:
      ZeroExtendConversion
    elif builder.kind(value) in {Int8Type, Int16Type, Int32Type}:
      SignExtendConversion
    else: BitcastConversion)
  builder.temporaries[index] = Temporary(value: bits, known: true, dirty: true)

proc integer(builder: var IrBuilder, register: Register,
    width = Word64): ValueId =
  ## Reads an integer temporary or the immutable zero value.
  let value = if register == ZeroRegister: builder.zero
    else: builder.read(int(register))
  if width == Word32:
    return builder.convert(value, UInt32Type, TruncateConversion)
  value

proc base(builder: var IrBuilder, register: Register): ValueId =
  ## Resolves a frame address or a concrete pointer temporary.
  if register == StackPointer:
    return builder.frame
  builder.convert(builder.integer(register), AddressType)

proc floating(builder: var IrBuilder, register: int,
    single: bool): ValueId =
  ## Reads binary32 or binary64 bits without numeric conversion.
  var value = builder.read(32 + register)
  if single:
    value = builder.convert(value, UInt32Type, TruncateConversion)
  builder.convert(value, if single: Float32Type else: Float64Type)

proc writeFloat(builder: var IrBuilder, register: int, value: ValueId) =
  ## Stores a floating temporary using its exact bit representation.
  let bits = builder.convert(value,
    if builder.kind(value) == Float32Type: UInt32Type else: UInt64Type)
  builder.write(32 + register, bits)

proc flush(builder: var IrBuilder) =
  ## Makes mutable state explicit on every outgoing control flow edge.
  for i, temporary in builder.temporaries:
    if temporary.dirty:
      discard builder.emit(IrInstruction(op: StoreOp, alignment: 8),
        [builder.addresses[i], temporary.value])

proc label*(builder: var IrBuilder): Label =
  ## Reserves a frontend control flow target without a native address.
  builder.targets.add(Target(function: -1, blockId: -1))
  Label(builder.targets.high)

proc target(builder: var IrBuilder, label: Label): int =
  ## Resolves a branch label to a block in the current IR function.
  let index = int(label)
  if builder.targets[index].function < 0:
    builder.targets[index] = Target(function: builder.function,
      blockId: builder.newBlock())
  if builder.targets[index].function != builder.function:
    error("IR branch crosses a procedure boundary")
  builder.targets[index].blockId

proc edge(builder: var IrBuilder, target: int): int32 =
  ## Appends a block edge with no implicit register transfer.
  result = int32(builder.module.functions[builder.function].edges.len)
  builder.module.functions[builder.function].edges.add(
    IrEdge(target: BlockId(target)))

proc branch*(builder: var IrBuilder, label: Label) =
  ## Terminates the current block with an explicit jump.
  if builder.current < 0:
    builder.enter(builder.newBlock())
  let destination = builder.target(label)
  builder.flush()
  let first = builder.edge(destination)
  builder.module.functions[builder.function].blocks[builder.current].
    terminator = IrTerminator(kind: JumpTerminator,
      edges: Span(first: first, count: 1))
  builder.current = -1

proc place*(builder: var IrBuilder, label: Label) =
  ## Connects fallthrough before entering a labeled block.
  let destination = builder.target(label)
  if builder.current == destination:
    return
  if builder.current >= 0 and builder.current != destination:
    builder.branch(label)
  builder.enter(destination)

proc beginFunction*(builder: var IrBuilder, index: int, label: Label) =
  ## Starts a complete procedure with explicit runtime and memory ABI inputs.
  builder.function = index
  builder.module.functions[index].blocks = @[IrBlock(
    parameters: Span(first: 0, count: 4))]
  builder.module.functions[index].values = newSeq[IrValue](4)
  for i, item in builder.module.functions[index].values.mpairs:
    item.valueType = AddressType
    let storage = builder.module.functions[index].signature.parameterStorage
    item.storage = if storage.len > 0: storage[i] else: 0
  builder.enter(0)
  builder.targets[int(label)] = Target(function: index, blockId: 0)
  builder.context = ValueId(0)
  builder.module.functions[index].slots.add(IrSlot(alignment: 16))
  builder.frame = builder.emit(IrInstruction(op: SlotAddressOp, target: 0),
    [], AddressType)
  builder.zero = builder.constant(0)
  for i in 0 ..< TemporaryCount:
    builder.module.functions[index].slots.add(
      IrSlot(byteCount: 8, alignment: 8))
    builder.addresses[i] = builder.emit(IrInstruction(op: SlotAddressOp,
      target: int32(i + 1)), [], AddressType)
    discard builder.emit(IrInstruction(op: StoreOp, alignment: 8),
      [builder.addresses[i], builder.zero])
  builder.write(19, builder.context)
  for i in 0 ..< 3:
    builder.write(i, ValueId(i + 1))

proc finishFunction*(builder: var IrBuilder, bytes: int) =
  ## Finalizes concrete local storage after the entire body has been lowered.
  builder.module.functions[builder.function].slots[0].byteCount = int32(bytes)
  for data in builder.module.functions[builder.function].blocks.mitems:
    if data.terminator.kind == UnsetTerminator:
      data.terminator.kind = ReturnTerminator
  builder.current = -1

proc position*(builder: IrBuilder): int =
  ## Identifies an IR instruction for deferred frame-size constants.
  builder.module.functions[builder.function].instructions.len

proc frameSize*(builder: var IrBuilder, destination: Register) =
  ## Defers total frame sizing until the target assigns registers and spills.
  builder.write(int(destination),
    builder.emit(IrInstruction(op: FrameSizeOp), []))

proc returnToCaller*(builder: var IrBuilder) =
  ## Emits a normal IR return without an architecture-specific epilogue.
  if builder.current < 0:
    builder.enter(builder.newBlock())
  builder.module.functions[builder.function].blocks[builder.current].
    terminator = IrTerminator(kind: ReturnTerminator)
  builder.current = -1

proc loadImmediate*(builder: var IrBuilder, width: Width,
    destination: Register, value: int64) =
  ## Assigns a literal to a frontend temporary.
  let kind = if width == Word32: UInt32Type else: UInt64Type
  let bits = if width == Word32: uint64(cast[uint32](value))
    else: cast[uint64](value)
  builder.write(int(destination), builder.constant(bits, kind))

proc moveRegister*(builder: var IrBuilder, width: Width,
    destination, source: Register) =
  ## Copies a virtual integer value without assigning a machine register.
  builder.write(int(destination), builder.integer(source, width))

proc addressOffset(builder: var IrBuilder, base: ValueId,
    offset: int): ValueId =
  ## Creates an explicit byte offset from a concrete address.
  builder.emit(IrInstruction(op: OffsetAddressOp),
    [base, builder.constant(cast[uint64](offset))], AddressType)

proc addImmediate*(builder: var IrBuilder, width: Width,
    destination, source: Register, value: int) =
  ## Computes pointer offsets or integer additions as typed IR.
  if source == StackPointer:
    builder.write(int(destination),
      builder.addressOffset(builder.frame, value))
  else:
    let a = builder.integer(source, width)
    builder.write(int(destination), builder.binary(AddOp, a,
      builder.constant(cast[uint64](value), builder.kind(a))))

proc subtractImmediate*(builder: var IrBuilder, width: Width,
    destination, source: Register, value: int) =
  ## Computes an explicit integer subtraction.
  let a = builder.integer(source, width)
  builder.write(int(destination), builder.binary(SubtractOp, a,
    builder.constant(cast[uint64](value), builder.kind(a))))

proc arithmetic(builder: var IrBuilder, width: Width, op: IrOpcode,
    destination, left, right: Register, signed = false) =
  ## Normalizes signedness before emitting one scalar operation.
  var
    a = builder.integer(left, width)
    b = builder.integer(right, width)
  if signed:
    let kind = if width == Word32: Int32Type else: Int64Type
    a = builder.convert(a, kind)
    b = builder.convert(b, kind)
  builder.write(int(destination), builder.binary(op, a, b))

proc addRegister*(builder: var IrBuilder, width: Width,
    destination, left, right: Register) =
  ## Emits a typed addRegister operation into the IR.
  builder.arithmetic(width, AddOp, destination, left, right)

proc subtractRegister*(builder: var IrBuilder, width: Width,
    destination, left, right: Register) =
  ## Emits a typed subtractRegister operation into the IR.
  builder.arithmetic(width, SubtractOp, destination, left, right)

proc multiply*(builder: var IrBuilder, width: Width,
    destination, left, right: Register) =
  ## Emits a typed multiply operation into the IR.
  builder.arithmetic(width, MultiplyOp, destination, left, right)

proc signedDivide*(builder: var IrBuilder, width: Width,
    destination, left, right: Register) =
  ## Emits a typed signedDivide operation into the IR.
  builder.arithmetic(width, DivideOp, destination, left, right, true)

proc remainder*(builder: var IrBuilder, width: Width,
    destination, left, right: Register, unsigned = false) =
  ## Preserves remainder semantics for shared optimization and each target.
  builder.arithmetic(
    width,
    RemainderOp,
    destination,
    left,
    right,
    not unsigned
  )

proc andRegister*(builder: var IrBuilder, width: Width,
    destination, left, right: Register) =
  ## Emits a typed andRegister operation into the IR.
  builder.arithmetic(width, AndOp, destination, left, right)

proc orRegister*(builder: var IrBuilder, width: Width,
    destination, left, right: Register) =
  ## Emits a typed orRegister operation into the IR.
  builder.arithmetic(width, OrOp, destination, left, right)

proc xorRegister*(builder: var IrBuilder, width: Width,
    destination, left, right: Register) =
  ## Emits a typed xorRegister operation into the IR.
  builder.arithmetic(width, XorOp, destination, left, right)

proc loadByte*(builder: var IrBuilder, destination, source: Register,
    offset = 0) =
  ## Loads exactly the declared scalar width from concrete memory.
  let value = builder.emit(IrInstruction(op: LoadOp,
    offset: int64(offset), alignment: 1), [builder.base(source)], UInt8Type)
  builder.write(int(destination), value)

proc loadHalf*(builder: var IrBuilder, destination, source: Register,
    offset = 0) =
  ## Loads exactly the declared scalar width from concrete memory.
  let value = builder.emit(IrInstruction(op: LoadOp,
    offset: int64(offset), alignment: 1), [builder.base(source)], UInt16Type)
  builder.write(int(destination), value)

proc loadWord*(builder: var IrBuilder, destination, source: Register,
    offset = 0) =
  ## Loads exactly the declared scalar width from concrete memory.
  let value = builder.emit(IrInstruction(op: LoadOp,
    offset: int64(offset), alignment: 1), [builder.base(source)], UInt32Type)
  builder.write(int(destination), value)

proc loadDouble*(builder: var IrBuilder, destination, source: Register,
    offset = 0) =
  ## Loads exactly the declared scalar width from concrete memory.
  let value = builder.emit(IrInstruction(op: LoadOp,
    offset: int64(offset), alignment: 1), [builder.base(source)], UInt64Type)
  builder.write(int(destination), value)

proc storeByte*(builder: var IrBuilder, source, destination: Register,
    offset = 0) =
  ## Stores exactly the declared scalar width to concrete memory.
  let value = builder.convert(builder.integer(source), UInt8Type,
    TruncateConversion)
  discard builder.emit(IrInstruction(op: StoreOp,
    offset: int64(offset), alignment: 1), [builder.base(destination), value])

proc storeHalf*(builder: var IrBuilder, source, destination: Register,
    offset = 0) =
  ## Stores exactly the declared scalar width to concrete memory.
  let value = builder.convert(builder.integer(source), UInt16Type,
    TruncateConversion)
  discard builder.emit(IrInstruction(op: StoreOp,
    offset: int64(offset), alignment: 1), [builder.base(destination), value])

proc storeWord*(builder: var IrBuilder, source, destination: Register,
    offset = 0) =
  ## Stores exactly the declared scalar width to concrete memory.
  let value = builder.convert(builder.integer(source), UInt32Type,
    TruncateConversion)
  discard builder.emit(IrInstruction(op: StoreOp,
    offset: int64(offset), alignment: 1), [builder.base(destination), value])

proc storeDouble*(builder: var IrBuilder, source, destination: Register,
    offset = 0) =
  ## Stores exactly the declared scalar width to concrete memory.
  let value = builder.convert(builder.integer(source), UInt64Type,
    TruncateConversion)
  discard builder.emit(IrInstruction(op: StoreOp,
    offset: int64(offset), alignment: 1), [builder.base(destination), value])

proc copyValue*(builder: var IrBuilder, destination, source: Register,
    bytes: int, storage = 0'i32) =
  ## Retains one aggregate copy until shared semantic optimization finishes.
  discard builder.emit(IrInstruction(op: MoveBytesOp, byteCount: int32(bytes),
    target: storage), [builder.base(destination), builder.base(source)])

proc clearValue*(builder: var IrBuilder, destination: Register,
    bytes: int, storage = 0'i32) =
  ## Retains aggregate initialization with its concrete storage identity.
  discard builder.emit(IrInstruction(op: ClearBytesOp, byteCount: int32(bytes),
    target: storage), [builder.base(destination)])

proc unsignedDivide*(builder: var IrBuilder,
    destination, left, right: Register) =
  ## Preserves unsigned division through the IR type.
  builder.arithmetic(Word64, DivideOp, destination, left, right)

proc negate*(builder: var IrBuilder, width: Width,
    destination, source: Register) =
  ## Defines wrapping negation at the requested width.
  let a = builder.integer(source, width)
  builder.write(int(destination), builder.emit(
    IrInstruction(op: NegateOp), [a], builder.kind(a)))

proc signExtend*(builder: var IrBuilder, destination, source: Register,
    bits: int) =
  ## Makes narrow signed wrapping explicit before extending to a full word.
  let kind = case bits
    of 8: Int8Type
    of 16: Int16Type
    of 32: Int32Type
    else: Int64Type
  let
    narrow = builder.convert(builder.integer(source), kind,
      TruncateConversion)
    wide = builder.convert(narrow, Int64Type, SignExtendConversion)
  builder.write(int(destination), wide)

proc signExtendWord*(builder: var IrBuilder,
    destination, source: Register) =
  ## Extends a signed binary32 integer to a full word.
  builder.signExtend(destination, source, 32)

proc multiplyAdd*(builder: var IrBuilder, width: Width,
    destination, left, right, addend: Register) =
  ## Represents multiplication and addition as separate portable operations.
  let product = builder.binary(MultiplyOp, builder.integer(left, width),
    builder.integer(right, width))
  builder.write(int(destination), builder.binary(AddOp, product,
    builder.integer(addend, width)))

proc multiplySubtract*(builder: var IrBuilder, width: Width,
    destination, left, right, minuend: Register) =
  ## Represents integer remainder construction without a machine opcode.
  let product = builder.binary(MultiplyOp, builder.integer(left, width),
    builder.integer(right, width))
  builder.write(int(destination), builder.binary(SubtractOp,
    builder.integer(minuend, width), product))

proc shiftRegister*(builder: var IrBuilder, destination, value,
    count: Register, operation: int) =
  ## Keeps shift kind and signedness explicit in portable IR.
  let op = case operation
    of 0: ShiftLeftOp
    of 1: ShiftRightOp
    else: ArithmeticRightOp
  builder.arithmetic(Word64, op, destination, value, count,
    operation == 2)

proc loadFloat*(builder: var IrBuilder, destination: int, source: Register,
    offset = 0, single = false) =
  ## Loads binary32 or binary64 from explicitly addressed memory.
  let value = builder.emit(IrInstruction(op: LoadOp,
    offset: int64(offset), alignment: 1), [builder.base(source)],
    if single: Float32Type else: Float64Type)
  builder.writeFloat(destination, value)

proc floatConstant*(builder: var IrBuilder, destination: int, bits: uint32) =
  ## Defines a binary32 literal without an intermediate binary64 value.
  builder.writeFloat(destination,
    builder.constant(uint64(bits), Float32Type))

proc storeFloat*(builder: var IrBuilder, source: int, destination: Register,
    offset = 0, single = false) =
  ## Stores floating bits at the declared precision.
  discard builder.emit(IrInstruction(op: StoreOp,
    offset: int64(offset), alignment: 1),
    [builder.base(destination), builder.floating(source, single)])

proc floatBinary*(builder: var IrBuilder, operation: int,
    destination, left, right: int, single = false) =
  ## Emits portable typed floating arithmetic.
  const Operations = [AddOp, SubtractOp, MultiplyOp, DivideOp]
  builder.writeFloat(destination, builder.binary(Operations[operation],
    builder.floating(left, single), builder.floating(right, single)))

proc floatUnary*(builder: var IrBuilder, operation: int,
    destination, source: int, single = false) =
  ## Emits scalar floating operations or an explicit absolute bit mask.
  var value = builder.floating(source, single)
  case operation
  of 0:
    discard
  of 1, 3, 4, 5:
    let opcode = case operation
      of 1: NegateOp
      of 3: SqrtOp
      of 4: FloorOp
      else: RoundOp
    value = builder.emit(IrInstruction(
      op: opcode),
      [value], builder.kind(value))
  of 2:
    let
      kind = if single: UInt32Type else: UInt64Type
      bits = builder.convert(value, kind)
      mask = builder.constant(
        if single: 0x7fffffff'u64 else: 0x7fffffffffffffff'u64, kind)
    value = builder.convert(builder.binary(AndOp, bits, mask),
      if single: Float32Type else: Float64Type)
  else:
    error("Invalid IR floating unary operation")
  builder.writeFloat(destination, value)

proc floatConvert*(builder: var IrBuilder, destination, source: int,
    single: bool) =
  ## Represents a binary32 or binary64 rounding conversion explicitly.
  let value = builder.convert(builder.floating(source, not single),
    if single: Float32Type else: Float64Type, FloatWidthConversion)
  builder.writeFloat(destination, value)

proc integerToFloat*(builder: var IrBuilder, destination: int,
    source: Register, single = false, unsigned = false) =
  ## Retains signedness and target precision in numeric conversion.
  let
    value = builder.convert(builder.integer(source),
      if unsigned: UInt64Type else: Int64Type)
    converted = builder.convert(value,
      if single: Float32Type else: Float64Type, IntegerFloatConversion)
  builder.writeFloat(destination, converted)

proc floatToInteger*(builder: var IrBuilder, destination: Register,
    source: int, single = false) =
  ## Truncates a previously guarded floating value to a signed word.
  builder.write(int(destination), builder.convert(
    builder.floating(source, single), Int64Type, FloatIntegerConversion))

proc bitsToFloat*(builder: var IrBuilder, destination: int,
    source: Register) =
  ## Reinterprets scalar bits without a numeric conversion.
  builder.writeFloat(destination,
    builder.convert(builder.integer(source), Float64Type))

proc compareRegister*(builder: var IrBuilder, width: Width,
    left, right: Register) =
  ## Retains comparison operands until a boolean condition is requested.
  builder.comparisonLeft = builder.integer(left, width)
  builder.comparisonRight = builder.integer(right, width)
  builder.floatingComparison = false

proc compareImmediate*(builder: var IrBuilder, width: Width,
    source: Register, value: int) =
  ## Compares a typed integer against a literal.
  builder.comparisonLeft = builder.integer(source, width)
  builder.comparisonRight = builder.constant(cast[uint64](value),
    builder.kind(builder.comparisonLeft))
  builder.floatingComparison = false

proc compareFloat*(builder: var IrBuilder, left, right: int,
    single = false) =
  ## Retains floating comparison operands including unordered values.
  builder.comparisonLeft = builder.floating(left, single)
  builder.comparisonRight = builder.floating(right, single)
  builder.floatingComparison = true

proc compareFloatMagnitude*(builder: var IrBuilder, source: int,
    bits: uint64, single = false) =
  ## Compares unsigned floating magnitude bits against a positive bound.
  let
    kind = if single: UInt32Type else: UInt64Type
    value = builder.convert(builder.floating(source, single), kind)
    mask = builder.constant(
      if single: 0x7fffffff'u64 else: 0x7fffffffffffffff'u64, kind)
  builder.comparisonLeft = builder.binary(AndOp, value, mask)
  builder.comparisonRight = builder.constant(bits, kind)
  builder.floatingComparison = false

proc compareFloatZero*(builder: var IrBuilder, source: int, single = false) =
  ## Compares floating values against positive zero at their declared precision.
  builder.comparisonLeft = builder.floating(source, single)
  builder.comparisonRight = builder.constant(0,
    if single: Float32Type else: Float64Type)
  builder.floatingComparison = true

proc comparison(builder: var IrBuilder, condition: Condition): ValueId =
  ## Converts frontend condition state to explicit portable boolean values.
  if condition == AlwaysCondition:
    return builder.constant(1, BoolType)
  var
    a = builder.comparisonLeft
    b = builder.comparisonRight
  proc cmp(builder: var IrBuilder, op: IrComparison,
      a, b: ValueId): ValueId =
    ## Defines one boolean comparison with explicit operand types.
    builder.emit(IrInstruction(op: CompareOp, comparison: op), [a, b], BoolType)
  proc invert(builder: var IrBuilder, value: ValueId): ValueId =
    ## Inverts a normalized boolean without integer flag state.
    builder.binary(XorOp, value, builder.constant(1, BoolType))
  if builder.floatingComparison:
    let ordered = builder.binary(AndOp,
      builder.cmp(EqualComparison, a, a),
      builder.cmp(EqualComparison, b, b))
    case condition
    of OverflowCondition: return builder.invert(ordered)
    of NoOverflowCondition: return ordered
    of CarrySetCondition, PositiveCondition:
      return builder.invert(builder.cmp(LessComparison, a, b))
    of UnsignedGreaterCondition:
      return builder.invert(builder.cmp(LessEqualComparison, a, b))
    of LessCondition:
      return builder.invert(builder.cmp(GreaterEqualComparison, a, b))
    of LessEqualCondition:
      return builder.invert(builder.cmp(GreaterComparison, a, b))
    else: discard
  elif condition in {LessCondition, LessEqualCondition, GreaterCondition,
      GreaterEqualCondition, NegativeCondition, PositiveCondition}:
    let kind = if builder.kind(a) == UInt32Type: Int32Type else: Int64Type
    a = builder.convert(a, kind)
    b = builder.convert(b, kind)
  let op = case condition
    of EqualCondition: EqualComparison
    of NotEqualCondition: NotEqualComparison
    of CarryClearCondition, NegativeCondition, LessCondition: LessComparison
    of CarrySetCondition, PositiveCondition, GreaterEqualCondition:
      GreaterEqualComparison
    of UnsignedGreaterCondition, GreaterCondition: GreaterComparison
    of UnsignedLessEqualCondition, LessEqualCondition: LessEqualComparison
    else:
      raise newException(BackendError, "Unsupported IR comparison condition")
  builder.cmp(op, a, b)

proc setOnCondition*(builder: var IrBuilder, width: Width,
    destination: Register, condition: Condition) =
  ## Materializes a boolean as zero or one in a virtual temporary.
  builder.write(int(destination), builder.comparison(condition))

proc branchValue(builder: var IrBuilder, value: ValueId, label: Label) =
  ## Emits both successors explicitly and starts the fallthrough block.
  let
    yes = builder.target(label)
    no = builder.newBlock()
  builder.flush()
  let first = builder.edge(yes)
  discard builder.edge(no)
  builder.module.functions[builder.function].blocks[builder.current].
    terminator = IrTerminator(kind: BranchTerminator,
      arguments: builder.parameters([value]),
      edges: Span(first: first, count: 2))
  builder.enter(no)

proc branchIf*(builder: var IrBuilder, condition: Condition, label: Label) =
  ## Branches on an explicit SSA boolean instead of machine flags.
  builder.branchValue(builder.comparison(condition), label)

proc branchIfZero*(builder: var IrBuilder, width: Width,
    source: Register, label: Label) =
  ## Compares against zero without changing the retained comparison operands.
  let
    a = builder.integer(source, width)
    value = builder.emit(IrInstruction(op: CompareOp,
      comparison: EqualComparison),
      [a, builder.constant(0, builder.kind(a))], BoolType)
  builder.branchValue(value, label)

proc branchIfNotZero*(builder: var IrBuilder, width: Width,
    source: Register, label: Label) =
  ## Branches on a nonzero typed scalar.
  let
    a = builder.integer(source, width)
    value = builder.emit(IrInstruction(op: CompareOp,
      comparison: NotEqualComparison),
      [a, builder.constant(0, builder.kind(a))], BoolType)
  builder.branchValue(value, label)

proc callHost*(builder: var IrBuilder, index: int,
    borrowedParameter = -1, borrowedBytes = -1) =
  ## Emits a typed host call with a stable runtime binding index.
  var target = index
  if borrowedParameter >= 0:
    var host = builder.module.hosts[index]
    doAssert borrowedParameter < host.signature.parameters.len
    doAssert host.signature.parameters[borrowedParameter] == AddressType
    doAssert borrowedBytes >= 0
    host.borrowedBytes = newSeq[int32](host.signature.parameters.len)
    for bytes in host.borrowedBytes.mitems:
      bytes = -1
    host.borrowedBytes[borrowedParameter] = int32(borrowedBytes)
    host.name.add(".borrow" & $borrowedParameter & "_" & $borrowedBytes)
    target = -1
    for i, existing in builder.module.hosts:
      if existing == host:
        target = i
        break
    if target < 0:
      target = builder.module.hosts.len
      builder.module.hosts.add(host)
  let signature = builder.module.hosts[target].signature
  var
    values: seq[ValueId]
    integer, floating = 0
  for kind in signature.parameters:
    if kind in {Float32Type, Float64Type}:
      values.add(builder.floating(floating, kind == Float32Type))
      inc floating
    else:
      values.add(builder.convert(builder.integer(Register(integer)), kind))
      inc integer
  let value = builder.emit(IrInstruction(op: HostCallOp,
    target: int32(target), results: Span(count: int32(signature.returns.len))),
    values, if signature.returns.len == 0: UInt64Type
      else: signature.returns[0])
  if signature.returns.len > 0:
    if signature.returns[0] in {Float32Type, Float64Type}:
      builder.writeFloat(0, value)
    else:
      builder.write(0, value)

proc callArguments(builder: var IrBuilder): seq[ValueId] =
  ## Passes runtime context, argument storage, return storage, and captures.
  @[builder.context, builder.base(X0), builder.base(X1), builder.base(X2)]

proc branchLink*(builder: var IrBuilder, label: Label) =
  ## Emits a direct IR call to a complete lowered procedure.
  let index = builder.targets[int(label)].function
  if index < 0:
    error("IR call has no declared procedure")
  var values = builder.callArguments()
  let signature = builder.module.functions[index].signature
  for i, storage in signature.parameterStorage:
    let value = int32(values[i])
    builder.module.functions[builder.function].values[value].storage = storage
  discard builder.emit(IrInstruction(op: CallOp, target: int32(index)), values)

proc callRegister*(builder: var IrBuilder, source: Register) =
  ## Emits an indirect IR call using the declared native procedure signature.
  var values = @[builder.base(source)]
  values.add(builder.callArguments())
  discard builder.emit(IrInstruction(op: IndirectCallOp, target: 0), values)

proc declareFunctions*(builder: var IrBuilder, names: openArray[string],
    labels: openArray[Label]) =
  ## Declares every call target before lowering any procedure body.
  let signature = IrSignature(parameters:
    @[AddressType, AddressType, AddressType, AddressType])
  builder.module.signatures = @[signature]
  for i, name in names:
    builder.module.functions.add(IrFunction(name: name,
      failureMode: NoFailCall, signature: signature))
    builder.targets[int(labels[i])] = Target(function: i, blockId: 0)

proc globalAddress*(builder: var IrBuilder, destination: Register,
    offset: int) =
  ## Names concrete global storage and preserves interior byte offsets in IR.
  for i, global in builder.module.globals:
    if offset >= global.offset and offset < global.offset + global.bytes.count:
      let value = builder.emit(IrInstruction(op: GlobalAddressOp,
        target: int32(i)), [], AddressType)
      builder.module.functions[builder.function].values[int32(value)].storage =
        global.storage
      builder.write(int(destination), builder.addressOffset(value,
        offset - int(global.offset)))
      return
  # Empty values can point at the end of the packed global allocation.
  builder.write(int(destination), builder.addressOffset(
    builder.base(X20), offset))

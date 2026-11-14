import std/strutils

type
  ValueId* = distinct int32
  BlockId* = distinct int32
  LocationId* = distinct int32

  Span* = object
    first*: int32
    count*: int32

  IrType* = enum
    BoolType, CharType,
    Int8Type, UInt8Type, Int16Type, UInt16Type,
    Int32Type, UInt32Type, Int64Type, UInt64Type,
    Float32Type, Float64Type, AddressType, Float32x2Type

  IrOpcode* = enum
    ConstantOp, AddOp, SubtractOp, MultiplyOp, DivideOp, RemainderOp,
    NegateOp, AndOp, OrOp, XorOp, NotOp,
    ShiftLeftOp, ShiftRightOp, ArithmeticRightOp,
    CompareOp, ConvertOp, SqrtOp, FloorOp, RoundOp,
    SlotAddressOp, GlobalAddressOp, OffsetAddressOp,
    LoadOp, StoreOp, MoveBytesOp, ClearBytesOp,
    CallOp, HostCallOp, FieldAddressOp,
    IndirectCallOp, FrameSizeOp, SelectOp,
    PackOp, ExtractOp, VectorAddOp, VectorSubtractOp, VectorMultiplyOp,
    VectorDivideOp, VectorSumOp

  IrStorageKind* = enum
    ScalarStorage, PointerStorage, ArrayStorage, StructStorage, OpaqueStorage

  IrFieldRole* = enum
    SourceField, RuntimeField, ReferenceField, RefcountField,
    DiscriminatorField, ReservedField, PaddingField

  IrStorage* = object
    name*: string
    kind*: IrStorageKind
    byteCount*: int32
    alignment*: int32
    scalar*: IrType
    element*: int32
    length*: int32
    fields*: Span

  IrField* = object
    name*: string
    storage*: int32
    offset*: int32
    role*: IrFieldRole

  IrPassing* = enum
    DirectPassing, ValuePassing, MutablePassing

  IrComparison* = enum
    EqualComparison, NotEqualComparison,
    LessComparison, LessEqualComparison,
    GreaterComparison, GreaterEqualComparison

  IrConversion* = enum
    TruncateConversion, SignExtendConversion, ZeroExtendConversion,
    IntegerFloatConversion, FloatIntegerConversion,
    FloatWidthConversion, BitcastConversion

  IrTerminatorKind* = enum
    UnsetTerminator, JumpTerminator, BranchTerminator, ReturnTerminator,
    InvokeTerminator, InvokeHostTerminator, FailTerminator,
    PropagateTerminator, UnreachableTerminator

  IrFailureMode* = enum
    MayFailCall, NoFailCall

  IrFailure* = enum
    DivisionFailure, ModuloFailure, BoundsFailure, ShiftFailure,
    ConversionFailure, DepthFailure, StackFailure, WorkFailure,
    BorrowFailure

  IrValue* = object
    valueType*: IrType
    storage*: int32
    ## Uses zero for untyped pointers, otherwise a one-based storage type ID.

  IrSource* = object
    file*: int32
    line*: int32
    column*: int32
    node*: int32

  IrInstruction* = object
    op*: IrOpcode
    results*: Span
    arguments*: Span
    bits*: uint64
    offset*: int64
    alignment*: int32
    byteCount*: int32
    target*: int32
    comparison*: IrComparison
    conversion*: IrConversion
    location*: LocationId
    volatile*: bool

  IrEdge* = object
    target*: BlockId
    arguments*: Span

  IrTerminator* = object
    kind*: IrTerminatorKind
    arguments*: Span
    results*: Span
    edges*: Span
    callee*: int32
    failure*: IrFailure
    location*: LocationId

  IrBlock* = object
    parameters*: Span
    instructions*: Span
    terminator*: IrTerminator

  IrSlot* = object
    byteCount*: int32
    alignment*: int32
    storage*: int32

  IrSignature* = object
    parameters*: seq[IrType]
    returns*: seq[IrType]
    parameterStorage*: seq[int32]
    returnStorage*: seq[int32]
    passing*: seq[IrPassing]

  IrFunction* = object
    name*: string
    failureMode*: IrFailureMode
    directOnly*: bool
    ## Identifies private source procedures with no first-class function value.
    signature*: IrSignature
    values*: seq[IrValue]
    blocks*: seq[IrBlock]
    instructions*: seq[IrInstruction]
    operands*: seq[ValueId]
    edges*: seq[IrEdge]
    slots*: seq[IrSlot]

  IrEffects* = object
    known*: bool
    readsMemory*, writesMemory*, allocates*, mayFail*: bool

  IrHost* = object
    name*: string
    failureMode*: IrFailureMode
    binding*: int32
    signature*: IrSignature
    effects*: IrEffects
    borrowedBytes*: seq[int32]
    ## Bounds nonretained pointer arguments; absent or negative means unknown.

  IrGlobal* = object
    name*: string
    bytes*: Span
    alignment*: int32
    readonly*: bool
    storage*: int32
    offset*: int64

  IrModule* = object
    pointerBytes*: int32
    functions*: seq[IrFunction]
    hosts*: seq[IrHost]
    signatures*: seq[IrSignature]
    globals*: seq[IrGlobal]
    data*: seq[byte]
    files*: seq[string]
    locations*: seq[IrSource]
    storageTypes*: seq[IrStorage]
    fields*: seq[IrField]

const
  NoValue* = ValueId(-1)
  NoLocation* = LocationId(-1)
  TypeNames: array[IrType, string] = [
    "bool", "char", "int8", "uint8", "int16", "uint16",
    "int32", "uint32", "int64", "uint64", "float32", "float64", "ptr",
    "float32x2"
  ]
  OpcodeNames: array[IrOpcode, string] = [
    "const", "add", "sub", "mul", "div", "rem", "neg", "and", "or", "xor",
    "not", "shl", "shr", "ashr", "cmp", "convert", "sqrt", "floor", "round",
    "saddr",
    "gaddr", "offset", "load", "store", "memmove", "memzero",
    "call", "hcall", "faddr", "icall", "framesize", "select",
    "pack", "extract", "vadd", "vsub", "vmul", "vdiv", "vsum"
  ]
  ComparisonNames: array[IrComparison, string] = [
    "eq", "ne", "lt", "le", "gt", "ge"
  ]
  ConversionNames: array[IrConversion, string] = [
    "trunc", "sext", "zext", "itof", "ftoi", "fcast", "bitcast"
  ]

proc typeName*(kind: IrType): string =
  ## Spells an explicit scalar type in the proposed text format.
  TypeNames[kind]

proc indices*(span: Span): HSlice[int, int] =
  ## Iterates a contiguous pool range, including an empty range.
  int(span.first) ..< int(span.first + span.count)

proc reference(value: ValueId): string =
  ## Prints a function-local virtual register identifier.
  "r" & $int32(value)

proc symbolText(name: string): string =
  ## Quotes symbol names so they cannot be confused with IR syntax.
  "`" & name.replace("\\", "\\\\").replace("`", "\\`").replace(
    "\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") & "`"

proc storageText*(module: IrModule, storage: int32): string =
  ## Spells a concrete storage reference without expanding recursive pointers.
  if storage == 0:
    return "void"
  let data = module.storageTypes[storage - 1]
  case data.kind
  of ScalarStorage:
    result = typeName(data.scalar)
  of PointerStorage:
    result = "ptr"
    if data.element > 0:
      result.add("[" & module.storageText(data.element) & "]")
  of ArrayStorage:
    result = "array[" & $data.length & ", " &
      module.storageText(data.element) & "]"
  of StructStorage, OpaqueStorage:
    result = symbolText(data.name)

proc valueTypeText(module: IrModule, value: IrValue): string =
  ## Includes pointee storage in typed address register declarations.
  result = typeName(value.valueType)
  if value.valueType == AddressType and value.storage > 0:
    result.add("[" & module.storageText(value.storage) & "]")

proc valuesText(module: IrModule, function: IrFunction, span: Span,
    typed = false, parameters = false): string =
  ## Prints a contiguous group of definitions from the value table.
  for i in span.indices:
    if result.len > 0:
      result.add(", ")
    result.add(reference(ValueId(i)))
    if typed:
      result.add(": " & module.valueTypeText(function.values[i]))
      if parameters and function.values[i].storage > 0:
        let index = i - int(span.first)
        let passing = if function.signature.passing.len == 0:
            DirectPassing
          else: function.signature.passing[index]
        case passing
        of DirectPassing:
          discard
        of ValuePassing:
          result.add(" byval")
        of MutablePassing:
          result.add(" mutable")

proc argumentsText(function: IrFunction, span: Span): string =
  ## Prints operand references from the shared operand pool.
  for i in span.indices:
    if result.len > 0:
      result.add(", ")
    result.add(reference(function.operands[i]))

proc typesText(module: IrModule, types: openArray[IrType],
    storage: seq[int32]): string =
  ## Prints concrete return types with parentheses for multiple results.
  if types.len == 0:
    return "void"
  for i, kind in types:
    if result.len > 0:
      result.add(", ")
    result.add(module.valueTypeText(IrValue(valueType: kind,
      storage: if storage.len > 0: storage[i] else: 0)))
  if types.len > 1:
    result = "(" & result & ")"

proc edgeText(function: IrFunction, index: int): string =
  ## Prints an edge and the values assigned to its destination parameters.
  let edge = function.edges[index]
  "b" & $int32(edge.target) & "(" &
    function.argumentsText(edge.arguments) & ")"

proc constantText(kind: IrType, bits: uint64): string =
  ## Keeps floating constants bit-exact and integral constants readable.
  case kind
  of Float32Type:
    "bits(0x" & bits.toHex(8).toLowerAscii() & ")"
  of Float64Type, Float32x2Type:
    "bits(0x" & bits.toHex(16).toLowerAscii() & ")"
  of BoolType:
    if bits == 0: "false" else: "true"
  of Int8Type: $cast[int8](bits)
  of Int16Type: $cast[int16](bits)
  of Int32Type: $cast[int32](bits)
  of Int64Type: $cast[int64](bits)
  else: $bits

proc dumpFunction*(module: IrModule, index: int): string =
  ## Renders the proposal's enum records without parsing or compiling text.
  let function = module.functions[index]
  result = "def " & symbolText(function.name) & "(" &
    module.valuesText(function, function.blocks[0].parameters, true, true) &
    ") -> " &
    module.typesText(function.signature.returns,
      function.signature.returnStorage) & ":\n"
  for i, slot in function.slots:
    result.add("  slot slot" & $i & ": " & $slot.byteCount &
      " bytes, align " & $slot.alignment)
    if slot.storage > 0:
      result.add(", type " & module.storageText(slot.storage))
    result.add("\n")
  for blockIndex, data in function.blocks:
    result.add("  b" & $blockIndex)
    if blockIndex > 0 and data.parameters.count > 0:
      result.add("(" & module.valuesText(function, data.parameters, true) & ")")
    result.add(":\n")
    for i in data.instructions.indices:
      let instruction = function.instructions[i]
      result.add("    ")
      if instruction.results.count > 0:
        result.add(module.valuesText(function, instruction.results, true) & " = ")
      case instruction.op
      of CompareOp:
        result.add(ComparisonNames[instruction.comparison])
      of ConvertOp:
        result.add(ConversionNames[instruction.conversion])
      else:
        result.add(OpcodeNames[instruction.op])
      case instruction.op
      of ConstantOp:
        result.add(" " & constantText(function.values[
          instruction.results.first].valueType, instruction.bits))
      of SlotAddressOp:
        result.add(" slot" & $instruction.target)
      of GlobalAddressOp:
        result.add(" " & symbolText(module.globals[instruction.target].name))
      of CallOp, HostCallOp:
        let name = if instruction.op == CallOp:
            module.functions[instruction.target].name
          else: module.hosts[instruction.target].name
        result.add(" " & symbolText(name) & "(" &
          function.argumentsText(instruction.arguments) & ")")
      of IndirectCallOp:
        result.add(" " & function.argumentsText(instruction.arguments))
      of FieldAddressOp:
        let
          base = function.operands[instruction.arguments.first]
          storage = function.values[int32(base)].storage
          owner = module.storageTypes[storage - 1]
        result.add(" " & function.argumentsText(instruction.arguments) &
          ", " & symbolText(owner.name) & "." &
          symbolText(module.fields[instruction.target].name))
      else:
        if instruction.arguments.count > 0:
          result.add(" " & function.argumentsText(instruction.arguments))
      if instruction.op == ExtractOp:
        result.add(", " & $instruction.target)
      if instruction.op in {LoadOp, StoreOp, OffsetAddressOp}:
        result.add(", offset " & $instruction.offset)
      if instruction.op in {LoadOp, StoreOp}:
        result.add(", align " & $instruction.alignment)
        if instruction.volatile:
          result.add(", volatile")
      if instruction.op in {MoveBytesOp, ClearBytesOp}:
        result.add(", bytes " & $instruction.byteCount)
      result.add("\n")
    let terminator = data.terminator
    result.add("    ")
    case terminator.kind
    of UnsetTerminator:
      doAssert false, "Design example contains an unterminated block"
    of JumpTerminator:
      result.add("jump " & function.edgeText(terminator.edges.first))
    of BranchTerminator:
      result.add("branch " & function.argumentsText(terminator.arguments) &
        ", " & function.edgeText(terminator.edges.first) &
        ", " & function.edgeText(terminator.edges.first + 1))
    of ReturnTerminator:
      result.add("return")
      if terminator.arguments.count > 0:
        result.add(" " & function.argumentsText(terminator.arguments))
    of InvokeTerminator, InvokeHostTerminator:
      let name = if terminator.kind == InvokeTerminator:
          module.functions[terminator.callee].name
        else: module.hosts[terminator.callee].name
      result.add(if terminator.kind == InvokeTerminator:
        "invoke " else: "hinvoke ")
      result.add(symbolText(name) & "(" &
        function.argumentsText(terminator.arguments) & ") -> (" &
        module.valuesText(function, terminator.results, true) & ")\n      next " &
        function.edgeText(terminator.edges.first) & ", fail " &
        function.edgeText(terminator.edges.first + 1))
    of FailTerminator:
      result.add("fail " & $terminator.failure)
      if int32(terminator.location) >= 0:
        result.add(", loc " & $int32(terminator.location))
    of PropagateTerminator:
      result.add("propagate")
    of UnreachableTerminator:
      result.add("unreachable")
    result.add("\n")

proc dumpLayouts*(module: IrModule, names: openArray[string] = []): string =
  ## Prints every struct field, including explicit padding and runtime fields.
  for data in module.storageTypes:
    if names.len > 0 and data.name notin names:
      continue
    if data.kind == OpaqueStorage:
      result.add("opaque " & symbolText(data.name) & " size " &
        $data.byteCount & " align " & $data.alignment & "\n\n")
    elif data.kind == StructStorage:
      result.add("struct " & symbolText(data.name) & " size " &
        $data.byteCount & " align " & $data.alignment & ":\n")
      if data.fields.count == 0:
        result.add("  pass\n")
      for index in data.fields.indices:
        let
          field = module.fields[index]
          storage = module.storageTypes[field.storage - 1]
        result.add("  " & symbolText(field.name) & ": " &
          module.storageText(field.storage) & " at " & $field.offset &
          " size " & $storage.byteCount & " align " & $storage.alignment)
        if field.role != SourceField:
          result.add(" " & (case field.role
            of RuntimeField: "runtime"
            of ReferenceField: "reference"
            of RefcountField: "refcount"
            of DiscriminatorField: "discriminator"
            of ReservedField: "reserved"
            of PaddingField: "padding"
            else: ""))
        result.add("\n")
      result.add("\n")

proc dumpDeclarations*(module: IrModule): string =
  ## Prints concrete layouts, globals, and typed runtime bindings.
  result = module.dumpLayouts()
  for global in module.globals:
    result.add("global " & symbolText(global.name) & ": " &
      module.storageText(global.storage) & " at " & $global.offset &
      " size " & $global.bytes.count & " align " & $global.alignment & "\n")
  for host in module.hosts:
    result.add("host " & symbolText(host.name) & "(")
    for i, kind in host.signature.parameters:
      if i > 0:
        result.add(", ")
      result.add("r" & $i & ": " & typeName(kind))
      if host.borrowedBytes.len > 0 and host.borrowedBytes[i] >= 0:
        result.add(" borrow[" & $host.borrowedBytes[i] & "]")
    result.add(") -> " & module.typesText(host.signature.returns,
      host.signature.returnStorage) & " binding " & $host.binding & "\n")
  if module.globals.len > 0 or module.hosts.len > 0:
    result.add("\n")

proc dumpModule*(module: IrModule): string =
  ## Prints complete data declarations followed by every function body.
  result = module.dumpDeclarations()
  for i in 0 ..< module.functions.len:
    result.add(module.dumpFunction(i) & "\n")

import std/math, irs, floatroundings

type
  ConstantState = enum
    UnknownValue, KnownValue, RuntimeValue

  ConstantFact = object
    state: ConstantState
    bits: uint64

  IrConstants* = object
    known*: seq[bool]
    bits*: seq[uint64]

proc width(kind: IrType): int {.raises: [].} =
  ## Returns the concrete scalar bit width used by integer folding.
  case kind
  of BoolType, CharType, Int8Type, UInt8Type: 8
  of Int16Type, UInt16Type: 16
  of Int32Type, UInt32Type, Float32Type: 32
  else: 64

proc canonical(bits: uint64, kind: IrType): uint64 {.raises: [].} =
  ## Preserves typed bits and sign extends signed narrow integer payloads.
  if kind == BoolType:
    return if (bits and 1) == 0: 0'u64 else: uint64.high
  let size = width(kind)
  if size == 64:
    return bits
  let mask = (1'u64 shl size) - 1
  result = bits and mask
  if kind in {Int8Type, Int16Type, Int32Type} and
      (result and (1'u64 shl (size - 1))) != 0:
    result = result or not mask

proc decimal(bits: uint64, kind: IrType): float64 {.raises: [].} =
  ## Decodes an exact floating constant without parsing decimal text.
  if kind == Float32Type: cast[float32](uint32(bits)).float64
  else: cast[float64](bits)

proc encode(value: float64, kind: IrType): uint64 {.raises: [].} =
  ## Encodes each floating result at its declared precision.
  if kind == Float32Type: uint64(cast[uint32](float32(value)))
  else: cast[uint64](value)

proc evaluate(function: IrFunction, instruction: IrInstruction,
    facts: seq[ConstantFact], bits: var uint64, conversions: bool): bool =
  ## Folds explicit scalar operations while declining invalid runtime work.
  let kind = function.values[instruction.results.first].valueType
  if instruction.op == ConstantOp and kind != AddressType:
    bits = canonical(instruction.bits, kind)
    return true
  if instruction.arguments.count == 0:
    return false
  let
    first = instruction.arguments.first
    aId = int32(function.operands[first])
    source = function.values[aId].valueType
    a = facts[aId].bits
    b = if instruction.arguments.count > 1:
        facts[int32(function.operands[first + 1])].bits
      else: 0'u64
    unsigned = source in {BoolType, CharType, UInt8Type, UInt16Type,
      UInt32Type, UInt64Type}
    floating = source in {Float32Type, Float64Type}
  var value: uint64
  if instruction.op == SelectOp:
    let chosen = first + (if a != 0: 1 else: 2)
    bits = facts[int32(function.operands[chosen])].bits
    return true
  if instruction.op == CompareOp:
    var equal, less, greater: bool
    if floating:
      let
        x = decimal(a, source)
        y = decimal(b, source)
      equal = x == y
      less = x < y
      greater = x > y
    elif unsigned:
      equal = a == b
      less = a < b
      greater = a > b
    else:
      equal = a == b
      less = cast[int64](a) < cast[int64](b)
      greater = cast[int64](a) > cast[int64](b)
    let answer = case instruction.comparison
      of EqualComparison: equal
      of NotEqualComparison: not equal
      of LessComparison: less
      of LessEqualComparison: less or equal
      of GreaterComparison: greater
      of GreaterEqualComparison: greater or equal
    bits = if answer: uint64.high else: 0
    return true
  if instruction.op == ConvertOp:
    if conversions and source != AddressType and kind != AddressType:
      let
        integers = source notin {Float32Type, Float64Type} and
          kind notin {Float32Type, Float64Type}
        representation = case instruction.conversion
        of BitcastConversion:
          width(source) == width(kind)
        of TruncateConversion:
          integers and width(kind) <= width(source)
        of SignExtendConversion:
          integers and source in {Int8Type, Int16Type, Int32Type, Int64Type} and
            width(kind) >= width(source)
        of ZeroExtendConversion:
          integers and unsigned and width(kind) >= width(source)
        else:
          false
      if representation:
        # Boolean facts use all bits, while typed registers carry zero or one.
        let value = if source == BoolType or kind == BoolType: a and 1 else: a
        bits = canonical(value, kind)
        return true
    if instruction.conversion == IntegerFloatConversion and
        source notin {BoolType, AddressType, Float32Type, Float64Type}:
      if kind == Float32Type:
        let number = if unsigned: float32(a) else: float32(cast[int64](a))
        bits = uint64(cast[uint32](number))
      else:
        bits = encode(if unsigned: float64(a) else: float64(cast[int64](a)), kind)
      return true
    if instruction.conversion == FloatWidthConversion and floating:
      let number = decimal(a, source)
      if number.classify notin {fcNan, fcInf, fcNegInf}:
        bits = encode(number, kind)
        return decimal(bits, kind).classify notin {fcNan, fcInf, fcNegInf}
    return false
  if floating:
    let
      x = decimal(a, source)
      y = decimal(b, source)
    if x.classify in {fcNan, fcInf, fcNegInf} or
        y.classify in {fcNan, fcInf, fcNegInf}:
      return false
    if instruction.op == DivideOp and y == 0:
      return false
    if instruction.op == SqrtOp and x < 0:
      return false
    var number: float64
    if kind == Float32Type:
      let
        left = float32(x)
        right = float32(y)
      number = (case instruction.op
        of AddOp: left + right
        of SubtractOp: left - right
        of MultiplyOp: left * right
        of DivideOp: left / right
        of NegateOp: -left
        of SqrtOp: sqrt(left)
        of FloorOp: floor(left)
        of RoundOp: roundSingle(left)
        else: return false).float64
    else:
      number = case instruction.op
        of AddOp: x + y
        of SubtractOp: x - y
        of MultiplyOp: x * y
        of DivideOp: x / y
        of NegateOp: -x
        of SqrtOp: sqrt(x)
        else: return false
    if number.classify in {fcNan, fcInf, fcNegInf}:
      return false
    bits = encode(number, kind)
    return true
  if source == AddressType:
    return false
  case instruction.op
  of AddOp: value = a + b
  of SubtractOp: value = a - b
  of MultiplyOp: value = a * b
  of NegateOp: value = 0'u64 - a
  of AndOp: value = a and b
  of OrOp: value = a or b
  of XorOp: value = a xor b
  of NotOp:
    value = if kind == BoolType:
        (if a == 0: uint64.high else: 0'u64)
      else: not a
  of ShiftLeftOp, ShiftRightOp, ArithmeticRightOp:
    let size = width(source)
    if b >= uint64(size):
      return false
    let mask = if size == 64: uint64.high else: (1'u64 shl size) - 1
    case instruction.op
    of ShiftLeftOp: value = a shl int(b)
    of ShiftRightOp: value = (a and mask) shr int(b)
    else:
      value = (a and mask) shr int(b)
      if cast[int64](a) < 0 and b != 0:
        value = value or (mask xor (mask shr int(b)))
  of DivideOp, RemainderOp:
    if b == 0:
      return false
    if unsigned:
      value = if instruction.op == DivideOp: a div b else: a mod b
    elif cast[int64](a) == int64.low and cast[int64](b) == -1:
      value = if instruction.op == DivideOp: a else: 0'u64
    else:
      value = cast[uint64](if instruction.op == DivideOp:
          cast[int64](a) div cast[int64](b)
        else: cast[int64](a) mod cast[int64](b))
  else:
    return false
  bits = canonical(value, kind)
  true

proc constantValues*(function: IrFunction, conversions = false): IrConstants =
  ## Propagates a monotone lattice through executable edges to a fixed point.
  var
    facts = newSeq[ConstantFact](function.values.len)
    reached = newSeq[bool](function.blocks.len)
    edges = newSeq[bool](function.edges.len)
    changed = true
  reached[0] = true
  for value in function.blocks[0].parameters.indices:
    facts[value].state = RuntimeValue
  proc merge(value: int, fact: ConstantFact) =
    ## Adds information without allowing a runtime value to become constant.
    let old = facts[value]
    if old.state == RuntimeValue or fact.state == UnknownValue:
      return
    if old.state == UnknownValue:
      facts[value] = fact
      changed = true
    elif fact.state == RuntimeValue or old.bits != fact.bits:
      facts[value].state = RuntimeValue
      changed = true
  while changed:
    changed = false
    for owner, data in function.blocks:
      if not reached[owner]:
        continue
      for i in data.instructions.indices:
        let instruction = function.instructions[i]
        var
          fact = ConstantFact(state: KnownValue)
          ready = true
        for j in instruction.arguments.indices:
          let input = facts[int32(function.operands[j])]
          if input.state == RuntimeValue:
            fact.state = RuntimeValue
          elif input.state == UnknownValue:
            ready = false
        if fact.state != RuntimeValue:
          if not ready:
            fact.state = UnknownValue
          elif instruction.results.count != 1 or
              not evaluate(function, instruction, facts, fact.bits, conversions):
            fact.state = RuntimeValue
        for value in instruction.results.indices:
          merge(value, fact)
      for value in data.terminator.results.indices:
        merge(value, ConstantFact(state: RuntimeValue))
      let terminator = data.terminator
      for i in terminator.edges.indices:
        var execute = true
        if terminator.kind == BranchTerminator:
          let condition = facts[int32(function.operands[terminator.arguments.first])]
          execute = condition.state == RuntimeValue or
            (condition.state == KnownValue and
              (condition.bits != 0) == (i == terminator.edges.first))
        if execute and not edges[i]:
          edges[i] = true
          changed = true
        if edges[i]:
          let
            edge = function.edges[i]
            target = int(int32(edge.target))
          if not reached[target]:
            reached[target] = true
            changed = true
          for j in 0 ..< int(edge.arguments.count):
            merge(int(function.blocks[target].parameters.first) + j,
              facts[int32(function.operands[int(edge.arguments.first) + j])])
  result.known = newSeq[bool](facts.len)
  result.bits = newSeq[uint64](facts.len)
  for value, fact in facts:
    result.known[value] = fact.state == KnownValue
    result.bits[value] = fact.bits

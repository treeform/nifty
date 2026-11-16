import irs

const
  Signed = {Int8Type, Int16Type, Int32Type, Int64Type}
  Integers = Signed + {UInt8Type, UInt16Type, UInt32Type, UInt64Type}

proc width(kind: IrType): int {.raises: [].} =
  ## Returns the declared width of supported integer operands.
  case kind
  of Int8Type, UInt8Type: 8
  of Int16Type, UInt16Type: 16
  of Int32Type, UInt32Type: 32
  else: 64

proc literal(function: IrFunction, definitions: seq[int], value: ValueId,
    bits: var uint64): bool {.raises: [].} =
  ## Reads literal divisors through exact integer signedness views.
  var current = int32(value)
  for step in 0 ..< function.values.len:
    let definition = definitions[current]
    if definition < 0:
      return false
    let item = function.instructions[definition]
    if item.op == ConstantOp:
      bits = item.bits
      return true
    if item.op != ConvertOp or item.conversion != BitcastConversion:
      return false
    let
      input = int32(function.operands[item.arguments.first])
      source = function.values[input].valueType
      target = function.values[current].valueType
    if source notin Integers or target notin Integers or
      width(source) != width(target):
        return false
    current = input

proc emit(function: var IrFunction, instructions: var seq[IrInstruction],
    op: IrOpcode, kind: IrType, inputs: openArray[ValueId],
    location: LocationId,
    bits = 0'u64, output = NoValue): ValueId {.raises: [].} =
  ## Appends one typed definition without changing existing SSA identities.
  result = output
  if int32(result) < 0:
    result = ValueId(function.values.len)
    function.values.add(IrValue(valueType: kind))
  instructions.add(IrInstruction(op: op, bits: bits, location: location,
    conversion: if op == ConvertOp: BitcastConversion else: TruncateConversion,
    results: Span(first: int32(result), count: 1),
    arguments: Span(first: int32(function.operands.len),
      count: int32(inputs.len))))
  function.operands.add(inputs)

proc reduceDivisions*(function: var IrFunction,
    fastMultiplyHigh = false) {.raises: [].} =
  ## Uses shifts for powers of two and exact reciprocals on capable targets.
  var candidates = false
  for item in function.instructions:
    if item.op in {DivideOp, RemainderOp} and
      function.values[item.results.first].valueType in Integers:
        candidates = true
        break
  if not candidates:
    return
  let old = function
  var
    definitions = newSeq[int](old.values.len)
    instructions: seq[IrInstruction]
  for definition in definitions.mitems:
    definition = -1
  for i, item in old.instructions:
    if item.results.count == 1:
      definitions[item.results.first] = i
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for index in data.instructions.indices:
      let item = old.instructions[index]
      var divisor: uint64
      if item.op notin {DivideOp, RemainderOp} or
        item.results.count != 1 or item.arguments.count != 2 or
        old.values[item.results.first].valueType notin Integers or
        not old.literal(definitions,
          old.operands[item.arguments.first + 1], divisor):
          instructions.add(item)
          continue
      let
        kind = old.values[item.results.first].valueType
        size = width(kind)
        mask = if size == 64: uint64.high else: (1'u64 shl size) - 1
        bits = divisor and mask
        negative = kind in Signed and
          (bits and (1'u64 shl (size - 1))) != 0
        magnitude = if negative: (0'u64 - bits) and mask else: bits
        input = old.operands[item.arguments.first]
        output = ValueId(item.results.first)
      if fastMultiplyHigh and kind == UInt64Type and bits > 1 and
          (bits and (bits - 1)) != 0:
        # floor(2^64/d) gives a quotient at most one too small. The residual
        # needs one unsigned correction; CSE can share the work for / and %.
        let
          reciprocal = function.emit(instructions, ConstantOp, kind, [],
            item.location, uint64.high div bits)
          divisorValue = function.emit(instructions, ConstantOp, kind, [],
            item.location, bits)
          estimate = function.emit(instructions, MultiplyHighOp, kind,
            [input, reciprocal], item.location)
          product = function.emit(instructions, MultiplyOp, kind,
            [estimate, divisorValue], item.location)
          residual = function.emit(instructions, SubtractOp, kind,
            [input, product], item.location)
          correction = function.emit(instructions, CompareOp, BoolType,
            [residual, divisorValue], item.location)
        instructions[^1].comparison = GreaterEqualComparison
        if item.op == RemainderOp:
          let adjusted = function.emit(instructions, SubtractOp, kind,
            [residual, divisorValue], item.location)
          discard function.emit(instructions, SelectOp, kind,
            [correction, adjusted, residual], item.location, output = output)
        else:
          let increment = function.emit(instructions, ConvertOp, kind,
            [correction], item.location)
          instructions[^1].conversion = ZeroExtendConversion
          discard function.emit(instructions, AddOp, kind,
            [estimate, increment], item.location, output = output)
        continue
      if magnitude == 0 or (magnitude and (magnitude - 1)) != 0:
        instructions.add(item)
        continue
      if magnitude == 1:
        if item.op == RemainderOp:
          discard function.emit(
            instructions,
            ConstantOp,
            kind,
            [],
            item.location,
            output = output
          )
        elif negative:
          discard function.emit(
            instructions,
            NegateOp,
            kind,
            [input],
            item.location,
            output = output
          )
        else:
          discard function.emit(
            instructions,
            ConvertOp,
            kind,
            [input],
            item.location,
            output = output
          )
        continue
      var
        shift = 0
        remaining = magnitude
      while remaining > 1:
        remaining = remaining shr 1
        inc shift
      template constant(bits: uint64): ValueId =
        ## Defines a literal at the operation's original integer width.
        function.emit(instructions, ConstantOp, kind, [], item.location, bits)
      template operation(op: IrOpcode, a, b: ValueId): ValueId =
        ## Reuses already evaluated SSA operands for an intermediate result.
        function.emit(instructions, op, kind, [a, b], item.location)
      if kind notin Signed:
        let amount = constant(if item.op == DivideOp:
          uint64(shift) else: magnitude - 1)
        discard function.emit(
          instructions,
          if item.op == DivideOp: ShiftRightOp else: AndOp,
          kind,
          [input, amount],
          item.location,
          output = output
        )
        continue
      let
        signShift = constant(uint64(size - 1))
        sign = operation(ArithmeticRightOp, input, signShift)
        lowMask = constant(magnitude - 1)
        bias = operation(AndOp, sign, lowMask)
        rounded = operation(AddOp, input, bias)
      if item.op == RemainderOp:
        let low = operation(AndOp, rounded, lowMask)
        discard function.emit(
          instructions,
          SubtractOp,
          kind,
          [low, bias],
          item.location,
          output = output
        )
      else:
        let amount = constant(uint64(shift))
        if negative:
          let quotient = operation(ArithmeticRightOp, rounded, amount)
          discard function.emit(
            instructions,
            NegateOp,
            kind,
            [quotient],
            item.location,
            output = output
          )
        else:
          discard function.emit(
            instructions,
            ArithmeticRightOp,
            kind,
            [rounded, amount],
            item.location,
            output = output
          )
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)

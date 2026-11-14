import irs, irchecks

proc reduceRemainderTests*(function: var IrFunction): bool =
  ## Reduces power-of-two remainders observed exclusively through zero tests.
  var present = false
  for item in function.instructions:
    if item.op == RemainderOp:
      present = true
  if not present:
    return
  let old = function
  var
    zeroOnly = newSeq[bool](old.values.len)
    used = newSeq[bool](old.values.len)
    constants = newSeq[bool](old.values.len)
    bits = newSeq[uint64](old.values.len)
    copies: seq[tuple[input, output: int32]]
  for allowed in zeroOnly.mitems:
    allowed = true
  for item in old.instructions:
    if item.op == ConstantOp:
      constants[item.results.first] = true
      bits[item.results.first] = item.bits
  var constantChanged = true
  while constantChanged:
    constantChanged = false
    for item in old.instructions:
      if item.op != ConvertOp or item.conversion != BitcastConversion or
          item.arguments.count != 1 or item.results.count != 1:
        continue
      let
        input = int32(old.operands[item.arguments.first])
        output = item.results.first
        source = old.values[input].valueType
        target = old.values[output].valueType
      if constants[input] and not constants[output] and
          source in {Int8Type .. UInt64Type} and
          target in {Int8Type .. UInt64Type} and
          byteCount(source, 8) == byteCount(target, 8):
        constants[output] = true
        bits[output] = bits[input]
        constantChanged = true
  for item in old.instructions:
    let first = item.arguments.first
    if item.op == ConvertOp and item.conversion == BitcastConversion and
        item.arguments.count == 1 and item.results.count == 1:
      let
        input = int32(old.operands[first])
        output = item.results.first
        source = old.values[input].valueType
        target = old.values[output].valueType
      if source in {Int8Type .. UInt64Type} and
          target in {Int8Type .. UInt64Type} and
          byteCount(source, 8) == byteCount(target, 8):
        used[input] = true
        copies.add((input, output))
        continue
    for position in item.arguments.indices:
      let value = int32(old.operands[position])
      used[value] = true
      var allowed = false
      if item.op == CompareOp and item.arguments.count == 2 and
          item.comparison in {EqualComparison, NotEqualComparison}:
        let other = int32(old.operands[first + 1 - (int32(position) - first)])
        allowed = constants[other] and bits[other] == 0
      if not allowed:
        zeroOnly[value] = false
  for data in old.blocks:
    for position in data.terminator.arguments.indices:
      zeroOnly[int32(old.operands[position])] = false
    for edge in data.terminator.edges.indices:
      for position in old.edges[edge].arguments.indices:
        zeroOnly[int32(old.operands[position])] = false
  var changed = true
  while changed:
    changed = false
    for (input, output) in copies:
      if zeroOnly[input] and not zeroOnly[output]:
        zeroOnly[input] = false
        changed = true
  var instructions: seq[IrInstruction]
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for index in data.instructions.indices:
      var item = old.instructions[index]
      if item.op == RemainderOp and not item.volatile and
          item.results.count == 1 and item.arguments.count == 2 and
          zeroOnly[item.results.first] and used[item.results.first]:
        let
          kind = old.values[item.results.first].valueType
          divisor = int32(old.operands[item.arguments.first + 1])
        if kind in {Int8Type .. UInt64Type} and constants[divisor]:
          let
            width = byteCount(kind, 8) * 8
            mask = if width == 64: uint64.high else: (1'u64 shl width) - 1
            raw = bits[divisor] and mask
          var magnitude = raw
          if kind in {Int8Type, Int16Type, Int32Type, Int64Type} and
              (raw and (1'u64 shl (width - 1))) != 0:
            magnitude = (0'u64 - raw) and mask
          if magnitude != 0 and (magnitude and (magnitude - 1)) == 0:
            let value = ValueId(function.values.len)
            function.values.add(old.values[item.results.first])
            instructions.add(IrInstruction(op: ConstantOp, bits: magnitude - 1,
              results: Span(first: int32(value), count: 1)))
            let input = old.operands[item.arguments.first]
            item.op = AndOp
            item.arguments = Span(first: int32(function.operands.len), count: 2)
            function.operands.add(input)
            function.operands.add(value)
            result = true
      instructions.add(item)
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)

import std/tables, irs, irlifetimes

proc recreate(function: var IrFunction, definitions: seq[int]) =
  ## Splits selected definitions at block boundaries and observing calls.
  let old = function
  var
    rebuilt = old
    instructions: seq[IrInstruction]
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    var local = initTable[int32, ValueId]()
    proc operands(span: Span): Span =
      ## Reuses one recreated definition until the next call in this block.
      result = Span(first: int32(rebuilt.operands.len), count: span.count)
      for position in span.indices:
        let value = int32(old.operands[position])
        var replacement = ValueId(value)
        if definitions[value] >= 0:
          if not local.hasKey(value):
            replacement = ValueId(rebuilt.values.len)
            rebuilt.values.add(old.values[value])
            var definition = old.instructions[definitions[value]]
            definition.results = Span(first: int32(replacement), count: 1)
            instructions.add(definition)
            local[value] = replacement
          replacement = local.getOrDefault(value)
        rebuilt.operands.add(replacement)
    for index in data.instructions.indices:
      var item = old.instructions[index]
      item.arguments = operands(item.arguments)
      instructions.add(item)
      if item.op in {CallOp, HostCallOp, IndirectCallOp}:
        local.clear()
    rebuilt.blocks[owner].terminator.arguments =
      operands(data.terminator.arguments)
    rebuilt.blocks[owner].terminator.edges.first = int32(rebuilt.edges.len)
    for index in data.terminator.edges.indices:
      var edge = old.edges[index]
      edge.arguments = operands(edge.arguments)
      rebuilt.edges.add(edge)
    rebuilt.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  rebuilt.instructions = move(instructions)
  function = move(rebuilt)

proc rematerializeAddresses*(function: var IrFunction): bool {.raises: [].} =
  ## Recreates frame addresses near uses instead of carrying them over calls.
  let crossing = liveAcrossCalls(function, analyzeLiveness(function))
  var definitions = newSeq[int](function.values.len)
  for definition in definitions.mitems:
    definition = -1
  for index, item in function.instructions:
    if item.op == SlotAddressOp and not item.volatile and
      crossing[item.results.first]:
        definitions[item.results.first] = index
        result = true
  if result:
    function.recreate(definitions)

proc cheapConstant(function: IrFunction, item: IrInstruction): bool =
  ## Limits duplication to float32 bits and small scalar integer payloads.
  if item.op != ConstantOp or item.volatile or item.results.count != 1:
    return false
  case function.values[item.results.first].valueType
  of Float32Type:
    true
  of BoolType, CharType, Int8Type .. UInt64Type:
    item.bits <= 65535 or item.bits >= uint64.high - 65535
  else:
    false

proc rematerializeConstants*(function: var IrFunction): bool {.raises: [].} =
  ## Places cheap immutable literals beside uses instead of across hot paths.
  let crossing = liveAcrossCalls(function, analyzeLiveness(function))
  var
    owners = newSeq[int](function.values.len)
    different = newSeq[bool](function.values.len)
    definitions = newSeq[int](function.values.len)
  for definition in definitions.mitems:
    definition = -1
  for owner, data in function.blocks:
    for index in data.instructions.indices:
      for value in function.instructions[index].results.indices:
        owners[value] = owner
  for owner, data in function.blocks:
    template checkUses(span: Span) =
      for index in span.indices:
        let value = int32(function.operands[index])
        if owners[value] != owner:
          different[value] = true
    for index in data.instructions.indices:
      checkUses(function.instructions[index].arguments)
    checkUses(data.terminator.arguments)
    for index in data.terminator.edges.indices:
      checkUses(function.edges[index].arguments)
  for index, item in function.instructions:
    if function.cheapConstant(item) and
      (different[item.results.first] or crossing[item.results.first]):
        definitions[item.results.first] = index
        result = true
  if result:
    function.recreate(definitions)

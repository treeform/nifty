import irs

proc preserveFloatParameters*(function: var IrFunction): bool =
  ## Keeps exact float32 payloads typed across joins and loop backedges.
  let old = function
  var
    candidates = newSeq[bool](old.values.len)
    definitions = newSeq[int](old.values.len)
  for definition in definitions.mitems:
    definition = -1
  for owner, data in old.blocks:
    if owner > 0:
      for value in data.parameters.indices:
        candidates[value] = old.values[value].valueType == UInt64Type
    for index in data.instructions.indices:
      let item = old.instructions[index]
      if item.results.count == 1:
        definitions[item.results.first] = index
  proc source(value: ValueId): ValueId =
    ## Finds a float32 producer or another candidate without numeric conversion.
    let index = int32(value)
    if candidates[index]:
      return value
    let definition = definitions[index]
    if definition < 0:
      return NoValue
    let outer = old.instructions[definition]
    if outer.op != ConvertOp or outer.conversion != ZeroExtendConversion:
      return NoValue
    let narrow = old.operands[outer.arguments.first]
    if old.values[int32(narrow)].valueType != UInt32Type:
      return NoValue
    let innerIndex = definitions[int32(narrow)]
    if innerIndex < 0:
      return NoValue
    let inner = old.instructions[innerIndex]
    if inner.op != ConvertOp or inner.conversion != BitcastConversion:
      return NoValue
    let floating = old.operands[inner.arguments.first]
    if old.values[int32(floating)].valueType == Float32Type:
      return floating
    NoValue
  proc literal(value: ValueId): bool =
    ## Allows a literal's low 32 bits when no wide observation can survive.
    let index = definitions[int32(value)]
    index >= 0 and old.instructions[index].op == ConstantOp
  var changed = true
  while changed:
    changed = false
    template reject(value: ValueId) =
      ## Removes one unsafe carrier and repeats dependent edge proofs.
      if candidates[int32(value)]:
        candidates[int32(value)] = false
        changed = true
    for data in old.blocks:
      for index in data.instructions.indices:
        let item = old.instructions[index]
        for position in item.arguments.indices:
          let value = old.operands[position]
          if candidates[int32(value)] and
            not (item.op == ConvertOp and
              item.conversion == TruncateConversion and
              item.arguments.count == 1 and item.results.count == 1 and
              old.values[item.results.first].valueType == UInt32Type):
                reject(value)
      for position in data.terminator.arguments.indices:
        reject(old.operands[position])
      for index in data.terminator.edges.indices:
        let edge = old.edges[index]
        for position in 0 ..< int(edge.arguments.count):
          let
            value = old.operands[int(edge.arguments.first) + position]
            parameter = ValueId(old.blocks[int32(edge.target)].
              parameters.first + int32(position))
          if candidates[int32(parameter)] and
            int32(source(value)) < 0 and not literal(value):
              reject(parameter)
          if candidates[int32(value)] and not candidates[int32(parameter)]:
            reject(value)
  var floating = newSeq[bool](old.values.len)
  for data in old.blocks:
    for index in data.instructions.indices:
      let item = old.instructions[index]
      if item.op != ConvertOp or item.conversion != BitcastConversion or
        old.values[item.results.first].valueType != Float32Type:
          continue
      let input = definitions[int32(old.operands[item.arguments.first])]
      if input >= 0:
        let inner = old.instructions[input]
        if inner.op == ConvertOp and inner.conversion == TruncateConversion:
          let value = int32(old.operands[inner.arguments.first])
          floating[value] = candidates[value]
    for index in data.terminator.edges.indices:
      let edge = old.edges[index]
      for position in 0 ..< int(edge.arguments.count):
        let
          value = source(old.operands[int(edge.arguments.first) + position])
          parameter = old.blocks[int32(edge.target)].parameters.first +
            int32(position)
        if candidates[parameter] and int32(value) >= 0 and
          old.values[int32(value)].valueType == Float32Type:
            floating[parameter] = true
  changed = true
  while changed:
    changed = false
    for data in old.blocks:
      for index in data.terminator.edges.indices:
        let edge = old.edges[index]
        for position in 0 ..< int(edge.arguments.count):
          let
            value = int32(old.operands[int(edge.arguments.first) + position])
            parameter = old.blocks[int32(edge.target)].parameters.first +
              int32(position)
          if candidates[value] and candidates[parameter] and
            floating[value] != floating[parameter]:
              floating[value] = true
              floating[parameter] = true
              changed = true
  for value in 0 ..< candidates.len:
    candidates[value] = candidates[value] and floating[value]
  var replacements = newSeq[ValueId](old.values.len)
  for value in replacements.mitems:
    value = NoValue
  for value, selected in candidates:
    if selected:
      function.values[value].valueType = Float32Type
      result = true
  if not result:
    return
  for data in old.blocks:
    for index in data.terminator.edges.indices:
      let edge = old.edges[index]
      for position in 0 ..< int(edge.arguments.count):
        let parameter = old.blocks[int32(edge.target)].parameters.first +
          int32(position)
        if not candidates[parameter]:
          continue
        let value = old.operands[int(edge.arguments.first) + position]
        if int32(source(value)) < 0 and int32(replacements[int32(value)]) < 0:
          replacements[int32(value)] = ValueId(function.values.len)
          function.values.add(IrValue(valueType: Float32Type))
  var instructions: seq[IrInstruction]
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for index in data.instructions.indices:
      var item = old.instructions[index]
      if item.op == ConvertOp and item.conversion == TruncateConversion and
        candidates[int32(old.operands[item.arguments.first])]:
          item.conversion = BitcastConversion
      instructions.add(item)
      if item.op == ConstantOp and
        int32(replacements[item.results.first]) >= 0:
          var copy = item
          copy.bits = item.bits and 0xffffffff'u64
          copy.results.first = int32(replacements[item.results.first])
          instructions.add(copy)
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
    for index in data.terminator.edges.indices:
      let
        edge = old.edges[index]
        start = int32(function.operands.len)
      for position in 0 ..< int(edge.arguments.count):
        let
          parameter = old.blocks[int32(edge.target)].parameters.first +
            int32(position)
          value = old.operands[int(edge.arguments.first) + position]
        if candidates[parameter]:
          let floating = source(value)
          function.operands.add(if int32(floating) >= 0: floating
            else: replacements[int32(value)])
        else:
          function.operands.add(value)
      function.edges[index].arguments = Span(first: start,
        count: edge.arguments.count)
  function.instructions = move(instructions)

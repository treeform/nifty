import irs

type Condition = object
  root: int32
  boolean: int32
  ## Keeps an exact boolean producer while root polarity evolves through loops.
  inverted: bool

proc foldIdenticalBranches*(function: var IrFunction): bool =
  ## Replaces a condition only when both edges transfer the same SSA values.
  for data in function.blocks.mitems:
    let terminal = data.terminator
    if terminal.kind != BranchTerminator:
      continue
    let
      yes = function.edges[terminal.edges.first]
      no = function.edges[terminal.edges.first + 1]
    if int32(yes.target) != int32(no.target) or
      yes.arguments.count != no.arguments.count:
        continue
    var identical = true
    for i in 0 ..< yes.arguments.count:
      if int32(function.operands[yes.arguments.first + i]) !=
        int32(function.operands[no.arguments.first + i]):
          identical = false
          break
    if identical:
      data.terminator.kind = JumpTerminator
      data.terminator.arguments = Span()
      data.terminator.edges.count = 1
      result = true

proc simplifyConditions*(function: var IrFunction): bool =
  ## Retains boolean SSA values through representation changes and joins.
  let old = function
  var
    facts = newSeq[Condition](old.values.len)
    constants = newSeq[int](old.values.len)
    oddMasks = newSeq[bool](old.values.len)
    users = newSeq[seq[int]](old.values.len)
    parameters: seq[int]
    incoming = newSeq[seq[ValueId]](old.values.len)
    pending: seq[int]
    queued = newSeq[bool](old.instructions.len)
  for value in 0 ..< facts.len:
    facts[value].root = -1
    facts[value].boolean = -1
    constants[value] = -1
  for data in old.blocks:
    for value in data.parameters.indices:
      if old.values[value].valueType == BoolType:
        facts[value].root = int32(value)
        facts[value].boolean = int32(value)
  for owner in 1 ..< old.blocks.len:
    for value in old.blocks[owner].parameters.indices:
      if old.values[value].valueType in {CharType, Int8Type .. UInt64Type}:
        parameters.add(value)
  for data in old.blocks:
    for index in data.terminator.edges.indices:
      let edge = old.edges[index]
      for i in 0 ..< int(edge.arguments.count):
        let value = int(old.blocks[int32(edge.target)].parameters.first) + i
        incoming[value].add(old.operands[int(edge.arguments.first) + i])
  for index, item in old.instructions:
    if item.results.count != 1:
      continue
    pending.add(index)
    queued[index] = true
    for argument in item.arguments.indices:
      users[int32(old.operands[argument])].add(index)
    let kind = old.values[item.results.first].valueType
    if item.op == ConstantOp and kind <= UInt64Type:
      oddMasks[item.results.first] = (item.bits and 1) != 0
      if item.bits <= 1:
        constants[item.results.first] = int(item.bits)
      elif kind == BoolType and item.bits == uint64.high:
        constants[item.results.first] = 1
  for i, value in parameters:
    let node = old.instructions.len + i
    pending.add(node)
    queued.add(true)
    for input in incoming[value]:
      users[int32(input)].add(node)
  var cursor = 0
  while cursor < pending.len:
    let index = pending[cursor]
    inc cursor
    queued[index] = false
    if index >= old.instructions.len:
      let value = parameters[index - old.instructions.len]
      var normalized = incoming[value].len > 0
      for input in incoming[value]:
        let fact = facts[int32(input)]
        if fact.boolean < 0:
          normalized = false
      let fact = Condition(root: if normalized: int32(value) else: -1,
        boolean: if normalized: int32(value) else: -1)
      if facts[value] != fact:
        facts[value] = fact
        for user in users[value]:
          if not queued[user]:
            pending.add(user)
            queued[user] = true
      continue
    let
      item = old.instructions[index]
      output = item.results.first
      kind = old.values[output].valueType
    var fact = Condition(root: -1, boolean: -1)
    if kind == BoolType:
      fact.root = output
    if item.arguments.count == 1 and item.op == ConvertOp:
      let input = int32(old.operands[item.arguments.first])
      if kind <= UInt64Type and old.values[input].valueType <= UInt64Type and
          item.conversion in {BitcastConversion, TruncateConversion,
            ZeroExtendConversion, SignExtendConversion} and
          facts[input].root >= 0:
        fact = facts[input]
    elif item.arguments.count == 2 and
        (item.op in {AndOp, XorOp} or (item.op == CompareOp and item.comparison in
          {EqualComparison, NotEqualComparison})):
      for side in 0 .. 1:
        let
          input = int32(old.operands[item.arguments.first + int32(side)])
          literal = int32(old.operands[item.arguments.first + int32(1 - side)])
          constant = constants[literal]
        if facts[input].root < 0:
          continue
        if item.op == AndOp and kind <= UInt64Type and oddMasks[literal]:
          fact = facts[input]
        elif item.op == XorOp and kind <= UInt64Type and constant >= 0:
          fact = facts[input]
          fact.inverted = fact.inverted xor (constant == 1)
          if constant == 1:
            fact.boolean = -1
        elif item.op == CompareOp and constant >= 0:
          fact = facts[input]
          fact.inverted = fact.inverted xor
            ((constant == 0) == (item.comparison == EqualComparison))
        else:
          continue
        break
    if kind == BoolType:
      fact.boolean = output
    if facts[output] != fact:
      facts[output] = fact
      for user in users[output]:
        if not queued[user]:
          pending.add(user)
          queued[user] = true
  var replacements = newSeq[ValueId](old.values.len)
  for value in 0 ..< old.values.len:
    replacements[value] = ValueId(value)
  for value in parameters:
    if facts[value].root != value:
      continue
    replacements[value] = ValueId(function.values.len)
    function.values.add(old.values[value])
    function.values[value] = IrValue(valueType: BoolType)
    result = true

  for operand in function.operands.mitems:
    operand = replacements[int32(operand)]
  for index, edge in old.edges:
    let first = int32(function.operands.len)
    for i in 0 ..< int(edge.arguments.count):
      let
        value = int(old.blocks[int32(edge.target)].parameters.first) + i
        input = old.operands[int(edge.arguments.first) + i]
      function.operands.add(
        if int32(replacements[value]) == value: replacements[int32(input)]
        else: ValueId(facts[int32(input)].boolean))
    function.edges[index].arguments = Span(first: first,
      count: edge.arguments.count)
  var instructions: seq[IrInstruction]
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for value in data.parameters.indices:
      if int32(replacements[value]) != value:
        let arguments = Span(first: int32(function.operands.len), count: 1)
        function.operands.add(ValueId(value))
        instructions.add(IrInstruction(op: ConvertOp,
          conversion: ZeroExtendConversion, arguments: arguments,
          results: Span(first: int32(replacements[value]), count: 1),
          location: NoLocation))
    for index in data.instructions.indices:
      instructions.add(old.instructions[index])
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)
  for owner, data in old.blocks:
    let terminal = data.terminator
    if terminal.kind != BranchTerminator:
      continue
    let
      value = int32(old.operands[terminal.arguments.first])
      fact = facts[value]
    if fact.root < 0 or (fact.root == value and not fact.inverted):
      continue
    function.blocks[owner].terminator.arguments = Span(
      first: int32(function.operands.len), count: 1)
    function.operands.add(ValueId(fact.root))
    if fact.inverted:
      function.blocks[owner].terminator.edges = Span(
        first: int32(function.edges.len), count: 2)
      function.edges.add(function.edges[terminal.edges.first + 1])
      function.edges.add(function.edges[terminal.edges.first])
    result = true

proc threadConditions*(function: var IrFunction): bool =
  ## Composes empty conditional joins without copying effects or escaped values.
  let old = function
  var
    owners = newSeq[int](old.values.len)
    escapes = newSeq[bool](old.blocks.len)
    constants = newSeq[int](old.values.len)
  for value in 0 ..< owners.len:
    owners[value] = -1
    constants[value] = -1
  for owner, data in old.blocks:
    for value in data.parameters.indices:
      owners[value] = owner
  proc track(arguments: Span, owner: int) =
    ## Keeps parameter definitions whose uses extend beyond their own block.
    for index in arguments.indices:
      let source = owners[int32(old.operands[index])]
      if source >= 0 and source != owner:
        escapes[source] = true
  for owner, data in old.blocks:
    for index in data.instructions.indices:
      let item = old.instructions[index]
      track(item.arguments, owner)
      if item.op == ConstantOp and
          old.values[item.results.first].valueType == BoolType:
        constants[item.results.first] = int(item.bits and 1)
    track(data.terminator.arguments, owner)
    for index in data.terminator.edges.indices:
      track(old.edges[index].arguments, owner)
  proc substitute(value: ValueId, edge: IrEdge): ValueId =
    ## Resolves a target parameter through this specific incoming edge.
    let parameters = old.blocks[int32(edge.target)].parameters
    if int32(value) in parameters.first ..< parameters.first + parameters.count:
      old.operands[edge.arguments.first + int32(value) - parameters.first]
    else:
      value
  proc arguments(edge, through: IrEdge): seq[ValueId] =
    ## Carries each outgoing value through the original simultaneous assignment.
    for index in edge.arguments.indices:
      result.add(substitute(old.operands[index], through))
  for owner, data in old.blocks:
    let terminal = data.terminator
    if terminal.kind notin {JumpTerminator, BranchTerminator}:
      continue
    for index in terminal.edges.indices:
      let
        incoming = old.edges[index]
        target = int(int32(incoming.target))
        blockData = old.blocks[target]
        next = blockData.terminator
      if target == owner or escapes[target] or
          blockData.instructions.count != 0 or next.kind != BranchTerminator:
        continue
      let condition = substitute(old.operands[next.arguments.first], incoming)
      var truth = constants[int32(condition)]
      if terminal.kind == BranchTerminator and
          int32(condition) == int32(old.operands[terminal.arguments.first]):
        truth = ord(index == terminal.edges.first)
      if truth >= 0:
        let
          selected = old.edges[next.edges.first + int32(ord(truth == 0))]
          values = arguments(selected, incoming)
        # Forward-only targets prevent cycling through argument permutations.
        if int32(selected.target) <= target:
          continue
        let first = int32(function.operands.len)
        function.operands.add(values)
        function.edges[index] = IrEdge(target: selected.target,
          arguments: Span(first: first, count: int32(values.len)))
        result = true
      elif terminal.kind == JumpTerminator:
        var rewritten = next
        rewritten.arguments = Span(first: int32(function.operands.len), count: 1)
        rewritten.edges = Span(first: int32(function.edges.len), count: 2)
        function.operands.add(condition)
        for edgeIndex in next.edges.indices:
          let
            selected = old.edges[edgeIndex]
            values = arguments(selected, incoming)
            first = int32(function.operands.len)
          function.operands.add(values)
          function.edges.add(IrEdge(target: selected.target,
            arguments: Span(first: first, count: int32(values.len))))
        function.blocks[owner].terminator = rewritten
        result = true

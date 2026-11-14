import irs

proc speculatable(function: IrFunction, item: IrInstruction): bool =
  ## Retains conditional floating work that can change exception flags.
  if item.volatile:
    return false
  case item.op
  of ConstantOp, SelectOp, NegateOp:
    # Floating negation changes only the sign bit, including NaN payloads.
    true
  of AddOp, SubtractOp, MultiplyOp, AndOp, OrOp, XorOp, NotOp, CompareOp:
    for position in item.arguments.indices:
      if function.values[int32(function.operands[position])].valueType in
          {Float32Type, Float64Type, Float32x2Type}:
        return false
    true
  else:
    false

proc resolve(aliases: seq[ValueId], value: ValueId): ValueId =
  ## Resolves forwarded arm parameters before creating a redundant choice.
  result = value
  while int32(aliases[int32(result)]) != int32(result):
    result = aliases[int32(result)]

proc selectValues*(function: var IrFunction): seq[ValueId] =
  ## Replaces small pure diamonds with typed choices and returns substitutions.
  let old = function
  var incoming = newSeq[int](old.blocks.len)
  for value in 0 ..< old.values.len:
    result.add(ValueId(value))
  for data in old.blocks:
    for index in data.terminator.edges.indices:
      inc incoming[int32(old.edges[index].target)]
  var instructions: seq[IrInstruction]
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for index in data.instructions.indices:
      instructions.add(old.instructions[index])
    let terminal = data.terminator
    if terminal.kind == BranchTerminator:
      let
        condition = old.operands[terminal.arguments.first]
        yes = old.edges[terminal.edges.first]
        no = old.edges[terminal.edges.first + 1]
      var
        left = yes
        right = no
        arms: seq[int]
        allowed = int32(yes.target) == int32(no.target)
      if not allowed:
        let
          a = old.blocks[int32(yes.target)]
          b = old.blocks[int32(no.target)]
        if incoming[int32(yes.target)] == 1 and
          incoming[int32(no.target)] == 1 and
          int32(yes.target) != 0 and int32(no.target) != 0 and
          int32(yes.target) != owner and int32(no.target) != owner and
          a.terminator.kind == JumpTerminator and
          b.terminator.kind == JumpTerminator and
          a.instructions.count + b.instructions.count <= 6:
            left = old.edges[a.terminator.edges.first]
            right = old.edges[b.terminator.edges.first]
            allowed = int32(left.target) == int32(right.target)
            for arm in [int(int32(yes.target)), int(int32(no.target))]:
              for index in old.blocks[arm].instructions.indices:
                if not old.speculatable(old.instructions[index]):
                  allowed = false
            if allowed:
              arms = @[int(int32(yes.target)), int(int32(no.target))]
      if allowed and left.arguments.count <= 8:
        for side, arm in arms:
          let
            parameters = old.blocks[arm].parameters
            edge = if side == 0: yes else: no
          for i in 0 ..< parameters.count:
            result[parameters.first + i] = old.operands[edge.arguments.first + i]
          for index in old.blocks[arm].instructions.indices:
            instructions.add(old.instructions[index])
        var choices: seq[ValueId]
        for index in 0 ..< left.arguments.count:
          let
            a = result.resolve(old.operands[left.arguments.first + index])
            b = result.resolve(old.operands[right.arguments.first + index])
          if int32(a) == int32(b):
            choices.add(a)
          else:
            let value = ValueId(function.values.len)
            function.values.add(old.values[int32(a)])
            result.add(value)
            instructions.add(IrInstruction(op: SelectOp,
              results: Span(first: int32(value), count: 1),
              arguments: Span(first: int32(function.operands.len), count: 3),
              location: terminal.location))
            function.operands.add([condition, a, b])
            choices.add(value)
        function.blocks[owner].terminator = IrTerminator(
          kind: JumpTerminator, location: terminal.location,
          edges: Span(first: int32(function.edges.len), count: 1))
        function.edges.add(IrEdge(target: left.target,
          arguments: Span(first: int32(function.operands.len),
            count: int32(choices.len))))
        function.operands.add(choices)
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)

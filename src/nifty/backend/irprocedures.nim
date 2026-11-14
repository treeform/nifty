import irs

proc trapBody*(function: IrFunction): bool {.raises: [].} =
  ## Recognizes an unconditional trap without effects or storage work.
  function.blocks.len == 1 and
    function.blocks[0].instructions.count == 0 and
    function.blocks[0].terminator.kind == UnreachableTerminator

proc reachableProcedures*(module: IrModule): seq[bool] =
  ## Follows final direct calls from main and every possibly escaped function.
  result = newSeq[bool](module.functions.len)
  var pending: seq[int]
  for index, function in module.functions:
    if index == 0 or not function.directOnly:
      result[index] = true
      pending.add(index)
  var cursor = 0
  while cursor < pending.len:
    let function = module.functions[pending[cursor]]
    inc cursor
    var
      blocks = @[0]
      visited = newSeq[bool](function.blocks.len)
      position = 0
    visited[0] = true
    template call(target: int32) =
      ## Retains one callee without duplicating its traversal.
      if not result[target]:
        result[target] = true
        pending.add(int(target))
    while position < blocks.len:
      let data = function.blocks[blocks[position]]
      inc position
      for index in data.instructions.indices:
        let item = function.instructions[index]
        if item.op == CallOp:
          call(item.target)
      if data.terminator.kind == InvokeTerminator:
        call(data.terminator.callee)
      for index in data.terminator.edges.indices:
        let target = int(function.edges[index].target)
        if not visited[target]:
          visited[target] = true
          blocks.add(target)

proc pruneProcedures*(module: var IrModule): bool =
  ## Removes private unreachable bodies while preserving runtime table IDs.
  let reachable = reachableProcedures(module)
  for index in 0 ..< module.functions.len:
    if reachable[index] or module.functions[index].trapBody():
      continue
    let old = module.functions[index]
    var function = IrFunction(name: old.name, signature: old.signature,
      directOnly: old.directOnly, failureMode: old.failureMode)
    for value in old.blocks[0].parameters.indices:
      function.values.add(old.values[value])
    function.blocks.add(IrBlock(
      parameters: Span(count: int32(function.values.len)),
      terminator: IrTerminator(kind: UnreachableTerminator,
        location: NoLocation)))
    module.functions[index] = move(function)
    result = true

import common, irs, irchecks

proc removeUnusedArguments*(module: var IrModule): bool
    {.raises: [BackendError].} =
  ## Prunes private parameters and their call operands without dropping effects.
  verifyIr(module)
  for function in module.functions:
    for data in function.blocks:
      let terminator = data.terminator
      if terminator.kind == InvokeTerminator:
        let target = int(terminator.callee)
        if target < 0 or target >= module.functions.len:
          return false
        if terminator.arguments.count !=
            module.functions[target].signature.parameters.len:
            return false
  var
    firsts: seq[int]
    total = 0
  for function in module.functions:
    firsts.add(total)
    total += function.signature.parameters.len
  var
    needed = newSeq[bool](total)
    callers = newSeq[seq[int]](total)
    pending: seq[int]
  proc demand(parameter: int) =
    ## Enqueues each observable parameter once for backwards propagation.
    if parameter >= 0 and not needed[parameter]:
      needed[parameter] = true
      pending.add(parameter)
  for index, function in module.functions:
    let entry = function.blocks[0].parameters
    var roots = newSeq[int](function.values.len)
    for root in roots.mitems:
      root = -1
    for i in 0 ..< int(entry.count):
      let parameter = firsts[index] + i
      roots[int(entry.first) + i] = parameter
      if index == 0 or not function.directOnly or
          (i == 0 and function.signature.parameters[i] == AddressType):
          demand(parameter)
    proc observe(span: Span, callee = -1) =
      ## Treats direct argument forwarding as a dependency, not an observation.
      for i in 0 ..< int(span.count):
        let root = roots[int32(function.operands[int(span.first) + i])]
        if root < 0:
          continue
        if callee >= 0:
          callers[firsts[callee] + i].add(root)
        else:
          demand(root)
    for data in function.blocks:
      for i in data.instructions.indices:
        let item = function.instructions[i]
        observe(item.arguments, if item.op == CallOp: int(item.target) else: -1)
      let terminator = data.terminator
      observe(terminator.arguments,
        if terminator.kind == InvokeTerminator: int(terminator.callee) else: -1)
      for i in terminator.edges.indices:
        observe(function.edges[i].arguments)
  while pending.len > 0:
    let parameter = pending.pop()
    for caller in callers[parameter]:
      demand(caller)
  var keep: seq[seq[bool]]
  for index, function in module.functions:
    keep.add(newSeq[bool](function.signature.parameters.len))
    for i in 0 ..< keep[index].len:
      keep[index][i] = needed[firsts[index] + i]
      if not keep[index][i]:
        result = true
  if not result:
    return
  for index in 0 ..< module.functions.len:
    let
      old = module.functions[index]
      entry = old.blocks[0].parameters
    var
      rebuilt = IrFunction(name: old.name, signature: old.signature,
        failureMode: old.failureMode, directOnly: old.directOnly,
        slots: old.slots)
      mapping = newSeq[ValueId](old.values.len)
    rebuilt.signature.parameters.setLen(0)
    rebuilt.signature.parameterStorage.setLen(0)
    rebuilt.signature.passing.setLen(0)
    for i, kind in old.signature.parameters:
      if keep[index][i]:
        rebuilt.signature.parameters.add(kind)
        if old.signature.parameterStorage.len > 0:
          rebuilt.signature.parameterStorage.add(
            old.signature.parameterStorage[i]
          )
        if old.signature.passing.len > 0:
          rebuilt.signature.passing.add(old.signature.passing[i])
    for i, value in old.values:
      mapping[i] = NoValue
      let parameter = i - int(entry.first)
      if parameter >= 0 and parameter < int(entry.count) and
          not keep[index][parameter]:
          continue
      mapping[i] = ValueId(rebuilt.values.len)
      rebuilt.values.add(value)
    proc results(span: Span): Span =
      ## Renumbers contiguous definitions after removing entry parameters.
      if span.count > 0:
        result = Span(first: int32(mapping[span.first]), count: span.count)
    proc arguments(span: Span, callee = -1): Span =
      ## Rebuilds operand pools while filtering the matching call positions.
      result.first = int32(rebuilt.operands.len)
      for i in 0 ..< int(span.count):
        if callee >= 0 and not keep[callee][i]:
          continue
        let value = mapping[int32(old.operands[int(span.first) + i])]
        doAssert int32(value) >= 0,
          "A removed parameter still has an observation"
        rebuilt.operands.add(value)
        inc result.count
    for owner, data in old.blocks:
      var blockData = data
      if owner == 0:
        blockData.parameters = Span(
          count: int32(rebuilt.signature.parameters.len)
        )
        if blockData.parameters.count > 0:
          for i in entry.indices:
            if int32(mapping[i]) >= 0:
              blockData.parameters.first = int32(mapping[i])
              break
      else:
        blockData.parameters = results(data.parameters)
      blockData.instructions.first = int32(rebuilt.instructions.len)
      for i in data.instructions.indices:
        var item = old.instructions[i]
        item.arguments = arguments(item.arguments,
          if item.op == CallOp: int(item.target) else: -1)
        item.results = results(item.results)
        rebuilt.instructions.add(item)
      blockData.instructions.count =
        int32(rebuilt.instructions.len) - blockData.instructions.first
      blockData.terminator.arguments = arguments(data.terminator.arguments,
        if data.terminator.kind == InvokeTerminator:
          int(data.terminator.callee) else: -1)
      blockData.terminator.results = results(data.terminator.results)
      blockData.terminator.edges.first = int32(rebuilt.edges.len)
      for i in data.terminator.edges.indices:
        let edge = old.edges[i]
        rebuilt.edges.add(IrEdge(target: edge.target,
          arguments: arguments(edge.arguments)))
      rebuilt.blocks.add(blockData)
    module.functions[index] = move(rebuilt)
  verifyIr(module)

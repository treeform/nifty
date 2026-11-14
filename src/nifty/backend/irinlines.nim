import irs, ircontexts

type
  IrInlineConfig* = object
    maxCalleeInstructions*: int
    maxCalleeBlocks*: int
    maxCalleeSlots*: int
    maxFunctionInstructions*: int
    maxFunctionBlocks*: int
    maxFunctionSlots*: int
    maxFunctionGrowth*: int
    maxModuleGrowth*: int
    maxCalls*: int

  IrInlineStats* = object
    callsInlined*: int
    instructionsAdded*: int
    blocksAdded*: int
    slotsAdded*: int
    candidatesRejected*: int
    budgetRejected*: int

proc defaultInlineConfig*(): IrInlineConfig =
  ## Bounds duplication while admitting small helpers with branches and loops.
  IrInlineConfig(maxCalleeInstructions: 384, maxCalleeBlocks: 96,
    maxCalleeSlots: 128, maxFunctionInstructions: 8192,
    maxFunctionBlocks: 512, maxFunctionSlots: 1024,
    maxFunctionGrowth: 8, maxModuleGrowth: 100000, maxCalls: 4096)

proc instructionCount(function: IrFunction): int =
  ## Counts active instructions rather than obsolete pooled instructions.
  for data in function.blocks:
    result += int(data.instructions.count)

proc appendOperands(function: var IrFunction,
    values: openArray[ValueId]): Span =
  ## Appends an operand group without changing its evaluation order.
  result = Span(first: int32(function.operands.len), count: int32(values.len))
  function.operands.add(values)

proc operands(function: IrFunction, span: Span): seq[ValueId] =
  ## Copies a live operand span from the source pool.
  for i in span.indices:
    result.add(function.operands[i])

proc jump(function: var IrFunction, target: int,
    arguments: openArray[ValueId]): IrTerminator =
  ## Builds a jump and its explicit block parameter transfers.
  let first = int32(function.edges.len)
  function.edges.add(IrEdge(target: BlockId(target),
    arguments: function.appendOperands(arguments)))
  IrTerminator(kind: JumpTerminator, edges: Span(first: first, count: 1))

proc recursiveFunctions(module: IrModule): seq[bool] =
  ## Rejects every function participating in a direct recursive call cycle.
  result = newSeq[bool](module.functions.len)
  var graph = newSeq[seq[int]](module.functions.len)
  for owner, function in module.functions:
    for data in function.blocks:
      for index in data.instructions.indices:
        let item = function.instructions[index]
        if item.op == CallOp:
          graph[owner].add(int(item.target))
      if data.terminator.kind == InvokeTerminator:
        graph[owner].add(int(data.terminator.callee))
  for root in 0 ..< graph.len:
    var
      visited = newSeq[bool](graph.len)
      pending = graph[root]
    while pending.len > 0:
      let current = pending.pop()
      if current == root:
        result[root] = true
        break
      if current >= 0 and current < graph.len and not visited[current]:
        visited[current] = true
        pending.add(graph[current])

proc eligible(function: IrFunction, config: IrInlineConfig): bool =
  ## Excludes frame introspection and unsupported exceptional return control.
  if function.failureMode != NoFailCall or function.blocks.len == 0 or
      function.blocks.len > config.maxCalleeBlocks or
      function.slots.len > config.maxCalleeSlots or
      function.instructionCount() > config.maxCalleeInstructions:
      return false
  var returned = false
  for data in function.blocks:
    case data.terminator.kind
    of ReturnTerminator:
      returned = true
    of JumpTerminator, BranchTerminator, UnreachableTerminator:
      discard
    else:
      return false
    for index in data.instructions.indices:
      if function.instructions[index].op == FrameSizeOp:
        return false
  returned

proc implicitContext(function: IrFunction): bool =
  ## Detects operations whose runtime binding comes from the current routine.
  for data in function.blocks:
    for index in data.instructions.indices:
      if function.instructions[index].op in {HostCallOp, GlobalAddressOp}:
        return true

proc inlineCall(function: var IrFunction, owner, index: int,
    callee: IrFunction) =
  ## Splices a whole CFG at a call, retaining pointer aliases and memory order.
  let
    original = function
    call = original.instructions[index]
    actuals = original.operands(call.arguments)
    parameters = callee.blocks[0].parameters
    firstBlock = original.blocks.len
    continuation = firstBlock + callee.blocks.len
    firstSlot = original.slots.len
  var rewritten = IrFunction(name: original.name,
    failureMode: original.failureMode, directOnly: original.directOnly,
    signature: original.signature, values: original.values,
    slots: original.slots)
  rewritten.slots.add(callee.slots)
  var mapping = newSeq[ValueId](callee.values.len)
  for value, data in callee.values:
    if value >= parameters.first and
        value < parameters.first + parameters.count:
      mapping[value] = actuals[value - int(parameters.first)]
    else:
      mapping[value] = ValueId(rewritten.values.len)
      rewritten.values.add(data)
  proc mapped(span: Span): Span =
    ## Remaps a contiguous definition span into newly allocated SSA values.
    if span.count > 0:
      result = Span(first: int32(mapping[span.first]), count: span.count)
  proc mappedOperands(span: Span): seq[ValueId] =
    ## Substitutes entry parameters directly with already evaluated actuals.
    for i in span.indices:
      result.add(mapping[int32(callee.operands[i])])
  proc copyInstruction(source: IrFunction, item: IrInstruction,
      clone: bool): IrInstruction =
    ## Copies one instruction and appends only its currently live operands.
    result = item
    if clone:
      result.results = mapped(item.results)
      result.arguments = rewritten.appendOperands(
        mappedOperands(item.arguments))
      if item.op == SlotAddressOp:
        result.target += int32(firstSlot)
    else:
      result.arguments = rewritten.appendOperands(
        source.operands(item.arguments))
  proc copyTerminator(source: IrFunction, terminal: IrTerminator,
      clone: bool): IrTerminator =
    ## Copies control flow and gives every cloned return a shared successor.
    if clone and terminal.kind == ReturnTerminator:
      return rewritten.jump(continuation,
        mappedOperands(terminal.arguments))
    result = terminal
    result.arguments = rewritten.appendOperands(
      if clone: mappedOperands(terminal.arguments)
      else: source.operands(terminal.arguments))
    if clone:
      result.results = mapped(terminal.results)
    result.edges = Span(first: int32(rewritten.edges.len),
      count: terminal.edges.count)
    for edgeIndex in terminal.edges.indices:
      let edge = source.edges[edgeIndex]
      rewritten.edges.add(IrEdge(
        target: if clone: BlockId(int32(edge.target) + int32(firstBlock))
          else: edge.target,
        arguments: rewritten.appendOperands(
          if clone: mappedOperands(edge.arguments)
          else: source.operands(edge.arguments))))
  for blockIndex, data in original.blocks:
    var copied = data
    copied.instructions = Span(first: int32(rewritten.instructions.len))
    for instructionIndex in data.instructions.indices:
      if blockIndex == owner and instructionIndex >= index:
        break
      rewritten.instructions.add(copyInstruction(original,
        original.instructions[instructionIndex], false))
      inc copied.instructions.count
    copied.terminator =
      if blockIndex == owner: rewritten.jump(firstBlock, [])
      else: copyTerminator(original, data.terminator, false)
    rewritten.blocks.add(copied)
  for blockIndex, data in callee.blocks:
    var copied = data
    copied.parameters = if blockIndex == 0: Span()
      else: mapped(data.parameters)
    copied.instructions = Span(first: int32(rewritten.instructions.len))
    for instructionIndex in data.instructions.indices:
      rewritten.instructions.add(copyInstruction(callee,
        callee.instructions[instructionIndex], true))
      inc copied.instructions.count
    copied.terminator = copyTerminator(callee, data.terminator, true)
    rewritten.blocks.add(copied)
  var resumed = IrBlock(parameters: call.results,
    instructions: Span(first: int32(rewritten.instructions.len)))
  let data = original.blocks[owner]
  for instructionIndex in index + 1 ..<
      int(data.instructions.first + data.instructions.count):
    rewritten.instructions.add(copyInstruction(original,
      original.instructions[instructionIndex], false))
    inc resumed.instructions.count
  resumed.terminator = copyTerminator(original, data.terminator, false)
  rewritten.blocks.add(resumed)
  function = rewritten

proc inlineIr*(module: var IrModule,
    config = defaultInlineConfig()): IrInlineStats =
  ## Inlines bounded direct calls without removing or renumbering functions.
  let recursive = module.recursiveFunctions()
  var originals = newSeq[int](module.functions.len)
  for owner, function in module.functions:
    originals[owner] = function.instructionCount()
  for owner in 0 ..< module.functions.len:
    var changed = true
    while changed and result.callsInlined < config.maxCalls:
      changed = false
      let contexts = module.functions[owner].contextAliases(module.pointerBytes)
      for blockIndex, data in module.functions[owner].blocks:
        for instructionIndex in data.instructions.indices:
          let call = module.functions[owner].instructions[instructionIndex]
          if call.op != CallOp:
            continue
          let target = int(call.target)
          if target == owner or target < 0 or target >= module.functions.len or
              recursive[target] or not module.functions[target].eligible(config):
            inc result.candidatesRejected
            continue
          let callee = module.functions[target]
          if callee.implicitContext():
            let
              entry = module.functions[owner].blocks[0].parameters
              context = if call.arguments.count > 0:
                  int32(module.functions[owner].operands[call.arguments.first])
                else: -1'i32
            if context < 0 or (not contexts[context] and
                (entry.count == 0 or context != entry.first)):
              inc result.candidatesRejected
              continue
          if call.arguments.count != callee.blocks[0].parameters.count or
              call.results.count != callee.signature.returns.len:
            inc result.candidatesRejected
            continue
          let
            growth = max(0, callee.instructionCount() - 1)
            size = module.functions[owner].instructionCount() + growth
            limit = max(originals[owner], 16) * config.maxFunctionGrowth
          if size > config.maxFunctionInstructions or size > limit or
              module.functions[owner].blocks.len + callee.blocks.len + 1 >
                config.maxFunctionBlocks or
              module.functions[owner].slots.len + callee.slots.len >
                config.maxFunctionSlots or
              result.instructionsAdded + growth > config.maxModuleGrowth:
            inc result.budgetRejected
            continue
          module.functions[owner].inlineCall(blockIndex, instructionIndex,
            callee)
          inc result.callsInlined
          result.instructionsAdded += growth
          result.blocksAdded += callee.blocks.len + 1
          result.slotsAdded += callee.slots.len
          changed = true
          break
        if changed:
          break

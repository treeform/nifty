import irs, irdominators

proc sinkLoads*(function: var IrFunction, hosts: seq[IrHost]): bool =
  ## Delays unused reads through acyclic regions without crossing memory writes.
  let
    old = function
    tree = dominance(old)
    count = old.blocks.len
  if count == 0:
    return
  var
    depths = newSeq[int](count)
    uses = newSeq[int](old.values.len)
    destinations = newSeq[int](old.instructions.len)
    arrivals = newSeq[seq[int]](count)
  for item in uses.mitems:
    item = -1
  for item in destinations.mitems:
    item = -1
  for owner in 0 ..< count:
    var current = owner
    while current > 0 and tree.parents[current] >= 0:
      inc depths[owner]
      current = tree.parents[current]
  proc common(a, b: int): int =
    ## Finds the deepest block that dominates every observing use.
    if a < 0:
      return b
    var
      left = a
      right = b
    while left != right:
      if depths[left] > depths[right]:
        left = tree.parents[left]
      else:
        right = tree.parents[right]
    left
  for owner, data in old.blocks:
    if tree.parents[owner] < 0:
      continue
    template observe(span: Span) =
      for position in span.indices:
        let value = int32(old.operands[position])
        uses[value] = common(uses[value], owner)
    for index in data.instructions.indices:
      observe(old.instructions[index].arguments)
    observe(data.terminator.arguments)
    for index in data.terminator.edges.indices:
      observe(old.edges[index].arguments)
  proc barrier(item: IrInstruction): bool =
    ## Keeps reads before unknown writes and all volatile operations.
    if item.volatile:
      return true
    case item.op
    of StoreOp, MoveBytesOp, ClearBytesOp, CallOp, IndirectCallOp:
      true
    of HostCallOp:
      not hosts[item.target].effects.known or
        hosts[item.target].effects.writesMemory
    else:
      false
  proc clearPath(source, target, position: int): bool =
    ## Rejects intervening effects and cycles that would repeat the read.
    var
      state = newSeq[int8](count)
      pending = @[(target, false)]
    while pending.len > 0:
      let (owner, finished) = pending.pop()
      if finished:
        state[owner] = 2
        continue
      if state[owner] == 1:
        return false
      if state[owner] == 2:
        continue
      if owner != source and depths[owner] <= depths[source]:
        return false
      state[owner] = 1
      pending.add((owner, true))
      if owner != target:
        let data = old.blocks[owner]
        if data.terminator.kind in {InvokeTerminator, InvokeHostTerminator}:
          return false
        for index in data.instructions.indices:
          if (owner != source or index > position) and
              barrier(old.instructions[index]):
            return false
      if owner != source:
        for predecessor in tree.predecessors[owner]:
          if tree.parents[predecessor] >= 0:
            pending.add((predecessor, false))
    true
  for owner, data in old.blocks:
    if tree.parents[owner] < 0:
      continue
    for index in data.instructions.indices:
      let item = old.instructions[index]
      if item.op != LoadOp or item.volatile or item.results.count != 1:
        continue
      let target = uses[item.results.first]
      if target < 0 or target == owner or common(owner, target) != owner:
        continue
      if clearPath(owner, target, index):
        destinations[index] = target
        arrivals[target].add(index)
        result = true
  if not result:
    return
  var instructions: seq[IrInstruction]
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for index in arrivals[owner]:
      instructions.add(old.instructions[index])
    for index in data.instructions.indices:
      if destinations[index] < 0:
        instructions.add(old.instructions[index])
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)

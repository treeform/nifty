import std/algorithm, irs

proc movable(instruction: IrInstruction, addresses: bool): bool =
  ## Selects pure scalar and vector operations without guarded preconditions.
  case instruction.op
  of ConstantOp, AddOp, SubtractOp, MultiplyOp, MultiplyHighOp, NegateOp,
      AndOp, OrOp, XorOp, NotOp, CompareOp, SelectOp, FloorOp, RoundOp,
      PackOp, ExtractOp, VectorAddOp, VectorSubtractOp, VectorMultiplyOp,
      VectorSumOp:
    true
  of GlobalAddressOp, OffsetAddressOp, FieldAddressOp:
    addresses
  of ConvertOp:
    instruction.conversion in {IntegerFloatConversion, FloatWidthConversion} or
      (addresses and instruction.conversion == BitcastConversion)
  else:
    # Loads remain in place; stack addresses retain call-site rematerialization.
    false

proc hoistLoops*(function: var IrFunction, addresses = false):
    bool {.discardable.} =
  ## Hoists safe invariant chains and reports whether any instruction moved.
  let count = function.blocks.len
  var
    predecessors = newSeq[seq[int]](count)
    reachable = newSeq[bool](count)
    pending = @[0]
  for owner, data in function.blocks:
    for i in data.terminator.edges.indices:
      predecessors[int32(function.edges[i].target)].add(owner)
  while pending.len > 0:
    let owner = pending.pop()
    if reachable[owner]:
      continue
    reachable[owner] = true
    for i in function.blocks[owner].terminator.edges.indices:
      pending.add(int(int32(function.edges[i].target)))
  let words = (count + 63) div 64
  var dominators = newSeq[uint64](count * words)
  for owner in 0 ..< count:
    for value in 0 ..< count:
      if reachable[owner] and reachable[value] and (owner != 0 or value == 0):
        dominators[owner * words + value div 64] =
          dominators[owner * words + value div 64] or
            (1'u64 shl (value mod 64))
  var changed = true
  while changed:
    changed = false
    for owner in 1 ..< count:
      if not reachable[owner]:
        continue
      for word in 0 ..< words:
        var bits = uint64.high
        for predecessor in predecessors[owner]:
          if reachable[predecessor]:
            bits = bits and dominators[predecessor * words + word]
        if owner div 64 == word:
          bits = bits or (1'u64 shl (owner mod 64))
        if dominators[owner * words + word] != bits:
          dominators[owner * words + word] = bits
          changed = true
  proc dominates(a, b: int): bool =
    ## Tests a definition's availability before a proposed hoist destination.
    (dominators[b * words + a div 64] and (1'u64 shl (a mod 64))) != 0
  var
    loops = newSeq[seq[bool]](count)
    sizes = newSeq[int](count)
    headers: seq[int]
  for owner, data in function.blocks:
    if not reachable[owner]:
      continue
    for i in data.terminator.edges.indices:
      let header = int(int32(function.edges[i].target))
      if not dominates(header, owner):
        continue
      if loops[header].len == 0:
        loops[header] = newSeq[bool](count)
        loops[header][header] = true
        headers.add(header)
      pending = @[owner]
      while pending.len > 0:
        let member = pending.pop()
        if loops[header][member]:
          continue
        loops[header][member] = true
        for predecessor in predecessors[member]:
          if reachable[predecessor]:
            pending.add(predecessor)
  for header in headers:
    for member in loops[header]:
      if member:
        inc sizes[header]
  headers.sort(proc(a, b: int): int =
    ## Visits inner loops before their enclosing loops.
    result = cmp(sizes[a], sizes[b])
    if result == 0:
      result = cmp(a, b))
  for header in headers:
    let members = loops[header]
    var
      preheader = -1
      multiple = false
    for predecessor in predecessors[header]:
      if reachable[predecessor] and not members[predecessor]:
        if preheader >= 0 and preheader != predecessor:
          multiple = true
        preheader = predecessor
    if multiple or preheader < 0 or
      function.blocks[preheader].terminator.kind != JumpTerminator:
        continue
    var
      owners = newSeq[int](function.values.len)
      selected = newSeq[bool](function.instructions.len)
      hoisted: seq[IrInstruction]
    for owner, data in function.blocks:
      for value in data.parameters.indices:
        owners[value] = owner
      for i in data.instructions.indices:
        for value in function.instructions[i].results.indices:
          owners[value] = owner
      for value in data.terminator.results.indices:
        owners[value] = owner
    changed = true
    while changed:
      changed = false
      for owner, data in function.blocks:
        if not members[owner]:
          continue
        for i in data.instructions.indices:
          let instruction = function.instructions[i]
          if selected[i] or not movable(instruction, addresses) or
            instruction.results.count != 1:
              continue
          var invariant = true
          for j in instruction.arguments.indices:
            let definition = owners[int32(function.operands[j])]
            if members[definition] or not dominates(definition, preheader):
              invariant = false
          if invariant:
            selected[i] = true
            hoisted.add(instruction)
            owners[instruction.results.first] = preheader
            changed = true
    if hoisted.len == 0:
      continue
    result = true
    var instructions: seq[IrInstruction]
    for owner, data in function.blocks.mpairs:
      let first = instructions.len
      for i in data.instructions.indices:
        if not selected[i]:
          instructions.add(function.instructions[i])
      if owner == preheader:
        instructions.add(hoisted)
      data.instructions = Span(first: int32(first),
        count: int32(instructions.len - first))
    function.instructions = move(instructions)

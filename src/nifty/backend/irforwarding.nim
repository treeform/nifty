import std/tables, irs, irchecks

type
  Address = tuple[root: int32, offset: int64]
  MemoryKey = tuple[address: Address, bytes: int,
    kind: IrType, storage: int32]

proc forwardMemory*(module: var IrModule): bool =
  ## Forwards exact memory values across disjoint stores and unique CFG edges.
  for functionIndex in 0 ..< module.functions.len:
    var function = module.functions[functionIndex]
    let old = function
    var
      addresses = newSeq[Address](old.values.len)
      constants = newSeq[bool](old.values.len)
      bits = newSeq[uint64](old.values.len)
      aliases = newSeq[ValueId](old.values.len)
      predecessors = newSeq[seq[int]](old.blocks.len)
      outgoing = newSeq[Table[MemoryKey, ValueId]](old.blocks.len)
      visited = newSeq[bool](old.blocks.len)
      order: seq[int]
      pending = @[0]
    for i in 0 ..< old.values.len:
      aliases[i] = ValueId(i)
      addresses[i].root = int32(i)
    for item in old.instructions:
      if item.op == ConstantOp:
        constants[item.results.first] = true
        bits[item.results.first] = item.bits
    var changed = true
    while changed:
      changed = false
      for item in old.instructions:
        if item.results.count != 1 or item.arguments.count == 0:
          continue
        let input = int32(old.operands[item.arguments.first])
        var address = addresses[input]
        if item.op == ConvertOp and item.conversion == BitcastConversion and
            old.values[input].valueType in {AddressType, Int64Type, UInt64Type} and
            old.values[item.results.first].valueType in
              {AddressType, Int64Type, UInt64Type}:
          discard
        elif item.op == FieldAddressOp:
          address.offset += module.fields[item.target].offset
        elif item.op in {AddOp, OffsetAddressOp} and item.arguments.count == 2:
          if old.values[input].valueType notin
              {AddressType, Int64Type, UInt64Type} or
              old.values[item.results.first].valueType notin
                {AddressType, Int64Type, UInt64Type}:
            continue
          let offset = int32(old.operands[item.arguments.first + 1])
          if not constants[offset]:
            continue
          let delta = cast[int64](bits[offset])
          if delta < -(1'i64 shl 40) or delta > (1'i64 shl 40) or
              address.offset < -(1'i64 shl 40) or
              address.offset > (1'i64 shl 40):
            continue
          address.offset += delta
        else:
          continue
        if item.op in {FieldAddressOp, OffsetAddressOp}:
          if item.offset < -(1'i64 shl 40) or item.offset > (1'i64 shl 40):
            continue
          address.offset += item.offset
        if addresses[item.results.first] != address:
          addresses[item.results.first] = address
          changed = true
    for owner, data in old.blocks:
      for i in data.terminator.edges.indices:
        predecessors[int32(old.edges[i].target)].add(owner)
    while pending.len > 0:
      let owner = pending.pop()
      if visited[owner]:
        continue
      visited[owner] = true
      order.add(owner)
      for i in old.blocks[owner].terminator.edges.indices:
        pending.add(int(int32(old.edges[i].target)))
    proc resolve(value: ValueId): ValueId =
      ## Follows value substitutions without introducing a new lifetime.
      result = value
      while int32(aliases[int32(result)]) != int32(result):
        result = aliases[int32(result)]
    var
      keep = newSeq[bool](old.instructions.len)
      processed = newSeq[bool](old.blocks.len)
    for value in keep.mitems:
      value = true
    for owner in order:
      var memory = initTable[MemoryKey, ValueId]()
      if predecessors[owner].len == 1:
        let predecessor = predecessors[owner][0]
        if processed[predecessor]:
          memory = outgoing[predecessor]
      let data = old.blocks[owner]
      for index in data.instructions.indices:
        let item = old.instructions[index]
        keep[index] = true
        if item.volatile:
          memory.clear()
          continue
        if item.op in {LoadOp, StoreOp}:
          let
            operand = resolve(old.operands[item.arguments.first])
            value = if item.op == LoadOp: ValueId(item.results.first)
              else: resolve(old.operands[item.arguments.first + 1])
            kind = old.values[int32(value)]
            origin = addresses[int32(operand)]
            address: Address = (origin.root, origin.offset +% item.offset)
            key: MemoryKey = (address, byteCount(kind.valueType, module.pointerBytes),
              kind.valueType, kind.storage)
          if address.offset < -(1'i64 shl 41) or address.offset > (1'i64 shl 41):
            memory.clear()
            continue
          if item.op == StoreOp:
            var invalid: seq[MemoryKey]
            for previous in memory.keys:
              # Different SSA pointer roots can still alias the same storage.
              if previous.address.root != address.root or
                  (previous.address.offset < address.offset + key.bytes and
                  address.offset < previous.address.offset + previous.bytes):
                invalid.add(previous)
            for previous in invalid:
              memory.del(previous)
          elif memory.hasKey(key):
            aliases[int32(value)] = resolve(memory.getOrDefault(key))
            keep[index] = false
            result = true
          if kind.valueType != BoolType:
            memory[key] = resolve(value)
        elif item.op in {CallOp, IndirectCallOp, MoveBytesOp, ClearBytesOp}:
          memory.clear()
        elif item.op == HostCallOp:
          let effects = module.hosts[item.target].effects
          if not effects.known or effects.writesMemory:
            memory.clear()
      if data.terminator.kind in {JumpTerminator, BranchTerminator}:
        outgoing[owner] = memory
      processed[owner] = true
    var instructions: seq[IrInstruction]
    for owner, data in old.blocks:
      let first = int32(instructions.len)
      for i in data.instructions.indices:
        if keep[i]:
          instructions.add(old.instructions[i])
      function.blocks[owner].instructions = Span(first: first,
        count: int32(instructions.len) - first)
    for operand in function.operands.mitems:
      operand = resolve(operand)
    function.instructions = move(instructions)
    module.functions[functionIndex] = move(function)

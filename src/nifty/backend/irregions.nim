import std/tables, irs, irchecks, irdominators

type
  OriginKind = enum
    OpaqueOrigin, ParameterOrigin, SlotOrigin, GlobalOrigin
  Origin = object
    kind: OriginKind
    root: int32
    offset: int64
  MemoryKey = tuple[origin: Origin, bytes: int, alignment: int32,
    kind: IrType, storage: int32]

proc forwardRegions*(function: var IrFunction, module: IrModule): seq[ValueId] =
  ## Reuses exact memory values along paths without joins or aliasing writes.
  let old = function
  var aliases = newSeq[ValueId](old.values.len)
  for value in 0 ..< aliases.len:
    aliases[value] = ValueId(value)
  if module.pointerBytes != 8:
    return aliases
  var
    origins = newSeq[Origin](old.values.len)
    constants = newSeq[bool](old.values.len)
    bits = newSeq[uint64](old.values.len)
  for value in 0 ..< origins.len:
    origins[value] = Origin(root: int32(value))
  for value in old.blocks[0].parameters.indices:
    if old.values[value].valueType == AddressType:
      origins[value].kind = ParameterOrigin
  for item in old.instructions:
    if item.op == ConstantOp:
      constants[item.results.first] = true
      bits[item.results.first] = item.bits
    elif item.op == SlotAddressOp:
      origins[item.results.first] = Origin(kind: SlotOrigin, root: item.target)
    elif item.op == GlobalAddressOp:
      origins[item.results.first] = Origin(kind: GlobalOrigin,
        offset: module.globals[item.target].offset)
  var changed = true
  while changed:
    changed = false
    for item in old.instructions:
      if item.results.count != 1 or item.arguments.count == 0:
        continue
      let
        output = item.results.first
        input = int32(old.operands[item.arguments.first])
      if old.values[output].valueType notin
          {AddressType, Int64Type, UInt64Type}:
        continue
      var origin = origins[input]
      case item.op
      of ConvertOp:
        if item.conversion != BitcastConversion or
            old.values[input].valueType notin
              {AddressType, Int64Type, UInt64Type}:
          continue
      of FieldAddressOp:
        origin.offset = origin.offset +% module.fields[item.target].offset
        origin.offset = origin.offset +% item.offset
      of OffsetAddressOp, AddOp:
        let other = int32(old.operands[item.arguments.first + 1])
        if not constants[other] or old.values[other].valueType notin
            {Int64Type, UInt64Type}:
          continue
        origin.offset = origin.offset +% cast[int64](bits[other])
        if item.op == OffsetAddressOp:
          origin.offset = origin.offset +% item.offset
      else:
        continue
      if origins[output] != origin:
        origins[output] = origin
        changed = true
  proc resolve(value: ValueId): ValueId =
    ## Resolves earlier load substitutions without changing their concrete type.
    result = value
    while int32(aliases[int32(result)]) != int32(result):
      result = aliases[int32(result)]
  proc originOf(value: ValueId): Origin =
    ## Follows a forwarded pointer payload before comparing memory regions.
    result = origins[int32(resolve(value))]
    while result.kind == OpaqueOrigin:
      let root = int32(resolve(ValueId(result.root)))
      if root == result.root:
        break
      let source = origins[root]
      result = Origin(kind: source.kind, root: source.root,
        offset: result.offset +% source.offset)
  proc local(key: MemoryKey): bool =
    ## Proves that a region remains inside its freshly allocated local slot.
    key.origin.kind == SlotOrigin and key.origin.offset >= 0 and
      key.origin.offset <= int64(old.slots[key.origin.root].byteCount) - key.bytes
  proc overlaps(a, b: MemoryKey): bool =
    ## Retains disjoint fields while treating opaque aliases conservatively.
    if a.origin.kind == b.origin.kind and a.origin.root == b.origin.root:
      return cast[uint64](a.origin.offset -% b.origin.offset) < uint64(b.bytes) or
        cast[uint64](b.origin.offset -% a.origin.offset) < uint64(a.bytes)
    if (local(a) and (local(b) or b.origin.kind in
        {ParameterOrigin, GlobalOrigin})) or
        (local(b) and a.origin.kind in {ParameterOrigin, GlobalOrigin}):
      return false
    true
  let tree = dominance(old)
  var
    outgoing = newSeq[Table[MemoryKey, ValueId]](old.blocks.len)
    ready = newSeq[bool](old.blocks.len)
    keep = newSeq[bool](old.instructions.len)
    pending = @[0]
  for selected in keep.mitems:
    selected = true
  while pending.len > 0:
    let owner = pending.pop()
    var memory: Table[MemoryKey, ValueId]
    if owner != 0 and tree.predecessors[owner].len == 1:
      let predecessor = tree.predecessors[owner][0]
      if ready[predecessor]:
        memory = outgoing[predecessor]
    let data = old.blocks[owner]
    for index in data.instructions.indices:
      let item = old.instructions[index]
      if item.volatile:
        memory.clear()
        continue
      if item.op in {LoadOp, StoreOp}:
        let
          value = if item.op == LoadOp: ValueId(item.results.first)
            else: resolve(old.operands[item.arguments.first + 1])
          metadata = old.values[int32(value)]
        var origin = originOf(old.operands[item.arguments.first])
        origin.offset = origin.offset +% item.offset
        let key: MemoryKey = (origin, byteCount(metadata.valueType, 8),
          item.alignment, metadata.valueType, metadata.storage)
        if item.op == StoreOp:
          var invalid: seq[MemoryKey]
          for observed in memory.keys:
            if overlaps(key, observed):
              invalid.add(observed)
          for observed in invalid:
            memory.del(observed)
          if metadata.valueType != BoolType:
            memory[key] = value
        elif memory.hasKey(key):
          aliases[item.results.first] = resolve(memory.getOrDefault(key))
          keep[index] = false
        else:
          memory[key] = value
      elif item.op in {CallOp, IndirectCallOp, HostCallOp,
          MoveBytesOp, ClearBytesOp}:
        if item.op != HostCallOp or not module.hosts[item.target].effects.known or
            module.hosts[item.target].effects.writesMemory:
          memory.clear()
    if data.terminator.kind in {InvokeTerminator, InvokeHostTerminator}:
      memory.clear()
    outgoing[owner] = move(memory)
    ready[owner] = true
    for child in tree.children[owner]:
      pending.add(child)
  var instructions: seq[IrInstruction]
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for index in data.instructions.indices:
      if keep[index]:
        instructions.add(old.instructions[index])
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)
  result = move(aliases)

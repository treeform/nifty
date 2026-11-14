import std/tables, irs, irchecks

type
  Origin = tuple[slot: int, offset: int64]
  Region = tuple[slot: int, offset: int64, bytes: int]

proc scalarizeSlots*(module: var IrModule, floatTypes = false) =
  ## Splits private aggregate fields into independently promotable scalar slots.
  for functionIndex in 0 ..< module.functions.len:
    var function = module.functions[functionIndex]
    let old = function
    var
      origins = newSeq[Origin](old.values.len)
      constants = newSeq[bool](old.values.len)
      bits = newSeq[uint64](old.values.len)
      escaped: seq[Region]
      accesses: seq[Region]
      candidates = initTable[Region, int]()
      events = initTable[Region, seq[tuple[owner: int, write: bool]]]()
      floating = initTable[Region, IrType]()
      addressesRead: seq[Region]
    for origin in origins.mitems:
      origin.slot = -1
    proc escape(origin: Origin, bytes = -1) =
      ## Conservatively retains every potentially observed byte of an address.
      if origin.slot >= 0:
        if bytes < 0:
          escaped.add((origin.slot, 0'i64, int(old.slots[origin.slot].byteCount)))
        else:
          escaped.add((origin.slot, origin.offset, bytes))
    for item in old.instructions:
      if item.op == ConstantOp:
        constants[item.results.first] = true
        bits[item.results.first] = item.bits
      elif item.op == SlotAddressOp:
        origins[item.results.first] = (int(item.target), 0'i64)
      elif item.op == ConvertOp and item.conversion == BitcastConversion and
          byteCount(old.values[item.results.first].valueType,
            module.pointerBytes) == int(module.pointerBytes):
        origins[item.results.first] =
          origins[int32(old.operands[item.arguments.first])]
      elif item.op in {OffsetAddressOp, AddOp, FieldAddressOp}:
        let
          a = old.operands[item.arguments.first]
          origin = origins[int32(a)]
        if origin.slot < 0:
          continue
        var
          offset = 0'i64
          known = false
        if item.op == FieldAddressOp:
          offset = module.fields[item.target].offset
          known = true
        else:
          let b = old.operands[item.arguments.first + 1]
          if constants[int32(b)]:
            offset = cast[int64](bits[int32(b)])
            known = offset >= 0 and
              offset <= int64(old.slots[origin.slot].byteCount)
        if known and origin.offset + offset <= old.slots[origin.slot].byteCount:
          origins[item.results.first] = (origin.slot, origin.offset + offset)
        else:
          escape(origin)
    for owner, data in old.blocks:
      for index in data.instructions.indices:
        let item = old.instructions[index]
        if item.op in {LoadOp, StoreOp}:
          let
            origin = origins[int32(old.operands[item.arguments.first])]
            value = if item.op == LoadOp: old.values[item.results.first]
              else: old.values[int32(old.operands[item.arguments.first + 1])]
          if origin.slot >= 0:
            let region: Region = (origin.slot, origin.offset + item.offset,
              byteCount(value.valueType, module.pointerBytes))
            accesses.add(region)
            if value.valueType in {Float32Type, Float64Type}:
              floating[region] = value.valueType
            elif value.valueType == AddressType:
              addressesRead.add(region)
            events.mgetOrPut(region, @[]).add((owner, item.op == StoreOp))
            if item.volatile or value.valueType == BoolType or
                region.offset < 0 or region.offset + region.bytes >
                  old.slots[origin.slot].byteCount:
              escaped.add(region)
            elif old.slots[origin.slot].byteCount > region.bytes:
              candidates[region] = -1
          if item.op == StoreOp:
            escape(origins[int32(old.operands[item.arguments.first + 1])])
        elif item.op == CallOp:
          let signature = module.functions[item.target].signature
          for i in 0 ..< int(item.arguments.count):
            let origin = origins[int32(old.operands[int(item.arguments.first) + i])]
            let storage = if i < signature.parameterStorage.len:
                signature.parameterStorage[i]
              else: 0
            escape(origin, if storage > 0:
                int(module.storageTypes[storage - 1].byteCount)
              else: -1)
        elif item.op == HostCallOp:
          let host = module.hosts[item.target]
          for i in 0 ..< int(item.arguments.count):
            let origin =
              origins[int32(old.operands[int(item.arguments.first) + i])]
            escape(origin, if host.borrowedBytes.len > 0:
                int(host.borrowedBytes[i])
              else: -1)
        elif item.op in {ConvertOp, OffsetAddressOp, AddOp, FieldAddressOp}:
          for i in item.arguments.indices:
            let origin = origins[int32(old.operands[i])]
            if origin.slot >= 0 and
                (origins[item.results.first].slot != origin.slot or
                (item.op == ConvertOp and item.conversion != BitcastConversion)):
              escape(origin)
        elif item.op notin {ConstantOp, SlotAddressOp}:
          for i in item.arguments.indices:
            escape(origins[int32(old.operands[i])])
      for i in data.terminator.arguments.indices:
        escape(origins[int32(old.operands[i])])
      for i in data.terminator.edges.indices:
        for j in old.edges[i].arguments.indices:
          escape(origins[int32(old.operands[j])])
    proc overlaps(a, b: Region): bool =
      ## Treats partially overlapping fields as one observable memory region.
      a.slot == b.slot and a.offset < b.offset + b.bytes and
        b.offset < a.offset + a.bytes
    var
      predecessors = newSeq[seq[int]](old.blocks.len)
      regions: seq[Region]
    for owner, data in old.blocks:
      for i in data.terminator.edges.indices:
        predecessors[int32(old.edges[i].target)].add(owner)
    proc initialized(region: Region): bool =
      ## Requires a defining store on every path reaching an observable read.
      var
        incoming = newSeq[bool](old.blocks.len)
        outgoing = newSeq[bool](old.blocks.len)
        defines = newSeq[bool](old.blocks.len)
      let uses = events.getOrDefault(region)
      for owner in 0 ..< old.blocks.len:
        incoming[owner] = owner != 0
        outgoing[owner] = true
      for use in uses:
        if use.write:
          defines[use.owner] = true
      var changed = true
      while changed:
        changed = false
        for owner in 0 ..< old.blocks.len:
          var value = owner != 0 and predecessors[owner].len > 0
          for predecessor in predecessors[owner]:
            value = value and outgoing[predecessor]
          incoming[owner] = value
          value = value or defines[owner]
          if outgoing[owner] != value:
            outgoing[owner] = value
            changed = true
      for use in uses:
        if use.write:
          incoming[use.owner] = true
        elif not incoming[use.owner]:
          return false
      true
    for region in accesses:
      if not candidates.hasKey(region) or region in regions:
        continue
      var allowed = true
      for other in accesses:
        if region != other and overlaps(region, other):
          allowed = false
          break
      if allowed:
        for other in escaped:
          if overlaps(region, other):
            allowed = false
            break
      if allowed and initialized(region):
        regions.add(region)
    if regions.len == 0:
      continue
    var
      instructions: seq[IrInstruction]
      addresses = initTable[Region, ValueId]()
    proc kind(region: Region): IrType =
      ## Keeps floating payloads typed while retaining exact mixed-view bits.
      if floatTypes and floating.hasKey(region) and region notin addressesRead:
        return floating.getOrDefault(region)
      case region.bytes
      of 1: UInt8Type
      of 2: UInt16Type
      of 4: UInt32Type
      else: UInt64Type
    proc emit(item: IrInstruction, arguments: openArray[ValueId],
        valueType = UInt64Type): ValueId =
      ## Adds a canonical scalar operation without changing original value IDs.
      var instruction = item
      instruction.arguments = Span(first: int32(function.operands.len),
        count: int32(arguments.len))
      function.operands.add(arguments)
      result = NoValue
      if instruction.op != StoreOp and instruction.results.count == 0:
        result = ValueId(function.values.len)
        instruction.results = Span(first: int32(result), count: 1)
        function.values.add(IrValue(valueType: valueType))
      instructions.add(instruction)
    for owner, data in old.blocks:
      let first = int32(instructions.len)
      if owner == 0:
        for region in regions:
          let slot = function.slots.len
          function.slots.add(IrSlot(byteCount: int32(region.bytes),
            alignment: int32(region.bytes)))
          let address = emit(IrInstruction(op: SlotAddressOp,
            target: int32(slot)), [], AddressType)
          addresses[region] = address
          let zero = emit(IrInstruction(op: ConstantOp), [], kind(region))
          discard emit(IrInstruction(op: StoreOp,
            alignment: int32(region.bytes)), [address, zero])
      for index in data.instructions.indices:
        let item = old.instructions[index]
        if item.op in {LoadOp, StoreOp}:
          let
            origin = origins[int32(old.operands[item.arguments.first])]
            value = if item.op == LoadOp: old.values[item.results.first]
              else: old.values[int32(old.operands[item.arguments.first + 1])]
            region: Region = (origin.slot, origin.offset + item.offset,
              byteCount(value.valueType, module.pointerBytes))
          if addresses.hasKey(region):
            let
              address = addresses.getOrDefault(region)
              canonical = kind(region)
            if item.op == LoadOp:
              let loaded = emit(IrInstruction(op: LoadOp,
                alignment: int32(region.bytes), location: item.location),
                [address], canonical)
              discard emit(IrInstruction(op: ConvertOp,
                conversion: BitcastConversion, results: item.results,
                location: item.location), [loaded])
            else:
              let stored = emit(IrInstruction(op: ConvertOp,
                conversion: BitcastConversion, location: item.location),
                [old.operands[item.arguments.first + 1]], canonical)
              discard emit(IrInstruction(op: StoreOp,
                alignment: int32(region.bytes), location: item.location),
                [address, stored])
            continue
        instructions.add(item)
      function.blocks[owner].instructions = Span(first: first,
        count: int32(instructions.len) - first)
    function.instructions = move(instructions)
    module.functions[functionIndex] = move(function)

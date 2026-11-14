import irs

proc materializeMemory*(module: var IrModule) =
  ## Expands aggregate byte operations only after semantic optimization.
  let
    storageTypes = module.storageTypes
    fields = module.fields
  for index in 0 ..< module.functions.len:
    var containsAggregate = false
    for item in module.functions[index].instructions:
      if item.op in {MoveBytesOp, ClearBytesOp}:
        containsAggregate = true
        break
    if not containsAggregate:
      continue
    var function = module.functions[index]
    var instructions: seq[IrInstruction]
    proc emit(op: IrOpcode, arguments: openArray[ValueId],
        kind = UInt64Type, offset = 0'i64, location = NoLocation): ValueId =
      ## Appends a scalar operation with explicit operands and source location.
      var item = IrInstruction(op: op, offset: offset, alignment: 1,
        location: location, arguments: Span(
          first: int32(function.operands.len), count: int32(arguments.len)))
      function.operands.add(arguments)
      result = NoValue
      if op != StoreOp:
        result = ValueId(function.values.len)
        item.results = Span(first: int32(result), count: 1)
        function.values.add(IrValue(valueType: kind))
      instructions.add(item)
    proc bytesAddress(value: ValueId): ValueId =
      ## Makes byte access explicit without pretending it is a field load.
      if function.values[int32(value)].storage == 0:
        return value
      result = emit(ConvertOp, [value], AddressType)
      instructions[^1].conversion = BitcastConversion
    for data in function.blocks.mitems:
      let first = instructions.len
      for i in data.instructions.indices:
        let item = function.instructions[i]
        if item.op notin {MoveBytesOp, ClearBytesOp} or
            item.byteCount > 256:
          instructions.add(item)
          continue
        let destination = bytesAddress(
          function.operands[item.arguments.first])
        var
          source = NoValue
          values: seq[tuple[value: ValueId, offset: int64]]
          chunks: seq[tuple[offset: int, kind: IrType]]
        proc span(offset, bytes: int) =
          ## Splits a byte span without merging neighboring scalar fields.
          var cursor = 0
          while cursor < bytes:
            let
              remaining = bytes - cursor
              size = if remaining >= 8: 8
                elif remaining >= 4: 4
                elif remaining >= 2: 2
                else: 1
              kind = if size == 8: UInt64Type
                elif size == 4: UInt32Type
                elif size == 2: UInt16Type
                else: UInt8Type
            chunks.add((offset + cursor, kind))
            cursor += size
        proc fieldsOf(storage: int32, offset: int) =
          ## Retains source field boundaries through concrete materialization.
          let layout = storageTypes[storage - 1]
          case layout.kind
          of StructStorage:
            for i in layout.fields.indices:
              let field = fields[i]
              if field.role == PaddingField:
                span(offset + int(field.offset),
                  int(storageTypes[field.storage - 1].byteCount))
              else:
                fieldsOf(field.storage, offset + int(field.offset))
          of ArrayStorage:
            let size = int(storageTypes[layout.element - 1].byteCount)
            for i in 0 ..< int(layout.length):
              fieldsOf(layout.element, offset + i * size)
          of ScalarStorage:
            when not defined(nimkeyNoIrFloatCopies):
              if layout.scalar == Float32Type and layout.byteCount == 4:
                chunks.add((offset, Float32Type))
              else:
                span(offset, int(layout.byteCount))
            else:
              span(offset, int(layout.byteCount))
          else:
            span(offset, int(layout.byteCount))
        if item.target > 0 and
            storageTypes[item.target - 1].byteCount == item.byteCount:
          fieldsOf(item.target, 0)
        else:
          span(0, int(item.byteCount))
        if item.op == MoveBytesOp:
          source = bytesAddress(function.operands[item.arguments.first + 1])
        for chunk in chunks:
          let value = if item.op == MoveBytesOp:
              emit(LoadOp, [source], chunk.kind,
                int64(chunk.offset), item.location)
            else:
              emit(ConstantOp, [], chunk.kind, location = item.location)
          values.add((value, int64(chunk.offset)))
        # Read the entire source first to preserve overlapping move semantics.
        for part in values:
          discard emit(StoreOp, [destination, part.value],
            offset = part.offset, location = item.location)
      data.instructions = Span(first: int32(first),
        count: int32(instructions.len - first))
    function.instructions = move(instructions)
    module.functions[index] = move(function)

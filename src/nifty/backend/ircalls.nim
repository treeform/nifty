import irs, irchecks

type
  Argument = tuple[offset: int64, kind: IrType]
  CallPlan = object
    enabled: bool
    parameter: int
    arguments: seq[Argument]
    addresses: seq[bool]
    loads: seq[int]

proc argumentPlan(module: IrModule, function: IrFunction, wide: bool):
    CallPlan =
  ## Requires bounded, nonvolatile reads of a private value argument record.
  let signature = function.signature
  if not function.directOnly or
      signature.parameterStorage.len != signature.parameters.len or
      signature.passing.len != signature.parameters.len:
      return
  var parameterIndex = -1
  for i, passing in signature.passing:
    if passing == ValuePassing:
      if parameterIndex >= 0:
        return
      parameterIndex = i
  if parameterIndex <= 0:
    return
  let
    storage = signature.parameterStorage[parameterIndex]
    parameter = int(function.blocks[0].parameters.first) + parameterIndex
  if storage <= 0:
    return
  var leaves: seq[Argument]
  proc fields(storage: int32, offset: int64): bool =
    ## Rejects references and dynamic payloads instead of changing ownership.
    let layout = module.storageTypes[storage - 1]
    if leaves.len > 32:
      return false
    case layout.kind
    of ScalarStorage:
      if layout.scalar == AddressType:
        return false
      leaves.add((offset, layout.scalar))
    of StructStorage:
      for index in layout.fields.indices:
        let field = module.fields[index]
        if field.role != PaddingField and
            not fields(field.storage, offset + field.offset):
          return false
    of ArrayStorage:
      if layout.length > 32:
        return false
      for i in 0 ..< layout.length:
        if not fields(layout.element, offset + int64(i) *
            module.storageTypes[layout.element - 1].byteCount):
          return false
    else:
      return false
    true
  if not fields(storage, 0):
    return
  var
    known = newSeq[bool](function.values.len)
    offsets = newSeq[int64](function.values.len)
    constants = newSeq[bool](function.values.len)
    bits = newSeq[uint64](function.values.len)
  known[parameter] = true
  for item in function.instructions:
    if item.op == ConstantOp:
      constants[item.results.first] = true
      bits[item.results.first] = item.bits
  var changed = true
  while changed:
    changed = false
    for item in function.instructions:
      if item.results.count != 1 or known[item.results.first] or
          item.arguments.count == 0:
        continue
      let input = int32(function.operands[item.arguments.first])
      if not known[input]:
        continue
      var offset = offsets[input]
      if item.op == ConvertOp and item.conversion == BitcastConversion and
          function.values[item.results.first].valueType in
            {AddressType, Int64Type, UInt64Type}:
        discard
      elif item.op == FieldAddressOp:
        offset += module.fields[item.target].offset
      elif item.op in {OffsetAddressOp, AddOp} and item.arguments.count == 2:
        let displacement = int32(function.operands[item.arguments.first + 1])
        if not constants[displacement]:
          continue
        let delta = cast[int64](bits[displacement])
        if delta < 0 or delta > module.storageTypes[storage - 1].byteCount:
          return
        offset += delta
      else:
        continue
      if item.op in {FieldAddressOp, OffsetAddressOp}:
        if item.offset < -int64(module.storageTypes[storage - 1].byteCount) or
            item.offset > int64(module.storageTypes[storage - 1].byteCount):
          return
        offset += item.offset
      known[item.results.first] = true
      offsets[item.results.first] = offset
      changed = true
  result.addresses = known
  result.parameter = parameterIndex
  result.loads = newSeq[int](function.instructions.len)
  for index in result.loads.mitems:
    index = -1
  var integers, floats = 0
  for i, kind in signature.parameters:
    if i != parameterIndex:
      if kind in {Float32Type, Float64Type}:
        inc floats
      else:
        inc integers
  for index, item in function.instructions:
    for position in item.arguments.indices:
      let value = int32(function.operands[position])
      if not known[value]:
        continue
      if position != int(item.arguments.first):
        return CallPlan()
      if item.results.count == 1 and known[item.results.first]:
        continue
      if item.op != LoadOp or item.volatile:
        return CallPlan()
      let
        loaded = function.values[item.results.first].valueType
        size = byteCount(loaded, module.pointerBytes)
        offset = offsets[value] + item.offset
      if loaded == AddressType or offset < 0 or offset + size >
          module.storageTypes[storage - 1].byteCount:
        return CallPlan()
      var kind = loaded
      for leaf in leaves:
        if leaf.offset == offset and
            byteCount(leaf.kind, module.pointerBytes) == size:
          kind = leaf.kind
          break
      let argument = (offset, kind)
      var selected = result.arguments.find(argument)
      if selected < 0:
        selected = result.arguments.len
        result.arguments.add(argument)
        if kind in {Float32Type, Float64Type}: inc floats
        else: inc integers
      result.loads[index] = selected
  for data in function.blocks:
    for index in data.terminator.arguments.indices:
      if known[int32(function.operands[index])]:
        return CallPlan()
    for index in data.terminator.edges.indices:
      for operand in function.edges[index].arguments.indices:
        if known[int32(function.operands[operand])]:
          return CallPlan()
  let maximum = if wide: 32 else: 8
  result.enabled = integers <= maximum and floats <= maximum

proc cacheArguments*(module: var IrModule): bool =
  ## Reads proven private value fields once without changing call signatures.
  for index in 0 ..< module.functions.len:
    let
      old = module.functions[index]
      plan = argumentPlan(module, old, true)
    if not plan.enabled:
      continue
    var outside = false
    for owner, data in old.blocks:
      if owner != 0:
        for position in data.instructions.indices:
          if plan.loads[position] >= 0:
            outside = true
    if not outside:
      continue
    var
      function = old
      keys: seq[tuple[field: int, kind: IrType, storage: int32]]
      values: seq[ValueId]
      replacement = newSeq[ValueId](old.instructions.len)
      initial: seq[IrInstruction]
      instructions: seq[IrInstruction]
    let address = ValueId(function.values.len)
    function.values.add(IrValue(valueType: AddressType))
    initial.add(IrInstruction(op: ConvertOp, conversion: BitcastConversion,
      arguments: Span(first: int32(function.operands.len), count: 1),
      results: Span(first: int32(address), count: 1)))
    function.operands.add(ValueId(old.blocks[0].parameters.first +
      int32(plan.parameter)))
    for value in replacement.mitems:
      value = NoValue
    for position, item in old.instructions:
      let field = plan.loads[position]
      if field < 0:
        continue
      let
        data = old.values[item.results.first]
        key = (field, data.valueType, data.storage)
      var selected = keys.find(key)
      if selected < 0:
        selected = keys.len
        keys.add(key)
        let value = ValueId(function.values.len)
        values.add(value)
        function.values.add(data)
        initial.add(IrInstruction(op: LoadOp,
          arguments: Span(first: int32(function.operands.len), count: 1),
          results: Span(first: int32(value), count: 1),
          offset: plan.arguments[field].offset, alignment: 1,
          location: item.location))
        function.operands.add(address)
      replacement[position] = values[selected]
    for owner, data in old.blocks:
      let first = int32(instructions.len)
      if owner == 0:
        instructions.add(initial)
      for position in data.instructions.indices:
        var item = old.instructions[position]
        if int32(replacement[position]) >= 0:
          item = IrInstruction(op: ConvertOp, conversion: BitcastConversion,
            results: item.results, location: item.location,
            arguments: Span(first: int32(function.operands.len), count: 1))
          function.operands.add(replacement[position])
        instructions.add(item)
      function.blocks[owner].instructions = Span(first: first,
        count: int32(instructions.len) - first)
    function.instructions = move(instructions)
    module.functions[index] = move(function)
    result = true

proc promoteArguments*(module: var IrModule, wide = false): bool =
  ## Replaces private argument records with typed SSA function parameters.
  var plans: seq[CallPlan]
  for function in module.functions:
    plans.add(argumentPlan(module, function, wide))
  for function in module.functions:
    for data in function.blocks:
      if data.terminator.kind == InvokeTerminator:
        plans[data.terminator.callee].enabled = false
  for index, plan in plans:
    if not plan.enabled:
      continue
    result = true
    var function = module.functions[index]
    let
      old = function
      first = int32(function.values.len)
      entry = old.blocks[0].parameters.first
    function.signature.parameters.setLen(0)
    function.signature.parameterStorage.setLen(0)
    function.signature.passing.setLen(0)
    var retained: seq[int]
    for position in 0 ..< int(old.blocks[0].parameters.count):
      if position == plan.parameter:
        continue
      retained.add(position)
      function.values.add(old.values[entry + int32(position)])
      function.signature.parameters.add(old.signature.parameters[position])
      function.signature.parameterStorage.add(
        old.signature.parameterStorage[position])
      function.signature.passing.add(old.signature.passing[position])
    for argument in plan.arguments:
      function.values.add(IrValue(valueType: argument.kind))
      function.signature.parameters.add(argument.kind)
      function.signature.parameterStorage.add(0)
      function.signature.passing.add(DirectPassing)
    function.blocks[0].parameters = Span(first: first,
      count: int32(retained.len + plan.arguments.len))
    for operand in function.operands.mitems:
      for ordinal, position in retained:
        if int32(operand) == entry + int32(position):
          operand = ValueId(first + int32(ordinal))
          break
    var instructions: seq[IrInstruction]
    for owner, data in old.blocks:
      let start = int32(instructions.len)
      for i in data.instructions.indices:
        var item = old.instructions[i]
        if item.results.count == 1 and plan.addresses[item.results.first]:
          continue
        if plan.loads[i] >= 0:
          item.op = ConvertOp
          item.conversion = BitcastConversion
          item.offset = 0
          item.arguments = Span(first: int32(function.operands.len), count: 1)
          function.operands.add(ValueId(first + int32(retained.len) +
            int32(plan.loads[i])))
        instructions.add(item)
      function.blocks[owner].instructions = Span(
        first: start,
        count: int32(instructions.len) - start
      )
    function.instructions = move(instructions)
    let operands = function.operands
    function.operands.setLen(0)
    proc repack(span: Span): Span =
      ## Drops obsolete operand records referring to removed address definitions.
      result = Span(first: int32(function.operands.len), count: span.count)
      for i in span.indices:
        function.operands.add(operands[i])
    for item in function.instructions.mitems:
      item.arguments = repack(item.arguments)
    for data in function.blocks.mitems:
      data.terminator.arguments = repack(data.terminator.arguments)
    for edge in function.edges.mitems:
      edge.arguments = repack(edge.arguments)
    module.functions[index] = move(function)
  for index in 0 ..< module.functions.len:
    var function = module.functions[index]
    var instructions: seq[IrInstruction]
    proc emit(op: IrOpcode, arguments: openArray[ValueId],
        kind: IrType, offset: int64, location: LocationId): ValueId =
      ## Adds a typed call input without assigning any physical register.
      result = ValueId(function.values.len)
      function.values.add(IrValue(valueType: kind))
      instructions.add(IrInstruction(op: op, conversion: BitcastConversion,
        results: Span(first: int32(result), count: 1), arguments: Span(
          first: int32(function.operands.len), count: int32(arguments.len)),
        offset: offset, alignment: 1, location: location))
      function.operands.add(arguments)
    for data in function.blocks.mitems:
      let start = int32(instructions.len)
      for i in data.instructions.indices:
        var item = function.instructions[i]
        if item.op == CallOp and plans[item.target].enabled:
          let
            first = item.arguments.first
            plan = plans[item.target]
          var arguments: seq[ValueId]
          for position in 0 ..< int(item.arguments.count):
            if position != plan.parameter:
              arguments.add(function.operands[first + int32(position)])
          let address = emit(ConvertOp,
            [function.operands[first + int32(plan.parameter)]],
            AddressType, 0, item.location)
          for argument in plan.arguments:
            arguments.add(emit(LoadOp, [address], argument.kind,
              argument.offset, item.location))
          item.arguments = Span(first: int32(function.operands.len),
            count: int32(arguments.len))
          function.operands.add(arguments)
        instructions.add(item)
      data.instructions = Span(first: start,
        count: int32(instructions.len) - start)
    function.instructions = move(instructions)
    module.functions[index] = move(function)

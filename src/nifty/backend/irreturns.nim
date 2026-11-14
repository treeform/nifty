import irs, irchecks

type ReturnPlan = object
  enabled: bool
  parameter: int
  kinds: seq[IrType]
  addresses: seq[bool]
  stores: seq[int]

proc roots(function: IrFunction): seq[int32] =
  ## Identifies addresses related only by full-width representation casts.
  result = newSeq[int32](function.values.len)
  for i in 0 ..< result.len:
    result[i] = int32(i)
  var changed = true
  while changed:
    changed = false
    for item in function.instructions:
      if item.op != ConvertOp or item.conversion != BitcastConversion:
        continue
      let
        input = int32(function.operands[item.arguments.first])
        output = item.results.first
      if function.values[input].valueType in
          {AddressType, UInt64Type, Int64Type} and
          function.values[output].valueType in
            {AddressType, UInt64Type, Int64Type} and
          result[output] != result[input]:
        result[output] = result[input]
        changed = true

proc resultKinds(module: IrModule, storage: int32,
    records: bool): seq[IrType] =
  ## Accepts scalar results or two to four contiguous binary32 fields.
  let layout = module.storageTypes[storage - 1]
  if layout.kind == ScalarStorage:
    if layout.scalar != AddressType:
      return @[layout.scalar]
    return
  if not records or layout.byteCount notin [8'i32, 12, 16]:
    return
  var cursor = 0'i32
  proc fields(storage, offset: int32): bool =
    ## Rejects padding, hidden fields, and ownership-bearing storage.
    let data = module.storageTypes[storage - 1]
    case data.kind
    of ScalarStorage:
      if data.scalar != Float32Type or offset != cursor:
        return false
      cursor += 4
    of StructStorage:
      for i in data.fields.indices:
        let field = module.fields[i]
        if field.role != SourceField or
          not fields(field.storage, offset + field.offset):
            return false
    of ArrayStorage:
      if data.length > 4:
        return false
      for i in 0 ..< data.length:
        if not fields(data.element, offset +
            i * module.storageTypes[data.element - 1].byteCount):
          return false
    else:
      return false
    cursor == offset + data.byteCount
  if fields(storage, 0) and cursor == layout.byteCount:
    for i in 0 ..< cursor div 4:
      result.add(Float32Type)

proc returnPlan(module: IrModule, function: IrFunction,
    records: bool): ReturnPlan =
  ## Accepts result pointers used only for complete scalar field stores.
  let signature = function.signature
  if not function.directOnly or signature.returns.len > 0 or
      signature.parameterStorage.len != signature.parameters.len or
      signature.passing.len != signature.parameters.len:
    return
  result.parameter = -1
  for i, passing in signature.passing:
    if passing == MutablePassing:
      if result.parameter >= 0:
        return ReturnPlan()
      result.parameter = i
  if result.parameter < 0:
    return
  let storage = signature.parameterStorage[result.parameter]
  if storage <= 0:
    return
  let
    parameter = function.blocks[0].parameters.first + int32(result.parameter)
    origins = roots(function)
  result.kinds = resultKinds(module, storage, records)
  if result.kinds.len == 0:
    return
  result.stores = newSeq[int](function.instructions.len)
  for lane in result.stores.mitems:
    lane = -1
  result.addresses = newSeq[bool](function.values.len)
  for i, root in origins:
    result.addresses[i] = root == parameter
  for index, item in function.instructions:
    for position in item.arguments.indices:
      let value = int32(function.operands[position])
      if not result.addresses[value]:
        continue
      if item.op == ConvertOp and result.addresses[item.results.first]:
        continue
      let lane = if result.kinds.len == 1: 0 else: int(item.offset div 4)
      if item.op != StoreOp or position != int(item.arguments.first) or
          item.volatile or item.offset < 0 or lane >= result.kinds.len or
          item.offset != int64(lane * 4) or
          byteCount(function.values[int32(function.operands[
            item.arguments.first + 1])].valueType, module.pointerBytes) !=
            byteCount(result.kinds[lane], module.pointerBytes):
        return ReturnPlan()
      result.stores[index] = lane
  for data in function.blocks:
    for i in data.terminator.arguments.indices:
      if result.addresses[int32(function.operands[i])]:
        return ReturnPlan()
    for i in data.terminator.edges.indices:
      for j in function.edges[i].arguments.indices:
        if result.addresses[int32(function.operands[j])]:
          return ReturnPlan()
  result.enabled = true

proc completeResult(function: IrFunction, plan: ReturnPlan): bool =
  ## Proves every return writes all lanes and no effect observes a delayed store.
  for data in function.blocks:
    if data.terminator.kind notin
        {JumpTerminator, BranchTerminator, ReturnTerminator}:
      return false
  proc harmless(item: IrInstruction): bool =
    ## Allows only nontrapping scalar and address work after an output store.
    if item.volatile:
      return false
    if item.op == ConvertOp:
      return item.conversion != FloatIntegerConversion
    item.op in {ConstantOp, AddOp, SubtractOp, MultiplyOp, NegateOp,
      AndOp, OrOp, XorOp, NotOp, ShiftLeftOp, ShiftRightOp, ArithmeticRightOp,
      CompareOp, SelectOp, SqrtOp, FloorOp, RoundOp, SlotAddressOp,
      GlobalAddressOp, OffsetAddressOp, FieldAddressOp, FrameSizeOp}
  var
    tails = newSeq[bool](function.blocks.len)
    changed = true
  while changed:
    changed = false
    for owner, data in function.blocks:
      var tail = data.terminator.kind == ReturnTerminator
      if data.terminator.kind in {JumpTerminator, BranchTerminator}:
        tail = true
        for edge in data.terminator.edges.indices:
          tail = tail and tails[int32(function.edges[edge].target)]
      for i in data.instructions.indices:
        tail = tail and (plan.stores[i] >= 0 or
          harmless(function.instructions[i]))
      if tail and not tails[owner]:
        tails[owner] = true
        changed = true
  for data in function.blocks:
    var tail = data.terminator.kind == ReturnTerminator
    if data.terminator.kind in {JumpTerminator, BranchTerminator}:
      tail = true
      for edge in data.terminator.edges.indices:
        tail = tail and tails[int32(function.edges[edge].target)]
    let last = int(data.instructions.first + data.instructions.count) - 1
    for i in countdown(last, int(data.instructions.first)):
      if plan.stores[i] >= 0:
        if not tail:
          return false
      else:
        tail = tail and harmless(function.instructions[i])
  let complete = (1 shl plan.kinds.len) - 1
  var
    masks = newSeq[int](function.blocks.len)
    reached = newSeq[bool](function.blocks.len)
    pending = @[0]
    cursor = 0
  reached[0] = true
  while cursor < pending.len:
    let owner = pending[cursor]
    inc cursor
    let data = function.blocks[owner]
    var mask = masks[owner]
    for i in data.instructions.indices:
      if plan.stores[i] >= 0:
        mask = mask or (1 shl plan.stores[i])
    if data.terminator.kind == ReturnTerminator:
      if mask != complete:
        return false
      continue
    for edge in data.terminator.edges.indices:
      let
        target = int32(function.edges[edge].target)
        combined = if reached[target]: masks[target] and mask else: mask
      if not reached[target] or combined != masks[target]:
        reached[target] = true
        masks[target] = combined
        pending.add(int(target))
  true

proc privateResult(module: IrModule, function: IrFunction,
    call: IrInstruction, plan: ReturnPlan): bool =
  ## Requires bounded caller-owned stack storage for the delayed output writes.
  var definitions = newSeq[int](function.values.len)
  for definition in definitions.mitems:
    definition = -1
  for i, item in function.instructions:
    for value in item.results.indices:
      definitions[value] = i
  var
    value = int32(function.operands[
      call.arguments.first + int32(plan.parameter)])
    offset = 0'i64
  for step in 0 ..< function.values.len:
    let index = definitions[value]
    if index < 0:
      return false
    let item = function.instructions[index]
    if item.op == SlotAddressOp:
      return offset >= 0 and offset <=
        int64(function.slots[item.target].byteCount) -
          int64(if plan.kinds.len == 1:
            byteCount(plan.kinds[0], module.pointerBytes)
          else: int32(plan.kinds.len * 4))
    if item.arguments.count == 0:
      return false
    let input = int32(function.operands[item.arguments.first])
    const PointerKinds = {AddressType, Int64Type, UInt64Type}
    if function.values[value].valueType notin PointerKinds or
        function.values[input].valueType notin PointerKinds:
      return false
    case item.op
    of ConvertOp:
      if item.conversion != BitcastConversion:
        return false
    of AddOp, OffsetAddressOp:
      let displacement = definitions[int32(function.operands[
        item.arguments.first + 1])]
      if displacement < 0 or
          function.instructions[displacement].op != ConstantOp:
        return false
      offset = offset +% cast[int64](function.instructions[displacement].bits)
      if item.op == OffsetAddressOp:
        offset = offset +% item.offset
    of FieldAddressOp:
      offset = offset +% int64(module.fields[item.target].offset) +% item.offset
    else:
      return false
    value = input
  false

proc promoteReturns*(module: var IrModule, records = false): bool =
  ## Returns fully stored private results in SSA after explicit safety proofs.
  var plans: seq[ReturnPlan]
  for function in module.functions:
    var plan = returnPlan(module, function, records)
    if plan.enabled and not completeResult(function, plan):
      plan.enabled = false
    plans.add(plan)
  for function in module.functions:
    for item in function.instructions:
      if item.op == CallOp and plans[item.target].enabled and
          not privateResult(module, function, item, plans[item.target]):
        plans[item.target].enabled = false
    for data in function.blocks:
      if data.terminator.kind == InvokeTerminator:
        plans[data.terminator.callee].enabled = false
  for index in 0 ..< module.functions.len:
    var function = module.functions[index]
    let
      old = function
      plan = plans[index]
    var
      instructions: seq[IrInstruction]
      transfers = newSeq[seq[IrInstruction]](old.instructions.len)
      resultAddresses: seq[ValueId]
    proc emit(op: IrOpcode, inputs: openArray[ValueId], kind: IrType,
        location = NoLocation): ValueId =
      ## Constructs explicit scalar work for subsequent shared SSA promotion.
      result = NoValue
      var item = IrInstruction(op: op, conversion: BitcastConversion,
        arguments: Span(first: int32(function.operands.len),
          count: int32(inputs.len)), alignment: 1, location: location)
      function.operands.add(inputs)
      if op != StoreOp:
        result = ValueId(function.values.len)
        function.values.add(IrValue(valueType: kind))
        item.results = Span(first: int32(result), count: 1)
      instructions.add(item)
    if plan.enabled:
      result = true
      let
        first = int32(function.values.len)
        entry = old.blocks[0].parameters
      function.signature.parameters.setLen(0)
      function.signature.parameterStorage.setLen(0)
      function.signature.passing.setLen(0)
      function.signature.returns = plan.kinds
      function.signature.returnStorage = newSeq[int32](plan.kinds.len)
      for position in 0 ..< int(entry.count):
        if position == plan.parameter:
          continue
        let replacement = ValueId(function.values.len)
        function.values.add(old.values[entry.first + int32(position)])
        function.signature.parameters.add(old.signature.parameters[position])
        function.signature.parameterStorage.add(
          old.signature.parameterStorage[position])
        function.signature.passing.add(old.signature.passing[position])
        for value in function.operands.mitems:
          if int32(value) == entry.first + int32(position):
            value = replacement
      function.blocks[0].parameters = Span(first: first, count: entry.count - 1)
      for kind in plan.kinds:
        let carrier = if kind == BoolType: UInt8Type else: kind
        let address = emit(SlotAddressOp, [], AddressType)
        resultAddresses.add(address)
        instructions[^1].target = int32(function.slots.len)
        function.slots.add(IrSlot(byteCount: int32(byteCount(carrier, 8)),
          alignment: 8))
        if plan.kinds.len == 1:
          let zero = emit(ConstantOp, [], carrier)
          discard emit(StoreOp, [address, zero], carrier)
    for i, item in old.instructions:
      if item.op == CallOp and plans[item.target].enabled:
        let
          target = plans[item.target]
          returned = ValueId(function.values.len)
          destination = function.operands[item.arguments.first +
            int32(target.parameter)]
        for kind in target.kinds:
          function.values.add(IrValue(valueType: kind))
        var call = item
        call.results = Span(first: int32(returned),
          count: int32(target.kinds.len))
        call.arguments = Span(first: int32(function.operands.len),
          count: item.arguments.count - 1)
        for position in 0 ..< int(item.arguments.count):
          if position != target.parameter:
            function.operands.add(function.operands[item.arguments.first +
              int32(position)])
        # Save the rewritten call in a parallel table indexed by the old pool.
        function.instructions[i] = call
        var address = destination
        if target.kinds.len > 1:
          address = ValueId(function.values.len)
          function.values.add(IrValue(valueType: AddressType))
          let arguments = Span(first: int32(function.operands.len), count: 1)
          function.operands.add(destination)
          transfers[i].add(IrInstruction(op: ConvertOp,
            arguments: arguments, conversion: BitcastConversion,
            results: Span(first: int32(address), count: 1),
            location: item.location))
        for lane in 0 ..< target.kinds.len:
          let arguments = Span(first: int32(function.operands.len), count: 2)
          function.operands.add([address, ValueId(int32(returned) +
            int32(lane))])
          transfers[i].add(IrInstruction(op: StoreOp,
            arguments: arguments, offset: int64(lane * 4), alignment: 1,
            location: item.location))
    for owner, data in old.blocks:
      let first = if owner == 0: 0'i32 else: int32(instructions.len)
      for i in data.instructions.indices:
        var item = function.instructions[i]
        if plan.enabled and item.results.count == 1 and
            item.results.first < plan.addresses.len and
            plan.addresses[item.results.first]:
          continue
        if plan.enabled and item.op == StoreOp and
            plan.addresses[int32(old.operands[item.arguments.first])]:
          let
            lane = plan.stores[i]
            kind = plan.kinds[lane]
            carrier = if kind == BoolType: UInt8Type else: kind
          let value = emit(
            ConvertOp,
            [function.operands[item.arguments.first + 1]],
            carrier,
            item.location
          )
          discard emit(StoreOp, [resultAddresses[lane], value], carrier,
            item.location)
        else:
          instructions.add(item)
        instructions.add(transfers[i])
      if plan.enabled and data.terminator.kind == ReturnTerminator:
        var returned: seq[ValueId]
        for lane, kind in plan.kinds:
          let carrier = if kind == BoolType: UInt8Type else: kind
          var value = emit(LoadOp, [resultAddresses[lane]], carrier)
          if carrier != kind:
            value = emit(ConvertOp, [value], kind)
          returned.add(value)
        function.blocks[owner].terminator.arguments =
          Span(first: int32(function.operands.len), count: int32(returned.len))
        function.operands.add(returned)
      function.blocks[owner].instructions = Span(first: first,
        count: int32(instructions.len) - first)
    function.instructions = move(instructions)
    let operands = function.operands
    function.operands.setLen(0)
    proc repack(span: Span): Span =
      ## Removes unused references to the retired output-pointer parameter.
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

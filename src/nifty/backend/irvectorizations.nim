import std/[sets, tables], irs

type
  FloatPair = object
    a, b, owner, position: int
    op: IrOpcode
    active, parameter: bool

  StorePair = object
    first, last, pair: int

proc vectorizeFloatPairs*(function: var IrFunction,
    divisions = false, sums = false): bool =
  ## Packs profitable float32 expression trees rooted in adjacent stores.
  let old = function
  var
    definitions = newSeq[int](old.values.len)
    owners = newSeq[int](old.instructions.len)
    assignments = newSeq[int](old.values.len)
    parameterOwners = newSeq[int](old.values.len)
    incoming = newSeq[seq[int]](old.blocks.len)
    edgeOwners = newSeq[int](old.edges.len)
    pairs: seq[FloatPair]
    stores: seq[StorePair]
  for item in definitions.mitems:
    item = -1
  for item in parameterOwners.mitems:
    item = -1
  for owner, data in old.blocks:
    for value in data.parameters.indices:
      parameterOwners[value] = owner
    for edge in data.terminator.edges.indices:
      incoming[int(old.edges[edge].target)].add(edge)
      edgeOwners[edge] = owner
    for index in data.instructions.indices:
      owners[index] = owner
      let item = old.instructions[index]
      if item.results.count == 1:
        definitions[item.results.first] = index
  proc input(item: IrInstruction, index: int): int =
    ## Reads one existing scalar operand from the immutable input pools.
    int(old.operands[int(item.arguments.first) + index])
  proc paired(a, b: int): int =
    ## Finds an existing pair only when its lane order matches exactly.
    let index = assignments[a] - 1
    if index >= 0 and pairs[index].a == a and pairs[index].b == b:
      return index
    -1
  proc request(a, b: int): int =
    ## Proposes paired values without crossing observable memory barriers.
    result = paired(a, b)
    if result >= 0:
      return
    if a == b or assignments[a] != 0 or assignments[b] != 0 or
      old.values[a].valueType != Float32Type or
      old.values[b].valueType != Float32Type:
        return -1
    let
      first = definitions[a]
      last = definitions[b]
    if first < 0 and last < 0 and a < b and parameterOwners[a] > 0 and
      parameterOwners[a] == parameterOwners[b]:
        let owner = parameterOwners[a]
        for edge in incoming[owner]:
          if old.blocks[edgeOwners[edge]].terminator.kind in
            {InvokeTerminator, InvokeHostTerminator}:
              return -1
        result = pairs.len
        pairs.add(FloatPair(a: a, b: b, owner: owner, position: -1,
          active: true, parameter: true))
        assignments[a] = result + 1
        assignments[b] = result + 1
        return
    if first < 0 or last < 0 or owners[first] != owners[last]:
      return -1
    let
      left = old.instructions[first]
      right = old.instructions[last]
    if left.op != right.op or left.volatile or right.volatile:
      return -1
    var operation: IrOpcode
    case left.op
    of AddOp: operation = VectorAddOp
    of SubtractOp: operation = VectorSubtractOp
    of MultiplyOp: operation = VectorMultiplyOp
    of DivideOp:
      if not divisions:
        return -1
      operation = VectorDivideOp
    of LoadOp:
      if input(left, 0) != input(right, 0) or
        left.offset > int64.high - 4 or right.offset != left.offset + 4:
          return -1
      for index in min(first, last) + 1 ..< max(first, last):
        let item = old.instructions[index]
        if item.volatile or item.op in {StoreOp, MoveBytesOp, ClearBytesOp,
          CallOp, HostCallOp, IndirectCallOp}:
            return -1
      operation = LoadOp
    else:
      return -1
    result = pairs.len
    pairs.add(FloatPair(a: a, b: b, owner: owners[first],
      position: if operation == LoadOp: min(first, last) else: max(first, last),
      op: operation, active: true))
    assignments[a] = result + 1
    assignments[b] = result + 1
  for data in old.blocks:
    var index = int(data.instructions.first)
    while index + 1 < data.instructions.first + data.instructions.count:
      let
        left = old.instructions[index]
        right = old.instructions[index + 1]
      if left.op == StoreOp and right.op == StoreOp and
        not left.volatile and not right.volatile and
        input(left, 0) == input(right, 0) and
        left.offset <= int64.high - 4 and right.offset == left.offset + 4:
          let pair = request(input(left, 1), input(right, 1))
          if pair >= 0:
            stores.add(StorePair(first: index, last: index + 1, pair: pair))
            inc index
      inc index
  for item in old.instructions:
    if item.op in {AddOp, SubtractOp} and not item.volatile:
      discard request(input(item, 0), input(item, 1))
  var cursor = 0
  while cursor < pairs.len:
    let pair = pairs[cursor]
    inc cursor
    if pair.parameter:
      let first = int(old.blocks[pair.owner].parameters.first)
      for edge in incoming[pair.owner]:
        let arguments = old.edges[edge].arguments
        discard request(
          int(old.operands[int(arguments.first) + pair.a - first]),
          int(old.operands[int(arguments.first) + pair.b - first])
        )
      continue
    if pair.op == LoadOp:
      continue
    let
      left = old.instructions[definitions[pair.a]]
      right = old.instructions[definitions[pair.b]]
    for argument in 0 ..< 2:
      discard request(input(left, argument), input(right, argument))
  if pairs.len == 0:
    return false
  var changed = true
  while changed:
    changed = false
    for index, item in old.instructions:
      let user = if item.results.count == 1:
          assignments[item.results.first] - 1
        else: -1
      let position = if user >= 0 and pairs[user].active:
          pairs[user].position
        else: index
      for argument in item.arguments.indices:
        let pair = assignments[int(old.operands[argument])] - 1
        if pair >= 0 and pairs[pair].active and not pairs[pair].parameter and
          owners[index] == pairs[pair].owner and
          position <= pairs[pair].position:
            pairs[pair].active = false
            changed = true
  proc child(pair, argument: int): int =
    ## Connects matching vector operands while leaving arbitrary scalars alone.
    let data = pairs[pair]
    result = paired(
      input(old.instructions[definitions[data.a]], argument),
      input(old.instructions[definitions[data.b]], argument)
    )
    if result >= 0 and not pairs[result].active:
      result = -1
  proc edgeInputs(pair, edge: int): tuple[a, b: int] =
    ## Reads corresponding scalar columns from one incoming SSA edge.
    let
      data = pairs[pair]
      parameters = old.blocks[data.owner].parameters
      arguments = old.edges[edge].arguments
    result.a = int(old.operands[arguments.first + int32(data.a) -
      parameters.first])
    result.b = int(old.operands[arguments.first + int32(data.b) -
      parameters.first])
  proc edgeChild(pair, edge: int): int =
    ## Finds a vector producer for an incoming pair, including loop cycles.
    let inputs = edgeInputs(pair, edge)
    result = paired(inputs.a, inputs.b)
    if result >= 0 and not pairs[result].active:
      result = -1
  var
    parents = newSeq[int](pairs.len)
    costs = newSeq[int](pairs.len)
    extracted = newSeq[bool](old.values.len)
    storeAt = newSeq[int](old.instructions.len)
    packing = initHashSet[(int, int, int, int)]()
  for i in 0 ..< pairs.len:
    parents[i] = i
  proc root(index: int): int =
    ## Finds a connected expression component for one profitability decision.
    result = index
    while parents[result] != result:
      result = parents[result]
  for i, pair in pairs:
    if not pair.active:
      continue
    if pair.parameter:
      for edge in incoming[pair.owner]:
        let input = edgeChild(i, edge)
        if input >= 0:
          parents[root(input)] = root(i)
      continue
    if pair.op == LoadOp:
      continue
    for argument in 0 ..< 2:
      let input = child(i, argument)
      if input >= 0:
        parents[root(input)] = root(i)
  proc packCost(pair, owner, a, b: int) =
    ## Charges one packing operation per pair and block in each component.
    let key = (root(pair), owner, a, b)
    if key notin packing:
      packing.incl(key)
      inc costs[root(pair)]
  for i, pair in pairs:
    if not pair.active:
      continue
    if pair.parameter:
      for edge in incoming[pair.owner]:
        dec costs[root(i)]
        if edgeChild(i, edge) < 0:
          let inputs = edgeInputs(i, edge)
          packCost(i, edgeOwners[edge], inputs.a, inputs.b)
      continue
    dec costs[root(i)]
    if pair.op != LoadOp:
      for argument in 0 ..< 2:
        if child(i, argument) < 0:
          packCost(i, pair.owner,
            input(old.instructions[definitions[pair.a]], argument),
            input(old.instructions[definitions[pair.b]], argument))
  for i, store in stores:
    if pairs[store.pair].active:
      dec costs[root(store.pair)]
      storeAt[store.first] = i + 1
      storeAt[store.last] = i + 1
  proc observe(value: int) =
    ## Charges each needed scalar extraction once within its producer block.
    let pair = assignments[value] - 1
    if pair >= 0 and pairs[pair].active and not extracted[value]:
      extracted[value] = true
      inc costs[root(pair)]
  for index, item in old.instructions:
    let user = if item.results.count == 1:
        assignments[item.results.first] - 1
      else: -1
    if sums and item.op == AddOp and not item.volatile and
      (user < 0 or not pairs[user].active):
        let source = paired(input(item, 0), input(item, 1))
        if source >= 0 and pairs[source].active:
          continue
    for argument in 0 ..< int(item.arguments.count):
      if storeAt[index] > 0 and argument == 1:
        continue
      let value = input(item, argument)
      if user >= 0 and pairs[user].active and not pairs[user].parameter and
        pairs[user].op != LoadOp:
        let source = child(user, argument)
        if source >= 0 and assignments[value] == source + 1:
          continue
      observe(value)
  for data in old.blocks:
    for index in data.terminator.arguments.indices:
      observe(int(old.operands[index]))
    for index in data.terminator.edges.indices:
      let
        edge = old.edges[index]
        parameters = old.blocks[int(edge.target)].parameters
      for column in 0 ..< int(edge.arguments.count):
        let pair = assignments[int(parameters.first) + column] - 1
        if pair >= 0 and pairs[pair].active and pairs[pair].parameter and
          edgeChild(pair, index) >= 0:
            continue
        observe(int(old.operands[int(edge.arguments.first) + column]))
  var
    vectors = newSeq[ValueId](pairs.len)
    values = old.values
    operands = old.operands
    blocks = old.blocks
    edges = old.edges
    parameterCopies = newSeq[seq[(int, ValueId)]](old.blocks.len)
  for i in 0 ..< pairs.len:
    pairs[i].active = pairs[i].active and costs[root(i)] < 0
    if pairs[i].active:
      result = true
      if not pairs[i].parameter:
        vectors[i] = ValueId(values.len)
        values.add(IrValue(valueType: Float32x2Type))
  if not result:
    return
  for owner, data in old.blocks:
    var rewrite = false
    for value in data.parameters.indices:
      let pair = assignments[value] - 1
      if pair >= 0 and pairs[pair].active and pairs[pair].parameter:
        rewrite = true
    if not rewrite:
      continue
    let first = int32(values.len)
    for value in data.parameters.indices:
      let pair = assignments[value] - 1
      if pair >= 0 and pairs[pair].active and pairs[pair].parameter:
        if value == pairs[pair].a:
          vectors[pair] = ValueId(values.len)
          values.add(IrValue(valueType: Float32x2Type))
      else:
        parameterCopies[owner].add((value, ValueId(values.len)))
        values.add(old.values[value])
    blocks[owner].parameters = Span(first: first,
      count: int32(values.len) - first)
  var instructions: seq[IrInstruction]
  proc arguments(inputs: openArray[ValueId]): Span =
    ## Appends new explicit operands without changing existing scalar spans.
    result = Span(first: int32(operands.len), count: int32(inputs.len))
    operands.add(inputs)
  var packed = initTable[(int, int), ValueId]()
  proc vector(a, b: int): ValueId =
    ## Reuses an available vector or packs scalar boundary values exactly once.
    let pair = paired(a, b)
    if pair >= 0 and pairs[pair].active:
      return vectors[pair]
    if (a, b) in packed:
      return packed.getOrDefault((a, b))
    result = ValueId(values.len)
    values.add(IrValue(valueType: Float32x2Type))
    var item = IrInstruction(op: PackOp, location: NoLocation,
      results: Span(first: int32(result), count: 1))
    if definitions[a] >= 0 and definitions[b] >= 0 and
      old.instructions[definitions[a]].op == ConstantOp and
      old.instructions[definitions[b]].op == ConstantOp:
        item.op = ConstantOp
        let low = old.instructions[definitions[a]].bits and 0xffffffff'u64
        item.bits = low or (old.instructions[definitions[b]].bits shl 32)
    else:
      item.arguments = arguments([ValueId(a), ValueId(b)])
    instructions.add(item)
    packed[(a, b)] = result
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    packed.clear()
    for copy in parameterCopies[owner]:
      instructions.add(IrInstruction(op: ConvertOp,
        conversion: BitcastConversion,
        results: Span(first: int32(copy[0]), count: 1),
        arguments: arguments([copy[1]]), location: NoLocation))
    for value in data.parameters.indices:
      let pair = assignments[value] - 1
      if pair >= 0 and pairs[pair].active and pairs[pair].parameter:
        instructions.add(IrInstruction(op: ExtractOp,
          results: Span(first: int32(value), count: 1),
          arguments: arguments([vectors[pair]]),
          target: int32(ord(value == pairs[pair].b)), location: NoLocation))
    for index in data.instructions.indices:
      let item = old.instructions[index]
      let pair = if item.results.count == 1:
          assignments[item.results.first] - 1
        else: -1
      if pair >= 0 and pairs[pair].active:
        let group = pairs[pair]
        if index != group.position:
          continue
        let
          left = old.instructions[definitions[group.a]]
          right = old.instructions[definitions[group.b]]
        var merged = left
        merged.op = group.op
        merged.results = Span(first: int32(vectors[pair]), count: 1)
        if group.op != LoadOp:
          let
            a = vector(input(left, 0), input(right, 0))
            b = vector(input(left, 1), input(right, 1))
          merged.arguments = arguments([a, b])
        instructions.add(merged)
        for lane, value in [group.a, group.b]:
          instructions.add(IrInstruction(op: ExtractOp,
            results: Span(first: int32(value), count: 1),
            arguments: arguments([vectors[pair]]), target: int32(lane),
            location: left.location))
      elif storeAt[index] > 0 and
        pairs[stores[storeAt[index] - 1].pair].active:
          let store = stores[storeAt[index] - 1]
          if index == store.first:
            continue
          var merged = old.instructions[store.first]
          merged.arguments = arguments(
            [ValueId(input(merged, 0)), vectors[store.pair]]
          )
          instructions.add(merged)
      else:
        instructions.add(item)
    for index in data.terminator.edges.indices:
      let edge = old.edges[index]
      let owner = int(edge.target)
      if blocks[owner].parameters == old.blocks[owner].parameters:
        continue
      var inputs: seq[ValueId]
      for column in 0 ..< int(old.blocks[owner].parameters.count):
        let
          value = int(old.blocks[owner].parameters.first) + column
          pair = assignments[value] - 1
        if pair >= 0 and pairs[pair].active and pairs[pair].parameter:
          if value == pairs[pair].a:
            let source = edgeInputs(pair, index)
            inputs.add(vector(source.a, source.b))
        else:
          inputs.add(old.operands[int(edge.arguments.first) + column])
      edges[index].arguments = arguments(inputs)
    # Edge packs do not depend on the boolean predicate. Keep its comparison
    # next to the branch so every backend can consume the predicate directly.
    if data.instructions.count > 0 and
      data.terminator.kind == BranchTerminator:
        let last = old.instructions[
          data.instructions.first + data.instructions.count - 1]
        if last.op == CompareOp and not last.volatile and
          last.results.count == 1 and last.results.first ==
          int32(old.operands[data.terminator.arguments.first]):
            var position = instructions.high
            while position >= int(first) and
              instructions[position].op in {ConstantOp, PackOp}:
                dec position
            if position >= int(first) and position < instructions.high and
              instructions[position].op == CompareOp and
              instructions[position].results == last.results:
                let comparison = instructions[position]
                instructions.delete(position)
                instructions.add(comparison)
    blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.values = move(values)
  function.operands = move(operands)
  function.blocks = move(blocks)
  function.edges = move(edges)
  function.instructions = move(instructions)

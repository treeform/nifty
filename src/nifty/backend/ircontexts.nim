import context, irs, irchecks

type ContextState = enum
  UnknownContext, ExactContext, OtherContext

proc analyzeContexts(function: IrFunction,
    pointerBytes = 8'i32): seq[bool] {.raises: [].} =
  ## Finds exact context-pointer aliases in previously verified 64-bit IR.
  result = newSeq[bool](function.values.len)
  if pointerBytes != 8 or function.signature.parameters.len == 0 or
      function.signature.parameters[0] != AddressType or
      function.blocks.len == 0 or function.blocks[0].parameters.count == 0:
      return
  const Representations = {AddressType, UInt64Type, Int64Type}
  var
    parents = newSeq[seq[int]](function.values.len)
    users = newSeq[seq[int]](function.values.len)
    states = newSeq[ContextState](function.values.len)
    pending: seq[int]
    queued = newSeq[bool](function.values.len)
  for state in states.mitems:
    state = OtherContext
  for owner, data in function.blocks:
    if owner > 0:
      for value in data.parameters.indices:
        if function.values[value].valueType in Representations:
          states[value] = UnknownContext
    for i in data.instructions.indices:
      let item = function.instructions[i]
      if item.op == ConvertOp and item.conversion == BitcastConversion and
          item.arguments.count == 1 and item.results.count == 1:
          let
            input = int(int32(function.operands[item.arguments.first]))
            output = int(item.results.first)
          if function.values[input].valueType in Representations and
              function.values[output].valueType in Representations:
              states[output] = UnknownContext
              parents[output].add(input)
    for i in data.terminator.edges.indices:
      let
        edge = function.edges[i]
        parameters = function.blocks[int32(edge.target)].parameters
      for j in 0 ..< int(edge.arguments.count):
        let value = int(parameters.first) + j
        if function.values[value].valueType in Representations:
          parents[value].add(int(int32(
            function.operands[int(edge.arguments.first) + j]
          )))
  let root = int(function.blocks[0].parameters.first)
  states[root] = ExactContext
  for value in 0 ..< parents.len:
    if states[value] == UnknownContext:
      if parents[value].len == 0:
        states[value] = OtherContext
      else:
        pending.add(value)
        queued[value] = true
        for parent in parents[value]:
          users[parent].add(value)
  proc propagate() =
    ## Resolves forwarding cycles until no dependent classification changes.
    while pending.len > 0:
      let value = pending.pop()
      queued[value] = false
      var state = UnknownContext
      for parent in parents[value]:
        state = max(state, states[parent])
      if state > states[value]:
        states[value] = state
        for user in users[value]:
          if not queued[user]:
            pending.add(user)
            queued[user] = true
  propagate()
  for value in 0 ..< states.len:
    if states[value] == UnknownContext:
      states[value] = OtherContext
      for user in users[value]:
        if not queued[user]:
          pending.add(user)
          queued[user] = true
  propagate()
  for value in 0 ..< result.len:
    result[value] = states[value] == ExactContext

proc contextAliases*(function: IrFunction,
    pointerBytes = 8'i32): seq[bool] {.raises: [].} =
  ## Selects shared context bindings independently of ordinary allocation.
  when defined(nimkeyNoContextAliases):
    newSeq[bool](function.values.len)
  else:
    analyzeContexts(function, pointerBytes)

proc removableContextLoads*(module: IrModule, function: IrFunction): seq[bool]
    {.raises: [].} =
  ## Proves nonvolatile reads stay inside the live runtime context object.
  if module.pointerBytes != 8 or
    function.signature.parameterStorage.len == 0 or
    function.signature.parameters.len == 0 or
    function.signature.parameters[0] != AddressType:
      return
  let storage = function.signature.parameterStorage[0]
  if storage <= 0 or storage > module.storageTypes.len:
    return
  let shape = module.storageTypes[storage - 1]
  if shape.kind != OpaqueStorage or shape.name != "$runtime.context":
    return
  let
    aliases = analyzeContexts(function, module.pointerBytes)
    bytes = min(int64(shape.byteCount), int64(sizeof(RuntimeContext)))
  result = newSeq[bool](function.instructions.len)
  for index, item in function.instructions:
    if item.op != LoadOp or item.volatile or item.arguments.count != 1 or
      item.results.count != 1:
        continue
    let width = byteCount(function.values[item.results.first].valueType,
      module.pointerBytes)
    result[index] = aliases[int32(function.operands[item.arguments.first])] and
      item.offset >= 0 and item.offset <= bytes - width

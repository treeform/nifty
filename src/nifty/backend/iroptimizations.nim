import std/tables, irs, irchecks, irconstants, irmotions, irmaterializations,
  irscalarizations, ircalls, irreturns, irforwarding, iraddresses, irarguments,
  irdominators, irpredicates, irconditions, irregions, irstores,
  irrematerializations, irselects, irdivisions, irremainders, irbooleans,
  irvectorizations, irreductions, irsinkings, ircontexts, irinductions, irorders,
  irprocedures, ircarriers, iraffines

type IrOptimization* = enum
  ReuseIrExpressions, RemoveIrDeadValues, ReuseIrLoads,
  RemoveIrIdentities, SimplifyIrParameters, ThreadIrJumps,
  MergeIrBlocks, ForwardIrStores, FoldIrConstants, HoistIrInvariants,
  PromoteIrSlots, SimplifyIrConversions, ReuseIrDominating, PromoteIrArguments,
  PromoteIrReturns, ForwardIrFields, FoldIrAddresses, RemoveIrArguments,
  FoldIrPredicates, PreserveIrFloatSlots, SimplifyIrConditions, ForwardIrRegions,
  RemoveIrStores, RematerializeIrAddresses, RematerializeIrConstants,
  SeparateIrTemporaries, PromoteIrRecordReturns, FoldIrConversions,
  PromoteIrWideArguments, MergeIrParameters, SelectIrValues, FoldIrAddressRoots,
  ReduceIrDivisions, ReduceIrRemainders, CacheIrArguments, SimplifyIrBooleans,
  VectorizeIrFloatPairs, VectorizeIrFloatDivisions, FoldIrFloatSums, SinkIrLoads,
  FoldIrBranches, RemoveIrContextLoads, HoistIrAddresses, ScaleIrInductions,
  SettleIrBranches, OrderIrBlocks, PruneIrProcedures, PreserveIrFloatParameters,
  ReuseIrAddresses

const DefaultIrOptimizations* = {
  ReuseIrExpressions, ReuseIrLoads, RemoveIrDeadValues,
  RemoveIrIdentities, SimplifyIrParameters, ThreadIrJumps,
  MergeIrBlocks, ForwardIrStores, FoldIrConstants, HoistIrInvariants,
  PromoteIrSlots, SimplifyIrConversions, ReuseIrDominating, PromoteIrArguments,
  PromoteIrReturns, PromoteIrRecordReturns, ForwardIrFields, FoldIrAddresses,
  RemoveIrArguments,
  FoldIrPredicates, PreserveIrFloatSlots, SimplifyIrConditions, ForwardIrRegions,
  RemoveIrStores, RematerializeIrAddresses, RematerializeIrConstants,
  SeparateIrTemporaries, MergeIrParameters, ReduceIrRemainders, CacheIrArguments,
  SinkIrLoads, FoldIrBranches, RemoveIrContextLoads, HoistIrAddresses,
  FoldIrAddressRoots, ReduceIrDivisions, SimplifyIrBooleans,
  ScaleIrInductions, SettleIrBranches, OrderIrBlocks,
  PreserveIrFloatParameters, ReuseIrAddresses
}

const ModuleIrOptimizations = {
  PromoteIrArguments, PromoteIrReturns, ForwardIrFields, RemoveIrArguments,
  RematerializeIrAddresses, RematerializeIrConstants, PromoteIrRecordReturns,
  PromoteIrWideArguments, CacheIrArguments, VectorizeIrFloatPairs,
  VectorizeIrFloatDivisions, FoldIrFloatSums, SinkIrLoads, FoldIrBranches,
  RemoveIrContextLoads, HoistIrAddresses, ScaleIrInductions, SettleIrBranches,
  OrderIrBlocks, PruneIrProcedures, PreserveIrFloatParameters, ReuseIrAddresses
}

proc dependencies*(pass: IrOptimization): set[IrOptimization] =
  ## Declares prerequisite normalization stages for dependent IR passes.
  case pass
  of FoldIrAddresses: {SimplifyIrConversions}
  of ReuseIrAddresses: {FoldIrAddresses, RemoveIrDeadValues}
  of FoldIrAddressRoots: {FoldIrAddresses, RemoveIrDeadValues}
  of FoldIrConversions, ReduceIrDivisions: {FoldIrConstants}
  of PromoteIrWideArguments: {PromoteIrArguments}
  of MergeIrParameters: {SimplifyIrParameters}
  of SelectIrValues:
    {MergeIrParameters, RemoveIrIdentities, RemoveIrDeadValues}
  of PreserveIrFloatSlots: {PromoteIrSlots}
  of RematerializeIrAddresses, RematerializeIrConstants: {RemoveIrDeadValues}
  of SeparateIrTemporaries: {PromoteIrSlots, RemoveIrDeadValues}
  of PromoteIrRecordReturns:
    {PromoteIrReturns, FoldIrAddresses, PromoteIrSlots, RemoveIrDeadValues}
  of VectorizeIrFloatPairs: {FoldIrAddresses, RemoveIrDeadValues}
  of VectorizeIrFloatDivisions: {VectorizeIrFloatPairs}
  of FoldIrFloatSums: {RemoveIrDeadValues}
  of RemoveIrContextLoads: {RemoveIrDeadValues}
  of ScaleIrInductions: {SimplifyIrConversions, RemoveIrDeadValues}
  of PreserveIrFloatParameters: {SimplifyIrConversions, RemoveIrDeadValues}
  of SettleIrBranches:
    {ThreadIrJumps, FoldIrBranches, MergeIrBlocks, RemoveIrDeadValues}
  else: {}

proc effectiveIrOptimizations*(requested: set[IrOptimization]):
    set[IrOptimization] =
  ## Disables dependent passes transitively when a prerequisite is absent.
  result = requested
  when defined(nimkeyNoFloatPairs):
    result.excl(VectorizeIrFloatPairs)
  when defined(nimkeyNoFloatPairDivisions):
    result.excl(VectorizeIrFloatDivisions)
  when defined(nimkeyNoFloatSums):
    result.excl(FoldIrFloatSums)
  when defined(nimkeyNoIrContextLoads):
    result.excl(RemoveIrContextLoads)
  when defined(nimkeyNoIrScaledLoops):
    result.excl(ScaleIrInductions)
  when defined(nimkeyNoIrBranchCleanup):
    result.excl(SettleIrBranches)
  when defined(nimkeyNoIrBlockOrder):
    result.excl(OrderIrBlocks)
  when defined(nimkeyNoIrProcedures):
    result.excl(PruneIrProcedures)
  when defined(nimkeyNoIrFloatParameters):
    result.excl(PreserveIrFloatParameters)
  when defined(nimkeyNoIrAffineAddresses):
    result.excl(ReuseIrAddresses)
  var changed = true
  while changed:
    changed = false
    for pass in IrOptimization:
      if pass in result and dependencies(pass) - result != {}:
        result.excl(pass)
        changed = true

proc identityAliases(function: IrFunction): seq[ValueId] =
  ## Starts an explicit value substitution table without any replacements.
  result = newSeq[ValueId](function.values.len)
  for i in 0 ..< function.values.len:
    result[i] = ValueId(i)

proc resolve(aliases: seq[ValueId], value: ValueId): ValueId =
  ## Follows substitutions to their surviving SSA definition.
  result = value
  while int32(aliases[int32(result)]) != int32(result):
    result = aliases[int32(result)]

proc compact(function: var IrFunction, aliases: seq[ValueId]) =
  ## Rebuilds reachable pools and removes substituted block parameters.
  let old = function
  var
    reachable = newSeq[bool](old.blocks.len)
    pending = @[0]
    mapping = newSeq[ValueId](old.values.len)
    blocks = newSeq[int](old.blocks.len)
    rebuilt = IrFunction(name: old.name, signature: old.signature,
      failureMode: old.failureMode, directOnly: old.directOnly, slots: old.slots)
  while pending.len > 0:
    let owner = pending.pop()
    if reachable[owner]:
      continue
    reachable[owner] = true
    for i in old.blocks[owner].terminator.edges.indices:
      pending.add(int(int32(old.edges[i].target)))
  proc define(span: Span, parameters = false): Span =
    ## Keeps result spans contiguous while dropping replaced parameters.
    result.first = int32(rebuilt.values.len)
    for i in span.indices:
      if not parameters or int32(aliases.resolve(ValueId(i))) == i:
        mapping[i] = ValueId(rebuilt.values.len)
        rebuilt.values.add(old.values[i])
        inc result.count
  for owner, data in old.blocks:
    if not reachable[owner]:
      continue
    blocks[owner] = rebuilt.blocks.len
    var target = data
    target.parameters = define(data.parameters, owner > 0)
    target.instructions.first = int32(rebuilt.instructions.len)
    for i in data.instructions.indices:
      var instruction = old.instructions[i]
      instruction.results = define(instruction.results)
      rebuilt.instructions.add(instruction)
    target.terminator.results = define(data.terminator.results)
    rebuilt.blocks.add(target)
  proc operands(span: Span, target = -1): Span =
    ## Rewrites uses and removes the matching incoming parameter positions.
    result.first = int32(rebuilt.operands.len)
    for i in 0 ..< int(span.count):
      let parameter = if target < 0: -1
        else: int(old.blocks[target].parameters.first) + i
      if target < 0 or
          int32(aliases.resolve(ValueId(parameter))) == parameter:
        rebuilt.operands.add(mapping[int32(aliases.resolve(
          old.operands[int(span.first) + i]))])
        inc result.count
  for instruction in rebuilt.instructions.mitems:
    instruction.arguments = operands(instruction.arguments)
  for data in rebuilt.blocks.mitems:
    data.terminator.arguments = operands(data.terminator.arguments)
    let edges = data.terminator.edges
    data.terminator.edges.first = int32(rebuilt.edges.len)
    for i in edges.indices:
      let edge = old.edges[i]
      rebuilt.edges.add(IrEdge(target: BlockId(blocks[int32(edge.target)]),
        arguments: operands(edge.arguments, int(int32(edge.target)))))
  function = move(rebuilt)

proc foldConstants(function: var IrFunction, conversions: bool) =
  ## Materializes proven constants and prunes statically selected successors.
  let facts = constantValues(function, conversions)
  var
    aliases = function.identityAliases()
    instructions: seq[IrInstruction]
  for data in function.blocks.mitems:
    let first = instructions.len
    for value in data.parameters.indices:
      if facts.known[value]:
        let replacement = ValueId(function.values.len)
        function.values.add(function.values[value])
        aliases.add(replacement)
        aliases[value] = replacement
        instructions.add(IrInstruction(op: ConstantOp,
          results: Span(first: int32(replacement), count: 1),
          bits: facts.bits[value], location: NoLocation))
    for i in data.instructions.indices:
      var instruction = function.instructions[i]
      if instruction.results.count == 1 and facts.known[instruction.results.first]:
        instruction.op = ConstantOp
        instruction.bits = facts.bits[instruction.results.first]
        instruction.arguments = Span()
      instructions.add(instruction)
    data.instructions = Span(first: int32(first),
      count: int32(instructions.len - first))
    if data.terminator.kind == BranchTerminator:
      let condition = int32(function.operands[data.terminator.arguments.first])
      if facts.known[condition]:
        let edge = data.terminator.edges.first + ord(facts.bits[condition] == 0)
        data.terminator.kind = JumpTerminator
        data.terminator.arguments = Span()
        data.terminator.edges = Span(first: int32(edge), count: 1)
  function.instructions = move(instructions)
  function.compact(aliases)

proc removeIdentities(function: var IrFunction) =
  ## Removes exact integer and selection identities without changing bits.
  var
    aliases = function.identityAliases()
    constants = newSeq[bool](function.values.len)
    bits = newSeq[uint64](function.values.len)
    instructions: seq[IrInstruction]
  for instruction in function.instructions:
    if instruction.op == ConstantOp:
      constants[instruction.results.first] = true
      bits[instruction.results.first] = instruction.bits
  for data in function.blocks.mitems:
    let first = instructions.len
    for i in data.instructions.indices:
      let instruction = function.instructions[i]
      var replacement = NoValue
      if instruction.op == SelectOp:
        let
          first = instruction.arguments.first
          condition = aliases.resolve(function.operands[first])
          yes = aliases.resolve(function.operands[first + 1])
          no = aliases.resolve(function.operands[first + 2])
        if int32(yes) == int32(no):
          replacement = yes
        elif constants[int32(condition)]:
          replacement = if bits[int32(condition)] != 0: yes else: no
      if instruction.results.count == 1 and
          instruction.arguments.count == 2 and
          function.values[instruction.results.first].valueType in
            {CharType, Int8Type .. UInt64Type}:
        let
          a = aliases.resolve(function.operands[instruction.arguments.first])
          b = aliases.resolve(function.operands[instruction.arguments.first + 1])
          zeroA = constants[int32(a)] and bits[int32(a)] == 0
          zeroB = constants[int32(b)] and bits[int32(b)] == 0
          oneA = constants[int32(a)] and bits[int32(a)] == 1
          oneB = constants[int32(b)] and bits[int32(b)] == 1
        case instruction.op
        of AddOp, OrOp, XorOp:
          if zeroA:
            replacement = b
          elif zeroB:
            replacement = a
        of SubtractOp, ShiftLeftOp, ShiftRightOp, ArithmeticRightOp:
          if zeroB:
            replacement = a
        of MultiplyOp:
          if oneA:
            replacement = b
          elif oneB:
            replacement = a
        of DivideOp:
          if oneB:
            replacement = a
        of AndOp:
          if int32(a) == int32(b):
            replacement = a
        else:
          discard
      if int32(replacement) >= 0:
        aliases[instruction.results.first] = replacement
      else:
        instructions.add(instruction)
    data.instructions = Span(first: int32(first),
      count: int32(instructions.len - first))
  function.instructions = move(instructions)
  function.compact(aliases)

proc simplifyParameters(function: var IrFunction) =
  ## Removes trivial parameters and cycles with one external SSA value.
  function.compact(function.identityAliases())
  let count = function.values.len
  var
    aliases = function.identityAliases()
    parameter = newSeq[bool](count)
    invoked = newSeq[bool](count)
    inputs = newSeq[seq[int]](count)
    outputs = newSeq[seq[int]](count)
    visited = newSeq[bool](count)
    order: seq[int]
  for owner in 1 ..< function.blocks.len:
    for i in function.blocks[owner].parameters.indices:
      parameter[i] = true
  for data in function.blocks:
    for i in data.terminator.results.indices:
      invoked[i] = true
    for i in data.terminator.edges.indices:
      let edge = function.edges[i]
      for j in 0 ..< int(edge.arguments.count):
        let
          target = int(function.blocks[int32(edge.target)].parameters.first) + j
          source = int(int32(function.operands[int(edge.arguments.first) + j]))
        inputs[target].add(source)
        if parameter[source]:
          outputs[source].add(target)
  # A changing cycle can still contain blocks that only forward its state.
  # Remove those individual copies before classifying the whole cycle.
  when not defined(nimkeyNoIrTrivialParameters):
    var changed = true
    while changed:
      changed = false
      for value in 0 ..< count:
        if not parameter[value] or int32(aliases[value]) != value:
          continue
        var
          candidate = NoValue
          conflict = false
        for input in inputs[value]:
          let external = aliases.resolve(ValueId(input))
          if int32(external) == value:
            continue
          if invoked[int32(external)]:
            conflict = true
          if int32(candidate) < 0:
            candidate = external
          elif int32(candidate) != int32(external):
            conflict = true
        if not conflict and int32(candidate) >= 0:
          aliases[value] = candidate
          changed = true
  for root in 0 ..< count:
    if not parameter[root] or visited[root]:
      continue
    var pending = @[(root, false)]
    while pending.len > 0:
      let (value, finished) = pending.pop()
      if finished:
        order.add(value)
      elif not visited[value]:
        visited[value] = true
        pending.add((value, true))
        for input in inputs[value]:
          if parameter[input]:
            pending.add((input, false))
  var
    components = newSeq[int](count)
    groups: seq[seq[int]]
  for item in components.mitems:
    item = -1
  for i in countdown(order.high, 0):
    let root = order[i]
    if components[root] >= 0:
      continue
    let group = groups.len
    groups.add(@[])
    var pending = @[root]
    while pending.len > 0:
      let value = pending.pop()
      if components[value] >= 0:
        continue
      components[value] = group
      groups[group].add(value)
      for output in outputs[value]:
        pending.add(output)
  for group in countdown(groups.high, 0):
    var
      candidate = NoValue
      conflict = false
    for value in groups[group]:
      for input in inputs[value]:
        if components[input] == group:
          continue
        let external = aliases.resolve(ValueId(input))
        if invoked[int32(external)]:
          conflict = true
        if int32(candidate) < 0:
          candidate = external
        elif int32(candidate) != int32(external):
          conflict = true
    if not conflict and int32(candidate) >= 0:
      for value in groups[group]:
        aliases[value] = candidate
  function.compact(aliases)

proc mergeParameters(function: var IrFunction) =
  ## Shares parameters whose typed incoming columns match on every edge.
  function.compact(function.identityAliases())
  var
    aliases = function.identityAliases()
    incoming = newSeq[seq[int]](function.blocks.len)
  for data in function.blocks:
    for index in data.terminator.edges.indices:
      incoming[int32(function.edges[index].target)].add(index)
  var changed = true
  while changed:
    changed = false
    for owner in 1 ..< function.blocks.len:
      let parameters = function.blocks[owner].parameters
      if incoming[owner].len == 0 or parameters.count < 2:
        continue
      var columns = initTable[seq[int32], ValueId]()
      for value in parameters.indices:
        if int32(aliases.resolve(ValueId(value))) != value:
          continue
        let info = function.values[value]
        var column = @[int32(ord(info.valueType)), info.storage]
        for index in incoming[owner]:
          let edge = function.edges[index]
          let input = function.operands[
            edge.arguments.first + int32(value) - parameters.first]
          column.add(int32(aliases.resolve(input)))
        if columns.hasKey(column):
          aliases[value] = columns.getOrDefault(column)
          changed = true
        else:
          columns[column] = ValueId(value)
  function.compact(aliases)

proc threadJumps(function: var IrFunction) =
  ## Composes typed edge arguments through effectless jump blocks.
  let old = function
  var
    visited = newSeq[int](old.blocks.len)
    parameterOwners = newSeq[int](old.values.len)
    escapes = newSeq[bool](old.blocks.len)
  for item in parameterOwners.mitems:
    item = -1
  for owner, data in old.blocks:
    for i in data.parameters.indices:
      parameterOwners[i] = owner
  proc track(span: Span, owner: int) =
    ## Retains forwarding blocks whose definitions have nonlocal uses.
    for i in span.indices:
      let source = parameterOwners[int32(old.operands[i])]
      if source >= 0 and source != owner:
        escapes[source] = true
  for owner, data in old.blocks:
    for i in data.instructions.indices:
      track(old.instructions[i].arguments, owner)
    track(data.terminator.arguments, owner)
    for i in data.terminator.edges.indices:
      track(old.edges[i].arguments, owner)
  for index in 0 ..< old.edges.len:
    var
      edge = old.edges[index]
      arguments: seq[ValueId]
    for i in edge.arguments.indices:
      arguments.add(old.operands[i])
    while true:
      let
        target = int(int32(edge.target))
        data = old.blocks[target]
      if visited[target] == index + 1 or escapes[target] or
          data.instructions.count != 0 or
          data.terminator.kind != JumpTerminator:
        break
      visited[target] = index + 1
      let next = old.edges[data.terminator.edges.first]
      var forwarded: seq[ValueId]
      for i in next.arguments.indices:
        let value = old.operands[i]
        if int32(value) in data.parameters.first ..<
            data.parameters.first + data.parameters.count:
          forwarded.add(arguments[int32(value) - data.parameters.first])
        else:
          forwarded.add(value)
      arguments = move(forwarded)
      edge.target = next.target
    edge.arguments = Span(first: int32(function.operands.len),
      count: int32(arguments.len))
    function.operands.add(arguments)
    function.edges[index] = edge
  function.compact(function.identityAliases())

proc mergeBlocks(function: var IrFunction) =
  ## Joins unique jump successors and substitutes their parallel arguments.
  function.compact(function.identityAliases())
  let old = function
  var
    predecessors = newSeq[int](old.blocks.len)
    consumed = newSeq[bool](old.blocks.len)
    aliases = old.identityAliases()
    instructions: seq[IrInstruction]
  for edge in old.edges:
    inc predecessors[int32(edge.target)]
  for owner in 0 ..< old.blocks.len:
    if consumed[owner]:
      continue
    let first = instructions.len
    var current = owner
    while true:
      let data = old.blocks[current]
      for i in data.instructions.indices:
        instructions.add(old.instructions[i])
      function.blocks[owner].terminator = data.terminator
      if data.terminator.kind != JumpTerminator:
        break
      let
        edge = old.edges[data.terminator.edges.first]
        target = int(int32(edge.target))
      if target <= owner or consumed[target] or predecessors[target] != 1:
        break
      consumed[target] = true
      for i in 0 ..< int(edge.arguments.count):
        aliases[int(old.blocks[target].parameters.first) + i] =
          aliases.resolve(old.operands[int(edge.arguments.first) + i])
      current = target
    function.blocks[owner].instructions = Span(first: int32(first),
      count: int32(instructions.len - first))
  function.instructions = move(instructions)
  function.compact(aliases)

proc pure(op: IrOpcode): bool {.raises: [].} =
  ## Identifies scalar operations whose checks were already made explicit.
  op in {ConstantOp, AddOp, SubtractOp, MultiplyOp, MultiplyHighOp, DivideOp, RemainderOp,
    NegateOp, AndOp, OrOp, XorOp, NotOp, ShiftLeftOp, ShiftRightOp,
    ArithmeticRightOp, CompareOp, SelectOp, ConvertOp, SqrtOp, FloorOp, RoundOp,
    FieldAddressOp,
    SlotAddressOp, GlobalAddressOp, OffsetAddressOp, FrameSizeOp,
    PackOp, ExtractOp, VectorAddOp, VectorSubtractOp, VectorMultiplyOp,
    VectorDivideOp, VectorSumOp}

proc reuse(function: var IrFunction) =
  ## Reuses identical scalar instructions within one basic block.
  var
    aliases = function.identityAliases()
    instructions: seq[IrInstruction]
    seen = initTable[tuple[op: IrOpcode, kind: IrType, bits: uint64,
      comparison: IrComparison, conversion: IrConversion,
      count: int32, a, b, target, storage: int32, offset: int64], int32]()
  for data in function.blocks.mitems:
    let first = instructions.len
    seen.clear()
    for i in data.instructions.indices:
      let instruction = function.instructions[i]
      for j in instruction.arguments.indices:
        function.operands[j] = aliases[int32(function.operands[j])]
      var shared = false
      if instruction.op.pure() and instruction.results.count == 1 and
          instruction.arguments.count <= 2:
        let
          count = instruction.arguments.count
          first = instruction.arguments.first
          key = (instruction.op,
            function.values[instruction.results.first].valueType,
            instruction.bits, instruction.comparison, instruction.conversion,
            count, if count > 0: int32(function.operands[first]) else: -1'i32,
            if count > 1: int32(function.operands[first + 1]) else: -1'i32,
            instruction.target,
            function.values[instruction.results.first].storage,
            instruction.offset)
        if seen.hasKey(key):
          aliases[instruction.results.first] = ValueId(seen.getOrDefault(key))
          shared = true
        else:
          seen[key] = instruction.results.first
      if not shared:
        instructions.add(instruction)
    data.instructions = Span(first: int32(first),
      count: int32(instructions.len - first))
  function.instructions = move(instructions)
  for value in function.operands.mitems:
    value = aliases[int32(value)]

proc reuseLoads(function: var IrFunction, hosts: seq[IrHost]) =
  ## Reuses address calculations and ordinary reads until a memory barrier.
  var
    aliases = function.identityAliases()
    instructions: seq[IrInstruction]
    addresses = initTable[tuple[op: IrOpcode, base, target, storage: int32,
      offset: int64], int32]()
    loads = initTable[tuple[address: int32, offset: int64, alignment: int32,
      kind: IrType, storage: int32], int32]()
  for data in function.blocks.mitems:
    let first = instructions.len
    addresses.clear()
    loads.clear()
    for i in data.instructions.indices:
      let instruction = function.instructions[i]
      for j in instruction.arguments.indices:
        function.operands[j] = aliases[int32(function.operands[j])]
      var shared = false
      if instruction.results.count == 1:
        let value = function.values[instruction.results.first]
        if instruction.op in {FieldAddressOp, SlotAddressOp, GlobalAddressOp}:
          let
            base = if instruction.arguments.count == 0: -1'i32
              else: int32(function.operands[instruction.arguments.first])
            key = (instruction.op, base, instruction.target, value.storage,
              instruction.offset)
          if addresses.hasKey(key):
            aliases[instruction.results.first] =
              ValueId(addresses.getOrDefault(key))
            shared = true
          else:
            addresses[key] = instruction.results.first
        elif instruction.op == LoadOp and not instruction.volatile:
          let key = (int32(function.operands[instruction.arguments.first]),
            instruction.offset, instruction.alignment, value.valueType,
            value.storage)
          if loads.hasKey(key):
            aliases[instruction.results.first] = ValueId(loads.getOrDefault(key))
            shared = true
          else:
            loads[key] = instruction.results.first
      let readonlyCall = instruction.op == HostCallOp and
        hosts[instruction.target].effects.known and
        not hosts[instruction.target].effects.writesMemory
      if instruction.volatile or
          (not instruction.op.pure() and instruction.op != LoadOp and
          not readonlyCall):
        loads.clear()
      if not shared:
        instructions.add(instruction)
    data.instructions = Span(first: int32(first),
      count: int32(instructions.len - first))
  function.instructions = move(instructions)
  for value in function.operands.mitems:
    value = aliases[int32(value)]

proc forwardStores(function: var IrFunction, hosts: seq[IrHost]) =
  ## Forwards exact typed stores until a possibly aliasing memory effect.
  var
    aliases = function.identityAliases()
    instructions: seq[IrInstruction]
    addresses = initTable[tuple[op: IrOpcode, base, target, storage: int32,
      offset: int64], ValueId]()
    stores = initTable[tuple[address: int32, offset: int64, alignment: int32,
      kind: IrType, storage: int32], ValueId]()
  for data in function.blocks.mitems:
    let first = instructions.len
    addresses.clear()
    stores.clear()
    for i in data.instructions.indices:
      let instruction = function.instructions[i]
      for j in instruction.arguments.indices:
        function.operands[j] = aliases.resolve(function.operands[j])
      var replacement = NoValue
      if instruction.op in {FieldAddressOp, SlotAddressOp, GlobalAddressOp}:
        let
          value = function.values[instruction.results.first]
          base = if instruction.arguments.count == 0: -1'i32
            else: int32(function.operands[instruction.arguments.first])
          key = (instruction.op, base, instruction.target, value.storage,
              instruction.offset)
        if addresses.hasKey(key):
          replacement = addresses.getOrDefault(key)
        else:
          addresses[key] = ValueId(instruction.results.first)
      elif instruction.op == StoreOp:
        stores.clear()
        let
          source = function.operands[instruction.arguments.first + 1]
          value = function.values[int32(source)]
        if not instruction.volatile and value.valueType != BoolType:
          stores[(int32(function.operands[instruction.arguments.first]),
            instruction.offset, instruction.alignment, value.valueType,
            value.storage)] = source
      elif instruction.op == LoadOp and not instruction.volatile:
        let
          value = function.values[instruction.results.first]
          key = (int32(function.operands[instruction.arguments.first]),
            instruction.offset, instruction.alignment, value.valueType,
            value.storage)
        if stores.hasKey(key):
          replacement = stores.getOrDefault(key)
      let readonlyCall = instruction.op == HostCallOp and
        hosts[instruction.target].effects.known and
        not hosts[instruction.target].effects.writesMemory
      if instruction.volatile or
          (not instruction.op.pure() and
          instruction.op notin {LoadOp, StoreOp} and not readonlyCall):
        stores.clear()
      if int32(replacement) >= 0:
        aliases[instruction.results.first] = replacement
      else:
        instructions.add(instruction)
    data.instructions = Span(first: int32(first),
      count: int32(instructions.len - first))
  function.instructions = move(instructions)
  function.compact(aliases)

proc removeDead(function: var IrFunction, removableLoads: seq[bool] = @[]) =
  ## Traces observable roots through instructions and incoming block values.
  let old = function
  doAssert removableLoads.len == 0 or removableLoads.len == old.instructions.len
  proc removable(index: int): bool =
    ## Includes only memory reads whose validity was established separately.
    let item = old.instructions[index]
    (item.op.pure() and item.op notin {DivideOp, RemainderOp} and
      not (item.op == ConvertOp and
        item.conversion == FloatIntegerConversion)) or
      (removableLoads.len > 0 and removableLoads[index])
  var
    live = newSeq[bool](old.values.len)
    definitions = newSeq[int](old.values.len)
    parameters = newSeq[int](old.values.len)
    work: seq[int]
    reachable = newSeq[bool](old.blocks.len)
    blocks = @[0]
  for item in definitions.mitems:
    item = -1
  for item in parameters.mitems:
    item = -1
  proc mark(value: ValueId) =
    ## Adds a newly required virtual register to the backwards worklist.
    let index = int32(value)
    if not live[index]:
      live[index] = true
      work.add(int(index))
  proc markOperands(span: Span) =
    ## Marks values consumed by one retained effect or live instruction.
    for i in span.indices:
      mark(old.operands[i])
  while blocks.len > 0:
    let index = blocks.pop()
    if reachable[index]:
      continue
    reachable[index] = true
    for j in old.blocks[index].terminator.edges.indices:
      blocks.add(int(int32(old.edges[j].target)))
  for owner, data in old.blocks:
    for i in data.parameters.indices:
      parameters[i] = owner
    for i in data.instructions.indices:
      let instruction = old.instructions[i]
      for value in instruction.results.indices:
        definitions[value] = i
      if reachable[owner] and not removable(i):
        markOperands(instruction.arguments)
    if reachable[owner]:
      markOperands(data.terminator.arguments)
  for i in old.blocks[0].parameters.indices:
    mark(ValueId(i))
  while work.len > 0:
    let value = work.pop()
    if definitions[value] >= 0:
      markOperands(old.instructions[definitions[value]].arguments)
    elif parameters[value] > 0:
      let
        target = parameters[value]
        parameter = value - int(old.blocks[target].parameters.first)
      for owner, data in old.blocks:
        if not reachable[owner]:
          continue
        for j in data.terminator.edges.indices:
          let edge = old.edges[j]
          if int32(edge.target) == target:
            mark(old.operands[int(edge.arguments.first) + parameter])
  var
    mapping = newSeq[ValueId](old.values.len)
    blockMapping = newSeq[int](old.blocks.len)
    rebuilt = IrFunction(name: old.name, signature: old.signature,
      failureMode: old.failureMode, directOnly: old.directOnly, slots: old.slots)
  proc define(span: Span, filter: bool): Span =
    ## Rebuilds contiguous result spans with compact virtual register IDs.
    result.first = int32(rebuilt.values.len)
    for i in span.indices:
      if not filter or live[i]:
        mapping[i] = ValueId(rebuilt.values.len)
        rebuilt.values.add(old.values[i])
        inc result.count
  for owner, data in old.blocks:
    if not reachable[owner]:
      continue
    blockMapping[owner] = rebuilt.blocks.len
    var target = data
    target.parameters = define(data.parameters, owner > 0)
    target.instructions.first = int32(rebuilt.instructions.len)
    target.instructions.count = 0
    for i in data.instructions.indices:
      var instruction = old.instructions[i]
      var keep = not removable(i)
      for value in instruction.results.indices:
        keep = keep or live[value]
      if keep:
        instruction.results = define(instruction.results, false)
        rebuilt.instructions.add(instruction)
        inc target.instructions.count
    target.terminator.results = define(data.terminator.results, false)
    rebuilt.blocks.add(target)
  proc operands(span: Span, target = -1): Span =
    ## Rebuilds references and drops arguments for dead block parameters.
    result.first = int32(rebuilt.operands.len)
    for i in 0 ..< int(span.count):
      if target < 0 or live[int(old.blocks[target].parameters.first) + i]:
        rebuilt.operands.add(mapping[int32(old.operands[int(span.first) + i])])
        inc result.count
  for instruction in rebuilt.instructions.mitems:
    instruction.arguments = operands(instruction.arguments)
  for data in rebuilt.blocks.mitems:
    data.terminator.arguments = operands(data.terminator.arguments)
    let span = data.terminator.edges
    data.terminator.edges.first = int32(rebuilt.edges.len)
    for i in span.indices:
      let edge = old.edges[i]
      rebuilt.edges.add(IrEdge(target: BlockId(blockMapping[int32(edge.target)]),
        arguments: operands(edge.arguments, int(int32(edge.target)))))
  var slots = newSeq[int32](old.slots.len)
  for slot in slots.mitems:
    slot = -1
  rebuilt.slots.setLen(0)
  for instruction in rebuilt.instructions.mitems:
    if instruction.op == SlotAddressOp:
      let index = instruction.target
      if slots[index] < 0:
        slots[index] = int32(rebuilt.slots.len)
        rebuilt.slots.add(old.slots[index])
      instruction.target = slots[index]
  function = move(rebuilt)

proc promoteSlots(function: var IrFunction, module: IrModule) =
  ## Promotes initialized private scalar slots into pruned SSA block arguments.
  function.compact(function.identityAliases())
  let
    old = function
    pointerBytes = module.pointerBytes
    booleans = normalizedBooleans(old)
    slotCount = old.slots.len
    blockCount = old.blocks.len
  if slotCount == 0:
    return
  var
    addresses = newSeq[int](old.values.len)
    allowed = newSeq[bool](slotCount)
    typed = newSeq[bool](slotCount)
    kinds = newSeq[IrValue](slotCount)
    defines = newSeq[bool](slotCount * blockCount)
    uses = newSeq[bool](slotCount * blockCount)
    live = newSeq[bool](slotCount * blockCount)
    constants = newSeq[bool](old.values.len)
    bits = newSeq[uint64](old.values.len)
    transparent = newSeq[bool](old.instructions.len)
  for address in addresses.mitems:
    address = -1
  for slot in allowed.mitems:
    slot = true
  for item in old.instructions:
    if item.op == SlotAddressOp:
      addresses[item.results.first] = int(item.target)
    elif item.op == ConstantOp:
      constants[item.results.first] = true
      bits[item.results.first] = item.bits
  var aliasesChanged = true
  while aliasesChanged:
    aliasesChanged = false
    for index, item in old.instructions:
      if item.results.count != 1 or item.arguments.count == 0:
        continue
      let
        input = int32(old.operands[item.arguments.first])
        output = item.results.first
      if addresses[input] < 0 or addresses[output] >= 0 or
          old.values[input].valueType notin
            {AddressType, Int64Type, UInt64Type} or
          old.values[output].valueType notin
            {AddressType, Int64Type, UInt64Type}:
        continue
      var same = item.op == ConvertOp and
        item.conversion == BitcastConversion
      if item.op in {OffsetAddressOp, AddOp} and item.arguments.count == 2:
        let displacement = int32(old.operands[item.arguments.first + 1])
        if constants[displacement] and old.values[displacement].valueType in
            {Int64Type, UInt64Type}:
          same = (bits[displacement] +
            (if item.op == OffsetAddressOp: cast[uint64](item.offset)
            else: 0'u64)) == 0
      elif item.op == FieldAddressOp:
        same = int64(module.fields[item.target].offset) +% item.offset == 0
      if same:
        addresses[output] = addresses[input]
        transparent[index] = true
        aliasesChanged = true
  proc width(kind: IrType): int32 =
    ## Requires a whole-slot access of the declared primitive width.
    case kind
    of BoolType, CharType, Int8Type, UInt8Type: 1
    of Int16Type, UInt16Type: 2
    of Int32Type, UInt32Type, Float32Type: 4
    of AddressType: pointerBytes
    else: 8
  proc escape(span: Span) =
    ## Rejects slots whose address can be retained or observed elsewhere.
    for i in span.indices:
      let slot = addresses[int32(old.operands[i])]
      if slot >= 0:
        allowed[slot] = false
  for owner, data in old.blocks:
    for index in data.instructions.indices:
      let item = old.instructions[index]
      for i in 0 ..< int(item.arguments.count):
        let
          value = old.operands[int(item.arguments.first) + i]
          slot = addresses[int32(value)]
        if slot < 0:
          continue
        if i == 0 and transparent[index]:
          continue
        if i != 0 or item.op notin {LoadOp, StoreOp} or
            item.volatile or item.offset != 0:
            allowed[slot] = false
            continue
        let accessed = if item.op == LoadOp: old.values[item.results.first]
          else: old.values[int32(old.operands[item.arguments.first + 1])]
        if old.slots[slot].byteCount != width(accessed.valueType):
          allowed[slot] = false
        if accessed.valueType == BoolType and item.op == StoreOp and
            not booleans[int32(old.operands[item.arguments.first + 1])]:
          allowed[slot] = false
        if typed[slot] and kinds[slot] != accessed:
          allowed[slot] = false
        typed[slot] = true
        kinds[slot] = accessed
        let position = owner * slotCount + slot
        if item.op == StoreOp:
          defines[position] = true
        elif not defines[position]:
          uses[position] = true
    escape(data.terminator.arguments)
    for i in data.terminator.edges.indices:
      escape(old.edges[i].arguments)
  var any = false
  for slot in 0 ..< slotCount:
    allowed[slot] = allowed[slot] and typed[slot]
    any = any or allowed[slot]
  if not any:
    return
  var changed = true
  while changed:
    changed = false
    for owner in countdown(blockCount - 1, 0):
      for slot in 0 ..< slotCount:
        if not allowed[slot]:
          continue
        let position = owner * slotCount + slot
        var needed = uses[position]
        if not defines[position]:
          for i in old.blocks[owner].terminator.edges.indices:
            let target = int(int32(old.edges[i].target))
            needed = needed or live[target * slotCount + slot]
        if needed and not live[position]:
          live[position] = true
          changed = true
  # A live entry value means some path reaches a load before any store.
  # Otherwise every incoming SSA argument has a definition on its path.
  for slot in 0 ..< slotCount:
    allowed[slot] = allowed[slot] and not live[slot]
  var
    aliases = function.identityAliases()
    parameters = newSeq[ValueId](blockCount * slotCount)
    instructions: seq[IrInstruction]
  for value in parameters.mitems:
    value = NoValue
  for owner in 1 ..< blockCount:
    let first = int32(function.values.len)
    for i in old.blocks[owner].parameters.indices:
      let value = ValueId(function.values.len)
      aliases[i] = value
      aliases.add(value)
      function.values.add(old.values[i])
    for slot in 0 ..< slotCount:
      if allowed[slot] and live[owner * slotCount + slot]:
        let value = ValueId(function.values.len)
        parameters[owner * slotCount + slot] = value
        aliases.add(value)
        function.values.add(kinds[slot])
    function.blocks[owner].parameters = Span(first: first,
      count: int32(function.values.len) - first)
  for owner, data in old.blocks:
    var current = newSeq[ValueId](slotCount)
    for slot in 0 ..< slotCount:
      current[slot] = parameters[owner * slotCount + slot]
    let first = int32(instructions.len)
    for index in data.instructions.indices:
      let item = old.instructions[index]
      if item.op == SlotAddressOp and allowed[item.target]:
        continue
      if transparent[index] and allowed[addresses[item.results.first]]:
        continue
      if item.op in {LoadOp, StoreOp}:
        let slot = addresses[int32(old.operands[item.arguments.first])]
        if slot >= 0 and allowed[slot]:
          if item.op == StoreOp:
            current[slot] = old.operands[item.arguments.first + 1]
          else:
            doAssert int32(current[slot]) >= 0
            aliases[item.results.first] = current[slot]
          continue
      instructions.add(item)
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
    for i in data.terminator.edges.indices:
      let
        edge = old.edges[i]
        target = int(int32(edge.target))
        start = int32(function.operands.len)
      for j in edge.arguments.indices:
        function.operands.add(old.operands[j])
      for slot in 0 ..< slotCount:
        if allowed[slot] and live[target * slotCount + slot]:
          doAssert int32(current[slot]) >= 0
          function.operands.add(current[slot])
      function.edges[i].arguments = Span(first: start,
        count: int32(function.operands.len) - start)
  for slot in 0 ..< slotCount:
    if allowed[slot]:
      function.slots[slot] = IrSlot(alignment: 1)
  function.instructions = move(instructions)
  function.compact(aliases)

proc simplifyConversions(function: var IrFunction, pointerBytes: int32) =
  ## Removes exact representation round trips without changing numeric rounding.
  let old = function
  var
    aliases = function.identityAliases()
    definitions = newSeq[int](function.values.len)
    keep = newSeq[bool](old.instructions.len)
  for item in definitions.mitems:
    item = -1
  for i, item in old.instructions:
    if item.results.count == 1:
      definitions[item.results.first] = i
    keep[i] = true
  proc width(kind: IrType): int =
    ## Requires matching concrete widths before cancelling bit reinterpretations.
    case kind
    of BoolType, CharType, Int8Type, UInt8Type: 8
    of Int16Type, UInt16Type: 16
    of Int32Type, UInt32Type, Float32Type: 32
    of AddressType: int(pointerBytes) * 8
    else: 64
  var changed = true
  while changed:
    changed = false
    for index, item in old.instructions:
      if not keep[index] or item.op != ConvertOp:
        continue
      let
        source = aliases.resolve(old.operands[item.arguments.first])
        input = old.values[int32(source)]
        output = old.values[item.results.first]
      var replacement = NoValue
      if input == output and item.conversion in {BitcastConversion,
          TruncateConversion, SignExtendConversion, ZeroExtendConversion}:
          replacement = source
      elif definitions[int32(source)] >= 0:
        let inner = old.instructions[definitions[int32(source)]]
        if inner.op == ConvertOp:
          let
            original = aliases.resolve(old.operands[inner.arguments.first])
            value = old.values[int32(original)]
          if value == output and value.valueType != BoolType and
              input.valueType != BoolType:
              if item.conversion == BitcastConversion and
                  inner.conversion == BitcastConversion and
                  width(value.valueType) == width(input.valueType):
                  replacement = original
              elif item.conversion == TruncateConversion and
                  inner.conversion in {SignExtendConversion,
                    ZeroExtendConversion} and
                  value.valueType notin {Float32Type, Float64Type, AddressType} and
                  input.valueType notin {Float32Type, Float64Type, AddressType} and
                  width(value.valueType) <= width(input.valueType):
                  replacement = original
      if int32(replacement) >= 0:
        aliases[item.results.first] = replacement
        keep[index] = false
        changed = true
  var instructions: seq[IrInstruction]
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for i in data.instructions.indices:
      if keep[i]:
        instructions.add(old.instructions[i])
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)
  function.compact(aliases)

proc reuseDominating(function: var IrFunction) =
  ## Reuses exact scalar definitions available on every path to a later use.
  function.compact(function.identityAliases())
  let
    old = function
    count = old.blocks.len
    tree = dominance(old)
  type Expression = tuple[
    op: IrOpcode, kind: IrType, storage: int32,
    conversion: IrConversion, comparison: IrComparison,
    bits: uint64, offset: int64, alignment, byteCount, target: int32,
    a, b, count: int32
  ]
  var
    aliases = function.identityAliases()
    operands = old.operands
    keep = newSeq[bool](old.instructions.len)
    seen = initTable[Expression, ValueId]()
    owners = newSeq[int](old.values.len)
    inserted = newSeq[seq[Expression]](count)
    numbers = function.identityAliases()
    constants = initTable[tuple[kind: IrType, storage: int32, bits: uint64],
      ValueId]()
  for item in old.instructions:
    if item.op == ConstantOp:
      let
        value = old.values[item.results.first]
        key = (value.valueType, value.storage, item.bits)
      if constants.hasKey(key):
        numbers[item.results.first] = constants.getOrDefault(key)
      else:
        constants[key] = ValueId(item.results.first)
  var pending = @[(0, false)]
  while pending.len > 0:
    let (owner, finished) = pending.pop()
    if finished:
      for key in inserted[owner]:
        seen.del(key)
      continue
    pending.add((owner, true))
    for child in tree.children[owner]:
      pending.add((child, false))
    for i in old.blocks[owner].instructions.indices:
      let item = old.instructions[i]
      for j in item.arguments.indices:
        operands[j] = aliases.resolve(operands[j])
      keep[i] = true
      if not item.op.pure() or
          item.op in {ConstantOp, FrameSizeOp} or item.volatile or
          item.results.count != 1 or item.arguments.count > 2:
          continue
      let
        value = old.values[item.results.first]
        first = int(item.arguments.first)
        key: Expression = (
          item.op, value.valueType, value.storage,
          item.conversion, item.comparison, item.bits, item.offset,
          item.alignment, item.byteCount, item.target,
          if item.arguments.count > 0: int32(numbers[int32(operands[first])]) else: -1'i32,
          if item.arguments.count > 1: int32(numbers[int32(operands[first + 1])]) else: -1'i32,
          item.arguments.count
        )
      if seen.hasKey(key):
        let candidate = seen.getOrDefault(key)
        if owners[int32(candidate)] == owner or
            item.op in {MultiplyOp, MultiplyHighOp, DivideOp, RemainderOp, SqrtOp}:
            aliases[item.results.first] = candidate
            keep[i] = false
      else:
        seen[key] = ValueId(item.results.first)
        owners[item.results.first] = owner
        inserted[owner].add(key)
  for value in operands.mitems:
    value = aliases.resolve(value)
  function.operands = move(operands)
  var instructions: seq[IrInstruction]
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for i in data.instructions.indices:
      if keep[i]:
        instructions.add(old.instructions[i])
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)
  function.compact(aliases)

proc settleBranches(function: var IrFunction) =
  ## Cleans control flow exposed by later passes until its size stops falling.
  while true:
    let previous = function.blocks.len + function.instructions.len +
      function.edges.len
    function.threadJumps()
    discard function.foldIdenticalBranches()
    function.mergeBlocks()
    function.removeDead()
    if function.blocks.len + function.instructions.len +
      function.edges.len >= previous:
        break

proc optimizeIr*(module: var IrModule,
    passes = DefaultIrOptimizations, fastMultiplyHigh = false) =
  ## Runs explicit shared IR passes and verifies the resulting graph.
  verifyIr(module)
  materializeMemory(module)
  verifyIr(module)
  let selected = effectiveIrOptimizations(passes)
  for pass in [PromoteIrSlots, SimplifyIrConversions, FoldIrConstants,
      ReduceIrRemainders, ReduceIrDivisions,
      RemoveIrIdentities, SimplifyIrParameters,
      ThreadIrJumps, MergeIrBlocks, ReuseIrExpressions, FoldIrAddresses,
      FoldIrAddressRoots,
      ForwardIrStores, ReuseIrLoads, ForwardIrRegions,
      HoistIrInvariants, ReuseIrDominating, SimplifyIrBooleans,
      SimplifyIrConditions, FoldIrPredicates,
      MergeIrParameters, SelectIrValues, RemoveIrStores, RemoveIrDeadValues]:
    if pass notin selected:
      continue
    if pass == PromoteIrSlots:
      for function in module.functions.mitems:
        function.promoteSlots(module)
        if SimplifyIrConversions in selected:
          function.simplifyConversions(module.pointerBytes)
      scalarizeSlots(module, PreserveIrFloatSlots in selected)
    for function in module.functions.mitems:
      case pass
      of PromoteIrArguments, PromoteIrReturns, ForwardIrFields,
          RemoveIrArguments, PreserveIrFloatSlots,
          RematerializeIrAddresses, RematerializeIrConstants,
          SeparateIrTemporaries, PromoteIrRecordReturns,
          FoldIrConversions, PromoteIrWideArguments, CacheIrArguments,
          VectorizeIrFloatPairs, VectorizeIrFloatDivisions, FoldIrFloatSums,
          SinkIrLoads, FoldIrBranches, RemoveIrContextLoads, HoistIrAddresses,
          ScaleIrInductions, SettleIrBranches, OrderIrBlocks,
          PruneIrProcedures, PreserveIrFloatParameters, ReuseIrAddresses: discard
      of FoldIrAddresses: function.foldAddresses(module.pointerBytes)
      of FoldIrAddressRoots:
        function.foldAddresses(module.pointerBytes, roots = true)
      of ReduceIrRemainders:
        discard function.reduceRemainderTests()
      of ForwardIrRegions:
        let aliases = function.forwardRegions(module)
        function.compact(aliases)
      of SimplifyIrConditions:
        if function.simplifyConditions() and RemoveIrDeadValues in selected:
          function.removeDead()
        if ThreadIrJumps in selected:
          function.compact(function.identityAliases())
          while function.threadConditions():
            function.compact(function.identityAliases())
            if RemoveIrDeadValues in selected:
              function.removeDead()
      of FoldIrPredicates:
        while function.foldPredicates():
          function.compact(function.identityAliases())
        if MergeIrBlocks in selected:
          function.mergeBlocks()
      of ReuseIrDominating: function.reuseDominating()
      of SimplifyIrBooleans:
        let aliases = function.simplifyBooleans()
        function.compact(aliases)
      of SimplifyIrConversions:
        function.simplifyConversions(module.pointerBytes)
      of PromoteIrSlots: function.promoteSlots(module)
      of HoistIrInvariants: function.hoistLoops()
      of FoldIrConstants:
        function.foldConstants(FoldIrConversions in selected)
      of ReduceIrDivisions: function.reduceDivisions(fastMultiplyHigh)
      of RemoveIrIdentities: function.removeIdentities()
      of SimplifyIrParameters: function.simplifyParameters()
      of MergeIrParameters: function.mergeParameters()
      of SelectIrValues:
        let aliases = function.selectValues()
        function.compact(aliases)
        function.removeIdentities()
        function.simplifyParameters()
        if MergeIrBlocks in selected:
          function.mergeBlocks()
      of ThreadIrJumps: function.threadJumps()
      of MergeIrBlocks: function.mergeBlocks()
      of ReuseIrExpressions: function.reuse()
      of ForwardIrStores: function.forwardStores(module.hosts)
      of ReuseIrLoads: function.reuseLoads(module.hosts)
      of RemoveIrDeadValues: function.removeDead()
      of RemoveIrStores: discard function.removeStores(module.pointerBytes)
    verifyIr(module)
  if PromoteIrArguments in selected and
      promoteArguments(module, PromoteIrWideArguments in selected):
    optimizeIr(module, selected - ModuleIrOptimizations, fastMultiplyHigh)
  if PromoteIrReturns in selected and
      promoteReturns(module, PromoteIrRecordReturns in selected):
    optimizeIr(module, selected - ModuleIrOptimizations, fastMultiplyHigh)
  if ForwardIrFields in selected and forwardMemory(module):
    optimizeIr(module, selected - ModuleIrOptimizations, fastMultiplyHigh)
  if CacheIrArguments in selected and cacheArguments(module):
    optimizeIr(module, selected - ModuleIrOptimizations, fastMultiplyHigh)
  # Later simplifications can expose memory aliases missed by the first sweep.
  # Each successful cleanup removes instructions, so iteration is bounded.
  if {ForwardIrStores, ReuseIrLoads} * selected != {}:
    for function in module.functions.mitems:
      while true:
        let previous = function.instructions.len
        if SimplifyIrConversions in selected:
          function.simplifyConversions(module.pointerBytes)
        if ForwardIrStores in selected:
          function.forwardStores(module.hosts)
        if ReuseIrLoads in selected:
          function.reuseLoads(module.hosts)
        if RemoveIrDeadValues in selected:
          function.removeDead()
        if function.instructions.len >= previous:
          break
    verifyIr(module)
  if RemoveIrArguments in selected:
    while removeUnusedArguments(module):
      optimizeIr(module, selected - {RemoveIrArguments, RematerializeIrAddresses,
        RematerializeIrConstants, VectorizeIrFloatPairs,
        VectorizeIrFloatDivisions, FoldIrFloatSums, SinkIrLoads, FoldIrBranches,
        RemoveIrContextLoads, HoistIrAddresses, SettleIrBranches, OrderIrBlocks,
        PruneIrProcedures, PreserveIrFloatParameters, ReuseIrAddresses}, fastMultiplyHigh)
  if PreserveIrFloatParameters in selected:
    for function in module.functions.mitems:
      if function.preserveFloatParameters():
        function.simplifyConversions(module.pointerBytes)
        function.removeDead()
    verifyIr(module)
  if RematerializeIrAddresses in selected:
    for function in module.functions.mitems:
      if function.rematerializeAddresses():
        function.removeDead()
    verifyIr(module)
  if RematerializeIrConstants in selected:
    for function in module.functions.mitems:
      if function.rematerializeConstants():
        function.removeDead()
    verifyIr(module)
  if ReuseIrAddresses in selected:
    for function in module.functions.mitems:
      if function.reuseAddresses(module.pointerBytes):
        function.removeDead()
    verifyIr(module)
  if VectorizeIrFloatPairs in selected:
    for function in module.functions.mitems:
      if function.vectorizeFloatPairs(
          VectorizeIrFloatDivisions in selected,
          FoldIrFloatSums in selected
      ):
        function.simplifyConversions(module.pointerBytes)
        function.removeDead()
    verifyIr(module)
  if FoldIrFloatSums in selected:
    for function in module.functions.mitems:
      if function.foldFloatSums():
        function.removeDead()
    verifyIr(module)
  # Rematerialization and vectorization introduce new loop-local definitions.
  # Settle their placement before allocating registers, then merge duplicates.
  if HoistIrInvariants in selected:
    for function in module.functions.mitems:
      if function.hoistLoops():
        if ReuseIrExpressions in selected:
          function.reuse()
        if ReuseIrDominating in selected:
          function.reuseDominating()
        if RemoveIrDeadValues in selected:
          function.removeDead()
    verifyIr(module)
  if SinkIrLoads in selected:
    for function in module.functions.mitems:
      discard function.sinkLoads(module.hosts)
    verifyIr(module)
  if FoldIrBranches in selected:
    for function in module.functions.mitems:
      if function.foldIdenticalBranches():
        if MergeIrBlocks in selected:
          function.mergeBlocks()
        if RemoveIrDeadValues in selected:
          function.removeDead()
    verifyIr(module)
  if RemoveIrContextLoads in selected:
    for function in module.functions.mitems:
      let removable = removableContextLoads(module, function)
      if true in removable:
        function.removeDead(removable)
    verifyIr(module)
  # Address formation is pure, but moving it early can lengthen live ranges
  # through later rewrites. Settle these chains once the other passes finish.
  if HoistIrAddresses in selected:
    for function in module.functions.mitems:
      if function.hoistLoops(addresses = true) and
          ReuseIrExpressions in selected:
        # Hoisting can reunite rematerialized copies in one preheader.
        # Let allocation see one value for each identical expression.
        function.reuse()
        if RemoveIrDeadValues in selected:
          function.removeDead()
    verifyIr(module)
  if ScaleIrInductions in selected:
    for function in module.functions.mitems:
      if function.reduceScaledLoops():
        function.simplifyConversions(module.pointerBytes)
        if ReuseIrExpressions in selected:
          function.reuse()
        function.removeDead()
    verifyIr(module)
  if SettleIrBranches in selected:
    for function in module.functions.mitems:
      function.settleBranches()
    verifyIr(module)
  if OrderIrBlocks in selected:
    for function in module.functions.mitems:
      discard function.orderBlocks()
    verifyIr(module)
  if PruneIrProcedures in selected:
    discard module.pruneProcedures()
    verifyIr(module)

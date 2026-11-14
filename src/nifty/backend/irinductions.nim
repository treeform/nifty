import irs, irchecks, irdominators

type ScaledLoop = object
  header, preheader, entry, back, parameter: int
  counter: ValueId
  comparison, step, boundSide, stepSide: int
  start, bound, increment, factor: uint64
  products: seq[int]

proc positiveLimit(kind: IrType): uint64 {.raises: [].} =
  ## Returns the largest nonnegative value in a supported integer type.
  case kind
  of Int8Type: uint64(int8.high)
  of UInt8Type: uint64(uint8.high)
  of Int16Type: uint64(int16.high)
  of UInt16Type: uint64(uint16.high)
  of Int32Type: uint64(int32.high)
  of UInt32Type: uint64(uint32.high)
  of Int64Type: uint64(int64.high)
  of UInt64Type: uint64.high
  else: 0

proc ordinal(function: IrFunction, definitions: seq[int], original: ValueId,
    number: var uint64): bool {.raises: [].} =
  ## Reads nonnegative constants through equal-width integer bitcasts.
  let
    kind = function.values[int32(original)].valueType
    limit = positiveLimit(kind)
    width = kind.byteCount(8) * 8
  if limit == 0:
    return false
  var value = original
  for depth in 0 .. 4:
    let index = definitions[int32(value)]
    if index < 0:
      return false
    let item = function.instructions[index]
    if item.volatile:
      return false
    if item.op == ConstantOp:
      let mask = if width == 64: uint64.high else: (1'u64 shl width) - 1
      number = item.bits and mask
      return number <= limit
    if item.op != ConvertOp or item.conversion != BitcastConversion:
      return false
    value = function.operands[item.arguments.first]
    let input = function.values[int32(value)].valueType
    if positiveLimit(input) == 0 or input.byteCount(8) * 8 != width:
      return false

proc dominates(tree: IrDominance, parent, child: int): bool {.raises: [].} =
  ## Tests ancestry in the reachable immediate-dominator tree.
  var owner = child
  while owner >= 0:
    if owner == parent:
      return true
    if tree.parents[owner] == owner:
      break
    owner = tree.parents[owner]

proc counterCasts(function: IrFunction, definitions: seq[int],
    input, counter: ValueId, casts: var seq[int],
    update: var int): bool {.raises: [].} =
  ## Recognizes same-width views of a counter or its immediate update.
  var value = input
  let width = function.values[int32(counter)].valueType.byteCount(8)
  for depth in 0 .. 4:
    if int32(value) == int32(counter):
      return true
    let index = definitions[int32(value)]
    if index < 0:
      return false
    let
      item = function.instructions[index]
      kind = function.values[int32(value)].valueType
    if item.volatile or positiveLimit(kind) == 0 or
      kind.byteCount(8) != width:
        return false
    if item.op == AddOp:
      for argument in item.arguments.indices:
        if int32(function.operands[argument]) == int32(counter):
          update = index
          return true
      return false
    if item.op != ConvertOp or item.conversion != BitcastConversion:
      return false
    casts.add(index)
    value = function.operands[item.arguments.first]

proc planLoop(function: IrFunction, tree: IrDominance,
    definitions, owners, uses: seq[int], header, parameter: int,
    plan: var ScaledLoop): bool {.raises: [].} =
  ## Proves a bounded counter can use scaled units without observable changes.
  let
    data = function.blocks[header]
    counter = ValueId(parameter)
    kind = function.values[parameter].valueType
    limit = positiveLimit(kind)
  if limit == 0 or data.terminator.kind != BranchTerminator:
    return false
  plan = ScaledLoop(header: header, counter: counter,
    parameter: parameter - int(data.parameters.first),
    preheader: -1, entry: -1, back: -1, step: -1)
  let comparison = definitions[int32(function.operands[
    data.terminator.arguments.first])]
  if comparison < 0 or owners[comparison] != header or
    function.instructions[comparison].op != CompareOp:
      return false
  plan.comparison = comparison
  let condition = function.instructions[comparison]
  var
    casts: seq[int]
    comparisonStep = -1
  if function.counterCasts(definitions,
      function.operands[condition.arguments.first], counter, casts,
      comparisonStep):
    plan.boundSide = 1
  else:
    casts.setLen(0)
    if not function.counterCasts(definitions,
        function.operands[condition.arguments.first + 1], counter, casts,
        comparisonStep):
      return false
    plan.boundSide = 0
  let
    bound = function.operands[condition.arguments.first + int32(plan.boundSide)]
    boundKind = function.values[int32(bound)].valueType
    strict = if plan.boundSide == 1: LessComparison else: GreaterComparison
    stopping = if plan.boundSide == 1:
        GreaterEqualComparison
      else:
        LessEqualComparison
    exact = condition.comparison in {EqualComparison, NotEqualComparison}
  if condition.comparison notin
    {strict, stopping, EqualComparison, NotEqualComparison} or
    not function.ordinal(definitions, bound, plan.bound):
      return false
  for index in casts:
    if uses[function.instructions[index].results.first] != 1:
      return false
  var latch = -1
  for owner, blockData in function.blocks:
    for edge in blockData.terminator.edges.indices:
      if int32(function.edges[edge].target) != header:
        continue
      if tree.parents[owner] < 0:
        return false
      if tree.dominates(header, owner):
        if plan.back >= 0:
          return false
        plan.back = edge
        latch = owner
      else:
        if plan.entry >= 0 or not tree.dominates(owner, header) or
          blockData.terminator.kind != JumpTerminator:
            return false
        plan.entry = edge
        plan.preheader = owner
  if plan.entry < 0 or plan.back < 0:
    return false
  var
    members = newSeq[bool](function.blocks.len)
    pending = @[latch]
  members[header] = true
  while pending.len > 0:
    let owner = pending.pop()
    if members[owner]:
      continue
    if not tree.dominates(header, owner):
      return false
    members[owner] = true
    for predecessor in tree.predecessors[owner]:
      pending.add(predecessor)
  let
    first = int32(function.edges[data.terminator.edges.first].target)
    second = int32(function.edges[data.terminator.edges.first + 1].target)
    enters = condition.comparison in {strict, NotEqualComparison}
    continuing = if enters: first else: second
    exiting = if enters: second else: first
  if not members[continuing] or members[exiting]:
    return false
  let
    entryArguments = function.edges[plan.entry].arguments
    backArguments = function.edges[plan.back].arguments
    initial = function.operands[entryArguments.first + int32(plan.parameter)]
    next = function.operands[backArguments.first + int32(plan.parameter)]
  if not function.ordinal(definitions, initial, plan.start) or
    plan.start > plan.bound or
    ((not exact or comparisonStep >= 0) and plan.start == plan.bound):
      return false
  plan.step = definitions[int32(next)]
  if plan.step < 0 or uses[int32(next)] != 1 + ord(comparisonStep >= 0):
    return false
  if comparisonStep >= 0 and
    (not exact or comparisonStep != plan.step or owners[plan.step] != header):
      return false
  let step = function.instructions[plan.step]
  if step.op != AddOp or step.volatile:
    return false
  if int32(function.operands[step.arguments.first]) == parameter:
    plan.stepSide = 1
  elif int32(function.operands[step.arguments.first + 1]) == parameter:
    plan.stepSide = 0
  else:
    return false
  if not function.ordinal(definitions,
      function.operands[step.arguments.first + int32(plan.stepSide)],
      plan.increment) or plan.increment == 0:
    return false
  var allowed = 0
  for blockData in function.blocks:
    for index in blockData.instructions.indices:
      let item = function.instructions[index]
      for argument in item.arguments.indices:
        if int32(function.operands[argument]) != parameter:
          continue
        inc allowed
        if index == plan.step or index == plan.comparison or index in casts:
          continue
        if item.op != MultiplyOp or item.volatile or
          function.values[item.results.first].valueType != kind:
            return false
        let other = item.arguments.first + 1 -
          (argument - item.arguments.first)
        var factor: uint64
        if not function.ordinal(definitions,
            function.operands[other], factor) or factor <= 1:
          return false
        if plan.factor != 0 and plan.factor != factor:
          return false
        plan.factor = factor
        plan.products.add(index)
  if plan.products.len == 0 or allowed != uses[parameter]:
    return false
  let maximum = min(limit, positiveLimit(boundKind))
  if exact:
    # The reachable equality endpoint bounds every observable product.
    # The compared current or updated counter must fit its scaled type.
    return (plan.bound - plan.start) mod plan.increment == 0 and
      plan.bound <= maximum div plan.factor and
      plan.increment <= limit div plan.factor
  if plan.increment - 1 > maximum or
    plan.bound > maximum - (plan.increment - 1):
      return false
  # Include the first failing header visit after the final increment.
  let last = plan.bound + (plan.increment - 1)
  last <= maximum div plan.factor

proc reduceScaledLoop(function: var IrFunction): bool {.raises: [].} =
  ## Rewrites one proven loop and leaves unrelated constant users untouched.
  let tree = function.dominance()
  var
    definitions = newSeq[int](function.values.len)
    owners = newSeq[int](function.instructions.len)
    uses = newSeq[int](function.values.len)
  for definition in definitions.mitems:
    definition = -1
  proc observe(span: Span, operands: seq[ValueId]) =
    ## Includes edge and return observations in counter ownership checks.
    for index in span.indices:
      inc uses[int32(operands[index])]
  for owner, data in function.blocks:
    for index in data.instructions.indices:
      let item = function.instructions[index]
      owners[index] = owner
      if item.results.count == 1:
        definitions[item.results.first] = index
      observe(item.arguments, function.operands)
    observe(data.terminator.arguments, function.operands)
    for edge in data.terminator.edges.indices:
      observe(function.edges[edge].arguments, function.operands)
  for header, data in function.blocks:
    if header == 0 or tree.parents[header] < 0:
      continue
    for parameter in data.parameters.indices:
      var plan: ScaledLoop
      if not function.planLoop(tree, definitions, owners, uses,
          header, parameter, plan):
        continue
      var constants: seq[IrInstruction]
      proc literal(function: var IrFunction, kind: IrType,
          bits: uint64): ValueId =
        ## Appends a private scaled constant that dominates the entire loop.
        result = ValueId(function.values.len)
        function.values.add(IrValue(valueType: kind))
        constants.add(IrInstruction(op: ConstantOp, bits: bits,
          results: Span(first: int32(result), count: 1)))
      proc changed(function: var IrFunction, span: Span, side: int,
          value: ValueId): Span =
        ## Replaces one operand without changing other references to its pool.
        result = Span(first: int32(function.operands.len), count: span.count)
        for i in 0 ..< int(span.count):
          function.operands.add(if i == side: value
            else: function.operands[span.first + int32(i)])
      let
        kind = function.values[parameter].valueType
        condition = function.instructions[plan.comparison]
        boundKind = function.values[int32(function.operands[
          condition.arguments.first + int32(plan.boundSide)])].valueType
        initial = function.literal(kind, plan.start * plan.factor)
        increment = function.literal(kind, plan.increment * plan.factor)
        bound = function.literal(boundKind, plan.bound * plan.factor)
      function.edges[plan.entry].arguments = function.changed(
        function.edges[plan.entry].arguments, plan.parameter, initial)
      function.instructions[plan.step].arguments = function.changed(
        function.instructions[plan.step].arguments, plan.stepSide, increment)
      function.instructions[plan.comparison].arguments = function.changed(
        condition.arguments, plan.boundSide, bound)
      for index in plan.products:
        function.instructions[index].op = ConvertOp
        function.instructions[index].conversion = BitcastConversion
        function.instructions[index].arguments = Span(
          first: int32(function.operands.len), count: 1)
        function.operands.add(plan.counter)
      var instructions: seq[IrInstruction]
      for owner, blockData in function.blocks.mpairs:
        let first = instructions.len
        for index in blockData.instructions.indices:
          instructions.add(function.instructions[index])
        if owner == plan.preheader:
          instructions.add(constants)
        blockData.instructions = Span(first: int32(first),
          count: int32(instructions.len - first))
      function.instructions = move(instructions)
      return true

proc reduceScaledLoops*(function: var IrFunction): bool {.raises: [].} =
  ## Advances bounded integer counters in the units used by their products.
  for attempt in 0 ..< function.blocks.len:
    if not function.reduceScaledLoop():
      break
    result = true

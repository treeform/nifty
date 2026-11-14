import std/tables, irs, irdominators

type Predicate = tuple[comparison: IrComparison, a, b: int32]

proc foldPredicates*(function: var IrFunction): bool =
  ## Selects branches whose exact predicate is known on a dominating CFG edge.
  let
    old = function
    tree = dominance(old)
  var
    numbers = newSeq[int32](old.values.len)
    conditions = newSeq[int](old.values.len)
    inverted = newSeq[bool](old.values.len)
    constants = initTable[tuple[kind: IrType, bits: uint64], int32]()
    predicates = initTable[Predicate, int]()
  for i in 0 ..< numbers.len:
    numbers[i] = int32(i)
    conditions[i] = i
  for item in old.instructions:
    if item.op == ConstantOp:
      let
        value = item.results.first
        key = (old.values[value].valueType, item.bits)
      if constants.hasKey(key):
        numbers[value] = constants.getOrDefault(key)
      else:
        constants[key] = value
  for item in old.instructions:
    if item.op != CompareOp or item.results.count != 1:
      continue
    let output = item.results.first
    var
      comparison = item.comparison
      a = numbers[int32(old.operands[item.arguments.first])]
      b = numbers[int32(old.operands[item.arguments.first + 1])]
    case comparison
    of NotEqualComparison:
      comparison = EqualComparison
      inverted[output] = true
    of GreaterComparison:
      comparison = LessComparison
      swap(a, b)
    of GreaterEqualComparison:
      comparison = LessEqualComparison
      swap(a, b)
    else:
      discard
    if comparison == EqualComparison and a > b:
      swap(a, b)
    let key: Predicate = (comparison, a, b)
    if not predicates.hasKey(key):
      predicates[key] = old.values.len + predicates.len
    conditions[output] = predicates.getOrDefault(key)
  var
    facts = initTable[int, bool]()
    added = newSeq[int](old.blocks.len)
    pending = @[(0, false)]
  for key in added.mitems:
    key = -1
  while pending.len > 0:
    let (owner, finished) = pending.pop()
    if finished:
      if added[owner] >= 0:
        facts.del(added[owner])
      continue
    if owner > 0 and tree.predecessors[owner].len == 1:
      let parent = old.blocks[tree.predecessors[owner][0]].terminator
      if parent.kind == BranchTerminator:
        let
          value = int32(old.operands[parent.arguments.first])
          truth = int32(old.edges[parent.edges.first].target) == owner
          key = conditions[value]
        if not facts.hasKey(key):
          facts[key] = truth xor inverted[value]
          added[owner] = key
    let terminal = old.blocks[owner].terminator
    if terminal.kind == BranchTerminator:
      let value = int32(old.operands[terminal.arguments.first])
      if facts.hasKey(conditions[value]):
        let truth = facts.getOrDefault(conditions[value]) xor inverted[value]
        function.blocks[owner].terminator.kind = JumpTerminator
        function.blocks[owner].terminator.arguments = Span()
        function.blocks[owner].terminator.edges = Span(
          first: terminal.edges.first + int32(ord(not truth)), count: 1)
        result = true
    pending.add((owner, true))
    for child in tree.children[owner]:
      pending.add((child, false))

import irs

type IrBranchPlan* = object
  comparisons*: seq[int32]
  conditions*: seq[bool]

type IrSelectPlan* = object
  comparisons*: seq[int32]
  conditions*: seq[bool]

proc selectComparisons*(function: IrFunction,
    preserves: set[IrOpcode]): IrSelectPlan {.raises: [].} =
  ## Finds comparison results used only by selects in one preserved region.
  result.comparisons = newSeq[int32](function.instructions.len)
  result.conditions = newSeq[bool](function.values.len)
  for comparison in result.comparisons.mitems:
    comparison = -1
  var uses = newSeq[int](function.values.len)
  proc observe(span: Span) =
    ## Counts actual spans so discarded pooled operands do not create users.
    for i in span.indices:
      inc uses[int32(function.operands[i])]
  for data in function.blocks:
    for i in data.instructions.indices:
      observe(function.instructions[i].arguments)
    observe(data.terminator.arguments)
    for edge in data.terminator.edges.indices:
      observe(function.edges[edge].arguments)
  for data in function.blocks:
    for index in data.instructions.indices:
      let item = function.instructions[index]
      if item.op != CompareOp:
        continue
      let value = item.results.first
      var selected: seq[int]
      for following in index + 1 ..<
        data.instructions.first + data.instructions.count:
          let next = function.instructions[following]
          if next.op == SelectOp:
            if int32(function.operands[next.arguments.first]) != value:
              break
            selected.add(following)
          elif next.op notin preserves or next.volatile:
            break
      if selected.len > 0 and selected.len == uses[value]:
        result.conditions[value] = true
        for following in selected:
          result.comparisons[following] = int32(index)

proc selectBranches(function: IrFunction): IrBranchPlan {.raises: [].} =
  ## Selects adjacent comparisons whose boolean result only feeds one branch.
  result.comparisons = newSeq[int32](function.blocks.len)
  result.conditions = newSeq[bool](function.values.len)
  for comparison in result.comparisons.mitems:
    comparison = -1
  var uses = newSeq[int32](function.values.len)
  proc observe(span: Span) =
    ## Counts actual operand spans rather than obsolete pooled operands.
    for i in span.indices:
      inc uses[int32(function.operands[i])]
  for data in function.blocks:
    for i in data.instructions.indices:
      observe(function.instructions[i].arguments)
    observe(data.terminator.arguments)
    for i in data.terminator.edges.indices:
      observe(function.edges[i].arguments)
  for owner, data in function.blocks:
    let terminal = data.terminator
    if terminal.kind != BranchTerminator or terminal.arguments.count != 1 or
        data.instructions.count == 0:
        continue
    let
      index = data.instructions.first + data.instructions.count - 1
      item = function.instructions[index]
    if item.op != CompareOp or item.results.count != 1:
      continue
    let value = item.results.first
    if function.values[value].valueType == BoolType and uses[value] == 1 and
        int32(function.operands[terminal.arguments.first]) == value:
        result.comparisons[owner] = index
        result.conditions[value] = true

proc branchComparisons*(function: IrFunction): IrBranchPlan {.raises: [].} =
  ## Shares compare-and-branch selection before target-specific flag lowering.
  when defined(nimkeyNoCompareBranches):
    result.comparisons = newSeq[int32](function.blocks.len)
    result.conditions = newSeq[bool](function.values.len)
    for comparison in result.comparisons.mitems:
      comparison = -1
  else:
    result = selectBranches(function)

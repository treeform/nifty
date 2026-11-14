## Expands small checked constant ranges before native IR construction.
import std/[sets, tables]
import types

type NativeUnrollConfig* = object
  maxIterations*: int
  maxBodyNodes*: int
  maxGrowth*: int

proc defaultNativeUnrollConfig*(): NativeUnrollConfig =
  ## Bounds duplicated transitive helper work independently in each routine.
  NativeUnrollConfig(maxIterations: 32, maxBodyNodes: 100, maxGrowth: 1024)

proc unrollNative*(source: Module,
    config = defaultNativeUnrollConfig()): Module =
  ## Copies checked syntax and exposes literal induction values to shared IR.
  new(result)
  result[] = source[]
  result.routines = @[]
  var constants = initTable[string, int64]()
  for item in source.consts:
    constants[item.name] = item.value
  var
    routines = initTable[string, Routine]()
    expandedCosts = initTable[string, int]()
    estimating = initHashSet[string]()
  for routine in source.routines:
    routines[routine.name] = routine
  let costCeiling = if config.maxGrowth < high(int):
      max(0, config.maxGrowth) + 1 else: high(int)
  proc addCost(total: var int, amount: int) =
    ## Saturates estimates once duplication cannot fit the configured budget.
    total = if amount >= costCeiling - total: costCeiling else: total + amount
  proc expandedBodyCost(body: seq[Stmt]): int
  proc expandedRoutineCost(name: string): int =
    ## Caches transitive call expansion and conservatively bounds cycles.
    if name in expandedCosts:
      return expandedCosts[name]
    if name in estimating:
      return costCeiling
    estimating.incl(name)
    result = expandedBodyCost(routines[name].body)
    estimating.excl(name)
    expandedCosts[name] = result
  proc expandedExpressionCost(value: Expr): int =
    ## Includes known helper bodies that later IR inlining may expose.
    if value.isNil:
      return 0
    result = 1
    for child in value.kids:
      result.addCost(expandedExpressionCost(child))
    if value.kind == CallExpr and value.sval in routines:
      result.addCost(expandedRoutineCost(value.sval))
  proc expandedBodyCost(body: seq[Stmt]): int =
    ## Estimates emitted work without multiplying loops inside called helpers.
    for item in body:
      result.addCost(1)
      for value in [item.init, item.lhs, item.rhs, item.cond,
          item.lo, item.hi, item.value]:
        result.addCost(expandedExpressionCost(value))
      for argument in item.args:
        result.addCost(expandedExpressionCost(argument))
      result.addCost(expandedBodyCost(item.body))
      result.addCost(expandedBodyCost(item.elseBody))
      for branch in item.elifs:
        result.addCost(expandedExpressionCost(branch.cond))
        result.addCost(expandedBodyCost(branch.body))
  proc constant(value: Expr, answer: var int64): bool =
    ## Accepts only side-effect-free integer literals and named constants.
    if value.isNil:
      return false
    case value.kind
    of IntExpr:
      answer = value.ival
      true
    of IdentExpr:
      if value.sval notin constants:
        return false
      answer = constants[value.sval]
      true
    of NegExpr:
      if value.kids.len != 1 or not constant(value.kids[0], answer) or
          answer == low(int64):
        return false
      answer = -answer
      true
    else: false
  proc expression(value: Expr, name: string, literal: int64): Expr =
    ## Substitutes only the checked loop binding and preserves typed flags.
    if value.isNil:
      return nil
    new(result)
    result[] = value[]
    result.kids = @[]
    if name.len > 0 and value.kind == IdentExpr and value.sval == name and
        value.symKind == LocalSym:
      result.kind = IntExpr
      result.ival = literal
      result.sval = ""
      result.rlo = literal
      result.rhi = literal
      result.rnz = literal != 0
    else:
      for child in value.kids:
        result.kids.add(expression(child, name, literal))
  proc nodes(value: Expr): int =
    ## Counts expression nodes without expanding calls.
    if value.isNil:
      return 0
    result = 1
    for child in value.kids:
      result += nodes(child)
  proc bodyNodes(body: seq[Stmt], hasBreak: var bool): int =
    ## Rejects nested loops while counting all duplicated source nodes.
    for item in body:
      if item.kind in {ForStmt, WhileStmt, LoopStmt, ForEachStmt}:
        return config.maxBodyNodes + 1
      if item.kind == BreakStmt:
        hasBreak = true
      result += 1 + nodes(item.init) + nodes(item.lhs) + nodes(item.rhs) +
        nodes(item.cond) + nodes(item.lo) + nodes(item.hi) + nodes(item.value)
      for argument in item.args:
        result += nodes(argument)
      result += bodyNodes(item.body, hasBreak)
      result += bodyNodes(item.elseBody, hasBreak)
      for branch in item.elifs:
        result += nodes(branch.cond) + bodyNodes(branch.body, hasBreak)
      if result > config.maxBodyNodes:
        return
  proc copyBody(body: seq[Stmt], name: string, literal: int64): seq[Stmt]
  proc copyStatement(item: Stmt, name: string, literal: int64): Stmt =
    ## Gives each expansion independent syntax and lexical declarations.
    new(result)
    result[] = item[]
    result.init = expression(item.init, name, literal)
    result.lhs = expression(item.lhs, name, literal)
    result.rhs = expression(item.rhs, name, literal)
    result.cond = expression(item.cond, name, literal)
    result.lo = expression(item.lo, name, literal)
    result.hi = expression(item.hi, name, literal)
    result.value = expression(item.value, name, literal)
    result.args = @[]
    for argument in item.args:
      result.args.add(expression(argument, name, literal))
    result.body = copyBody(item.body, name, literal)
    result.elseBody = copyBody(item.elseBody, name, literal)
    result.elifs = @[]
    for branch in item.elifs:
      result.elifs.add(Elif(cond: expression(branch.cond, name, literal),
        body: copyBody(branch.body, name, literal)))
  proc copyBody(body: seq[Stmt], name: string, literal: int64): seq[Stmt] =
    ## Copies a statement sequence without sharing mutable AST nodes.
    for item in body:
      result.add(copyStatement(item, name, literal))
  var growth = 0
  proc transform(body: seq[Stmt]): seq[Stmt] =
    ## Selects bounded loops and leaves unsupported ranges on their old path.
    for item in body:
      var first, last: int64
      var count = -1
      var hasBreak = false
      let size = if item.kind == ForStmt:
          bodyNodes(item.body, hasBreak)
        else: 0
      if item.kind == ForStmt and config.maxIterations >= 0 and
          size <= config.maxBodyNodes and constant(item.lo, first) and
          constant(item.hi, last):
        if last < first or (last == first and not item.inclusive):
          count = 0
        else:
          let distance = cast[uint64](last) - cast[uint64](first)
          if distance <= uint64(config.maxIterations) and
              (not item.inclusive or distance < uint64(config.maxIterations)):
            count = int(distance) + ord(item.inclusive)
      let
        duplicates = max(0, count - 1)
        expandedSize = if count > 1: expandedBodyCost(item.body) else: 0
        fits = count >= 0 and config.maxGrowth >= growth and
          (duplicates == 0 or expandedSize <=
            (config.maxGrowth - growth) div duplicates)
        added = if fits: expandedSize * duplicates else: 0
      if fits:
        growth += added
        var expanded: seq[Stmt]
        for iteration in 0 ..< count:
          expanded.add(Stmt(kind: BlockStmt, line: item.line,
            body: copyBody(item.body, item.name, first + int64(iteration))))
        if hasBreak and count > 0:
          result.add(Stmt(kind: WhileStmt, line: item.line, maxTrips: 1,
            tripBound: 1, cond: Expr(kind: BoolExpr, line: item.line,
              typ: Typ(kind: BoolType), bval: true), body: expanded))
        else:
          result.add(Stmt(kind: BlockStmt, line: item.line, body: expanded))
      else:
        let copied = copyStatement(item, "", 0)
        copied.body = transform(item.body)
        copied.elseBody = transform(item.elseBody)
        for i in 0 ..< copied.elifs.len:
          copied.elifs[i].body = transform(item.elifs[i].body)
        result.add(copied)
  for routine in source.routines:
    var copied: Routine
    new(copied)
    copied[] = routine[]
    growth = 0
    copied.body = transform(routine.body)
    result.routines.add(copied)

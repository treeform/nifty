## Folds checked literals and branches, and expands small constant ranges.
import std/[sets, tables]
import types, semantics

type NativeUnrollConfig* = object
  maxIterations*: int
  maxBodyNodes*: int
  maxGrowth*: int

proc defaultNativeUnrollConfig*(): NativeUnrollConfig =
  ## Bounds duplicated transitive helper work independently in each routine.
  NativeUnrollConfig(maxIterations: 32, maxBodyNodes: 100, maxGrowth: 1024)

proc foldLiteral(value: Expr) =
  ## Only evaluates literal integer/boolean operands; calls and reads stay put.
  if value.isNil or value.typ.isNil or value.typ.opt or value.unwrapOpt or
      value.typ.kind notin {IntType, BoolType}:
    return
  var integer: int64
  var boolean: bool
  if value.kind == NegExpr and value.kids[0].kind == IntExpr:
    if value.kids[0].ival == low(int64): return
    integer = -value.kids[0].ival
  elif value.kind == NotExpr and value.kids[0].kind == BoolExpr:
    boolean = not value.kids[0].bval
  elif value.kind == BinExpr:
    let left = value.kids[0]
    let right = value.kids[1]
    if left.typ.opt or right.typ.opt: return
    if left.kind == BoolExpr and value.sval in ["and", "or"]:
      if value.sval == "and" and not left.bval:
        boolean = false
      elif value.sval == "or" and left.bval:
        boolean = true
      elif right.kind == BoolExpr:
        boolean = right.bval
      else:
        return
    elif left.kind == IntExpr and right.kind == IntExpr:
      let a = left.ival
      let b = right.ival
      case value.sval
      of "+":
        if (b > 0 and a > high(int64) - b) or
            (b < 0 and a < low(int64) - b): return
        integer = a + b
      of "-":
        if (b < 0 and a > high(int64) + b) or
            (b > 0 and a < low(int64) + b): return
        integer = a - b
      of "*":
        if a > 0:
          if (b > 0 and a > high(int64) div b) or
              (b < 0 and b < low(int64) div a): return
        elif a < 0:
          if (b > 0 and a < low(int64) div b) or
              (b < 0 and a < high(int64) div b): return
        integer = a * b
      of "/", "%":
        if b == 0 or (a == low(int64) and b == -1): return
        integer = if value.sval == "/": a div b else: a mod b
      of "==": boolean = a == b
      of "!=": boolean = a != b
      of "<": boolean = a < b
      of "<=": boolean = a <= b
      of ">": boolean = a > b
      of ">=": boolean = a >= b
      else: return
    else:
      return
  else:
    return
  if value.typ.kind == BoolType:
    value.kind = BoolExpr
    value.bval = boolean
  else:
    value.kind = IntExpr
    value.ival = integer
    value.rlo = integer
    value.rhi = integer
    value.rnz = integer != 0
  value.kids = @[]
  value.sval = ""

proc rangeOperand(value: Expr): bool =
  ## Restricts discarded evaluation to checked scalar reads and arithmetic.
  if value.isNil or value.typ.isNil or value.typ.kind != IntType or
      value.typ.opt or value.wrapOpt or value.unwrapOpt or value.rlo > value.rhi:
    return false
  case value.kind
  of IntExpr: true
  of IdentExpr: value.symKind in {ConstSym, LocalSym, ParamSym}
  of NegExpr: rangeOperand(value.kids[0])
  of BinExpr:
    value.sval in ["+", "-", "*"] and
      rangeOperand(value.kids[0]) and rangeOperand(value.kids[1])
  else: false

proc foldRangeComparison(value: Expr) =
  ## Uses facts proved at each expression's original evaluation point.
  if value.isNil or value.kind != BinExpr or value.typ.isNil or
      value.typ.kind != BoolType or value.typ.opt or value.wrapOpt or
      value.unwrapOpt or not rangeOperand(value.kids[0]) or
      not rangeOperand(value.kids[1]):
    return
  let
    a = value.kids[0]
    b = value.kids[1]
  var yes, no: bool
  case value.sval
  of "<":
    yes = a.rhi < b.rlo
    no = a.rlo >= b.rhi
  of "<=":
    yes = a.rhi <= b.rlo
    no = a.rlo > b.rhi
  of ">":
    yes = a.rlo > b.rhi
    no = a.rhi <= b.rlo
  of ">=":
    yes = a.rlo >= b.rhi
    no = a.rhi < b.rlo
  of "==", "!=":
    yes = a.rlo == a.rhi and b.rlo == b.rhi and a.rlo == b.rlo
    no = a.rhi < b.rlo or b.rhi < a.rlo or
      (a.rnz and b.rlo == 0 and b.rhi == 0) or
      (b.rnz and a.rlo == 0 and a.rhi == 0)
    if value.sval == "!=": swap(yes, no)
  else: return
  if yes or no:
    value.kind = BoolExpr
    value.bval = yes
    value.kids = @[]
    value.sval = ""

proc simplifyBranches(body: seq[Stmt]) =
  ## Retains a lexical scope for selected bodies so owner drops remain local.
  for item in body:
    simplifyBranches(item.body)
    simplifyBranches(item.elseBody)
    for branch in item.elifs:
      simplifyBranches(branch.body)
    if item.kind != IfStmt: continue
    var branches: seq[Elif]
    for branch in item.elifs:
      if branch.cond.kind != BoolExpr:
        branches.add(branch)
      elif branch.cond.bval:
        item.elseBody = branch.body
        break
    item.elifs = branches
    if branches.len == 0:
      item.kind = BlockStmt
      item.body = item.elseBody
      item.elseBody = @[]

proc unrollNative*(source: Module,
    config = defaultNativeUnrollConfig()): Module =
  ## Copies checked syntax and simplifies it before C or native lowering.
  source.requireChecked()
  new(result)
  result[] = source[]
  result.globals = @[]
  for global in source.globals:
    result.globals.add(global)
  result.routines = @[]
  var constants = initTable[string, int64]()
  for item in source.consts:
    constants[item.name] = item.value
  var locals = initTable[BindingId, Expr]()
  proc remember(item: Stmt, added: var seq[BindingId]) =
    ## Only immutable scalar literals can be substituted without evaluation.
    if item.kind == LetStmt and item.binding > 0 and item.typ != nil and
        not item.typ.opt and item.typ.kind in {IntType, BoolType} and
        item.init != nil and item.init.kind in {IntExpr, BoolExpr} and
        not item.init.wrapOpt and not item.init.unwrapOpt:
      locals[item.binding] = item.init
      added.add(item.binding)
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
      if value.symKind != ConstSym or value.sval notin constants:
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
    ## Substitutes checked scalar bindings and preserves each use's type.
    if value.isNil:
      return nil
    new(result)
    result[] = value[]
    result.kids = @[]
    if value.kind == IdentExpr and value.symKind == LocalSym and
        value.binding in locals and value.typ != nil and
        not value.typ.opt and not value.unwrapOpt:
      let literal = locals[value.binding]
      result.kind = literal.kind
      result.ival = literal.ival
      result.bval = literal.bval
      result.sval = ""
      result.rlo = literal.rlo
      result.rhi = literal.rhi
      result.rnz = literal.rnz
    elif value.kind == IdentExpr and value.typ != nil and value.typ.kind == IntType and
        not value.typ.opt and not value.unwrapOpt and
        ((name.len > 0 and value.sval == name and value.symKind == LocalSym) or
         (value.symKind == ConstSym and value.sval in constants)):
      let number = if value.symKind == ConstSym: constants[value.sval] else: literal
      result.kind = IntExpr
      result.ival = number
      result.sval = ""
      result.rlo = number
      result.rhi = number
      result.rnz = number != 0
    else:
      for child in value.kids:
        result.kids.add(expression(child, name, literal))
    foldLiteral(result)
    foldRangeComparison(result)
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
    var localBindings: seq[BindingId]
    defer:
      for binding in localBindings: locals.del(binding)
    for item in body:
      let copied = copyStatement(item, name, literal)
      result.add(copied)
      remember(copied, localBindings)
  var growth = 0
  proc transform(body: seq[Stmt]): seq[Stmt] =
    ## Selects bounded loops and leaves unsupported ranges on their old path.
    var localBindings: seq[BindingId]
    defer:
      for binding in localBindings: locals.del(binding)
    for item in body:
      var first, last: int64
      var count = -1
      var hasBreak = false
      let size = if item.kind == ForStmt:
          bodyNodes(item.body, hasBreak)
        else: 0
      if item.kind == ForStmt and config.maxIterations >= 0 and
          size <= config.maxBodyNodes and constant(expression(item.lo, "", 0), first) and
          constant(expression(item.hi, "", 0), last):
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
        remember(copied, localBindings)
  for routine in source.routines:
    var copied: Routine
    new(copied)
    copied[] = routine[]
    copied.params = @[]
    for parameter in routine.params:
      copied.params.add(parameter)
    growth = 0
    copied.body = transform(routine.body)
    simplifyBranches(copied.body)
    result.routines.add(copied)
  prepareSemantics(result)
  result.semantics.locks = source.semantics.locks
  result.semantics.channelProgress = source.semantics.channelProgress

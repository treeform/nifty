## Plans binding identity, borrowing, and cleanup for every backend.

import std/tables
import common, types

type
  Planner = object
    plan: SemanticPlan
    globals: Table[string, BindingId]
    names: seq[Table[string, BindingId]]
    owners: seq[seq[BindingId]]
    loops: seq[int]
    routine: string

proc requireChecked*(m: Module) =
  ## Requires the shared semantic checks before consuming a module.
  if m.isNil or m.semantics.isNil:
    raise newException(NiftyError,
      "module must pass semantic checking before backend generation " &
      "or reporting")

proc mode*(m: Module, binding: BindingId): BindingMode =
  ## Reads a binding's checked value, ownership, or borrow mode.
  m.requireChecked()
  if binding <= 0 or binding >= m.semantics.bindings.len:
    return UnplannedMode
  m.semantics.bindings[binding].mode

proc isBorrow*(mode: BindingMode): bool =
  ## Identifies semantic borrows independently of target representation.
  mode in {ReadBorrowMode, MutBorrowMode}

proc addBinding(p: var Planner, name: string, line: int, typ: Typ,
    mode: BindingMode, kind: SymKind): BindingId =
  ## Gives each declaration a stable identity within the checked module.
  result = p.plan.bindings.len
  p.plan.bindings.add(SemanticBinding(name: name, routine: p.routine,
    line: line, typ: typ, mode: mode, kind: kind))
  p.plan.usesHeap = p.plan.usesHeap or hasOwned(typ)

proc resolve(p: Planner, name: string): BindingId =
  ## Resolves names against the checked source's lexical scopes.
  for i in countdown(p.names.high, 0):
    if name in p.names[i]:
      return p.names[i][name]
  p.globals.getOrDefault(name)

proc expression(p: var Planner, e: Expr) =
  ## Records resolved identities on expression references.
  if e.isNil:
    return
  e.binding = 0
  if e.kind == IdentExpr:
    e.binding = p.resolve(e.sval)
    if e.binding == 0:
      raise newException(NiftyError,
        "checked module has an unresolved binding: " & e.sval)
  for child in e.kids:
    p.expression(child)

proc drops(p: Planner, first: int): seq[BindingId] =
  ## Orders currently live owners from innermost and newest to oldest.
  for i in countdown(p.owners.high, first):
    for j in countdown(p.owners[i].high, 0):
      result.add(p.owners[i][j])

proc body(p: var Planner, statements: seq[Stmt],
    initial: seq[BindingId] = @[], loop = false): int

proc statement(p: var Planner, s: Stmt) =
  ## Plans one checked statement before later declarations become live.
  s.binding = 0
  s.binding2 = 0
  s.bodyScope = 0
  s.elseScope = 0
  s.drops.setLen(0)
  p.plan.usesHeap = p.plan.usesHeap or hasOwned(s.typ)
  for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
    p.expression(e)
  for e in s.args:
    p.expression(e)
  case s.kind
  of VarStmt, LetStmt:
    let mode = if hasOwned(s.typ): OwnerMode else: ValueMode
    s.binding = p.addBinding(s.name, s.line, s.typ, mode, LocalSym)
    p.names[^1][s.name] = s.binding
    if mode == OwnerMode:
      p.owners[^1].add(s.binding)
  of ForStmt, ForEachStmt:
    let
      typ = if s.kind == ForStmt: intType() else: s.typ
      mode = if hasOwned(typ): ReadBorrowMode else: ValueMode
    s.binding = p.addBinding(s.name, s.line, typ, mode, LocalSym)
    var initial = @[s.binding]
    if s.name2.len > 0:
      let mode = if hasOwned(s.typ2): ReadBorrowMode else: ValueMode
      s.binding2 = p.addBinding(s.name2, s.line, s.typ2, mode, LocalSym)
      initial.add(s.binding2)
    s.bodyScope = p.body(s.body, initial, loop = true)
  of WhileStmt, LoopStmt:
    s.bodyScope = p.body(s.body, loop = true)
  of IfStmt:
    for branch in s.elifs.mitems:
      p.expression(branch.cond)
      branch.scope = p.body(branch.body)
    s.elseScope = p.body(s.elseBody)
  of WithStmt, BlockStmt:
    if s.kind == WithStmt:
      s.binding = p.resolve(s.name)
    s.bodyScope = p.body(s.body)
  of ReturnStmt:
    s.drops = p.drops(0)
  of BreakStmt:
    if p.loops.len == 0:
      raise newException(NiftyError,
        "checked module has a break outside a loop")
    s.drops = p.drops(p.loops[^1])
  of AssignStmt, EchoStmt, DiscardStmt, CallStmt:
    discard

proc body(p: var Planner, statements: seq[Stmt],
    initial: seq[BindingId] = @[], loop = false): int =
  ## Records normal scope cleanup and every explicit exit inside it.
  result = p.plan.scopes.len
  p.plan.scopes.add(SemanticScope())
  let first = p.owners.len
  p.names.add(initTable[string, BindingId]())
  p.owners.add(@[])
  for binding in initial:
    p.names[^1][p.plan.bindings[binding].name] = binding
  if loop:
    p.loops.add(first)
  for s in statements:
    p.statement(s)
  p.plan.scopes[result].drops = p.drops(first)
  if loop:
    discard p.loops.pop()
  discard p.names.pop()
  discard p.owners.pop()

proc prepareSemantics*(m: Module) =
  ## Publishes backend-neutral lifetime decisions after source checking.
  m.semantics = nil
  var p = Planner(plan: SemanticPlan(
    bindings: @[SemanticBinding()], scopes: @[SemanticScope()]))
  for constant in m.consts:
    let typ = intType(constant.value, constant.value)
    let binding = p.addBinding(constant.name, constant.line, typ,
      ValueMode, ConstSym)
    p.globals[constant.name] = binding
  for global in m.globals.mitems:
    let mode = if hasOwned(global.typ): OwnerMode else: ValueMode
    global.binding = p.addBinding(global.name, global.line, global.typ,
      mode, GlobalSym)
    p.globals[global.name] = global.binding
  for global in countdown(m.globals.high, 0):
    let binding = m.globals[global].binding
    if p.plan.bindings[binding].mode == OwnerMode:
      p.plan.globalDrops.add(binding)
  for definition in m.types:
    p.plan.usesHeap = p.plan.usesHeap or hasOwned(definition.typ)
  for routine in m.routines:
    p.routine = routine.name
    p.plan.usesHeap = p.plan.usesHeap or hasOwned(routine.ret)
    var initial: seq[BindingId]
    for parameter in routine.params.mitems:
      let mode = if parameter.isVar: MutBorrowMode
        elif hasOwned(parameter.typ) or parameter.typ.kind == ArrayType:
          ReadBorrowMode
        else: ValueMode
      parameter.binding = p.addBinding(parameter.name, routine.line,
        parameter.typ, mode, ParamSym)
      initial.add(parameter.binding)
    routine.bodyScope = p.body(routine.body, initial)
  m.semantics = p.plan

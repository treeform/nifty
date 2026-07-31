## Semantic checker: enforces the rules that make nifty provable.
## No recursion (declare-before-use), func purity, thread constraints,
## with-block protocol and escape rules, types.

import std/[tables, sets]
import common, types

type
  Sym = object
    kind: SymKind
    typ: Typ
    mutable: bool
    isVarParam: bool
  Ctx = object
    consts: Table[string, int64]
    globals: Table[string, Typ]
    routineTab: Table[string, Routine]
    allRoutines: HashSet[string]
    checked: HashSet[string]   # routines whose bodies passed the checker
    cur: Routine
    scopes: seq[Table[string, Sym]]
    withDepth: int
    loopWiths: seq[int]        # withDepth at entry of each enclosing loop

proc isDeclared(c: Ctx, name: string): bool =
  for sc in c.scopes:
    if name in sc:
      return true
  name in c.consts or name in c.globals or name in c.allRoutines

proc checkExpr(c: var Ctx, e: Expr): Typ

proc expectVal(c: var Ctx, e: Expr): Typ =
  result = c.checkExpr(e)
  if result.isNil:
    err(e.line, "'" & e.sval & "' does not return a value")

proc resolveIdent(c: var Ctx, e: Expr) =
  let name = e.sval
  for i in countdown(c.scopes.len - 1, 0):
    if name in c.scopes[i]:
      let s = c.scopes[i][name]
      e.symKind = s.kind
      e.mut = s.mutable
      e.isVarParam = s.isVarParam
      e.typ = s.typ
      return
  if name in c.consts:
    e.symKind = syConst
    e.mut = false
    e.typ = Typ(kind: tyInt)
    return
  if name in c.globals:
    if c.cur.kind == rkFunc:
      err(e.line, "func '" & c.cur.name & "' cannot access global '" & name & "'")
    let t = c.globals[name]
    if t.kind == tyLock:
      err(e.line, "'" & name & "' is a Lock; it can only be used in a with statement")
    e.symKind = syGlobal
    e.mut = true
    e.typ = t
    return
  if name in c.allRoutines:
    err(e.line, "'" & name & "' is a routine, not a value (call it with parentheses)")
  err(e.line, "unknown identifier: '" & name & "'")

proc rootIdent(e: Expr): Expr =
  result = e
  while result.kind in {ekIndex, ekField}:
    result = result.kids[0]

proc checkExpr(c: var Ctx, e: Expr): Typ =
  case e.kind
  of ekInt:
    e.typ = Typ(kind: tyInt)
  of ekBool:
    e.typ = Typ(kind: tyBool)
  of ekStr:
    e.typ = Typ(kind: tyString)
  of ekIdent:
    c.resolveIdent(e)
  of ekNeg:
    if c.expectVal(e.kids[0]).kind != tyInt:
      err(e.line, "unary '-' needs an int operand")
    e.typ = Typ(kind: tyInt)
  of ekNot:
    if c.expectVal(e.kids[0]).kind != tyBool:
      err(e.line, "'not' needs a bool operand")
    e.typ = Typ(kind: tyBool)
  of ekBin:
    let a = c.expectVal(e.kids[0])
    let b = c.expectVal(e.kids[1])
    case e.sval
    of "+", "-", "*", "/", "%":
      if a.kind != tyInt or b.kind != tyInt:
        err(e.line, "'" & e.sval & "' needs int operands, got " & $a & " and " & $b)
      e.typ = Typ(kind: tyInt)
    of "<", "<=", ">", ">=":
      if a.kind != tyInt or b.kind != tyInt:
        err(e.line, "'" & e.sval & "' needs int operands, got " & $a & " and " & $b)
      e.typ = Typ(kind: tyBool)
    of "==", "!=":
      if not typEq(a, b) or a.kind notin {tyInt, tyBool}:
        err(e.line, "'" & e.sval & "' needs two ints or two bools, got " &
          $a & " and " & $b)
      e.typ = Typ(kind: tyBool)
    of "and", "or":
      if a.kind != tyBool or b.kind != tyBool:
        err(e.line, "'" & e.sval & "' needs bool operands, got " & $a & " and " & $b)
      e.typ = Typ(kind: tyBool)
    else:
      err(e.line, "internal: unknown operator " & e.sval)
  of ekIndex:
    let base = c.expectVal(e.kids[0])
    if base.kind != tyArray:
      err(e.line, "'[]' needs an array, got " & $base)
    if c.expectVal(e.kids[1]).kind != tyInt:
      err(e.line, "array index must be an int")
    e.typ = base.elem
  of ekField:
    let base = c.expectVal(e.kids[0])
    if base.kind != tyObject:
      err(e.line, "'.' needs an object, got " & $base)
    for f in base.fields:
      if f.name == e.sval:
        e.typ = f.typ
        break
    if e.typ.isNil:
      err(e.line, "type " & base.name & " has no field '" & e.sval & "'")
  of ekCall:
    let name = e.sval
    if name notin c.allRoutines:
      err(e.line, "unknown func or proc: '" & name & "'")
    if name == c.cur.name:
      err(e.line, "recursion is not allowed: '" & name & "' calls itself")
    if name notin c.checked:
      err(e.line, "'" & name & "' is called before its declaration " &
        "(declare-before-use keeps the call graph recursion-free)")
    let r = c.routineTab[name]
    if r.kind == rkThread:
      err(e.line, "threads start at program start; they cannot be called")
    if c.cur.kind == rkFunc and r.kind != rkFunc:
      err(e.line, "func '" & c.cur.name & "' can only call other funcs; '" &
        name & "' is a " & $r.kind)
    if e.kids.len != r.params.len:
      err(e.line, "'" & name & "' expects " & $r.params.len &
        " argument(s), got " & $e.kids.len)
    for i, arg in e.kids:
      let pt = r.params[i]
      let at = c.expectVal(arg)
      if not typEq(at, pt.typ):
        err(arg.line, "argument " & $(i + 1) & " of '" & name & "': expected " &
          $pt.typ & ", got " & $at)
      if pt.isVar:
        if arg.kind notin {ekIdent, ekIndex, ekField}:
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must be a variable")
        let root = arg.rootIdent
        if root.kind != ekIdent or not root.mut:
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must be mutable")
    e.typ = r.ret
  e.typ

proc checkStmt(c: var Ctx, s: Stmt, topLevel: bool)

proc checkBody(c: var Ctx, body: seq[Stmt]) =
  c.scopes.add initTable[string, Sym]()
  for s in body:
    c.checkStmt(s, false)
  discard c.scopes.pop

proc checkStmt(c: var Ctx, s: Stmt, topLevel: bool) =
  case s.kind
  of skVar, skLet:
    if s.typ != nil and s.typ.kind == tyLock:
      err(s.line, "a Lock must be a global")
    var t = s.typ
    if s.init != nil:
      let it = c.expectVal(s.init)
      if it.kind == tyString:
        err(s.line, "string values only exist as echo arguments in v0")
      if it.kind == tyArray:
        err(s.line, "arrays cannot be copied; copy elements in a loop")
      if t == nil:
        t = it
      elif not typEq(t, it):
        err(s.line, "type mismatch: declared " & $t & ", initializer is " & $it)
    else:
      if s.kind == skLet:
        err(s.line, "let requires an initializer")
      if t == nil:
        err(s.line, "variable needs a type or an initializer")
    if c.isDeclared(s.name):
      err(s.line, "'" & s.name & "' is already declared (shadowing is not allowed)")
    s.typ = t
    c.scopes[^1][s.name] = Sym(kind: syLocal, typ: t, mutable: s.kind == skVar)
  of skAssign:
    let lt = c.expectVal(s.lhs)
    let root = s.lhs.rootIdent
    if root.kind != ekIdent:
      err(s.lhs.line, "cannot assign to this expression")
    if not root.mut:
      err(s.lhs.line, "cannot assign to immutable '" & root.sval & "'")
    if lt.kind == tyArray:
      err(s.lhs.line, "whole-array assignment is not allowed; copy elements in a loop")
    let rt = c.expectVal(s.rhs)
    if not typEq(lt, rt):
      err(s.line, "type mismatch: cannot assign " & $rt & " to " & $lt)
  of skIf:
    for br in s.elifs:
      if c.expectVal(br.cond).kind != tyBool:
        err(br.cond.line, "condition must be a bool")
      c.checkBody(br.body)
    if s.elseBody.len > 0:
      c.checkBody(s.elseBody)
  of skWhile:
    if c.expectVal(s.cond).kind != tyBool:
      err(s.cond.line, "condition must be a bool")
    c.loopWiths.add c.withDepth
    c.checkBody(s.body)
    discard c.loopWiths.pop
  of skFor:
    if c.expectVal(s.lo).kind != tyInt or c.expectVal(s.hi).kind != tyInt:
      err(s.line, "for loop bounds must be ints")
    if c.isDeclared(s.name):
      err(s.line, "'" & s.name & "' is already declared (shadowing is not allowed)")
    c.scopes.add initTable[string, Sym]()
    c.scopes[^1][s.name] = Sym(kind: syLocal, typ: Typ(kind: tyInt), mutable: false)
    c.loopWiths.add c.withDepth
    for st in s.body:
      c.checkStmt(st, false)
    discard c.loopWiths.pop
    discard c.scopes.pop
  of skLoop:
    if c.cur.kind != rkThread or not topLevel:
      err(s.line, "loop is only allowed at the top level of a thread body")
    c.loopWiths.add c.withDepth
    c.checkBody(s.body)
    discard c.loopWiths.pop
  of skWith:
    if c.cur.kind == rkFunc:
      err(s.line, "with is not allowed in func (start/end are side effects)")
    if s.name in c.globals and c.globals[s.name].kind == tyLock:
      # Builtin protocol: start = acquire the mutex, end = release it.
      s.typ = c.globals[s.name]
    else:
      # User protocol: with x calls start(x) on entry and end(x) on exit.
      let t = c.expectVal(s.lhs)
      if not s.lhs.mut:
        err(s.line, "with target '" & s.name & "' must be mutable")
      let want = "proc name(x: var " & $t & ")"
      for pn in ["start", "end"]:
        if pn notin c.allRoutines:
          err(s.line, "with on a " & $t & " needs a '" & pn & "' proc: " & want)
        if pn notin c.checked:
          err(s.line, "'" & pn & "' must be declared before this with statement")
        let r = c.routineTab[pn]
        if r.kind != rkProc or r.params.len != 1 or not r.params[0].isVar or
            not typEq(r.params[0].typ, t) or not r.ret.isNil:
          err(s.line, "with on a " & $t & " needs '" & pn & "' to be: " & want)
      s.typ = t
    inc c.withDepth
    c.checkBody(s.body)
    dec c.withDepth
  of skReturn:
    if c.withDepth > 0:
      err(s.line, "cannot return inside a with block (its end would never run)")
    if c.cur.kind == rkThread:
      err(s.line, "threads do not return; let the body end instead")
    if c.cur.ret.isNil:
      if s.value != nil:
        err(s.line, "'" & c.cur.name & "' has no return type")
    else:
      if s.value == nil:
        err(s.line, "return needs a value of type " & $c.cur.ret)
      let t = c.expectVal(s.value)
      if not typEq(t, c.cur.ret):
        err(s.line, "return type mismatch: got " & $t & ", expected " & $c.cur.ret)
  of skBreak:
    if c.loopWiths.len == 0:
      err(s.line, "break outside a loop")
    if c.withDepth != c.loopWiths[^1]:
      err(s.line, "cannot break out of a with block (its end would never run)")
  of skEcho:
    if c.cur.kind == rkFunc:
      err(s.line, "echo is a side effect; not allowed in func")
    for a in s.args:
      if c.expectVal(a).kind notin {tyInt, tyBool, tyString}:
        err(a.line, "cannot echo a " & $a.typ)
  of skDiscard:
    discard c.checkExpr(s.value)
  of skCall:
    let t = c.checkExpr(s.value)
    if not t.isNil:
      err(s.line, "return value of '" & s.value.sval &
        "' is discarded (use discard or assign it)")

proc alwaysReturns(body: seq[Stmt]): bool =
  if body.len == 0:
    return false
  let s = body[^1]
  case s.kind
  of skReturn:
    true
  of skIf:
    if s.elseBody.len == 0:
      return false
    for br in s.elifs:
      if not alwaysReturns(br.body):
        return false
    alwaysReturns(s.elseBody)
  else:
    false

proc check*(m: Module) =
  ## Check the whole module; raises NiftyError on the first violation.
  var c = Ctx()
  var used: HashSet[string]
  for td in m.types:
    if td.name in used:
      err(td.line, "duplicate name: '" & td.name & "'")
    used.incl td.name
  for cd in m.consts:
    if cd.name in used:
      err(cd.line, "duplicate name: '" & cd.name & "'")
    used.incl cd.name
    c.consts[cd.name] = cd.value
  for gd in m.globals:
    if gd.name in used:
      err(gd.line, "duplicate name: '" & gd.name & "'")
    used.incl gd.name
    c.globals[gd.name] = gd.typ
  var anyThread = false
  for r in m.routines:
    if r.name in used:
      err(r.line, "duplicate name: '" & r.name & "'")
    used.incl r.name
    c.allRoutines.incl r.name
    c.routineTab[r.name] = r
    if r.kind == rkThread:
      anyThread = true
  if not anyThread:
    err(1, "a nifty program needs at least one thread (thread name() = ...)")
  for r in m.routines:
    c.cur = r
    c.withDepth = 0
    c.loopWiths = @[]
    case r.kind
    of rkThread:
      if r.params.len > 0:
        err(r.line, "threads take no parameters")
      if not r.ret.isNil:
        err(r.line, "threads do not return a value")
    of rkFunc:
      if r.ret.isNil:
        err(r.line, "func must have a return type (use proc for side effects)")
    of rkProc:
      discard
    var paramScope = initTable[string, Sym]()
    for pm in r.params:
      if pm.typ.kind == tyLock:
        err(r.line, "a Lock cannot be a parameter")
      if pm.isVar and r.kind == rkFunc:
        err(r.line, "func parameters are read-only; var parameters are not allowed")
      if pm.name in paramScope or pm.name in used:
        err(r.line, "duplicate or shadowing parameter name: '" & pm.name & "'")
      paramScope[pm.name] = Sym(kind: syParam, typ: pm.typ,
        mutable: pm.isVar, isVarParam: pm.isVar)
    c.scopes = @[paramScope, initTable[string, Sym]()]
    for s in r.body:
      c.checkStmt(s, true)
    if not r.ret.isNil and not alwaysReturns(r.body):
      err(r.line, "'" & r.name & "': not all code paths return a value")
    c.checked.incl r.name

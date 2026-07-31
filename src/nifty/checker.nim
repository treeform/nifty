## Semantic checker: enforces the rules that make nifty provable.
## No recursion (declare-before-use), func purity, thread constraints,
## with-block protocol and escape rules — and the static proofs: every
## division, every array index, and every arithmetic operation must be
## proven safe at compile time. The generated C has no runtime checks.
##
## The proof engine is interval analysis: every int expression gets a
## proven [lo, hi] range (plus a separate nonzero bit, since an interval
## cannot express "anything but zero"). Declared range types are
## invariants enforced at every store; flow facts refine locals between
## tests and uses. Globals and var params never carry flow facts —
## another thread (or an alias) could change them between test and use —
## so their declared range is all the checker will believe.

import std/[strutils, tables, sets]
import common, types

type
  Fact = object
    ## What is proven about an int value at some program point.
    lo, hi: int64
    notZero: bool
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
    facts: Table[string, Fact] # names with refined ranges at this point
    heldLocks: seq[string]     # Lock names currently held (lexical with-stack)
    sharedProt: Table[string, HashSet[string]] # shared global -> its lock(s)
    routineWrites: Table[string, HashSet[string]] # routine -> globals it may write

const
  IntLow = low(int64)
  IntHigh = high(int64)

proc fullFact(): Fact =
  Fact(lo: IntLow, hi: IntHigh, notZero: false)

proc typFact(t: Typ): Fact =
  ## The fact implied by a declared type: its range invariant.
  if t != nil and t.kind == tyInt:
    Fact(lo: t.rlo, hi: t.rhi, notZero: t.rlo > 0 or t.rhi < 0)
  else:
    fullFact()

proc rangeStr(lo, hi: int64): string =
  if lo == IntLow and hi == IntHigh: "int"
  elif lo == hi: $lo
  else: $lo & " .. " & $hi

proc rangeStr(f: Fact): string =
  rangeStr(f.lo, f.hi)

proc fits(f: Fact, t: Typ): bool =
  t.kind != tyInt or (f.lo >= t.rlo and f.hi <= t.rhi)

# --- saturating interval arithmetic ---------------------------------------
# Each op reports whether the true result could overflow int64; the checker
# turns that into a compile error, which is the overflow proof.

proc satAdd(a, b: int64): tuple[v: int64, ov: bool] =
  if b > 0 and a > IntHigh - b: (IntHigh, true)
  elif b < 0 and a < IntLow - b: (IntLow, true)
  else: (a + b, false)

proc satSub(a, b: int64): tuple[v: int64, ov: bool] =
  if b < 0 and a > IntHigh + b: (IntHigh, true)
  elif b > 0 and a < IntLow + b: (IntLow, true)
  else: (a - b, false)

proc satMul(a, b: int64): tuple[v: int64, ov: bool] =
  if a == 0 or b == 0:
    (0'i64, false)
  elif a > 0 and b > 0:
    if a > IntHigh div b: (IntHigh, true) else: (a * b, false)
  elif a > 0 and b < 0:
    if b < IntLow div a: (IntLow, true) else: (a * b, false)
  elif a < 0 and b > 0:
    if a < IntLow div b: (IntLow, true) else: (a * b, false)
  else: # both negative
    if b < IntHigh div a: (IntHigh, true) else: (a * b, false)

proc satNeg(a: int64): tuple[v: int64, ov: bool] =
  if a == IntLow: (IntHigh, true) else: (-a, false)

proc maxMag(f: Fact): int64 =
  ## Largest absolute value in the interval, saturated.
  let (nl, ovl) = satNeg(f.lo)
  let m = if ovl: IntHigh else: nl
  max(m, max(f.hi, 0'i64))

proc addF(a, b: Fact): tuple[f: Fact, ov: bool] =
  let l = satAdd(a.lo, b.lo)
  let h = satAdd(a.hi, b.hi)
  (Fact(lo: l.v, hi: h.v), l.ov or h.ov)

proc subF(a, b: Fact): tuple[f: Fact, ov: bool] =
  let l = satSub(a.lo, b.hi)
  let h = satSub(a.hi, b.lo)
  (Fact(lo: l.v, hi: h.v), l.ov or h.ov)

proc mulF(a, b: Fact): tuple[f: Fact, ov: bool] =
  var lo = IntHigh
  var hi = IntLow
  var ov = false
  for x in [a.lo, a.hi]:
    for y in [b.lo, b.hi]:
      let r = satMul(x, y)
      ov = ov or r.ov
      lo = min(lo, r.v)
      hi = max(hi, r.v)
  (Fact(lo: lo, hi: hi), ov)

proc divF(a, b: Fact): Fact =
  ## Divisor is already proven nonzero and the int64.min / -1 case is
  ## already excluded by the caller.
  if b.lo > 0 or b.hi < 0:
    var lo = IntHigh
    var hi = IntLow
    for x in [a.lo, a.hi]:
      for y in [b.lo, b.hi]:
        let r = x div y
        lo = min(lo, r)
        hi = max(hi, r)
    Fact(lo: lo, hi: hi)
  else:
    # Nonzero but sign-unknown divisor: |result| <= |dividend|.
    let m = maxMag(a)
    let (nm, _) = satNeg(m)
    Fact(lo: nm, hi: m)

proc modF(a, b: Fact): Fact =
  ## Divisor proven nonzero; |result| < |divisor| and sign follows dividend.
  let m = maxMag(b)
  let bound = if m == 0: 0'i64 else: m - 1
  var lo = if a.lo >= 0: 0'i64 else: -bound
  var hi = bound
  if a.lo >= 0:
    hi = min(hi, a.hi)
  Fact(lo: lo, hi: hi)

# --- symbol handling ------------------------------------------------------

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
    e.typ = intType()
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

proc declFactByName(c: Ctx, name: string): Fact =
  for i in countdown(c.scopes.len - 1, 0):
    if name in c.scopes[i]:
      return typFact(c.scopes[i][name].typ)
  if name in c.globals:
    return typFact(c.globals[name])
  fullFact()

proc curFact(c: Ctx, name: string): Fact =
  c.facts.getOrDefault(name, c.declFactByName(name))

# --- facts ----------------------------------------------------------------

proc tryConstEval(c: Ctx, e: Expr): tuple[known: bool, val: int64] =
  ## Evaluate an expression at compile time if possible.
  case e.kind
  of ekInt:
    (true, e.ival)
  of ekIdent:
    if e.sval in c.consts:
      (true, c.consts[e.sval])
    else:
      (false, 0'i64)
  of ekNeg:
    let r = c.tryConstEval(e.kids[0])
    (r.known, -r.val)
  of ekBin:
    let a = c.tryConstEval(e.kids[0])
    let b = c.tryConstEval(e.kids[1])
    if not (a.known and b.known):
      (false, 0'i64)
    else:
      case e.sval
      of "+": (true, a.val + b.val)
      of "-": (true, a.val - b.val)
      of "*": (true, a.val * b.val)
      of "/":
        if b.val == 0: (false, 0'i64) else: (true, a.val div b.val)
      of "%":
        if b.val == 0: (false, 0'i64) else: (true, a.val mod b.val)
      else: (false, 0'i64)
  else:
    (false, 0'i64)

proc factName(c: Ctx, e: Expr): string =
  ## The name a flow fact can attach to. Locals and non-var parameters
  ## always qualify. A global qualifies when it is thread-owned (accessed
  ## by at most one thread) or when the lock that protects it is currently
  ## held — in both cases no other thread can change it between a test
  ## and a use. Var params never qualify (they may alias anything).
  if e.kind != ekIdent or e.typ == nil or e.typ.kind != tyInt:
    return ""
  case e.symKind
  of syLocal:
    e.sval
  of syParam:
    if e.isVarParam: "" else: e.sval
  of syGlobal:
    if e.sval notin c.sharedProt:
      e.sval # thread-owned (or never written): sequential here
    else:
      for l in c.heldLocks:
        if l in c.sharedProt[e.sval]:
          return e.sval
      ""
  else:
    ""

proc flipCmp(op: string): string =
  case op
  of "<": ">"
  of "<=": ">="
  of ">": "<"
  of ">=": "<="
  else: op

proc negateCmp(op: string): string =
  case op
  of "==": "!="
  of "!=": "=="
  of "<": ">="
  of "<=": ">"
  of ">": "<="
  of ">=": "<"
  else: op

proc cmpFact(c: Ctx, e: Expr): tuple[name: string, op: string, k: int64] =
  ## Normalize a comparison to (localName op constant); name is "" otherwise.
  result = ("", "", 0'i64)
  if e.kind != ekBin or e.sval notin ["==", "!=", "<", "<=", ">", ">="]:
    return
  let lc = c.tryConstEval(e.kids[0])
  let rc = c.tryConstEval(e.kids[1])
  if c.factName(e.kids[0]) != "" and rc.known:
    result = (e.kids[0].sval, e.sval, rc.val)
  elif c.factName(e.kids[1]) != "" and lc.known:
    result = (e.kids[1].sval, flipCmp(e.sval), lc.val)

proc applyCmpFact(c: var Ctx, name, op: string, k: int64) =
  var f = c.curFact(name)
  case op
  of "<": f.hi = min(f.hi, satSub(k, 1).v)
  of "<=": f.hi = min(f.hi, k)
  of ">": f.lo = max(f.lo, satAdd(k, 1).v)
  of ">=": f.lo = max(f.lo, k)
  of "==":
    f.lo = max(f.lo, k)
    f.hi = min(f.hi, k)
  of "!=":
    if k == 0:
      f.notZero = true
  else:
    discard
  if f.lo > 0 or f.hi < 0:
    f.notZero = true
  c.facts[name] = f

proc addCondFacts(c: var Ctx, e: Expr, negated = false) =
  ## Record what is proven when `e` is true (or false, if negated).
  if e.kind == ekNot:
    c.addCondFacts(e.kids[0], not negated)
    return
  if e.kind != ekBin:
    return
  if not negated and e.sval == "and":
    c.addCondFacts(e.kids[0])
    c.addCondFacts(e.kids[1])
    return
  if negated and e.sval == "or":
    c.addCondFacts(e.kids[0], true)
    c.addCondFacts(e.kids[1], true)
    return
  let f = c.cmpFact(e)
  if f.name == "":
    return
  let op = if negated: negateCmp(f.op) else: f.op
  c.applyCmpFact(f.name, op, f.k)

proc joinFacts(c: Ctx, tabs: seq[Table[string, Fact]]): Table[string, Fact] =
  ## The hull of the facts along several joining paths. A name missing on
  ## one path falls back to its declared range there.
  var names: HashSet[string]
  for t in tabs:
    for k in t.keys:
      names.incl k
  for n in names:
    var f = tabs[0].getOrDefault(n, c.declFactByName(n))
    for i in 1 ..< tabs.len:
      let g = tabs[i].getOrDefault(n, c.declFactByName(n))
      f.lo = min(f.lo, g.lo)
      f.hi = max(f.hi, g.hi)
      f.notZero = f.notZero and g.notZero
    result[n] = f

proc collectAssignedExpr(c: Ctx, e: Expr, s: var HashSet[string]) =
  if e.isNil:
    return
  if e.kind == ekCall and e.sval in c.routineTab:
    let r = c.routineTab[e.sval]
    for i, arg in e.kids:
      if i < r.params.len and r.params[i].isVar:
        let root = arg.rootIdent
        if root.kind == ekIdent:
          s.incl root.sval
    if e.sval in c.routineWrites:
      for g in c.routineWrites[e.sval]:
        s.incl g
  for k in e.kids:
    c.collectAssignedExpr(k, s)

proc collectAssigned(c: Ctx, body: seq[Stmt], s: var HashSet[string]) =
  ## Names a body might change: assignment targets, var arguments, and
  ## with targets. Facts about them cannot survive a loop iteration.
  for st in body:
    for e in [st.init, st.lhs, st.rhs, st.cond, st.lo, st.hi, st.value]:
      c.collectAssignedExpr(e, s)
    for a in st.args:
      c.collectAssignedExpr(a, s)
    if st.kind == skAssign:
      let root = st.lhs.rootIdent
      if root.kind == ekIdent:
        s.incl root.sval
    if st.kind == skWith:
      s.incl st.name
    c.collectAssigned(st.body, s)
    for br in st.elifs:
      c.collectAssignedExpr(br.cond, s)
      c.collectAssigned(br.body, s)
    c.collectAssigned(st.elseBody, s)

proc dropAssigned(c: var Ctx, body: seq[Stmt]) =
  var assigned: HashSet[string]
  c.collectAssigned(body, assigned)
  for n in assigned:
    c.facts.del n

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

proc alwaysExits(body: seq[Stmt]): bool =
  ## Does this body always leave the enclosing block (return or break)?
  body.len > 0 and (body[^1].kind in {skReturn, skBreak} or alwaysReturns(body))

proc hasLoopBreak(body: seq[Stmt]): bool =
  ## Is there a break that targets the enclosing loop (not a nested one)?
  for st in body:
    case st.kind
    of skBreak:
      return true
    of skWhile, skFor, skLoop:
      discard # a break in there targets the inner loop
    of skIf:
      for br in st.elifs:
        if hasLoopBreak(br.body):
          return true
      if hasLoopBreak(st.elseBody):
        return true
    of skWith:
      if hasLoopBreak(st.body):
        return true
    else:
      discard

# --- termination proof ----------------------------------------------------

proc condZeroExit(c: Ctx, cond: Expr, v: string): bool =
  ## Does the condition guarantee |v| >= 1 while the loop keeps running?
  ## (Needed for halving progress: v = v / k stalls at 0.)
  let f = c.cmpFact(cond)
  if f.name != v:
    return false
  case f.op
  of "!=": f.k == 0
  of ">": f.k >= 0
  of ">=": f.k >= 1
  of "<": f.k <= 0
  of "<=": f.k <= -1
  else: false

proc whileBound(c: Ctx, s: Stmt): int64 =
  ## The proven worst-case iteration count of a while loop, or 0 if none.
  ## A loop is bounded if some finite-ranged local makes strict progress
  ## on every iteration: every assignment to it is v = v + k or v = v - k
  ## (same direction, const k >= 1), at least one of them at the top
  ## level of the body — or v = v / k (|k| >= 2) with a condition that
  ## exits at zero (halving stalls at 0).
  type Cand = object
    dir: int # +1 inc, -1 dec, 2 halving, 0 none
    minStep: int64
    top: bool
    bad: bool
  var cands: Table[string, Cand]

  proc classify(st: Stmt, top: bool) =
    if st.kind == skAssign and st.lhs.kind == ekIdent:
      let v = st.lhs.sval
      var cd = cands.getOrDefault(v, Cand())
      var thisDir = 0
      var step = 1'i64
      let r = st.rhs
      if r.kind == ekBin and r.kids[0].kind == ekIdent and r.kids[0].sval == v:
        let kc = c.tryConstEval(r.kids[1])
        if kc.known:
          if r.sval == "+" and kc.val >= 1:
            thisDir = 1
            step = kc.val
          elif r.sval == "-" and kc.val >= 1:
            thisDir = -1
            step = kc.val
          elif r.sval == "/" and (kc.val >= 2 or kc.val <= -2):
            thisDir = 2
      if thisDir == 0 or (cd.dir != 0 and cd.dir != thisDir):
        cd.bad = true
      else:
        cd.dir = thisDir
        cd.minStep = if cd.minStep == 0: step else: min(cd.minStep, step)
        if top:
          cd.top = true
      cands[v] = cd
    if st.kind == skWith:
      var cd = cands.getOrDefault(st.name, Cand())
      cd.bad = true
      cands[st.name] = cd
    # Anything touched through a var argument makes an unknown change.
    var touched: HashSet[string]
    for e in [st.init, st.lhs, st.rhs, st.cond, st.lo, st.hi, st.value]:
      c.collectAssignedExpr(e, touched)
    for a in st.args:
      c.collectAssignedExpr(a, touched)
    for t in touched:
      var cd = cands.getOrDefault(t, Cand())
      cd.bad = true
      cands[t] = cd
    for sub in st.body:
      classify(sub, false)
    for br in st.elifs:
      for sub in br.body:
        classify(sub, false)
    for sub in st.elseBody:
      classify(sub, false)

  for st in s.body:
    classify(st, true)

  result = 0
  for v, cd in cands:
    if cd.bad or not cd.top or cd.dir == 0:
      continue
    var t: Typ = nil
    for i in countdown(c.scopes.len - 1, 0):
      if v in c.scopes[i]:
        if c.scopes[i][v].kind == syLocal:
          t = c.scopes[i][v].typ
        break
    if t == nil or t.kind != tyInt:
      continue
    var bound = 0'i64
    case cd.dir
    of 1, -1:
      if t.rhi < IntHigh and t.rlo > IntLow:
        bound = satSub(t.rhi, t.rlo).v div cd.minStep + 1
    else:
      if c.condZeroExit(s.cond, v):
        bound = 64 # |v| at least halves every pass; int64 is 64 bits
    if bound > 0 and (result == 0 or bound < result):
      result = bound

# --- range compatibility --------------------------------------------------

proc typRangeEq(a, b: Typ): bool =
  ## Exact range match, required for var parameters (writes flow both ways).
  if a.kind != b.kind:
    return false
  case a.kind
  of tyInt: a.rlo == b.rlo and a.rhi == b.rhi
  of tyArray: a.len == b.len and typRangeEq(a.elem, b.elem)
  else: true

proc typRangeFits(a, b: Typ): bool =
  ## a is usable where b is expected read-only (a's ranges inside b's).
  if a.kind != b.kind:
    return false
  case a.kind
  of tyInt: a.rlo >= b.rlo and a.rhi <= b.rhi
  of tyArray: a.len == b.len and typRangeFits(a.elem, b.elem)
  else: true

proc zeroOk(t: Typ): bool =
  ## Can this type be zero-initialized without violating a range?
  case t.kind
  of tyInt: t.rlo <= 0 and t.rhi >= 0
  of tyArray: zeroOk(t.elem)
  of tyObject:
    for f in t.fields:
      if not zeroOk(f.typ):
        return false
    true
  else: true

# --- expression checking --------------------------------------------------

proc exprFact(e: Expr): Fact =
  Fact(lo: e.rlo, hi: e.rhi, notZero: e.rnz)

proc setFact(e: Expr, f: Fact) =
  e.rlo = f.lo
  e.rhi = f.hi
  e.rnz = f.notZero or f.lo > 0 or f.hi < 0

proc checkExpr(c: var Ctx, e: Expr): Typ =
  case e.kind
  of ekInt:
    e.typ = intType()
    e.setFact Fact(lo: e.ival, hi: e.ival, notZero: e.ival != 0)
  of ekBool:
    e.typ = Typ(kind: tyBool)
  of ekStr:
    e.typ = Typ(kind: tyString)
  of ekIdent:
    c.resolveIdent(e)
    if e.typ.kind == tyInt:
      if e.symKind == syConst:
        let v = c.consts[e.sval]
        e.setFact Fact(lo: v, hi: v, notZero: v != 0)
      elif c.factName(e) != "":
        e.setFact c.curFact(e.sval)
      else:
        # Unowned globals outside their lock and var params: only the
        # declared range invariant holds.
        e.setFact typFact(e.typ)
  of ekNeg:
    if c.expectVal(e.kids[0]).kind != tyInt:
      err(e.line, "unary '-' needs an int operand")
    let a = exprFact(e.kids[0])
    let l = satNeg(a.hi)
    let h = satNeg(a.lo)
    if l.ov or h.ov:
      err(e.line, "cannot prove unary '-' does not overflow (operand is " &
        rangeStr(a) & ")")
    e.typ = intType()
    e.setFact Fact(lo: l.v, hi: h.v, notZero: a.notZero)
  of ekNot:
    if c.expectVal(e.kids[0]).kind != tyBool:
      err(e.line, "'not' needs a bool operand")
    e.typ = Typ(kind: tyBool)
  of ekBin:
    case e.sval
    of "and", "or":
      if c.expectVal(e.kids[0]).kind != tyBool:
        err(e.line, "'" & e.sval & "' needs bool operands")
      # Short-circuit: the right side is only evaluated when the left side
      # already held (and) or failed (or) — check it under those facts.
      let saved = c.facts
      c.addCondFacts(e.kids[0], negated = e.sval == "or")
      if c.expectVal(e.kids[1]).kind != tyBool:
        err(e.line, "'" & e.sval & "' needs bool operands")
      c.facts = saved
      e.typ = Typ(kind: tyBool)
    else:
      let a = c.expectVal(e.kids[0])
      let b = c.expectVal(e.kids[1])
      case e.sval
      of "+", "-", "*", "/", "%":
        if a.kind != tyInt or b.kind != tyInt:
          err(e.line, "'" & e.sval & "' needs int operands, got " & $a & " and " & $b)
        let af = exprFact(e.kids[0])
        let bf = exprFact(e.kids[1])
        case e.sval
        of "+":
          let r = addF(af, bf)
          if r.ov:
            err(e.line, "cannot prove '+' does not overflow: " & rangeStr(af) &
              " + " & rangeStr(bf) & "; narrow the ranges or guard first")
          e.setFact r.f
        of "-":
          let r = subF(af, bf)
          if r.ov:
            err(e.line, "cannot prove '-' does not overflow: " & rangeStr(af) &
              " - " & rangeStr(bf) & "; narrow the ranges or guard first")
          e.setFact r.f
        of "*":
          let r = mulF(af, bf)
          if r.ov:
            err(e.line, "cannot prove '*' does not overflow: " & rangeStr(af) &
              " * " & rangeStr(bf) & "; narrow the ranges or guard first")
          e.setFact r.f
        else: # "/" and "%": prove the divisor nonzero, then no overflow.
          let d = e.kids[1]
          let word = if e.sval == "/": "division" else: "modulo"
          if not (bf.notZero or bf.lo > 0 or bf.hi < 0):
            if bf.lo == 0 and bf.hi == 0:
              err(e.line, word & " by zero")
            elif d.kind == ekIdent and c.factName(d) != "":
              err(e.line, "cannot prove '" & d.sval &
                "' is not zero here; guard the division with 'if " & d.sval &
                " != 0:'")
            else:
              err(e.line, "cannot prove the divisor is not zero; put it in a " &
                "local first and guard with 'if x != 0:'")
          if af.lo == IntLow and bf.lo <= -1 and bf.hi >= -1:
            err(e.line, "cannot prove '" & e.sval & "' does not overflow: " &
              "the dividend may be the smallest int64 and the divisor may be -1")
          if e.sval == "/":
            e.setFact divF(af, bf)
          else:
            e.setFact modF(af, bf)
        e.typ = intType()
      of "<", "<=", ">", ">=":
        if a.kind != tyInt or b.kind != tyInt:
          err(e.line, "'" & e.sval & "' needs int operands, got " & $a & " and " & $b)
        e.typ = Typ(kind: tyBool)
      of "==", "!=":
        if not typEq(a, b) or a.kind notin {tyInt, tyBool}:
          err(e.line, "'" & e.sval & "' needs two ints or two bools, got " &
            $a & " and " & $b)
        e.typ = Typ(kind: tyBool)
      else:
        err(e.line, "internal: unknown operator " & e.sval)
  of ekIndex:
    let base = c.expectVal(e.kids[0])
    if base.kind != tyArray:
      err(e.line, "'[]' needs an array, got " & $base)
    if c.expectVal(e.kids[1]).kind != tyInt:
      err(e.line, "array index must be an int")
    # The index proof: the index interval must fit inside 0 ..< len.
    let f = exprFact(e.kids[1])
    if f.lo > base.len - 1 or f.hi < 0:
      err(e.line, "index " & rangeStr(f) & " is always out of bounds for an " &
        "array of length " & $base.len)
    if f.lo < 0 or f.hi > base.len - 1:
      err(e.line, "cannot prove index is inside 0 ..< " & $base.len &
        " (index is " & rangeStr(f) & "); test it first")
    e.typ = base.elem
    e.setFact typFact(base.elem)
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
    e.setFact typFact(e.typ)
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
        if not typRangeEq(at, pt.typ):
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must have exactly the range " & $pt.typ & " (got " & $at & ")")
        c.facts.del root.sval
      else:
        if pt.typ.kind == tyInt:
          if not exprFact(arg).fits(pt.typ):
            err(arg.line, "cannot prove argument " & $(i + 1) & " of '" &
              name & "' (" & rangeStr(exprFact(arg)) & ") fits parameter '" &
              pt.name & "' (" & $pt.typ & "); guard or clamp first")
        elif not typRangeFits(at, pt.typ):
          err(arg.line, "argument " & $(i + 1) & " of '" & name &
            "': element ranges of " & $at & " do not fit " & $pt.typ)
    # The callee may write globals; facts about them are now stale.
    if name in c.routineWrites:
      for g in c.routineWrites[name]:
        c.facts.del g
    e.typ = r.ret
    if r.ret != nil and r.ret.kind == tyInt:
      e.setFact typFact(r.ret)
  e.typ

# --- statement checking ---------------------------------------------------

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
    var initFact = Fact(lo: 0, hi: 0, notZero: false)
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
      initFact = exprFact(s.init)
      if t.kind == tyInt and not initFact.fits(t):
        err(s.line, "cannot prove initializer (" & rangeStr(initFact) &
          ") fits '" & s.name & "' (" & $t & "); guard or clamp first")
    else:
      if s.kind == skLet:
        err(s.line, "let requires an initializer")
      if t == nil:
        err(s.line, "variable needs a type or an initializer")
      if not zeroOk(t):
        err(s.line, "'" & s.name & "' is zero-initialized, but 0 is not in " &
          $t & "; add an initializer")
    if c.isDeclared(s.name):
      err(s.line, "'" & s.name & "' is already declared (shadowing is not allowed)")
    s.typ = t
    c.scopes[^1][s.name] = Sym(kind: syLocal, typ: t, mutable: s.kind == skVar)
    if t.kind == tyInt:
      c.facts[s.name] = initFact
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
    # The store proof: the value must fit the declared range invariant.
    if lt.kind == tyInt:
      let rf = exprFact(s.rhs)
      if not rf.fits(lt):
        err(s.line, "cannot prove value (" & rangeStr(rf) & ") fits " & $lt &
          "; guard or clamp first")
    if s.lhs.kind == ekIdent and c.factName(s.lhs) != "":
      c.facts[s.lhs.sval] = exprFact(s.rhs)
  of skIf:
    let base = c.facts
    var negAcc = base
    var branchFacts: seq[Table[string, Fact]]
    for br in s.elifs:
      c.facts = negAcc
      if c.expectVal(br.cond).kind != tyBool:
        err(br.cond.line, "condition must be a bool")
      c.addCondFacts(br.cond)
      c.checkBody(br.body)
      if not alwaysExits(br.body):
        branchFacts.add c.facts
      c.facts = negAcc
      c.addCondFacts(br.cond, negated = true)
      negAcc = c.facts
    if s.elseBody.len > 0:
      c.facts = negAcc
      c.checkBody(s.elseBody)
      if not alwaysExits(s.elseBody):
        branchFacts.add c.facts
    else:
      branchFacts.add negAcc # the fall-through path
    if branchFacts.len == 0:
      c.facts = base # everything after is unreachable
    elif branchFacts.len == 1:
      c.facts = branchFacts[0]
    else:
      c.facts = c.joinFacts(branchFacts)
  of skWhile:
    let base = c.facts
    # Facts about anything the body can change do not survive an iteration;
    # facts from the condition are re-established on every entry.
    c.dropAssigned(s.body)
    let dropped = c.facts
    if c.expectVal(s.cond).kind != tyBool:
      err(s.cond.line, "condition must be a bool")
    c.addCondFacts(s.cond)
    c.loopWiths.add c.withDepth
    c.checkBody(s.body)
    discard c.loopWiths.pop
    # The termination proof: strict induction progress, or an explicit
    # max N (which bounds the loop by construction - it also stops after
    # N iterations).
    var bound = c.whileBound(s)
    if s.maxTrips > 0:
      bound = if bound > 0: min(bound, s.maxTrips) else: s.maxTrips
    if bound == 0:
      err(s.line, "cannot prove this while loop terminates: no finite-" &
        "ranged variable makes strict progress every iteration; add " &
        "'max N' to bound it (the loop then also stops after N iterations)")
    s.tripBound = bound
    c.facts = dropped
    # After the loop the condition is false - but only if the loop cannot
    # leave any other way (break, or the max cap).
    if s.maxTrips == 0 and not hasLoopBreak(s.body):
      c.addCondFacts(s.cond, negated = true)
  of skFor:
    if c.expectVal(s.lo).kind != tyInt or c.expectVal(s.hi).kind != tyInt:
      err(s.line, "for loop bounds must be ints")
    if c.isDeclared(s.name):
      err(s.line, "'" & s.name & "' is already declared (shadowing is not allowed)")
    let lof = exprFact(s.lo)
    let hif = exprFact(s.hi)
    var iHi = hif.hi
    if s.inclusive:
      if iHi == IntHigh:
        err(s.line, "cannot prove the inclusive loop bound stays below " &
          "int64.max; use ..< or a ranged bound")
    else:
      iHi = satSub(iHi, 1).v
    s.tripBound = max(0'i64, satAdd(satSub(iHi, lof.lo).v, 1).v)
    c.dropAssigned(s.body)
    let dropped = c.facts
    c.scopes.add initTable[string, Sym]()
    c.scopes[^1][s.name] = Sym(kind: syLocal, typ: intType(), mutable: false)
    c.facts[s.name] = Fact(lo: lof.lo, hi: iHi)
    c.loopWiths.add c.withDepth
    for st in s.body:
      c.checkStmt(st, false)
    discard c.loopWiths.pop
    discard c.scopes.pop
    c.facts = dropped
    c.facts.del s.name
  of skLoop:
    if c.cur.kind != rkThread or not topLevel:
      err(s.line, "loop is only allowed at the top level of a thread body")
    c.dropAssigned(s.body)
    let dropped = c.facts
    c.loopWiths.add c.withDepth
    c.checkBody(s.body)
    discard c.loopWiths.pop
    c.facts = dropped
  of skWith:
    if c.cur.kind == rkFunc:
      err(s.line, "with is not allowed in func (start/end are side effects)")
    c.facts.del s.name
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
            not typEq(r.params[0].typ, t) or not typRangeEq(r.params[0].typ, t) or
            not r.ret.isNil:
          err(s.line, "with on a " & $t & " needs '" & pn & "' to be: " & want)
      s.typ = t
    let isLock = s.typ != nil and s.typ.kind == tyLock
    if isLock:
      c.heldLocks.add s.name
    inc c.withDepth
    c.checkBody(s.body)
    dec c.withDepth
    if isLock:
      discard c.heldLocks.pop
      # Facts proven under the lock die with it: another thread may take
      # the lock and write before we ever hold it again.
      var stale: seq[string]
      for k in c.facts.keys:
        if k in c.sharedProt and s.name in c.sharedProt[k]:
          stale.add k
      for k in stale:
        c.facts.del k
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
      if c.cur.ret.kind == tyInt:
        let rf = exprFact(s.value)
        if not rf.fits(c.cur.ret):
          err(s.line, "cannot prove return value (" & rangeStr(rf) &
            ") fits " & $c.cur.ret & "; guard or clamp first")
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

proc check*(m: Module) =
  ## Check the whole module; raises NiftyError on the first violation.
  var c = Ctx()
  var used: HashSet[string]
  for td in m.types:
    if td.name in used:
      err(td.line, "duplicate name: '" & td.name & "'")
    used.incl td.name
    if not zeroOk(td.typ):
      err(td.line, "object '" & td.name & "' has a field range that does " &
        "not include 0 (objects are zero-initialized)")
  for cd in m.consts:
    if cd.name in used:
      err(cd.line, "duplicate name: '" & cd.name & "'")
    used.incl cd.name
    c.consts[cd.name] = cd.value
  for gd in m.globals:
    if gd.name in used:
      err(gd.line, "duplicate name: '" & gd.name & "'")
    used.incl gd.name
    if not zeroOk(gd.typ):
      err(gd.line, "global '" & gd.name & "' is zero-initialized, but 0 is " &
        "not in " & $gd.typ)
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

  # --- thread ownership and lock protection of globals ---------------------
  # For every routine, compute (a) which globals it may touch and which
  # locks are held at EVERY such access (including transitively through
  # calls), and (b) which globals it may write. Then: a global accessed by
  # one thread is thread-owned. A global accessed by 2+ threads with at
  # least one writer is shared: all threads must agree on one common lock,
  # for reads too (a read outside the lock could see a torn or mid-update
  # value, and two reads could disagree). This is all computable because
  # threads are declared, the call graph is a DAG, and names cannot shadow.
  var access: Table[string, Table[string, HashSet[string]]]
  var writes: Table[string, HashSet[string]]
  var acc: Table[string, HashSet[string]]
  var wr: HashSet[string]

  proc isPlainGlobal(name: string): bool =
    name in c.globals and c.globals[name].kind != tyLock

  proc note(g: string, held: HashSet[string]) =
    if g in acc:
      acc[g] = acc[g] * held
    else:
      acc[g] = held

  proc mergeCallee(callee: string, held: HashSet[string]) =
    if callee in access:
      for g, ls in access[callee]:
        note(g, held + ls)
      for g in writes[callee]:
        wr.incl g

  proc scanE(e: Expr, held: HashSet[string]) =
    if e.isNil:
      return
    if e.kind == ekIdent and isPlainGlobal(e.sval):
      note(e.sval, held)
    if e.kind == ekCall and e.sval in c.routineTab:
      mergeCallee(e.sval, held)
      let r2 = c.routineTab[e.sval]
      for i, arg in e.kids:
        if i < r2.params.len and r2.params[i].isVar:
          let root = arg.rootIdent
          if root.kind == ekIdent and isPlainGlobal(root.sval):
            note(root.sval, held)
            wr.incl root.sval
    for k in e.kids:
      scanE(k, held)

  proc scanS(s: Stmt, held: HashSet[string]) =
    for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
      scanE(e, held)
    for a in s.args:
      scanE(a, held)
    var bodyHeld = held
    case s.kind
    of skAssign:
      let root = s.lhs.rootIdent
      if root.kind == ekIdent and isPlainGlobal(root.sval):
        note(root.sval, held)
        wr.incl root.sval
    of skWith:
      if s.name in c.globals and c.globals[s.name].kind == tyLock:
        bodyHeld = held + [s.name].toHashSet
      else:
        if isPlainGlobal(s.name):
          note(s.name, held)
          wr.incl s.name
        mergeCallee("start", held)
        mergeCallee("end", held)
    else:
      discard
    for st in s.body:
      scanS(st, bodyHeld)
    for br in s.elifs:
      scanE(br.cond, held)
      for st in br.body:
        scanS(st, held)
    for st in s.elseBody:
      scanS(st, held)

  for r in m.routines:
    acc = initTable[string, HashSet[string]]()
    wr = initHashSet[string]()
    for st in r.body:
      scanS(st, initHashSet[string]())
    access[r.name] = acc
    writes[r.name] = wr
  c.routineWrites = writes

  var accThreads: Table[string, seq[string]]
  var lockProt: Table[string, HashSet[string]]
  var writeThreads: Table[string, HashSet[string]]
  for r in m.routines:
    if r.kind != rkThread:
      continue
    for g, ls in access[r.name]:
      if g notin accThreads:
        accThreads[g] = @[]
        lockProt[g] = ls
      else:
        lockProt[g] = lockProt[g] * ls
      accThreads[g].add r.name
    for g in writes[r.name]:
      if g notin writeThreads:
        writeThreads[g] = initHashSet[string]()
      writeThreads[g].incl r.name
  for gd in m.globals:
    if gd.typ.kind == tyLock:
      continue
    let g = gd.name
    if g in accThreads and accThreads[g].len >= 2 and g in writeThreads:
      if lockProt[g].len == 0:
        err(gd.line, "shared global '" & g & "' is accessed by threads " &
          accThreads[g].join(", ") & " but not consistently protected; " &
          "every access (reads too) must be inside a with block holding " &
          "one common lock")
      c.sharedProt[g] = lockProt[g]

  for r in m.routines:
    c.cur = r
    c.withDepth = 0
    c.loopWiths = @[]
    c.facts = initTable[string, Fact]()
    c.heldLocks = @[]
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

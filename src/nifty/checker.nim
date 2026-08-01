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
    mutBan: int                # >0 where mutating methods may not appear
    routineAccess: Table[string, HashSet[string]] # routine -> globals it touches
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

proc exprFact(e: Expr): Fact =
  Fact(lo: e.rlo, hi: e.rhi, notZero: e.rnz)

proc setFact(e: Expr, f: Fact) =
  e.rlo = f.lo
  e.rhi = f.hi
  e.rnz = f.notZero or f.lo > 0 or f.hi < 0

proc rejectOpt(t: Typ, e: Expr) =
  ## Optionals must be proven before their value is used.
  if t != nil and t.opt:
    let name = if e.kind == ekIdent: e.sval else: "it"
    err(e.line, "cannot use '" & name & "' before proving it has a value; " &
      "test with 'if " & name & ".ok:' first (or use ." &
      "or(fallback))")

proc coerceOpt(c: var Ctx, e: Expr, target: Typ): bool =
  ## A plain value fits an optional destination (wrapped as ok); `none`
  ## fits any optional destination.
  if target == nil or not target.opt:
    return false
  if e.kind == ekNone:
    e.typ = target
    return true
  if e.typ != nil and not e.typ.opt and typEq(e.typ, deOpt(target)):
    if e.typ.kind == tyInt and not exprFact(e).fits(deOpt(target)):
      err(e.line, "cannot prove value (" & rangeStr(exprFact(e)) &
        ") fits " & $deOpt(target) & "; guard or clamp first")
    e.wrapOpt = true
    e.typ = target
    return true
  false

proc coerceStrLit(c: Ctx, e: Expr, target: Typ): bool =
  ## A string literal fits a string[N] destination if its bytes fit.
  if target != nil and target.kind == tyStr and e != nil and e.kind == ekStr:
    if e.sval.len > target.len:
      err(e.line, "string literal (" & $e.sval.len & " bytes) does not fit " &
        $target)
    e.typ = target
    true
  else:
    false

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

proc pathHasMapIndex(e: Expr): bool =
  ## Map elements are values, not places: m[k] cannot appear inside an
  ## lvalue path (var arguments, foreach bases, method targets).
  var cur = e
  while cur.kind in {ekIndex, ekField}:
    if cur.kind == ekIndex and cur.kids[0].typ != nil and
        cur.kids[0].typ.kind in {tyMapD, tyMapS}:
      return true
    cur = cur.kids[0]
  false

proc rootIdent(e: Expr): Expr =
  result = e
  while result.kind in {ekIndex, ekField}:
    result = result.kids[0]

proc declFactByName(c: Ctx, name: string): Fact =
  if name.len > 4 and name.endsWith(".len"):
    let root = name[0 ..< name.len - 4]
    for i in countdown(c.scopes.len - 1, 0):
      if root in c.scopes[i]:
        let t = c.scopes[i][root].typ
        if t.kind in {tySeq, tyStr, tyQueue, tyMapS}:
          return Fact(lo: 0, hi: t.len)
        if t.kind in {tySet, tyMapD}:
          return Fact(lo: 0, hi: t.setSize)
        return fullFact()
    if root in c.globals and
        c.globals[root].kind in {tySeq, tyStr, tyQueue, tyMapS}:
      return Fact(lo: 0, hi: c.globals[root].len)
    if root in c.globals and c.globals[root].kind == tyMapD:
      return Fact(lo: 0, hi: c.globals[root].setSize)
    if root in c.globals and c.globals[root].kind == tySet:
      return Fact(lo: 0, hi: c.globals[root].setSize)
    return fullFact()
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

proc factEligibleIdent(c: Ctx, e: Expr): bool =
  ## Can flow facts attach to this identifier here? Locals and non-var
  ## parameters always qualify. A global qualifies when it is thread-owned
  ## (accessed by at most one thread) or when the lock that protects it is
  ## currently held — in both cases no other thread can change it between
  ## a test and a use. Var params never qualify (they may alias anything).
  if e.kind != ekIdent:
    return false
  case e.symKind
  of syLocal:
    true
  of syParam:
    not e.isVarParam
  of syGlobal:
    if e.sval notin c.sharedProt:
      true # thread-owned (or never written): sequential here
    else:
      for l in c.heldLocks:
        if l in c.sharedProt[e.sval]:
          return true
      false
  else:
    false

proc factName(c: Ctx, e: Expr): string =
  ## The name an int flow fact can attach to.
  if e.typ != nil and e.typ.kind == tyInt and c.factEligibleIdent(e):
    e.sval
  else:
    ""

proc lenPathName(c: Ctx, e: Expr): string =
  ## "s.len" when e reads the length of a factable seq/string variable.
  if e.kind == ekField and e.sval == "len" and e.kids[0].kind == ekIdent and
      e.kids[0].typ != nil and
      e.kids[0].typ.kind in {tySeq, tyStr, tySet, tyQueue, tyMapD, tyMapS} and
      c.factEligibleIdent(e.kids[0]):
    e.kids[0].sval & ".len"
  else:
    ""

proc mapFactKey(c: Ctx, m: Expr, k: Expr): string =
  ## The containment-predicate key "m@k" for a stable map/key pair, or ""
  ## when either side cannot carry a fact.
  if m.kind != ekIdent or not c.factEligibleIdent(m):
    return ""
  let kv = c.tryConstEval(k)
  if kv.known:
    return m.sval & "@=" & $kv.val
  if k.kind == ekStr:
    return m.sval & "@=s" & k.sval
  if k.kind == ekIdent and c.factEligibleIdent(k):
    return m.sval & "@" & k.sval
  ""

proc factOrLenName(c: Ctx, e: Expr): string =
  result = c.factName(e)
  if result == "":
    result = c.lenPathName(e)

proc delFacts(c: var Ctx, name: string) =
  ## Forget everything about a variable: its own fact, its length fact,
  ## and any containment predicates it appears in (either side).
  c.facts.del name
  c.facts.del name & ".len"
  var stale: seq[string]
  for k in c.facts.keys:
    if k.startsWith(name & "@") or k.endsWith("@" & name):
      stale.add k
  for k in stale:
    c.facts.del k

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
  let ln = c.factOrLenName(e.kids[0])
  let rn = c.factOrLenName(e.kids[1])
  if ln != "" and rc.known:
    result = (ln, e.sval, rc.val)
  elif rn != "" and lc.known:
    result = (rn, flipCmp(e.sval), lc.val)

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
  if e.kind == ekField and e.isOptOk and not negated:
    if e.kids[0].kind == ekIdent and c.factEligibleIdent(e.kids[0]):
      c.facts[e.kids[0].sval & "@ok"] = Fact(lo: 1, hi: 1)
    return
  if e.kind == ekMethod and e.sval == "contains" and not negated and
      e.kids.len == 2:
    let key = c.mapFactKey(e.kids[0], e.kids[1])
    if key != "":
      c.facts[key] = Fact(lo: 1, hi: 1)
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
    if "@" in n:
      # Containment predicates are all-or-nothing: keep only if proven
      # on every path.
      var everywhere = true
      for t in tabs:
        if n notin t:
          everywhere = false
      if everywhere:
        result[n] = tabs[0][n]
      continue
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
  if e.kind == ekMethod and e.sval in mutMethods:
    let root = e.kids[0].rootIdent
    if root.kind == ekIdent:
      s.incl root.sval
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
    c.delFacts n

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
    of skWhile, skFor, skLoop, skForEach:
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

# --- accumulator widening -------------------------------------------------

proc containsIdent(e: Expr, v: string): bool =
  if e.isNil:
    return false
  if e.kind == ekIdent and e.sval == v:
    return true
  for k in e.kids:
    if containsIdent(k, v):
      return true

proc declTypeOf(c: Ctx, e: Expr): Typ =
  ## The type of a value expression from declarations only (no checking).
  case e.kind
  of ekIdent:
    for i in countdown(c.scopes.len - 1, 0):
      if e.sval in c.scopes[i]:
        return c.scopes[i][e.sval].typ
    if e.sval in c.globals:
      return c.globals[e.sval]
    nil
  of ekIndex:
    let b = c.declTypeOf(e.kids[0])
    if b != nil and b.kind == tyArray: b.elem else: nil
  of ekField:
    let b = c.declTypeOf(e.kids[0])
    if b != nil and b.kind == tyObject:
      for f in b.fields:
        if f.name == e.sval:
          return f.typ
    nil
  else:
    nil

proc declFact(c: Ctx, e: Expr, loopVar: string, loopFact: Fact):
    tuple[ok: bool, f: Fact] =
  ## Interval of an expression from declared ranges, consts, and the loop
  ## variable only — no flow facts, so it is valid on every iteration.
  result = (false, fullFact())
  case e.kind
  of ekInt:
    result = (true, Fact(lo: e.ival, hi: e.ival))
  of ekIdent:
    if e.sval == loopVar:
      result = (true, loopFact)
    elif e.sval in c.consts:
      let v = c.consts[e.sval]
      result = (true, Fact(lo: v, hi: v))
    else:
      let t = c.declTypeOf(e)
      if t != nil and t.kind == tyInt:
        result = (true, typFact(t))
  of ekNeg:
    let a = c.declFact(e.kids[0], loopVar, loopFact)
    if a.ok:
      let l = satNeg(a.f.hi)
      let h = satNeg(a.f.lo)
      if not (l.ov or h.ov):
        result = (true, Fact(lo: l.v, hi: h.v))
  of ekBin:
    let a = c.declFact(e.kids[0], loopVar, loopFact)
    let b = c.declFact(e.kids[1], loopVar, loopFact)
    if a.ok and b.ok:
      case e.sval
      of "+":
        let r = addF(a.f, b.f)
        if not r.ov: result = (true, r.f)
      of "-":
        let r = subF(a.f, b.f)
        if not r.ov: result = (true, r.f)
      of "*":
        let r = mulF(a.f, b.f)
        if not r.ov: result = (true, r.f)
      of "/", "%":
        if (b.f.lo > 0 or b.f.hi < 0) and
            not (a.f.lo == IntLow and b.f.lo <= -1 and b.f.hi >= -1):
          if e.sval == "/":
            result = (true, divF(a.f, b.f))
          else:
            result = (true, modF(a.f, b.f))
      else:
        discard
  of ekIndex, ekField:
    let t = c.declTypeOf(e)
    if t != nil and t.kind == tyInt:
      result = (true, typFact(t))
  of ekCall:
    if e.sval in c.routineTab:
      let rt = c.routineTab[e.sval].ret
      if rt != nil and rt.kind == tyInt:
        result = (true, typFact(rt))
  else:
    discard

proc accumWiden(c: Ctx, s: Stmt, assigned: HashSet[string],
    loopFact: Fact, entry: Table[string, Fact]): Table[string, Fact] =
  ## Induction for accumulators in a counted for loop: a local assigned
  ## ONLY as v = v + e / v = v - e (e independent of v, not inside a
  ## nested loop) keeps a widened fact instead of losing everything:
  ## its entry value plus tripCount * the per-iteration delta.
  let trips = s.tripBound
  for v in assigned:
    var declTyp: Typ = nil
    for i in countdown(c.scopes.len - 1, 0):
      if v in c.scopes[i]:
        if c.scopes[i][v].kind == syLocal:
          declTyp = c.scopes[i][v].typ
        break
    if declTyp == nil or declTyp.kind != tyInt:
      continue
    var sites: seq[tuple[sign: int, e: Expr]]
    var ok = true

    proc walk(body: seq[Stmt], nested: bool) =
      for st in body:
        var touched: HashSet[string]
        for e in [st.init, st.lhs, st.rhs, st.cond, st.lo, st.hi, st.value]:
          c.collectAssignedExpr(e, touched)
        for a in st.args:
          c.collectAssignedExpr(a, touched)
        for br in st.elifs:
          c.collectAssignedExpr(br.cond, touched)
        if v in touched or (st.kind == skWith and st.name == v):
          ok = false
        if st.kind == skAssign and st.lhs.kind == ekIdent and st.lhs.sval == v:
          if nested:
            ok = false
          else:
            let r = st.rhs
            if r.kind == ekBin and r.sval in ["+", "-"] and
                r.kids[0].kind == ekIdent and r.kids[0].sval == v and
                not containsIdent(r.kids[1], v):
              sites.add (sign: (if r.sval == "+": 1 else: -1), e: r.kids[1])
            else:
              ok = false
        let deeper = nested or st.kind in {skWhile, skFor, skLoop, skForEach}
        walk(st.body, deeper)
        for br in st.elifs:
          walk(br.body, deeper)
        walk(st.elseBody, deeper)

    walk(s.body, false)
    if not ok or sites.len == 0:
      continue
    # Per-iteration delta: each site runs at most once per iteration.
    var dLo = 0'i64
    var dHi = 0'i64
    var good = true
    for site in sites:
      let r = c.declFact(site.e, s.name, loopFact)
      if not r.ok:
        good = false
        break
      var lo = r.f.lo
      var hi = r.f.hi
      if site.sign < 0:
        let nl = satNeg(hi)
        let nh = satNeg(lo)
        if nl.ov or nh.ov:
          good = false
          break
        lo = nl.v
        hi = nh.v
      dLo = satAdd(dLo, min(0'i64, lo)).v
      dHi = satAdd(dHi, max(0'i64, hi)).v
    if not good:
      continue
    # Saturation only widens the interval, which stays sound; the declared
    # range is an invariant, so the intersection is sound and tighter.
    let v0 = entry.getOrDefault(v, c.declFactByName(v))
    let dt = typFact(declTyp)
    result[v] = Fact(
      lo: max(satAdd(v0.lo, satMul(trips, dLo).v).v, dt.lo),
      hi: min(satAdd(v0.hi, satMul(trips, dHi).v).v, dt.hi))

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
  of tyArray, tySeq, tyQueue: a.len == b.len and typRangeEq(a.elem, b.elem)
  of tyMapD: typRangeEq(a.val, b.val)
  of tyMapS: a.len == b.len and typRangeEq(a.elem, b.elem) and
    typRangeEq(a.val, b.val)
  else: true

proc typRangeFits(a, b: Typ): bool =
  ## a is usable where b is expected read-only (a's ranges inside b's).
  if a.kind != b.kind:
    return false
  case a.kind
  of tyInt: a.rlo >= b.rlo and a.rhi <= b.rhi
  of tyArray, tySeq, tyQueue: a.len == b.len and typRangeFits(a.elem, b.elem)
  of tyMapD: typRangeFits(a.val, b.val)
  of tyMapS: a.len == b.len and typRangeFits(a.elem, b.elem) and
    typRangeFits(a.val, b.val)
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

proc checkExpr(c: var Ctx, e: Expr): Typ =
  case e.kind
  of ekInt:
    e.typ = intType()
    e.setFact Fact(lo: e.ival, hi: e.ival, notZero: e.ival != 0)
  of ekBool:
    e.typ = Typ(kind: tyBool)
  of ekNone:
    err(e.line, "none needs an optional destination " &
      "(var x: int? = none / x = none / return none)")
  of ekStr:
    if e.typ == nil or e.typ.kind != tyStr:
      e.typ = Typ(kind: tyString)
  of ekIdent:
    c.resolveIdent(e)
    if e.typ != nil and e.typ.opt and c.factEligibleIdent(e) and
        (e.sval & "@ok") in c.facts:
      # Proven present: the name acts as its base type from here.
      e.typ = deOpt(e.typ)
      e.unwrapOpt = true
    if e.typ.kind == tyInt and not e.typ.opt:
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
    let nt = c.expectVal(e.kids[0])
    rejectOpt(nt, e.kids[0])
    if nt.kind != tyInt:
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
      inc c.mutBan # the right side may be skipped at runtime
      if c.expectVal(e.kids[1]).kind != tyBool:
        err(e.line, "'" & e.sval & "' needs bool operands")
      dec c.mutBan
      c.facts = saved
      # The right side MAY have run: anything it can change is unknown now.
      var rhsTouched: HashSet[string]
      c.collectAssignedExpr(e.kids[1], rhsTouched)
      for n in rhsTouched:
        c.delFacts n
      e.typ = Typ(kind: tyBool)
    else:
      let a = c.expectVal(e.kids[0])
      let b = c.expectVal(e.kids[1])
      rejectOpt(a, e.kids[0])
      rejectOpt(b, e.kids[1])
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
    if base.kind in {tyMapD, tyMapS}:
      # Reading m[k] must be proven present: a contains test, a strict
      # write, or iteration provides the fact.
      var kt = c.expectVal(e.kids[1])
      if base.kind == tyMapS and c.coerceStrLit(e.kids[1], base.elem):
        kt = base.elem
      let want = if base.kind == tyMapD: intType() else: base.elem
      if (base.kind == tyMapD and kt.kind != tyInt) or
          (base.kind == tyMapS and not typEq(kt, base.elem)):
        err(e.kids[1].line, "map key must be " & $base.elem & ", got " & $kt)
      let key = c.mapFactKey(e.kids[0], e.kids[1])
      if key == "" or key notin c.facts:
        err(e.line, "cannot prove the key is present; test with 'if " &
          (if e.kids[0].kind == ekIdent: e.kids[0].sval else: "m") &
          ".contains(k):' first, or use .get(k, fallback)")
      e.typ = base.val
      e.setFact typFact(base.val)
      return e.typ
    if base.kind notin {tyArray, tySeq, tyStr}:
      err(e.line, "'[]' needs an array, seq, string, or map, got " & $base)
    if c.expectVal(e.kids[1]).kind != tyInt:
      err(e.line, "index must be an int")
    let f = exprFact(e.kids[1])
    if f.lo > base.len - 1 or f.hi < 0:
      err(e.line, "index " & rangeStr(f) & " is always out of bounds for " &
        $base)
    if base.kind == tyArray:
      # The index proof: the index interval must fit inside 0 ..< len.
      if f.lo < 0 or f.hi > base.len - 1:
        err(e.line, "cannot prove index is inside 0 ..< " & $base.len &
          " (index is " & rangeStr(f) & "); test it first")
      e.typ = base.elem
    else:
      # Only the live part 0 ..< len of a seq/string is readable/writable.
      var lf = Fact(lo: 0, hi: base.len)
      if e.kids[0].kind == ekIdent and c.factEligibleIdent(e.kids[0]):
        lf = c.curFact(e.kids[0].sval & ".len")
      if f.lo < 0 or f.hi > lf.lo - 1:
        err(e.line, "cannot prove index is below the length (index is " &
          rangeStr(f) & ", length is at least " & $lf.lo &
          "); test .len first")
      e.typ = if base.kind == tySeq: base.elem else: intType(0, 255)
    e.setFact typFact(e.typ)
  of ekField:
    let base = c.expectVal(e.kids[0])
    if e.sval == "ok" and e.kids[0].kind == ekIdent and
        (base.opt or e.kids[0].unwrapOpt):
      # Reading the presence flag never needs a proof; undo any strip so
      # codegen reads the flag, not the value.
      if e.kids[0].unwrapOpt:
        e.kids[0].unwrapOpt = false
      e.isOptOk = true
      e.typ = Typ(kind: tyBool)
      return e.typ
    rejectOpt(base, e.kids[0])
    if base.kind in {tySeq, tyStr, tySet, tyQueue, tyMapD, tyMapS}:
      if e.sval != "len":
        err(e.line, $base & " has no property '" & e.sval & "' (only .len)")
      e.typ = intType(0,
        (if base.kind in {tySet, tyMapD}: base.setSize else: base.len))
      let key = c.lenPathName(e)
      if key != "":
        e.setFact c.curFact(key)
      else:
        e.setFact Fact(lo: 0, hi: base.len)
    elif base.kind == tyObject:
      for f in base.fields:
        if f.name == e.sval:
          e.typ = f.typ
          break
      if e.typ.isNil:
        err(e.line, "type " & base.name & " has no field '" & e.sval & "'")
      e.setFact typFact(e.typ)
    else:
      err(e.line, "'.' needs an object, seq, or string, got " & $base)
  of ekMethod:
    var bt = c.expectVal(e.kids[0])
    let nArgs = e.kids.len - 1
    if e.sval == "or":
      # Total read of an optional: the value, or the fallback.
      if nArgs != 1:
        err(e.line, "or takes one fallback argument")
      if e.kids[0].kind == ekIdent and e.kids[0].unwrapOpt:
        # Already proven: undo the strip, or() still works.
        e.kids[0].unwrapOpt = false
        bt = c.declTypeOf(e.kids[0])
        e.kids[0].typ = bt
      if bt == nil or not bt.opt:
        err(e.line, "or() needs an optional value")
      var ft = c.expectVal(e.kids[1])
      if c.coerceStrLit(e.kids[1], deOpt(bt)):
        ft = deOpt(bt)
      if not typEq(ft, deOpt(bt)):
        err(e.kids[1].line, "fallback must be " & $deOpt(bt) & ", got " & $ft)
      if deOpt(bt).kind == tyInt and not exprFact(e.kids[1]).fits(deOpt(bt)):
        err(e.kids[1].line, "cannot prove fallback fits " & $deOpt(bt))
      e.typ = deOpt(bt)
      e.setFact typFact(e.typ)
      return e.typ
    rejectOpt(bt, e.kids[0])
    if e.sval in mutMethods:
      if c.mutBan > 0:
        err(e.line, "a mutating method cannot appear here: this position " &
          "may not run exactly once (loop conditions re-run; elif and " &
          "and/or right sides may be skipped); do it in its own statement")
      if e.kids[0].kind != ekIdent:
        err(e.line, "mutate a seq/string through a plain variable name")
      if not e.kids[0].mut:
        err(e.line, "cannot mutate immutable '" & e.kids[0].sval & "'")
      # The mutated variable may be serving as a map KEY in a containment
      # fact ("m@base"): that predicate is about its old value.
      var staleKeys: seq[string]
      for fk in c.facts.keys:
        if fk.endsWith("@" & e.kids[0].sval):
          staleKeys.add fk
      for fk in staleKeys:
        c.facts.del fk
    var key = ""
    if e.kids[0].kind == ekIdent and c.factEligibleIdent(e.kids[0]):
      key = e.kids[0].sval & ".len"
    var lf = Fact(lo: 0, hi: (
      if bt.kind in {tySeq, tyStr, tyQueue, tyMapS}: bt.len
      elif bt.kind in {tySet, tyMapD}: bt.setSize
      else: 0))
    if key != "":
      lf = c.curFact(key)
    case bt.kind
    of tySeq, tyQueue:
      case e.sval
      of "add", "push":
        if nArgs != 1:
          err(e.line, e.sval & " takes one argument")
        var at = c.expectVal(e.kids[1])
        if c.coerceStrLit(e.kids[1], bt.elem):
          at = bt.elem
        if not typEq(at, bt.elem):
          err(e.kids[1].line, "cannot add " & $at & " to " & $bt)
        if bt.elem.kind == tyInt and not exprFact(e.kids[1]).fits(bt.elem):
          err(e.kids[1].line, "cannot prove value (" &
            rangeStr(exprFact(e.kids[1])) & ") fits element range " &
            $bt.elem & "; guard or clamp first")
        if e.sval == "add":
          if lf.hi > bt.len - 1:
            err(e.line, "cannot prove '" & e.kids[0].sval & "' has room " &
              "(length is up to " & $lf.hi & " of " & $bt.len & "); guard " &
              "with 'if " & e.kids[0].sval & ".len < " & $bt.len &
              ":' or use push (returns false when full)")
          if key != "":
            c.facts[key] = Fact(lo: min(lf.lo + 1, bt.len),
              hi: min(lf.hi + 1, bt.len))
          e.typ = nil
        else:
          if key != "":
            c.facts[key] = Fact(lo: lf.lo, hi: min(lf.hi + 1, bt.len))
          e.typ = Typ(kind: tyBool)
      of "pop":
        if nArgs != 0:
          err(e.line, "pop takes no arguments")
        if lf.lo < 1:
          err(e.line, "cannot prove '" & e.kids[0].sval & "' is not " &
            "empty; guard with 'if " & e.kids[0].sval & ".len > 0:'")
        if key != "":
          c.facts[key] = Fact(lo: lf.lo - 1, hi: max(lf.hi - 1, 0'i64))
        e.typ = bt.elem
        e.setFact typFact(bt.elem)
      of "clear":
        if nArgs != 0:
          err(e.line, "clear takes no arguments")
        if key != "":
          c.facts[key] = Fact(lo: 0, hi: 0)
        e.typ = nil
      else:
        err(e.line, $bt & " has no method '" & e.sval & "'")
    of tyStr:
      case e.sval
      of "add":
        if nArgs != 1:
          err(e.line, "add takes one argument")
        let a = e.kids[1]
        var addLo, addHi: int64
        if a.kind == ekStr:
          discard c.checkExpr(a)
          addLo = a.sval.len
          addHi = a.sval.len
        else:
          if a.kind notin {ekIdent, ekField, ekIndex}:
            err(a.line, "put the appended string in a variable first")
          let at = c.expectVal(a)
          if at.kind != tyStr:
            err(a.line, "can only add a string literal or a string, got " & $at)
          var alf = Fact(lo: 0, hi: at.len)
          if a.kind == ekIdent and c.factEligibleIdent(a):
            alf = c.curFact(a.sval & ".len")
          addLo = alf.lo
          addHi = alf.hi
        if lf.hi + addHi > bt.len:
          err(e.line, "cannot prove '" & e.kids[0].sval & "' has room for " &
            "up to " & $addHi & " more bytes (length is up to " & $lf.hi &
            " of " & $bt.len & "); test .len first")
        if key != "":
          c.facts[key] = Fact(lo: min(lf.lo + addLo, bt.len),
            hi: min(lf.hi + addHi, bt.len))
        e.typ = nil
      of "clear":
        if nArgs != 0:
          err(e.line, "clear takes no arguments")
        if key != "":
          c.facts[key] = Fact(lo: 0, hi: 0)
        e.typ = nil
      else:
        err(e.line, $bt & " has no method '" & e.sval & "'")
    of tySet:
      case e.sval
      of "incl", "excl":
        if nArgs != 1:
          err(e.line, e.sval & " takes one argument")
        if c.expectVal(e.kids[1]).kind != tyInt:
          err(e.kids[1].line, e.sval & " needs an int value")
        if not exprFact(e.kids[1]).fits(bt.elem):
          err(e.kids[1].line, "cannot prove value (" &
            rangeStr(exprFact(e.kids[1])) & ") is inside " & $bt &
            "; guard or clamp first")
        if key != "":
          if e.sval == "incl":
            c.facts[key] = Fact(lo: lf.lo, hi: min(lf.hi + 1, bt.setSize))
          else:
            c.facts[key] = Fact(lo: max(lf.lo - 1, 0'i64), hi: lf.hi)
        e.typ = nil
      of "contains":
        if nArgs != 1:
          err(e.line, "contains takes one argument")
        if e.kids[0].kind notin {ekIdent, ekField, ekIndex}:
          err(e.line, "put the set in a variable first")
        if c.expectVal(e.kids[1]).kind != tyInt:
          err(e.kids[1].line, "contains needs an int value")
        # Total: out-of-range values are simply not in the set.
        e.typ = Typ(kind: tyBool)
      of "clear":
        if nArgs != 0:
          err(e.line, "clear takes no arguments")
        if key != "":
          c.facts[key] = Fact(lo: 0, hi: 0)
        e.typ = nil
      else:
        err(e.line, $bt & " has no method '" & e.sval & "'")
    of tyMapD, tyMapS:
      let dense = bt.kind == tyMapD
      case e.sval
      of "put":
        if nArgs != 2:
          err(e.line, "put takes a key and a value")
        var kt = c.expectVal(e.kids[1])
        if not dense and c.coerceStrLit(e.kids[1], bt.elem):
          kt = bt.elem
        if dense:
          if kt.kind != tyInt:
            err(e.kids[1].line, "map key must be an int")
          if not exprFact(e.kids[1]).fits(bt.elem):
            err(e.kids[1].line, "cannot prove key (" &
              rangeStr(exprFact(e.kids[1])) & ") is inside " & $bt.elem &
              "; guard or clamp first")
        else:
          if not typEq(kt, bt.elem):
            err(e.kids[1].line, "map key must be " & $bt.elem & ", got " & $kt)
          if bt.elem.kind == tyInt and
              not exprFact(e.kids[1]).fits(bt.elem):
            err(e.kids[1].line, "cannot prove key fits " & $bt.elem)
        var vt = c.expectVal(e.kids[2])
        if c.coerceStrLit(e.kids[2], bt.val):
          vt = bt.val
        if not typEq(vt, bt.val):
          err(e.kids[2].line, "map value must be " & $bt.val & ", got " & $vt)
        if bt.val.kind == tyInt and not exprFact(e.kids[2]).fits(bt.val):
          err(e.kids[2].line, "cannot prove value (" &
            rangeStr(exprFact(e.kids[2])) & ") fits " & $bt.val)
        let cap = if dense: bt.setSize else: bt.len
        if key != "":
          c.facts[key] = Fact(lo: lf.lo, hi: min(lf.hi + 1, cap))
        if dense:
          # Total: there is a slot for every possible key.
          let pk = c.mapFactKey(e.kids[0], e.kids[1])
          if pk != "":
            c.facts[pk] = Fact(lo: 1, hi: 1)
          e.typ = nil
        else:
          e.typ = Typ(kind: tyBool)
      of "get":
        if nArgs != 2:
          err(e.line, "get takes a key and a fallback")
        var kt = c.expectVal(e.kids[1])
        if not dense and c.coerceStrLit(e.kids[1], bt.elem):
          kt = bt.elem
        if (dense and kt.kind != tyInt) or
            (not dense and not typEq(kt, bt.elem)):
          err(e.kids[1].line, "map key must be " & $bt.elem & ", got " & $kt)
        var ft = c.expectVal(e.kids[2])
        if c.coerceStrLit(e.kids[2], bt.val):
          ft = bt.val
        if not typEq(ft, bt.val):
          err(e.kids[2].line, "fallback must be " & $bt.val & ", got " & $ft)
        if bt.val.kind == tyInt and not exprFact(e.kids[2]).fits(bt.val):
          err(e.kids[2].line, "cannot prove fallback fits " & $bt.val)
        e.typ = bt.val
        e.setFact typFact(bt.val)
      of "contains":
        if nArgs != 1:
          err(e.line, "contains takes one argument")
        if e.kids[0].kind notin {ekIdent, ekField, ekIndex}:
          err(e.line, "put the map in a variable first")
        var kt = c.expectVal(e.kids[1])
        if not dense and c.coerceStrLit(e.kids[1], bt.elem):
          kt = bt.elem
        if (dense and kt.kind != tyInt) or
            (not dense and not typEq(kt, bt.elem)):
          err(e.kids[1].line, "map key must be " & $bt.elem & ", got " & $kt)
        e.typ = Typ(kind: tyBool)
      of "remove":
        if nArgs != 1:
          err(e.line, "remove takes one argument")
        var kt = c.expectVal(e.kids[1])
        if not dense and c.coerceStrLit(e.kids[1], bt.elem):
          kt = bt.elem
        if (dense and kt.kind != tyInt) or
            (not dense and not typEq(kt, bt.elem)):
          err(e.kids[1].line, "map key must be " & $bt.elem & ", got " & $kt)
        if key != "":
          c.facts[key] = Fact(lo: max(lf.lo - 1, 0'i64), hi: lf.hi)
        # Any containment could be gone now.
        var stale: seq[string]
        for fk in c.facts.keys:
          if fk.startsWith(e.kids[0].sval & "@"):
            stale.add fk
        for fk in stale:
          c.facts.del fk
        e.typ = nil
      of "clear":
        if nArgs != 0:
          err(e.line, "clear takes no arguments")
        if key != "":
          c.facts[key] = Fact(lo: 0, hi: 0)
        var stale: seq[string]
        for fk in c.facts.keys:
          if fk.startsWith(e.kids[0].sval & "@"):
            stale.add fk
        for fk in stale:
          c.facts.del fk
        e.typ = nil
      else:
        err(e.line, $bt & " has no method '" & e.sval & "'")
    else:
      err(e.line, "'." & e.sval &
        "()' needs a seq, string, set, queue, or map, got " & $bt)
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
      var at: Typ = nil
      if arg.kind == ekNone:
        if not pt.typ.opt:
          err(arg.line, "none needs an optional parameter")
        arg.typ = pt.typ
        at = pt.typ
      else:
        at = c.expectVal(arg)
        if c.coerceOpt(arg, pt.typ):
          at = pt.typ
        elif c.coerceStrLit(arg, pt.typ):
          at = pt.typ
      if not typEq(at, pt.typ):
        err(arg.line, "argument " & $(i + 1) & " of '" & name & "': expected " &
          $pt.typ & ", got " & $at)
      if pt.isVar:
        if arg.kind notin {ekIdent, ekIndex, ekField}:
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must be a variable")
        if pathHasMapIndex(arg):
          err(arg.line, "a map element cannot be passed as var; copy it " &
            "out, change it, and put it back")
        let root = arg.rootIdent
        if root.kind != ekIdent or not root.mut:
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must be mutable")
        if not typRangeEq(at, pt.typ):
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must have exactly the range " & $pt.typ & " (got " & $at & ")")
        if name in c.routineAccess:
          if root.symKind == syGlobal and root.sval in c.routineAccess[name]:
            err(arg.line, "cannot pass global '" & root.sval &
              "' as a var argument to '" & name & "': it also accesses '" &
              root.sval & "' directly, and writes through the parameter " &
              "would make its facts lie (aliasing)")
          if root.symKind == syParam and root.isVarParam:
            for gname in c.routineAccess[name]:
              if gname in c.globals and typEq(c.globals[gname], root.typ):
                err(arg.line, "cannot forward var parameter '" & root.sval &
                  "' to '" & name & "': it accesses global '" & gname &
                  "' of the same type, which '" & root.sval &
                  "' might alias")
        c.delFacts root.sval
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
        c.delFacts g
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
    if s.init != nil and s.init.kind == ekNone:
      if t == nil or not t.opt:
        err(s.line, "none needs an optional destination " &
          "(e.g. var x: int? = none)")
      s.init.typ = t
    elif s.init != nil:
      var it = c.expectVal(s.init)
      if c.coerceOpt(s.init, t):
        it = t
      elif c.coerceStrLit(s.init, t):
        it = t
      elif it.kind == tyString:
        err(s.line, "string literals need a string[N] destination " &
          "(e.g. var s: string[20] = \"hi\")")
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
    if t.opt:
      if s.init != nil and s.init.kind != ekNone:
        c.facts[s.name & "@ok"] = Fact(lo: 1, hi: 1)
        if t.kind == tyInt:
          c.facts[s.name] = initFact
    elif t.kind == tyInt:
      c.facts[s.name] = initFact
    elif t.kind in {tySeq, tyStr, tySet, tyQueue, tyMapD, tyMapS}:
      if s.init == nil:
        c.facts[s.name & ".len"] = Fact(lo: 0, hi: 0) # zero-init = empty
      elif s.init.kind == ekStr:
        c.facts[s.name & ".len"] =
          Fact(lo: s.init.sval.len, hi: s.init.sval.len)
      elif s.init.kind == ekIdent and c.factEligibleIdent(s.init):
        c.facts[s.name & ".len"] = c.curFact(s.init.sval & ".len")
  of skAssign:
    if s.lhs.kind == ekIndex:
      let bt = c.expectVal(s.lhs.kids[0])
      if bt.kind in {tyMapD, tyMapS}:
        # m[k] = v: strict insert-or-update. Dense: the key must fit the
        # range (there is a slot for every key). Sparse: prove presence
        # (update) or room (insert). Either way the key is present after.
        if s.lhs.kids[0].kind != ekIdent:
          err(s.lhs.line, "write a map through a plain variable name")
        if not s.lhs.kids[0].mut:
          err(s.lhs.line, "cannot mutate immutable '" & s.lhs.kids[0].sval & "'")
        var kt = c.expectVal(s.lhs.kids[1])
        if bt.kind == tyMapS and c.coerceStrLit(s.lhs.kids[1], bt.elem):
          kt = bt.elem
        if bt.kind == tyMapD:
          if kt.kind != tyInt:
            err(s.lhs.kids[1].line, "map key must be an int")
          if not exprFact(s.lhs.kids[1]).fits(bt.elem):
            err(s.lhs.kids[1].line, "cannot prove key (" &
              rangeStr(exprFact(s.lhs.kids[1])) & ") is inside " &
              $bt.elem & "; guard or clamp first")
        else:
          if not typEq(kt, bt.elem):
            err(s.lhs.kids[1].line, "map key must be " & $bt.elem &
              ", got " & $kt)
          if bt.elem.kind == tyInt and
              not exprFact(s.lhs.kids[1]).fits(bt.elem):
            err(s.lhs.kids[1].line, "cannot prove key fits " & $bt.elem)
        var vt = c.expectVal(s.rhs)
        if c.coerceStrLit(s.rhs, bt.val):
          vt = bt.val
        if not typEq(vt, bt.val):
          err(s.line, "map value must be " & $bt.val & ", got " & $vt)
        if bt.val.kind == tyInt and not exprFact(s.rhs).fits(bt.val):
          err(s.line, "cannot prove value (" & rangeStr(exprFact(s.rhs)) &
            ") fits " & $bt.val)
        let mname = s.lhs.kids[0].sval
        let pk = c.mapFactKey(s.lhs.kids[0], s.lhs.kids[1])
        var lkey = ""
        if c.factEligibleIdent(s.lhs.kids[0]):
          lkey = mname & ".len"
        let cap = if bt.kind == tyMapD: bt.setSize else: bt.len
        var lf = Fact(lo: 0, hi: cap)
        if lkey != "":
          lf = c.curFact(lkey)
        if bt.kind == tyMapS:
          if not ((pk != "" and pk in c.facts) or lf.hi < bt.len):
            err(s.line, "cannot prove this write fits: prove '" & mname &
              ".contains(k)' (update) or '" & mname & ".len < " & $bt.len &
              "' (insert) first, or use put (returns false when full)")
        if lkey != "":
          c.facts[lkey] = Fact(lo: lf.lo, hi: min(lf.hi + 1, cap))
        if pk != "":
          c.facts[pk] = Fact(lo: 1, hi: 1)
        s.lhs.typ = bt.val
        return
    if s.lhs.kind == ekIdent:
      # An assignment target is a place, not a value: undo any ok-strip.
      discard c.expectVal(s.lhs)
      if s.lhs.unwrapOpt:
        s.lhs.unwrapOpt = false
        s.lhs.typ = c.declTypeOf(s.lhs)
    let lt =
      if s.lhs.kind == ekIdent: s.lhs.typ
      else: c.expectVal(s.lhs)
    let root = s.lhs.rootIdent
    if root.kind != ekIdent:
      err(s.lhs.line, "cannot assign to this expression")
    if not root.mut:
      err(s.lhs.line, "cannot assign to immutable '" & root.sval & "'")
    if lt.kind == tyArray:
      err(s.lhs.line, "whole-array assignment is not allowed; copy elements in a loop")
    var rt: Typ = nil
    if s.rhs.kind == ekNone:
      if lt == nil or not lt.opt:
        err(s.line, "none needs an optional destination")
      s.rhs.typ = lt
      rt = lt
    else:
      rt = c.expectVal(s.rhs)
      if c.coerceOpt(s.rhs, lt):
        rt = lt
      elif c.coerceStrLit(s.rhs, lt):
        rt = lt
    if not typEq(lt, rt):
      err(s.line, "type mismatch: cannot assign " & $rt & " to " & $lt)
    # The store proof: the value must fit the declared range invariant.
    if lt.kind == tyInt:
      let rf = exprFact(s.rhs)
      if not rf.fits(lt):
        err(s.line, "cannot prove value (" & rangeStr(rf) & ") fits " & $lt &
          "; guard or clamp first")
    if s.lhs.kind == ekIdent:
      c.delFacts s.lhs.sval
      if lt != nil and lt.opt and c.factEligibleIdent(s.lhs):
        # A definite value (wrapped plain or a proven optional) grants ok.
        if s.rhs.wrapOpt or s.rhs.unwrapOpt:
          c.facts[s.lhs.sval & "@ok"] = Fact(lo: 1, hi: 1)
          if lt.kind == tyInt:
            c.facts[s.lhs.sval] = exprFact(s.rhs)
      elif c.factName(s.lhs) != "":
        c.facts[s.lhs.sval] = exprFact(s.rhs)
  of skIf:
    var negAcc = c.facts
    var branchFacts: seq[Table[string, Fact]]
    for i, br in s.elifs:
      c.facts = negAcc
      if i > 0:
        inc c.mutBan # elif conditions may be skipped at runtime
      if c.expectVal(br.cond).kind != tyBool:
        err(br.cond.line, "condition must be a bool")
      if i > 0:
        dec c.mutBan
      # Condition side effects persist for everything after: the first
      # condition always runs; later ones only invalidate facts (their
      # mutations are banned), and forgetting early is always sound.
      negAcc = c.facts
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
      c.facts = negAcc # everything after is unreachable
    elif branchFacts.len == 1:
      c.facts = branchFacts[0]
    else:
      c.facts = c.joinFacts(branchFacts)
  of skWhile:
    # Facts about anything the body can change do not survive an iteration
    # (except widened accumulators); facts from the condition are
    # re-established on every entry.
    let entry = c.facts
    var assigned: HashSet[string]
    c.collectAssigned(s.body, assigned)
    for n in assigned:
      c.delFacts n
    inc c.mutBan # the condition re-runs every iteration
    if c.expectVal(s.cond).kind != tyBool:
      err(s.cond.line, "condition must be a bool")
    dec c.mutBan
    # The termination proof: strict induction progress, or an explicit
    # max N (which bounds the loop by construction - it also stops after
    # N iterations). Runs after the condition is checked (the halving
    # rule inspects it); its trip bound feeds accumulator widening.
    var bound = c.whileBound(s)
    if s.maxTrips > 0:
      bound = if bound > 0: min(bound, s.maxTrips) else: s.maxTrips
    if bound == 0:
      err(s.line, "cannot prove this while loop terminates: no finite-" &
        "ranged variable makes strict progress every iteration; add " &
        "'max N' to bound it (the loop then also stops after N iterations)")
    s.tripBound = bound
    let widened = c.accumWiden(s, assigned, fullFact(), entry)
    for n, f in widened:
      c.facts[n] = f
    let dropped = c.facts
    c.addCondFacts(s.cond)
    c.loopWiths.add c.withDepth
    c.checkBody(s.body)
    discard c.loopWiths.pop
    c.facts = dropped
    # After the loop the condition is false - but only if the loop cannot
    # leave any other way (break, or the max cap).
    if s.maxTrips == 0 and not hasLoopBreak(s.body):
      c.addCondFacts(s.cond, negated = true)
  of skFor:
    let loT = c.expectVal(s.lo)
    let hiT = c.expectVal(s.hi)
    rejectOpt(loT, s.lo)
    rejectOpt(hiT, s.hi)
    if loT.kind != tyInt or hiT.kind != tyInt:
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
    let loopFact = Fact(lo: lof.lo, hi: iHi)
    var assigned: HashSet[string]
    c.collectAssigned(s.body, assigned)
    # Simple accumulators keep a widened fact instead of losing everything.
    let widened = c.accumWiden(s, assigned, loopFact, c.facts)
    for n in assigned:
      c.delFacts n
    for n, f in widened:
      c.facts[n] = f
    let dropped = c.facts
    c.scopes.add initTable[string, Sym]()
    c.scopes[^1][s.name] = Sym(kind: syLocal, typ: intType(), mutable: false)
    c.facts[s.name] = loopFact
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
  of skForEach:
    let t = c.expectVal(s.value)
    if t.kind notin {tySeq, tyStr, tySet, tyQueue, tyMapD, tyMapS}:
      err(s.line, "for-in needs a seq, string, set, queue, or map to " &
        "iterate, got " & $t)
    if s.name2.len > 0 and t.kind notin {tyMapD, tyMapS}:
      err(s.line, "only maps iterate with two variables (for k, v in m:)")
    let root = s.value.rootIdent
    if root.kind != ekIdent:
      err(s.line, "iterate a container through a variable path")
    if pathHasMapIndex(s.value):
      err(s.line, "a map element cannot be iterated in place; copy it out")
    if c.isDeclared(s.name):
      err(s.line, "'" & s.name & "' is already declared (shadowing is not allowed)")
    var assigned: HashSet[string]
    c.collectAssigned(s.body, assigned)
    if root.sval in assigned:
      err(s.line, "cannot modify '" & root.sval & "' while iterating it")
    s.tripBound = if t.kind == tySet: t.setSize else: t.len
    let elemT =
      if t.kind in {tySeq, tyQueue}: t.elem
      elif t.kind in {tySet, tyMapD, tyMapS}: t.elem
      else: intType(0, 255)
    s.typ = elemT # recorded for codegen
    if t.kind in {tyMapD, tyMapS}:
      s.typ2 = t.val
    # Accumulators widen here too: the element variable is the loop
    # variable, bounded by the element type.
    let widened = c.accumWiden(s, assigned, typFact(elemT), c.facts)
    for n in assigned:
      c.delFacts n
    for n, f in widened:
      c.facts[n] = f
    let dropped = c.facts
    c.scopes.add initTable[string, Sym]()
    c.scopes[^1][s.name] = Sym(kind: syLocal, typ: elemT, mutable: false)
    if s.name2.len > 0:
      if c.isDeclared(s.name2):
        err(s.line, "'" & s.name2 & "' is already declared")
      c.scopes[^1][s.name2] = Sym(kind: syLocal, typ: t.val, mutable: false)
    if t.kind in {tyMapD, tyMapS} and s.value.kind == ekIdent and
        c.factEligibleIdent(s.value):
      # The loop key is contained by construction, and the map cannot
      # change during iteration.
      c.facts[s.value.sval & "@" & s.name] = Fact(lo: 1, hi: 1)
    c.loopWiths.add c.withDepth
    for st in s.body:
      c.checkStmt(st, false)
    discard c.loopWiths.pop
    discard c.scopes.pop
    c.facts = dropped
    c.facts.del s.name
  of skWith:
    if c.cur.kind == rkFunc:
      err(s.line, "with is not allowed in func (start/end are side effects)")
    c.delFacts s.name
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
      for pn in ["start", "end"]:
        if pn in c.routineWrites:
          for gw in c.routineWrites[pn]:
            c.delFacts gw
      s.typ = t
    let isLock = s.typ != nil and s.typ.kind == tyLock
    if isLock:
      c.heldLocks.add s.name
    inc c.withDepth
    c.checkBody(s.body)
    dec c.withDepth
    if not isLock:
      # end(x) runs after the body and may write globals too.
      for pn in ["start", "end"]:
        if pn in c.routineWrites:
          for gw in c.routineWrites[pn]:
            c.delFacts gw
    if isLock:
      discard c.heldLocks.pop
      # Facts proven under the lock die with it: another thread may take
      # the lock and write before we ever hold it again.
      var stale: seq[string]
      for k in c.facts.keys:
        var root = k
        if root.endsWith(".len"):
          root = root[0 ..< root.len - 4]
        elif "@" in root:
          root = root.split("@")[0]
        if root in c.sharedProt and s.name in c.sharedProt[root]:
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
      var t: Typ = nil
      if s.value.kind == ekNone:
        if not c.cur.ret.opt:
          err(s.line, "none needs an optional return type")
        s.value.typ = c.cur.ret
        t = c.cur.ret
      else:
        t = c.expectVal(s.value)
        if c.coerceOpt(s.value, c.cur.ret):
          t = c.cur.ret
        elif c.coerceStrLit(s.value, c.cur.ret):
          t = c.cur.ret
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
      let at = c.expectVal(a)
      rejectOpt(at, a)
      if at.kind notin {tyInt, tyBool, tyString, tyStr}:
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
    if e.kind == ekMethod and e.sval in mutMethods:
      let root = e.kids[0].rootIdent
      if root.kind == ekIdent and isPlainGlobal(root.sval):
        note(root.sval, held)
        wr.incl root.sval
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
  for rname, accTab in access:
    var names: HashSet[string]
    for g in accTab.keys:
      names.incl g
    c.routineAccess[rname] = names

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

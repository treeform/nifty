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
## tests and uses. Shared globals require a lock, and mutable owning
## parameters require an exclusive borrow before facts can attach.

import std/[algorithm, strutils, tables, sets]
import common, lexer, types, parser, semantics, progress

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
    allowBigRet: bool        # true only for a call that IS a store target
    heldLocks: seq[string]     # Lock names currently held (lexical with-stack)
    varDecls: Table[string, int]   # var locals/params -> declaration line
    modified: HashSet[string]      # names actually modified this routine
    sharedProt: Table[string, HashSet[string]] # shared global -> its lock(s)
    routineWrites: Table[string, HashSet[string]] # routine -> globals it may write
    usedNames: HashSet[string]     # every module-level name (shadow checks)
    generics: Table[string, Routine]    # generic name -> captured declaration
    instCache: Table[string, string]    # binding key -> instance name
    instances: Table[string, seq[Routine]] # generic name -> its instances
    instStack: seq[string]              # generics being instantiated (recursion)
    lockOrder: Table[string, int]       # lock name -> declaration position
    routineLocks: Table[string, HashSet[string]] # routine -> locks it may take
    overloads: Table[string, seq[string]] # shared name -> unique routine names

const
  IntLow = low(int64)
  IntHigh = high(int64)

proc fullFact(): Fact =
  Fact(lo: IntLow, hi: IntHigh, notZero: false)

proc typeFact(t: Typ): Fact =
  ## The fact implied by a declared type: its range invariant.
  if t != nil and t.kind == IntType:
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
  t.kind != IntType or t.opt or (f.lo >= t.rlo and f.hi <= t.rhi)

## Saturating Interval Arithmetic
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

proc maxMag(f: Fact): uint64 =
  ## Largest absolute value in the interval, including |int64.low|.
  if f.lo == IntLow:
    uint64(IntHigh) + 1'u64
  else:
    uint64(max(-f.lo, max(f.hi, 0'i64)))

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
    if m > uint64(IntHigh):
      Fact(lo: IntLow, hi: IntHigh)
    else:
      Fact(lo: -int64(m), hi: int64(m))

proc modF(a, b: Fact): Fact =
  ## Divisor proven nonzero; |result| < |divisor| and sign follows dividend.
  let m = maxMag(b)
  let bound = if m == 0: 0'i64 else: int64(m - 1'u64)
  var lo = if a.lo >= 0: 0'i64 else: -bound
  var hi = bound
  if a.lo >= 0:
    hi = min(hi, a.hi)
  Fact(lo: lo, hi: hi)

## Symbol Handling

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
    if e.kind in {IdentExpr, FieldExpr}:
      let name = if e.kind == IdentExpr: e.sval else: "this optional"
      err(e.line, "cannot use " &
        (if e.kind == IdentExpr: "'" & name & "'" else: name) &
        " before proving it has a value; test with '.ok' first " &
        "(or use .or(fallback))")
    else:
      err(e.line, "this optional has no stable name to prove; bind it " &
        "first: let r = ...; if r.ok:")

proc coerceOpt(c: var Ctx, e: Expr, target: Typ): bool =
  ## A plain value fits an optional destination (wrapped as ok); `none`
  ## fits any optional destination.
  if target == nil or not target.opt:
    return false
  if e.kind == NoneExpr:
    e.typ = target
    return true
  if e.typ != nil and not e.typ.opt and typeEq(e.typ, deOpt(target)):
    if e.typ.kind == IntType and not exprFact(e).fits(deOpt(target)):
      err(e.line, "cannot prove value (" & rangeStr(exprFact(e)) &
        ") fits " & $deOpt(target) & "; guard or clamp first")
    e.wrapOpt = true
    e.typ = target
    return true
  false

proc coerceStrLit(c: Ctx, e: Expr, target: Typ): bool =
  ## A string literal fits a string[N] destination if its bytes fit.
  if target != nil and target.kind == StringType and e != nil and e.kind == StrExpr:
    if not target.dynamic and e.sval.len > target.len:
      err(e.line, "string literal (" & $e.sval.len & " bytes) does not fit " &
        $target)
    e.typ = target
    true
  else:
    false

proc checkExpr(c: var Ctx, e: Expr): Typ
proc instantiate(c: var Ctx, e: Expr, ats: seq[Typ]): string

proc coerceFloatLit(e: Expr, want: Typ): bool =
  ## A float literal has no width of its own: it takes the width its
  ## destination asks for, like int literals slot into any range.
  if e == nil or want == nil or want.kind != FloatType or want.opt:
    return false
  if e.kind == FloatExpr:
    e.typ = want
    return true
  if e.kind == NegExpr and e.kids[0].kind == FloatExpr:
    e.kids[0].typ = want
    e.typ = want
    return true
  false

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
    e.symKind = ConstSym
    e.mut = false
    e.typ = intType()
    return
  if name in c.globals:
    if c.cur.kind == FuncRoutine:
      err(e.line, "func '" & c.cur.name & "' cannot access global '" & name & "'")
    let t = c.globals[name]
    if t.kind == LockType:
      err(e.line, "'" & name & "' is a Lock; it can only be used in a with statement")
    e.symKind = GlobalSym
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
  while cur.kind in {IndexExpr, FieldExpr}:
    if cur.kind == IndexExpr and cur.kids[0].typ != nil and
        cur.kids[0].typ.kind in {DenseMapType, SparseMapType}:
      return true
    cur = cur.kids[0]
  false

proc pathHasProperty(e: Expr): bool =
  ## Computed properties and container metadata are never writable places.
  var current = e
  while current.kind in {IndexExpr, FieldExpr}:
    if current.kind == FieldExpr and (current.isOptOk or
        current.kids[0].typ == nil or
        current.kids[0].typ.kind != ObjectType):
      return true
    current = current.kids[0]
  false

proc markModified(c: var Ctx, name: string) =
  c.modified.incl name

proc rootIdent(e: Expr): Expr =
  result = e
  while result.kind in {IndexExpr, FieldExpr}:
    result = result.kids[0]

proc capacityBound(t: Typ): int64 =
  ## Dynamic capacities are bounded by the runtime's signed length type.
  if t.dynamic: IntHigh else: t.len

proc containsType(container, item: Typ): bool =
  ## A borrowed field or element may belong to a larger global owner.
  if container == nil or item == nil:
    return false
  if typeEq(deOpt(container), deOpt(item)):
    return true
  if item.dynamic and container.kind == item.kind:
    if item.kind == StringType:
      return true
    if item.kind == SeqType and typeEq(container.elem, item.elem) and
        container.elem.width == item.elem.width:
      return true
  if containsType(container.elem, item) or containsType(container.val, item):
    return true
  for field in container.fields:
    if containsType(field.typ, item):
      return true
  false

proc validateOwnedType(t: Typ, line: int) =
  ## Reject layouts whose existing operations cannot preserve ownership.
  if t == nil:
    return
  if t.opt and hasOwned(t):
    err(line, "an owning string or seq cannot be optional; use an empty owner")
  if t.kind in {QueueType, ChannelType, DenseMapType, SparseMapType} and
      hasOwned(t):
    err(line, "owning strings and seqs cannot be stored in queues, channels, " &
      "or maps; pass caller-owned storage instead")
  validateOwnedType(t.elem, line)
  validateOwnedType(t.val, line)
  for field in t.fields:
    validateOwnedType(field.typ, line)

proc foreignWritable(t: Typ): bool =
  ## Checks raw storage for range and container invariants.
  if t == nil or t.opt:
    return false
  case t.kind
  of IntType:
    let unsigned = t.dname.startsWith("uint") or t.dname == "char"
    if t.width == 8 and unsigned:
      return false # C uint64 can exceed nifty's signed interval domain.
    let bits = if t.width == 0: 64 else: t.width * 8
    let lo = if unsigned: 0'i64 else:
      (if bits == 64: low(int64) else: -(1'i64 shl (bits - 1)))
    let hi = if bits == 64: high(int64)
      elif unsigned: (1'i64 shl bits) - 1
      else: (1'i64 shl (bits - 1)) - 1
    t.rlo == lo and t.rhi == hi
  of FloatType:
    true
  of ArrayType:
    foreignWritable(t.elem)
  of ObjectType:
    for field in t.fields:
      if not foreignWritable(field.typ):
        return false
    true
  else:
    false

proc declFactByName(c: Ctx, name: string): Fact =
  if name.len > 4 and name.endsWith(".len"):
    let parts = name[0 ..< name.len - 4].split('.')
    let root = parts[0]
    var container: Typ
    for i in countdown(c.scopes.len - 1, 0):
      if root in c.scopes[i]:
        container = c.scopes[i][root].typ
        break
    if container == nil and root in c.globals:
      container = c.globals[root]
    for i in 1 ..< parts.len:
      if container == nil or container.kind != ObjectType:
        return fullFact()
      var fieldType: Typ
      for field in container.fields:
        if field.name == parts[i]:
          fieldType = field.typ
      container = fieldType
    if container != nil:
      if container.kind in {SeqType, StringType, QueueType, SparseMapType}:
        return Fact(lo: 0, hi: container.capacityBound)
      if container.kind in {SetType, DenseMapType}:
        return Fact(lo: 0, hi: container.setSize)
    return fullFact()
  for i in countdown(c.scopes.len - 1, 0):
    if name in c.scopes[i]:
      return typeFact(c.scopes[i][name].typ)
  if name in c.globals:
    return typeFact(c.globals[name])
  fullFact()

proc curFact(c: Ctx, name: string): Fact =
  c.facts.getOrDefault(name, c.declFactByName(name))

## Facts

proc tryConstEval(c: Ctx, e: Expr): tuple[known: bool, val: int64] =
  ## Evaluate an expression at compile time if possible.
  case e.kind
  of IntExpr:
    (true, e.ival)
  of IdentExpr:
    if e.sval in c.consts:
      (true, c.consts[e.sval])
    else:
      (false, 0'i64)
  of NegExpr:
    let r = c.tryConstEval(e.kids[0])
    let negated = satNeg(r.val)
    (r.known and not negated.ov, negated.v)
  of BinExpr:
    let a = c.tryConstEval(e.kids[0])
    let b = c.tryConstEval(e.kids[1])
    if not (a.known and b.known):
      (false, 0'i64)
    else:
      case e.sval
      of "+":
        let sum = satAdd(a.val, b.val)
        (not sum.ov, sum.v)
      of "-":
        let difference = satSub(a.val, b.val)
        (not difference.ov, difference.v)
      of "*":
        let product = satMul(a.val, b.val)
        (not product.ov, product.v)
      of "/":
        if b.val == 0 or (a.val == IntLow and b.val == -1):
          (false, 0'i64)
        else:
          (true, a.val div b.val)
      of "%":
        if b.val == 0 or (a.val == IntLow and b.val == -1):
          (false, 0'i64)
        else:
          (true, a.val mod b.val)
      else: (false, 0'i64)
  else:
    (false, 0'i64)

proc factEligibleIdent(c: Ctx, e: Expr): bool =
  ## Can flow facts attach to this identifier here? Locals and non-var
  ## parameters always qualify. A global qualifies when it is thread-owned
  ## (accessed by at most one thread) or when the lock that protects it is
  ## currently held — in both cases no other thread can change it between
  ## a test and a use. Only owning var parameters have exclusive borrows.
  if e.kind != IdentExpr:
    return false
  case e.symKind
  of LocalSym:
    true
  of ParamSym:
    not e.isVarParam or hasOwned(e.typ)
  of GlobalSym:
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
  if e.typ != nil and e.typ.kind == IntType and c.factEligibleIdent(e):
    e.sval
  else:
    ""

proc stablePathName(c: Ctx, e: Expr): string

proc lenPathName(c: Ctx, e: Expr): string =
  ## "s.len" when e reads the length of a factable seq/string variable.
  if e.kind == FieldExpr and e.sval == "len" and
      e.kids[0].typ != nil and
      e.kids[0].typ.kind in {SeqType, StringType, SetType, QueueType,
        DenseMapType, SparseMapType}:
    let path = c.stablePathName(e.kids[0])
    if path != "":
      return path & ".len"
  ""

proc capPathName(c: Ctx, e: Expr): string =
  ## Names a dynamic container's capacity for a guarded foreign call.
  if e.kind == FieldExpr and e.sval == "cap" and
      e.kids[0].typ != nil and e.kids[0].typ.dynamic:
    let path = c.stablePathName(e.kids[0])
    if path != "":
      return path & ".cap"
  ""

proc capCountKey(c: Ctx, buffer, count: Expr): string =
  ## Names a proven count <= capacity relationship for two stable values.
  if count.kind != IdentExpr or c.factName(count) == "":
    return ""
  let path = c.stablePathName(buffer)
  if path == "":
    return ""
  path & "@cap@" & count.sval

proc stablePathName(c: Ctx, e: Expr): string =
  ## A provable name: an eligible ident, or a pure field chain on one
  ## ("p.fix"). Indexed paths have no stable name.
  case e.kind
  of IdentExpr:
    if c.factEligibleIdent(e): e.sval else: ""
  of FieldExpr:
    let inner = c.stablePathName(e.kids[0])
    if inner != "" and not e.isOptOk: inner & "." & e.sval else: ""
  else:
    ""

proc indexFactKey(c: Ctx, base, index: Expr): string =
  ## Index predicates retain the owner path and the index dependency.
  let path = c.stablePathName(base)
  if path == "":
    return ""
  let constant = c.tryConstEval(index)
  if constant.known:
    return path & "@index=" & $constant.val
  if index.kind == IdentExpr and c.factEligibleIdent(index):
    return path & "@index@" & index.sval
  ""

proc mapFactKey(c: Ctx, m: Expr, k: Expr): string =
  ## The containment-predicate key "m@k" for a stable map/key pair, or ""
  ## when either side cannot carry a fact.
  if m.kind != IdentExpr or not c.factEligibleIdent(m):
    return ""
  let kv = c.tryConstEval(k)
  if kv.known:
    return m.sval & "@=" & $kv.val
  if k.kind == StrExpr:
    return m.sval & "@=s" & k.sval
  if k.kind == IdentExpr and c.factEligibleIdent(k):
    return m.sval & "@" & k.sval
  ""

proc factOrLenName(c: Ctx, e: Expr): string =
  result = c.factName(e)
  if result == "":
    result = c.lenPathName(e)
  if result == "":
    result = c.capPathName(e)

proc delFacts(c: var Ctx, name: string) =
  ## Forget everything about a variable: its own fact, its length fact,
  ## and any containment predicates it appears in (either side).
  c.facts.del name
  c.facts.del name & ".len"
  c.facts.del name & ".cap"
  var stale: seq[string]
  for k in c.facts.keys:
    if k.startsWith(name & "@") or k.startsWith(name & ".") or
        k.endsWith("@" & name):
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
  if e.kind != BinExpr or e.sval notin ["==", "!=", "<", "<=", ">", ">="]:
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

proc collectAssignedExpr(c: Ctx, e: Expr, s: var HashSet[string])

proc addCondFacts(c: var Ctx, e: Expr, negated = false) =
  ## Record what is proven when `e` is true (or false, if negated).
  if e.kind == NotExpr:
    c.addCondFacts(e.kids[0], not negated)
    return
  if e.kind == MethodExpr and e.sval in ["reserve", "resize"] and
      not negated and e.kids.len == 2 and e.kids[0].typ.dynamic:
    let path = c.stablePathName(e.kids[0])
    if path != "":
      let size = exprFact(e.kids[1])
      let old = c.curFact(path & ".cap")
      let lo = if e.sval == "reserve": max(old.lo, size.lo)
        else: size.lo
      c.facts[path & ".cap"] = Fact(lo: lo, hi: IntHigh)
      let key = c.capCountKey(e.kids[0], e.kids[1])
      if key != "":
        c.facts[key] = Fact(lo: 1, hi: 1)
  if e.kind == FieldExpr and e.isOptOk and not negated:
    let pn = c.stablePathName(e.kids[0])
    if pn != "":
      c.facts[pn & "@ok"] = Fact(lo: 1, hi: 1)
    return
  if e.kind == MethodExpr and e.sval == "contains" and not negated and
      e.kids.len == 2 and e.kids[0].typ.kind in
      {DenseMapType, SparseMapType}:
    let key = c.mapFactKey(e.kids[0], e.kids[1])
    if key != "":
      c.facts[key] = Fact(lo: 1, hi: 1)
    return
  if e.kind == MethodExpr and e.kids[0].typ != nil and
      e.kids[0].typ.dynamic and not negated:
    let base = c.stablePathName(e.kids[0])
    if base != "" and e.sval in ["resize", "setLen"]:
      c.facts[base & ".len"] = exprFact(e.kids[1])
    return
  if e.kind != BinExpr:
    return
  if not negated and e.sval == "and":
    c.addCondFacts(e.kids[0])
    var touched: HashSet[string]
    c.collectAssignedExpr(e.kids[1], touched)
    for name in touched:
      c.delFacts name
    c.addCondFacts(e.kids[1])
    return
  if negated and e.sval == "or":
    c.addCondFacts(e.kids[0], true)
    var touched: HashSet[string]
    c.collectAssignedExpr(e.kids[1], touched)
    for name in touched:
      c.delFacts name
    c.addCondFacts(e.kids[1], true)
    return
  # A comparison that mutates an operand cannot refine its current value.
  var touched: HashSet[string]
  c.collectAssignedExpr(e, touched)
  if touched.len > 0:
    return
  var left = e.kids[0]
  var right = e.kids[1]
  var relation = if negated: negateCmp(e.sval) else: e.sval
  if relation in ["<=", "<"]:
    if right.kind == FieldExpr and right.sval == "cap":
      let key = c.capCountKey(right.kids[0], left)
      if key != "":
        c.facts[key] = Fact(lo: 1, hi: 1)
  elif relation in [">=", ">"]:
    if left.kind == FieldExpr and left.sval == "cap":
      let key = c.capCountKey(left.kids[0], right)
      if key != "":
        c.facts[key] = Fact(lo: 1, hi: 1)
  if relation == ">":
    swap(left, right)
    relation = "<"
  if relation == "<" and right.kind == FieldExpr and
      right.sval == "len" and right.kids[0].typ != nil and
      right.kids[0].typ.kind in {SeqType, StringType}:
    let key = c.indexFactKey(right.kids[0], left)
    if key != "":
      c.facts[key] = Fact(lo: 1, hi: 1)
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
  if e.kind == MethodExpr and e.sval in mutMethods:
    let root = e.kids[0].rootIdent
    if root.kind == IdentExpr:
      s.incl root.sval
  if e.kind in {CallExpr, MethodExpr} and
      (e.kind == CallExpr or e.sval notin builtinMethods):
    let callees = c.overloads.getOrDefault(e.sval, @[e.sval])
    for name in callees:
      if name in c.routineTab:
        let r = c.routineTab[name]
        for i, arg in e.kids:
          if i < r.params.len and r.params[i].isVar:
            let root = arg.rootIdent
            if root.kind == IdentExpr:
              s.incl root.sval
      if name in c.routineWrites:
        for g in c.routineWrites[name]:
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
    if st.kind == AssignStmt:
      let root = st.lhs.rootIdent
      if root.kind == IdentExpr:
        s.incl root.sval
    if st.kind == WithStmt:
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
  of ReturnStmt:
    true
  of IfStmt:
    if s.elseBody.len == 0:
      return false
    for br in s.elifs:
      if not alwaysReturns(br.body):
        return false
    alwaysReturns(s.elseBody)
  of BlockStmt:
    alwaysReturns(s.body)
  else:
    false

proc alwaysExits(body: seq[Stmt]): bool =
  ## Does this body always leave the enclosing block (return or break)?
  body.len > 0 and (body[^1].kind in {ReturnStmt, BreakStmt} or alwaysReturns(body))

proc hasLoopBreak(body: seq[Stmt]): bool =
  ## Is there a break that targets the enclosing loop (not a nested one)?
  for st in body:
    case st.kind
    of BreakStmt:
      return true
    of WhileStmt, ForStmt, LoopStmt, ForEachStmt:
      discard # a break in there targets the inner loop
    of IfStmt:
      for br in st.elifs:
        if hasLoopBreak(br.body):
          return true
      if hasLoopBreak(st.elseBody):
        return true
    of WithStmt, BlockStmt:
      if hasLoopBreak(st.body):
        return true
    else:
      discard

## Accumulator Widening

proc containsIdent(e: Expr, v: string): bool =
  if e.isNil:
    return false
  if e.kind == IdentExpr and e.sval == v:
    return true
  for k in e.kids:
    if containsIdent(k, v):
      return true

proc dispatchKey(t: Typ): string =
  ## The "kind" of a first parameter or argument, for overload
  ## resolution: overloads of one name must differ in this, so a call
  ## picks its routine by what its first argument is. Coarse on
  ## purpose - ranges, capacities, and widths never take part.
  if t == nil or t.opt:
    return ""
  case t.kind
  of IntType: "an int"
  of FloatType: "a float"
  of BoolType: "a bool"
  of StringType, StringLitType: "a string"
  of ArrayType: "an array"
  of SeqType: "a seq"
  of QueueType: "a queue"
  of SetType: "a set"
  of DenseMapType, SparseMapType: "a map"
  of ObjectType: t.name
  else: ""

proc declTypeOf(c: Ctx, e: Expr): Typ =
  ## The type of a value expression from declarations only (no checking).
  case e.kind
  of IdentExpr:
    for i in countdown(c.scopes.len - 1, 0):
      if e.sval in c.scopes[i]:
        return c.scopes[i][e.sval].typ
    if e.sval in c.globals:
      return c.globals[e.sval]
    nil
  of IndexExpr:
    let b = c.declTypeOf(e.kids[0])
    if b != nil and b.kind == ArrayType: b.elem else: nil
  of FieldExpr:
    let b = c.declTypeOf(e.kids[0])
    if b != nil and b.kind == ObjectType:
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
  of IntExpr:
    result = (true, Fact(lo: e.ival, hi: e.ival))
  of IdentExpr:
    if e.sval == loopVar:
      result = (true, loopFact)
    elif e.sval in c.consts:
      let v = c.consts[e.sval]
      result = (true, Fact(lo: v, hi: v))
    else:
      let t = c.declTypeOf(e)
      if t != nil and t.kind == IntType:
        result = (true, typeFact(t))
  of NegExpr:
    let a = c.declFact(e.kids[0], loopVar, loopFact)
    if a.ok:
      let l = satNeg(a.f.hi)
      let h = satNeg(a.f.lo)
      if not (l.ov or h.ov):
        result = (true, Fact(lo: l.v, hi: h.v))
  of BinExpr:
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
  of IndexExpr, FieldExpr:
    let t = c.declTypeOf(e)
    if t != nil and t.kind == IntType:
      result = (true, typeFact(t))
  of CallExpr:
    if e.sval in c.routineTab:
      let rt = c.routineTab[e.sval].ret
      if rt != nil and rt.kind == IntType:
        result = (true, typeFact(rt))
  else:
    discard

proc accumWiden(c: Ctx, s: Stmt, assigned: HashSet[string],
    loopFact: Fact, entry: Table[string, Fact],
    trips: int64): Table[string, Fact] =
  ## Induction for accumulators in a counted for loop: a local assigned
  ## ONLY as v = v + e / v = v - e (e independent of v, not inside a
  ## nested loop) keeps a widened fact instead of losing everything:
  ## its entry value plus trips * the per-iteration delta. Inside the
  ## body at most trips - 1 additions have run, so callers pass a
  ## smaller bound for the in-body fact than for the after-loop fact.
  for v in assigned:
    var declTyp: Typ = nil
    for i in countdown(c.scopes.len - 1, 0):
      if v in c.scopes[i]:
        if c.scopes[i][v].kind == LocalSym:
          declTyp = c.scopes[i][v].typ
        break
    if declTyp == nil or declTyp.kind != IntType:
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
        if v in touched or (st.kind == WithStmt and st.name == v):
          ok = false
        if st.kind == AssignStmt and st.lhs.kind == IdentExpr and st.lhs.sval == v:
          if nested:
            ok = false
          else:
            let r = st.rhs
            if r.kind == BinExpr and r.sval in ["+", "-"] and
                r.kids[0].kind == IdentExpr and r.kids[0].sval == v and
                not containsIdent(r.kids[1], v):
              sites.add (sign: (if r.sval == "+": 1 else: -1), e: r.kids[1])
            else:
              ok = false
        let deeper = nested or st.kind in {WhileStmt, ForStmt, LoopStmt, ForEachStmt}
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
    var dLoOverflow = false
    var dHiOverflow = false
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
      let
        lowerStep = satAdd(dLo, min(0'i64, lo))
        upperStep = satAdd(dHi, max(0'i64, hi))
      dLoOverflow = dLoOverflow or lowerStep.ov
      dHiOverflow = dHiOverflow or upperStep.ov
      dLo = lowerStep.v
      dHi = upperStep.v
    if not good:
      continue
    # Saturation only widens the interval, which stays sound; the declared
    # range is an invariant, so the intersection is sound and tighter.
    let v0 = entry.getOrDefault(v, c.declFactByName(v))
    let dt = typeFact(declTyp)
    let
      lowerDelta = satMul(trips, dLo)
      upperDelta = satMul(trips, dHi)
      lower = if (trips > 0 and dLoOverflow) or lowerDelta.ov: IntLow
        else: satAdd(v0.lo, lowerDelta.v).v
      upper = if (trips > 0 and dHiOverflow) or upperDelta.ov: IntHigh
        else: satAdd(v0.hi, upperDelta.v).v
    result[v] = Fact(lo: max(lower, dt.lo), hi: min(upper, dt.hi))

## Termination Proof

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
    if st.kind == AssignStmt and st.lhs.kind == IdentExpr:
      let v = st.lhs.sval
      var cd = cands.getOrDefault(v, Cand())
      var thisDir = 0
      var step = 1'i64
      let r = st.rhs
      if r.kind == BinExpr and r.kids[0].kind == IdentExpr and r.kids[0].sval == v:
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
    if st.kind == WithStmt:
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

  var conditionWrites: HashSet[string]
  c.collectAssignedExpr(s.cond, conditionWrites)
  result = 0
  for v, cd in cands:
    if cd.bad or not cd.top or cd.dir == 0 or v in conditionWrites:
      continue
    var t: Typ = nil
    for i in countdown(c.scopes.len - 1, 0):
      if v in c.scopes[i]:
        if c.scopes[i][v].kind == LocalSym:
          t = c.scopes[i][v].typ
        break
    if t == nil or t.kind != IntType:
      continue
    var bound = 0'i64
    case cd.dir
    of 1, -1:
      if t.rhi < IntHigh and t.rlo > IntLow:
        let span = satSub(t.rhi, t.rlo)
        if not span.ov:
          let count = satAdd(span.v div cd.minStep, 1)
          if not count.ov:
            bound = count.v
    else:
      if c.condZeroExit(s.cond, v):
        bound = 64 # |v| at least halves every pass; int64 is 64 bits
    if bound > 0 and (result == 0 or bound < result):
      result = bound

## Range Compatibility

proc typeRangeEq(a, b: Typ): bool =
  if a != nil and b != nil and (a.width != b.width): return false
  ## Exact range match, required for var parameters (writes flow both ways).
  if a.kind != b.kind or a.dynamic != b.dynamic:
    return false
  case a.kind
  of IntType: a.rlo == b.rlo and a.rhi == b.rhi
  of ArrayType, SeqType, QueueType: a.len == b.len and typeRangeEq(a.elem, b.elem)
  of DenseMapType: typeRangeEq(a.val, b.val)
  of SparseMapType: a.len == b.len and typeRangeEq(a.elem, b.elem) and
    typeRangeEq(a.val, b.val)
  else: true

proc typeRangeFits(a, b: Typ): bool =
  ## a is usable where b is expected read-only (a's ranges inside b's).
  if a.kind != b.kind or a.dynamic != b.dynamic:
    return false
  case a.kind
  of IntType: a.rlo >= b.rlo and a.rhi <= b.rhi
  of ArrayType, SeqType, QueueType: a.len == b.len and typeRangeFits(a.elem, b.elem)
  of DenseMapType: typeRangeFits(a.val, b.val)
  of SparseMapType: a.len == b.len and typeRangeFits(a.elem, b.elem) and
    typeRangeFits(a.val, b.val)
  else: true

proc zeroOk(t: Typ): bool =
  ## Can this type be zero-initialized without violating a range?
  if t.opt:
    return true # zero-init means none
  case t.kind
  of IntType: t.rlo <= 0 and t.rhi >= 0
  of ArrayType: zeroOk(t.elem)
  of ObjectType:
    for f in t.fields:
      if not zeroOk(f.typ):
        return false
    true
  else: true

proc rejectOwnerEffects(c: Ctx, owner, expr: Expr, borrowedView = false) =
  ## An evaluated address must stay valid while later expressions run.
  let root = owner.rootIdent
  if root.kind != IdentExpr or (not hasOwned(root.typ) and not borrowedView):
    return
  var touched: HashSet[string]
  c.collectAssignedExpr(expr, touched)
  if root.sval in touched:
    err(expr.line, "cannot modify '" & root.sval &
      "' while an argument or element of its allocation is borrowed")

proc checkDynamicMethod(c: var Ctx, e: Expr, bt: Typ): Typ =
  ## Growable operations are fallible boundaries on caller-owned storage.
  let count = e.kids.len - 1
  let root = e.kids[0].rootIdent
  let path = c.stablePathName(e.kids[0])
  let key = if path != "": path & ".len" else: ""
  let length = if key != "": c.curFact(key) else: Fact(lo: 0, hi: IntHigh)
  if e.sval in mutMethods:
    if c.cur.kind == FuncRoutine:
      err(e.line, "growable storage can only be mutated in a proc or thread")
    c.delFacts root.sval
  template arity(n: int) =
    if count != n:
      err(e.line, e.sval & " takes " & $n & " argument(s)")
  template integer(i: int) =
    if c.expectVal(e.kids[i]).kind != IntType:
      err(e.kids[i].line, e.sval & " needs an integer argument")
  template stringArg(i: int) =
    let argumentType = c.expectVal(e.kids[i])
    if argumentType.kind notin {StringType, StringLitType}:
      err(e.kids[i].line, e.sval & " needs a string argument")
  case e.sval
  of "resize", "setLen", "reserve":
    arity(1)
    integer(1)
    if exprFact(e.kids[1]).lo < 0:
      err(e.kids[1].line, "cannot prove the requested size is nonnegative")
    if e.sval != "reserve" and bt.kind == SeqType and not zeroOk(bt.elem):
      err(e.line, "resize requires a zero-initializable element type; " &
        "use add or push to initialize elements")
    result = Typ(kind: BoolType)
  of "clear":
    arity(0)
    if key != "":
      c.facts[key] = Fact(lo: 0, hi: 0)
  of "copyFrom":
    arity(1)
    if bt.kind == StringType:
      stringArg(1)
    else:
      let source = c.expectVal(e.kids[1])
      if source.kind != SeqType or not typeEq(source.elem, bt.elem) or
          source.elem.width != bt.elem.width or
          not typeRangeFits(source.elem, bt.elem):
        err(e.line, "copyFrom needs a sequence with compatible elements")
      e.kids[1].borrowedView = not source.dynamic
    result = Typ(kind: BoolType)
  of "add", "push":
    arity(1)
    if bt.kind == StringType:
      stringArg(1)
    else:
      var at: Typ
      if e.kids[1].kind == NoneExpr:
        if not bt.elem.opt:
          err(e.line, "none needs an optional element type")
        e.kids[1].typ = bt.elem
        at = bt.elem
      else:
        at = c.expectVal(e.kids[1])
        if c.coerceOpt(e.kids[1], bt.elem) or
            c.coerceStrLit(e.kids[1], bt.elem) or
            coerceFloatLit(e.kids[1], bt.elem):
          at = bt.elem
      if not typeEq(at, bt.elem) or
          (bt.elem.kind != IntType and not typeRangeFits(at, bt.elem)):
        err(e.line, "cannot add " & $at & " to " & $bt)
      if bt.elem.kind == IntType and not exprFact(e.kids[1]).fits(bt.elem):
        err(e.line, "cannot prove value fits element range " & $bt.elem)
    result = Typ(kind: BoolType)
  of "pop":
    arity(0)
    if bt.kind != SeqType:
      err(e.line, "pop requires a sequence")
    if hasOwned(bt.elem):
      err(e.line, "cannot pop an owning element; shrink the sequence instead")
    if bigRet(bt.elem):
      err(e.line, "pop cannot copy a large element; use guarded indexing " &
        "and pass the element to a child procedure")
    if length.lo < 1:
      err(e.line, "cannot prove the sequence is not empty; test .len first")
    if key != "":
      c.facts[key] = Fact(lo: length.lo - 1, hi: length.hi - 1)
    result = bt.elem
    e.setFact typeFact(result)
  of "get":
    arity(1)
    integer(1)
    let elem = if bt.kind == StringType: intType(0, 255) else: bt.elem
    if hasOwned(elem) or elem.opt:
      err(e.line, "get requires a non-owning, non-optional element type")
    result = optOf(elem)
  of "addByte", "addNum":
    arity(1)
    if bt.kind != StringType:
      err(e.line, e.sval & " requires a string")
    integer(1)
    let value = exprFact(e.kids[1])
    if e.sval == "addByte" and (value.lo < 0 or value.hi > 255):
      err(e.line, "cannot prove the byte is 0 .. 255")
    result = Typ(kind: BoolType)
  of "copyRange":
    arity(3)
    if bt.kind != StringType:
      err(e.line, "copyRange requires a string")
    stringArg(1)
    integer(2)
    integer(3)
    result = Typ(kind: BoolType)
  of "startsWith", "endsWith", "contains", "find":
    arity(1)
    if bt.kind != StringType:
      err(e.line, e.sval & " requires a string")
    stringArg(1)
    result = if e.sval == "find": optOf(intType(0, IntHigh - 1))
      else: Typ(kind: BoolType)
  of "findByte":
    arity(1)
    if bt.kind != StringType:
      err(e.line, "findByte requires a string")
    integer(1)
    result = optOf(intType(0, IntHigh - 1))
  of "toInt":
    arity(0)
    if bt.kind != StringType:
      err(e.line, "toInt requires a string")
    result = optOf(intType())
  else:
    err(e.line, $bt & " has no method '" & e.sval & "'")
  for i in 1 ..< e.kids.len:
    c.rejectOwnerEffects(e.kids[0], e.kids[i])
    if hasOwned(e.kids[i].typ) or e.kids[i].typ.kind == StringType:
      for j in i + 1 ..< e.kids.len:
        c.rejectOwnerEffects(e.kids[i], e.kids[j], borrowedView = true)
    let argument = e.kids[i].rootIdent
    if e.sval in mutMethods and argument.kind == IdentExpr and
        argument.sval == root.sval and
        (hasOwned(e.kids[i].typ) or e.kids[i].typ.kind == StringType):
      err(e.line, "cannot borrow '" & root.sval &
        "' as both mutation target and source; use separate storage")
  if e.sval in mutMethods and key != "" and
      e.sval notin ["clear", "pop"]:
    c.facts[key] = Fact(lo: 0, hi: IntHigh)

## Expression Checking

proc checkExpr(c: var Ctx, e: Expr): Typ =
  case e.kind
  of FloatExpr:
    e.typ = floatType(8, "float64") # literals default to float64
  of IntExpr:
    e.typ = intType()
    e.setFact Fact(lo: e.ival, hi: e.ival, notZero: e.ival != 0)
  of BoolExpr:
    e.typ = Typ(kind: BoolType)
  of NoneExpr:
    err(e.line, "none needs an optional destination " &
      "(var x: int? = none / x = none / return none)")
  of StrExpr:
    if e.typ == nil or e.typ.kind != StringType:
      e.typ = Typ(kind: StringLitType)
  of IdentExpr:
    c.resolveIdent(e)
    if e.typ != nil and e.typ.opt and c.factEligibleIdent(e) and
        (e.sval & "@ok") in c.facts:
      # Proven present: the name acts as its base type from here.
      e.typ = deOpt(e.typ)
      e.unwrapOpt = true
    if e.typ.kind == IntType and not e.typ.opt:
      if e.symKind == ConstSym:
        let v = c.consts[e.sval]
        e.setFact Fact(lo: v, hi: v, notZero: v != 0)
      elif c.factName(e) != "":
        e.setFact c.curFact(e.sval)
      else:
        # Unowned globals outside their lock and var params: only the
        # declared range invariant holds.
        e.setFact typeFact(e.typ)
  of NegExpr:
    let nt = c.expectVal(e.kids[0])
    rejectOpt(nt, e.kids[0])
    if nt.kind == FloatType:
      e.typ = nt
      return e.typ
    if nt.kind != IntType:
      err(e.line, "unary '-' needs an int or float operand")
    let a = exprFact(e.kids[0])
    let l = satNeg(a.hi)
    let h = satNeg(a.lo)
    if l.ov or h.ov:
      err(e.line, "cannot prove unary '-' does not overflow (operand is " &
        rangeStr(a) & ")")
    e.typ = intType()
    e.setFact Fact(lo: l.v, hi: h.v, notZero: a.notZero)
  of NotExpr:
    if c.expectVal(e.kids[0]).kind != BoolType:
      err(e.line, "'not' needs a bool operand")
    e.typ = Typ(kind: BoolType)
  of BinExpr:
    case e.sval
    of "and", "or":
      if c.expectVal(e.kids[0]).kind != BoolType:
        err(e.line, "'" & e.sval & "' needs bool operands")
      # Short-circuit: the right side is only evaluated when the left side
      # already held (and) or failed (or) — check it under those facts.
      let saved = c.facts
      c.addCondFacts(e.kids[0], negated = e.sval == "or")
      inc c.mutBan # the right side may be skipped at runtime
      if c.expectVal(e.kids[1]).kind != BoolType:
        err(e.line, "'" & e.sval & "' needs bool operands")
      dec c.mutBan
      c.facts = saved
      # The right side MAY have run: anything it can change is unknown now.
      var rhsTouched: HashSet[string]
      c.collectAssignedExpr(e.kids[1], rhsTouched)
      for n in rhsTouched:
        c.delFacts n
      e.typ = Typ(kind: BoolType)
    else:
      let a = c.expectVal(e.kids[0])
      let b = c.expectVal(e.kids[1])
      rejectOpt(a, e.kids[0])
      rejectOpt(b, e.kids[1])
      var fa = a
      var fb = b
      if fa.kind == FloatType or fb.kind == FloatType:
        # Float literals take the width of the other side.
        if coerceFloatLit(e.kids[1], fa):
          fb = fa
        elif coerceFloatLit(e.kids[0], fb):
          fa = fb
        if fa.kind != FloatType or fb.kind != FloatType or fa.width != fb.width:
          err(e.line, "'" & e.sval & "' cannot mix " & $fa & " and " & $fb &
            "; convert explicitly (float64(x), float32(x), or x.toInt)")
        case e.sval
        of "+", "-", "*", "/":
          # IEEE never traps: x / 0.0 is inf, overflow is inf, 0.0 / 0.0
          # is NaN - all values, no exits. Floats carry no proofs.
          e.typ = fa
        of "%":
          err(e.line, "'%' is not defined for floats")
        of "<", "<=", ">", ">=", "==", "!=":
          e.typ = Typ(kind: BoolType) # NaN compares false; == is IEEE ==
        else:
          err(e.line, "internal: unknown operator " & e.sval)
        return e.typ
      case e.sval
      of "+", "-", "*", "/", "%":
        if a.kind != IntType or b.kind != IntType:
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
            elif d.kind == IdentExpr and c.factName(d) != "":
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
        if a.kind != IntType or b.kind != IntType:
          err(e.line, "'" & e.sval & "' needs int operands, got " & $a & " and " & $b)
        e.typ = Typ(kind: BoolType)
      of "==", "!=":
        if not typeEq(a, b) or a.kind notin {IntType, BoolType}:
          err(e.line, "'" & e.sval & "' needs two ints or two bools, got " &
            $a & " and " & $b)
        e.typ = Typ(kind: BoolType)
      else:
        err(e.line, "internal: unknown operator " & e.sval)
  of IndexExpr:
    let base = c.expectVal(e.kids[0])
    if base.kind in {DenseMapType, SparseMapType}:
      # Reading m[k] must be proven present: a contains test, a strict
      # write, or iteration provides the fact.
      var kt = c.expectVal(e.kids[1])
      if base.kind == SparseMapType and c.coerceStrLit(e.kids[1], base.elem):
        kt = base.elem
      let want = if base.kind == DenseMapType: intType() else: base.elem
      if (base.kind == DenseMapType and kt.kind != IntType) or
          (base.kind == SparseMapType and not typeEq(kt, base.elem)):
        err(e.kids[1].line, "map key must be " & $base.elem & ", got " & $kt)
      let key = c.mapFactKey(e.kids[0], e.kids[1])
      if key == "" or key notin c.facts:
        err(e.line, "cannot prove the key is present; test with 'if " &
          (if e.kids[0].kind == IdentExpr: e.kids[0].sval else: "m") &
          ".contains(k):' first, or use .get(k, fallback)")
      e.typ = base.val
      e.setFact typeFact(base.val)
      return e.typ
    if base.kind notin {ArrayType, SeqType, StringType}:
      err(e.line, "'[]' needs an array, seq, string, or map, got " & $base)
    if c.expectVal(e.kids[1]).kind != IntType:
      err(e.line, "index must be an int")
    c.rejectOwnerEffects(e.kids[0], e.kids[1])
    let f = exprFact(e.kids[1])
    if (not base.dynamic and f.lo > base.len - 1) or f.hi < 0:
      err(e.line, "index " & rangeStr(f) & " is always out of bounds for " &
        $base)
    if base.kind == ArrayType:
      # The index proof: the index interval must fit inside 0 ..< len.
      if f.lo < 0 or f.hi > base.len - 1:
        err(e.line, "cannot prove index is inside 0 ..< " & $base.len &
          " (index is " & rangeStr(f) & "); test it first")
      e.typ = base.elem
    else:
      # Only the live part 0 ..< len of a seq/string is readable/writable.
      var lf = Fact(lo: 0, hi: base.capacityBound)
      let path = c.stablePathName(e.kids[0])
      if path != "":
        lf = c.facts.getOrDefault(path & ".len", lf)
      let relation = c.indexFactKey(e.kids[0], e.kids[1])
      if f.lo < 0 or (f.hi > lf.lo - 1 and
          (relation == "" or relation notin c.facts)):
        err(e.line, "cannot prove index is below the length (index is " &
          rangeStr(f) & ", length is at least " & $lf.lo &
          "); test .len first")
      e.typ = if base.kind == SeqType: base.elem else: intType(0, 255)
    e.setFact typeFact(e.typ)
  of FieldExpr:
    let base = c.expectVal(e.kids[0])
    if e.sval == "ok" and (base.opt or e.kids[0].unwrapOpt):
      # Reading the presence flag never needs a proof; undo any strip so
      # codegen reads the flag, not the value.
      if e.kids[0].unwrapOpt:
        e.kids[0].unwrapOpt = false
        if e.kids[0].kind == IdentExpr:
          e.kids[0].typ = c.declTypeOf(e.kids[0])
        elif e.kids[0].typ != nil:
          e.kids[0].typ = optOf(e.kids[0].typ)
      e.isOptOk = true
      e.typ = Typ(kind: BoolType)
      return e.typ
    rejectOpt(base, e.kids[0])
    if base.kind == StringType and e.sval == "toInt":
      # Parse a decimal number, or none: absence is a value to consult.
      e.typ = optOf(intType())
      return e.typ
    if base.kind in {SeqType, StringType, SetType, QueueType, DenseMapType, SparseMapType}:
      if e.sval == "cap" and base.dynamic:
        e.typ = intType(0, IntHigh)
        let key = c.capPathName(e)
        if key == "":
          e.setFact typeFact(e.typ)
        else:
          e.setFact c.facts.getOrDefault(key, typeFact(e.typ))
        return e.typ
      if e.sval != "len":
        err(e.line, $base & " has no property '" & e.sval &
          (if base.kind == StringType: "' (only .len and .toInt)"
           else: "' (only .len)"))
      e.typ = intType(0,
        (if base.kind in {SetType, DenseMapType}: base.setSize
         else: base.capacityBound))
      let key = c.lenPathName(e)
      if key != "":
        e.setFact c.curFact(key)
      else:
        let path = c.stablePathName(e.kids[0])
        e.setFact c.facts.getOrDefault(path & ".len",
          Fact(lo: 0, hi: base.capacityBound))
    elif base.kind == ObjectType:
      for f in base.fields:
        if f.name == e.sval:
          e.typ = f.typ
          break
      if e.typ.isNil:
        err(e.line, "type " & base.name & " has no field '" & e.sval & "'")
      if e.typ.opt:
        # A proven optional field acts as its base type, like idents.
        let pn = c.stablePathName(e)
        if pn != "" and (pn & "@ok") in c.facts:
          e.typ = deOpt(e.typ)
          e.unwrapOpt = true
      e.setFact typeFact(e.typ)
    elif base.kind == FloatType:
      if e.sval != "toInt":
        err(e.line, $base & " has no property '" & e.sval & "' (only .toInt)")
      # Saturating and NaN-safe (NaN -> 0): the one float -> int door.
      # Full-range result: guard before using it as an index or length.
      e.typ = intType()
    else:
      err(e.line, "'.' needs an object, seq, or string, got " & $base)
  of MethodExpr:
    # Uniform call syntax: b.a(c, d) is a(b, c, d) for any routine a.
    # Decided by name alone, before anything is checked - builtin
    # method names keep their meaning on every type, so the rewrite is
    # unambiguous and nothing gets type-checked twice. The kids of a
    # MethodExpr are already [base, args...], which is exactly a
    # CallExpr's argument layout.
    if e.sval notin builtinMethods and
        (e.sval in c.routineTab or e.sval in c.generics or
         e.sval in c.overloads):
      e.kind = CallExpr
      return c.checkExpr(e)
    let bigOk = c.allowBigRet
    c.allowBigRet = false
    var bt = c.expectVal(e.kids[0])
    let nArgs = e.kids.len - 1
    if e.sval == "or":
      # Total read of an optional: the value, or the fallback.
      if nArgs != 1:
        err(e.line, "or takes one fallback argument")
      if e.kids[0].kind == IdentExpr and e.kids[0].unwrapOpt:
        # Already proven: undo the strip, or() still works.
        e.kids[0].unwrapOpt = false
        bt = c.declTypeOf(e.kids[0])
        e.kids[0].typ = bt
      if bt == nil or not bt.opt:
        err(e.line, "or() needs an optional value")
      if hasOwned(bt):
        err(e.line, "or() cannot copy an owning value")
      var ft = c.expectVal(e.kids[1])
      if c.coerceStrLit(e.kids[1], deOpt(bt)):
        ft = deOpt(bt)
      if not typeEq(ft, deOpt(bt)):
        err(e.kids[1].line, "fallback must be " & $deOpt(bt) & ", got " & $ft)
      if deOpt(bt).kind == IntType and not exprFact(e.kids[1]).fits(deOpt(bt)):
        err(e.kids[1].line, "cannot prove fallback fits " & $deOpt(bt))
      e.typ = deOpt(bt)
      e.setFact typeFact(e.typ)
      return e.typ
    rejectOpt(bt, e.kids[0])
    if bt != nil and bt.kind == FloatType:
      if e.sval != "toInt":
        err(e.line, $bt & " has no method '" & e.sval & "'")
      if nArgs != 0:
        err(e.line, "toInt takes no arguments")
      # Saturating and NaN-safe (NaN becomes 0): a bare C cast of an
      # out-of-range or NaN float is undefined behavior, so nifty never
      # emits one. The result is a full-range int: guard before use.
      e.typ = intType()
      return e.typ
    if e.sval in mutMethods:
      if c.mutBan > 0:
        err(e.line, "a mutating method cannot appear here: this position " &
          "may not run exactly once (loop conditions re-run; elif and " &
          "and/or right sides may be skipped); do it in its own statement")
      let mutationRoot = e.kids[0].rootIdent
      if e.kids[0].kind != IdentExpr and not bt.dynamic:
        err(e.line, "mutate a seq/string through a plain variable name")
      if mutationRoot.kind != IdentExpr or pathHasMapIndex(e.kids[0]):
        err(e.line, "mutate growable storage through a variable path")
      if not mutationRoot.mut:
        err(e.line, "cannot mutate immutable '" & mutationRoot.sval &
          "' (declared with let; make it var if it must change)")
      c.markModified(mutationRoot.sval)
      # The mutated variable may be serving as a map KEY in a containment
      # fact ("m@base"): that predicate is about its old value.
      var staleKeys: seq[string]
      for fk in c.facts.keys:
        if fk.endsWith("@" & e.kids[0].sval) or
            fk.startsWith(mutationRoot.sval & "@index"):
          staleKeys.add fk
      for fk in staleKeys:
        c.facts.del fk
    if bt.dynamic:
      e.typ = c.checkDynamicMethod(e, bt)
      if bigRet(e.typ) and not bigOk:
        err(e.line, "get returns a large value; store it straight into " &
          "a variable before using it")
      return e.typ
    var key = ""
    if e.kids[0].kind == IdentExpr and c.factEligibleIdent(e.kids[0]):
      key = e.kids[0].sval & ".len"
    var lf = Fact(lo: 0, hi: (
      if bt.kind in {SeqType, StringType, QueueType, SparseMapType}: bt.len
      elif bt.kind in {SetType, DenseMapType}: bt.setSize
      else: 0))
    if key != "":
      lf = c.curFact(key)
    case bt.kind
    of SeqType, QueueType:
      if hasOwned(bt.elem) and e.sval in ["add", "push", "pop"]:
        err(e.line, "fixed containers cannot copy owning elements; " &
          "use a growable seq or mutate an existing element")
      case e.sval
      of "add", "push":
        if nArgs != 1:
          err(e.line, e.sval & " takes one argument")
        var at: Typ = nil
        if e.kids[1].kind == NoneExpr:
          if not bt.elem.opt:
            err(e.kids[1].line, "none needs an optional destination")
          e.kids[1].typ = bt.elem
          at = bt.elem
        else:
          at = c.expectVal(e.kids[1])
          if c.coerceOpt(e.kids[1], bt.elem):
            at = bt.elem
          elif c.coerceStrLit(e.kids[1], bt.elem):
            at = bt.elem
          elif coerceFloatLit(e.kids[1], bt.elem):
            at = bt.elem
        if not typeEq(at, bt.elem):
          err(e.kids[1].line, "cannot add " & $at & " to " & $bt)
        if bt.elem.kind == IntType and not exprFact(e.kids[1]).fits(bt.elem):
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
          e.typ = Typ(kind: BoolType)
      of "pop":
        if nArgs != 0:
          err(e.line, "pop takes no arguments")
        if lf.lo < 1:
          err(e.line, "cannot prove '" & e.kids[0].sval & "' is not " &
            "empty; guard with 'if " & e.kids[0].sval & ".len > 0:'")
        if key != "":
          c.facts[key] = Fact(lo: lf.lo - 1, hi: max(lf.hi - 1, 0'i64))
        e.typ = bt.elem
        e.setFact typeFact(bt.elem)
      of "clear":
        if nArgs != 0:
          err(e.line, "clear takes no arguments")
        if key != "":
          c.facts[key] = Fact(lo: 0, hi: 0)
        e.typ = nil
      else:
        err(e.line, $bt & " has no method '" & e.sval & "'")
    of ChannelType:
      # The semaphore system: send blocks until there is room, recv
      # blocks until there is an item - a real OS-level sleep
      # (pthread condition variables), fused with the data it hands
      # over. No proofs needed: blocking IS the backpressure, and the
      # channel synchronizes itself (no with, no lock).
      case e.sval
      of "send":
        if nArgs != 1:
          err(e.line, "send takes one argument")
        var at: Typ = nil
        if e.kids[1].kind == NoneExpr:
          if not bt.elem.opt:
            err(e.kids[1].line, "none needs an optional destination")
          e.kids[1].typ = bt.elem
          at = bt.elem
        else:
          at = c.expectVal(e.kids[1])
          if c.coerceOpt(e.kids[1], bt.elem):
            at = bt.elem
          elif c.coerceStrLit(e.kids[1], bt.elem):
            at = bt.elem
          elif coerceFloatLit(e.kids[1], bt.elem):
            at = bt.elem
        if not typeEq(at, bt.elem):
          err(e.kids[1].line, "cannot send " & $at & " into " & $bt)
        if bt.elem.kind == IntType and not exprFact(e.kids[1]).fits(bt.elem):
          err(e.kids[1].line, "cannot prove value (" &
            rangeStr(exprFact(e.kids[1])) & ") fits element range " &
            $bt.elem & "; guard or clamp first")
        e.typ = nil
      of "recv":
        if nArgs != 0:
          err(e.line, "recv takes no arguments")
        e.typ = bt.elem
        e.setFact typeFact(bt.elem)
      else:
        err(e.line, $bt & " has no method '" & e.sval &
          "' (channels have exactly send and recv)")
    of StringType:
      case e.sval
      of "add":
        if nArgs != 1:
          err(e.line, "add takes one argument")
        let a = e.kids[1]
        var addLo, addHi: int64
        if a.kind == StrExpr:
          discard c.checkExpr(a)
          addLo = a.sval.len
          addHi = a.sval.len
        else:
          if a.kind notin {IdentExpr, FieldExpr, IndexExpr}:
            err(a.line, "put the appended string in a variable first")
          let at = c.expectVal(a)
          if at.kind != StringType:
            err(a.line, "can only add a string literal or a string, got " & $at)
          var alf = Fact(lo: 0, hi: at.capacityBound)
          if a.kind == IdentExpr and c.factEligibleIdent(a):
            alf = c.curFact(a.sval & ".len")
          addLo = alf.lo
          addHi = alf.hi
        let total = satAdd(lf.hi, addHi)
        if total.ov or total.v > bt.len:
          err(e.line, "cannot prove '" & e.kids[0].sval & "' has room for " &
            "up to " & $addHi & " more bytes (length is up to " & $lf.hi &
            " of " & $bt.len & "); test .len first")
        if key != "":
          c.facts[key] = Fact(lo: min(satAdd(lf.lo, addLo).v, bt.len),
            hi: min(satAdd(lf.hi, addHi).v, bt.len))
        e.typ = nil
      of "addByte":
        # Append one byte: the char/byte building block.
        if nArgs != 1:
          err(e.line, "addByte takes one argument")
        let bt2 = c.expectVal(e.kids[1])
        if bt2.kind != IntType:
          err(e.kids[1].line, "addByte needs a byte (char or 0 .. 255)")
        let bf = exprFact(e.kids[1])
        if bf.lo < 0 or bf.hi > 255:
          err(e.kids[1].line, "cannot prove the byte (" & rangeStr(bf) &
            ") is 0 .. 255; guard or clamp first")
        if lf.hi + 1 > bt.len:
          err(e.line, "cannot prove '" & e.kids[0].sval &
            "' has room for one more byte (length is up to " & $lf.hi &
            " of " & $bt.len & "); test .len first")
        if key != "":
          c.facts[key] = Fact(lo: min(lf.lo + 1, bt.len),
            hi: min(lf.hi + 1, bt.len))
        e.typ = nil
      of "addNum":
        # Append a decimal number: up to 20 bytes (int64.min).
        if nArgs != 1:
          err(e.line, "addNum takes one argument")
        let nt2 = c.expectVal(e.kids[1])
        if nt2.kind != IntType:
          err(e.kids[1].line, "addNum needs an int")
        if lf.hi + 20 > bt.len:
          err(e.line, "cannot prove '" & e.kids[0].sval & "' has room for " &
            "a number (up to 20 bytes; length is up to " & $lf.hi & " of " &
            $bt.len & "); test .len first")
        if key != "":
          c.facts[key] = Fact(lo: lf.lo, hi: min(lf.hi + 20, bt.len))
        e.typ = nil
      of "setLen":
        # After C wrote into the buffer: set the live length, proven to
        # fit the capacity. Any byte value is a valid string byte, so
        # this cannot expose anything unsound.
        if nArgs != 1:
          err(e.line, "setLen takes one argument")
        let nt = c.expectVal(e.kids[1])
        if nt.kind != IntType:
          err(e.kids[1].line, "setLen needs an int")
        let nf = exprFact(e.kids[1])
        if nf.lo < 0 or nf.hi > bt.len:
          err(e.kids[1].line, "cannot prove the new length (" &
            rangeStr(nf) & ") fits 0 .. " & $bt.len &
            "; guard the value first")
        if key != "":
          c.facts[key] = Fact(lo: nf.lo, hi: nf.hi)
        e.typ = nil
      of "clear":
        if nArgs != 0:
          err(e.line, "clear takes no arguments")
        if key != "":
          c.facts[key] = Fact(lo: 0, hi: 0)
        e.typ = nil
      of "startsWith", "endsWith", "contains":
        # Total: a needle longer than the haystack is simply false.
        if nArgs != 1:
          err(e.line, e.sval & " takes one argument")
        let a = e.kids[1]
        if a.kind == StrExpr:
          discard c.checkExpr(a)
        else:
          let at = c.expectVal(a)
          if at.kind != StringType:
            err(a.line, e.sval & " needs a string literal or a string, got " &
              $at)
        e.typ = Typ(kind: BoolType)
      of "find":
        # The index of the needle, or none: absence is a value, and the
        # optional forces the caller to consult it.
        if nArgs != 1:
          err(e.line, "find takes one argument")
        let a = e.kids[1]
        if a.kind == StrExpr:
          discard c.checkExpr(a)
        else:
          let at = c.expectVal(a)
          if at.kind != StringType:
            err(a.line, "find needs a string literal or a string, got " & $at)
        e.typ = optOf(intType(0, max(bt.len - 1, 0)))
      of "findByte":
        if nArgs != 1:
          err(e.line, "findByte takes one argument")
        let bt2 = c.expectVal(e.kids[1])
        if bt2.kind != IntType:
          err(e.kids[1].line, "findByte needs a byte (char or 0 .. 255)")
        e.typ = optOf(intType(0, max(bt.len - 1, 0)))
      of "copyRange":
        # Total by clamping: any lo/hi give a defined result (possibly
        # empty), so slicing needs no proof at every call site.
        if nArgs != 3:
          err(e.line, "copyRange takes a source, a start, and an end")
        let st = c.expectVal(e.kids[1])
        if st.kind != StringType:
          err(e.kids[1].line, "copyRange needs a string source, got " & $st)
        for i in 2 .. 3:
          if c.expectVal(e.kids[i]).kind != IntType:
            err(e.kids[i].line, "copyRange bounds must be ints")
        if key != "":
          c.facts[key] = Fact(lo: 0, hi: bt.len)
        e.typ = nil
      of "toInt":
        # Parse a decimal number, or none when the string is not one.
        if nArgs != 0:
          err(e.line, "toInt takes no arguments")
        e.typ = optOf(intType())
      else:
        err(e.line, $bt & " has no method '" & e.sval & "'")
    of SetType:
      case e.sval
      of "incl", "excl":
        if nArgs != 1:
          err(e.line, e.sval & " takes one argument")
        if c.expectVal(e.kids[1]).kind != IntType:
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
        if e.kids[0].kind notin {IdentExpr, FieldExpr, IndexExpr}:
          err(e.line, "put the set in a variable first")
        if c.expectVal(e.kids[1]).kind != IntType:
          err(e.kids[1].line, "contains needs an int value")
        # Total: out-of-range values are simply not in the set.
        e.typ = Typ(kind: BoolType)
      of "clear":
        if nArgs != 0:
          err(e.line, "clear takes no arguments")
        if key != "":
          c.facts[key] = Fact(lo: 0, hi: 0)
        e.typ = nil
      else:
        err(e.line, $bt & " has no method '" & e.sval & "'")
    of DenseMapType, SparseMapType:
      let dense = bt.kind == DenseMapType
      case e.sval
      of "put":
        if nArgs != 2:
          err(e.line, "put takes a key and a value")
        var kt = c.expectVal(e.kids[1])
        if not dense and c.coerceStrLit(e.kids[1], bt.elem):
          kt = bt.elem
        if dense:
          if kt.kind != IntType:
            err(e.kids[1].line, "map key must be an int")
          if not exprFact(e.kids[1]).fits(bt.elem):
            err(e.kids[1].line, "cannot prove key (" &
              rangeStr(exprFact(e.kids[1])) & ") is inside " & $bt.elem &
              "; guard or clamp first")
        else:
          if not typeEq(kt, bt.elem):
            err(e.kids[1].line, "map key must be " & $bt.elem & ", got " & $kt)
          if bt.elem.kind == IntType and
              not exprFact(e.kids[1]).fits(bt.elem):
            err(e.kids[1].line, "cannot prove key fits " & $bt.elem)
        var vt: Typ = nil
        if e.kids[2].kind == NoneExpr:
          if not bt.val.opt:
            err(e.kids[2].line, "none needs an optional destination")
          e.kids[2].typ = bt.val
          vt = bt.val
        else:
          vt = c.expectVal(e.kids[2])
          if c.coerceOpt(e.kids[2], bt.val):
            vt = bt.val
          elif c.coerceStrLit(e.kids[2], bt.val):
            vt = bt.val
          elif coerceFloatLit(e.kids[2], bt.val):
            vt = bt.val
        if not typeEq(vt, bt.val):
          err(e.kids[2].line, "map value must be " & $bt.val & ", got " & $vt)
        if bt.val.kind == IntType and not exprFact(e.kids[2]).fits(bt.val):
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
          e.typ = Typ(kind: BoolType)
      of "get":
        if nArgs != 2:
          err(e.line, "get takes a key and a fallback")
        var kt = c.expectVal(e.kids[1])
        if not dense and c.coerceStrLit(e.kids[1], bt.elem):
          kt = bt.elem
        if (dense and kt.kind != IntType) or
            (not dense and not typeEq(kt, bt.elem)):
          err(e.kids[1].line, "map key must be " & $bt.elem & ", got " & $kt)
        var ft: Typ = nil
        if e.kids[2].kind == NoneExpr:
          if not bt.val.opt:
            err(e.kids[2].line, "none needs an optional destination")
          e.kids[2].typ = bt.val
          ft = bt.val
        else:
          ft = c.expectVal(e.kids[2])
          if c.coerceOpt(e.kids[2], bt.val):
            ft = bt.val
          elif c.coerceStrLit(e.kids[2], bt.val):
            ft = bt.val
          elif coerceFloatLit(e.kids[2], bt.val):
            ft = bt.val
        if not typeEq(ft, bt.val):
          err(e.kids[2].line, "fallback must be " & $bt.val & ", got " & $ft)
        if bt.val.kind == IntType and not exprFact(e.kids[2]).fits(bt.val):
          err(e.kids[2].line, "cannot prove fallback fits " & $bt.val)
        e.typ = bt.val
        e.setFact typeFact(bt.val)
      of "contains":
        if nArgs != 1:
          err(e.line, "contains takes one argument")
        if e.kids[0].kind notin {IdentExpr, FieldExpr, IndexExpr}:
          err(e.line, "put the map in a variable first")
        var kt = c.expectVal(e.kids[1])
        if not dense and c.coerceStrLit(e.kids[1], bt.elem):
          kt = bt.elem
        if (dense and kt.kind != IntType) or
            (not dense and not typeEq(kt, bt.elem)):
          err(e.kids[1].line, "map key must be " & $bt.elem & ", got " & $kt)
        e.typ = Typ(kind: BoolType)
      of "remove":
        if nArgs != 1:
          err(e.line, "remove takes one argument")
        var kt = c.expectVal(e.kids[1])
        if not dense and c.coerceStrLit(e.kids[1], bt.elem):
          kt = bt.elem
        if (dense and kt.kind != IntType) or
            (not dense and not typeEq(kt, bt.elem)):
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
  of CallExpr:
    let bigOk = c.allowBigRet
    c.allowBigRet = false # arguments are not store targets
    var name = e.sval
    if name in ["float32", "float64"]:
      if e.kids.len != 1:
        err(e.line, name & "(x) takes exactly one argument")
      let at = c.expectVal(e.kids[0])
      rejectOpt(at, e.kids[0])
      if at.kind notin {IntType, FloatType}:
        err(e.line, name & "(x) converts ints and floats, got " & $at)
      e.typ = floatType((if name == "float32": 4 else: 8), name)
      return e.typ
    if name notin c.allRoutines:
      err(e.line, "unknown func or proc: '" & name & "'")
    if name == c.cur.name:
      err(e.line, "recursion is not allowed: '" & name & "' calls itself")
    if name notin c.checked:
      err(e.line, "'" & name & "' is called before its declaration " &
        "(declare-before-use keeps the call graph recursion-free)")
    # Every argument is typed exactly once, in source order, up front:
    # a generic callee needs the types to bind its $names.
    var ats = newSeq[Typ](e.kids.len)
    for i, arg in e.kids:
      if arg.kind != NoneExpr:
        ats[i] = c.expectVal(arg)
    if name in c.overloads:
      # Overload resolution: the first argument's kind picks the
      # routine, and from here on the call is the plain one.
      if e.kids.len == 0 or ats[0] == nil:
        err(e.line, "cannot resolve overloaded '" & name &
          "': it needs a first argument to pick an overload by")
      let key = dispatchKey(ats[0])
      if key == "":
        err(e.line, "cannot resolve overloaded '" & name & "': " &
          $ats[0] & " does not pick an overload")
      var found = ""
      for cn in c.overloads[name]:
        if c.routineTab[cn].params.len > 0 and
            dispatchKey(c.routineTab[cn].params[0].typ) == key:
          found = cn
      if found == "":
        err(e.line, "no overload of '" & name & "' takes " & key &
          " as its first argument")
      e.sval = found
      name = found
      if name == c.cur.name:
        err(e.line, "recursion is not allowed: '" & name & "' calls itself")
      if name notin c.checked:
        err(e.line, "'" & name & "' is called before its declaration " &
          "(declare-before-use keeps the call graph recursion-free)")
    if name in c.generics:
      name = c.instantiate(e, ats)
    let r = c.routineTab[name]
    if r.kind == ThreadRoutine:
      err(e.line, "threads start at program start; they cannot be called")
    if c.cur.kind == FuncRoutine and r.kind != FuncRoutine:
      err(e.line, "func '" & c.cur.name & "' can only call other funcs; '" &
        name & "' is a " & $r.kind)
    if e.kids.len != r.params.len:
      err(e.line, "'" & name & "' expects " & $r.params.len &
        " argument(s), got " & $e.kids.len)
    if r.externLib != "":
      for i, pm in r.params:
        if pm.boundedBy == "":
          continue
        var countIndex = -1
        for j, candidate in r.params:
          if candidate.name == pm.boundedBy:
            countIndex = j
        let count = if countIndex >= 0: exprFact(e.kids[countIndex])
          elif pm.boundedBy in c.consts:
            Fact(lo: c.consts[pm.boundedBy], hi: c.consts[pm.boundedBy])
          else:
            let n = parseBiggestInt(pm.boundedBy)
            Fact(lo: n, hi: n)
        let buffer = e.kids[i]
        let capRelation =
          if countIndex >= 0 and pm.isVar and pm.typ.kind == StringType:
            let key = c.capCountKey(buffer, e.kids[countIndex])
            key != "" and key in c.facts and c.facts[key].lo >= 1
          else:
            false
        let followsLength =
          if countIndex >= 0 and not pm.isVar and
              e.kids[countIndex].kind == FieldExpr and
              e.kids[countIndex].sval == "len":
            let base = e.kids[countIndex].kids[0]
            let left = c.stablePathName(base)
            left != "" and left == c.stablePathName(buffer)
          else:
            false
        let available =
          if pm.typ.kind == ArrayType:
            pm.typ.len
          elif pm.isVar and not pm.typ.dynamic:
            pm.typ.len
          elif buffer.kind == StrExpr and not pm.isVar:
            int64(buffer.sval.len)
          else:
            let path = c.stablePathName(buffer)
            if path == "": 0'i64
            elif pm.isVar:
              c.facts.getOrDefault(path & ".cap",
                Fact(lo: 0, hi: IntHigh)).lo
            else: c.curFact(path & ".len").lo
        if count.lo < 0 or
            (not followsLength and not capRelation and count.hi > available):
          err(e.line, "cannot prove foreign buffer '" & pm.name &
            "' has " & rangeStr(count) & " accessible bytes or elements " &
            "(available at least " & $available & "); resize or guard first")
    for i, arg in e.kids:
      let pt = r.params[i]
      var at: Typ = ats[i]
      if arg.kind == NoneExpr:
        if not pt.typ.opt:
          err(arg.line, "none needs an optional parameter")
        arg.typ = pt.typ
        at = pt.typ
      else:
        if c.coerceOpt(arg, pt.typ):
          at = pt.typ
        elif c.coerceStrLit(arg, pt.typ):
          at = pt.typ
        elif coerceFloatLit(arg, pt.typ):
          at = pt.typ
      let borrowedView = not pt.isVar and pt.typ.dynamic and
        not at.dynamic and at.kind == pt.typ.kind and
        (pt.typ.kind == StringType or (pt.typ.kind == SeqType and
          typeEq(at.elem, pt.typ.elem) and
          at.elem.width == pt.typ.elem.width and
          typeRangeFits(at.elem, pt.typ.elem)))
      arg.borrowedView = borrowedView
      if not typeEq(at, pt.typ) and not borrowedView:
        err(arg.line, "argument " & $(i + 1) & " of '" & name & "': expected " &
          $pt.typ & ", got " & $at)
      if pt.isVar:
        if arg.kind notin {IdentExpr, IndexExpr, FieldExpr}:
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must be a variable")
        if pathHasMapIndex(arg):
          err(arg.line, "a map element cannot be passed as var; copy it " &
            "out, change it, and put it back")
        if pathHasProperty(arg):
          err(arg.line, "container properties are read-only; " &
            "use container methods")
        let root = arg.rootIdent
        if root.kind == IdentExpr:
          c.markModified(root.sval)
        if root.kind != IdentExpr or not root.mut:
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must be mutable")
        if not typeRangeEq(at, pt.typ):
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must have exactly the range " & $pt.typ & " (got " & $at & ")")
        if name in c.routineAccess:
          if root.symKind == GlobalSym and root.sval in c.routineAccess[name]:
            err(arg.line, "cannot pass global '" & root.sval &
              "' as a var argument to '" & name & "': it also accesses '" &
              root.sval & "' directly, and writes through the parameter " &
              "would make its facts lie (aliasing)")
          if root.symKind == ParamSym and root.isVarParam:
            for gname in c.routineAccess[name]:
              if gname in c.globals and typeEq(c.globals[gname], root.typ):
                err(arg.line, "cannot forward var parameter '" & root.sval &
                  "' to '" & name & "': it accesses global '" & gname &
                  "' of the same type, which '" & root.sval &
                  "' might alias")
        c.delFacts root.sval
      else:
        if pt.typ.opt and at != nil and at.opt and
            not typeRangeFits(at, pt.typ):
          err(arg.line, "argument " & $(i + 1) & " of '" & name & "': " &
            $at & " does not fit " & $pt.typ)
        if pt.typ.kind == IntType and not pt.typ.opt:
          if not exprFact(arg).fits(pt.typ):
            err(arg.line, "cannot prove argument " & $(i + 1) & " of '" &
              name & "' (" & rangeStr(exprFact(arg)) & ") fits parameter '" &
              pt.name & "' (" & $pt.typ & "); guard or clamp first")
        elif not borrowedView and not typeRangeFits(at, pt.typ):
          err(arg.line, "argument " & $(i + 1) & " of '" & name &
            "': element ranges of " & $at & " do not fit " & $pt.typ)
    for i, arg in e.kids:
      let parameter = r.params[i]
      let borrowed = parameter.isVar or hasOwned(parameter.typ) or
        parameter.typ.kind == ArrayType
      if not borrowed:
        continue
      let root = arg.rootIdent
      if root.kind != IdentExpr:
        continue
      for j in i + 1 ..< e.kids.len:
        c.rejectOwnerEffects(arg, e.kids[j],
          borrowedView = hasOwned(parameter.typ) or
            parameter.typ.kind == ArrayType)
        let other = e.kids[j].rootIdent
        let otherParam = r.params[j]
        let otherBorrowed = otherParam.isVar or hasOwned(otherParam.typ) or
          otherParam.typ.kind == ArrayType
        if other.kind == IdentExpr and otherBorrowed and
            root.sval == other.sval and
            (parameter.isVar or otherParam.isVar):
          err(e.line, "overlapping borrows of '" & root.sval &
            "': a mutable borrow must be exclusive")
      if borrowed:
        let accesses = if parameter.isVar:
            c.routineAccess.getOrDefault(name)
          else: c.routineWrites.getOrDefault(name)
        for global in accesses:
          if global notin c.globals:
            continue
          if root.symKind == GlobalSym and root.sval == global:
            err(e.line, "borrowed global '" & global &
              "' is also accessed through another path by '" & name & "'")
          if root.symKind == ParamSym and
              (hasOwned(c.globals[global]) or hasOwned(root.typ) or
                root.typ.kind == ArrayType) and
              containsType(c.globals[global], root.typ):
            err(e.line, "borrowed parameter '" & root.sval &
              "' might alias owning global '" & global &
              "' accessed by '" & name & "'")
    if c.heldLocks.len > 0 and name in c.routineLocks:
      for xl in c.routineLocks[name]:
        for hl in c.heldLocks:
          if xl == hl:
            err(e.line, "deadlock: '" & name & "' acquires lock '" & xl &
              "', which is already held here")
          if c.lockOrder[xl] <= c.lockOrder[hl]:
            err(e.line, "deadlock risk: '" & name & "' acquires lock '" &
              xl & "' while '" & hl & "' is held; locks must be acquired " &
              "in declaration order")
    # The callee may write globals; facts about them are now stale.
    if name in c.routineWrites:
      for g in c.routineWrites[name]:
        c.delFacts g
    if bigRet(r.ret) and not bigOk:
      err(e.line, "'" & name & "' returns " & $r.ret & " (" &
        $typeSize(r.ret) & " bytes); a value this big must be stored " &
        "straight into a variable: var x = " & name & "(...)")
    e.typ = r.ret
    if r.ret != nil and r.ret.kind == IntType:
      e.setFact typeFact(r.ret)
  if e.kind == MethodExpr:
    for i, argument in e.kids:
      if hasOwned(argument.typ) or argument.typ.kind == StringType:
        for j in i + 1 ..< e.kids.len:
          c.rejectOwnerEffects(argument, e.kids[j], borrowedView = true)
  e.typ

## Statement Checking

proc checkStmt(c: var Ctx, s: Stmt, topLevel: bool)

proc checkBody(c: var Ctx, body: seq[Stmt]) =
  c.scopes.add initTable[string, Sym]()
  for s in body:
    c.checkStmt(s, false)
  for name in c.scopes[^1].keys:
    c.delFacts name
  discard c.scopes.pop

proc checkStmt(c: var Ctx, s: Stmt, topLevel: bool) =
  case s.kind
  of VarStmt, LetStmt:
    validateOwnedType(s.typ, s.line)
    if s.typ != nil and s.typ.kind in {LockType, ChannelType}:
      err(s.line, "a " & (if s.typ.kind == LockType: "Lock" else: "channel") &
        " must be a global")
    var t = s.typ
    var initFact = Fact(lo: 0, hi: 0, notZero: false)
    if s.init != nil and s.init.kind == NoneExpr:
      if t == nil or not t.opt:
        err(s.line, "none needs an optional destination " &
          "(e.g. var x: int? = none)")
      s.init.typ = t
    elif s.init != nil:
      if s.init.kind in {CallExpr, MethodExpr}:
        c.allowBigRet = true # MethodExpr: may become a call via uniform syntax
      var it = c.expectVal(s.init)
      if c.coerceOpt(s.init, t):
        it = t
      elif c.coerceStrLit(s.init, t):
        it = t
      elif coerceFloatLit(s.init, t):
        it = t
      elif coerceFloatLit(s.init, t):
        it = t
      elif it.kind == StringLitType:
        err(s.line, "string literals need a string[N] destination " &
          "(e.g. var s: string[20] = \"hi\")")
      if t == nil:
        t = it
      elif not typeEq(t, it):
        err(s.line, "type mismatch: declared " & $t & ", initializer is " & $it)
      if t.kind in {ArrayType, SeqType, QueueType, DenseMapType,
          SparseMapType} and not typeRangeFits(it, t):
        err(s.line, "cannot copy: element ranges of " & $it &
          " do not fit " & $t)
      initFact = exprFact(s.init)
      if t.kind == IntType and not initFact.fits(t):
        err(s.line, "cannot prove initializer (" & rangeStr(initFact) &
          ") fits '" & s.name & "' (" & $t & "); guard or clamp first")
    else:
      if s.kind == LetStmt:
        err(s.line, "let requires an initializer")
      if t == nil:
        err(s.line, "variable needs a type or an initializer")
      if not zeroOk(t):
        err(s.line, "'" & s.name & "' is zero-initialized, but 0 is not in " &
          $t & "; add an initializer")
    validateOwnedType(t, s.line)
    if hasOwned(t) and s.init != nil:
      err(s.line, "owning strings and seqs cannot be copied or initialized " &
        "from a value; declare empty storage and use copyFrom")
    if c.isDeclared(s.name):
      err(s.line, "'" & s.name & "' is already declared (shadowing is not allowed)")
    s.typ = t
    c.scopes[^1][s.name] = Sym(kind: LocalSym, typ: t, mutable: s.kind == VarStmt)
    if s.kind == VarStmt:
      c.varDecls[s.name] = s.line
    if t.opt:
      # Only a DEFINITE initializer grants ok: a wrapped plain value or a
      # proven optional. An unproven optional (or none) grants nothing.
      if s.init != nil and (s.init.wrapOpt or s.init.unwrapOpt):
        c.facts[s.name & "@ok"] = Fact(lo: 1, hi: 1)
        if t.kind == IntType:
          c.facts[s.name] = initFact
    elif t.kind == IntType:
      c.facts[s.name] = initFact
    elif t.kind in {SeqType, StringType, SetType, QueueType, DenseMapType, SparseMapType}:
      if s.init == nil:
        c.facts[s.name & ".len"] = Fact(lo: 0, hi: 0) # zero-init = empty
      elif s.init.kind == StrExpr:
        c.facts[s.name & ".len"] =
          Fact(lo: s.init.sval.len, hi: s.init.sval.len)
      elif s.init.kind == IdentExpr and c.factEligibleIdent(s.init):
        c.facts[s.name & ".len"] = c.curFact(s.init.sval & ".len")
  of AssignStmt:
    if s.lhs.kind == IndexExpr:
      let bt = c.expectVal(s.lhs.kids[0])
      if bt.kind in {DenseMapType, SparseMapType}:
        # m[k] = v: strict insert-or-update. Dense: the key must fit the
        # range (there is a slot for every key). Sparse: prove presence
        # (update) or room (insert). Either way the key is present after.
        if s.lhs.kids[0].kind != IdentExpr:
          err(s.lhs.line, "write a map through a plain variable name")
        if not s.lhs.kids[0].mut:
          err(s.lhs.line, "cannot mutate immutable '" & s.lhs.kids[0].sval & "'")
        var kt = c.expectVal(s.lhs.kids[1])
        if bt.kind == SparseMapType and c.coerceStrLit(s.lhs.kids[1], bt.elem):
          kt = bt.elem
        if bt.kind == DenseMapType:
          if kt.kind != IntType:
            err(s.lhs.kids[1].line, "map key must be an int")
          if not exprFact(s.lhs.kids[1]).fits(bt.elem):
            err(s.lhs.kids[1].line, "cannot prove key (" &
              rangeStr(exprFact(s.lhs.kids[1])) & ") is inside " &
              $bt.elem & "; guard or clamp first")
        else:
          if not typeEq(kt, bt.elem):
            err(s.lhs.kids[1].line, "map key must be " & $bt.elem &
              ", got " & $kt)
          if bt.elem.kind == IntType and
              not exprFact(s.lhs.kids[1]).fits(bt.elem):
            err(s.lhs.kids[1].line, "cannot prove key fits " & $bt.elem)
        var vt: Typ = nil
        if s.rhs.kind == NoneExpr:
          if not bt.val.opt:
            err(s.line, "none needs an optional destination")
          s.rhs.typ = bt.val
          vt = bt.val
        else:
          vt = c.expectVal(s.rhs)
          if c.coerceOpt(s.rhs, bt.val):
            vt = bt.val
          elif c.coerceStrLit(s.rhs, bt.val):
            vt = bt.val
          elif coerceFloatLit(s.rhs, bt.val):
            vt = bt.val
        if not typeEq(vt, bt.val):
          err(s.line, "map value must be " & $bt.val & ", got " & $vt)
        if bt.val.kind == IntType and not exprFact(s.rhs).fits(bt.val):
          err(s.line, "cannot prove value (" & rangeStr(exprFact(s.rhs)) &
            ") fits " & $bt.val)
        let mname = s.lhs.kids[0].sval
        c.markModified(mname)
        let pk = c.mapFactKey(s.lhs.kids[0], s.lhs.kids[1])
        var lkey = ""
        if c.factEligibleIdent(s.lhs.kids[0]):
          lkey = mname & ".len"
        let cap = if bt.kind == DenseMapType: bt.setSize else: bt.len
        var lf = Fact(lo: 0, hi: cap)
        if lkey != "":
          lf = c.curFact(lkey)
        if bt.kind == SparseMapType:
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
    if s.lhs.kind == IdentExpr:
      # An assignment target is a place, not a value: undo any ok-strip.
      discard c.expectVal(s.lhs)
      if s.lhs.unwrapOpt:
        s.lhs.unwrapOpt = false
        s.lhs.typ = c.declTypeOf(s.lhs)
    let lt =
      if s.lhs.kind == IdentExpr: s.lhs.typ
      else: c.expectVal(s.lhs)
    if pathHasProperty(s.lhs):
      err(s.line, "container properties are read-only; use container methods")
    if hasOwned(lt):
      err(s.line, "owning strings and seqs cannot be assigned; use copyFrom")
    if lt != nil and lt.kind == ChannelType:
      err(s.lhs.line, "a channel cannot be assigned or copied; " &
        "use send and recv")
    let root = s.lhs.rootIdent
    if root.kind != IdentExpr:
      err(s.lhs.line, "cannot assign to this expression")
    if not root.mut:
      if root.symKind == ParamSym:
        if c.cur.kind == FuncRoutine:
          err(s.lhs.line, "cannot assign to parameter '" & root.sval &
            "' (func params are read-only; use a proc with a var parameter)")
        err(s.lhs.line, "cannot assign to parameter '" & root.sval &
          "' (make it a var parameter if it must change)")
      err(s.lhs.line, "cannot assign to immutable '" & root.sval &
        "' (declared with let or a loop variable; make it var)")

    var rt: Typ = nil
    if s.rhs.kind == NoneExpr:
      if lt == nil or not lt.opt:
        err(s.line, "none needs an optional destination")
      s.rhs.typ = lt
      rt = lt
    else:
      if s.rhs.kind in {CallExpr, MethodExpr}:
        c.allowBigRet = true
      rt = c.expectVal(s.rhs)
      if c.coerceOpt(s.rhs, lt):
        rt = lt
      elif c.coerceStrLit(s.rhs, lt):
        rt = lt
      elif coerceFloatLit(s.rhs, lt):
        rt = lt
    if s.lhs.kind in {IndexExpr, FieldExpr}:
      c.rejectOwnerEffects(s.lhs, s.rhs)
    if s.rhs.kind == CallExpr and bigRet(rt):
      # The callee fills the destination directly; it must not also be
      # reading that destination as a global, or its facts would lie.
      let callee = s.rhs.sval
      if callee in c.routineAccess:
        if root.symKind == GlobalSym and root.sval in c.routineAccess[callee]:
          err(s.line, "cannot assign '" & callee & "(...)' straight into " &
            "global '" & root.sval & "': '" & callee & "' also accesses '" &
            root.sval & "'; store to a local first")
        if root.symKind == ParamSym and root.isVarParam:
          for gname in c.routineAccess[callee]:
            if gname in c.globals and typeEq(c.globals[gname], root.typ):
              err(s.line, "cannot assign '" & callee & "(...)' straight " &
                "into var parameter '" & root.sval & "': '" & callee &
                "' accesses global '" & gname & "' of the same type, " &
                "which '" & root.sval & "' might alias; store to a local first")
    if not typeEq(lt, rt):
      err(s.line, "type mismatch: cannot assign " & $rt & " to " & $lt)
    if lt.kind in {ArrayType, SeqType, QueueType, DenseMapType,
        SparseMapType} and not typeRangeFits(rt, lt):
      err(s.line, "cannot copy: element ranges of " & $rt &
        " do not fit " & $lt)
    if lt.opt and rt != nil and rt.opt and not typeRangeFits(rt, lt):
      err(s.line, "cannot assign: " & $rt & " does not fit " & $lt)
    # The store proof: the value must fit the declared range invariant.
    if lt.kind == IntType:
      let rf = exprFact(s.rhs)
      if not rf.fits(lt):
        err(s.line, "cannot prove value (" & rangeStr(rf) & ") fits " & $lt &
          "; guard or clamp first")
    c.markModified(root.sval)
    if s.lhs.kind == IdentExpr:
      c.delFacts s.lhs.sval
      if lt != nil and lt.opt and c.factEligibleIdent(s.lhs):
        # A definite value (wrapped plain or a proven optional) grants ok.
        if s.rhs.wrapOpt or s.rhs.unwrapOpt:
          c.facts[s.lhs.sval & "@ok"] = Fact(lo: 1, hi: 1)
          if lt.kind == IntType:
            c.facts[s.lhs.sval] = exprFact(s.rhs)
      elif c.factName(s.lhs) != "":
        c.facts[s.lhs.sval] = exprFact(s.rhs)
    else:
      # A store through a FIELD path invalidates facts under its root
      # (field ok-facts live there); a pure element store (s[i] = v)
      # changes no lengths and carries no facts, so nothing dies.
      var hasField = false
      var cur = s.lhs
      while cur.kind in {IndexExpr, FieldExpr}:
        if cur.kind == FieldExpr:
          hasField = true
        cur = cur.kids[0]
      if hasField:
        c.delFacts root.sval
        if lt != nil and lt.opt and s.lhs.kind == FieldExpr:
          # A definite store into an optional field grants its path.
          let pn = c.stablePathName(s.lhs)
          if pn != "" and (s.rhs.wrapOpt or s.rhs.unwrapOpt):
            c.facts[pn & "@ok"] = Fact(lo: 1, hi: 1)
  of IfStmt:
    var negAcc = c.facts
    var branchFacts: seq[Table[string, Fact]]
    for i, br in s.elifs:
      c.facts = negAcc
      if i > 0:
        inc c.mutBan # elif conditions may be skipped at runtime
      if c.expectVal(br.cond).kind != BoolType:
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
  of WhileStmt:
    # Facts about anything the body can change do not survive an iteration
    # (except widened accumulators); facts from the condition are
    # re-established on every entry.
    let entry = c.facts
    var assigned: HashSet[string]
    c.collectAssigned(s.body, assigned)
    for n in assigned:
      c.delFacts n
    inc c.mutBan # the condition re-runs every iteration
    if c.expectVal(s.cond).kind != BoolType:
      err(s.cond.line, "condition must be a bool")
    dec c.mutBan
    var conditionWrites: HashSet[string]
    c.collectAssignedExpr(s.cond, conditionWrites)
    var widenCandidates: HashSet[string]
    for name in assigned:
      if name notin conditionWrites:
        widenCandidates.incl name
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
    let widenedIn = c.accumWiden(s, widenCandidates, fullFact(), entry,
      max(0'i64, bound - 1))
    let widenedOut = c.accumWiden(s, widenCandidates, fullFact(), entry, bound)
    for n, f in widenedIn:
      c.facts[n] = f
    var dropped = c.facts
    for n, f in widenedOut:
      dropped[n] = f
    c.addCondFacts(s.cond)
    c.loopWiths.add c.withDepth
    c.checkBody(s.body)
    discard c.loopWiths.pop
    c.facts = dropped
    # After the loop the condition is false - but only if the loop cannot
    # leave any other way (break, or the max cap).
    if s.maxTrips == 0 and not hasLoopBreak(s.body):
      c.addCondFacts(s.cond, negated = true)
  of ForStmt:
    let loT = c.expectVal(s.lo)
    let hiT = c.expectVal(s.hi)
    rejectOpt(loT, s.lo)
    rejectOpt(hiT, s.hi)
    if loT.kind != IntType or hiT.kind != IntType:
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
    let
      span = satSub(iHi, lof.lo)
      count = satAdd(span.v, 1)
      finiteTrips = not span.ov and not count.ov
    s.tripBound =
      if span.ov and iHi < lof.lo: 0'i64
      elif finiteTrips: max(0'i64, count.v)
      else: IntHigh
    let loopFact = Fact(lo: lof.lo, hi: iHi)
    var assigned: HashSet[string]
    c.collectAssigned(s.body, assigned)
    # Simple accumulators keep a widened fact instead of losing everything.
    let widenedIn =
      if finiteTrips:
        c.accumWiden(s, assigned, loopFact, c.facts,
          max(0'i64, s.tripBound - 1))
      else:
        initTable[string, Fact]()
    let widenedOut =
      if finiteTrips:
        c.accumWiden(s, assigned, loopFact, c.facts, s.tripBound)
      else:
        initTable[string, Fact]()
    for n in assigned:
      c.delFacts n
    var dropped = c.facts
    for n, f in widenedOut:
      dropped[n] = f
    for n, f in widenedIn:
      c.facts[n] = f
    c.scopes.add initTable[string, Sym]()
    c.scopes[^1][s.name] = Sym(kind: LocalSym, typ: intType(), mutable: false)
    c.facts[s.name] = loopFact
    if not s.inclusive and s.hi.kind == FieldExpr and s.hi.sval == "len" and
        s.hi.kids[0].typ != nil and
        s.hi.kids[0].typ.kind in {SeqType, StringType}:
      let root = s.hi.kids[0].rootIdent
      if root.kind == IdentExpr and root.sval notin assigned:
        let index = Expr(kind: IdentExpr, sval: s.name, typ: intType(),
          symKind: LocalSym)
        let key = c.indexFactKey(s.hi.kids[0], index)
        if key != "":
          c.facts[key] = Fact(lo: 1, hi: 1)
    c.loopWiths.add c.withDepth
    for st in s.body:
      c.checkStmt(st, false)
    discard c.loopWiths.pop
    discard c.scopes.pop
    c.facts = dropped
    c.facts.del s.name
  of LoopStmt:
    if c.cur.kind != ThreadRoutine or not topLevel:
      err(s.line, "loop is only allowed at the top level of a thread body")
    c.dropAssigned(s.body)
    let dropped = c.facts
    c.loopWiths.add c.withDepth
    c.checkBody(s.body)
    discard c.loopWiths.pop
    c.facts = dropped
  of BlockStmt:
    c.checkBody(s.body)
  of ForEachStmt:
    let t = c.expectVal(s.value)
    if t.kind notin {SeqType, StringType, SetType, QueueType, DenseMapType, SparseMapType}:
      err(s.line, "for-in needs a seq, string, set, queue, or map to " &
        "iterate, got " & $t)
    if s.name2.len > 0 and t.kind notin {DenseMapType, SparseMapType}:
      err(s.line, "only maps iterate with two variables (for k, v in m:)")
    let root = s.value.rootIdent
    if root.kind != IdentExpr:
      err(s.line, "iterate a container through a variable path")
    if pathHasMapIndex(s.value):
      err(s.line, "a map element cannot be iterated in place; copy it out")
    if c.isDeclared(s.name):
      err(s.line, "'" & s.name & "' is already declared (shadowing is not allowed)")
    var assigned: HashSet[string]
    c.collectAssigned(s.body, assigned)
    if root.sval in assigned:
      err(s.line, "cannot modify '" & root.sval & "' while iterating it")
    s.tripBound = if t.dynamic: -1
      elif t.kind == SetType: t.setSize else: t.len
    let elemT =
      if t.kind in {SeqType, QueueType}: t.elem
      elif t.kind in {SetType, DenseMapType, SparseMapType}: t.elem
      else: intType(0, 255)
    s.typ = elemT # recorded for codegen
    if t.kind in {DenseMapType, SparseMapType}:
      s.typ2 = t.val
    # Accumulators widen here too: the element variable is the loop
    # variable, bounded by the element type.
    let wideningBound = if t.dynamic: IntHigh else: s.tripBound
    let widenedIn = c.accumWiden(s, assigned, typeFact(elemT), c.facts,
      max(0'i64, wideningBound - 1))
    let widenedOut = c.accumWiden(s, assigned, typeFact(elemT), c.facts,
      wideningBound)
    for n in assigned:
      c.delFacts n
    var dropped = c.facts
    for n, f in widenedOut:
      dropped[n] = f
    for n, f in widenedIn:
      c.facts[n] = f
    c.scopes.add initTable[string, Sym]()
    c.scopes[^1][s.name] = Sym(kind: LocalSym, typ: elemT, mutable: false)
    if s.name2.len > 0:
      if c.isDeclared(s.name2):
        err(s.line, "'" & s.name2 & "' is already declared")
      c.scopes[^1][s.name2] = Sym(kind: LocalSym, typ: t.val, mutable: false)
    if t.kind in {DenseMapType, SparseMapType} and s.value.kind == IdentExpr and
        c.factEligibleIdent(s.value):
      # The loop key is contained by construction, and the map cannot
      # change during iteration.
      c.facts[s.value.sval & "@" & s.name] = Fact(lo: 1, hi: 1)
    c.loopWiths.add c.withDepth
    for st in s.body:
      c.checkStmt(st, false)
    c.collectAssigned(s.body, assigned)
    if root.sval in assigned:
      err(s.line, "cannot modify '" & root.sval & "' while iterating it")
    discard c.loopWiths.pop
    discard c.scopes.pop
    c.facts = dropped
    c.facts.del s.name
  of WithStmt:
    if c.cur.kind == FuncRoutine:
      err(s.line, "with is not allowed in func (start/end are side effects)")
    c.markModified(s.name) # start/end write the target through var
    c.delFacts s.name
    if s.name in c.globals and c.globals[s.name].kind == ChannelType:
      err(s.line, "a channel is not a with resource; it synchronizes " &
        "itself (use send and recv)")
    if s.name in c.globals and c.globals[s.name].kind == LockType:
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
        if r.kind != ProcRoutine or r.params.len != 1 or not r.params[0].isVar or
            not typeEq(r.params[0].typ, t) or not typeRangeEq(r.params[0].typ, t) or
            not r.ret.isNil:
          err(s.line, "with on a " & $t & " needs '" & pn & "' to be: " & want)
        discard c.checkExpr(Expr(kind: CallExpr, sval: pn,
          kids: @[s.lhs], line: s.line))
      for pn in ["start", "end"]:
        if pn in c.routineWrites:
          for gw in c.routineWrites[pn]:
            c.delFacts gw
        if c.heldLocks.len > 0 and pn in c.routineLocks:
          for xl in c.routineLocks[pn]:
            for hl in c.heldLocks:
              if c.lockOrder[xl] <= c.lockOrder[hl]:
                err(s.line, "deadlock risk: '" & pn & "' acquires lock '" &
                  xl & "' while '" & hl & "' is held; locks must be " &
                  "acquired in declaration order")
      s.typ = t
    let isLock = s.typ != nil and s.typ.kind == LockType
    if isLock:
      # Deadlock freedom by total order: locks may only be acquired in
      # declaration order, so a cycle of waiters cannot exist.
      for hl in c.heldLocks:
        if s.name == hl:
          err(s.line, "deadlock: lock '" & s.name & "' is already held")
        if c.lockOrder[s.name] <= c.lockOrder[hl]:
          err(s.line, "deadlock risk: locks must be acquired in " &
            "declaration order; '" & s.name & "' is declared before '" &
            hl & "', which is already held (swap the with blocks, or " &
            "swap the two lock declarations)")
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
        let root = k.split("@")[0].split(".")[0]
        let dependency = if "@" in k: k.split("@")[^1] else: ""
        if (root in c.sharedProt and s.name in c.sharedProt[root]) or
            (dependency in c.sharedProt and
              s.name in c.sharedProt[dependency]):
          stale.add k
      for k in stale:
        c.facts.del k
  of ReturnStmt:
    if c.withDepth > 0:
      err(s.line, "cannot return inside a with block (its end would never run)")
    if c.cur.kind == ThreadRoutine:
      err(s.line, "threads do not return; let the body end instead")
    if c.cur.ret.isNil:
      if s.value != nil:
        err(s.line, "'" & c.cur.name & "' has no return type")
    else:
      if s.value == nil:
        err(s.line, "return needs a value of type " & $c.cur.ret)
      var t: Typ = nil
      if s.value.kind == NoneExpr:
        if not c.cur.ret.opt:
          err(s.line, "none needs an optional return type")
        s.value.typ = c.cur.ret
        t = c.cur.ret
      else:
        if s.value.kind in {CallExpr, MethodExpr}:
          c.allowBigRet = true
        t = c.expectVal(s.value)
        if c.coerceOpt(s.value, c.cur.ret):
          t = c.cur.ret
        elif coerceFloatLit(s.value, c.cur.ret):
          t = c.cur.ret
        elif c.coerceStrLit(s.value, c.cur.ret):
          t = c.cur.ret
        elif coerceFloatLit(s.value, c.cur.ret):
          t = c.cur.ret
      if not typeEq(t, c.cur.ret):
        err(s.line, "return type mismatch: got " & $t & ", expected " & $c.cur.ret)
      if c.cur.ret.kind == IntType:
        let rf = exprFact(s.value)
        if not rf.fits(c.cur.ret):
          err(s.line, "cannot prove return value (" & rangeStr(rf) &
            ") fits " & $c.cur.ret & "; guard or clamp first")
  of BreakStmt:
    if c.loopWiths.len == 0:
      err(s.line, "break outside a loop")
    if c.withDepth != c.loopWiths[^1]:
      err(s.line, "cannot break out of a with block (its end would never run)")
  of EchoStmt:
    if c.cur.kind == FuncRoutine:
      err(s.line, "echo is a side effect; not allowed in func")
    for a in s.args:
      let at = c.expectVal(a)
      rejectOpt(at, a)
      if at.kind notin {IntType, BoolType, StringLitType, StringType,
          FloatType}:
        err(a.line, "cannot echo a " & $a.typ)
    for i, a in s.args:
      if hasOwned(a.typ):
        for j in i + 1 ..< s.args.len:
          c.rejectOwnerEffects(a, s.args[j])
  of DiscardStmt:
    discard c.checkExpr(s.value)
  of CallStmt:
    let t = c.checkExpr(s.value)
    if not t.isNil:
      err(s.line, "return value of '" & s.value.sval &
        "' is discarded (use discard or assign it)")

## Smallest-Scope Enforcement (Power of 10, rule 6)

proc usesName(e: Expr, name: string): bool =
  if e.isNil:
    return false
  if e.kind == IdentExpr and e.sval == name:
    return true
  for k in e.kids:
    if usesName(k, name):
      return true

proc stmtUsesName(s: Stmt, name: string): bool =
  if s.kind == WithStmt and s.name == name:
    return true
  for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
    if usesName(e, name):
      return true
  for a in s.args:
    if usesName(a, name):
      return true
  for st in s.body:
    if stmtUsesName(st, name):
      return true
  for br in s.elifs:
    if usesName(br.cond, name):
      return true
    for st in br.body:
      if stmtUsesName(st, name):
        return true
  for st in s.elseBody:
    if stmtUsesName(st, name):
      return true

proc mayReadFirst(body: seq[Stmt], name: string, written: var bool): bool =
  ## Could this body observe `name`'s value from before it runs?
  ## Conservative: true means "possibly"; false is a proof that every
  ## path fully overwrites the location before any read.
  for s in body:
    if written:
      return false
    case s.kind
    of AssignStmt:
      if usesName(s.rhs, name):
        return true
      if s.lhs.kind == IdentExpr and s.lhs.sval == name:
        written = true
      elif usesName(s.lhs, name):
        return true # a partial write keeps the rest of the old value
    of VarStmt, LetStmt:
      if usesName(s.init, name):
        return true
    of IfStmt:
      var allWrote = s.elseBody.len > 0
      for br in s.elifs:
        if usesName(br.cond, name):
          return true
        var w = written
        if mayReadFirst(br.body, name, w):
          return true
        if not w:
          allWrote = false
      var w = written
      if mayReadFirst(s.elseBody, name, w):
        return true
      if not w:
        allWrote = false
      if allWrote:
        written = true
    of WhileStmt:
      if usesName(s.cond, name):
        return true
      var w = written
      if mayReadFirst(s.body, name, w):
        return true # zero iterations possible: body writes don't count
    of ForStmt:
      if usesName(s.lo, name) or usesName(s.hi, name):
        return true
      var w = written
      if mayReadFirst(s.body, name, w):
        return true
    of ForEachStmt:
      if usesName(s.value, name):
        return true
      var w = written
      if mayReadFirst(s.body, name, w):
        return true
    of LoopStmt:
      var w = written
      if mayReadFirst(s.body, name, w):
        return true
    of WithStmt:
      if s.name == name or usesName(s.lhs, name):
        return true
      if mayReadFirst(s.body, name, written):
        return true
    of BlockStmt:
      if mayReadFirst(s.body, name, written):
        return true
    of ReturnStmt:
      if usesName(s.value, name):
        return true
      return false # this path ends without reading
    of BreakStmt:
      return false
    of EchoStmt:
      for a in s.args:
        if usesName(a, name):
          return true
    of DiscardStmt, CallStmt:
      if usesName(s.value, name):
        return true
  false

proc narrowTarget(u: Stmt, name: string): string =
  ## If every use of a local lives inside this one statement, can (and
  ## therefore must) the declaration move inside it? Returns the error
  ## text, or "" when moving would change meaning.
  case u.kind
  of BlockStmt:
    "'" & name & "' is only used inside the block at line " &
      $(u.line mod fileLineBase) & "; declare it inside the block"
  of WithStmt:
    if u.name == name or usesName(u.lhs, name):
      return ""
    "'" & name & "' is only used inside the with block at line " &
      $(u.line mod fileLineBase) & "; declare it there"
  of IfStmt:
    var inBranches = 0
    for br in u.elifs:
      if usesName(br.cond, name):
        return ""
      var found = false
      for st in br.body:
        if stmtUsesName(st, name):
          found = true
      if found:
        inBranches.inc
    var inElse = false
    for st in u.elseBody:
      if stmtUsesName(st, name):
        inElse = true
    if inElse:
      inBranches.inc
    if inBranches != 1:
      return ""
    "'" & name & "' is only used inside one branch of the if at line " &
      $(u.line mod fileLineBase) & "; declare it in that branch"
  of WhileStmt, ForStmt, ForEachStmt, LoopStmt:
    for e in [u.cond, u.lo, u.hi, u.value]:
      if usesName(e, name):
        return ""
    var w = false
    if mayReadFirst(u.body, name, w):
      return "" # carries a value across iterations; must stay outside
    "'" & name & "' is only used inside the loop at line " &
      $(u.line mod fileLineBase) & " and never carries a value across " &
      "iterations; declare it inside the loop"
  else:
    ""

proc checkSmallestScope(body: seq[Stmt]) =
  ## A local declared wider than its use must move in. Only literal or
  ## missing initializers are considered: their evaluation is timing-
  ## independent, so moving the declaration provably changes nothing.
  for i, s in body:
    if s.kind in {VarStmt, LetStmt} and
        (s.init == nil or s.init.kind in {IntExpr, FloatExpr, BoolExpr,
          StrExpr}):
      var users: seq[int]
      for j in (i + 1) ..< body.len:
        if stmtUsesName(body[j], s.name):
          users.add j
      if users.len == 1:
        let msg = narrowTarget(body[users[0]], s.name)
        if msg != "":
          err(s.line, msg)
    checkSmallestScope(s.body)
    for br in s.elifs:
      checkSmallestScope(br.body)
    checkSmallestScope(s.elseBody)

proc checkRoutine(c: var Ctx, r: Routine) =
  if hasOwned(r.ret):
    err(r.line, "owning strings and seqs cannot be returned; " &
      "fill a var parameter owned by the caller")
  c.cur = r
  c.withDepth = 0
  c.loopWiths = @[]
  c.facts = initTable[string, Fact]()
  c.heldLocks = @[]
  c.varDecls = initTable[string, int]()
  c.modified = initHashSet[string]()
  c.allowBigRet = false
  case r.kind
  of ThreadRoutine:
    if r.params.len > 0:
      err(r.line, "threads take no parameters")
    if not r.ret.isNil:
      err(r.line, "threads do not return a value")
  of FuncRoutine:
    if r.ret.isNil:
      err(r.line, "func must have a return type (use proc for side effects)")
  of ProcRoutine:
    discard
  var paramScope = initTable[string, Sym]()
  for pm in r.params:
    validateOwnedType(pm.typ, r.line)
    if pm.typ.kind in {LockType, ChannelType}:
      err(r.line, "a " & (if pm.typ.kind == LockType: "Lock" else: "channel") &
        " cannot be a parameter; name the global directly")
    if pm.isVar and r.kind == FuncRoutine:
      err(r.line, "func parameters are read-only; var parameters are not allowed")
    if pm.name in paramScope or pm.name in c.usedNames:
      err(r.line, "duplicate or shadowing parameter name: '" & pm.name & "'")
    if pm.isVar:
      c.varDecls[pm.name] = r.line
    paramScope[pm.name] = Sym(kind: ParamSym, typ: pm.typ,
      mutable: pm.isVar, isVarParam: pm.isVar)
  c.scopes = @[paramScope, initTable[string, Sym]()]
  for s in r.body:
    c.checkStmt(s, true)
  if not r.ret.isNil and not alwaysReturns(r.body):
    err(r.line, "'" & r.name & "': not all code paths return a value")
  # Mutability is strategic: var means it changes. A var that never
  # changes must be a let (or a plain parameter).
  for vname, vline in c.varDecls:
    if vname notin c.modified:
      var isParam = false
      for pm in r.params:
        if pm.name == vname:
          isParam = true
      if isParam:
        if r.name in ["start", "end"]:
          continue # the with protocol imposes the var signature
        err(vline, "var parameter '" & vname & "' is never modified in '" &
          r.name & "'; remove var")
      else:
        err(vline, "'" & vname & "' is never modified; declare it with " &
          "let instead of var")
  checkSmallestScope(r.body)
  c.checked.incl r.name

## Generic Instantiation

proc mangleVal(v: int64): string =
  if v < 0: "m" & $(-v) else: $v

proc mangleTyp(t: Typ): string =
  result =
    case t.kind
    of IntType:
      if t.dname != "": t.dname
      elif t.isFullRange: "int"
      else: mangleVal(t.rlo) & "_" & mangleVal(t.rhi)
    of FloatType: t.dname
    of BoolType: "bool"
    of StringType: (if t.dynamic: "strdyn" else: "str" & $t.len)
    of SeqType:
      (if t.dynamic: "seqdyn_" else: "seq" & $t.len & "_") &
        mangleTyp(t.elem)
    of ObjectType: t.name
    of ArrayType: "arr" & $t.len & "_" & mangleTyp(t.elem)
    else: "x"
  if t.opt:
    result.add "opt"

proc unifyPat(c: Ctx, pat, at: Typ, sizes: var Table[string, int64],
    typs: var Table[string, Typ], order: var seq[string],
    line: int, gname: string) =
  ## Match a $-pattern against a concrete argument type, binding every
  ## $name on first sight and demanding agreement after that.
  if pat.isNil or at.isNil:
    return
  if pat.kind == TypeVarType:
    if pat.gname in typs:
      let prev = typs[pat.gname]
      if not (typeEq(prev, at) and typeRangeEq(prev, at) and
          prev.opt == at.opt):
        err(line, "generic '" & gname & "': $" & pat.gname &
          " is bound to both " & $prev & " and " & $at)
    else:
      typs[pat.gname] = at
      order.add pat.gname
    return
  if pat.kind != at.kind:
    err(line, "generic '" & gname & "': expected " & $pat & ", got " & $at)
  if pat.dynamic != at.dynamic:
    err(line, "generic '" & gname & "': expected " & $pat & ", got " & $at)
  if pat.lenVar != "":
    if pat.lenVar in sizes:
      if sizes[pat.lenVar] != at.len:
        err(line, "generic '" & gname & "': $" & pat.lenVar &
          " is bound to both " & $sizes[pat.lenVar] & " and " & $at.len)
    else:
      sizes[pat.lenVar] = at.len
      order.add pat.lenVar
  c.unifyPat(pat.elem, at.elem, sizes, typs, order, line, gname)
  c.unifyPat(pat.val, at.val, sizes, typs, order, line, gname)

proc typToToks(t: Typ, line: int, gname: string): seq[Token] =
  ## Spell a bound type back out as source tokens for substitution.
  proc op(s: string): Token = Token(kind: OpToken, text: s, line: line)
  proc idt(s: string): Token = Token(kind: IdentToken, text: s, line: line)
  proc num(v: int64): seq[Token] =
    if v < 0: @[op("-"), Token(kind: IntToken, text: $(-v), line: line)]
    else: @[Token(kind: IntToken, text: $v, line: line)]
  case t.kind
  of IntType:
    if t.dname != "": result = @[idt(t.dname)]
    elif t.isFullRange: result = @[idt("int")]
    else: result = num(t.rlo) & @[op("..")] & num(t.rhi)
  of FloatType:
    result = @[idt(t.dname)]
  of BoolType:
    result = @[idt("bool")]
  of StringType:
    result = @[idt("string")]
    if not t.dynamic:
      result.add @[op("["), Token(kind: IntToken, text: $t.len,
        line: line), op("]")]
  of SeqType:
    result = @[idt("seq"), op("[")]
    if not t.dynamic:
      result.add @[Token(kind: IntToken, text: $t.len, line: line), op(",")]
    result.add typToToks(t.elem, line, gname) & @[op("]")]
  of ObjectType:
    result = @[idt(t.name)]
  of ArrayType:
    result = @[idt("array"), op("["),
      Token(kind: IntToken, text: $t.len, line: line), op(",")] &
      typToToks(t.elem, line, gname) & @[op("]")]
  else:
    err(line, "generic '" & gname & "': cannot substitute " & $t &
      " for a $ type variable")
  if t.opt:
    result.add op("?")

proc scanNoGlobals(c: Ctx, gname: string, body: seq[Stmt]) =
  ## Generic bodies may not reach globals: the thread-ownership and lock
  ## proofs run before any instantiation exists, so a generic's global
  ## footprint must be empty for them to stay sound.
  proc scanE(c: Ctx, e: Expr) =
    if e.isNil:
      return
    if e.kind == IdentExpr and e.sval in c.globals:
      err(e.line, "generic '" & gname & "' touches global '" & e.sval &
        "'; generic routines cannot access globals - pass values " &
        "through parameters")
    if e.kind in {CallExpr, MethodExpr} and
        (e.kind == CallExpr or e.sval notin builtinMethods):
      for callee in c.overloads.getOrDefault(e.sval, @[e.sval]):
        if callee in c.routineAccess and c.routineAccess[callee].len > 0:
          err(e.line, "generic '" & gname & "' calls '" & e.sval &
            "', which touches globals; generic routines cannot access " &
            "globals - pass values through parameters")
    for k in e.kids:
      scanE(c, k)
  proc scanS(c: Ctx, s: Stmt) =
    if s.kind == WithStmt and s.name in c.globals:
      err(s.line, "generic '" & gname & "' locks global '" & s.name &
        "'; generic routines cannot access globals")
    for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
      scanE(c, e)
    for a in s.args:
      scanE(c, a)
    for st in s.body:
      scanS(c, st)
    for br in s.elifs:
      scanE(c, br.cond)
      for st in br.body:
        scanS(c, st)
    for st in s.elseBody:
      scanS(c, st)
  for s in body:
    scanS(c, s)

proc directExpr(e: Expr, globals: Table[string, Typ], rname: string,
    direct: var Table[string, HashSet[string]]) =
  if e.isNil:
    return
  if e.kind == IdentExpr and e.sval in globals:
    direct.mgetOrPut(e.sval, initHashSet[string]()).incl rname
  for k in e.kids:
    directExpr(k, globals, rname, direct)

proc directStmt(s: Stmt, globals: Table[string, Typ], rname: string,
    direct: var Table[string, HashSet[string]]) =
  if s.kind == WithStmt and s.name in globals:
    direct.mgetOrPut(s.name, initHashSet[string]()).incl rname
  for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
    directExpr(e, globals, rname, direct)
  for a in s.args:
    directExpr(a, globals, rname, direct)
  for st in s.body:
    directStmt(st, globals, rname, direct)
  for br in s.elifs:
    directExpr(br.cond, globals, rname, direct)
    for st in br.body:
      directStmt(st, globals, rname, direct)
  for st in s.elseBody:
    directStmt(st, globals, rname, direct)

proc instantiate(c: var Ctx, e: Expr, ats: seq[Typ]): string =
  ## Bind a generic's $names from the argument types, splice the
  ## bindings into the captured tokens, reparse, and check the result
  ## as an ordinary routine - once per distinct binding.
  let gname = e.sval
  let gr = c.generics[gname]
  if gname in c.instStack:
    err(e.line, "recursion is not allowed: generic '" & gname &
      "' calls itself (even at another binding)")
  if e.kids.len != gr.params.len:
    err(e.line, "'" & gname & "' expects " & $gr.params.len &
      " argument(s), got " & $e.kids.len)
  var sizes: Table[string, int64]
  var typs: Table[string, Typ]
  var order: seq[string]
  for i, pm in gr.params:
    if ats[i] == nil:
      err(e.kids[i].line, "cannot infer generic $names from none; " &
        "pass a typed value")
    c.unifyPat(pm.typ, ats[i], sizes, typs, order, e.kids[i].line, gname)
  var parts: seq[string]
  var binds: seq[string]
  for nm in order:
    if nm in sizes:
      parts.add mangleVal(sizes[nm])
      binds.add "$" & nm & " = " & $sizes[nm]
    else:
      parts.add mangleTyp(typs[nm])
      binds.add "$" & nm & " = " & $typs[nm]
  let key = gname & "|" & parts.join("|")
  if key in c.instCache:
    e.sval = c.instCache[key]
    return e.sval
  let mangled = gname & "__" & parts.join("_")
  var toks: seq[Token]
  var i = 0
  while i < gr.toks.len:
    let tk = gr.toks[i]
    if i == 1:
      toks.add Token(kind: IdentToken, text: mangled, line: tk.line)
      inc i
    elif tk.kind == OpToken and tk.text == "$":
      if i + 1 >= gr.toks.len or gr.toks[i + 1].kind != IdentToken:
        err(tk.line, "a name must follow '$'")
      let nm = gr.toks[i + 1].text
      if nm in typs and i + 3 < gr.toks.len and
          gr.toks[i + 2].kind == OpToken and gr.toks[i + 2].text == "." and
          gr.toks[i + 3].kind == IdentToken and
          gr.toks[i + 3].text in ["lo", "hi"]:
        let bt = typs[nm]
        if bt.kind != IntType or bt.opt:
          err(tk.line, "$" & nm & "." & gr.toks[i + 3].text &
            " needs an int type; $" & nm & " is " & $bt)
        let v = if gr.toks[i + 3].text == "lo": bt.rlo else: bt.rhi
        if v < 0:
          toks.add Token(kind: OpToken, text: "-", line: tk.line)
          toks.add Token(kind: IntToken, text: $(-v), line: tk.line)
        else:
          toks.add Token(kind: IntToken, text: $v, line: tk.line)
        i += 4
      elif nm in sizes:
        toks.add Token(kind: IntToken, text: $sizes[nm], line: tk.line)
        i += 2
      elif nm in typs:
        toks.add typToToks(typs[nm], tk.line, gname)
        i += 2
      else:
        err(tk.line, "'$" & nm & "' is not bound by any parameter of '" &
          gname & "'")
    else:
      toks.add tk
      inc i
  toks.add Token(kind: EofToken, line: gr.toks[^1].line)
  let inst = parseInstance(toks, gr.constsSnap, gr.typesSnap)
  c.allRoutines.incl mangled
  c.routineTab[mangled] = inst
  c.routineAccess[mangled] = initHashSet[string]()
  c.routineWrites[mangled] = initHashSet[string]()
  # Check the instance re-entrantly, with the caller's state parked.
  let savedCur = c.cur
  let savedScopes = c.scopes
  let savedWith = c.withDepth
  let savedLoopW = c.loopWiths
  let savedFacts = c.facts
  let savedMutBan = c.mutBan
  let savedHeld = c.heldLocks
  let savedVarDecls = c.varDecls
  let savedModified = c.modified
  let savedBigRet = c.allowBigRet
  c.instStack.add gname
  try:
    c.scanNoGlobals(gname, inst.body)
    c.checkRoutine(inst)
  except NiftyError as ex:
    ex.msg.add "\n  while instantiating '" & gname & "' with " &
      binds.join(", ") & " at " & locOf(e.line)
    raise ex
  finally:
    discard c.instStack.pop
    c.cur = savedCur
    c.scopes = savedScopes
    c.withDepth = savedWith
    c.loopWiths = savedLoopW
    c.facts = savedFacts
    c.mutBan = savedMutBan
    c.heldLocks = savedHeld
    c.varDecls = savedVarDecls
    c.modified = savedModified
    c.allowBigRet = savedBigRet
  c.instCache[key] = mangled
  c.instances.mgetOrPut(gname, @[]).add inst
  e.sval = mangled
  mangled

proc check*(m: Module) =
  ## Check the module and publish its shared semantic plan on success.
  m.semantics = nil
  var lockReport: seq[LockProof]
  var c = Ctx()
  var used: HashSet[string]
  for td in m.types:
    validateOwnedType(td.typ, td.line)
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
    validateOwnedType(gd.typ, gd.line)
    if gd.name in used:
      err(gd.line, "duplicate name: '" & gd.name & "'")
    used.incl gd.name
    if not zeroOk(gd.typ):
      err(gd.line, "global '" & gd.name & "' is zero-initialized, but 0 is " &
        "not in " & $gd.typ)
    if gd.typ.kind == LockType:
      c.lockOrder[gd.name] = c.lockOrder.len
    c.globals[gd.name] = gd.typ
  var anyThread = false
  for r in m.routines:
    if r.name in used:
      # Overloading: routines may share a name when each one can be
      # told apart by the kind of its first parameter - close(file)
      # and close(socket) are two routines with one good name. The
      # later declarations get unique internal names; calls resolve
      # by their first argument and are rewritten to those.
      let src = r.name
      let first = if src in c.routineTab: c.routineTab[src] else: nil
      if first == nil or first.kind == ThreadRoutine or first.generic or
          r.kind == ThreadRoutine or r.generic or src in ["start", "end"]:
        err(r.line, "duplicate name: '" & r.name & "'")
      if src notin c.overloads:
        c.overloads[src] = @[src]
      if r.params.len == 0:
        err(r.line, "cannot overload '" & src & "': an overload needs a " &
          "first parameter to be picked by")
      let key = dispatchKey(r.params[0].typ)
      if key == "":
        err(r.line, "cannot overload '" & src & "' on a first parameter " &
          "of type " & $r.params[0].typ)
      for cn in c.overloads[src]:
        let other = c.routineTab[cn]
        if other.params.len == 0:
          err(r.line, "cannot overload '" & src & "': the declaration at " &
            "line " & $other.line & " takes no parameters")
        if dispatchKey(other.params[0].typ) == key:
          err(r.line, "ambiguous overload: '" & src & "' declared at " &
            "line " & $other.line & " also takes " & key & " first")
      if r.externLib != "" and r.cname == "":
        r.cname = src # keep linking against the C symbol, not our suffix
      r.name = src & "__" & $(c.overloads[src].len + 1)
      c.overloads[src].add r.name
    used.incl r.name
    c.allRoutines.incl r.name
    if r.generic:
      c.generics[r.name] = r
    else:
      c.routineTab[r.name] = r
    if r.kind == ThreadRoutine:
      anyThread = true
  c.usedNames = used
  if not anyThread:
    err(1, "a nifty program needs at least one thread (thread name() = ...)")

  ## Thread Ownership and Lock Protection
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
    name in c.globals and c.globals[name].kind != LockType

  var lockGlobals: Table[string, HashSet[string]] # lock -> globals under it
  var lockEcho: HashSet[string]                   # locks held around an echo
  var routineEcho: Table[string, bool]
  var routineLocks: Table[string, HashSet[string]]
  var routineSends: Table[string, HashSet[string]] # channels it may send on
  var routineRecvs: Table[string, HashSet[string]] # channels it may recv on
  var curEcho = false
  var curLocks: HashSet[string]
  var curSends: HashSet[string]
  var curRecvs: HashSet[string]

  proc note(g: string, held: HashSet[string]) =
    if g in acc:
      acc[g] = acc[g] * held
    else:
      acc[g] = held
    for lk in held:
      lockGlobals.mgetOrPut(lk, initHashSet[string]()).incl g

  proc noteEcho(held: HashSet[string]) =
    curEcho = true
    for lk in held:
      lockEcho.incl lk

  proc noteBlock(ch: string, op: string, held: HashSet[string], line: int) =
    # Blocking never happens while a lock is held: a blocked thread
    # would keep every signaler out of the lock - the lock/channel
    # deadlock, excluded statically the way lock order excludes the
    # lock/lock one.
    if held.len > 0:
      for hl in held:
        err(line, "cannot " & op & " on channel '" & ch & "' while " &
          "holding lock '" & hl & "': blocking while holding a lock " &
          "can deadlock; move the channel operation outside the with " &
          "block")
    if op == "send":
      curSends.incl ch
    else:
      curRecvs.incl ch

  proc mergeCallee(callee: string, held: HashSet[string], line: int) =
    if callee in access:
      for g, ls in access[callee]:
        note(g, held + ls)
      for g in writes[callee]:
        wr.incl g
    if routineEcho.getOrDefault(callee, false):
      noteEcho(held)
    for lk in routineLocks.getOrDefault(callee, initHashSet[string]()):
      curLocks.incl lk
    for ch in routineSends.getOrDefault(callee, initHashSet[string]()):
      if held.len > 0:
        for hl in held:
          err(line, "'" & callee & "' may block sending on channel '" &
            ch & "' and lock '" & hl & "' is held here; blocking while " &
            "holding a lock can deadlock")
      curSends.incl ch
    for ch in routineRecvs.getOrDefault(callee, initHashSet[string]()):
      if held.len > 0:
        for hl in held:
          err(line, "'" & callee & "' may block receiving on channel '" &
            ch & "' and lock '" & hl & "' is held here; blocking while " &
            "holding a lock can deadlock")
      curRecvs.incl ch

  proc scanE(e: Expr, held: HashSet[string]) =
    if e.isNil:
      return
    if e.kind == IdentExpr and isPlainGlobal(e.sval):
      note(e.sval, held)
    if e.kind == MethodExpr and e.sval in mutMethods:
      let root = e.kids[0].rootIdent
      if root.kind == IdentExpr and isPlainGlobal(root.sval):
        note(root.sval, held)
        wr.incl root.sval
        if e.sval in ["send", "recv"] and root.sval in c.globals and
            c.globals[root.sval].kind == ChannelType:
          noteBlock(root.sval, e.sval, held, e.line)
    if e.kind in {CallExpr, MethodExpr} and
        (e.kind == CallExpr or e.sval notin builtinMethods) and
        (e.sval in c.routineTab or e.sval in c.overloads):
      # This pass runs before types are known, so an overloaded call
      # merges every candidate - an over-approximation, which is the
      # sound direction for ownership, locks, and blocking.
      var callees = @[e.sval]
      if e.sval in c.overloads:
        callees = c.overloads[e.sval]
      for callee in callees:
        if callee notin c.routineTab:
          continue
        mergeCallee(callee, held, e.line)
        let r2 = c.routineTab[callee]
        for i, arg in e.kids:
          if i < r2.params.len and r2.params[i].isVar:
            let root = arg.rootIdent
            if root.kind == IdentExpr and isPlainGlobal(root.sval):
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
    if s.kind == EchoStmt:
      noteEcho(held)
    case s.kind
    of AssignStmt:
      let root = s.lhs.rootIdent
      if root.kind == IdentExpr and isPlainGlobal(root.sval):
        note(root.sval, held)
        wr.incl root.sval
    of WithStmt:
      if s.name in c.globals and c.globals[s.name].kind == LockType:
        bodyHeld = held + [s.name].toHashSet
        curLocks.incl s.name
      else:
        if isPlainGlobal(s.name):
          note(s.name, held)
          wr.incl s.name
        mergeCallee("start", held, s.line)
        mergeCallee("end", held, s.line)
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
    curEcho = false
    curLocks = initHashSet[string]()
    curSends = initHashSet[string]()
    curRecvs = initHashSet[string]()
    for st in r.body:
      scanS(st, initHashSet[string]())
    access[r.name] = acc
    writes[r.name] = wr
    routineEcho[r.name] = curEcho
    routineLocks[r.name] = curLocks
    routineSends[r.name] = curSends
    routineRecvs[r.name] = curRecvs
  c.routineLocks = routineLocks
  c.routineWrites = writes
  for rname, accTab in access:
    var names: HashSet[string]
    for g in accTab.keys:
      names.incl g
    c.routineAccess[rname] = names

  var accThreads: Table[string, seq[string]]
  var accInstances: Table[string, int] # thread 4 w() counts as 4 accessors
  var lockProt: Table[string, HashSet[string]]
  var writeThreads: Table[string, HashSet[string]]
  for r in m.routines:
    if r.kind != ThreadRoutine:
      continue
    for g, ls in access[r.name]:
      if g notin accThreads:
        accThreads[g] = @[]
        accInstances[g] = 0
        lockProt[g] = ls
      else:
        lockProt[g] = lockProt[g] * ls
      accThreads[g].add (if r.instances > 1: r.name & " x" & $r.instances
        else: r.name)
      accInstances[g] = accInstances[g] + r.instances
    for g in writes[r.name]:
      if g notin writeThreads:
        writeThreads[g] = initHashSet[string]()
      writeThreads[g].incl r.name
  # Channels synchronize themselves, so they are exempt from the lock
  # rule - but they must have both sides: a thread that sends and a
  # thread that receives (a counted thread's instances count separately).
  var sendInst: Table[string, int]
  var recvInst: Table[string, int]
  for r in m.routines:
    if r.kind != ThreadRoutine:
      continue
    for ch in routineSends[r.name]:
      sendInst[ch] = sendInst.getOrDefault(ch, 0) + r.instances
    for ch in routineRecvs[r.name]:
      recvInst[ch] = recvInst.getOrDefault(ch, 0) + r.instances
  for gd in m.globals:
    if gd.typ.kind == ChannelType:
      if sendInst.getOrDefault(gd.name, 0) == 0 or
          recvInst.getOrDefault(gd.name, 0) == 0 or
          accInstances.getOrDefault(gd.name, 0) < 2:
        err(gd.line, "channel '" & gd.name & "' needs a thread that " &
          "sends and a thread that receives (" &
          $sendInst.getOrDefault(gd.name, 0) & " sending, " &
          $recvInst.getOrDefault(gd.name, 0) & " receiving); a channel " &
          "without both sides waits forever")
      continue
    if gd.typ.kind == LockType:
      continue
    let g = gd.name
    if g in accThreads and accInstances[g] >= 2 and g in writeThreads:
      if lockProt[g].len == 0:
        err(gd.line, "shared global '" & g & "' is accessed by threads " &
          accThreads[g].join(", ") & " but not consistently protected; " &
          "every access (reads too) must be inside a with block holding " &
          "one common lock")
      c.sharedProt[g] = lockProt[g]

  for r in m.routines:
    if r.generic:
      c.checked.incl r.name
      continue
    if r.externLib != "":
      # Binary FFI: we declared the shape; validate it is expressible.
      for pm in r.params:
        validateOwnedType(pm.typ, r.line)
        if hasOwned(pm.typ) and pm.typ.kind != StringType:
          err(r.line, "extern '" & r.name &
            "' cannot access owning descriptors; pass string bytes instead")
        case pm.typ.kind
        of IntType, FloatType:
          discard # by value (or by pointer when var)
        of StringType, ArrayType:
          discard # a data pointer; var makes it writable
        of ObjectType:
          if not pm.isVar:
            err(r.line, "extern '" & r.name & "': pass objects as var " &
              "(a pointer); by-value struct ABIs are not supported")
        else:
          err(r.line, "extern '" & r.name & "': " & $pm.typ &
            " cannot cross the C boundary; use sized ints, floats, " &
            "string[N] buffers, arrays, or var objects")
        if pm.typ.opt:
          err(r.line, "extern '" & r.name & "': optionals cannot cross " &
            "the C boundary")
        # A top-level string passes only its payload bytes. Strings inside
        # aggregates expose length metadata that raw writes cannot preserve.
        if pm.isVar and pm.typ.kind != StringType and
            not foreignWritable(pm.typ):
          err(r.line, "extern '" & r.name & "': writable parameter '" &
            pm.name & "' has a range or container invariant foreign code " &
            "can violate")
        if pm.isVar and pm.typ.kind in {StringType, ArrayType} and
            pm.boundedBy == "":
          err(r.line, "extern '" & r.name & "': writable buffer '" &
            pm.name & "' needs boundedBy count")
        if pm.boundedBy != "":
          if pm.typ.kind notin {StringType, ArrayType}:
            err(r.line, "extern '" & r.name & "': boundedBy requires " &
              "a string or array buffer")
          var found = pm.boundedBy in c.consts or
            (pm.boundedBy.len > 0 and pm.boundedBy[0] in {'0' .. '9'})
          for other in r.params:
            if other.name == pm.boundedBy:
              found = other.typ.kind == IntType
          if not found:
            err(r.line, "extern '" & r.name & "': boundedBy '" &
              pm.boundedBy & "' needs an integer count parameter or const")
      if r.ret != nil and r.ret.kind notin {IntType, FloatType}:
        err(r.line, "extern '" & r.name & "' can only return ints or " &
          "floats (fill a var buffer for data)")
      if r.ret != nil and r.ret.kind == IntType and
          not foreignWritable(r.ret):
        err(r.line, "extern '" & r.name &
          "': result range is not guaranteed by the foreign ABI")
      c.checked.incl r.name
      continue
    c.checkRoutine(r)
  var flat: seq[Routine]
  for r in m.routines:
    if r.generic:
      for inst in c.instances.getOrDefault(r.name, @[]):
        flat.add inst
    else:
      flat.add r
  m.routines = flat

  # Smallest scope for globals (Power of 10, rule 6): a global is only
  # honest if its width is needed - by several routines, or by state
  # that must survive between calls.
  var direct: Table[string, HashSet[string]]
  for r in m.routines:
    for s in r.body:
      directStmt(s, c.globals, r.name, direct)
  for gd in m.globals:
    let users = direct.getOrDefault(gd.name)
    if users.len == 0:
      err(gd.line, "global '" & gd.name & "' is never used; remove it")
    elif users.len == 1:
      var rn = ""
      for u in users:
        rn = u
      let rr = c.routineTab[rn]
      # A counted thread (thread 4 w()) is several threads: a global or
      # lock used only by it is still shared between its instances.
      if rr.kind == ThreadRoutine and rr.instances == 1:
        if gd.typ.kind == LockType:
          err(gd.line, "lock '" & gd.name & "' is only used by thread '" &
            rn & "'; a lock held by a single thread protects nothing - " &
            "remove it")
        err(gd.line, "global '" & gd.name & "' is only used by thread '" &
          rn & "'; declare it inside the thread")
      if rr.kind == ProcRoutine and gd.typ.kind != LockType:
        var w = false
        if not mayReadFirst(rr.body, gd.name, w):
          err(gd.line, "global '" & gd.name & "' is only used by '" & rn &
            "', which always overwrites it before reading; declare it " &
            "as a local there")
    var effUsers = 0
    for u in users:
      let ur = c.routineTab[u]
      effUsers += (if ur.kind == ThreadRoutine: ur.instances else: 1)
    if gd.typ.kind == LockType and effUsers >= 2:
      # A lock earns its place by guarding shared state (or, at minimum,
      # serializing output). Otherwise it only costs cycles.
      var guards: seq[string]
      for g in lockGlobals.getOrDefault(gd.name, initHashSet[string]()):
        if g in c.sharedProt and gd.name in c.sharedProt[g]:
          guards.add g
      guards.sort()
      if guards.len == 0 and gd.name notin lockEcho:
        err(gd.line, "lock '" & gd.name & "' does not protect anything " &
          "shared: nothing accessed while it is held is used by more " &
          "than one thread; remove it")
      var us: seq[string]
      for u in users:
        us.add u
      us.sort()
      lockReport.add LockProof(name: gd.name, guards: guards, users: us)
  let channelProgress = checkProgress(m)
  prepareSemantics(m)
  m.semantics.locks = lockReport
  m.semantics.channelProgress = channelProgress

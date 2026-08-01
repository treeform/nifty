## C code generation: checked Module -> one C99 + pthreads translation unit.
## Because nifty enforces declare-before-use, the generated C needs no
## forward prototypes: definitions appear in call order.

import std/[strutils, tables, sets, sequtils]
import types

type
  Gen = object
    o: string
    ind: int
    tmpN: int
    src: string
    routines: Table[string, Routine]
    emitted: HashSet[string] # typedefs already generated, by mangled name
    frameOf: Table[string, int64]  # routine -> its own arena frame bytes
    needOf: Table[string, int64]   # routine -> worst-case arena incl callees
    bigOffs: Table[string, Table[string, int64]] # routine -> local -> offset
    curArena: Table[string, int64] # current routine's big locals
    curRet: Typ                    # return type of the routine being emitted
    curFrame: int64                # current routine's arena frame bytes

proc put(g: var Gen, s: string) =
  g.o.add spaces(g.ind * 2)
  g.o.add s
  g.o.add '\n'

proc cQuote(s: string): string =
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    else: result.add ch
  result.add "\""

proc mangleNum(n: int64): string =
  if n < 0: "m" & $(-n) else: $n

proc mangle(t: Typ): string =
  if t.opt:
    return "p" & mangle(deOpt(t))
  case t.kind
  of IntType: "i"
  of BoolType: "b"
  of ArrayType: "a" & $t.len & "_" & mangle(t.elem)
  of SeqType: "q" & $t.len & "_" & mangle(t.elem)
  of StringType: "s" & $t.len
  of SetType: "t" & mangleNum(t.elem.rlo) & "_" & mangleNum(t.elem.rhi)
  of QueueType: "u" & $t.len & "_" & mangle(t.elem)
  of DenseMapType: "d" & mangleNum(t.elem.rlo) & "_" & mangleNum(t.elem.rhi) &
    "_" & mangle(t.val)
  of SparseMapType: "m" & $t.len & "_" & mangle(t.elem) & "_" & mangle(t.val)
  of ObjectType: "o" & t.name
  else: "x"

proc cBase(t: Typ): string =
  if t.opt:
    return "NS_" & mangle(t)
  case t.kind
  of BoolType: "bool"
  of ObjectType: "S_" & t.name
  of SeqType, StringType, SetType, QueueType, DenseMapType, SparseMapType: "NS_" & mangle(t)
  else: "int64_t"

proc cDecl(name: string, t: Typ): string =
  var base = t
  var dims = ""
  while base.kind == ArrayType:
    dims.add "[" & $base.len & "]"
    base = base.elem
  cBase(base) & " " & name & dims

proc passByPtr(t: Typ): bool =
  ## var parameters pass by pointer, except arrays which already decay.
  t.kind != ArrayType

proc genExpr(g: var Gen, e: Expr): string =
  if e.wrapOpt:
    # A plain value flowing into an optional destination.
    let optT = e.typ
    e.wrapOpt = false
    e.typ = deOpt(optT)
    let inner = g.genExpr(e)
    e.typ = optT
    e.wrapOpt = true
    return "((" & cBase(optT) & "){ .m_val = " & inner & ", .m_ok = true })"
  case e.kind
  of NoneExpr:
    "((" & cBase(e.typ) & "){0})"
  of IntExpr:
    $e.ival & "LL"
  of BoolExpr:
    if e.bval: "true" else: "false"
  of StrExpr:
    if e.typ != nil and e.typ.kind == StringType:
      "(" & cBase(e.typ) & "){ .m_len = " & $e.sval.len & "LL, .m_data = " &
        cQuote(e.sval) & " }"
    else:
      cQuote(e.sval)
  of IdentExpr:
    let nm =
      case e.symKind
      of ConstSym: "C_" & e.sval
      of GlobalSym: "g_" & e.sval
      of LocalSym:
        if e.sval in g.curArena:
          "(*v_" & e.sval & ")" # big local: lives on the thread's arena
        else:
          "v_" & e.sval
      of ParamSym:
        if e.isVarParam and e.typ.passByPtr:
          "(*p_" & e.sval & ")"
        else:
          "p_" & e.sval
    if e.unwrapOpt: nm & ".m_val" else: nm
  of NegExpr:
    "(-" & g.genExpr(e.kids[0]) & ")"
  of NotExpr:
    "(!" & g.genExpr(e.kids[0]) & ")"
  of BinExpr:
    let a = g.genExpr(e.kids[0])
    let b = g.genExpr(e.kids[1])
    case e.sval
    # / and % are proven safe by the checker; no runtime check needed.
    of "and": "(" & a & " && " & b & ")"
    of "or": "(" & a & " || " & b & ")"
    else: "(" & a & " " & e.sval & " " & b & ")"
  of IndexExpr:
    # The checker proved the index is in bounds; no runtime check needed.
    if e.kids[0].typ != nil and e.kids[0].typ.kind == DenseMapType:
      g.genExpr(e.kids[0]) & ".m_vals[(" & g.genExpr(e.kids[1]) & ") - " &
        $e.kids[0].typ.elem.rlo & "LL]"
    elif e.kids[0].typ != nil and e.kids[0].typ.kind == SparseMapType:
      cBase(e.kids[0].typ) & "_at(&" & g.genExpr(e.kids[0]) & ", " &
        g.genExpr(e.kids[1]) & ")"
    elif e.kids[0].typ != nil and e.kids[0].typ.kind in {SeqType, StringType}:
      g.genExpr(e.kids[0]) & ".m_data[" & g.genExpr(e.kids[1]) & "]"
    else:
      g.genExpr(e.kids[0]) & "[" & g.genExpr(e.kids[1]) & "]"
  of CallExpr:
    let r = g.routines[e.sval]
    var parts: seq[string]
    for i, a in e.kids:
      if r.params[i].isVar and r.params[i].typ.passByPtr:
        parts.add "&" & g.genExpr(a)
      else:
        parts.add g.genExpr(a)
    "f_" & e.sval & "(" & parts.join(", ") & ")"
  of FieldExpr:
    if e.isOptOk:
      g.genExpr(e.kids[0]) & ".m_ok"
    elif e.kids[0].typ != nil and not e.kids[0].typ.opt and
        e.kids[0].typ.kind in {SeqType, StringType, SetType, QueueType, DenseMapType, SparseMapType}:
      g.genExpr(e.kids[0]) & ".m_len"
    elif e.unwrapOpt:
      g.genExpr(e.kids[0]) & ".m_" & e.sval & ".m_val"
    else:
      g.genExpr(e.kids[0]) & ".m_" & e.sval
  of MethodExpr:
    let bt = e.kids[0].typ
    if e.sval == "or" and bt != nil and bt.opt:
      return cBase(bt) & "_or(" & g.genExpr(e.kids[0]) & ", " &
        g.genExpr(e.kids[1]) & ")"
    let fn = cBase(bt) & "_" & (if bt.kind == StringType and e.sval == "add": "adds"
      else: e.sval)
    let basePtr = "&" & g.genExpr(e.kids[0])
    if bt.kind == StringType and e.sval == "add":
      let a = e.kids[1]
      if a.kind == StrExpr and (a.typ == nil or a.typ.kind != StringType):
        fn & "(" & basePtr & ", (const uint8_t *)" & cQuote(a.sval) & ", " &
          $a.sval.len & "LL)"
      else:
        # The argument is a path-like string value; safe to mention twice.
        let av = g.genExpr(a)
        fn & "(" & basePtr & ", " & av & ".m_data, " & av & ".m_len)"
    elif e.kids.len > 2:
      fn & "(" & basePtr & ", " & g.genExpr(e.kids[1]) & ", " &
        g.genExpr(e.kids[2]) & ")"
    elif e.kids.len > 1:
      fn & "(" & basePtr & ", " & g.genExpr(e.kids[1]) & ")"
    else:
      fn & "(" & basePtr & ")"

proc hasEffects(g: Gen, e: Expr): bool =
  ## Does evaluating this expression run a proc or mutate a container?
  ## (func calls are pure and echo-free by construction.)
  if e.isNil:
    return false
  if e.kind == CallExpr and e.sval in g.routines and
      g.routines[e.sval].kind == ProcRoutine:
    return true
  if e.kind == MethodExpr and e.sval in mutMethods:
    return true
  for k in e.kids:
    if g.hasEffects(k):
      return true

proc genOrdered(g: var Gen, e: Expr): string

proc genPathOrdered(g: var Gen, e: Expr): string =
  ## An lvalue path with its index expressions hoisted in source order.
  case e.kind
  of FieldExpr:
    g.genPathOrdered(e.kids[0]) & ".m_" & e.sval
  of IndexExpr:
    let base = g.genPathOrdered(e.kids[0])
    let idx = g.genOrdered(e.kids[1])
    if e.kids[0].typ != nil and e.kids[0].typ.kind in {SeqType, StringType}:
      base & ".m_data[" & idx & "]"
    else:
      base & "[" & idx & "]"
  else:
    g.genExpr(e)

proc tempFor(g: var Gen, e: Expr, val: string): string =
  let t = "ni_t" & $g.tmpN
  inc g.tmpN
  let ctype =
    if e.typ == nil: "int64_t"
    elif e.typ.opt: cBase(e.typ)
    elif e.typ.kind == BoolType: "bool"
    elif e.typ.kind in {ObjectType, SeqType, StringType, SetType, QueueType,
      DenseMapType, SparseMapType}: cBase(e.typ)
    else: "int64_t"
  g.put ctype & " " & t & " = " & val & ";"
  t

proc genOrdered(g: var Gen, e: Expr): string =
  ## Emit the expression with strict left-to-right evaluation, effects
  ## included: effectful nodes become their own C statements, and every
  ## read is captured at the moment the program text reaches it, so C's
  ## unspecified subexpression order can never be observed.
  if e.wrapOpt:
    let optT = e.typ
    e.wrapOpt = false
    e.typ = deOpt(optT)
    let inner = g.genOrdered(e)
    e.typ = optT
    e.wrapOpt = true
    return "((" & cBase(optT) & "){ .m_val = " & inner & ", .m_ok = true })"
  case e.kind
  of NoneExpr, IntExpr, BoolExpr, StrExpr:
    g.genExpr(e)
  of IdentExpr:
    if e.typ != nil and e.typ.kind == ArrayType:
      g.genExpr(e) # arrays are reference-like; the path is the value
    else:
      g.tempFor(e, g.genExpr(e))
  of FieldExpr:
    if e.typ != nil and e.typ.kind == ArrayType:
      g.genPathOrdered(e)
    elif e.kids[0].typ != nil and
        e.kids[0].typ.kind in {SeqType, StringType, SetType, QueueType, DenseMapType, SparseMapType}:
      g.tempFor(e, g.genPathOrdered(e.kids[0]) & ".m_len")
    else:
      g.tempFor(e, g.genPathOrdered(e))
  of IndexExpr:
    if e.kids[0].typ != nil and e.kids[0].typ.kind == DenseMapType:
      let base = g.genPathOrdered(e.kids[0])
      let k = g.genOrdered(e.kids[1])
      g.tempFor(e, base & ".m_vals[(" & k & ") - " &
        $e.kids[0].typ.elem.rlo & "LL]")
    elif e.kids[0].typ != nil and e.kids[0].typ.kind == SparseMapType:
      let base = g.genPathOrdered(e.kids[0])
      let k = g.genOrdered(e.kids[1])
      g.tempFor(e, cBase(e.kids[0].typ) & "_at(&" & base & ", " & k & ")")
    elif e.typ != nil and e.typ.kind == ArrayType:
      g.genPathOrdered(e)
    else:
      g.tempFor(e, g.genPathOrdered(e))
  of NegExpr:
    "(-" & g.genOrdered(e.kids[0]) & ")"
  of NotExpr:
    "(!" & g.genOrdered(e.kids[0]) & ")"
  of BinExpr:
    if e.sval in ["and", "or"]:
      # Short-circuit preserved: the right side runs only when needed.
      let t = "ni_t" & $g.tmpN
      inc g.tmpN
      g.put "bool " & t & " = " & g.genOrdered(e.kids[0]) & ";"
      g.put (if e.sval == "and": "if (" & t & ") {"
        else: "if (!" & t & ") {")
      inc g.ind
      let r = g.genOrdered(e.kids[1])
      g.put t & " = " & r & ";"
      dec g.ind
      g.put "}"
      t
    else:
      let a = g.genOrdered(e.kids[0])
      let b = g.genOrdered(e.kids[1])
      "(" & a & " " & e.sval & " " & b & ")"
  of CallExpr:
    let r = g.routines[e.sval]
    var parts: seq[string]
    for i, a in e.kids:
      if r.params[i].isVar and r.params[i].typ.passByPtr:
        parts.add "&" & g.genPathOrdered(a)
      elif a.typ != nil and a.typ.kind == ArrayType:
        parts.add g.genPathOrdered(a)
      else:
        parts.add g.genOrdered(a)
    let call = "f_" & e.sval & "(" & parts.join(", ") & ")"
    if r.kind == FuncRoutine:
      call # pure: args are already ordered, the call itself has no effects
    elif r.ret.isNil:
      g.put call & ";"
      ""
    else:
      g.tempFor(e, call)
  of MethodExpr:
    let bt = e.kids[0].typ
    if e.sval == "or" and bt != nil and bt.opt:
      let b = g.genOrdered(e.kids[0])
      let f = g.genOrdered(e.kids[1])
      return g.tempFor(e, cBase(bt) & "_or(" & b & ", " & f & ")")
    let base = g.genPathOrdered(e.kids[0])
    let fn = cBase(bt) & "_" &
      (if bt.kind == StringType and e.sval == "add": "adds" else: e.sval)
    var call: string
    if bt.kind == StringType and e.sval == "add":
      let a = e.kids[1]
      if a.kind == StrExpr and (a.typ == nil or a.typ.kind != StringType):
        call = fn & "(&" & base & ", (const uint8_t *)" & cQuote(a.sval) &
          ", " & $a.sval.len & "LL)"
      else:
        let av = g.genPathOrdered(a)
        call = fn & "(&" & base & ", " & av & ".m_data, " & av & ".m_len)"
    elif e.kids.len > 2:
      let a1 = g.genOrdered(e.kids[1])
      let a2 = g.genOrdered(e.kids[2])
      call = fn & "(&" & base & ", " & a1 & ", " & a2 & ")"
    elif e.kids.len > 1:
      call = fn & "(&" & base & ", " & g.genOrdered(e.kids[1]) & ")"
    else:
      call = fn & "(&" & base & ")"
    if e.typ.isNil:
      g.put call & ";"
      ""
    else:
      g.tempFor(e, call)

proc genCallInto(g: var Gen, e: Expr, dest: string) =
  ## A big-return call: C cannot return arrays (and big values would land
  ## on the C stack), so the caller passes where the result goes and the
  ## callee fills it in place.
  let r = g.routines[e.sval]
  var parts: seq[string]
  for i, a in e.kids:
    if r.params[i].isVar and r.params[i].typ.passByPtr:
      parts.add "&" & g.genPathOrdered(a)
    elif a.typ != nil and a.typ.kind == ArrayType:
      parts.add g.genPathOrdered(a)
    else:
      parts.add g.genOrdered(a)
  parts.add dest
  g.put "f_" & e.sval & "(" & parts.join(", ") & ");"

proc collectBig(body: seq[Stmt], offs: var Table[string, int64],
    off: var int64) =
  ## Assign arena offsets (8-aligned) to every big local in a routine.
  for s in body:
    if s.kind in {VarStmt, LetStmt} and s.typ != nil and
        typeSize(s.typ) > arenaThreshold:
      off = (off + 7) div 8 * 8
      offs[s.name] = off
      off = off + typeSize(s.typ)
    collectBig(s.body, offs, off)
    for br in s.elifs:
      collectBig(br.body, offs, off)
    collectBig(s.elseBody, offs, off)

proc walkCalleeExpr(e: Expr, into: var HashSet[string]) =
  if e.isNil:
    return
  if e.kind == CallExpr:
    into.incl e.sval
  for k in e.kids:
    walkCalleeExpr(k, into)

proc collectCallees(body: seq[Stmt], into: var HashSet[string]) =
  for s in body:
    for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
      walkCalleeExpr(e, into)
    for a in s.args:
      walkCalleeExpr(a, into)
    if s.kind == WithStmt and s.typ != nil and s.typ.kind != LockType:
      into.incl "start"
      into.incl "end"
    collectCallees(s.body, into)
    for br in s.elifs:
      walkCalleeExpr(br.cond, into)
      collectCallees(br.body, into)
    collectCallees(s.elseBody, into)

proc genCond(g: var Gen, e: Expr): string =
  ## A condition wrapped in exactly one set of parentheses.
  let s = g.genExpr(e)
  if e.kind in {BinExpr, NotExpr, NegExpr}: s
  else: "(" & s & ")"

proc genStmt(g: var Gen, s: Stmt)

proc genBlock(g: var Gen, body: seq[Stmt]) =
  inc g.ind
  for s in body:
    g.genStmt(s)
  dec g.ind

proc genStmt(g: var Gen, s: Stmt) =
  case s.kind
  of VarStmt, LetStmt:
    if s.name in g.curArena:
      # A big local: a typed pointer into this thread's arena.
      let off = $g.curArena[s.name] & "LL"
      var base = s.typ
      var dims = ""
      while base.kind == ArrayType:
        dims.add "[" & $base.len & "]"
        base = base.elem
      if dims.len > 0:
        g.put cBase(base) & " (*v_" & s.name & ")" & dims & " = (" &
          cBase(base) & " (*)" & dims & ")(ni_base + " & off & ");"
      else:
        g.put cBase(s.typ) & " *v_" & s.name & " = (" & cBase(s.typ) &
          " *)(ni_base + " & off & ");"
      if s.init != nil and s.init.kind == CallExpr and bigRet(s.init.typ):
        g.genCallInto(s.init, "v_" & s.name)
      elif s.init != nil and s.typ.kind == ArrayType:
        let v =
          if g.hasEffects(s.init): g.genPathOrdered(s.init)
          else: g.genExpr(s.init)
        g.put "memcpy(v_" & s.name & ", " & v & ", " &
          $typeSize(s.typ) & "LL);"
      elif s.init != nil:
        let v =
          if g.hasEffects(s.init): g.genOrdered(s.init)
          else: g.genExpr(s.init)
        g.put "*v_" & s.name & " = " & v & ";"
      else:
        g.put "memset(v_" & s.name & ", 0, " & $typeSize(s.typ) & "LL);"
      return
    if s.init != nil and s.init.kind == CallExpr and bigRet(s.init.typ):
      g.put cDecl("v_" & s.name, s.typ) & ";"
      g.genCallInto(s.init, "&v_" & s.name)
      return
    if s.typ.kind == ArrayType and s.init != nil:
      # C cannot initialize an array from another; declare then copy.
      let v =
        if g.hasEffects(s.init): g.genPathOrdered(s.init)
        else: g.genExpr(s.init)
      g.put cDecl("v_" & s.name, s.typ) & ";"
      g.put "memcpy(v_" & s.name & ", " & v & ", " & $typeSize(s.typ) & "LL);"
      return
    let init =
      if s.init != nil and g.hasEffects(s.init): g.genOrdered(s.init)
      elif s.init != nil: g.genExpr(s.init)
      elif s.typ.opt: "{0}"
      elif s.typ.kind in {ArrayType, ObjectType, SeqType, StringType, SetType, QueueType,
        DenseMapType, SparseMapType}: "{0}"
      elif s.typ.kind == BoolType: "false"
      else: "0"
    g.put cDecl("v_" & s.name, s.typ) & " = " & init & ";"
  of AssignStmt:
    if s.rhs.kind == CallExpr and s.rhs.sval in g.routines and
        bigRet(g.routines[s.rhs.sval].ret):
      let lhs =
        if g.hasEffects(s.lhs): g.genPathOrdered(s.lhs)
        else: g.genExpr(s.lhs)
      g.genCallInto(s.rhs, "&(" & lhs & ")")
      return
    if s.lhs.typ != nil and s.lhs.typ.kind == ArrayType:
      var lhs, rhs: string
      if g.hasEffects(s.lhs) or g.hasEffects(s.rhs):
        lhs = g.genPathOrdered(s.lhs)
        rhs = g.genPathOrdered(s.rhs)
      else:
        lhs = g.genExpr(s.lhs)
        rhs = g.genExpr(s.rhs)
      g.put "memcpy(" & lhs & ", " & rhs & ", " & $typeSize(s.lhs.typ) & "LL);"
      return
    if s.lhs.kind == IndexExpr and s.lhs.kids[0].typ != nil and
        s.lhs.kids[0].typ.kind in {DenseMapType, SparseMapType}:
      let mt = s.lhs.kids[0].typ
      var base, k, v: string
      if g.hasEffects(s.lhs) or g.hasEffects(s.rhs):
        base = g.genPathOrdered(s.lhs.kids[0])
        k = g.genOrdered(s.lhs.kids[1])
        v = g.genOrdered(s.rhs)
      else:
        base = g.genExpr(s.lhs.kids[0])
        k = g.genExpr(s.lhs.kids[1])
        v = g.genExpr(s.rhs)
      if mt.kind == DenseMapType:
        g.put cBase(mt) & "_put(&" & base & ", " & k & ", " & v & ");"
      else:
        g.put "(void)" & cBase(mt) & "_put(&" & base & ", " & k & ", " &
          v & ");"
    elif g.hasEffects(s.lhs) or g.hasEffects(s.rhs):
      # Left-to-right, as written: target indexes first, then the value.
      let lhs = g.genPathOrdered(s.lhs)
      let rhs = g.genOrdered(s.rhs)
      g.put lhs & " = " & rhs & ";"
    else:
      g.put g.genExpr(s.lhs) & " = " & g.genExpr(s.rhs) & ";"
  of IfStmt:
    var anyEff = false
    for br in s.elifs:
      if g.hasEffects(br.cond):
        anyEff = true
    if not anyEff:
      for i, br in s.elifs:
        g.put (if i == 0: "if " else: "} else if ") & g.genCond(br.cond) & " {"
        g.genBlock(br.body)
      if s.elseBody.len > 0:
        g.put "} else {"
        g.genBlock(s.elseBody)
      g.put "}"
    else:
      # Effectful conditions run in order, each only when reached:
      # nested else blocks give every condition its own sequence point.
      var closes = 0
      for i, br in s.elifs:
        let cnd =
          if g.hasEffects(br.cond): g.genOrdered(br.cond)
          else: g.genExpr(br.cond)
        g.put "if (" & cnd & ") {"
        g.genBlock(br.body)
        if i < s.elifs.len - 1 or s.elseBody.len > 0:
          g.put "} else {"
          inc g.ind
          inc closes
        else:
          g.put "}"
      if s.elseBody.len > 0:
        for st in s.elseBody:
          g.genStmt(st)
      for _ in 0 ..< closes:
        dec g.ind
        g.put "}"
  of WhileStmt:
    if g.hasEffects(s.cond):
      # The condition re-runs every iteration with defined order:
      # evaluate it inside the loop, then decide.
      g.put "{"
      inc g.ind
      var ctr = ""
      if s.maxTrips > 0:
        ctr = "ni_trips" & $g.tmpN
        inc g.tmpN
        g.put "int64_t " & ctr & " = 0;"
      g.put "for (;;) {"
      inc g.ind
      if s.maxTrips > 0:
        g.put "if (" & ctr & " >= " & $s.maxTrips & "LL) break;"
      let cnd = g.genOrdered(s.cond)
      g.put "if (!(" & cnd & ")) break;"
      for st in s.body:
        g.genStmt(st)
      if s.maxTrips > 0:
        g.put "++" & ctr & ";"
      dec g.ind
      g.put "}"
      dec g.ind
      g.put "}"
    elif s.maxTrips > 0:
      # `while cond max N` is bounded by construction: the loop also
      # stops after N iterations.
      let ctr = "ni_trips" & $g.tmpN
      inc g.tmpN
      g.put "{"
      inc g.ind
      g.put "int64_t " & ctr & " = 0;"
      g.put "while (" & ctr & " < " & $s.maxTrips & "LL && " &
        g.genCond(s.cond) & ") {"
      g.genBlock(s.body)
      inc g.ind
      g.put "++" & ctr & ";"
      dec g.ind
      g.put "}"
      dec g.ind
      g.put "}"
    else:
      g.put "while " & g.genCond(s.cond) & " {"
      g.genBlock(s.body)
      g.put "}"
  of ForStmt:
    let tmp = "ni_end" & $g.tmpN
    inc g.tmpN
    g.put "{"
    inc g.ind
    let loS =
      if g.hasEffects(s.lo): g.genOrdered(s.lo) else: g.genExpr(s.lo)
    g.put "int64_t v_" & s.name & " = " & loS & ";"
    let hiS =
      if g.hasEffects(s.hi): g.genOrdered(s.hi) else: g.genExpr(s.hi)
    g.put "const int64_t " & tmp & " = " & hiS & ";"
    g.put "for (; v_" & s.name & (if s.inclusive: " <= " else: " < ") & tmp &
      "; ++v_" & s.name & ") {"
    g.genBlock(s.body)
    g.put "}"
    dec g.ind
    g.put "}"
  of LoopStmt:
    g.put "for (;;) {"
    g.genBlock(s.body)
    g.put "}"
  of WithStmt:
    if s.typ.kind == LockType:
      g.put "pthread_mutex_lock(&g_" & s.name & ");"
      g.put "{"
      g.genBlock(s.body)
      g.put "}"
      g.put "pthread_mutex_unlock(&g_" & s.name & ");"
    else:
      let arg = (if s.typ.passByPtr: "&" else: "") & g.genExpr(s.lhs)
      g.put "f_start(" & arg & ");"
      g.put "{"
      g.genBlock(s.body)
      g.put "}"
      g.put "f_end(" & arg & ");"
  of ReturnStmt:
    if s.value.isNil:
      if g.curFrame > 0:
        g.put "ni_sp = ni_base;"
      g.put "return;"
    elif bigRet(g.curRet):
      if s.value.kind == CallExpr:
        # A same-type call: forward our destination straight through.
        g.genCallInto(s.value, "ni_ret")
      elif g.curRet.kind == ArrayType:
        let v =
          if g.hasEffects(s.value): g.genPathOrdered(s.value)
          else: g.genExpr(s.value)
        g.put "memcpy(ni_ret, " & v & ", " & $typeSize(g.curRet) & "LL);"
      else:
        let v =
          if g.hasEffects(s.value): g.genOrdered(s.value)
          else: g.genExpr(s.value)
        g.put "*ni_ret = " & v & ";"
      if g.curFrame > 0:
        g.put "ni_sp = ni_base;"
      g.put "return;"
    elif g.hasEffects(s.value):
      let v = g.genOrdered(s.value)
      if g.curFrame > 0:
        g.put "ni_sp = ni_base;" # arena memory stays intact until the call ends
      g.put "return " & v & ";"
    else:
      let v = g.genExpr(s.value)
      if g.curFrame > 0:
        g.put "ni_sp = ni_base;"
      g.put "return " & v & ";"
  of BreakStmt:
    g.put "break;"
  of EchoStmt:
    # Every value argument is hoisted to a temp, in order: C leaves printf
    # argument evaluation order unspecified, nifty does not.
    var temps: Table[int, string]
    for i, a in s.args:
      if a.typ.kind != StringLitType:
        temps[i] = "ni_e" & $g.tmpN
        inc g.tmpN
    if temps.len > 0:
      g.put "{"
      inc g.ind
      for i, a in s.args:
        if i in temps:
          let ctype =
            case a.typ.kind
            of BoolType: "bool"
            of StringType: cBase(a.typ)
            else: "int64_t"
          let v =
            if g.hasEffects(a): g.genOrdered(a) else: g.genExpr(a)
          g.put ctype & " " & temps[i] & " = " & v & ";"
    var fmt = ""
    var cargs: seq[string]
    for i, a in s.args:
      case a.typ.kind
      of StringLitType:
        fmt.add a.sval.replace("%", "%%")
      of StringType:
        fmt.add "%.*s"
        cargs.add "(int)(" & temps[i] & ".m_len)"
        cargs.add "(const char *)" & temps[i] & ".m_data"
      of IntType:
        fmt.add "%lld"
        cargs.add "(long long)(" & temps[i] & ")"
      of BoolType:
        fmt.add "%s"
        cargs.add "((" & temps[i] & ") ? \"true\" : \"false\")"
      else:
        discard
    fmt.add "\n"
    var call = "printf(" & cQuote(fmt)
    for x in cargs:
      call.add ", " & x
    call.add ");"
    g.put call
    if temps.len > 0:
      dec g.ind
      g.put "}"
  of ForEachStmt:
    let it = "ni_it" & $g.tmpN
    let ix = "ni_ix" & $g.tmpN
    let nn = "ni_n" & $g.tmpN
    inc g.tmpN
    g.put "{"
    inc g.ind
    let basePath =
      if g.hasEffects(s.value): g.genPathOrdered(s.value)
      else: g.genExpr(s.value)
    g.put cBase(s.value.typ) & " *" & it & " = &" & basePath & ";"
    if s.value.typ.kind in {SetType, DenseMapType}:
      let lo = $s.value.typ.elem.rlo & "LL"
      let hi = $s.value.typ.elem.rhi & "LL"
      g.put "for (int64_t " & ix & " = " & lo & "; " & ix & " <= " & hi &
        "; ++" & ix & ") {"
      inc g.ind
      g.put "if (!" & cBase(s.value.typ) & "_contains(" & it & ", " & ix &
        ")) continue;"
      g.put cBase(s.typ) & " v_" & s.name & " = " & ix & ";"
      if s.name2.len > 0:
        g.put cBase(s.typ2) & " v_" & s.name2 & " = " & it & "->m_vals[" &
          ix & " - " & lo & "];"
    elif s.value.typ.kind == SparseMapType:
      g.put "const int64_t " & nn & " = " & it & "->m_len;"
      g.put "for (int64_t " & ix & " = 0; " & ix & " < " & nn & "; ++" & ix &
        ") {"
      inc g.ind
      g.put cBase(s.typ) & " v_" & s.name & " = " & it & "->m_keys[" & ix & "];"
      if s.name2.len > 0:
        g.put cBase(s.typ2) & " v_" & s.name2 & " = " & it & "->m_vals[" &
          ix & "];"
    elif s.value.typ.kind == QueueType:
      g.put "const int64_t " & nn & " = " & it & "->m_len;"
      g.put "for (int64_t " & ix & " = 0; " & ix & " < " & nn & "; ++" & ix &
        ") {"
      inc g.ind
      g.put cBase(s.typ) & " v_" & s.name & " = " & it & "->m_data[(" & it &
        "->m_head + " & ix & ") % " & $s.value.typ.len & "LL];"
    else:
      g.put "const int64_t " & nn & " = " & it & "->m_len;"
      g.put "for (int64_t " & ix & " = 0; " & ix & " < " & nn & "; ++" & ix &
        ") {"
      inc g.ind
      g.put cBase(s.typ) & " v_" & s.name & " = " & it & "->m_data[" & ix & "];"
    for st in s.body:
      g.genStmt(st)
    dec g.ind
    g.put "}"
    dec g.ind
    g.put "}"
  of DiscardStmt:
    if g.hasEffects(s.value):
      let v = g.genOrdered(s.value)
      if v.len > 0:
        g.put "(void)(" & v & ");"
    else:
      g.put "(void)(" & g.genExpr(s.value) & ");"
  of CallStmt:
    if g.hasEffects(s.value):
      let v = g.genOrdered(s.value)
      if v.len > 0:
        g.put v & ";"
    else:
      g.put g.genExpr(s.value) & ";"

const cPrelude = """
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <pthread.h>
"""

proc emitTypeDefs(g: var Gen, t: Typ) =
  ## Emit typedefs (and the inline ops for seq/string) exactly once each,
  ## dependencies first. Declare-before-use makes this a simple post-order.
  if t.isNil:
    return
  if t.opt:
    let base = deOpt(t)
    g.emitTypeDefs(base)
    let key = mangle(t)
    if key in g.emitted:
      return
    g.emitted.incl key
    let n = "NS_" & key
    let b = cBase(base)
    g.put ""
    g.put "typedef struct {"
    g.put "  " & b & " m_val;"
    g.put "  bool m_ok;"
    g.put "} " & n & ";"
    g.put "static " & b & " " & n & "_or(" & n & " r, " & b &
      " fb) { return r.m_ok ? r.m_val : fb; }"
    return
  case t.kind
  of ArrayType:
    g.emitTypeDefs(t.elem)
  of ObjectType:
    let key = mangle(t)
    if key in g.emitted:
      return
    g.emitted.incl key
    for f in t.fields:
      g.emitTypeDefs(f.typ)
    g.put ""
    g.put "typedef struct {"
    for f in t.fields:
      g.put "  " & cDecl("m_" & f.name, f.typ) & ";"
    g.put "} S_" & t.name & ";"
  of SeqType:
    g.emitTypeDefs(t.elem)
    let key = mangle(t)
    if key in g.emitted:
      return
    g.emitted.incl key
    let n = "NS_" & key
    let e = cBase(t.elem)
    g.put ""
    g.put "typedef struct {"
    g.put "  int64_t m_len;"
    g.put "  " & e & " m_data[" & $t.len & "];"
    g.put "} " & n & ";"
    g.put "static void " & n & "_add(" & n & " *s, " & e &
      " v) { s->m_data[s->m_len] = v; s->m_len += 1; }"
    g.put "static bool " & n & "_push(" & n & " *s, " & e &
      " v) { if (s->m_len >= " & $t.len &
      "LL) return false; s->m_data[s->m_len] = v; s->m_len += 1; return true; }"
    g.put "static " & e & " " & n & "_pop(" & n &
      " *s) { s->m_len -= 1; return s->m_data[s->m_len]; }"
    g.put "static void " & n & "_clear(" & n & " *s) { s->m_len = 0; }"
  of StringType:
    let key = mangle(t)
    if key in g.emitted:
      return
    g.emitted.incl key
    let n = "NS_" & key
    g.put ""
    g.put "typedef struct {"
    g.put "  int64_t m_len;"
    g.put "  uint8_t m_data[" & $t.len & "];"
    g.put "} " & n & ";"
    g.put "static void " & n & "_adds(" & n &
      " *s, const uint8_t *d, int64_t k) { " &
      "memcpy(&s->m_data[s->m_len], d, (size_t)k); s->m_len += k; }"
    g.put "static void " & n & "_clear(" & n & " *s) { s->m_len = 0; }"
  of QueueType:
    g.emitTypeDefs(t.elem)
    let key = mangle(t)
    if key in g.emitted:
      return
    g.emitted.incl key
    let n = "NS_" & key
    let e = cBase(t.elem)
    let cap = $t.len & "LL"
    g.put ""
    g.put "typedef struct {"
    g.put "  int64_t m_len;"
    g.put "  int64_t m_head;"
    g.put "  " & e & " m_data[" & $t.len & "];"
    g.put "} " & n & ";"
    g.put "static void " & n & "_add(" & n & " *s, " & e & " v) { " &
      "s->m_data[(s->m_head + s->m_len) % " & cap &
      "] = v; s->m_len += 1; }"
    g.put "static bool " & n & "_push(" & n & " *s, " & e & " v) { " &
      "if (s->m_len >= " & cap & ") return false; " &
      "s->m_data[(s->m_head + s->m_len) % " & cap &
      "] = v; s->m_len += 1; return true; }"
    g.put "static " & e & " " & n & "_pop(" & n & " *s) { " &
      e & " v = s->m_data[s->m_head]; " &
      "s->m_head = (s->m_head + 1) % " & cap & "; s->m_len -= 1; return v; }"
    g.put "static void " & n & "_clear(" & n &
      " *s) { s->m_len = 0; s->m_head = 0; }"
  of DenseMapType:
    g.emitTypeDefs(t.val)
    let key = mangle(t)
    if key in g.emitted:
      return
    g.emitted.incl key
    let n = "NS_" & key
    let lo = $t.elem.rlo & "LL"
    let hi = $t.elem.rhi & "LL"
    let span = t.setSize
    let words = (span + 63) div 64
    let v = cBase(t.val)
    g.put ""
    g.put "typedef struct {"
    g.put "  int64_t m_len;"
    g.put "  uint64_t m_bits[" & $words & "];"
    g.put "  " & v & " m_vals[" & $span & "];"
    g.put "} " & n & ";"
    g.put "static bool " & n & "_contains(" & n & " *s, int64_t k) { " &
      "if (k < " & lo & " || k > " & hi & ") return false; " &
      "return (s->m_bits[(k - " & lo & ") >> 6] >> ((k - " & lo &
      ") & 63)) & 1; }"
    g.put "static void " & n & "_put(" & n & " *s, int64_t k, " & v &
      " x) { uint64_t *w = &s->m_bits[(k - " & lo & ") >> 6]; " &
      "uint64_t m = 1ULL << ((k - " & lo & ") & 63); " &
      "if (!(*w & m)) { *w |= m; s->m_len += 1; } " &
      "s->m_vals[k - " & lo & "] = x; }"
    g.put "static " & v & " " & n & "_get(" & n & " *s, int64_t k, " & v &
      " fb) { return " & n & "_contains(s, k) ? s->m_vals[k - " & lo &
      "] : fb; }"
    g.put "static void " & n & "_remove(" & n & " *s, int64_t k) { " &
      "if (k < " & lo & " || k > " & hi & ") return; " &
      "uint64_t *w = &s->m_bits[(k - " & lo & ") >> 6]; " &
      "uint64_t m = 1ULL << ((k - " & lo & ") & 63); " &
      "if (*w & m) { *w &= ~m; s->m_len -= 1; " &
      "memset(&s->m_vals[k - " & lo & "], 0, sizeof(" & v & ")); } }"
    g.put "static void " & n & "_clear(" & n &
      " *s) { memset(s, 0, sizeof(*s)); }"
  of SparseMapType:
    g.emitTypeDefs(t.elem)
    g.emitTypeDefs(t.val)
    let key = mangle(t)
    if key in g.emitted:
      return
    g.emitted.incl key
    let n = "NS_" & key
    let cap = $t.len & "LL"
    let kt = cBase(t.elem)
    let v = cBase(t.val)
    g.put ""
    g.put "typedef struct {"
    g.put "  int64_t m_len;"
    g.put "  " & kt & " m_keys[" & $t.len & "];"
    g.put "  " & v & " m_vals[" & $t.len & "];"
    g.put "} " & n & ";"
    if t.elem.kind == StringType:
      g.put "static int " & n & "_cmp(" & kt & " a, " & kt & " b) { " &
        "size_t na = (size_t)a.m_len, nb = (size_t)b.m_len; " &
        "int c = memcmp(a.m_data, b.m_data, na < nb ? na : nb); " &
        "if (c) return c; return (a.m_len > b.m_len) - (a.m_len < b.m_len); }"
      g.put "static int64_t " & n & "_find(" & n & " *s, " & kt & " k) { " &
        "int64_t lo = 0, hi = s->m_len - 1; while (lo <= hi) { " &
        "int64_t mid = (lo + hi) / 2; int c = " & n &
        "_cmp(s->m_keys[mid], k); if (c == 0) return mid; " &
        "if (c < 0) lo = mid + 1; else hi = mid - 1; } return -(lo + 1); }"
    else:
      g.put "static int64_t " & n & "_find(" & n & " *s, " & kt & " k) { " &
        "int64_t lo = 0, hi = s->m_len - 1; while (lo <= hi) { " &
        "int64_t mid = (lo + hi) / 2; if (s->m_keys[mid] == k) return mid; " &
        "if (s->m_keys[mid] < k) lo = mid + 1; else hi = mid - 1; } " &
        "return -(lo + 1); }"
    g.put "static bool " & n & "_contains(" & n & " *s, " & kt &
      " k) { return " & n & "_find(s, k) >= 0; }"
    g.put "static bool " & n & "_put(" & n & " *s, " & kt & " k, " & v &
      " x) { int64_t i = " & n & "_find(s, k); " &
      "if (i >= 0) { s->m_vals[i] = x; return true; } " &
      "if (s->m_len >= " & cap & ") return false; int64_t p = -i - 1; " &
      "memmove(&s->m_keys[p + 1], &s->m_keys[p], " &
      "(size_t)((s->m_len - p) * (int64_t)sizeof(" & kt & "))); " &
      "memmove(&s->m_vals[p + 1], &s->m_vals[p], " &
      "(size_t)((s->m_len - p) * (int64_t)sizeof(" & v & "))); " &
      "s->m_keys[p] = k; s->m_vals[p] = x; s->m_len += 1; return true; }"
    g.put "static " & v & " " & n & "_get(" & n & " *s, " & kt & " k, " & v &
      " fb) { int64_t i = " & n & "_find(s, k); " &
      "return i >= 0 ? s->m_vals[i] : fb; }"
    g.put "static " & v & " " & n & "_at(" & n & " *s, " & kt &
      " k) { return s->m_vals[" & n & "_find(s, k)]; }"
    g.put "static void " & n & "_remove(" & n & " *s, " & kt & " k) { " &
      "int64_t i = " & n & "_find(s, k); if (i < 0) return; " &
      "memmove(&s->m_keys[i], &s->m_keys[i + 1], " &
      "(size_t)((s->m_len - i - 1) * (int64_t)sizeof(" & kt & "))); " &
      "memmove(&s->m_vals[i], &s->m_vals[i + 1], " &
      "(size_t)((s->m_len - i - 1) * (int64_t)sizeof(" & v & "))); " &
      "s->m_len -= 1; memset(&s->m_keys[s->m_len], 0, sizeof(" & kt &
      ")); memset(&s->m_vals[s->m_len], 0, sizeof(" & v & ")); }"
    g.put "static void " & n & "_clear(" & n &
      " *s) { memset(s, 0, sizeof(*s)); }"
  of SetType:
    let key = mangle(t)
    if key in g.emitted:
      return
    g.emitted.incl key
    let n = "NS_" & key
    let lo = $t.elem.rlo & "LL"
    let hi = $t.elem.rhi & "LL"
    let words = (t.setSize + 63) div 64
    g.put ""
    g.put "typedef struct {"
    g.put "  int64_t m_len;"
    g.put "  uint64_t m_bits[" & $words & "];"
    g.put "} " & n & ";"
    g.put "static void " & n & "_incl(" & n & " *s, int64_t v) { " &
      "uint64_t *w = &s->m_bits[(v - " & lo & ") >> 6]; " &
      "uint64_t m = 1ULL << ((v - " & lo & ") & 63); " &
      "if (!(*w & m)) { *w |= m; s->m_len += 1; } }"
    g.put "static void " & n & "_excl(" & n & " *s, int64_t v) { " &
      "uint64_t *w = &s->m_bits[(v - " & lo & ") >> 6]; " &
      "uint64_t m = 1ULL << ((v - " & lo & ") & 63); " &
      "if (*w & m) { *w &= ~m; s->m_len -= 1; } }"
    g.put "static bool " & n & "_contains(" & n & " *s, int64_t v) { " &
      "if (v < " & lo & " || v > " & hi & ") return false; " &
      "return (s->m_bits[(v - " & lo & ") >> 6] >> ((v - " & lo &
      ") & 63)) & 1; }"
    g.put "static void " & n & "_clear(" & n &
      " *s) { memset(s, 0, sizeof(*s)); }"
  else:
    discard

proc emitBodyTypeDefs(g: var Gen, body: seq[Stmt]) =
  for s in body:
    if s.kind in {VarStmt, LetStmt, ForEachStmt}:
      g.emitTypeDefs(s.typ)
    g.emitBodyTypeDefs(s.body)
    for br in s.elifs:
      g.emitBodyTypeDefs(br.body)
    g.emitBodyTypeDefs(s.elseBody)

proc generate*(m: Module, src: string): string =
  ## Generate the complete C translation unit for a checked module.
  var g = Gen(src: src)
  for r in m.routines:
    g.routines[r.name] = r
  # Arena analysis: big locals leave the C stack for per-thread arenas,
  # sized by the same call-DAG walk the report uses. One bump pointer
  # per thread; constant offsets; overflow impossible by sizing.
  for r in m.routines:
    var offs: Table[string, int64]
    var off = 0'i64
    collectBig(r.body, offs, off)
    g.bigOffs[r.name] = offs
    g.frameOf[r.name] = (off + 15) div 16 * 16
    var callees: HashSet[string]
    collectCallees(r.body, callees)
    var worst = 0'i64
    for c2 in callees:
      if c2 in g.needOf and g.needOf[c2] > worst:
        worst = g.needOf[c2]
    g.needOf[r.name] = g.frameOf[r.name] + worst
  var anyArena = false
  for r in m.routines:
    if r.kind == ThreadRoutine and g.needOf[r.name] > 0:
      anyArena = true
  g.put "// Generated by nifty from " & src & ". Do not edit."
  g.o.add cPrelude
  if anyArena:
    g.put "static _Thread_local uint8_t *ni_sp;"
  for td in m.types:
    g.emitTypeDefs(td.typ)
  for gd in m.globals:
    g.emitTypeDefs(gd.typ)
  for r in m.routines:
    for pm in r.params:
      g.emitTypeDefs(pm.typ)
    g.emitTypeDefs(r.ret)
    g.emitBodyTypeDefs(r.body)
  if m.consts.len > 0:
    g.put ""
    for cd in m.consts:
      g.put "static const int64_t C_" & cd.name & " = " & $cd.value & "LL;"
  if m.globals.len > 0:
    g.put ""
    for gd in m.globals:
      if gd.typ.kind == LockType:
        g.put "static pthread_mutex_t g_" & gd.name & " = PTHREAD_MUTEX_INITIALIZER;"
      else:
        g.put "static " & cDecl("g_" & gd.name, gd.typ) & ";"
  if anyArena:
    g.put ""
    for r in m.routines:
      if r.kind == ThreadRoutine and g.needOf[r.name] > 0:
        g.put "static _Alignas(16) uint8_t ni_arena_" & r.name & "[" &
          $g.needOf[r.name] & "];"
  for r in m.routines:
    g.curArena = g.bigOffs[r.name]
    g.curFrame = g.frameOf[r.name]
    g.curRet = (if r.kind == ThreadRoutine: nil else: r.ret)
    g.put ""
    if r.kind == ThreadRoutine:
      g.put "static void *t_" & r.name & "(void *ni_arg) {"
      inc g.ind
      g.put "(void)ni_arg;"
      if g.needOf[r.name] > 0:
        g.put "ni_sp = ni_arena_" & r.name & ";"
      if g.curFrame > 0:
        g.put "uint8_t *ni_base = ni_sp;"
        g.put "ni_sp += " & $g.curFrame & "LL;"
      for s in r.body:
        g.genStmt(s)
      if g.curFrame > 0:
        g.put "ni_sp = ni_base;"
      g.put "return NULL;"
      dec g.ind
      g.put "}"
    else:
      var ps: seq[string]
      for pm in r.params:
        if pm.isVar and pm.typ.passByPtr:
          ps.add cBase(pm.typ) & " *p_" & pm.name
        elif pm.typ.kind == ArrayType:
          # Non-var arrays decay to pointers in C; const makes the C
          # compiler enforce read-only as a second line of defense.
          ps.add "const " & cDecl("p_" & pm.name, pm.typ)
        else:
          ps.add cDecl("p_" & pm.name, pm.typ)
      if bigRet(r.ret):
        if r.ret.kind == ArrayType:
          var base = r.ret
          var dims = ""
          while base.kind == ArrayType:
            dims.add "[" & $base.len & "]"
            base = base.elem
          ps.add cBase(base) & " (*ni_ret)" & dims
        else:
          ps.add cBase(r.ret) & " *ni_ret"
      let ret = if r.ret.isNil or bigRet(r.ret): "void" else: cBase(r.ret)
      g.put "static " & ret & " f_" & r.name & "(" &
        (if ps.len == 0: "void" else: ps.join(", ")) & ") {"
      inc g.ind
      if g.curFrame > 0:
        g.put "uint8_t *ni_base = ni_sp;"
        g.put "ni_sp += " & $g.curFrame & "LL;"
      for s in r.body:
        g.genStmt(s)
      if g.curFrame > 0 and r.ret.isNil:
        g.put "ni_sp = ni_base;" # fall-off-the-end exit for void procs
      dec g.ind
      g.put "}"
  let threads = m.routines.filterIt(it.kind == ThreadRoutine)
  g.put ""
  g.put "int main(void) {"
  inc g.ind
  g.put "pthread_t ni_threads[" & $threads.len & "];"
  for i, t in threads:
    g.put "if (pthread_create(&ni_threads[" & $i & "], NULL, t_" & t.name &
      ", NULL) != 0) { fprintf(stderr, \"nifty: failed to start thread " &
      t.name & "\\n\"); return 1; }"
  for i, t in threads:
    g.put "pthread_join(ni_threads[" & $i & "], NULL);"
  g.put "return 0;"
  dec g.ind
  g.put "}"
  g.o

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
  case t.kind
  of tyInt: "i"
  of tyBool: "b"
  of tyArray: "a" & $t.len & "_" & mangle(t.elem)
  of tySeq: "q" & $t.len & "_" & mangle(t.elem)
  of tyStr: "s" & $t.len
  of tySet: "t" & mangleNum(t.elem.rlo) & "_" & mangleNum(t.elem.rhi)
  of tyQueue: "u" & $t.len & "_" & mangle(t.elem)
  of tyObject: "o" & t.name
  else: "x"

proc cBase(t: Typ): string =
  case t.kind
  of tyBool: "bool"
  of tyObject: "S_" & t.name
  of tySeq, tyStr, tySet, tyQueue: "NS_" & mangle(t)
  else: "int64_t"

proc cDecl(name: string, t: Typ): string =
  var base = t
  var dims = ""
  while base.kind == tyArray:
    dims.add "[" & $base.len & "]"
    base = base.elem
  cBase(base) & " " & name & dims

proc passByPtr(t: Typ): bool =
  ## var parameters pass by pointer, except arrays which already decay.
  t.kind != tyArray

proc genExpr(g: var Gen, e: Expr): string =
  case e.kind
  of ekInt:
    $e.ival & "LL"
  of ekBool:
    if e.bval: "true" else: "false"
  of ekStr:
    if e.typ != nil and e.typ.kind == tyStr:
      "(" & cBase(e.typ) & "){ .m_len = " & $e.sval.len & "LL, .m_data = " &
        cQuote(e.sval) & " }"
    else:
      cQuote(e.sval)
  of ekIdent:
    case e.symKind
    of syConst: "C_" & e.sval
    of syGlobal: "g_" & e.sval
    of syLocal: "v_" & e.sval
    of syParam:
      if e.isVarParam and e.typ.passByPtr:
        "(*p_" & e.sval & ")"
      else:
        "p_" & e.sval
  of ekNeg:
    "(-" & g.genExpr(e.kids[0]) & ")"
  of ekNot:
    "(!" & g.genExpr(e.kids[0]) & ")"
  of ekBin:
    let a = g.genExpr(e.kids[0])
    let b = g.genExpr(e.kids[1])
    case e.sval
    # / and % are proven safe by the checker; no runtime check needed.
    of "and": "(" & a & " && " & b & ")"
    of "or": "(" & a & " || " & b & ")"
    else: "(" & a & " " & e.sval & " " & b & ")"
  of ekIndex:
    # The checker proved the index is in bounds; no runtime check needed.
    if e.kids[0].typ != nil and e.kids[0].typ.kind in {tySeq, tyStr}:
      g.genExpr(e.kids[0]) & ".m_data[" & g.genExpr(e.kids[1]) & "]"
    else:
      g.genExpr(e.kids[0]) & "[" & g.genExpr(e.kids[1]) & "]"
  of ekCall:
    let r = g.routines[e.sval]
    var parts: seq[string]
    for i, a in e.kids:
      if r.params[i].isVar and r.params[i].typ.passByPtr:
        parts.add "&" & g.genExpr(a)
      else:
        parts.add g.genExpr(a)
    "f_" & e.sval & "(" & parts.join(", ") & ")"
  of ekField:
    if e.kids[0].typ != nil and
        e.kids[0].typ.kind in {tySeq, tyStr, tySet, tyQueue}:
      g.genExpr(e.kids[0]) & ".m_len"
    else:
      g.genExpr(e.kids[0]) & ".m_" & e.sval
  of ekMethod:
    let bt = e.kids[0].typ
    let fn = cBase(bt) & "_" & (if bt.kind == tyStr and e.sval == "add": "adds"
      else: e.sval)
    let basePtr = "&" & g.genExpr(e.kids[0])
    if bt.kind == tyStr and e.sval == "add":
      let a = e.kids[1]
      if a.kind == ekStr and (a.typ == nil or a.typ.kind != tyStr):
        fn & "(" & basePtr & ", (const uint8_t *)" & cQuote(a.sval) & ", " &
          $a.sval.len & "LL)"
      else:
        # The argument is a path-like string value; safe to mention twice.
        let av = g.genExpr(a)
        fn & "(" & basePtr & ", " & av & ".m_data, " & av & ".m_len)"
    elif e.kids.len > 1:
      fn & "(" & basePtr & ", " & g.genExpr(e.kids[1]) & ")"
    else:
      fn & "(" & basePtr & ")"

proc hasEffects(g: Gen, e: Expr): bool =
  ## Does evaluating this expression run a proc or mutate a container?
  ## (func calls are pure and echo-free by construction.)
  if e.isNil:
    return false
  if e.kind == ekCall and e.sval in g.routines and
      g.routines[e.sval].kind == rkProc:
    return true
  if e.kind == ekMethod and e.sval in mutMethods:
    return true
  for k in e.kids:
    if g.hasEffects(k):
      return true

proc genOrdered(g: var Gen, e: Expr): string

proc genPathOrdered(g: var Gen, e: Expr): string =
  ## An lvalue path with its index expressions hoisted in source order.
  case e.kind
  of ekField:
    g.genPathOrdered(e.kids[0]) & ".m_" & e.sval
  of ekIndex:
    let base = g.genPathOrdered(e.kids[0])
    let idx = g.genOrdered(e.kids[1])
    if e.kids[0].typ != nil and e.kids[0].typ.kind in {tySeq, tyStr}:
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
    elif e.typ.kind == tyBool: "bool"
    elif e.typ.kind in {tyObject, tySeq, tyStr, tySet, tyQueue}: cBase(e.typ)
    else: "int64_t"
  g.put ctype & " " & t & " = " & val & ";"
  t

proc genOrdered(g: var Gen, e: Expr): string =
  ## Emit the expression with strict left-to-right evaluation, effects
  ## included: effectful nodes become their own C statements, and every
  ## read is captured at the moment the program text reaches it, so C's
  ## unspecified subexpression order can never be observed.
  case e.kind
  of ekInt, ekBool, ekStr:
    g.genExpr(e)
  of ekIdent:
    if e.typ != nil and e.typ.kind == tyArray:
      g.genExpr(e) # arrays are reference-like; the path is the value
    else:
      g.tempFor(e, g.genExpr(e))
  of ekField:
    if e.typ != nil and e.typ.kind == tyArray:
      g.genPathOrdered(e)
    elif e.kids[0].typ != nil and
        e.kids[0].typ.kind in {tySeq, tyStr, tySet, tyQueue}:
      g.tempFor(e, g.genPathOrdered(e.kids[0]) & ".m_len")
    else:
      g.tempFor(e, g.genPathOrdered(e))
  of ekIndex:
    if e.typ != nil and e.typ.kind == tyArray:
      g.genPathOrdered(e)
    else:
      g.tempFor(e, g.genPathOrdered(e))
  of ekNeg:
    "(-" & g.genOrdered(e.kids[0]) & ")"
  of ekNot:
    "(!" & g.genOrdered(e.kids[0]) & ")"
  of ekBin:
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
  of ekCall:
    let r = g.routines[e.sval]
    var parts: seq[string]
    for i, a in e.kids:
      if r.params[i].isVar and r.params[i].typ.passByPtr:
        parts.add "&" & g.genPathOrdered(a)
      elif a.typ != nil and a.typ.kind == tyArray:
        parts.add g.genPathOrdered(a)
      else:
        parts.add g.genOrdered(a)
    let call = "f_" & e.sval & "(" & parts.join(", ") & ")"
    if r.kind == rkFunc:
      call # pure: args are already ordered, the call itself has no effects
    elif r.ret.isNil:
      g.put call & ";"
      ""
    else:
      g.tempFor(e, call)
  of ekMethod:
    let bt = e.kids[0].typ
    let base = g.genPathOrdered(e.kids[0])
    let fn = cBase(bt) & "_" &
      (if bt.kind == tyStr and e.sval == "add": "adds" else: e.sval)
    var call: string
    if bt.kind == tyStr and e.sval == "add":
      let a = e.kids[1]
      if a.kind == ekStr and (a.typ == nil or a.typ.kind != tyStr):
        call = fn & "(&" & base & ", (const uint8_t *)" & cQuote(a.sval) &
          ", " & $a.sval.len & "LL)"
      else:
        let av = g.genPathOrdered(a)
        call = fn & "(&" & base & ", " & av & ".m_data, " & av & ".m_len)"
    elif e.kids.len > 1:
      call = fn & "(&" & base & ", " & g.genOrdered(e.kids[1]) & ")"
    else:
      call = fn & "(&" & base & ")"
    if e.typ.isNil:
      g.put call & ";"
      ""
    else:
      g.tempFor(e, call)

proc genCond(g: var Gen, e: Expr): string =
  ## A condition wrapped in exactly one set of parentheses.
  let s = g.genExpr(e)
  if e.kind in {ekBin, ekNot, ekNeg}: s
  else: "(" & s & ")"

proc genStmt(g: var Gen, s: Stmt)

proc genBlock(g: var Gen, body: seq[Stmt]) =
  inc g.ind
  for s in body:
    g.genStmt(s)
  dec g.ind

proc genStmt(g: var Gen, s: Stmt) =
  case s.kind
  of skVar, skLet:
    let init =
      if s.init != nil and g.hasEffects(s.init): g.genOrdered(s.init)
      elif s.init != nil: g.genExpr(s.init)
      elif s.typ.kind in {tyArray, tyObject, tySeq, tyStr, tySet, tyQueue}: "{0}"
      elif s.typ.kind == tyBool: "false"
      else: "0"
    g.put cDecl("v_" & s.name, s.typ) & " = " & init & ";"
  of skAssign:
    if g.hasEffects(s.lhs) or g.hasEffects(s.rhs):
      # Left-to-right, as written: target indexes first, then the value.
      let lhs = g.genPathOrdered(s.lhs)
      let rhs = g.genOrdered(s.rhs)
      g.put lhs & " = " & rhs & ";"
    else:
      g.put g.genExpr(s.lhs) & " = " & g.genExpr(s.rhs) & ";"
  of skIf:
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
  of skWhile:
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
  of skFor:
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
  of skLoop:
    g.put "for (;;) {"
    g.genBlock(s.body)
    g.put "}"
  of skWith:
    if s.typ.kind == tyLock:
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
  of skReturn:
    if s.value.isNil:
      g.put "return;"
    elif g.hasEffects(s.value):
      g.put "return " & g.genOrdered(s.value) & ";"
    else:
      g.put "return " & g.genExpr(s.value) & ";"
  of skBreak:
    g.put "break;"
  of skEcho:
    # Every value argument is hoisted to a temp, in order: C leaves printf
    # argument evaluation order unspecified, nifty does not.
    var temps: Table[int, string]
    for i, a in s.args:
      if a.typ.kind != tyString:
        temps[i] = "ni_e" & $g.tmpN
        inc g.tmpN
    if temps.len > 0:
      g.put "{"
      inc g.ind
      for i, a in s.args:
        if i in temps:
          let ctype =
            case a.typ.kind
            of tyBool: "bool"
            of tyStr: cBase(a.typ)
            else: "int64_t"
          let v =
            if g.hasEffects(a): g.genOrdered(a) else: g.genExpr(a)
          g.put ctype & " " & temps[i] & " = " & v & ";"
    var fmt = ""
    var cargs: seq[string]
    for i, a in s.args:
      case a.typ.kind
      of tyString:
        fmt.add a.sval.replace("%", "%%")
      of tyStr:
        fmt.add "%.*s"
        cargs.add "(int)(" & temps[i] & ".m_len)"
        cargs.add "(const char *)" & temps[i] & ".m_data"
      of tyInt:
        fmt.add "%lld"
        cargs.add "(long long)(" & temps[i] & ")"
      of tyBool:
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
  of skForEach:
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
    if s.value.typ.kind == tySet:
      let lo = $s.value.typ.elem.rlo & "LL"
      let hi = $s.value.typ.elem.rhi & "LL"
      g.put "for (int64_t " & ix & " = " & lo & "; " & ix & " <= " & hi &
        "; ++" & ix & ") {"
      inc g.ind
      g.put "if (!" & cBase(s.value.typ) & "_contains(" & it & ", " & ix &
        ")) continue;"
      g.put cBase(s.typ) & " v_" & s.name & " = " & ix & ";"
    elif s.value.typ.kind == tyQueue:
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
  of skDiscard:
    if g.hasEffects(s.value):
      let v = g.genOrdered(s.value)
      if v.len > 0:
        g.put "(void)(" & v & ");"
    else:
      g.put "(void)(" & g.genExpr(s.value) & ");"
  of skCall:
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
  case t.kind
  of tyArray:
    g.emitTypeDefs(t.elem)
  of tyObject:
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
  of tySeq:
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
  of tyStr:
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
  of tyQueue:
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
  of tySet:
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
    if s.kind in {skVar, skLet, skForEach}:
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
  g.put "// Generated by nifty from " & src & ". Do not edit."
  g.o.add cPrelude
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
      if gd.typ.kind == tyLock:
        g.put "static pthread_mutex_t g_" & gd.name & " = PTHREAD_MUTEX_INITIALIZER;"
      else:
        g.put "static " & cDecl("g_" & gd.name, gd.typ) & ";"
  for r in m.routines:
    g.put ""
    if r.kind == rkThread:
      g.put "static void *t_" & r.name & "(void *ni_arg) {"
      inc g.ind
      g.put "(void)ni_arg;"
      for s in r.body:
        g.genStmt(s)
      g.put "return NULL;"
      dec g.ind
      g.put "}"
    else:
      var ps: seq[string]
      for pm in r.params:
        if pm.isVar and pm.typ.passByPtr:
          ps.add cBase(pm.typ) & " *p_" & pm.name
        elif pm.typ.kind == tyArray:
          # Non-var arrays decay to pointers in C; const makes the C
          # compiler enforce read-only as a second line of defense.
          ps.add "const " & cDecl("p_" & pm.name, pm.typ)
        else:
          ps.add cDecl("p_" & pm.name, pm.typ)
      let ret = if r.ret.isNil: "void" else: cBase(r.ret)
      g.put "static " & ret & " f_" & r.name & "(" &
        (if ps.len == 0: "void" else: ps.join(", ")) & ") {"
      inc g.ind
      for s in r.body:
        g.genStmt(s)
      dec g.ind
      g.put "}"
  let threads = m.routines.filterIt(it.kind == rkThread)
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

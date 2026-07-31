## C code generation: checked Module -> one C99 + pthreads translation unit.
## Because nifty enforces declare-before-use, the generated C needs no
## forward prototypes: definitions appear in call order.

import std/[strutils, tables, sequtils]
import types

type
  Gen = object
    o: string
    ind: int
    tmpN: int
    src: string
    routines: Table[string, Routine]

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

proc cBase(t: Typ): string =
  case t.kind
  of tyBool: "bool"
  of tyObject: "S_" & t.name
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
    g.genExpr(e.kids[0]) & ".m_" & e.sval

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
      if s.init != nil: g.genExpr(s.init)
      elif s.typ.kind in {tyArray, tyObject}: "{0}"
      elif s.typ.kind == tyBool: "false"
      else: "0"
    g.put cDecl("v_" & s.name, s.typ) & " = " & init & ";"
  of skAssign:
    g.put g.genExpr(s.lhs) & " = " & g.genExpr(s.rhs) & ";"
  of skIf:
    for i, br in s.elifs:
      g.put (if i == 0: "if (" else: "} else if (") & g.genExpr(br.cond) & ") {"
      g.genBlock(br.body)
    if s.elseBody.len > 0:
      g.put "} else {"
      g.genBlock(s.elseBody)
    g.put "}"
  of skWhile:
    g.put "while (" & g.genExpr(s.cond) & ") {"
    g.genBlock(s.body)
    g.put "}"
  of skFor:
    let tmp = "ni_end" & $g.tmpN
    inc g.tmpN
    g.put "{"
    inc g.ind
    g.put "int64_t v_" & s.name & " = " & g.genExpr(s.lo) & ";"
    g.put "const int64_t " & tmp & " = " & g.genExpr(s.hi) & ";"
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
    else:
      g.put "return " & g.genExpr(s.value) & ";"
  of skBreak:
    g.put "break;"
  of skEcho:
    var fmt = ""
    var cargs: seq[string]
    for a in s.args:
      case a.typ.kind
      of tyString:
        fmt.add a.sval.replace("%", "%%")
      of tyInt:
        fmt.add "%lld"
        cargs.add "(long long)(" & g.genExpr(a) & ")"
      of tyBool:
        fmt.add "%s"
        cargs.add "((" & g.genExpr(a) & ") ? \"true\" : \"false\")"
      else:
        discard
    fmt.add "\n"
    var call = "printf(" & cQuote(fmt)
    for x in cargs:
      call.add ", " & x
    call.add ");"
    g.put call
  of skDiscard:
    g.put "(void)(" & g.genExpr(s.value) & ");"
  of skCall:
    g.put g.genExpr(s.value) & ";"

const cPrelude = """
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
"""

proc generate*(m: Module, src: string): string =
  ## Generate the complete C translation unit for a checked module.
  var g = Gen(src: src)
  for r in m.routines:
    g.routines[r.name] = r
  g.put "// Generated by nifty from " & src & ". Do not edit."
  g.o.add cPrelude
  for td in m.types:
    g.put ""
    g.put "typedef struct {"
    for f in td.typ.fields:
      g.put "  " & cDecl("m_" & f.name, f.typ) & ";"
    g.put "} S_" & td.name & ";"
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

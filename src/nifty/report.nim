## Static resource report. Three numbers per program, all derived at
## compile time from properties the checker already proved:
## - RAM: the globals ARE the heap, so their sizes sum exactly.
## - Stack: no recursion means the call graph is a DAG; worst-case depth
##   per thread is the deepest chain of frames (a language-level
##   estimate: locals + params + fixed frame overhead).
## - Ops: every loop has a proven trip bound, so each thread has a
##   worst-case abstract operation count per pass of its outer loop.

import std/[strutils, tables, sets]
import types

const frameOverhead = 16'i64 # return address + saved frame pointer

proc sat(a: int64): int64 =
  if a < 0: high(int64) else: a

proc sadd(a, b: int64): int64 =
  if a > high(int64) - b: high(int64) else: a + b

proc smul(a, b: int64): int64 =
  if a != 0 and b > high(int64) div a: high(int64) else: a * b

# --- sizes (C layout: alignment and padding) ------------------------------

proc typeAlign(t: Typ): int64 =
  case t.kind
  of tyBool:
    result = 1
  of tyArray:
    result = typeAlign(t.elem)
  of tyObject:
    result = 1
    for f in t.fields:
      result = max(result, typeAlign(f.typ))
  else:
    result = 8 # int, seq/string (int64 length field first), Lock

proc typeSize(t: Typ): int64 =
  case t.kind
  of tyBool: 1
  of tyInt: 8
  of tyArray: smul(t.len, typeSize(t.elem))
  of tySeq:
    # int64 length + data, padded to 8.
    let data = smul(t.len, typeSize(t.elem))
    (sadd(8, data) + 7) div 8 * 8
  of tyStr:
    # int64 length + one byte per capacity, padded to 8.
    (sadd(8, t.len) + 7) div 8 * 8
  of tyObject:
    var off = 0'i64
    for f in t.fields:
      let a = typeAlign(f.typ)
      off = (off + a - 1) div a * a
      off = sadd(off, typeSize(f.typ))
    let a = typeAlign(t)
    (off + a - 1) div a * a
  else: 0 # Lock: platform-sized, reported separately

# --- worst-case ops -------------------------------------------------------

proc exprOps(e: Expr, costs: Table[string, int64]): int64 =
  if e.isNil:
    return 0
  result = 1
  if e.kind == ekCall:
    result = sadd(result, costs.getOrDefault(e.sval, 0))
  for k in e.kids:
    result = sadd(result, exprOps(k, costs))

proc bodyOps(body: seq[Stmt], costs: Table[string, int64]): int64

proc stmtOps(s: Stmt, costs: Table[string, int64]): int64 =
  result = 1
  for e in [s.init, s.lhs, s.rhs, s.value]:
    result = sadd(result, exprOps(e, costs))
  for a in s.args:
    result = sadd(result, exprOps(a, costs))
  case s.kind
  of skIf:
    var worst = bodyOps(s.elseBody, costs)
    for br in s.elifs:
      result = sadd(result, exprOps(br.cond, costs))
      worst = max(worst, bodyOps(br.body, costs))
    result = sadd(result, worst)
  of skWhile:
    let once = sadd(bodyOps(s.body, costs), exprOps(s.cond, costs))
    result = sadd(result, sadd(smul(sat(s.tripBound), once),
      exprOps(s.cond, costs)))
  of skFor:
    result = sadd(result, sadd(exprOps(s.lo, costs), exprOps(s.hi, costs)))
    result = sadd(result, smul(sat(s.tripBound),
      sadd(bodyOps(s.body, costs), 1)))
  of skForEach:
    result = sadd(result, smul(sat(s.tripBound),
      sadd(bodyOps(s.body, costs), 1)))
  of skWith:
    # Lock/unlock (or start/end) plus the body.
    result = sadd(result, 2)
    result = sadd(result, sadd(costs.getOrDefault("start", 0),
      costs.getOrDefault("end", 0)))
    result = sadd(result, bodyOps(s.body, costs))
  of skLoop:
    result = sadd(result, bodyOps(s.body, costs))
  else:
    result = sadd(result, bodyOps(s.body, costs))

proc bodyOps(body: seq[Stmt], costs: Table[string, int64]): int64 =
  for s in body:
    result = sadd(result, stmtOps(s, costs))

# --- worst-case stack -----------------------------------------------------

proc paramBytes(p: Param): int64 =
  if p.isVar or p.typ.kind == tyArray:
    8 # passed as a pointer
  else:
    typeSize(p.typ)

proc localBytes(body: seq[Stmt]): int64 =
  for s in body:
    if s.kind in {skVar, skLet}:
      result = sadd(result, typeSize(s.typ))
    if s.kind == skFor:
      result = sadd(result, 8)
    if s.kind == skForEach:
      result = sadd(result, sadd(typeSize(s.typ), 16)) # elem + iterator
    result = sadd(result, localBytes(s.body))
    for br in s.elifs:
      result = sadd(result, localBytes(br.body))
    result = sadd(result, localBytes(s.elseBody))

proc collectCallsExpr(e: Expr, into: var HashSet[string]) =
  if e.isNil:
    return
  if e.kind == ekCall:
    into.incl e.sval
  for k in e.kids:
    collectCallsExpr(k, into)

proc collectCalls(body: seq[Stmt], globals: Table[string, Typ],
    into: var HashSet[string]) =
  for s in body:
    for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
      collectCallsExpr(e, into)
    for a in s.args:
      collectCallsExpr(a, into)
    if s.kind == skWith and
        not (s.name in globals and globals[s.name].kind == tyLock):
      into.incl "start"
      into.incl "end"
    collectCalls(s.body, globals, into)
    for br in s.elifs:
      collectCallsExpr(br.cond, into)
      collectCalls(br.body, globals, into)
    collectCalls(s.elseBody, globals, into)

# --- the report -----------------------------------------------------------

proc buildReport*(m: Module, src: string): string =
  var globals: Table[string, Typ]
  for gd in m.globals:
    globals[gd.name] = gd.typ

  var lines: seq[string]
  lines.add "nifty report: " & src

  # Globals: the whole heap, one line each.
  lines.add ""
  lines.add "globals:"
  var total = 0'i64
  var locks = 0
  for gd in m.globals:
    if gd.typ.kind == tyLock:
      inc locks
      continue
    let size = typeSize(gd.typ)
    total = sadd(total, size)
    lines.add "  " & gd.name & ": " & $size & " bytes (" & $gd.typ & ")"
  var totalLine = "  total: " & $total & " bytes"
  if locks > 0:
    totalLine.add " + " & $locks & " lock" & (if locks > 1: "s" else: "") &
      " (platform-sized)"
  lines.add totalLine

  # Per-routine cost and frame tables, in declaration order (callees
  # first, so a single pass suffices - declare-before-use is a topological
  # sort of the call DAG).
  var costs: Table[string, int64]
  var frames: Table[string, int64]
  var deepest: Table[string, tuple[bytes: int64, chain: string]]
  for r in m.routines:
    costs[r.name] = bodyOps(r.body, costs)
    frames[r.name] = sadd(frameOverhead,
      sadd(localBytes(r.body), block:
        var pb = 0'i64
        for p in r.params:
          pb = sadd(pb, paramBytes(p))
        pb))
    var calls: HashSet[string]
    collectCalls(r.body, globals, calls)
    var best = (bytes: 0'i64, chain: "")
    for callee in calls:
      if callee in deepest:
        let d = deepest[callee]
        if d.bytes > best.bytes:
          best = d
    deepest[r.name] = (bytes: sadd(frames[r.name], best.bytes),
      chain: r.name & (if best.chain.len > 0: " -> " & best.chain else: ""))

  lines.add ""
  lines.add "stack, worst case per thread (estimate: locals + params + " &
    $frameOverhead & " bytes/frame):"
  for r in m.routines:
    if r.kind != rkThread:
      continue
    let d = deepest[r.name]
    lines.add "  " & r.name & ": " & $d.bytes & " bytes (" & d.chain & ")"

  # Ops: for a thread with top-level loops, report the cost of one pass
  # of each loop plus everything outside them; otherwise the total.
  lines.add ""
  lines.add "worst-case abstract ops per thread:"
  for r in m.routines:
    if r.kind != rkThread:
      continue
    var outside = 0'i64
    var passes: seq[int64]
    for s in r.body:
      if s.kind == skLoop:
        passes.add bodyOps(s.body, costs)
      else:
        outside = sadd(outside, stmtOps(s, costs))
    if passes.len == 0:
      lines.add "  " & r.name & ": " & $outside & " ops total"
    else:
      var line = "  " & r.name & ": " & $outside & " ops outside the loop"
      for i, p in passes:
        line.add ", " & $p & " ops per loop pass"
      lines.add line

  lines.join("\n") & "\n"

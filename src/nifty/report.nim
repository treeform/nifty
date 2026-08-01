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

## Sizes (C Layout)

## Worst-Case Ops

proc log2Ceil(n: int64): int64 =
  result = 1
  var v = 1'i64
  while v < n:
    v = v * 2
    inc result

proc exprOps(e: Expr, costs: Table[string, int64]): int64 =
  if e.isNil:
    return 0
  result = 1
  if e.kind == CallExpr:
    result = sadd(result, costs.getOrDefault(e.sval, 0))
  if e.kind == MethodExpr and e.kids[0].typ != nil:
    let bt = e.kids[0].typ
    if bt.kind == SparseMapType:
      # Sorted entries: searches are log-bounded, writes shift.
      if e.sval in ["contains", "get"]:
        result = sadd(result, log2Ceil(bt.len))
      elif e.sval in ["put", "remove"]:
        result = sadd(result, bt.len)
    elif bt.kind == StringType and e.sval == "add":
      result = sadd(result, bt.len)
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
  of IfStmt:
    var worst = bodyOps(s.elseBody, costs)
    for br in s.elifs:
      result = sadd(result, exprOps(br.cond, costs))
      worst = max(worst, bodyOps(br.body, costs))
    result = sadd(result, worst)
  of WhileStmt:
    let once = sadd(bodyOps(s.body, costs), exprOps(s.cond, costs))
    result = sadd(result, sadd(smul(sat(s.tripBound), once),
      exprOps(s.cond, costs)))
  of ForStmt:
    result = sadd(result, sadd(exprOps(s.lo, costs), exprOps(s.hi, costs)))
    result = sadd(result, smul(sat(s.tripBound),
      sadd(bodyOps(s.body, costs), 1)))
  of ForEachStmt:
    result = sadd(result, smul(sat(s.tripBound),
      sadd(bodyOps(s.body, costs), 1)))
  of WithStmt:
    # Lock/unlock (or start/end) plus the body.
    result = sadd(result, 2)
    result = sadd(result, sadd(costs.getOrDefault("start", 0),
      costs.getOrDefault("end", 0)))
    result = sadd(result, bodyOps(s.body, costs))
  of LoopStmt:
    result = sadd(result, bodyOps(s.body, costs))
  else:
    result = sadd(result, bodyOps(s.body, costs))

proc bodyOps(body: seq[Stmt], costs: Table[string, int64]): int64 =
  for s in body:
    result = sadd(result, stmtOps(s, costs))

## Worst-Case Stack

proc paramBytes(p: Param): int64 =
  if p.isVar or p.typ.kind == ArrayType:
    8 # passed as a pointer
  else:
    typeSize(p.typ)

proc localBytes(body: seq[Stmt]): int64 =
  ## C-stack bytes only: big locals live on the thread arena and cost a
  ## pointer here.
  for s in body:
    if s.kind in {VarStmt, LetStmt}:
      let sz = typeSize(s.typ)
      result = sadd(result, (if sz > arenaThreshold: 8'i64 else: sz))
    if s.kind == ForStmt:
      result = sadd(result, 8)
    if s.kind == ForEachStmt:
      result = sadd(result, sadd(typeSize(s.typ), 16)) # elem + iterator
    result = sadd(result, localBytes(s.body))
    for br in s.elifs:
      result = sadd(result, localBytes(br.body))
    result = sadd(result, localBytes(s.elseBody))

proc arenaWalk(body: seq[Stmt], off: var int64, hi: var int64) =
  ## Mirrors codegen's collectBig: sequential 8-aligned allocation,
  ## blocks rewind on exit, and the frame is the high-water mark.
  for s in body:
    if s.kind in {VarStmt, LetStmt}:
      let sz = typeSize(s.typ)
      if sz > arenaThreshold:
        off = (off + 7) div 8 * 8
        off = sadd(off, sz)
        if off > hi:
          hi = off
    if s.kind == BlockStmt:
      let entry = off
      arenaWalk(s.body, off, hi)
      off = entry
    else:
      arenaWalk(s.body, off, hi)
    for br in s.elifs:
      arenaWalk(br.body, off, hi)
    arenaWalk(s.elseBody, off, hi)

proc arenaBytes(body: seq[Stmt]): int64 =
  ## Bytes of big locals: this routine's arena frame.
  var off = 0'i64
  var hi = 0'i64
  arenaWalk(body, off, hi)
  hi

proc collectCallsExpr(e: Expr, into: var HashSet[string]) =
  if e.isNil:
    return
  if e.kind == CallExpr:
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
    if s.kind == WithStmt and
        not (s.name in globals and globals[s.name].kind == LockType):
      into.incl "start"
      into.incl "end"
    collectCalls(s.body, globals, into)
    for br in s.elifs:
      collectCallsExpr(br.cond, into)
      collectCalls(br.body, globals, into)
    collectCalls(s.elseBody, globals, into)

## The Report

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
    if gd.typ.kind == LockType:
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
    $frameOverhead & " bytes/frame; big locals are on the arena):"
  for r in m.routines:
    if r.kind != ThreadRoutine:
      continue
    let d = deepest[r.name]
    lines.add "  " & r.name & ": " & $d.bytes & " bytes (" & d.chain & ")"

  # Arenas: exact, allocated at that size, so overflow is impossible.
  var aframes: Table[string, int64]
  var adeep: Table[string, tuple[bytes: int64, chain: string]]
  var anyArena = false
  for r in m.routines:
    aframes[r.name] = (arenaBytes(r.body) + 15) div 16 * 16
    var calls: HashSet[string]
    collectCalls(r.body, globals, calls)
    var best = (bytes: 0'i64, chain: "")
    for callee in calls:
      if callee in adeep and adeep[callee].bytes > best.bytes:
        best = adeep[callee]
    adeep[r.name] = (bytes: sadd(aframes[r.name], best.bytes),
      chain: r.name & (if best.chain.len > 0: " -> " & best.chain else: ""))
    if r.kind == ThreadRoutine and adeep[r.name].bytes > 0:
      anyArena = true
  if anyArena:
    lines.add ""
    lines.add "arena per thread (exact; big locals, allocated up front):"
    for r in m.routines:
      if r.kind != ThreadRoutine:
        continue
      let d = adeep[r.name]
      if d.bytes > 0:
        lines.add "  " & r.name & ": " & $d.bytes & " bytes (" & d.chain & ")"

  # Ops: for a thread with top-level loops, report the cost of one pass
  # of each loop plus everything outside them; otherwise the total.
  lines.add ""
  lines.add "worst-case abstract ops per thread:"
  for r in m.routines:
    if r.kind != ThreadRoutine:
      continue
    var outside = 0'i64
    var passes: seq[int64]
    for s in r.body:
      if s.kind == LoopStmt:
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

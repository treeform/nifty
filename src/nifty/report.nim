## Resource reports separate static storage from runtime heap payloads.
## Static programs retain exact arena sizes and representable operation bounds.
## Dynamic work is propagated through calls instead of given a false bound.

import std/[strutils, tables, sets]
import types, semantics, echolowering

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
    elif bt.kind == StringType:
      # Appends copy, scans walk: everything is capacity-bounded.
      if e.sval in ["add", "find", "findByte", "contains", "copyRange",
          "toInt", "addNum"]:
        result = sadd(result, bt.len)
      elif e.sval in ["startsWith", "endsWith"]:
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
    let hooks = s.resourceHooks
    result = sadd(result, sadd(costs.getOrDefault(hooks[0], 0),
      costs.getOrDefault(hooks[1], 0)))
    result = sadd(result, bodyOps(s.body, costs))
  of LoopStmt:
    result = sadd(result, bodyOps(s.body, costs))
  else:
    result = sadd(result, bodyOps(s.body, costs))

proc bodyOps(body: seq[Stmt], costs: Table[string, int64]): int64 =
  for s in body:
    result = sadd(result, stmtOps(s, costs))

proc runtimeExpr(e: Expr, costs: Table[string, bool]): bool =
  ## Detect allocation and work whose size is chosen at runtime.
  if e.isNil:
    return false
  if e.kind == CallExpr and costs.getOrDefault(e.sval, false):
    return true
  if e.kind == MethodExpr and e.kids.len > 0:
    let t = e.kids[0].typ
    if t.hasOwned and e.sval notin ["get", "pop", "len", "cap", "ok"]:
      return true
  if e.kind == FieldExpr and e.sval == "toInt" and
      e.kids.len > 0 and e.kids[0].typ.hasOwned:
    return true
  for k in e.kids:
    if runtimeExpr(k, costs):
      return true

proc runtimeLength(e: Expr, lengths: HashSet[string]): bool =
  ## Recognize bounds derived from a dynamic container's length.
  if e.isNil:
    return false
  if e.kind == IdentExpr and e.sval in lengths:
    return true
  if e.kind == FieldExpr and e.sval in ["len", "cap"] and
      e.kids.len > 0 and e.kids[0].typ.hasOwned:
    return true
  for k in e.kids:
    if runtimeLength(k, lengths) or
        (e.kind == CallExpr and k.typ.hasOwned):
      return true

proc collectLengths(body: seq[Stmt], lengths: var HashSet[string]) =
  ## Conservatively follow saved runtime lengths through local assignments.
  for s in body:
    if s.kind in {VarStmt, LetStmt} and runtimeLength(s.init, lengths):
      lengths.incl s.name
    if s.kind == AssignStmt and s.lhs != nil and
        s.lhs.kind == IdentExpr and runtimeLength(s.rhs, lengths):
      lengths.incl s.lhs.sval
    collectLengths(s.body, lengths)
    collectLengths(s.elseBody, lengths)
    for br in s.elifs:
      collectLengths(br.body, lengths)

proc runtimeBody(body: seq[Stmt], costs: Table[string, bool],
    lengths: HashSet[string]): bool

proc runtimeStmt(s: Stmt, costs: Table[string, bool],
    lengths: HashSet[string]): bool =
  ## Include implicit owner cleanup and dynamically bounded iteration.
  if s.kind in {VarStmt, LetStmt} and s.typ.hasOwned:
    return true
  if s.kind in {WhileStmt, ForStmt, ForEachStmt} and s.tripBound < 0:
    return true
  if s.kind == ForEachStmt and s.value != nil and s.value.typ.hasOwned:
    return true
  if s.kind == ForStmt and
      (runtimeLength(s.lo, lengths) or runtimeLength(s.hi, lengths)):
    return true
  if s.kind == WhileStmt and s.maxTrips == 0 and
      runtimeLength(s.cond, lengths):
    return true
  for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
    if runtimeExpr(e, costs):
      return true
  for a in s.args:
    if runtimeExpr(a, costs) or
        (s.kind == EchoStmt and a.typ.hasOwned):
      return true
  if runtimeBody(s.body, costs, lengths) or
      runtimeBody(s.elseBody, costs, lengths):
    return true
  for br in s.elifs:
    if runtimeExpr(br.cond, costs) or runtimeBody(br.body, costs, lengths):
      return true

proc runtimeBody(body: seq[Stmt], costs: Table[string, bool],
    lengths: HashSet[string]): bool =
  ## Find runtime work in any branch of a statement list.
  for s in body:
    if runtimeStmt(s, costs, lengths):
      return true

proc ownerLines*(m: Module): seq[string] =
  ## Describes owners from the checked plan without bounding heap payloads.
  if m.isNil:
    return
  requireChecked(m)
  for binding in m.semantics.bindings:
    if binding.mode != OwnerMode:
      continue
    if binding.kind == GlobalSym:
      result.add "  global " & binding.name & ": " & $binding.typ &
        " (program lifetime; freed after threads finish)"
    else:
      result.add "  local " & binding.routine & "." & binding.name & ": " &
        $binding.typ & " (declaration scope)"

## Worst-Case Stack

proc paramBytes(m: Module, r: Routine, p: Param): int64 =
  ## Foreign parameters occupy scalar ABI argument slots: string/array
  ## parameters expose pointers, and narrow values use a full 64-bit slot.
  if r.externLib != "":
    return 8
  if m.mode(p.binding).isBorrow:
    8 # passed as a pointer
  else:
    typeSize(p.typ)

proc localBytes(m: Module, body: seq[Stmt]): int64 =
  ## C-stack bytes only: big locals live on the thread arena and cost a
  ## pointer here.
  for s in body:
    if s.kind in {VarStmt, LetStmt}:
      let sz = typeSize(s.typ)
      result = sizeAdd(result, (if sz > arenaThreshold: 8'i64 else: sz))
    if s.kind == ForStmt:
      result = sizeAdd(result, 8)
    if s.kind == ForEachStmt:
      let size =
        if m.mode(s.binding).isBorrow: 8'i64 else: typeSize(s.typ)
      result = sizeAdd(result, sizeAdd(size, 16)) # Element borrow/value + iterator.
    result = sizeAdd(result, localBytes(m, s.body))
    for br in s.elifs:
      result = sizeAdd(result, localBytes(m, br.body))
    result = sizeAdd(result, localBytes(m, s.elseBody))

proc arenaWalk(body: seq[Stmt], off: var int64, hi: var int64) =
  ## Mirrors codegen's collectBig: sequential 8-aligned allocation,
  ## blocks rewind on exit, and the frame is the high-water mark.
  for s in body:
    if s.kind in {VarStmt, LetStmt}:
      let sz = typeSize(s.typ)
      if sz > arenaThreshold:
        off = sizeAlign(off, 8, s.line)
        off = sizeAdd(off, sz, s.line)
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
      for name in s.resourceHooks: into.incl name
    collectCalls(s.body, globals, into)
    for br in s.elifs:
      collectCallsExpr(br.cond, into)
      collectCalls(br.body, globals, into)
    collectCalls(s.elseBody, globals, into)

## The Report

proc threadLabel(r: Routine): string =
  ## thread 4 worker() reports as "worker x4" - the numbers that follow
  ## are per instance.
  if r.instances > 1: r.name & " x" & $r.instances else: r.name

proc buildReport*(m: Module, src: string): string =
  ## Reports storage and work using a successfully checked source module.
  requireChecked(m)
  # Echo's ordinary helpers and value captures consume real C storage.
  # Keep source work/proof reporting on the original checked syntax.
  let storage = lowerEcho(m, src)
  let storageRoutines = backendRoutines(storage)
  var globals: Table[string, Typ]
  for gd in m.globals:
    globals[gd.name] = gd.typ

  var lines: seq[string]
  lines.add "nifty report: " & src

  # Globals contain fixed storage and any owning descriptors.
  lines.add ""
  lines.add "globals:"
  var total = 0'i64
  var locks = 0
  for gd in m.globals:
    if gd.typ.kind == LockType:
      inc locks
      continue
    let size = typeSize(gd.typ)
    total = sizeAdd(total, size, gd.line)
    lines.add "  " & gd.name & ": " & $size & " bytes (" & $gd.typ & ")"
  var totalLine = "  total: " & $total & " bytes"
  if locks > 0:
    totalLine.add " + " & $locks & " lock" & (if locks > 1: "s" else: "") &
      " (platform-sized)"
  lines.add totalLine

  let owners = ownerLines(m)
  if m.semantics.channelProgress.len > 0:
    lines.add ""
    lines.add "channels: " & m.semantics.channelProgress
  if owners.len > 0:
    lines.add ""
    lines.add "heap (runtime-sized; separate from static storage):"
    lines.add owners
    lines.add "  owner descriptors are included in globals/stack/arena"
    lines.add "  payload and spare capacity: no static bound inferred"
    lines.add "  allocator overhead and temporary growth/copy peaks are " &
      "additional"
    lines.add "  cleanup may take runtime-dependent work; global cleanup " &
      "runs after threads"
    lines.add "  stack estimates exclude allocator/runtime helper frames"

  # Locks: what each one actually protects (from the checker's
  # ownership analysis - a lock that protected nothing did not compile).
  if m.semantics.locks.len > 0:
    lines.add ""
    lines.add "locks (acquired in declaration order - deadlock-free):"
    for lk in m.semantics.locks:
      var what =
        if lk.guards.len > 0: "protects " & lk.guards.join(", ")
        else: "serializes output"
      lines.add "  " & lk.name & ": " & what & "; used by " &
        lk.users.join(", ")

  # Abstract work remains a source-language metric, with original proofs.
  var costs: Table[string, int64]
  var runtimeCosts: Table[string, bool]
  for r in m.routines:
    costs[r.name] = bodyOps(r.body, costs)
    var lengths: HashSet[string]
    while true:
      let count = lengths.len
      collectLengths(r.body, lengths)
      if count == lengths.len:
        break
    runtimeCosts[r.name] = runtimeBody(r.body, runtimeCosts, lengths)
    if r.externLib != "":
      for p in r.params:
        if p.typ.hasOwned:
          runtimeCosts[r.name] = true
    var calls: HashSet[string]
    collectCalls(r.body, globals, calls)
    for callee in calls:
      if runtimeCosts.getOrDefault(callee, false):
        runtimeCosts[r.name] = true

  # Storage follows the same normalized call DAG as C generation, including
  # standard-library formatting buffers and readonly echo argument captures.
  var frames: Table[string, int64]
  var deepest: Table[string, tuple[bytes: int64, chain: string]]
  for r in storageRoutines:
    frames[r.name] = sizeAdd(frameOverhead,
      sizeAdd(localBytes(storage, r.body), block:
        var pb = 0'i64
        for p in r.params:
          pb = sizeAdd(pb, paramBytes(storage, r, p), r.line)
        pb))
    var calls: HashSet[string]
    collectCalls(r.body, globals, calls)
    var best = (bytes: 0'i64, chain: "")
    for callee in calls:
      if callee in deepest:
        let d = deepest[callee]
        if d.bytes > best.bytes:
          best = d
    deepest[r.name] = (bytes: sizeAdd(frames[r.name], best.bytes, r.line),
      chain: r.name & (if best.chain.len > 0: " -> " & best.chain else: ""))

  lines.add ""
  lines.add "stack, worst case per thread (estimate: locals + params + " &
    $frameOverhead & " bytes/frame; big locals are on the arena):"
  for r in m.routines:
    if r.kind != ThreadRoutine:
      continue
    let d = deepest[r.name]
    lines.add "  " & threadLabel(r) & ": " & $d.bytes & " bytes (" &
      d.chain & ")"

  # Arenas: exact, allocated at that size, so overflow is impossible.
  var aframes: Table[string, int64]
  var adeep: Table[string, tuple[bytes: int64, chain: string]]
  var anyArena = false
  for r in storageRoutines:
    aframes[r.name] = sizeAlign(arenaBytes(r.body), 16, r.line)
    var calls: HashSet[string]
    collectCalls(r.body, globals, calls)
    var best = (bytes: 0'i64, chain: "")
    for callee in calls:
      if callee in adeep and adeep[callee].bytes > best.bytes:
        best = adeep[callee]
    adeep[r.name] = (bytes: sizeAdd(aframes[r.name], best.bytes, r.line),
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
        var line = "  " & threadLabel(r) & ": " & $d.bytes & " bytes"
        if r.instances > 1:
          line.add " each"
        lines.add line & " (" & d.chain & ")"

  # Ops: for a thread with top-level loops, report the cost of one pass
  # of each loop plus everything outside them; otherwise the total.
  lines.add ""
  lines.add "worst-case abstract ops per thread:"
  for r in m.routines:
    if r.kind != ThreadRoutine:
      continue
    if runtimeCosts.getOrDefault(r.name, false):
      lines.add "  " & threadLabel(r) &
        ": runtime-dependent (dynamic allocation, traversal, or cleanup)"
      continue
    var outside = 0'i64
    var passes: seq[int64]
    for s in r.body:
      if s.kind == LoopStmt:
        passes.add bodyOps(s.body, costs)
      else:
        outside = sadd(outside, stmtOps(s, costs))
    if outside == high(int64) or high(int64) in passes:
      lines.add "  " & threadLabel(r) &
        ": not representable (abstract ops exceed int64)"
      continue
    if passes.len == 0:
      lines.add "  " & threadLabel(r) & ": " & $outside & " ops total"
    else:
      var line = "  " & threadLabel(r) & ": " & $outside &
        " ops outside the loop"
      for i, p in passes:
        line.add ", " & $p & " ops per loop pass"
      lines.add line

  lines.join("\n") & "\n"

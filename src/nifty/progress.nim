## Checks foreign blocking effects and closed channel protocols.

import std/[tables, sets, strutils]
import common, types

const
  MaxProtocolSteps = 4096
  MaxProtocolStates = 100_000
  MaxProtocolThreads = 64

type
  Action = object
    channel: string
    sending: bool
    line: int
  Protocol = object
    actions: seq[Action]
    repeatAt: int
    unknown: bool
    stopped: bool
  ProtocolState = object
    positions: seq[int]
    counts: seq[int]
  Analysis = object
    routines: Table[string, Routine]
    foreign: Table[string, string]

proc foreignCall(a: Analysis, e: Expr): string =
  ## Finds a transitive foreign effect in an expression.
  if e.isNil:
    return
  for child in e.kids:
    result = a.foreignCall(child)
    if result.len > 0:
      return
  if e.kind == CallExpr:
    result = a.foreign.getOrDefault(e.sval)

proc foreignCalls(a: Analysis, body: seq[Stmt]): string =
  ## Summarizes foreign effects through the checked call DAG.
  for s in body:
    for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
      result = a.foreignCall(e)
      if result.len > 0:
        return
    for e in s.args:
      result = a.foreignCall(e)
      if result.len > 0:
        return
    if s.kind == WithStmt and s.typ.kind != LockType:
      for name in ["start", "end"]:
        result = a.foreign.getOrDefault(name)
        if result.len > 0:
          return
    for branch in s.elifs:
      result = a.foreignCall(branch.cond)
      if result.len == 0:
        result = a.foreignCalls(branch.body)
      if result.len > 0:
        return
    for body in [s.body, s.elseBody]:
      result = a.foreignCalls(body)
      if result.len > 0:
        return

proc checkLocks(a: Analysis, body: seq[Stmt]) =
  ## Rejects unknown foreign blocking while a Nifty lock is held.
  for s in body:
    if s.kind == WithStmt and s.typ.kind == LockType:
      let foreign = a.foreignCalls(s.body)
      if foreign.len > 0:
        err(s.line, "foreign call '" & foreign & "' may block while lock '" &
          s.name & "' is held; move the call outside the with block")
    a.checkLocks(s.body)
    a.checkLocks(s.elseBody)
    for branch in s.elifs:
      a.checkLocks(branch.body)

proc append(p: var Protocol, actions: seq[Action]) =
  ## Bounds compile-time trace expansion independently of runtime work.
  if actions.len > MaxProtocolSteps - p.actions.len:
    p.unknown = true
  elif not p.unknown:
    p.actions.add(actions)

proc body(a: Analysis, statements: seq[Stmt]): Protocol

proc expression(a: Analysis, e: Expr, p: var Protocol) =
  ## Records channel operations in the language's evaluation order.
  if e.isNil or p.unknown:
    return
  if e.kind == BinExpr and e.sval in ["and", "or"]:
    a.expression(e.kids[0], p)
    var rhs = Protocol(repeatAt: -1)
    a.expression(e.kids[1], rhs)
    if rhs.unknown or rhs.actions.len > 0:
      p.unknown = true
    return
  for child in e.kids:
    a.expression(child, p)
  if e.kind == MethodExpr and e.kids.len > 0 and
      e.kids[0].typ.kind == ChannelType:
    let receiver = e.kids[0]
    if receiver.kind != IdentExpr or receiver.symKind != GlobalSym:
      p.unknown = true
    else:
      p.append(@[Action(channel: receiver.sval, sending: e.sval == "send",
        line: e.line)])
  elif e.kind == CallExpr and e.sval in a.routines:
    let routine = a.routines[e.sval]
    if routine.externLib.len > 0:
      p.unknown = true
    elif routine.kind != FuncRoutine:
      let called = a.body(routine.body)
      p.unknown = p.unknown or called.unknown or called.repeatAt >= 0
      p.append(called.actions)

proc sameActions(a, b: Protocol): bool =
  ## Compares protocol effects without depending on source locations.
  if a.unknown or b.unknown or a.stopped != b.stopped or
      a.repeatAt != b.repeatAt or a.actions.len != b.actions.len:
    return false
  for i, action in a.actions:
    if action.channel != b.actions[i].channel or
        action.sending != b.actions[i].sending:
      return false
  true

proc body(a: Analysis, statements: seq[Stmt]): Protocol =
  ## Extracts exact traces, declining data-dependent communication.
  result.repeatAt = -1
  for s in statements:
    if result.unknown or result.stopped:
      break
    for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
      a.expression(e, result)
    for e in s.args:
      a.expression(e, result)
    case s.kind
    of IfStmt:
      var chosen = a.body(s.elseBody)
      for branch in s.elifs:
        var condition = Protocol(repeatAt: -1)
        a.expression(branch.cond, condition)
        let candidate = a.body(branch.body)
        if condition.unknown or condition.actions.len > 0 or
            not sameActions(chosen, candidate):
          result.unknown = true
      result.append(chosen.actions)
      result.stopped = chosen.stopped
    of ForStmt:
      let iteration = a.body(s.body)
      if iteration.unknown or iteration.stopped or iteration.repeatAt >= 0:
        result.unknown = true
      elif iteration.actions.len > 0:
        if s.lo.rlo != s.lo.rhi or s.hi.rlo != s.hi.rhi or
            s.tripBound > MaxProtocolSteps:
          result.unknown = true
        else:
          for i in 0 ..< int(s.tripBound):
            result.append(iteration.actions)
    of WhileStmt, ForEachStmt:
      let iteration = a.body(s.body)
      if iteration.unknown or iteration.stopped or iteration.actions.len > 0:
        result.unknown = true
    of LoopStmt:
      let iteration = a.body(s.body)
      if iteration.unknown or iteration.stopped or iteration.repeatAt >= 0:
        result.unknown = true
      else:
        if iteration.actions.len > 0:
          result.repeatAt = result.actions.len
          result.append(iteration.actions)
        result.stopped = true
    of BlockStmt, WithStmt:
      let nested = a.body(s.body)
      result.unknown = result.unknown or nested.unknown
      if s.kind == WithStmt and s.typ.kind != LockType:
        for name in ["start", "end"]:
          if a.foreign.getOrDefault(name).len > 0:
            result.unknown = true
          elif name in a.routines:
            let effects = a.body(a.routines[name].body)
            if effects.unknown or effects.actions.len > 0:
              result.unknown = true
      result.append(nested.actions)
      result.stopped = nested.stopped
    of BreakStmt:
      result.unknown = true
    of ReturnStmt:
      result.stopped = true
    else:
      discard

proc stateKey(state: ProtocolState): string =
  ## Encodes the bounded protocol state for visited-state elimination.
  for position in state.positions:
    result.add($position & ",")
  result.add(":")
  for count in state.counts:
    result.add($count & ",")

proc checkProgress*(m: Module): string =
  ## Rejects reachable deadlocks in exact channel protocols before codegen.
  var a: Analysis
  for routine in m.routines:
    a.routines[routine.name] = routine
    a.foreign[routine.name] = if routine.externLib.len > 0: routine.name
      else: a.foreignCalls(routine.body)
  for routine in m.routines:
    a.checkLocks(routine.body)
  var
    indices: Table[string, int]
    capacities: seq[int64]
  for global in m.globals:
    if global.typ.kind == ChannelType:
      indices[global.name] = capacities.len
      capacities.add(global.typ.len)
  if capacities.len == 0:
    return ""
  var protocols: seq[Protocol]
  for routine in m.routines:
    if routine.kind == ThreadRoutine:
      let protocol = a.body(routine.body)
      if protocol.unknown:
        return "not proven: data-dependent communication or foreign calls"
      if routine.instances > MaxProtocolThreads - protocols.len:
        return "not proven: channel analysis thread limit exceeded"
      for i in 0 ..< routine.instances:
        protocols.add(protocol)
  let initial = ProtocolState(positions: newSeq[int](protocols.len),
    counts: newSeq[int](capacities.len))
  var
    pending = @[initial]
    visited = initHashSet[string]()
    head = 0
  visited.incl(stateKey(initial))
  while head < pending.len:
    let current = pending[head]
    inc head
    var waiting: seq[Action]
    var enabled = false
    for i, protocol in protocols:
      let position = current.positions[i]
      if position >= protocol.actions.len:
        continue
      let
        action = protocol.actions[position]
        channel = indices[action.channel]
        count = current.counts[channel]
        runnable = if action.sending: int64(count) < capacities[channel]
          else: count > 0
      if not runnable:
        waiting.add(action)
        continue
      enabled = true
      var next = current
      next.counts[channel] += (if action.sending: 1 else: -1)
      next.positions[i] += 1
      if next.positions[i] == protocol.actions.len and protocol.repeatAt >= 0:
        next.positions[i] = protocol.repeatAt
      let key = stateKey(next)
      if key notin visited:
        if visited.len >= MaxProtocolStates:
          return "not proven: channel analysis state limit exceeded"
        visited.incl(key)
        pending.add(next)
    if not enabled and waiting.len > 0:
      var details: seq[string]
      for action in waiting:
        details.add(action.channel & (if action.sending: ".send" else: ".recv"))
      err(waiting[0].line, "channel protocol can deadlock: " &
        details.join(", ") & " cannot make progress")
  "no blocked channel state in " & $visited.len &
    " protocol states; assumes runnable threads execute"

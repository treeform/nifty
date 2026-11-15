## Synthesizes exhaustive first-argument dispatch before semantic analysis.

proc unionDispatchTargets(c: Ctx, name: string, union: Typ,
    targets: var seq[Routine]): string =
  ## Finds a unique concrete overload with one consistent signature per case.
  let candidates = c.overloads.getOrDefault(name, @[name])
  for member in union.members:
    var selected: Routine
    for candidate in candidates:
      if candidate notin c.routineTab:
        continue
      let routine = c.routineTab[candidate]
      if routine.params.len == 0 or routine.generic or
          routine.kind == ThreadRoutine or
          not typeEq(routine.params[0].typ, member):
        continue
      if selected != nil:
        return "ambiguous union dispatch for '" & name & "': member " &
          $member & " has multiple applicable overloads"
      selected = routine
    if selected == nil:
      return "cannot dispatch '" & name & "' on " & $union &
        ": missing overload for " & $member
    targets.add selected
  if targets.len == 0:
    return "cannot dispatch an empty union"
  let first = targets[0]
  for target in targets:
    if target.params.len != first.params.len:
      return "cannot dispatch '" & name & "' on " & $union &
        ": member overloads need the same number of parameters"
    if not typeEq(target.ret, first.ret) or
        (target.ret != nil and not typeRangeEq(target.ret, first.ret)):
      return "cannot dispatch '" & name & "' on " & $union &
        ": member overloads need the same return type"
    for i, parameter in target.params:
      let expected = first.params[i]
      if parameter.isVar != expected.isVar:
        return "cannot dispatch '" & name & "' on " & $union &
          ": member overloads need matching var parameters"
      if i > 0 and (not typeEq(parameter.typ, expected.typ) or
          not typeRangeEq(parameter.typ, expected.typ)):
        return "cannot dispatch '" & name & "' on " & $union &
          ": parameters after the first must have the same types"
  ""

proc unionDispatchProblem(c: Ctx, name: string, union: Typ): string =
  ## Explains why an unknown union cannot use concrete overloads.
  var targets: seq[Routine]
  c.unionDispatchTargets(name, union, targets)

proc synthesizeUnionDispatchers(c: var Ctx, m: Module,
    used: var HashSet[string]) =
  ## Inserts checked-language dispatchers after all of their concrete callees.
  var
    families: seq[string]
    insertion: Table[int, seq[Routine]]
    sourceIndices: Table[string, int]
    counter = 0
  for i, routine in m.routines:
    sourceIndices[routine.name] = i
  for name in c.routineTab.keys:
    var memberName = false
    for family, overloads in c.overloads:
      if family notin c.moduleViews and name != family and name in overloads:
        memberName = true
        break
    if not memberName:
      families.add name
  for name in c.moduleViews.keys:
    families.add name
  families.sort()
  for definition in m.types:
    let union = definition.typ
    if union.kind != UnionType:
      continue
    for name in families:
      let candidates = c.overloads.getOrDefault(name, @[name])
      var explicit = false
      for candidate in candidates:
        if candidate notin c.routineTab:
          continue
        let routine = c.routineTab[candidate]
        if routine.params.len > 0 and
            typeEq(routine.params[0].typ, union):
          explicit = true
      if explicit:
        continue
      var targets: seq[Routine]
      if c.unionDispatchTargets(name, union, targets) != "":
        continue
      var last = -1
      for target in targets:
        last = max(last, sourceIndices[target.name])
      var internal: string
      while true:
        internal = "__union_dispatch_" & $counter
        inc counter
        if internal notin used:
          break
      let
        first = targets[0]
        routine = Routine(name: internal, line: first.line,
          kind: FuncRoutine, ret: first.ret, unionDispatcher: true)
      for target in targets:
        if target.kind != FuncRoutine:
          routine.kind = ProcRoutine
      for i, parameter in first.params:
        var parameterName = internal & "_arg" & $i
        while parameterName in used:
          parameterName.add "_"
        routine.params.add Param(name: parameterName,
          typ: (if i == 0: union else: parameter.typ),
          isVar: parameter.isVar)
      let dispatch = Stmt(kind: IfStmt, line: first.line)
      for i, target in targets:
        var arguments: seq[Expr]
        for parameter in routine.params:
          arguments.add Expr(kind: IdentExpr, line: first.line,
            sval: parameter.name)
        let call = Expr(kind: CallExpr, line: first.line,
          sval: target.name, kids: arguments, directCall: true)
        let branch = @[
          Stmt(kind: (if routine.ret == nil: CallStmt else: ReturnStmt),
            line: first.line, value: call)
        ]
        if i == targets.high:
          dispatch.elseBody = branch
        else:
          let condition = Expr(kind: BinExpr, line: first.line, sval: "==",
            kids: @[
              Expr(kind: CallExpr, line: first.line, sval: "type", kids: @[
                Expr(kind: IdentExpr, line: first.line,
                  sval: routine.params[0].name)
              ]),
              Expr(kind: IdentExpr, line: first.line,
                sval: union.members[i].name)
            ])
          dispatch.elifs.add Elif(cond: condition, body: branch)
      routine.body = @[dispatch]
      used.incl internal
      c.allRoutines.incl internal
      c.routineTab[internal] = routine
      if name notin c.overloads:
        c.overloads[name] = @[name]
      c.overloads[name].add internal
      insertion.mgetOrPut(last, @[]).add routine
  var routines: seq[Routine]
  for i, routine in m.routines:
    routines.add routine
    routines.add insertion.getOrDefault(i)
  m.routines = routines

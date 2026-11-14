## Expands checked echo syntax into ordinary standard-library calls.
## Source checking and progress proofs retain the language-level echo effect.
import std/[tables, sets]
import common, lexer, types, parser, loader, checker, semantics

proc copyExpr(value: Expr): Expr =
  if value.isNil:
    return nil
  new(result)
  result[] = value[]
  result.kids = @[]
  for child in value.kids:
    result.kids.add(copyExpr(child))

proc copyBody(body: seq[Stmt]): seq[Stmt]
proc copyStmt(value: Stmt): Stmt =
  new(result)
  result[] = value[]
  result.init = copyExpr(value.init)
  result.lhs = copyExpr(value.lhs)
  result.rhs = copyExpr(value.rhs)
  result.value = copyExpr(value.value)
  result.cond = copyExpr(value.cond)
  result.lo = copyExpr(value.lo)
  result.hi = copyExpr(value.hi)
  result.args = @[]
  for argument in value.args:
    result.args.add(copyExpr(argument))
  result.body = copyBody(value.body)
  result.elseBody = copyBody(value.elseBody)
  result.elifs = @[]
  for branch in value.elifs:
    result.elifs.add(Elif(cond: copyExpr(branch.cond),
      body: copyBody(branch.body)))

proc copyBody(body: seq[Stmt]): seq[Stmt] =
  for value in body:
    result.add(copyStmt(value))

proc hasEcho(body: seq[Stmt]): bool =
  for value in body:
    if value.kind == EchoStmt or hasEcho(value.body) or
        hasEcho(value.elseBody):
      return true
    for branch in value.elifs:
      if hasEcho(branch.body):
        return true

proc backendRoutines*(source: Module): seq[Routine] =
  ## C definitions and storage analysis visit support callees before users.
  if source.supportCount == 0:
    return source.routines
  source.routines[source.routines.len - source.supportCount .. ^1] &
    source.routines[0 ..< source.routines.len - source.supportCount]

proc lowerEcho*(source: Module, filename = "", portableIo = false): Module =
  ## Keeps the original checked tree and its semantic bindings immutable.
  source.requireChecked()
  var needed = false
  for routine in source.routines:
    needed = needed or hasEcho(routine.body)
  if not needed:
    return source

  # Support-file ids are appended; existing user/import ids remain valid.
  if srcFiles.len == 0:
    srcFiles.add(if filename.len > 0: filename else: "<source>")
  var tokens = loadStandardTokens("_echo", portableIo)
  tokens.setLen(tokens.len - 1)
  tokens.add(tokenize("thread niftyEchoBootstrap() =\n  discard 0\n"))
  let library = parse(tokens)
  check(library)
  library.routines.setLen(library.routines.len - 1)

  var used: HashSet[string]
  proc names(body: seq[Stmt]) =
    for statement in body:
      used.incl(statement.name)
      used.incl(statement.name2)
      names(statement.body)
      names(statement.elseBody)
      for branch in statement.elifs:
        names(branch.body)
  for routine in source.routines:
    used.incl(routine.name)
    for parameter in routine.params:
      used.incl(parameter.name)
    names(routine.body)
  for constant in source.consts: used.incl(constant.name)
  for global in source.globals: used.incl(global.name)
  for definition in source.types: used.incl(definition.name)
  var renamed: Table[string, string]
  var serial = 0
  proc unique(name: string): string =
    result = "niftyEchoSupport_" & name
    while result in used:
      inc serial
      result = "niftyEchoSupport" & $serial & "_" & name
    used.incl(result)
  for definition in library.types:
    renamed[definition.name] = unique(definition.name)
  for routine in library.routines:
    renamed[routine.name] = unique(routine.name)
  for constant in library.consts:
    renamed[constant.name] = unique(constant.name)
  proc renameExpr(value: Expr) =
    if value.isNil: return
    if value.kind in {CallExpr, IdentExpr} and value.sval in renamed:
      value.sval = renamed[value.sval]
    for child in value.kids:
      renameExpr(child)
  proc renameBody(body: seq[Stmt]) =
    for statement in body:
      for value in [statement.init, statement.lhs, statement.rhs,
          statement.value, statement.cond, statement.lo, statement.hi]:
        renameExpr(value)
      for argument in statement.args: renameExpr(argument)
      renameBody(statement.body)
      renameBody(statement.elseBody)
      for branch in statement.elifs:
        renameExpr(branch.cond)
        renameBody(branch.body)
  for routine in library.routines:
    routine.name = renamed[routine.name]
    renameBody(routine.body)
  for constant in library.consts.mitems:
    constant.name = renamed[constant.name]
  for definition in library.types.mitems:
    definition.name = renamed[definition.name]
    definition.typ.name = definition.name

  new(result)
  result[] = source[]
  result.globals = @[]
  for global in source.globals: result.globals.add(global)
  result.types = @[]
  result.types.add(source.types)
  result.types.add(library.types)
  result.consts = @[]
  result.consts.add(source.consts)
  result.consts.add(library.consts)
  result.routines = @[]
  proc call(name: string, arguments: seq[Expr], line: int): Stmt =
    Stmt(kind: CallStmt, line: line,
      value: Expr(kind: CallExpr, sval: renamed[name], kids: arguments,
        line: line))
  proc expand(body: seq[Stmt]): seq[Stmt] =
    for statement in body:
      if statement.kind == EchoStmt:
        var captures, output: seq[Stmt]
        for argument in statement.args:
          let name = unique("value")
          var typ = argument.typ
          if typ.kind == StringLitType:
            typ = Typ(kind: StringType, len: int64(max(1, argument.sval.len)))
            argument.typ = typ
          captures.add(Stmt(kind: LetStmt, name: name, typ: typ,
            init: argument, line: argument.line,
            nonowningTemp: hasOwned(typ)))
          var value = Expr(kind: IdentExpr, sval: name, typ: typ,
            symKind: LocalSym, line: argument.line)
          let helper = case typ.kind
            of StringType:
              value.borrowedView = not typ.dynamic
              "echoText"
            of BoolType: "echoBool"
            of FloatType:
              if typ.width == 4:
                value = Expr(kind: CallExpr, sval: "float64", kids: @[value],
                  typ: floatType(8, "float64"), line: value.line)
              "echoFloat"
            else:
              if typ.dname == "char": "echoChar" else: "echoInt"
          output.add(call(helper, @[value], argument.line))
        captures.add(call("echoStart", @[], statement.line))
        captures.add(output)
        captures.add(call("echoFinish", @[], statement.line))
        result.add(Stmt(kind: BlockStmt, body: captures, line: statement.line))
      else:
        statement.body = expand(statement.body)
        statement.elseBody = expand(statement.elseBody)
        for branch in statement.elifs.mitems:
          branch.body = expand(branch.body)
        result.add(statement)
  for original in source.routines:
    var routine: Routine
    new(routine)
    routine[] = original[]
    routine.params = @[]
    for parameter in original.params: routine.params.add(parameter)
    routine.body = expand(copyBody(original.body))
    result.routines.add(routine)
  result.routines.add(library.routines)
  result.supportCount = library.routines.len
  let locks = source.semantics.locks
  let progress = source.semantics.channelProgress
  prepareSemantics(result)
  result.semantics.locks = locks
  result.semantics.channelProgress = progress

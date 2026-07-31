## Nifty — nimmy's super-static brother.
## A tiny fixed-everything systems language with Nim-flavored syntax that
## compiles to portable C. See spec.md for the language definition.
##
## Pipeline: tokenize -> parse -> check -> generate C.

import std/[strutils, tables, sets, sequtils]

type
  NiftyError* = object of CatchableError

proc err(line: int, msg: string) {.noreturn.} =
  raise newException(NiftyError, "line " & $line & ": " & msg)

# ---------------------------------------------------------------------------
# Tokenizer
# ---------------------------------------------------------------------------

type
  TokKind = enum
    tkIdent, tkInt, tkStr, tkOp, tkNewline, tkIndent, tkDedent, tkEof
  Token = object
    kind: TokKind
    text: string
    line: int

const multiOps = ["..<", "..", "==", "!=", "<=", ">="]
const singleOps = {'+', '-', '*', '/', '%', '(', ')', '[', ']', ':', ',', '=', '<', '>'}

proc tokenize(src: string): seq[Token] =
  ## Turn source text into tokens, including indent/dedent tokens.
  var indents = @[0]
  var lineNo = 0
  for rawLine in src.splitLines:
    inc lineNo
    # Cut off comments (a '#' outside a string literal).
    var line = rawLine
    var inStr = false
    var i = 0
    while i < line.len:
      let c = line[i]
      if inStr:
        if c == '\\': inc i
        elif c == '"': inStr = false
      else:
        if c == '"': inStr = true
        elif c == '#':
          line = line[0 ..< i]
          break
      inc i
    if line.strip.len == 0:
      continue
    # Indentation.
    var ind = 0
    while ind < line.len and line[ind] == ' ':
      inc ind
    if line[ind] == '\t':
      err(lineNo, "tabs are not allowed; indent with spaces")
    if ind > indents[^1]:
      indents.add ind
      result.add Token(kind: tkIndent, line: lineNo)
    else:
      while ind < indents[^1]:
        discard indents.pop
        result.add Token(kind: tkDedent, line: lineNo)
      if ind != indents[^1]:
        err(lineNo, "inconsistent indentation")
    # Tokens on the line.
    var p = ind
    while p < line.len:
      let c = line[p]
      if c == ' ':
        inc p
      elif c.isDigit:
        let s = p
        while p < line.len and (line[p].isDigit or line[p] == '_'):
          inc p
        result.add Token(kind: tkInt, text: line[s ..< p].replace("_", ""), line: lineNo)
      elif c.isAlphaAscii or c == '_':
        let s = p
        while p < line.len and (line[p].isAlphaNumeric or line[p] == '_'):
          inc p
        result.add Token(kind: tkIdent, text: line[s ..< p], line: lineNo)
      elif c == '"':
        inc p
        var s = ""
        while p < line.len and line[p] != '"':
          if line[p] == '\\':
            inc p
            if p >= line.len:
              err(lineNo, "unterminated string escape")
            case line[p]
            of 'n': s.add '\n'
            of 't': s.add '\t'
            of '"': s.add '"'
            of '\\': s.add '\\'
            else: err(lineNo, "unknown escape: \\" & line[p])
          else:
            s.add line[p]
          inc p
        if p >= line.len:
          err(lineNo, "unterminated string")
        inc p
        result.add Token(kind: tkStr, text: s, line: lineNo)
      else:
        var op = ""
        for m in multiOps:
          if line.len - p >= m.len and line[p ..< p + m.len] == m:
            op = m
            break
        if op == "":
          if c in singleOps:
            op = $c
          else:
            err(lineNo, "unexpected character: '" & $c & "'")
        result.add Token(kind: tkOp, text: op, line: lineNo)
        p += op.len
    result.add Token(kind: tkNewline, line: lineNo)
  while indents.len > 1:
    discard indents.pop
    result.add Token(kind: tkDedent, line: lineNo)
  result.add Token(kind: tkEof, line: lineNo)

# ---------------------------------------------------------------------------
# AST
# ---------------------------------------------------------------------------

type
  TypKind = enum
    tyInt, tyBool, tyString, tyLock, tyArray
  Typ = ref object
    kind: TypKind
    len: int64 # tyArray
    elem: Typ  # tyArray

  SymKind = enum
    syConst, syGlobal, syLocal, syParam

  ExprKind = enum
    ekInt, ekBool, ekStr, ekIdent, ekBin, ekNot, ekNeg, ekIndex, ekCall
  Expr = ref object
    kind: ExprKind
    line: int
    ival: int64
    bval: bool
    sval: string   # ekStr text, ekIdent name, ekBin operator, ekCall name
    kids: seq[Expr]
    typ: Typ       # set by the checker
    symKind: SymKind
    isVarParam: bool
    mut: bool

  StmtKind = enum
    skVar, skLet, skAssign, skIf, skWhile, skFor, skLoop, skWithLock,
    skReturn, skBreak, skEcho, skDiscard, skCall
  Elif = object
    cond: Expr
    body: seq[Stmt]
  Stmt = ref object
    kind: StmtKind
    line: int
    name: string      # var/let/for/withLock
    typ: Typ          # var/let declared or inferred type
    init: Expr        # var/let initializer
    lhs, rhs: Expr    # assign
    cond: Expr        # while
    lo, hi: Expr      # for
    inclusive: bool   # for: .. vs ..<
    value: Expr       # return/discard/call
    args: seq[Expr]   # echo
    body: seq[Stmt]
    elifs: seq[Elif]  # if: all condition branches, first is the `if`
    elseBody: seq[Stmt]

  RoutineKind = enum
    rkFunc = "func", rkProc = "proc", rkThread = "thread"
  Param = object
    name: string
    typ: Typ
    isVar: bool
  Routine = ref object
    kind: RoutineKind
    name: string
    line: int
    params: seq[Param]
    ret: Typ # nil = no return value
    body: seq[Stmt]

  ConstDef = object
    name: string
    value: int64
    line: int
  GlobalDef = object
    name: string
    typ: Typ
    line: int
  Module = ref object
    consts: seq[ConstDef]
    globals: seq[GlobalDef]
    routines: seq[Routine]

proc typEq(a, b: Typ): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind:
    return false
  if a.kind == tyArray:
    return a.len == b.len and typEq(a.elem, b.elem)
  true

proc `$`(t: Typ): string =
  if t.isNil:
    return "void"
  case t.kind
  of tyInt: "int"
  of tyBool: "bool"
  of tyString: "string"
  of tyLock: "Lock"
  of tyArray: "array[" & $t.len & ", " & $t.elem & "]"

# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

type
  Parser = object
    toks: seq[Token]
    pos: int
    consts: Table[string, int64] # needed at parse time for array lengths

proc peek(p: Parser): Token =
  p.toks[p.pos]

proc next(p: var Parser): Token =
  result = p.toks[p.pos]
  inc p.pos

proc atOp(p: Parser, s: string): bool =
  p.peek.kind == tkOp and p.peek.text == s

proc atIdent(p: Parser, s: string): bool =
  p.peek.kind == tkIdent and p.peek.text == s

proc expectOp(p: var Parser, s: string) =
  if not p.atOp(s):
    err(p.peek.line, "expected '" & s & "'")
  discard p.next

proc expectIdent(p: var Parser): string =
  if p.peek.kind != tkIdent:
    err(p.peek.line, "identifier expected")
  p.next.text

proc expectKeyword(p: var Parser, s: string) =
  if not p.atIdent(s):
    err(p.peek.line, "expected '" & s & "'")
  discard p.next

proc expectNewline(p: var Parser) =
  if p.peek.kind notin {tkNewline, tkEof}:
    err(p.peek.line, "end of line expected")
  if p.peek.kind == tkNewline:
    discard p.next

proc parseType(p: var Parser): Typ =
  let t = p.next
  if t.kind != tkIdent:
    err(t.line, "type expected")
  case t.text
  of "int":
    Typ(kind: tyInt)
  of "bool":
    Typ(kind: tyBool)
  of "Lock":
    Typ(kind: tyLock)
  of "array":
    p.expectOp("[")
    let lt = p.next
    var n: int64
    if lt.kind == tkInt:
      n = parseBiggestInt(lt.text)
    elif lt.kind == tkIdent and lt.text in p.consts:
      n = p.consts[lt.text]
    else:
      err(lt.line, "array length must be an integer literal or a const")
    if n <= 0:
      err(lt.line, "array length must be positive")
    p.expectOp(",")
    let e = p.parseType()
    if e.kind == tyLock:
      err(lt.line, "Lock cannot be an array element")
    p.expectOp("]")
    Typ(kind: tyArray, len: n, elem: e)
  else:
    err(t.line, "unknown type: '" & t.text & "'")

proc parseExpr(p: var Parser): Expr

proc parseAtom(p: var Parser): Expr =
  let t = p.peek
  case t.kind
  of tkInt:
    discard p.next
    result = Expr(kind: ekInt, line: t.line, ival: parseBiggestInt(t.text))
  of tkStr:
    discard p.next
    result = Expr(kind: ekStr, line: t.line, sval: t.text)
  of tkIdent:
    discard p.next
    if t.text == "true":
      result = Expr(kind: ekBool, line: t.line, bval: true)
    elif t.text == "false":
      result = Expr(kind: ekBool, line: t.line, bval: false)
    else:
      result = Expr(kind: ekIdent, line: t.line, sval: t.text)
  else:
    if p.atOp("("):
      discard p.next
      result = p.parseExpr()
      p.expectOp(")")
    else:
      err(t.line, "expression expected")

proc parsePostfix(p: var Parser): Expr =
  result = p.parseAtom()
  while true:
    if p.atOp("["):
      discard p.next
      let idx = p.parseExpr()
      p.expectOp("]")
      result = Expr(kind: ekIndex, line: result.line, kids: @[result, idx])
    elif p.atOp("("):
      if result.kind != ekIdent:
        err(result.line, "only a named func or proc can be called")
      discard p.next
      var args: seq[Expr]
      if not p.atOp(")"):
        args.add p.parseExpr()
        while p.atOp(","):
          discard p.next
          args.add p.parseExpr()
      p.expectOp(")")
      result = Expr(kind: ekCall, line: result.line, sval: result.sval, kids: args)
    else:
      break

proc parseUnary(p: var Parser): Expr =
  if p.atOp("-"):
    let line = p.next.line
    Expr(kind: ekNeg, line: line, kids: @[p.parseUnary()])
  else:
    p.parsePostfix()

proc parseMul(p: var Parser): Expr =
  result = p.parseUnary()
  while p.peek.kind == tkOp and p.peek.text in ["*", "/", "%"]:
    let op = p.next.text
    result = Expr(kind: ekBin, line: result.line, sval: op,
      kids: @[result, p.parseUnary()])

proc parseAdd(p: var Parser): Expr =
  result = p.parseMul()
  while p.peek.kind == tkOp and p.peek.text in ["+", "-"]:
    let op = p.next.text
    result = Expr(kind: ekBin, line: result.line, sval: op,
      kids: @[result, p.parseMul()])

proc parseCmp(p: var Parser): Expr =
  result = p.parseAdd()
  if p.peek.kind == tkOp and p.peek.text in ["==", "!=", "<", "<=", ">", ">="]:
    let op = p.next.text
    result = Expr(kind: ekBin, line: result.line, sval: op,
      kids: @[result, p.parseAdd()])

proc parseNot(p: var Parser): Expr =
  if p.atIdent("not"):
    let line = p.next.line
    Expr(kind: ekNot, line: line, kids: @[p.parseNot()])
  else:
    p.parseCmp()

proc parseAnd(p: var Parser): Expr =
  result = p.parseNot()
  while p.atIdent("and"):
    discard p.next
    result = Expr(kind: ekBin, line: result.line, sval: "and",
      kids: @[result, p.parseNot()])

proc parseExpr(p: var Parser): Expr =
  result = p.parseAnd()
  while p.atIdent("or"):
    discard p.next
    result = Expr(kind: ekBin, line: result.line, sval: "or",
      kids: @[result, p.parseAnd()])

proc parseStmt(p: var Parser): Stmt
proc parseBody(p: var Parser): seq[Stmt]

proc parseSimpleStmt(p: var Parser): Stmt =
  ## One statement that fits on a line. Does not consume the newline.
  let t = p.peek
  case t.text
  of "var", "let":
    discard p.next
    let name = p.expectIdent()
    var typ: Typ = nil
    var init: Expr = nil
    if p.atOp(":"):
      discard p.next
      typ = p.parseType()
    if p.atOp("="):
      discard p.next
      init = p.parseExpr()
    Stmt(kind: (if t.text == "let": skLet else: skVar), line: t.line,
      name: name, typ: typ, init: init)
  of "return":
    discard p.next
    var val: Expr = nil
    if p.peek.kind notin {tkNewline, tkEof, tkDedent}:
      val = p.parseExpr()
    Stmt(kind: skReturn, line: t.line, value: val)
  of "break":
    discard p.next
    Stmt(kind: skBreak, line: t.line)
  of "echo":
    discard p.next
    var args = @[p.parseExpr()]
    while p.atOp(","):
      discard p.next
      args.add p.parseExpr()
    Stmt(kind: skEcho, line: t.line, args: args)
  of "discard":
    discard p.next
    Stmt(kind: skDiscard, line: t.line, value: p.parseExpr())
  else:
    let e = p.parseExpr()
    if p.atOp("="):
      discard p.next
      if e.kind notin {ekIdent, ekIndex}:
        err(e.line, "cannot assign to this expression")
      Stmt(kind: skAssign, line: t.line, lhs: e, rhs: p.parseExpr())
    else:
      if e.kind != ekCall:
        err(e.line, "expression has no effect")
      Stmt(kind: skCall, line: t.line, value: e)

proc parseBlock(p: var Parser): seq[Stmt] =
  p.expectNewline()
  if p.peek.kind != tkIndent:
    err(p.peek.line, "indented block expected")
  discard p.next
  while p.peek.kind notin {tkDedent, tkEof}:
    result.add p.parseStmt()
  if p.peek.kind == tkDedent:
    discard p.next

proc parseBody(p: var Parser): seq[Stmt] =
  ## Either an indented block, or a single simple statement on the same line.
  if p.peek.kind == tkNewline:
    p.parseBlock()
  else:
    let s = p.parseSimpleStmt()
    p.expectNewline()
    @[s]

proc parseStmt(p: var Parser): Stmt =
  let t = p.peek
  if t.kind != tkIdent:
    err(t.line, "statement expected")
  case t.text
  of "if":
    discard p.next
    result = Stmt(kind: skIf, line: t.line)
    let cond = p.parseExpr()
    p.expectOp(":")
    result.elifs.add Elif(cond: cond, body: p.parseBody())
    while p.atIdent("elif"):
      discard p.next
      let c = p.parseExpr()
      p.expectOp(":")
      result.elifs.add Elif(cond: c, body: p.parseBody())
    if p.atIdent("else"):
      discard p.next
      p.expectOp(":")
      result.elseBody = p.parseBody()
  of "while":
    discard p.next
    result = Stmt(kind: skWhile, line: t.line, cond: p.parseExpr())
    p.expectOp(":")
    result.body = p.parseBody()
  of "for":
    discard p.next
    result = Stmt(kind: skFor, line: t.line, name: p.expectIdent())
    p.expectKeyword("in")
    result.lo = p.parseExpr()
    if p.atOp("..<"):
      result.inclusive = false
    elif p.atOp(".."):
      result.inclusive = true
    else:
      err(p.peek.line, "expected '..' or '..<' in for loop")
    discard p.next
    result.hi = p.parseExpr()
    p.expectOp(":")
    result.body = p.parseBody()
  of "loop":
    discard p.next
    result = Stmt(kind: skLoop, line: t.line)
    p.expectOp(":")
    result.body = p.parseBody()
  of "withLock":
    discard p.next
    result = Stmt(kind: skWithLock, line: t.line, name: p.expectIdent())
    p.expectOp(":")
    result.body = p.parseBody()
  else:
    result = p.parseSimpleStmt()
    p.expectNewline()

proc evalConst(p: Parser, e: Expr): int64 =
  case e.kind
  of ekInt:
    e.ival
  of ekIdent:
    if e.sval in p.consts:
      p.consts[e.sval]
    else:
      err(e.line, "unknown const: '" & e.sval & "'")
  of ekNeg:
    -p.evalConst(e.kids[0])
  of ekBin:
    let a = p.evalConst(e.kids[0])
    let b = p.evalConst(e.kids[1])
    case e.sval
    of "+": a + b
    of "-": a - b
    of "*": a * b
    of "/":
      if b == 0: err(e.line, "division by zero in const")
      a div b
    of "%":
      if b == 0: err(e.line, "modulo by zero in const")
      a mod b
    else:
      err(e.line, "operator not allowed in const expression: " & e.sval)
  else:
    err(e.line, "constant expression expected")

proc parseModule(p: var Parser): Module =
  result = Module()
  while p.peek.kind != tkEof:
    if p.peek.kind == tkNewline:
      discard p.next
      continue
    let t = p.peek
    if t.kind != tkIdent:
      err(t.line, "declaration expected")
    case t.text
    of "const":
      discard p.next
      let name = p.expectIdent()
      p.expectOp("=")
      let v = p.evalConst(p.parseExpr())
      if name in p.consts:
        err(t.line, "duplicate const: '" & name & "'")
      p.consts[name] = v
      result.consts.add ConstDef(name: name, value: v, line: t.line)
      p.expectNewline()
    of "var":
      discard p.next
      let name = p.expectIdent()
      p.expectOp(":")
      let typ = p.parseType()
      if p.atOp("="):
        err(t.line, "globals are zero-initialized; initializers are not allowed")
      result.globals.add GlobalDef(name: name, typ: typ, line: t.line)
      p.expectNewline()
    of "func", "proc", "thread":
      discard p.next
      let kind = case t.text
        of "func": rkFunc
        of "proc": rkProc
        else: rkThread
      var r = Routine(kind: kind, name: p.expectIdent(), line: t.line)
      p.expectOp("(")
      if not p.atOp(")"):
        while true:
          var names = @[p.expectIdent()]
          while p.atOp(","):
            discard p.next
            names.add p.expectIdent()
          p.expectOp(":")
          var isVar = false
          if p.atIdent("var"):
            discard p.next
            isVar = true
          let ty = p.parseType()
          for n in names:
            r.params.add Param(name: n, typ: ty, isVar: isVar)
          if p.atOp(","):
            discard p.next
          else:
            break
      p.expectOp(")")
      if p.atOp(":"):
        discard p.next
        r.ret = p.parseType()
      p.expectOp("=")
      r.body = p.parseBody()
      result.routines.add r
    else:
      err(t.line, "unknown declaration: '" & t.text &
        "' (expected const, var, func, proc, or thread)")

# ---------------------------------------------------------------------------
# Checker
# ---------------------------------------------------------------------------

type
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
    lockDepth: int
    loopLocks: seq[int]        # lockDepth at entry of each enclosing loop

proc isDeclared(c: Ctx, name: string): bool =
  for sc in c.scopes:
    if name in sc:
      return true
  name in c.consts or name in c.globals or name in c.allRoutines

proc checkExpr(c: var Ctx, e: Expr): Typ

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
    e.symKind = syConst
    e.mut = false
    e.typ = Typ(kind: tyInt)
    return
  if name in c.globals:
    if c.cur.kind == rkFunc:
      err(e.line, "func '" & c.cur.name & "' cannot access global '" & name & "'")
    let t = c.globals[name]
    if t.kind == tyLock:
      err(e.line, "'" & name & "' is a Lock; it can only be used with withLock")
    e.symKind = syGlobal
    e.mut = true
    e.typ = t
    return
  if name in c.allRoutines:
    err(e.line, "'" & name & "' is a routine, not a value (call it with parentheses)")
  err(e.line, "unknown identifier: '" & name & "'")

proc rootIdent(e: Expr): Expr =
  result = e
  while result.kind == ekIndex:
    result = result.kids[0]

proc checkExpr(c: var Ctx, e: Expr): Typ =
  case e.kind
  of ekInt:
    e.typ = Typ(kind: tyInt)
  of ekBool:
    e.typ = Typ(kind: tyBool)
  of ekStr:
    e.typ = Typ(kind: tyString)
  of ekIdent:
    c.resolveIdent(e)
  of ekNeg:
    if c.expectVal(e.kids[0]).kind != tyInt:
      err(e.line, "unary '-' needs an int operand")
    e.typ = Typ(kind: tyInt)
  of ekNot:
    if c.expectVal(e.kids[0]).kind != tyBool:
      err(e.line, "'not' needs a bool operand")
    e.typ = Typ(kind: tyBool)
  of ekBin:
    let a = c.expectVal(e.kids[0])
    let b = c.expectVal(e.kids[1])
    case e.sval
    of "+", "-", "*", "/", "%":
      if a.kind != tyInt or b.kind != tyInt:
        err(e.line, "'" & e.sval & "' needs int operands, got " & $a & " and " & $b)
      e.typ = Typ(kind: tyInt)
    of "<", "<=", ">", ">=":
      if a.kind != tyInt or b.kind != tyInt:
        err(e.line, "'" & e.sval & "' needs int operands, got " & $a & " and " & $b)
      e.typ = Typ(kind: tyBool)
    of "==", "!=":
      if not typEq(a, b) or a.kind notin {tyInt, tyBool}:
        err(e.line, "'" & e.sval & "' needs two ints or two bools, got " &
          $a & " and " & $b)
      e.typ = Typ(kind: tyBool)
    of "and", "or":
      if a.kind != tyBool or b.kind != tyBool:
        err(e.line, "'" & e.sval & "' needs bool operands, got " & $a & " and " & $b)
      e.typ = Typ(kind: tyBool)
    else:
      err(e.line, "internal: unknown operator " & e.sval)
  of ekIndex:
    let base = c.expectVal(e.kids[0])
    if base.kind != tyArray:
      err(e.line, "'[]' needs an array, got " & $base)
    if c.expectVal(e.kids[1]).kind != tyInt:
      err(e.line, "array index must be an int")
    e.typ = base.elem
  of ekCall:
    let name = e.sval
    if name notin c.allRoutines:
      err(e.line, "unknown func or proc: '" & name & "'")
    if name == c.cur.name:
      err(e.line, "recursion is not allowed: '" & name & "' calls itself")
    if name notin c.checked:
      err(e.line, "'" & name & "' is called before its declaration " &
        "(declare-before-use keeps the call graph recursion-free)")
    let r = c.routineTab[name]
    if r.kind == rkThread:
      err(e.line, "threads start at program start; they cannot be called")
    if c.cur.kind == rkFunc and r.kind != rkFunc:
      err(e.line, "func '" & c.cur.name & "' can only call other funcs; '" &
        name & "' is a " & $r.kind)
    if e.kids.len != r.params.len:
      err(e.line, "'" & name & "' expects " & $r.params.len &
        " argument(s), got " & $e.kids.len)
    for i, arg in e.kids:
      let pt = r.params[i]
      let at = c.expectVal(arg)
      if not typEq(at, pt.typ):
        err(arg.line, "argument " & $(i + 1) & " of '" & name & "': expected " &
          $pt.typ & ", got " & $at)
      if pt.isVar:
        if arg.kind notin {ekIdent, ekIndex}:
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must be a variable")
        let root = arg.rootIdent
        if root.kind != ekIdent or not root.mut:
          err(arg.line, "argument for var parameter '" & pt.name &
            "' must be mutable")
    e.typ = r.ret
  e.typ

proc checkStmt(c: var Ctx, s: Stmt, topLevel: bool)

proc checkBody(c: var Ctx, body: seq[Stmt]) =
  c.scopes.add initTable[string, Sym]()
  for s in body:
    c.checkStmt(s, false)
  discard c.scopes.pop

proc checkStmt(c: var Ctx, s: Stmt, topLevel: bool) =
  case s.kind
  of skVar, skLet:
    if s.typ != nil and s.typ.kind == tyLock:
      err(s.line, "a Lock must be a global")
    var t = s.typ
    if s.init != nil:
      let it = c.expectVal(s.init)
      if it.kind == tyString:
        err(s.line, "string values only exist as echo arguments in v0")
      if it.kind == tyArray:
        err(s.line, "arrays cannot be copied; copy elements in a loop")
      if t == nil:
        t = it
      elif not typEq(t, it):
        err(s.line, "type mismatch: declared " & $t & ", initializer is " & $it)
    else:
      if s.kind == skLet:
        err(s.line, "let requires an initializer")
      if t == nil:
        err(s.line, "variable needs a type or an initializer")
    if c.isDeclared(s.name):
      err(s.line, "'" & s.name & "' is already declared (shadowing is not allowed)")
    s.typ = t
    c.scopes[^1][s.name] = Sym(kind: syLocal, typ: t, mutable: s.kind == skVar)
  of skAssign:
    let lt = c.expectVal(s.lhs)
    let root = s.lhs.rootIdent
    if root.kind != ekIdent:
      err(s.lhs.line, "cannot assign to this expression")
    if not root.mut:
      err(s.lhs.line, "cannot assign to immutable '" & root.sval & "'")
    if lt.kind == tyArray:
      err(s.lhs.line, "whole-array assignment is not allowed; copy elements in a loop")
    let rt = c.expectVal(s.rhs)
    if not typEq(lt, rt):
      err(s.line, "type mismatch: cannot assign " & $rt & " to " & $lt)
  of skIf:
    for br in s.elifs:
      if c.expectVal(br.cond).kind != tyBool:
        err(br.cond.line, "condition must be a bool")
      c.checkBody(br.body)
    if s.elseBody.len > 0:
      c.checkBody(s.elseBody)
  of skWhile:
    if c.expectVal(s.cond).kind != tyBool:
      err(s.cond.line, "condition must be a bool")
    c.loopLocks.add c.lockDepth
    c.checkBody(s.body)
    discard c.loopLocks.pop
  of skFor:
    if c.expectVal(s.lo).kind != tyInt or c.expectVal(s.hi).kind != tyInt:
      err(s.line, "for loop bounds must be ints")
    if c.isDeclared(s.name):
      err(s.line, "'" & s.name & "' is already declared (shadowing is not allowed)")
    c.scopes.add initTable[string, Sym]()
    c.scopes[^1][s.name] = Sym(kind: syLocal, typ: Typ(kind: tyInt), mutable: false)
    c.loopLocks.add c.lockDepth
    for st in s.body:
      c.checkStmt(st, false)
    discard c.loopLocks.pop
    discard c.scopes.pop
  of skLoop:
    if c.cur.kind != rkThread or not topLevel:
      err(s.line, "loop is only allowed at the top level of a thread body")
    c.loopLocks.add c.lockDepth
    c.checkBody(s.body)
    discard c.loopLocks.pop
  of skWithLock:
    if c.cur.kind == rkFunc:
      err(s.line, "withLock is not allowed in func")
    if s.name notin c.globals or c.globals[s.name].kind != tyLock:
      err(s.line, "withLock expects a global of type Lock")
    inc c.lockDepth
    c.checkBody(s.body)
    dec c.lockDepth
  of skReturn:
    if c.lockDepth > 0:
      err(s.line, "return inside withLock is not allowed (the lock would never be released)")
    if c.cur.kind == rkThread:
      err(s.line, "threads do not return; let the body end instead")
    if c.cur.ret.isNil:
      if s.value != nil:
        err(s.line, "'" & c.cur.name & "' has no return type")
    else:
      if s.value == nil:
        err(s.line, "return needs a value of type " & $c.cur.ret)
      let t = c.expectVal(s.value)
      if not typEq(t, c.cur.ret):
        err(s.line, "return type mismatch: got " & $t & ", expected " & $c.cur.ret)
  of skBreak:
    if c.loopLocks.len == 0:
      err(s.line, "break outside a loop")
    if c.lockDepth != c.loopLocks[^1]:
      err(s.line, "break out of withLock is not allowed (the lock would never be released)")
  of skEcho:
    if c.cur.kind == rkFunc:
      err(s.line, "echo is a side effect; not allowed in func")
    for a in s.args:
      if c.expectVal(a).kind notin {tyInt, tyBool, tyString}:
        err(a.line, "cannot echo a " & $a.typ)
  of skDiscard:
    discard c.checkExpr(s.value)
  of skCall:
    let t = c.checkExpr(s.value)
    if not t.isNil:
      err(s.line, "return value of '" & s.value.sval &
        "' is discarded (use discard or assign it)")

proc alwaysReturns(body: seq[Stmt]): bool =
  if body.len == 0:
    return false
  let s = body[^1]
  case s.kind
  of skReturn:
    true
  of skIf:
    if s.elseBody.len == 0:
      return false
    for br in s.elifs:
      if not alwaysReturns(br.body):
        return false
    alwaysReturns(s.elseBody)
  else:
    false

proc check(m: Module) =
  var c = Ctx()
  var used: HashSet[string]
  for cd in m.consts:
    if cd.name in used:
      err(cd.line, "duplicate name: '" & cd.name & "'")
    used.incl cd.name
    c.consts[cd.name] = cd.value
  for gd in m.globals:
    if gd.name in used:
      err(gd.line, "duplicate name: '" & gd.name & "'")
    used.incl gd.name
    c.globals[gd.name] = gd.typ
  var anyThread = false
  for r in m.routines:
    if r.name in used:
      err(r.line, "duplicate name: '" & r.name & "'")
    used.incl r.name
    c.allRoutines.incl r.name
    c.routineTab[r.name] = r
    if r.kind == rkThread:
      anyThread = true
  if not anyThread:
    err(1, "a nifty program needs at least one thread (thread name() = ...)")
  for r in m.routines:
    c.cur = r
    c.lockDepth = 0
    c.loopLocks = @[]
    case r.kind
    of rkThread:
      if r.params.len > 0:
        err(r.line, "threads take no parameters")
      if not r.ret.isNil:
        err(r.line, "threads do not return a value")
    of rkFunc:
      if r.ret.isNil:
        err(r.line, "func must have a return type (use proc for side effects)")
    of rkProc:
      discard
    var paramScope = initTable[string, Sym]()
    for pm in r.params:
      if pm.typ.kind == tyLock:
        err(r.line, "a Lock cannot be a parameter")
      if pm.isVar and r.kind == rkFunc:
        err(r.line, "func parameters are read-only; var parameters are not allowed")
      if pm.name in paramScope or pm.name in used:
        err(r.line, "duplicate or shadowing parameter name: '" & pm.name & "'")
      paramScope[pm.name] = Sym(kind: syParam, typ: pm.typ,
        mutable: pm.isVar, isVarParam: pm.isVar)
    c.scopes = @[paramScope, initTable[string, Sym]()]
    for s in r.body:
      c.checkStmt(s, true)
    if not r.ret.isNil and not alwaysReturns(r.body):
      err(r.line, "'" & r.name & "': not all code paths return a value")
    c.checked.incl r.name

# ---------------------------------------------------------------------------
# C code generation
# ---------------------------------------------------------------------------

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

proc where(g: Gen, line: int): string =
  cQuote(g.src & ":" & $line)

proc cBase(t: Typ): string =
  case t.kind
  of tyBool: "bool"
  else: "int64_t"

proc cDecl(name: string, t: Typ): string =
  var base = t
  var dims = ""
  while base.kind == tyArray:
    dims.add "[" & $base.len & "]"
    base = base.elem
  cBase(base) & " " & name & dims

proc isScalar(t: Typ): bool =
  t.kind in {tyInt, tyBool}

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
      if e.isVarParam and e.typ.isScalar:
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
    of "/": "ni_div(" & a & ", " & b & ", " & g.where(e.line) & ")"
    of "%": "ni_mod(" & a & ", " & b & ", " & g.where(e.line) & ")"
    of "and": "(" & a & " && " & b & ")"
    of "or": "(" & a & " || " & b & ")"
    else: "(" & a & " " & e.sval & " " & b & ")"
  of ekIndex:
    g.genExpr(e.kids[0]) & "[ni_idx(" & g.genExpr(e.kids[1]) & ", " &
      $e.kids[0].typ.len & "LL, " & g.where(e.line) & ")]"
  of ekCall:
    let r = g.routines[e.sval]
    var parts: seq[string]
    for i, a in e.kids:
      if r.params[i].isVar and r.params[i].typ.isScalar:
        parts.add "&" & g.genExpr(a)
      else:
        parts.add g.genExpr(a)
    "f_" & e.sval & "(" & parts.join(", ") & ")"

proc genStmt(g: var Gen, s: Stmt)

proc genBlock(g: var Gen, body: seq[Stmt]) =
  inc g.ind
  for s in body:
    g.genStmt(s)
  dec g.ind

proc genStmt(g: var Gen, s: Stmt) =
  case s.kind
  of skVar, skLet:
    if s.typ.kind == tyArray:
      g.put cDecl("v_" & s.name, s.typ) & " = {0};"
    else:
      let init =
        if s.init != nil: g.genExpr(s.init)
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
  of skWithLock:
    g.put "pthread_mutex_lock(&g_" & s.name & ");"
    g.put "{"
    g.genBlock(s.body)
    g.put "}"
    g.put "pthread_mutex_unlock(&g_" & s.name & ");"
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
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>

static int64_t ni_idx(int64_t i, int64_t len, const char *where) {
  if (i < 0 || i >= len) {
    fprintf(stderr, "nifty: index %lld out of bounds (0 ..< %lld) at %s\n",
      (long long)i, (long long)len, where);
    exit(1);
  }
  return i;
}

static int64_t ni_div(int64_t a, int64_t b, const char *where) {
  if (b == 0) {
    fprintf(stderr, "nifty: division by zero at %s\n", where);
    exit(1);
  }
  return a / b;
}

static int64_t ni_mod(int64_t a, int64_t b, const char *where) {
  if (b == 0) {
    fprintf(stderr, "nifty: modulo by zero at %s\n", where);
    exit(1);
  }
  return a % b;
}
"""

proc generate(m: Module, src: string): string =
  var g = Gen(src: src)
  for r in m.routines:
    g.routines[r.name] = r
  g.put "// Generated by nifty from " & src & ". Do not edit."
  g.o.add cPrelude
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
        if pm.isVar and pm.typ.isScalar:
          ps.add cBase(pm.typ) & " *p_" & pm.name
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

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

proc compileToC*(src: string, moduleName: string): string =
  ## Compile nifty source text to a C translation unit.
  var p = Parser(toks: tokenize(src))
  let m = p.parseModule()
  check(m)
  generate(m, moduleName)

when isMainModule:
  import std/os

  const usage = """
nifty - compile a .nifty file to C and build it with cc

usage:
  nifty [run] file.nifty [options]   build and, if there are no errors, run (default)
  nifty build file.nifty [options]   build only

options:
  -o binary   output binary path (default: source path without extension)
  --emit-c    only write the .c file, do not run cc
"""
  var cmd = "run"
  var sawCmd = false
  var srcPath = ""
  var outPath = ""
  var emitOnly = false
  let params = commandLineParams()
  var i = 0
  while i < params.len:
    let a = params[i]
    case a
    of "run", "build":
      if sawCmd or srcPath.len > 0: quit(usage, 1)
      cmd = a
      sawCmd = true
    of "-o":
      inc i
      if i >= params.len: quit(usage, 1)
      outPath = params[i]
    of "--emit-c", "-c":
      emitOnly = true
    of "-h", "--help":
      echo usage
      quit(0)
    else:
      if srcPath.len > 0: quit(usage, 1)
      srcPath = a
    inc i
  if srcPath == "":
    quit(usage, 1)
  let modName = srcPath.extractFilename
  var cCode = ""
  try:
    cCode = compileToC(readFile(srcPath), modName)
  except NiftyError as e:
    quit("nifty: " & srcPath & ": " & e.msg, 1)
  let base = srcPath.changeFileExt("")
  let cPath = base & ".c"
  writeFile(cPath, cCode)
  if emitOnly:
    echo cPath
    quit(0)
  let bin = if outPath.len > 0: outPath else: base
  if execShellCmd("cc -O2 -pthread -o " & quoteShell(bin) & " " & quoteShell(cPath)) != 0:
    quit("nifty: C compilation failed", 1)
  echo "built ", bin
  if cmd == "run":
    let exe = if '/' in bin: bin else: "./" & bin
    quit(execShellCmd(quoteShell(exe)))

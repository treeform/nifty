## Recursive-descent parser: tokens -> Module AST.
## Declare-before-use is enforced structurally: consts and types must exist
## before they are referenced in later declarations.

import std/[strutils, tables]
import common, lexer, types

type
  Parser = object
    toks: seq[Token]
    pos: int
    consts: Table[string, int64] # needed at parse time for array lengths
    types: Table[string, Typ]    # declared object types

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

proc parseExpr(p: var Parser): Expr
proc evalConst(p: Parser, e: Expr): int64

proc parseType(p: var Parser): Typ =
  let t = p.peek
  if t.kind == tkIdent and
      (t.text in ["int", "bool", "Lock", "array"] or t.text in p.types):
    discard p.next
    case t.text
    of "int":
      intType()
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
      p.types[t.text]
  else:
    # Range type: constExpr .. constExpr  (or ..< for an exclusive bound).
    if t.kind == tkIdent and t.text notin p.consts:
      err(t.line, "unknown type: '" & t.text & "'")
    let lo = p.evalConst(p.parseExpr())
    var inclusive = true
    if p.atOp("..<"):
      inclusive = false
    elif not p.atOp(".."):
      err(t.line, "type expected")
    discard p.next
    var hi = p.evalConst(p.parseExpr())
    if not inclusive:
      hi = hi - 1
    if hi < lo:
      err(t.line, "empty range type: " & $lo & " .. " & $hi)
    intType(lo, hi)

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
    elif p.atOp("."):
      discard p.next
      result = Expr(kind: ekField, line: result.line, sval: p.expectIdent(),
        kids: @[result])
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
      if e.kind notin {ekIdent, ekIndex, ekField}:
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
  of "with":
    discard p.next
    let target = p.expectIdent()
    result = Stmt(kind: skWith, line: t.line, name: target,
      lhs: Expr(kind: ekIdent, line: t.line, sval: target))
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
    of "object":
      # object Name = with fields on indented lines. A type can only refer
      # to types declared above it, so recursive types (and thus unknown
      # sizes) are impossible by construction.
      discard p.next
      let name = p.expectIdent()
      if name in p.types or name in p.consts or
          name in ["int", "bool", "Lock", "array"]:
        err(t.line, "duplicate or reserved type name: '" & name & "'")
      p.expectOp("=")
      p.expectNewline()
      if p.peek.kind != tkIndent:
        err(t.line, "object needs at least one field on an indented line")
      discard p.next
      var typ = Typ(kind: tyObject, name: name)
      while p.peek.kind notin {tkDedent, tkEof}:
        var names = @[p.expectIdent()]
        while p.atOp(","):
          discard p.next
          names.add p.expectIdent()
        p.expectOp(":")
        let ft = p.parseType()
        if ft.kind == tyLock:
          err(p.peek.line, "Lock cannot be a field; a Lock must be a global")
        for n in names:
          for f in typ.fields:
            if f.name == n:
              err(p.peek.line, "duplicate field: '" & n & "'")
          typ.fields.add Field(name: n, typ: ft)
        p.expectNewline()
      if p.peek.kind == tkDedent:
        discard p.next
      p.types[name] = typ
      result.types.add TypeDef(name: name, typ: typ, line: t.line)
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
        "' (expected const, var, object, func, proc, or thread)")

proc parse*(toks: seq[Token]): Module =
  ## Parse a token stream into a Module AST.
  var p = Parser(toks: toks)
  p.parseModule()

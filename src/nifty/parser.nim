## Recursive-descent parser: tokens -> Module AST.
## Named type shapes support forward references; routines retain source order.

import std/[strutils, tables, sequtils]
import common, lexer, types

type
  Parser = object
    toks: seq[Token]
    pos: int
    consts: Table[string, int64] # needed at parse time for array lengths
    types: Table[string, Typ]    # declared object types
    optionals: seq[tuple[source, target: Typ]]
    pendingSizes: seq[tuple[typ: Typ, line: int]]
    predeclared: bool
    aliases: Table[string, Typ]
    allowTypeVar: bool           # $names legal (generic parameter lists only)

proc peek(p: Parser): Token =
  p.toks[p.pos]

proc next(p: var Parser): Token =
  result = p.toks[p.pos]
  inc p.pos

proc atOp(p: Parser, s: string): bool =
  p.peek.kind == OpToken and p.peek.text == s

proc atIdent(p: Parser, s: string): bool =
  p.peek.kind == IdentToken and p.peek.text == s

proc expectOp(p: var Parser, s: string) =
  if not p.atOp(s):
    err(p.peek.line, "expected '" & s & "'")
  discard p.next

proc expectIdent(p: var Parser): string =
  if p.peek.kind != IdentToken:
    err(p.peek.line, "identifier expected")
  p.next.text

proc expectKeyword(p: var Parser, s: string) =
  if not p.atIdent(s):
    err(p.peek.line, "expected '" & s & "'")
  discard p.next

proc expectNewline(p: var Parser) =
  if p.peek.kind notin {NewlineToken, EofToken}:
    err(p.peek.line, "end of line expected")
  if p.peek.kind == NewlineToken:
    discard p.next

proc parseIntLit(t: Token): int64 =
  try:
    parseBiggestInt(t.text)
  except ValueError:
    err(t.line, "integer literal is too large for int64")

proc hasTypeVar(t: Typ): bool =
  if t.isNil:
    return false
  if t.kind == TypeVarType or t.lenVar != "":
    return true
  hasTypeVar(t.elem) or hasTypeVar(t.val)

proc seqHasCapacity(p: Parser): bool =
  ## Distinguish seq[N, T] from seq[T] inside its opening bracket.
  var depth = 0
  for i in p.pos ..< p.toks.len:
    let token = p.toks[i]
    if token.kind == EofToken:
      break
    if token.kind != OpToken:
      continue
    case token.text
    of "[":
      inc depth
    of "]":
      if depth == 0:
        return false
      dec depth
    of ",":
      if depth == 0:
        return true
    else:
      discard
  false

proc parseExpr(p: var Parser): Expr
proc evalConst(p: Parser, e: Expr): int64
proc parseType(p: var Parser): Typ

proc parseTypeCore(p: var Parser): Typ =
  if p.atOp("$"):
    if not p.allowTypeVar:
      err(p.peek.line, "'$' type variables are only allowed in generic " &
        "parameter lists")
    discard p.next
    return Typ(kind: TypeVarType, gname: p.expectIdent())
  let t = p.peek
  if t.kind == IdentToken and
      (t.text in ["int", "bool", "Lock", "array", "seq", "string", "cstring", "set",
        "queue", "channel", "map", "int8", "uint8", "char", "int16", "uint16",
        "int32", "uint32", "int64", "uint64", "float32", "float64"] or
       t.text in p.types):
    discard p.next
    case t.text
    of "int":
      intType()
    of "int8":
      sizedInt(-128, 127, 1, "int8")
    of "uint8":
      sizedInt(0, 255, 1, "uint8")
    of "char":
      # One byte, always: a UTF-8 code unit. A Unicode code point may be
      # several chars; strings are always UTF-8 bytes.
      sizedInt(0, 255, 1, "char")
    of "int16":
      sizedInt(-32768, 32767, 2, "int16")
    of "uint16":
      sizedInt(0, 65535, 2, "uint16")
    of "int32":
      sizedInt(-2147483648, 2147483647, 4, "int32")
    of "uint32":
      sizedInt(0, 4294967295, 4, "uint32")
    of "int64":
      sizedInt(low(int64), high(int64), 8, "int64")
    of "uint64":
      # Stored as 8 unsigned bytes for binary compatibility; nifty
      # values stay in 0 .. int64.high (the interval engine's world).
      sizedInt(0, high(int64), 8, "uint64")
    of "float32":
      floatType(4, "float32")
    of "float64":
      floatType(8, "float64")
    of "bool":
      Typ(kind: BoolType)
    of "Lock":
      Typ(kind: LockType)
    of "array", "seq", "queue", "channel":
      p.expectOp("[")
      var n: int64 = 0
      var lv = ""
      let dynamic = t.text == "seq" and not p.seqHasCapacity()
      if dynamic:
        discard
      elif p.atOp("$"):
        if not p.allowTypeVar:
          err(p.peek.line, "'$' size variables are only allowed in generic " &
            "parameter lists")
        discard p.next
        lv = p.expectIdent()
      else:
        let lt = p.next
        if lt.kind == IntToken:
          n = parseIntLit(lt)
        elif lt.kind == IdentToken and lt.text in p.consts:
          n = p.consts[lt.text]
        else:
          err(lt.line, t.text & " capacity must be an integer literal or a const")
        if n <= 0:
          err(lt.line, t.text & " capacity must be positive")
      if not dynamic:
        p.expectOp(",")
      let e = p.parseType()
      if not p.predeclared and e.kind == LockType:
        err(t.line, "Lock cannot be a " & t.text & " element")
      if not p.predeclared and
          t.text in ["seq", "queue", "channel"] and e.kind == ArrayType:
        err(t.line, "a " & t.text & " element cannot be a plain array; " &
          "wrap it in an object")
      if not p.predeclared and e.kind == ChannelType:
        err(t.line, "a channel can only be a global, not a " & t.text &
          " element")
      p.expectOp("]")
      Typ(kind: (case t.text
        of "seq": SeqType
        of "queue": QueueType
        of "channel": ChannelType
        else: ArrayType), len: n, lenVar: lv, elem: e, dynamic: dynamic)
    of "map":
      # map[lo .. hi, V] (dense) or map[N, K, V] (sorted sparse)
      p.expectOp("[")
      let n = p.evalConst(p.parseExpr())
      if p.atOp("..") or p.atOp("..<"):
        let inclusive = p.peek.text == ".."
        discard p.next
        var hi = p.evalConst(p.parseExpr())
        if not inclusive:
          if hi == low(int64):
            err(t.line, "empty key range for map")
          dec hi
        if hi < n:
          err(t.line, "empty key range for map")
        if n < -1_000_000_000 or hi > 1_000_000_000 or
            hi - n + 1 > 16_777_216:
          err(t.line, "map key range is too large (max 16777216 keys)")
        p.expectOp(",")
        let v = p.parseType()
        if not p.predeclared and v.kind in {LockType, ChannelType, ArrayType}:
          err(t.line, "a map value cannot be a " & $v &
            "; wrap arrays in an object")
        p.expectOp("]")
        Typ(kind: DenseMapType, elem: intType(n, hi), val: v)
      else:
        if n <= 0:
          err(t.line, "map capacity must be positive")
        p.expectOp(",")
        let k = p.parseType()
        if not p.predeclared and
            (k.kind notin {IntType, StringType} or k.opt or k.dynamic):
          err(t.line, "map keys must be ints (or ranges) or string[N], got " & $k)
        p.expectOp(",")
        let v = p.parseType()
        if not p.predeclared and v.kind in {LockType, ChannelType, ArrayType}:
          err(t.line, "a map value cannot be a " & $v &
            "; wrap arrays in an object")
        p.expectOp("]")
        Typ(kind: SparseMapType, len: n, elem: k, val: v)
    of "set":
      p.expectOp("[")
      let e = p.parseType()
      if not p.predeclared and
          (e.kind != IntType or e.isFullRange or e.opt):
        err(t.line, "set needs a range element type, e.g. set[0 .. 63]")
      if not p.predeclared and
          (e.rlo < -1_000_000_000 or e.rhi > 1_000_000_000 or
          e.rhi - e.rlo + 1 > 16_777_216):
        err(t.line, "set range is too large (max 16777216 values)")
      p.expectOp("]")
      Typ(kind: SetType, elem: e)
    of "cstring":
      Typ(kind: CStringType, dynamic: true)
    of "string":
      if not p.atOp("["):
        return Typ(kind: StringType, dynamic: true)
      p.expectOp("[")
      var n: int64 = 0
      var lv = ""
      if p.atOp("$"):
        if not p.allowTypeVar:
          err(p.peek.line, "'$' size variables are only allowed in generic " &
            "parameter lists")
        discard p.next
        lv = p.expectIdent()
      else:
        let lt = p.next
        if lt.kind == IntToken:
          n = parseIntLit(lt)
        elif lt.kind == IdentToken and lt.text in p.consts:
          n = p.consts[lt.text]
        else:
          err(lt.line, "string capacity must be an integer literal or a const")
        if n <= 0:
          err(lt.line, "string capacity must be positive")
      p.expectOp("]")
      Typ(kind: StringType, len: n, lenVar: lv)
    else:
      p.types[t.text]
  else:
    # Range type: constExpr .. constExpr  (or ..< for an exclusive bound).
    if t.kind == IdentToken and t.text notin p.consts:
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
      if hi == low(int64):
        err(t.line, "empty range type")
      dec hi
    if hi < lo:
      err(t.line, "empty range type: " & $lo & " .. " & $hi)
    intType(lo, hi)

proc parseType(p: var Parser): Typ =
  let line = p.peek.line
  result = p.parseTypeCore()
  if p.atOp("?"):
    discard p.next
    if result.kind notin {IntType, ObjectType, UnionType, StringType,
        OpaqueType}:
      err(p.peek.line, "only ints, objects, unions, strings, and opaque " &
        "handles can be optional")
    let source = result
    result = optOf(result)
    if p.predeclared:
      p.optionals.add (source, result)
  if p.predeclared:
    p.pendingSizes.add (result, line)
  else:
    discard typeSize(result, line)

proc parseAtom(p: var Parser): Expr =
  let t = p.peek
  case t.kind
  of IntToken:
    discard p.next
    result = Expr(kind: IntExpr, line: t.line, ival: parseIntLit(t))
  of FloatToken:
    discard p.next
    result = Expr(kind: FloatExpr, line: t.line,
      fval: parseFloat(t.text))
  of StrToken:
    discard p.next
    result = Expr(kind: StrExpr, line: t.line, sval: t.text)
  of IdentToken:
    discard p.next
    if t.text == "true":
      result = Expr(kind: BoolExpr, line: t.line, bval: true)
    elif t.text == "false":
      result = Expr(kind: BoolExpr, line: t.line, bval: false)
    elif t.text == "none":
      result = Expr(kind: NoneExpr, line: t.line)
    else:
      result = Expr(kind: IdentExpr, line: t.line, sval: t.text)
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
      result = Expr(kind: IndexExpr, line: result.line, kids: @[result, idx])
    elif p.atOp("."):
      discard p.next
      let fname = p.expectIdent()
      if p.atOp("("):
        # Builtin method call: s.add(x), s.pop(), s.clear(), s.push(x)
        discard p.next
        var m = Expr(kind: MethodExpr, line: result.line, sval: fname,
          kids: @[result])
        if not p.atOp(")"):
          m.kids.add p.parseExpr()
          while p.atOp(","):
            discard p.next
            m.kids.add p.parseExpr()
        p.expectOp(")")
        result = m
      else:
        result = Expr(kind: FieldExpr, line: result.line, sval: fname,
          kids: @[result])
    elif p.atOp("("):
      if result.kind != IdentExpr:
        err(result.line, "only a named func or proc can be called")
      discard p.next
      var args: seq[Expr]
      if not p.atOp(")"):
        args.add p.parseExpr()
        while p.atOp(","):
          discard p.next
          args.add p.parseExpr()
      p.expectOp(")")
      result = Expr(kind: CallExpr, line: result.line, sval: result.sval, kids: args)
    else:
      break

proc parseUnary(p: var Parser): Expr =
  if p.atOp("-"):
    let line = p.next.line
    Expr(kind: NegExpr, line: line, kids: @[p.parseUnary()])
  else:
    p.parsePostfix()

proc parseMul(p: var Parser): Expr =
  result = p.parseUnary()
  while p.peek.kind == OpToken and p.peek.text in ["*", "/", "%"]:
    let op = p.next.text
    result = Expr(kind: BinExpr, line: result.line, sval: op,
      kids: @[result, p.parseUnary()])

proc parseAdd(p: var Parser): Expr =
  result = p.parseMul()
  while p.peek.kind == OpToken and p.peek.text in ["+", "-"]:
    let op = p.next.text
    result = Expr(kind: BinExpr, line: result.line, sval: op,
      kids: @[result, p.parseMul()])

proc parseCmp(p: var Parser): Expr =
  result = p.parseAdd()
  if p.peek.kind == OpToken and p.peek.text in ["==", "!=", "<", "<=", ">", ">="]:
    let op = p.next.text
    result = Expr(kind: BinExpr, line: result.line, sval: op,
      kids: @[result, p.parseAdd()])

proc parseNot(p: var Parser): Expr =
  if p.atIdent("not"):
    let line = p.next.line
    Expr(kind: NotExpr, line: line, kids: @[p.parseNot()])
  else:
    p.parseCmp()

proc parseAnd(p: var Parser): Expr =
  result = p.parseNot()
  while p.atIdent("and"):
    discard p.next
    result = Expr(kind: BinExpr, line: result.line, sval: "and",
      kids: @[result, p.parseNot()])

proc parseExpr(p: var Parser): Expr =
  result = p.parseAnd()
  while p.atIdent("or"):
    discard p.next
    result = Expr(kind: BinExpr, line: result.line, sval: "or",
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
    Stmt(kind: (if t.text == "let": LetStmt else: VarStmt), line: t.line,
      name: name, typ: typ, init: init)
  of "return":
    discard p.next
    var val: Expr = nil
    if p.peek.kind notin {NewlineToken, EofToken, DedentToken}:
      val = p.parseExpr()
    Stmt(kind: ReturnStmt, line: t.line, value: val)
  of "break":
    discard p.next
    Stmt(kind: BreakStmt, line: t.line)
  of "echo":
    discard p.next
    var args = @[p.parseExpr()]
    while p.atOp(","):
      discard p.next
      args.add p.parseExpr()
    Stmt(kind: EchoStmt, line: t.line, args: args)
  of "discard":
    discard p.next
    Stmt(kind: DiscardStmt, line: t.line, value: p.parseExpr())
  else:
    # Command syntax: when a call is the whole statement, the parens
    # are optional - "bump counter" is bump(counter). The token after
    # the name must begin an argument (a name or a literal), so
    # operators still mean themselves: "a - 1" stays arithmetic.
    if t.kind == IdentToken and p.pos + 1 < p.toks.len and
        p.toks[p.pos + 1].kind in {IdentToken, IntToken, FloatToken,
          StrToken}:
      discard p.next
      var call = Expr(kind: CallExpr, line: t.line, sval: t.text)
      call.kids.add p.parseExpr()
      while p.atOp(","):
        discard p.next
        call.kids.add p.parseExpr()
      return Stmt(kind: CallStmt, line: t.line, value: call)
    let e = p.parseExpr()
    if p.atOp("="):
      discard p.next
      if e.kind notin {IdentExpr, IndexExpr, FieldExpr}:
        err(e.line, "cannot assign to this expression")
      Stmt(kind: AssignStmt, line: t.line, lhs: e, rhs: p.parseExpr())
    else:
      if e.kind notin {CallExpr, MethodExpr}:
        err(e.line, "expression has no effect")
      Stmt(kind: CallStmt, line: t.line, value: e)

proc parseBlock(p: var Parser): seq[Stmt] =
  p.expectNewline()
  if p.peek.kind != IndentToken:
    err(p.peek.line, "indented block expected")
  discard p.next
  while p.peek.kind notin {DedentToken, EofToken}:
    result.add p.parseStmt()
  if p.peek.kind == DedentToken:
    discard p.next

proc parseBody(p: var Parser): seq[Stmt] =
  ## Either an indented block, or a single simple statement on the same line.
  if p.peek.kind == NewlineToken:
    p.parseBlock()
  else:
    let s = p.parseSimpleStmt()
    p.expectNewline()
    @[s]

proc parseStmt(p: var Parser): Stmt =
  let t = p.peek
  if t.kind != IdentToken:
    err(t.line, "statement expected")
  case t.text
  of "if":
    discard p.next
    result = Stmt(kind: IfStmt, line: t.line)
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
    result = Stmt(kind: WhileStmt, line: t.line, cond: p.parseExpr())
    if p.atIdent("max"):
      discard p.next
      let n = p.evalConst(p.parseExpr())
      if n < 1:
        err(t.line, "max bound must be at least 1")
      result.maxTrips = n
    p.expectOp(":")
    result.body = p.parseBody()
  of "for":
    discard p.next
    let vname = p.expectIdent()
    var vname2 = ""
    if p.atOp(","):
      discard p.next
      vname2 = p.expectIdent()
    p.expectKeyword("in")
    let first = p.parseExpr()
    if p.atOp("..<") or p.atOp(".."):
      result = Stmt(kind: ForStmt, line: t.line, name: vname, lo: first)
      result.inclusive = p.peek.text == ".."
      discard p.next
      result.hi = p.parseExpr()
    elif p.atOp(":"):
      # for x in s: - iterate a container (for k, v in m: over maps)
      result = Stmt(kind: ForEachStmt, line: t.line, name: vname,
        name2: vname2, value: first)
    else:
      err(p.peek.line, "expected '..', '..<' (a range) or ':' (iterate a " &
        "seq/string) in for loop")
    p.expectOp(":")
    result.body = p.parseBody()
  of "loop":
    discard p.next
    result = Stmt(kind: LoopStmt, line: t.line)
    p.expectOp(":")
    result.body = p.parseBody()
  of "block":
    discard p.next
    result = Stmt(kind: BlockStmt, line: t.line)
    p.expectOp(":")
    result.body = p.parseBody()
  of "with":
    discard p.next
    let target = p.expectIdent()
    result = Stmt(kind: WithStmt, line: t.line, name: target,
      lhs: Expr(kind: IdentExpr, line: t.line, sval: target))
    p.expectOp(":")
    result.body = p.parseBody()
  else:
    result = p.parseSimpleStmt()
    p.expectNewline()

proc evalConst(p: Parser, e: Expr): int64 =
  case e.kind
  of IntExpr:
    e.ival
  of IdentExpr:
    if e.sval in p.consts:
      p.consts[e.sval]
    else:
      err(e.line, "unknown const: '" & e.sval & "'")
  of NegExpr:
    let v = p.evalConst(e.kids[0])
    if v == low(int64):
      err(e.line, "constant expression overflows int64")
    -v
  of BinExpr:
    let a = p.evalConst(e.kids[0])
    let b = p.evalConst(e.kids[1])
    case e.sval
    of "+":
      if (b > 0 and a > high(int64) - b) or (b < 0 and a < low(int64) - b):
        err(e.line, "constant expression overflows int64")
      a + b
    of "-":
      if (b < 0 and a > high(int64) + b) or (b > 0 and a < low(int64) + b):
        err(e.line, "constant expression overflows int64")
      a - b
    of "*":
      let overflow =
        if a > 0:
          (b > 0 and a > high(int64) div b) or
            (b < 0 and b < low(int64) div a)
        elif a < 0:
          (b > 0 and a < low(int64) div b) or
            (b < 0 and a < high(int64) div b)
        else:
          false
      if overflow:
        err(e.line, "constant expression overflows int64")
      a * b
    of "/":
      if b == 0: err(e.line, "division by zero in const")
      if a == low(int64) and b == -1:
        err(e.line, "constant expression overflows int64")
      a div b
    of "%":
      if b == 0: err(e.line, "modulo by zero in const")
      if a == low(int64) and b == -1:
        0
      else:
        a mod b
    else:
      err(e.line, "operator not allowed in const expression: " & e.sval)
  else:
    err(e.line, "constant expression expected")

proc parseModule(p: var Parser): Module =
  result = Module()
  while p.peek.kind != EofToken:
    if p.peek.kind == NewlineToken:
      discard p.next
      continue
    let t = p.peek
    if t.kind != IdentToken:
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
      # Named shapes are reserved before parsing their field graphs.
      discard p.next
      let name = p.expectIdent()
      if (name in p.types and not p.predeclared) or name in p.consts or
          name in ["int", "bool", "Lock", "array"]:
        err(t.line, "duplicate or reserved type name: '" & name & "'")
      p.expectOp("=")
      p.expectNewline()
      let hasFields = p.peek.kind == IndentToken
      if hasFields:
        discard p.next
      let typ =
        if name in p.types: p.types[name]
        else: Typ(kind: ObjectType, name: name)
      if hasFields and p.atIdent("discard"):
        discard p.next
        p.expectNewline()
      while hasFields and p.peek.kind notin {DedentToken, EofToken}:
        var names = @[p.expectIdent()]
        while p.atOp(","):
          discard p.next
          names.add p.expectIdent()
        p.expectOp(":")
        let ft = p.parseType()
        if ft.kind in {LockType, ChannelType}:
          err(p.peek.line, $ft & " cannot be a field; it must be a global")
        for n in names:
          for f in typ.fields:
            if f.name == n:
              err(p.peek.line, "duplicate field: '" & n & "'")
          typ.fields.add Field(name: n, typ: ft)
        p.expectNewline()
      if hasFields and p.peek.kind == DedentToken:
        discard p.next
      p.types[name] = typ
      result.types.add TypeDef(name: name, typ: typ, line: t.line)
    of "type":
      discard p.next
      let name = p.expectIdent()
      if name in p.consts:
        err(t.line, "duplicate or reserved type name: '" & name & "'")
      p.expectOp("=")
      let typ = p.types[name]
      if p.atIdent("opaque"):
        discard p.next
        typ.kind = OpaqueType
        result.types.add TypeDef(name: name, typ: typ, line: t.line)
        p.expectNewline()
        continue
      let first = p.parseType()
      if p.atIdent("or"):
        typ.kind = UnionType
        typ.members = @[first]
        while p.atIdent("or"):
          discard p.next
          typ.members.add p.parseType()
      else:
        p.aliases[name] = first
      result.types.add TypeDef(name: name, typ: typ, line: t.line)
      p.expectNewline()
    of "extern":
      # extern "lib": - binary bindings. We declare the shapes ourselves
      # in plain sized types and link against the symbols; no headers.
      discard p.next
      if p.peek.kind != StrToken:
        err(t.line, "extern needs a library name string: extern \"libc\":")
      let lib = p.next.text
      if lib notin result.externLibs:
        result.externLibs.add lib
      p.expectOp(":")
      p.expectNewline()
      if p.peek.kind != IndentToken:
        err(p.peek.line, "an indented block of proc declarations expected")
      discard p.next
      while p.peek.kind != DedentToken:
        if p.peek.kind == NewlineToken:
          discard p.next
          continue
        p.expectKeyword("proc")
        var r = Routine(kind: ProcRoutine, name: p.expectIdent(),
          line: p.peek.line, externLib: lib)
        if p.peek.kind == StrToken:
          r.cname = p.next.text # proc bindSock "bind" (...)
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
            var boundedBy = ""
            if p.atIdent("boundedBy"):
              discard p.next
              if p.peek.kind == IntToken:
                boundedBy = $parseIntLit(p.next)
              else:
                boundedBy = p.expectIdent()
            for n in names:
              r.params.add Param(name: n, typ: ty, isVar: isVar,
                boundedBy: boundedBy)
            if p.atOp(","):
              discard p.next
            else:
              break
        p.expectOp(")")
        if p.atOp(":"):
          discard p.next
          r.ret = p.parseType()
        p.expectNewline()
        result.routines.add r
      discard p.next
    of "func", "proc", "thread":
      let startPos = p.pos
      discard p.next
      let kind = case t.text
        of "func": FuncRoutine
        of "proc": ProcRoutine
        else: ThreadRoutine
      # thread 4 worker() = ... declares four identical threads; the
      # count is an int literal or a const, like any capacity.
      var count = 1
      if kind == ThreadRoutine:
        let ct = p.peek
        if ct.kind == IntToken:
          discard p.next
          count = int(parseIntLit(ct))
        elif ct.kind == IdentToken and p.pos + 1 < p.toks.len and
            p.toks[p.pos + 1].kind == IdentToken:
          if ct.text notin p.consts:
            err(ct.line, "unknown const '" & ct.text & "' as thread count")
          discard p.next
          count = int(p.consts[ct.text])
        if count < 1:
          err(ct.line, "a thread count must be at least 1")
      var r = Routine(kind: kind, count: count, name: p.expectIdent(),
        line: t.line)
      p.expectOp("(")
      p.allowTypeVar = true
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
      p.allowTypeVar = false
      var isGen = false
      for pm in r.params:
        if hasTypeVar(pm.typ):
          isGen = true
      if isGen:
        # A generic: keep the whole declaration as tokens; each
        # instantiation substitutes the $names and reparses.
        if kind == ThreadRoutine:
          err(t.line, "threads cannot be generic")
        r.generic = true
        while not p.atOp("=") and p.peek.kind != EofToken:
          discard p.next
        p.expectOp("=")
        if p.peek.kind == NewlineToken:
          discard p.next
        if p.peek.kind != IndentToken:
          err(p.peek.line, "an indented body expected")
        discard p.next
        var depth = 1
        while depth > 0:
          case p.peek.kind
          of IndentToken: inc depth
          of DedentToken: dec depth
          of EofToken:
            err(p.peek.line, "unexpected end of file inside '" & r.name & "'")
          else: discard
          discard p.next
        r.toks = p.toks[startPos ..< p.pos]
        r.constsSnap = p.consts
        r.typesSnap = p.types
      else:
        if p.atOp(":"):
          discard p.next
          r.ret = p.parseType()
        p.expectOp("=")
        r.body = p.parseBody()
      result.routines.add r
    else:
      err(t.line, "unknown declaration: '" & t.text &
        "' (expected const, var, type, object, func, proc, thread, or extern; " &
        "import must be at the top of the file)")

proc predeclare(p: var Parser) =
  ## Reserve named shapes without making later routines visible.
  var depth = 0
  for i, token in p.toks:
    case token.kind
    of IndentToken: inc depth
    of DedentToken: dec depth
    else: discard
    if depth != 0 or token.kind != IdentToken or
        token.text notin ["object", "type"]:
      continue
    if i > 0 and p.toks[i - 1].kind notin {NewlineToken, DedentToken}:
      continue
    if i + 1 >= p.toks.len or p.toks[i + 1].kind != IdentToken:
      continue
    let name = p.toks[i + 1].text
    if name in p.types or name in ["int", "bool", "Lock", "array", "seq",
        "string", "set", "queue", "channel", "map", "int8", "uint8",
        "char", "int16", "uint16", "int32", "uint32", "int64",
        "uint64", "float32", "float64", "opaque", "cstring"]:
      err(token.line, "duplicate or reserved type name: '" & name & "'")
    p.types[name] = Typ(kind: ObjectType, name: name)
  p.predeclared = true

proc resolveAlias(p: var Parser, name: string, visiting: var seq[string],
    finished: var seq[string]) =
  ## Resolve structural aliases without accepting recursive alias graphs.
  if name in finished or name notin p.aliases:
    return
  if name in visiting:
    err(0, "recursive type alias: '" & name & "'")
  visiting.add name
  let aliases = p.aliases
  proc dependencies(t: Typ): seq[string] =
    if t.isNil:
      return
    if t.name in aliases:
      return @[t.name]
    if t.kind notin {ObjectType, UnionType}:
      result.add dependencies(t.elem)
      result.add dependencies(t.val)
  for dependency in dependencies(p.aliases[name]):
    p.resolveAlias(dependency, visiting, finished)
  for optional in p.optionals:
    if optional.source.kind in {IntType, ObjectType, UnionType, StringType, OpaqueType}:
      optional.target[] = optional.source[]
      optional.target.opt = true
  p.types[name][] = p.aliases[name][]
  discard visiting.pop()
  finished.add name

proc finishTypes(p: var Parser, m: Module) =
  ## Resolve aliases before checking nominal members and finite layouts.
  var visiting: seq[string]
  var finished: seq[string]
  let names = p.aliases.keys.toSeq
  for name in names:
    p.resolveAlias(name, visiting, finished)
  for optional in p.optionals:
    if optional.source.kind notin {IntType, ObjectType, UnionType, StringType, OpaqueType}:
      err(0, "only ints, objects, unions, strings, and opaque handles can be optional")
    optional.target[] = optional.source[]
    optional.target.opt = true
  for definition in m.types:
    let typ = definition.typ
    if typ.kind == UnionType:
      var names: seq[string]
      for member in typ.members:
        if member.kind != ObjectType or member.opt:
          err(definition.line, "union members must be nominal objects")
        if member.name in names:
          err(definition.line, "duplicate union member: '" & member.name & "'")
        names.add member.name
    if typ.kind == ObjectType:
      for field in typ.fields:
        if field.typ.kind in {LockType, ChannelType}:
          err(definition.line, $field.typ &
            " cannot be a field; it must be a global")
  for pending in p.pendingSizes:
    let typ = pending.typ
    case typ.kind
    of ArrayType, SeqType, QueueType, ChannelType:
      let container = case typ.kind
        of ArrayType: "array"
        of SeqType: "seq"
        of QueueType: "queue"
        else: "channel"
      if typ.elem.kind == LockType:
        err(pending.line, "Lock cannot be a " & container & " element")
      if typ.kind != ArrayType and typ.elem.kind == ArrayType:
        err(pending.line, "a " & container &
          " element cannot be a plain array; wrap it in an object")
      if typ.elem.kind == ChannelType:
        err(pending.line, "a channel can only be a global, not a " &
          container & " element")
    of DenseMapType, SparseMapType:
      if typ.val.kind in {LockType, ChannelType, ArrayType}:
        err(pending.line, "a map value cannot be a " & $typ.val &
          "; wrap arrays in an object")
      if typ.kind == SparseMapType and
          (typ.elem.kind notin {IntType, StringType} or
          typ.elem.opt or typ.elem.dynamic):
        err(pending.line, "map keys must be ints (or ranges) or string[N], got " &
          $typ.elem)
    of SetType:
      let elem = typ.elem
      if elem.kind != IntType or elem.isFullRange or elem.opt:
        err(pending.line, "set needs a range element type, e.g. set[0 .. 63]")
      if elem.rlo < -1_000_000_000 or elem.rhi > 1_000_000_000 or
          elem.rhi - elem.rlo + 1 > 16_777_216:
        err(pending.line, "set range is too large (max 16777216 values)")
    else:
      discard
  for definition in m.types:
    discard typeSize(definition.typ, definition.line)
  for global in m.globals:
    discard typeSize(global.typ, global.line)
  for pending in p.pendingSizes:
    discard typeSize(pending.typ, pending.line)

proc parse*(toks: seq[Token]): Module =
  ## Parse a token stream into a Module AST.
  var p = Parser(toks: toks)
  p.predeclare()
  result = p.parseModule()
  p.finishTypes(result)

proc parseInstance*(toks: seq[Token], consts: Table[string, int64],
    otypes: Table[string, Typ]): Routine =
  ## Parse one substituted generic instantiation, with the consts and
  ## object types that were visible where the generic was declared.
  var p = Parser(toks: toks, consts: consts, types: otypes)
  p.parseModule().routines[0]

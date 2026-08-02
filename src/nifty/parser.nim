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
      (t.text in ["int", "bool", "Lock", "array", "seq", "string", "set",
        "queue", "map", "int8", "uint8", "char", "int16", "uint16",
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
    of "array", "seq", "queue":
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
          err(lt.line, t.text & " capacity must be an integer literal or a const")
        if n <= 0:
          err(lt.line, t.text & " capacity must be positive")
      p.expectOp(",")
      let e = p.parseType()
      if e.kind == LockType:
        err(t.line, "Lock cannot be a " & t.text & " element")
      if t.text in ["seq", "queue"] and e.kind == ArrayType:
        err(t.line, "a " & t.text & " element cannot be a plain array; " &
          "wrap it in an object")
      p.expectOp("]")
      Typ(kind: (case t.text
        of "seq": SeqType
        of "queue": QueueType
        else: ArrayType), len: n, lenVar: lv, elem: e)
    of "map":
      # map[lo .. hi, V] (dense) or map[N, K, V] (sorted sparse)
      p.expectOp("[")
      let n = p.evalConst(p.parseExpr())
      if p.atOp("..") or p.atOp("..<"):
        let inclusive = p.peek.text == ".."
        discard p.next
        var hi = p.evalConst(p.parseExpr())
        if not inclusive:
          hi = hi - 1
        if hi < n:
          err(t.line, "empty key range for map")
        if n < -1_000_000_000 or hi > 1_000_000_000 or
            hi - n + 1 > 16_777_216:
          err(t.line, "map key range is too large (max 16777216 keys)")
        p.expectOp(",")
        let v = p.parseType()
        if v.kind in {LockType, ArrayType}:
          err(t.line, "a map value cannot be a " & $v &
            "; wrap arrays in an object")
        p.expectOp("]")
        Typ(kind: DenseMapType, elem: intType(n, hi), val: v)
      else:
        if n <= 0:
          err(t.line, "map capacity must be positive")
        p.expectOp(",")
        let k = p.parseType()
        if not (k.kind == IntType or k.kind == StringType) or k.opt:
          err(t.line, "map keys must be ints (or ranges) or string[N], got " & $k)
        p.expectOp(",")
        let v = p.parseType()
        if v.kind in {LockType, ArrayType}:
          err(t.line, "a map value cannot be a " & $v &
            "; wrap arrays in an object")
        p.expectOp("]")
        Typ(kind: SparseMapType, len: n, elem: k, val: v)
    of "set":
      p.expectOp("[")
      let e = p.parseType()
      if e.kind != IntType or e.isFullRange or e.opt:
        err(t.line, "set needs a range element type, e.g. set[0 .. 63]")
      if e.rlo < -1_000_000_000 or e.rhi > 1_000_000_000 or
          e.rhi - e.rlo + 1 > 16_777_216:
        err(t.line, "set range is too large (max 16777216 values)")
      p.expectOp("]")
      Typ(kind: SetType, elem: e)
    of "string":
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
      hi = hi - 1
    if hi < lo:
      err(t.line, "empty range type: " & $lo & " .. " & $hi)
    intType(lo, hi)

proc parseType(p: var Parser): Typ =
  result = p.parseTypeCore()
  if p.atOp("?"):
    discard p.next
    if result.kind notin {IntType, ObjectType, StringType}:
      err(p.peek.line, "only ints, objects, and strings can be optional")
    result = optOf(result)

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
      if a != 0 and b != 0:
        if (a > 0) == (b > 0):
          if max(abs(a), abs(b)) > high(int64) div min(abs(a), abs(b)):
            err(e.line, "constant expression overflows int64")
        else:
          if a == low(int64) or b == low(int64) or
              abs(a) > high(int64) div abs(b):
            err(e.line, "constant expression overflows int64")
      a * b
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
      if p.peek.kind != IndentToken:
        err(t.line, "object needs at least one field on an indented line")
      discard p.next
      var typ = Typ(kind: ObjectType, name: name)
      while p.peek.kind notin {DedentToken, EofToken}:
        var names = @[p.expectIdent()]
        while p.atOp(","):
          discard p.next
          names.add p.expectIdent()
        p.expectOp(":")
        let ft = p.parseType()
        if ft.kind == LockType:
          err(p.peek.line, "Lock cannot be a field; a Lock must be a global")
        for n in names:
          for f in typ.fields:
            if f.name == n:
              err(p.peek.line, "duplicate field: '" & n & "'")
          typ.fields.add Field(name: n, typ: ft)
        p.expectNewline()
      if p.peek.kind == DedentToken:
        discard p.next
      p.types[name] = typ
      result.types.add TypeDef(name: name, typ: typ, line: t.line)
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
      var r = Routine(kind: kind, name: p.expectIdent(), line: t.line)
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
        "' (expected const, var, object, func, proc, thread, or extern; " &
        "import must be at the top of the file)")

proc parse*(toks: seq[Token]): Module =
  ## Parse a token stream into a Module AST.
  var p = Parser(toks: toks)
  p.parseModule()

proc parseInstance*(toks: seq[Token], consts: Table[string, int64],
    otypes: Table[string, Typ]): Routine =
  ## Parse one substituted generic instantiation, with the consts and
  ## object types that were visible where the generic was declared.
  var p = Parser(toks: toks, consts: consts, types: otypes)
  p.parseModule().routines[0]

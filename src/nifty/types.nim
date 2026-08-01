## The AST and type representation shared by the parser, checker, and codegen.

type
  TypKind* = enum
    IntType, BoolType, StringLitType, LockType, ArrayType, ObjectType, SeqType, StringType, SetType,
    QueueType, DenseMapType, SparseMapType # dense map[range, V]; sorted sparse map[N, K, V]
  Field* = object
    name*: string
    typ*: Typ
  Typ* = ref object
    kind*: TypKind
    len*: int64          # ArrayType/SeqType/StringType: capacity
    elem*: Typ           # ArrayType/SeqType; SetType: the range element type
    name*: string        # ObjectType
    fields*: seq[Field]  # ObjectType
    val*: Typ            # DenseMapType/SparseMapType: the value type
    rlo*, rhi*: int64    # IntType: declared range; full range = plain int
    opt*: bool           # T?: an optional (value + ok flag)

  SymKind* = enum
    ConstSym, GlobalSym, LocalSym, ParamSym

  ExprKind* = enum
    IntExpr, BoolExpr, StrExpr, IdentExpr, BinExpr, NotExpr, NegExpr, IndexExpr, CallExpr,
    FieldExpr, MethodExpr, # MethodExpr: builtin op on a container, kids[0] = base
    NoneExpr # the absent optional value; typed by its destination
  Expr* = ref object
    kind*: ExprKind
    line*: int
    ival*: int64
    bval*: bool
    sval*: string   # StrExpr text, IdentExpr name, BinExpr operator, CallExpr name,
                    # FieldExpr field name
    kids*: seq[Expr]
    typ*: Typ       # set by the checker
    symKind*: SymKind
    isVarParam*: bool
    mut*: bool
    rlo*, rhi*: int64 # proven value range, set by the checker for int exprs
    rnz*: bool        # proven nonzero, set by the checker for int exprs
    wrapOpt*: bool    # codegen: wrap this value into an optional
    unwrapOpt*: bool  # codegen: read .m_val (ident proven ok)
    isOptOk*: bool    # codegen: this FieldExpr reads the optional's ok flag

  StmtKind* = enum
    VarStmt, LetStmt, AssignStmt, IfStmt, WhileStmt, ForStmt, LoopStmt, WithStmt,
    ReturnStmt, BreakStmt, EchoStmt, DiscardStmt, CallStmt,
    ForEachStmt # for x in s: over a seq/string; value = s, name = x
  Elif* = object
    cond*: Expr
    body*: seq[Stmt]
  Stmt* = ref object
    kind*: StmtKind
    line*: int
    name*: string      # var/let/for/with
    name2*: string     # for k, v in m: - the value variable
    typ*: Typ          # var/let declared or inferred type
    typ2*: Typ         # foreach over a map: the value variable's type
    init*: Expr        # var/let initializer
    lhs*, rhs*: Expr   # assign
    cond*: Expr        # while
    maxTrips*: int64   # while: explicit `max N` bound (0 = none)
    tripBound*: int64  # while/for: proven worst-case iterations (checker)
    lo*, hi*: Expr     # for
    inclusive*: bool   # for: .. vs ..<
    value*: Expr       # return/discard/call
    args*: seq[Expr]   # echo
    body*: seq[Stmt]
    elifs*: seq[Elif]  # if: all condition branches, first is the `if`
    elseBody*: seq[Stmt]

  RoutineKind* = enum
    FuncRoutine = "func", ProcRoutine = "proc", ThreadRoutine = "thread"
  Param* = object
    name*: string
    typ*: Typ
    isVar*: bool
  Routine* = ref object
    kind*: RoutineKind
    name*: string
    line*: int
    params*: seq[Param]
    ret*: Typ # nil = no return value
    body*: seq[Stmt]

  ConstDef* = object
    name*: string
    value*: int64
    line*: int
  GlobalDef* = object
    name*: string
    typ*: Typ
    line*: int
  TypeDef* = object
    name*: string
    typ*: Typ
    line*: int
  Module* = ref object
    consts*: seq[ConstDef]
    globals*: seq[GlobalDef]
    types*: seq[TypeDef]
    routines*: seq[Routine]

const mutMethods* = ["add", "push", "pop", "clear", "incl", "excl",
  "put", "remove"]

proc deOpt*(t: Typ): Typ =
  ## The base type of an optional (a copy with the flag cleared).
  if t == nil or not t.opt:
    return t
  Typ(kind: t.kind, len: t.len, elem: t.elem, name: t.name,
    fields: t.fields, val: t.val, rlo: t.rlo, rhi: t.rhi, opt: false)

proc optOf*(t: Typ): Typ =
  ## The optional flavor of a type (a copy with the flag set).
  Typ(kind: t.kind, len: t.len, elem: t.elem, name: t.name,
    fields: t.fields, val: t.val, rlo: t.rlo, rhi: t.rhi, opt: true)

proc intType*(lo = low(int64), hi = high(int64)): Typ =
  ## An int type, optionally restricted to a declared range.
  Typ(kind: IntType, rlo: lo, rhi: hi)

proc isFullRange*(t: Typ): bool =
  t.rlo == low(int64) and t.rhi == high(int64)

proc setSize*(t: Typ): int64 =
  ## Number of possible values of a set's (or dense map's) element range.
  t.elem.rhi - t.elem.rlo + 1

const arenaThreshold* = 256'i64 # locals bigger than this go to the arena

proc sizeAdd(a, b: int64): int64 =
  if a > high(int64) - b: high(int64) else: a + b

proc sizeMul(a, b: int64): int64 =
  if a != 0 and b > high(int64) div a: high(int64) else: a * b

proc typeAlign*(t: Typ): int64 =
  case t.kind
  of BoolType:
    result = 1
  of ArrayType:
    result = typeAlign(t.elem)
  of ObjectType:
    result = 1
    for f in t.fields:
      result = max(result, typeAlign(f.typ))
  else:
    result = 8 # int, containers (int64 length field first), Lock

proc typeSize*(t: Typ): int64 =
  ## C layout size, with alignment and padding.
  if t.opt:
    let a = typeAlign(deOpt(t))
    return (sizeAdd(typeSize(deOpt(t)), 1) + a - 1) div a * a
  case t.kind
  of BoolType: 1
  of IntType: 8
  of ArrayType: sizeMul(t.len, typeSize(t.elem))
  of SeqType:
    (sizeAdd(8, sizeMul(t.len, typeSize(t.elem))) + 7) div 8 * 8
  of StringType:
    (sizeAdd(8, t.len) + 7) div 8 * 8
  of SetType:
    sizeAdd(8, (t.setSize + 63) div 64 * 8)
  of QueueType:
    (sizeAdd(16, sizeMul(t.len, typeSize(t.elem))) + 7) div 8 * 8
  of DenseMapType:
    (sizeAdd(sizeAdd(8, (t.setSize + 63) div 64 * 8),
      sizeMul(t.setSize, typeSize(t.val))) + 7) div 8 * 8
  of SparseMapType:
    (sizeAdd(8, sizeAdd(sizeMul(t.len, typeSize(t.elem)),
      sizeMul(t.len, typeSize(t.val)))) + 7) div 8 * 8
  of ObjectType:
    var off = 0'i64
    for f in t.fields:
      let a = typeAlign(f.typ)
      off = (off + a - 1) div a * a
      off = sizeAdd(off, typeSize(f.typ))
    let a = typeAlign(t)
    (off + a - 1) div a * a
  else: 0 # Lock: platform-sized, reported separately

proc typEq*(a, b: Typ): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.opt != b.opt:
    return false
  if a.kind != b.kind:
    return false
  if a.kind in {ArrayType, SeqType, QueueType}:
    return a.len == b.len and typEq(a.elem, b.elem)
  if a.kind == StringType:
    return a.len == b.len
  if a.kind == SetType:
    return a.elem.rlo == b.elem.rlo and a.elem.rhi == b.elem.rhi
  if a.kind == DenseMapType:
    return a.elem.rlo == b.elem.rlo and a.elem.rhi == b.elem.rhi and
      typEq(a.val, b.val)
  if a.kind == SparseMapType:
    return a.len == b.len and typEq(a.elem, b.elem) and typEq(a.val, b.val)
  if a.kind == ObjectType:
    return a.name == b.name
  true

proc `$`*(t: Typ): string =
  if t.isNil:
    return "void"
  if t.opt:
    return $deOpt(t) & "?"
  case t.kind
  of IntType:
    if t.isFullRange: "int" else: $t.rlo & " .. " & $t.rhi
  of BoolType: "bool"
  of StringLitType: "string"
  of LockType: "Lock"
  of ArrayType: "array[" & $t.len & ", " & $t.elem & "]"
  of SeqType: "seq[" & $t.len & ", " & $t.elem & "]"
  of StringType: "string[" & $t.len & "]"
  of SetType: "set[" & $t.elem & "]"
  of QueueType: "queue[" & $t.len & ", " & $t.elem & "]"
  of DenseMapType: "map[" & $t.elem & ", " & $t.val & "]"
  of SparseMapType: "map[" & $t.len & ", " & $t.elem & ", " & $t.val & "]"
  of ObjectType: t.name

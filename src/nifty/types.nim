## The AST and type representation shared by the parser, checker, and codegen.

import std/tables
import lexer

type
  TypKind* = enum
    IntType, BoolType, StringLitType, LockType, ArrayType, ObjectType, SeqType, StringType, SetType,
    QueueType, DenseMapType, SparseMapType, # dense map[range, V]; sorted sparse map[N, K, V]
    TypeVarType, # a generic $T waiting to be bound at instantiation
    FloatType # IEEE float32/float64: data values, outside the proof engine
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
    gname*: string       # TypeVarType: the $name
    lenVar*: string      # containers: a $name standing in for the size
    width*: int          # storage bytes for hardware types (0 = natural 8)
    dname*: string       # display name for named hardware types

  SymKind* = enum
    ConstSym, GlobalSym, LocalSym, ParamSym

  ExprKind* = enum
    IntExpr, FloatExpr, BoolExpr, StrExpr, IdentExpr, BinExpr, NotExpr, NegExpr, IndexExpr, CallExpr,
    FieldExpr, MethodExpr, # MethodExpr: builtin op on a container, kids[0] = base
    NoneExpr # the absent optional value; typed by its destination
  Expr* = ref object
    kind*: ExprKind
    line*: int
    ival*: int64
    fval*: float64
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
    ForEachStmt, # for x in s: over a seq/string; value = s, name = x
    BlockStmt # block: - a scope inside a routine; sibling blocks share arena
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
    externLib*: string         # extern routines: the library ("libc", ...)
    cname*: string             # extern routines: the C symbol, if renamed
    generic*: bool             # has $ variables; body kept as tokens
    toks*: seq[Token]          # generic only: the whole declaration
    constsSnap*: Table[string, int64] # consts visible at declaration
    typesSnap*: Table[string, Typ]    # object types visible at declaration

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
    externLibs*: seq[string]   # every extern library, for link flags
    consts*: seq[ConstDef]
    globals*: seq[GlobalDef]
    types*: seq[TypeDef]
    routines*: seq[Routine]

const mutMethods* = ["add", "push", "pop", "clear", "incl", "excl",
  "put", "remove", "setLen", "addByte", "addNum", "copyRange"]

proc deOpt*(t: Typ): Typ =
  ## The base type of an optional (a copy with the flag cleared).
  if t == nil or not t.opt:
    return t
  Typ(kind: t.kind, len: t.len, elem: t.elem, name: t.name,
    fields: t.fields, val: t.val, rlo: t.rlo, rhi: t.rhi, opt: false,
    width: t.width, dname: t.dname)

proc optOf*(t: Typ): Typ =
  ## The optional flavor of a type (a copy with the flag set).
  Typ(kind: t.kind, len: t.len, elem: t.elem, name: t.name,
    fields: t.fields, val: t.val, rlo: t.rlo, rhi: t.rhi, opt: true,
    width: t.width, dname: t.dname)

proc intType*(lo = low(int64), hi = high(int64)): Typ =
  ## An int type, optionally restricted to a declared range.
  Typ(kind: IntType, rlo: lo, rhi: hi)

proc sizedInt*(lo, hi: int64, width: int, dname: string): Typ =
  ## A hardware integer: an ordinary range with a storage width.
  Typ(kind: IntType, rlo: lo, rhi: hi, width: width, dname: dname)

proc floatType*(width: int, dname: string): Typ =
  ## float32 or float64: IEEE data values, no ranges, no proofs.
  Typ(kind: FloatType, width: width, dname: dname)

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
  of IntType, FloatType:
    result = if t.width > 0: t.width else: 8
  of ArrayType:
    result = typeAlign(t.elem)
  of ObjectType:
    result = 1
    for f in t.fields:
      result = max(result, typeAlign(f.typ))
  else:
    result = 8 # containers (int64 length field first), Lock

proc bigRet*(t: Typ): bool
  ## Returns of arrays (C cannot) and of values bigger than the arena
  ## threshold go through a caller-provided destination pointer instead
  ## of a by-value C return, so no copy ever lands on the C stack.

proc typeSize*(t: Typ): int64 =
  ## C layout size, with alignment and padding.
  if t.opt:
    let a = typeAlign(deOpt(t))
    return (sizeAdd(typeSize(deOpt(t)), 1) + a - 1) div a * a
  case t.kind
  of BoolType: 1
  of IntType: (if t.width > 0: t.width else: 8)
  of FloatType: t.width
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

proc typeEq*(a, b: Typ): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.opt != b.opt:
    return false
  if a.kind != b.kind:
    return false
  if a.kind == FloatType:
    return a.width == b.width
  if a.kind in {ArrayType, SeqType, QueueType}:
    # Elements must also match in storage width: the memory layouts of
    # array[4, uint8] and array[4, 0 .. 255] are different things.
    return a.len == b.len and typeEq(a.elem, b.elem) and
      a.elem.width == b.elem.width
  if a.kind == StringType:
    return a.len == b.len
  if a.kind == SetType:
    return a.elem.rlo == b.elem.rlo and a.elem.rhi == b.elem.rhi
  if a.kind == DenseMapType:
    return a.elem.rlo == b.elem.rlo and a.elem.rhi == b.elem.rhi and
      typeEq(a.val, b.val) and a.val.width == b.val.width
  if a.kind == SparseMapType:
    return a.len == b.len and typeEq(a.elem, b.elem) and
      typeEq(a.val, b.val) and a.val.width == b.val.width
  if a.kind == ObjectType:
    return a.name == b.name
  true

proc sizeStr(t: Typ): string =
  if t.lenVar != "": "$" & t.lenVar else: $t.len

proc `$`*(t: Typ): string =
  if t.isNil:
    return "void"
  if t.opt:
    return $deOpt(t) & "?"
  case t.kind
  of IntType:
    if t.dname != "": t.dname
    elif t.isFullRange: "int"
    else: $t.rlo & " .. " & $t.rhi
  of FloatType: t.dname
  of BoolType: "bool"
  of StringLitType: "string"
  of LockType: "Lock"
  of ArrayType: "array[" & t.sizeStr & ", " & $t.elem & "]"
  of SeqType: "seq[" & t.sizeStr & ", " & $t.elem & "]"
  of StringType: "string[" & t.sizeStr & "]"
  of SetType: "set[" & $t.elem & "]"
  of QueueType: "queue[" & t.sizeStr & ", " & $t.elem & "]"
  of DenseMapType: "map[" & $t.elem & ", " & $t.val & "]"
  of SparseMapType: "map[" & $t.len & ", " & $t.elem & ", " & $t.val & "]"
  of ObjectType: t.name
  of TypeVarType: "$" & t.gname

proc bigRet*(t: Typ): bool =
  t != nil and (t.kind == ArrayType or typeSize(t) > arenaThreshold)

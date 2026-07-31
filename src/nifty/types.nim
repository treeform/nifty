## The AST and type representation shared by the parser, checker, and codegen.

type
  TypKind* = enum
    tyInt, tyBool, tyString, tyLock, tyArray, tyObject, tySeq, tyStr, tySet,
    tyQueue
  Field* = object
    name*: string
    typ*: Typ
  Typ* = ref object
    kind*: TypKind
    len*: int64          # tyArray/tySeq/tyStr: capacity
    elem*: Typ           # tyArray/tySeq; tySet: the range element type
    name*: string        # tyObject
    fields*: seq[Field]  # tyObject
    rlo*, rhi*: int64    # tyInt: declared range; full range = plain int

  SymKind* = enum
    syConst, syGlobal, syLocal, syParam

  ExprKind* = enum
    ekInt, ekBool, ekStr, ekIdent, ekBin, ekNot, ekNeg, ekIndex, ekCall,
    ekField, ekMethod # ekMethod: builtin op on a seq/string, kids[0] = base
  Expr* = ref object
    kind*: ExprKind
    line*: int
    ival*: int64
    bval*: bool
    sval*: string   # ekStr text, ekIdent name, ekBin operator, ekCall name,
                    # ekField field name
    kids*: seq[Expr]
    typ*: Typ       # set by the checker
    symKind*: SymKind
    isVarParam*: bool
    mut*: bool
    rlo*, rhi*: int64 # proven value range, set by the checker for int exprs
    rnz*: bool        # proven nonzero, set by the checker for int exprs

  StmtKind* = enum
    skVar, skLet, skAssign, skIf, skWhile, skFor, skLoop, skWith,
    skReturn, skBreak, skEcho, skDiscard, skCall,
    skForEach # for x in s: over a seq/string; value = s, name = x
  Elif* = object
    cond*: Expr
    body*: seq[Stmt]
  Stmt* = ref object
    kind*: StmtKind
    line*: int
    name*: string      # var/let/for/with
    typ*: Typ          # var/let declared or inferred type
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
    rkFunc = "func", rkProc = "proc", rkThread = "thread"
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

const mutMethods* = ["add", "push", "pop", "clear", "incl", "excl"]

proc intType*(lo = low(int64), hi = high(int64)): Typ =
  ## An int type, optionally restricted to a declared range.
  Typ(kind: tyInt, rlo: lo, rhi: hi)

proc isFullRange*(t: Typ): bool =
  t.rlo == low(int64) and t.rhi == high(int64)

proc setSize*(t: Typ): int64 =
  ## Number of possible values of a set's element range.
  t.elem.rhi - t.elem.rlo + 1

proc typEq*(a, b: Typ): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind:
    return false
  if a.kind in {tyArray, tySeq, tyQueue}:
    return a.len == b.len and typEq(a.elem, b.elem)
  if a.kind == tyStr:
    return a.len == b.len
  if a.kind == tySet:
    return a.elem.rlo == b.elem.rlo and a.elem.rhi == b.elem.rhi
  if a.kind == tyObject:
    return a.name == b.name
  true

proc `$`*(t: Typ): string =
  if t.isNil:
    return "void"
  case t.kind
  of tyInt:
    if t.isFullRange: "int" else: $t.rlo & " .. " & $t.rhi
  of tyBool: "bool"
  of tyString: "string"
  of tyLock: "Lock"
  of tyArray: "array[" & $t.len & ", " & $t.elem & "]"
  of tySeq: "seq[" & $t.len & ", " & $t.elem & "]"
  of tyStr: "string[" & $t.len & "]"
  of tySet: "set[" & $t.elem & "]"
  of tyQueue: "queue[" & $t.len & ", " & $t.elem & "]"
  of tyObject: t.name

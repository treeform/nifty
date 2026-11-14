## The AST and type representation shared by the parser, checker, and codegen.

import std/[sets, tables]
import lexer, common

type
  TypKind* = enum
    IntType, BoolType, StringLitType, LockType, ArrayType, ObjectType, SeqType, StringType, SetType,
    QueueType, DenseMapType, SparseMapType, # dense map[range, V]; sorted sparse map[N, K, V]
    ChannelType, # channel[N, T]: a blocking bounded queue (the semaphore system)
    TypeVarType, # a generic $T waiting to be bound at instantiation
    FloatType, # IEEE float32/float64: data values, outside the proof engine
    UnionType, # A tagged union of nominal object alternatives.
    OpaqueType, # nominal foreign pointer; only null testing and equality
    CStringType # Immutable owned NUL-terminated bytes; borrowed pointer at FFI.
  Field* = object
    name*: string
    typ*: Typ
  Typ* = ref object
    kind*: TypKind
    len*: int64          # ArrayType/SeqType/StringType: capacity
    dynamic*: bool       # Growable seq/string: len is not a static capacity.
    elem*: Typ           # ArrayType/SeqType; SetType: the range element type
    name*: string        # ObjectType/OpaqueType: nominal identity
    fields*: seq[Field]  # ObjectType
    members*: seq[Typ]   # UnionType alternatives in declaration order.
    typeId*: int64       # Canonical identity within the checked program.
    val*: Typ            # DenseMapType/SparseMapType: the value type
    rlo*, rhi*: int64    # IntType: declared range; full range = plain int
    opt*: bool           # T?: an optional (value + ok flag)
    gname*: string       # TypeVarType: the $name
    lenVar*: string      # containers: a $name standing in for the size
    width*: int          # storage bytes for hardware types (0 = natural 8)
    dname*: string       # display name for named hardware types

  SymKind* = enum
    ConstSym, GlobalSym, LocalSym, ParamSym

  BindingMode* = enum
    UnplannedMode, ValueMode, OwnerMode, ReadBorrowMode, MutBorrowMode
  BindingId* = int
  SemanticBinding* = object
    name*, routine*: string
    line*: int
    typ*: Typ
    mode*: BindingMode
    kind*: SymKind
  SemanticScope* = object
    drops*: seq[BindingId]
  LockProof* = object
    name*: string
    guards*, users*: seq[string]
  SemanticPlan* = ref object
    bindings*: seq[SemanticBinding]
    scopes*: seq[SemanticScope]
    globalDrops*: seq[BindingId]
    usesHeap*: bool
    locks*: seq[LockProof]
    channelProgress*: string

  ExprKind* = enum
    IntExpr, FloatExpr, BoolExpr, StrExpr, IdentExpr, BinExpr, NotExpr, NegExpr, IndexExpr, CallExpr,
    FieldExpr, MethodExpr, # MethodExpr: builtin op on a container, kids[0] = base
    NoneExpr, # The absent optional value; typed by its destination.
    ObjectExpr, # Constructor payloads in declaration field order.
    UnionWrapExpr, # kids[0] is the concrete payload; typ is the union.
    UnionProjectExpr, # Proven concrete payload view into kids[0].
    TypeIdExpr # kids[0] is evaluated; ival=0 loads a union tag.
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
    binding*: BindingId # Resolved declaration; zero for non-binding nodes.
    borrowedView*: bool # Checked fixed storage to growable readonly view.
    directCall*: bool # Synthesized call already has a resolved callee.
    symKind*: SymKind
    isVarParam*: bool
    mut*: bool
    rlo*, rhi*: int64 # proven value range, set by the checker for int exprs
    rnz*: bool        # proven nonzero, set by the checker for int exprs
    wrapOpt*: bool    # codegen: wrap this value into an optional
    wrapSource*: Typ  # Original value type before optional coercion.
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
    scope*: int
  Stmt* = ref object
    kind*: StmtKind
    line*: int
    name*: string      # var/let/for/with
    name2*: string     # for k, v in m: - the value variable
    binding*, binding2*: BindingId
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
    bodyScope*, elseScope*: int
    nonowningTemp*: bool # Compiler-generated readonly descriptor snapshot.
    drops*: seq[BindingId] # Ordered owners released by return or break.

  RoutineKind* = enum
    FuncRoutine = "func", ProcRoutine = "proc", ThreadRoutine = "thread"
  Param* = object
    name*: string
    typ*: Typ
    isVar*: bool
    boundedBy*: string # Foreign buffer's named element or byte count.
    binding*: BindingId
  Routine* = ref object
    kind*: RoutineKind
    name*: string
    line*: int
    count*: int                # threads: instances declared (thread 4 w());
                               # 0 or 1 means one
    params*: seq[Param]
    ret*: Typ # nil = no return value
    body*: seq[Stmt]
    bodyScope*: int
    externLib*: string         # extern routines: the library ("libc", ...)
    cname*: string             # extern routines: the C symbol, if renamed
    unionDispatcher*: bool    # Synthesized exhaustive union overload.
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
    binding*: BindingId
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
    supportCount*: int        # Trailing backend support routines.
    semantics*: SemanticPlan # Present only after all source checks pass.
    typeIds*: Table[string, int64] # Build-local, collision-free identities.

const mutMethods* = ["add", "push", "pop", "clear", "incl", "excl",
  "put", "remove", "setLen", "addByte", "addNum", "copyRange",
  "send", "recv", "reserve", "resize", "copyFrom"]

# Names the container/optional method system owns. A routine with one
# of these names is still callable the classic way, but never through
# uniform call syntax - builtins keep their meaning on every type.
const builtinMethods* = @mutMethods & @["or", "get", "contains",
  "startsWith", "endsWith", "find", "findByte", "toInt",
  "len", "ok", "lo", "hi", "isNull", "toCString"]

proc instances*(r: Routine): int =
  ## How many OS threads a thread declaration starts (thread 4 w()).
  max(1, r.count)

proc deOpt*(t: Typ): Typ =
  ## The base type of an optional (a copy with the flag cleared).
  if t == nil or not t.opt:
    return t
  Typ(kind: t.kind, len: t.len, elem: t.elem, name: t.name,
    fields: t.fields, members: t.members, val: t.val,
    rlo: t.rlo, rhi: t.rhi, opt: false,
    width: t.width, dname: t.dname, dynamic: t.dynamic,
    gname: t.gname, lenVar: t.lenVar)

proc optOf*(t: Typ): Typ =
  ## The optional flavor of a type (a copy with the flag set).
  Typ(kind: t.kind, len: t.len, elem: t.elem, name: t.name,
    fields: t.fields, members: t.members, val: t.val,
    rlo: t.rlo, rhi: t.rhi, opt: true,
    width: t.width, dname: t.dname, dynamic: t.dynamic,
    gname: t.gname, lenVar: t.lenVar)

proc hasOwned*(t: Typ): bool =
  ## Whether a value owns heap storage directly or through its contents.
  var seen: HashSet[pointer]
  proc visit(current: Typ): bool =
    ## Walks recursive type graphs without following a node twice.
    if current.isNil or cast[pointer](current) in seen:
      return false
    seen.incl(cast[pointer](current))
    if current.dynamic or visit(current.elem) or visit(current.val):
      return true
    for field in current.fields:
      if visit(field.typ):
        return true
    for member in current.members:
      if visit(member):
        return true
    false
  visit(t)

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

proc sizeAdd*(a, b: int64, line = 0): int64 =
  ## Adds nonnegative storage sizes without returning a false bound.
  if a < 0 or b < 0 or a > high(int64) - b:
    err(line, "static storage size exceeds int64")
  a + b

proc sizeMul*(a, b: int64, line = 0): int64 =
  ## Multiplies nonnegative storage sizes with an explicit overflow error.
  if a < 0 or b < 0 or (a != 0 and b > high(int64) div a):
    err(line, "static storage size exceeds int64")
  a * b

proc sizeAlign*(bytes, alignment: int64, line = 0): int64 =
  ## Rounds storage up without overflowing an already aligned size.
  if bytes < 0 or alignment <= 0:
    err(line, "invalid static storage size or alignment")
  let remainder = bytes mod alignment
  if remainder == 0: bytes
  else: sizeAdd(bytes, alignment - remainder, line)

proc typeLayout(t: Typ, line = 0): tuple[bytes, alignment: int64] =
  ## Computes finite inline layouts while allowing growable indirection.
  var visiting: HashSet[pointer]
  proc layout(current: Typ): tuple[bytes, alignment: int64] =
    ## Rejects only cycles that require infinitely large inline storage.
    if current.isNil:
      return (0'i64, 1'i64)
    let key = cast[pointer](current)
    if key in visiting:
      err(line, "recursive type requires a growable seq indirection")
    visiting.incl(key)
    defer: visiting.excl(key)
    if current.opt:
      let base = layout(deOpt(current))
      return (sizeAlign(sizeAdd(base.bytes, 1, line),
        base.alignment, line), base.alignment)
    case current.kind
    of BoolType:
      result = (1'i64, 1'i64)
    of IntType, FloatType:
      let width = if current.width > 0: int64(current.width) else: 8'i64
      result = (width, width)
    of OpaqueType:
      result = (8'i64, 8'i64)
    of CStringType:
      result = (24'i64, 8'i64)
    of ArrayType:
      let item = layout(current.elem)
      result = (sizeMul(current.len, item.bytes, line), item.alignment)
    of SeqType, StringType:
      result.alignment = 8
      if current.dynamic:
        result.bytes = 24
      else:
        let bytes =
          if current.kind == StringType: current.len
          else: sizeMul(current.len, layout(current.elem).bytes, line)
        result.bytes = sizeAlign(sizeAdd(8, bytes, line), 8, line)
    of SetType:
      result = (sizeAdd(8,
        sizeMul(sizeAdd(current.setSize, 63, line) div 64, 8, line),
        line), 8'i64)
    of QueueType, ChannelType:
      let header = if current.kind == ChannelType: 176'i64 else: 16'i64
      result = (sizeAlign(sizeAdd(header,
        sizeMul(current.len, layout(current.elem).bytes, line), line),
        8, line), 8'i64)
    of DenseMapType:
      let bytes = sizeAdd(sizeAdd(8,
        sizeMul(sizeAdd(current.setSize, 63, line) div 64, 8, line), line),
        sizeMul(current.setSize, layout(current.val).bytes, line), line)
      result = (sizeAlign(bytes, 8, line), 8'i64)
    of SparseMapType:
      let bytes = sizeAdd(8, sizeAdd(
        sizeMul(current.len, layout(current.elem).bytes, line),
        sizeMul(current.len, layout(current.val).bytes, line), line), line)
      result = (sizeAlign(bytes, 8, line), 8'i64)
    of ObjectType:
      result.alignment = 1
      for field in current.fields:
        let item = layout(field.typ)
        result.alignment = max(result.alignment, item.alignment)
        result.bytes = sizeAlign(result.bytes, item.alignment, line)
        result.bytes = sizeAdd(result.bytes, item.bytes, line)
      result.bytes = sizeAlign(max(1'i64, result.bytes),
        result.alignment, line)
    of UnionType:
      result.alignment = 8
      var payload = 0'i64
      for member in current.members:
        let item = layout(member)
        result.alignment = max(result.alignment, item.alignment)
        payload = max(payload, item.bytes)
      result.bytes = sizeAlign(sizeAdd(
        sizeAlign(8, result.alignment, line), payload, line),
        result.alignment, line)
    else:
      result = (0'i64, 8'i64)
  layout(t)

proc typeAlign*(t: Typ): int64 =
  ## Returns the common alignment used by all compiler backends.
  typeLayout(t).alignment

proc typeSize*(t: Typ, line = 0): int64 =
  ## Computes representable storage size, including checked padding.
  typeLayout(t, line).bytes

proc unionPayloadOffset*(t: Typ): int64 =
  ## Locates the inline payload immediately after its 64-bit tag.
  sizeAlign(8, typeAlign(t))

proc unionMember*(union, member: Typ): bool =
  ## Tests membership by nominal type identity, never by payload shape.
  if union.isNil or member.isNil or union.kind != UnionType:
    return false
  for candidate in union.members:
    if candidate.kind == member.kind and candidate.name == member.name and
        candidate.opt == member.opt:
      return true
  false

proc bigRet*(t: Typ): bool
  ## Identifies returns that require a caller-provided destination.

proc sameStorage(a, b: Typ): bool =
  ## Match scalar carriers inside otherwise compatible aggregate types.
  if a.kind == IntType and b.kind == IntType:
    let
      aWidth = if a.width > 0: a.width else: 8
      bWidth = if b.width > 0: b.width else: 8
      aUnsigned = a.width > 0 and a.rlo >= 0
      bUnsigned = b.width > 0 and b.rlo >= 0
    return aWidth == bWidth and aUnsigned == bUnsigned
  a.width == b.width

proc typeEq*(a, b: Typ): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.opt != b.opt:
    return false
  if a.kind != b.kind or a.dynamic != b.dynamic:
    return false
  if a.opt and a.kind == IntType:
    # Optional payloads are copied as aggregates without scalar conversion.
    return sameStorage(a, b)
  if a.kind == FloatType:
    return a.width == b.width
  if a.kind in {ArrayType, SeqType, QueueType}:
    # Elements must also match in storage width: the memory layouts of
    # array[4, uint8] and array[4, 0 .. 255] are different things.
    return a.len == b.len and typeEq(a.elem, b.elem) and
      sameStorage(a.elem, b.elem)
  if a.kind == StringType:
    return a.len == b.len
  if a.kind == SetType:
    return a.elem.rlo == b.elem.rlo and a.elem.rhi == b.elem.rhi
  if a.kind == DenseMapType:
    return a.elem.rlo == b.elem.rlo and a.elem.rhi == b.elem.rhi and
      typeEq(a.val, b.val) and sameStorage(a.val, b.val)
  if a.kind == SparseMapType:
    return a.len == b.len and typeEq(a.elem, b.elem) and
      sameStorage(a.elem, b.elem) and
      typeEq(a.val, b.val) and sameStorage(a.val, b.val)
  if a.kind in {ObjectType, UnionType, OpaqueType}:
    return a.name == b.name
  if a.kind == ChannelType:
    return false # channels are never copied or compared
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
  of CStringType: "cstring"
  of LockType: "Lock"
  of ArrayType: "array[" & t.sizeStr & ", " & $t.elem & "]"
  of SeqType:
    if t.dynamic: "seq[" & $t.elem & "]"
    else: "seq[" & t.sizeStr & ", " & $t.elem & "]"
  of StringType:
    if t.dynamic: "string"
    else: "string[" & t.sizeStr & "]"
  of SetType: "set[" & $t.elem & "]"
  of QueueType: "queue[" & t.sizeStr & ", " & $t.elem & "]"
  of ChannelType: "channel[" & t.sizeStr & ", " & $t.elem & "]"
  of DenseMapType: "map[" & $t.elem & ", " & $t.val & "]"
  of SparseMapType: "map[" & $t.len & ", " & $t.elem & ", " & $t.val & "]"
  of ObjectType, UnionType, OpaqueType: t.name
  of TypeVarType: "$" & t.gname

proc bigRet*(t: Typ): bool =
  t != nil and (t.kind == ArrayType or typeSize(t) > arenaThreshold)

proc needsDefaultInit*(t: Typ): bool =
  ## Finds inline default values that need a valid nonzero union tag.
  var seen: HashSet[pointer]
  proc visit(current: Typ): bool =
    ## Empty containers and absent optionals have no active payloads.
    if current.isNil or current.opt or current.dynamic or
        cast[pointer](current) in seen:
      return false
    seen.incl(cast[pointer](current))
    case current.kind
    of UnionType:
      return true
    of ObjectType:
      for field in current.fields:
        if visit(field.typ):
          return true
    of ArrayType:
      return visit(current.elem)
    else:
      discard
    false
  visit(t)

proc typeIdentity*(t: Typ): string =
  ## Canonicalizes program-local identities without relying on hashes.
  if t.isNil:
    return "void"
  if t.opt:
    return "optional[" & typeIdentity(deOpt(t)) & "]"
  case t.kind
  of ObjectType:
    "object:" & t.name
  of UnionType:
    "union:" & t.name
  of IntType:
    "int[" & $(if t.width == 0: 8 else: t.width) & "," &
      $t.rlo & "," & $t.rhi & "]"
  of FloatType:
    "float[" & $t.width & "]"
  of TypeVarType:
    "variable:" & t.gname
  of ArrayType, SeqType, StringType, SetType, QueueType, ChannelType,
      DenseMapType, SparseMapType:
    $t.kind & "[" & $t.dynamic & "," & $t.len & "," & t.lenVar &
      "," & typeIdentity(t.elem) & "," & typeIdentity(t.val) & "]"
  else:
    $t.kind

proc ensureTypeId*(m: Module, t: Typ): int64 =
  ## Assigns a unique identity shared by all equivalent type nodes.
  if t.isNil:
    return 0
  let key = typeIdentity(t)
  if key notin m.typeIds:
    m.typeIds[key] = int64(m.typeIds.len + 1)
  result = m.typeIds[key]
  t.typeId = result

proc assignTypeIds*(m: Module) =
  ## Interns every type reachable from parsed or checked declarations.
  var seen: HashSet[pointer]
  proc visit(t: Typ) =
    ## Assigns identity before traversing recursive nominal definitions.
    if t.isNil or cast[pointer](t) in seen:
      return
    seen.incl(cast[pointer](t))
    discard m.ensureTypeId(t)
    visit(t.elem)
    visit(t.val)
    for field in t.fields:
      visit(field.typ)
    for member in t.members:
      visit(member)
  proc expression(e: Expr) =
    ## Includes inferred and synthesized expression types after checking.
    if e.isNil:
      return
    visit(e.typ)
    visit(e.wrapSource)
    for child in e.kids:
      expression(child)
  proc statements(body: seq[Stmt]) =
    ## Includes local annotations and nested checked expression types.
    for s in body:
      visit(s.typ)
      visit(s.typ2)
      for e in [s.init, s.lhs, s.rhs, s.cond, s.lo, s.hi, s.value]:
        expression(e)
      for e in s.args:
        expression(e)
      statements(s.body)
      for branch in s.elifs:
        expression(branch.cond)
        statements(branch.body)
      statements(s.elseBody)
  for definition in m.types:
    visit(definition.typ)
  for global in m.globals:
    visit(global.typ)
  for routine in m.routines:
    for parameter in routine.params:
      visit(parameter.typ)
    visit(routine.ret)
    statements(routine.body)

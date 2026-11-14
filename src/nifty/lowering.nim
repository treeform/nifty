## Lowers checked Nifty syntax to explicit native SSA and storage.
import std/[tables, sets]
import types, common, semantics, nativeplans, nativeirtypes, echolowering, backend/irs

type
  Binding = object
    address: ValueId
    typ: Typ
  Lower = object
    plan: NativePlan
    source: Module
    routines: Table[string, int]
    globals: Table[string, int]
    constants: Table[string, int64]
    layouts: Table[string, int]
    storageTypes: seq[int32]
    argumentTypes: seq[int32]
    bindings: Table[BindingId, Binding]
    fn, current, line: int
    routine: Routine
    arena, highArena: int
    frames: seq[int]
    calls: seq[seq[int]]
    patches: seq[int]
    breaks: seq[int]

proc aligned(n, a: int): int =
  ## Rounds storage to its concrete alignment.
  int(sizeAlign(n, a))

proc layout(g: var Lower, t: Typ): int =
  ## Registers the fixed native representation of a checked type.
  if t.isNil:
    return -1
  let key = $t & ":" & $t.width & ":" & $t.dynamic
  if key in g.layouts:
    return g.layouts[key]
  result = g.plan.layouts.len
  g.layouts[key] = result
  g.plan.layouts.add(NativeLayout())
  var l = NativeLayout(kind: t.kind, align: 8, capacity: t.len,
    elem: -1, key: -1, val: -1, okOffset: -1, display: t.dname,
    lower: t.rlo, upper: t.rhi, optional: t.opt,
    dynamic: t.dynamic, owned: hasOwned(t))
  if t.opt:
    let base = g.layout(deOpt(t))
    l = g.plan.layouts[base]
    l.optional = true
    l.okOffset = int(l.bytes)
    l.bytes = int64(aligned(int(l.bytes) + 1, int(l.align)))
  else:
    case t.kind
    of IntType, FloatType, OpaqueType:
      l.bytes = if t.width > 0: t.width else: 8
      l.align = l.bytes
    of BoolType:
      l.bytes = 1
      l.align = 1
    of LockType:
      l.bytes = 8
    of ArrayType:
      l.elem = g.layout(t.elem)
      l.align = g.plan.layouts[l.elem].align
      l.bytes = t.len * g.plan.layouts[l.elem].bytes
    of ObjectType:
      l.align = 1
      for f in t.fields:
        let ft = g.layout(f.typ)
        let fl = g.plan.layouts[ft]
        l.bytes = int64(aligned(int(l.bytes), int(fl.align)))
        l.fields.add(NativeField(name: f.name, typ: ft,
          offset: int(l.bytes)))
        l.bytes += fl.bytes
        l.align = max(l.align, fl.align)
      l.bytes = int64(aligned(int(l.bytes), int(l.align)))
    of CStringType:
      l.kind = StringType # Runtime owner descriptor; nominality is checked in the frontend.
      l.dynamic = true
      l.dataOffset = 16
      l.bytes = 24
    of StringType, StringLitType:
      if t.dynamic:
        l.dataOffset = 16
        l.bytes = 24
      else:
        l.dataOffset = 8
        l.bytes = int64(aligned(8 + int(t.len), 8))
    of SeqType, QueueType, ChannelType:
      l.elem = g.layout(t.elem)
      if t.dynamic:
        l.dataOffset = 16
        l.bytes = 24
      else:
        l.dataOffset = if t.kind in {QueueType, ChannelType}: 16 else: 8
        l.bytes = int64(aligned(l.dataOffset + int(t.len *
          g.plan.layouts[l.elem].bytes), 8))
    of SetType, DenseMapType:
      l.elem = g.layout(t.elem)
      l.lower = t.elem.rlo
      l.upper = t.elem.rhi
      l.dataOffset = 8
      l.bytes = 8 + (t.setSize + 63) div 64 * 8
      if t.kind == DenseMapType:
        l.val = g.layout(t.val)
        let vl = g.plan.layouts[l.val]
        l.valOffset = aligned(int(l.bytes), int(vl.align))
        l.bytes = int64(l.valOffset) + t.setSize * vl.bytes
      l.bytes = int64(aligned(int(l.bytes), 8))
    of SparseMapType:
      l.key = g.layout(t.elem)
      l.elem = l.key
      l.val = g.layout(t.val)
      l.keyOffset = 8
      l.valOffset = aligned(8 + int(t.len *
        g.plan.layouts[l.key].bytes), int(g.plan.layouts[l.val].align))
      l.bytes = int64(aligned(l.valOffset + int(t.len *
        g.plan.layouts[l.val].bytes), 8))
    of TypeVarType:
      raise newException(NiftyError,
        "Internal compiler error: uninstantiated native type " & $t)
  discard nativeSize(l.bytes, g.line)
  g.plan.layouts[result] = l

proc size(g: var Lower, t: Typ): int =
  ## Returns the fixed native byte count.
  int(g.plan.layouts[g.layout(t)].bytes)

proc storage(g: var Lower, t: Typ): int32 =
  ## Returns the complete concrete IR representation of a checked type.
  let index = g.layout(t)
  g.plan.layoutStorage(g.storageTypes, index)

proc scalar(t: Typ): IrType =
  ## Selects a concrete scalar storage type.
  case t.kind
  of BoolType: irs.BoolType
  of FloatType:
    if t.width == 4: Float32Type else: Float64Type
  else:
    case t.width
    of 1:
      if t.rlo < 0: Int8Type else: UInt8Type
    of 2:
      if t.rlo < 0: Int16Type else: UInt16Type
    of 4:
      if t.rlo < 0: Int32Type else: UInt32Type
    else: Int64Type

proc aggregate(t: Typ): bool =
  ## Reports values represented by a storage address.
  t != nil and (t.opt or
    t.kind notin {IntType, FloatType, OpaqueType, types.BoolType})

proc operands(g: var Lower, values: openArray[ValueId]): Span =
  ## Appends an explicit operand range.
  result = Span(first: int32(g.plan.module.functions[g.fn].operands.len),
    count: int32(values.len))
  g.plan.module.functions[g.fn].operands.add(values)

proc emit(g: var Lower, instruction: IrInstruction,
    values: openArray[ValueId], kind = Int64Type,
    storage = 0'i32): ValueId =
  ## Emits a typed instruction in the active basic block.
  var ins = instruction
  ins.arguments = g.operands(values)
  ins.location = LocationId(g.plan.module.locations.len)
  g.plan.module.locations.add(IrSource(file: int32(g.line div fileLineBase),
    line: int32(g.line mod fileLineBase)))
  if ins.op notin {StoreOp, ClearBytesOp, MoveBytesOp, CallOp,
      HostCallOp} or ins.results.count > 0:
    result = ValueId(g.plan.module.functions[g.fn].values.len)
    ins.results = Span(first: int32(result), count: 1)
    g.plan.module.functions[g.fn].values.add(IrValue(valueType: kind, storage: storage))
  else:
    result = NoValue
  let index = g.plan.module.functions[g.fn].instructions.len
  if g.plan.module.functions[g.fn].blocks[g.current].instructions.count == 0:
    g.plan.module.functions[g.fn].blocks[g.current].instructions.first =
      int32(index)
  inc g.plan.module.functions[g.fn].blocks[g.current].instructions.count
  g.plan.module.functions[g.fn].instructions.add(ins)

proc constant(g: var Lower, n: int64, kind = Int64Type): ValueId =
  ## Defines a bit-exact scalar literal.
  g.emit(IrInstruction(op: ConstantOp, bits: cast[uint64](n)), [], kind)

proc offset(g: var Lower, p: ValueId, n: int): ValueId =
  ## Forms an interior byte address.
  if n == 0: p
  else: g.emit(IrInstruction(op: OffsetAddressOp, offset: int64(n)),
    [p, g.constant(0)], AddressType)

proc fieldAddress(g: var Lower, p: ValueId, name: string,
    fallback: int): ValueId =
  ## Preserves concrete field identities through aggregate address paths.
  let storage = g.plan.module.functions[g.fn].values[int32(p)].storage
  if storage > 0:
    let owner = g.plan.module.storageTypes[storage - 1]
    if owner.kind == StructStorage:
      for i in owner.fields.indices:
        let field = g.plan.module.fields[i]
        if field.name == name:
          return g.emit(IrInstruction(op: FieldAddressOp,
            target: int32(i)), [p], AddressType, field.storage)
  g.offset(p, fallback)

proc kind(g: Lower, v: ValueId): IrType =
  ## Reads one SSA scalar type.
  g.plan.module.functions[g.fn].values[int32(v)].valueType

proc convert(g: var Lower, v: ValueId, target: IrType): ValueId =
  ## Makes scalar widening and conversion explicit.
  let source = g.kind(v)
  if source == target:
    return v
  let conv =
    if target in {Float32Type, Float64Type}:
      if source in {Float32Type, Float64Type}: FloatWidthConversion
      else: IntegerFloatConversion
    elif source in {Float32Type, Float64Type}: FloatIntegerConversion
    elif target in {Int8Type, UInt8Type, Int16Type, UInt16Type,
        Int32Type, UInt32Type, irs.BoolType}: TruncateConversion
    elif source in {Int8Type, Int16Type, Int32Type}: SignExtendConversion
    elif source in {irs.BoolType, UInt8Type, UInt16Type, UInt32Type}:
      ZeroExtendConversion
    else: BitcastConversion
  g.emit(IrInstruction(op: ConvertOp, conversion: conv), [v], target)

proc binary(g: var Lower, op: IrOpcode, a, b: ValueId): ValueId =
  ## Defines arithmetic with explicitly matched operand types.
  g.emit(IrInstruction(op: op), [a, g.convert(b, g.kind(a))], g.kind(a))

proc compare(g: var Lower, op: IrComparison, a, b: ValueId): ValueId =
  ## Defines a normalized boolean comparison.
  g.emit(IrInstruction(op: CompareOp, comparison: op),
    [a, g.convert(b, g.kind(a))], irs.BoolType)

proc untyped(g: var Lower, p: ValueId): ValueId =
  ## Forms a byte view without changing the original pointer's storage type.
  g.emit(IrInstruction(op: OffsetAddressOp),
    [p, g.constant(0)], AddressType)

proc load(g: var Lower, p: ValueId, kind = Int64Type): ValueId =
  ## Loads scalar storage at its declared width.
  let storage = g.plan.module.functions[g.fn].values[int32(p)].storage
  var address = p
  if storage > 0:
    let data = g.plan.module.storageTypes[storage - 1]
    if data.kind != ScalarStorage or data.scalar != kind:
      address = g.untyped(p)
  g.emit(IrInstruction(op: LoadOp, alignment: 1), [address], kind)

proc store(g: var Lower, p, v: ValueId) =
  ## Stores a concrete scalar value.
  let storage = g.plan.module.functions[g.fn].values[int32(p)].storage
  var address = p
  if storage > 0:
    let data = g.plan.module.storageTypes[storage - 1]
    if data.kind != ScalarStorage or data.scalar != g.kind(v):
      address = g.untyped(p)
  discard g.emit(IrInstruction(op: StoreOp, alignment: 1), [address, v])

proc allocate(g: var Lower, bytes: int, align = 8,
    storage = 0'i32): ValueId =
  ## Allocates bounded stack storage or a thread arena slice.
  if bytes > int(arenaThreshold):
    g.arena = aligned(g.arena, align)
    result = g.emit(IrInstruction(op: OffsetAddressOp,
      offset: int64(g.arena)), [ValueId(3), g.constant(0)], AddressType)
    g.plan.module.functions[g.fn].values[int32(result)].storage = storage
    g.arena = int(sizeAdd(g.arena, bytes, g.line))
    g.highArena = max(g.highArena, g.arena)
  else:
    let slot = g.plan.module.functions[g.fn].slots.len
    g.plan.module.functions[g.fn].slots.add(IrSlot(
      byteCount: int32(max(1, bytes)), alignment: int32(align),
      storage: storage))
    result = g.emit(IrInstruction(op: SlotAddressOp,
      target: int32(slot)), [], AddressType, storage)

proc allocType(g: var Lower, t: Typ): ValueId =
  ## Allocates one native value.
  let l = g.plan.layouts[g.layout(t)]
  g.allocate(int(l.bytes), int(l.align), g.storage(t))

proc clear(g: var Lower, p: ValueId, bytes: int) =
  ## Initializes all bytes including padding.
  discard g.emit(IrInstruction(op: ClearBytesOp,
    byteCount: int32(bytes),
    target: g.plan.module.functions[g.fn].values[int32(p)].storage), [p])

proc copy(g: var Lower, p, value: ValueId, t: Typ) =
  ## Writes an expression value into its destination representation.
  if aggregate(t):
    discard g.emit(IrInstruction(op: MoveBytesOp,
      byteCount: int32(g.size(t)), target: g.storage(t)), [p, value])
  else:
    g.store(p, g.convert(value, scalar(t)))

proc read(g: var Lower, p: ValueId, t: Typ): ValueId =
  ## Materializes scalar values while aggregates retain their address.
  if aggregate(t): p
  elif t.kind == IntType: g.convert(g.load(p, scalar(t)), Int64Type)
  else: g.load(p, scalar(t))

proc blockId(g: var Lower): int =
  ## Appends an empty control flow block.
  result = g.plan.module.functions[g.fn].blocks.len
  g.plan.module.functions[g.fn].blocks.add(IrBlock())

proc live(g: Lower): bool =
  ## Reports whether the current block needs a terminator.
  g.plan.module.functions[g.fn].blocks[g.current].terminator.kind ==
    UnsetTerminator

proc jump(g: var Lower, target: int) =
  ## Terminates the active path with a direct control flow edge.
  if not g.live: return
  let first = g.plan.module.functions[g.fn].edges.len
  g.plan.module.functions[g.fn].edges.add(IrEdge(target: BlockId(target)))
  g.plan.module.functions[g.fn].blocks[g.current].terminator =
    IrTerminator(kind: JumpTerminator,
      edges: Span(first: int32(first), count: 1))

proc branch(g: var Lower, cond: ValueId, yes, no: int) =
  ## Terminates a conditional path with both explicit successors.
  let first = g.plan.module.functions[g.fn].edges.len
  g.plan.module.functions[g.fn].edges.add(IrEdge(target: BlockId(yes)))
  g.plan.module.functions[g.fn].edges.add(IrEdge(target: BlockId(no)))
  g.plan.module.functions[g.fn].blocks[g.current].terminator =
    IrTerminator(kind: BranchTerminator, arguments: g.operands([cond]),
      edges: Span(first: int32(first), count: 2))

proc expression(g: var Lower, e: Expr): ValueId
proc path(g: var Lower, e: Expr): ValueId
proc assignExpression(g: var Lower, dest: ValueId, e: Expr, t: Typ)

proc packed(g: var Lower, args: seq[Expr], host: var NativeHost): ValueId =
  ## Captures arguments in source order into a fixed storage frame.
  var bytes = 0
  for a in args:
    let t = if a.typ.kind == StringLitType:
        Typ(kind: StringType, len: int64(a.sval.len))
      else: a.typ
    let tid = g.layout(t)
    let l = g.plan.layouts[tid]
    bytes = aligned(bytes, int(l.align))
    host.paramTypes.add(tid)
    host.paramOffsets.add(bytes)
    bytes += int(l.bytes)
  result = g.allocate(bytes)
  for i, a in args:
    let value = g.expression(a)
    if a.typ.kind == StringLitType:
      discard g.emit(IrInstruction(op: MoveBytesOp,
        byteCount: int32(g.plan.layouts[host.paramTypes[i]].bytes)),
        [g.offset(result, host.paramOffsets[i]), value])
    else:
      g.copy(g.offset(result, host.paramOffsets[i]), value, a.typ)

proc hostCall(g: var Lower, host: NativeHost, receiver, args,
    output: ValueId) =
  ## Calls the runtime dispatcher with its stable metadata index.
  let id = g.plan.hosts.len
  g.plan.hosts.add(host)
  g.plan.module.hosts.add(IrHost(name: "nifty." & $id & "." &
    host.operation, binding: int32(id), failureMode: NoFailCall,
    signature: IrSignature(parameters: @[AddressType, Int64Type,
      AddressType, AddressType, AddressType])))
  discard g.emit(IrInstruction(op: HostCallOp, target: int32(id)),
    [ValueId(0), g.constant(int64(id)), receiver, args, output])

proc null(g: var Lower): ValueId =
  ## Defines a null address for absent ABI payloads.
  g.constant(0, AddressType)

proc data(g: var Lower, base: ValueId, t: Typ): ValueId =
  ## Finds container elements in inline or heap storage.
  let layout = g.plan.layouts[g.layout(t)]
  if layout.dynamic:
    g.load(g.offset(base, layout.dataOffset), AddressType)
  else:
    g.offset(base, layout.dataOffset)

proc borrowedView(g: var Lower, source: ValueId, t: Typ): ValueId =
  ## Presents fixed string or sequence storage as a read-only growable view.
  let layout = g.plan.layouts[g.layout(t)]
  result = g.allocate(24)
  g.clear(result, 24)
  g.store(result, g.load(source))
  g.store(g.offset(result, 8), g.constant(layout.capacity))
  g.store(g.offset(result, 16), g.offset(source, layout.dataOffset))

proc methodCall(g: var Lower, e: Expr): ValueId =
  ## Dispatches total bounded container operations over fixed layouts.
  let bt = e.kids[0].typ
  let receiver = g.path(e.kids[0])
  var host = NativeHost(kind: ContainerHost, operation: e.sval,
    receiverType: g.layout(bt), resultType: g.layout(e.typ))
  let args = g.packed(e.kids[1 .. ^1], host)
  let output = if e.typ.isNil: g.null else: g.allocType(e.typ)
  g.hostCall(host, receiver, args, output)
  if e.typ.isNil: NoValue else: g.read(output, e.typ)

proc floatInt(g: var Lower, value: ValueId): ValueId =
  ## Implements saturating truncation including NaN and infinities.
  let v = g.convert(value, Float64Type)
  let output = g.allocate(8)
  let nanBlock = g.blockId
  let rangeBlock = g.blockId
  let highBlock = g.blockId
  let lowTest = g.blockId
  let lowBlock = g.blockId
  let castBlock = g.blockId
  let done = g.blockId
  g.branch(g.compare(NotEqualComparison, v, v), nanBlock, rangeBlock)
  g.current = nanBlock
  g.store(output, g.constant(0))
  g.jump(done)
  g.current = rangeBlock
  g.branch(g.compare(GreaterEqualComparison, v,
    g.constant(cast[int64](9223372036854775808.0), Float64Type)),
    highBlock, lowTest)
  g.current = highBlock
  g.store(output, g.constant(high(int64)))
  g.jump(done)
  g.current = lowTest
  g.branch(g.compare(LessEqualComparison, v,
    g.constant(cast[int64](-9223372036854775808.0), Float64Type)),
    lowBlock, castBlock)
  g.current = lowBlock
  g.store(output, g.constant(low(int64)))
  g.jump(done)
  g.current = castBlock
  g.store(output, g.convert(v, Int64Type))
  g.jump(done)
  g.current = done
  g.load(output)

proc addressParam(g: Lower, p: Param): bool =
  ## Selects native packet storage without redefining borrow semantics.
  case g.source.mode(p.binding)
  of MutBorrowMode:
    true
  of ReadBorrowMode:
    # Immutable nonowning arrays retain their existing native value ABI.
    p.typ.kind != ArrayType or hasOwned(p.typ)
  else:
    false

proc routineCall(g: var Lower, e: Expr, dest = NoValue): ValueId =
  ## Captures value and mutable arguments before calling a routine.
  let index = g.routines[e.sval]
  let r = g.source.routines[index - 1]
  var offsets: seq[int]
  var bytes = 0
  for p in r.params:
    let borrowed = g.addressParam(p)
    bytes = aligned(bytes, if borrowed: 8 else:
      int(g.plan.layouts[g.layout(p.typ)].align))
    offsets.add(bytes)
    bytes = int(nativeSize(sizeAdd(bytes,
      (if borrowed: 8 else: g.size(p.typ))), g.line))
  let argumentType = g.argumentTypes[index]
  let argumentLayout = g.plan.module.storageTypes[argumentType - 1]
  let args = if bytes == 0: g.allocate(0)
    else: g.allocate(int(argumentLayout.byteCount),
      int(argumentLayout.alignment), argumentType)
  for i, a in e.kids:
    let p = r.params[i]
    let destination = g.fieldAddress(args, p.name, offsets[i])
    if g.addressParam(p):
      let source = g.path(a)
      let address = if a.borrowedView:
          g.borrowedView(source, a.typ)
        else: source
      g.store(destination, address)
    else:
      g.assignExpression(destination, a, p.typ)
  let output = if r.ret.isNil: g.null
    elif int32(dest) >= 0: dest
    else: g.allocType(r.ret)
  if r.externLib != "":
    var host = NativeHost(kind: ExternHost, operation: r.name,
      symbol: (if r.cname != "": r.cname else: r.name),
      library: r.externLib, resultType: g.layout(r.ret),
      receiverType: -1, paramOffsets: offsets)
    var values: seq[ValueId]
    var parameters: seq[IrType]
    for i, p in r.params:
      host.paramTypes.add(g.layout(p.typ))
      host.paramVars.add(g.source.mode(p.binding) == MutBorrowMode)
      var v: ValueId
      if g.addressParam(p):
        v = g.load(g.offset(args, offsets[i]), AddressType)
        if p.typ.kind in {StringType, CStringType}:
          v = g.data(v, p.typ)
      elif p.typ.kind in {StringType, CStringType}:
        v = g.data(g.offset(args, offsets[i]), p.typ)
      elif aggregate(p.typ):
        v = g.offset(args, offsets[i])
      else:
        v = g.load(g.offset(args, offsets[i]), scalar(p.typ))
      values.add(v)
      parameters.add(g.kind(v))
    let id = g.plan.hosts.len
    g.plan.hosts.add(host)
    let returns = if r.ret.isNil: newSeq[IrType]() else: @[scalar(r.ret)]
    g.plan.module.hosts.add(IrHost(name: host.symbol, binding: int32(id),
      failureMode: NoFailCall,
      signature: IrSignature(parameters: parameters, returns: returns)))
    let v = g.emit(IrInstruction(op: HostCallOp, target: int32(id),
      results: Span(count: int32(returns.len))), values,
      if r.ret.isNil: Int64Type else: scalar(r.ret))
    if not r.ret.isNil: g.copy(output, v, r.ret)
  else:
    let zero = g.constant(0)
    g.patches.add(g.plan.module.functions[g.fn].instructions.len)
    let arena = g.emit(IrInstruction(op: OffsetAddressOp),
      [ValueId(3), zero], AddressType)
    let signature = g.plan.module.functions[index].signature
    var passed = @[ValueId(0), args, output, arena]
    for i, storage in signature.parameterStorage:
      if g.plan.module.functions[g.fn].values[int32(passed[i])].storage !=
          storage:
        passed[i] = g.untyped(passed[i])
        g.plan.module.functions[g.fn].values[int32(passed[i])].storage =
          storage
    discard g.emit(IrInstruction(op: CallOp, target: int32(index)), passed)
    g.calls[g.fn].add(index)
  if r.ret.isNil: NoValue else: g.read(output, r.ret)

proc path(g: var Lower, e: Expr): ValueId =
  ## Evaluates a storage path, including every index, left to right.
  case e.kind
  of IdentExpr:
    if e.symKind == GlobalSym:
      result = g.emit(IrInstruction(op: GlobalAddressOp,
        target: int32(g.globals[e.sval])), [], AddressType,
        g.storage(e.typ))
    else:
      result = g.bindings[e.binding].address
  of FieldExpr:
    if not e.isOptOk and e.kids[0].typ.kind != ObjectType:
      return g.expression(e)
    var p = g.path(e.kids[0])
    let l = g.plan.layouts[g.layout(e.kids[0].typ)]
    if e.isOptOk:
      return g.fieldAddress(p, "ok", l.okOffset)
    if e.kids[0].typ.opt or e.kids[0].unwrapOpt:
      p = g.fieldAddress(p, "value", 0)
    for f in l.fields:
      if f.name == e.sval:
        return g.fieldAddress(p, f.name, f.offset)
    raise newException(NiftyError,
      "Internal compiler error: native field unavailable: " & e.sval)
  of IndexExpr:
    let base = g.path(e.kids[0])
    let index = g.expression(e.kids[1])
    let bt = e.kids[0].typ
    let l = g.plan.layouts[g.layout(bt)]
    if bt.kind == SparseMapType:
      var host = NativeHost(kind: ContainerHost, operation: "address",
        receiverType: g.layout(bt), resultType: -1)
      host.paramTypes = @[g.layout(e.kids[1].typ)]
      host.paramOffsets = @[0]
      let args = g.allocType(e.kids[1].typ)
      g.copy(args, index, e.kids[1].typ)
      let output = g.allocate(8)
      g.hostCall(host, base, args, output)
      return g.load(output, AddressType)
    let adjusted = if bt.kind == DenseMapType:
        g.binary(SubtractOp, index, g.constant(l.lower))
      else: index
    let stride = if bt.kind == StringType: 1
      elif bt.kind == DenseMapType: g.size(bt.val)
      else: g.size(bt.elem)
    let displacement = g.binary(MultiplyOp, adjusted,
      g.constant(int64(stride)))
    let start = if bt.kind == DenseMapType: l.valOffset
      elif bt.kind in {SeqType, StringType} and not bt.dynamic:
        l.dataOffset else: 0
    let storage = if bt.dynamic: g.data(base, bt) else: base
    result = g.emit(IrInstruction(op: OffsetAddressOp,
      offset: int64(start)), [storage, displacement], AddressType)
  else:
    result = g.expression(e)

proc expression(g: var Lower, e: Expr): ValueId =
  ## Evaluates one checked expression with source language sequencing.
  g.line = e.line
  if e.wrapOpt:
    let saved = e.typ
    e.typ = e.wrapSource
    e.wrapOpt = false
    let value = g.expression(e)
    e.typ = saved
    e.wrapOpt = true
    let output = g.allocType(saved)
    g.clear(output, g.size(saved))
    g.copy(output, value, deOpt(saved))
    g.store(g.offset(output, g.plan.layouts[g.layout(saved)].okOffset),
      g.constant(1, irs.BoolType))
    return output
  case e.kind
  of NoneExpr:
    result = g.allocType(e.typ)
    g.clear(result, g.size(e.typ))
  of IntExpr:
    result = g.constant(e.ival)
  of FloatExpr:
    result = if e.typ.width == 4:
        g.constant(int64(cast[uint32](float32(e.fval))), Float32Type)
      else: g.constant(cast[int64](e.fval), Float64Type)
  of BoolExpr:
    result = g.constant(int64(e.bval), irs.BoolType)
  of StrExpr:
    let terminated = e.typ.kind == CStringType
    let fixed = e.typ.kind == StringLitType or e.typ.dynamic
    let t = if fixed:
        Typ(kind: StringType, len: int64(e.sval.len + ord(terminated))) else: e.typ
    let storage = g.allocType(t)
    g.clear(storage, g.size(t))
    g.store(storage, g.constant(int64(e.sval.len + ord(terminated))))
    for i, c in e.sval:
      g.store(g.offset(storage, 8 + i),
        g.constant(int64(ord(c)), UInt8Type))
    result = if e.typ.dynamic: g.borrowedView(storage, t) else: storage
  of IdentExpr:
    if e.symKind == ConstSym:
      return g.constant(g.constants[e.sval])
    result = g.read(g.path(e), e.typ)
    if e.unwrapOpt:
      result = g.read(g.path(e), deOpt(e.typ))
    if aggregate(e.typ) and e.typ.kind != ArrayType:
      let captured = g.allocType(e.typ)
      g.copy(captured, result, e.typ)
      result = captured
  of IndexExpr:
    let p = g.path(e)
    if e.kids[0].typ.kind == StringType:
      result = g.convert(g.load(p, UInt8Type), Int64Type)
    else:
      result = g.read(p, e.typ)
      if aggregate(e.typ) and e.typ.kind != ArrayType:
        let captured = g.allocType(e.typ)
        g.copy(captured, result, e.typ)
        result = captured
  of NegExpr:
    let value = g.expression(e.kids[0])
    result = g.emit(IrInstruction(op: NegateOp), [value], g.kind(value))
  of NotExpr:
    result = g.binary(XorOp, g.expression(e.kids[0]),
      g.constant(1, irs.BoolType))
  of BinExpr:
    let a = g.expression(e.kids[0])
    if e.sval in ["and", "or"]:
      let output = g.allocate(1, 1)
      g.store(output, a)
      let rhs = g.blockId
      let done = g.blockId
      if e.sval == "and": g.branch(a, rhs, done)
      else: g.branch(a, done, rhs)
      g.current = rhs
      g.store(output, g.expression(e.kids[1]))
      g.jump(done)
      g.current = done
      return g.load(output, irs.BoolType)
    let b = g.expression(e.kids[1])
    case e.sval
    of "==", "!=", "<", "<=", ">", ">=":
      let op = case e.sval
        of "==": EqualComparison
        of "!=": NotEqualComparison
        of "<": LessComparison
        of "<=": LessEqualComparison
        of ">": GreaterComparison
        else: GreaterEqualComparison
      result = g.compare(op, a, b)
    else:
      let op = case e.sval
        of "+": AddOp
        of "-": SubtractOp
        of "*": MultiplyOp
        of "/": DivideOp
        of "%": RemainderOp
        else:
          raise newException(NiftyError,
            "Internal compiler error: unsupported native operator " & e.sval)
      result = g.binary(op, a, b)
  of CallExpr:
    if e.sval in ["float32", "float64"]:
      result = g.convert(g.expression(e.kids[0]), scalar(e.typ))
    else:
      result = g.routineCall(e)
  of FieldExpr:
    let bt = e.kids[0].typ
    if bt.kind == OpaqueType and e.sval == "isNull":
      result = g.compare(EqualComparison, g.expression(e.kids[0]), g.constant(0))
    elif bt.kind == FloatType:
      result = g.floatInt(g.expression(e.kids[0]))
    elif e.sval in ["toInt", "toCString"] and bt.kind == StringType:
      result = g.methodCall(e)
    elif e.sval == "cap" and bt.dynamic:
      result = g.load(g.offset(g.path(e.kids[0]), 8))
    elif not bt.opt and bt.kind in {SeqType, StringType, SetType,
        QueueType, DenseMapType, SparseMapType}:
      result = g.load(g.path(e.kids[0]))
    else:
      result = g.read(g.path(e), if e.unwrapOpt: deOpt(e.typ) else: e.typ)
      if aggregate(e.typ) and e.typ.kind != ArrayType:
        let captured = g.allocType(e.typ)
        g.copy(captured, result, e.typ)
        result = captured
  of MethodExpr:
    let bt = e.kids[0].typ
    if bt.kind == FloatType:
      return g.floatInt(g.expression(e.kids[0]))
    if bt.opt and e.sval == "or":
      let base = g.expression(e.kids[0])
      let fallback = g.expression(e.kids[1])
      let output = g.allocType(e.typ)
      let yes = g.blockId
      let no = g.blockId
      let done = g.blockId
      g.branch(g.load(g.offset(base,
        g.plan.layouts[g.layout(bt)].okOffset), irs.BoolType), yes, no)
      g.current = yes
      g.copy(output, g.read(base, deOpt(bt)), e.typ)
      g.jump(done)
      g.current = no
      g.copy(output, fallback, e.typ)
      g.jump(done)
      g.current = done
      return g.read(output, e.typ)
    result = g.methodCall(e)

proc statements(g: var Lower, body: seq[Stmt], scope: int)

proc cleanup(g: var Lower, drops: seq[BindingId]) =
  ## Emits the destruction order already established by semantic analysis.
  for id in drops:
    let owner = g.bindings[id]
    let host = NativeHost(kind: ContainerHost, operation: "drop",
      receiverType: g.layout(owner.typ), resultType: -1)
    g.hostCall(host, owner.address, g.null, g.null)

proc assignExpression(g: var Lower, dest: ValueId, e: Expr, t: Typ) =
  ## Forwards caller storage directly through native destination returns.
  if e.kind == CallExpr and e.sval in g.routines and not e.wrapOpt:
    let ret = g.source.routines[g.routines[e.sval] - 1].ret
    if g.size(ret) == g.size(t) and
        (aggregate(t) or scalar(ret) == scalar(t)):
      discard g.routineCall(e, dest)
      return
  if aggregate(t) and e.kind in {IdentExpr, FieldExpr, IndexExpr} and
      not e.wrapOpt and not e.unwrapOpt:
    g.copy(dest, g.path(e), t)
    return
  g.copy(dest, g.expression(e), t)

proc initialized(g: var Lower, body: seq[Stmt], index: int): bool =
  ## Proves consecutive writes initialize every byte before the first read.
  let declaration = body[index]
  if declaration.kind notin {VarStmt, LetStmt} or
      declaration.init != nil or declaration.typ.kind != ObjectType or
      declaration.typ.opt or hasOwned(declaration.typ):
    return false
  proc mentions(e: Expr): bool =
    ## Detects every direct reference to the not-yet-initialized local.
    if e.isNil:
      return false
    if e.kind == IdentExpr and e.sval == declaration.name:
      return true
    for child in e.kids:
      if mentions(child):
        return true
  proc destination(g: var Lower, e: Expr, offset: var int): bool =
    ## Accepts only fixed fields rooted at the newly declared local.
    if e.kind == IdentExpr:
      return e.sval == declaration.name
    if e.kind != FieldExpr or e.isOptOk or
        e.kids[0].typ.kind != ObjectType or
        not destination(g, e.kids[0], offset):
      return false
    let data = g.plan.layouts[g.layout(e.kids[0].typ)]
    for field in data.fields:
      if field.name == e.sval:
        offset += field.offset
        return true
  var ranges: seq[tuple[first, last: int]]
  let bytes = g.size(declaration.typ)
  for i in index + 1 ..< body.len:
    let assignment = body[i]
    if assignment.kind != AssignStmt or mentions(assignment.rhs):
      return false
    var offset = 0
    if not destination(g, assignment.lhs, offset):
      return false
    ranges.add((offset, offset + g.size(assignment.lhs.typ)))
    var cursor = 0
    for unused in 0 ..< ranges.len:
      let before = cursor
      for item in ranges:
        if item.first <= cursor:
          cursor = max(cursor, item.last)
      if cursor == before:
        break
    if cursor >= bytes:
      return true

proc statement(g: var Lower, s: Stmt, initialize = true) =
  ## Lowers statements to explicit mutation and structured branches.
  g.line = s.line
  case s.kind
  of VarStmt, LetStmt:
    let p = g.allocType(s.typ)
    let retained = g.arena
    if s.init.isNil:
      if initialize:
        g.clear(p, g.size(s.typ))
    else:
      g.assignExpression(p, s.init, s.typ)
    g.arena = retained
    g.bindings[s.binding] = Binding(address: p, typ: s.typ)
  of AssignStmt:
    if s.lhs.kind == IndexExpr and
        s.lhs.kids[0].typ.kind in {DenseMapType, SparseMapType}:
      let receiver = g.path(s.lhs.kids[0])
      var host = NativeHost(kind: ContainerHost, operation: "put",
        receiverType: g.layout(s.lhs.kids[0].typ), resultType: -1)
      let args = g.packed(@[s.lhs.kids[1], s.rhs], host)
      g.hostCall(host, receiver, args, g.null)
    else:
      let p = g.path(s.lhs)
      if s.lhs.kind == IndexExpr and s.lhs.kids[0].typ.kind == StringType:
        g.store(p, g.convert(g.expression(s.rhs), UInt8Type))
      else:
        g.assignExpression(p, s.rhs, s.lhs.typ)
  of IfStmt:
    let done = g.blockId
    for br in s.elifs:
      let yes = g.blockId
      let no = g.blockId
      let cond = g.expression(br.cond)
      g.branch(cond, yes, no)
      g.current = yes
      g.statements(br.body, br.scope)
      g.jump(done)
      g.current = no
    g.statements(s.elseBody, s.elseScope)
    g.jump(done)
    g.current = done
  of WhileStmt, LoopStmt:
    let ctr = if s.maxTrips > 0: g.allocate(8) else: NoValue
    if s.maxTrips > 0: g.store(ctr, g.constant(0))
    let test = g.blockId
    let run = g.blockId
    let done = g.blockId
    g.jump(test)
    g.current = test
    if s.maxTrips > 0:
      let check = g.blockId
      g.branch(g.compare(LessComparison, g.load(ctr),
        g.constant(s.maxTrips)), check, done)
      g.current = check
    if s.kind == WhileStmt:
      let cond = g.expression(s.cond)
      g.branch(cond, run, done)
    else:
      g.jump(run)
    g.current = run
    g.breaks.add(done)
    g.statements(s.body, s.bodyScope)
    discard g.breaks.pop()
    if g.live and s.maxTrips > 0:
      g.store(ctr, g.binary(AddOp, g.load(ctr), g.constant(1)))
    g.jump(test)
    g.current = done
  of ForStmt:
    let p = g.allocate(8)
    g.store(p, g.expression(s.lo))
    let bound = g.expression(s.hi)
    g.bindings[s.binding] = Binding(address: p, typ: intType())
    let test = g.blockId
    let run = g.blockId
    let done = g.blockId
    g.jump(test)
    g.current = test
    g.branch(g.compare(if s.inclusive: LessEqualComparison
      else: LessComparison, g.load(p), bound), run, done)
    g.current = run
    g.breaks.add(done)
    g.statements(s.body, s.bodyScope)
    discard g.breaks.pop()
    if g.live:
      if s.inclusive:
        let increment = g.blockId
        g.branch(g.compare(EqualComparison, g.load(p), bound), done, increment)
        g.current = increment
      g.store(p, g.binary(AddOp, g.load(p), g.constant(1)))
    g.jump(test)
    g.current = done
  of ReturnStmt:
    if s.value != nil:
      g.assignExpression(ValueId(2), s.value, g.routine.ret)
    g.cleanup(s.drops)
    g.plan.module.functions[g.fn].blocks[g.current].terminator =
      IrTerminator(kind: ReturnTerminator)
  of BreakStmt:
    g.cleanup(s.drops)
    g.jump(g.breaks[^1])
  of EchoStmt:
    raise newException(NiftyError, "echo must be expanded before native lowering")
  of DiscardStmt, CallStmt:
    discard g.expression(s.value)
  of BlockStmt:
    let entry = g.arena
    g.statements(s.body, s.bodyScope)
    g.arena = entry
  of WithStmt:
    let receiver = if s.typ.kind != LockType and s.lhs != nil:
        g.path(s.lhs)
      else: g.emit(IrInstruction(op: GlobalAddressOp,
        target: int32(g.globals[s.name])), [], AddressType,
        g.storage(s.typ))
    if s.typ.kind == LockType:
      let host = NativeHost(kind: LockHost, operation: "lock",
        receiverType: g.layout(s.typ), resultType: -1)
      g.hostCall(host, receiver, g.null, g.null)
      g.statements(s.body, s.bodyScope)
      if g.live:
        var unlock = host
        unlock.operation = "unlock"
        g.hostCall(unlock, receiver, g.null, g.null)
    else:
      let start = Expr(kind: CallExpr, sval: "start", kids: @[s.lhs])
      discard g.routineCall(start)
      g.statements(s.body, s.bodyScope)
      if g.live:
        let finish = Expr(kind: CallExpr, sval: "end", kids: @[s.lhs])
        discard g.routineCall(finish)
  of ForEachStmt:
    let receiver = g.path(s.value)
    let bt = s.value.typ
    let l = g.plan.layouts[g.layout(bt)]
    let p = g.allocate(8)
    g.store(p, g.constant(0))
    let bound = if bt.kind in {SetType, DenseMapType}:
        g.constant(l.upper - l.lower + 1) else: g.load(receiver)
    let borrowed = g.source.mode(s.binding).isBorrow
    let item = if borrowed: NoValue else: g.allocType(s.typ)
    g.bindings[s.binding] = Binding(address: item, typ: s.typ)
    var value = NoValue
    if s.name2 != "":
      value = g.allocType(s.typ2)
      g.bindings[s.binding2] = Binding(address: value, typ: s.typ2)
    let test = g.blockId
    let run = g.blockId
    let next = g.blockId
    let done = g.blockId
    g.jump(test)
    g.current = test
    g.branch(g.compare(LessComparison, g.load(p), bound), run, done)
    g.current = run
    var index = g.load(p)
    if bt.kind in {SetType, DenseMapType}:
      index = g.binary(AddOp, index, g.constant(l.lower))
      var host = NativeHost(kind: ContainerHost, operation: "contains",
        receiverType: g.layout(bt), resultType: g.layout(Typ(kind: types.BoolType)),
        paramTypes: @[g.layout(intType())], paramOffsets: @[0])
      let args = g.allocate(8)
      g.store(args, index)
      let output = g.allocate(1, 1)
      g.hostCall(host, receiver, args, output)
      let present = g.blockId
      g.branch(g.load(output, irs.BoolType), present, next)
      g.current = present
      g.copy(item, index, s.typ)
      if int32(value) >= 0:
        let displacement = g.binary(MultiplyOp, g.load(p),
          g.constant(int64(g.size(s.typ2))))
        let address = g.emit(IrInstruction(op: OffsetAddressOp,
          offset: int64(l.valOffset)), [receiver, displacement], AddressType)
        g.copy(value, g.read(address, s.typ2), s.typ2)
    else:
      if bt.kind == QueueType:
        index = g.binary(RemainderOp,
          g.binary(AddOp, g.load(g.offset(receiver, 8)), index),
          g.constant(bt.len))
      let stride = if bt.kind == StringType: 1 else: g.size(s.typ)
      let data = if bt.kind == SparseMapType: l.keyOffset
        elif bt.dynamic: 0 else: l.dataOffset
      let displacement = g.binary(MultiplyOp, index, g.constant(int64(stride)))
      let storage = if bt.dynamic: g.data(receiver, bt) else: receiver
      let address = g.emit(IrInstruction(op: OffsetAddressOp,
        offset: int64(data)), [storage, displacement], AddressType)
      if bt.kind == StringType:
        g.copy(item, g.convert(g.load(address, UInt8Type), Int64Type), s.typ)
      elif borrowed:
        g.bindings[s.binding] = Binding(address: address, typ: s.typ)
      else:
        g.copy(item, g.read(address, s.typ), s.typ)
      if int32(value) >= 0:
        let vd = g.binary(MultiplyOp, index,
          g.constant(int64(g.size(s.typ2))))
        let vp = g.emit(IrInstruction(op: OffsetAddressOp,
          offset: int64(l.valOffset)), [receiver, vd], AddressType)
        g.copy(value, g.read(vp, s.typ2), s.typ2)
    g.breaks.add(done)
    g.statements(s.body, s.bodyScope)
    discard g.breaks.pop()
    g.jump(next)
    g.current = next
    g.store(p, g.binary(AddOp, g.load(p), g.constant(1)))
    g.jump(test)
    g.current = done

proc statements(g: var Lower, body: seq[Stmt], scope: int) =
  ## Lowers reachable statements and releases temporary arena slices.
  for i, s in body:
    if not g.live: break
    let entry = g.arena
    let initialize = not g.initialized(body, i)
    g.statement(s, initialize)
    if s.kind notin {VarStmt, LetStmt}:
      g.arena = entry
  if g.live:
    g.cleanup(g.source.semantics.scopes[scope].drops)

proc lowerNative*(checked: Module, filename = "",
    portableIo = false): NativePlan =
  ## Builds native IR, fixed layouts, and executable runtime metadata.
  checked.requireChecked()
  let source = lowerEcho(checked, filename, portableIo)
  var g = Lower(source: source)
  g.plan.module.pointerBytes = 8
  g.plan.module.files = if srcFiles.len > 0: srcFiles else: @[filename]
  let signature = IrSignature(parameters:
    @[AddressType, AddressType, AddressType, AddressType],
    parameterStorage: @[0'i32, 0, 0, 0])
  g.plan.module.signatures = @[signature]
  g.plan.module.functions.add(IrFunction(name: "nifty.entry",
    signature: signature, failureMode: NoFailCall))
  for i, r in source.routines:
    g.routines[r.name] = i + 1
    g.plan.module.functions.add(IrFunction(name: r.name,
      signature: signature, failureMode: NoFailCall,
      directOnly: r.kind != ThreadRoutine and r.externLib == ""))
  g.argumentTypes = newSeq[int32](g.plan.module.functions.len)
  for i, r in source.routines:
    var
      members: seq[IrField]
      bytes = 0
      alignment = 1
    for p in r.params:
      let storage = if g.addressParam(p):
          g.plan.addStorage(IrStorage(kind: PointerStorage,
            byteCount: 8, alignment: 8))
        else: g.storage(p.typ)
      let data = g.plan.module.storageTypes[storage - 1]
      bytes = aligned(bytes, int(data.alignment))
      members.add(IrField(name: p.name, storage: storage,
        offset: int32(bytes)))
      bytes = int(nativeSize(sizeAdd(bytes, data.byteCount), r.line))
      alignment = max(alignment, int(data.alignment))
    let arguments = g.plan.recordStorage("$args." & $i & "." & r.name,
      members, aligned(bytes, alignment), alignment)
    g.argumentTypes[i + 1] = arguments
    let returned = g.storage(r.ret)
    g.plan.module.functions[i + 1].signature.parameterStorage =
      @[0'i32, if bytes == 0: 0'i32 else: arguments, returned, 0'i32]
    g.plan.module.functions[i + 1].signature.passing = @[
      DirectPassing, if bytes == 0: DirectPassing else: ValuePassing,
      if returned == 0: DirectPassing else: MutablePassing, DirectPassing]
  g.frames = newSeq[int](g.plan.module.functions.len)
  g.calls = newSeq[seq[int]](g.frames.len)
  for c in source.consts: g.constants[c.name] = c.value
  for v in source.globals:
    let l = g.plan.layouts[g.layout(v.typ)]
    g.plan.globalBytes = aligned(g.plan.globalBytes, int(l.align))
    let off = g.plan.globalBytes
    g.globals[v.name] = g.plan.module.globals.len
    g.plan.module.globals.add(IrGlobal(name: v.name, offset: int64(off),
      bytes: Span(first: int32(off), count: int32(l.bytes)),
      alignment: int32(l.align), storage: g.storage(v.typ)))
    if v.typ.kind == LockType: g.plan.lockOffsets.add(off)
    if v.typ.kind == ChannelType: g.plan.channelOffsets.add(off)
    g.plan.globalBytes = int(nativeSize(
      sizeAdd(g.plan.globalBytes, l.bytes), v.line))
  # Runtime metadata keeps its declaration-order ABI and reverses at exit.
  for i in countdown(source.semantics.globalDrops.high, 0):
    let owner = source.semantics.bindings[source.semantics.globalDrops[i]]
    let global = g.plan.module.globals[g.globals[owner.name]]
    g.plan.ownedGlobals.add(OwnedGlobal(offset: int(global.offset),
      layout: g.layout(owner.typ)))
  g.plan.initialData = newSeq[byte](g.plan.globalBytes)
  g.plan.module.data = g.plan.initialData
  for fn in 0 ..< g.plan.module.functions.len:
    g.fn = fn
    g.current = 0
    g.arena = 0
    g.highArena = 0
    g.patches.setLen(0)
    g.bindings.clear()
    for i in 0 ..< 4:
      g.plan.module.functions[fn].values.add(IrValue(valueType: AddressType,
        storage: g.plan.module.functions[fn].signature.parameterStorage[i]))
    g.plan.module.functions[fn].blocks.add(IrBlock(
      parameters: Span(first: 0, count: 4)))
    if fn > 0:
      g.routine = source.routines[fn - 1]
      var bytes = 0
      for p in g.routine.params:
        let borrowed = g.addressParam(p)
        bytes = aligned(bytes, if borrowed: 8 else:
          int(g.plan.layouts[g.layout(p.typ)].align))
        let address = g.fieldAddress(ValueId(1), p.name, bytes)
        let bound = if borrowed:
            g.untyped(g.load(address, AddressType))
          else: address
        if borrowed:
          g.plan.module.functions[g.fn].values[int32(bound)].storage =
            g.storage(p.typ)
        g.bindings[p.binding] = Binding(typ: p.typ, address: bound)
        bytes = int(nativeSize(sizeAdd(bytes,
          (if borrowed: 8 else: g.size(p.typ))), g.line))
      if g.routine.externLib == "":
        g.statements(g.routine.body, g.routine.bodyScope)
    if g.live:
      g.plan.module.functions[fn].blocks[g.current].terminator =
        IrTerminator(kind: ReturnTerminator)
    g.frames[fn] = aligned(g.highArena, 8)
    for patch in g.patches:
      g.plan.module.functions[fn].instructions[patch].offset =
        int64(g.frames[fn])
  var totals = newSeq[int](g.frames.len)
  var visiting = initHashSet[int]()
  proc total(fn: int): int =
    ## Computes the maximum arena path through the acyclic call graph.
    if fn in visiting:
      raise newException(NiftyError,
        "Internal compiler error: recursive native arena call graph")
    if totals[fn] > 0: return totals[fn]
    visiting.incl(fn)
    var child = 0
    for callee in g.calls[fn]: child = max(child, total(callee))
    visiting.excl(fn)
    result = int(sizeAdd(g.frames[fn], child))
    totals[fn] = result
  for i, r in source.routines:
    if r.kind == ThreadRoutine:
      g.plan.threads.add(ThreadPlan(name: r.name, count: r.instances,
        functionIndex: i + 1, arenaBytes: total(i + 1)))
  result = g.plan

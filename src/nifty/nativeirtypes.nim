## Describes Nifty value and owner representations in the shared native IR.
import nativeplans, types, common, backend/irs

proc nativeSize*(bytes: int64, line = 0): int32 =
  ## Rejects storage that cannot be represented by the native IR.
  if bytes < 0 or bytes > high(int32):
    err(line, "native storage size exceeds 2147483647 bytes")
  int32(bytes)

proc addStorage*(plan: var NativePlan, data: IrStorage): int32 =
  ## Appends a storage descriptor using one-based IR references.
  plan.module.storageTypes.add(data)
  int32(plan.module.storageTypes.len)

proc byteStorage(plan: var NativePlan): int32 =
  ## Declares a byte element for explicit payloads and padding.
  plan.addStorage(IrStorage(kind: ScalarStorage, scalar: UInt8Type,
    byteCount: 1, alignment: 1))

proc arrayStorage(plan: var NativePlan, element: int32,
    count: int): int32 =
  ## Declares a bounded array with the element's exact representation.
  let item = plan.module.storageTypes[element - 1]
  plan.addStorage(IrStorage(kind: ArrayStorage, element: element,
    length: nativeSize(count),
    byteCount: nativeSize(sizeMul(count, item.byteCount)),
    alignment: item.alignment))

proc recordStorage*(plan: var NativePlan, name: string,
    members: seq[IrField], bytes, alignment: int): int32 =
  ## Declares every record byte, including internal and trailing padding.
  var
    fields: seq[IrField]
    offset = 0
  for member in members:
    if int(member.offset) > offset:
      let padding = plan.arrayStorage(plan.byteStorage,
        int(member.offset) - offset)
      fields.add(IrField(name: "$pad" & $offset, storage: padding,
        offset: int32(offset), role: PaddingField))
    fields.add(member)
    offset = int(member.offset) +
      int(plan.module.storageTypes[member.storage - 1].byteCount)
  if bytes > offset:
    let padding = plan.arrayStorage(plan.byteStorage, bytes - offset)
    fields.add(IrField(name: "$pad" & $offset, storage: padding,
      offset: int32(offset), role: PaddingField))
  let first = int32(plan.module.fields.len)
  plan.module.fields.add(fields)
  plan.addStorage(IrStorage(name: name, kind: StructStorage,
    byteCount: nativeSize(bytes), alignment: int32(alignment),
    fields: Span(first: first, count: int32(fields.len))))

proc layoutStorage*(plan: var NativePlan, mapping: var seq[int32],
    index: int): int32 =
  ## Maps a checked native layout to complete scalar or aggregate storage.
  if index < 0:
    return 0
  if mapping.len <= index:
    mapping.setLen(index + 1)
  if mapping[index] > 0:
    return mapping[index]
  let data = plan.layouts[index]
  var members: seq[IrField]
  if data.optional:
    # Optional layouts retain their base payload followed by a presence byte.
    var base = data
    base.optional = false
    base.bytes = int64(data.okOffset)
    base.okOffset = -1
    let baseIndex = plan.layouts.len
    plan.layouts.add(base)
    let payload = plan.layoutStorage(mapping, baseIndex)
    members.add(IrField(name: "value", storage: payload))
    let present = plan.addStorage(IrStorage(kind: ScalarStorage,
      scalar: irs.BoolType, byteCount: 1, alignment: 1))
    members.add(IrField(name: "ok", storage: present,
      offset: int32(data.okOffset), role: DiscriminatorField))
  elif data.dynamic:
    let
      word = plan.addStorage(IrStorage(kind: ScalarStorage,
        scalar: Int64Type, byteCount: 8, alignment: 8))
      address = plan.addStorage(IrStorage(kind: PointerStorage,
        byteCount: 8, alignment: 8))
    members.add(IrField(name: "length", storage: word,
      role: RuntimeField))
    members.add(IrField(name: "capacity", storage: word, offset: 8,
      role: RuntimeField))
    members.add(IrField(name: "data", storage: address, offset: 16,
      role: RuntimeField))
  else:
    case data.kind
    of IntType, FloatType, OpaqueType, types.BoolType:
      let scalar = case data.kind
        of FloatType:
          if data.bytes == 4: Float32Type else: Float64Type
        of types.BoolType: irs.BoolType
        else:
          case data.bytes
          of 1:
            if data.lower < 0: Int8Type else: UInt8Type
          of 2:
            if data.lower < 0: Int16Type else: UInt16Type
          of 4:
            if data.lower < 0: Int32Type else: UInt32Type
          else: Int64Type
      result = plan.addStorage(IrStorage(kind: ScalarStorage,
        scalar: scalar, byteCount: int32(data.bytes),
        alignment: int32(data.align)))
    of ArrayType:
      let element = plan.layoutStorage(mapping, data.elem)
      result = plan.arrayStorage(element, int(data.capacity))
    of ObjectType:
      for field in data.fields:
        let storage = plan.layoutStorage(mapping, field.typ)
        members.add(IrField(name: field.name, storage: storage,
          offset: int32(field.offset)))
    of LockType:
      result = plan.addStorage(IrStorage(name: "$lock." & $index,
        kind: OpaqueStorage, byteCount: int32(data.bytes),
        alignment: int32(data.align)))
    of StringType, StringLitType, SeqType, QueueType, ChannelType,
        SetType, DenseMapType, SparseMapType:
      let word = plan.addStorage(IrStorage(kind: ScalarStorage,
        scalar: Int64Type, byteCount: 8, alignment: 8))
      members.add(IrField(name: "length", storage: word,
        role: RuntimeField))
      case data.kind
      of QueueType, ChannelType:
        members.add(IrField(name: "head", storage: word,
          offset: 8, role: RuntimeField))
      else:
        discard
      case data.kind
      of StringType, StringLitType:
        let payload = plan.arrayStorage(plan.byteStorage, int(data.capacity))
        members.add(IrField(name: "data", storage: payload, offset: 8))
      of SeqType, QueueType, ChannelType:
        let element = plan.layoutStorage(mapping, data.elem)
        let payload = plan.arrayStorage(element, int(data.capacity))
        members.add(IrField(name: "data", storage: payload,
          offset: int32(data.dataOffset)))
      of SetType, DenseMapType:
        let count = int((data.upper - data.lower + 64) div 64)
        let bits = plan.arrayStorage(word, count)
        members.add(IrField(name: "bits", storage: bits, offset: 8))
        if data.kind == DenseMapType:
          let element = plan.layoutStorage(mapping, data.val)
          let values = plan.arrayStorage(element,
            int(data.upper - data.lower + 1))
          members.add(IrField(name: "values", storage: values,
            offset: int32(data.valOffset)))
      of SparseMapType:
        let
          key = plan.layoutStorage(mapping, data.key)
          value = plan.layoutStorage(mapping, data.val)
          keys = plan.arrayStorage(key, int(data.capacity))
          values = plan.arrayStorage(value, int(data.capacity))
        members.add(IrField(name: "keys", storage: keys, offset: 8))
        members.add(IrField(name: "values", storage: values,
          offset: int32(data.valOffset)))
      else:
        discard
    of TypeVarType:
      doAssert false, "Native storage requires instantiated types"
  if result == 0:
    result = plan.recordStorage("$native." & $index, members,
      int(data.bytes), int(data.align))
  mapping[index] = result

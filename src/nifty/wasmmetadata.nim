## Portable runtime descriptors, independent of native compiler object layouts.
import std/[json, jsonutils]
import common, nativeplans, types

const
  WasmMetadataMagic* = "NIFTYWM1"
  WasmMetadataHeader* = 16
  WasmMetadataCapacity* = 1048576
  WasmStorageLimit* = 1024 * 1024 * 1024

type
  WasmMetadata = object
    globalBytes: int
    initialData: seq[byte]
    threads: seq[ThreadPlan]
    hosts: seq[NativeHost]
    layouts: seq[NativeLayout]
    lockOffsets, channelOffsets: seq[int]
    ownedGlobals: seq[OwnedGlobal]

proc invalid(message: string) {.noreturn.} =
  ## Reports malformed portable runtime descriptors.
  raise newException(NiftyError, "invalid WASM metadata: " & message)

proc validateWasmMetadata*(plan: NativePlan) =
  ## Bounds allocations and all descriptors consumed by the shared runtime.
  for host in plan.hosts:
    if host.kind == EmbeddedHost:
      invalid("embedding callbacks require a scripting runtime")
  if plan.globalBytes < 0 or plan.globalBytes > WasmStorageLimit or
      plan.initialData.len > plan.globalBytes:
    invalid("global allocation")
  if plan.threads.len != 1 or plan.threads[0].count != 1:
    invalid("WASM currently requires exactly one thread instance")
  if plan.threads[0].arenaBytes < 0 or
      plan.threads[0].arenaBytes > WasmStorageLimit:
    invalid("thread arena")
  if int64(plan.globalBytes) + int64(plan.threads[0].arenaBytes) >
      WasmStorageLimit:
    invalid("startup storage exceeds limit")
  if plan.channelOffsets.len != 0:
    invalid("WASM channels are not supported")
  for offset in plan.lockOffsets:
    if offset < 0 or offset > plan.globalBytes - 8:
      invalid("lock offset")
  for layout in plan.layouts:
    if layout.bytes < 0 or layout.bytes > WasmStorageLimit or
        layout.align notin [1'i64, 2, 4, 8, 16] or
        layout.capacity < 0 or layout.capacity > WasmStorageLimit:
      invalid("layout size")
    if layout.kind == ChannelType:
      invalid("WASM channels are not supported")
    if layout.optional and (layout.okOffset < 0 or
        layout.okOffset >= layout.bytes):
      invalid("optional discriminator")
    if layout.kind == OpaqueType and
        (layout.align != 8 or layout.dynamic or layout.owned or
        (not layout.optional and layout.bytes != 8) or
        (layout.optional and
          (layout.bytes != 16 or layout.okOffset != 8))):
      invalid("opaque handle layout")
    if layout.dynamic and
        (layout.kind notin {StringType, SeqType} or
        not layout.owned or layout.dataOffset != 16 or
        layout.align != 8 or
        (not layout.optional and layout.bytes != 24) or
        (layout.optional and
          (layout.bytes != 32 or layout.okOffset != 24))):
      invalid("dynamic layout")
    if layout.owned and layout.kind notin
        {StringType, SeqType, ArrayType, ObjectType, UnionType}:
      invalid("ownership layout")
    if layout.kind in {ArrayType, SeqType, QueueType}:
      if layout.elem < 0 or layout.elem >= plan.layouts.len:
        invalid("element layout")
      if not layout.dynamic and
          (layout.dataOffset < 0 or layout.dataOffset > layout.bytes or
          layout.capacity > (layout.bytes - layout.dataOffset) div
            max(1'i64, plan.layouts[layout.elem].bytes)):
        invalid("element storage")
    if layout.kind in {SetType, DenseMapType, SparseMapType}:
      if layout.elem < 0 or layout.elem >= plan.layouts.len or
          layout.lower > layout.upper:
        invalid("key layout")
    if layout.kind in {DenseMapType, SparseMapType}:
      if layout.val < 0 or layout.val >= plan.layouts.len or
          layout.valOffset < 0 or layout.valOffset > layout.bytes:
        invalid("map value layout")
      let count = if layout.kind == DenseMapType:
          uint64(layout.upper) - uint64(layout.lower) + 1
        else: uint64(layout.capacity)
      let width = max(1'i64, plan.layouts[layout.val].bytes)
      if count == 0 or count > uint64((layout.bytes - layout.valOffset) div width):
        invalid("map value storage")
    if layout.kind == SparseMapType:
      if layout.key != layout.elem or layout.keyOffset < 0 or
          layout.keyOffset > layout.valOffset or
          layout.capacity > (layout.valOffset - layout.keyOffset) div
            max(1'i64, plan.layouts[layout.key].bytes):
        invalid("map key storage")
    var owned = layout.dynamic
    if layout.kind in {ArrayType, SeqType, QueueType, SetType,
        DenseMapType, SparseMapType}:
      owned = owned or plan.layouts[layout.elem].owned
    if layout.kind in {DenseMapType, SparseMapType}:
      owned = owned or plan.layouts[layout.val].owned
    if layout.kind == UnionType:
      if layout.members.len < 2 or layout.dataOffset < 8 or
          layout.dataOffset > layout.bytes:
        invalid("union layout")
      for member in layout.members:
        if member < 0 or member >= plan.layouts.len or
            plan.layouts[member].typeId <= 0 or
            plan.layouts[member].bytes > layout.bytes - layout.dataOffset:
          invalid("union member")
        owned = owned or plan.layouts[member].owned
    for field in layout.fields:
      if field.typ < 0 or field.typ >= plan.layouts.len or
          field.offset < 0 or field.offset > layout.bytes or
          plan.layouts[field.typ].bytes > layout.bytes - field.offset:
        invalid("field layout")
      owned = owned or plan.layouts[field.typ].owned
    if layout.owned != owned:
      invalid("inconsistent ownership layout")
  for i, owned in plan.ownedGlobals:
    if owned.layout < 0 or owned.layout >= plan.layouts.len:
      invalid("owned global layout")
    let layout = plan.layouts[owned.layout]
    if not layout.owned or owned.offset < 0 or
        owned.offset > plan.globalBytes or
        layout.bytes > plan.globalBytes - owned.offset or
        owned.offset mod int(layout.align) != 0:
      invalid("owned global range")
    for j in 0 ..< i:
      if plan.ownedGlobals[j].offset == owned.offset:
        invalid("duplicate owned global")
  for host in plan.hosts:
    if host.kind == ReservedHost:
      invalid("legacy host service")
    if host.paramTypes.len != host.paramOffsets.len or
        (host.paramVars.len != 0 and
        host.paramVars.len != host.paramTypes.len):
      invalid("host parameters")
    if host.kind == ContainerHost and
        (host.receiverType < 0 or host.receiverType >= plan.layouts.len or
        host.resultType < -1 or host.resultType >= plan.layouts.len):
      invalid("container layout")
    for i, typ in host.paramTypes:
      if typ < 0 or typ >= plan.layouts.len or
          host.paramOffsets[i] < 0 or
          host.paramOffsets[i] > WasmStorageLimit:
        invalid("host parameter layout")

proc wasmMetadataSize*(data: openArray[byte]): int =
  ## Reads a bounded size from a complete portable metadata header.
  if data.len < WasmMetadataHeader:
    invalid("truncated header")
  for i, value in WasmMetadataMagic:
    if data[i] != byte(value):
      invalid("magic or version")
  var size: uint64
  for i in 0 ..< 8:
    size = size or (uint64(data[8 + i]) shl (8 * i))
  if size > uint64(WasmMetadataCapacity - WasmMetadataHeader):
    invalid("payload exceeds reserved region")
  WasmMetadataHeader + int(size)

proc serializeWasmMetadata*(plan: NativePlan): string =
  ## Serializes explicit portable descriptors without embedding compiler IR.
  validateWasmMetadata(plan)
  let metadata = WasmMetadata(globalBytes: plan.globalBytes,
    initialData: plan.initialData, threads: plan.threads, hosts: plan.hosts,
    layouts: plan.layouts, lockOffsets: plan.lockOffsets,
    channelOffsets: plan.channelOffsets, ownedGlobals: plan.ownedGlobals)
  let payload = $metadata.toJson()
  if payload.len > WasmMetadataCapacity - WasmMetadataHeader:
    invalid("payload exceeds reserved region")
  result = WasmMetadataMagic
  for shift in countup(0, 56, 8):
    result.add(char((uint64(payload.len) shr shift) and 255))
  result.add(payload)

proc deserializeWasmMetadata*(data: string): NativePlan =
  ## Decodes and validates explicit runtime fields on any 64-bit target.
  if data.len < WasmMetadataHeader:
    invalid("truncated header")
  let bytes = cast[ptr UncheckedArray[byte]](unsafeAddr data[0])
  if wasmMetadataSize(bytes.toOpenArray(0, WasmMetadataHeader - 1)) !=
      data.len:
    invalid("payload length")
  var metadata: WasmMetadata
  try:
    fromJson(metadata, parseJson(data[WasmMetadataHeader ..< data.len]))
  except CatchableError as failure:
    invalid("JSON descriptors: " & failure.msg)
  result = NativePlan(globalBytes: metadata.globalBytes,
    initialData: metadata.initialData, threads: metadata.threads,
    hosts: metadata.hosts, layouts: metadata.layouts,
    lockOffsets: metadata.lockOffsets,
    channelOffsets: metadata.channelOffsets,
    ownedGlobals: metadata.ownedGlobals)
  validateWasmMetadata(result)

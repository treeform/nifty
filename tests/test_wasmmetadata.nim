## Verifies portable metadata validation without allocating program storage.
import ../src/nifty/[common, nativeplans, types, wasmmetadata]

proc rejects(plan: NativePlan) =
  ## Requires malformed descriptors to fail before serialization or allocation.
  var failed = false
  try:
    discard serializeWasmMetadata(plan)
  except NiftyError:
    failed = true
  doAssert failed, "Malformed runtime descriptors were accepted"

proc rejectsBytes(data: string) =
  ## Requires corrupt portable bytes to fail during decoding.
  var failed = false
  try:
    discard deserializeWasmMetadata(data)
  except NiftyError:
    failed = true
  doAssert failed, "Malformed runtime bytes were accepted"

let base = NativePlan(threads: @[ThreadPlan(count: 1, arenaBytes: 16)])
let encoded = serializeWasmMetadata(base)
doAssert serializeWasmMetadata(deserializeWasmMetadata(encoded)) == encoded
rejectsBytes("")
rejectsBytes("NIFTYWM2" & encoded[8 .. ^1])
rejectsBytes(encoded[0 .. ^2])
rejectsBytes(encoded & "x")
rejectsBytes("NIFTYWM1" & "\xff\xff\xff\xff\xff\xff\xff\xff")

var invalid = base
invalid.threads = @[ThreadPlan(count: 2)]
rejects(invalid)
invalid = base
invalid.globalBytes = WasmStorageLimit
rejects(invalid)
invalid = base
invalid.channelOffsets = @[0]
rejects(invalid)

let opaque = NativeLayout(kind: OpaqueType, bytes: 8, align: 8)
var handles = base
handles.layouts = @[opaque]
discard serializeWasmMetadata(handles)
handles.layouts[0].bytes = 4
rejects(handles)
handles.layouts[0] = opaque
handles.layouts[0].align = 4
rejects(handles)
handles.layouts[0] = NativeLayout(kind: OpaqueType, bytes: 16,
  align: 8, optional: true, okOffset: 8)
discard serializeWasmMetadata(handles)
handles.layouts[0].okOffset = 4
rejects(handles)

let dynamic = NativeLayout(kind: StringType, bytes: 24, align: 8,
  dynamic: true, owned: true, dataOffset: 16)
var owners = base
owners.globalBytes = 32
owners.layouts = @[dynamic]
owners.ownedGlobals = @[OwnedGlobal(offset: 0, layout: 0)]
discard serializeWasmMetadata(owners)
owners.ownedGlobals[0].offset = 1
rejects(owners)
owners.ownedGlobals[0].offset = 0
owners.layouts[0].owned = false
rejects(owners)

var nested = base
nested.layouts = @[
  dynamic,
  NativeLayout(kind: ArrayType, bytes: 48, align: 8,
    capacity: 2, elem: 0, owned: true),
  NativeLayout(kind: ObjectType, bytes: 48, align: 8,
    fields: @[NativeField(name: "rows", typ: 1)], owned: true)]
discard serializeWasmMetadata(nested)
nested.layouts[1].owned = false
rejects(nested)
nested.layouts[1].owned = true
nested.layouts[2].owned = false
rejects(nested)
nested.layouts[2].owned = true
nested.layouts[2].fields[0].offset = 8
rejects(nested)

var unions = base
unions.layouts = @[
  NativeLayout(kind: UnionType, bytes: 32, align: 8,
    dataOffset: 8, typeId: 1, members: @[1, 2], owned: true),
  NativeLayout(kind: IntType, bytes: 8, align: 8, typeId: 2),
  NativeLayout(kind: SeqType, bytes: 24, align: 8,
    dynamic: true, owned: true, dataOffset: 16, elem: 0, typeId: 3)]
unions.globalBytes = 32
unions.ownedGlobals = @[OwnedGlobal(offset: 0, layout: 0)]
let unionBytes = serializeWasmMetadata(unions)
let decodedUnion = deserializeWasmMetadata(unionBytes)
doAssert serializeWasmMetadata(decodedUnion) == unionBytes
doAssert decodedUnion.layouts[0].members == @[1, 2]
doAssert decodedUnion.layouts[0].typeId == 1
doAssert decodedUnion.layouts[0].dataOffset == 8
doAssert decodedUnion.layouts[2].elem == 0
unions.layouts[0].owned = false
rejects(unions)
unions.layouts[0].owned = true
unions.layouts[0].members = @[1]
rejects(unions)
unions.layouts[0].members = @[1, 3]
rejects(unions)
unions.layouts[0].members = @[1, 2]
unions.layouts[2].typeId = 0
rejects(unions)
unions.layouts[2].typeId = 3
unions.layouts[0].dataOffset = 16
rejects(unions)
unions.layouts[0].dataOffset = 0
rejects(unions)

echo "WASM metadata validation passed"

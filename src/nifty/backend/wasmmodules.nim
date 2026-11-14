import common, wasmbinaries

type
  WasmType* = object
    parameters*: seq[int]
    returns*: seq[int]
    bytes*: string

  WasmExport* = object
    name*: string
    kind*: int
    index*: int

  WasmModule* = object
    sections*: array[14, string]
    types*: seq[WasmType]
    functions*: seq[int]
    bodies*: seq[string]
    exports*: seq[WasmExport]
    globals*: seq[int64]
    importedFunctions*: int
    importedTypes*: seq[int]
    globalTypes*: seq[int]
    memoryPages*: int
    maximumMemoryPages*: int
    tableMaximum*: int
    tableSize*: int
    tableFlags*: int
    entry*: int
    metadata*: int
    stack*: int
    scriptType*: int

  WasmReader* = object
    bytes*: string
    position*: int

proc byte*(reader: var WasmReader): int {.raises: [BackendError].} =
  ## Reads one bounded binary byte.
  if reader.position >= reader.bytes.len:
    error("Truncated WASM64 binary")
  result = reader.bytes[reader.position].ord
  inc reader.position

proc unsigned*(reader: var WasmReader): int {.raises: [BackendError].} =
  ## Reads a bounded nonnegative binary index or length.
  var shift = 0
  while true:
    let value = reader.byte()
    if shift >= 63 or (shift == 56 and value > 127):
      error("WASM64 integer exceeds limits")
    result = result or ((value and 127) shl shift)
    if value < 128:
      return
    shift += 7

proc signed*(reader: var WasmReader): int64 {.raises: [BackendError].} =
  ## Reads a full-width signed LEB128 constant.
  var shift = 0
  while true:
    let value = reader.byte()
    if shift >= 64 or (shift == 63 and value notin [0, 127]):
      error("WASM64 constant exceeds limits")
    result = result or (value.int64 and 127) shl shift
    shift += 7
    if value < 128:
      if shift < 64 and (value and 64) != 0:
        result = result or (-1'i64 shl shift)
      return

proc span*(reader: var WasmReader, size: int): string
    {.raises: [BackendError].} =
  ## Copies a length-checked binary span.
  if size < 0 or size > reader.bytes.len - reader.position:
    error("WASM64 span exceeds binary")
  result = reader.bytes.substr(reader.position, reader.position + size - 1)
  reader.position += size

proc name*(reader: var WasmReader): string {.raises: [BackendError].} =
  ## Reads a binary string or function body.
  let size = reader.unsigned()
  reader.span(size)

proc count*(reader: var WasmReader): int {.raises: [BackendError].} =
  ## Bounds vector counts by the bytes remaining in their section.
  result = reader.unsigned()
  if result > reader.bytes.len - reader.position:
    error("Invalid WASM64 vector count")

proc symbol*(module: WasmModule, name: string, kind: int): int
    {.raises: [BackendError].} =
  ## Resolves one exported runtime ABI symbol during compilation.
  for item in module.exports:
    if item.name == name and item.kind == kind:
      return item.index
  error("WASM64 runtime is missing " & name)

proc requireSignature*(module: WasmModule, index: int,
    parameters, returns: openArray[int], name: string)
    {.raises: [BackendError].} =
  ## Checks a runtime function against the exact lowered calling convention.
  var typeIndex: int
  if index < 0:
    error("Invalid WASM64 runtime function " & name)
  elif index < module.importedFunctions:
    typeIndex = module.importedTypes[index]
  elif index - module.importedFunctions < module.functions.len:
    typeIndex = module.functions[index - module.importedFunctions]
  else:
    error("Invalid WASM64 runtime function " & name)
  if typeIndex < 0 or typeIndex >= module.types.len:
    error("Invalid WASM64 runtime function type " & name)
  let data = module.types[typeIndex]
  if data.parameters != @parameters or data.returns != @returns:
    error("WASM64 runtime signature differs from IR for " & name)

proc finished(reader: WasmReader) {.raises: [BackendError].} =
  ## Rejects unparsed trailing bytes in a structured runtime section.
  if reader.position != reader.bytes.len:
    error("Trailing bytes in WASM64 runtime section")

proc parseModule*(bytes: string): WasmModule {.raises: [BackendError].} =
  ## Reads the controlled precompiled memory64 runtime without relocation.
  if bytes.len < 8 or bytes.substr(0, 7) != "\0asm\x01\0\0\0":
    error("Invalid WASM64 runtime header")
  var
    reader = WasmReader(bytes: bytes, position: 8)
    seen: array[14, bool]
  while reader.position < bytes.len:
    let id = reader.byte()
    let payload = reader.name()
    if id == 0:
      continue
    if id >= result.sections.len or seen[id]:
      error("Invalid WASM64 section table")
    seen[id] = true
    result.sections[id] = payload
  reader = WasmReader(bytes: result.sections[1])
  let types = reader.count()
  for i in 0 ..< types:
    let start = reader.position
    if reader.byte() != 0x60:
      error("Unsupported WASM64 runtime type")
    var data: WasmType
    let parameters = reader.count()
    for j in 0 ..< parameters:
      data.parameters.add(reader.byte())
    let returns = reader.count()
    for j in 0 ..< returns:
      data.returns.add(reader.byte())
    data.bytes = reader.bytes.substr(start, reader.position - 1)
    result.types.add(data)
  reader.finished()
  reader = WasmReader(bytes: result.sections[2])
  if reader.bytes.len > 0:
    let imports = reader.count()
    for i in 0 ..< imports:
      let
        source = reader.name()
        name = reader.name()
      if reader.byte() != 0 or source != "wasi_snapshot_preview1":
          error("Unexpected WASM64 runtime import " & source & "." & name)
      let typeIndex = reader.unsigned()
      if typeIndex >= result.types.len:
        error("Invalid WASM64 import function type")
      result.importedTypes.add(typeIndex)
      inc result.importedFunctions
  reader.finished()
  reader = WasmReader(bytes: result.sections[3])
  let functions = reader.count()
  for i in 0 ..< functions:
    let typeIndex = reader.unsigned()
    if typeIndex >= result.types.len:
      error("Invalid WASM64 function type")
    result.functions.add(typeIndex)
  reader.finished()
  reader = WasmReader(bytes: result.sections[10])
  let bodies = reader.count()
  if bodies != functions:
    error("WASM64 runtime function count differs from its code count")
  for i in 0 ..< bodies:
    result.bodies.add(reader.name())
  reader.finished()
  reader = WasmReader(bytes: result.sections[4])
  if reader.unsigned() != 1 or reader.byte() != 0x70:
    error("WASM64 runtime requires one function table")
  result.tableFlags = reader.unsigned()
  if result.tableFlags != 5:
    error("WASM64 runtime requires a bounded table64")
  result.tableSize = reader.unsigned()
  result.tableMaximum = reader.unsigned()
  if result.tableSize > result.tableMaximum:
    error("WASM64 table minimum exceeds maximum")
  reader.finished()
  reader = WasmReader(bytes: result.sections[5])
  if reader.unsigned() != 1 or reader.unsigned() != 5:
    error("WASM64 runtime requires one bounded memory64")
  result.memoryPages = reader.unsigned()
  result.maximumMemoryPages = reader.unsigned()
  if result.memoryPages > result.maximumMemoryPages or
      result.maximumMemoryPages > (1 shl 48):
      error("Invalid WASM64 memory64 bounds")
  reader.finished()
  reader = WasmReader(bytes: result.sections[6])
  let globals = reader.count()
  for i in 0 ..< globals:
    let kind = reader.byte()
    let mutable = reader.byte()
    if mutable notin [0, 1]:
      error("Invalid WASM64 global mutability")
    result.globalTypes.add(kind)
    let opcode = reader.byte()
    if (kind != I32 or opcode != 0x41) and
        (kind != I64 or opcode != 0x42):
      error("Unsupported WASM64 runtime global initializer")
    result.globals.add(reader.signed())
    if reader.byte() != 0x0b:
      error("Invalid WASM64 global initializer")
  reader.finished()
  reader = WasmReader(bytes: result.sections[7])
  let exports = reader.count()
  for i in 0 ..< exports:
    result.exports.add(WasmExport(name: reader.name(), kind: reader.byte(),
      index: reader.unsigned()))
  reader.finished()
  result.entry = result.symbol("nifty_entry", 0)
  let
    metadata = result.symbol("nifty_metadata", 3)
    stack = result.symbol("nifty_stack", 3)
  if result.entry < result.importedFunctions or
      result.entry - result.importedFunctions >= result.functions.len or
      metadata >= result.globals.len or stack >= result.globals.len:
      error("Invalid WASM64 runtime ABI exports")
  result.metadata = result.globals[metadata].int
  result.stack = result.globals[stack].int
  if result.globalTypes[metadata] != I64 or result.globalTypes[stack] != I64:
    error("WASM64 runtime storage addresses must be i64 globals")
  if result.metadata < 1024 or result.stack < 1024 or
      result.metadata.int64 + 1024 * 1024 > result.memoryPages.int64 * 65536 or
      result.stack.int64 + 4 * 1024 * 1024 + 64 >
        result.memoryPages.int64 * 65536 or
      (result.metadata < result.stack + 4 * 1024 * 1024 + 64 and
        result.stack < result.metadata + 1024 * 1024):
      error("Invalid WASM64 runtime storage regions")
  result.requireSignature(result.entry, [I64, I64], [], "nifty_entry")
  result.requireSignature(result.symbol("nifty_dispatch", 0),
    [I64, I64, I64, I64, I64], [], "nifty_dispatch")
  result.requireSignature(result.symbol("nifty_stack_failure", 0),
    [], [], "nifty_stack_failure")
  result.scriptType = result.types.len
  result.types.add(WasmType(parameters: @[I64, I64, I64, I64, I64],
    bytes: signature([I64, I64, I64, I64, I64])))

proc vector(values: seq[string]): string {.raises: [].} =
  ## Encodes a vector of already encoded section records.
  result.unsigned(values.len)
  for value in values:
    result.add(value)

proc internType*(types: var seq[WasmType], data: WasmType): int {.raises: [].} =
  ## Shares a deterministic type index between emission and module assembly.
  for index, existing in types:
    if existing.bytes == data.bytes:
      return index
  result = types.len
  types.add(data)

proc filledModule*(runtime: WasmModule, bodies: seq[string],
    metadata: string,
    types: seq[WasmType] = @[],
    indirectTypes: seq[WasmType] = @[]): string {.raises: [BackendError].} =
  ## Appends compiled functions and data while preserving runtime indexes.
  if bodies.len < 2 or metadata.len > 1024 * 1024:
    error("WASM64 image exceeds runtime region limits")
  if types.len != 0 and types.len != bodies.len - 1:
    error("WASM64 function types must match the emitted bodies")
  var module = runtime
  var reader = WasmReader(bytes: bodies[0])
  module.bodies[module.entry - module.importedFunctions] = reader.name()
  reader.finished()
  var functions: seq[int]
  for i in 1 ..< bodies.len:
    functions.add(module.functions.len + module.importedFunctions)
    var selected = module.scriptType
    if types.len > 0:
      selected = module.types.internType(types[i - 1])
    module.functions.add(selected)
    reader = WasmReader(bytes: bodies[i])
    module.bodies.add(reader.name())
    reader.finished()
  for data in indirectTypes:
    discard module.types.internType(data)
  var payload = ""
  for data in module.types:
    payload.add(data.bytes)
  module.sections[1] = ""
  module.sections[1].unsigned(module.types.len)
  module.sections[1].add(payload)
  payload = ""
  payload.unsigned(module.functions.len)
  for index in module.functions:
    payload.unsigned(index)
  module.sections[3] = payload
  payload = "\x01\x70"
  payload.unsigned(module.tableFlags)
  payload.unsigned(module.tableSize + functions.len)
  payload.unsigned(module.tableSize + functions.len)
  module.sections[4] = payload
  payload = ""
  for item in module.bodies:
    payload.name(item)
  module.sections[10] = ""
  module.sections[10].unsigned(module.bodies.len)
  module.sections[10].add(payload)
  reader = WasmReader(bytes: module.sections[9])
  let elements = reader.unsigned()
  payload = ""
  payload.unsigned(elements + 1)
  payload.add(reader.bytes.substr(reader.position))
  payload.op(0)
  payload.constant(module.tableSize)
  payload.op(0x0b)
  payload.unsigned(functions.len)
  for index in functions:
    payload.unsigned(index)
  module.sections[9] = payload
  reader = WasmReader(bytes: module.sections[11])
  let segments = reader.unsigned()
  payload = ""
  payload.unsigned(segments + 1)
  payload.add(reader.bytes.substr(reader.position))
  payload.op(0)
  payload.constant(module.metadata)
  payload.op(0x0b)
  payload.name(metadata)
  module.sections[11] = payload
  if module.sections[12].len > 0:
    module.sections[12] = ""
    module.sections[12].unsigned(segments + 1)
  payload = ""
  var exports: seq[string]
  for item in module.exports:
    if item.name in ["memory", "_start"]:
      var value = ""
      value.name(item.name)
      value.op(item.kind)
      value.unsigned(item.index)
      exports.add(value)
  module.sections[7] = vector(exports)
  result = "\0asm\x01\0\0\0"
  for id in [1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 10, 11, 13]:
    if module.sections[id].len > 0:
      result.section(id, module.sections[id])

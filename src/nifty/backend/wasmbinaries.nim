
const
  I32* = 0x7f
  I64* = 0x7e
  F32* = 0x7d
  F64* = 0x7c
  V128* = 0x7b
  Empty* = 0x40

proc op*(code: var string, value: int) {.raises: [].} =
  ## Appends one WebAssembly opcode or value type.
  code.add(char(value))

proc unsigned*(code: var string, value: int) {.raises: [].} =
  ## Encodes a nonnegative section length or index as unsigned LEB128.
  doAssert value >= 0
  var remaining = value
  while remaining >= 128:
    code.op((remaining and 127) or 128)
    remaining = ashr(remaining, 7)
  code.op(remaining)

proc signed*(code: var string, value: int64) {.raises: [].} =
  ## Encodes a signed constant, including the full int64 range.
  var remaining = value
  while true:
    let value = int(remaining and 127)
    remaining = ashr(remaining, 7)
    if (remaining == 0 and (value and 64) == 0) or
      (remaining == -1 and (value and 64) != 0):
        code.op(value)
        break
    code.op(value or 128)

proc name*(code: var string, value: string) {.raises: [].} =
  ## Writes a length-prefixed byte string.
  code.unsigned(value.len)
  code.add(value)

proc indexed*(code: var string, opcode, index: int) {.raises: [].} =
  ## Emits an instruction with an unsigned local, global, or function index.
  code.op(opcode)
  code.unsigned(index)

proc constant*(code: var string, value: int64, wide = true) {.raises: [].} =
  ## Pushes an integer constant of the selected machine width.
  code.op(if wide: 0x42 else: 0x41)
  code.signed(value)

proc memory*(code: var string, opcode: int, offset = 0) {.raises: [].} =
  ## Emits a memory instruction with conservative byte alignment.
  code.op(opcode)
  code.unsigned(0)
  code.unsigned(offset)

proc floating*(code: var string, value: float64, single = false)
    {.raises: [].} =
  ## Emits the exact IEEE representation of a floating constant.
  code.op(if single: 0x43 else: 0x44)
  let bits =
    if single: cast[uint32](value.float32).uint64
    else: cast[uint64](value)
  for i in 0 ..< (if single: 4 else: 8):
    code.op(int((bits shr (i * 8)) and 255))

proc section*(module: var string, id: int, payload: string) {.raises: [].} =
  ## Appends a complete binary section without an assembler or linker.
  module.op(id)
  module.name(payload)

proc signature*(parameters, returns: openArray[int]): string
    {.raises: [].} =
  ## Encodes a core function type with an explicit ordered result vector.
  result.op(0x60)
  result.unsigned(parameters.len)
  for parameter in parameters:
    result.op(parameter)
  result.unsigned(returns.len)
  for kind in returns:
    result.op(kind)

proc signature*(parameters: openArray[int], returns = Empty): string
    {.raises: [].} =
  ## Preserves the scalar runtime signature boundary.
  if returns == Empty:
    signature(parameters, [])
  else:
    signature(parameters, [returns])

proc body*(code: string, locals: openArray[int]): string {.raises: [].} =
  ## Prefixes typed local declarations and terminates a function body.
  var payload = ""
  payload.unsigned(locals.len)
  for local in locals:
    payload.unsigned(1)
    payload.op(local)
  payload.add(code)
  payload.op(0x0b)
  result.name(payload)

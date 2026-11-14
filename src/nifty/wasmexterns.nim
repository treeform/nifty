## Explicit standalone WASM C ABI whitelist and normalized scalar signatures.
import common, nativeplans, backend/irs

const WasmExternNames* = [
  "write", "fflush", "_Exit", "nifty_stdout_stream", "nifty_stdout_lock",
  "nifty_stdout_unlock", "nifty_format_float", "strlen", "memset", "memcpy",
  "memmove", "memcmp", "strcmp", "strncmp", "abs", "labs", "llabs",
  "clock_gettime", "gettimeofday", "sqrt", "sqrtf", "floor", "floorf",
  "round", "roundf", "ceil", "ceilf", "trunc", "truncf", "fabs", "fabsf",
  "sin", "sinf", "cos", "cosf", "tan", "tanf", "asin", "asinf",
  "acos", "acosf", "atan", "atanf", "exp", "expf", "log", "logf",
  "log10", "log10f", "pow", "powf", "atan2", "atan2f", "fmod", "fmodf",
  "hypot", "hypotf"
]

proc wasmExternSymbol*(host: NativeHost, signature: IrSignature): string =
  ## Rejects unsupported libraries or ABI shapes before emitting a direct call.
  template fail() =
    raise newException(NiftyError, "wasm64 unsupported extern ABI: " &
      host.library & "." & host.symbol)
  if host.kind != ExternHost:
    fail()
  var parameters, returns: seq[IrType]
  if host.library == "nifty":
    case host.symbol
    of "nifty_stdout_stream": returns = @[AddressType]
    of "nifty_stdout_lock", "nifty_stdout_unlock": discard
    of "nifty_format_float":
      parameters = @[Float64Type, AddressType, UInt64Type]
      returns = @[Int32Type]
    else: fail()
  elif host.library == "libc":
    case host.symbol
    of "write":
      parameters = @[Int32Type, AddressType, Int64Type]
      returns = @[Int64Type]
    of "fflush":
      parameters = @[AddressType]
      returns = @[Int32Type]
    of "_Exit": parameters = @[Int32Type]
    of "strlen":
      parameters = @[AddressType]
      returns = @[UInt64Type]
    of "memset":
      parameters = @[AddressType, Int32Type, Int64Type]
      returns = @[Int64Type]
    of "memcpy", "memmove":
      parameters = @[AddressType, AddressType, Int64Type]
      returns = @[Int64Type]
    of "memcmp", "strncmp":
      parameters = @[AddressType, AddressType, Int64Type]
      returns = @[Int32Type]
    of "strcmp":
      parameters = @[AddressType, AddressType]
      returns = @[Int32Type]
    of "abs":
      parameters = @[Int32Type]
      returns = @[Int32Type]
    of "labs", "llabs":
      parameters = @[Int64Type]
      returns = @[Int64Type]
    of "clock_gettime":
      parameters = @[Int32Type, AddressType]
      returns = @[Int32Type]
    of "gettimeofday":
      parameters = @[AddressType, AddressType]
      returns = @[Int32Type]
    else: fail()
  elif host.library == "m":
    if host.symbol notin WasmExternNames:
      fail()
    let single = host.symbol[^1] == 'f'
    let typ = if single: Float32Type else: Float64Type
    parameters = @[typ]
    returns = @[typ]
    if host.symbol in ["pow", "powf", "atan2", "atan2f", "fmod", "fmodf",
        "hypot", "hypotf"]:
      parameters.add(typ)
    elif host.symbol notin ["sqrt", "sqrtf", "floor", "floorf", "round",
        "roundf", "ceil", "ceilf", "trunc", "truncf", "fabs", "fabsf",
        "sin", "sinf", "cos", "cosf", "tan", "tanf", "asin", "asinf",
        "acos", "acosf", "atan", "atanf", "exp", "expf", "log", "logf",
        "log10", "log10f"]:
      fail()
  else:
    fail()
  if host.symbol == "nifty_stdout_stream" and
      signature.returns.len == 1 and
      signature.returns[0] in {Int64Type, UInt64Type, AddressType}:
    returns = signature.returns
  if host.symbol == "fflush" and signature.parameters.len == 1 and
      signature.parameters[0] in {Int64Type, UInt64Type, AddressType}:
    parameters = signature.parameters
  # Pointer-valued libc functions may be declared as their 64-bit bits.
  if host.symbol in ["strlen", "memset", "memcpy", "memmove"] and
      signature.returns.len == 1 and
      signature.returns[0] in {Int64Type, UInt64Type, AddressType}:
    returns = signature.returns
  if host.library == "libc" and host.symbol in
      ["write", "memset", "memcpy", "memmove", "memcmp", "strncmp"] and
      signature.parameters.len == parameters.len and
      signature.parameters[^1] == UInt64Type:
    parameters[^1] = UInt64Type
  # The shared lowerer represents both signed and unsigned 64-bit values
  # with Int64Type. Both carry the same unmodified bits through this ABI.
  if signature.parameters.len == parameters.len:
    for i in 0 ..< parameters.len:
      if parameters[i] in {Int64Type, UInt64Type} and
          signature.parameters[i] in {Int64Type, UInt64Type}:
        parameters[i] = signature.parameters[i]
  if signature.returns.len == returns.len:
    for i in 0 ..< returns.len:
      if returns[i] in {Int64Type, UInt64Type} and
          signature.returns[i] in {Int64Type, UInt64Type}:
        returns[i] = signature.returns[i]
  if signature.parameters != parameters or signature.returns != returns:
    fail()
  result = "nf_ext_" & host.symbol

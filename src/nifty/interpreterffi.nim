## Runtime libffi bridge for nonvariadic C scalar calls.
## ABI constants follow libffi's src/{x86,aarch64}/ffitarget.h.
import std/[dynlib, os]
import backend/irs

type
  InterpreterFfiError* = object of CatchableError
  PrepareProc = proc(cif: pointer, abi, count: cuint,
    returns: pointer, arguments: ptr pointer): cint {.cdecl, gcsafe.}
  CallProc = proc(cif, address, returns: pointer,
    arguments: ptr pointer) {.cdecl, gcsafe.}
  ForeignData = object
    handle: LibHandle
    # Opaque ffi_cif storage, aligned to uint64. Supported libffi 3.x CIFs
    # contain only unsigned integers and pointers and fit in 64 bytes.
    cif: array[16, uint64]
    types: seq[pointer]
  ForeignStorage = ref ForeignData
  ForeignCall* = object
    storage: ForeignStorage
    address: pointer
    invoke: CallProc
    returnKind: IrType
    hasReturn: bool

const DefaultAbi =
  when defined(arm64):
    when defined(windows): 2.cuint
    else: 1.cuint
  elif defined(amd64):
    when defined(windows): 1.cuint
    else: 2.cuint
  else: 0.cuint

proc `=destroy`(data: var ForeignData) =
  ## Releases the library reference after the last prepared call is gone.
  if data.handle != nil:
    unloadLib(data.handle)
  `=destroy`(data.types)

proc library(): LibHandle =
  ## Finds a runtime library without introducing a link dependency.
  let override = getEnv("NIFTY_LIBFFI")
  if override.len > 0:
    return loadLib(override)
  when defined(macosx):
    const Names = ["/usr/lib/libffi.dylib", "libffi.dylib"]
  elif defined(windows):
    const Names = ["libffi-8.dll", "libffi-7.dll", "libffi.dll"]
  else:
    const Names = ["libffi.so.8", "libffi.so.7", "libffi.so"]
  for name in Names:
    result = loadLib(name)
    if result != nil:
      return

proc foreignAvailable*(): bool =
  ## Reports whether the runtime dependency can be loaded.
  let handle = library()
  result = handle != nil and DefaultAbi != 0
  if handle != nil:
    unloadLib(handle)

proc symbol(handle: LibHandle, name: string): pointer =
  ## Resolves a required public libffi symbol.
  result = symAddr(handle, name)
  if result == nil:
    raise newException(InterpreterFfiError,
      "libffi is missing required symbol " & name)

proc foreignType(handle: LibHandle, kind: IrType): pointer =
  ## Maps IR scalars to libffi's exported type descriptors.
  let name = case kind
    of BoolType, CharType, UInt8Type: "uint8"
    of Int8Type: "sint8"
    of UInt16Type: "uint16"
    of Int16Type: "sint16"
    of UInt32Type: "uint32"
    of Int32Type: "sint32"
    of UInt64Type: "uint64"
    of Int64Type: "sint64"
    of Float32Type: "float"
    of Float64Type: "double"
    of AddressType: "pointer"
    of Float32x2Type:
      raise newException(InterpreterFfiError,
        "C extern calls do not support vector or aggregate values")
  result = symbol(handle, "ffi_type_" & name)

proc prepareForeign*(signature: IrSignature,
    address: pointer): ForeignCall =
  ## Prepares immutable call metadata before interpreter threads start.
  if DefaultAbi == 0:
    raise newException(InterpreterFfiError,
      "Interpreter C extern calls require an amd64 or arm64 host")
  if signature.returns.len > 1:
    raise newException(InterpreterFfiError,
      "C extern calls support at most one scalar return")
  if address == nil:
    raise newException(InterpreterFfiError, "C extern address is nil")
  let handle = library()
  if handle == nil:
    raise newException(InterpreterFfiError,
      "Interpreter C extern calls require libffi 3.x. Install libffi " &
      "(Windows: place libffi-8.dll on PATH), or set NIFTY_LIBFFI " &
      "to the runtime library path. No headers are required.")
  # Retain the runtime library until the last copy of this call is gone.
  result.storage = ForeignStorage(handle: handle)
  result.address = address
  result.invoke = cast[CallProc](symbol(handle, "ffi_call"))
  for kind in signature.parameters:
    result.storage.types.add foreignType(handle, kind)
  result.hasReturn = signature.returns.len != 0
  let returnType =
    if result.hasReturn:
      result.returnKind = signature.returns[0]
      foreignType(handle, result.returnKind)
    else:
      symbol(handle, "ffi_type_void")
  let arguments =
    if result.storage.types.len == 0: nil
    else: addr result.storage.types[0]
  let prepare = cast[PrepareProc](symbol(handle, "ffi_prep_cif"))
  if prepare(addr result.storage.cif[0], DefaultAbi,
      cuint(signature.parameters.len), returnType, arguments) != 0:
    raise newException(InterpreterFfiError,
      "libffi rejected the C extern signature or host ABI")

proc callForeign*(call: ptr ForeignCall, arguments: openArray[uint64],
    returns: var openArray[uint64]) {.gcsafe.} =
  ## Invokes a prepared call using private argument and result storage.
  if arguments.len != call.storage.types.len or
      returns.len != ord(call.hasReturn):
    raise newException(InterpreterFfiError,
      "C extern argument or return count does not match signature")
  const StackArguments = 16
  var output: uint64
  if arguments.len <= StackArguments:
    var
      values: array[StackArguments, uint64]
      pointers: array[StackArguments, pointer]
    for i, bits in arguments:
      values[i] = bits
      pointers[i] = addr values[i]
    let addresses = if arguments.len == 0: nil else: addr pointers[0]
    call.invoke(addr call.storage.cif[0], call.address, addr output, addresses)
  else:
    var
      values = newSeq[uint64](arguments.len)
      pointers = newSeq[pointer](arguments.len)
    for i, bits in arguments:
      values[i] = bits
      pointers[i] = addr values[i]
    call.invoke(addr call.storage.cif[0], call.address, addr output,
      addr pointers[0])
  if call.hasReturn:
    returns[0] = case call.returnKind
      of Int8Type: cast[uint64](int64(cast[int8](uint8(output))))
      of Int16Type: cast[uint64](int64(cast[int16](uint16(output))))
      of Int32Type: cast[uint64](int64(cast[int32](uint32(output))))
      of BoolType, CharType, UInt8Type: output and 0xff
      of UInt16Type: output and 0xffff
      of UInt32Type, Float32Type: output and 0xffffffff'u64
      else: output

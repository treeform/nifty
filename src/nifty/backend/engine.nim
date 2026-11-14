## Emits verified Nifty IR to relocatable native machine code.
## Routines accept (context, arguments, returned, reserved) pointers.
## Hosts use scalar C signatures, including native stack arguments.
## Aggregate and variadic C signatures are outside this backend contract.
import common, irs, irmachines, iramds, memories
export irs

type
  NativeTarget* = enum
    Arm64Target, Amd64Target

  NativeImage* = object
    bytes*: seq[byte]
    offsets*: seq[int]
    frameBytes*: seq[int]
    ## Includes locals, outgoing arguments, saved registers, and AMD64 return IP.
    wrapperFrameBytes*: int
    target*: NativeTarget

proc emitNative*(module: IrModule, target: NativeTarget): NativeImage
    {.raises: [BackendError].} =
  ## Emits actual IR routine entries separately from the leading wrapper.
  if module.pointerBytes != 8:
    error("Native code requires 64-bit pointers")
  for function in module.functions:
    if function.signature.parameters !=
        @[AddressType, AddressType, AddressType, AddressType] or
        function.signature.returns.len != 0:
      error("Native routines require four address arguments and no return")
  for host in module.hosts:
    if host.binding < 0:
      error("Native host binding must be nonnegative")
  result.target = target
  case target
  of Arm64Target:
    let image = emitArm64Ir(module, MaxNativeBytes)
    result.offsets = image.offsets
    result.frameBytes = image.frameBytes
    result.wrapperFrameBytes = image.wrapperFrameBytes
    for word in image.words:
      for shift in [0, 8, 16, 24]:
        result.bytes.add(byte((word shr shift) and 255))
  of Amd64Target:
    let image = emitAmd64Ir(module, MaxNativeBytes)
    result.bytes = image.bytes
    result.offsets = image.offsets
    result.frameBytes = image.frameBytes
    result.wrapperFrameBytes = image.wrapperFrameBytes

## Emits verified Nifty IR to relocatable native machine code.
import common, irs, irmachines, iramds, memories
export irs

type
  NativeTarget* = enum
    Arm64Target, Amd64Target

  NativeImage* = object
    bytes*: seq[byte]
    offsets*: seq[int]
    target*: NativeTarget

proc emitNative*(module: IrModule, target: NativeTarget): NativeImage
    {.raises: [BackendError].} =
  ## Emits actual IR routine entries separately from the leading wrapper.
  result.target = target
  case target
  of Arm64Target:
    let image = emitArm64Ir(module, MaxNativeBytes)
    result.offsets = image.offsets
    for word in image.words:
      for shift in [0, 8, 16, 24]:
        result.bytes.add(byte((word shr shift) and 255))
  of Amd64Target:
    let image = emitAmd64Ir(module, MaxNativeBytes)
    result.bytes = image.bytes
    result.offsets = image.offsets

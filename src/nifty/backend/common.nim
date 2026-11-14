## Common errors and limits for the native backend.
import ../common

type BackendError* = NiftyError

const MaxFrameBytes* = 1_048_576

proc error*(message: string) {.noreturn, raises: [BackendError].} =
  ## Raises a compiler error at the native backend boundary.
  raise newException(BackendError, message)

proc aligned*(size, alignment: int): int {.raises: [].} =
  ## Rounds a byte count to a power-of-two alignment.
  (size + alignment - 1) and not (alignment - 1)

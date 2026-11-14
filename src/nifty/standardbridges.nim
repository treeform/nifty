## Small C ABI adapters for standard-library synchronization and formatting.
## These functions never write program output; Nifty libraries use normal FFI.
const consoleBridgeC* = """
void nifty_stdout_lock(void) { flockfile(stdout); }
void nifty_stdout_unlock(void) { funlockfile(stdout); }
int32_t nifty_format_float(double value, uint8_t *buffer, uint64_t count) {
  return (int32_t)snprintf((char *)buffer, (size_t)count, "%g", value);
}
"""

var bridgeStdout {.importc: "stdout", header: "<stdio.h>".}: File
when defined(windows):
  proc lockStream(file: File) {.importc: "_lock_file", header: "<stdio.h>".}
  proc unlockStream(file: File) {.importc: "_unlock_file", header: "<stdio.h>".}
else:
  proc lockStream(file: File) {.importc: "flockfile", header: "<stdio.h>".}
  proc unlockStream(file: File) {.importc: "funlockfile", header: "<stdio.h>".}
proc snprintf(buffer: pointer, count: csize_t, format: cstring): cint
  {.importc, varargs, header: "<stdio.h>".}

proc stdoutLock() {.cdecl.} = lockStream(bridgeStdout)
proc stdoutUnlock() {.cdecl.} = unlockStream(bridgeStdout)
proc formatFloat(value: float64, buffer: pointer, count: uint64): int32 {.cdecl.} =
  int32(snprintf(buffer, csize_t(count), "%g", value))

proc standardSymbol*(name: string): pointer =
  ## Resolves the same adapter ABI used by reference C executables.
  case name
  of "nifty_stdout_lock": cast[pointer](stdoutLock)
  of "nifty_stdout_unlock": cast[pointer](stdoutUnlock)
  of "nifty_format_float": cast[pointer](formatFloat)
  else: nil

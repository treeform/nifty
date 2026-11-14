## Invalid foreign conversion metadata fails before unchecked runtime access.
import std/strutils
import ../src/nifty
import ../src/nifty/[lowering, nativefiles]

const Source = """
extern "libc":
  proc textLength "strlen"(text: cstring): int64
thread main() =
  let text: string[8] = "checked"
  let converted = text.toCString()
  if converted.ok:
    discard textLength(converted)
"""

let checked = checkedModule(Source, "ffi_validation.nifty")
for target in NativeTarget:
  let program = buildNativeProgram(lowerNative(checked, "ffi_validation"), target)
  let encoded = program.encodeNative()
  var hostIndex = -1
  for i, host in program.plan.hosts:
    if host.operation == "toCString":
      hostIndex = i
  doAssert hostIndex >= 0
  for field in ["receiver", "result"]:
    for invalidIndex in [-2, -1, program.plan.layouts.len]:
      var broken = decodeNative(encoded)
      if field == "receiver":
        broken.plan.hosts[hostIndex].receiverType = invalidIndex
      else:
        broken.plan.hosts[hostIndex].resultType = invalidIndex
      var rejected = false
      try:
        discard broken.encodeNative()
      except NiftyError:
        rejected = true
      doAssert rejected, field & " index " & $invalidIndex & " was accepted"
  var broken = decodeNative(encoded)
  broken.plan.hosts[hostIndex].resultType = broken.plan.hosts[hostIndex].receiverType
  var rejected = false
  try:
    validateNative(broken)
  except NiftyError:
    rejected = true
  doAssert rejected, "a nonoptional cstring owner result was accepted"

var rejected = false
try:
  discard checkedModule("type cstring = opaque\nthread main() =\n  discard 0\n",
    "reserved_ffi.nifty")
except NiftyError as failure:
  rejected = "reserved type name" in failure.msg
doAssert rejected
echo "FFI conversion metadata and reserved types passed"

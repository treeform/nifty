import std/[dynlib, os, osproc, strutils]
import nifty/[interpreterffi]
import nifty/backend/irs

let directory = getTempDir() /
  ("nifty_interpreter_ffi_fixture_" & $getCurrentProcessId())
createDir(directory)
let source = directory / "fixture.c"
let libraryPath = directory /
  (when defined(windows): "fixture.dll"
   elif defined(macosx): "fixture.dylib"
   else: "fixture.so")
writeFile(source, """
#include <stdint.h>
#ifdef _WIN32
#define API __declspec(dllexport)
#else
#define API
#endif
API double mixed(int8_t a, double b, uint16_t c, float d,
 int64_t e, double f, uint64_t g, float h, int32_t i, double j,
 uint32_t k, float l, int16_t m, double n, uint8_t o, float p,
 double q, double r, double s, double t, double u) {
 return a+b+c+d+e+f+g+h+i+j+k+l+m+n+o+p+q+r+s+t+u;
}
API int8_t signed8(int8_t x) { return x; }
API int16_t signed16(int16_t x) { return x; }
API int32_t signed32(int32_t x) { return x; }
API uint64_t unsigned64(uint64_t x) { return x; }
API float single(float x) { return x; }
API void* pointer(void* x) { return x; }
API void store(uint64_t* x, uint64_t value) { *x = value; }
""")
var compiler = getEnv("CC")
if compiler.len == 0:
  for name in ["cc", "gcc", "clang"]:
    compiler = findExe(name)
    if compiler.len > 0:
      break
doAssert compiler.len > 0, "FFI fixture requires cc, gcc, or clang; set CC"
let architecture =
  when defined(macosx) and defined(amd64): "-arch x86_64 "
  elif defined(macosx) and defined(arm64): "-arch arm64 "
  else: ""
let command = quoteShell(compiler) & " -shared " & architecture &
  (when defined(windows): "" else: "-fPIC ") &
  quoteShell(source) & " -o " & quoteShell(libraryPath)
let compiled = execCmdEx(command)
doAssert compiled.exitCode == 0, compiled.output
let handle = loadLib(libraryPath)
doAssert handle != nil
proc invoke(name: string, kinds: seq[IrType], outputs: seq[IrType],
    values: seq[uint64]): seq[uint64] =
  ## Calls a fixture symbol through the interpreter's generic bridge.
  var call = prepareForeign(IrSignature(parameters: kinds, returns: outputs),
    symAddr(handle, name))
  result = newSeq[uint64](outputs.len)
  callForeign(addr call, values, result)

let originalOverride = getEnv("NIFTY_LIBFFI")
let hadOverride = existsEnv("NIFTY_LIBFFI")
putEnv("NIFTY_LIBFFI", directory / "missing-libffi-library")
doAssert not foreignAvailable()
var missingRaised = false
try:
  discard prepareForeign(IrSignature(), symAddr(handle, "mixed"))
except InterpreterFfiError as error:
  missingRaised = "NIFTY_LIBFFI" in error.msg and "libffi" in error.msg
doAssert missingRaised
if hadOverride:
  putEnv("NIFTY_LIBFFI", originalOverride)
else:
  delEnv("NIFTY_LIBFFI")
doAssert foreignAvailable()
let kinds = @[Int8Type, Float64Type, UInt16Type, Float32Type,
  Int64Type, Float64Type, UInt64Type, Float32Type, Int32Type,
  Float64Type, UInt32Type, Float32Type, Int16Type, Float64Type,
  UInt8Type, Float32Type, Float64Type, Float64Type, Float64Type,
  Float64Type, Float64Type]
var values: seq[uint64]
var expected = 0.0
for i, kind in kinds:
  let value = float64(i + 1)
  expected += value
  values.add case kind
    of Float64Type: cast[uint64](value)
    of Float32Type: uint64(cast[uint32](float32(value)))
    else: uint64(i + 1)
let mixed = invoke("mixed", kinds, @[Float64Type], values)
doAssert cast[float64](mixed[0]) == expected
for (name, kind) in [("signed8", Int8Type), ("signed16", Int16Type),
    ("signed32", Int32Type)]:
  doAssert invoke(name, @[kind], @[kind], @[uint64.high])[0] == uint64.high
let large = 0xfedcba9876543210'u64
doAssert invoke("unsigned64", @[UInt64Type], @[UInt64Type], @[large])[0] == large
let single = uint64(cast[uint32](-12.375'f))
doAssert invoke("single", @[Float32Type], @[Float32Type], @[single])[0] == single
var cell: uint64
let address = cast[uint64](addr cell)
doAssert invoke("pointer", @[AddressType], @[AddressType], @[address])[0] == address
doAssert invoke("store", @[AddressType, UInt64Type], @[], @[address, large]).len == 0
doAssert cell == large
unloadLib(handle)
removeFile(source)
removeFile(libraryPath)
removeDir(directory)
echo "Interpreter libffi scalar ABI passed."

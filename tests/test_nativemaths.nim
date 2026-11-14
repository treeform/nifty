## Checks guarded libm specialization and exact exceptional fallbacks.
import std/dynlib
import nifty/[nativeplans, nativemaths]
import nifty/[parser, loader, checker, lowering]
import nifty/backend/[irs, irchecks, engine, context, memories]
import nifty/backend/iroptimizations

type
  Math64 = proc(value: cdouble): cdouble {.cdecl, raises: [].}
  Math32 = proc(value: cfloat): cfloat {.cdecl, raises: [].}

# Resolve libm at runtime so C optimizers cannot fold across rounding changes.
let
  mathLibrary = loadLib(when defined(macosx): "libm.dylib" else: "libm.so.6")
  sqrtLib = cast[Math64](symAddr(mathLibrary, "sqrt"))
  sqrtfLib = cast[Math32](symAddr(mathLibrary, "sqrtf"))
  floorLib = cast[Math64](symAddr(mathLibrary, "floor"))
  roundLib = cast[Math64](symAddr(mathLibrary, "round"))
doAssert mathLibrary != nil and sqrtLib != nil and sqrtfLib != nil
proc clearExceptions(exceptions: cint): cint
  {.importc: "feclearexcept", header: "<fenv.h>".}
proc testExceptions(exceptions: cint): cint
  {.importc: "fetestexcept", header: "<fenv.h>".}
proc setRounding(mode: cint): cint
  {.importc: "fesetround", header: "<fenv.h>".}
proc getRounding(): cint {.importc: "fegetround", header: "<fenv.h>".}
var
  allExceptions {.importc: "FE_ALL_EXCEPT", header: "<fenv.h>".}: cint
  nearest {.importc: "FE_TONEAREST", header: "<fenv.h>".}: cint
  downward {.importc: "FE_DOWNWARD", header: "<fenv.h>".}: cint
  upward {.importc: "FE_UPWARD", header: "<fenv.h>".}: cint
  towardZero {.importc: "FE_TOWARDZERO", header: "<fenv.h>".}: cint
when defined(macosx):
  proc errnoLocation(): ptr cint {.importc: "__error", header: "<errno.h>".}
else:
  proc errnoLocation(): ptr cint
    {.importc: "__errno_location", header: "<errno.h>".}

var
  calls = 0
  roundingReference: Math64

proc observedSqrt(value: cdouble): cdouble {.cdecl, raises: [].} =
  ## Counts fallback execution while preserving the platform libm result.
  inc calls
  sqrtLib(value)

proc observedSqrtf(value: cfloat): cfloat {.cdecl, raises: [].} =
  ## Counts binary32 fallbacks while preserving the platform libm result.
  inc calls
  sqrtfLib(value)

proc observedRounding(value: cdouble): cdouble {.cdecl, raises: [].} =
  ## Counts exceptional rounding fallbacks through the selected platform libm.
  inc calls
  roundingReference(value)

proc plan(kind: IrType, library = "m", symbol = "sqrt"): NativePlan =
  ## Constructs a scalar host call within the native four-pointer entry ABI.
  let signature = IrSignature(parameters: @[kind], returns: @[kind])
  result.hosts = @[NativeHost(kind: ExternHost,
    library: library, symbol: symbol)]
  result.module = IrModule(pointerBytes: 8, hosts: @[IrHost(
    name: symbol, signature: signature, failureMode: NoFailCall)])
  var function = IrFunction(name: "root", failureMode: NoFailCall,
    signature: IrSignature(parameters:
      @[AddressType, AddressType, AddressType, AddressType]))
  for i in 0 ..< 4:
    function.values.add(IrValue(valueType: AddressType))
  function.values.add(IrValue(valueType: kind))
  function.values.add(IrValue(valueType: kind))
  function.operands = @[ValueId(1), ValueId(4), ValueId(2), ValueId(5)]
  function.instructions = @[
    IrInstruction(op: LoadOp, results: Span(first: 4, count: 1),
      arguments: Span(first: 0, count: 1), alignment: 1),
    IrInstruction(op: HostCallOp, results: Span(first: 5, count: 1),
      arguments: Span(first: 1, count: 1)),
    IrInstruction(op: StoreOp, arguments: Span(first: 2, count: 2),
      alignment: 1)]
  function.blocks = @[IrBlock(parameters: Span(count: 4),
    instructions: Span(count: 3),
    terminator: IrTerminator(kind: ReturnTerminator))]
  result.module.functions = @[function]

proc invoke(module: IrModule, input, output, host: pointer,
    exceptions: var cint) =
  ## Verifies both targets and executes the generated code on this machine.
  verifyIr(module)
  for target in NativeTarget:
    let image = emitNative(module, target)
    doAssert image.bytes.len > 0
    when defined(arm64) or defined(amd64):
      let nativeTarget = when defined(arm64): Arm64Target else: Amd64Target
      if target == nativeTarget:
        var
          buffer = initCodeBuffer(image.bytes)
          bindings = [host]
          ctx = RuntimeContext(hosts: bindings.addr)
        type Entry = proc(ctx, arguments, returned, reserved: pointer)
          {.cdecl, raises: [].}
        let entry = cast[Entry](cast[uint](buffer.entry()) +
          uint(image.offsets[0]))
        discard clearExceptions(allExceptions)
        entry(ctx.addr, input, output, nil)
        exceptions = testExceptions(allExceptions)
        buffer.release()

for kind in [Float32Type, Float64Type]:
  let symbol = if kind == Float64Type: "sqrt" else: "sqrtf"
  var specialized = plan(kind, symbol = symbol)
  verifyIr(specialized.module)
  doAssert specialized.specializeNativeMaths() == 1
  verifyIr(specialized.module)
  doAssert specialized.module.functions[0].blocks.len == 4
  let patterns = if kind == Float64Type:
    @[0'u64, 0x8000000000000000'u64, 1'u64,
      0x3ff0000000000000'u64, 0x4000000000000000'u64,
      0x7fefffffffffffff'u64, 0x7ff0000000000000'u64,
      0xbff0000000000000'u64, 0xfff0000000000000'u64,
      0x7ff8000000001234'u64, 0xfff8000000001234'u64,
      0x7ff0000000001234'u64]
    else:
      @[0'u64, 0x80000000'u64, 1'u64, 0x3f800000'u64,
        0x40000000'u64, 0x7f7fffff'u64, 0x7f800000'u64,
        0xbf800000'u64, 0xff800000'u64, 0x7fc01234'u64,
        0xffc01234'u64, 0x7f801234'u64]
  for pattern in patterns:
    calls = 0
    var exceptions: cint
    if kind == Float64Type:
      var
        input = cast[float64](pattern)
        output: float64
      errnoLocation()[] = 123
      discard clearExceptions(allExceptions)
      let expected = sqrtLib(input)
      let expectedErrno = errnoLocation()[]
      let expectedExceptions = testExceptions(allExceptions)
      errnoLocation()[] = 123
      specialized.module.invoke(input.addr, output.addr,
        cast[pointer](observedSqrt), exceptions)
      doAssert cast[uint64](output) == cast[uint64](expected)
      doAssert errnoLocation()[] == expectedErrno
      doAssert exceptions == expectedExceptions
      let safe = pattern <= 0x7ff0000000000000'u64 or
        pattern == 0x8000000000000000'u64
      doAssert calls == (if safe: 0 else: 1)
    else:
      let bits = uint32(pattern)
      var
        input = cast[float32](bits)
        output: float32
      errnoLocation()[] = 123
      discard clearExceptions(allExceptions)
      let expected = sqrtfLib(input)
      let expectedErrno = errnoLocation()[]
      let expectedExceptions = testExceptions(allExceptions)
      errnoLocation()[] = 123
      specialized.module.invoke(input.addr, output.addr,
        cast[pointer](observedSqrtf), exceptions)
      doAssert cast[uint32](output) == cast[uint32](expected)
      doAssert errnoLocation()[] == expectedErrno
      doAssert exceptions == expectedExceptions
      let safe = bits <= 0x7f800000'u32 or bits == 0x80000000'u32
      doAssert calls == (if safe: 0 else: 1)

let originalRounding = getRounding()
for mode in [nearest, downward, upward, towardZero]:
  doAssert setRounding(mode) == 0
  var specialized = plan(Float64Type)
  discard specialized.specializeNativeMaths()
  for function in specialized.module.functions:
    for item in function.instructions:
      if item.op == ConvertOp:
        doAssert item.conversion == BitcastConversion
  for value in [2.0, 3.0, 0.1, 1.23456789e300]:
    var
      input = value
      output: float64
      exceptions: cint
    let expected = sqrtLib(input)
    specialized.module.invoke(input.addr, output.addr,
      cast[pointer](observedSqrt), exceptions)
    doAssert cast[uint64](output) == cast[uint64](expected),
      "mode=" & $mode & " input=" & $value & " actual=" &
      $cast[uint64](output) & " expected=" & $cast[uint64](expected)
doAssert setRounding(originalRounding) == 0

let roundingPatterns = [0'u64, 0x8000000000000000'u64,
  1'u64, 0x8000000000000001'u64, 0x000fffffffffffff'u64,
  0x3ff0000000000000'u64, 0xbff0000000000000'u64,
  0x3fe0000000000000'u64, 0xbfe0000000000000'u64,
  0x3fdfffffffffffff'u64, 0x3fe0000000000001'u64,
  0x3fefffffffffffff'u64, 0xbfefffffffffffff'u64,
  0x3ff8000000000000'u64, 0xbff8000000000000'u64,
  0x4004000000000000'u64, 0xc004000000000000'u64,
  0x432fffffffffffff'u64, 0xc32fffffffffffff'u64,
  0x433fffffffffffff'u64, 0x4340000000000000'u64,
  0x7fefffffffffffff'u64, 0xffefffffffffffff'u64,
  0x7ff0000000000000'u64, 0xfff0000000000000'u64,
  0x7ff8000000001234'u64, 0xfff8000000001234'u64,
  0x7ff0000000001234'u64, 0xfff0000000001234'u64]
for symbol in ["floor", "round"]:
  roundingReference = if symbol == "floor": floorLib else: roundLib
  doAssert roundingReference != nil
  var specialized = plan(Float64Type, symbol = symbol)
  let expectedChanges = when defined(macosx): 1 else: 0
  doAssert specialized.specializeNativeMaths() == expectedChanges
  verifyIr(specialized.module)
  optimizeIr(specialized.module)
  verifyIr(specialized.module)
  for mode in [nearest, downward, upward, towardZero]:
    doAssert setRounding(mode) == 0
    for pattern in roundingPatterns:
      var
        input = cast[float64](pattern)
        output: float64
        exceptions: cint
      calls = 0
      errnoLocation()[] = 123
      discard clearExceptions(allExceptions)
      let expected = roundingReference(input)
      let expectedErrno = errnoLocation()[]
      let expectedExceptions = testExceptions(allExceptions)
      errnoLocation()[] = 123
      specialized.module.invoke(input.addr, output.addr,
        cast[pointer](observedRounding), exceptions)
      doAssert cast[uint64](output) == cast[uint64](expected),
        symbol & " mode=" & $mode & " bits=" & $pattern
      doAssert errnoLocation()[] == expectedErrno
      doAssert exceptions == expectedExceptions
      let safe = expectedChanges > 0 and
        (pattern and 0x7fffffffffffffff'u64) <= 0x7ff0000000000000'u64
      doAssert calls == (if safe: 0 else: 1)
doAssert setRounding(originalRounding) == 0

let source = parse(loadTokens("""
extern "m":
  proc sqrt(x: float64): float64
  proc floor(x: float64): float64
  proc round(x: float64): float64
proc roots(x: float64): float64 =
  if x < 0.0:
    return sqrt(x)
  return round(floor(sqrt(sqrt(x))))
thread main() =
  echo roots(4.0)
""", "math-test.nifty", "."))
check(source)
var lowered = lowerNative(source)
doAssert lowered.specializeNativeMaths() ==
  (when defined(macosx): 5 else: 3)
verifyIr(lowered.module)
optimizeIr(lowered.module)
verifyIr(lowered.module)
for target in NativeTarget:
  doAssert emitNative(lowered.module, target).bytes.len > 0

for library in ["libc", "custom"]:
  for symbol in ["sqrt", "floor", "round"]:
    var unknown = plan(Float64Type, library, symbol)
    doAssert unknown.specializeNativeMaths() == 0
for kind in [Float32Type, Float64Type]:
  var mismatched = plan(kind,
    symbol = if kind == Float64Type: "sqrtf" else: "sqrt")
  doAssert mismatched.specializeNativeMaths() == 0
for symbol in ["floor", "round", "floorf", "roundf"]:
  var mismatched = plan(Float32Type, symbol = symbol)
  doAssert mismatched.specializeNativeMaths() == 0
echo "Guarded native libm operations passed"
unloadLib(mathLibrary)

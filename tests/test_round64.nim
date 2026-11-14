## Compare exact AMD64 floor/round bits and floating environment with libm.
import std/[dynlib, strutils]
import nifty/backend/[irs, irchecks, iramds, memories, context]

type Math64 = proc(value: cdouble): cdouble {.cdecl, raises: [].}

proc clearExceptions(exceptions: cint): cint
  {.importc: "feclearexcept", header: "<fenv.h>".}
proc raiseExceptions(exceptions: cint): cint
  {.importc: "feraiseexcept", header: "<fenv.h>".}
proc testExceptions(exceptions: cint): cint
  {.importc: "fetestexcept", header: "<fenv.h>".}
proc setRounding(mode: cint): cint
  {.importc: "fesetround", header: "<fenv.h>".}
proc getRounding(): cint {.importc: "fegetround", header: "<fenv.h>".}
var
  allExceptions {.importc: "FE_ALL_EXCEPT", header: "<fenv.h>".}: cint
  divideByZero {.importc: "FE_DIVBYZERO", header: "<fenv.h>".}: cint
  nearest {.importc: "FE_TONEAREST", header: "<fenv.h>".}: cint
  downward {.importc: "FE_DOWNWARD", header: "<fenv.h>".}: cint
  upward {.importc: "FE_UPWARD", header: "<fenv.h>".}: cint
  towardZero {.importc: "FE_TOWARDZERO", header: "<fenv.h>".}: cint
when defined(macosx):
  proc errnoLocation(): ptr cint {.importc: "__error", header: "<errno.h>".}
elif defined(windows):
  proc errnoLocation(): ptr cint {.importc: "_errno", header: "<errno.h>".}
else:
  proc errnoLocation(): ptr cint
    {.importc: "__errno_location", header: "<errno.h>".}

var module = IrModule(pointerBytes: 8)
for operation in [FloorOp, RoundOp]:
  var function = IrFunction(name: $operation, failureMode: NoFailCall,
    signature: IrSignature(parameters:
      @[AddressType, AddressType, AddressType, AddressType]))
  for i in 0 ..< 4:
    function.values.add(IrValue(valueType: AddressType))
  for i in 0 ..< 2:
    function.values.add(IrValue(valueType: Float64Type))
  function.operands = @[ValueId(1), ValueId(4), ValueId(2), ValueId(5)]
  function.instructions = @[
    IrInstruction(op: LoadOp, results: Span(first: 4, count: 1),
      arguments: Span(first: 0, count: 1), alignment: 1),
    IrInstruction(op: operation, results: Span(first: 5, count: 1),
      arguments: Span(first: 1, count: 1)),
    IrInstruction(op: StoreOp, arguments: Span(first: 2, count: 2),
      alignment: 1)]
  function.blocks = @[IrBlock(parameters: Span(count: 4),
    instructions: Span(count: 3),
    terminator: IrTerminator(kind: ReturnTerminator))]
  module.functions.add(function)
verifyIr(module)
let image = emitAmd64Ir(module, MaxNativeBytes)
echo "AMD64 binary64 floor/round image: ", image.bytes.len, " bytes"

when defined(windows):
  # UCRT round preserves signaling NaNs; the native operation quiets them.
  # Windows deliberately retains CRT calls in specializeNativeMaths.
  echo "Windows CRT floor/round parity uses guarded host-call tests; " &
    "native libm replacement stays disabled"
elif defined(amd64):
  let
    library = loadLib(when defined(windows): "ucrtbase.dll"
      elif defined(macosx): "libm.dylib" else: "libm.so.6")
    floorLib = cast[Math64](symAddr(library, "floor"))
    roundLib = cast[Math64](symAddr(library, "round"))
  doAssert library != nil and floorLib != nil and roundLib != nil
  var
    buffer = initCodeBuffer(image.bytes)
    ctx: RuntimeContext
    patterns = @[0'u64, 0x8000000000000000'u64,
      0x7ff8000000001234'u64, 0xfff8000000001234'u64,
      0x7ff0000000001234'u64, 0xfff0000000001234'u64]
  for exponent in 0'u64 .. 2047'u64:
    for fraction in [0'u64, 1'u64, 0x0007ffffffffffff'u64,
        0x0008000000000000'u64, 0x0008000000000001'u64,
        0x000fffffffffffff'u64]:
      let bits = (exponent shl 52) or fraction
      patterns.add(bits)
      patterns.add(bits or 0x8000000000000000'u64)
  # Sample neighbors of integer and half-integer boundaries in both signs.
  for i in -2048 .. 2048:
    let bits = cast[uint64](float64(i) * 0.5)
    for delta in -2 .. 2:
      patterns.add(bits + cast[uint64](delta))
  var random = 0x123456789abcdef0'u64
  for i in 0 ..< 20_000:
    random = random xor (random shl 13)
    random = random xor (random shr 7)
    random = random xor (random shl 17)
    patterns.add(random)
  type Entry = proc(ctx, input, output, reserved: pointer)
    {.cdecl, raises: [].}
  let originalRounding = getRounding()
  var cases = 0
  for index, reference in [floorLib, roundLib]:
    let entry = cast[Entry](cast[uint](buffer.entry()) +
      uint(image.offsets[index]))
    for mode in [nearest, downward, upward, towardZero]:
      doAssert setRounding(mode) == 0
      for preset in [0.cint, divideByZero]:
        for pattern in patterns:
          var
            input = pattern
            output: uint64
          errnoLocation()[] = 123
          discard clearExceptions(allExceptions)
          discard raiseExceptions(preset)
          let expected = reference(cast[float64](input))
          let expectedErrno = errnoLocation()[]
          let expectedExceptions = testExceptions(allExceptions)
          errnoLocation()[] = 123
          discard clearExceptions(allExceptions)
          discard raiseExceptions(preset)
          entry(ctx.addr, input.addr, output.addr, nil)
          let actualExceptions = testExceptions(allExceptions)
          doAssert output == cast[uint64](expected),
            "op=" & $index & " mode=" & $mode & " input=" & pattern.toHex &
            " actual=" & output.toHex & " expected=" & cast[uint64](expected).toHex
          doAssert errnoLocation()[] == expectedErrno
          doAssert actualExceptions == expectedExceptions,
            "op=" & $index & " input=" & pattern.toHex &
            " exceptions=" & $actualExceptions & " expected=" &
            $expectedExceptions
          doAssert getRounding() == mode
          inc cases
  doAssert setRounding(originalRounding) == 0
  echo "AMD64 binary64 floor/round exact cases passed: ", cases

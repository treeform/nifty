## Checks interval proofs against concrete signed arithmetic near int64 limits.
import std/[random, strutils]
import ../src/nifty
import ../src/nifty/[lowering, types]

const
  IntLow = low(int64)
  IntHigh = high(int64)
  EdgeValues = [IntLow, IntLow + 1, -100'i64, -2'i64, -1'i64,
    0'i64, 1'i64, 2'i64, 100'i64, IntHigh - 1, IntHigh]

proc literal(value: int64): string =
  ## Writes the smallest signed value without an out-of-range token.
  if value == IntLow:
    "(-9223372036854775807 - 1)"
  else:
    $value

proc checkRemainder(dividend, divisor: int64) =
  ## Requires the checker interval to contain the concrete remainder.
  if divisor == 0 or (dividend == IntLow and divisor == -1):
    return
  let source = "thread main() =\n" &
    "  let result = " & literal(dividend) & " % " & literal(divisor) & "\n" &
    "  echo result\n"
  let module = checkedModule(source, "arithmeticproofs.nifty")
  let fact = module.routines[0].body[0].init
  let remainder = dividend mod divisor
  doAssert fact.rlo <= remainder and remainder <= fact.rhi,
    "Unsound remainder interval for " & $dividend & " % " & $divisor &
    ": " & $fact.rlo & " .. " & $fact.rhi

for dividend in EdgeValues:
  for divisor in EdgeValues:
    checkRemainder(dividend, divisor)

var rng = initRand(416429)
for i in 0 ..< 200:
  let
    dividend = if i mod 2 == 0: EdgeValues[rand(rng, EdgeValues.high)]
      else: rand(rng, -1000000'i64 .. 1000000'i64)
    divisor = if i mod 3 == 0: EdgeValues[rand(rng, EdgeValues.high)]
      else: rand(rng, -1000000'i64 .. 1000000'i64)
  checkRemainder(dividend, divisor)

let unsound = "thread main() =\n" &
  "  let x = 9223372036854775807 % (-9223372036854775807 - 1)\n" &
  "  echo x + 1\n"
var rejected = false
try:
  discard checkedModule(unsound, "arithmeticproofs.nifty")
except NiftyError:
  rejected = true
doAssert rejected, "The maximum remainder must not prove safe to increment"

let hugeLoop = "thread main() =\n" &
  "  for i in (-9223372036854775807 - 1) ..< 9223372036854775807:\n" &
  "    echo 1\n"
let hugeReport = reportFor(hugeLoop, "huge.nifty")
doAssert "not representable (abstract ops exceed int64)" in hugeReport
doAssert "9223372036854775807 ops total" notin hugeReport

let smallLoop = "thread main() =\n" &
  "  for i in 0 ..< 3:\n" &
  "    echo i\n"
doAssert "ops total" in reportFor(smallLoop, "small.nifty")

let independentGlobalWrite = """
var state: 0 .. 1
proc setState() =
  state = 1
proc note(): bool =
  setState()
  return true
thread main() =
  var i: 0 .. 2 = 0
  while i < 2 and note():
    i = i + 1
  echo state
"""
discard checkedModule(independentGlobalWrite, "arithmeticproofs.nifty")

proc rejectsStorage(source: string) =
  ## Requires a source diagnostic rather than an internal overflow defect.
  var rejected = false
  try:
    discard checkedModule(source, "layout.nifty")
  except NiftyError as error:
    doAssert "static storage size exceeds int64" in error.msg, error.msg
    rejected = true
  doAssert rejected

rejectsStorage("thread main() =\n" &
  "  var data: seq[1152921504606846975, int]\n" &
  "  data.add(1)\n  echo data.len\n")
rejectsStorage("thread main() =\n" &
  "  var data: string[9223372036854775799]\n" &
  "  data.clear()\n  echo data.len\n")
rejectsStorage("object Padded =\n" &
  "  first: array[9223372036854775807, uint8]\n" &
  "  second: int\nthread main() =\n  echo 1\n")

doAssert sizeAlign(IntHigh - 7, 8) == IntHigh - 7
doAssert typeSize(Typ(kind: ArrayType, len: IntHigh,
  elem: sizedInt(0, 255, 1, "uint8"))) == IntHigh

let giantArena = "thread main() =\n" &
  "  var data: array[9223372036854775807, uint8]\n" &
  "  data[0] = 1\n  echo data[0]\n"
for render in [compileToC, reportFor]:
  var rejected = false
  try:
    discard render(giantArena, "arena.nifty", "")
  except NiftyError as error:
    doAssert "static storage size exceeds int64" in error.msg, error.msg
    rejected = true
  doAssert rejected

let nativeLimit = "thread main() =\n" &
  "  var data: array[2147483648, uint8]\n" &
  "  data[0] = 1\n  echo data[0]\n"
discard compileToC(nativeLimit, "native-limit.nifty")
# The exact C arena includes the array and echo's planned helper storage.
doAssert "2147491856 bytes" in reportFor(nativeLimit, "native-limit.nifty")
var rejectedNative = false
try:
  discard lowerNative(checkedModule(nativeLimit, "native-limit.nifty"))
except NiftyError as error:
  doAssert "native storage size exceeds 2147483647 bytes" in error.msg,
    error.msg
  rejectedNative = true
doAssert rejectedNative

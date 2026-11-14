## Checks interval proofs against concrete signed arithmetic near int64 limits.
import std/[random, strutils]
import ../src/nifty

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

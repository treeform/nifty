## Checks storage declarations and conservative source lowering proofs.
import std/[os, strutils]
import ../src/nifty/[parser, loader, checker, lowering]
import ../src/nifty/backend/[irs, irchecks, engine]

proc lower(text: string): IrModule =
  ## Checks a source snippet before inspecting its concrete native IR.
  let source = parse(loadTokens(text, "lowering-test.nifty", "."))
  check(source)
  result = lowerNative(source).module
  verifyIr(result)

proc routine(module: IrModule, name: string): IrFunction =
  ## Finds one named source procedure in the lowered module.
  for function in module.functions:
    if function.name == name:
      return function
  doAssert false, "Missing routine: " & name

proc count(function: IrFunction, op: IrOpcode): int =
  ## Counts operations before backend optimization can remove redundancy.
  for instruction in function.instructions:
    if instruction.op == op:
      inc result

let module = lower("""
object Pair =
  x: float64
  y: float64
object Padded =
  flag: bool
  value: float64
func complete(x, y: float64): Pair =
  var value: Pair
  value.x = x
  value.y = y
  return value
func partial(x: float64): Pair =
  var value: Pair
  value.x = x
  return value
func observed(x: float64): Pair =
  var value: Pair
  value.x = value.y + x
  value.y = x
  return value
func padded(x: float64): Padded =
  var value: Padded
  value.flag = true
  value.value = x
  return value
func optional(value: Padded): Padded? =
  return value
proc mutate(value: var Pair) =
  value.x = value.y
extern "libc":
  proc unknown(value: float64): float64
thread main() =
  var global: Pair
  global = complete(2.0, 3.0)
  mutate(global)
  echo global.x
  let maybe = optional(padded(9.0))
  if maybe.ok:
    echo maybe.value
""")
let
  complete = module.routine("complete")
  partial = module.routine("partial")
  observed = module.routine("observed")
  padded = module.routine("padded")
  main = module.routine("main")
var optionalField = false
for instruction in main.instructions:
  if instruction.op == FieldAddressOp:
    let field = module.fields[instruction.target]
    if field.name == "value" and field.offset == 8:
      optionalField = true
doAssert optionalField
doAssert complete.directOnly and not main.directOnly
doAssert complete.count(ClearBytesOp) == 0
doAssert complete.count(MoveBytesOp) == 1
doAssert complete.count(FieldAddressOp) >= 4
doAssert partial.count(ClearBytesOp) == 1
doAssert observed.count(ClearBytesOp) == 1
doAssert padded.count(ClearBytesOp) == 1
doAssert complete.signature.parameterStorage.len == 4
doAssert complete.signature.passing[1] == ValuePassing
doAssert complete.signature.passing[2] == MutablePassing
for slot in complete.slots:
  doAssert slot.storage > 0
var padding = false
for field in module.fields:
  if field.role == PaddingField:
    padding = true
doAssert padding
for host in module.hosts:
  doAssert not host.effects.known
for target in [Arm64Target, Amd64Target]:
  doAssert emitNative(module, target).bytes.len > 0

# Existing fixtures cover effects, mutable aliases, optional values, and layouts.
var fixtures = 0
for path in walkFiles("tests/scripts/*.nifty"):
  if path.extractFilename.startsWith("_"):
    continue
  let source = parse(loadTokens(readFile(path), path, path.parentDir))
  check(source)
  let lowered = lowerNative(source, path).module
  verifyIr(lowered)
  for global in lowered.globals:
    doAssert global.storage > 0
  inc fixtures
doAssert fixtures >= 40
let benchmark = "benchmarks/raytracer.nifty"
let source = parse(loadTokens(readFile(benchmark), benchmark,
  benchmark.parentDir))
check(source)
verifyIr(lowerNative(source, benchmark).module)
echo "Native lowering storage and initialization proofs passed"

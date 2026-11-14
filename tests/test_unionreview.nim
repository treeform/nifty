## Exercises union argument snapshots, aliases, and container dispatch.
import std/[os, osproc, strutils]
import ../src/nifty
import ../src/nifty/[ctoolchains, lowering]
import ../src/nifty/backend/[engine, irchecks]
import fixtures

const Source = """
object Left =
  value: int
object Right =
  value: int
type Choice = Left or Right
type Alias = Left
type ChoiceAlias = Choice
object Holder =
  value: Choice
proc change(value: var Choice): int =
  value = Right(99)
  return 5
proc observe(value: Left, extra: int) =
  echo "left ", value.value, " ", extra
proc observe(value: Right, extra: int) =
  echo "right ", value.value, " ", extra
proc fallback(value: Choice) =
  echo "union"
proc fallback(value: Left) =
  echo "left"
func amount(value: Left): int =
  return value.value
func amount(value: Right): int =
  return value.value
thread main() =
  var value: Choice = Left(7)
  if type(value) == Left:
    observe(value, change(value))
  observe(value, 0)
  value = Left(8)
  observe(value, change(value))
  let inferred = Alias(3)
  echo type(inferred) == Left, " ", type(inferred) == Alias
  echo type(value) == ChoiceAlias
  let holder = Holder(Left(11))
  echo amount(holder.value)
  fallback(holder.value)
  if type(holder.value) == Left:
    fallback(holder.value)
  var values: seq[Choice]
  discard values.push(Left(12))
  discard values.push(Right(13))
  for item in values:
    echo amount(item)
"""

let checked = checkedModule(Source, "union-review.nifty")
let plan = lowerNative(checked, "union-review")
verifyIr(plan.module)
for target in [Arm64Target, Amd64Target]:
  doAssert emitNative(plan.module, target).bytes.len > 0

let directory = getTempDir() / ("nifty-union-review-" & $getCurrentProcessId())
createDir(directory)
try:
  let cPath = directory / "review.c"
  let binary = directory / ("review" &
    (when defined(windows): ".exe" else: ""))
  writeFile(cPath, compileToC(Source, "union-review.nifty"))
  let compilation = execCmdEx(cCompileCommand(cPath, binary, lastExternLibs))
  doAssert compilation.exitCode == 0, compilation.output
  let execution = runFixture(binary)
  doAssert execution.exitCode == 0, execution.output
  doAssert execution.output.replace("\r\n", "\n").strip() == """
left 7 5
right 99 0
left 8 5
true true
false
11
union
left
12
13
""".strip(), execution.output
finally:
  removeDir(directory)
echo "Union review passed"

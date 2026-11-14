## Checks tagged union proofs and executes their reference backend fixtures.
import std/[os, osproc, strutils]
import ../src/nifty
import ../src/nifty/ctoolchains
import fixtures

const Prelude = """
object Left =
  value: int
object Right =
  value: int
type Choice = Left or Right
"""

proc rejects(source: string, diagnostic = "") =
  ## Requires an ordinary diagnostic instead of unsafe generated code.
  var rejected = false
  try:
    discard compileToC(source, "union-error.nifty")
  except NiftyError as error:
    doAssert error.msg.len > 0
    doAssert diagnostic in error.msg, error.msg
    rejected = true
  doAssert rejected, "Unsafe union program was accepted:\n" & source

rejects(Prelude & """
proc inspect(value: Choice) =
  echo value.value
thread main() =
  inspect(Left(1))
""", "'.' needs an object")

rejects(Prelude & """
proc replace(value: var Choice) =
  value = Right(2)
proc inspect(value: var Choice) =
  if type(value) == Left:
    replace(value)
    echo value.value
thread main() =
  var value: Choice = Left(1)
  inspect(value)
""", "'.' needs an object")

rejects(Prelude & """
proc inspect(value: var Choice) =
  if type(value) == Left:
    value = Right(2)
    echo value.value + 9223372036854775807
thread main() =
  var value: Choice = Left(1)
  inspect(value)
""", "does not overflow")

rejects(Prelude & """
proc show(value: Left) =
  echo value.value
proc inspect(value: Choice) =
  show(value)
thread main() =
  inspect(Right(1))
""", "argument 1 of 'show'")

rejects(Prelude & """
func amount(value: Left): int =
  return value.value
func amount(value: Right): bool =
  return true
proc inspect(value: Choice) =
  echo amount(value)
thread main() =
  inspect(Left(1))
""", "same return type")

rejects(Prelude & """
proc show(value: Left, amount: int) =
  echo amount
proc show(value: Right, amount: bool) =
  echo amount
proc inspect(value: Choice) =
  show(value, 1)
thread main() =
  inspect(Left(1))
""", "parameters after the first")

rejects(Prelude & """
var shared: Choice
proc replace() =
  shared = Right(2)
proc inspect() =
  if type(shared) == Left:
    replace()
    echo shared.value
thread main() =
  inspect()
""", "'.' needs an object")

rejects("""
object Same =
  value: int
type Invalid = Same or Same
thread main() =
  echo 1
""", "duplicate union member")

rejects("""
type Invalid = int or bool
thread main() =
  echo 1
""", "union members must be nominal objects")

rejects("""
object Number =
  value: int
object Text =
  value: string
type Value = Number or Text
thread main() =
  var value: Value = Text()
  let copied = value
  echo type(copied) == Text
  value = Number(1)
""", "cannot be copied or initialized")

rejects("""
object Recursive =
  value: Invalid
object Empty =
  discard
type Invalid = Recursive or Empty
thread main() =
  var value: Invalid
""", "growable seq indirection")

rejects(Prelude & """
proc inspect(value: Choice?) =
  echo type(value) == Left
thread main() =
  inspect(none)
""", "before proving it has a value")

rejects("""
object Text =
  value: string
object Number =
  value: int
type Value = Text or Number
proc inspect(value: Value?) =
  echo value.ok
thread main() =
  inspect(none)
""", "cannot be optional")

let workDir = getTempDir() / ("nifty-unions-" & $getCurrentProcessId())
createDir(workDir)

for name in ["union_values", "union_defaults", "union_order",
    "union_overloads", "union_owners", "union_recursive",
    "union_typeids", "union_boundaries", "union_deep", "union_large",
    "union_containers", "union_optionals"]:
  let
    path = currentSourcePath().parentDir / "scripts" / (name & ".nifty")
    source = readFile(path)
    generated = compileToC(source, path, path.parentDir)
    cPath = workDir / (name & ".c")
    binary = workDir / (name &
      (when defined(windows): ".exe" else: ""))
  if name == "union_large":
    for aggregate in ["S_Large", "U_Choice"]:
      doAssert aggregate & " ni_" notin generated,
        "Large aggregate temporaries must use the static arena"
      doAssert "(" & aggregate & "){" notin generated and
        "(" & aggregate & ") {" notin generated,
        "Large aggregate constructors must not use C compound literals"
  writeFile(cPath, generated)
  let compilation = execCmdEx(cCompileCommand(cPath, binary, lastExternLibs))
  doAssert compilation.exitCode == 0, compilation.output
  let execution = runFixture(binary)
  doAssert execution.exitCode == 0, name & ": " & execution.output
  doAssert execution.output.replace("\r\n", "\n").strip() ==
    readFile(path.changeFileExt(".txt")).replace("\r\n", "\n").strip(),
    name & ": unexpected output:\n" & execution.output

removeDir(workDir)
echo "Union proofs and runtime fixtures passed"

## Module namespaces, aliases and single-instance imports across backends.
import std/[os, osproc, strutils, tables]
import ../src/nifty
import ../src/nifty/[types, lowering, nativefiles, ctoolchains]

let directory = getTempDir() / ("nifty-modules-" & $getCurrentProcessId())
createDir(directory)
proc source(name, text: string) =
  createDir((directory / name).parentDir)
  writeFile(directory / name, text)
proc expectError(text, message: string) =
  var rejected = false
  try: discard checkedModule(text, directory / "main.nifty", directory)
  except NiftyError as error:
    rejected = message in error.msg
    doAssert rejected, error.msg
  doAssert rejected, "expected rejection: " & message

source("counter.nifty", """
var counter: 0 .. 1000
proc next(): int =
  if counter < 1000:
    counter = counter + 1
  return counter
""")
source("a.nifty", """
import counter
const Name = 1
func foo(): int =
  return 10
func own(): int =
  return foo()
""")
source("b.nifty", """
import "./counter.nifty"
const Name = 2
func foo(): int =
  return 20
""")
source("leaf.nifty", """
const Capacity = 4
const _secret = 9
object Item =
  value: int
type Handle = opaque
func get(item: Item): int =
  return item.value
func identity(value: $T): $T =
  return value
func _helper(): int =
  return _secret
proc combine(text: string) =
  echo text
""")
source("facade.nifty", "import leaf\n")
source("copies/leaf.nifty", readFile(directory / "leaf.nifty"))
source("graphics/window.nifty", "const Width = 80\n")
source("shadow.nifty", """
const thing = 77
func value(): int =
  return thing
""")
source("resource.nifty", """
object Resource =
  value: 0 .. 10
proc start(item: var Resource) =
  item.value = 4
proc end(item: var Resource) =
  item.value = 0
proc exercise(): int =
  var item: Resource
  var result: 0 .. 10 = 0
  with item:
    result = item.value
  return result + item.value
""")
source("loopnames.nifty", "func n(): int =\n  return 0\n")
source("worker.nifty", "thread worker() =\n  echo \"once\"\n")
source("thread_a.nifty", "import worker\n")
source("thread_b.nifty", "import \"./worker.nifty\"\n")
source("over_a.nifty", "func choose(value: int): int =\n  return 1\n")
source("over_b.nifty", "func choose(value: int): int =\n  return 2\n")
source("over_local.nifty", """
import over_a
func choose(value: int): int =
  return 3
func own(): int =
  return choose(0)
""")
source("over_export.nifty", "import over_local\n")
source("state.nifty", """
var value: 0 .. 9
var gate: Lock
proc increment() =
  with gate:
    if value < 9:
      value = value + 1
thread writer() =
  increment()
""")
source("keyword_var.nifty", """
func count(max: 0 .. 2): int =
  var i: 0 .. 2 = 0
  while i < max max 2:
    i = i + 1
  return i
""")
source("keyword_fn.nifty", """
func max(a: int, b: int): int =
  if a > b:
    return a
  return b
""")
source("leak.nifty", "func run(): int =\n  return missing()\n")
source("leak_type.nifty", "func identity(value: $T): $T =\n  var extra: Caller\n  return value\n")
source("other_generic.nifty", "func identity(value: $T): $T =\n  return value\n")
source("union_number.nifty", """
object Number =
  value: int
func evaluate(item: Number): int =
  return item.value
""")
source("union_flag.nifty", """
object Flag =
  value: bool
func evaluate(item: Flag): int =
  if item.value:
    return 2
  return 3
""")
source("union_facade.nifty", "import union_number\nimport union_flag\n")
source("union_duplicate.nifty", """
import union_number
func evaluate(item: Number): int =
  return 9
""")
source("union_effect.nifty", """
import union_number
var count: 0 .. 10
proc record(item: Number) =
  if count < 10:
    count = count + 1
""")
source("union_effect_flag.nifty", """
import union_flag
proc record(item: Flag) =
  discard item.value
""")

const Main = """
import a
import b
import "counter.nifty" as shared
import facade
import "graphics/window.nifty"
import shadow
import resource
import loopnames
import keyword_var
import keyword_fn
import union_facade

type List = facade.Item
type Item = union_number.Number or union_flag.Flag
type SameHandle = leaf.Handle
number = a.Name
selected = b.foo
copyValue = leaf.identity
OtherList = leaf.Item
dispatch = union_facade.evaluate

object Caller =
  number: int

func foo(): int =
  return 30
proc combine(value: int) =
  echo value
func inspect(item: Item): int =
  return dispatch(item)
func evaluate(item: Item): int =
  return 99
func inspectExplicit(item: Item): int =
  return evaluate(item)

thread main() =
  echo next(), " ", a.next(), " ", counter.next(), " ", shared.next()
  echo foo(), " ", a.foo(), " ", b.foo(), " ", a.own(), " ", selected()
  echo number, " ", b.Name, " ", window.Width
  var item: List
  item.value = 7
  echo facade.leaf.get(item), " ", copyValue(8)
  var values: array[leaf.Capacity, int]
  values[0] = 6
  echo values[0], " ", _secret, " ", _helper()
  combine(1)
  combine("one")
  let thing = 3
  echo thing, " ", shadow.value()
  echo resource.exercise()
  var item2: resource.Resource
  with item2:
    echo item2.value
  block:
    let next = shared.next()
    echo next
  echo next()
  for n in n() ..< 2:
    echo n
  echo n()
  let other: OtherList = item
  echo leaf.get(other)
  var caller: Caller
  caller.number = 8
  let copied = copyValue(caller)
  echo copied.number
  echo keyword_fn.max(1, 2), " ", keyword_var.count(2)
  echo inspect(union_number.Number(7)), " ", inspect(union_flag.Flag(true))
  echo inspectExplicit(union_flag.Flag(false))
"""
const Expected = "1 2 3 4\n30 10 20 10 20\n1 2 80\n7 8\n6 9 9\n1\none\n3 77\n4\n4\n5\n6\n0\n1\n0\n7\n8\n2 2\n7 2\n99\n"

try:
  let checked = checkedModule(Main, directory / "main.nifty", directory)
  var counters = 0
  for global in checked.globals:
    if global.name.endsWith("_s_counter"): inc counters
  doAssert counters == 1, "diamond and aliases instantiated counter more than once"
  let threaded = checkedModule("import thread_a\nimport thread_b\nthread main() =\n  discard 0\n",
    directory / "threads.nifty", directory)
  doAssert lowerNative(threaded).threads.len == 2, "an imported thread was duplicated"
  let plan = lowerNative(checked, "modules")
  for target in NativeTarget:
    discard decodeNative(buildNativeProgram(plan, target).encodeNative())
  source("main.nifty", Main)
  let compiler = currentSourcePath().parentDir.parentDir / "nifty" &
    (when defined(windows): ".exe" else: "")
  for backend in ["c", when defined(arm64): "arm64" else: "amd64"]:
    for optimization in ["none", "speed"]:
      let binary = directory / ("module-" & backend & "-" & optimization &
        (when defined(windows): ".exe" else: ""))
      var built: tuple[output: string, exitCode: int]
      if backend == "c":
        let cpath = directory / ("modules-" & optimization & ".c")
        built = execCmdEx(quoteShellCommand(@[compiler, "build",
          directory / "main.nifty", "--emit-c", "-o", cpath]))
        doAssert built.exitCode == 0, built.output
        built = execCmdEx(cCompileCommand(cpath, binary,
          options = @[(if optimization == "none": "-O0" else: "-O2")]))
      else:
        built = execCmdEx(quoteShellCommand(@[compiler, "build",
          directory / "main.nifty", "--backend:" & backend, "--opt:" & optimization,
          "-o", binary]))
      doAssert built.exitCode == 0, built.output
      let ran = execCmdEx(quoteShell(binary))
      doAssert ran.exitCode == 0, ran.output
      doAssert ran.output.replace("\r\n", "\n") == Expected, ran.output
  let node = findExe("node")
  let canRunWasm = node.len > 0 and execCmdEx(quoteShellCommand(@[node, "-e",
    "process.exit(WebAssembly.validate(Buffer.from('0061736d010000000404017004010503010401','hex')) ? 0 : 1)"])).exitCode == 0
  let runner = currentSourcePath().parentDir.parentDir / "tools" / "wasm" / "run.mjs"
  for optimization in ["none", "speed"]:
    let binary = directory / ("modules-" & optimization & ".wasm")
    let built = execCmdEx(quoteShellCommand(@[compiler, "build",
      directory / "main.nifty", "--backend:wasm64", "--opt:" & optimization,
      "-o", binary]))
    doAssert built.exitCode == 0, built.output
    if canRunWasm:
      let ran = execCmdEx(quoteShellCommand(@[findExe("node"), runner, binary]))
      doAssert ran.exitCode == 0, ran.output
      doAssert ran.output.replace("\r\n", "\n") == Expected, ran.output
  expectError("import a\nimport b\nthread main() =\n  echo Name\n", "ambiguous imported name 'Name'")
  expectError("import a\nimport b\nthread main() =\n  echo foo()\n", "ambiguous imported name 'foo'")
  expectError("import b\nimport a\nthread main() =\n  echo foo()\n", "ambiguous imported name 'foo'")
  expectError("import a, b\nthread main() =\n  discard 0\n", "one import is allowed per line")
  expectError("import a\nthread main() =\n  let a = 1\n  echo a\n", "module name 'a' is reserved")
  expectError("import leaf\nimport \"copies/leaf.nifty\" as other\nthread main() =\n  var x: leaf.Item\n  echo other.get(x)\n", "expected")
  expectError("import a\nx = y\ny = x\nthread main() =\n  discard 0\n", "alias cycle")
  expectError("import a\ntype Wrong = a.foo\nthread main() =\n  discard 0\n", "must name a type")
  expectError("import over_a\nimport over_b\nthread main() =\n  echo choose(0)\n",
    "ambiguous imported name 'choose'")
  expectError("import over_b\nimport over_a\nthread main() =\n  echo choose(0)\n",
    "ambiguous imported name 'choose'")
  expectError("import over_export\nimport over_a\nthread main() =\n  echo choose(0)\n",
    "ambiguous imported name 'choose'")
  expectError("import state\noutside = state.value\nthread main() =\n  outside = 1\n",
    "shared global")
  expectError("import leak\nfunc missing(): int =\n  return 1\nthread main() =\n  echo leak.run()\n",
    "unknown func or proc: 'missing'")
  expectError("import leak_type\nobject Caller =\n  number: int\nthread main() =\n  var value: Caller\n  value.number = 1\n  let copied = leak_type.identity(value)\n  echo copied.number\n",
    "unknown type")
  expectError("import leaf\nimport other_generic\nthread main() =\n  echo identity(1)\n",
    "ambiguous imported name 'identity'")
  expectError("""
import union_facade
import leaf
type Item = union_number.Number or leaf.Item
func inspect(item: Item): int =
  return evaluate(item)
thread main() =
  echo inspect(union_number.Number(1))
""", "missing overload for")
  expectError("""
import union_facade
import union_duplicate
type Item = union_number.Number or union_flag.Flag
func inspect(item: Item): int =
  return evaluate(item)
thread main() =
  echo inspect(union_number.Number(1))
""", "ambiguous union dispatch")
  expectError("""
import union_effect
import union_effect_flag
type Item = union_number.Number or union_flag.Flag
proc inspect(item: Item) =
  record(item)
thread main() =
  inspect(union_number.Number(1))
thread worker() =
  inspect(union_flag.Flag(true))
""", "shared global")
  let explicitChoice = checkedModule("import over_export\nthread main() =\n  echo choose(0), own()\n",
    directory / "choice.nifty", directory)
  discard lowerNative(explicitChoice)
finally:
  removeDir(directory)
echo "Module namespaces, aliases and identity passed"

## Checks deferred generic callees in resource reports and generated C.
import std/[os, osproc, strutils]
import ../src/nifty
import ../src/nifty/[ctoolchains, types]
import fixtures

const
  ArenaSource = """
proc outer(value: $T) =
  inner(value)
proc inner(value: $T) =
  var own: array[1024, int]
  own[0] = 9
  leaf()
  echo own[0]
proc leaf() =
  var scratch: array[1024, int]
  scratch[0] = 7
  echo scratch[0]
thread main() =
  outer(1)
"""
  DynamicSource = """
proc invoke(value: $T) =
  work()
proc work() =
  var text: string
  discard text.add("ok")
  echo text
thread main() =
  invoke(1)
"""
  HookSource = """
proc invoke(value: $T) =
  var target: int = 0
  with target:
    echo value
  echo target
proc start(target: var int) =
  target = 1
proc end(target: var int) =
  target = 2
thread main() =
  invoke(3)
"""
  CollisionSource = """
object A_B =
  value: int
object C =
  value: int
object A =
  padding: int
  value: int
object B_C =
  value: int
func pick(first: $T, second: $U): int =
  return first.value
thread main() =
  echo pick(A_B(11), C(0))
  echo pick(A(0, 22), B_C(0))
  echo pick(A_B(33), C(0))
"""
  CacheSource = """
object arr1_0_9 =
  value: int
func identity(value: $T): $T =
  return value
thread main() =
  let item = identity(arr1_0_9(9))
  echo item.value
  var values: array[1, 0 .. 9]
  values[0] = 3
  let copied = identity(values)
  echo copied[0]
"""
  DeclaredNameSource = """
func identity__int(): int =
  return 42
func identity(value: $T): $T =
  return value
thread main() =
  echo identity__int()
  echo identity(7)
"""
  OptionalSource = """
object Item =
  value: int
object Itemopt =
  value: int
func optional(): Item? =
  return Item(5)
func identity(value: $T): $T =
  return value
thread main() =
  let maybe = identity(optional())
  if maybe.ok:
    echo maybe.value
  let named = identity(Itemopt(6))
  echo named.value
"""
  OpaqueSource = """
type First = opaque
type Second = opaque
func identity(value: $T): $T =
  return value
thread main() =
  var first: First
  first = first
  var second: Second
  second = second
  echo identity(first).isNull, " ", identity(second).isNull
"""
  WidthSource = """
func identity(value: $T): $T =
  return value
thread main() =
  let byte: int8 = 7
  let ranged: -128 .. 127 = 9
  echo identity(byte), " ", identity(ranged)
  let wide: int64 = 11
  let plain: int = 13
  echo identity(wide), " ", identity(plain)
"""

let
  arena = checkedModule(ArenaSource, "generic-arena.nifty")
  report = reportFor(ArenaSource, "generic-arena.nifty")
doAssert arena.routines[0].name == "leaf"
doAssert arena.routines[1].name == "inner__int"
doAssert arena.routines[2].name == "outer__int"
doAssert arena.routines[3].name == "main"
doAssert ("main: 313 bytes (main -> outer__int -> inner__int -> leaf -> " &
  "niftyEchoSupport_echoInt -> niftyEchoSupport_echoText -> " &
  "niftyEchoSupport_consoleWrite -> niftyEchoSupport_ioWriteChunk -> " &
  "niftyEchoSupport_ioRawWrite)") in report
doAssert ("main: 24592 bytes (main -> outer__int -> inner__int -> leaf -> " &
  "niftyEchoSupport_echoFinish -> niftyEchoSupport_echoText -> " &
  "niftyEchoSupport_consoleWrite)") in report
doAssert "main: 28 ops total" in report, report
doAssert "main: runtime-dependent" in
  reportFor(DynamicSource, "generic-dynamic.nifty")
let collisions = checkedModule(CollisionSource, "generic-collision.nifty")
doAssert collisions.routines.len == 3
doAssert collisions.routines[0].name != collisions.routines[1].name
let widths = checkedModule(WidthSource, "generic-widths.nifty")
doAssert widths.routines.len == 5
doAssert widths.routines[0].params[0].typ.width == 1
doAssert widths.routines[1].params[0].typ.width == 0

let directory = getTempDir() / "nifty-generic-order-" &
  $getCurrentProcessId()
createDir(directory)
try:
  for fixture in [
    ("arena", ArenaSource, "7\n9"),
    ("dynamic", DynamicSource, "ok"),
    ("hooks", HookSource, "3\n2"),
    ("collisions", CollisionSource, "11\n22\n33"),
    ("cache", CacheSource, "9\n3"),
    ("declared-name", DeclaredNameSource, "42\n7"),
    ("optional", OptionalSource, "5\n6"),
    ("opaque", OpaqueSource, "true true"),
    ("widths", WidthSource, "7 9\n11 13")
  ]:
    let
      (name, source, expected) = fixture
      cPath = directory / name & ".c"
      executable = directory / (name &
        (when defined(windows): ".exe" else: ""))
    writeFile(cPath, compileToC(source, name & ".nifty"))
    let build = execCmdEx(cCompileCommand(cPath, executable,
      options = @["-std=c99"]))
    doAssert build.exitCode == 0, build.output
    let execution = runFixture(executable)
    doAssert execution.exitCode == 0, execution.output
    doAssert execution.output.replace("\r\n", "\n").strip() == expected,
      execution.output
finally:
  removeDir(directory)

echo "Deferred generic routine ordering passed"

## C reports must include the same echo/library arenas as generated C.
import std/strutils
import ../src/nifty
import ../src/nifty/[types, report, codegen]

proc arenaInC(generated, name: string): int64 =
  for line in generated.splitLines():
    if line.startsWith("static _Alignas(16) uint8_t ni_arena_" & name & "["):
      return parseBiggestInt(line[line.rfind('[') + 1 ..< line.rfind(']')])

proc arenaInReport(value, label: string): int64 =
  var inArena = false
  for line in value.splitLines():
    if line.startsWith("arena per thread (exact;"):
      inArena = true
    elif inArena and line.startsWith("  " & label & ": "):
      let prefix = "  " & label & ": "
      return parseBiggestInt(line[prefix.len ..< line.find(" bytes")])

const cases = [
  ("silent", "thread main() =\n  discard 0\n", "main"),
  ("scalar", "thread main() =\n  echo 7\n", "main"),
  ("literal", "thread main() =\n  echo \"hello\"\n", "main"),
  ("fixed", """
thread main() =
  var text: string[1024]
  text.add("fixed")
  echo text
""", "main"),
  ("dynamic", """
thread main() =
  var text: string
  discard text.add("owned")
  echo text
""", "main"),
  ("console", """
import console
thread main() =
  discard write("prefix")
  echo "suffix"
""", "main"),
  ("instances", "thread 2 main() =\n  echo 7\n", "main x2")]

for (name, source, label) in cases:
  let checked = checkedModule(source, name & ".nifty")
  let bindings = checked.semantics.bindings.len
  let routines = checked.routines.len
  let last = checked.routines[^1]
  let generated = generate(checked, name & ".nifty")
  let value = buildReport(checked, name & ".nifty")
  let actual = arenaInC(generated, "main")
  doAssert arenaInReport(value, label) == actual, value
  if name == "silent":
    doAssert actual == 0
  elif name == "fixed":
    doAssert actual > 8208
  else:
    doAssert actual == 8208
  if name == "scalar":
    doAssert "main: 2 ops total" in value
  if name == "dynamic":
    doAssert "local main.text: string (declaration scope)" in value
    doAssert "main: runtime-dependent" in value
  doAssert checked.semantics.bindings.len == bindings
  doAssert checked.routines.len == routines
  doAssert checked.routines[^1] == last
  if name != "silent":
    doAssert last.body[^1].kind == EchoStmt
  doAssert buildReport(checked, name & ".nifty") == value

# Both platform variants must report the same foreign argument carriers.
# Model the relevant ABI difference directly, without relying on the host OS.
for countType in ["int32", "int64"]:
  let source = "extern \"libc\":\n" &
    "  proc raw(data: string[4096], count: " & countType & "): int64\n" &
    "thread main() =\n  discard raw(\"x\", 1)\n"
  let value = reportFor(source, "foreign-slots.nifty")
  doAssert "main: 48 bytes (main -> raw)" in value, value

# Source operation/progress/lock sections remain source-level metrics.
let locked = """
var gate: Lock
thread 2 main() =
  with gate:
    echo 1
"""
let value = reportFor(locked, "locked.nifty")
doAssert "gate: serializes output; used by main" in value
doAssert "main x2: 6 ops total" in value, value

echo "C report storage accounting passed"

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

let directory = getTempDir() / "nifty-generic-order-" &
  $getCurrentProcessId()
createDir(directory)
try:
  for fixture in [
    ("arena", ArenaSource, "7\n9"),
    ("dynamic", DynamicSource, "ok"),
    ("hooks", HookSource, "3\n2")
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

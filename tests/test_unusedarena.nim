## Checks arena declarations for emitted routines unreachable from threads.
import
  std/[os, osproc, strutils],
  ../src/nifty,
  ../src/nifty/ctoolchains,
  fixtures

const Unused = """
proc unused() =
  var scratch: array[1024, int]
  scratch[0] = 99
  echo scratch[0]
proc small() =
  echo 7
"""

let directory = getTempDir() / ("nifty-unused-arena-" &
  $getCurrentProcessId())
createDir(directory)
try:
  for fixture in [
    ("none", Unused & "thread main() =\n  echo 3\n", "3"),
    ("small", Unused & "thread main() =\n  small()\n", "7"),
    ("large", Unused & "thread main() =\n  unused()\n", "99")
  ]:
    let
      (name, source, expected) = fixture
      generated = compileToC(source, name & ".nifty")
      cPath = directory / (name & ".c")
      binary = directory / (name & ExeExt)
    doAssert "static _Thread_local uint8_t *ni_sp;" in generated
    doAssert "static void f_unused(" in generated
    if name == "large":
      doAssert "uint8_t ni_arena_main[8192]" in generated
    else:
      doAssert "uint8_t ni_arena_" notin generated
    writeFile(cPath, generated)
    let build = execCmdEx(cCompileCommand(cPath, binary))
    doAssert build.exitCode == 0, build.output
    let execution = runFixture(binary)
    doAssert execution.exitCode == 0, execution.output
    doAssert execution.output.strip() == expected, execution.output
finally:
  removeDir(directory)
echo "Unused arena routine checks passed (3 fixtures)"

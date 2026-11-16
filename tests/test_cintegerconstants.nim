## Minimum signed constants must compile as standard C, without oversized literals.
import std/[os, osproc, strutils]
import ../src/nifty
import ../src/nifty/ctoolchains
import fixtures

const Source = """
const Minimum = -9223372036854775807 - 1
const NearMinimum = -9223372036854775807
const Maximum = 9223372036854775807
thread main() =
  echo Minimum
  echo NearMinimum
  echo Maximum
  echo Minimum < 0
"""

let work = getTempDir() / ("nifty_cintegerconstants_" & $getCurrentProcessId())
createDir(work)
let source = work / "constants.c"
let binary = work / ("constants" & (when defined(windows): ".exe" else: ""))
try:
  let generated = compileToC(Source, "constants.nifty")
  doAssert "C_Minimum = INT64_MIN;" in generated
  doAssert "-9223372036854775808LL" notin generated
  writeFile(source, generated)
  let built = execCmdEx(cCompileCommand(source, binary,
    options = @["-std=c11", "-pedantic-errors"]))
  doAssert built.exitCode == 0, built.output
  let executed = runFixture(binary)
  doAssert executed.exitCode == 0, executed.output
  doAssert executed.output.replace("\r\n", "\n").strip() ==
    "-9223372036854775808\n-9223372036854775807\n9223372036854775807\ntrue"
finally:
  removeDir(work)

echo "C signed integer boundary literals passed"

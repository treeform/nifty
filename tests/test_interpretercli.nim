## Checks direct interpretation with no compiler or writable source directory.
import std/[os, osproc, streams, strutils]

if paramCount() != 1:
  quit("Usage: test_interpretercli /absolute/path/to/nifty", 1)
let
  compiler = absolutePath(paramStr(1))
  work = getTempDir() / ("nifty-interpreter-" & $getCurrentProcessId())
  source = work / "hello.nifty"
  previousPath = getEnv("PATH")
createDir(work)
writeFile(source, "thread main() =\n  echo \"interpreter CLI passed\"\n")
let
  directoryPermissions = getFilePermissions(work)
  sourcePermissions = getFilePermissions(source)

proc invoke(arguments: seq[string]): tuple[output: string, status: int] =
  ## Executes the already built interpreter with an empty executable path.
  let process = startProcess(compiler, args = arguments,
    options = {poStdErrToStdOut})
  result.output = process.outputStream.readAll()
  result.status = process.waitForExit()
  process.close()

try:
  putEnv("PATH", "")
  setFilePermissions(source, {fpUserRead, fpGroupRead, fpOthersRead})
  when not defined(windows):
    setFilePermissions(work, {fpUserRead, fpUserExec})
  for optimization in ["none", "speed"]:
    for arguments in [@["interpret", source],
        @[source, "--backend:interp"],
        @[source, "--backend:interpreter"],
        @[source, "--backend:interpret"]]:
      let executed = invoke(arguments & @["--opt:" & optimization])
      doAssert executed.status == 0, executed.output
      doAssert executed.output == "interpreter CLI passed\n", executed.output
  let emitted = invoke(@["interpret", source, "--emit-ir"])
  doAssert emitted.status == 0, emitted.output
  doAssert emitted.output.len > 0
  doAssert "built " notin emitted.output
  let report = invoke(@["report", source, "--backend:interp"])
  doAssert report.status == 0, report.output
  doAssert "IR instructions:" in report.output
  for arguments in [@["build", source, "--backend:interp"],
      @["interpret", source, "-o", work / "output"],
      @["interpret", source, "--emit-native"]]:
    let rejected = invoke(arguments)
    doAssert rejected.status != 0, rejected.output
    doAssert "interpreter runs IR directly" in rejected.output
  var files = 0
  for kind, path in walkDir(work):
    doAssert kind == pcFile and path == source, path
    inc files
  doAssert files == 1
finally:
  putEnv("PATH", previousPath)
  setFilePermissions(work, directoryPermissions)
  setFilePermissions(source, sourcePermissions)
  removeDir(work)
echo "Interpreter CLI passed without tools or artifacts"

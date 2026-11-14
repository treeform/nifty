## Exercises C string copies without optimization hiding invalid memory calls.
import std/[os, osproc, strutils]
import ../src/nifty, ../src/nifty/ctoolchains, fixtures

let
  fixture = currentSourcePath().parentDir / "scripts" / "copyrange_edges.nifty"
  expected = readFile(fixture.changeFileExt("txt")).strip()
  directory = getTempDir() / ("nifty-copyrange-" & $getCurrentProcessId())
  source = directory / "copyrange.c"
  binary = directory / ("copyrange" &
    (when defined(windows): ".exe" else: ""))
var options = @["-std=c99", "-O0"]
if getEnv("NIFTY_SANITIZE") == "1":
  options.add @["-g", "-fsanitize=address,undefined",
    "-fno-sanitize-recover=all", "-fno-omit-frame-pointer"]
createDir(directory)
try:
  writeFile(source, compileToC(readFile(fixture), fixture))
  let build = execCmdEx(cCompileCommand(source, binary, options = options))
  doAssert build.exitCode == 0, build.output
  let execution = runFixture(binary)
  doAssert execution.exitCode == 0, execution.output
  doAssert execution.output.replace("\r\n", "\n").strip() == expected,
    execution.output
finally:
  removeDir(directory)
echo "String copy bounds and overlap checks passed"

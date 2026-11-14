## Checks C literal escapes preserve binary bytes and storage lengths.
import std/[os, osproc, strutils]
import ../src/nifty, ../src/nifty/ctoolchains, fixtures

const
  Source = """
thread main() =
  let fixed: string[32] = "\0123\0456\0789\089\0007\0"
  var growable: string
  discard growable.add("\0123\0456\0789\089\0007\0")
  echo fixed.len, " ", growable.len
  echo fixed
  echo growable
  echo "\0123\0456\0789\089\0007\0"
  echo "\n1\r2\t3\\4\"5"
"""
  Payload = "\x00123\x00456\x00789\x0089\x00007\x00"
  Expected = "20 20\n" & Payload & "\n" & Payload & "\n" &
    Payload & "\n\n1\r2\t3\\4\"5\n"

let
  directory = getTempDir() / ("nifty-string-literals-" &
    $getCurrentProcessId())
  source = directory / "string_literals.c"
  binary = directory / ("string_literals" &
    (when defined(windows): ".exe" else: ""))
var options = @["-std=c99", "-O0"]
if getEnv("NIFTY_SANITIZE") == "1":
  options.add @["-g", "-fsanitize=address,undefined",
    "-fno-sanitize-recover=all", "-fno-omit-frame-pointer"]
createDir(directory)
try:
  writeFile(source, compileToC(Source, "string_literals.nifty"))
  let build = execCmdEx(cCompileCommand(source, binary, options = options))
  doAssert build.exitCode == 0, build.output
  let execution = runFixture(binary)
  doAssert execution.exitCode == 0, execution.output
  doAssert execution.output == Expected, execution.output.escape()
finally:
  removeDir(directory)
echo "C string literal byte checks passed"

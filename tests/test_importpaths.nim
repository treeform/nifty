## Checks quoted paths and imports relative to each importing module.
import std/[os, osproc, strutils]
import ../src/nifty
import ../src/nifty/ctoolchains
import fixtures

let directory = getTempDir() / ("nifty-import-paths-" & $getCurrentProcessId())
createDir(directory / "library" / "nested")
try:
  writeFile(directory / "library" / "nested" / "leaf.nifty",
    "func answer(): int =\n  return 7\n")
  writeFile(directory / "library" / "entry.nifty",
    "import \"nested/leaf\"\nfunc combined(): int =\n  return answer()\n")
  let source = "import \"library/entry\"\n" &
    "import \"library/nested/leaf\"\n" &
    "thread main() =\n  echo combined()\n"
  let
    cPath = directory / "imports.c"
    binary = directory / ("imports" & ExeExt)
  writeFile(cPath, compileToC(source, "imports.nifty", directory))
  let compilation = execCmdEx(cCompileCommand(cPath, binary))
  doAssert compilation.exitCode == 0, compilation.output
  let execution = runFixture(binary)
  doAssert execution.exitCode == 0, execution.output
  doAssert execution.output.strip() == "7", execution.output

  writeFile(directory / "library" / "nested" / "leaf.nifty",
    "import \"../entry\"\n")
  var rejected = false
  try:
    discard checkedModule(source, "imports.nifty", directory)
  except NiftyError as error:
    doAssert "import cycle" in error.msg, error.msg
    rejected = true
  doAssert rejected, "Relative imports must preserve cycle detection"
finally:
  removeDir(directory)

echo "Relative import paths passed"

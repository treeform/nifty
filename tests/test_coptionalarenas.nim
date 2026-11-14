## Checks large optional union wrappers use planned C arena storage.
import
  std/[os, osproc, strutils],
  ../src/nifty,
  ../src/nifty/ctoolchains,
  fixtures

const Source = """
object Large =
  values: array[4096, int]
object Small =
  value: int
type Choice = Large or Small

func make(): Choice? =
  var values: array[4096, int]
  values[4095] = 7
  return Large(values)

thread main() =
  var values: array[4096, int]
  values[4095] = 3
  var choice: Choice? = Large(values)
  if choice.ok:
    if type(choice) == Large:
      echo choice.values[4095]
  choice = make()
  if choice.ok:
    if type(choice) == Large:
      echo choice.values[4095]
"""

let directory = getTempDir() / ("nifty-optional-arena-" &
  $getCurrentProcessId())
createDir(directory)
try:
  let
    generated = compileToC(Source, "optional-arena.nifty")
    cPath = directory / "optional.c"
    binary = directory / ("optional" & ExeExt)
  doAssert "NS_pu_Choice ni_" notin generated,
    "Large optional union temporaries must use arena storage"
  doAssert "((NS_pu_Choice){" notin generated,
    "Large optional wrappers must avoid C compound literals"
  writeFile(cPath, generated)
  let compilation = execCmdEx(cCompileCommand(cPath, binary))
  doAssert compilation.exitCode == 0, compilation.output
  let execution = runFixture(binary)
  doAssert execution.exitCode == 0, execution.output
  doAssert execution.output.strip() == "3\n7", execution.output
finally:
  removeDir(directory)
echo "Large optional union C arena checks passed"

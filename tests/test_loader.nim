## Standard modules resolve independently of the user's working directory.
import std/[os, sequtils, strutils]
import ../src/nifty/[common, lexer, loader]

let directory = getTempDir() / ("nifty-loader-" & $getCurrentProcessId())
let previousLibrary = getEnv("NIFTY_STDLIB")
createDir(directory / "application")
createDir(directory / "library")
try:
  putEnv("NIFTY_STDLIB", directory / "library")
  writeFile(directory / "library" / "helper.nifty", "const Helper = 19\n")
  writeFile(directory / "library" / "sample.nifty",
    "import helper\nconst Sample = Helper + 4\n")
  let loaded = loadTokens("import sample\n", "main.nifty",
    directory / "application")
  doAssert loaded.anyIt(it.kind == IdentToken and it.text == "Helper")
  doAssert srcFiles[1].endsWith("sample.nifty")
  doAssert srcFiles[2] == directory / "library" / "helper.nifty"
  writeFile(directory / "application" / "sample.nifty", "const Local = 1\n")
  let local = loadTokens("import sample\n", "main.nifty",
    directory / "application")
  doAssert local.anyIt(it.kind == IdentToken and it.text == "Local")
  doAssert not local.anyIt(it.kind == IdentToken and it.text == "Helper")
  try:
    discard loadTokens("import missing\n", "main.nifty",
      directory / "application")
    doAssert false, "missing imports must be rejected"
  except NiftyError as error:
    doAssert "cannot find import 'missing'" in error.msg
finally:
  if previousLibrary.len == 0:
    delEnv("NIFTY_STDLIB")
  else:
    putEnv("NIFTY_STDLIB", previousLibrary)
  removeDir(directory)

echo "Standard library lookup checks passed"

## tests.nim
## Gold master tests for nifty.
## Each .nifty file is paired with a .txt file holding the expected result:
## - scripts/  : programs that compile and run; stdout must equal the .txt
## - errors/   : programs the checker must reject; the .txt text must
##               appear in the compile error
## - syntax/   : programs the lexer/parser must reject; same .txt rule
## - runtime/  : programs that compile but must trap when run; the .txt
##               text must appear in the output and the exit code be nonzero
## - reports/  : programs whose `nifty report` output must equal the .txt

import
  std/[algorithm, os, osproc, strutils],
  ../src/nifty

var testsPassed* = 0
var testsFailed* = 0

type
  TestMode = enum
    tmRun, tmCompileError, tmRuntimeTrap

proc firstLine(s: string): string =
  if s.len == 0: "(empty)" else: s.splitLines()[0]

proc runTestsInDir(dir, label: string, mode: TestMode, workDir: string) =
  if not dirExists(dir):
    return
  var paths: seq[string]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".nifty"):
      paths.add path
  paths.sort()
  for path in paths:
    if path.extractFilename().startsWith("_"):
      continue # helper module for an import test, not a test itself
    let testName = path.extractFilename().changeFileExt("")
    let expectedPath = path.changeFileExt(".txt")
    if not fileExists(expectedPath):
      echo "  SKIP: " & label & "/" & testName & " (no .txt file)"
      continue
    let expected = readFile(expectedPath).replace("\r\n", "\n").strip()
    var compileError = ""
    var cCode = ""
    try:
      cCode = compileToC(readFile(path), path.extractFilename, path.parentDir)
    except NiftyError as e:
      compileError = e.msg

    case mode
    of tmCompileError:
      # Exact match, including file:line - a wrong location is a bug.
      if compileError.len > 0 and compileError.strip() == expected:
        echo "  PASS: " & label & "/" & testName
        testsPassed += 1
      elif compileError.len > 0:
        echo "  FAIL: " & label & "/" & testName
        echo "    Expected error: " & expected
        echo "    Actual error:   " & compileError
        testsFailed += 1
      else:
        echo "  FAIL: " & label & "/" & testName
        echo "    Expected error containing: " & expected
        echo "    But it compiled without error"
        testsFailed += 1
    of tmRun, tmRuntimeTrap:
      if compileError.len > 0:
        echo "  FAIL: " & label & "/" & testName
        echo "    Compile error: " & compileError
        testsFailed += 1
        continue
      let cPath = workDir / testName & ".c"
      writeFile(cPath, cCode)
      let bin = workDir / testName
      if execShellCmd("cc -O2 -pthread -o " & quoteShell(bin) & " " &
          quoteShell(cPath)) != 0:
        echo "  FAIL: " & label & "/" & testName & " (cc failed)"
        testsFailed += 1
        continue
      let (output, code) = execCmdEx(quoteShell(bin))
      let actual = output.replace("\r\n", "\n").strip()
      if mode == tmRun:
        if code == 0 and actual == expected:
          echo "  PASS: " & label & "/" & testName
          testsPassed += 1
        else:
          echo "  FAIL: " & label & "/" & testName
          echo "    Expected: " & firstLine(expected) & "..."
          echo "    Actual:   " & firstLine(actual) & "... (exit " & $code & ")"
          testsFailed += 1
      else:
        if code != 0 and expected in actual:
          echo "  PASS: " & label & "/" & testName
          testsPassed += 1
        else:
          echo "  FAIL: " & label & "/" & testName
          echo "    Expected a trap containing: " & expected
          echo "    Actual: " & firstLine(actual) & " (exit " & $code & ")"
          testsFailed += 1

proc runReportTests(dir, label: string) =
  if not dirExists(dir):
    return
  var paths: seq[string]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".nifty"):
      paths.add path
  paths.sort()
  for path in paths:
    if path.extractFilename().startsWith("_"):
      continue
    let testName = path.extractFilename().changeFileExt("")
    let expectedPath = path.changeFileExt(".txt")
    if not fileExists(expectedPath):
      echo "  SKIP: " & label & "/" & testName & " (no .txt file)"
      continue
    let expected = readFile(expectedPath).replace("\r\n", "\n").strip()
    try:
      let actual = reportFor(readFile(path), path.extractFilename,
        path.parentDir).strip()
      if actual == expected:
        echo "  PASS: " & label & "/" & testName
        testsPassed += 1
      else:
        echo "  FAIL: " & label & "/" & testName
        echo "    Expected: " & firstLine(expected) & "..."
        echo "    Actual:   " & firstLine(actual) & "..."
        testsFailed += 1
    except NiftyError as e:
      echo "  FAIL: " & label & "/" & testName
      echo "    Compile error: " & e.msg
      testsFailed += 1

proc runGoldMasterTests*(): tuple[passed: int, failed: int] =
  testsPassed = 0
  testsFailed = 0

  let baseDir = currentSourcePath().parentDir()
  let workDir = getTempDir() / "nifty_gold_tests"
  createDir(workDir)

  echo "Gold master tests:"
  runTestsInDir(baseDir / "scripts", "scripts", tmRun, workDir)
  runTestsInDir(baseDir / "errors", "errors", tmCompileError, workDir)
  runTestsInDir(baseDir / "syntax", "syntax", tmCompileError, workDir)
  runTestsInDir(baseDir / "runtime", "runtime", tmRuntimeTrap, workDir)
  runReportTests(baseDir / "reports", "reports")

  (testsPassed, testsFailed)

when isMainModule:
  let (passed, failed) = runGoldMasterTests()
  echo ""
  echo "TOTAL: " & $passed & " passed, " & $failed & " failed"
  if failed > 0:
    echo "FAILED"
    quit(1)
  else:
    echo "ALL TESTS PASSED"

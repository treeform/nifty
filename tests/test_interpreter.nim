## End-to-end direct IR interpreter conformance, without a compiler in PATH.
## Run: nim r tests/test_interpreter.nim /absolute/path/to/nifty [--opt:none|speed]
import
  std/[algorithm, os, osproc, sha1, streams, strtabs, strutils, times]
import fixtures

type
  Result = tuple[output: string, code: int]
  Snapshot = seq[tuple[path, hash: string]]

proc drain(input: tuple[stream: Stream, output: ptr string]) {.thread.} =
  ## Drains output concurrently while the parent enforces a deadline.
  input.output[] = input.stream.readAll()

proc run(compiler, source, optimization, work: string): Result =
  ## Executes a source file without compiler tools on the executable path.
  var environment = newStringTable(
    when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for key, value in envPairs():
    environment[key] = value
  environment["PATH"] = ""
  let process = startProcess(compiler, workingDir = work,
    args = @["interpret", source, optimization], env = environment,
    options = {poStdErrToStdOut})
  defer: process.close()
  # Drain concurrently so output larger than a pipe buffer cannot deadlock.
  var reader: Thread[tuple[stream: Stream, output: ptr string]]
  createThread(reader, drain, (process.outputStream, addr result.output))
  result.code = process.waitForExit(60_000)
  if result.code == -1:
    process.kill()
    discard process.waitForExit()
  joinThread(reader)

proc normalized(value: string): string =
  ## Matches golden files while preserving meaningful internal whitespace.
  value.replace("\r\n", "\n").strip()

proc snapshot(directory: string): Snapshot =
  ## Records every file to detect source changes and generated artifacts.
  for path in walkDirRec(directory):
    result.add (path.relativePath(directory), $secureHashFile(path))
  result.sort(proc(a, b: tuple[path, hash: string]): int = cmp(a.path, b.path))

proc copySources(source, destination: string) =
  ## Copies read-only sources while preserving their relative import paths.
  createDir(destination)
  for kind, path in walkDir(source):
    if kind == pcFile and path.endsWith(".nifty"):
      let target = destination / path.extractFilename
      copyFile(path, target)
      setFilePermissions(target, {fpUserRead, fpGroupRead, fpOthersRead})

proc main() =
  ## Checks the full corpus and runtime services in each optimization mode.
  const Usage = "Usage: test_interpreter /absolute/path/to/nifty [--opt:none|speed]"
  if paramCount() notin 1 .. 2:
    quit(Usage, 1)
  var optimizations = @["--opt:none", "--opt:speed"]
  if paramCount() == 2:
    if paramStr(2) notin optimizations:
      quit(Usage, 1)
    optimizations = @[paramStr(2)]
  let
    compiler = absolutePath(paramStr(1))
    root = currentSourcePath().parentDir
    work = getTempDir() / ("nifty_interpreter_tests_" & $getCurrentProcessId() &
      "_" & $int(epochTime()))
  doAssert fileExists(compiler), "Compiler does not exist: " & compiler
  createDir(work)
  for group in ["scripts", "native", "runtime", "errors", "syntax"]:
    copySources(root / group, work / group)
  copySources(root.parentDir / "examples", work / "examples")
  copySources(root.parentDir / "lib", work / "lib")
  let binarySource = work / "binary_output.nifty"
  writeFile(binarySource, "thread main() =\n  echo \"a\\0b\\r\\nc\\nd\"\n")
  setFilePermissions(binarySource, {fpUserRead, fpGroupRead, fpOthersRead})
  let libcSource = work / "libc_copy.nifty"
  writeFile(libcSource, """type Pointer = opaque
extern "libc":
  proc strlen(text: string[8]): int64
  proc copy "memcpy"(target: var string[8] boundedBy count, source: string[8] boundedBy count, count: int64): Pointer
thread main() =
  echo strlen("ab\0cd")
  var target: string[8]
  discard copy(target, "x\0y", 3)
  target.setLen(3)
  echo target
""")
  setFilePermissions(libcSource, {fpUserRead, fpGroupRead, fpOthersRead})
  let initial = snapshot(work)
  var passed, failed, skipped: int
  for optimization in optimizations:
    for group in ["scripts", "native", "runtime", "errors", "syntax"]:
      var paths: seq[string]
      for kind, path in walkDir(work / group):
        if kind == pcFile and not path.extractFilename.startsWith("_"):
          paths.add path
      paths.sort()
      for path in paths:
        let label = optimization & "/" & group & "/" & path.extractFilename
        if not supportsFixture(path):
          echo "SKIP ", label, ": fixture requires another operating system"
          inc skipped
          continue
        let golden = root / group / path.extractFilename.changeFileExt(".txt")
        doAssert fileExists(golden), "Missing golden: " & golden
        let expected = normalized(readFile(golden))
        let executed = run(compiler, path, optimization, work)
        var actual = normalized(executed.output)
        if group in ["errors", "syntax"]:
          actual = actual.replace(expandFilename(path.parentDir) & DirSep, "")
            .replace(path.parentDir & DirSep, "")
          actual.removePrefix("nifty: ")
        let matches = if group in ["errors", "syntax"]:
            executed.code notin [0, -1] and actual == expected
          elif group == "runtime":
            executed.code notin [0, -1] and expected in actual
          else:
            executed.code == 0 and actual == expected
        if matches:
          inc passed
        else:
          inc failed
          echo "FAIL ", label, " (exit=", executed.code, ")"
          echo "Expected:\n", expected, "\nActual:\n", actual
    let binary = run(compiler, binarySource, optimization, work)
    if binary.code == 0 and binary.output == "a\0b\r\nc\nd\n":
      inc passed
    else:
      inc failed
      echo "FAIL ", optimization, "/binary output (exit=", binary.code, ")"
    let copied = run(compiler, libcSource, optimization, work)
    if copied.code == 0 and copied.output == "2\nx\0y\n":
      inc passed
    else:
      inc failed
      echo "FAIL ", optimization, "/libc strlen/memcpy (exit=", copied.code,
        ")\n", copied.output
    for repeated in 1 .. 3:
      for name in ["channels", "thread_count"]:
        let executed = run(compiler, work / "scripts" / (name & ".nifty"),
          optimization, work)
        let expected = normalized(readFile(root / "scripts" / (name & ".txt")))
        if executed.code == 0 and normalized(executed.output) == expected:
          inc passed
        else:
          inc failed
          echo "FAIL ", optimization, "/", name, " repeat ", repeated,
            " (exit=", executed.code, ")\n", executed.output
    for example in ["json_parser", "snappy"]:
      let executed = run(compiler, work / "examples" / (example & ".nifty"),
        optimization, work)
      let matches = if example == "json_parser":
          "object with 7 fields" in executed.output and
          "integer value 42" in executed.output and
          "array with 3 children" in executed.output and
          "JSON error at byte " in executed.output
        else:
          "Round trip: true" in executed.output and
          "Snappy in Nifty!" in executed.output
      if executed.code == 0 and matches:
        inc passed
      else:
        inc failed
        echo "FAIL ", optimization, "/examples/", example,
          " (exit=", executed.code, ")\n", executed.output
    # Failure paths and successful programs alike must preserve every source and
    # leave no generated C, IR, executable, cache, or other file beside them.
    if snapshot(work) == initial:
      inc passed
    else:
      inc failed
      echo "FAIL ", optimization, ": source changed or interpreter emitted files"
  echo "Interpreter tests: ", passed, " passed, ", failed, " failed, ",
    skipped, " platform skips"
  if failed > 0:
    echo "Fixtures retained at ", work
    quit(1)
  for path in walkDirRec(work):
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  removeDir(work)

main()

## Exercise ordinary library functions through both compiler backends.
## Run: nim r tests/test_io.nim path/to/nifty
import std/[os, osproc, streams, strutils]
import ../src/nifty/ctoolchains

proc enforceDeadline(process: Process) {.thread.} =
  if process.waitForExit(30_000) == -1:
    process.kill()
    discard process.waitForExit()

proc captureBinary(path: string): tuple[output: string, exitCode: int] =
  let process = startProcess(path, options = {poStdErrToStdOut})
  var watcher: Thread[Process]
  createThread(watcher, enforceDeadline, process)
  result.output = process.outputStream.readAll()
  joinThread(watcher)
  result.exitCode = process.peekExitCode()
  process.close()

const Source = """
import io

extern "libc":
  proc terminate "exit"(code: int32)

proc exercise(): bool =
  if openRead("missing-directory/no-file").ok:
    return false
  if openWrite("missing-directory/no-file").ok:
    return false
  var text: string
  for i in 0 ..< 9001:
    if not text.addByte(i % 251):
      return false
  var path: string[32] = "roundtrip"
  path.add(".bin")
  let converted = path.toCString()
  if not converted.ok:
    return false
  let output = openWrite(converted)
  if not output.ok:
    return false
  let wrote = writeFile(output, text)
  let closedOutput = close(output)
  if not wrote or not closedOutput:
    return false
  let input = openRead("roundtrip.bin")
  if not input.ok:
    return false
  var result: string
  var small: string[17]
  let first = readChunk(input, small)
  if not first.ok:
    discard close(input)
    return false
  if first != 17:
    discard close(input)
    return false
  if not result.add(small):
    discard close(input)
    return false
  var finished = false
  for attempt in 0 ..< 5:
    var chunk: string
    let got = readChunkGrow(input, chunk)
    if not got.ok:
      break
    if got == 0:
      finished = true
      break
    if not result.add(chunk):
      break
  var previous: string
  if not previous.add("previous"):
    discard close(input)
    return false
  let eof = readChunkGrow(input, previous)
  if not eof.ok:
    discard close(input)
    return false
  if eof != 0 or previous.len != 8 or not previous.startsWith("previous"):
    discard close(input)
    return false
  let closedInput = close(input)
  if not finished or not closedInput or result.len != text.len:
    return false
  return write(result)

proc errors(): bool =
  var invalid: string[32] = "bad"
  invalid.addByte(0)
  let converted = invalid.toCString()
  if converted.ok:
    return false
  let output = openWrite("errors.bin")
  if not output.ok:
    return false
  var chunk: string[8192]
  let got = readChunk(output, chunk)
  let closedOutput = close(output)
  if got.ok or not closedOutput:
    return false
  let failedRead = openWrite("read-error.bin")
  if not failedRead.ok:
    return false
  var unchanged: string
  if not unchanged.add("previous"):
    discard close(failedRead)
    return false
  let readError = readChunkGrow(failedRead, unchanged)
  let closedError = close(failedRead)
  if readError.ok or unchanged.len != 8 or not unchanged.startsWith("previous") or not closedError:
    return false
  let input = openRead("errors.bin")
  if not input.ok:
    return false
  let wrote = writeFile(input, "cannot-write")
  let closedInput = close(input)
  return not wrote and closedInput

thread main() =
  if not exercise() or not errors():
    terminate(17)
"""

doAssert paramCount() <= 1, "usage: test_io [path/to/nifty]"
let compiler = if paramCount() == 1: absolutePath(paramStr(1))
  else: currentSourcePath().parentDir.parentDir / "nifty" &
    (when defined(windows): ".exe" else: "")
let directory = getTempDir() / ("nifty-io-" & $getCurrentProcessId())
createDir(directory)
let previousDirectory = getCurrentDir()
try:
  setCurrentDir(directory)
  writeFile("main.nifty", Source)
  var expected = newString(9001)
  for index in 0 ..< expected.len:
    expected[index] = char(index mod 251)
  for backend in ["c", when defined(arm64): "arm64" else: "amd64"]:
    for optimization in ["none", "speed"]:
      let binary = directory / ("program" &
        (when defined(windows): ".exe" else: ""))
      if backend == "c":
        let source = directory / "program.c"
        let emit = execCmdEx(quoteShellCommand(@[compiler, "build",
          "main.nifty", "--emit-c", "-o", source]))
        doAssert emit.exitCode == 0, emit.output
        let build = execCmdEx(cCompileCommand(source, binary,
          options = @[(if optimization == "none": "-O0" else: "-O2")]))
        doAssert build.exitCode == 0, build.output
      else:
        let build = execCmdEx(quoteShellCommand(@[compiler, "build",
          "main.nifty", "--backend:" & backend, "--opt:" & optimization,
          "-o", binary]))
        doAssert build.exitCode == 0, build.output
      let execution = captureBinary(binary)
      doAssert execution.exitCode == 0, execution.output
      doAssert execution.output == expected,
        backend & "/" & optimization & ": stdout bytes differ"
      doAssert readFile("roundtrip.bin") == expected
  # The installed compiler and library travel together; no working-directory
  # assumptions are needed for the conventional prefix/bin + prefix/lib layout.
  let distribution = directory / "distribution"
  createDir(distribution / "bin")
  createDir(distribution / "lib" / "nifty")
  let relocated = distribution / "bin" / compiler.extractFilename
  copyFile(compiler, relocated)
  for kind, path in walkDir(currentSourcePath().parentDir.parentDir / "std"):
    if kind == pcFile:
      copyFile(path, distribution / "lib" / "nifty" / path.extractFilename)
  writeFile(distribution / "lib" / "nifty" / "installation_probe.nifty",
    "const InstallationProbe = 73\n")
  writeFile("relocated.nifty", "import installation_probe\n" & Source)
  let relocatedBuild = execCmdEx(quoteShellCommand(@[relocated, "build",
    "relocated.nifty", "--backend:c", "-o", directory / "relocated-program" &
    (when defined(windows): ".exe" else: "")]))
  doAssert relocatedBuild.exitCode == 0, relocatedBuild.output
  writeFile("unsafe-size.nifty", """
import io
thread main() =
  let file = openRead("roundtrip.bin")
  if file.ok:
    var buffer: string[IoChunkSize]
    discard ioRead(buffer, 2, 1, file)
    discard close(file)
""")
  let rejected = execCmdEx(quoteShellCommand(@[compiler, "build",
    "unsafe-size.nifty", "--emit-c", "-o", directory / "unsafe.c"]))
  doAssert rejected.exitCode != 0, "fread element size must remain one"
  doAssert "fits" in rejected.output, rejected.output
finally:
  setCurrentDir(previousDirectory)
  removeDir(directory)

echo "FFI console and file I/O checks passed"

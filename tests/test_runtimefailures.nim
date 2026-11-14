## Checks thread startup rollback and stdout failure diagnostics.
import std/[os, osproc, streams, strutils]
import ../src/nifty
import ../src/nifty/[ctoolchains, lowering, nativeplatforms,
  nativeruntime]

if tryRunEmbedded():
  quit(0)

const
  StartupSource = """
var queue: channel[1, int]
thread consumer() =
  echo queue.recv()
thread producer() =
  queue.send(42)
"""
  OutputSource = """
thread main() =
  var binary: string
  discard binary.add("a")
  discard binary.addByte(0)
  discard binary.add("b")
  echo 123
  echo "text"
  echo binary
"""
  PipeSource = """
thread main() =
  var binary: string
  discard binary.add("a")
  discard binary.addByte(0)
  discard binary.add("b")
  for i in 0 ..< 10000:
    echo i
    echo "text"
    echo binary
"""

var
  startAttempts = 0
  failAt = -1

proc injectedStart(handle: var ThreadHandle, start: NativeThreadStart,
    argument: pointer): cint =
  ## Fails exactly one requested OS thread creation for rollback tests.
  let attempt = startAttempts
  inc startAttempts
  if attempt == failAt:
    return 1
  startNativeThread(handle, start, argument)

let target = when defined(arm64): Arm64Target else: Amd64Target
let checked = checkedModule(StartupSource, "startup.nifty")
let program = buildNativeProgram(lowerNative(checked, "startup"), target)
for index in [0, 1]:
  startAttempts = 0
  failAt = index
  var failed = false
  try:
    runNative(program, startThread = injectedStart)
  except NiftyError as error:
    failed = "cannot start native thread" in error.msg
  doAssert failed
  doAssert startAttempts == index + 1

let directory = getTempDir() / "nifty-runtime-failures-" &
  $getCurrentProcessId()
createDir(directory)
try:
  let
    source = directory / "startup.c"
    executable = directory / ("startup" &
      (when defined(windows): ".exe" else: ""))
  writeFile(source, compileToC(StartupSource, "startup.nifty"))
  for index in [0, 1]:
    let build = execCmdEx(cCompileCommand(source, executable,
      options = @["-std=c99", "-DNIFTY_TEST_THREAD_FAIL_AT=" & $index]))
    doAssert build.exitCode == 0, build.output
    let execution = execCmdEx(quoteShell(executable))
    doAssert execution.exitCode != 0
    doAssert execution.output.strip() == "nifty: failed to start thread"
  for backend in ["c", "native"]:
    let
      binary = directory / (backend &
        (when defined(windows): ".exe" else: ""))
      pipeBinary = directory / (backend & "-pipe" &
        (when defined(windows): ".exe" else: ""))
    for item in [(OutputSource, binary), (PipeSource, pipeBinary)]:
      let (sourceText, path) = item
      if backend == "c":
        let cPath = path & ".c"
        writeFile(cPath, compileToC(sourceText, "output.nifty"))
        let build = execCmdEx(cCompileCommand(cPath, path,
          options = @["-std=c99"]))
        doAssert build.exitCode == 0, build.output
      else:
        let checkedOutput = checkedModule(sourceText, "output.nifty")
        let outputProgram = buildNativeProgram(
          lowerNative(checkedOutput, "output"), target)
        writeStandalone(outputProgram, path)
    let child = startProcess(pipeBinary, options = {})
    outputStream(child).close()
    let status = waitForExit(child, 5000)
    doAssert status != 0 and status != -1,
      backend & " closed pipe status " & $status
    let diagnostic = errorStream(child).readAll()
    doAssert "nifty: stdout write failed" in diagnostic, diagnostic
    close(child)
    when not defined(windows):
      let diagnosticPath = directory / (backend & "-flush.txt")
      let command = "exec 1>&-; exec " & quoteShell(binary) &
        " 2> " & quoteShell(diagnosticPath)
      let flushed = execCmdEx("sh -c " & quoteShell(command))
      doAssert flushed.exitCode != 0
      doAssert "nifty: stdout write failed" in
        readFile(diagnosticPath)
finally:
  removeDir(directory)
echo "Runtime failure handling passed"

## Checks thread startup rollback and stdout failure diagnostics.
import std/[os, osproc, strutils]
when defined(windows):
  import std/winlean
else:
  import std/streams
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

when defined(windows):
  proc closeWinHandle(handle: var winlean.Handle) =
    ## Closes one owned Windows handle exactly once.
    if handle != 0 and handle != INVALID_HANDLE_VALUE:
      doAssert winlean.closeHandle(handle) != 0
      handle = 0

  proc runBrokenPipe(executable: string): tuple[status: int,
      diagnostic: string] =
    ## Starts a child with an inherited stdout pipe that has no reader.
    var
      attributes = SECURITY_ATTRIBUTES(
        nLength: int32(sizeof(SECURITY_ATTRIBUTES)), bInheritHandle: 1)
      inputRead, inputWrite: winlean.Handle
      outputRead, outputWrite: winlean.Handle
      errorRead, errorWrite: winlean.Handle
      process: PROCESS_INFORMATION
    try:
      doAssert createPipe(inputRead, inputWrite, attributes, 0) != 0
      doAssert createPipe(outputRead, outputWrite, attributes, 0) != 0
      doAssert createPipe(errorRead, errorWrite, attributes, 0) != 0
      closeWinHandle(inputWrite)
      closeWinHandle(outputRead)
      var startup = STARTUPINFO(
        cb: int32(sizeof(STARTUPINFO)),
        dwFlags: STARTF_USESTDHANDLES,
        hStdInput: inputRead,
        hStdOutput: outputWrite,
        hStdError: errorWrite)
      let
        application = newWideCString(executable)
        command = newWideCString(quoteShellWindows(executable))
      doAssert createProcessW(application, command, nil, nil, 1,
        NORMAL_PRIORITY_CLASS, nil, nil, startup, process) != 0
      closeWinHandle(inputRead)
      closeWinHandle(outputWrite)
      closeWinHandle(errorWrite)
      let waited = waitForSingleObject(process.hProcess, 5000)
      if waited == WAIT_TIMEOUT:
        discard terminateProcess(process.hProcess, 1)
        discard waitForSingleObject(process.hProcess, 5000)
      doAssert waited == WAIT_OBJECT_0,
        "broken pipe child exceeded five seconds"
      var code: int32
      doAssert getExitCodeProcess(process.hProcess, code) != 0
      result.status = int(code)
      var buffer: array[512, char]
      while true:
        var count: int32
        if winlean.readFile(errorRead, addr buffer[0],
            int32(buffer.len), addr count, nil) == 0 or count == 0:
          break
        for i in 0 ..< int(count):
          result.diagnostic.add buffer[i]
    finally:
      closeWinHandle(inputRead)
      closeWinHandle(inputWrite)
      closeWinHandle(outputRead)
      closeWinHandle(outputWrite)
      closeWinHandle(errorRead)
      closeWinHandle(errorWrite)
      closeWinHandle(process.hThread)
      closeWinHandle(process.hProcess)

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
    let (status, diagnostic) = when defined(windows):
        runBrokenPipe(pipeBinary)
      else:
        block:
          let child = startProcess(pipeBinary, options = {})
          outputStream(child).close()
          let status = waitForExit(child, 5000)
          let diagnostic = errorStream(child).readAll()
          close(child)
          (status, diagnostic)
    doAssert status != 0 and status != -1,
      backend & " closed pipe status " & $status
    doAssert "nifty: stdout write failed" in diagnostic, diagnostic
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

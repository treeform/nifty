## Checks Windows CLI output paths and direct execution of PE files.
import std/[os, osproc, streams, strutils]

when defined(windows):
  if paramCount() != 1:
    quit("Usage: test_windowscli /absolute/path/to/nifty.exe", 1)
  let compiler = absolutePath(paramStr(1))
  let work = getTempDir() / ("nifty CLI " & $getCurrentProcessId())
  createDir(work)
  try:
    let source = work / "hello.nifty"
    writeFile(source, "thread main() =\n  echo \"Windows CLI passed\"\n")
    for backend in ["c", "amd64"]:
      for suffix in ["", ".exe", ".bin"]:
        # Native PE files may have any explicit suffix; GCC supplies .exe.
        if backend == "c" and suffix == ".bin":
          continue
        let output = work / (backend & " output" & suffix)
        let process = startProcess(compiler,
          args = @[source, "--backend:" & backend, "-o", output],
          options = {poStdErrToStdOut})
        let status = process.waitForExit(30_000)
        if status == -1:
          process.kill()
          discard process.waitForExit()
        let text = process.outputStream.readAll()
        process.close()
        doAssert status == 0, text
        doAssert "Windows CLI passed" in text, text
        doAssert fileExists(output & (if suffix.len == 0: ".exe" else: ""))
  finally:
    removeDir(work)
  echo "Windows CLI paths and execution passed"

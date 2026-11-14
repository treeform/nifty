## Explicit operating system requirements for binary FFI golden fixtures.
import std/[os, osproc, streams, strutils]

proc runFixture*(path: string): tuple[output: string, exitCode: int] =
  ## Captures binary output without treating embedded zero bytes as lines.
  let process = startProcess(absolutePath(path), options = {poStdErrToStdOut})
  defer: process.close()
  result.exitCode = process.waitForExit(30_000)
  if result.exitCode == -1:
    process.kill()
    discard process.waitForExit()
  result.output = process.outputStream.readAll()

proc supportsFixture*(path: string): bool =
  ## Checks an optional platform marker without changing language semantics.
  for line in readFile(path).splitLines():
    if line.startsWith("# platforms:"):
      let platforms = line[12 .. ^1].splitWhitespace()
      when defined(windows):
        return "windows" in platforms
      elif defined(macosx):
        return "macosx" in platforms or "posix" in platforms
      else:
        return "linux" in platforms or "posix" in platforms
    if not line.startsWith("#") and line.strip().len > 0:
      break
  true

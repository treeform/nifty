## Checks empty sources without relying on libc accepting null byte pointers.
import
  std/[os, osproc, strutils],
  ../src/nifty, ../src/nifty/ctoolchains, fixtures

const MemoryHooks = """
#include <stdlib.h>
#include <string.h>
static void *ni_checked_copy(void *to, const void *from, size_t count) {
  if (to == NULL || from == NULL) abort();
  return memcpy(to, from, count);
}
static int ni_checked_compare(const void *a, const void *b, size_t count) {
  if (a == NULL || b == NULL) abort();
  return memcmp(a, b, count);
}
#define memcpy ni_checked_copy
#define memcmp ni_checked_compare
"""

proc main() =
  ## Exercises the C library pointer contract even when the byte count is zero.
  let
    root = currentSourcePath().parentDir
    fixture = root / "native" / "empty_strings.nifty"
    work = getTempDir() / ("nifty_empty_strings_" & $getCurrentProcessId())
    source = work / "empty_strings.c"
    binary = work / ("empty_strings" &
      (when defined(windows): ".exe" else: ""))
  createDir(work)
  defer:
    removeDir(work)
  writeFile(source, MemoryHooks & compileToC(readFile(fixture), fixture))
  let build = execCmdEx(cCompileCommand(source, binary))
  doAssert build.exitCode == 0, build.output
  let execution = runFixture(binary)
  doAssert execution.exitCode == 0, execution.output
  doAssert execution.output.replace("\r\n", "\n").strip() ==
    readFile(fixture.changeFileExt("txt")).replace("\r\n", "\n").strip()
  echo "Empty string memory contracts passed"

main()

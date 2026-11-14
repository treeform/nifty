## Compile and execute ownership regressions with allocator instrumentation.

import
  std/[algorithm, os, osproc, strutils],
  ../src/nifty

const AllocatorHooks = """
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static pthread_mutex_t probe_mutex = PTHREAD_MUTEX_INITIALIZER;
static int64_t probe_live = 0;
static int64_t probe_fail_after = -1;
static int probe_registered = 0;
static void probe_check_exit(void) {
  if (probe_live != 0) {
    fprintf(stderr, "live allocations at exit: %lld\n",
      (long long)probe_live);
    abort();
  }
}
static void *probe_realloc(void *pointer, size_t size) {
  pthread_mutex_lock(&probe_mutex);
  if (!probe_registered) {
    assert(atexit(probe_check_exit) == 0);
    probe_registered = 1;
  }
  assert(size != 0);
  if (probe_fail_after == 0) {
    probe_fail_after = -1;
    pthread_mutex_unlock(&probe_mutex);
    return NULL;
  }
  if (probe_fail_after > 0) --probe_fail_after;
  const int fresh = pointer == NULL;
  void *result = realloc(pointer, size);
  if (result && fresh) ++probe_live;
  pthread_mutex_unlock(&probe_mutex);
  return result;
}
static void probe_free(void *pointer) {
  if (!pointer) return;
  pthread_mutex_lock(&probe_mutex);
  assert(probe_live > 0);
  --probe_live;
  free(pointer);
  pthread_mutex_unlock(&probe_mutex);
}
int64_t probeExpect(int64_t expected) {
  pthread_mutex_lock(&probe_mutex);
  if (probe_live != expected) {
    fprintf(stderr, "expected %lld live allocations, got %lld\n",
      (long long)expected, (long long)probe_live);
    abort();
  }
  pthread_mutex_unlock(&probe_mutex);
  return 1;
}
void probeFailAfter(int64_t attempts) {
  pthread_mutex_lock(&probe_mutex);
  probe_fail_after = attempts;
  pthread_mutex_unlock(&probe_mutex);
}
int64_t probeFill(uint8_t *data, int64_t capacity) {
  assert(capacity >= 3);
  memcpy(data, "ffi", 3);
  return 3;
}
#define NIFTY_REALLOC(pointer, bytes) probe_realloc(pointer, bytes)
#define NIFTY_FREE(pointer) probe_free(pointer)
"""

const CleanupSource = """
extern "libc":
  proc expect "probeExpect"(count: int64): int64

proc leave(): int =
  var first: string
  if not first.add("A"):
    return 0
  discard expect(1)
  block:
    var second: string
    if not second.add("B"):
      return 0
    discard expect(2)
    return first.get(0).or(0) + second.get(0).or(0)

proc work() =
  discard expect(0)
  echo leave()
  discard expect(0)
  block:
    var outer: string
    if not outer.add("outer"):
      return
    for i in 0 ..< 3:
      var inner: string
      if not inner.addNum(i):
        return
      discard expect(2)
      if i == 1:
        break
    discard expect(1)
    echo outer
  discard expect(0)
  echo "cleanup ok"

thread main() =
  work()
"""

const FailureSource = """
extern "libc":
  proc failAfter "probeFailAfter"(attempts: int64)
  proc expect "probeExpect"(count: int64): int64

proc growFailure(): bool =
  var text: string
  if not text.add("keep"):
    return false
  let capacity = text.cap
  failAfter(0)
  if text.reserve(1000000):
    return false
  if text.cap != capacity or text.len != 4:
    return false
  if not text.startsWith("keep"):
    return false
  if not text.add("!"):
    return false
  var numbers: seq[int]
  if not numbers.push(42):
    return false
  if numbers.reserve(9223372036854775807):
    return false
  return numbers.get(0).or(0) == 42 and text.endsWith("!")

proc copyFailure(): bool =
  var source: seq[string]
  if not source.resize(2):
    return false
  if source.len >= 2:
    if not source[0].add("first"):
      return false
  if source.len >= 2:
    if not source[1].add("second"):
      return false
  var output: seq[string]
  if not output.resize(1):
    return false
  if output.len >= 1:
    if not output[0].add("old"):
      return false
  for failure in 0 ..< 3:
    failAfter(failure)
    let copied = output.copyFrom(source)
    failAfter(-1)
    if copied:
      return false
    if output.len != 1:
      return false
    if output.len == 1:
      if not output[0].startsWith("old"):
        return false
    discard expect(5)
  if not output.copyFrom(source):
    return false
  source.clear()
  if output.len != 2:
    return false
  if output.len == 2:
    return output[0].startsWith("first") and output[1].endsWith("second")
  return false

thread main() =
  echo growFailure()
  discard expect(0)
  echo copyFailure()
  discard expect(0)
"""

const GlobalSource = """
var text: string
var textLock: Lock
var ready: channel[1, int]

thread writer() =
  with textLock:
    discard text.add("global")
  ready.send(1)

thread reader() =
  let signal = ready.recv()
  with textLock:
    echo text, " ", signal
"""

const ForeignSource = """
extern "libc":
  proc fill "probeFill"(text: var string, capacity: int64): int64

proc work() =
  var text: string
  if not text.reserve(16):
    return
  let capacity = text.cap
  let count = fill(text, capacity)
  if count >= 0 and count <= 16:
    echo text.setLen(count)
    echo text
  echo text.add("!")
  echo text

thread main() =
  work()
"""

const BinarySource = """
thread main() =
  var text: string
  discard text.add("a")
  discard text.addByte(0)
  discard text.add("b")
  echo text
"""

proc runCase(name, source, expected, workDir: string,
    sanitize: bool): bool =
  ## Run one generated C program with allocation and cleanup checks.
  let
    cPath = workDir / name & ".c"
    binary = workDir / name
  try:
    writeFile(cPath, AllocatorHooks & compileToC(source, name & ".nifty"))
  except NiftyError as error:
    echo "  FAIL: memory/", name, " (", error.msg, ")"
    return false
  let flags =
    if sanitize:
      " -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer"
    else:
      " -O2"
  let build = execCmdEx("cc -std=c99 -pthread -fno-strict-aliasing " &
    "-ffp-contract=off" & flags & " -o " & quoteShell(binary) & " " &
    quoteShell(cPath))
  if build.exitCode != 0:
    echo "  FAIL: memory/", name, " (C compiler)\n", build.output
    return false
  let execution = execCmdEx(quoteShell(binary))
  if execution.exitCode != 0 or execution.output.strip() != expected.strip():
    echo "  FAIL: memory/", name, " (exit ", execution.exitCode, ")"
    echo "    Expected: ", expected.strip()
    echo "    Actual: ", execution.output.strip()
    return false
  echo "  PASS: memory/", name
  true

proc runMemoryTests*(): tuple[passed, failed: int] =
  ## Check ownership and failure behavior, optionally under C sanitizers.
  let
    workDir = getTempDir() / ("nifty_memory_" & $getCurrentProcessId())
    sanitize = getEnv("NIFTY_SANITIZE") == "1"
  createDir(workDir)
  echo "Memory integration tests", (if sanitize: " (ASan/UBSan)" else: ""), ":"
  for test in [
    ("cleanup", CleanupSource, "131\nouter\ncleanup ok"),
    ("failure", FailureSource, "true\ntrue"),
    ("global", GlobalSource, "global 1"),
    ("foreign", ForeignSource, "true\nffi\ntrue\nffi!"),
    ("binary", BinarySource, "a\0b")
  ]:
    if runCase(test[0], test[1], test[2], workDir, sanitize):
      inc result.passed
    else:
      inc result.failed
  let scriptsDir = currentSourcePath().parentDir() / "scripts"
  var paths: seq[string]
  for path in walkFiles(scriptsDir / "memory_*.nifty"):
    paths.add path
  paths.sort()
  for path in paths:
    let name = path.extractFilename().changeFileExt("")
    if runCase(name, readFile(path), readFile(path.changeFileExt("txt")),
        workDir, sanitize):
      inc result.passed
    else:
      inc result.failed

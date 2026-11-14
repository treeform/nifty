## Checks native growable storage, allocation failure, and scoped release.
import std/[os, posix, strutils]
import ../src/nifty/[checker, loader, lowering, nativecontainers,
  nativeruntime, parser]

const
  HostTarget = when defined(arm64): Arm64Target else: Amd64Target
  FailedGrowth = """
thread main() =
  var text: string
  echo text.add("first")
  echo text.len
  echo text.add("next")
  echo text
"""
  CopySource = """
proc work() =
  var source: seq[string]
  if not source.resize(2):
    echo "setup failed"
    return
  if source.len == 2:
    if not source[0].add("first"):
      echo "setup failed"
      return
  if source.len == 2:
    if not source[1].add("second"):
      echo "setup failed"
      return
  var output: seq[string]
  if not output.resize(1):
    echo "setup failed"
    return
  if output.len == 1:
    if not output[0].add("old"):
      echo "setup failed"
      return
  echo output.copyFrom(source)
  echo output.len
  if output.len == 1:
    echo output[0]
  if output.len == 2:
    echo output[0], " ", output[1]

thread main() =
  work()
"""
  GlobalSource = """
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
  ForeignSource = """
extern "libc":
  proc fill "memset"(text: var string, value: int32, count: uint64): int64

proc work() =
  var text: string
  if not text.reserve(16):
    return
  discard fill(text, 102, 3)
  echo text.setLen(3)
  echo text
  echo text.add("!")
  echo text

thread main() =
  work()
"""
  BinarySource = """
thread main() =
  var text: string
  discard text.add("a")
  discard text.addByte(0)
  discard text.add("b")
  echo text
"""

var
  liveAllocations = 0
  allocationAttempts = 0
  failedAllocations = 0
  failAfter = -1

proc cRealloc(address: pointer, bytes: csize_t): pointer
    {.importc: "realloc", header: "<stdlib.h>".}
proc cFree(address: pointer) {.importc: "free", header: "<stdlib.h>".}
proc flushAll(stream: pointer): cint
    {.importc: "fflush", header: "<stdio.h>".}

proc trackedRealloc(address: pointer, bytes: csize_t): pointer {.cdecl.} =
  ## Injects one allocation failure while counting live payloads.
  inc allocationAttempts
  if failAfter == 0:
    failAfter = -1
    inc failedAllocations
    return nil
  if failAfter > 0:
    dec failAfter
  result = cRealloc(address, bytes)
  if address == nil and result != nil:
    inc liveAllocations

proc trackedFree(address: pointer) {.cdecl.} =
  ## Counts each final payload release, including global owners.
  if address == nil:
    return
  doAssert liveAllocations > 0
  dec liveAllocations
  cFree(address)

proc capture(program: NativeProgram, name: string): string =
  ## Captures C stdout from threads while running with allocator hooks.
  let path = getTempDir() / ("nifty_native_memory_" &
    $getCurrentProcessId() & "_" & name & ".txt")
  let output = open(path, fmWrite)
  let saved = dup(1)
  doAssert saved >= 0
  doAssert flushAll(nil) == 0
  doAssert dup2(cint(getFileHandle(output)), 1) >= 0
  try:
    runNative(program, NativeMemory(reallocate: trackedRealloc,
      release: trackedFree))
  finally:
    doAssert flushAll(nil) == 0
    doAssert dup2(saved, 1) >= 0
    doAssert close(saved) == 0
    output.close()
  result = readFile(path).replace("\r\n", "\n").strip()
  removeFile(path)

proc runSource(source, name: string, failure = -1): string =
  ## Compiles checked source and verifies all owned payloads are released.
  let checked = parse(loadTokens(source, name & ".nifty", ""))
  check(checked)
  let program = buildNativeProgram(lowerNative(checked, name), HostTarget)
  liveAllocations = 0
  allocationAttempts = 0
  failedAllocations = 0
  failAfter = failure
  result = capture(program, name)
  doAssert liveAllocations == 0, name & " leaked " &
    $liveAllocations & " native payloads"

let scripts = currentSourcePath().parentDir() / "scripts"
for name in ["memory_cleanup", "memory_arena", "memory_nested",
    "memory_seqs", "memory_strings", "memory_large",
    "memory_large_get", "memory_generics"]:
  let expected = readFile(scripts / name & ".txt").strip()
  doAssert runSource(readFile(scripts / name & ".nifty"), name) ==
    expected, name
  doAssert allocationAttempts > 0, name

doAssert runSource(FailedGrowth, "failed_growth", 0) ==
  "false\n0\ntrue\nnext"
doAssert failedAllocations == 1

var copyFailures = 0
for failure in 0 .. 12:
  let output = runSource(CopySource, "copy_" & $failure, failure)
  if output == "false\n1\nold":
    inc copyFailures
  else:
    doAssert output in ["setup failed", "true\n2\nfirst second"],
      "copy failure " & $failure & ": " & output
doAssert copyFailures >= 2, "Deep copy did not encounter injected failures"

doAssert runSource(GlobalSource, "global") == "global 1"
doAssert runSource(ForeignSource, "foreign") ==
  "true\nfff\ntrue\nfff!"
let binary = runSource(BinarySource, "binary")
doAssert binary == "a\0b", binary.escape()

echo "Native growable memory tests passed"

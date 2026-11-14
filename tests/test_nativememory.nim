## Checks native growable storage, allocation failure, and scoped release.
import std/[os, strutils]
when defined(windows):
  proc dup(descriptor: cint): cint {.importc: "_dup", header: "<io.h>".}
  proc dup2(source, destination: cint): cint
    {.importc: "_dup2", header: "<io.h>".}
  proc close(descriptor: cint): cint {.importc: "_close", header: "<io.h>".}
else:
  import std/posix
import ../src/nifty/[checker, loader, lowering, nativecontainers,
  nativeoptimizations, nativeruntime, nativeunroll, parser]

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
  PopulatedGrowth = """
thread main() =
  var text: string
  echo text.add("keep")
  let capacity = text.cap
  echo text.reserve(1024)
  echo text.cap == capacity
  echo text.len
  echo text
  echo text.add("!")
  echo text
"""
  MovingGrowth = """
thread main() =
  var text: string
  discard text.add("keep")
  echo text.reserve(1024)
  echo text.add("!")
  echo text
  var numbers: seq[int]
  discard numbers.push(42)
  echo numbers.reserve(1024)
  echo numbers.get(0).or(0)
"""
  ScopedSource = """
proc leave(): int =
  var outer: string
  discard outer.add("A")
  block:
    var inner: string
    discard inner.add("B")
    return outer.get(0).or(0) + inner.get(0).or(0)

thread main() =
  echo leave()
  for i in 0 ..< 3:
    var temporary: string
    discard temporary.addNum(i)
    echo temporary
  for i in 0 ..< 3:
    var temporary: string
    discard temporary.addNum(i)
    echo temporary
    break
  block:
    var temporary: string
    discard temporary.add("sibling")
    echo temporary
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

const GuardBytes = 16

type Allocation = object
  base, payload: pointer
  bytes: int
  active: bool

var
  allocations: array[256, Allocation]
  allocationCount = 0
  liveAllocations = 0
  peakAllocations = 0
  movedAllocations = 0
  allocationAttempts = 0
  failedAllocations = 0
  failAfter = -1

proc cRealloc(address: pointer, bytes: csize_t): pointer
    {.importc: "realloc", header: "<stdlib.h>".}
proc cFree(address: pointer) {.importc: "free", header: "<stdlib.h>".}
proc flushAll(stream: pointer): cint
    {.importc: "fflush", header: "<stdio.h>".}

proc findAllocation(address: pointer): int =
  ## Rejects unknown and already released program payloads.
  for i in 0 ..< allocationCount:
    if allocations[i].payload == address:
      doAssert allocations[i].active, "Released payload reused"
      return i
  doAssert false, "Unknown program payload"

proc checkAllocation(allocation: Allocation) =
  ## Checks guards and detects writes to quarantined payloads.
  let data = cast[ptr UncheckedArray[byte]](allocation.base)
  for i in 0 ..< GuardBytes:
    doAssert data[i] == 0xa5
    doAssert data[GuardBytes + allocation.bytes + i] == 0xa5
  if not allocation.active:
    for i in 0 ..< allocation.bytes:
      doAssert data[GuardBytes + i] == 0xdd, "Write after payload release"

proc retire(index: int) =
  ## Keeps poisoned storage quarantined so stale pointers cannot alias owners.
  checkAllocation(allocations[index])
  let data = cast[ptr UncheckedArray[byte]](allocations[index].payload)
  for i in 0 ..< allocations[index].bytes:
    data[i] = 0xdd
  allocations[index].active = false
  dec liveAllocations

proc trackedRealloc(address: pointer, bytes: csize_t): pointer {.cdecl.} =
  ## Moves every successful resize and preserves old storage on failure.
  doAssert bytes > 0
  let previous = if address == nil: -1 else: findAllocation(address)
  if previous >= 0:
    checkAllocation(allocations[previous])
  inc allocationAttempts
  if failAfter == 0:
    failAfter = -1
    inc failedAllocations
    return nil
  if failAfter > 0:
    dec failAfter
  doAssert allocationCount < allocations.len
  let base = cRealloc(nil, bytes + csize_t(GuardBytes * 2))
  doAssert base != nil
  let data = cast[ptr UncheckedArray[byte]](base)
  for i in 0 ..< int(bytes) + GuardBytes * 2:
    data[i] = 0xa5
  result = addr data[GuardBytes]
  if previous >= 0:
    copyMem(result, address, min(int(bytes), allocations[previous].bytes))
    retire(previous)
    inc movedAllocations
  allocations[allocationCount] = Allocation(
    base: base, payload: result, bytes: int(bytes), active: true)
  inc allocationCount
  inc liveAllocations
  peakAllocations = max(peakAllocations, liveAllocations)

proc trackedFree(address: pointer) {.cdecl.} =
  ## Releases exactly one live payload while retaining diagnostic storage.
  if address != nil:
    retire(findAllocation(address))

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

proc runSource(source, name: string, optimization: NativeOptimization,
    failure = -1): string =
  ## Compiles the CLI optimization pipeline and checks every payload lifetime.
  let checked = parse(loadTokens(source, name & ".nifty", ""))
  check(checked)
  let
    prepared = if optimization == SpeedOptimization:
        unrollNative(checked) else: checked
    program = buildNativeProgram(lowerNative(prepared, name), HostTarget,
      optimization = optimization)
  allocationCount = 0
  liveAllocations = 0
  peakAllocations = 0
  movedAllocations = 0
  allocationAttempts = 0
  failedAllocations = 0
  failAfter = failure
  result = capture(program, name)
  doAssert liveAllocations == 0, name & " leaked " &
    $liveAllocations & " native payloads"
  for i in 0 ..< allocationCount:
    checkAllocation(allocations[i])
    cFree(allocations[i].base)

let root = currentSourcePath().parentDir().parentDir()
let scripts = root / "tests" / "scripts"
var raySource = readFile(root / "benchmarks" / "raytracer.nifty")
  .replace("const ImageSize = 64", "const ImageSize = 4")
  .replace("const ClockId = 6", when defined(macosx):
    "const ClockId = 6" else: "const ClockId = 1")
when defined(windows):
  # This test checks ownership and pixels; it does not measure render time.
  raySource = raySource.replace(
    "proc clock_gettime(clock: int32, value: var Timespec): int32",
    "proc timespecGet \"_timespec64_get\"(value: var Timespec, base: int32): int32")
    .replace("clock_gettime(ClockId, started)", "timespecGet(started, 1)")
    .replace("clock_gettime(ClockId, finished)", "timespecGet(finished, 1)")
let rayPixels = readFile(root / "benchmarks" / "reference" / "4.rgb")
for optimization in NativeOptimization:
  for name in ["memory_cleanup", "memory_arena", "memory_nested",
      "memory_seqs", "memory_strings", "memory_large",
      "memory_large_get", "memory_generics"]:
    let expected = readFile(scripts / name & ".txt").strip()
    doAssert runSource(readFile(scripts / name & ".nifty"), name,
      optimization) == expected, name
    doAssert allocationAttempts > 0, name

  doAssert runSource(FailedGrowth, "failed_growth", optimization, 0) ==
    "false\n0\ntrue\nnext"
  doAssert failedAllocations == 1
  doAssert runSource(PopulatedGrowth, "populated_failure", optimization, 1) ==
    "true\nfalse\ntrue\n4\nkeep\ntrue\nkeep!"
  doAssert failedAllocations == 1
  doAssert runSource(MovingGrowth, "moving_growth", optimization) ==
    "true\ntrue\nkeep!\ntrue\n42"
  doAssert movedAllocations >= 2
  doAssert runSource(ScopedSource, "scoped", optimization) ==
    "131\n0\n1\n2\n0\nsibling"
  doAssert peakAllocations == 2, "Owners survived their scopes"

  var copyFailures = 0
  for failure in 0 .. 12:
    let output = runSource(CopySource, "copy_" & $failure,
      optimization, failure)
    if output == "false\n1\nold":
      inc copyFailures
    else:
      doAssert output in ["setup failed", "true\n2\nfirst second"],
        "copy failure " & $failure & ": " & output
  doAssert copyFailures >= 2, "Deep copy missed injected failures"

  doAssert runSource(GlobalSource, "global", optimization) == "global 1"
  doAssert runSource(ForeignSource, "foreign", optimization) ==
    "true\nfff\ntrue\nfff!"
  let binary = runSource(BinarySource, "binary", optimization)
  doAssert binary == "a\0b", binary.escape()
  let ray = runSource(raySource, "ray_memory", optimization)
  doAssert allocationAttempts == 0, "Ray renderer allocated owned storage"
  var actualPixels = ""
  for line in ray.splitLines():
    if line.startsWith("rgb "):
      for value in line.splitWhitespace()[1 .. 3]:
        actualPixels.add(char(parseInt(value)))
  doAssert actualPixels == rayPixels, "Ray renderer pixels changed"
  echo "Native growable memory tests passed: ", optimization

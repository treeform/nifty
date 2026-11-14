## Checks native JSON trees, strict errors, and fallible ownership.
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
  Source = """
import json

proc load(text: string[128], output: var JsonNode, error: var JsonError): bool =
  var input: string
  if not input.add(text):
    return false
  return parseJson(input, output, error)

thread main() =
  var output: JsonNode
  var error: JsonError
  echo load("null", output, error) and type(output) == NullNode
  echo load("true", output, error)
  if type(output) == BoolNode:
    echo output.value
  echo load("-9223372036854775808", output, error)
  echo jsonInt(output).or(0) == (-9223372036854775807 - 1)
  echo load("9223372036854775808", output, error)
  echo not jsonInt(output).ok
  if type(output) == NumNode:
    echo output.text.startsWith("9223372036854775808") and output.text.len == 19
  echo load("-1.2300e+999999999999999999999", output, error)
  if type(output) == NumNode:
    echo output.text.startsWith("-1.2300e+999999999999999999999") and output.text.len == 30
  echo load("\"\\u0000\\ud834\\udd1e\\u00e9\"", output, error)
  if type(output) == StrNode:
    echo output.value.len == 7
    echo output.value.get(0).or(255) == 0
    echo output.value.get(1).or(0) == 240
    echo output.value.get(4).or(0) == 158
    echo output.value.get(5).or(0) == 195
    echo output.value.get(6).or(0) == 169
  echo load("{\"items\":[null,{\"n\":42},true],\"empty\":{}}", output, error)
  if type(output) == ObjNode:
    echo output.fields.len == 2
    if output.fields.len == 2:
      echo output.fields[0].name.startsWith("items") and output.fields[0].name.len == 5
      if type(output.fields[0].value) == ArrNode:
        echo output.fields[0].value.items.len == 3
        if output.fields[0].value.items.len == 3:
          echo type(output.fields[0].value.items[0]) == NullNode
          if type(output.fields[0].value.items[1]) == ObjNode:
            echo output.fields[0].value.items[1].fields.len == 1
            if output.fields[0].value.items[1].fields.len == 1:
              echo jsonInt(output.fields[0].value.items[1].fields[0].value).or(0) == 42
      if type(output.fields[1].value) == ObjNode:
        echo output.fields[1].value.fields.len == 0
  echo not load("[1,]", output, error)
  echo type(output) == NullNode and error.code == JsonSyntaxError
  echo not load("1e+", output, error)
  echo error.code == JsonNumberError
  echo not load("\"\\ud800\"", output, error)
  echo error.code == JsonUnicodeError
  echo not load("true false", output, error)
  echo type(output) == NullNode
  block:
    var input: string
    discard input.add("[[0]]")
    echo not parseJsonWithDepth(input, output, error, 1)
    echo error.code == JsonDepthError and type(output) == NullNode
    echo parseJsonWithDepth(input, output, error, 2)
  echo load("false", output, error)
  echo error.code == 0
  if type(output) == BoolNode:
    echo not output.value
"""
  FailureSource = """
import json

proc work() =
  var input: string
  if not input.add("{\"a\":[\"value\",{\"b\":123}],\"c\":false}"):
    echo "setup"
    return
  var output: JsonNode
  var error: JsonError
  if parseJson(input, output, error):
    echo type(output) == ObjNode
  else:
    echo error.code == JsonAllocationError and type(output) == NullNode
thread main() =
  work()
"""

const GuardBytes = 16

type Allocation = object
  base, payload: pointer
  bytes: int
  active: bool

var
  allocations: array[4096, Allocation]
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
  let path = getTempDir() / ("nifty_json_native_" &
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


proc compileSource(source, name: string,
    optimization: NativeOptimization): NativeProgram =
  ## Checks parser imports and builds both target instruction streams.
  let root = currentSourcePath().parentDir().parentDir()
  let checked = parse(loadTokens(source, name & ".nifty", root / "lib"))
  check(checked)
  let prepared = if optimization == SpeedOptimization:
      unrollNative(checked) else: checked
  let lowered = lowerNative(prepared, name)
  for target in [Arm64Target, Amd64Target]:
    let program = buildNativeProgram(lowered, target,
      optimization = optimization)
    if target == HostTarget:
      result = program

proc runProgram(program: NativeProgram, name: string, failure = -1): string =
  ## Runs with moving, guarded allocations and checks all releases.
  allocationCount = 0
  liveAllocations = 0
  peakAllocations = 0
  movedAllocations = 0
  allocationAttempts = 0
  failedAllocations = 0
  failAfter = failure
  result = capture(program, name)
  doAssert liveAllocations == 0, name & " leaked native payloads"
  for i in 0 ..< allocationCount:
    checkAllocation(allocations[i])
    cFree(allocations[i].base)

for optimization in NativeOptimization:
  let program = compileSource(Source, "json_native", optimization)
  let output = runProgram(program, "json_native")
  doAssert output.splitLines().len == 39, output
  for line in output.splitLines():
    doAssert line == "true", output
  let failures = compileSource(FailureSource, "json_native_failures",
    optimization)
  doAssert runProgram(failures, "json_native_failures") == "true"
  let attempts = allocationAttempts
  doAssert attempts > 10
  for failure in 0 ..< attempts:
    let output = runProgram(failures, "json_native_failures", failure)
    doAssert output in ["setup", "true"], output
    doAssert failedAllocations == 1
  echo "Native JSON tests passed: ", optimization

## Echo expands to ordinary library/FFI calls without owner allocations.
import std/[os, osproc, strutils]
when defined(windows):
  proc dup(descriptor: cint): cint {.importc: "_dup", header: "<io.h>".}
  proc dup2(source, destination: cint): cint
    {.importc: "_dup2", header: "<io.h>".}
  proc close(descriptor: cint): cint {.importc: "_close", header: "<io.h>".}
else:
  import std/posix
import ../src/nifty
import ../src/nifty/[common, types, lexer, parser, checker, codegen,
  ctoolchains, lowering, nativeruntime]

const
  Source = """
extern "libc":
  proc foreignPuts "puts"(text: string[16]): int32
proc argument(value: int): int =
  echo "arg", value
  return value
proc change(value: var int, next: int): int =
  value = next
  return next
thread main() =
  discard foreignPuts("first\0")
  echo "second"
  echo "prefix", argument(1), argument(2)
  var value: int = 0
  echo change(value, 1), " ", value, " ", change(value, 2)
  let fixed: string[16] = "a\0b"
  let zero: char = 0
  let letter: char = 65
  let single: float32 = 1.25
  echo fixed, zero, letter, " ", true, " ", false, " ", single, " ", -2.5
  echo -9223372036854775807 - 1, " ", 9223372036854775807
  echo ""
"""
  Expected = "first\nsecond\narg1\narg2\nprefix12\n1 1 2\na\0b\0A true false 1.25 -2.5\n" &
    "-9223372036854775808 9223372036854775807\n\n"
  InteropSource = """
import console
extern "libc":
  proc foreignPuts "puts"(text: string[16]): int32
thread main() =
  discard foreignPuts("first\0")
  discard write("write\n")
  discard foreignPuts("third\0")
  echo "echo"
"""
  InteropExpected = "first\nwrite\nthird\necho\n"
  AtomicSource = """
thread 4 first() =
  var text: string[9000]
  for i in 0 ..< 9000:
    if text.len < 9000:
      text.addByte(65)
  echo text, "A"
thread 4 second() =
  var text: string[9000]
  for i in 0 ..< 9000:
    if text.len < 9000:
      text.addByte(66)
  echo text, "B"
"""
  FailAllocC = """
#include <stdlib.h>
static void *forbidden_allocation(void *address, size_t bytes) {
  (void)address; (void)bytes; abort(); return NULL;
}
#define NIFTY_REALLOC(address, bytes) forbidden_allocation(address, bytes)
"""

var attempts = 0
proc failAllocation(address: pointer, bytes: csize_t): pointer {.cdecl, raises: [].} =
  inc attempts
  nil
proc forbiddenFree(address: pointer) {.cdecl, raises: [].} =
  doAssert address == nil
proc flushAll(file: pointer): cint {.importc: "fflush", header: "<stdio.h>".}

let directory = getTempDir() / ("nifty-echo-" & $getCurrentProcessId())
createDir(directory)
proc capture(program: NativeProgram): string =
  let path = directory / "native-output"
  let file = open(path, fmWrite)
  let saved = dup(1)
  doAssert saved >= 0 and flushAll(nil) == 0
  doAssert dup2(cint(getFileHandle(file)), 1) >= 0
  try:
    attempts = 0
    runNative(program, NativeMemory(reallocate: failAllocation, release: forbiddenFree))
    doAssert attempts == 0, "echo attempted an owner allocation"
  finally:
    doAssert flushAll(nil) == 0
    doAssert dup2(saved, 1) >= 0
    doAssert close(saved) == 0
    file.close()
  readFile(path)

proc assertAtomic(output: string) =
  let lines = output.splitLines()
  doAssert lines.len == 9 and lines[^1] == "", $lines.len
  var first, second: int
  for line in lines[0 ..< 8]:
    doAssert line.len == 9001
    if line[0] == 'A':
      inc first
      doAssert line == repeat('A', 9001)
    else:
      inc second
      doAssert line == repeat('B', 9001)
  doAssert first == 4 and second == 4

try:
  for (name, text) in [("values", Source), ("interop", InteropSource),
      ("atomic", AtomicSource)]:
    # These APIs intentionally bypass the facade and its import loader.
    srcFiles = @[name & ".nifty"]
    let module = if name == "interop": checkedModule(text, name & ".nifty")
      else: parse(tokenize(text))
    if name != "interop": check(module)
    let original = module.routines[0]
    let bindings = module.semantics.bindings.len
    for optimization in NativeOptimization:
      let generated = generate(module, name & ".nifty")
      doAssert "ni_extern_niftyEchoSupport_ioRawWrite" in generated
      doAssert "fwrite(" notin generated and "printf(\"%" notin generated
      let path = directory / (name & $ord(optimization))
      let cpath = path & ".c"
      let binary = path & (when defined(windows): ".exe" else: "")
      writeFile(cpath, FailAllocC & generated)
      let build = execCmdEx(cCompileCommand(cpath, binary,
        options = @["-std=c99", if optimization == NoOptimization: "-O0" else: "-O2"]))
      doAssert build.exitCode == 0, build.output
      let outputPath = path & ".txt"
      let command = quoteShell(binary) & " > " & quoteShell(outputPath)
      let execution = when defined(windows): execCmdEx("cmd /d /c " & command)
        else: execCmdEx("sh -c " & quoteShell(command))
      doAssert execution.exitCode == 0, execution.output
      let coutput = readFile(outputPath)
      let plan = lowerNative(module, name & ".nifty")
      doAssert plan.module.functions[1].name == original.name
      var foreign = false
      for host in plan.hosts:
        doAssert host.kind != ReservedHost
        foreign = foreign or (host.kind == ExternHost and
          host.symbol in ["write", "_write"])
      doAssert foreign
      let target = when defined(arm64): Arm64Target else: Amd64Target
      let program = buildNativeProgram(plan, target, optimization = optimization)
      let noutput = capture(decodeNative(encodeNative(program)))
      if name == "atomic":
        assertAtomic(coutput)
        assertAtomic(noutput)
      else:
        let expected = if name == "values": Expected else: InteropExpected
        doAssert coutput == expected, coutput.escape()
        when defined(windows):
          # Foreign puts runs before the first console write selects binary
          # descriptor mode. Its initial newline may therefore be CRLF.
          doAssert noutput in [expected, "first\r\n" & expected[6 .. ^1]],
            noutput.escape()
        else:
          doAssert noutput == expected, noutput.escape()
      doAssert module.routines[0] == original
      doAssert module.semantics.bindings.len == bindings
      doAssert srcFiles[0] == name & ".nifty"
finally:
  removeDir(directory)

echo "Ordinary FFI echo checks passed"

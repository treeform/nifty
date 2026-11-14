import std/[os, osproc]
import ../src/nifty/[common, nativeruntime]

if tryRunEmbedded():
  quit(0)

let target = when defined(arm64): Arm64Target else: Amd64Target
let bytes = when defined(arm64): @[0xc0'u8, 0x03, 0x5f, 0xd6]
  else: @[0xc3'u8]
let program = NativeProgram(platform: NativeHostPlatform,
  image: NativeImage(target: target, bytes: bytes, offsets: @[0, 0]),
  plan: NativePlan(globalBytes: 64, initialData: @[7'u8],
    lockOffsets: @[0, 8, 16, 24], channelOffsets: @[32, 40, 48, 56],
    hosts: @[NativeHost(kind: ExternHost, library: "libc", symbol: "strlen")],
    threads: @[
      ThreadPlan(name: "workers", count: 4, functionIndex: 1, arenaBytes: 32),
      ThreadPlan(name: "empty", count: 2, functionIndex: 1)]))

let encoded = program.encodeNative()
doAssert decodeNative(encoded).encodeNative() == encoded
for count in [0, 7, 20, encoded.len - 1]:
  var rejected = false
  try:
    discard decodeNative(encoded[0 ..< count])
  except NiftyError:
    rejected = true
  doAssert rejected
var damaged = encoded
damaged[^1] = char(byte(damaged[^1]) xor 1)
var rejected = false
try:
  discard decodeNative(damaged)
except NiftyError:
  rejected = true
doAssert rejected

runNative(program)
var foreignProgram = program
foreignProgram.platform = if NativeHostPlatform == MacosPlatform:
  LinuxPlatform else: MacosPlatform
rejected = false
try:
  runNative(foreignProgram)
except NiftyError:
  rejected = true
doAssert rejected
let directory = getTempDir() / "nifty-runtime-" & $getCurrentProcessId()
createDir(directory)
try:
  let
    imagePath = directory / "program.nift"
    executable = directory / (when defined(windows): "standalone.exe"
      else: "standalone")
  writeNativeFile(program, imagePath)
  doAssert readNativeFile(imagePath).encodeNative() == encoded
  writeStandalone(program, executable)
  let standalone = readFile(executable)
  rejected = false
  try:
    writeStandalone(foreignProgram, executable)
  except NiftyError:
    rejected = true
  doAssert rejected
  doAssert readFile(executable) == standalone
  var crossProgram = program
  crossProgram.image.target = if target == Arm64Target:
    Amd64Target else: Arm64Target
  let variable = if target == Arm64Target:
    "NIFTY_RUNTIME_AMD64" else: "NIFTY_RUNTIME_ARM64"
  let previous = getEnv(variable)
  putEnv(variable, getAppFilename())
  rejected = false
  try:
    writeStandalone(crossProgram, executable)
  except NiftyError:
    rejected = true
  finally:
    if previous.len > 0: putEnv(variable, previous)
    else: delEnv(variable)
  doAssert rejected
  doAssert readFile(executable) == standalone
  doAssert embeddedImage(readFile(executable)) == encoded
  let response = execCmdEx(quoteShell(executable))
  doAssert response.exitCode == 0, response.output
  doAssert response.output.len == 0
  when defined(macosx):
    let signed = execCmdEx("/usr/bin/codesign --verify --strict " &
      quoteShell(executable))
    doAssert signed.exitCode == 0, signed.output
finally:
  removeDir(directory)
echo "Native runtime, files, and standalone launch passed"

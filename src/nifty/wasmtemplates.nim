## Embedded memory64 runtime with source and ABI freshness validation.
import std/[strutils]
import common, nativeplans, nativecontainers, backend/wasmmodules

proc runtimeDigest(data: string): string {.compileTime.} =
  ## Computes SHA-1 with VM-safe operations for the embedded source stamp.
  var bytes = data
  let bitLength = uint64(bytes.len) * 8
  bytes.add(char(128))
  while bytes.len mod 64 != 56:
    bytes.add(char(0))
  for shift in countdown(56, 0, 8):
    bytes.add(char((bitLength shr shift) and 255))
  var state = [0x67452301'u32, 0xefcdab89'u32, 0x98badcfe'u32,
    0x10325476'u32, 0xc3d2e1f0'u32]
  template rotate(value: uint32, count: int): uint32 =
    (value shl count) or (value shr (32 - count))
  for base in countup(0, bytes.len - 1, 64):
    var words: array[80, uint32]
    for i in 0 ..< 16:
      for j in 0 ..< 4:
        words[i] = (words[i] shl 8) or uint32(ord(bytes[base + i * 4 + j]))
    for i in 16 ..< 80:
      words[i] = rotate(words[i - 3] xor words[i - 8] xor
        words[i - 14] xor words[i - 16], 1)
    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    for i in 0 ..< 80:
      let f = if i < 20: (b and c) or ((not b) and d)
        elif i < 40: b xor c xor d
        elif i < 60: (b and c) or (b and d) or (c and d)
        else: b xor c xor d
      let k = if i < 20: 0x5a827999'u32
        elif i < 40: 0x6ed9eba1'u32
        elif i < 60: 0x8f1bbcdc'u32
        else: 0xca62c1d6'u32
      let next = rotate(a, 5) + f + e + k + words[i]
      e = d
      d = c
      c = rotate(b, 30)
      b = a
      a = next
    state[0] += a
    state[1] += b
    state[2] += c
    state[3] += d
    state[4] += e
  for word in state:
    result.add(word.toHex(8))

static:
  doAssert runtimeDigest("abc") == "A9993E364706816ABA3E25717850C26C9CD0D89D"

const
  WasmRuntimeMagic* = "NFTYWA01"
  WasmRuntimeStamp* = runtimeDigest((
    $sizeof(int) & $sizeof(pointer) &
    $sizeof(NativeMemory) & $sizeof(NativeHost) & $sizeof(NativeLayout) &
    staticRead("wasmtemplates.nim") &
    staticRead("common.nim") & staticRead("types.nim") &
    staticRead("backend/irs.nim") & staticRead("nativeplans.nim") &
    staticRead("backend/wasmbinaries.nim") &
    staticRead("standardbridges.nim") &
    staticRead("nativecontainers.nim") & staticRead("wasmmetadata.nim") &
    staticRead("wasmexterns.nim") & staticRead("backend/wasmmodules.nim") &
    staticRead("../../tools/runtime_wasm.nim") &
    staticRead("../../tools/runtime_wasm.c") &
    staticRead("../../tools/gen_wasm_runtime.nim")
  ).replace("\r\n", "\n"))

proc runtimeAsset*(asset: string): string =
  ## Validates source freshness and module structure before returning WASM.
  if sizeof(int) != 8 or sizeof(pointer) != 8:
    raise newException(NiftyError, "WASM requires a 64-bit compiler host")
  if asset.len < 56 or asset[0 ..< 8] != WasmRuntimeMagic:
    raise newException(NiftyError, "unsupported WASM runtime asset")
  if asset[8 ..< 48] != WasmRuntimeStamp:
    raise newException(NiftyError,
      "WASM runtime is stale; run tools/gen_wasm_runtime.nim")
  result = asset[48 ..< asset.len]
  discard parseModule(result)

proc wasmRuntime*(): string =
  ## Loads the precompiled runtime without invoking external compiler tools.
  when defined(niftyBuildWasmRuntime):
    raise newException(NiftyError, "WASM runtime is being rebuilt")
  else:
    const Asset = staticRead("assets/wasm64.bin")
    runtimeAsset(Asset)

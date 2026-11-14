## Checks ownership metadata in versioned native images.
import std/json
import ../src/nifty/[common, types, parser, loader, checker,
  lowering, nativefiles]

proc number(data: string, offset: int): uint64 =
  ## Reads one little endian image header integer.
  for i in 0 ..< 8:
    result = result or (uint64(byte(data[offset + i])) shl (i * 8))

proc setNumber(data: var string, offset: int, value: uint64) =
  ## Updates one little endian image header integer.
  for i in 0 ..< 8:
    data[offset + i] = char((value shr (i * 8)) and 255)

proc fingerprint(data: string): uint64 =
  ## Computes the native image payload checksum.
  result = 14695981039346656037'u64
  for value in data:
    result = (result xor uint64(byte(value))) * 1099511628211'u64

proc metadata(data: string): JsonNode =
  ## Parses the metadata without validating its contents.
  let size = int(data.number(8))
  parseJson(data[40 ..< 40 + size])

proc replaceMetadata(data: string, value: JsonNode): string =
  ## Rebuilds a valid checksum around modified metadata.
  let
    oldSize = int(data.number(8))
    valueText = $value
  result = data[0 ..< 40]
  result.setNumber(8, uint64(valueText.len))
  result.setNumber(24, fingerprint(valueText))
  result.add valueText
  result.add data[40 + oldSize ..< data.len]

proc rejected(data: string) =
  ## Requires a damaged native image to fail validation.
  var failed = false
  try:
    discard decodeNative(data)
  except NiftyError:
    failed = true
  doAssert failed

let target = when defined(arm64): Arm64Target else: Amd64Target
let bytes = when defined(arm64): @[0xc0'u8, 0x03, 0x5f, 0xd6]
  else: @[0xc3'u8]
let program = NativeProgram(
  platform: NativeHostPlatform,
  image: NativeImage(target: target, bytes: bytes, offsets: @[0]),
  plan: NativePlan(
    globalBytes: 128,
    initialData: newSeq[byte](128),
    layouts: @[
      NativeLayout(kind: IntType, bytes: 8, align: 8),
      NativeLayout(kind: StringType, bytes: 24, align: 8,
        dynamic: true, owned: true, dataOffset: 16),
      NativeLayout(kind: ObjectType, bytes: 32, align: 8, owned: true,
        fields: @[
          NativeField(name: "id", typ: 0, offset: 0),
          NativeField(name: "name", typ: 1, offset: 8)]),
      NativeLayout(kind: ArrayType, bytes: 64, align: 8,
        capacity: 2, elem: 2, owned: true),
      NativeLayout(kind: SeqType, bytes: 56, align: 8,
        capacity: 2, elem: 1, dataOffset: 8, owned: true),
      NativeLayout(kind: StringType, bytes: 32, align: 8,
        dynamic: true, owned: true, optional: true,
        dataOffset: 16, okOffset: 24)],
    ownedGlobals: @[
      OwnedGlobal(offset: 0, layout: 1),
      OwnedGlobal(offset: 32, layout: 2),
      OwnedGlobal(offset: 64, layout: 3)]))

let encoded = program.encodeNative()
doAssert encoded[0 ..< 8] == NativeMagic
let decoded = decodeNative(encoded)
doAssert decoded.encodeNative() == encoded
doAssert decoded.plan.ownedGlobals == program.plan.ownedGlobals
doAssert decoded.plan.layouts[1].dynamic
doAssert decoded.plan.layouts[2].owned
doAssert decoded.plan.layouts[5].optional

let sourceText = """
object Row =
  text: string
var shared: Row
thread worker() =
  echo shared.text.len
thread main() =
  echo shared.text.len
"""
let source = parse(loadTokens(sourceText, "memoryfiles.nifty", "."))
check(source)
let generated = buildNativeProgram(
  lowerNative(source, "memoryfiles.nifty"),
  target)
doAssert generated.plan.ownedGlobals.len == 1
doAssert decodeNative(generated.encodeNative()).plan.ownedGlobals ==
  generated.plan.ownedGlobals

var oldVersion = encoded
oldVersion[0 ..< 8] = "NIFTYN01"
rejected(oldVersion)

var changed = encoded.metadata()
changed["layouts"][1].delete("owned")
rejected(encoded.replaceMetadata(changed))

changed = encoded.metadata()
changed["layouts"][1]["owned"] = %false
rejected(encoded.replaceMetadata(changed))

changed = encoded.metadata()
changed["layouts"][0]["dynamic"] = %true
rejected(encoded.replaceMetadata(changed))

changed = encoded.metadata()
changed["layouts"][1]["bytes"] = %8
rejected(encoded.replaceMetadata(changed))

changed = encoded.metadata()
changed["layouts"][2]["fields"][1]["offset"] = %24
rejected(encoded.replaceMetadata(changed))

changed = encoded.metadata()
changed["ownedGlobals"][0]["offset"] = %120
rejected(encoded.replaceMetadata(changed))

changed = encoded.metadata()
changed["ownedGlobals"][0]["layout"] = %0
rejected(encoded.replaceMetadata(changed))

echo "Native ownership image metadata passed"

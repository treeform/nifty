import ../src/nifty/[nativecontainers, nativeplans, types]

type Buffer = array[512, byte]

var layouts = @[
  NativeLayout(kind: IntType, bytes: 8, align: 8,
    lower: low(int64), upper: high(int64)),
  NativeLayout(kind: BoolType, bytes: 1, align: 1, lower: 0, upper: 1),
  NativeLayout(kind: IntType, bytes: 16, align: 8, optional: true,
    okOffset: 8),
  NativeLayout(kind: StringType, bytes: 136, align: 8,
    capacity: 128, dataOffset: 8),
  NativeLayout(kind: SeqType, bytes: 32, align: 8, capacity: 3,
    elem: 0, dataOffset: 8),
  NativeLayout(kind: QueueType, bytes: 40, align: 8, capacity: 3,
    elem: 0, dataOffset: 16),
  NativeLayout(kind: SetType, bytes: 24, align: 8, capacity: 65,
    lower: -32, upper: 32, dataOffset: 8),
  NativeLayout(kind: DenseMapType, bytes: 40, align: 8, capacity: 3,
    lower: -1, upper: 1, dataOffset: 8, valOffset: 16, val: 0),
  NativeLayout(kind: SparseMapType, bytes: 56, align: 8, capacity: 3,
    key: 0, val: 0, keyOffset: 8, valOffset: 32),
  NativeLayout(kind: SparseMapType, bytes: 440, align: 8, capacity: 3,
    key: 3, val: 0, keyOffset: 8, valOffset: 416)
]

proc putInt(buffer: var Buffer, value: int64, offset = 0) =
  ## Set a scalar payload in the test storage.
  cast[ptr int64](at(addr buffer, offset))[] = value

proc getInt(buffer: var Buffer, offset = 0): int64 =
  ## Read a scalar payload from the test storage.
  cast[ptr int64](at(addr buffer, offset))[]

proc putString(buffer: var Buffer, value: string, offset = 0) =
  ## Set length-exact string storage, including embedded zero bytes.
  putInt(buffer, value.len, offset)
  if value.len > 0:
    copyMem(at(addr buffer, offset + 8), unsafeAddr value[0], value.len)

proc getString(buffer: var Buffer): string =
  ## Read length-exact storage for test assertions.
  result = newString(int(getInt(buffer)))
  if result.len > 0:
    copyMem(addr result[0], at(addr buffer, 8), result.len)

proc invoke(operation: string, receiverType: int,
    receiver, args, output: var Buffer, paramTypes: seq[int] = @[],
    resultType = 0, offsets: seq[int] = @[]) =
  ## Call the same fixed-storage dispatch used by native execution.
  var positions = offsets
  if positions.len == 0:
    for i in 0 ..< paramTypes.len:
      positions.add i * 8
  let host = NativeHost(operation: operation, receiverType: receiverType,
    resultType: resultType, paramTypes: paramTypes, paramOffsets: positions)
  executeContainer(host, layouts, addr receiver, addr args, addr output)

var receiver, args, output: Buffer

for container in [4, 5]:
  zeroMem(addr receiver, sizeof(receiver))
  for value in 1 .. 3:
    putInt(args, value)
    invoke("push", container, receiver, args, output, @[0], 1)
    doAssert output[0] == 1
  putInt(args, 4)
  invoke("push", container, receiver, args, output, @[0], 1)
  doAssert output[0] == 0
  invoke("pop", container, receiver, args, output)
  doAssert getInt(output) == (if container == 4: 3 else: 1)
  putInt(args, 4)
  invoke("add", container, receiver, args, output, @[0])
  for value in (if container == 4: @[4, 2, 1] else: @[2, 3, 4]):
    invoke("pop", container, receiver, args, output)
    doAssert getInt(output) == value
  invoke("clear", container, receiver, args, output)
  doAssert getInt(receiver) == 0
  if container == 5:
    doAssert getInt(receiver, 8) == 0

echo "Native sequence and ring operations passed"

putString(receiver, "ab\0cdab")
putString(args, "\0c")
invoke("find", 3, receiver, args, output, @[3], 2)
doAssert getInt(output) == 2 and output[8] == 1
invoke("contains", 3, receiver, args, output, @[3], 1)
doAssert output[0] == 1
putString(args, "absent")
invoke("find", 3, receiver, args, output, @[3], 2)
doAssert getInt(output) == 0 and output[8] == 0
putString(args, "")
invoke("find", 3, receiver, args, output, @[3], 2)
doAssert getInt(output) == 0 and output[8] == 1
putString(args, "ab")
for operation in ["startsWith", "endsWith"]:
  invoke(operation, 3, receiver, args, output, @[3], 1)
  doAssert output[0] == 1
putInt(args, 0)
invoke("findByte", 3, receiver, args, output, @[0], 2)
doAssert getInt(output) == 2 and output[8] == 1
putString(args, "012345")
putInt(args, -9, 144)
putInt(args, 3, 152)
invoke("copyRange", 3, receiver, args, output, @[3, 0, 0],
  offsets = @[0, 144, 152])
doAssert getString(receiver) == "012"
putInt(args, high(int64), 144)
invoke("copyRange", 3, receiver, args, output, @[3, 0, 0],
  offsets = @[0, 144, 152])
doAssert getString(receiver) == ""
putString(receiver, "start")
putString(args, "end")
invoke("add", 3, receiver, args, output, @[3])
doAssert getString(receiver) == "startend"
putInt(args, 0)
invoke("addByte", 3, receiver, args, output, @[0])
doAssert getString(receiver) == "startend\0"
for value in [low(int64), -1'i64, 0, 1, high(int64)]:
  invoke("clear", 3, receiver, args, output)
  putInt(args, value)
  invoke("addNum", 3, receiver, args, output, @[0])
  doAssert getString(receiver) == $value
  invoke("toInt", 3, receiver, args, output, resultType = 2)
  doAssert output[8] == 1 and getInt(output) == value
for value in ["", "-", "+1", "1 ", " 1", "1\0", "9223372036854775808",
    "-9223372036854775809", "999999999999999999999999"]:
  putString(receiver, value)
  invoke("toInt", 3, receiver, args, output, resultType = 2)
  doAssert output[8] == 0 and getInt(output) == 0
putString(receiver, "12345")
putInt(args, 2)
invoke("setLen", 3, receiver, args, output, @[0])
doAssert getString(receiver) == "12"
echo "Native exact-byte string operations passed"

zeroMem(addr receiver, sizeof(receiver))
for key in [-32, 0, 32, 0]:
  putInt(args, key)
  invoke("incl", 6, receiver, args, output, @[0])
doAssert getInt(receiver) == 3
for key in [-33, -32, 0, 32, 33]:
  putInt(args, key)
  invoke("contains", 6, receiver, args, output, @[0], 1)
  doAssert (output[0] != 0) == (key >= -32 and key <= 32)
putInt(args, 0)
invoke("excl", 6, receiver, args, output, @[0])
invoke("excl", 6, receiver, args, output, @[0])
doAssert getInt(receiver) == 2
invoke("clear", 6, receiver, args, output)
doAssert getInt(receiver) == 0 and getInt(receiver, 8) == 0

echo "Native multiword set operations passed"

for container in [7, 8]:
  zeroMem(addr receiver, sizeof(receiver))
  for key in [1, -1, 0]:
    putInt(args, key)
    putInt(args, key + 100, 8)
    invoke("put", container, receiver, args, output, @[0, 0], 1)
  doAssert getInt(receiver) == 3
  putInt(args, 0)
  putInt(args, 500, 8)
  invoke("put", container, receiver, args, output, @[0, 0], 1)
  doAssert getInt(receiver) == 3
  invoke("at", container, receiver, args, output, @[0])
  doAssert getInt(output) == 500
  invoke("address", container, receiver, args, output, @[0])
  doAssert cast[ptr int64](cast[ptr pointer](addr output)[])[] == 500
  if container == 8:
    doAssert getInt(receiver, 8) == -1
    doAssert getInt(receiver, 16) == 0
    doAssert getInt(receiver, 24) == 1
    putInt(args, 5)
    invoke("put", container, receiver, args, output, @[0, 0], 1)
    doAssert output[0] == 0 and getInt(receiver) == 3
  putInt(args, 0)
  invoke("remove", container, receiver, args, output, @[0])
  invoke("remove", container, receiver, args, output, @[0])
  doAssert getInt(receiver) == 2
  if container == 7:
    doAssert getInt(receiver, 24) == 0
  else:
    doAssert getInt(receiver, 24) == 0
    doAssert getInt(receiver, 48) == 0
  putInt(args, 999)
  putInt(args, 42, 8)
  invoke("get", container, receiver, args, output, @[0, 0])
  doAssert getInt(output) == 42
  invoke("contains", container, receiver, args, output, @[0], 1)
  doAssert output[0] == 0
  invoke("clear", container, receiver, args, output)
  for i in 0 ..< int(layouts[container].bytes):
    doAssert receiver[i] == 0

echo "Native dense and sparse map operations passed"

zeroMem(addr receiver, sizeof(receiver))
for key in ["ab", "a\0", "a"]:
  putString(args, key)
  putInt(args, key.len, 144)
  invoke("put", 9, receiver, args, output, @[3, 0], 1, @[0, 144])
doAssert getInt(receiver) == 3
var key: Buffer
copyMem(addr key, at(addr receiver, 8), 136)
doAssert getString(key) == "a"
copyMem(addr key, at(addr receiver, 144), 136)
doAssert getString(key) == "a\0"
copyMem(addr key, at(addr receiver, 280), 136)
doAssert getString(key) == "ab"
putString(args, "a\0")
invoke("at", 9, receiver, args, output, @[3])
doAssert getInt(output) == 2
invoke("remove", 9, receiver, args, output, @[3])
doAssert getInt(receiver) == 2
for i in 280 ..< 416:
  doAssert receiver[i] == 0
doAssert getInt(receiver, 432) == 0

echo "Native string-key map operations passed"

zeroMem(addr receiver, sizeof(receiver))
putInt(args, 77)
invoke("or", 2, receiver, args, output, @[0])
doAssert getInt(output) == 77
putInt(receiver, 0)
receiver[8] = 1
invoke("or", 2, receiver, args, output, @[0])
doAssert getInt(output) == 0

echo "Native optional fallback operations passed"

let
  signedByte = layouts.len
  unsignedByte = signedByte + 1
  narrowMap = signedByte + 2
layouts.add NativeLayout(kind: IntType, bytes: 1, align: 1,
  lower: -128, upper: 127)
layouts.add NativeLayout(kind: IntType, bytes: 1, align: 1,
  lower: 0, upper: 255)
layouts.add NativeLayout(kind: SparseMapType, bytes: 40, align: 8,
  capacity: 3, key: unsignedByte, val: 0, keyOffset: 8, valOffset: 16)
for container in [4, 5]:
  zeroMem(addr receiver, sizeof(receiver))
  for value in [-128, -1, 127]:
    for i in 0 ..< args.len:
      args[i] = 0x5a
    args[0] = cast[byte](int8(value))
    invoke("add", container, receiver, args, output, @[signedByte])
  for expected in (if container == 4: @[127, -1, -128]
      else: @[-128, -1, 127]):
    invoke("pop", container, receiver, args, output)
    doAssert getInt(output) == expected
for container in [7, 8]:
  zeroMem(addr receiver, sizeof(receiver))
  putInt(args, 0)
  args[8] = cast[byte](-128'i8)
  args[9] = 0x5a
  invoke("put", container, receiver, args, output, @[0, signedByte], 1)
  invoke("at", container, receiver, args, output, @[0])
  doAssert getInt(output) == -128
  putInt(args, 500)
  args[8] = cast[byte](-1'i8)
  invoke("get", container, receiver, args, output, @[0, signedByte])
  doAssert getInt(output) == -1
zeroMem(addr receiver, sizeof(receiver))
putInt(args, 0)
putInt(args, 123, 8)
invoke("put", narrowMap, receiver, args, output, @[0, 0], 1)
for key in [-256, 256, 0]:
  putInt(args, key)
  invoke("contains", narrowMap, receiver, args, output, @[0], 1)
  doAssert (output[0] != 0) == (key == 0)
putInt(args, 255)
putInt(args, 456, 8)
invoke("put", narrowMap, receiver, args, output, @[0, 0], 1)
doAssert receiver[9] == 255
args[0] = 255
invoke("at", narrowMap, receiver, args, output, @[unsignedByte])
doAssert getInt(output) == 456

echo "Native scalar-width normalization passed"

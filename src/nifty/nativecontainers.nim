## Fixed-storage container operations used by native host calls.
import nativeplans, types

{.push raises: [], checks: off.}

proc at*(base: pointer, offset: int64): pointer {.inline.} =
  ## Address an offset within fixed native storage.
  cast[pointer](cast[uint](base) + cast[uint](offset))

proc length(base: pointer): var int64 {.inline.} =
  ## Access the native length field.
  cast[ptr int64](base)[]

proc integer*(base: pointer, layout: NativeLayout): int64 =
  ## Read an integer using its declared storage width and signedness.
  case layout.bytes
  of 1:
    if layout.lower >= 0: int64(cast[ptr uint8](base)[])
    else: int64(cast[ptr int8](base)[])
  of 2:
    if layout.lower >= 0: int64(cast[ptr uint16](base)[])
    else: int64(cast[ptr int16](base)[])
  of 4:
    if layout.lower >= 0: int64(cast[ptr uint32](base)[])
    else: int64(cast[ptr int32](base)[])
  else: cast[ptr int64](base)[]

proc writeInteger*(base: pointer, layout: NativeLayout, value: int64) =
  ## Store an integer using its declared storage width.
  case layout.bytes
  of 1: cast[ptr uint8](base)[] = cast[uint8](value)
  of 2: cast[ptr uint16](base)[] = cast[uint16](value)
  of 4: cast[ptr uint32](base)[] = cast[uint32](value)
  else: cast[ptr int64](base)[] = value

proc bytesEqual(a, b: pointer, count: int64): bool =
  ## Compare raw bytes without constructing strings.
  let
    left = cast[ptr UncheckedArray[byte]](a)
    right = cast[ptr UncheckedArray[byte]](b)
  for i in 0 ..< count:
    if left[i] != right[i]:
      return false
  true

proc stringCompare(a, b: pointer, dataOffset: int): int =
  ## Compare length-exact strings in bytewise lexical order.
  let
    left = cast[ptr UncheckedArray[byte]](at(a, dataOffset))
    right = cast[ptr UncheckedArray[byte]](at(b, dataOffset))
    count = min(length(a), length(b))
  for i in 0 ..< count:
    if left[i] < right[i]:
      return -1
    if left[i] > right[i]:
      return 1
  if length(a) < length(b):
    return -1
  if length(a) > length(b):
    return 1
  0

proc findString(receiver, needle: pointer, dataOffset: int,
    needleOffset: int): int64 =
  ## Find the first exact byte sequence, including an empty needle.
  let
    count = length(needle)
    source = at(receiver, dataOffset)
    target = at(needle, needleOffset)
  if count == 0:
    return 0
  if count > length(receiver):
    return -1
  for i in 0 .. length(receiver) - count:
    if bytesEqual(at(source, i), target, count):
      return i
  -1

proc optionalInteger(output: pointer, layout: NativeLayout,
    value: int64, present: bool) =
  ## Write the full canonical optional integer result.
  zeroMem(output, int(layout.bytes))
  if present:
    cast[ptr int64](output)[] = value
    cast[ptr bool](at(output, layout.okOffset))[] = true

proc parseInteger(receiver: pointer, dataOffset: int,
    value: var int64): bool =
  ## Parse strict signed decimal with checked full-range accumulation.
  let
    count = length(receiver)
    data = cast[ptr UncheckedArray[byte]](at(receiver, dataOffset))
  if count == 0:
    return false
  var
    i = 0'i64
    negative = false
    accumulated = 0'u64
  if data[0] == byte('-'):
    negative = true
    i = 1
  if i == count:
    return false
  let limit = if negative: 9223372036854775808'u64
    else: 9223372036854775807'u64
  while i < count:
    let digit = data[i]
    if digit < byte('0') or digit > byte('9'):
      return false
    let number = uint64(digit - byte('0'))
    if accumulated > (limit - number) div 10:
      return false
    accumulated = accumulated * 10 + number
    inc i
  value = if negative: cast[int64](0'u64 - accumulated)
    else: int64(accumulated)
  true

proc addNumber(receiver: pointer, dataOffset: int, value: int64) =
  ## Append decimal text through a fixed stack buffer, including INT64_MIN.
  var
    buffer: array[20, byte]
    count = 0
    magnitude = if value < 0: 0'u64 - cast[uint64](value)
      else: uint64(value)
  while true:
    buffer[count] = byte(magnitude mod 10) + byte('0')
    inc count
    magnitude = magnitude div 10
    if magnitude == 0:
      break
  let data = cast[ptr UncheckedArray[byte]](at(receiver, dataOffset))
  if value < 0:
    data[length(receiver)] = byte('-')
    inc length(receiver)
  while count > 0:
    dec count
    data[length(receiver)] = buffer[count]
    inc length(receiver)

proc sparseFind(receiver, key: pointer, layout: NativeLayout,
    keyLayout: NativeLayout): int64 =
  ## Binary-search sorted fixed storage and encode the insertion position.
  var
    low = 0'i64
    high = length(receiver) - 1
  while low <= high:
    let
      middle = low + (high - low) div 2
      candidate = at(receiver,
        int64(layout.keyOffset) + middle * keyLayout.bytes)
    var comparison: int
    if keyLayout.kind == StringType:
      comparison = stringCompare(candidate, key, keyLayout.dataOffset)
    else:
      let
        left = integer(candidate, keyLayout)
        right = integer(key, keyLayout)
      comparison = if left < right: -1 elif left > right: 1 else: 0
    if comparison == 0:
      return middle
    if comparison < 0:
      low = middle + 1
    else:
      high = middle - 1
  -(low + 1)

proc queueAdd*(receiver, value: pointer, layout: NativeLayout,
    elementSize: int64) =
  ## Append to a proven nonfull fixed ring buffer.
  let
    head = cast[ptr int64](at(receiver, 8))[]
    index = (head + length(receiver)) mod layout.capacity
  copyMem(at(receiver, int64(layout.dataOffset) + index * elementSize),
    value, int(elementSize))
  inc length(receiver)

proc queuePop*(receiver, output: pointer, layout: NativeLayout,
    elementSize: int64) =
  ## Remove the front of a proven nonempty fixed ring buffer.
  let head = cast[ptr int64](at(receiver, 8))
  copyMem(output,
    at(receiver, int64(layout.dataOffset) + head[] * elementSize),
    int(elementSize))
  head[] = (head[] + 1) mod layout.capacity
  dec length(receiver)

proc executeContainer*(host: NativeHost, layouts: seq[NativeLayout],
    receiver, args, output: pointer) =
  ## Execute a checked container method without allocations or GC writes.
  template layout: untyped = layouts[host.receiverType]
  template argument(index: int): pointer =
    at(args, int64(host.paramOffsets[index]))
  template argumentLayout(index: int): NativeLayout =
    layouts[host.paramTypes[index]]
  template argumentInteger(index: int): int64 =
    integer(argument(index), argumentLayout(index))
  template boolean(value: bool) =
    cast[ptr bool](output)[] = value
  if layout.optional:
    if cast[ptr bool](at(receiver, layout.okOffset))[]:
      copyMem(output, receiver, int(layout.okOffset))
    else:
      copyMem(output, argument(0), int(layout.okOffset))
    return
  if host.operation == "clear":
    case layout.kind
    of SetType, DenseMapType, SparseMapType:
      zeroMem(receiver, int(layout.bytes))
    of QueueType:
      length(receiver) = 0
      cast[ptr int64](at(receiver, 8))[] = 0
    else:
      length(receiver) = 0
    return
  case layout.kind
  of SeqType, QueueType:
    let elementSize = layouts[layout.elem].bytes
    case host.operation
    of "add", "push":
      if host.operation == "push" and length(receiver) >= layout.capacity:
        boolean(false)
        return
      if layout.kind == QueueType:
        queueAdd(receiver, argument(0), layout, elementSize)
      else:
        copyMem(at(receiver,
          int64(layout.dataOffset) + length(receiver) * elementSize),
          argument(0), int(elementSize))
        inc length(receiver)
      if host.operation == "push":
        boolean(true)
    of "pop":
      if layout.kind == QueueType:
        queuePop(receiver, output, layout, elementSize)
      else:
        dec length(receiver)
        copyMem(output, at(receiver,
          int64(layout.dataOffset) + length(receiver) * elementSize),
          int(elementSize))
    else:
      discard
  of StringType:
    let data = at(receiver, layout.dataOffset)
    case host.operation
    of "add":
      let
        source = argument(0)
        count = length(source)
      moveMem(at(data, length(receiver)),
        at(source, argumentLayout(0).dataOffset), int(count))
      length(receiver) += count
    of "setLen":
      length(receiver) = argumentInteger(0)
    of "addByte":
      cast[ptr byte](at(data, length(receiver)))[] = byte(argumentInteger(0))
      inc length(receiver)
    of "addNum":
      addNumber(receiver, layout.dataOffset, argumentInteger(0))
    of "startsWith", "endsWith":
      let
        source = argument(0)
        count = length(source)
      var found = false
      if count <= length(receiver):
        let offset = if host.operation == "startsWith": 0'i64
          else: length(receiver) - count
        found = bytesEqual(at(data, offset),
          at(source, argumentLayout(0).dataOffset), count)
      boolean(found)
    of "contains", "find":
      let found = findString(receiver, argument(0), layout.dataOffset,
        argumentLayout(0).dataOffset)
      if host.operation == "contains":
        boolean(found >= 0)
      else:
        optionalInteger(output, layouts[host.resultType], found, found >= 0)
    of "findByte":
      var found = -1'i64
      let target = byte(argumentInteger(0))
      for i in 0 ..< length(receiver):
        if cast[ptr byte](at(data, i))[] == target:
          found = i
          break
      optionalInteger(output, layouts[host.resultType], found, found >= 0)
    of "toInt":
      var value = 0'i64
      let present = parseInteger(receiver, layout.dataOffset, value)
      optionalInteger(output, layouts[host.resultType], value, present)
    of "copyRange":
      let
        source = argument(0)
        sourceLength = length(source)
        low = max(0'i64, min(sourceLength, argumentInteger(1)))
        high = max(0'i64, min(sourceLength, argumentInteger(2)))
        count = min(layout.capacity, max(0'i64, high - low))
      if count > 0:
        moveMem(data, at(source,
          int64(argumentLayout(0).dataOffset) + low), int(count))
      length(receiver) = count
    else:
      discard
  of SetType, DenseMapType:
    let
      key = argumentInteger(0)
      inRange = key >= layout.lower and key <= layout.upper
    if host.operation == "contains" and not inRange:
      boolean(false)
      return
    if host.operation == "remove" and not inRange:
      return
    if host.operation == "get" and not inRange:
      copyMem(output, argument(1), int(layouts[layout.val].bytes))
      return
    let
      index = key - layout.lower
      word = cast[ptr uint64](at(receiver,
        int64(layout.dataOffset) + (index shr 6) * 8))
      mask = 1'u64 shl (index and 63)
      present = (word[] and mask) != 0
    case host.operation
    of "contains":
      boolean(present)
    of "incl", "put":
      if not present:
        word[] = word[] or mask
        inc length(receiver)
      if layout.kind == DenseMapType:
        let valueSize = layouts[layout.val].bytes
        copyMem(at(receiver, int64(layout.valOffset) + index * valueSize),
          argument(1), int(valueSize))
    of "excl", "remove":
      if present:
        word[] = word[] and not mask
        dec length(receiver)
        if layout.kind == DenseMapType:
          let valueSize = layouts[layout.val].bytes
          zeroMem(at(receiver,
            int64(layout.valOffset) + index * valueSize), int(valueSize))
    of "get", "at", "address":
      let valueSize = layouts[layout.val].bytes
      if host.operation == "address":
        cast[ptr pointer](output)[] =
          at(receiver, int64(layout.valOffset) + index * valueSize)
      elif present:
        copyMem(output,
          at(receiver, int64(layout.valOffset) + index * valueSize),
          int(valueSize))
      else:
        copyMem(output, argument(1), int(valueSize))
    else:
      discard
  of SparseMapType:
    template keyLayout: untyped = layouts[layout.key]
    let
      keySize = keyLayout.bytes
      valueSize = layouts[layout.val].bytes
      index = sparseFind(receiver, argument(0), layout, keyLayout)
    template keyAt(index: int64): pointer =
      at(receiver, int64(layout.keyOffset) + index * keySize)
    template valueAt(index: int64): pointer =
      at(receiver, int64(layout.valOffset) + index * valueSize)
    case host.operation
    of "contains":
      boolean(index >= 0)
    of "get", "at", "address":
      if host.operation == "address":
        cast[ptr pointer](output)[] = valueAt(index)
      elif index >= 0:
        copyMem(output, valueAt(index), int(valueSize))
      elif host.operation == "get":
        copyMem(output, argument(1), int(valueSize))
    of "put":
      if index >= 0:
        copyMem(valueAt(index), argument(1), int(valueSize))
        if output != nil:
          boolean(true)
      elif length(receiver) >= layout.capacity:
        if output != nil:
          boolean(false)
      else:
        let
          position = -index - 1
          remaining = length(receiver) - position
        moveMem(keyAt(position + 1), keyAt(position), int(remaining * keySize))
        moveMem(valueAt(position + 1), valueAt(position),
          int(remaining * valueSize))
        copyMem(keyAt(position), argument(0), int(keySize))
        copyMem(valueAt(position), argument(1), int(valueSize))
        inc length(receiver)
        if output != nil:
          boolean(true)
    of "remove":
      if index >= 0:
        let remaining = length(receiver) - index - 1
        moveMem(keyAt(index), keyAt(index + 1), int(remaining * keySize))
        moveMem(valueAt(index), valueAt(index + 1), int(remaining * valueSize))
        dec length(receiver)
        zeroMem(keyAt(length(receiver)), int(keySize))
        zeroMem(valueAt(length(receiver)), int(valueSize))
    else:
      discard
  else:
    discard

{.pop.}

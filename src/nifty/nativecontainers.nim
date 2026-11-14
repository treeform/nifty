## Container operations and owned storage used by native host calls.
import nativeplans, types

{.push raises: [], checks: off.}

type
  NativeMemory* = object
    ## Allocation callbacks for program-owned storage.
    reallocate*: proc(address: pointer, bytes: csize_t): pointer
      {.cdecl, raises: [].}
    release*: proc(address: pointer) {.cdecl, raises: [].}

proc cRealloc(address: pointer, bytes: csize_t): pointer
    {.importc: "realloc", header: "<stdlib.h>", raises: [].}
proc cFree(address: pointer)
    {.importc: "free", header: "<stdlib.h>", raises: [].}

proc reallocate(memory: NativeMemory, address: pointer,
    bytes: csize_t): pointer =
  ## Allocate program-owned bytes through a scoped callback or libc.
  if memory.reallocate != nil:
    memory.reallocate(address, bytes)
  else:
    cRealloc(address, bytes)

proc release(memory: NativeMemory, address: pointer) =
  ## Free program-owned bytes through a scoped callback or libc.
  if address != nil:
    if memory.release != nil:
      memory.release(address)
    else:
      cFree(address)

proc at*(base: pointer, offset: int64): pointer {.inline.} =
  ## Address an offset within fixed native storage.
  cast[pointer](cast[uint](base) + cast[uint](offset))

proc length(base: pointer): var int64 {.inline.} =
  ## Access the native length field.
  cast[ptr int64](base)[]

proc capacity(base: pointer): var int64 {.inline.} =
  ## Access the capacity of a dynamic descriptor.
  cast[ptr int64](at(base, 8))[]

proc dataPointer(base: pointer, layout: NativeLayout): pointer =
  ## Find inline fixed data or the allocation in a dynamic descriptor.
  if layout.dynamic:
    cast[ptr pointer](at(base, 16))[]
  else:
    at(base, layout.dataOffset)

proc dataSlot(base: pointer): var pointer {.inline.} =
  ## Access the allocation pointer of a dynamic descriptor.
  cast[ptr pointer](at(base, 16))[]

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

proc copyValue*(destination, source: pointer,
    targetLayout, sourceLayout: NativeLayout) =
  ## Convert scalar integer widths while copying fixed aggregate values.
  if targetLayout.kind == IntType and not targetLayout.optional:
    writeInteger(destination, targetLayout, integer(source, sourceLayout))
  else:
    copyMem(destination, source, int(targetLayout.bytes))

proc reserveDynamic(base: pointer, layout: NativeLayout,
    elementBytes, wanted: int64, memory: NativeMemory): bool =
  ## Grow a descriptor while preserving its live data and zeroing spare slots.
  if wanted < 0 or elementBytes <= 0:
    return false
  if wanted <= capacity(base):
    return true
  if uint64(wanted) > uint64(high(int) - 24) div uint64(elementBytes) or
      uint64(wanted) > uint64(high(csize_t) - 24) div uint64(elementBytes):
    return false
  var grown = max(8'i64, capacity(base))
  while grown < wanted:
    if grown > high(int64) div 2:
      grown = wanted
      break
    grown *= 2
  if uint64(grown) > uint64(high(int) - 24) div uint64(elementBytes) or
      uint64(grown) > uint64(high(csize_t) - 24) div uint64(elementBytes):
    grown = wanted
  # Reserved tail frames let destruction traverse trees without allocation.
  let address = reallocate(memory, dataSlot(base),
    csize_t(grown) * csize_t(elementBytes) + 24)
  if address == nil:
    return false
  zeroMem(at(address, capacity(base) * elementBytes),
    int((grown - capacity(base)) * elementBytes))
  dataSlot(base) = address
  capacity(base) = grown
  true

proc dropInline(layouts: seq[NativeLayout], id: int, address: pointer,
    memory: NativeMemory, pending: var pointer) =
  ## Release inline leaves and enqueue dynamic sequence descendants.
  let layout = layouts[id]
  if not layout.owned:
    return
  if layout.optional:
    if cast[ptr bool](at(address, layout.okOffset))[]:
      for i, candidate in layouts:
        if candidate.kind == layout.kind and
            candidate.bytes == int64(layout.okOffset) and
            not candidate.optional and candidate.dynamic == layout.dynamic:
          dropInline(layouts, i, address, memory, pending)
          break
    return
  case layout.kind
  of UnionType:
    for member in layout.members:
      if layouts[member].typeId == length(address):
        dropInline(layouts, member, at(address, layout.dataOffset),
          memory, pending)
        break
  of StringType:
    if layout.dynamic:
      release(memory, dataSlot(address))
  of SeqType:
    if layout.dynamic:
      let element = layouts[layout.elem]
      if dataSlot(address) != nil:
        let frame = at(dataSlot(address), capacity(address) * element.bytes)
        cast[ptr pointer](frame)[] = pending
        cast[ptr pointer](at(frame, 8))[] = address
        cast[ptr int64](at(frame, 16))[] = int64(id)
        pending = frame
    else:
      let element = layouts[layout.elem]
      for i in countdown(length(address) - 1, 0'i64):
        dropInline(layouts, layout.elem,
          at(dataPointer(address, layout), i * element.bytes), memory, pending)
  of ArrayType:
    let element = layouts[layout.elem]
    for i in countdown(layout.capacity - 1, 0'i64):
      dropInline(layouts, layout.elem, at(address, i * element.bytes),
        memory, pending)
  of ObjectType:
    for field in layout.fields:
      dropInline(layouts, field.typ, at(address, field.offset),
        memory, pending)
  else:
    discard

proc dropOwned*(layouts: seq[NativeLayout], layoutId: int,
    base: pointer, memory = NativeMemory()) =
  ## Destroy owned trees using reserved allocation tails as a work stack.
  if not layouts[layoutId].owned:
    return
  var pending: pointer
  dropInline(layouts, layoutId, base, memory, pending)
  while pending != nil:
    let
      frame = pending
      address = cast[ptr pointer](at(frame, 8))[]
      id = int(cast[ptr int64](at(frame, 16))[])
      layout = layouts[id]
    if length(address) > 0 and layouts[layout.elem].owned:
      dec length(address)
      dropInline(layouts, layout.elem, at(dataSlot(address),
        length(address) * layouts[layout.elem].bytes), memory, pending)
    else:
      pending = cast[ptr pointer](frame)[]
      release(memory, dataSlot(address))
  zeroMem(base, int(layouts[layoutId].bytes))

proc copyOwnedZero(layouts: seq[NativeLayout], layoutId: int,
    destination, source: pointer, memory: NativeMemory): bool =
  ## Clone with a fallible task stack, cleaning partial trees on failure.
  type Task = object
    id: int
    destination, source: pointer
  var
    local: array[32, Task]
    tasks = cast[ptr UncheckedArray[Task]](addr local[0])
    count = 0
    slots = local.len
    allocated: pointer
  defer:
    release(memory, allocated)
  template push(taskId, target, input: untyped): bool =
    block:
      var success = true
      if count == slots:
        if slots > high(int) div (2 * sizeof(Task)):
          success = false
        else:
          let grown = reallocate(memory, allocated,
            csize_t(slots * 2 * sizeof(Task)))
          if grown == nil:
            success = false
          else:
            if allocated == nil:
              copyMem(grown, addr local[0], count * sizeof(Task))
            allocated = grown
            tasks = cast[ptr UncheckedArray[Task]](grown)
            slots *= 2
      if success:
        tasks[count] = Task(id: taskId, destination: target, source: input)
        inc count
      success
  template enqueue(id, destination, source: untyped) =
    if not push(id, destination, source):
      dropOwned(layouts, layoutId, destinationRoot, memory)
      return false
  let destinationRoot = destination
  discard push(layoutId, destination, source)
  while count > 0:
    dec count
    let
      task = tasks[count]
      layout = layouts[task.id]
      destination = task.destination
      source = task.source
    if not layout.owned:
      copyMem(destination, source, int(layout.bytes))
      continue
    if layout.optional:
      if cast[ptr bool](at(source, layout.okOffset))[]:
        for i, candidate in layouts:
          if candidate.kind == layout.kind and
              candidate.bytes == int64(layout.okOffset) and
              not candidate.optional and candidate.dynamic == layout.dynamic:
            cast[ptr bool](at(destination, layout.okOffset))[] = true
            enqueue(i, destination, source)
            break
      continue
    case layout.kind
    of UnionType:
      length(destination) = length(source)
      for member in layout.members:
        if layouts[member].typeId == length(source):
          enqueue(member, at(destination, layout.dataOffset),
            at(source, layout.dataOffset))
          break
    of StringType, SeqType:
      let elementBytes = if layout.kind == StringType: 1'i64
        else: layouts[layout.elem].bytes
      if layout.dynamic:
        if not reserveDynamic(destination, layout, elementBytes,
            length(source), memory):
          dropOwned(layouts, layoutId, destinationRoot, memory)
          return false
      length(destination) = length(source)
      if layout.kind == SeqType and layouts[layout.elem].owned:
        for i in countdown(length(source) - 1, 0'i64):
          enqueue(layout.elem,
            at(dataPointer(destination, layout), i * elementBytes),
            at(dataPointer(source, layout), i * elementBytes))
      elif length(source) > 0:
        copyMem(dataPointer(destination, layout),
          dataPointer(source, layout), int(length(source) * elementBytes))
    of ArrayType:
      let element = layouts[layout.elem]
      for i in countdown(layout.capacity - 1, 0'i64):
        enqueue(layout.elem, at(destination, i * element.bytes),
          at(source, i * element.bytes))
    of ObjectType:
      for field in layout.fields:
        enqueue(field.typ, at(destination, field.offset),
          at(source, field.offset))
    else:
      copyMem(destination, source, int(layout.bytes))
  true

proc copyOwned*(layouts: seq[NativeLayout], layoutId: int,
    destination, source: pointer, memory = NativeMemory()): bool =
  ## Copy an owner transactionally, leaving the old value on failure.
  if destination == source:
    return true
  let layout = layouts[layoutId]
  var scratch: array[128, uint64]
  let temporary = if layout.bytes <= int64(sizeof(scratch)):
      cast[pointer](addr scratch[0])
    else:
      reallocate(memory, nil, csize_t(layout.bytes))
  if temporary == nil:
    return false
  zeroMem(temporary, int(layout.bytes))
  if not copyOwnedZero(layouts, layoutId, temporary, source, memory):
    if temporary != cast[pointer](addr scratch[0]):
      release(memory, temporary)
    return false
  dropOwned(layouts, layoutId, destination, memory)
  copyMem(destination, temporary, int(layout.bytes))
  if temporary != cast[pointer](addr scratch[0]):
    release(memory, temporary)
  true

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
    data = cast[ptr UncheckedArray[byte]](
      if dataOffset < 0: dataSlot(receiver)
      else: at(receiver, dataOffset))
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
    keyLayout, argumentLayout: NativeLayout): int64 =
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
        right = integer(key, argumentLayout)
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

proc appendDynamic(receiver, source: pointer, count: int64,
    memory: NativeMemory): bool =
  ## Append bytes to a dynamic string after a checked growth.
  if count < 0 or count > high(int64) - length(receiver):
    return false
  let oldLength = length(receiver)
  if not reserveDynamic(receiver, NativeLayout(), 1,
      oldLength + count, memory):
    return false
  if count > 0:
    moveMem(at(dataSlot(receiver), oldLength), source, int(count))
  length(receiver) = oldLength + count
  true

proc copyDynamicFrom(layouts: seq[NativeLayout], layoutId: int,
    destination, source: pointer, sourceLayout: NativeLayout,
    memory: NativeMemory): bool =
  ## Replace a dynamic descriptor with a deep copy of fixed or dynamic data.
  let layout = layouts[layoutId]
  var temporary: array[3, uint64]
  let target = cast[pointer](addr temporary[0])
  zeroMem(target, 24)
  let elementBytes = if layout.kind == StringType: 1'i64
    else: layouts[layout.elem].bytes
  if not reserveDynamic(target, layout, elementBytes,
      length(source), memory):
    return false
  if layout.kind == SeqType and layouts[layout.elem].owned:
    for i in 0 ..< length(source):
      if not copyOwnedZero(layouts, layout.elem,
          at(dataSlot(target), i * elementBytes),
          at(dataPointer(source, sourceLayout), i * elementBytes), memory):
        dropOwned(layouts, layoutId, target, memory)
        return false
      inc length(target)
  else:
    if length(source) > 0:
      copyMem(dataSlot(target), dataPointer(source, sourceLayout),
        int(length(source) * elementBytes))
    length(target) = length(source)
  dropOwned(layouts, layoutId, destination, memory)
  copyMem(destination, target, 24)
  true

proc initializeValue*(layouts: seq[NativeLayout], id: int, base: pointer) =
  ## Initialize declared defaults recursively within zeroed storage.
  let layout = layouts[id]
  if layout.optional:
    return
  case layout.kind
  of UnionType:
    if layout.members.len > 0:
      let member = layout.members[0]
      length(base) = layouts[member].typeId
      initializeValue(layouts, member, at(base, layout.dataOffset))
  of ObjectType:
    for field in layout.fields:
      initializeValue(layouts, field.typ, at(base, field.offset))
  of ArrayType:
    for i in 0 ..< layout.capacity:
      initializeValue(layouts, layout.elem,
        at(base, i * layouts[layout.elem].bytes))
  else:
    discard

proc executeDynamic(host: NativeHost, layouts: seq[NativeLayout],
    receiver, args, output: pointer, memory: NativeMemory) =
  ## Dispatch fallible growable string and sequence operations.
  template layout: untyped = layouts[host.receiverType]
  template argument(index: int): pointer =
    at(args, int64(host.paramOffsets[index]))
  template argumentLayout(index: int): NativeLayout =
    layouts[host.paramTypes[index]]
  template argumentInteger(index: int): int64 =
    integer(argument(index), argumentLayout(index))
  template boolean(value: bool) =
    cast[ptr bool](output)[] = value
  let elementBytes = if layout.kind == StringType: 1'i64
    else: layouts[layout.elem].bytes
  case host.operation
  of "drop":
    dropOwned(layouts, host.receiverType, receiver, memory)
  of "clear":
    if layout.kind == SeqType and layouts[layout.elem].owned:
      for i in countdown(length(receiver) - 1, 0'i64):
        dropOwned(layouts, layout.elem,
          at(dataSlot(receiver), i * elementBytes), memory)
    if length(receiver) > 0:
      zeroMem(dataSlot(receiver), int(length(receiver) * elementBytes))
    length(receiver) = 0
  of "reserve":
    boolean(reserveDynamic(receiver, layout, elementBytes,
      argumentInteger(0), memory))
  of "resize", "setLen":
    let wanted = argumentInteger(0)
    if wanted < 0 or
        (host.operation == "setLen" and wanted > capacity(receiver)):
      boolean(false)
      return
    if host.operation == "resize" and not reserveDynamic(receiver,
        layout, elementBytes, wanted, memory):
      boolean(false)
      return
    if layout.kind == SeqType and layouts[layout.elem].owned:
      for i in countdown(length(receiver) - 1, wanted):
        dropOwned(layouts, layout.elem,
          at(dataSlot(receiver), i * elementBytes), memory)
    if wanted > length(receiver) and
        (host.operation == "resize" or layout.kind == SeqType):
      zeroMem(at(dataSlot(receiver), length(receiver) * elementBytes),
        int((wanted - length(receiver)) * elementBytes))
      if layout.kind == SeqType:
        for i in length(receiver) ..< wanted:
          initializeValue(layouts, layout.elem,
            at(dataSlot(receiver), i * elementBytes))
    length(receiver) = wanted
    boolean(true)
  of "copyFrom":
    boolean(copyDynamicFrom(layouts, host.receiverType, receiver,
      argument(0), argumentLayout(0), memory))
  of "add", "push":
    if layout.kind == StringType:
      let source = argument(0)
      boolean(appendDynamic(receiver,
        dataPointer(source, argumentLayout(0)), length(source), memory))
    else:
      if length(receiver) == high(int64):
        boolean(false)
        return
      if layouts[layout.elem].owned:
        var scratch: array[128, uint64]
        let temporary = if elementBytes <= int64(sizeof(scratch)):
            cast[pointer](addr scratch[0])
          else:
            reallocate(memory, nil, csize_t(elementBytes))
        if temporary == nil:
          boolean(false)
          return
        zeroMem(temporary, int(elementBytes))
        if not copyOwnedZero(layouts, layout.elem, temporary,
            argument(0), memory):
          if temporary != cast[pointer](addr scratch[0]):
            release(memory, temporary)
          boolean(false)
          return
        if not reserveDynamic(receiver, layout, elementBytes,
            length(receiver) + 1, memory):
          dropOwned(layouts, layout.elem, temporary, memory)
          if temporary != cast[pointer](addr scratch[0]):
            release(memory, temporary)
          boolean(false)
          return
        copyMem(at(dataSlot(receiver), length(receiver) * elementBytes),
          temporary, int(elementBytes))
        if temporary != cast[pointer](addr scratch[0]):
          release(memory, temporary)
      else:
        if not reserveDynamic(receiver, layout, elementBytes,
            length(receiver) + 1, memory):
          boolean(false)
          return
        copyValue(at(dataSlot(receiver), length(receiver) * elementBytes),
          argument(0), layouts[layout.elem], argumentLayout(0))
      inc length(receiver)
      boolean(true)
  of "pop":
    dec length(receiver)
    copyMem(output, at(dataSlot(receiver), length(receiver) * elementBytes),
      int(elementBytes))
  of "get":
    zeroMem(output, int(layouts[host.resultType].bytes))
    let index = argumentInteger(0)
    if index >= 0 and index < length(receiver):
      if layout.kind == StringType:
        cast[ptr int64](output)[] = int64(
          cast[ptr byte](at(dataSlot(receiver), index))[])
        cast[ptr bool](at(output,
          layouts[host.resultType].okOffset))[] = true
      else:
        let element = layouts[layout.elem]
        copyMem(output, at(dataSlot(receiver), index * elementBytes),
          int(elementBytes))
        if not element.optional:
          cast[ptr bool](at(output,
            layouts[host.resultType].okOffset))[] = true
  of "addByte":
    var value = byte(argumentInteger(0))
    boolean(appendDynamic(receiver, addr value, 1, memory))
  of "addNum":
    var
      buffer: array[20, byte]
      count = 0
      magnitude = if argumentInteger(0) < 0:
          0'u64 - cast[uint64](argumentInteger(0))
        else:
          uint64(argumentInteger(0))
    while true:
      buffer[count] = byte(magnitude mod 10) + byte('0')
      inc count
      magnitude = magnitude div 10
      if magnitude == 0:
        break
    if argumentInteger(0) < 0:
      buffer[count] = byte('-')
      inc count
    var ordered: array[20, byte]
    for i in 0 ..< count:
      ordered[i] = buffer[count - i - 1]
    boolean(appendDynamic(receiver, addr ordered[0], count, memory))
  of "copyRange":
    let source = argument(0)
    let low = max(0'i64, min(length(source), argumentInteger(1)))
    let high = max(low, min(length(source), argumentInteger(2)))
    var section: array[3, uint64]
    let temporary = cast[pointer](addr section[0])
    zeroMem(temporary, 24)
    length(temporary) = high - low
    dataSlot(temporary) = at(dataPointer(source, argumentLayout(0)), low)
    boolean(copyDynamicFrom(layouts, host.receiverType, receiver,
      temporary, NativeLayout(dynamic: true), memory))
  of "startsWith", "endsWith", "contains", "find":
    let source = argument(0)
    let count = length(source)
    let data = dataSlot(receiver)
    let needle = dataPointer(source, argumentLayout(0))
    var found = -1'i64
    if count == 0:
      found = 0
    elif count <= length(receiver):
      if host.operation == "startsWith":
        if bytesEqual(data, needle, count):
          found = 0
      elif host.operation == "endsWith":
        if bytesEqual(at(data, length(receiver) - count), needle, count):
          found = length(receiver) - count
      else:
        for i in 0 .. length(receiver) - count:
          if bytesEqual(at(data, i), needle, count):
            found = i
            break
    if host.operation == "find":
      optionalInteger(output, layouts[host.resultType], found, found >= 0)
    else:
      boolean(found >= 0)
  of "findByte":
    var found = -1'i64
    for i in 0 ..< length(receiver):
      if cast[ptr byte](at(dataSlot(receiver), i))[] ==
          byte(argumentInteger(0)):
        found = i
        break
    optionalInteger(output, layouts[host.resultType], found, found >= 0)
  of "toInt":
    var value = 0'i64
    let present = parseInteger(receiver, -1, value)
    optionalInteger(output, layouts[host.resultType], value, present)
  else:
    discard

proc executeContainer*(host: NativeHost, layouts: seq[NativeLayout],
    receiver, args, output: pointer, memory = NativeMemory()) =
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
  if host.operation == "initialize":
    initializeValue(layouts, host.receiverType, receiver)
    return
  if host.operation == "toCString":
    let target = layouts[host.resultType]
    zeroMem(output, int(target.bytes))
    let count = length(receiver)
    if count < 0 or count == high(int64) or uint64(count) >= uint64(high(int)):
      return
    let source = dataPointer(receiver, layout)
    for i in 0 ..< count:
      if cast[ptr byte](at(source, i))[] == 0:
        return
    let address = reallocate(memory, nil, csize_t(count + 1))
    if address == nil:
      return
    if count > 0:
      copyMem(address, source, int(count))
    cast[ptr byte](at(address, count))[] = 0
    length(output) = count + 1 # Internal owner length includes its terminator.
    capacity(output) = count + 1
    dataSlot(output) = address
    cast[ptr bool](at(output, target.okOffset))[] = true
    return
  if host.operation == "drop":
    dropOwned(layouts, host.receiverType, receiver, memory)
    return
  if layout.dynamic:
    executeDynamic(host, layouts, receiver, args, output, memory)
    return
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
    of SeqType:
      if layouts[layout.elem].owned:
        let element = layouts[layout.elem]
        for i in countdown(length(receiver) - 1, 0'i64):
          dropOwned(layouts, layout.elem,
            at(receiver, int64(layout.dataOffset) + i * element.bytes),
            memory)
        zeroMem(at(receiver, layout.dataOffset),
          int(length(receiver) * element.bytes))
      length(receiver) = 0
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
      let index = if layout.kind == QueueType:
          (cast[ptr int64](at(receiver, 8))[] + length(receiver)) mod
            layout.capacity
        else: length(receiver)
      copyValue(at(receiver, int64(layout.dataOffset) + index * elementSize),
        argument(0), layouts[layout.elem], argumentLayout(0))
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
        dataPointer(source, argumentLayout(0)), int(count))
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
          dataPointer(source, argumentLayout(0)), count)
      boolean(found)
    of "contains", "find":
      let found = if argumentLayout(0).dynamic:
          block:
            let source = argument(0)
            var index = -1'i64
            if length(source) == 0:
              index = 0
            elif length(source) <= length(receiver):
              for i in 0 .. length(receiver) - length(source):
                if bytesEqual(at(data, i), dataPointer(source,
                    argumentLayout(0)), length(source)):
                  index = i
                  break
            index
        else:
          findString(receiver, argument(0), layout.dataOffset,
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
        moveMem(data, at(dataPointer(source, argumentLayout(0)), low),
          int(count))
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
      copyValue(output, argument(1), layouts[layout.val], argumentLayout(1))
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
        copyValue(at(receiver, int64(layout.valOffset) + index * valueSize),
          argument(1), layouts[layout.val], argumentLayout(1))
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
        copyValue(output, argument(1), layouts[layout.val], argumentLayout(1))
    else:
      discard
  of SparseMapType:
    template keyLayout: untyped = layouts[layout.key]
    let
      keySize = keyLayout.bytes
      valueSize = layouts[layout.val].bytes
      index = sparseFind(receiver, argument(0), layout, keyLayout,
        argumentLayout(0))
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
        copyValue(output, argument(1), layouts[layout.val], argumentLayout(1))
    of "put":
      if index >= 0:
        copyValue(valueAt(index), argument(1),
          layouts[layout.val], argumentLayout(1))
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
        copyValue(keyAt(position), argument(0), keyLayout, argumentLayout(0))
        copyValue(valueAt(position), argument(1),
          layouts[layout.val], argumentLayout(1))
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

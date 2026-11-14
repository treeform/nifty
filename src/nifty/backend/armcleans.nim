const DefaultArmBranchPairs* = not defined(nimkeyNoArmBranchPairs) and
  not defined(nimkeyNoArmCleanup)

type
  CleanBranch = enum
    NoCleanBranch, JumpCleanBranch, CallCleanBranch, TestCleanBranch,
    BitCleanBranch

  StackStore = object
    valid: bool
    offset: int
    bytes: int
    floating: bool
    source: uint32

proc cleanSigned(value: uint32, bits: int): int {.raises: [].} =
  ## Decodes one signed PC-relative displacement in instruction words.
  let sign = 1 shl (bits - 1)
  (value.int xor sign) - sign

proc cleanBranch(word: uint32): CleanBranch {.raises: [].} =
  ## Selects the PC-relative instruction forms emitted by this assembler.
  if (word and 0xFC000000'u32) == 0x14000000'u32:
    JumpCleanBranch
  elif (word and 0xFC000000'u32) == 0x94000000'u32:
    CallCleanBranch
  elif (word and 0xFF000010'u32) == 0x54000000'u32 or
      (word and 0x7E000000'u32) == 0x34000000'u32:
      TestCleanBranch
  elif (word and 0x7E000000'u32) == 0x36000000'u32:
    BitCleanBranch
  else:
    NoCleanBranch

proc cleanNoop(word: uint32): bool {.raises: [].} =
  ## Recognizes identities without discarding flags or 32-bit zero extension.
  let
    destination = word and 31
    source = (word shr 5) and 31
  if (word and 0xFFE0FFE0'u32) == 0xAA0003E0'u32:
    return destination == ((word shr 16) and 31) or destination == 31
  if (word and 0xFFFFFC00'u32) == 0x1E604000'u32:
    return destination == source
  if (word and 0xFF000000'u32) in [0x91000000'u32, 0xD1000000'u32] and
      ((word shr 10) and 4095) == 0:
      return destination == source
  word == 0xD503201F'u32

proc cleanup*(assembler: var Assembler, roots: openArray[Label],
    branchPairs = DefaultArmBranchPairs)
    {.raises: [BackendError].} =
  ## Compacts resolved ARM64 text and remaps every branch and entry label.
  ## Roots must include every indirectly callable entry in the image.
  if assembler.fixups.len != 0:
    fail("ARM64 cleanup requires resolved branches")
  for pass in 0 ..< 2:
    let size = assembler.code.len
    if size == 0:
      return
    var
      destinations = newSeq[int](size)
      kinds = newSeq[CleanBranch](size)
      boundary = newSeq[bool](size + 1)
      live = newSeq[bool](size)
      keep = newSeq[bool](size)
      words = assembler.code
      pending = @[0]
    for i, word in words:
      if (word and 0x1F000000'u32) == 0x10000000'u32 or
          (word and 0x3B000000'u32) == 0x18000000'u32:
          fail("ARM64 cleanup does not support this PC-relative instruction")
      kinds[i] = cleanBranch(word)
      destinations[i] = -1
      case kinds[i]
      of JumpCleanBranch, CallCleanBranch:
        destinations[i] = i + cleanSigned(word and 0x03FFFFFF, 26)
      of TestCleanBranch:
        destinations[i] = i + cleanSigned((word shr 5) and 0x7FFFF, 19)
      of BitCleanBranch:
        destinations[i] = i + cleanSigned((word shr 5) and 0x3FFF, 14)
      of NoCleanBranch:
        discard
      if kinds[i] != NoCleanBranch and
          (destinations[i] < 0 or destinations[i] > size):
        fail("ARM64 cleanup found an invalid branch target")
    for i in 0 ..< size:
      var destination = destinations[i]
      if kinds[i] == NoCleanBranch:
        continue
      for hop in 0 ..< 32:
        if destination < 0 or destination >= size or
            kinds[destination] != JumpCleanBranch or
            destinations[destination] == destination:
            break
        let candidate = destinations[destination]
        if kinds[i] == TestCleanBranch and
            (candidate - i < -(1 shl 18) or candidate - i >= (1 shl 18)):
            break
        if kinds[i] == BitCleanBranch and
            (candidate - i < -(1 shl 13) or candidate - i >= (1 shl 13)):
            break
        destination = candidate
      destinations[i] = destination
      if destination >= 0:
        boundary[destination] = true
    for position in assembler.targets:
      if position > size:
        fail("ARM64 cleanup found a label outside emitted text")
      if position >= 0 and position <= size:
        boundary[position] = true
    for root in roots:
      let index = root.int
      if index < 0 or index >= assembler.targets.len or
          assembler.targets[index] < 0:
          fail("ARM64 cleanup found an invalid entry label")
      pending.add(assembler.targets[index])
    # Invert only when the skipped jump has no independent entry.
    if branchPairs and DefaultArmBranchPairs:
      for i in 0 ..< size - 1:
        if kinds[i] notin {TestCleanBranch, BitCleanBranch} or
          destinations[i] != i + 2 or
          kinds[i + 1] != JumpCleanBranch or boundary[i + 1]:
            continue
        let
          destination = destinations[i + 1]
          distance = destination - i
          limit = if kinds[i] == BitCleanBranch: 1 shl 13 else: 1 shl 18
          flags = (words[i] and 0xFF000010'u32) == 0x54000000'u32
        if distance < -limit or distance >= limit or
          (flags and (words[i] and 15) >= 14):
            continue
        words[i] = words[i] xor (if flags: 1'u32 else: 0x01000000'u32)
        destinations[i] = destination
        words[i + 1] = 0xD503201F'u32
        kinds[i + 1] = NoCleanBranch
        destinations[i + 1] = -1
    var cursor = 0
    while cursor < pending.len:
      let position = pending[cursor]
      inc cursor
      if position < 0 or position >= size or live[position]:
        continue
      live[position] = true
      let word = words[position]
      if kinds[position] != NoCleanBranch:
        pending.add(destinations[position])
      if kinds[position] == JumpCleanBranch or
          (word and 0xFFFFFC1F'u32) in [0xD61F0000'u32, 0xD65F0000'u32]:
          continue
      pending.add(position + 1)
    const NoAddress = int.low
    var
      addresses: array[32, int]
      stored: StackStore
    for address in addresses.mitems:
      address = NoAddress
    for i in 0 ..< size:
      if boundary[i]:
        for address in addresses.mitems:
          address = NoAddress
        stored.valid = false
      if not live[i]:
        continue
      var word = words[i]
      if cleanNoop(word):
        continue
      keep[i] = true
      let
        destination = int(word and 31)
        base = int((word shr 5) and 31)
      if (word and 0xFF000000'u32) in [0x91000000'u32, 0xD1000000'u32]:
        let
          immediate = int((word shr 10) and 4095) shl
            (if (word and 0x00400000) == 0: 0 else: 12)
          offset = if (word and 0x40000000) == 0: immediate else: -immediate
          address = if base == 31: 0 else: addresses[base]
        if destination != 31 and address != NoAddress:
          let result = address + offset
          if addresses[destination] == result:
            keep[i] = false
          else:
            addresses[destination] = result
            if stored.valid and not stored.floating and
                stored.source.int == destination:
                stored.valid = false
          continue
      elif (word and 0x3B000000'u32) == 0x39000000'u32 and
          ((word shr 22) and 3) <= 1:
          let
            floating = (word and 0x04000000) != 0
            bytes = 1 shl int(word shr 30)
            offset = int((word shr 10) and 4095) * bytes
            address = if base == 31: 0 else: addresses[base]
            loading = (word and 0x00400000) != 0
          if address != NoAddress and (not floating or bytes in [4, 8]):
            let position = address + offset
            if not loading:
              if stored.valid and stored.offset == position and
                  stored.bytes == bytes and stored.floating == floating and
                  stored.source.int == destination:
                  keep[i] = false
              stored = StackStore(valid: true, offset: position, bytes: bytes,
                floating: floating, source: destination.uint32)
            else:
              if stored.valid and stored.offset == position and
                  stored.bytes == bytes and stored.floating == floating:
                  let source = stored.source
                  word = if floating:
                      (if bytes == 4: 0x1E204000'u32 else: 0x1E604000'u32) or
                        (source shl 5) or destination.uint32
                    elif bytes == 8:
                      0xAA0003E0'u32 or (source shl 16) or destination.uint32
                    elif bytes == 4:
                      0x2A0003E0'u32 or (source shl 16) or destination.uint32
                    else:
                      0xD3400000'u32 or ((bytes * 8 - 1).uint32 shl 10) or
                        (source shl 5) or destination.uint32
                  words[i] = word
                  if cleanNoop(word):
                    keep[i] = false
              elif stored.valid and stored.floating == floating and
                  stored.source.int == destination:
                  stored.valid = false
              if not floating and destination != 31:
                addresses[destination] = NoAddress
            continue
      for address in addresses.mitems:
        address = NoAddress
      stored.valid = false
    var mapping = newSeq[int](size + 1)
    var length = 0
    for i in 0 ..< size:
      mapping[i] = length
      if keep[i]:
        inc length
    mapping[size] = length
    for i in 0 ..< size:
      if keep[i] and kinds[i] in
        {JumpCleanBranch, TestCleanBranch, BitCleanBranch} and
          destinations[i] >= 0 and
          mapping[destinations[i]] == mapping[i] + 1:
          keep[i] = false
    length = 0
    for i in 0 ..< size:
      mapping[i] = length
      if keep[i]:
        inc length
    mapping[size] = length
    var output = newSeqOfCap[uint32](length)
    for i in 0 ..< size:
      if not keep[i]:
        continue
      var word = words[i]
      if kinds[i] != NoCleanBranch:
        let distance = mapping[destinations[i]] - mapping[i]
        if kinds[i] in {JumpCleanBranch, CallCleanBranch}:
          if distance < -(1 shl 25) or distance >= (1 shl 25):
            fail("Cleaned ARM64 branch is out of range")
          word = (word and not 0x03FFFFFF'u32) or
            (uint32(distance) and 0x03FFFFFF'u32)
        elif kinds[i] == BitCleanBranch:
          if distance < -(1 shl 13) or distance >= (1 shl 13):
            fail("Cleaned ARM64 bit branch is out of range")
          word = (word and not 0x0007FFE0'u32) or
            ((uint32(distance) and 0x3FFF'u32) shl 5)
        else:
          if distance < -(1 shl 18) or distance >= (1 shl 18):
            fail("Cleaned ARM64 conditional branch is out of range")
          word = (word and not 0x00FFFFE0'u32) or
            ((uint32(distance) and 0x7FFFF'u32) shl 5)
      output.add(word)
    for target in assembler.targets.mitems:
      if target >= 0:
        target = mapping[target]
    assembler.code = move(output)

## Execute emitter memory fallbacks without optimization passes.
import nifty/backend/[engine, context, memories]
when defined(posix):
  import std/posix

type Entry = proc(ctx, source, destination, reserved: pointer)
  {.cdecl, raises: [].}

proc memoryFunction(op: IrOpcode, bytes: int,
    identity = false): IrFunction =
  ## Creates one fixed-size operation with alignment-one pointer arguments.
  result.name = $op & $bytes
  result.failureMode = NoFailCall
  result.signature.parameters = @[
    AddressType, AddressType, AddressType, AddressType]
  for i in 0 ..< 4:
    result.values.add(IrValue(valueType: AddressType))
  result.blocks.add(IrBlock(parameters: Span(first: 0, count: 4),
    instructions: Span(first: 0, count: 1),
    terminator: IrTerminator(kind: ReturnTerminator)))
  result.operands = @[ValueId(2)]
  if op == MoveBytesOp:
    result.operands.add(ValueId(if identity: 2 else: 1))
  result.instructions.add(IrInstruction(op: op, byteCount: int32(bytes),
    alignment: 1, arguments: Span(first: 0,
      count: int32(result.operands.len))))

var module = IrModule(pointerBytes: 8)
for op in [MoveBytesOp, ClearBytesOp]:
  for bytes in 0 .. 300:
    module.functions.add(memoryFunction(op, bytes))
module.functions.add(memoryFunction(MoveBytesOp, 300, identity = true))
for bytes in [511, 512, 513, 1023, 1024, 1025, 4095, 4096, 4097]:
  for op in [MoveBytesOp, ClearBytesOp]:
    module.functions.add(memoryFunction(op, bytes))

for target in NativeTarget:
  let image = emitNative(module, target)
  echo target, " memory image: ", image.bytes.len, " bytes"
  when defined(arm64) or defined(amd64):
    const Native = when defined(arm64): Arm64Target else: Amd64Target
    if target != Native:
      continue
    var
      buffer = initCodeBuffer(image.bytes)
      ctx: RuntimeContext
      actual, expected: array[12288, byte]
      cases = 0
    proc entry(index: int): Entry =
      ## Resolves each directly callable native function in the emitted image.
      cast[Entry](cast[uint](buffer.entry()) + uint(image.offsets[index]))
    proc fill() =
      ## Restores a varying pattern so incomplete or excessive writes differ.
      for i in 0 ..< actual.len:
        actual[i] = byte((i * 29 + i div 251) mod 256)
      expected = actual
    proc move(index, source, destination, bytes: int) =
      ## Compares complete memory against a source snapshot, including guards.
      fill()
      for i in 0 ..< bytes:
        expected[destination + i] = actual[source + i]
      entry(index)(ctx.addr, actual[source].addr, actual[destination].addr, nil)
      doAssert actual == expected,
        "Move " & $bytes & " from " & $source & " to " & $destination
      inc cases
    proc clear(index, destination, bytes: int) =
      ## Checks both the cleared range and every untouched surrounding byte.
      fill()
      for i in 0 ..< bytes:
        expected[destination + i] = 0
      entry(index)(ctx.addr, nil, actual[destination].addr, nil)
      doAssert actual == expected, "Clear " & $bytes & " at " & $destination
      inc cases
    for bytes in 0 .. 300:
      for alignment in 0 .. 15:
        let source = 64 + alignment
        for delta in -17 .. 17:
          move(bytes, source, source + delta, bytes)
        move(bytes, source, 512 + alignment, bytes)
        move(bytes, 512 + alignment, source, bytes)
        clear(301 + bytes, source, bytes)
      # Equal pointers, including nil, must never access the pointed memory.
      entry(bytes)(ctx.addr, nil, nil, nil)
    entry(0)(ctx.addr, nil, cast[pointer](1), nil)
    entry(301)(ctx.addr, nil, nil, nil)
    entry(602)(ctx.addr, nil, nil, nil)
    for i, bytes in [511, 512, 513, 1023, 1024, 1025, 4095, 4096, 4097]:
      let index = 603 + i * 2
      for alignment in 0 .. 15:
        let source = 64 + alignment
        for delta in -17 .. 17:
          move(index, source, source + delta, bytes)
        move(index, source, 6144 + alignment, bytes)
        move(index, 6144 + alignment, source, bytes)
        clear(index + 1, source, bytes)
    echo target, " memory cases passed: ", cases

    when defined(posix):
      let pageBytes = int(sysconf(SC_PAGESIZE))
      proc guarded(): pointer =
        ## Places accessible storage between two inaccessible guard pages.
        result = mmap(nil, pageBytes * 3, PROT_NONE,
          MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
        doAssert result != MAP_FAILED
        let middle = cast[pointer](cast[uint](result) + uint(pageBytes))
        doAssert mprotect(middle, pageBytes, PROT_READ or PROT_WRITE) == 0
      let
        sourceMap = guarded()
        destinationMap = guarded()
      for bytes in 1 .. 300:
        for atEnd in [false, true]:
          let
            offset = if atEnd: pageBytes * 2 - bytes else: pageBytes
            source = cast[ptr UncheckedArray[byte]](
              cast[uint](sourceMap) + uint(offset))
            destination = cast[ptr UncheckedArray[byte]](
              cast[uint](destinationMap) + uint(offset))
          for i in 0 ..< bytes:
            source[i] = byte(i mod 256)
            destination[i] = 255
          entry(bytes)(ctx.addr, source, destination, nil)
          for i in 0 ..< bytes:
            doAssert destination[i] == source[i]
          entry(301 + bytes)(ctx.addr, nil, destination, nil)
          for i in 0 ..< bytes:
            doAssert destination[i] == 0
      doAssert munmap(sourceMap, pageBytes * 3) == 0
      doAssert munmap(destinationMap, pageBytes * 3) == 0
      echo target, " guarded memory bounds passed"

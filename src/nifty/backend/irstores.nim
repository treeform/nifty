import std/sets, irs, irchecks

type StoreRegion = tuple[address: int32, offset: int64, bytes: int32]

proc removeStores*(function: var IrFunction, pointerBytes: int32): bool =
  ## Removes writes overwritten within a block before any possible observation.
  var
    keep = newSeq[bool](function.instructions.len)
    instructions: seq[IrInstruction]
  for retained in keep.mitems:
    retained = true
  for data in function.blocks:
    var written = initHashSet[StoreRegion]()
    for index in countdown(
      int(data.instructions.first + data.instructions.count) - 1,
      int(data.instructions.first)
    ):
      let item = function.instructions[index]
      if item.volatile:
        written.clear()
        continue
      case item.op
      of StoreOp, LoadOp:
        let
          address = int32(function.operands[item.arguments.first])
          value =
            if item.op == LoadOp:
              item.results.first
            else:
              int32(function.operands[item.arguments.first + 1])
          bytes = byteCount(function.values[value].valueType, pointerBytes)
          region: StoreRegion = (address, item.offset, bytes)
        # Bound offset comparisons without assuming pointers are disjoint.
        if item.offset < -(1'i64 shl 41) or item.offset > (1'i64 shl 41):
          written.clear()
          continue
        if item.op == StoreOp:
          if region in written:
            keep[index] = false
            result = true
          written.incl(region)
        else:
          var observed: seq[StoreRegion]
          for later in written:
            if later.address != address or
              (later.offset < item.offset + bytes and
              item.offset < later.offset + later.bytes):
                observed.add(later)
          for later in observed:
            written.excl(later)
      of ConstantOp, AddOp, SubtractOp, MultiplyOp, NegateOp,
          AndOp, OrOp, XorOp, NotOp, ShiftLeftOp, ShiftRightOp,
          ArithmeticRightOp, CompareOp, SelectOp, SqrtOp, FloorOp, RoundOp,
          SlotAddressOp,
          GlobalAddressOp, OffsetAddressOp, FieldAddressOp, FrameSizeOp:
        discard
      of ConvertOp:
        if item.conversion == FloatIntegerConversion:
          written.clear()
      else:
        # Calls, copies, budgets, and possible arithmetic traps are barriers.
        written.clear()
  if not result:
    return
  for data in function.blocks.mitems:
    let first = int32(instructions.len)
    for index in data.instructions.indices:
      if keep[index]:
        instructions.add(function.instructions[index])
    data.instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)

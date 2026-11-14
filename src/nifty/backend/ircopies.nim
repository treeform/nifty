import irs

const
  CopyScratch* = int.low
  FloatCopyBase* = 32
  StackCopyBase* = 64
  DefaultIrUnusedCopies* = not defined(nimkeyNoIrUnusedCopies)

type IrCopy* = object
  source*: int
  destination*: int
  valueType*: IrType

proc copyLocation*(kind: IrType, register, offset: int): int =
  ## Encodes a target register bank or a byte offset in its spill frame.
  if register < 0:
    doAssert offset >= 0
    return StackCopyBase + offset
  doAssert register < FloatCopyBase
  register + (if kind in {Float32Type, Float64Type, Float32x2Type}: FloatCopyBase else: 0)

proc parameterUses*(function: IrFunction): seq[bool] =
  ## Finds entry parameters read by owned instructions, terminators, or edges.
  let parameters = function.blocks[0].parameters
  result = newSeq[bool](parameters.count)
  template read(span: Span) =
    ## Marks parameter reads without treating unused pool entries as code.
    for operand in span.indices:
      let value = int32(function.operands[operand]) - parameters.first
      if value >= 0 and value < parameters.count:
        result[value] = true
  for data in function.blocks:
    for index in data.instructions.indices:
      read(function.instructions[index].arguments)
    read(data.terminator.arguments)
    for edge in data.terminator.edges.indices:
      read(function.edges[edge].arguments)

proc parameterCopies*(function: IrFunction,
    incoming, locations: openArray[int],
    unusedCopies = DefaultIrUnusedCopies): seq[IrCopy] =
  ## Connects ABI inputs to allocated SSA parameters without staging storage.
  let
    parameters = function.blocks[0].parameters
    prune = unusedCopies and not defined(nimkeyNoIrUnusedCopies)
    used = if prune: parameterUses(function) else: @[]
  doAssert incoming.len == int(parameters.count)
  for i in 0 ..< int(parameters.count):
    if prune and not used[i]:
      continue
    let value = int(parameters.first) + i
    result.add(IrCopy(
      source: incoming[i],
      destination: locations[value],
      valueType: function.values[value].valueType
    ))

proc edgeCopies*(function: IrFunction, edgeIndex: int,
    locations: openArray[int]): seq[IrCopy] =
  ## Describes simultaneous SSA transfers independently of native encoding.
  let
    edge = function.edges[edgeIndex]
    parameters = function.blocks[int32(edge.target)].parameters
  for i in 0 ..< int(edge.arguments.count):
    let
      source = int32(function.operands[int(edge.arguments.first) + i])
      destination = parameters.first + int32(i)
    result.add(IrCopy(source: locations[source],
      destination: locations[destination],
      valueType: function.values[source].valueType))

proc scheduleCopies*(copies: openArray[IrCopy]): seq[IrCopy] =
  ## Schedules parallel assignments with one scratch payload only for cycles.
  var pending: seq[IrCopy]
  for item in copies:
    if item.source != item.destination:
      pending.add(item)
  while pending.len > 0:
    var ready = -1
    for i, item in pending:
      var needed = false
      for other in pending:
        needed = needed or other.source == item.destination
      if not needed:
        ready = i
        break
    if ready >= 0:
      result.add(pending[ready])
      pending.delete(ready)
    else:
      let location = pending[0].destination
      var kind = pending[0].valueType
      for item in pending:
        if item.source == location:
          kind = item.valueType
          break
      result.add(IrCopy(source: location, destination: CopyScratch,
        valueType: kind))
      for item in pending.mitems:
        if item.source == location:
          item.source = CopyScratch

import std/[algorithm, bitops], irs, irlifetimes

const
  MaxConflictBytes = 8 * 1024 * 1024
  DefaultIrFloatColors* = not defined(nimkeyNoIrFloatColors)
  DefaultAmdIrFloatColors* =
    defined(nimkeyAmdFloatColors) and DefaultIrFloatColors

type IrAllocation* = object
  registers*: seq[int32]
  ranges*: seq[IrLiveRange]
  spills*: int

proc floating*(kind: IrType): bool {.raises: [].} =
  ## Selects a distinct register file for binary32 and binary64 values.
  kind in {Float32Type, Float64Type, Float32x2Type}

proc preserved(mask: uint64, register: int): bool {.raises: [].} =
  ## Tests the target's explicit call-preserved register contract.
  register in 0 ..< 64 and (mask and (1'u64 shl register)) != 0

proc colorRegisters(function: IrFunction, analysis: IrLiveness,
    crossing: seq[bool], integers, floats: int,
    preservedIntegers, preservedFloats: uint64,
    fixedValues: openArray[bool], preferredRegisters: openArray[int32],
    graph: seq[uint64],
    floatingOnly = false, preferredPreservedFloats = 0'u64): IrAllocation =
  ## Colors exact conflicts while preferring incoming block argument locations.
  var
    allocation = IrAllocation(ranges: analysis.ranges,
      registers: newSeq[int32](function.values.len))
    degrees = newSeq[int](function.values.len)
    preferences = newSeq[seq[int]](function.values.len)
    order: seq[int]
  for value in 0 ..< function.values.len:
    allocation.registers[value] = -1
    if analysis.ranges[value].first < 0 or
        (fixedValues.len > 0 and fixedValues[value]) or
        (floatingOnly and not function.values[value].valueType.floating()):
        continue
    order.add(value)
    for word in 0 ..< analysis.words:
      var bits = graph[value * analysis.words + word]
      while bits != 0:
        let other = word * 64 + countTrailingZeroBits(bits)
        if function.values[value].valueType.floating() ==
            function.values[other].valueType.floating():
          inc degrees[value]
        bits = bits and (bits - 1)
  for edge in function.edges:
    for i in 0 ..< int(edge.arguments.count):
      let
        source = int(int32(function.operands[int(edge.arguments.first) + i]))
        target = int(function.blocks[int32(edge.target)].parameters.first) + i
      preferences[source].add(target)
      preferences[target].add(source)
  order.sort(proc(a, b: int): int =
    ## Gives more constrained live values priority, with stable tie breaking.
    result = cmp(degrees[b], degrees[a])
    if result == 0:
      result = cmp(a, b))
  for value in order:
    let
      count = if function.values[value].valueType.floating(): floats
        else: integers
      mask = if function.values[value].valueType.floating(): preservedFloats
        else: preservedIntegers
      crossesCall = crossing[value]
    var occupied = newSeq[bool](max(0, count))
    if crossesCall and mask == 0:
      continue
    if crossesCall:
      for register in 0 ..< occupied.len:
        occupied[register] = not preserved(mask, register)
    for word in 0 ..< analysis.words:
      var bits = graph[value * analysis.words + word]
      while bits != 0:
        let other = word * 64 + countTrailingZeroBits(bits)
        if function.values[value].valueType.floating() ==
            function.values[other].valueType.floating():
          let register = allocation.registers[other]
          if register >= 0:
            occupied[register] = true
        bits = bits and (bits - 1)
    if crossesCall and function.values[value].valueType.floating():
      for register in 0 ..< occupied.len:
        if preserved(preferredPreservedFloats, register) and
            not occupied[register]:
          allocation.registers[value] = int32(register)
          break
    if allocation.registers[value] < 0 and preferredRegisters.len > 0:
      let register = preferredRegisters[value]
      if register >= 0 and register < int32(count) and not occupied[register]:
        allocation.registers[value] = register
    for other in preferences[value]:
      if allocation.registers[value] >= 0:
        break
      let register = allocation.registers[other]
      if register >= 0 and not occupied[register]:
        allocation.registers[value] = register
        break
    if allocation.registers[value] < 0:
      for register in 0 ..< occupied.len:
        if not occupied[register]:
          allocation.registers[value] = int32(register)
          break
  for value in order:
    if allocation.registers[value] < 0:
      inc allocation.spills
  result = move(allocation)

proc allocateRegisters*(function: IrFunction, integers = 6,
    floats = 16, coalesce = false, preservedIntegers = 0'u64,
    preservedFloats = 0'u64,
    fixedValues: openArray[bool] = [],
    holes = not defined(nimkeyNoIrLiveHoles),
    affinity = not defined(nimkeyNoIrOperandAffinity),
    floatColors = DefaultIrFloatColors,
    preferredRegisters: openArray[int32] = [],
    preferredPreservedFloats = 0'u64): IrAllocation =
  ## Scans integer definitions and colors floating conflicts within the bound.
  doAssert fixedValues.len == 0 or fixedValues.len == function.values.len
  doAssert preferredRegisters.len == 0 or
    preferredRegisters.len == function.values.len
  let
    analysis = analyzeLiveness(function)
    crossing = liveAcrossCalls(function, analysis)
  var
    allocation = IrAllocation(ranges: analysis.ranges)
    order: seq[int]
    active: seq[int]
  allocation.registers = newSeq[int32](function.values.len)
  for register in allocation.registers.mitems:
    register = -1
  for value, interval in analysis.ranges:
    if interval.first >= 0 and
        (fixedValues.len == 0 or not fixedValues[value]):
        order.add(value)
  order.sort(proc(a, b: int): int =
    ## Orders definitions deterministically before assigning finite registers.
    result = cmp(analysis.ranges[a].first, analysis.ranges[b].first)
    if result == 0:
      result = cmp(a, b))
  if coalesce:
    return colorRegisters(function, analysis, crossing, integers, floats,
      preservedIntegers, preservedFloats, fixedValues, preferredRegisters,
      interference(function, analysis),
      preferredPreservedFloats = preferredPreservedFloats)
  let
    exact = holes and function.values.len <=
      MaxConflictBytes div sizeof(uint64) div max(1, analysis.words)
    graph = if exact: interference(function, analysis) else: @[]
  var preferred = newSeq[int](function.values.len)
  for value in preferred.mitems:
    value = -1
  if affinity:
    for item in function.instructions:
      if item.results.count == 1 and item.arguments.count > 0:
        let source = int(function.operands[item.arguments.first])
        if function.values[source].valueType.floating() ==
            function.values[item.results.first].valueType.floating():
          preferred[item.results.first] = source
  proc conflicts(a, b: int): bool =
    ## Falls back to intervals when exact conflicts exceed the memory bound.
    not exact or (graph[a * analysis.words + b div 64] and
      (1'u64 shl (b mod 64))) != 0
  for value in order:
    let
      interval = analysis.ranges[value]
      isFloat = function.values[value].valueType.floating()
      count = if isFloat: floats else: integers
      mask = if isFloat: preservedFloats else: preservedIntegers
      crossesCall = crossing[value]
    if floatColors and exact and isFloat:
      continue
    var
      kept: seq[int]
      occupied = newSeq[bool](max(0, count))
      owners = newSeq[int](max(0, count))
    for other in active:
      if analysis.ranges[other].last >= interval.first:
        kept.add(other)
        if function.values[other].valueType.floating() == isFloat and
            conflicts(value, other):
          occupied[allocation.registers[other]] = true
          inc owners[allocation.registers[other]]
    active = move(kept)
    if crossesCall and mask == 0:
      continue
    if crossesCall:
      for register in 0 ..< occupied.len:
        occupied[register] = occupied[register] or not preserved(mask, register)
    if crossesCall and isFloat:
      for register in 0 ..< occupied.len:
        if preserved(preferredPreservedFloats, register) and
            not occupied[register]:
          allocation.registers[value] = int32(register)
          break
    if allocation.registers[value] < 0 and preferredRegisters.len > 0:
      let register = preferredRegisters[value]
      if register >= 0 and register < int32(count) and not occupied[register]:
        allocation.registers[value] = register
    let source = preferred[value]
    # Prefer a dying input only after applying conflicts and call masks.
    # This assigns locations without aliasing distinct SSA values.
    if source >= 0 and allocation.registers[value] < 0:
      let register = allocation.registers[source]
      if register >= 0 and not occupied[register]:
        allocation.registers[value] = register
    if allocation.registers[value] < 0:
      for register in 0 ..< occupied.len:
        if not occupied[register]:
          allocation.registers[value] = int32(register)
          break
    if allocation.registers[value] < 0:
      var victim = -1
      for other in active:
        if function.values[other].valueType.floating() == isFloat and
            conflicts(value, other) and
            owners[allocation.registers[other]] == 1 and
            (not crossesCall or
            preserved(mask, int(allocation.registers[other]))) and
            analysis.ranges[other].last > interval.last and
            (victim < 0 or analysis.ranges[other].last >
              analysis.ranges[victim].last):
          victim = other
      if victim >= 0:
        allocation.registers[value] = allocation.registers[victim]
        allocation.registers[victim] = -1
        active.delete(active.find(victim))
    if allocation.registers[value] >= 0:
      active.add(value)
  if floatColors and exact:
    let colored = colorRegisters(
      function,
      analysis,
      crossing,
      integers,
      floats,
      preservedIntegers,
      preservedFloats,
      fixedValues,
      preferredRegisters,
      graph,
      floatingOnly = true,
      preferredPreservedFloats = preferredPreservedFloats
    )
    for value in order:
      if function.values[value].valueType.floating():
        allocation.registers[value] = colored.registers[value]
  for value in order:
    if allocation.registers[value] < 0:
      inc allocation.spills
  result = move(allocation)

proc dumpAllocation*(function: IrFunction): string =
  ## Prints the actual abstract register assignments before target mapping.
  let allocation = allocateRegisters(function, coalesce = true)
  for value, register in allocation.registers:
    if allocation.ranges[value].first < 0:
      continue
    result.add("r" & $value & ": ")
    if register < 0:
      result.add("spill")
    else:
      result.add(if function.values[value].valueType.floating(): "fp" else: "gp")
      result.add($register)
    result.add("\n")

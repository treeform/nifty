import irs, irbranches, arms

type
  ArmBitPlan* = object
    inputs*: seq[ValueId]
    bits*: seq[int]
    whenSet*: seq[bool]
    skipped*: seq[bool]
    omitted*: seq[bool]
  ArmImmediatePlan* = object
    sides*: seq[int]
    bits*: seq[uint64]
    omitted*: seq[bool]
  ArmFloatZeroPlan* = object
    comparisons*: seq[bool]
    omitted*: seq[bool]

proc floatAbiPreferences*(function: IrFunction): seq[int32] {.raises: [].} =
  ## Suggests ABI colors without overriding conflicts or call preservation.
  result = newSeq[int32](function.values.len)
  for register in result.mitems:
    register = -1
  proc floating(kind: IrType): bool =
    ## Identifies the private ABI's independent floating argument bank.
    kind in {Float32Type, Float64Type, Float32x2Type}
  var bank = 0
  for i, kind in function.signature.parameters:
    if floating(kind):
      if bank < 6:
        result[function.blocks[0].parameters.first + int32(i)] = int32(bank)
      inc bank
  for data in function.blocks:
    for index in data.instructions.indices:
      let item = function.instructions[index]
      if item.op notin {CallOp, HostCallOp, IndirectCallOp}:
        continue
      bank = 0
      for i in ord(item.op == IndirectCallOp) ..< int(item.arguments.count):
        let value = function.operands[item.arguments.first + int32(i)]
        if floating(function.values[int32(value)].valueType):
          if bank < 6:
            result[int32(value)] = int32(bank)
          inc bank
      for i in 0 ..< int(item.results.count):
        let value = item.results.first + int32(i)
        if i < 6 and floating(function.values[value].valueType):
          result[value] = int32(i)
    if data.terminator.kind == ReturnTerminator:
      for i in 0 ..< int(data.terminator.arguments.count):
        let value = function.operands[
          data.terminator.arguments.first + int32(i)]
        if i < 6 and floating(function.values[int32(value)].valueType):
          result[int32(value)] = int32(i)

proc floatLoadPairs*(function: IrFunction, registers: openArray[int32],
    enabled = true): seq[bool] {.raises: [].} =
  ## Selects adjacent same-width floating loads after register allocation.
  result = newSeq[bool](function.instructions.len)
  if not enabled:
    return
  for data in function.blocks:
    var index = int(data.instructions.first)
    let finish = index + int(data.instructions.count)
    while index + 1 < finish:
      let
        first = function.instructions[index]
        second = function.instructions[index + 1]
      if first.op == LoadOp and second.op == LoadOp and
        not first.volatile and not second.volatile and
        first.results.count == 1 and second.results.count == 1 and
        first.arguments.count == 1 and second.arguments.count == 1 and
        function.values[first.results.first].valueType in
          {Float32Type, Float64Type} and
        function.values[second.results.first].valueType ==
          function.values[first.results.first].valueType and
        int32(function.operands[first.arguments.first]) ==
          int32(function.operands[second.arguments.first]) and
        registers[first.results.first] >= 0 and
        registers[second.results.first] >= 0 and
        registers[first.results.first] != registers[second.results.first]:
          let width = if function.values[first.results.first].valueType ==
              Float32Type: 4'i64 else: 8'i64
          if first.offset >= -64 * width and first.offset <= 63 * width and
              first.offset mod width == 0 and
              second.offset == first.offset + width:
            result[index] = true
            inc index
      inc index

proc floatZeroComparisons*(function: IrFunction, enabled = true):
    ArmFloatZeroPlan {.raises: [].} =
  ## Selects exact positive floating zero without an unused register.
  result.comparisons = newSeq[bool](function.instructions.len)
  result.omitted = newSeq[bool](function.values.len)
  if not enabled:
    return
  var
    zeros = newSeq[bool](function.values.len)
    uses = newSeq[int](function.values.len)
    selected = newSeq[int](function.values.len)
  proc observe(span: Span) =
    ## Counts all active uses, including terminators and edge arguments.
    for index in span.indices:
      inc uses[int32(function.operands[index])]
  for data in function.blocks:
    for index in data.instructions.indices:
      let item = function.instructions[index]
      observe(item.arguments)
      if item.op == ConstantOp and item.results.count == 1 and
        not item.volatile and item.bits == 0 and
        function.values[item.results.first].valueType in
          {Float32Type, Float64Type}:
          zeros[item.results.first] = true
    observe(data.terminator.arguments)
    for index in data.terminator.edges.indices:
      observe(function.edges[index].arguments)
  for data in function.blocks:
    for index in data.instructions.indices:
      let item = function.instructions[index]
      if item.op != CompareOp or item.arguments.count != 2:
        continue
      let right = int32(function.operands[item.arguments.first + 1])
      if zeros[right]:
        result.comparisons[index] = true
        inc selected[right]
  for value in 0 ..< uses.len:
    result.omitted[value] = zeros[value] and uses[value] > 0 and
      uses[value] == selected[value]

proc integerWidth(kind: IrType): int {.raises: [].} =
  ## Limits immediate selection to ordinary fixed-width integer values.
  case kind
  of Int8Type, UInt8Type: 8
  of Int16Type, UInt16Type: 16
  of Int32Type, UInt32Type: 32
  of Int64Type, UInt64Type: 64
  else: 0

proc integerLiteral(bits: uint64, kind: IrType): uint64 {.raises: [].} =
  ## Matches the canonical register representation used by normalization.
  let width = integerWidth(kind)
  result = bits
  if width > 0 and width < 64:
    let mask = (1'u64 shl width) - 1
    result = result and mask
    if kind in {Int8Type, Int16Type, Int32Type} and
      (result and (1'u64 shl (width - 1))) != 0:
        result = result or not mask

proc integerImmediates*(function: IrFunction): ArmImmediatePlan
    {.raises: [].} =
  ## Selects constant operands and omits definitions with no register uses.
  result.sides = newSeq[int](function.instructions.len)
  result.bits = newSeq[uint64](function.instructions.len)
  result.omitted = newSeq[bool](function.values.len)
  for side in result.sides.mitems:
    side = -1
  when defined(nimkeyArmIntegerImmediates) and
    not defined(nimkeyNoArmIntegerImmediates):
    var
      known = newSeq[bool](function.values.len)
      literals = newSeq[uint64](function.values.len)
      uses = newSeq[int](function.values.len)
      selected = newSeq[int](function.values.len)
      inputs = newSeq[int32](function.values.len)
      heads = newSeq[int32](function.values.len)
      next = newSeq[int32](function.values.len)
    for input in inputs.mitems:
      input = -1
    for head in heads.mitems:
      head = -1
    proc observe(span: Span) =
      ## Counts only operands reachable through active instruction spans.
      for i in span.indices:
        inc uses[int32(function.operands[i])]
    for data in function.blocks:
      for i in data.instructions.indices:
        let item = function.instructions[i]
        observe(item.arguments)
        if item.op == ConvertOp and item.conversion == BitcastConversion and
          item.arguments.count == 1 and item.results.count == 1:
            let
              value = item.results.first
              input = int32(function.operands[item.arguments.first])
              width = integerWidth(function.values[value].valueType)
            if width > 0 and
              width == integerWidth(function.values[input].valueType):
                inputs[value] = input
                next[value] = heads[input]
                heads[input] = value
        if item.op != ConstantOp or item.results.count != 1:
          continue
        let
          value = item.results.first
          kind = function.values[value].valueType
          width = integerWidth(kind)
        if width == 0:
          continue
        known[value] = true
        literals[value] = integerLiteral(item.bits, kind)
      observe(data.terminator.arguments)
      for edge in data.terminator.edges.indices:
        observe(function.edges[edge].arguments)
    var pending: seq[int]
    for value, literal in known:
      if literal:
        pending.add(value)
    while pending.len > 0:
      let input = pending.pop()
      var value = heads[input]
      while value >= 0:
        known[value] = true
        literals[value] = integerLiteral(
          literals[input], function.values[value].valueType
        )
        pending.add(int(value))
        value = next[value]
    for data in function.blocks:
      for i in data.instructions.indices:
        let item = function.instructions[i]
        if item.op notin {AndOp, OrOp, XorOp, ShiftLeftOp, ShiftRightOp,
          ArithmeticRightOp} or item.arguments.count != 2:
            continue
        for side in countdown(1, 0):
          if side == 0 and item.op notin {AndOp, OrOp, XorOp}:
            break
          let value = int32(function.operands[item.arguments.first + side])
          if not known[value]:
            continue
          let literal = literals[value]
          if item.op in {AndOp, OrOp, XorOp}:
            if logicalEncoding(Word64, literal) < 0:
              continue
          elif literal >= 64:
            continue
          result.sides[i] = side
          result.bits[i] = literal
          inc selected[value]
          break
    for value in 0 ..< uses.len:
      if known[value] and uses[value] > 0 and uses[value] == selected[value]:
        pending.add(value)
    while pending.len > 0:
      let value = pending.pop()
      if result.omitted[value]:
        continue
      result.omitted[value] = true
      let input = inputs[value]
      if input >= 0:
        inc selected[input]
        if selected[input] == uses[input]:
          pending.add(int(input))

proc selectFlags*(function: IrFunction): IrSelectPlan {.raises: [].} =
  ## Keeps ARM64 comparison flags across constants and matching selections.
  when defined(nimkeyNoArmSelectFlags):
    result.comparisons = newSeq[int32](function.instructions.len)
    result.conditions = newSeq[bool](function.values.len)
    for comparison in result.comparisons.mitems:
      comparison = -1
  else:
    result = selectComparisons(function, {ConstantOp, FrameSizeOp})

proc bitIndex(bits: uint64, kind: IrType): int {.raises: [].} =
  ## Recognizes one meaningful bit at the operand's declared integer width.
  let width = case kind
    of BoolType: 1
    of CharType, Int8Type, UInt8Type: 8
    of Int16Type, UInt16Type: 16
    of Int32Type, UInt32Type: 32
    of Int64Type, UInt64Type: 64
    else: 0
  if width == 0:
    return -1
  let mask = if width == 64: bits else: bits and ((1'u64 shl width) - 1)
  if mask == 0 or (mask and (mask - 1)) != 0:
    return -1
  result = 0
  var value = mask
  while value > 1:
    value = value shr 1
    inc result

proc bitBranches*(function: IrFunction, branches: IrBranchPlan): ArmBitPlan
    {.raises: [].} =
  ## Fuses single-use bit masks with adjacent zero-comparison branches.
  result.inputs = newSeq[ValueId](function.blocks.len)
  result.bits = newSeq[int](function.blocks.len)
  result.whenSet = newSeq[bool](function.blocks.len)
  result.skipped = newSeq[bool](function.instructions.len)
  result.omitted = newSeq[bool](function.values.len)
  for input in result.inputs.mitems:
    input = NoValue
  when defined(nimkeyArmBitBranches) and
    not defined(nimkeyNoArmBitBranches) and
    not defined(nimkeyNoCompareBranches) and
    not defined(nimkeyNoArmCleanup):
      var
        definitions = newSeq[int](function.values.len)
        uses = newSeq[int](function.values.len)
      for definition in definitions.mitems:
        definition = -1
      proc observe(span: Span) =
        ## Counts only active instruction, terminator, and edge operands.
        for i in span.indices:
          inc uses[int32(function.operands[i])]
      for data in function.blocks:
        for i in data.instructions.indices:
          let item = function.instructions[i]
          for value in item.results.indices:
            definitions[value] = i
          observe(item.arguments)
        observe(data.terminator.arguments)
        for edge in data.terminator.edges.indices:
          observe(function.edges[edge].arguments)
      for owner, comparison in branches.comparisons:
        if comparison < 0:
          continue
        let predicate = function.instructions[comparison]
        if predicate.comparison notin {EqualComparison, NotEqualComparison}:
          continue
        for side in 0 .. 1:
          let
            masked = function.operands[predicate.arguments.first + int32(side)]
            zero = function.operands[predicate.arguments.first + int32(1 - side)]
            maskAt = definitions[int32(masked)]
            zeroAt = definitions[int32(zero)]
          if maskAt < function.blocks[owner].instructions.first or
            maskAt >= comparison or zeroAt < 0 or uses[int32(masked)] != 1:
              continue
          let
            mask = function.instructions[maskAt]
            constant = function.instructions[zeroAt]
          if mask.op != AndOp or constant.op != ConstantOp or
            constant.bits != 0:
              continue
          for operand in 0 .. 1:
            let
              input = function.operands[mask.arguments.first + int32(operand)]
              literal = function.operands[mask.arguments.first + int32(1 - operand)]
              at = definitions[int32(literal)]
            if at < 0 or function.instructions[at].op != ConstantOp:
              continue
            let bit = bitIndex(
              function.instructions[at].bits,
              function.values[int32(masked)].valueType
            )
            if bit < 0:
              continue
            var safe = true
            for i in maskAt + 1 ..< int(comparison):
              let item = function.instructions[i]
              if item.op != ConstantOp or item.results.count != 1:
                safe = false
                break
              let value = item.results.first
              var consumed = 0
              for span in [mask.arguments, predicate.arguments]:
                for j in span.indices:
                  if int32(function.operands[j]) == value:
                    inc consumed
              if consumed != uses[value] or consumed == 0:
                safe = false
                break
            if not safe:
              continue
            result.inputs[owner] = input
            result.bits[owner] = bit
            result.whenSet[owner] = predicate.comparison == EqualComparison
            result.skipped[maskAt] = true
            result.skipped[comparison] = true
            break
          if int32(result.inputs[owner]) >= 0:
            break
      var consumed = newSeq[int](uses.len)
      for i, item in function.instructions:
        if result.skipped[i]:
          for operand in item.arguments.indices:
            inc consumed[int32(function.operands[operand])]
      for input in result.inputs:
        if int32(input) >= 0:
          dec consumed[int32(input)]
      for value, definition in definitions:
        if definition >= 0 and uses[value] > 0 and
          uses[value] == consumed[value] and
          function.instructions[definition].op == ConstantOp:
            result.skipped[definition] = true
      for i, item in function.instructions:
        if result.skipped[i]:
          for value in item.results.indices:
            result.omitted[value] = true

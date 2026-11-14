import irs

type BooleanState = enum
  UnknownBoolean, NormalBoolean, FalseBoolean, TrueBoolean

proc known(state: BooleanState): bool {.raises: [].} =
  ## Distinguishes an exact truth value from a normalized unknown boolean.
  state in {FalseBoolean, TrueBoolean}

proc truth(value: bool): BooleanState {.raises: [].} =
  ## Encodes an exact zero-or-one result without choosing a machine register.
  if value:
    TrueBoolean
  else:
    FalseBoolean

proc booleanFacts(function: IrFunction): seq[BooleanState] {.raises: [].} =
  ## Proves canonical boolean values through producers, selections, and joins.
  let count = function.values.len
  var
    definitions = newSeq[int](count)
    incoming = newSeq[seq[ValueId]](count)
    users = newSeq[seq[int]](count)
    pending: seq[int]
    queued = newSeq[bool](count)
  result = newSeq[BooleanState](count)
  for definition in definitions.mitems:
    definition = -1
  for data in function.blocks:
    for index in data.instructions.indices:
      let item = function.instructions[index]
      if item.results.count != 1 or
        function.values[item.results.first].valueType != BoolType:
          continue
      let value = int(item.results.first)
      definitions[value] = index
      pending.add(value)
      queued[value] = true
      for argument in item.arguments.indices:
        users[int32(function.operands[argument])].add(value)
    for index in data.terminator.edges.indices:
      let edge = function.edges[index]
      if int32(edge.target) == 0:
        continue
      let parameters = function.blocks[int32(edge.target)].parameters
      for i in 0 ..< int(edge.arguments.count):
        let value = int(parameters.first) + i
        if function.values[value].valueType != BoolType:
          continue
        let input = function.operands[int(edge.arguments.first) + i]
        incoming[value].add(input)
        users[int32(input)].add(value)
        if not queued[value]:
          pending.add(value)
          queued[value] = true
  var cursor = 0
  while cursor < pending.len:
    let value = pending[cursor]
    inc cursor
    queued[value] = false
    var state = UnknownBoolean
    if definitions[value] < 0:
      for i, input in incoming[value]:
        let other = result[int32(input)]
        if i == 0:
          state = other
        elif state == UnknownBoolean or other == UnknownBoolean:
          state = UnknownBoolean
          break
        elif state != other:
          state = NormalBoolean
    else:
      let item = function.instructions[definitions[value]]
      case item.op
      of ConstantOp:
        state = truth((item.bits and 1) != 0)
      of CompareOp, LoadOp, ConvertOp, AddOp, SubtractOp, MultiplyOp,
          DivideOp, RemainderOp, NegateOp, AndOp, OrOp, XorOp, NotOp,
          ShiftLeftOp, ShiftRightOp, ArithmeticRightOp:
        state = NormalBoolean
      else:
        discard
      if item.op == SelectOp:
        let
          first = item.arguments.first
          condition = result[int32(function.operands[first])]
          yes = result[int32(function.operands[first + 1])]
          no = result[int32(function.operands[first + 2])]
        if condition.known():
          state = if condition == TrueBoolean: yes else: no
        elif yes != UnknownBoolean and no != UnknownBoolean:
          state = if yes == no: yes else: NormalBoolean
      elif item.arguments.count == 2 and item.op in
        {AndOp, OrOp, XorOp, CompareOp}:
          let
            a = int32(function.operands[item.arguments.first])
            b = int32(function.operands[item.arguments.first + 1])
            left = result[a]
            right = result[b]
          case item.op
          of AndOp:
            if left == FalseBoolean or right == FalseBoolean:
              state = FalseBoolean
            elif left == TrueBoolean and right == TrueBoolean:
              state = TrueBoolean
          of OrOp:
            if left == TrueBoolean or right == TrueBoolean:
              state = TrueBoolean
            elif left == FalseBoolean and right == FalseBoolean:
              state = FalseBoolean
          of XorOp:
            if a == b:
              state = FalseBoolean
            elif left.known() and right.known():
              state = truth(left != right)
          of CompareOp:
            if function.values[a].valueType == BoolType:
              if a == b:
                state = truth(item.comparison in {EqualComparison,
                  LessEqualComparison, GreaterEqualComparison})
              elif left.known() and right.known():
                state = truth(case item.comparison
                  of EqualComparison: left == right
                  of NotEqualComparison: left != right
                  of LessComparison: left < right
                  of LessEqualComparison: left <= right
                  of GreaterComparison: left > right
                  of GreaterEqualComparison: left >= right)
          else:
            discard
      elif item.op == NotOp:
        let input = result[int32(function.operands[item.arguments.first])]
        if input.known():
          state = truth(input == FalseBoolean)
    if state != result[value]:
      doAssert not result[value].known()
      result[value] = state
      for user in users[value]:
        if not queued[user]:
          pending.add(user)
          queued[user] = true

proc simplifyBooleans*(function: var IrFunction): seq[ValueId] {.raises: [].} =
  ## Removes proven boolean identities while keeping operand evaluation.
  let
    old = function
    facts = booleanFacts(old)
  for value in 0 ..< old.values.len:
    result.add(ValueId(value))
  var instructions: seq[IrInstruction]
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for index in data.instructions.indices:
      var item = old.instructions[index]
      var replacement = NoValue
      if not item.volatile and item.results.count == 1 and
        old.values[item.results.first].valueType == BoolType and
        item.op in {AndOp, OrOp, XorOp, NotOp, CompareOp, SelectOp}:
          let value = item.results.first
          if facts[value].known():
            item = IrInstruction(op: ConstantOp, results: item.results,
              location: item.location,
              bits: if facts[value] == TrueBoolean: uint64.high else: 0)
          elif item.arguments.count == 2:
            let
              a = old.operands[item.arguments.first]
              b = old.operands[item.arguments.first + 1]
            if item.op in {AndOp, OrOp} and int32(a) == int32(b) and
              facts[int32(a)] != UnknownBoolean:
                replacement = a
            else:
              for side in 0 .. 1:
                let
                  input = if side == 0: a else: b
                  literal = if side == 0: b else: a
                  state = facts[int32(literal)]
                if facts[int32(input)] == UnknownBoolean:
                  continue
                let identity = case item.op
                  of AndOp: state == TrueBoolean
                  of OrOp, XorOp: state == FalseBoolean
                  of CompareOp:
                    (item.comparison == EqualComparison and
                      state == TrueBoolean) or
                    (item.comparison == NotEqualComparison and
                      state == FalseBoolean)
                  else: false
                if identity:
                  replacement = input
                  break
      if int32(replacement) >= 0:
        result[item.results.first] = replacement
      else:
        instructions.add(item)
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)

proc normalizedBooleans*(function: IrFunction): seq[bool] {.raises: [].} =
  ## Proves zero-or-one payloads independently of call failure annotations.
  let facts = booleanFacts(function)
  result = newSeq[bool](facts.len)
  for value, fact in facts:
    result[value] = fact != UnknownBoolean

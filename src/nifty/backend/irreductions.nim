import irs

proc foldFloatSums*(function: var IrFunction): bool =
  ## Replaces ordered lane extractions and addition without reassociation.
  var definitions = newSeq[int](function.values.len)
  for index in definitions.mitems:
    index = -1
  for index, item in function.instructions:
    if item.results.count == 1:
      definitions[item.results.first] = index
  for item in function.instructions.mitems:
    if item.op != AddOp or item.volatile or
      function.values[item.results.first].valueType != Float32Type:
        continue
    let
      left = definitions[int32(function.operands[item.arguments.first])]
      right = definitions[int32(function.operands[item.arguments.first + 1])]
    if left < 0 or right < 0:
      continue
    let
      a = function.instructions[left]
      b = function.instructions[right]
    if a.op != ExtractOp or b.op != ExtractOp or a.volatile or b.volatile or
      a.target != 0 or b.target != 1:
        continue
    let source = function.operands[a.arguments.first]
    if int32(source) != int32(function.operands[b.arguments.first]):
      continue
    item.op = VectorSumOp
    item.arguments = Span(first: int32(function.operands.len), count: 1)
    function.operands.add(source)
    result = true

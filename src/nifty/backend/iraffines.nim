import std/tables, irs

const MaxAddressTerms = 4

type
  Terms = object
    count: int
    values: array[MaxAddressTerms, int32]
    factors: array[MaxAddressTerms, uint64]
  Address = object
    terms: Terms
    offset: uint64

proc add(terms: var Terms, value: int32, factor: uint64): bool =
  ## Maintains a bounded sorted sum with wrapping coefficients.
  if factor == 0:
    return true
  var index = 0
  while index < terms.count and terms.values[index] < value:
    inc index
  if index < terms.count and terms.values[index] == value:
    terms.factors[index] += factor
    if terms.factors[index] == 0:
      for i in index ..< terms.count - 1:
        terms.values[i] = terms.values[i + 1]
        terms.factors[i] = terms.factors[i + 1]
      dec terms.count
      terms.values[terms.count] = 0
      terms.factors[terms.count] = 0
    return true
  if terms.count == MaxAddressTerms:
    return false
  for i in countdown(terms.count, index + 1):
    terms.values[i] = terms.values[i - 1]
    terms.factors[i] = terms.factors[i - 1]
  terms.values[index] = value
  terms.factors[index] = factor
  inc terms.count
  true

proc reuseAddresses*(function: var IrFunction, pointerBytes: int32): bool =
  ## Reuses same-block affine raw addresses through memory displacements.
  if pointerBytes != 8:
    return false
  let old = function
  var
    definitions = newSeq[int](old.values.len)
    ready = newSeq[bool](old.values.len)
    addresses = newSeq[Address](old.values.len)
  for index in definitions.mitems:
    index = -1
  for index, item in old.instructions:
    if item.results.count == 1:
      definitions[item.results.first] = index

  proc wide(value: int32): bool =
    ## Accepts only representations with identical 64-bit wrapping algebra.
    old.values[value].valueType in {AddressType, Int64Type, UInt64Type}

  proc describe(value: int32, depth = 0): Address =
    ## Normalizes pure integer chains, treating other producers as atoms.
    if ready[value]:
      return addresses[value]
    discard result.terms.add(value, 1)
    if not wide(value) or definitions[value] < 0 or depth >= 32:
      return
    let item = old.instructions[definitions[value]]
    var valid = false
    if item.op == ConstantOp:
      result = Address(offset: item.bits)
    elif item.arguments.count > 0:
      let input = int32(old.operands[item.arguments.first])
      if wide(input):
        let left = describe(input, depth + 1)
        if item.op == ConvertOp and item.conversion == BitcastConversion:
          result = left
        elif item.arguments.count == 2 and
          item.op in {AddOp, SubtractOp, MultiplyOp, OffsetAddressOp}:
            let second = int32(old.operands[item.arguments.first + 1])
            if wide(second):
              let right = describe(second, depth + 1)
              var candidate = left
              case item.op
              of AddOp, SubtractOp, OffsetAddressOp:
                let scale = if item.op == SubtractOp: high(uint64) else: 1'u64
                candidate.offset += right.offset * scale
                if item.op == OffsetAddressOp:
                  candidate.offset += cast[uint64](item.offset)
                valid = true
                for i in 0 ..< right.terms.count:
                  if not candidate.terms.add(right.terms.values[i],
                      right.terms.factors[i] * scale):
                    valid = false
                    break
              of MultiplyOp:
                if left.terms.count == 0 or right.terms.count == 0:
                  let
                    source = if left.terms.count == 0: right else: left
                    scale = if left.terms.count == 0:
                        left.offset else: right.offset
                  candidate = Address(offset: source.offset * scale)
                  valid = true
                  for i in 0 ..< source.terms.count:
                    discard candidate.terms.add(source.terms.values[i],
                      source.terms.factors[i] * scale)
              else:
                discard
              if valid:
                result = candidate
    ready[value] = true
    addresses[value] = result

  for blockData in old.blocks:
    var views: Table[Terms, int32]

    proc remember(value: int32) =
      ## Records the first available raw address for each normalized sum.
      if old.values[value] == IrValue(valueType: AddressType):
        let address = describe(value)
        if address.terms notin views:
          views[address.terms] = value

    for value in blockData.parameters.indices:
      remember(int32(value))
    for index in blockData.instructions.indices:
      let item = old.instructions[index]
      if item.op in {LoadOp, StoreOp}:
        let value = int32(old.operands[item.arguments.first])
        if old.values[value] == IrValue(valueType: AddressType):
          let address = describe(value)
          if address.terms in views:
            let root = views.getOrDefault(address.terms)
            if root != value:
              let first = int32(function.operands.len)
              function.operands.add(ValueId(root))
              for i in 1 ..< item.arguments.count:
                function.operands.add(old.operands[item.arguments.first + i])
              function.instructions[index].arguments.first = first
              function.instructions[index].offset = cast[int64](
                address.offset - describe(root).offset +
                cast[uint64](item.offset))
              result = true
          else:
            remember(value)
      for value in item.results.indices:
        remember(int32(value))

import irs

type Address = object
  known: bool
  root: int32
  offset: int64
  computed: bool

proc foldAddresses*(function: var IrFunction, pointerBytes: int32,
    roots = false) =
  ## Folds constant byte-address chains into existing memory displacements.
  if pointerBytes != 8:
    return
  let old = function
  var
    addresses = newSeq[Address](old.values.len)
    constants = newSeq[bool](old.values.len)
    bits = newSeq[uint64](old.values.len)
  for i, value in old.values:
    if (value.valueType == AddressType and value.storage == 0) or
      (roots and value.valueType in {AddressType, Int64Type, UInt64Type}):
        addresses[i] = Address(known: true, root: int32(i))
  for item in old.instructions:
    if item.op == ConstantOp:
      constants[item.results.first] = true
      bits[item.results.first] = item.bits
  var changed = true
  while changed:
    changed = false
    for item in old.instructions:
      if item.results.count != 1 or item.arguments.count == 0:
        continue
      let
        input = int32(old.operands[item.arguments.first])
        output = item.results.first
      var address = addresses[input]
      if not address.known or old.values[output].valueType notin
          {AddressType, Int64Type, UInt64Type}:
          continue
      case item.op
      of ConvertOp:
        if item.conversion != BitcastConversion or
            old.values[input].valueType notin
              {AddressType, Int64Type, UInt64Type}:
            continue
      of AddOp, OffsetAddressOp:
        var displacement = int32(old.operands[item.arguments.first + 1])
        if roots and item.op == AddOp and constants[input] and
          not constants[displacement]:
            address = addresses[displacement]
            displacement = input
        if not address.known:
          continue
        if not constants[displacement] or
            old.values[displacement].valueType notin {Int64Type, UInt64Type}:
            continue
        address.offset = address.offset +% cast[int64](bits[displacement])
        address.computed = true
        if item.op == OffsetAddressOp:
          address.offset = address.offset +% item.offset
      else:
        continue
      if addresses[output] != address:
        addresses[output] = address
        changed = true
  var
    instructions: seq[IrInstruction]
    views = newSeq[ValueId](old.values.len)
    owners = newSeq[int32](old.values.len)
  for owner in owners.mitems:
    owner = -1
  for owner, data in old.blocks:
    let first = int32(instructions.len)
    for index in data.instructions.indices:
      var item = old.instructions[index]
      if item.results.count == 1:
        let
          value = item.results.first
          kind = old.values[value]
          address = addresses[value]
        if kind.valueType == AddressType and kind.storage == 0 and
          address.known and address.offset == 0 and not address.computed:
            views[address.root] = ValueId(value)
            owners[address.root] = int32(owner)
      if item.op in {LoadOp, StoreOp}:
        let
          value = int32(old.operands[item.arguments.first])
          address = addresses[value]
        if address.known and address.root != value and
          old.values[value].storage == 0:
            let
              root = old.values[address.root]
              raw = root.valueType == AddressType and root.storage == 0
            if raw or address.computed:
              var pointer = ValueId(address.root)
              if not raw:
                if owners[address.root] == int32(owner):
                  pointer = views[address.root]
                else:
                  pointer = ValueId(function.values.len)
                  function.values.add(IrValue(valueType: AddressType))
                  let arguments = Span(first: int32(function.operands.len),
                    count: 1)
                  function.operands.add(ValueId(address.root))
                  instructions.add(IrInstruction(op: ConvertOp,
                    conversion: BitcastConversion, location: item.location,
                    arguments: arguments,
                    results: Span(first: int32(pointer), count: 1)))
                  views[address.root] = pointer
                  owners[address.root] = int32(owner)
              let
                arguments = item.arguments
                start = int32(function.operands.len)
              for position in arguments.indices:
                function.operands.add(
                  if position == int(arguments.first): pointer
                  else: old.operands[position])
              item.arguments.first = start
              item.offset = address.offset +% item.offset
      instructions.add(item)
    function.blocks[owner].instructions = Span(first: first,
      count: int32(instructions.len) - first)
  function.instructions = move(instructions)

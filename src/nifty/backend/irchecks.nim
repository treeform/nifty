import common, irs

proc require(condition: bool, message: string) {.raises: [BackendError].} =
  ## Reports malformed compiler IR through the language error boundary.
  if not condition:
    raise newException(BackendError, "Invalid IR: " & message)

proc valid(span: Span, length: int): bool {.raises: [].} =
  ## Checks pooled ranges without overflowing their stored integer width.
  span.first >= 0 and span.count >= 0 and
    int64(span.first) + int64(span.count) <= int64(length)

proc byteCount*(kind: IrType, pointerBytes: int32): int32 {.raises: [].} =
  ## Returns the physical byte width of a primitive IR value.
  case kind
  of BoolType, CharType, Int8Type, UInt8Type: 1
  of Int16Type, UInt16Type: 2
  of Int32Type, UInt32Type, Float32Type: 4
  of AddressType: pointerBytes
  else: 8

proc verifyReturnAbi*(module: IrModule) {.raises: [BackendError].} =
  ## Allows scalar returns or uniform private bundles of two to four floats.
  for function in module.functions:
    require(Float32x2Type notin function.signature.parameters and
      Float32x2Type notin function.signature.returns,
      "vectors are internal values, not call ABI values")
    let kinds = function.signature.returns
    if kinds.len <= 1:
      continue
    require(function.directOnly and kinds.len <= 4,
      "multiple results require a private direct floating bundle")
    require(kinds[0] in {Float32Type, Float64Type},
      "multiple results require floating lanes")
    for kind in kinds:
      require(kind == kinds[0], "multiple results require uniform lanes")
  for signature in module.signatures:
    require(Float32x2Type notin signature.parameters and
      Float32x2Type notin signature.returns, "vector indirect ABI unsupported")
    require(signature.returns.len <= 1,
      "indirect calls do not support result bundles")
  for host in module.hosts:
    require(Float32x2Type notin host.signature.parameters and
      Float32x2Type notin host.signature.returns, "vector host ABI unsupported")
    require(host.signature.returns.len <= 1,
      "host calls do not support result bundles")

proc verifyLayouts(module: IrModule) {.raises: [BackendError].} =
  ## Validates storage sizes, complete struct coverage, and recursive layouts.
  proc storage(id: int32): IrStorage =
    ## Requires a bounded one-based memory type reference.
    require(id > 0 and id <= module.storageTypes.len, "invalid storage type")
    module.storageTypes[id - 1]
  var names: seq[string]
  for data in module.storageTypes:
    require(data.byteCount >= 0, "negative storage size")
    require(data.alignment > 0 and
      (data.alignment and (data.alignment - 1)) == 0, "invalid storage alignment")
    require(data.byteCount mod data.alignment == 0,
      "storage size is not aligned")
    require(data.fields.valid(module.fields.len), "invalid struct fields")
    if data.kind != StructStorage:
      require(data.fields.count == 0, "non-struct has fields")
    case data.kind
    of ScalarStorage:
      require(data.byteCount == byteCount(data.scalar, module.pointerBytes) and
        data.alignment == data.byteCount, "incorrect scalar layout")
    of PointerStorage:
      require(data.byteCount == module.pointerBytes and
        data.alignment == module.pointerBytes, "incorrect pointer layout")
      if data.element != 0:
        discard storage(data.element)
    of ArrayStorage:
      let element = storage(data.element)
      require(data.length >= 0 and int64(data.byteCount) ==
        int64(data.length) * int64(element.byteCount) and
        data.alignment == element.alignment, "incorrect array layout")
    of StructStorage:
      var offset = 0'i64
      for i in data.fields.indices:
        let
          field = module.fields[i]
          member = storage(field.storage)
        require(field.offset == offset,
          "struct fields overlap or omit explicit padding")
        require(field.offset mod member.alignment == 0 and
          data.alignment >= member.alignment, "misaligned struct field")
        offset += member.byteCount
        require(offset <= data.byteCount, "field exceeds struct size")
        for j in int(data.fields.first) ..< i:
          require(module.fields[j].name != field.name, "duplicate field name")
        case field.role
        of ReferenceField:
          require(member.kind == PointerStorage, "reference field is not a pointer")
        of RefcountField, DiscriminatorField:
          require(member.kind == ScalarStorage and member.scalar in
            {BoolType, CharType, Int8Type, UInt8Type, Int16Type, UInt16Type,
              Int32Type, UInt32Type, Int64Type, UInt64Type},
            "refcount or discriminator is not an integer")
        of PaddingField, ReservedField:
          require(member.kind == ArrayStorage,
            "padding or reserved field is not a byte array")
          let item = storage(member.element)
          require(item.kind == ScalarStorage and item.scalar == UInt8Type,
            "padding or reserved field is not bytes")
        else:
          discard
      require(offset == data.byteCount, "struct has undeclared trailing bytes")
    of OpaqueStorage:
      discard
    if data.kind in {StructStorage, OpaqueStorage}:
      require(data.name.len > 0 and data.name notin names,
        "missing or duplicate storage name")
      names.add(data.name)
  var states = newSeq[int](module.storageTypes.len)
  proc visit(index, depth: int, namesOnly: bool) =
    ## Rejects inline cycles and unprintable anonymous pointer cycles.
    require(depth <= 128, "storage nesting exceeds limits")
    if states[index] == 2:
      return
    require(states[index] == 0, "recursive inline or anonymous storage")
    states[index] = 1
    let data = module.storageTypes[index]
    if data.kind == ArrayStorage or
        (namesOnly and data.kind == PointerStorage and data.element > 0):
      visit(int(data.element - 1), depth + 1, namesOnly)
    elif not namesOnly and data.kind == StructStorage:
      for i in data.fields.indices:
        visit(int(module.fields[i].storage - 1), depth + 1, namesOnly)
    states[index] = 2
  for namesOnly in [false, true]:
    for item in states.mitems:
      item = 0
    for i in 0 ..< module.storageTypes.len:
      visit(i, 0, namesOnly)

proc verifyIr*(module: IrModule) {.raises: [BackendError].} =
  ## Checks pooled storage, signatures, typed edges, and SSA dominance.
  require(module.pointerBytes in [4, 8], "unsupported pointer width")
  verifyLayouts(module)
  for host in module.hosts:
    require(Float32x2Type notin host.signature.parameters and
      Float32x2Type notin host.signature.returns, "vector host ABI unsupported")
    require(host.borrowedBytes.len in [0, host.signature.parameters.len],
      "invalid host borrow annotations")
    for i, bytes in host.borrowedBytes:
      require(bytes >= -1, "invalid host borrow size")
      require(bytes < 0 or host.signature.parameters[i] == AddressType,
        "host borrow requires a pointer")
  for global in module.globals:
    require(global.bytes.valid(module.data.len), "invalid global data span")
    require(global.storage >= 0 and global.storage <= module.storageTypes.len,
      "invalid global storage")
    if global.storage > 0:
      let storage = module.storageTypes[global.storage - 1]
      require(global.bytes.count == storage.byteCount and
        global.alignment == storage.alignment, "global layout mismatch")
  for index in 0 ..< module.functions.len:
    let
      function = module.functions[index]
      count = function.blocks.len
    require(count > 0, "function has no entry block")
    for value in function.values:
      require(value.storage >= 0 and value.storage <= module.storageTypes.len,
        "invalid value storage")
      require(value.storage == 0 or value.valueType == AddressType,
        "only address registers have pointee storage")
    let signature = function.signature
    require(signature.parameterStorage.len in [0, signature.parameters.len] and
      signature.returnStorage.len in [0, signature.returns.len] and
      signature.passing.len in [0, signature.parameters.len],
      "invalid signature storage annotations")
    for slot in function.slots:
      require(slot.storage >= 0 and slot.storage <= module.storageTypes.len,
        "invalid slot storage")
      if slot.storage > 0:
        let storage = module.storageTypes[slot.storage - 1]
        require(slot.byteCount == storage.byteCount and
          slot.alignment == storage.alignment, "slot layout mismatch")
    var
      definitions = newSeq[int](function.values.len)
      positions = newSeq[int](function.values.len)
      invokeResults = newSeq[bool](function.values.len)
      predecessors = newSeq[seq[int]](count)
    for item in definitions.mitems:
      item = -1
    proc define(span: Span, owner, position: int, invoked = false) =
      ## Registers one unique definition for each typed value ID.
      require(span.valid(function.values.len), "invalid result span")
      for value in span.indices:
        require(definitions[value] == -1, "value defined twice")
        definitions[value] = owner
        positions[value] = position
        invokeResults[value] = invoked
    for i, data in function.blocks:
      define(data.parameters, i, -1)
      require(data.instructions.valid(function.instructions.len),
        "invalid instruction span")
      for j in data.instructions.indices:
        let instruction = function.instructions[j]
        require(not instruction.volatile or instruction.op in {LoadOp, StoreOp},
          "volatile flag requires a memory access")
        require(instruction.arguments.valid(function.operands.len),
          "invalid instruction operands")
        define(instruction.results, i, j - int(data.instructions.first))
      let terminator = data.terminator
      require(terminator.kind != UnsetTerminator, "unterminated block")
      require(terminator.arguments.valid(function.operands.len),
        "invalid terminator operands")
      require(terminator.edges.valid(function.edges.len), "invalid edge span")
      define(terminator.results, i, int(data.instructions.count), true)
      let edgeCount = case terminator.kind
        of JumpTerminator: 1
        of BranchTerminator, InvokeTerminator, InvokeHostTerminator: 2
        else: 0
      require(terminator.edges.count == edgeCount, "wrong successor count")
      if terminator.kind == InvokeTerminator:
        require(terminator.callee in 0 ..< module.functions.len,
          "invalid procedure invoke target")
      if terminator.kind == UnreachableTerminator:
        require(terminator.arguments.count == 0 and
          terminator.results.count == 0, "unreachable has operands or results")
      for j in terminator.edges.indices:
        let edge = function.edges[j]
        require(int32(edge.target) in 0 ..< count, "invalid block target")
        require(int32(edge.target) != 0, "entry block has a predecessor")
        require(edge.arguments.valid(function.operands.len),
          "invalid edge operands")
        predecessors[int32(edge.target)].add(i)
    for value in function.operands:
      require(int32(value) in 0 ..< function.values.len, "invalid value ID")
      require(definitions[int32(value)] >= 0, "undefined operand")
    let entry = function.blocks[0].parameters
    require(entry.count == function.signature.parameters.len,
      "entry signature arity mismatch")
    for i in 0 ..< int(entry.count):
      require(function.values[int(entry.first) + i].valueType ==
        function.signature.parameters[i], "entry signature type mismatch")
      let expected = if signature.parameterStorage.len == 0: 0'i32
        else: signature.parameterStorage[i]
      require(function.values[int(entry.first) + i].storage == expected,
        "entry pointee type mismatch")
      if signature.passing.len > 0 and signature.passing[i] != DirectPassing:
        require(signature.parameters[i] == AddressType and expected > 0,
          "memory passing mode requires a typed address")
    var
      visited = newSeq[bool](count)
      stack = @[(0, false)]
      order: seq[int]
    while stack.len > 0:
      let (index, finished) = stack.pop()
      if finished:
        order.add(index)
      elif not visited[index]:
        visited[index] = true
        stack.add((index, true))
        for j in function.blocks[index].terminator.edges.indices:
          stack.add((int(int32(function.edges[j].target)), false))
    var
      ranks = newSeq[int](count)
      dominators = newSeq[int](count)
    for item in dominators.mitems:
      item = -1
    for i in 0 ..< order.len:
      ranks[order[order.high - i]] = i
    dominators[0] = 0
    proc intersect(a, b: int): int =
      ## Finds the nearest common ancestor in the current dominator tree.
      var
        left = a
        right = b
      while left != right:
        if ranks[left] > ranks[right]:
          left = dominators[left]
        else:
          right = dominators[right]
      left
    var changed = true
    while changed:
      changed = false
      for i in countdown(order.len - 2, 0):
        let target = order[i]
        var parent = -1
        for predecessor in predecessors[target]:
          if dominators[predecessor] >= 0:
            parent = if parent < 0: predecessor
              else: intersect(parent, predecessor)
        if dominators[target] != parent:
          dominators[target] = parent
          changed = true
    proc use(span: Span, owner, position: int, normalEdge = false) =
      ## Requires every operand to dominate its reachable use.
      for i in span.indices:
        let value = int32(function.operands[i])
        if invokeResults[value]:
          require(normalEdge and definitions[value] == owner,
            "invoke result used outside its normal edge")
          continue
        if not visited[owner]:
          continue
        let definition = definitions[value]
        if definition == owner:
          require(positions[value] < position, "use before definition")
        else:
          var current = owner
          while current != definition and current != 0:
            current = dominators[current]
          require(current == definition, "definition does not dominate use")
    proc operandType(span: Span, index: int): IrType =
      ## Looks up one already bounded operand type.
      function.values[int32(function.operands[int(span.first) + index])].valueType
    for owner, data in function.blocks:
      for j in data.instructions.indices:
        let instruction = function.instructions[j]
        use(instruction.arguments, owner, j - int(data.instructions.first))
        let
          arguments = instruction.arguments
          results = instruction.results
          arity = case instruction.op
            of ConstantOp, SlotAddressOp, GlobalAddressOp, FrameSizeOp: 0
            of NegateOp, NotOp, ConvertOp, SqrtOp, FloorOp, RoundOp, LoadOp,
                ClearBytesOp, FieldAddressOp, ExtractOp, VectorSumOp: 1
            of CallOp, HostCallOp, IndirectCallOp: -1
            of SelectOp: 3
            else: 2
        if arity >= 0:
          require(arguments.count == arity, "wrong instruction arity")
        if instruction.op notin {StoreOp, MoveBytesOp, ClearBytesOp,
            CallOp, HostCallOp, IndirectCallOp}:
          require(results.count == 1, "instruction requires one result")
        if instruction.op in {StoreOp, MoveBytesOp, ClearBytesOp}:
          require(results.count == 0, "effect instruction has a result")
        let vector = results.count == 1 and
          function.values[results.first].valueType == Float32x2Type
        if vector:
          require(instruction.op in {ConstantOp, PackOp, VectorAddOp,
            VectorSubtractOp, VectorMultiplyOp, VectorDivideOp, LoadOp,
            ConvertOp, SelectOp},
            "unsupported vector result operation")
        for i in arguments.indices:
          if function.values[int32(function.operands[i])].valueType ==
              Float32x2Type:
            require(instruction.op in {VectorAddOp, VectorSubtractOp,
              VectorMultiplyOp, VectorDivideOp, VectorSumOp, ExtractOp, StoreOp,
              ConvertOp, SelectOp},
              "unsupported vector operand operation")
        if instruction.op == ConvertOp and
            (vector or operandType(arguments, 0) == Float32x2Type):
          require(instruction.conversion == BitcastConversion and
            operandType(arguments, 0) in {Float32x2Type, UInt64Type, Int64Type} and
            function.values[results.first].valueType in
            {Float32x2Type, UInt64Type, Int64Type},
            "vectors require a 64-bit integer bitcast")
        case instruction.op
        of PackOp:
          require(vector and operandType(arguments, 0) == Float32Type and
            operandType(arguments, 1) == Float32Type,
            "pack requires two float32 lanes")
        of VectorSumOp:
          require(function.values[results.first].valueType == Float32Type and
            operandType(arguments, 0) == Float32x2Type,
            "vector sum requires float32x2 input and float32 result")
        of ExtractOp:
          require(function.values[results.first].valueType == Float32Type and
            operandType(arguments, 0) == Float32x2Type and
            instruction.target in 0 .. 1, "invalid float32 vector lane")
        of VectorAddOp, VectorSubtractOp, VectorMultiplyOp, VectorDivideOp:
          require(vector and operandType(arguments, 0) == Float32x2Type and
            operandType(arguments, 1) == Float32x2Type,
            "vector arithmetic requires float32x2 operands and result")
        of CallOp, HostCallOp, IndirectCallOp:
          let target = instruction.target
          var signature: IrSignature
          var first = 0
          case instruction.op
          of CallOp:
            require(target in 0 ..< module.functions.len,
              "invalid procedure call target")
            signature = module.functions[target].signature
          of HostCallOp:
            require(target in 0 ..< module.hosts.len,
              "invalid host call target")
            signature = module.hosts[target].signature
          else:
            require(target in 0 ..< module.signatures.len,
              "invalid indirect call signature")
            require(arguments.count > 0 and
              operandType(arguments, 0) == AddressType,
              "indirect callee is not an address")
            signature = module.signatures[target]
            first = 1
          require(arguments.count == signature.parameters.len + first,
            "call argument arity mismatch")
          require(results.count == signature.returns.len,
            "call return arity mismatch")
          for i, kind in signature.parameters:
            require(operandType(arguments, i + first) == kind,
              "call argument type mismatch")
            if signature.parameterStorage.len > 0 and
                signature.parameterStorage[i] > 0:
              let value = function.operands[arguments.first + int32(i + first)]
              require(function.values[int32(value)].storage ==
                signature.parameterStorage[i], "call pointee type mismatch")
          for i, kind in signature.returns:
            require(function.values[results.first + int32(i)].valueType == kind,
              "call result type mismatch")
        of FrameSizeOp:
          require(function.values[results.first].valueType == UInt64Type,
            "frame size must be uint64")
        of AddOp, SubtractOp, MultiplyOp, DivideOp, RemainderOp,
            AndOp, OrOp, XorOp, ShiftLeftOp, ShiftRightOp, ArithmeticRightOp:
          require(operandType(arguments, 0) == operandType(arguments, 1) and
            function.values[results.first].valueType ==
              operandType(arguments, 0), "binary type mismatch")
        of SelectOp:
          require(operandType(arguments, 0) == BoolType,
            "select condition must be boolean")
          let value = function.values[results.first]
          for side in 1 .. 2:
            let input = function.values[int32(function.operands[
              arguments.first + int32(side)])]
            require(input.valueType == value.valueType and
              input.storage == value.storage, "select value type mismatch")
        of CompareOp:
          require(operandType(arguments, 0) == operandType(arguments, 1) and
            function.values[results.first].valueType == irs.BoolType,
            "comparison type mismatch")
        of NegateOp, NotOp, SqrtOp:
          require(function.values[results.first].valueType ==
            operandType(arguments, 0), "unary type mismatch")
        of FloorOp, RoundOp:
          require(function.values[results.first].valueType == Float32Type and
            operandType(arguments, 0) == Float32Type,
            "floating rounding requires float32 operands and results")
        of LoadOp, StoreOp, MoveBytesOp, ClearBytesOp, OffsetAddressOp:
          require(operandType(arguments, 0) == AddressType,
            "memory operand is not an address")
          let pointer = function.values[int32(function.operands[arguments.first])]
          if instruction.op in {MoveBytesOp, ClearBytesOp}:
            require(instruction.byteCount >= 0,
              "aggregate byte span must be nonnegative")
            require(instruction.target >= 0 and
              instruction.target <= module.storageTypes.len,
              "invalid aggregate storage identity")
            if instruction.op == MoveBytesOp:
              require(operandType(arguments, 1) == AddressType,
                "aggregate source is not an address")
          if instruction.op in {LoadOp, StoreOp}:
            let alignment = instruction.alignment
            require(alignment > 0 and (alignment and (alignment - 1)) == 0,
              "invalid memory alignment")
            if pointer.storage > 0:
              let
                storage = module.storageTypes[pointer.storage - 1]
                value = if instruction.op == LoadOp:
                    function.values[results.first]
                  else: function.values[int32(function.operands[
                    arguments.first + 1])]
              require(storage.kind in {ScalarStorage, PointerStorage},
                "aggregate memory requires field addressing or byte moves")
              require(instruction.offset == 0 and
                alignment <= storage.alignment and
                byteCount(value.valueType, module.pointerBytes) ==
                  storage.byteCount, "typed memory access exceeds its layout")
              if storage.kind == ScalarStorage:
                require(value.valueType == storage.scalar and value.storage == 0,
                  "memory value type mismatch")
              else:
                require(value.valueType == AddressType and
                  value.storage == storage.element, "pointer load type mismatch")
        of FieldAddressOp:
          require(operandType(arguments, 0) == AddressType and
            function.values[results.first].valueType == AddressType,
            "field addressing requires pointers")
          let base = function.values[int32(function.operands[arguments.first])]
          require(base.storage > 0, "field base has no struct type")
          let owner = module.storageTypes[base.storage - 1]
          require(owner.kind == StructStorage and
            instruction.target in owner.fields.indices,
            "field does not belong to the base struct")
          require(function.values[results.first].storage ==
            module.fields[instruction.target].storage,
            "field pointer type mismatch")
        of SlotAddressOp:
          require(instruction.target in 0 ..< function.slots.len,
            "invalid stack slot")
          require(function.values[results.first].valueType == AddressType and
            function.values[results.first].storage ==
              function.slots[instruction.target].storage,
            "slot pointer type mismatch")
        of GlobalAddressOp:
          require(instruction.target in 0 ..< module.globals.len,
            "invalid global")
          require(function.values[results.first].valueType == AddressType and
            function.values[results.first].storage ==
              module.globals[instruction.target].storage,
            "global pointer type mismatch")
        else:
          discard
      let terminator = data.terminator
      use(terminator.arguments, owner, int(data.instructions.count))
      if terminator.kind == BranchTerminator:
        require(terminator.arguments.count == 1 and
          operandType(terminator.arguments, 0) == irs.BoolType,
          "branch condition is not bool")
      if terminator.kind == ReturnTerminator:
        require(terminator.arguments.count == function.signature.returns.len,
          "return arity mismatch")
        for i in 0 ..< int(terminator.arguments.count):
          require(operandType(terminator.arguments, i) ==
            function.signature.returns[i], "return type mismatch")
          let expected = if signature.returnStorage.len == 0: 0'i32
            else: signature.returnStorage[i]
          require(function.values[int32(function.operands[
            int(terminator.arguments.first) + i])].storage == expected,
            "return pointee type mismatch")
      for j in terminator.edges.indices:
        let
          edge = function.edges[j]
          parameters = function.blocks[int32(edge.target)].parameters
        use(edge.arguments, owner, int(data.instructions.count),
          terminator.kind in {InvokeTerminator, InvokeHostTerminator} and
            j == terminator.edges.first)
        require(edge.arguments.count == parameters.count,
          "edge argument arity mismatch")
        for i in 0 ..< int(parameters.count):
          require(operandType(edge.arguments, i) ==
            function.values[int(parameters.first) + i].valueType,
            "edge argument type mismatch")
          require(function.values[int32(function.operands[
            int(edge.arguments.first) + i])].storage ==
              function.values[int(parameters.first) + i].storage,
            "edge argument pointee mismatch")

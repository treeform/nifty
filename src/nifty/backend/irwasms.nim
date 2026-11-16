## Emits memory64 WebAssembly exclusively from the shared verified IR.
import
  common, context, wasmbinaries, wasmmodules,
  irs as ir, irchecks, ircontexts, irbranches, irprocedures

type IrWasmImage* = object
  bodies*: seq[string]
  types*: seq[WasmType]
  indirectTypes*: seq[WasmType]
  offsets*: seq[int]
  codeBytes*: int

proc wasmType(kind: ir.IrType): int {.raises: [].} =
  ## Keeps floating precision explicit and uses full-width integer carriers.
  case kind
  of ir.Float32Type: F32
  of ir.Float64Type: F64
  of ir.Float32x2Type: V128
  else: I64

proc vectorOp(code: var string, opcode: int) {.raises: [].} =
  ## Emits a SIMD opcode using the required unsigned LEB128 subopcode.
  code.op(0xfd)
  code.unsigned(opcode)

proc vectorConstant(code: var string, bits: uint64) {.raises: [].} =
  ## Stores two low float32 lanes with zero padding in a WASM v128 value.
  code.vectorOp(0x0c)
  for i in 0 ..< 8:
    code.op(int((bits shr (i * 8)) and 255))
  for i in 0 ..< 8:
    code.op(0)

proc wasmSignature(data: ir.IrSignature): WasmType {.raises: [].} =
  ## Adds the private stack argument to each declared scalar IR signature.
  result.parameters = @[I64]
  for kind in data.parameters:
    result.parameters.add(wasmType(kind))
  for kind in data.returns:
    result.returns.add(wasmType(kind))
  result.bytes = signature(result.parameters, result.returns)

proc floating(kind: ir.IrType): bool {.raises: [].} =
  ## Identifies floating values without importing a target register allocator.
  kind in {ir.Float32Type, ir.Float64Type}

proc unsigned(kind: ir.IrType): bool {.raises: [].} =
  ## Selects unsigned integer division, comparison, and conversion semantics.
  kind in {ir.BoolType, ir.CharType, ir.UInt8Type, ir.UInt16Type,
    ir.UInt32Type, ir.UInt64Type, ir.AddressType}

proc normalize(code: var string, kind: ir.IrType) {.raises: [].} =
  ## Implements the IR's declared integer width on an i64 stack operand.
  case kind
  of ir.Int8Type: code.op(0xc2)
  of ir.Int16Type: code.op(0xc3)
  of ir.Int32Type: code.op(0xc4)
  of ir.BoolType, ir.CharType, ir.UInt8Type, ir.UInt16Type, ir.UInt32Type:
    code.constant(case kind
      of ir.BoolType: 1'i64
      of ir.CharType, ir.UInt8Type: 255'i64
      of ir.UInt16Type: 65535'i64
      else: 0xffffffff'i64)
    code.op(0x83)
  else:
    discard

proc emitWasmIr*(module: ir.IrModule, runtime: WasmModule,
    entryFunction: int, hostSymbols: seq[string],
    stackBytes = 4 * 1024 * 1024,
    maxBytes = 64 * 1024 * 1024): IrWasmImage {.raises: [BackendError].} =
  ## Selects WASM instructions after checking the complete portable IR module.
  verifyIr(module)
  verifyReturnAbi(module)
  if module.pointerBytes != 8 or module.functions.len == 0 or maxBytes < 1:
    error("WASM IR requires memory64, an entry, and a positive code limit")
  if entryFunction < 0 or entryFunction >= module.functions.len:
    error("WASM entry function is outside the IR module")
  if stackBytes < 1 or stackBytes > 4 * 1024 * 1024:
    error("WASM private stack exceeds its reserved runtime region")
  if hostSymbols.len != module.hosts.len:
    error("WASM host symbols must map every IR host")
  for function in module.functions:
    if function.failureMode != ir.NoFailCall:
      error("WASM does not support may-fail IR functions")
  for host in module.hosts:
    if host.failureMode != ir.NoFailCall:
      error("WASM does not support may-fail IR hosts")
  var hostFunctions: seq[int]
  for index, host in module.hosts:
    var expected: WasmType
    for kind in host.signature.parameters:
      expected.parameters.add(wasmType(kind))
    for kind in host.signature.returns:
      expected.returns.add(wasmType(kind))
    let target = runtime.symbol(hostSymbols[index], 0)
    runtime.requireSignature(target, expected.parameters, expected.returns,
      hostSymbols[index])
    hostFunctions.add(target)
  var entry = ""
  entry.constant(runtime.stack + stackBytes + 64)
  entry.indexed(0x20, 0)
  for i in 0 ..< 2:
    entry.constant(0)
  entry.indexed(0x20, 1)
  entry.indexed(0x10, runtime.functions.len + runtime.importedFunctions +
    entryFunction)
  result.bodies.add(body(entry, []))
  result.codeBytes = result.bodies[0].len
  var
    types = runtime.types
    indirectTypes: seq[int]
  for function in module.functions:
    let data = wasmSignature(function.signature)
    result.types.add(data)
    discard types.internType(data)
  for declared in module.signatures:
    let data = wasmSignature(declared)
    result.indirectTypes.add(data)
    indirectTypes.add(types.internType(data))
  for index, function in module.functions:
    let contexts = contextAliases(function, module.pointerBytes)
    let branches = branchComparisons(function)
    if function.signature.parameters.len == 0 or
        function.signature.parameters[0] != ir.AddressType or
        (index == entryFunction and function.signature.parameters !=
          @[ir.AddressType, ir.AddressType, ir.AddressType, ir.AddressType]) or
        (index == entryFunction and function.signature.returns.len != 0):
        error("WASM IR requires a context argument and a storage entry ABI")
    let returnTypes = result.types[index].returns
    result.offsets.add(runtime.tableSize + index)
    if function.trapBody():
      let compiled = body("\x00", [])
      result.codeBytes += compiled.len
      if result.codeBytes > maxBytes:
        error("WASM code size exceeds limits")
      result.bodies.add(compiled)
      continue
    var
      slots: seq[int]
      frameBytes = 0
      locals: seq[int]
      locations: seq[int]
    for slot in function.slots:
      frameBytes = aligned(frameBytes, int(slot.alignment))
      slots.add(frameBytes)
      frameBytes += int(slot.byteCount)
    frameBytes = aligned(frameBytes + 16, 16)
    if frameBytes > MaxFrameBytes:
      error("IR WASM frame exceeds limits")
    # The extra stack parameter is a WASM calling convention detail.
    let ValueBase = 1 + function.signature.parameters.len
    for i, value in function.values:
      if branches.conditions[i]:
        locations.add(-1)
      elif contexts[i]:
        locations.add(1)
      else:
        locations.add(ValueBase + locals.len)
        locals.add(wasmType(value.valueType))
    let
      frame = ValueBase + locals.len
      dispatchLocal = frame + 1
    locals.add(I64)
    locals.add(I32)
    proc read(code: var string, value: ir.ValueId) =
      ## Pushes one typed SSA value from its function-local WASM local.
      doAssert locations[int32(value)] >= 0
      code.indexed(0x20, locations[int32(value)])
    proc edge(code: var string, edgeIndex: int) =
      ## Copies edge arguments in parallel using the WASM operand stack.
      let
        edge = function.edges[edgeIndex]
        parameters = function.blocks[int32(edge.target)].parameters
      for i in 0 ..< int(edge.arguments.count):
        if not contexts[int(parameters.first) + i]:
          code.read(function.operands[int(edge.arguments.first) + i])
      for i in countdown(int(parameters.count) - 1, 0):
        if not contexts[int(parameters.first) + i]:
          code.indexed(0x21, locations[int(parameters.first) + i])
      code.constant(int32(edge.target), false)
      code.indexed(0x21, dispatchLocal)
    proc instruction(code: var string, item: ir.IrInstruction) =
      ## Encodes one portable scalar, memory, or call operation.
      let kind = if item.results.count == 0: ir.UInt64Type
        else: function.values[item.results.first].valueType
      proc operand(i: int): ir.ValueId =
        ## Resolves the current instruction's explicit operand list.
        function.operands[int(item.arguments.first) + i]
      proc operandKind(i: int): ir.IrType =
        ## Reads the source type before choosing a typed WASM instruction.
        function.values[int32(operand(i))].valueType
      proc address(code: var string) =
        ## Places a full-width memory address with a signed displacement.
        code.read(operand(0))
        if item.offset != 0:
          code.constant(item.offset)
          code.op(0x7c)
      case item.op
      of ir.ConstantOp, ir.FrameSizeOp:
        let bits = if item.op == ir.FrameSizeOp: uint64(frameBytes)
          else: item.bits
        if kind == ir.Float32x2Type:
          code.vectorConstant(bits)
        else:
          code.constant(cast[int64](bits))
        if kind == ir.Float32Type:
          code.op(0xa7)
          code.op(0xbe)
        elif kind == ir.Float64Type:
          code.op(0xbf)
        else:
          code.normalize(kind)
      of ir.SlotAddressOp:
        code.indexed(0x20, frame)
        code.constant(slots[item.target])
        code.op(0x7c)
      of ir.GlobalAddressOp:
        code.indexed(0x20, 1)
        code.memory(0x29, offsetOf(RuntimeContext, globals))
        code.constant(module.globals[item.target].offset)
        code.op(0x7c)
      of ir.OffsetAddressOp, ir.FieldAddressOp:
        code.read(operand(0))
        if item.op == ir.FieldAddressOp:
          code.constant(module.fields[item.target].offset)
        else:
          code.read(operand(1))
        code.op(0x7c)
        if item.offset != 0:
          code.constant(item.offset)
          code.op(0x7c)
      of ir.MoveBytesOp, ir.ClearBytesOp:
        if item.byteCount == 0:
          return
        code.read(operand(0))
        if item.op == ir.MoveBytesOp:
          code.read(operand(1))
        else:
          code.constant(0, false)
        code.constant(item.byteCount)
        code.op(0xfc)
        code.unsigned(if item.op == ir.MoveBytesOp: 10 else: 11)
        code.unsigned(0)
        if item.op == ir.MoveBytesOp:
          code.unsigned(0)
      of ir.LoadOp, ir.StoreOp:
        code.address()
        let stored = if item.op == ir.LoadOp: kind else: operandKind(1)
        if item.op == ir.StoreOp:
          code.read(operand(1))
        let opcode = case stored
          of ir.BoolType, ir.CharType, ir.UInt8Type, ir.Int8Type: 0x31
          of ir.UInt16Type, ir.Int16Type: 0x33
          of ir.UInt32Type, ir.Int32Type: 0x35
          of ir.Float32Type: 0x2a
          of ir.Float64Type: 0x2b
          else: 0x29
        let store = case stored
          of ir.BoolType, ir.CharType, ir.UInt8Type, ir.Int8Type: 0x3c
          of ir.UInt16Type, ir.Int16Type: 0x3d
          of ir.UInt32Type, ir.Int32Type: 0x3e
          of ir.Float32Type: 0x38
          of ir.Float64Type: 0x39
          else: 0x37
        if stored == ir.Float32x2Type:
          code.vectorOp(if item.op == ir.LoadOp: 0x5d else: 0x5b)
          code.unsigned(0)
          code.unsigned(0)
          if item.op == ir.StoreOp:
            code.op(0)
        else:
          code.memory(if item.op == ir.LoadOp: opcode else: store)
        if item.op == ir.LoadOp:
          code.normalize(stored)
      of ir.ConvertOp:
        if contexts[item.results.first] and contexts[int32(operand(0))]:
          return
        let source = operandKind(0)
        code.read(operand(0))
        case item.conversion
        of ir.IntegerFloatConversion:
          code.op((if kind == ir.Float32Type: 0xb4 else: 0xb9) +
            ord(unsigned(source)))
        of ir.FloatIntegerConversion:
          code.op((if source == ir.Float32Type: 0xae else: 0xb0) +
            ord(unsigned(kind)))
          code.normalize(kind)
        of ir.FloatWidthConversion:
          if source != kind:
            code.op(if kind == ir.Float32Type: 0xb6 else: 0xbb)
        else:
          if source == ir.Float32x2Type and kind != ir.Float32x2Type:
            code.vectorOp(0x1d)
            code.op(0)
          if kind == ir.Float32x2Type and source != ir.Float32x2Type:
            code.op(0x1a)
            code.vectorConstant(0)
            code.read(operand(0))
            code.vectorOp(0x1e)
            code.op(0)
          if floating(source):
            code.op(if source == ir.Float32Type: 0xbc else: 0xbd)
            if source == ir.Float32Type:
              code.op(0xad)
          if floating(kind):
            if kind == ir.Float32Type:
              code.op(0xa7)
            code.op(if kind == ir.Float32Type: 0xbe else: 0xbf)
          else:
            code.normalize(kind)
      of ir.CallOp, ir.IndirectCallOp:
        code.indexed(0x20, frame)
        let first = ord(item.op == ir.IndirectCallOp)
        for i in first ..< int(item.arguments.count):
          code.read(operand(i))
        if item.op == ir.CallOp:
          code.indexed(0x10, runtime.functions.len +
            runtime.importedFunctions + int(item.target))
        else:
          code.read(operand(0))
          code.op(0x11)
          code.unsigned(indirectTypes[item.target])
          code.unsigned(0)
      of ir.HostCallOp:
        for i in 0 ..< int(item.arguments.count):
          code.read(operand(i))
        code.indexed(0x10, hostFunctions[item.target])
        if item.results.count > 0:
          code.normalize(kind)
      of ir.PackOp:
        code.vectorConstant(0)
        code.read(operand(0))
        code.vectorOp(0x20)
        code.op(0)
        code.read(operand(1))
        code.vectorOp(0x20)
        code.op(1)
      of ir.VectorSumOp:
        for lane in 0 ..< 2:
          code.read(operand(0))
          code.vectorOp(0x1f)
          code.op(lane)
        code.op(0x92)
      of ir.ExtractOp:
        code.read(operand(0))
        code.vectorOp(0x1f)
        code.op(int(item.target))
      of ir.VectorAddOp, ir.VectorSubtractOp, ir.VectorMultiplyOp, ir.VectorDivideOp:
        code.read(operand(0))
        code.read(operand(1))
        code.vectorOp(case item.op
          of ir.VectorAddOp: 0xe4
          of ir.VectorSubtractOp: 0xe5
          of ir.VectorMultiplyOp: 0xe6
          else: 0xe7)
      of ir.SelectOp:
        code.read(operand(1))
        code.read(operand(2))
        code.read(operand(0))
        code.op(0x50)
        code.op(0x45)
        if kind == ir.Float32x2Type:
          code.op(0x1c)
          code.unsigned(1)
          code.op(V128)
        else:
          code.op(0x1b)
      of ir.CompareOp:
        let source = operandKind(0)
        code.read(operand(0))
        code.read(operand(1))
        let opcode = if floating(source):
            (if source == ir.Float32Type: 0x5b else: 0x61) +
              [0, 1, 2, 4, 3, 5][ord(item.comparison)]
          else:
            case item.comparison
            of ir.EqualComparison: 0x51
            of ir.NotEqualComparison: 0x52
            of ir.LessComparison: 0x53 + ord(unsigned(source))
            of ir.LessEqualComparison: 0x57 + ord(unsigned(source))
            of ir.GreaterComparison: 0x55 + ord(unsigned(source))
            of ir.GreaterEqualComparison: 0x59 + ord(unsigned(source))
        code.op(opcode)
        if branches.conditions[item.results.first]:
          return
        code.op(0xad)
      of ir.FloorOp:
        code.read(operand(0))
        code.op(if kind == ir.Float32Type: 0x8e else: 0x9c)
      of ir.RoundOp:
        # Round the fractional part, avoiding the double rounding of abs(x)+0.5.
        code.read(operand(0))
        code.op(0x8b + (if kind == ir.Float64Type: 14 else: 0))
        code.op(0x8f + (if kind == ir.Float64Type: 14 else: 0))
        code.read(operand(0))
        code.op(0x8b + (if kind == ir.Float64Type: 14 else: 0))
        code.read(operand(0))
        code.op(0x8b + (if kind == ir.Float64Type: 14 else: 0))
        code.op(0x8f + (if kind == ir.Float64Type: 14 else: 0))
        code.op(0x93 + (if kind == ir.Float64Type: 14 else: 0))
        code.floating(0.5, kind == ir.Float32Type)
        code.op(0x60 + (if kind == ir.Float64Type: 6 else: 0))
        code.op(0x04)
        code.op(wasmType(kind))
        code.floating(1.0, kind == ir.Float32Type)
        code.op(0x05)
        code.floating(0.0, kind == ir.Float32Type)
        code.op(0x0b)
        code.op(0x92 + (if kind == ir.Float64Type: 14 else: 0))
        code.read(operand(0))
        code.op(0x98 + (if kind == ir.Float64Type: 14 else: 0))
      of ir.AddOp, ir.SubtractOp, ir.MultiplyOp, ir.DivideOp,
          ir.RemainderOp, ir.AndOp, ir.OrOp, ir.XorOp, ir.NotOp,
          ir.NegateOp, ir.SqrtOp, ir.ShiftLeftOp, ir.ShiftRightOp,
          ir.ArithmeticRightOp:
        if item.op == ir.NegateOp and not floating(kind):
          code.constant(0)
        code.read(operand(0))
        if item.op == ir.ShiftRightOp and
            kind in {ir.Int8Type, ir.Int16Type, ir.Int32Type}:
          # A logical shift consumes the narrow pattern, not its signed i64 view.
          code.constant((1'i64 shl (byteCount(kind, 8) * 8)) - 1)
          code.op(0x83)
        if item.arguments.count == 2:
          code.read(operand(1))
        if floating(kind):
          let opcode = case item.op
            of ir.AddOp: 0x92
            of ir.SubtractOp: 0x93
            of ir.MultiplyOp: 0x94
            of ir.DivideOp: 0x95
            of ir.NegateOp: 0x8c
            of ir.SqrtOp: 0x91
            else: raise newException(BackendError,
              "Unsupported floating WASM IR arithmetic")
          code.op(opcode + (if kind == ir.Float64Type: 14 else: 0))
        else:
          case item.op
          of ir.NotOp:
            code.constant(-1)
            code.op(0x85)
          of ir.DivideOp, ir.RemainderOp:
            if not unsigned(kind) and item.op == ir.DivideOp:
              # Avoid WASM's signed minimum divided by minus one trap.
              code.op(0x1a)
              code.op(0x1a)
              code.read(operand(0))
              code.constant(int64.low)
              code.op(0x51)
              code.read(operand(1))
              code.constant(-1)
              code.op(0x51)
              code.op(0x71)
              code.op(0x04)
              code.op(I64)
              code.constant(int64.low)
              code.op(0x05)
              code.read(operand(0))
              code.read(operand(1))
              code.op(0x7f)
              code.op(0x0b)
            else:
              code.op((if item.op == ir.DivideOp: 0x7f else: 0x81) +
                ord(unsigned(kind)))
          else:
            code.op(case item.op
              of ir.AddOp: 0x7c
              of ir.SubtractOp, ir.NegateOp: 0x7d
              of ir.MultiplyOp: 0x7e
              of ir.AndOp: 0x83
              of ir.OrOp: 0x84
              of ir.XorOp: 0x85
              of ir.ShiftLeftOp: 0x86
              of ir.ShiftRightOp: 0x88
              of ir.ArithmeticRightOp: 0x87
              else: raise newException(BackendError,
                "Unsupported integer WASM IR arithmetic"))
          code.normalize(kind)
      for value in countdown(int(item.results.first + item.results.count) - 1,
          int(item.results.first)):
        code.indexed(0x21, locations[value])
    proc dispatch(code: var string, first, stop, depth: int) =
      ## Structures IR blocks as a balanced tree inside a WASM loop.
      if stop - first > 1:
        let middle = (first + stop) div 2
        code.indexed(0x20, dispatchLocal)
        code.constant(middle, false)
        code.op(0x49)
        code.op(0x04)
        code.op(Empty)
        code.dispatch(first, middle, depth + 1)
        code.op(0x05)
        code.dispatch(middle, stop, depth + 1)
        code.op(0x0b)
        return
      let data = function.blocks[first]
      for i in data.instructions.indices:
        code.instruction(function.instructions[i])
      let terminal = data.terminator
      case terminal.kind
      of ir.JumpTerminator:
        code.edge(int(terminal.edges.first))
      of ir.BranchTerminator:
        if branches.comparisons[first] < 0:
          code.read(function.operands[terminal.arguments.first])
          code.op(0xa7)
        code.op(0x04)
        code.op(Empty)
        code.edge(int(terminal.edges.first))
        code.op(0x05)
        code.edge(int(terminal.edges.first) + 1)
        code.op(0x0b)
      of ir.UnreachableTerminator:
        code.op(0x00)
        return
      of ir.ReturnTerminator:
        for argument in terminal.arguments.indices:
          code.read(function.operands[argument])
        code.op(0x0f)
        return
      else:
        error("Unsupported complete WASM IR terminator")
      code.indexed(0x0c, depth)
    var code = ""
    # Check storage before subtracting the explicit linear-memory stack frame.
    code.indexed(0x20, 0)
    code.constant(runtime.stack + frameBytes)
    code.op(0x54)
    code.op(0x04)
    code.op(Empty)
    code.indexed(0x10, runtime.symbol("nifty_stack_failure", 0))
    code.op(0x00)
    code.op(0x0b)
    code.indexed(0x20, 0)
    code.constant(frameBytes)
    code.op(0x7d)
    code.indexed(0x21, frame)
    let parameters = function.blocks[0].parameters
    for i in 0 ..< int(parameters.count):
      if contexts[int(parameters.first) + i]:
        continue
      code.indexed(0x20, i + 1)
      code.indexed(0x21, locations[int(parameters.first) + i])
    code.op(0x03)
    code.op(Empty)
    code.dispatch(0, function.blocks.len, 0)
    code.op(0x0b)
    if returnTypes.len > 0:
      code.op(0x00)
    let compiled = body(code, locals)
    result.codeBytes += compiled.len
    if result.codeBytes > maxBytes:
      error("WASM code size exceeds limits")
    result.bodies.add(compiled)

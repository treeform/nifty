## Exercises the WASM selector directly, independently of source lowering.
import
  std/[os, osproc, strutils],
  nifty/backend/[common, irs, irwasms, wasmbinaries, wasmmodules]

proc runtimeBytes(): string =
  ## Builds a tiny bounded memory64/table64 runtime for selector tests.
  result = "\0asm\x01\0\0\0"
  var section = ""
  section.unsigned(5)
  section.add(signature([I64, I64]))
  section.add(signature([I64, I64, I64, I64, I64]))
  section.add(signature([]))
  section.add(signature([], I64))
  section.add(signature([I64, F32], F32))
  result.section(1, section)
  section = ""
  section.unsigned(5)
  for index in 0 ..< 5:
    section.unsigned(index)
  result.section(3, section)
  section = "\x01\x70\x05\x01\x01"
  result.section(4, section)
  section = "\x01\x05"
  section.unsigned(90)
  section.unsigned(131072)
  result.section(5, section)
  section = "\x02"
  for address in [1024, 1024 + 1024 * 1024]:
    section.op(I64)
    section.op(0)
    section.constant(address)
    section.op(0x0b)
  result.section(6, section)
  section = ""
  section.unsigned(8)
  for item in [("nifty_entry", 0, 0), ("nifty_dispatch", 0, 1),
      ("nifty_stack_failure", 0, 2), ("_start", 0, 3),
      ("test_host", 0, 4), ("nifty_metadata", 3, 0),
      ("nifty_stack", 3, 1), ("memory", 2, 0)]:
    section.name(item[0])
    section.op(item[1])
    section.unsigned(item[2])
  result.section(7, section)
  result.section(9, "\0")
  var code = ""
  code.constant(16)
  code.constant(32)
  code.memory(0x37)
  code.constant(16)
  code.constant(1234)
  code.indexed(0x10, 0)
  code.constant(32)
  code.memory(0x29)
  section = "\x05"
  section.add(body("", []))
  section.add(body("", []))
  section.add(body("\x00", []))
  section.add(body(code, []))
  code = ""
  code.indexed(0x20, 1)
  section.add(body(code, []))
  result.section(10, section)
  result.section(11, "\0")

proc function(parameters, returns: seq[IrType], directOnly = false): IrFunction =
  ## Creates an entry block with its declared signature parameters.
  result = IrFunction(failureMode: NoFailCall, directOnly: directOnly,
    signature: IrSignature(parameters: parameters, returns: returns))
  for kind in parameters:
    result.values.add(IrValue(valueType: kind))
  result.blocks.add(IrBlock(parameters: Span(count: int32(parameters.len))))

proc emit(fn: var IrFunction, op: IrOpcode, kinds: openArray[IrType],
    arguments: openArray[ValueId], bits = 0'u64, target = 0,
    conversion = BitcastConversion, byteCount = 0): seq[ValueId] =
  ## Appends one explicitly typed raw IR instruction.
  var item = IrInstruction(op: op, bits: bits, target: int32(target),
    conversion: conversion, byteCount: int32(byteCount), alignment: 1,
    results: Span(first: int32(fn.values.len), count: int32(kinds.len)),
    arguments: Span(first: int32(fn.operands.len),
      count: int32(arguments.len)))
  for kind in kinds:
    result.add(ValueId(fn.values.len))
    fn.values.add(IrValue(valueType: kind))
  fn.operands.add(arguments)
  fn.instructions.add(item)
  inc fn.blocks[0].instructions.count

proc constant(fn: var IrFunction, kind: IrType, bits: uint64): ValueId =
  ## Defines a literal without involving the language frontend.
  fn.emit(ConstantOp, [kind], [], bits)[0]

proc finish(fn: var IrFunction, returns: openArray[ValueId] = []) =
  ## Terminates a one-block function with explicit result operands.
  fn.blocks[0].terminator = IrTerminator(kind: ReturnTerminator,
    arguments: Span(first: int32(fn.operands.len), count: int32(returns.len)))
  fn.operands.add(returns)

proc moduleForTest(): IrModule =
  ## Selects entry one so an accidental function-zero wrapper traps.
  result.pointerBytes = 8
  var trap = function(@[AddressType, AddressType, AddressType, AddressType], @[])
  trap.blocks[0].terminator.kind = UnreachableTerminator
  result.functions.add(trap)
  result.functions.add(function(
    @[AddressType, AddressType, AddressType, AddressType], @[]))
  result.globals.add(IrGlobal(bytes: Span(count: 8), alignment: 8))
  result.data = newSeq[system.byte](8)

proc storeResult(module: var IrModule, value: ValueId) =
  ## Stores the selected scalar result through RuntimeContext.globals.
  let address = module.functions[1].emit(GlobalAddressOp,
    [AddressType], [])[0]
  discard module.functions[1].emit(StoreOp, [], [address, value])
  module.functions[1].finish()

let runtime = parseModule(runtimeBytes())
let runner = findExe("wasmtime")
var sequence = 0

proc execute(module: IrModule, expected: int64,
    symbols: seq[string] = @[]): string =
  ## Validates and executes the filled binary with a real WASM64 engine.
  let image = emitWasmIr(module, runtime, 1, symbols)
  result = filledModule(runtime, image.bodies, "", image.types,
    image.indirectTypes)
  if runner.len == 0:
    return
  inc sequence
  let path = getTempDir() / ("nifty-irwasm-" & $getCurrentProcessId() &
    "-" & $sequence & ".wasm")
  writeFile(path, result)
  defer: removeFile(path)
  let execution = execCmdEx(quoteShell(runner) & " run --invoke _start " &
    quoteShell(path))
  doAssert execution.exitCode == 0, execution.output
  doAssert execution.output.strip().splitLines()[^1] == $expected,
    execution.output

var arena = moduleForTest()
arena.storeResult(ValueId(3))
discard arena.execute(1234)

var edited = moduleForTest()
let changed = edited.functions[1].constant(Int64Type, 5678)
edited.storeResult(changed)
doAssert arena.execute(1234) != edited.execute(5678)

var division = moduleForTest()
let
  minimum = division.functions[1].constant(Int64Type, cast[uint64](int64.low))
  negative = division.functions[1].constant(Int64Type, uint64.high)
  quotient = division.functions[1].emit(DivideOp, [Int64Type],
    [minimum, negative])[0]
division.storeResult(quotient)
discard division.execute(int64.low)

var narrow = moduleForTest()
let
  byteValue = narrow.functions[1].constant(UInt8Type, 511)
  widened = narrow.functions[1].emit(ConvertOp, [UInt64Type], [byteValue],
    conversion = ZeroExtendConversion)[0]
narrow.storeResult(widened)
discard narrow.execute(255)

var signedByte = moduleForTest()
let
  byteValueSigned = signedByte.functions[1].constant(Int8Type, 255)
  widenedSigned = signedByte.functions[1].emit(ConvertOp, [Int64Type],
    [byteValueSigned], conversion = SignExtendConversion)[0]
signedByte.storeResult(widenedSigned)
discard signedByte.execute(-1)

var bundle = moduleForTest()
var callee = function(@[AddressType], @[Float64Type, Float64Type], true)
let
  left = callee.constant(Float64Type, cast[uint64](1.75))
  right = callee.constant(Float64Type, cast[uint64](2.5))
callee.finish([left, right])
bundle.functions.add(callee)
let
  returned = bundle.functions[1].emit(CallOp, [Float64Type, Float64Type],
    [ValueId(0)], target = 2)
  sum = bundle.functions[1].emit(AddOp, [Float64Type], returned)[0]
  rounded = bundle.functions[1].emit(RoundOp, [Float64Type], [sum])[0]
  integer = bundle.functions[1].emit(ConvertOp, [Int64Type], [rounded],
    conversion = FloatIntegerConversion)[0]
bundle.storeResult(integer)
discard bundle.execute(4)

var host = moduleForTest()
host.hosts.add(IrHost(name: "test_host", failureMode: NoFailCall,
  signature: IrSignature(parameters: @[Int64Type, Float32Type],
    returns: @[Float32Type])))
let
  ignored = host.functions[1].constant(Int64Type, 999)
  floating = host.functions[1].constant(Float32Type,
    cast[uint32](6.5'f).uint64)
  returnedHost = host.functions[1].emit(HostCallOp, [Float32Type],
    [ignored, floating])[0]
  flooredHost = host.functions[1].emit(FloorOp, [Float32Type],
    [returnedHost])[0]
  hostInteger = host.functions[1].emit(ConvertOp, [Int64Type], [flooredHost],
    conversion = FloatIntegerConversion)[0]
host.storeResult(hostInteger)
discard host.execute(6, @["test_host"])
var rejected = false
try:
  discard emitWasmIr(host, runtime, 1, @["nifty_dispatch"])
except BackendError:
  rejected = true
doAssert rejected

var bulk = moduleForTest()
bulk.functions[1].slots.add(IrSlot(byteCount: 16, alignment: 8))
let slot = bulk.functions[1].emit(SlotAddressOp, [AddressType], [])[0]
discard bulk.functions[1].emit(ClearBytesOp, [], [slot], byteCount = 16)
let stored = bulk.functions[1].constant(UInt64Type, 0x1122)
discard bulk.functions[1].emit(StoreOp, [], [slot, stored])
let
  displacement = bulk.functions[1].constant(UInt64Type, 1)
  destination = bulk.functions[1].emit(OffsetAddressOp, [AddressType],
    [slot, displacement])[0]
discard bulk.functions[1].emit(MoveBytesOp, [], [destination, slot],
  byteCount = 7)
let moved = bulk.functions[1].emit(LoadOp, [UInt64Type], [destination])[0]
bulk.storeResult(moved)
discard bulk.execute(0x1122)

var vector = moduleForTest()
let
  laneOne = vector.functions[1].constant(Float32Type,
    cast[uint32](1.5'f).uint64)
  laneTwo = vector.functions[1].constant(Float32Type,
    cast[uint32](2.5'f).uint64)
  packed = vector.functions[1].emit(PackOp, [Float32x2Type],
    [laneOne, laneTwo])[0]
  doubled = vector.functions[1].emit(VectorAddOp, [Float32x2Type],
    [packed, packed])[0]
  reduced = vector.functions[1].emit(VectorSumOp, [Float32Type], [doubled])[0]
  vectorInteger = vector.functions[1].emit(ConvertOp, [Int64Type], [reduced],
    conversion = FloatIntegerConversion)[0]
vector.storeResult(vectorInteger)
discard vector.execute(8)

var indirect = moduleForTest()
var target = function(@[AddressType], @[Int64Type])
let targetResult = target.constant(Int64Type, 77)
target.finish([targetResult])
indirect.functions.add(target)
indirect.signatures.add(target.signature)
let
  tableIndex = indirect.functions[1].constant(AddressType,
    uint64(runtime.tableSize + 2))
  indirectResult = indirect.functions[1].emit(IndirectCallOp, [Int64Type],
    [tableIndex, ValueId(0)])[0]
indirect.storeResult(indirectResult)
discard indirect.execute(77)

for sectionIndex in [4, 5]:
  var invalid = runtime
  invalid.sections[sectionIndex][if sectionIndex == 4: 2 else: 1] = char(1)
  var invalidBytes = "\0asm\x01\0\0\0"
  for id in [1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 10, 11, 13]:
    if invalid.sections[id].len > 0:
      invalidBytes.section(id, invalid.sections[id])
  rejected = false
  try:
    discard parseModule(invalidBytes)
  except BackendError:
    rejected = true
  doAssert rejected, "A memory32/table32 runtime must be rejected"

if runner.len == 0:
  echo "IR WASM binaries checked; install wasmtime to execute them"
else:
  echo "IR WASM selector checks passed"

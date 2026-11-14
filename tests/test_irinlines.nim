import nifty/backend/[context, engine, irchecks, irinlines, memories]

proc function(name: string, parameters: seq[IrType],
    returns: seq[IrType] = @[]): IrFunction =
  ## Creates a test routine with explicit scalar signature and entry block.
  result = IrFunction(name: name, failureMode: NoFailCall,
    signature: IrSignature(parameters: parameters, returns: returns))
  for kind in parameters:
    result.values.add(IrValue(valueType: kind))
  result.blocks.add(IrBlock(parameters:
    Span(first: 0, count: int32(parameters.len))))

proc arguments(function: var IrFunction,
    values: openArray[ValueId]): Span =
  ## Appends an ordered test operand list.
  result = Span(first: int32(function.operands.len), count: int32(values.len))
  function.operands.add(values)

proc instruction(function: var IrFunction, op: IrOpcode,
    arguments: openArray[ValueId], kind = Int64Type, bits = 0'u64,
    target = 0'i32, offset = 0'i64, count = 1): ValueId =
  ## Appends an explicitly typed test instruction in the current block.
  result = ValueId(function.values.len)
  let span = function.arguments(arguments)
  for i in 0 ..< count:
    function.values.add(IrValue(valueType: kind))
  function.instructions.add(IrInstruction(op: op, bits: bits,
    target: target, offset: offset, alignment: 1,
    results: Span(first: int32(result), count: int32(count)), arguments: span))
  inc function.blocks[^1].instructions.count

proc newBlock(function: var IrFunction,
    parameters: openArray[IrType] = []): seq[ValueId] =
  ## Starts a block with fresh consecutive SSA parameter definitions.
  let first = int32(function.values.len)
  for kind in parameters:
    result.add(ValueId(function.values.len))
    function.values.add(IrValue(valueType: kind))
  function.blocks.add(IrBlock(parameters:
    Span(first: first, count: int32(parameters.len)),
    instructions: Span(first: int32(function.instructions.len))))

proc edge(function: var IrFunction, target: int,
    values: openArray[ValueId] = []): int32 =
  ## Creates a directed CFG edge with explicit phi transfers.
  result = int32(function.edges.len)
  function.edges.add(IrEdge(target: BlockId(target),
    arguments: function.arguments(values)))

proc finish(function: var IrFunction,
    values: openArray[ValueId] = []) =
  ## Terminates a block with a possibly scalar normal return.
  function.blocks[^1].terminator = IrTerminator(kind: ReturnTerminator,
    arguments: function.arguments(values))

proc jump(function: var IrFunction, target: int,
    values: openArray[ValueId] = []) =
  ## Terminates the current block with a parameterized jump.
  function.blocks[^1].terminator = IrTerminator(kind: JumpTerminator,
    edges: Span(first: function.edge(target, values), count: 1))

proc branch(function: var IrFunction, condition: ValueId, yes, no: int) =
  ## Terminates the current block with two ordered successors.
  let first = function.edge(yes)
  discard function.edge(no)
  function.blocks[^1].terminator = IrTerminator(kind: BranchTerminator,
    arguments: function.arguments([condition]),
    edges: Span(first: first, count: 2))

const Abi = @[AddressType, AddressType, AddressType, AddressType]

proc invoke(module: IrModule, index: int, input, output: pointer,
    bindings: pointer = nil, reserved: pointer = nil) =
  ## Verifies both targets and executes the host target's chosen entry.
  verifyIr(module)
  for target in NativeTarget:
    let image = emitNative(module, target)
    doAssert image.offsets.len == module.functions.len
    when defined(arm64) or defined(amd64):
      let nativeTarget = when defined(arm64): Arm64Target else: Amd64Target
      if target == nativeTarget:
        var
          buffer = initCodeBuffer(image.bytes)
          ctx = RuntimeContext(hosts: bindings)
        type Entry = proc(ctx, arguments, returned, reserved: pointer)
          {.cdecl, raises: [].}
        let entry = cast[Entry](cast[uint](buffer.entry()) +
          uint(image.offsets[index]))
        entry(ctx.addr, input, output, reserved)
        buffer.release()

var vector = function("vector", Abi)
vector.slots = @[IrSlot(byteCount: 12, alignment: 4)]
let temporary = vector.instruction(SlotAddressOp, [], AddressType)
discard vector.instruction(MoveBytesOp, [temporary, ValueId(1)], count = 0)
vector.instructions[^1].byteCount = 12
let factor = vector.instruction(ConstantOp, [], Float32Type,
  bits = uint64(cast[uint32](2.0'f)))
for i in 0 ..< 3:
  let
    value = vector.instruction(LoadOp, [temporary], Float32Type,
      offset = int64(i * 4))
    doubled = vector.instruction(MultiplyOp, [value, factor], Float32Type)
  discard vector.instruction(StoreOp, [ValueId(2), doubled],
    offset = int64(i * 4), count = 0)
vector.finish()
var vectorCaller = function("vectorCaller", Abi)
discard vectorCaller.instruction(CallOp,
  [ValueId(0), ValueId(1), ValueId(2), ValueId(3)], target = 0, count = 0)
vectorCaller.finish()
var vectorModule = IrModule(pointerBytes: 8, functions: @[vector, vectorCaller])
var input = [1.0'f, -2.0'f, 3.5'f]
var output: array[3, float32]
vectorModule.invoke(1, input.addr, output.addr)
doAssert output == [2.0'f, -4.0'f, 7.0'f]
let vectorStats = vectorModule.inlineIr()
doAssert vectorStats.callsInlined == 1
doAssert vectorStats.slotsAdded == 1
doAssert vectorModule.functions.len == 2
output = [0.0'f, 0.0'f, 0.0'f]
vectorModule.invoke(1, input.addr, output.addr)
doAssert output == [2.0'f, -4.0'f, 7.0'f]

var sum = function("sum", Abi)
let limit = sum.instruction(LoadOp, [ValueId(1)])
let
  zero = sum.instruction(ConstantOp, [], bits = 0)
  one = sum.instruction(ConstantOp, [], bits = 1)
  negative = sum.instruction(CompareOp, [limit, zero], BoolType)
sum.instructions[^1].comparison = LessComparison
sum.branch(negative, 1, 2)
discard sum.newBlock()
discard sum.instruction(StoreOp, [ValueId(2), one], count = 0)
sum.finish()
discard sum.newBlock()
sum.jump(3, [zero, zero])
let state = sum.newBlock([Int64Type, Int64Type])
let condition = sum.instruction(CompareOp, [state[0], limit], BoolType)
sum.instructions[^1].comparison = LessComparison
sum.branch(condition, 4, 5)
discard sum.newBlock()
let
  next = sum.instruction(AddOp, [state[0], one])
  total = sum.instruction(AddOp, [state[1], next])
sum.jump(3, [next, total])
discard sum.newBlock()
discard sum.instruction(StoreOp, [ValueId(2), state[1]], count = 0)
sum.finish()
var caller = function("sumCaller", Abi)
discard caller.instruction(CallOp,
  [ValueId(0), ValueId(1), ValueId(2), ValueId(3)], target = 0, count = 0)
caller.finish()
var loopModule = IrModule(pointerBytes: 8, functions: @[sum, caller])
for optimized in [false, true]:
  if optimized:
    doAssert loopModule.inlineIr().callsInlined == 1
  for value in [-5'i64, 0, 1, 10]:
    var
      argument = value
      answer = 0'i64
    loopModule.invoke(1, argument.addr, answer.addr)
    doAssert answer == (if value < 0: 1'i64 else: value * (value + 1) div 2)

proc mutate(address: ptr int64) {.cdecl, raises: [].} =
  ## Gives the alias test an observable host mutation between IR accesses.
  address[] += 3

var effect = function("effect", Abi)
let ten = effect.instruction(ConstantOp, [], bits = 10)
discard effect.instruction(StoreOp, [ValueId(1), ten], count = 0)
discard effect.instruction(HostCallOp, [ValueId(2)], count = 0)
let observed = effect.instruction(LoadOp, [ValueId(1)])
discard effect.instruction(StoreOp, [ValueId(2), observed], count = 0)
effect.finish()
var effectCaller = function("effectCaller", Abi)
discard effectCaller.instruction(CallOp,
  [ValueId(0), ValueId(1), ValueId(1), ValueId(3)], target = 0, count = 0)
let
  after = effectCaller.instruction(LoadOp, [ValueId(1)])
  two = effectCaller.instruction(ConstantOp, [], bits = 2)
  multiplied = effectCaller.instruction(MultiplyOp, [after, two])
discard effectCaller.instruction(StoreOp, [ValueId(2), multiplied], count = 0)
effectCaller.finish()
var effectModule = IrModule(pointerBytes: 8,
  functions: @[effect, effectCaller], hosts: @[
    IrHost(name: "mutate", failureMode: NoFailCall,
      signature: IrSignature(parameters: @[AddressType]))])
var bindings = [cast[pointer](mutate)]
for optimized in [false, true]:
  if optimized:
    doAssert effectModule.inlineIr().callsInlined == 1
  var
    argument = 5'i64
    answer = 0'i64
  effectModule.invoke(1, argument.addr, answer.addr, bindings.addr)
  doAssert argument == 13
  doAssert answer == 26

var contextCaller = effectCaller
contextCaller.name = "differentContext"
contextCaller.operands[contextCaller.instructions[0].arguments.first] = ValueId(3)
var contextModule = IrModule(pointerBytes: 8,
  functions: @[effect, contextCaller], hosts: effectModule.hosts)
doAssert contextModule.inlineIr().callsInlined == 0
var
  alternateContext = RuntimeContext(hosts: bindings.addr)
  contextArgument = 5'i64
  contextAnswer = 0'i64
contextModule.invoke(1, contextArgument.addr, contextAnswer.addr,
  reserved = alternateContext.addr)
doAssert contextArgument == 13 and contextAnswer == 26
var aliasCaller = function("sameContextAlias", Abi)
let contextAlias = aliasCaller.instruction(ConvertOp, [ValueId(0)], AddressType)
aliasCaller.instructions[^1].conversion = BitcastConversion
discard aliasCaller.instruction(CallOp,
  [contextAlias, ValueId(1), ValueId(2), ValueId(3)], target = 0, count = 0)
aliasCaller.finish()
var aliasModule = IrModule(pointerBytes: 8,
  functions: @[effect, aliasCaller], hosts: effectModule.hosts)
doAssert aliasModule.inlineIr().callsInlined == 1
verifyIr(aliasModule)

var scalar = function("scalar", @[AddressType, Int64Type], @[Int64Type])
scalar.directOnly = true
let increment = scalar.instruction(ConstantOp, [], bits = 1)
let incremented = scalar.instruction(AddOp, [ValueId(1), increment])
scalar.finish([incremented])
var scalarCaller = function("scalarCaller", Abi)
let
  scalarArgument = scalarCaller.instruction(LoadOp, [ValueId(1)])
  scalarAnswer = scalarCaller.instruction(CallOp,
    [ValueId(0), scalarArgument], target = 1)
discard scalarCaller.instruction(StoreOp, [ValueId(2), scalarAnswer], count = 0)
scalarCaller.finish()
var scalarEntry = function("scalarEntry", Abi)
scalarEntry.finish()
var scalarModule = IrModule(pointerBytes: 8,
  functions: @[scalarEntry, scalar, scalarCaller])
for optimized in [false, true]:
  if optimized:
    doAssert scalarModule.inlineIr().callsInlined == 1
  var
    argument = 41'i64
    answer = 0'i64
  scalarModule.invoke(2, argument.addr, answer.addr)
  doAssert answer == 42
doAssert scalarModule.functions[2].blocks[^1].parameters.count == 1

var bundle = function("bundle", @[AddressType, Float32Type],
  @[Float32Type, Float32Type, Float32Type])
bundle.directOnly = true
let
  bundleTwo = bundle.instruction(ConstantOp, [], Float32Type,
    bits = uint64(cast[uint32](2.0'f)))
  bundleThree = bundle.instruction(ConstantOp, [], Float32Type,
    bits = uint64(cast[uint32](3.0'f)))
  laneTwo = bundle.instruction(MultiplyOp,
    [ValueId(1), bundleTwo], Float32Type)
  laneThree = bundle.instruction(MultiplyOp,
    [ValueId(1), bundleThree], Float32Type)
bundle.finish([ValueId(1), laneTwo, laneThree])
var bundleCaller = function("bundleCaller", Abi)
let
  bundleArgument = bundleCaller.instruction(LoadOp, [ValueId(1)], Float32Type)
  bundleAnswer = bundleCaller.instruction(CallOp,
    [ValueId(0), bundleArgument], Float32Type, target = 1, count = 3)
for i in 0 ..< 3:
  discard bundleCaller.instruction(StoreOp,
    [ValueId(2), ValueId(int32(bundleAnswer) + int32(i))],
    offset = int64(i * 4), count = 0)
bundleCaller.finish()
var bundleModule = IrModule(pointerBytes: 8,
  functions: @[scalarEntry, bundle, bundleCaller])
for optimized in [false, true]:
  if optimized:
    doAssert bundleModule.inlineIr().callsInlined == 1
  var
    argument = 4.0'f
    answer: array[3, float32]
  bundleModule.invoke(2, argument.addr, answer.addr)
  doAssert answer == [4.0'f, 8.0'f, 12.0'f]

var wideBundle = function("wideBundle", @[AddressType, Float64Type],
  @[Float64Type, Float64Type, Float64Type])
wideBundle.directOnly = true
let
  wideZero = wideBundle.instruction(ConstantOp, [], Float64Type)
  wideCondition = wideBundle.instruction(CompareOp,
    [ValueId(1), wideZero], BoolType)
wideBundle.instructions[^1].comparison = LessComparison
wideBundle.branch(wideCondition, 1, 2)
discard wideBundle.newBlock()
let
  wideNegativeZero = wideBundle.instruction(ConstantOp, [], Float64Type,
    bits = 0x8000000000000000'u64)
  wideNan = wideBundle.instruction(ConstantOp, [], Float64Type,
    bits = 0x7ff8000000001234'u64)
wideBundle.finish([ValueId(1), wideNegativeZero, wideNan])
discard wideBundle.newBlock()
var wideLanes: seq[ValueId]
for scale in [2.0, 3.0, 4.0]:
  let factor = wideBundle.instruction(ConstantOp, [], Float64Type,
    bits = cast[uint64](scale))
  wideLanes.add(wideBundle.instruction(MultiplyOp,
    [ValueId(1), factor], Float64Type))
wideBundle.finish(wideLanes)
var wideCaller = function("wideCaller", Abi)
let
  wideArgument = wideCaller.instruction(LoadOp, [ValueId(1)], Float64Type)
  wideAnswer = wideCaller.instruction(CallOp,
    [ValueId(0), wideArgument], Float64Type, target = 1, count = 3)
for i in 0 ..< 3:
  discard wideCaller.instruction(StoreOp,
    [ValueId(2), ValueId(int32(wideAnswer) + int32(i))],
    offset = int64(i * 8), count = 0)
wideCaller.finish()
var wideModule = IrModule(pointerBytes: 8,
  functions: @[scalarEntry, wideBundle, wideCaller])
for optimized in [false, true]:
  if optimized:
    doAssert wideModule.inlineIr().callsInlined == 1
    doAssert wideModule.functions[2].blocks[^1].parameters.count == 3
  for value in [4.0, -4.0]:
    var
      argument = value
      answer: array[3, uint64]
    wideModule.invoke(2, argument.addr, answer.addr)
    let expected = if value < 0:
        [cast[uint64](value), 0x8000000000000000'u64, 0x7ff8000000001234'u64]
      else:
        [cast[uint64](value * 2), cast[uint64](value * 3), cast[uint64](value * 4)]
    doAssert answer == expected

var budgetModule = IrModule(pointerBytes: 8, functions: @[vector, vectorCaller])
var budget = defaultInlineConfig()
budget.maxModuleGrowth = 0
let budgetStats = budgetModule.inlineIr(budget)
doAssert budgetStats.callsInlined == 0
doAssert budgetStats.budgetRejected > 0
verifyIr(budgetModule)

for limit in 0 ..< 2:
  var limited = IrModule(pointerBytes: 8, functions: @[vector, vectorCaller])
  var config = defaultInlineConfig()
  if limit == 0:
    config.maxFunctionBlocks = 1
  else:
    config.maxFunctionSlots = 0
  let stats = limited.inlineIr(config)
  doAssert stats.callsInlined == 0
  doAssert stats.budgetRejected > 0
  verifyIr(limited)

var recursive = function("recursive", Abi)
discard recursive.instruction(CallOp,
  [ValueId(0), ValueId(1), ValueId(2), ValueId(3)], target = 0, count = 0)
recursive.finish()
var recursiveModule = IrModule(pointerBytes: 8,
  functions: @[recursive, vectorCaller])
doAssert recursiveModule.inlineIr().callsInlined == 0
verifyIr(recursiveModule)

echo "IR inlining, control flow, aliases, and budgets passed"

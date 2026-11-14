## Verifies native resource accounting from finalized frames and direct calls.
import std/strutils
import ../src/nifty/[common, nativeplans, nativereports]
import ../src/nifty/backend/[engine, irs]

proc samplePlan(): NativePlan =
  ## Builds a diamond call graph with duplicated calls and two thread types.
  result.module.functions = @[
    IrFunction(name: "unused wrapper target"),
    IrFunction(name: "leaf"),
    IrFunction(name: "middle", instructions: @[
      IrInstruction(op: CallOp, target: 1)]),
    IrFunction(name: "worker", instructions: @[
      IrInstruction(op: CallOp, target: 1),
      IrInstruction(op: CallOp, target: 2),
      IrInstruction(op: CallOp, target: 2)]),
    IrFunction(name: "other", blocks: @[IrBlock(
      terminator: IrTerminator(kind: InvokeTerminator, callee: 1))])]
  result.globalBytes = 80
  result.initialData = newSeq[byte](80)
  result.module.data = newSeq[byte](80)
  result.threads = @[
    ThreadPlan(name: "worker", count: 3, functionIndex: 3, arenaBytes: 128),
    ThreadPlan(name: "other", count: 2, functionIndex: 4, arenaBytes: 16)]

proc sampleImage(): NativeImage =
  ## Supplies deterministic finalized native frame sizes.
  NativeImage(target: Arm64Target, bytes: newSeq[byte](512),
    frameBytes: @[1000, 16, 32, 48, 64], wrapperFrameBytes: 32)

proc rejected(plan: NativePlan, image: NativeImage, expected: string) =
  ## Checks invalid inputs fail as compiler errors rather than false bounds.
  var failed = false
  try:
    discard nativeReport(plan, image, "test.nifty")
  except NiftyError as error:
    failed = true
    doAssert expected in error.msg, error.msg
  doAssert failed, "Expected native report rejection: " & expected

let
  plan = samplePlan()
  image = sampleImage()
  report = nativeReport(plan, image, "test.nifty")
doAssert "nifty native report: test.nifty (arm64)" in report
doAssert "machine code: 512 bytes (including wrapper)" in report
doAssert "global storage: 80 bytes" in report
doAssert "initialization payload: 80 bytes" in report
doAssert "read-only global payload: 0 bytes" in report
doAssert "worker x3: 96 bytes each, 288 bytes all instances " &
  "(worker -> middle -> leaf)" in report
doAssert "other x2: 80 bytes each, 160 bytes all instances " &
  "(other -> leaf)" in report
doAssert "total: 448 bytes across 5 thread instances" in report
doAssert "worker x3: 128 bytes each, 384 bytes all instances" in report
doAssert "other x2: 16 bytes each, 32 bytes all instances" in report
doAssert "total: 416 bytes" in report
doAssert "accounted storage (globals + stack bounds + arenas): " &
  "944 bytes" in report
doAssert "entry wrapper: 32 bytes (unused by thread entries)" in report
doAssert "external host stack is excluded" in report
doAssert "not native instruction counts or wall-time promises" in report

block:
  var changed = image
  changed.target = Amd64Target
  doAssert "(amd64)" in nativeReport(plan, changed, "test.nifty")

block:
  var changed = plan
  changed.module.globals = @[
    IrGlobal(bytes: Span(count: 12), readonly: true),
    IrGlobal(bytes: Span(count: 68))]
  doAssert "read-only global payload: 12 bytes" in
    nativeReport(changed, image, "test.nifty")

block:
  let empty = nativeReport(NativePlan(), NativeImage(), "empty.nifty")
  doAssert "total: 0 bytes across 0 thread instances" in empty
  doAssert "accounted storage (globals + stack bounds + arenas): " &
    "0 bytes" in empty

block:
  var changed = plan
  changed.module.functions[1].instructions = @[
    IrInstruction(op: CallOp, target: 3)]
  rejected(changed, image, "recursive native call graph")

block:
  var changed = plan
  changed.module.functions[0].instructions = @[
    IrInstruction(op: CallOp, target: 0)]
  rejected(changed, image, "recursive native call graph")

block:
  var changed = plan
  changed.module.functions[3].instructions[0].target = -1
  rejected(changed, image, "invalid call target")

block:
  var changed = plan
  changed.module.functions[3].instructions[0].target = 5
  rejected(changed, image, "invalid call target")

block:
  var changed = plan
  changed.module.functions[3].instructions[0].op = IndirectCallOp
  rejected(changed, image, "indirect call prevents")

block:
  var changed = plan
  changed.module.functions[3].instructions = @[
    IrInstruction(op: HostCallOp, target: 0)]
  var amd = image
  amd.target = Amd64Target
  doAssert "worker x3: 56 bytes each" in
    nativeReport(changed, amd, "host.nifty")
  doAssert "worker x3: 48 bytes each" in
    nativeReport(changed, image, "host.nifty")
  changed.module.functions[3].instructions = @[]
  changed.module.functions[3].blocks = @[IrBlock(
    terminator: IrTerminator(kind: InvokeHostTerminator, callee: 0))]
  doAssert "worker x3: 56 bytes each" in
    nativeReport(changed, amd, "host.nifty")

block:
  var changed = image
  changed.frameBytes.setLen(3)
  rejected(plan, changed, "frame table does not match")

block:
  var changed = image
  changed.frameBytes[0] = -1
  rejected(plan, changed, "negative frame size")

block:
  var changed = image
  changed.wrapperFrameBytes = -1
  rejected(plan, changed, "negative wrapper frame size")

block:
  var changed = plan
  changed.threads[0].functionIndex = 5
  rejected(changed, image, "invalid entry function")

block:
  var changed = plan
  changed.threads[0].count = 0
  rejected(changed, image, "instance count must be positive")

block:
  var changed = plan
  changed.threads[0].arenaBytes = -1
  rejected(changed, image, "negative arena size")

block:
  var changed = plan
  changed.globalBytes = -1
  rejected(changed, image, "negative global storage size")

block:
  var changed = plan
  changed.threads[0].count = high(int)
  rejected(changed, image, "byte count exceeds")

block:
  var changed = image
  changed.frameBytes[1] = high(int)
  rejected(plan, changed, "byte count exceeds")

block:
  var leaf = IrFunction(name: "generatedLeaf", failureMode: NoFailCall,
    signature: IrSignature(parameters: @[
      AddressType, AddressType, AddressType, AddressType]),
    values: @[
      IrValue(valueType: AddressType), IrValue(valueType: AddressType),
      IrValue(valueType: AddressType), IrValue(valueType: AddressType)],
    blocks: @[IrBlock(parameters: Span(count: 4),
      terminator: IrTerminator(kind: ReturnTerminator))],
    slots: @[IrSlot(byteCount: 128, alignment: 16)])
  var caller = leaf
  caller.name = "generatedCaller"
  caller.slots = @[]
  caller.operands = @[ValueId(0), ValueId(1), ValueId(2), ValueId(3)]
  caller.instructions = @[IrInstruction(op: CallOp,
    arguments: Span(count: 4), target: 0)]
  caller.blocks[0].instructions = Span(count: 1)
  let generatedPlan = NativePlan(
    module: IrModule(pointerBytes: 8, functions: @[leaf, caller]),
    threads: @[ThreadPlan(name: "generatedCaller", count: 2,
      functionIndex: 1, arenaBytes: 64)])
  for target in [Arm64Target, Amd64Target]:
    let
      generated = emitNative(generatedPlan.module, target)
      generatedReport = nativeReport(generatedPlan, generated, "emitted.nifty")
      stackBytes = generated.frameBytes[0] + generated.frameBytes[1]
    doAssert generated.frameBytes[0] >= 128
    doAssert "machine code: " & $generated.bytes.len & " bytes" in
      generatedReport
    doAssert "generatedCaller x2: " & $stackBytes & " bytes each, " &
      $(stackBytes * 2) & " bytes all instances " &
      "(generatedCaller -> generatedLeaf)" in generatedReport

echo "Native resource report tests passed"

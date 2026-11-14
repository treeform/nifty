## Checks constant-range expansion against the original native behavior.
import std/[os, strutils]
import nifty/[parser, loader, checker, lowering, nativeunroll, types]
import nifty/backend/[engine, context, memories]

proc evaluate(source: Module): int64 =
  ## Runs the compute routine directly through its native storage ABI.
  let
    plan = lowerNative(source)
    target = when defined(arm64): Arm64Target else: Amd64Target
    image = emitNative(plan.module, target)
  var buffer = initCodeBuffer(image.bytes)
  defer: buffer.release()
  var ctx: RuntimeContext
  type Entry = proc(ctx, arguments, returned, reserved: pointer)
    {.cdecl, raises: [].}
  let entry = cast[Entry](cast[uint](buffer.entry()) + uint(image.offsets[1]))
  entry(ctx.addr, nil, result.addr, nil)

proc loops(body: seq[Stmt]): int =
  ## Counts remaining source range loops across every conditional path.
  for item in body:
    if item.kind == ForStmt:
      inc result
    result += loops(item.body) + loops(item.elseBody)
    for branch in item.elifs:
      result += loops(branch.body)

proc verify(body: string, expected: int64, remaining = 0,
    config = defaultNativeUnrollConfig()) =
  ## Compares unrolled execution and verifies the expected planning decision.
  let text = "proc compute(): int =\n" & body.indent(2) &
    "\nthread main() =\n  discard compute()\n"
  let source = parse(loadTokens(text, "unroll-test", ""))
  check(source)
  let before = loops(source.routines[0].body)
  let expanded = unrollNative(source, config)
  doAssert loops(expanded.routines[0].body) == remaining
  doAssert loops(source.routines[0].body) == before
  doAssert evaluate(source) == expected
  doAssert evaluate(expanded) == expected

verify("""var answer: -1000 .. 1000 = 0
for i in 0 ..< 0:
  if answer >= -900 and answer <= 900:
    answer = answer + i
return answer""", 0)
verify("""var answer: -1000 .. 1000 = 0
for i in 0 ..< 1:
  if answer >= -900 and answer <= 900:
    answer = answer + i + 1
return answer""", 1)
verify("""var answer: -1000 .. 1000 = 0
for i in 3 ..< 6:
  let value = i
  if answer >= -900 and answer <= 900:
    answer = answer + value
return answer""", 12)
verify("""var answer: -1000 .. 1000 = 0
for i in -3 ..< 1:
  if answer >= -900 and answer <= 900:
    answer = answer + i
return answer""", -6)
verify("""var answer: -1000 .. 1000 = 0
for i in 2 .. 4:
  if answer >= -900 and answer <= 900:
    answer = answer + i
return answer""", 9)
verify("""var answer: -1000 .. 1000 = 0
for i in 0 ..< 5:
  if i == 2:
    break
  if answer >= -900 and answer <= 900:
    answer = answer + i
return answer""", 1)
verify("""for i in 0 ..< 5:
  if i == 2:
    return 20 + i
return 99""", 22)
verify("""var answer: -1000 .. 1000 = 0
for i in 0 ..< 3:
  for j in 0 ..< 2:
    if answer >= -900 and answer <= 900:
      answer = answer + i * 2 + j
return answer""", 15, 1)
verify("""var answer: -1000 .. 1000 = 0
for i in 0 ..< 33:
  if answer >= -900 and answer <= 900:
    answer = answer + i
return answer""", 528, 1)
verify("""var answer: -1000 .. 1000 = 0
for i in 3 ..< 2:
  if answer >= -900 and answer <= 900:
    answer = answer + i
return answer""", 0)
verify("""var answer: -1000 .. 1000 = 0
for i in 1 ..< 4:
  if answer <= 900:
    answer = answer + i
return answer""", 6, 1,
  NativeUnrollConfig(maxIterations: 32, maxBodyNodes: 100, maxGrowth: 0))
verify("""var answer: -1000 .. 1000 = 0
for i in 0 ..< 3:
  for j in 0 ..< 4:
    if j == 2:
      break
    if answer <= 900:
      answer = answer + j
return answer""", 3, 1)

for path in walkFiles("tests/scripts/*.nifty"):
  if path.extractFilename.startsWith("_"):
    continue
  let source = parse(loadTokens(readFile(path), path, path.parentDir))
  check(source)
  let plan = lowerNative(unrollNative(source), path)
  for target in NativeTarget:
    doAssert emitNative(plan.module, target).bytes.len > 0

echo "Native bounded range unrolling passed"

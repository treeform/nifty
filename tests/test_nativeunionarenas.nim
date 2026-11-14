## Checks large constructors, arguments, and returns use native arena storage.
import ../src/nifty/[types, parser, loader, checker, lowering]

let sourceText = readFile("tests/scripts/union_large.nifty")
let source = parse(loadTokens(sourceText, "union_large.nifty", ""))
check(source)
let plan = lowerNative(source, "union_large")
doAssert plan.threads.len == 1
doAssert plan.threads[0].arenaBytes >= 4096 * 8
for routine in plan.module.functions:
  for slot in routine.slots:
    doAssert int64(slot.byteCount) <= arenaThreshold,
      "Large constructor storage escaped arena planning"
echo "Native union constructor arena accounting passed"

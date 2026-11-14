## Checks every accepted language fixture through both machine backends.
import std/[os, strutils]
import ../src/nifty/[parser, loader, checker, lowering]
import ../src/nifty/backend/[engine, irchecks]

var count = 0
for path in walkFiles("tests/scripts/*.nifty"):
  if path.extractFilename.startsWith("_"):
    continue
  let source = parse(loadTokens(readFile(path), path, path.parentDir))
  check(source)
  let plan = lowerNative(source, path)
  verifyIr(plan.module)
  doAssert plan.initialData.len == plan.globalBytes
  doAssert plan.threads.len > 0
  for target in [Arm64Target, Amd64Target]:
    let image = emitNative(plan.module, target)
    doAssert image.bytes.len > 0
    doAssert image.offsets.len == plan.module.functions.len
  inc count

doAssert count >= 40
echo "Native lowering fixtures passed: ", count

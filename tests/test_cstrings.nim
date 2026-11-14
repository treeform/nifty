## Checked C-string interoperability, native ABI metadata and C owner release.
import std/[os, osproc, strutils]
import ../src/nifty
import ../src/nifty/[checker, ctoolchains, loader, lowering, nativefiles,
  nativeunroll, parser, types]
import cstring_sources, fixtures

proc checked(source: string): types.Module =
  result = parse(loadTokens(source, "cstring.nifty", ""))
  check(result)

proc rejects(source, expected: string) =
  var message = ""
  try:
    discard checked(source)
  except NiftyError as error:
    message = error.msg
  doAssert expected in message, "Expected " & expected & "; got " & message

const Foreign = """
extern "libc":
  proc length "strlen"(text: cstring): int64
"""
const Owner = """
thread main() =
  let text: string[8] = "abc"
  let value = text.toCString()
"""

rejects(Foreign & """
thread main() =
  let text: string[8] = "abc"
  echo length(text)
""", "expected cstring, got string[8]")
rejects(Foreign & "thread main() =\n  echo length(\"a\\0b\")\n", "embedded NUL")
rejects("""
extern "libc":
  proc foreign(): cstring
thread main() =
  discard foreign()
""", "can only return")
rejects("""
extern "libc":
  proc foreign(text: var cstring)
thread main() =
  echo 1
""", "immutable borrowed inputs")
rejects(Foreign & Owner & "  echo length(value)\n", "got cstring?")
rejects(Foreign & Owner & "  if value.ok:\n    let copied = value\n    echo length(copied)\n", "cannot be copied")
rejects(Owner & "  discard value.clear()\n", "before proving")
rejects(Owner & "  if value.ok:\n    value.clear()\n", "exposes no methods")
rejects(Owner & "  if value.ok:\n    echo value.len\n", "got cstring")
rejects(Owner & "  if value.ok:\n    echo value[0]\n", "got cstring")
rejects(Owner & "  if value.ok:\n    echo value == value\n", "needs two ints")
rejects(Owner & "  discard value.or(value)\n", "cannot copy an owning value")
rejects("""
thread main() =
  let text: string[8] = "abc"
  discard text.toCString()
""", "must initialize a scoped local directly")
rejects("""
thread main() =
  let text: string[8] = "abc"
  echo text.toCString().ok
""", "must initialize a scoped local directly")
rejects("""
thread main() =
  var value: cstring
  discard value
""", "zero-initialized")
rejects("""
thread main() =
  let value: cstring = "literal"
  discard value
""", "string literals need")
rejects("""
proc escape(text: cstring): cstring =
  return text
thread main() =
  discard escape("literal")
""", "cannot be returned")
rejects("""
thread main() =
  var values: seq[cstring]
  discard values.resize(1)
""", "cannot be stored inside a container")
rejects("""
object Holder =
  value: cstring
thread main() =
  echo 1
""", "cannot be stored inside an object")

# Both machine backends and the persisted runtime metadata must preserve pointers.
for optimization in NativeOptimization:
  for target in NativeTarget:
    let ast = checked(CStringSource)
    let prepared = if optimization == SpeedOptimization: unrollNative(ast) else: ast
    let program = buildNativeProgram(lowerNative(prepared, "cstring"), target,
      optimization = optimization)
    let restored = decodeNative(encodeNative(program))
    doAssert restored.plan.hosts.len == program.plan.hosts.len
    doAssert restored.image.bytes == program.image.bytes

const Hooks = """
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
static int live, peak, attempts, fail_at;
static void check_exit(void) {
  assert(live == 0);
  assert(peak <= EXPECT_PEAK);
  assert(attempts == EXPECT_ATTEMPTS);
}
static void *tracked_realloc(void *p, size_t n) {
  assert(n > 0);
  ++attempts;
  if (attempts == fail_at) return NULL;
  void *out = realloc(p, n);
  if (out && !p) { ++live; if (live > peak) peak = live; }
  return out;
}
static void tracked_free(void *p) { if (p) { --live; assert(live >= 0); free(p); } }
#define NIFTY_REALLOC(p, n) tracked_realloc(p, n)
#define NIFTY_FREE(p) tracked_free(p)
"""
let work = getTempDir() / ("nifty_cstring_" & $getCurrentProcessId())
createDir(work)
for level in ["-O0", "-O2"]:
  for item in [(CStringSource, CStringExpected, 4, 4, 0),
      (CStringLiteralSource, "7\n0", 0, 0, 0),
      (CStringFailureSource, "false\ntrue\n5", 1, 2, 1),
      (CStringScopesSource, "5\n4\n4\n4\n5", 1, 5, 0)]:
    let path = work / "cstring.c"
    let binary = work / ("cstring" & ExeExt)
    let code = compileToC(item[0], "cstring.nifty")
      .replace("int main(void) {", "int main(void) { atexit(check_exit); fail_at = " & $item[4] & ";")
    writeFile(path, "#define EXPECT_PEAK " & $item[2] & "\n#define EXPECT_ATTEMPTS " & $item[3] & "\n" & Hooks & code)
    let build = execCmdEx(cCompileCommand(path, binary, options = @["-std=c99", level]))
    doAssert build.exitCode == 0, build.output
    let run = runFixture(binary)
    doAssert run.exitCode == 0, run.output
    doAssert run.output.replace("\r\n", "\n").strip() == item[1], run.output

echo "C-string semantic, C runtime and both native backend tests passed"

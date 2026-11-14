## Exercises deep C union copying and allocation-free destruction.
import std/[os, osproc, strutils]
import ../src/nifty
import ../src/nifty/[codegen, ctoolchains, types]

const Source = """
object Number =
  value: int
object Array =
  items: seq[Node]
type Node = Number or Array
thread main() =
  var node: Node
  node = Array()
"""

const Allocator = """
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
static int64_t attempts, live, fail_at;
static int deny;
static void *test_realloc(void *p, size_t n) {
  assert(!deny);
  ++attempts;
  if (fail_at && attempts == fail_at) return NULL;
  void *out = realloc(p, n);
  if (out && !p) ++live;
  return out;
}
static void test_free(void *p) {
  if (p) --live;
  free(p);
}
#define NIFTY_REALLOC test_realloc
#define NIFTY_FREE test_free
"""

const Harness = """
int main(void) {
  U_Node root = {0}, copy = {0};
  root.m_tag = ARRAY_TAG;
  U_Node *cursor = &root;
  for (int i = 0; i < 100000; ++i) {
    NS_dq_u_Node *items = &cursor->m_payload.m_Array.m_items;
    assert(NS_dq_u_Node_resize(items, 1));
    cursor = &items->m_data[0];
    cursor->m_tag = ARRAY_TAG;
  }
  int64_t baseline = live;
  for (int i = 1; i <= 16; ++i) {
    ni_init_u_Node(&copy);
    fail_at = attempts + i;
    assert(!ni_copy_u_Node(&copy, &root));
    fail_at = 0;
    assert(copy.m_tag == NUMBER_TAG);
    deny = 1;
    ni_drop_u_Node(&copy);
    deny = 0;
    assert(live == baseline);
  }
  assert(ni_copy_u_Node(&copy, &root));
  cursor = &copy;
  for (int i = 0; i < 100000; ++i) {
    assert(cursor->m_tag == ARRAY_TAG);
    assert(cursor->m_payload.m_Array.m_items.m_len == 1);
    cursor = &cursor->m_payload.m_Array.m_items.m_data[0];
  }
  deny = 1;
  ni_drop_u_Node(&root);
  ni_drop_u_Node(&copy);
  deny = 0;
  assert(live == 0);
  puts("Deep C union copy/drop passed");
  return 0;
}
"""

let checked = checkedModule(Source, "union-c-memory.nifty")
var arrayTag, numberTag: int64
for declaration in checked.types:
  if declaration.typ.name == "Array":
    arrayTag = declaration.typ.typeId
  if declaration.typ.name == "Number":
    numberTag = declaration.typ.typeId
let
  directory = getTempDir() / ("nifty-union-memory-" & $getCurrentProcessId())
  cPath = directory / "deep.c"
  binary = directory / ("deep" & ExeExt)
  generated = generate(checked, "union-c-memory.nifty").replace(
    "int main(void)", "int nifty_fixture_main(void)")
createDir(directory)
writeFile(cPath, Allocator & generated & Harness.replace(
  "ARRAY_TAG", $arrayTag & "ULL").replace("NUMBER_TAG", $numberTag & "ULL"))
var options = @["-O1", "-g"]
when not defined(windows):
  options.add @["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
let compilation = execCmdEx(cCompileCommand(cPath, binary, options = options))
doAssert compilation.exitCode == 0, compilation.output
let execution = execCmdEx(quoteShell(binary))
doAssert execution.exitCode == 0, execution.output
doAssert execution.output.strip() == "Deep C union copy/drop passed",
  execution.output
removeDir(directory)
echo "Deep C union memory and allocation failure checks passed"

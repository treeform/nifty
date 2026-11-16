## Flat JSON documents: independent values, IDs, growth, and failure cleanup.
import std/[json, os, osproc, strutils, tables, random]
import ../src/nifty
import ../src/nifty/[codegen, ctoolchains, types]

proc cString(value: string): string =
  result = "\""
  for ch in value: result.add "\\" & toOct(ord(ch), 3)
  result.add '"'

const Hooks = """
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { size_t bytes, pad; } TestHeader;
static int64_t live, attempts, fail_at, moved;
static void *test_realloc(void *p, size_t n) {
  ++attempts;
  if (fail_at && attempts == fail_at) return NULL;
  TestHeader *old = p ? (TestHeader *)p - 1 : NULL;
  TestHeader *h = malloc(sizeof(*h) + n);
  if (!h) return NULL;
  h->bytes = n;
  void *result = h + 1;
  if (old) {
    memcpy(result, p, old->bytes < n ? old->bytes : n);
    memset(p, 0xdd, old->bytes);
    free(old); ++moved;
  } else ++live;
  return result;
}
static void test_free(void *p) {
  if (p) { --live; free((TestHeader *)p - 1); }
}
#define NIFTY_REALLOC test_realloc
#define NIFTY_FREE test_free
"""

var valid = @[
  "null", "true", "false", "0", "-0", "1", "-12.5", "6.022e23", "1E-10",
  "  \t\r\n[ ] \n", "{}", "[]", "\"\"", "\"plain text\"",
  "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"",
  "\"\\u0000x\\u007f\\u0080\\u07ff\\u0800\\uffff\"",
  "\"\\ud834\\udd1e\"", "\"h\xc3\xa9llo \xf0\x9f\x98\x80\"",
  "[null,true,false,1,-2.5,\"x\",[],{}]",
  "{\"name\":\"nifty\",\"nested\":[{\"value\":42},null]}",
  "{\"\":\"\",\"\\u0000\":[{\"key\":\"\\u00e9\"},2]}",
  "\"" & repeat("x", 65536) & "\""
]
proc randomValue(rng: var Rand, depth: int): JsonNode =
  case rng.rand(if depth > 0: 5 else: 3)
  of 0: result = newJNull()
  of 1: result = newJBool(rng.rand(1) == 1)
  of 2: result = newJInt(rng.rand(200000) - 100000)
  of 3:
    let strings = ["", "a\0b", "quote\"slash\\", "\xc3\xa9\xf0\x9f\x98\x80"]
    result = newJString(strings[rng.rand(strings.high)])
  of 4:
    result = newJArray()
    for i in 0 ..< rng.rand(5): result.add randomValue(rng, depth - 1)
  else:
    result = newJObject()
    for i in 0 ..< rng.rand(5): result["key" & $i] = randomValue(rng, depth - 1)
var rng = initRand(619)
for i in 0 ..< 100: valid.add $randomValue(rng, 4)
let invalid = @[
  "", " \t\n", "x", "TRUE", "nul", "truefalse", "null x", "[]{}", "[", "{",
  "[1", "{\"x\":", "[1,]", "{\"x\":1,}", "[,1]", "[1 2]", "{x:1}",
  "{\"x\" 1}", "{\"x\":1 \"y\":2}", "+1", "01", "-01", "-", ".1", "1.",
  "1e", "1e+", "1e-", "NaN", "Infinity", "\"", "\"\\\"", "\"\\x20\"",
  "\"\\u12\"", "\"\\u12xz\"", "\"\\ud800\"", "\"\\udc00\"",
  "\"\\ud800\\u0041\"", "\"a\nb\"", "\"\x00\"", "\"\xc0\xaf\"",
  "\"\xed\xa0\x80\"", "\"\xf4\x90\x80\x80\"", "\"\xe2\x82\"",
  "\xef\xbb\xbfnull"
]
let root = currentSourcePath().parentDir.parentDir
let checked = checkedModule("import jsondoc\nthread main() =\n  echo 0\n",
  "json-document-test.nifty", root / "lib")
var harness = """
static void span(S_JsonDocument *doc, int64_t a, int64_t b,
                 const char *expected, size_t length) {
  assert(a >= 0 && b >= a && b <= doc->m_bytes.m_len);
  assert((uint64_t)(b-a) == length);
  if (length) assert(!memcmp(doc->m_bytes.m_data+a, expected, length));
}
static void input_bytes(NS_ds *text, const char *bytes, int64_t length) {
  assert(NS_ds_resize(text, length));
  if (length) memcpy(text->m_data, bytes, (size_t)length);
}
static void parse_ok(const char *bytes, int64_t length, S_JsonDocument *doc) {
  NS_ds text = {0}; S_JsonError error = {0};
  input_bytes(&text, bytes, length);
  assert(f_parseJsonDocument(&text, doc, &error));
  assert(error.m_code == 0 && doc->m_root == 0);
  ni_drop_ds(&text);
}
int main(void) {
"""
var nextId = 0
proc expect(value: JsonNode, name = "", named = false, numberText = "") =
  let id = nextId
  inc nextId
  let node = "doc.m_nodes.m_data[" & $id & "]"
  harness.add "assert(doc.m_nodes.m_len > " & $id & ");\n"
  if named:
    harness.add "span(&doc, " & node & ".m_nameOffset, " & node &
      ".m_nameLimit, " & cString(name) & ", " & $name.len & ");\n"
  else: harness.add "assert(" & node & ".m_nameOffset == 0);\n"
  case value.kind
  of JNull: harness.add "assert(" & node & ".m_kind == 0);\n"
  of JBool:
    harness.add "assert(" & node & ".m_kind == 1 && " & node &
      ".m_boolean == " & (if value.getBool(): "1" else: "0") & ");\n"
  of JInt, JFloat, JString:
    let text = if value.kind == JString: value.getStr()
      elif numberText.len > 0: numberText else: $value
    harness.add "assert(" & node & ".m_kind == " &
      (if value.kind == JString: "3" else: "2") & ");\n"
    harness.add "span(&doc, " & node & ".m_offset, " & node &
      ".m_limit, " & cString(text) & ", " & $text.len & ");\n"
  of JArray:
    harness.add "assert(" & node & ".m_kind == 4);\n"
    for child in value: expect(child)
  of JObject:
    harness.add "assert(" & node & ".m_kind == 5);\n"
    for key, child in value: expect(child, key, true)
  harness.add "assert(" & node & ".m_after == " & $nextId & ");\n"

for text in valid:
  harness.add "{ S_JsonDocument doc = {0}; parse_ok(" & cString(text) &
    ", " & $text.len & ", &doc);\n"
  nextId = 0
  expect(parseJson(text), numberText = text.strip())
  harness.add "assert(doc.m_nodes.m_len == " & $nextId & ");\n"
  harness.add "ni_drop_oJsonDocument(&doc); assert(live == 0); }\n"
for text in ["1e9999", "-1e-9999", "123456789012345678901234567890"]:
  harness.add "{ S_JsonDocument doc = {0}; parse_ok(" & cString(text) &
    ", " & $text.len & ", &doc);\n"
  nextId = 0
  expect(parseJson("0"), numberText = text)
  harness.add "ni_drop_oJsonDocument(&doc); assert(live == 0); }\n"
for text in invalid:
  harness.add "{ NS_ds text = {0}; input_bytes(&text, " & cString(text) &
    ", " & $text.len & "); S_JsonDocument doc = {0}; S_JsonError error = {0};\n"
  harness.add "assert(!f_parseJsonDocument(&text, &doc, &error));\n"
  harness.add "assert(error.m_code != 0 && error.m_offset >= 0 && error.m_offset <= text.m_len);\n"
  harness.add "assert(doc.m_root == -1 && !doc.m_nodes.m_len && !doc.m_bytes.m_len);\n"
  harness.add "ni_drop_oJsonDocument(&doc); ni_drop_ds(&text); assert(live == 0); }\n"
harness.add """
{
  S_JsonDocument doc = {0};
  parse_ok("{\"x\":1,\"x\":2}", 13, &doc);
  assert(doc.m_nodes.m_len == 3 && doc.m_nodes.m_data[0].m_after == 3);
  for (int i=1; i<=2; ++i) {
    S_JsonDocNode *node=&doc.m_nodes.m_data[i];
    span(&doc,node->m_nameOffset,node->m_nameLimit,"x",1);
    assert(doc.m_bytes.m_data[node->m_offset]=='0'+i);
  }
  ni_drop_oJsonDocument(&doc); assert(live == 0);
}
{
  NS_ds text = {0}; S_JsonDocument doc = {0}; S_JsonError error = {0};
  input_bytes(&text,"[[0]]",5);
  assert(!f_parseJsonDocumentWithDepth(&text,&doc,&error,1));
  assert(error.m_code==6 && doc.m_root==-1);
  assert(f_parseJsonDocumentWithDepth(&text,&doc,&error,2));
  assert(doc.m_nodes.m_len==3 && doc.m_nodes.m_data[0].m_after==3);
  assert(!f_parseJsonDocumentWithDepth(&text,&doc,&error,-1));
  input_bytes(&text,"null",4);
  assert(f_parseJsonDocumentWithDepth(&text,&doc,&error,0));
  input_bytes(&text,"[]",2);
  assert(!f_parseJsonDocumentWithDepth(&text,&doc,&error,0));
  assert(error.m_code==6 && doc.m_root==-1 && doc.m_bytes.m_len==0);
  ni_drop_oJsonDocument(&doc); ni_drop_ds(&text); assert(live==0);
}
{
  const int depth=512;
  char *bytes=malloc(depth*2+1);
  memset(bytes,'[',depth); bytes[depth]='0'; memset(bytes+depth+1,']',depth);
  S_JsonDocument doc={0}; parse_ok(bytes,depth*2+1,&doc);
  assert(doc.m_nodes.m_len==depth+1);
  for(int i=0;i<depth;++i) assert(doc.m_nodes.m_data[i].m_after==depth+1);
  assert(doc.m_nodes.m_data[depth].m_kind==2);
  ni_drop_oJsonDocument(&doc); free(bytes); assert(live==0);
}
{
  NS_ds text={0}; S_JsonDocument doc={0}; S_JsonError error={0};
  assert(NS_ds_resize(&text,1027)); memset(text.m_data,'[',513);
  text.m_data[513]='0'; memset(text.m_data+514,']',513);
  assert(!f_parseJsonDocument(&text,&doc,&error));
  assert(error.m_code==6 && doc.m_root==-1);
  ni_drop_oJsonDocument(&doc); ni_drop_ds(&text); assert(live==0);
}
{
  const char *bytes="{\"a\":[\"one\",{\"b\":[1,2,3]},true,null]}";
  NS_ds text={0}; input_bytes(&text,bytes,(int64_t)strlen(bytes));
  int64_t baseline=live, count=0;
  for(int64_t failure=1;failure<1000;++failure) {
    S_JsonDocument doc={0}; S_JsonError error={0};
    fail_at=attempts+failure;
    bool ok=f_parseJsonDocument(&text,&doc,&error);
    if(!ok) assert(error.m_code==5 && doc.m_root==-1 && !doc.m_nodes.m_len && !doc.m_bytes.m_len);
    fail_at=0; ni_drop_oJsonDocument(&doc); assert(live==baseline);
    if(ok){ count=failure; break; }
  }
  assert(count>1); ni_drop_ds(&text); assert(live==0 && moved>0);
}
puts("JSON document checks passed"); return 0;
}
"""
for declaration in checked.types:
  let original = checked.sourceNames.getOrDefault(declaration.typ.name)
  if original.len > 0:
    harness = harness.replace("S_" & original, "S_" & declaration.typ.name)
    harness = harness.replace("ni_drop_o" & original & "(",
      "ni_drop_o" & declaration.typ.name & "(")
for routine in checked.routines:
  if routine.sourceName in ["parseJsonDocument", "parseJsonDocumentWithDepth"]:
    harness = harness.replace("f_" & routine.sourceName & "(", "f_" & routine.name & "(")
let directory = getTempDir() / ("nifty-json-doc-" & $getCurrentProcessId())
createDir(directory)
try:
  let source = directory / "document.c"
  let binary = directory / (when defined(windows): "document.exe" else: "document")
  let generated = generate(checked, "json-document-test.nifty").replace(
    "int main(void)", "int nifty_fixture_main(void)")
  writeFile(source, Hooks & generated & harness)
  var options = @["-O1", "-g"]
  when not defined(windows):
    options.add @["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
  let build = execCmdEx(cCompileCommand(source, binary, options = options))
  doAssert build.exitCode == 0, build.output
  let execution = execCmdEx(quoteShell(binary))
  doAssert execution.exitCode == 0, execution.output
  doAssert execution.output.strip() == "JSON document checks passed", execution.output
finally:
  removeDir(directory)
echo "JSON document conformance, moving allocations and failure cleanup passed"

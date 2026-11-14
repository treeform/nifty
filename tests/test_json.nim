## Exercises the Nifty JSON parser through its generated C implementation.
import
  std/[json, os, osproc, strutils],
  ../src/nifty,
  ../src/nifty/[codegen, ctoolchains, types]

proc cString(value: string): string =
  ## Encodes arbitrary input bytes without C escape ambiguities.
  result = "\""
  for ch in value:
    result.add "\\" & toOct(ord(ch), 3)
  result.add '"'

const Hooks = """
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
static int64_t live, attempts, fail_at;
static void *test_realloc(void *p, size_t n) {
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

let valid = @[
  "null", "true", "false", "0", "-0", "1", "-12.5", "6.022e23",
  "1E-10", "  \t\r\n[ ] \n", "{}", "[]", "\"\"",
  "\"plain text\"", "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"",
  "\"\\u0000x\\u007f\\u0080\\u07ff\\u0800\\uffff\"",
  "\"\\ud834\\udd1e\"", "\"héllo 世界 😀\"",
  "[null,true,false,1,-2.5,\"x\",[],{}]",
  "{\"name\":\"nifty\",\"nested\":[{\"value\":42},null]}",
  "\"" & repeat("x", 65536) & "\""
]
let invalid = @[
  "", " \t\n", "x", "NullNode", "TRUE", "nul", "truefalse", "null x",
  "[]{}", "[", "{", "[1", "{\"x\":", "[1,]", "{\"x\":1,}",
  "[,1]", "[1 2]", "{x:1}", "{\"x\" 1}", "{\"x\":1 \"y\":2}",
  "+1", "01", "-01", "-", ".1", "1.", "1e", "1e+", "1e-",
  "NaN", "Infinity", "\"", "\"\\\"", "\"\\x20\"",
  "\"\\u12\"", "\"\\u12xz\"", "\"\\ud800\"", "\"\\udc00\"",
  "\"\\ud800\\u0041\"", "\"a\nb\"", "\"\x00\"",
  "\"\xc0\xaf\"", "\"\xed\xa0\x80\"", "\"\xf4\x90\x80\x80\"",
  "\"\xe2\x82\"", "\xef\xbb\xbfnull"
]

let
  directory = getTempDir() / ("nifty-json-" & $getCurrentProcessId())
  root = currentSourcePath().parentDir.parentDir
  checked = checkedModule("import json\nthread main() =\n  echo 0\n",
    "json-test.nifty", root / "lib")
var tags: array[6, int64]
for declaration in checked.types:
  for i, name in ["NumNode", "StrNode", "ArrNode", "ObjNode", "BoolNode", "NullNode"]:
    if declaration.typ.name == name:
      tags[i] = declaration.typ.typeId
var harness = """
static void parse_ok(const char *bytes, int64_t len, U_JsonNode *node) {
  NS_ds text = {0};
  assert(NS_ds_resize(&text, len));
  memcpy(text.m_data, bytes, (size_t)len);
  S_JsonError error = {0};
  assert(f_parseJson(&text, node, &error));
  ni_drop_ds(&text);
}
int main(void) {
"""

proc expect(value: JsonNode, path: string, numberText = "") =
  ## Emits independent tree checks against Nim's standard JSON parser.
  case value.kind
  of JNull:
    harness.add "assert(" & path & "->m_tag == " & $tags[5] & "ULL);\n"
  of JBool:
    harness.add "assert(" & path & "->m_tag == " & $tags[4] & "ULL);\n"
    harness.add "assert(" & path & "->m_payload.m_BoolNode.m_value == " &
      (if value.getBool(): "1" else: "0") & ");\n"
  of JInt, JFloat:
    harness.add "assert(" & path & "->m_tag == " & $tags[0] & "ULL);\n"
    let text = if numberText.len > 0: numberText else: $value
    let field = path & "->m_payload.m_NumNode.m_text"
    harness.add "assert(" & field & ".m_len == " & $text.len & ");\n"
    if text.len > 0:
      harness.add "assert(!memcmp(" & field & ".m_data, " &
        cString(text) & ", " & $text.len & "));\n"
  of JString:
    let text = value.getStr()
    harness.add "assert(" & path & "->m_tag == " & $tags[1] & "ULL);\n"
    let field = path & "->m_payload.m_StrNode.m_value"
    harness.add "assert(" & field & ".m_len == " & $text.len & ");\n"
    if text.len > 0:
      harness.add "assert(!memcmp(" & field & ".m_data, " &
        cString(text) & ", " & $text.len & "));\n"
  of JArray:
    harness.add "assert(" & path & "->m_tag == " & $tags[2] & "ULL);\n"
    let field = path & "->m_payload.m_ArrNode.m_items"
    harness.add "assert(" & field & ".m_len == " & $value.len & ");\n"
    for i in 0 ..< value.len:
      expect(value[i], "(&" & field & ".m_data[" & $i & "])")
  of JObject:
    harness.add "assert(" & path & "->m_tag == " & $tags[3] & "ULL);\n"
    let field = path & "->m_payload.m_ObjNode.m_fields"
    harness.add "assert(" & field & ".m_len == " & $value.len & ");\n"
    var i = 0
    for key, child in value:
      let entry = field & ".m_data[" & $i & "]"
      harness.add "assert(" & entry & ".m_name.m_len == " & $key.len & ");\n"
      if key.len > 0:
        harness.add "assert(!memcmp(" & entry & ".m_name.m_data, " &
          cString(key) & ", " & $key.len & "));\n"
      expect(child, "(&" & entry & ".m_value)")
      inc i

for text in valid:
  harness.add "{ U_JsonNode node = {0}; parse_ok(" & cString(text) &
    ", " & $text.len & ", &node);\n"
  expect(parseJson(text), "(&node)", text.strip())
  harness.add "ni_drop_u_JsonNode(&node); assert(live == 0); }\n"
for text in ["1e9999", "-1e-9999", "123456789012345678901234567890"]:
  harness.add "{ U_JsonNode node = {0}; parse_ok(" & cString(text) &
    ", " & $text.len & ", &node);\n"
  expect(parseJson("0"), "(&node)", text)
  harness.add "ni_drop_u_JsonNode(&node); assert(live == 0); }\n"
for text in invalid:
  harness.add "{ NS_ds text = {0}; assert(NS_ds_resize(&text, " &
    $text.len & ")); if (text.m_len) memcpy(text.m_data, " & cString(text) & ", " &
    $text.len & "); U_JsonNode node = {0}; S_JsonError error = {0};\n"
  harness.add "assert(!f_parseJson(&text, &node, &error));\n"
  harness.add "assert(error.m_code != 0); assert(error.m_offset >= 0 && " &
    "error.m_offset <= text.m_len); assert(node.m_tag == " &
    $tags[5] & "ULL);\n"
  harness.add "ni_drop_u_JsonNode(&node); ni_drop_ds(&text); " &
    "assert(live == 0); }\n"
harness.add """
{
  U_JsonNode node = {0};
  parse_ok("{\"x\":1,\"x\":2}", 13, &node);
  assert(node.m_tag == OBJECT_TAG);
  assert(node.m_payload.m_ObjNode.m_fields.m_len == 2);
  for (int i = 0; i < 2; ++i) {
    S_JsonField *field = &node.m_payload.m_ObjNode.m_fields.m_data[i];
    assert(field->m_name.m_len == 1 && field->m_name.m_data[0] == 'x');
    assert(field->m_value.m_tag == NUMBER_TAG);
    assert(field->m_value.m_payload.m_NumNode.m_text.m_data[0] == '1' + i);
  }
  ni_drop_u_JsonNode(&node);
  assert(live == 0);
}
{
  NS_ds text = {0};
  assert(NS_ds_resize(&text, 1027));
  memset(text.m_data, '[', 513);
  text.m_data[513] = '0';
  memset(text.m_data + 514, ']', 513);
  U_JsonNode node = {0};
  S_JsonError error = {0};
  assert(!f_parseJson(&text, &node, &error));
  assert(error.m_code == 6 && node.m_tag == NULL_TAG);
  ni_drop_u_JsonNode(&node);
  ni_drop_ds(&text);
  assert(live == 0);
}
""".replace("OBJECT_TAG", $tags[3] & "ULL").replace(
  "NUMBER_TAG", $tags[0] & "ULL").replace(
  "NULL_TAG", $tags[5] & "ULL")
harness.add """
{
  NS_ds text = {0};
  assert(NS_ds_resize(&text, 4));
  memcpy(text.m_data, "[[]]", 4);
  U_JsonNode node = {0};
  S_JsonError error = {0};
  assert(!f_parseJsonWithDepth(&text, &node, &error, 1));
  assert(error.m_code == 6 && node.m_tag == NULL_TAG);
  assert(f_parseJsonWithDepth(&text, &node, &error, 2));
  assert(error.m_code == 0);
  ni_drop_u_JsonNode(&node);
  ni_drop_ds(&text);
  assert(live == 0);
}
""".replace("NULL_TAG", $tags[5] & "ULL")
harness.add """
{
  NS_ds text = {0};
  assert(NS_ds_resize(&text, 4));
  memcpy(text.m_data, "null", 4);
  U_JsonNode node = {0};
  S_JsonError error = {0};
  assert(f_parseJsonWithDepth(&text, &node, &error, 0));
  assert(node.m_tag == NULL_TAG && error.m_code == 0);
  assert(!f_parseJsonWithDepth(&text, &node, &error, -1));
  assert(node.m_tag == NULL_TAG && error.m_code == 6);
  memcpy(text.m_data, "[  ]", 4);
  assert(!f_parseJsonWithDepth(&text, &node, &error, 0));
  assert(node.m_tag == NULL_TAG && error.m_code == 6);
  ni_drop_u_JsonNode(&node);
  ni_drop_ds(&text);
  assert(live == 0);
}
""".replace("NULL_TAG", $tags[5] & "ULL")
harness.add """
{
  NS_ds text = {0};
  assert(NS_ds_resize(&text, 1));
  text.m_data[0] = '?';
  int64_t baseline = live;
  U_JsonNode node = {0};
  parse_ok("[\"owned\",{\"child\":true}]", 24, &node);
  S_JsonError error = {0};
  assert(!f_parseJson(&text, &node, &error));
  assert(node.m_tag == NULL_TAG && error.m_code == 3);
  assert(error.m_offset == 0 && live == baseline);
  ni_drop_u_JsonNode(&node);
  ni_drop_ds(&text);
  assert(live == 0);
}
""".replace("NULL_TAG", $tags[5] & "ULL")
harness.add """
{
  const int depth = 128;
  char *bytes = malloc((size_t)(depth * 2 + 1));
  assert(bytes);
  memset(bytes, '[', (size_t)depth);
  bytes[depth] = '0';
  memset(bytes + depth + 1, ']', (size_t)depth);
  U_JsonNode node = {0};
  parse_ok(bytes, depth * 2 + 1, &node);
  U_JsonNode *cursor = &node;
  for (int i = 0; i < depth; ++i) {
    assert(cursor->m_tag == ARRAY_TAG);
    assert(cursor->m_payload.m_ArrNode.m_items.m_len == 1);
    cursor = &cursor->m_payload.m_ArrNode.m_items.m_data[0];
  }
  assert(cursor->m_tag == NUMBER_TAG);
  ni_drop_u_JsonNode(&node);
  free(bytes);
  assert(live == 0);
}
{
  const char *bytes = "{\"a\":[\"one\",{\"b\":[1,2,3]},true,null]}";
  NS_ds text = {0};
  int64_t len = (int64_t)strlen(bytes);
  assert(NS_ds_resize(&text, len));
  memcpy(text.m_data, bytes, (size_t)len);
  int64_t baseline = live, count = 0;
  for (int64_t failure = 1; failure < 1000; ++failure) {
    U_JsonNode node = {0};
    S_JsonError error = {0};
    fail_at = attempts + failure;
    bool ok = f_parseJson(&text, &node, &error);
    if (!ok) { assert(error.m_code == 5); assert(node.m_tag == NULL_TAG); }
    fail_at = 0;
    ni_drop_u_JsonNode(&node);
    assert(live == baseline);
    if (ok) { count = failure; break; }
  }
  assert(count > 1);
  ni_drop_ds(&text);
  assert(live == 0);
}
""".replace("ARRAY_TAG", $tags[2] & "ULL").replace(
  "NUMBER_TAG", $tags[0] & "ULL").replace(
  "NULL_TAG", $tags[5] & "ULL")
harness.add "puts(\"JSON parser checks passed\"); return 0; }\n"
createDir(directory)
try:
  let
    source = directory / "json.c"
    binary = directory / ("json" & ExeExt)
    generated = generate(checked, "json-test.nifty").replace(
      "int main(void)", "int nifty_fixture_main(void)")
  writeFile(source, Hooks & generated & harness)
  var options = @["-O1", "-g"]
  when not defined(windows):
    options.add @["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
  let build = execCmdEx(cCompileCommand(source, binary, options = options))
  doAssert build.exitCode == 0, build.output
  let execution = execCmdEx(quoteShell(binary))
  doAssert execution.exitCode == 0, execution.output
  doAssert execution.output.strip() == "JSON parser checks passed",
    execution.output
finally:
  removeDir(directory)
echo "JSON parser conformance and tree checks passed"

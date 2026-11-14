## Exercises generated Snappy allocation failures without a C codec fallback.
import
  std/[os, osproc, strutils, tables],
  ../src/nifty,
  ../src/nifty/[codegen, ctoolchains]

const Hooks = """
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static struct { unsigned char *p; size_t n; } blocks[128];
static int64_t live, attempts, fail_at, failures;
static void guards(void) {
  for (int i = 0; i < 128; ++i) if (blocks[i].p) {
    for (int j = 0; j < 16; ++j) {
      assert(blocks[i].p[j] == 0xa5);
      assert(blocks[i].p[16 + blocks[i].n + j] == 0x5a);
    }
  }
}
static int slot(void *p) {
  for (int i = 0; i < 128; ++i)
    if (blocks[i].p && blocks[i].p + 16 == p) return i;
  assert(!p);
  for (int i = 0; i < 128; ++i) if (!blocks[i].p) return i;
  abort();
}
static void *test_realloc(void *p, size_t n) {
  guards();
  ++attempts;
  if (fail_at && attempts == fail_at) return NULL;
  int i = slot(p);
  unsigned char *raw = malloc(n + 32);
  assert(raw);
  memset(raw, 0xa5, 16);
  memset(raw + 16 + n, 0x5a, 16);
  if (p) {
    memcpy(raw + 16, p, blocks[i].n < n ? blocks[i].n : n);
    free(blocks[i].p);
  } else ++live;
  blocks[i].p = raw;
  blocks[i].n = n;
  return raw + 16;
}
static void test_free(void *p) {
  guards();
  if (p) {
    int i = slot(p);
    free(blocks[i].p);
    blocks[i].p = NULL;
    blocks[i].n = 0;
    --live;
  }
}
#define NIFTY_REALLOC test_realloc
#define NIFTY_FREE test_free
"""

const Harness = """
static void seed(NS_ds *s, int64_t n) {
  assert(NS_ds_resize(s, n));
  for (int64_t i = 0; i < n; ++i)
    s->m_data[i] = (uint8_t)((i * 37 + i / 97) % 251);
}
static void reset_error(S_SnappyError *e) {
  e->m_code = 99;
  e->m_offset = 99;
}
static void success(S_SnappyError *e) {
  assert(e->m_code == 0 && e->m_offset == 0);
  assert(e->m_message.m_len == 0);
  guards();
}
static void sweep(NS_ds *input, int decompress, int existing) {
  int64_t baseline = live;
  int reached = 0;
  for (int64_t failure = 1; failure < 128; ++failure) {
    NS_ds output = {0};
    if (existing) seed(&output, 8);
    S_SnappyError error = {0};
    reset_error(&error);
    fail_at = attempts + failure;
    int ok = decompress ?
      f_uncompressSnappy(input, &output, 200000, &error) :
      f_compressSnappy(input, &output, &error);
    fail_at = 0;
    guards();
    if (!ok) {
      ++failures;
      assert(error.m_code == 2 && output.m_len == 0);
      assert(error.m_message.m_len > 0);
    } else {
      success(&error);
      reached = 1;
    }
    ni_drop_ds(&output);
    assert(live == baseline);
    if (ok) break;
  }
  assert(reached);
}
int main(void) {
  static _Alignas(16) uint8_t arena[65536];
  ni_sp = arena;
  NS_ds input = {0}, compressed = {0}, output = {0};
  S_SnappyError error = {0};
  seed(&input, 131073);
  sweep(&input, 0, 0);
  sweep(&input, 0, 1);
  reset_error(&error);
  assert(f_compressSnappy(&input, &compressed, &error));
  success(&error);
  sweep(&compressed, 1, 0);
  sweep(&compressed, 1, 1);
  seed(&output, 200000);
  uint8_t *storage = output.m_data;
  int64_t before = attempts;
  fail_at = attempts + 1;
  reset_error(&error);
  assert(f_uncompressSnappy(&compressed, &output, 200000, &error));
  success(&error);
  assert(output.m_data == storage && attempts == before);
  assert(output.m_len == input.m_len);
  assert(!memcmp(output.m_data, input.m_data, (size_t)input.m_len));
  reset_error(&error);
  assert(f_compressSnappy(&input, &output, &error));
  success(&error);
  assert(output.m_data == storage && attempts == before);
  assert(output.m_len == compressed.m_len);
  assert(!memcmp(output.m_data, compressed.m_data,
    (size_t)compressed.m_len));
  fail_at = 0;
  const uint8_t malformed[][5] = {
    {0x80}, {4, 0, 'a'}, {4, 1, 0}, {1, 0, 'a', 0},
    {2, 0, 'a', 0xf0, 0}
  };
  const int lengths[] = {1, 3, 3, 4, 5};
  for (int i = 0; i < 5; ++i) {
    NS_ds bad = {0};
    assert(NS_ds_resize(&bad, lengths[i]));
    memcpy(bad.m_data, malformed[i], (size_t)lengths[i]);
    seed(&output, 8);
    reset_error(&error);
    assert(!f_uncompressSnappy(&bad, &output, 200000, &error));
    assert(error.m_code == 1 && output.m_len == 0);
    assert(error.m_offset >= 0 && error.m_offset <= bad.m_len);
    assert(error.m_message.m_len > 0);
    guards();
    ni_drop_ds(&bad);
  }
  reset_error(&error);
  assert(!f_uncompressSnappy(&compressed, &output, 1, &error));
  assert(error.m_code == 3 && output.m_len == 0);
  reset_error(&error);
  assert(f_uncompressSnappy(&compressed, &output, 200000, &error));
  success(&error);
  ni_drop_ds(&output);
  ni_drop_ds(&compressed);
  ni_drop_ds(&input);
  assert(live == 0 && failures >= 4);
  printf("Snappy allocation checks passed (%lld injected failures)\n",
    (long long)failures);
  return 0;
}
"""

let
  directory = getTempDir() / ("nifty-snappy-" & $getCurrentProcessId())
  root = currentSourcePath().parentDir.parentDir
  checked = checkedModule("import snappy\nthread main() =\n" &
    "  var output: string\n  var error: SnappyError\n" &
    "  echo compressSnappy(\"fixture\", output, error)\n",
    "snappy-test.nifty", root / "lib")
var
  harness = Harness
  typesFound = 0
  routinesFound = 0
for declaration in checked.types:
  if checked.sourceNames.getOrDefault(declaration.typ.name) == "SnappyError":
    harness = harness.replace("S_SnappyError", "S_" & declaration.typ.name)
    inc typesFound
for routine in checked.routines:
  if routine.sourceName in ["compressSnappy", "uncompressSnappy"]:
    harness = harness.replace("f_" & routine.sourceName & "(",
      "f_" & routine.name & "(")
    inc routinesFound
doAssert typesFound == 1 and routinesFound == 2
createDir(directory)
try:
  let
    source = directory / "snappy.c"
    binary = directory / ("snappy" & ExeExt)
    generated = generate(checked, "snappy-test.nifty").replace(
      "int main(void)", "int nifty_fixture_main(void)")
  writeFile(source, Hooks & generated & harness)
  var options = @["-O1", "-g"]
  when not defined(windows):
    options.add @["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
  let build = execCmdEx(cCompileCommand(source, binary, options = options))
  doAssert build.exitCode == 0, build.output
  let execution = execCmdEx(quoteShell(binary))
  doAssert execution.exitCode == 0, execution.output
  doAssert execution.output.startsWith("Snappy allocation checks passed"),
    execution.output
  echo execution.output.strip()
finally:
  removeDir(directory)

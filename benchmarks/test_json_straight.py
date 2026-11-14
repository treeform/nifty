#!/usr/bin/env python3
"""Compile and check the standalone C DOM, without a Nifty toolchain."""

import argparse
import json
import os
from pathlib import Path
import random
import platform
import re
import shutil
import subprocess
import tempfile

import run_json as oracle


def checksum(data):
  """Parse independently while preserving numbers and duplicate object keys."""
  return oracle.digest(json.loads(data, parse_int=oracle.Number,
                                 parse_float=oracle.Number,
                                 object_pairs_hook=oracle.Object))


def cases():
  """Cover grammar, decoded Unicode, exact numbers, and varied tree shapes."""
  valid = [b'null', b'true', b'false', b'0', b'-0', b'1.00e+999999',
           b'900719925474099312345678901234567890', b'-1E-999999',
           b'""', b'[]', b'{}', b' \r\n\t [null,true,false] \n',
           br'"\"\\\/\b\f\n\r\t"', br'"a\u0000b"',
           br'"\uD800\uDC00\uDBFF\uDFFF"',
           br'{"a":1,"a":2,"\u0000":"\u0000"}',
           '"\u007f\u0080\u07ff\u0800\uffff\U00010000\U0010ffff"'.encode(),
           oracle.RecordText.encode(), b'[' + b'0,' * 199 + b'0]',
           b'{' + b','.join(b'"k%d":[]' % i for i in range(80)) + b'}',
           b'[' * 64 + b'0' + b']' * 64,
           b'[' * 512 + b'0' + b']' * 512, b'1' + b'0' * 4096]
  generator = random.Random(3927)

  def value(depth):
    """Generate bounded mixed trees with deterministic UTF-8 strings."""
    if depth and generator.randrange(3) == 0:
      return [value(depth - 1) for _ in range(generator.randrange(6))]
    if depth and generator.randrange(3) == 0:
      return {str(i): value(depth - 1) for i in range(generator.randrange(6))}
    return generator.choice([None, True, False, generator.randrange(-10**25, 10**25),
                             '', 'a\x00é😃\\\n', 1.25])

  for _ in range(100):
    valid.append(json.dumps(value(4), ensure_ascii=False).encode())
  invalid = [b'', b' ', b'NULL', b'True', b'undefined', b'NaN', b'Infinity',
             b'+1', b'01', b'-01', b'1.', b'.1', b'1e', b'1e+', b'--1',
             b'0x1', b'null null', b'true0', b'[]x', b'\xef\xbb\xbfnull',
             b'[', b'{', b'[1,]', b'[,1]', b'[1 2]', b'{"x"}',
             b'{x:1}', b'{"x":}', b'{"x":1,}', b'{"x":1 "y":2}',
             b'/*x*/null', b'null\x00', b'\x0bnull', b'\x0cnull',
             b'"', b'"a\x00b"', b'"\n"', br'"\x20"', br'"\u123"',
             br'"\uGGGG"', br'"\uD800"', br'"\uDC00"',
             br'"\uD800\u0041"', br'"\uD800\uD800"',
             b'"\x80"', b'"\xc0\x80"', b'"\xc1\xbf"', b'"\xc2"',
             b'"\xe0\x80\x80"', b'"\xed\xa0\x80"',
             b'"\xf0\x80\x80\x80"', b'"\xf4\x90\x80\x80"',
             b'"\xf5\x80\x80\x80"', b'"\xff"',
             b'[' * 513 + b'0' + b']' * 513,
             b'[' * 2048 + b'0' + b']' * 2048]
  invalid += [b'"' + bytes([byte]) + b'"' for byte in range(32)]
  fixture = oracle.RecordText.encode()
  invalid += [fixture[:length] for length in range(1, len(fixture))]
  return [(f'valid-{i}', data, checksum(data)) for i, data in enumerate(valid)] + [
    (f'invalid-{i}', data, None) for i, data in enumerate(invalid)]


Harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef JSON_HAND_ASM
#include <sys/mman.h>
#include <unistd.h>
#endif
static size_t attempts, failAt, live;
#ifdef JSON_HAND_ASM
typedef union {
  max_align_t alignment;
  struct { size_t size; unsigned char guard[32]; } value;
} Allocation;
static void verifyAllocation(Allocation *header) {
  unsigned char *tail = (unsigned char *)(header + 1) + header->value.size;
  for (size_t i = 0; i < 32; ++i) {
    assert(header->value.guard[i] == 0x6d && tail[i] == 0xb7);
  }
}
#endif
static void *trackedMalloc(size_t size) {
  if (++attempts == failAt) return NULL;
#ifdef JSON_HAND_ASM
  Allocation *header = malloc(sizeof(*header) + size + 32);
  if (!header) return NULL;
  header->value.size = size;
  memset(header->value.guard, 0x6d, 32);
  void *result = header + 1;
  memset((unsigned char *)result + size, 0xb7, 32);
#else
  void *result = malloc(size);
#endif
  if (result) ++live;
  return result;
}
static void *trackedRealloc(void *old, size_t size) {
  if (++attempts == failAt) return NULL;
#ifdef JSON_HAND_ASM
  /* Force every successful growth to move, exposing stale child pointers. */
  Allocation *header = old ? (Allocation *)old - 1 : NULL;
  if (header) verifyAllocation(header);
  size_t savedAttempts = attempts;
  size_t savedFailure = failAt;
  failAt = 0;
  void *result = trackedMalloc(size);
  failAt = savedFailure;
  attempts = savedAttempts;
  if (result && header) {
    memcpy(result, old, header->value.size < size ? header->value.size : size);
    memset(old, 0xdd, header->value.size);
    free(header);
    --live;
  }
  /* trackedMalloc already counted this allocation. */
  if (result && !old) --live;
#else
  void *result = realloc(old, size);
#endif
  assert(size != 0);
  if (result && !old) ++live;
  return result;
}
static void trackedFree(void *value) {
  if (value) {
    assert(live);
    --live;
#ifdef JSON_HAND_ASM
    Allocation *header = (Allocation *)value - 1;
    verifyAllocation(header);
    memset(value, 0xdd, header->value.size);
    free(header);
#else
    free(value);
#endif
  }
}
#ifdef JSON_HAND_ASM
/* External names allow assembly allocations to share fault accounting. */
void *jsonAsmTestMalloc(size_t size) { return trackedMalloc(size); }
void *jsonAsmTestRealloc(void *old, size_t size) {
  return trackedRealloc(old, size);
}
void jsonAsmTestFree(void *value) { trackedFree(value); }
#endif
#define JSON_MALLOC trackedMalloc
#define JSON_REALLOC trackedRealloc
#define JSON_FREE trackedFree
#define JSON_STRAIGHT_NO_MAIN
#include "json_parser_straight.c"
struct Case {const unsigned char *data; size_t size; int valid; uint64_t digest;};
CASES
static size_t failureChecks;
static void check(struct Case test, size_t index) {
  JsonNode node = {0};
  JsonError error = {0};
  unsigned char *input = malloc(test.size ? test.size : 1);
  assert(input);
  memcpy(input, test.data, test.size);
  attempts = 0;
  failAt = 0;
  int result = jsonParse(input, test.size, &node, &error);
  size_t allocations = attempts;
  if (result != test.valid) {
    fprintf(stderr, "case %zu: expected %d, got %d at %zu: %s\n",
      index, test.valid, result, error.offset, error.message ? error.message : "");
    abort();
  }
  memset(input, 0xa5, test.size);
  free(input);
  if (result) assert(jsonDigest(&node) == test.digest);
  else { assert(node.kind == JsonNull); assert(error.message); assert(error.offset <= test.size); }
#ifdef JSON_HAND_ASM
  /* Assembly accesses are not instrumented by ASan: protect both input ends. */
  size_t page = (size_t)sysconf(_SC_PAGESIZE);
  size_t span = ((test.size + page - 1) / page + 1) * page;
  unsigned char *mapping = mmap(NULL, span + 2 * page,
    PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  assert(mapping != MAP_FAILED);
  assert(!mprotect(mapping, page, PROT_NONE));
  assert(!mprotect(mapping + page + span, page, PROT_NONE));
  for (int side = 0; side < 2; ++side) {
    unsigned char *bounded = side ? mapping + page + span - test.size
                                  : mapping + page;
    memcpy(bounded, test.data, test.size);
    JsonNode guarded = {0};
    JsonError guardedError = {0};
    assert(jsonParse(bounded, test.size, &guarded, &guardedError) == test.valid);
    if (test.valid) assert(jsonDigest(&guarded) == test.digest);
    jsonDrop(&guarded);
  }
  assert(!munmap(mapping, span + 2 * page));
#endif
  jsonDrop(&node);
  jsonDrop(&node);
  assert(node.kind == JsonNull && live == 0);
  /* Every allocation can fail, including growth with existing children. */
  for (size_t failure = 1; failure <= allocations; ++failure) {
    attempts = 0;
    failAt = failure;
    assert(!jsonParse(test.data, test.size, &node, &error));
    assert(node.kind == JsonNull && error.message);
    assert(error.offset <= test.size);
    jsonDrop(&node);
    assert(live == 0);
    ++failureChecks;
  }
  failAt = 0;
}
int main(void) {
  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) check(cases[i], i);
  JsonNode node = {0};
  JsonError error = {0};
  const unsigned char owned[] = "{\"a\":[\"owned\",1,{}]}";
  assert(jsonParse(owned, sizeof(owned)-1, &node, &error));
  assert(jsonParse((const unsigned char *)"true", 4, &node, &error));
  assert(node.kind == JsonBool && node.as.boolean);
  assert(jsonParse(owned, sizeof(owned)-1, &node, &error));
  assert(!jsonParse((const unsigned char *)"[", 1, &node, &error));
  assert(node.kind == JsonNull && live == 0);
  for (size_t failure = 1; failure <= 3; ++failure) {
    failAt = 0;
    assert(jsonParse(owned, sizeof(owned)-1, &node, &error));
    attempts = 0;
    failAt = failure;
    assert(!jsonParse(owned, sizeof(owned)-1, &node, &error));
    assert(node.kind == JsonNull && live == 0);
  }
  failAt = 0;
  jsonDrop(&node);
  assert(live == 0);
  printf("%zu cases; %zu allocation failure checks passed\n",
    sizeof(cases) / sizeof(cases[0]), failureChecks);
  return 0;
}
'''


def main():
  """Build once, run under supported sanitizers, and optionally check a corpus."""
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('--suite', type=Path,
                      help='Optional JSONTestSuite test_parsing directory')
  parser.add_argument('--assembly', type=Path,
                      help='macOS ARM64 assembly implementation to test')
  options = parser.parse_args()
  if options.assembly and (platform.system() != 'Darwin' or
                           platform.machine() != 'arm64'):
    print('SKIP: assembly tests require macOS ARM64')
    return
  tests = cases()
  if options.suite:
    paths = sorted(options.suite.glob('*.json'))
    if not paths:
      parser.error('--suite contains no JSON files')
    for path in paths:
      data = path.read_bytes()
      if path.name.startswith('y_'):
        tests.append((path.name, data, checksum(data)))
      elif path.name.startswith('n_'):
        tests.append((path.name, data, None))
  rows = []
  for name, data, expected in tests:
    encoded = ','.join(str(byte) for byte in data) or '0'
    rows.append(f'{{(const unsigned char[]){{{encoded}}}, {len(data)}, '
                f'{int(expected is not None)}, {expected or 0}}}, /* {name} */')
  source = Harness.replace('CASES', 'static struct Case cases[] = {\n' +
                           '\n'.join(rows) + '\n};')
  compiler = [os.environ['CC']] if os.environ.get('CC') else []
  if not compiler:
    compiler = [next((path for name in ('cc', 'clang', 'gcc')
                      if (path := shutil.which(name))), '')]
  if not compiler[0]:
    raise RuntimeError('A C compiler is required (set CC)')
  with tempfile.TemporaryDirectory(prefix='json-straight-') as temporary:
    directory = Path(temporary)
    harness = directory / 'harness.c'
    harness.write_text(source, encoding='utf-8')
    executable = directory / ('harness.exe' if os.name == 'nt' else 'harness')
    command = compiler + ['-std=c11', '-O1', '-g', '-Wall', '-Wextra',
                          '-I', str(Path(__file__).resolve().parent),
                          str(harness), '-o', str(executable)]
    if options.assembly:
      # Rewrite only external allocator branch operands in a temporary copy.
      assembly = directory / 'implementation.s'
      contents = options.assembly.read_text(encoding='utf-8')
      contents = re.sub(r'(?m)(\b(?:bl|b)\s+)_malloc\b',
                        r'\1_jsonAsmTestMalloc', contents)
      contents = re.sub(r'(?m)(\b(?:bl|b)\s+)_realloc\b',
                        r'\1_jsonAsmTestRealloc', contents)
      contents = re.sub(r'(?m)(\b(?:bl|b)\s+)_free\b',
                        r'\1_jsonAsmTestFree', contents)
      assembly.write_text(contents, encoding='utf-8')
      object_path = directory / 'implementation.o'
      subprocess.run(compiler + ['-c', str(assembly), '-o', str(object_path)],
                     check=True, timeout=60)
      command += ['-DJSON_HAND_ASM', '-D_DARWIN_C_SOURCE', str(object_path)]
    sanitizers = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    if os.name != 'nt':
      probe = directory / 'probe.c'
      probe.write_text('int main(void) { return 0; }\n')
      supported = subprocess.run(compiler + sanitizers + [str(probe), '-o',
                                 str(directory / 'probe')], capture_output=True,
                                 timeout=60).returncode == 0
      if supported:
        command += sanitizers
    else:
      supported = False
    subprocess.run(command, check=True, timeout=60)
    result = subprocess.run([str(executable)], capture_output=True,
                            text=True, timeout=60)
    if result.returncode or result.stderr:
      raise AssertionError(f'harness exited {result.returncode}:\n' +
                           result.stdout + result.stderr)
    print(result.stdout.strip())
    print('Address/undefined sanitizers: ' + ('enabled' if supported else 'unavailable'))


if __name__ == '__main__':
  main()

#!/usr/bin/env python3
"""Differential, guard-page and moving-allocation checks for macOS ARM64 JSON.

The assembly defaults to the checked-in handwritten implementation. Extra CLI
arguments (including --suite) are forwarded to test_json_straight.
"""

import json
from pathlib import Path
import sys

import test_json_straight as straight


Reference = r'''
#undef JSON_HAND_ASM
#define jsonParse referenceParse
#define jsonDigest referenceDigest
#define jsonDrop referenceDrop
#include "json_parser_straight.c"
#undef jsonParse
#undef jsonDigest
#undef jsonDrop
#define JSON_HAND_ASM
extern bool jsonParse(const unsigned char *, size_t, JsonNode *, JsonError *);
extern uint64_t jsonDigest(const JsonNode *);
extern void jsonDrop(JsonNode *);
'''

def abi_probe():
  """Build a test-only trampoline checking Darwin ARM64 preserved registers."""
  lines = ['.text', '.p2align 2', '_jsonAbiProbe:',
           'sub sp, sp, #176', 'stp x29, x30, [sp, #160]']
  for i in range(5):
    lines.append(f'stp x{19 + 2*i}, x{20 + 2*i}, [sp, #{16*i}]')
  for i in range(4):
    lines.append(f'stp d{8 + 2*i}, d{9 + 2*i}, [sp, #{80 + 16*i}]')
  lines += ['mov x29, sp', 'mov x16, x0', 'mov x0, x1',
            'mov x1, x2', 'mov x2, x3', 'mov x3, x4']
  for i in range(19, 29):
    lines.append(f'mov x{i}, #{i * 137}')
  for i in range(8, 16):
    lines += [f'mov x9, #{i * 251}', f'fmov d{i}, x9']
  lines += ['blr x16', 'mov x0, #0', 'mov x9, sp', 'cmp x9, x29',
            'b.ne Labi_failure']
  for i in range(19, 29):
    lines += [f'cmp x{i}, #{i * 137}', 'b.ne Labi_failure']
  for i in range(8, 16):
    lines += [f'fmov x9, d{i}', f'cmp x9, #{i * 251}',
              'b.ne Labi_failure']
  lines += ['b Labi_restore', 'Labi_failure:', 'mov x0, #1', 'Labi_restore:']
  for i in range(5):
    lines.append(f'ldp x{19 + 2*i}, x{20 + 2*i}, [sp, #{16*i}]')
  for i in range(4):
    lines.append(f'ldp d{8 + 2*i}, d{9 + 2*i}, [sp, #{80 + 16*i}]')
  lines += ['ldp x29, x30, [sp, #160]', 'add sp, sp, #176', 'ret']
  return ('extern int jsonAbiProbe(void (*)(void), uintptr_t, uintptr_t, '
          'uintptr_t, uintptr_t);\n__asm__(' +
          json.dumps('\n'.join(lines) + '\n') + ');\n')


Differential = r'''
  /* Check integer, SIMD low halves, frame pointer, and stack restoration. */
  JsonNode abiNode = {0};
  JsonError abiError = {0};
  const unsigned char abiText[] = "{\"key\":[true,123,\"escaped\\n\"]}";
  assert(!jsonAbiProbe((void (*)(void))jsonParse, (uintptr_t)abiText,
    sizeof(abiText) - 1, (uintptr_t)&abiNode, (uintptr_t)&abiError));
  assert(abiNode.kind == JsonObject);
  assert(!jsonAbiProbe((void (*)(void))jsonDigest, (uintptr_t)&abiNode, 0, 0, 0));
  assert(!jsonAbiProbe((void (*)(void))jsonDrop, (uintptr_t)&abiNode, 0, 0, 0));
  assert(!jsonAbiProbe((void (*)(void))jsonParse, (uintptr_t)"[",
    1, (uintptr_t)&abiNode, (uintptr_t)&abiError));
  assert(abiNode.kind == JsonNull && abiError.message);
  assert(!jsonAbiProbe((void (*)(void))jsonDigest, (uintptr_t)&abiNode, 0, 0, 0));
  assert(!jsonAbiProbe((void (*)(void))jsonDrop, (uintptr_t)&abiNode, 0, 0, 0));
  assert(live == 0);
  puts("ARM64 callee-saved integer/SIMD registers and stack checks passed");
  /* Deterministic bytes cover truncated UTF-8 and escaped-string errors. */
  unsigned state = 17;
  size_t page = (size_t)sysconf(_SC_PAGESIZE);
  unsigned char *mapping = mmap(NULL, 3 * page, PROT_READ | PROT_WRITE,
    MAP_PRIVATE | MAP_ANON, -1, 0);
  assert(mapping != MAP_FAILED);
  assert(!mprotect(mapping, page, PROT_NONE));
  assert(!mprotect(mapping + 2 * page, page, PROT_NONE));
  for (size_t trial = 0; trial < 100000; ++trial) {
    state = state * 1664525u + 1013904223u;
    size_t size = state % 1024;
    unsigned char *data = trial & 1 ? mapping + page : mapping + 2 * page - size;
    for (size_t i = 0; i < size; ++i) {
      state = state * 1664525u + 1013904223u;
      data[i] = trial % 3 == 0 ? 32 + state % 96 : state >> 24;
    }
    if (size && trial % 4) {
      data[0] = '"';
      if (trial % 2) data[size - 1] = '"';
    }
    JsonNode reference = {0}, candidate = {0};
    JsonError expected = {0}, actual = {0};
    int valid = referenceParse(data, size, &reference, &expected);
    assert(jsonParse(data, size, &candidate, &actual) == valid);
    if (valid) {
      assert(referenceDigest(&reference) == referenceDigest(&candidate));
      assert(jsonDigest(&candidate) == referenceDigest(&reference));
    } else {
      assert(expected.offset == actual.offset);
      assert(!strcmp(expected.message, actual.message));
    }
    referenceDrop(&reference);
    jsonDrop(&candidate);
    assert(live == 0);
  }
  assert(!munmap(mapping, 3 * page));
  puts("100000 differential random parses and error offsets passed");
'''


def main():
  """Reuse the allocation-failure corpus and add an independent C oracle."""
  if '--assembly' not in sys.argv:
    sys.argv += ['--assembly', str(Path(__file__).resolve().parent /
                                  'arm64/json_parser_hand.S')]
  straight.Harness = straight.Harness.replace(
    '#include "json_parser_straight.c"', Reference + abi_probe()).replace(
      'int main(void) {', 'int main(void) {\n' + Differential)
  straight.main()


if __name__ == '__main__':
  main()

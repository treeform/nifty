#!/usr/bin/env python3
"""Conformance and memory boundaries for the standalone Snappy implementations."""
import argparse
import os
from pathlib import Path
import platform
import random
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile

Root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Root / 'tests'))
from snappy_reference import decode, literal, literalBlock, varint
from test_snappy import cases, inputs, prepareInterop

Harness = r'''
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#if defined(GUARDS)
#include <sys/mman.h>
#include <unistd.h>
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif
static void *outputMap;
static size_t outputMapSize, outputSize;
static unsigned char *outputPointer;
static int edge;
static void *guarded(size_t n, void **map, size_t *mapSize) {
  size_t page = (size_t)sysconf(_SC_PAGESIZE);
  size_t usable = ((n ? n : 1) + page - 1) / page * page;
  *mapSize = usable + 2 * page;
  *map = mmap(NULL, *mapSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (*map == MAP_FAILED) abort();
  unsigned char *start = (unsigned char *)*map + page;
  if (mprotect(start, usable, PROT_READ | PROT_WRITE)) abort();
  memset(start, 0xa5, usable);
  return edge ? start + usable - n : start;
}
#endif
static int failAllocation;
static void *testRealloc(void *p, size_t n) {
  if (failAllocation) return NULL;
#if defined(GUARDS)
  void *map; size_t mapSize;
  unsigned char *q = guarded(n, &map, &mapSize);
  if (p) {
    if (p != outputPointer) abort();
    memcpy(q, p, outputSize < n ? outputSize : n);
    munmap(outputMap, outputMapSize);
  }
  outputPointer = q; outputSize = n;
  outputMap = map; outputMapSize = mapSize;
  return q;
#else
  return realloc(p, n);
#endif
}
#if defined(GUARDS)
void *snappyTestRealloc(void *p, size_t n) { return testRealloc(p, n); }
#endif
#define SNAPPY_REALLOC testRealloc
#define SNAPPY_NO_MAIN
#include "snappy_straight.c"
#if defined(GUARDS)
_Static_assert(sizeof(SnappyBuffer) == 24, "Buffer ABI size");
_Static_assert(offsetof(SnappyBuffer, len) == 8, "Buffer ABI len");
_Static_assert(offsetof(SnappyBuffer, cap) == 16, "Buffer ABI cap");
extern int checkedCompress(const uint8_t *, size_t, SnappyBuffer *);
extern int checkedUncompress(const uint8_t *, size_t, SnappyBuffer *, size_t);
#define snappyCompress checkedCompress
#define snappyUncompress checkedUncompress
#endif
static uint32_t read32(FILE *f) {
  unsigned char b[4];
  if (fread(b, 1, 4, f) != 4) abort();
  return (uint32_t)b[0] | (uint32_t)b[1]<<8 |
    (uint32_t)b[2]<<16 | (uint32_t)b[3]<<24;
}
static void write32(FILE *f, uint32_t n) {
  unsigned char b[4] = {n, n>>8, n>>16, n>>24};
  if (fwrite(b, 1, 4, f) != 4) abort();
}
int main(int argc, char **argv) {
  if (argc != 3) return 90;
  FILE *in = fopen(argv[1], "rb"), *out = fopen(argv[2], "wb");
  if (!in || !out) return 91;
  uint32_t count = read32(in);
  for (uint32_t i = 0; i < count; ++i) {
    uint32_t op = read32(in), n = read32(in), limit = read32(in);
    uint32_t fail = read32(in), side = read32(in);
    unsigned char *source;
#if defined(GUARDS)
    edge = side;
    void *sourceMap; size_t sourceMapSize;
    source = guarded(n, &sourceMap, &sourceMapSize);
#else
    (void)side;
    source = malloc(n ? n : 1);
#endif
    if (!source || fread(source, 1, n, in) != n) abort();
    unsigned char *original = malloc(n ? n : 1);
    if (!original) abort();
    memcpy(original, source, n);
#if defined(GUARDS)
    size_t sourcePage = (size_t)sysconf(_SC_PAGESIZE);
    if (mprotect((unsigned char *)sourceMap + sourcePage,
                 sourceMapSize - 2 * sourcePage, PROT_READ)) abort();
#endif
    SnappyBuffer b = {0};
    /* A stale length must be cleared even on failures before allocation. */
    b.len = 123;
    failAllocation = fail;
    int status = op ? snappyCompress(source, n, &b) :
      snappyUncompress(source, n, &b, limit);
    failAllocation = 0;
    if (memcmp(original, source, n)) abort();
    free(original);
    if (b.len > b.cap || (status && b.len)) abort();
    write32(out, status); write32(out, (uint32_t)b.len);
    if (b.len && fwrite(b.data, 1, b.len, out) != b.len) abort();
#if defined(GUARDS)
    /* Check the writable slack at the opposite edge as well as guard pages. */
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    if (outputMap) {
      unsigned char *start = (unsigned char *)outputMap + page;
      unsigned char *end = (unsigned char *)outputMap + outputMapSize - page;
      for (unsigned char *p = start; p < outputPointer; ++p)
        if (*p != 0xa5) abort();
      for (unsigned char *p = outputPointer + outputSize; p < end; ++p)
        if (*p != 0xa5) abort();
      munmap(outputMap, outputMapSize);
      outputMap = NULL; outputPointer = NULL; outputSize = 0;
    }
    munmap(sourceMap, sourceMapSize);
#else
    free(source); free(b.data);
#endif
  }
  /* Retained allocations must work without realloc, and survive failed growth. */
  unsigned char small[] = {1, 2, 3}, large[4096];
  memset(large, 42, sizeof(large));
  SnappyBuffer reuse = {0};
  if (snappyCompress(small, sizeof(small), &reuse)) abort();
  unsigned char *retained = reuse.data;
  size_t capacity = reuse.cap;
  failAllocation = 1;
  if (snappyCompress(small, sizeof(small), &reuse)) abort();
  if (reuse.data != retained || reuse.cap != capacity) abort();
  if (snappyCompress(large, sizeof(large), &reuse) != 2) abort();
  if (reuse.data != retained || reuse.cap != capacity || reuse.len) abort();
  /* The failed growth must leave the retained bytes usable for decoding. */
  unsigned char encoded[] = {3, 8, 1, 2, 3};
  if (snappyUncompress(encoded, sizeof(encoded), &reuse, 3)) abort();
  if (reuse.len != 3 || memcmp(reuse.data, small, 3)) abort();
  failAllocation = 0;
#if defined(GUARDS)
  munmap(outputMap, outputMapSize);
#else
  free(reuse.data);
#endif
  if (fgetc(in) != EOF || fclose(out)) abort();
  fclose(in);
  return 0;
}
'''


def run(command, **kwargs):
  """Report subprocess diagnostics without losing sanitizer failures."""
  result = subprocess.run([str(x) for x in command], capture_output=True,
                          timeout=300, **kwargs)
  assert result.returncode == 0, (command, result.returncode,
      result.stdout.decode(errors='replace'), result.stderr.decode(errors='replace'))
  assert not result.stderr, result.stderr.decode(errors='replace')
  return result


def execute(executable, directory, vectors):
  """Run the complete corpus in one process through a binary file protocol."""
  payload = bytearray(struct.pack('<I', len(vectors)))
  for op, data, limit, fail, side, expected, label in vectors:
    payload.extend(struct.pack('<IIIII', op, len(data), limit, fail, side))
    payload.extend(data)
  source, target = directory / 'input', directory / 'output'
  source.write_bytes(payload)
  run([executable, source, target])
  response = target.read_bytes()
  cursor, compressed = 0, []
  for op, data, limit, fail, side, expected, label in vectors:
    assert cursor + 8 <= len(response), label
    status, length = struct.unpack_from('<II', response, cursor)
    cursor += 8
    value = response[cursor:cursor + length]
    cursor += length
    assert len(value) == length and status in (0, 1, 2, 3), label
    if fail:
      assert status == 2 and value == b'', (label, status)
    elif expected is None:
      assert status != 0 and value == b'', (label, status)
      if label.startswith('random-'):
        assert status in (1, 3), (label, status)
      elif label.startswith(('limit', 'huge-header-limit')):
        assert status == 3, (label, status)
      else:
        assert status == 1, (label, status)
    elif op:
      assert status == 0 and decode(value) == data, (label, status)
      compressed.append(value)
    else:
      assert status == 0 and value == expected, (label, status)
  assert cursor == len(response), 'Trailing response bytes'
  return compressed


def abiSource():
  """Wrap calls with sentinel checks for every ARM64 callee-saved register."""
  prefix = '_' if platform.system() == 'Darwin' else ''
  lines = ['.text', '.p2align 2']
  for public, target in (('checkedCompress', 'snappyCompress'),
                         ('checkedUncompress', 'snappyUncompress')):
    lines.extend([f'.globl {prefix}{public}', f'{prefix}{public}:'])
    # x16 is reserved for the indirect target until the call.
    if prefix:
      lines.extend([f'adrp x16, {prefix}{target}@PAGE',
                    f'add x16, x16, {prefix}{target}@PAGEOFF'])
    else:
      lines.extend([f'adrp x16, {target}',
                    f'add x16, x16, :lo12:{target}'])
    lines.append('b Lcheck')
  lines.extend(['Lcheck:', 'sub sp, sp, #160'])
  for i in range(6):
    lines.append(f'stp x{19 + 2*i}, x{20 + 2*i}, [sp, #{16*i}]')
  for i in range(4):
    lines.append(f'stp d{8 + 2*i}, d{9 + 2*i}, [sp, #{96 + 16*i}]')
  for i in range(19, 30):
    lines.append(f'mov x{i}, #0x1357')
  for i in range(8, 16):
    lines.append(f'fmov d{i}, x19')
  lines.extend(['blr x16', 'mov x9, #0x1357'])
  for i in range(19, 30):
    lines.extend([f'cmp x{i}, x9', 'b.ne Lbad'])
  for i in range(8, 16):
    lines.extend([f'fmov x10, d{i}', 'cmp x10, x9', 'b.ne Lbad'])
  for i in range(6):
    lines.append(f'ldp x{19 + 2*i}, x{20 + 2*i}, [sp, #{16*i}]')
  for i in range(4):
    lines.append(f'ldp d{8 + 2*i}, d{9 + 2*i}, [sp, #{96 + 16*i}]')
  lines.extend(['add sp, sp, #160', 'ret', 'Lbad:', 'brk #1'])
  if not prefix:
    lines.append('.section .note.GNU-stack,"",@progbits')
  return '\n'.join(lines) + '\n'


def main():
  """Check C with sanitizers and native ARM64 with guarded allocations."""
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('--cc', default=os.environ.get('CC', 'cc'))
  parser.add_argument('--supersnappy', type=Path)
  parser.add_argument('--corpus', type=Path)
  parser.add_argument('--assembly', type=Path,
      default=Root / 'benchmarks/arm64/snappy_hand.S')
  parser.add_argument('--require-sanitizers', action='store_true')
  parser.add_argument('--require-asm', action='store_true')
  args = parser.parse_args()
  cc = shlex.split(args.cc)
  if not shutil.which(cc[0]):
    parser.error('A GCC-compatible C compiler is required (set CC or --cc)')
  tests = [row for row in cases() if row[0] != 'negative-limit']
  # The C ABI uses size_t; a negative output limit is not representable.
  tests.extend([('limit-zero-empty', b'\0', 0, b''),
                ('limit-zero-nonempty', literalBlock(b'a'), 0, None)])
  for n in range(1, 41):
    data = bytes(range(n))
    tests.append((f'literal-boundary-{n}', literalBlock(data), n, data))
  # Exercise every short repeating period and exact copy tail length.
  for distance in range(2, 8):
    for count in range(1, 65):
      for kind in (2, 3):
        seed = bytes(range(101, 101 + distance))
        expected = (seed * ((count + 2 * distance) // distance))[:distance + count]
        encoded = (varint(len(expected)) + literal(seed) +
                   bytes([kind | ((count - 1) << 2)]) +
                   distance.to_bytes(2 if kind == 2 else 4, 'little'))
        tests.append((f'pattern-{distance}-{count}-{kind}', encoded,
                      len(expected), expected))
  raw = inputs()
  if args.corpus:
    raw.extend(p.read_bytes() for p in sorted(args.corpus.rglob('*')) if p.is_file())
  rng = random.Random(1729)
  for _ in range(500):
    data = rng.randbytes(rng.randrange(80))
    try:
      expected = decode(data, 1000000)
    except ValueError:
      expected = None
    # Random malformed framing can also legitimately fail the output cap.
    tests.append(('random-block', data, 1000000, expected))
  with tempfile.TemporaryDirectory(prefix='snappy-hand-') as temporary:
    directory = Path(temporary)
    interop = prepareInterop(args.supersnappy, directory, raw) if args.supersnappy else None
    if interop:
      tests.extend(interop[1])
    vectors = [(0, data, limit, 0, side, expected, name)
               for side in (0, 1) for name, data, limit, expected in tests]
    vectors += [(1, data, 0, 0, side, data, f'compress-{i}')
                for side in (0, 1) for i, data in enumerate(raw)]
    vectors += [(op, data, 1000000, 1, side, None, 'allocation')
                for side in (0, 1)
                for op, data in ((0, literalBlock(b'abc')), (1, b'abc' * 100))]
    source = directory / 'harness.c'
    source.write_text(Harness)
    probe = directory / 'probe.c'
    probe.write_text('int main(void) { return 0; }\n')
    extension = '.exe' if os.name == 'nt' else ''
    probeExe = directory / ('probe' + extension)
    flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    build = subprocess.run([*cc, *flags, str(probe), '-o', str(probeExe)],
                           capture_output=True, timeout=60)
    supported = build.returncode == 0
    if supported:
      result = subprocess.run([str(probeExe)], capture_output=True, timeout=60)
      supported = result.returncode == 0 and not result.stderr
    assert supported or not args.require_sanitizers, 'ASan/UBSan unavailable'
    baseline = None
    for opt in ('-O0', '-O2'):
      executable = directory / ('c' + opt + extension)
      run([*cc, '-std=c11', opt, '-g', *(flags if supported else []),
           '-I', Root / 'benchmarks', source, '-o', executable])
      compressed = execute(executable, directory, vectors)
      if baseline is None:
        baseline = compressed
      assert compressed == baseline, 'C optimization changed compressed bytes'
      print(f'C {opt}: {len(vectors)} cases passed; ASan/UBSan {"enabled" if supported else "unavailable"}')
    assembly = args.assembly.resolve()
    native = platform.machine().lower() in ('arm64', 'aarch64') and platform.system() == 'Darwin'
    if native and assembly.exists():
      executable = directory / 'arm64'
      abi = directory / 'abi.S'
      abi.write_text(abiSource())
      run([*cc, '-O2', '-g', '-DGUARDS', '-DSNAPPY_HAND_ASM',
           '-D_realloc=_snappyTestRealloc',
           '-I', Root / 'benchmarks', source, assembly, abi, '-o', executable])
      assert execute(executable, directory, vectors) == baseline, 'ASM compressed bytes differ from C'
      print(f'ARM64: {len(vectors)} cases passed; guard pages, canaries, and callee-saved register checks')
    else:
      assert not args.require_asm, 'Native ARM64 assembly unavailable'
      print('ARM64 skipped: requires a native ARM64 macOS host and snappy_hand.S')
    if interop:
      for i, data in enumerate(baseline[:len(raw)]):
        (directory / f'nifty-{i}').write_bytes(data)
      run([interop[0], directory, len(raw), 'check'])
      exact = sum(data == interop[1][i][1] for i, data in enumerate(baseline[:len(raw)]))
      print(f'Supersnappy interoperability passed; {exact}/{len(raw)} exact compressed blocks')


if __name__ == '__main__':
  main()

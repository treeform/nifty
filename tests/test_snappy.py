#!/usr/bin/env python3
"""Batch raw Snappy conformance across available Nifty backends, without timings."""
import argparse
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile

from snappy_reference import decode, literal, literalBlock, varint

Root = Path(__file__).resolve().parent.parent
Backends = ('c', 'arm64', 'amd64', 'interp')


def cases():
  """Exercise every tag form and hostile framing independently of the port."""
  valid = [('empty', b'\0', b'')]
  for length in (1, 59, 60, 61, 255, 256, 257, 65535, 65536, 65537):
    data = bytes(index % 256 for index in range(length))
    valid.append((f'literal-{length}', literalBlock(data), data))
  for width in range(1, 5):
    valid.append((f'literal-width-{width}', b'\1' + literal(b'Z', width), b'Z'))
  for kind in (1, 2, 3):
    for offset in (1, 2, 7):
      seed = bytes(range(offset))
      for count in (range(4, 12) if kind == 1 else range(1, 65)):
        if kind == 1:
          tag = bytes([1 | ((count - 4) << 2) | ((offset >> 8) << 5), offset & 255])
        else:
          tag = bytes([kind | ((count - 1) << 2)]) + offset.to_bytes(2 if kind == 2 else 4, 'little')
        expected = (seed * ((offset + count + offset - 1) // offset))[:offset + count]
        valid.append((f'copy-{kind}-{offset}-{count}', varint(len(expected)) + literal(seed) + tag, expected))
  # Large legal offsets exercise high offset bits of all three copy tags.
  for kind, offset in ((1, 2047), (2, 65535), (3, 65536)):
    seed = bytes(index % 251 for index in range(offset))
    tag = (bytes([1 | ((offset >> 8) << 5), offset & 255]) if kind == 1 else
           bytes([kind | (3 << 2)]) + offset.to_bytes(2 if kind == 2 else 4, 'little'))
    valid.append((f'wide-offset-{kind}', varint(offset + 4) + literal(seed) + tag, seed + seed[:4]))
  invalid = [b'', b'\x80', b'\x80' * 5, b'\xff\xff\xff\xff\x10',
             b'\xff\xff\xff\xff\xff\0', b'\1', b'\0\0x',
             b'\1\4ab', b'\2\0a', b'\1\0', b'\1\xf0',
             b'\1\xf4\0', b'\1\xf8\0\0', b'\1\xfc\0\0\0',
             b'\1\xfc\xff\xff\xff\xff']
  for name, encoded, expected in valid:
    if len(encoded) < 128:
      invalid.extend(encoded[:end] for end in range(1, len(encoded)))
  for kind in (1, 2, 3):
    width = (1, 2, 4)[kind - 1]
    for offset in (0, 2):
      invalid.append(b'\5\0a' + bytes([kind]) + offset.to_bytes(width, 'little'))
    tag = bytes([kind]) + (1).to_bytes(width, 'little')
    for prefix in range(1, len(tag)):
      invalid.append(b'\5\0a' + tag[:prefix])
  result = [(name, data, len(expected), expected) for name, data, expected in valid]
  result += [(f'invalid-{i}', data, 1000000, None) for i, data in enumerate(invalid)]
  result += [('limit', literalBlock(b'abc'), 2, None),
             ('negative-limit', b'\0', -1, None),
             ('huge-header-limit', varint(0xffffffff), 1024, None)]
  for name, data, limit, expected in result:
    try:
      actual = decode(data, limit)
    except ValueError:
      assert expected is None, name
    else:
      assert actual == expected, name
  return result


def inputs():
  """Include deterministic binary, random, low entropy, and fragment boundaries."""
  rng = random.Random(20261114)
  result = [b'', b'\0', bytes(range(256)), b'abc\0def\xff' * 100]
  for length in (1, 2, 3, 4, 15, 16, 17, 59, 60, 61, 255, 256,
                 257, 1024, 65535, 65536, 65537, 131073):
    result.extend((rng.randbytes(length), bytes(rng.randrange(4) for _ in range(length)),
                   (b'abcd\0' * ((length + 4) // 5))[:length]))
  return result


Prelude = '''import "lib/snappy"
extern "libc":
  proc getchar(): int32
proc readHex(): 0 .. 15 =
  let digit = getchar()
  if digit >= 48 and digit <= 57:
    return digit - 48
  if digit >= 97 and digit <= 102:
    return digit - 87
  return 0
proc readByte(): 0 .. 255 =
  let high = readHex()
  let low = readHex()
  return high * 16 + low
proc readCount(): 0 .. 4294967295 =
  var value: 0 .. 4294967295 = 0
  for i in 0 ..< 4:
    let byte = readByte()
    if byte >= 0 and byte <= 255 and value <= 16777215:
      value = value * 256 + byte
  return value
proc load(count: int, input: var string) =
  input.clear()
  for i in 0 ..< count:
    let byte = readByte()
    if byte >= 0 and byte <= 255:
      discard input.addByte(byte)
proc emit(ok: bool, output: string, error: SnappyError) =
  echo ok
  echo error.code
  echo error.offset
  echo error.message.len
  echo output.len
  for i in 0 ..< output.len:
    echo output[i]
thread main() =
  var input: string
  var output: string
  var error: SnappyError
'''


def sourceFor(tests, raw):
  """Generate calls only; all codec work remains in the Nifty library."""
  return Prelude + f'''  for testIndex in 0 ..< {len(tests)}:
    load(readCount(), input)
    let limit = readCount() - 1
    discard output.add("stale")
    emit(uncompressSnappy(input, output, limit, error), output, error)
  for testIndex in 0 ..< {len(raw)}:
    load(readCount(), input)
    let size = input.len
    emit(compressSnappy(input, output, error), output, error)
    discard input.copyFrom(output)
    emit(uncompressSnappy(input, output, size, error), output, error)
'''


def inputPayload(tests, raw):
  """Transport framed bytes as ASCII hex to survive Windows text-mode stdin."""
  return (b''.join(len(data).to_bytes(4, 'big') + data +
                   (limit + 1).to_bytes(4, 'big')
                   for name, data, limit, expected in tests) +
          b''.join(len(data).to_bytes(4, 'big') + data for data in raw)).hex().encode('ascii')


def checkOutput(output, tests, raw):
  """Require exact framing, complete bytes, output clearing, and error resets."""
  rows = iter(output.decode('ascii').splitlines())
  def record():
    ok = next(rows)
    assert ok in ('true', 'false')
    code, offset, message, length = (int(next(rows)) for _ in range(4))
    assert 0 <= length <= 16777216
    data = bytes(int(next(rows)) for _ in range(length))
    return ok == 'true', code, offset, message, data
  for name, encoded, limit, expected in tests:
    ok, code, offset, message, data = record()
    assert ok == (expected is not None), (name, ok, code)
    if ok:
      assert data == expected and (code, offset, message) == (0, 0, 0), name
    else:
      assert not data and code != 0 and message > 0, name
      assert 0 <= offset <= len(encoded), (name, offset)
  compressed = []
  for index, expected in enumerate(raw):
    ok, code, offset, message, encoded = record()
    assert ok and (code, offset, message) == (0, 0, 0), index
    assert decode(encoded) == expected, index
    compressed.append(encoded)
    ok, code, offset, message, data = record()
    assert ok and data == expected and (code, offset, message) == (0, 0, 0), index
  assert next(rows, None) is None, 'Unexpected trailing output'
  return compressed


def run(command, **kwargs):
  """Keep compiler diagnostics attached to any failure."""
  result = subprocess.run([str(item) for item in command], capture_output=True,
                          timeout=300, **kwargs)
  if result.returncode:
    raise AssertionError(f'{command}: exit {result.returncode}\n' +
                         result.stdout.decode(errors='replace') +
                         result.stderr.decode(errors='replace'))
  return result


def prepareInterop(checkout, directory, raw):
  """Compile Supersnappy once; cross-check both directions with binary files."""
  source = directory / 'interop.nim'
  source.write_text('''import std/[os, strutils]
import supersnappy
let args = commandLineParams()
for i in 0 ..< parseInt(args[1]):
  let raw = readFile(args[0] / ("raw-" & $i))
  if args[2] == "compress":
    var encoded: string
    compress(encoded, raw)
    writeFile(args[0] / ("nim-" & $i), encoded)
  else:
    var decoded: string
    uncompress(decoded, readFile(args[0] / ("nifty-" & $i)))
    doAssert decoded == raw
''')
  executable = directory / ('interop.exe' if os.name == 'nt' else 'interop')
  run(['nim', 'c', '-d:release', '--hints:off',
       f'--path:{checkout.resolve() / "src"}', f'-o:{executable}', source])
  for index, data in enumerate(raw):
    (directory / f'raw-{index}').write_bytes(data)
  run([executable, directory, len(raw), 'compress'])
  tests = []
  for index, data in enumerate(raw):
    encoded = (directory / f'nim-{index}').read_bytes()
    assert decode(encoded) == data
    tests.append((f'supersnappy-{index}', encoded, len(data), data))
  return executable, tests


def main():
  """Compile once per backend/optimization and run the whole batched suite."""
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('--compiler', type=Path, default=Root / ('nifty.exe' if os.name == 'nt' else 'nifty'))
  parser.add_argument('--backend', action='append', choices=Backends)
  parser.add_argument('--supersnappy', type=Path, help='Optional Supersnappy checkout')
  parser.add_argument('--corpus', type=Path, help='Additional files for round trips')
  args = parser.parse_args()
  args.compiler = args.compiler.expanduser().resolve()
  for path in (args.corpus, args.supersnappy):
    if path is not None and not path.is_dir():
      parser.error(f'Not a directory: {path}')
  sys.path.insert(0, str(Root / 'benchmarks'))
  import run as infrastructure
  host = infrastructure.hostInfo()
  backends = args.backend or [backend for backend in
    infrastructure.availableBackends(host, args.compiler) if backend in Backends]
  tests, raw = cases(), inputs()
  if args.corpus:
    raw.extend(path.read_bytes() for path in sorted(args.corpus.rglob('*')) if path.is_file())
  payload = inputPayload(tests, raw)
  with tempfile.TemporaryDirectory(prefix='nifty-snappy-') as temporary:
    directory = Path(temporary)
    source = Root / f'.snappy-conformance-{os.getpid()}.nifty'
    try:
      interop = prepareInterop(args.supersnappy, directory, raw) if args.supersnappy else None
      if interop:
        tests.extend(interop[1])
        payload = inputPayload(tests, raw)
      source.write_text(sourceFor(tests, raw))
      for backend in backends:
        for opt in ('none', 'speed'):
          executable = directory / (f'{backend}-{opt}' + ('.exe' if os.name == 'nt' else ''))
          if backend == 'c':
            csource = directory / f'{backend}-{opt}.c'
            run([args.compiler, 'build', source, '--emit-c', '-o', csource])
            cc = os.environ.get('CC') or next((path for name in ('cc', 'gcc', 'clang')
                      if (path := shutil.which(name))), None)
            if not cc:
              parser.error('A C compiler is required (set CC)')
            standard = ['-O0' if opt == 'none' else '-O2', '-g',
                        '-pthread', '-fno-strict-aliasing', '-ffp-contract=off']
            if os.name == 'nt':
              standard.append('-static')
            flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
            probe = directory / 'probe.c'
            probe.write_text('int main(void) { return 0; }\n')
            probeExe = directory / ('probe.exe' if os.name == 'nt' else 'probe')
            probeBuild = subprocess.run(
              [cc, *standard, *flags, str(probe), '-o', str(probeExe), '-lm'],
              capture_output=True, timeout=60)
            supported = probeBuild.returncode == 0
            if supported:
              try:
                probeRun = subprocess.run([str(probeExe)], capture_output=True,
                                          timeout=60)
                supported = probeRun.returncode == 0 and not probeRun.stderr
              except OSError:
                supported = False
            run([cc, *standard, *(flags if supported else []),
                 csource, '-o', executable, '-lm'])
          elif backend != 'interp':
            run([args.compiler, 'build', source, f'--backend:{backend}', f'--opt:{opt}', '-o', executable])
          prefix = ['/usr/bin/arch', '-x86_64'] if backend == 'amd64' and host['system'] == 'Darwin' and host['physical_architecture'] == 'arm64' else []
          command = ([args.compiler, 'interpret', source, f'--opt:{opt}']
                     if backend == 'interp' else [*prefix, executable])
          result = run(command, input=payload)
          assert not result.stderr, result.stderr.decode(errors='replace')
          compressed = checkOutput(result.stdout, tests, raw)
          if interop:
            exact = sum(data == interop[1][index][1]
                        for index, data in enumerate(compressed))
            for index, data in enumerate(compressed):
              (directory / f'nifty-{index}').write_bytes(data)
            run([interop[0], directory, len(raw), 'check'])
          print(f'{backend}/{opt}: {len(tests)} decode vectors, {len(raw)} independent round trips passed' +
                (f'; sanitizers {"enabled" if supported else "unavailable"}' if backend == 'c' else '') +
                (f'; Supersnappy both directions passed, {exact}/{len(raw)} identical compressed blocks' if interop else ''))
    finally:
      source.unlink(missing_ok=True)


if __name__ == '__main__':
  main()

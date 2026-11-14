# Snappy in Nifty

`lib/snappy.nifty` ports compression and decompression from
[Supersnappy](https://github.com/guzba/supersnappy), using the local source
revision `ff8fe2bffefc1f4edc15deb20d921f600babb8c4`. The implementation is
Nifty code and runs through the C, ARM64, and AMD64 backends. The original
MIT license is retained in [SNAPPY_LICENSE](../lib/SNAPPY_LICENSE).

It implements the same [raw Snappy block format](https://github.com/google/snappy/blob/main/format_description.txt)
as Supersnappy. The separate framed stream format, CRC checksums, and file
container headers are outside this API.

## Try it

Build the compiler and available runtimes with `nim r tools/build.nim`,
then run the example:

```sh
./nifty examples/snappy.nifty --backend:c
./nifty examples/snappy.nifty --backend:arm64
./nifty examples/snappy.nifty --backend:amd64
```

The example compresses repeated text from 67 bytes to 22 bytes, expands it,
and prints the original text and a successful round-trip check. AMD64
execution on an ARM64 Mac requires Rosetta.

The two operations write into caller-owned growable strings:

```nifty
import "../lib/snappy"

thread main() =
  var compressed: string
  var restored: string
  var error: SnappyError
  if compressSnappy("hello hello hello", compressed, error):
    if uncompressSnappy(compressed, restored, 1048576, error):
      echo restored
    else:
      echo error.offset, ": ", error.message
  else:
    echo error.message
```

`maxOutput`, here 1 MiB, limits the declared decompressed size before any
output allocation. A negative limit fails. Input and output are distinct
buffers under Nifty's borrowing rules. Strings carry arbitrary bytes,
including embedded NUL and non-UTF-8 data. Neither operation requires a
text encoding.

Both return `bool`. Success clears the error; failure sets its code,
offset, and message and leaves output empty. Existing output capacity can
be reused. Error codes are `SnappyFormatError`, `SnappyAllocationError`,
and `SnappyLimitError`. Offsets refer to the compressed input when decoding.
Compression input and declared decompressed size are limited to
`2^32 - 1` bytes.

## How it works

A raw block starts with the original byte length encoded as a varint.
The rest alternates between literals and copies. A literal stores bytes
directly. A copy says how far back to look in the decoded output and how
many bytes to repeat. Copies can overlap, allowing a short pattern to
expand into a longer run.

The 67-byte example is represented by an original-length prefix, a
17-byte literal containing `Snappy in Nifty! `, and a copy of 50 bytes
from 17 bytes back. Its compressed representation occupies 22 bytes.
Small or incompressible inputs can grow because tags and lengths take
space too.

The compressor keeps Supersnappy's 64 KiB fragments, adaptive hash table
of 256 through 16,384 entries, skipped probes for unmatched data, and
64/60-byte copy splitting. The maximum table occupies 32 KiB in Nifty's
statically planned per-thread arena. The decoder accepts all three copy
tag forms, including offsets larger than a compressor fragment, and
checks every input and output boundary.

The port uses bounded byte loads, stores, and match scanning. Supersnappy's
unchecked wide loads, trailing-zero match scan, and deliberate over-copy
fast paths are not reproduced. The wrapping 32-bit hash is expressed as
bounded integer multiplication followed by modulo. This makes the code
valid under Nifty's arithmetic and memory rules while preserving the
compression algorithm. These are measurements of the Nifty port, not a
performance claim against the original Nim implementation.

## Benchmark

```sh
python3 benchmarks/run_snappy.py
python3 benchmarks/run_snappy.py --samples 7 --repeat 10 --wall
python3 benchmarks/run_snappy.py --backend hand-asm,hand-c
python3 benchmarks/run_snappy.py --backend wasm64 --samples 7 --repeat 100
python3 benchmarks/run_snappy.py --backend c,arm64 --size 65537
python3 benchmarks/run_snappy.py --opt none --output /tmp/snappy-unoptimized
```

By default, each backend processes three deterministic 256 KiB workloads:

- `repetitive`: a repeated English sentence.
- `mixed`: repeated short patterns mixed with changing bytes.
- `random`: pseudorandom bytes from a fixed integer generator.

Each workload crosses four compressor fragments. The benchmark reports
compressed size and one combined compression-plus-decompression time.
Both codec calls are timed separately with
`clock_gettime(CLOCK_MONOTONIC)`. Setup, hex formatting, checksums, and
byte-for-byte verification are outside the intervals. Clock-call overhead
is included.

The program first exercises both operations, then reuses their output
capacities. Consequently, steady-state output allocation is normally
avoided. Table initialization, buffer length changes, memory writes, and
the codec itself remain timed. This is a reusable-buffer benchmark, not
the cost of allocating and freeing fresh buffers on every operation.

The runner builds each backend once and rotates execution order across
warmup and measured rounds. Each sample starts a fresh process, with its
own capacity warmup. The reported median is taken over process samples;
each sample averages the sum of its paired compression and decompression
calls. It does not add independently calculated medians. Separate codec
times and throughput remain available in the JSON results. Native optimization
defaults to `speed`; `--opt none` selects the unoptimized native pipeline.
The C backend uses its normal `-O2` flags. AMD64 on Apple Silicon is
explicitly labeled as Rosetta execution.

The timing runner requires macOS or Linux and Python's standard library.
Nifty rows require the Nifty compiler and matching runtime templates.
Hand C and the C backend require a C compiler, selected with `--cc` or `CC`.
Hand ASM requires macOS on ARM64. Selecting only Hand C or Hand ASM does
not require the Nifty compiler.

WASM64 runs the same Nifty codec through Wasmtime with memory64 enabled.
Select `--backend wasm64` (or `wasm`); `NIFTY_WASMTIME` overrides the engine
executable. The runner uses WASI's monotonic clock and records the engine
version and hash. Compilation and process startup are outside the timed
compression and decompression intervals. WASM64 appears last when available.

[snappy_straight.c](snappy_straight.c) is a standalone C port of the same
Supersnappy algorithm. It uses wide loads and match scanning, retains the
same fragment, hash, probe, and copy-splitting rules, and produces the same
compressed bytes. Its decoder checks input lengths, output limits, and
copy distances before expanding data. The maximum hash table occupies
32 KiB of stack storage. The Nifty implementation keeps its table in the
per-thread arena instead.

Hand ASM links a persisted ARM64 codec into the same C benchmark driver.
See [SNAPPY_HAND_ASM.md](SNAPPY_HAND_ASM.md) for its provenance, manual
changes, and validation. Default row order is Hand ASM, Hand C, Nifty C
backend, ARM64 backend, AMD64 backend via Rosetta where applicable, and WASM64.

An independent Python decoder validates each process's compressed bytes
against separately generated inputs. Every timed round trip compares all
decoded bytes in the workload program; the runner also validates lengths
and checksums.
Compressed output must agree across backends and samples. Errors prevent
publication of timing results.

`benchmarks/output/snappy` is ignored by Git and contains the report,
original inputs, raw timing samples, clock values, executable architecture,
build commands, and compiler/source hashes. Each build keeps snapshots of
the workload and all four library modules for Nifty, or the C driver and
selected assembly with provenance for the standalone implementations.
Use a separate `--output`
directory to retain another run. `--wall` also shows process wall time,
which includes the deliberately untimed verification and output work.

### Measured example

Apple M4 Pro, macOS 15.1, November 14, 2026. Each cell is median
compression plus decompression time in milliseconds for 256 KiB, seven
process samples, and one hundred paired operations per sample:

| Implementation | Repetitive | Mixed | Random |
| --- | ---: | ---: | ---: |
| Hand ASM | 0.025 | 0.192 | 0.012 |
| Hand C | 0.034 | 0.211 | 0.013 |
| Nifty C backend | 0.324 | 0.522 | 0.358 |
| ARM64 backend | 1.241 | 1.672 | 1.170 |
| AMD64 via Rosetta | 1.064 | 1.681 | 1.274 |

The saved run is `benchmarks/output/snappy-hand/results.json`. The combined
[raytrace / JSON / snappy table](COMPARISON.md) keeps the earlier raytrace
and JSON measurements.

All backends produced identical compressed blocks: 12,475 bytes for
repetitive data, 40,513 for mixed data, and 262,159 for random data. The
last fixture expands slightly, as expected for effectively incompressible
input. These are synthetic workloads and timings are machine-specific.

## Validation

```sh
python3 benchmarks/test_snappy_runner.py
python3 benchmarks/test_snappy_hand.py
python3 tests/test_snappy.py
python3 tests/test_snappy.py --supersnappy /path/to/supersnappy
nim r tests/test_snappy.nim
```

The format suite covers literals at all length boundaries, every copy tag
and legal copy count, overlapping copies, offsets above 65,535, fragment
boundaries, binary data, malformed and truncated streams, output limits,
and error/output reuse. The optional Supersnappy checkout checks
interoperability in both directions without becoming a runtime dependency.
C tests use AddressSanitizer and UndefinedBehaviorSanitizer when supported.
The allocator test injects failures and checks cleanup, output clearing,
capacity reuse, and guards around owned memory.

The initial run passed 4,071 decoding vectors and 58 independent round
trips in each of six backend/optimization combinations, with Supersnappy
interoperability enabled. All 58 compressed blocks matched the Nim
implementation byte for byte. The allocation harness passed four injected
failures. Importing only the decoder also has a C compiler regression test:
unused routines with arena storage must not leave undeclared references
in generated code.

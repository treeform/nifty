# Retained JSON tree benchmark

`json_parser.nifty` measures the parser in `lib/json.nifty` alongside the
raytracer benchmark. `json_parser_straight.c` is an independent handwritten
C parser with its own owned tree. It compiles directly with the C compiler
and does not use Nifty. Tables list Hand ASM, Hand C, Nifty C backend,
ARM64, AMD64, then WASM64 when available. Build the Nifty compiler and runtime templates from
the repository root with `nim r tools/build.nim`, then compare them:

```sh
python3 benchmarks/run_json_tree.py
python3 benchmarks/run_json_tree.py --backend hand-c,c,arm64 --records 512 --repeat 20 --wall
python3 benchmarks/run_json_tree.py --backend hand-c
python3 benchmarks/run_json_tree.py --backend hand-asm,hand-c --repeat 100
python3 benchmarks/run_json_tree.py --backend wasm64 --records 128 --repeat 100
python3 benchmarks/run_json_tree.py --opt none --output /tmp/nifty-json-unoptimized
python3 benchmarks/test_json_runner.py
python3 benchmarks/test_json_straight.py
python3 benchmarks/test_json_hand_asm.py
```

The runner uses Python's standard library. Timed programs use POSIX
`clock_gettime(CLOCK_MONOTONIC)` on macOS or Linux. C requires `cc`; native
backends require the matching runtime beside the compiler or through
`NIFTY_RUNTIME_ARM64` and `NIFTY_RUNTIME_AMD64`. The default backend list
selects available executable targets. AMD64 on an ARM64 Mac requires
Rosetta and is explicitly labeled as translated execution. The Python
protocol tests also run on Windows, where the timed workload is currently
unsupported.

`wasm64` (alias `wasm`) runs the same Nifty parser through Wasmtime with
memory64 enabled. Install Wasmtime or set `NIFTY_WASMTIME` to its executable.
The runner selects WASI's monotonic clock, validates the module's memory64
ABI, and records the engine version and hash. Engine compilation and process
startup are outside the guest's timed parse/consume/cleanup intervals.

`hand-c` (also `c-straight`) is the handwritten C parser; `c` is the Nifty parser compiled
through Nifty's C backend. Both C entries use the same C compiler and
`-O2 -pthread -fno-strict-aliasing -ffp-contract=off` flags. `--cc` selects
that compiler; its default respects `CC` and otherwise uses `cc`. The
standalone-only command needs no Nifty compiler, source modules, or runtime.
`--hand-c-source` (also `--straight-c-source`) selects an alternate standalone source.

`hand-asm` uses the same standalone C driver and tree layout, linked to a
persisted ARM64 assembly implementation. It starts with Clang's C output
and manually optimizes ASCII string copying and checksum arithmetic. It
appears as `Hand ASM (ARM64)` and is automatically available on ARM64 Macs
with a C compiler. It requires no Nifty compiler or runtime. The assembly
uses Mach-O syntax and is not enabled on Linux or Windows. See
[HAND_ASM.md](HAND_ASM.md) for the original assembly listing, changes,
provenance, and validation. `--hand-asm-source` selects another listing.

The default input is an array of 128 records, totaling 26,753 bytes. Each
record includes all six JSON value types, nested arrays and objects, an
integer beyond float64's exact integer range, an exponent spelling,
escaped newlines, Unicode surrogate pairs, an embedded NUL, and empty
containers. `--records` changes the array length from 1 through 4096.
This is a fixed shallow workload; it does not represent deep-nesting or
large-string performance.

Input construction happens before timing. Each timed cycle parses a fresh
owned tree, consumes every value and key into a checksum, and frees the
tree before returning. The Nifty consumer follows the fixture's four
container levels without recursive calls or copying the tree. Timing
includes parsing, allocation, tree consumption, and destruction. It
excludes process startup, input setup, final result formatting, and Python
validation. MiB/s is input bytes divided by this complete cycle time, not
tokenization-only throughput.

The C baseline implements the complete JSON grammar, strict UTF-8 and
Unicode escape validation, exact numeric spelling, ordered duplicate keys,
and a 512-container nesting limit. Its tree owns the strings and number
text independently of the input. It uses bounded recursive descent,
consumption, and destruction, and transfers child ownership into parent
containers. Nifty uses an explicit parse stack and currently copies
completed subtrees. The comparison therefore measures parser design and
ownership overhead as well as compiler code generation; it does not
isolate a backend-only performance difference. This C implementation is a
benchmark baseline, not a claim about the fastest available C JSON parser.

Each process performs 10 cycles by default. The runner compiles each
backend once, runs one warmup process, then collects five measured
processes per backend. It rotates backend order every round. The report
shows median, minimum, and maximum time per cycle, throughput, and separate
compile wall time. Cycle times divide each batch interval by its repetition
count. Samples start fresh processes, so first-use execution and Rosetta
translation within the timed loop remain included. `--wall` adds
whole-process wall medians. Native optimization defaults to `speed`;
`--opt none` selects the unoptimized
native backend. C always uses its existing `-O2` compilation flags.

Python independently parses the exact input using `json.loads`, preserving
number spellings and object order. It calculates the expected typed tree
checksum from decoded UTF-8 strings, exact number text, booleans, nulls,
keys, and container boundaries. Every parse in every warmup and sample
must match that checksum. The runner also validates workload size, parse
count, clocks, per-cycle checksums, and their batch sum. A failed parse,
incorrect tree, failed clock, unexpected output, or build failure prevents
publication of timing results. Checksums are a correctness check for this
benchmark, not a collision-free serialization of arbitrary trees.

The default output directory is `benchmarks/output/jsontree`, ignored by Git:

- `results.md` contains the validated timing table.
- `results.json` preserves raw samples, clock fields, sample order,
  commands, compiler and source hashes, architecture labels, and metadata.
- `input.json` contains the exact benchmark input.
- `build/nRECORDS-rREPEAT/BACKEND/` preserves generated source, a snapshot
  of the four Nifty parser modules where applicable, the executable, and
  build output. The standalone build contains a snapshot of the C source.
  Hand ASM also preserves the assembly, adjacent provenance manifest when
  present, and their hashes.
- `--emit-ir` preserves native IR through a separate compiler call outside
  compile timing and workload timing.

Use `--compiler` to select another compiler, `--samples` and `--warmups`
to change sampling, and `--repeat` to amortize clock overhead. Repetitions
and warmups are limited to 1 through 1000, samples to 5 through 1000. The
default timeout is 300 seconds per build or process; `--timeout` permits
up to 3600 seconds. Generated copies receive the workload constants and
host clock ID. The tracked workload and library are not modified.

The standalone program also builds directly on macOS or Linux:

```sh
cc -O2 -pthread -fno-strict-aliasing -ffp-contract=off \
  -DRECORDS=128 -DREPETITIONS=10 \
  benchmarks/json_parser_straight.c -o /tmp/json-parser-straight
/tmp/json-parser-straight
```

The C conformance test compiles once, compares arbitrary trees against
Python's parser, mutates and frees input to verify ownership, and injects
failure at each allocation point. It tests safe replacement of existing
output and cleanup after malformed input. Address and undefined behavior
sanitizers are enabled when supported. An optional external JSONTestSuite
checkout can be supplied with `--suite /path/to/test_parsing`; normal tests
do not download anything or depend on that checkout.

Use separate output directories for comparisons. A run clears prior
timing results from its chosen output directory before building. Build
artifacts remain available if validation fails. The raytracer continues
to use `python3 benchmarks/run.py` and its own output files.

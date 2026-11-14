# JSON parser benchmark

`json_parser.nifty` measures the parser in `lib/json.nifty` alongside the
raytracer benchmark. Build the compiler and runtime templates from the
repository root with `nim r tools/build.nim`, then run:

```sh
python3 benchmarks/run_json.py
python3 benchmarks/run_json.py --backend c,arm64 --records 512 --repeat 20 --wall
python3 benchmarks/run_json.py --opt none --output /tmp/nifty-json-unoptimized
python3 benchmarks/test_json_runner.py
```

The runner uses Python's standard library. Timed programs use POSIX
`clock_gettime(CLOCK_MONOTONIC)` on macOS or Linux. C requires `cc`; native
backends require the matching runtime beside the compiler or through
`NIFTY_RUNTIME_ARM64` and `NIFTY_RUNTIME_AMD64`. The default backend list
selects available executable targets. AMD64 on an ARM64 Mac requires
Rosetta and is explicitly labeled as translated execution. The Python
protocol tests also run on Windows, where the timed workload is currently
unsupported.

The default input is an array of 128 records, totaling 26,753 bytes. Each
record includes all six JSON value types, nested arrays and objects, an
integer beyond float64's exact integer range, an exponent spelling,
escaped newlines, Unicode surrogate pairs, an embedded NUL, and empty
containers. `--records` changes the array length from 1 through 4096.
This is a fixed shallow workload; it does not represent deep-nesting or
large-string performance.

Input construction happens before timing. Each timed cycle parses a fresh
owned tree, consumes every value and key into a checksum, and frees the
tree before returning. The bounded consumer follows the fixture's four
container levels without recursive calls or copying the tree. Timing
includes parsing, allocation, tree consumption, and destruction. It
excludes process startup, input setup, final result formatting, and Python
validation. MiB/s is input bytes divided by this complete cycle time, not
tokenization-only throughput.

Each process performs 10 cycles by default. The runner compiles each
backend once, runs one warmup process, then collects five measured
processes per backend. It rotates backend order every round. The report
shows median, minimum, and maximum time per cycle, throughput, and separate
compile wall time. Cycle times divide each batch interval by its repetition
count. Samples start fresh processes, so first-use execution and Rosetta
translation within the timed loop remain included. `--wall` adds
whole-process wall medians. Native
optimization defaults to `speed`; `--opt none` selects the unoptimized
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

The default output directory is `benchmarks/output/json`, ignored by Git:

- `results.md` contains the validated timing table.
- `results.json` preserves raw samples, clock fields, sample order,
  commands, compiler and source hashes, architecture labels, and metadata.
- `input.json` contains the exact benchmark input.
- `build/nRECORDS-rREPEAT/BACKEND/` preserves generated source, a snapshot
  of the four parser modules, the executable, and build output.
- `--emit-ir` preserves native IR through a separate compiler call outside
  compile timing and workload timing.

Use `--compiler` to select another compiler, `--samples` and `--warmups`
to change sampling, and `--repeat` to amortize clock overhead. Repetitions
and warmups are limited to 1 through 1000, samples to 5 through 1000. The
default timeout is 300 seconds per build or process; `--timeout` permits
up to 3600 seconds. Generated copies receive the workload constants and
host clock ID. The tracked workload and library are not modified.

Use separate output directories for comparisons. A run clears prior
timing results from its chosen output directory before building. Build
artifacts remain available if validation fails. The raytracer continues
to use `python3 benchmarks/run.py` and its own output files.

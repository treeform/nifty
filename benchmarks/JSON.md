# JSON document benchmark

The main JSON benchmark uses `lib/jsondoc.nifty`, a document with a node pool
and a byte pool. `json_document.nifty` measures the Nifty implementation;
`json_document_hand.c` is the handwritten C document reference.

Build Nifty from the repository root with `nim r tools/build.nim`, then run:

```sh
python benchmarks/run_json.py
python benchmarks/run_json.py --backend hand-c,c,amd64 --records 128 --repeat 100 --samples 5
python benchmarks/run_json.py --backend c,arm64 --records 128 --repeat 100 --samples 5
```

The default backend list is Hand C, Nifty C, and the physical host's native
backend. Only JSONdoc is built and displayed. `--backend` selects a subset;
`--cc` selects the C compiler, respecting `CC` by default. Windows uses
QueryPerformanceCounter; Linux and macOS use clock_gettime. Native runtime
templates must be available beside the Nifty compiler or through the matching
`NIFTY_RUNTIME_AMD64` / `NIFTY_RUNTIME_ARM64` environment variable.

The default input has 128 records and 26,753 bytes, including nested containers,
all JSON value types, exact number spellings, Unicode escapes, embedded NULs,
and empty containers. Each timed cycle parses a fresh document, hashes every
decoded value and ordered key, and releases both pools. Input setup, process
startup, and output are excluded. This is a fixed shallow workload rather than
a general claim about JSON performance. The hand C reference uses the same
pooled representation, with its own parser and traversal implementation.

The runner rotates variants through one warmup and seven measured processes
by default, with 50 complete cycles per process. Every repeated checksum must
match Python's independent JSON oracle before results are published.
`--records`, `--repeat`, `--samples`, and `--warmups` adjust the workload.
`--opt none` disables Nifty's AST and IR speed optimizations; the external C
compiler uses `-O2` in both modes.

Results go to `benchmarks/output/jsondoc` by default, independently of other
benchmarks. Use `--output` to choose another directory:

- `results.md`: document-only timing table and separate allocation counts.
- `results.json`: raw samples, sample order, build commands, compiler/source
  hashes, host details, and allocation traffic.
- `input.json`: exact benchmark input.
- `build/document/BACKEND/`: source snapshots, executable, and build output.
- `allocations/document/`: a separate instrumented C build. These counters
  never affect timed binaries; requested bytes are cumulative traffic, not
  peak memory.

See the [JSON document guide](../docs/json-document.md) for the representation
and API. The raytracer continues to use `benchmarks/run.py`.

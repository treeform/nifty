# Path filling benchmark

`path_fill.nifty` fills an original capital A defined entirely by straight
line segments in code: eight outer edges and a triangular inner contour.
There are no font files, curves, graphics APIs, or external input assets.
`path_fill_hand.c` implements the same algorithm as a handwritten C reference.

Build Nifty with `nim r tools/build.nim`, then run from the repository root:

```sh
python benchmarks/run_path_fill.py
python benchmarks/run_path_fill.py --size 128 --repeat 256 --samples 5
python benchmarks/run_path_fill.py --backend c,amd64
```

The default backends are Hand C, Nifty C, and the physical host's native
backend. `--backend c,arm64` selects C and ARM64 on an ARM64 host. Optional
`wasm64` requires Wasmtime with memory64 support; `interp` uses Nifty's
interpreter. These are explicit selections, excluded from the default run.
`--compiler` and `--cc` select toolchains; `--opt none` disables native speed
optimizations. C uses `-O2`. Windows timing uses QueryPerformanceCounter;
Linux and macOS use clock_gettime with CLOCK_MONOTONIC.

The rasterizer uses integer scanline intersections, insertion-sorted span
boundaries, even-odd filling, and 4x4 sample-center coverage. Horizontal edges
are ignored and vertical edge intervals are top-inclusive, bottom-exclusive.
The coverage buffer holds counts from 0 through 16. Every fill clears and
reuses it; there is no per-fill heap allocation. Sixteen quarter-pixel x/y
translations cycle through the workload so consecutive outputs differ.

The timer includes buffer clearing, edge intersection and sorting, span
filling, and a position-weighted checksum over every pixel. Outline setup,
process startup, validation, text output, and PNG encoding are excluded.
It measures a complete CPU coverage-mask fill and consumption, with no
compositing, stroking, curve flattening, text shaping, or GPU work.

Python independently classifies sample points against the contours using
integer point-in-polygon tests, rather than the benchmark's sorted span
algorithm. Every coverage count in all 16 phases must match exactly in
every process. Every timed fill must also match its phase's checksum.
No timing report is written after a failed check.

Defaults are 128x128 pixels, 256 fills per process, one warmup process, and
five measured processes per backend. Order rotates each round. `--size`
accepts 16 through 512; `--repeat`, `--samples`, and `--warmups` adjust the
workload. Use small counts for an exploratory smoke check.

Results go under `benchmarks/output/path-fill`, ignored by Git:

- `results.md`: median/minimum/maximum microseconds per fill, fills per second,
  and separate build times.
- `results.json`: raw timings, clock fields, sample order, host/toolchain
  details, source/executable hashes, phase checksums, and coverage hashes.
- `path_fill.png`: the verified untranslated A, black on white, at the actual
  benchmark resolution.
- `build/SIZE-rREPEAT/BACKEND/`: configured source, executable, and build output.

`--output` selects another directory. The runner changes workload constants
and clock bindings only in generated copies; tracked sources stay unchanged.

Initial Windows AMD64 run, 128x128, 256 fills per process, five measured
samples, native `speed` and C `-O2`:

| Backend | Median microseconds/fill |
| --- | ---: |
| Hand C | 111.367 |
| Nifty C | 111.239 |
| AMD64 | 229.332 |

These numbers include the pixel checksum. They describe this fixed A outline
and machine, rather than general font-rendering performance.

# Raytracer benchmark

Other workloads: [JSON documents](JSON.md) and [line-only path filling](PATH_FILL.md).

`raytracer.nifty` renders the fixed scene ported from Nimkey's raytracer.
The runner uses Python 3 and its standard library. Build the Nifty compiler
and the runtime templates first using `nim r tools/build.nim` from the repo
root. The C backend additionally requires `cc` in `PATH`.

```sh
python3 benchmarks/run.py
python3 benchmarks/run.py --check --samples 7 --repeat 3 --wall --emit-ir
python3 benchmarks/run.py --backend c,arm64 --size 16 --output /tmp/nifty-ray
python3 benchmarks/test_runner.py
```

Use `--compiler /absolute/path/to/nifty` to select another compiler build.
Runtime templates are found beside that compiler or through
`NIFTY_RUNTIME_ARM64` and `NIFTY_RUNTIME_AMD64`. The default backend list
includes each target executable on the current host with an available runtime.
An explicit unavailable target fails before compiling. On an ARM64 Mac,
AMD64 runs use `/usr/bin/arch -x86_64` and require Rosetta. Reports label
these measurements as translated execution. They are not native AMD64
hardware measurements. C compilation uses Nifty's `cc -O2` flags.

The default image is 64 by 64 pixels. Each backend compiles once for the
requested image size and repeat count. The runner executes one untimed
warmup process per backend and then five measured processes per backend.
Each process renders `--repeat` frames. Backend order rotates each round
to reduce bias from changing machine load or temperature. Compile wall
time appears separately from render samples. `--check` also builds and
validates the 4 and 16 pixel reference configurations when different from
the requested size. These configurations have their own compile measurements
in JSON and are not pooled with the requested benchmark.

Renderer timestamps come from `clock_gettime(CLOCK_MONOTONIC)` immediately
around the repeated rendering loop. Python subtracts the integer seconds and
nanoseconds. The timed loop includes an RGB byte sum after each frame so
every repetition affects an observable batch checksum. Reported per-frame
times divide this duration by the repeat count. Process startup, runtime
initialization, final verification, text output, Python parsing, and PNG
writing are outside the render interval. Whole-process wall times are
recorded separately in JSON and can be displayed with `--wall`.

Every warmup and sample must produce the expected dimensions, successful
clock status, positive elapsed time, valid RGB bytes, a matching byte sum,
and a batch sum equal to the final byte sum times the repeat count. Every
pixel must exactly match the independent reference when that size has one,
and must match all previous backend runs. Reference RGB bytes in
`reference/` come from the original Nimkey implementation. The manifest
records their provenance. An arbitrary size without a reference is labeled
`no independent golden` and checked against the other runs. A single backend
without a golden only establishes repeatability and the checksum invariants.
Any error aborts the run without publishing timing results.

The port retains float64 math, camera, scene, lighting, shadows, reflection
depth, and rounded byte wrapping from `tests/benchmarks/raytracer.nimkey`.
Nifty's recursion rule is respected by keeping six bounded reflection frames
and combining their colors in reverse order. Fixed lookup functions replace
the original constant scene arrays. Square root, floor, power, and round use
the platform math library through Nifty's binary FFI.

Normal benchmark runs do not require Nimkey. To regenerate the independent
4, 16, and 64 pixel references, build the Nimkey revision recorded in
`reference/manifest.json`, then run:

```sh
python3 benchmarks/generate_reference.py --nimkey /absolute/path/to/nimkey
```

This uses the original source snapshot in `reference/raytracer.nimkey` and
Nimkey's interpreter in 32-pixel tiles. It records RGB hashes, checksums, and
source provenance. The original MIT license is retained in `LICENSE`.

The source has no runtime configuration parser. The runner changes only
`ImageSize`, `Repetitions`, `EmitPixels`, and `ClockId` in generated copies
inside the output directory. Tracked source stays untouched. Image size is
limited to 1 through 512, sample counts to 5 through 1000, warmups and repeat
counts to 1 through 1000. Each compiler or renderer process has a 300 second
timeout by default, configurable with `--timeout` up to 3600 seconds.

The default output directory is `benchmarks/output`, ignored by Git:

- `results.json` contains machine details, tool versions, exact commands,
  source and compiler hashes, raw samples, statistics, checksums, RGB hashes,
  clock fields, and independent reference provenance.
- `results.md` contains the validated timing table.
- `raytracer.png` is the actual rendered image, encoded losslessly from the
  verified RGB bytes using Python's standard library.
- `build/SIZExSIZE-rREPEAT/BACKEND/` preserves generated Nifty source,
  executables, and build stdout and stderr. C builds preserve generated C.
  `--emit-ir` also preserves native IR from a separate compiler invocation
  outside the measured build and render intervals.

The runner clears prior `results.json`, `results.md`, and `raytracer.png`
from the chosen output directory before executing. Build artifacts remain
available for inspection even if a later correctness check fails. Dedicated
output directories prevent comparisons from accidentally using stale results.

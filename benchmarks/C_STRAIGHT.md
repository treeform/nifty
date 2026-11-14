# Hand C ray tracer

The ray-tracing benchmark includes Hand C (`hand-c`), a handwritten C program
compiled directly with the C compiler. It does not pass through Nifty's
parser, checker, C emitter, or native runtime. The existing `c` entry is
still Nifty source compiled through the Nifty C backend. The old
`c-straight` CLI spelling and report key remain compatible.

The default order is Hand ASM, Hand C, Nifty C backend, ARM64, then AMD64.
Hand ASM is available on Apple Silicon Macs; see [RAY_HAND_ASM.md](RAY_HAND_ASM.md).

```sh
# Compare Hand ASM, Hand C, Nifty C, and available native targets.
python3 benchmarks/run.py --check --samples 7 --repeat 3 --wall

# Select just the two C implementations and native ARM64.
python3 benchmarks/run.py --backend hand-c,c,arm64 --repeat 3

# Run only the standalone baseline, without a Nifty compiler installed.
python3 benchmarks/run.py --backend hand-c
```

The handwritten source is `raytracer_straight.c`, ported from
`treeform/nimkey/tests/benchmarks/raytracer.c`. Its original scene arrays,
operation order, shading, recursive reflections, and RGB quantization are
retained. The upstream C version used float32. This port uses float64 and
the corresponding math functions to match Nifty's current ray tracer.
Provenance and the original source hash are recorded in
`reference/c_straight.json`; the accompanying MIT license applies.

Both C entries use the same compiler and `-O2 -pthread
-fno-strict-aliasing -ffp-contract=off` flags. Use `--cc /path/to/clang` to
select that compiler; the default respects `CC`, falling back to `cc`.
`--hand-c-source` (also `--straight-c-source`) selects a different standalone source when needed.
Each build records its exact command, source hash, executable hash, and
execution architecture. The standalone source is copied unchanged into
the output directory and configured through compiler definitions.

The baseline renders the same complete frames. Every timed frame includes
an RGB checksum reduction; a volatile scalar publishes each frame's sum.
Camera setup, allocation, final verification, text output, and PNG writing
are outside the timer. Each sample starts a new process, and first-use
execution or translation inside the timed loop remains included. The
runner rotates all entries across warmups and samples and divides each
batch's elapsed time by its frame count.

Every rendered RGB byte must match the independent reference at sizes 4,
16, and 64 and all other executions. `--check` includes the small reference
sizes as separate validation builds. Arbitrary sizes without a reference
are explicitly labeled and compared byte for byte across implementations.
A mismatch prevents publication of timing results.

Compile the program directly on macOS or Linux without any Nifty tools:

```sh
cc -O2 -pthread -fno-strict-aliasing -ffp-contract=off \
  -DIMAGE_SIZE=64 -DREPETITIONS=3 \
  benchmarks/raytracer_straight.c -lm -o /tmp/raytracer-straight
/tmp/raytracer-straight
```

The executable writes the existing `NIFTY_RAY_V1` timing and RGB protocol.
The runner validates that output and saves `results.json`, `results.md`,
and `raytracer.png` under `benchmarks/output` by default. Use `--output` to
keep separate comparisons. The timed workload requires POSIX
`clock_gettime`; Python protocol and routing tests also run on Windows.

`tools/compare_backends.py` also includes a standalone C entry for every
selected C architecture. On macOS it passes `-arch` to both C builds, so
an AMD64 native result can be compared with AMD64 generated C and AMD64
standalone C. All AMD64 executables use the same Rosetta launch path on
an ARM64 Mac. Those are translated measurements, not measurements from
native AMD64 hardware.

```sh
python3 tools/compare_backends.py \
  --baseline /path/to/old/nifty --candidate /path/to/new/nifty \
  --backend arm64 --backend amd64 --size 64 --size 256 --repeat 3 \
  --output /tmp/nifty-ray-comparison
```

The ordinary runner's `hand-c` and `c` entries normally target the host
architecture; use the comparison tool for separate C baselines matched to
each native architecture. The JSON benchmark uses the same Hand ASM / Hand C naming and ordering.

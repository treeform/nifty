# Hand ASM ray tracer

The ray tracer now compares Hand ASM, Hand C, Nifty C backend, ARM64, and
AMD64 in that order. Hand ASM is a persisted, manually tuned ARM64 core
linked to the same C timing and checksum driver used by Hand C. It runs
on Apple Silicon Macs and does not require the Nifty compiler or runtime.

```sh
python3 benchmarks/run.py --size 256 --samples 7 --repeat 20 --check --wall
python3 benchmarks/run.py --backend hand-asm,hand-c --size 256 --repeat 20
python3 benchmarks/run.py --backend hand-asm
python3 benchmarks/test_ray_hand_asm.py
```

`hand-c` is the preferred name for the existing handwritten C baseline.
The old `c-straight` spelling and JSON report key remain supported.
`--hand-c-source` and `--straight-c-source` select the same C source option.
`--hand-asm-source` selects an alternative assembly listing. Explicit
standalone selections need no Nifty installation.

## Assembly origin

[raytracer_clang.s](arm64/raytracer_clang.s) preserves the Apple Clang 16
`-O2` listing before manual tuning. [raytracer_hand.S](arm64/raytracer_hand.S)
is the selected implementation. [raytracer_manifest.json](arm64/raytracer_manifest.json)
records the compiler, source and assembly hashes, generation command,
ABI, and changes. Both derive from [raytracer_straight.c](raytracer_straight.c),
whose original MIT license and upstream provenance remain in
[LICENSE](LICENSE) and [reference/c_straight.json](reference/c_straight.json).

The renderer now receives the image dimension as an argument. This lets
one frozen assembly core render all supported sizes, including odd sizes,
with the existing compile-time dimensions retained in the driver. Hand C
uses the same interface. The original compile-time C version was retained
in the local screening comparison to check that this adjustment did not
create an artificial performance advantage.

Recreate the untuned listing with the recorded toolchain:

```sh
cc -O2 -pthread -fno-strict-aliasing -ffp-contract=off \
  -DRAY_STRAIGHT_NO_MAIN -S benchmarks/raytracer_straight.c \
  -o /tmp/raytracer_clang.s
diff -u benchmarks/arm64/raytracer_clang.s benchmarks/arm64/raytracer_hand.S
```

The hand listing uses a macOS 11 deployment marker and baseline ARM64
instructions. Validation was performed on the current macOS host, not
every older macOS release. The Mach-O assembly is not enabled on Linux
or Windows.

## Optimizations

- `intersections` tests the two spheres together using two float64 SIMD
  lanes. It retains the plane test, exact square roots, nearest-hit order,
  and tie behavior. Inactive lanes are masked before square root.
- `render` calculates the camera's vertical contribution once per row
  and reuses it across columns.
- `shade` reuses its reflected-ray storage after intersection testing.
  `traceRay` avoids redundant ray copies, reduces its frame from 80 to
  32 bytes, and tail-calls shading. `getNaturalColor` drops unused register
  saves and restores.

The scene, lights, five reflection levels, shadows, color quantization,
and libm `pow` calls are unchanged. The implementation does not use fused
multiply-add, approximate reciprocals or square roots, cached frames, or
reduced image quality. This is a compiler-derived implementation with
focused manual edits, rather than a completely handwritten renderer.

## Validation and timing

The native test compares every RGB byte with Hand C at 15 sizes from
1 through 512, placing output at both ends of guarded mappings. Sizes
4, 16, and 64 also match the independent Nimkey interpreter goldens.
It checks randomized camera, ray, and shading results, nonpositive-size
no-ops, output canaries, and preserved registers and stack state. The C
oracle and harness run under ASan/UBSan; raw assembly accesses are covered
by explicit memory guards.

The intersection candidate additionally passed one million exact ray
comparisons and 100,000 bounded-ray floating-point exception comparisons.
Shading changes passed 3,000 varied rays across depths zero through six.
These tests check both hit selection and floating-point results before
RGB rounding can conceal differences.

The benchmark times complete frames plus an RGB checksum reduction. Setup,
allocation, final validation, text output, and PNG generation remain
outside the timer. Each measured sample starts a new process, renders the
requested number of frames, and contributes one per-frame average to the
median. Backend order rotates between samples. All RGB output must agree
before the runner publishes results.

On the Apple M4 Pro running macOS 15.1, the November 14, 2026 run at
256 x 256 pixels, seven measured samples, and 20 frames per sample gave:

| Backend | Median frame (ms) |
| --- | ---: |
| Hand ASM (ARM64) | 6.263 |
| Hand C (`-O2`) | 6.760 |
| Nifty C backend (`-O2`) | 7.321 |
| ARM64 | 7.468 |
| AMD64 via Rosetta | 10.839 |

Hand ASM used about 7.3 percent less render time than Hand C. The longer
paired screening run also showed about a 7 percent reduction. This gain is
smaller than the JSON assembly gain; the ray tracer's C baseline already
removes many redundant calculations. All five implementations produced
RGB SHA-256 `77c56ca90c6d7a71b509d25b9875e09c797e80203eedcde717928b5b01b16c32`.
The 256-pixel comparison is against the other implementations; the
independent interpreter goldens cover sizes 4, 16, and 64.

Reports, source snapshots, exact commands, hashes, raw samples, and the
rendered PNG are saved under `benchmarks/output`. The local candidate
screening and longer paired comparison are retained under
`benchmarks/output/ray-asm-study`. Use a separate `--output` directory to
retain another run. The JSON runner uses the same display names and order.

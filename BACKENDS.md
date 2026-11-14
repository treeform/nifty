# Nifty backends

Nifty keeps one parser and proof checker. The C backend generates readable C
directly from the checked AST. The native path lowers that AST into explicit
control flow, storage, and typed IR, then emits ARM64 or AMD64 instructions.
There is no generated C step when compiling a Nifty program natively.

## Build the toolchain

From this worktree:

```sh
nim r tools/build.nim
```

This builds `nifty`. On an ARM64 Mac it also builds the
`nifty-runtime-amd64` template, enabling AMD64 executables and Rosetta testing.
Nim and a C compiler are bootstrap dependencies for building these tools once.
Compiling individual Nifty programs with a native backend does not invoke them.

The C backend uses GCC or Clang compatible C compilers. Binary FFI declarations
use their C99-compatible `__asm__` labels and `__USER_LABEL_PREFIX__` macro to
bind private C identifiers to the requested external symbols. This keeps the
declared binary shapes independent of prototypes in runtime headers and lets
the C compiler provide the target's symbol prefix.

On Windows AMD64, `nim r tools/build.nim` builds `nifty.exe`. Native builds
use Windows threads, critical sections, condition variables, and executable
memory; no pthread runtime or external build tools are needed to compile or
run native programs. The C reference backend requires a MinGW GCC or Clang
toolchain with pthread support. Set `CC` to choose a compiler; otherwise
Nifty looks for `cc`, `gcc`, then `clang`. Windows C builds link their
toolchain runtimes statically.

## Select a backend

```sh
./nifty examples/sort.nifty --backend:arm64
./nifty examples/sort.nifty --backend:amd64
./nifty examples/sort.nifty --backend:c
./nifty build examples/sort.nifty --backend:arm64 -o /tmp/sort
```

The default backend matches the compiler's native architecture. `run` is the
default command; `build` writes an executable without running it. On an ARM64
Mac, the CLI uses Rosetta when running an AMD64 executable.

Native builds use `--opt:speed` by default. Select `--opt:none` to inspect or
execute the lowered IR without the shared optimization pipeline. The same
selection applies to `--emit-ir`, `--emit-native`, and native resource reports.
The C backend continues to generate directly from the checked source AST.

Inspect the C reference and native IR for the same program:

```sh
./nifty examples/sort.nifty --emit-c -o /tmp/sort.c
./nifty examples/sort.nifty --emit-ir -o /tmp/sort.ir
./nifty examples/sort.nifty --backend:amd64 --emit-native -o /tmp/sort.niftybin
```

`--emit-native` writes a versioned code-and-metadata image, not an OS executable.
`build` packages that image with the runtime into an executable. Native output
contains machine instructions and fixed storage descriptors; it does not
interpret the source or compile it to C at startup.

## Compiler boundaries

- `src/nifty.nim`: checked-source facade and backend selection.
- `src/nifty/checker.nim`: type, range, borrow, effect, lock, and termination
  checks, plus generic instantiation and validated argument conversions.
- `src/nifty/semantics.nim`: shared binding identities, parameter modes,
  ownership inventory, and ordered cleanup on each scope and control edge.
- `src/nifty/progress.nim`: foreign blocking checks and bounded exploration
  of exact channel protocols, with explicit reporting of incomplete analyses.
- `src/nifty/codegen.nim`: C emission from the checked AST and semantic plan.
- `src/nifty/lowering.nim`: source evaluation order, explicit branches,
  optional values, numeric conversions, and emission of planned borrows and
  cleanup into native IR, with target storage and arena planning.
- `src/nifty/backend/`: IR validation, register allocation, frame layout,
  instruction encoding, and executable memory. Adapted from Nimkey with
  attribution in `src/nifty/backend/PROVENANCE.md`.
- `src/nifty/nativecontainers.nim`: operations on fixed-capacity and growable
  storage, including fallible allocation and recursive ownership cleanup.
- `src/nifty/nativeruntime.nim`: preallocated program storage, host calls,
  thread startup, synchronization, and external symbol binding.
- `src/nifty/nativefiles.nim` and `nativebundles.nim`: image validation,
  serialization, and standalone packaging.

`check(module)` publishes the semantic plan only after all source checks
succeed. Generators and source reports require that plan; they do not run
their own type or borrow checking. Reports read ownership and lock proofs
from the same checked module. Backend IR, ABI, and image validation remain
separate checks on generated code and artifacts.

The native path retains Nifty's checker and diagnostics. It uses Nifty's own
fixed-capacity and growable layouts. Public and thread entries receive an
execution context, argument storage, result destination, and per-thread arena
pointer. Private routines can pass scalar arguments and return scalar values
or small homogeneous floating records in registers. User arithmetic, branches,
memory accesses, and routine calls are emitted as machine code; runtime helpers handle containers,
I/O, synchronization, and external library interaction.

## Native optimization

The native pipeline ports Nimkey's generic IR passes: scalar replacement,
constant folding, memory forwarding, dead value and store removal, common
expression reuse, loop invariant motion, address simplification, private
argument and return promotion, and branch cleanup. Checked constant ranges
may be unrolled within fixed source and transitive call expansion budgets.
Bounded CFG inlining and cleanup run for at most three rounds. Function indices
remain stable for runtime thread descriptors.

Typed storage metadata preserves field offsets, padding, optional payloads,
and argument passing modes. Growable descriptors retain pointer metadata so
private argument promotion cannot copy an owner. AST unrolling rebuilds binding
identities and scoped cleanup, and zero-initialization elision excludes owners.
Unknown external calls remain memory barriers.
Return promotion requires complete stores on every reachable return and
proves that delayed result writes cannot change observable behavior.
Floating arithmetic retains its source order and precision, without fused
multiply-add or reassociation. Floating records and SSA joins preserve their
bits, including signed zero and NaN payloads.

Static type sizes and alignment are checked before backend entry. Storage
calculations that overflow produce diagnostics rather than saturated reports.
Native IR storage descriptors use signed 32-bit byte counts, so layouts larger
than 2,147,483,647 bytes are rejected with a target-limit diagnostic. The C
backend can retain larger representable layouts.

Standard `m.sqrt` and `m.sqrtf` declarations with their exact scalar signatures
have a guarded hardware path. Integer bit classification accepts nonnegative
numbers and negative zero; negative arguments and NaNs still call libm. Tests
compare results, errno, floating exceptions, and rounding modes. Other external
libraries and signatures retain ordinary calls.

On macOS, exact float64 `m.floor` and `m.round` signatures also have native paths
for numeric arguments, with NaNs sent to libm. ARM64 uses rounding instructions;
AMD64 uses exact SSE2 bit operations, including ties away from zero for `round`.
Other operating systems retain the rounding library calls until their libm
behavior is validated.

Both emitters use bounded wide memory transfers with overlap-safe copies.
ARM64 also uses double-precision register moves, preserved float registers,
exact floating immediates, paired loads, and comparisons against zero.
AMD64 saves live floating registers around calls as needed. ARM64 saves volatile
floats at guarded math fallback calls, keeping normal calls on its existing
ABI-preserved register policy. The cold-call hint affects allocation only;
fallbacks still run normally and preserve live values when taken. These changes
keep values in registers along paths that do not execute a call and also
apply with `--opt:none`.

Saving floats at all ARM calls is available experimentally with the build flag
`-d:nimkeyArmCallSaves`. The default retains ABI-preserved registers and spills;
the experimental strategy regressed the raytracer on the measured ARM host.

## Resource reports

```sh
./nifty report examples/arena.nifty --backend:arm64
./nifty report examples/arena.nifty --backend:amd64
./nifty report examples/arena.nifty --backend:c
```

Native reports use finalized frame sizes, including register spills and ABI
space, combined with the direct-call graph. Arena reports distinguish logical
needs from aligned reservations for each thread instance. They explicitly
exclude unknown external-call stack usage, OS stack reservations, and runtime
bookkeeping. The C/source report remains available for abstract operation
bounds and comparison with the original implementation.

Growable `string` and `seq[T]` have fixed-size owning descriptors and
runtime-sized payloads on every backend. Native reports include descriptors
in their static storage figures and report heap payload separately. Allocation,
traversal, copying, and cleanup can make abstract work runtime-dependent.
Allocator overhead and temporary growth peaks are excluded from static totals.

Borrowed parameters keep ownership with the caller. The common semantic pass
plans cleanup at scope exits, early returns, and breaks. Both C and native
generation emit those ordered drops, evaluating return values first; shared
global owners are released after all threads finish. The checker rejects
escaping owners,
overlapping mutable borrows, and mutation of container metadata for every
backend. Allocation failure is a checked boolean result.

## Runtime distribution

Standalone packaging currently reuses a compiler binary as its prebuilt
runtime template. This produces larger executables than a dedicated minimal
runtime would, but requires no compiler during native program builds. A
different-architecture template can be supplied with `NIFTY_RUNTIME_AMD64` or
`NIFTY_RUNTIME_ARM64`, or placed beside the compiler under
`nifty-runtime-amd64` or `nifty-runtime-arm64`.
Windows runtime template filenames have an `.exe` suffix.

Native images use the `NIFTYN03` format, which includes union tags, member
layouts, and ownership metadata.
Rebuild the compiler and runtime templates together after this update, and
re-emit images created with the earlier format.

macOS packaging uses `/usr/bin/codesign` for an ad-hoc signature. ARM64 and
AMD64 execution are tested on macOS, with AMD64 run through Rosetta.
Windows AMD64 packaging validates a PE32+ runtime and appends the native
image to an ordinary Windows executable. Linux and macOS use POSIX threads;
Windows uses the native OS synchronization APIs and CRT thread startup.

Windows binary FFI resolves `libc` and `m` symbols from the system CRT DLLs,
and other library names as DLLs, for example `extern "kernel32"`.
Declarations must use the Windows ABI and available Windows symbols.
POSIX calls and Darwin socket structures are not emulated.

## Validation

```sh
nim r tests/tests.nim
nim r tests/test_semantics.nim
nim r tests/test_progress.nim
nim r tests/test_arithmeticproofs.nim
NIFTY_SANITIZE=1 nim r tests/test_copyrange.nim
nim r tests/test_runtimefailures.nim
nim r tests/test_backend_engine.nim
nim r tests/test_nativecontainers.nim
nim r tests/test_nativeruntime.nim
nim r tests/test_nativelowering.nim
nim r tests/test_nativereports.nim
nim r tests/test_iroptimizations.nim
nim r tests/test_irinlines.nim
nim r tests/test_irselects.nim
nim r tests/test_irfloatcarriers.nim
nim r tests/test_returnbundles.nim
nim r tests/test_callsaves.nim
nim r tests/test_armcalls.nim
nim r tests/test_armconversions.nim
nim r tests/test_floatconstants.nim
nim r tests/test_round64.nim
nim r tests/test_memoryops.nim
nim r tests/test_nativeunroll.nim
nim r tests/test_loweringoptimizations.nim
nim r tests/test_nativemaths.nim
nim r tests/test_memoryfiles.nim
nim r tests/test_nativememory.nim
nim r tests/test_native.nim "$PWD/nifty"
```

The cross-backend harness checks the language golden files and additional
numeric, evaluation-order, and arena cases through C, ARM64, and AMD64.
It verifies native executable architecture and builds and runs native programs
with compiler tools removed from `PATH`. C remains a useful independent
reference alongside the expected results.
On Windows, use `nim r tests/test_native.nim "$PWD/nifty.exe"`.
OS-specific FFI fixtures carry explicit platform markers and are reported
as skipped on other systems. Windows has a DLL/CRT/math fixture of its own.
Windows keeps `floor` and `round` as CRT calls: UCRT's signaling-NaN behavior
differs from the native replacement. Guarded math tests check that Windows
retains those calls, results, and floating exception behavior.
Unavailable CPUs are checked by emitting and validating native images,
without requiring a foreign runtime template. The harness also checks exact
output bytes, including embedded zero bytes and explicit CR/LF sequences.

## Benchmarks

The first benchmark is a float64 port of Nimkey's raytracer, using a bounded
reflection stack in place of recursion. Run `python3 benchmarks/run.py --check`
to compare C, ARM64, and AMD64 where available. Rendering is timed inside the
program; compilation, startup, and pixel formatting are measured separately
or excluded. Every sample is checked against its pixels, and checked-in
Nimkey interpreter images provide independent references at 4, 16, and 64
pixels square. See [benchmarks/README.md](benchmarks/README.md) for settings,
artifacts, and timing details.

For a frozen compiler comparison, `tools/compare_backends.py` builds both native
compilers and C for each selected architecture before rotating measured runs:

```sh
python3 tools/compare_backends.py \
  --baseline /path/to/frozen/nifty --candidate ./nifty \
  --backend arm64 --backend amd64 --repeat 10 \
  --output benchmarks/output/comparison
```

Use `--c-compiler ./nifty` to generate the C reference with the candidate;
otherwise C emission uses the baseline compiler. Keep the matching AMD64 runtime
beside each compiler. The runner retains exact
commands, compiler and executable hashes, all timings, and pixel checks. It uses
the existing C flags, including `-O2` and `-ffp-contract=off`, and runs AMD64 C and
native executables through Rosetta on Apple silicon. The default image sizes
are 64 and 256. Independent reference pixels exist at 4, 16, and 64; 256 compares
exact pixels across all variants.

A sample starts a new process. `--repeat 1` measures a single render, while
larger repetition counts report the average of a batch in that process. For
generated AMD64 code under Rosetta, first-use translation can contribute to
the timed render. Compare both single-frame and batch results; warmup processes
do not establish that a later process's generated code is already translated.

## Measured optimization results

Measured on an Apple M4 Pro with Darwin 24.1.0, using compiler code revision
`8a8a9d9` against the frozen `e517918` compiler. Seven measured processes follow
two warmup processes; each renders ten frames. Values are median milliseconds
per frame. AMD64 and its matching C reference both run through Rosetta.

| Image | Target | Before | Optimized | Matching C |
| --- | --- | ---: | ---: | ---: |
| 64x64 | ARM64 | 34.142 | 0.460 | 0.466 |
| 64x64 | AMD64 | 36.442 | 0.743 | 0.970 |
| 256x256 | ARM64 | 561.547 | 7.170 | 7.160 |
| 256x256 | AMD64 | 597.301 | 10.426 | 15.217 |

ARM64 matches the C backend in these batch measurements. AMD64 takes 23-31%
less render time. Native performance improves 49-78 times over the baseline.
All RGB bytes match; independent references cover 4, 16, and 64 pixels square,
while 256 compares every variant exactly.

Single-frame latency remains a separate limitation. At 64x64, optimized ARM64
takes 0.520 ms versus C's 0.471 ms, and AMD64 takes 1.598 ms versus C's 0.998 ms.
At 256x256, ARM64 takes 7.274 ms versus 7.026 ms, and AMD64 takes 11.782 ms versus
15.191 ms. The tiny fresh-process cases still trail C, particularly under
Rosetta; batch averages must not be presented as single-frame latency.

The local evidence is in `benchmarks/output/optimization-final/results.md`
and its JSON, with single-frame samples in `optimization-final-single`.
Reproduce with the comparison command above, adding `--samples 7 --warmups 2`.
The C/ARM64/AMD64 corpus passes 495 checks in each optimization mode, inspecting
102 native executables each time. All 19 focused native/optimizer test programs
and the original 158 C golden tests also pass.


## Memory model merge results

Main `34e4bbf` is merged into the optimized backends at `0740677`. A frozen
pre-merge `4ef9ed7` toolchain is the baseline; C is generated by the merged
compiler (`--c-compiler ./nifty`). The host, flags, sample count, warmups, and
rotation protocol match the measurements above. Median milliseconds per frame,
ten frames per fresh process:

| Image | Target | Before merge | After merge | Current C |
| --- | --- | ---: | ---: | ---: |
| 64x64 | ARM64 | 0.489 | 0.485 | 0.510 |
| 64x64 | AMD64 | 0.796 | 0.800 | 1.050 |
| 256x256 | ARM64 | 7.394 | 7.361 | 7.317 |
| 256x256 | AMD64 | 10.741 | 10.714 | 15.507 |

Before/after batch medians differ by less than 1%. ARM64 remains at C speed;
AMD64 renders the 256x256 image in about 31% less time than matching C through
Rosetta. Single-frame medians remain about 1% or less apart before/after the
merge. At 64x64 the merged ARM64/AMD64 times are 0.531/1.728 ms versus C's
0.508/1.073 ms; at 256x256 they are 7.329/11.737 ms versus 6.979/15.334 ms.
The small fresh-process limitation remains.

Both optimization modes pass 606 corpus checks with 120 native executables
inspected per mode. All 210 C golden/integration checks pass, including memory
fixtures with ASan/UBSan. The 22 focused Nim suites and benchmark runner checks
pass. Allocation-hook tests pass on ARM64 and actual AMD64 through Rosetta,
including moved reallocations, allocation failure, recursive and scoped release,
and unrolled early exits. The raytracer hook case confirms zero owned payload
allocations; runtime setup storage is separate.

Every benchmark image matches exactly; 4/16/64 also match independent references.
Local evidence and reproduction commands are in
`benchmarks/output/memory-merge-final/results.md`, with raw batch and single-frame
samples in `memory-merge-final/results.json` and `memory-merge-single/results.json`.

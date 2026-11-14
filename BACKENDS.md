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
fixed-capacity and growable layouts. Every routine
receives an execution context, argument storage, result destination, and
per-thread arena pointer. User arithmetic, branches, memory accesses, and
routine calls are emitted as machine code; runtime helpers handle containers,
I/O, synchronization, and external library interaction.

The backend currently uses register allocation and target instruction
simplification without importing Nimkey's broader IR optimization pipeline.
This keeps the initial semantic contract small.

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

Native images use the `NIFTYN02` format, which includes ownership metadata.
Rebuild the compiler and runtime templates together after this update, and
re-emit images created with the earlier format.

macOS packaging uses `/usr/bin/codesign` for an ad-hoc signature. ARM64 and
AMD64 execution are tested on macOS, with AMD64 run through Rosetta. Other OS
targets need their own runtime validation; the native runtime currently uses
POSIX threads.

## Validation

```sh
nim r tests/tests.nim
nim r tests/test_semantics.nim
nim r tests/test_backend_engine.nim
nim r tests/test_nativecontainers.nim
nim r tests/test_nativeruntime.nim
nim r tests/test_nativelowering.nim
nim r tests/test_nativereports.nim
nim r tests/test_memoryfiles.nim
nim r tests/test_nativememory.nim
nim r tests/test_native.nim "$PWD/nifty"
```

The cross-backend harness checks the language golden files and additional
numeric, evaluation-order, and arena cases through C, ARM64, and AMD64.
It verifies native executable architecture and builds and runs native programs
with compiler tools removed from `PATH`. C remains a useful independent
reference alongside the expected results.

## Benchmarks

The first benchmark is a float64 port of Nimkey's raytracer, using a bounded
reflection stack in place of recursion. Run `python3 benchmarks/run.py --check`
to compare C, ARM64, and AMD64 where available. Rendering is timed inside the
program; compilation, startup, and pixel formatting are measured separately
or excluded. Every sample is checked against its pixels, and checked-in
Nimkey interpreter images provide independent references at 4, 16, and 64
pixels square. See [benchmarks/README.md](benchmarks/README.md) for settings,
artifacts, and timing details.

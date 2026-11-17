# Nifty - a super static language.

Nifty is a small systems language with Nim-flavored syntax, checked integer
ranges, and statically checked memory and thread access. Fixed-capacity
containers need no heap; growable containers report allocation failure
explicitly. It compiles to C (C99 + pthreads) or native AMD64 and ARM64.

See [spec.md](spec.md) for the language, `examples/` for programs.
The [module guide](docs/modules.md) covers cascading imports, qualification,
aliases, and cached URL sources.
The [embedding guide](docs/embedding.md) describes Bassy-style Nim hosts,
capability-based scripting contexts, and execution limits.
The [document JSON guide](docs/json-document.md) covers the node/byte-pool
parser used by the main [JSON benchmark](benchmarks/JSON.md).
The [path filling benchmark](benchmarks/PATH_FILL.md) rasterizes a line-only A
with antialiased coverage and compares Hand C, Nifty C, and native code.
The [FFI guide](docs/ffi.md) covers foreign buffer contracts, opaque handles,
and checked C-string inputs. The ordinary [console and file library](docs/io.md)
uses that FFI; [file_io.nifty](examples/file_io.nifty) shows a binary file
roundtrip without compiler output builtins.

```nim
var total: int

func double(x: int): int =   # pure: params in, value out, no globals
  return x * 2

proc addTotal(x: int) =      # may touch globals
  total = total + x

thread main() =              # one OS thread, starts at program start
  for i in 0 ..< 10:
    addTotal(double(i))
  echo "total: ", total
```

## Scripting untrusted code

Nifty can be embedded in a Nim program as a scripting language for untrusted
code. The host passes a source string to an isolated VM, which checks it,
compiles it, and runs it.

The isolated VM disables `import` and `extern`. A script can only use the
language itself and the host functions it is given. It cannot open files,
make network calls, or call into C.

Safety comes from the checker, not from runtime traps:

- Every index, division, and integer range is proven safe before the
  script runs.
- Recursion is rejected, so stack and arena use is bounded.
- Shared globals must be accessed under a lock.
- Allocation failure is reported to the script as a value.

There are two backends:

| Backend | Isolation |
|---|---|
| WASM64 | The checker plus the WASM engine. A checker bug stays inside linear memory. |
| Native AMD64 / ARM64 | The checker only. The code runs in the host process with no runtime guard. |

Use WASM64 when the extra layer matters more than speed.

The VM is created with `initHost()`. Imports and externs are off by
default. They can be turned on with `initHost(allowImports = true)` and
`initHost(allowExterns = true)` for trusted code only. See
[docs/embedding.md](docs/embedding.md).

The compiler also runs in the host process, so every resource a script can
grow has a default cap: 1 MB of source, 250,000 tokens, 10,000 globals,
10,000 routines, 10,000 types, 10,000 consts and a syntax depth of 64. All of
them can be changed in the script limits.

## Usage

```
nim r src/nifty.nim examples/sort.nifty    # build and, if no errors, run (default)
```

Or with a compiled `nifty` binary:

```
nim c -d:release -o:nifty src/nifty.nim
./nifty examples/hello.nifty         # run is the default command
./nifty build examples/hello.nifty   # build only
./nifty run examples/hello.nifty     # explicit run
./nifty report examples/queue.nifty  # static RAM / stack / ops report
```

`--opt:speed` (the default) folds checked integer and Boolean literals, removes
constant branches, and expands small constant loops before C or IR generation.
Immutable local integer and Boolean literals propagate through later uses,
including chained `let` declarations and constant loop bounds.
Integer comparisons also fold when the checker's ranges or nonzero facts prove
the result and evaluating their operands has no effects. Calls retain their
evaluation even when their declared result range would settle a comparison.
Source checking still happens first, including in branches that are removed.
IR optimization remains available after lowering to catch constants exposed by
inlining. AMD64 and ARM64 also share exact unsigned constant-division reduction
using a multiply-high operation; WASM and the interpreter retain division for
non-power-of-two constants. `--opt:none` skips these AST and IR optimizations;
the external C compiler still uses `-O2`.

## Tests

Gold master style: each `tests/*/name.nifty` is paired with a `name.txt`
holding the expected result.

- `tests/scripts/` — programs that run; stdout must match the `.txt`
- `tests/errors/` — programs the checker must reject; the `.txt` text must
  appear in the compile error
- `tests/syntax/` — programs the lexer/parser must reject
- `tests/runtime/` — programs that compile but must trap when run

```
nim r tests/tests.nim
```

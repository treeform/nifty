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

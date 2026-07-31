# Nifty - a super static language.

Nifty is nimmy's super-static brother: a tiny systems language with
Nim-flavored syntax where memory, threads, and control flow are all fixed at
compile time. No heap, no recursion, no exceptions, no hidden anything.
It compiles to portable C (C99 + pthreads).

See [spec.md](spec.md) for the language, `examples/` for programs.

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

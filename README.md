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
nim c -d:release -o:nifty src/nifty.nim
./nifty examples/hello.nifty -r
```

## Tests

```
nim r test/tests.nim
```

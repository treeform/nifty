# Nifty — language spec (v0 draft)

Nifty is nimmy's super-static brother. nimmy is a dynamic scripting language;
nifty is a small systems language where everything is fixed at compile time:
memory, threads, stack depth, control flow. Nifty compiles to portable C.

The design goal is *provability through simplicity*: the whole working set of
a program is visible in its source, and the compiler can (eventually) put a
static bound on memory, stack depth, and worst-case iterations per thread.

## Core model

- **The heap is the globals.** All long-lived data lives in global `var`
  declarations of fixed size. There is no allocator, no `alloc`/`free`, no
  hidden allocation anywhere. Globals are zero-initialized.
- **Threads are declared, not created.** Every `thread name() =` declaration
  is one OS thread. All threads start at program start. There is no
  `createThread`, no teardown logic; a program is "start once, run until done
  (or forever)". The program exits when every thread returns.
- **No recursion.** Declare-before-use with no forward declarations makes the
  call graph a DAG by construction; a routine calling itself is rejected.
  Stack depth is therefore statically bounded. (Planned: allow self and
  mutual recursion when every call in the cycle is a provable tail call,
  compiled to loops.)
- **No exceptions, no traps.** Division by zero, array indexing, and
  integer overflow are all proven safe at compile time (see Static proofs);
  the generated C contains no runtime checks and no exit paths. Planned:
  a per-thread error flag / lightweight `Result` values for I/O-style
  errors. There is no unwinding, ever.
- **No pointers.** `var` parameters cover mutable arguments. Long-lived
  references are array indices. (Planned: `index arr` types — indices bound
  to a specific global array, born in-range and never dangling, so
  dereference needs no runtime check.)

## Program structure

A module is a sequence of declarations. There is no top-level executable
code and no special `main`:

```nim
const MaxItems = 10        # compile-time int constant

var total: int             # globals: the entire heap, zero-initialized
var items: array[MaxItems, int]
var itemsLock: Lock

func double(x: int): int = # pure: params in, value out
  return x * 2

proc addItem(v: int) =     # may touch globals
  with itemsLock:
    items[total] = v
    total = total + 1

thread main() =            # one OS thread, starts at program start
  for i in 0 ..< MaxItems:
    addItem(double(i))
  echo "total: ", total
```

## Routines: `func`, `proc`, `thread`

Three kinds of routines, in increasing order of rights:

|                       | `func` | `proc` | `thread` |
| --------------------- | ------ | ------ | -------- |
| read/write globals    | no     | yes    | yes      |
| `var` parameters      | no     | yes    | (no params) |
| call `func`s          | yes    | yes    | yes      |
| call `proc`s          | no     | yes    | yes      |
| `echo`                | no     | yes    | yes      |
| `with`                | no     | yes    | yes      |
| return value          | required | optional | none |
| callable              | yes    | yes    | never    |

A `func` is strict: the only things that go in are its parameters, the only
thing that comes out is its return value. Parameters are read-only (no `var`
params, no assignment to params). A `func` may only call other `func`s —
otherwise it could reach globals through a `proc`. This makes every `func`
referentially transparent: same arguments, same result, no side effects.

A `thread` takes no parameters, returns nothing, and cannot be called. Its
body is the life of one OS thread.

Recursion is rejected in all three: routines must be declared before use,
there are no forward declarations, and a routine may not call itself.

## Types

v0 types:

- `int` — 64-bit signed integer (the full range).
- `lo .. hi` / `lo ..< hi` — a range-restricted int, Pascal-subrange style:
  `var head: 0 ..< QueueSize`, `func double(x: 0 .. 100): 0 .. 200`.
  Bounds are constant expressions. A declared range is an *invariant*:
  every store into the variable/field/element must prove the value fits.
  That makes reads known-bounded — even reads of globals shared between
  threads, because no write anywhere can violate the invariant. Ranges
  are what feed the index and overflow proofs. Zero-initialized locations
  (globals, fields, un-initialized locals) need 0 inside their range.
- `bool` — `true` / `false`.
- `array[N, T]` — fixed length `N` (an integer literal or `const`), element
  type `T`. Indexing `a[i]` is proven in bounds at compile time (see
  Static proofs). Whole-array assignment/copy is not allowed; copy
  elements in a loop.
- `seq[N, T]` — a bounded dynamic array: storage for `N` elements plus a
  runtime length `0 .. N`. Zero-init means empty; only the live part
  `0 ..< len` is ever readable or writable, so dead slots are free (a
  `seq` of `1 .. 5` ints is fine zero-initialized). Value semantics like
  objects. Operations carry proof contracts:
  - `s.len` — the length, typed `0 .. N`; tests on it (`if s.len < N:`)
    create flow facts exactly like ints, invalidated when `s` changes.
  - `s.add(x)` — requires proof there is room; `s.push(x)` returns
    `false` when full instead (backpressure style, usable in helpers).
  - `s.pop()` — requires proof `s` is not empty. `s.clear()`.
  - `s[i]` — requires proof `i < s.len` (pin or test the length first).
  - `for x in s:` — iteration is safe by construction, bounded by `N`
    (termination free); modifying `s` inside is a compile error.
  A mutating method may only appear where it runs exactly once: not in
  `while` conditions (re-run every iteration), not in `elif` conditions
  or `and`/`or` right sides (may be skipped). The first condition of an
  `if` is fine — `if q.push(x):` — and its effect is tracked into every
  branch and the code after. Multiple mutations in one statement are
  fine: evaluation order is defined, left to right.

**Evaluation order is strictly left to right, as written — effects
included.** C leaves subexpression order within a statement unspecified;
nifty does not inherit that. Whenever a statement contains an effectful
call (a proc call or a container mutation), the compiler lowers it to
temporaries in source order in the generated C — reads are captured at
the moment the program text reaches them, effectful calls become their
own sequence points, and `and`/`or` keep their short-circuit via
branches. So `arr[g] = bump()` indexes with the value `g` had *before*
`bump` ran, `a() + b()` calls `a` first, and `s.pop() - s.pop()` pops
left then right — one exact meaning each, at zero runtime cost (the C
optimizer erases the temporaries). The checker's fact tracking follows
the same order, so proofs and execution always agree. Condition side
effects are tracked precisely: the first `if` condition always runs and
its effects persist into every branch; `elif` conditions and `and`/`or`
right sides may only invalidate facts (their calls' write-effects are
forgotten conservatively), and container mutations remain banned there
and in `while` conditions, where execution counts cannot be modeled.
- `string[N]` — a `seq` of bytes (`0 .. 255`, stored as one byte each)
  with literal syntax: `var s: string[40] = "hello"` (the literal must
  fit, checked at compile time), `s.add(", ")`, `s.add(other)` (append,
  with a capacity proof), `echo s`, `s[i]`, `for b in s:`.
- `set[T]` — a set over a *range type*, which needs no capacity
  parameter: the range is the capacity. `set[0 .. 63]` is one 64-bit
  word; `set[0 .. 255]` is 32 bytes (plus a cardinality field). Every
  operation is total — any value of the element type is in-domain and
  there is always room — so sets carry no proof obligations at all:
  `s.incl(x)` / `s.excl(x)` (the value must prove it fits the range,
  like any store), `s.contains(x)` (accepts any int; out-of-range is
  simply false), `s.len` (cardinality), `s.clear()`, and `for x in s:`
  (ascending order, `x` typed as the element range).
- `Lock` — a mutex. Only allowed as a global; only usable via `with`.
- `object` — a static struct, exactly like C:

  ```nim
  object Vec2 =
    x: int
    y: int

  object Rect =
    pos: Vec2
    size: Vec2
  ```

  Nothing grows, everything is defined: fields are `int`, `bool`, arrays,
  or other objects (no `Lock`). A type can only refer to types declared
  *above* it — declare-before-use for types — so recursive types, and
  therefore unknown sizes, are impossible by construction. Objects have C
  value semantics: assignment and non-`var` parameters copy (a fixed,
  compile-time-known cost), `var` parameters pass by pointer. Field access
  is `a.b`, nests freely with indexing (`particles[i].pos.x`). Objects are
  zero-initialized. There are no constructors and no literals in v0:
  declare, then assign fields.
- String literals appear as `echo` arguments and anywhere a `string[N]`
  is expected (they must fit, checked at compile time).

Planned types:

- **Typed indices** `index arr` — sugar for `0 ..< len(arr)` plus
  provenance, so an index cannot be used on the wrong array.
- **Wildcard generics over builtins only** — `proc sort(arr: var array)` or
  `array[N, T]` with `N`, `T` binding implicitly at the call site, checked
  per instantiation, monomorphized. Only builtin type constructors are
  generic; user code cannot declare new generic types (Go-before-1.18 rule).

## Statements

- `var name: T` / `var name = expr` / `let name = expr` — locals. `let` is
  immutable. Shadowing is not allowed.
- `name = expr`, `a[i] = expr` — assignment.
- `if cond: ... elif cond: ... else: ...`
- `for i in lo ..< hi:` / `for i in lo .. hi:` — bounded by construction;
  `i` is immutable; bounds are evaluated once.
- `for x in s:` — iterate a seq or string; `x` is an immutable copy of
  each live element. Safe by construction: no index, no proof, bounded
  by the capacity.
- `while cond:` — must be provably bounded. Either the compiler
  recognizes induction — a finite-ranged local that strictly steps toward
  a bound on every iteration (`i = i + 1` at the top level of the body),
  or halves toward a zero-exit condition (`d = d / 2` under
  `while d != 0:`) — or the loop carries an explicit cap:
  `while cond max N:`, which is bounded *by construction*: the loop also
  stops after N iterations (no trap, no unbounded spin; worst case is
  exactly N passes). Together with no-recursion this gives a static
  worst-case iteration count per thread (static gas / WCET).
  Note: facts from the negated condition apply after the loop only when
  it cannot exit another way (no `break`, no `max` cap).
- `loop:` — infinite loop, allowed **only at the top level of a `thread`
  body**. This is the event/server loop; everything inside it must
  (eventually) be bounded. `break` is allowed.
- `with x:` — a scoped resource block. For a `Lock`, it is also the only
  way to touch shared globals: a global accessed by two or more threads
  must have every access (reads included) inside `with` blocks that all
  hold one common lock — the checker infers which lock protects which
  global from the access sites and rejects inconsistent locking.
  `with x:` desugars to `start(x)`, the block body, then `end(x)`:
  - if `x` is a `Lock`, `start`/`end` are builtin: acquire and release the
    mutex;
  - for any other type `T`, the program must define `proc start(v: var T)`
    and `proc end(v: var T)`, declared before the `with` statement.
  `return` and `break` may not jump out of a `with` block — `end` would
  never run — and the compiler rejects them. `with` is not allowed in
  `func` (start/end are side effects).
- `return expr` / `return`
- `break`
- `echo a, b, c` — writes a line to stdout. Accepts `int`, `bool`, and
  string literals.
- `discard expr` — explicitly drop a value. Silently ignoring a returned
  value is an error.

## Static proofs

Nifty proves safety at compile time instead of checking it at run time.
There is no gradual fallback: what cannot be proven does not compile, and
the user adds a test the prover can see. Three proofs are implemented, all
running on one engine — interval analysis. Every int expression carries a
proven `[lo, hi]` range (plus a separate nonzero bit, since an interval
cannot express "anything but zero").

**Where ranges come from:**

- literals and consts: `4` is `[4, 4]`;
- declared range types: reading `var head: 0 ..< QueueSize` gives
  `[0, QueueSize-1]` anywhere, even across threads — the range is an
  invariant every write must prove;
- `for i in a ..< b:` — the loop variable is `[a.lo, b.hi - 1]`, immutable;
- flow tests on locals: `if i < 5:` clamps in the then-branch, the else
  branch gets the negation, `elif` chains accumulate negations,
  `if x > 100: return` clamps everything after (guard style), `and` is
  short-circuit-aware (`j >= 0 and data[j] > key` checks `data[j]` under
  `j >= 0`), and branches rejoin by interval hull — so clamping works:

  ```nim
  var nx = pos + vel        # may be out of range
  if nx > 1000: nx = 1000   # after the if: proven <= 1000
  ```

- arithmetic: ranges combine through `+ - * / %` exactly.

**What invalidates a flow fact:** assigning something wider, passing the
variable as a `var` argument, using it as a `with` target, calling a
routine that may write it (including a `with` block's `start`/`end`), or
entering a loop whose body modifies it (the loop condition re-proves what
it can on every entry). Var params never carry flow facts — they may
alias anything. Aliasing itself is restricted: a global cannot be passed
as a `var` argument to a routine that also touches that global directly,
and a `var` param cannot be forwarded to a routine touching a
type-compatible global — writes through the alias would make the
callee's facts lie.

One loop exception — **accumulator induction**: in any loop with a proven
trip bound (`for`, and `while` via its termination bound), a local
assigned *only* as `v = v + e` / `v = v - e` (with `e` independent of `v`
and the sites outside nested loops) keeps a widened fact instead of
losing everything: its entry value plus `tripCount ×` the per-iteration
delta, clamped to its declared range, where `e`'s bound comes from
declared ranges, consts, and the loop variable only. So this proves with
zero annotations:

```nim
var sum = 0
for i in 0 ..< 5:
  sum = sum + i     # proven: sum stays within 0 .. 20
echo sum
```

The widened fact survives the loop, so downstream arithmetic proves too.
Accumulators inside `loop` (infinite by design) still need a guard —
there is no trip count to widen by.

**Globals and threads.** The checker computes, from the static call graph,
which threads touch each global:

- **Thread-owned** (accessed by at most one thread): proven exactly like a
  local — tests refine it, stores update it. Most globals in a
  single-threaded program just work.
- **Shared** (accessed by two or more threads, written by at least one):
  every access — *reads too*, since an unlocked read can see a torn or
  mid-update value and two reads can disagree — must be inside a `with`
  block holding one common lock. This is checked, not trusted. Inside
  that lock block the global proves like a local again (no other thread
  can slip in while the lock is held); the facts die when the lock is
  released. Outside the lock the global cannot be touched at all.

This makes the queue idiom both natural and proven:

```nim
with queueLock:
  if count < QueueSize:
    queue[tail] = v
    count = count + 1   # proven: count is ours while we hold the lock
```

### The three proofs

1. **Division**: every `/` and `%` divisor must be proven nonzero
   (`if b != 0:`, `b > 0`, a positive range type, ...). The
   `int64.min / -1` case must also be excluded.
2. **Indexing**: every `a[i]` must prove `i` inside `0 ..< len`. A
   provably-bad index (`a[6]` on `array[5, T]`) is reported as always out
   of bounds; an unprovable one demands a test. `for` loops over
   `0 ..< len` prove for free; ranged index variables (`var head:
   0 ..< QueueSize`) make even cross-thread indexing check-free.
3. **Overflow**: every `+ - * /` (and unary `-`) must prove its result
   fits int64. Full-range `int + int` does not compile — narrow a range
   or guard first (`if sum <= 900: sum = sum + x`). This is what makes
   the interval analysis honest: ranges cannot silently wrap.
4. **Termination**: every `while` must be provably bounded — induction
   or an explicit `max N` cap (see Statements). `loop` at the top of a
   thread is the only infinite control flow in the language.

Stores complete the system: assigning to (or initializing, returning into,
or passing as an argument for) a ranged location must prove the value fits
its declared range. `var` parameters require the exact same range on both
sides, since writes flow both ways.

**The payoff:** the generated C contains no runtime checks of any kind —
no bounds checks, no division checks, no overflow checks, no trap-and-exit
paths. `queue[tail]` compiles to `g_queue[g_tail]`. What remains at run
time is exactly the program.

## Compilation model

Nifty compiles one module to one portable C file (C99 + pthreads):

| nifty                  | C                                          |
| ---------------------- | ------------------------------------------ |
| global `var`           | `static` global (zero-initialized)         |
| `const`                | `static const int64_t`                     |
| `func` / `proc`        | `static` function                          |
| `thread foo`           | `static void *t_foo(void*)` + `pthread_create`/`join` in generated `main` |
| `object Name =`        | `typedef struct`                           |
| `with` on a `Lock`     | `pthread_mutex_t` lock–unlock pair         |
| `with` on other types  | `start(x)` / `end(x)` calls around the block |
| `a[i]`                 | bare C indexing (proven safe, no checks)   |
| `/`, `%`               | bare C `/` and `%` (proven safe, no checks) |
| `lo .. hi` range types | `int64_t` (ranges exist only at compile time) |
| `var` param (scalar)   | pointer parameter                          |
| array param            | decayed pointer, `const` in C unless `var` |

Because declare-before-use is required in nifty, the generated C needs no
forward prototypes — definitions appear in call order.

The host compiles; the target only executes. There is no runtime beyond
libc + pthreads and a few line-tagged trap helpers.

## The report

`nifty report file.nifty` prints the program's static resource footprint —
numbers most toolchains can only measure or guess, derived here from
properties the checker proves:

- **globals** — the whole heap, byte-exact per global (C layout, with
  struct padding), plus the lock count.
- **stack** — worst case per thread: no recursion means the call graph is
  a DAG, so the deepest chain of frames is exact; frame bytes are a
  language-level estimate (locals + params + 16 bytes overhead). The
  chain itself is printed (`consumer -> tryPop`).
- **ops** — worst-case abstract operation count per thread: every loop
  has a proven trip bound, so each thread's outer `loop` pass (or its
  whole body) has a finite worst case. Multiply by a target's
  cycles-per-op to approximate WCET; feed it to the watchdog.

## Grammar (v0, informal)

```
module      = { constDecl | globalDecl | objectDecl | routineDecl }
constDecl   = "const" ident "=" constExpr NL
globalDecl  = "var" ident ":" type NL
objectDecl  = "object" ident "=" NL INDENT { fieldDecl } DEDENT
fieldDecl   = ident { "," ident } ":" type NL
routineDecl = ("func" | "proc" | "thread") ident "(" [params] ")" [":" type] "=" body
params      = param { "," param }
param       = ident { "," ident } ":" ["var"] type
type        = "int" | "bool" | "Lock" | "array" "[" (int | constIdent) "," type "]"
            | objectTypeName | constExpr (".." | "..<") constExpr
body        = simpleStmt NL | NL INDENT { stmt } DEDENT
stmt        = simpleStmt NL | ifStmt | whileStmt | forStmt | loopStmt | withStmt
whileStmt   = "while" expr ["max" constExpr] ":" body
simpleStmt  = varDecl | assign | callStmt | "return" [expr] | "break"
            | "echo" expr { "," expr } | "discard" expr
expr        = orExpr; standard precedence:
              or < and < not < (== != < <= > >=) < (+ -) < (* / %) < unary - < postfix
postfix     = atom { "[" expr "]" | "." ident | "(" [args] ")" }
```

Comments run from `#` to end of line. Indentation is spaces only.

## v0 implementation status

Implemented: everything above not marked *planned* — `const`/`var` globals,
`object` types and range types with declare-before-use,
`func`/`proc`/`thread` with the full rights table, no-recursion via
declare-before-use, `if`/`while`/`for`/`loop`/`with` (Lock and start/end
protocol), locks, the three static proofs (division, indexing, overflow)
via interval analysis with zero runtime checks in the generated C, `echo`,
`discard`, C output, generated `main` with thread spawn/join.

Not yet implemented: `index` types, wildcard generics, `map`/`queue`
builtins (same recipe as seq: fixed storage + range-typed state + op
contracts), tail-call recursion, the per-thread error flag,
deterministic floats and fixed-point (`fixed[lo .. hi, step]` — a scaled
ranged int, so the existing proofs apply directly), int width from ranges
(seq elements are still 8 bytes each; string data is already 1 byte).

# Nifty — language spec (v0 draft)

Nifty is nimmy's super-static brother. nimmy is a dynamic scripting language;
nifty is a small systems language where everything is fixed at compile time:
memory, threads, stack depth, control flow, evaluation order. Nifty compiles
to portable C.

The design goal is *provability through simplicity*: the whole working set
of a program is visible in its source, and the compiler puts a static bound
on memory, stack depth, and worst-case iterations per thread. What cannot be
proven does not compile; what compiles cannot trap.

## Core model

- **The heap is the globals.** All long-lived data lives in global `var`
  declarations of fixed size. There is no allocator, no `alloc`/`free`, no
  hidden allocation anywhere. Globals are zero-initialized.
- **Threads are declared, not created.** Every `thread name() =` declaration
  is one OS thread. All threads start at program start. There is no
  `createThread`, no teardown logic; a program is "start once, run until
  done (or forever)". The program exits when every thread returns.
- **No recursion.** Declare-before-use with no forward declarations makes
  the call graph a DAG by construction; a routine calling itself is
  rejected. Stack use is therefore statically bounded — and big locals
  don't even use the C stack (see Big locals). (Planned: allow self and
  mutual recursion when every call in the cycle is a provable tail call,
  compiled to loops.)
- **No exceptions, no traps, no runtime checks.** Division by zero, out-of-
  bounds indexing, integer overflow, non-termination of `while` loops, and
  data races are all proven impossible at compile time (see Static proofs).
  The generated C contains no checks and no exit paths. There is no
  unwinding, ever.
- **Errors are optionals at the boundary.** Internal code is total: a
  `func` provably terminates and cannot fail. Fallibility exists only
  where the outside world can say no (sensors, input, hardware), expressed
  as flow-typed optionals `T?` — see Types. There is no error flag, no
  exception, no result-wrapper ceremony.
- **Evaluation order is strictly left to right, as written — effects
  included.** C leaves subexpression order unspecified; nifty does not
  inherit that (see Evaluation order).
- **No pointers.** `var` parameters cover mutable arguments. Long-lived
  references are array indices. (Planned: `index arr` types — indices
  bound to a specific global array, born in-range and never dangling.)

## Imports

`import name` at the top of a file splices `name.nifty` (resolved next
to the importing file) into the program — once, no matter how many
files import it. Whole-program, fresh, every time: the SQLite-
amalgamation model, and in nifty it is not even a trade-off, because
every proof (thread ownership, lock inference, arenas, WCET) is a
whole-program analysis — separate compilation was never possible.

- Imports come before any declaration; the import graph must be a DAG
  (a cycle is a compile error — the no-recursion principle, one level
  up). Splice order is import order, so declare-before-use holds across
  files and all proofs work unchanged.
- One namespace, no visibility modifiers. A cross-file name collision is
  the ordinary duplicate-name error. Encapsulation as *safety* is the
  checker's job (races, ranges, container internals are already
  unbreakable); encapsulation as *communication* is a naming convention.
- Errors report `file.nifty:line` across splices.

## Program structure

A module is a sequence of declarations. There is no top-level executable
code and no special `main`:

```nim
const MaxItems = 10        # compile-time int constant

var total: 0 .. 1000       # globals: the entire heap, zero-initialized
var items: array[MaxItems, int]
var itemsLock: Lock

func double(x: 0 .. 100): 0 .. 200 =  # pure: params in, value out
  return x * 2

proc addItem(i: 0 ..< MaxItems, v: int) =  # may touch globals
  with itemsLock:
    items[i] = v

thread main() =            # one OS thread, starts at program start
  for i in 0 ..< MaxItems:
    addItem(i, double(i))
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

A `func` is strict: the only things that go in are its parameters, the
only thing that comes out is its return value. Parameters are read-only
(no `var` params, no assignment to params, not even to their fields or
elements). A `func` may only call other `func`s — otherwise it could
reach globals through a `proc`. This makes every `func` referentially
transparent — and, with the termination proof, *total*: same arguments,
same result, always returns, never fails.

A `thread` takes no parameters, returns nothing, and cannot be called.
Its body is the life of one OS thread.

Recursion is rejected in all three: routines must be declared before use,
there are no forward declarations, and a routine may not call itself.

Routines can return values of any size — arrays, big strings, big
objects. C cannot return arrays (and returning a big struct by value
would land a copy on the C stack), so any return of an array or of a
value over the arena threshold compiles to **destination passing**: the
signature becomes `void f(params..., T *ret)` and the caller passes
where the result goes; the callee fills it in place. `return inner(x)`
forwards the destination straight through — a call chain builds the
result exactly once, with zero copies. The one rule: a big-returning
call must be stored straight into a variable (`var x = f(...)`,
`let x = f(...)`, or `x = f(...)`) — it cannot sit inside a larger
expression, because there would be nowhere for the result to live.
Assigning one straight into a global the callee itself accesses is
rejected (the callee would be writing its own input); store to a local
first.

## Generics: `$` substitution variables

A routine becomes generic by using `$name` variables in its parameter
types: `$N` in a size position binds a compile-time integer, `$T` in an
element position binds a type — including its exact range, which is the
point: nifty's "element types" are the whole space of ranges, so
`sort(data: var array[$N, $T])` accepts an `array[8, 0 .. 9]` exactly
(a `var` parameter demands the precise range; only a bound `$T` can
supply it).

The rules are few and mechanical:

- A `$name` **binds** at its first occurrence in the parameter list,
  left to right. Every later occurrence — another parameter, the return
  type, the body — **references** that binding and must agree:
  `func dot(a: array[$N, int], b: array[$N, int])` states in the
  signature that both arrays are the same size, and a mismatched call
  fails with `$N is bound to both 3 and 4`.
- In the body, a size `$N` is a `const`: usable in ranges
  (`var i: 1 .. $N`), expressions (`while i < $N`), and local types
  (`var copy: seq[$N, $T]`). A type `$T` is a type, and exposes its
  bounds as constants: `$T.lo`, `$T.hi`.
- Return types are expressions over the bindings — sizes are already
  const-expressions, so arithmetic falls out:
  `func merge(a: seq[$N, $T], b: seq[$M, $T]): seq[$N + $M, $T]`, or the
  proof-carrying `func sum(data: array[$N, $T]): $N * $T.lo .. $N * $T.hi`.

**Instantiation is splice-and-prove.** A generic is kept as its token
slice (the same mechanism as imports). Each call binds the `$names`
from the argument types, substitutes them into the tokens, reparses,
and then checks and **proves** the result as an ordinary routine — with
concrete constants, once per distinct binding (later identical calls
reuse the instance). There is no separate generic type system: the
body's proof obligations, evaluated per instance, are the constraint
language, exactly as strict as the body requires. Proof failures name
the binding: `... while instantiating 'sum' with $N = 4, $T = int
at main.nifty:10`.

Each instance monomorphizes to one C function and one report entry
(`sort__5_0_9`). Restrictions: threads cannot be generic; a generic may
not call itself (no recursion through other bindings); and a generic
routine may not touch globals, directly or through callees — the
thread-ownership and lock proofs run before any instantiation exists,
so a generic's global footprint must be empty. Pass values through
parameters — which is what a reusable routine should do anyway.

## Types

- `int` — 64-bit signed integer (the full range).
- `lo .. hi` / `lo ..< hi` — a range-restricted int, Pascal-subrange
  style: `var head: 0 ..< QueueSize`, `func double(x: 0 .. 100): 0 .. 200`.
  Bounds are constant expressions. A declared range is an *invariant*:
  every store into the variable/field/element must prove the value fits.
  That makes reads known-bounded — even reads of globals shared between
  threads, because no write anywhere can violate the invariant. Ranges
  feed the index and overflow proofs. Zero-initialized locations
  (globals, fields, un-initialized locals) need 0 inside their range.
- `bool` — `true` / `false`.
- **Hardware integers** `int8 uint8 int16 uint16 int32 uint32 int64
  uint64` — ordinary ranges (`uint8` *is* `0 .. 255`) that also fix the
  storage width: object fields, container elements, and globals hold
  the hardware size, so structs are byte-compatible with C and the
  report tells the truth. Arithmetic still runs in the one int64 proof
  engine (no C promotion rules, no width-dependent overflow: the
  generated C widens operands to 64 bits, so `int32 * int32` is exact).
  `uint64` is stored as 8 unsigned bytes for binary compatibility, but
  nifty values stay within `0 .. int64.high`. There is no wraparound
  anywhere: exceeding a range is the ordinary overflow error.
- `char` — one byte, always: a UTF-8 code unit (same range and storage
  as `uint8`). A Unicode code point may span several chars; strings are
  always UTF-8 bytes. There is no Unicode-codepoint char type.
- `float32` / `float64` — IEEE floats, **outside the proof engine**:
  data values for graphics, DSP, and FFI. They carry no ranges and no
  proof obligations, and they cannot trap: `1.0 / 0.0` is `inf`,
  `0.0 / 0.0` is NaN — values, not exits. Structural safety holds
  because indices, loop bounds, and termination counters are ints, so
  floats can never reach a proof. No implicit conversions: mixing
  int and float (or float32 and float64) is a compile error; convert
  with `float64(x)` / `float32(x)`, and come back through `.toInt` —
  the one float-to-int door, saturating and NaN-safe (NaN becomes 0;
  a bare C cast of an out-of-range float is undefined behavior, so
  nifty never emits one). Its result is a full-range int: guard before
  use. Float literals (`1.5`, `2.5e3`) are widthless and slot into
  either float type, like int literals slot into ranges. `%` is not
  defined for floats; `==` is IEEE equality (NaN never equals).
- `array[N, T]` — fixed length `N` (an integer literal or `const`),
  element type `T`. Indexing `a[i]` is proven in bounds at compile time.
  Arrays are values like everything else: whole-array assignment and
  initialization copy (a `memcpy` in the generated C), and a copy from a
  differently-ranged source must prove the element ranges fit.
- `object` — a static struct, exactly like C:

  ```nim
  object Vec2 =
    x: -1000 .. 1000
    y: -1000 .. 1000
  ```

  Nothing grows, everything is defined. A type can only refer to types
  declared *above* it — declare-before-use for types — so recursive
  types, and therefore unknown sizes, are impossible by construction.
  Objects have C value semantics: assignment and non-`var` parameters
  copy (a fixed, compile-time-known cost), `var` parameters pass by
  pointer. Field access `a.b` nests freely with indexing
  (`particles[i].pos.x`). Zero-initialized; no constructors or literals
  in v0: declare, then assign fields.
- `Lock` — a mutex. Only allowed as a global; only usable via `with`.
- String literals appear as `echo` arguments and anywhere a `string[N]`
  is expected (they must fit, checked at compile time).

### Containers

All containers are bounded, value-semantic, zero-init-is-empty, and
sealed builtins (the compiler owns their representation, so it can prove
their contracts and optimize freely). Only the live part of a container
is ever readable, so dead slots are free — a `seq` of `1 .. 5` ints is
fine zero-initialized. `.len` reads create flow facts exactly like ints
(`if s.len < N:`), invalidated when the container changes.

- `seq[N, T]` — a bounded dynamic array: storage for `N` elements plus a
  length `0 .. N`.
  - `s.add(x)` — requires proof of room; `s.push(x)` returns `false`
    when full instead (backpressure style, usable in helpers).
  - `s.pop()` — from the *end* (stack style); requires nonempty proof.
  - `s[i]` — requires proof `i < s.len` (pin or test the length first).
  - `s.clear()`; `for x in s:` — safe by construction, bounded by `N`.
- `string[N]` — a `seq` of bytes (`0 .. 255`, stored one byte each) with
  literal syntax: `var s: string[40] = "hello"`, `s.add(", ")`,
  `s.add(other)` (append, with a capacity proof), `echo s`, `s[i]`,
  `for b in s:`.
- `set[T]` — a set over a *range type*; no capacity parameter, the range
  IS the capacity (`set[0 .. 63]` is one 64-bit word plus a cardinality
  field). Every operation is total: `incl`/`excl` (the value proves it
  fits the range, like any store), `contains` (any int; out-of-range is
  simply false), `len`, `clear`, `for x in s:`.
- `queue[N, T]` — a FIFO ring buffer (internal head, invisible wrap).
  `q.push(x)` returns `false` when full — the bounded capacity IS the
  backpressure. `q.pop()` takes from the *front* behind a nonempty
  proof; `q.add(x)` is the strict push; `for x in q:` runs front to
  back. No `q[i]` — queues are streams, not tables.
- `map[lo .. hi, V]` (dense) — when the key is a range, the range IS the
  capacity: one value slot per possible key plus a presence bitset.
  Every operation is total: `put` always has room, `get(k, fallback)`,
  `contains` (out-of-range is false), `remove` (absent is a no-op).
- `map[N, K, V]` (sparse) — sorted entries with binary search; keys are
  ints/ranges or `string[N]` (bytewise lexicographic, shorter-first on
  prefix ties). `m.put(k, v): bool` inserts-or-updates, `false` when
  full-and-absent; `m[k] = v` is the strict write — prove
  `m.contains(k)` (update) or `m.len < N` (insert) first. Vacated slots
  are zeroed, so a map's bytes are a canonical function of its contents.
- **Map reading rule** (both shapes): `m[k]` requires a **proven
  containment** — established by `if m.contains(k):`, a strict write, a
  total dense `put`, or iteration (`for k, v in m:` proves the loop key
  by construction). `m.get(k, fallback)` is the total escape hatch.
  Map elements are values, not places: `m[k]` cannot be a `var` argument
  or an iteration base.
- **One iteration law**: `set` and both maps iterate **ascending by
  key** — iteration order is a function of contents, never of insertion
  history. Seq/string/queue iterate in element order.

### Optionals

`T?` is a flow-typed optional: a value that may be absent. Usable
anywhere a regular type is — variables, params, returns, object fields,
container elements and map values; only `set` elements and map *keys*
stay non-optional (domains, not values).

- `none` is the absent value — for *missing*, not for failure. A plain
  value converts implicitly (it is self-evidently present). Zero-init is
  `none`.
- Reading requires **proven presence**: `if r.ok:` grants it, and then
  `r` simply *is* its base type — no unwrap, no projection:
  `lastFix.lat`, not `lastFix.value.lat`. Guard style
  (`if not r.ok: return`) and definite assignment grant too; assigning
  `none` or an unproven optional, `var` arguments, lock release, and
  loops kill the fact.
- Field paths carry facts (`if p.fix.ok:` proves `p.fix`). Container
  elements have no stable name — bind first (`let r = s[i]; if r.ok:`)
  or read totally with `.or(fallback)`, which works on any optional
  expression.
- Using an unproven optional is a compile error — the same proof
  obligation family as division, indexing, and map reads. The discard
  rule forces returned optionals to be consulted.

Planned types: typed indices (`index arr` — a range plus provenance),
absence *reasons* (`T ? codeRange` with a provable `.error`),
fixed-point (`fixed[lo .. hi, step]` — a scaled ranged int),
deterministic floats. Generics exist — see Generics above.

## Statements

- `var name: T` / `var name = expr` / `let name = expr` — locals. `let`
  is immutable. Shadowing is not allowed. Mutability is strategic, not
  cosmetic: a `var` that is never modified is a compile error ("declare
  it with let instead of var"), and so is a `var` parameter the routine
  never writes. Reading a declaration tells you the truth: `let` never
  changes, `var` definitely does. (`start`/`end` are exempt from the
  `var`-parameter rule — the `with` protocol imposes their signature.)
- `block:` — a bare scope inside a routine. Locals declared in a block
  die with it; sibling blocks may reuse names. Big locals in sibling
  blocks share the same arena bytes (the frame is the high-water mark,
  not the sum), so blocks are also a RAM tool: scoped scratch sections
  inside one long, readable routine.
- `name = expr`, `a[i] = expr`, `o.f = expr`, `m[k] = expr` — assignment.
- `if cond: ... elif cond: ... else: ...`
- `for i in lo ..< hi:` / `for i in lo .. hi:` — bounded by construction;
  `i` is immutable; bounds are evaluated once.
- `for x in c:` — iterate a seq, string, set, or queue; `for k, v in m:`
  (or `for k in m:`) iterates a map. Loop variables are immutable
  copies; modifying the container inside is a compile error; bounded by
  capacity, so termination is free.
- `while cond:` — must be provably bounded. Either the compiler
  recognizes induction — a finite-ranged local that strictly steps
  toward a bound on every iteration (`i = i + 1` at the top level of the
  body), or halves toward a zero-exit condition (`d = d / 2` under
  `while d != 0:`) — or the loop carries an explicit cap:
  `while cond max N:`, bounded *by construction*: the loop also stops
  after N iterations (no trap; worst case is exactly N passes). Facts
  from the negated condition apply after the loop only when it cannot
  exit another way (no `break`, no `max` cap).
- `loop:` — infinite loop, allowed **only at the top level of a `thread`
  body**. The event/server loop; everything inside must be bounded.
  `break` is allowed.
- `with x:` — a scoped resource block; desugars to `start(x)`, the body,
  then `end(x)`. For a `Lock`, `start`/`end` are the builtin mutex
  acquire/release — and `with` is the only way to touch shared globals
  (see Static proofs). For any other type `T`, the program defines
  `proc start(v: var T)` and `proc end(v: var T)`. `return` and `break`
  may not jump out of a `with` block — `end` would never run. Not
  allowed in `func`.
- `return expr` / `return` / `break`
- `echo a, b, c` — writes a line to stdout. Accepts `int`, `bool`,
  `string[N]`, and string literals. Arguments are evaluated left to
  right (hoisted to temporaries in the generated C).
- `discard expr` — explicitly drop a value. Silently ignoring a returned
  value is an error.

## Smallest scope (Power of 10, rule 6)

Scope is strategic, like mutability: a declaration's placement must
tell the truth about its lifetime. Where the truth is provable, wider
than needed is a compile error:

- A global used by **nothing** is an error: remove it.
- A global used by exactly **one thread** is an error: threads run
  once, so a local of the thread has identical semantics (same
  zero-init, same persistence across `loop` iterations, arena for the
  big ones). Same for a **lock** used by a single thread — it protects
  nothing.
- A global used by exactly **one proc** that provably overwrites it
  before every read is an error: cross-call persistence is
  unobservable, so it is a local (a scratch buffer masquerading as
  state). If any path reads first, it is honest cross-call state and
  stays a global — `seen = seen + 1` counters are untouched.
- A local (with a zero or literal initializer — timing-independent by
  construction) whose every use sits inside one block, one `with`, or
  one `if` branch must be declared there. Inside one **loop** body it
  must move only when it provably never carries a value across
  iterations — accumulators stay outside.

The nifty scorecard for the rest of the Power of 10: rules 1, 2, 3, 8,
9 hold by construction (no goto/recursion, proven loop bounds, no
allocation, no preprocessor, no pointers); rule 5's assertions became
compile-time proof obligations on every division, index, store, and
loop; rule 7 is the discard rule plus ranged parameters; rule 10 has no
warning tier to negotiate with. Rule 4 (short functions) is rejected
deliberately: verification here is the checker's job, not the
reviewer's eyeball span, and `block:` gives scoped sections inside one
long readable routine.

## Locks: order and honesty

Data-race freedom was already proven (every access to a shared global
must hold its one common lock). Two more lock rules close the story:

- **Deadlock freedom by total order.** Locks may only be acquired in
  declaration order: `with second:` while `first` is held is fine only
  if `first` is declared first. The rule is checked lexically and
  across calls (a proc's whole transitive lock set must sort after
  every lock held at the call site), and re-acquiring a held lock is an
  error outright (pthread mutexes are not recursive). A waits-for cycle
  needs two threads acquiring two locks in opposite orders; a total
  order makes that unrepresentable, so deadlock is impossible — the
  same shape of argument as no-recursion, one level up.
- **Pointless locks are errors.** A lock used by one thread protects
  nothing. A lock under which nothing shared is ever touched (and no
  output is serialized — `echo` under a lock counts as intentional
  serialization) only costs cycles: remove it.

`nifty report` prints the lock story it proved: each lock, what it
protects, and which routines take it
(`qLock: protects q; used by consumer, producer`).

## Evaluation order

**Strictly left to right, as written — effects included.** Whenever a
statement contains an effectful call (a proc call or a container
mutation), the compiler lowers it to temporaries in source order: reads
are captured at the moment the program text reaches them, effectful
calls become their own sequence points, and `and`/`or` keep their
short-circuit via branches. So `arr[g] = bump()` indexes with the value
`g` had *before* `bump` ran, `a() + b()` calls `a` first, and
`s.pop() - s.pop()` pops left then right — one exact meaning each, at
zero runtime cost (the C optimizer erases the temporaries). The
checker's fact tracking follows the same order, so proofs and execution
always agree.

Condition side effects are tracked precisely: the first `if` condition
always runs and its effects persist into every branch and the code
after; `elif` conditions and `and`/`or` right sides may only invalidate
facts (their calls' write-effects are forgotten conservatively). A
container mutation may only appear where it runs exactly once: not in
`while` conditions (re-run every iteration), not in `elif` conditions or
`and`/`or` right sides (may be skipped). The first condition of an `if`
is fine — `if q.push(x):` — and multiple mutations in one statement are
fine: the order is defined.

## Static proofs

Nifty proves safety at compile time instead of checking it at run time.
There is no gradual fallback: what cannot be proven does not compile,
and the user adds a test the prover can see.

The engine is interval analysis: every int expression carries a proven
`[lo, hi]` range (plus a nonzero bit, since an interval cannot express
"anything but zero"), and a second kind of fact — **predicates** — for
containment (`m@k`) and presence (`r@ok`).

**Where facts come from:**

- literals and consts: `4` is `[4, 4]`;
- declared range types: reading `var head: 0 ..< QueueSize` gives
  `[0, QueueSize-1]` anywhere, even across threads — the range is an
  invariant every write must prove;
- `for i in a ..< b:` — the loop variable is `[a.lo, b.hi - 1]`;
- flow tests: `if i < 5:` clamps the then-branch, the else branch gets
  the negation, `elif` chains accumulate negations, guards
  (`if x > 100: return`) clamp everything after, `and` is
  short-circuit-aware, and branches rejoin by interval hull (predicates
  join all-or-nothing: kept only if proven on every path) — so clamping
  works:

  ```nim
  var nx = pos + vel        # may be out of range
  if nx > 1000: nx = 1000   # after the if: proven <= 1000
  ```

- container tests: `if s.len < N:`, `if m.contains(k):`, `if r.ok:`;
- arithmetic: ranges combine through `+ - * / %` exactly.

**What invalidates a fact:** assigning something wider, passing the
variable as a `var` argument, using it as a `with` target, mutating it
through a method, calling a routine that may write it (including a
`with` block's `start`/`end`), releasing the lock that protected it, or
entering a loop whose body modifies it (the loop condition re-proves
what it can on every entry). Var params never carry flow facts — they
may alias anything. Aliasing itself is restricted: a global cannot be
passed as a `var` argument to a routine that also touches that global
directly, and a `var` param cannot be forwarded toward a routine
touching a type-compatible global.

**Accumulator induction** — the one loop exception: in any loop with a
proven trip bound, a local assigned *only* as `v = v + e` / `v = v - e`
(with `e` independent of `v`, outside nested loops) keeps a widened
fact: its entry value plus `tripCount ×` the per-iteration delta,
clamped to its declared range. So this proves with zero annotations:

```nim
var sum = 0
for i in 0 ..< 5:
  sum = sum + i     # proven: sum stays within 0 .. 20
echo sum
```

The widened fact survives the loop. Accumulators inside `loop` (infinite
by design) still need a guard — there is no trip count to widen by.

**Globals and threads.** The checker computes, from the static call
graph, which threads touch each global:

- **Thread-owned** (accessed by at most one thread): proven exactly like
  a local — tests refine it, stores update it.
- **Shared** (accessed by two or more threads, written by at least one):
  every access — *reads too*, since an unlocked read can be torn or
  disagree with the next one — must be inside `with` blocks holding one
  common lock, which the checker infers from the access sites. Inside
  the lock block the global proves like a local (no other thread can
  slip in); the facts die when the lock is released. Outside the lock
  the global cannot be touched at all. Programs are data-race-free by
  construction.

```nim
with queueLock:
  if count < QueueSize:
    queue[tail] = v
    count = count + 1   # proven: count is ours while we hold the lock
```

### The proof obligations

1. **Division**: every `/` and `%` divisor must be proven nonzero
   (`if b != 0:`, `b > 0`, a positive range type). The `int64.min / -1`
   case must also be excluded.
2. **Indexing**: every `a[i]` must prove `i` inside the valid range —
   `0 ..< N` for arrays, `0 ..< len` (the live part) for seq/string. A
   provably-bad index (`a[6]` on `array[5, T]`) is reported as always
   out of bounds; an unprovable one demands a test. `for` loops prove
   for free; ranged index variables make even cross-thread indexing
   check-free.
3. **Overflow**: every `+ - * /` (and unary `-`) must prove its result
   fits int64. Full-range `int + int` does not compile — narrow a range
   or guard first. Ranges cannot silently wrap.
4. **Termination**: every `while` must be provably bounded — induction
   or an explicit `max N` cap. `loop` at the top of a thread is the only
   infinite control flow in the language.
5. **Containment / presence**: `m[k]` requires proven containment;
   using a `T?` requires proven presence; `pop` requires proven
   nonempty; `add` requires proven room (or use the `bool`-returning
   `push`/`put`).

Stores complete the system: assigning to (or initializing, returning
into, or passing as an argument for) a ranged location must prove the
value fits its declared range. `var` parameters require the exact same
range on both sides, since writes flow both ways.

**The payoff:** the generated C contains no runtime checks of any kind —
no bounds checks, no division checks, no overflow checks, no
trap-and-exit paths. `queue[tail]` compiles to `g_queue[g_tail]`. What
remains at run time is exactly the program.

## Big locals: per-thread arenas

Locals larger than 256 bytes do not live on the C stack — they live on a
**per-thread arena**: a global byte array sized to that thread's proven
worst-case call path (the no-recursion DAG walk), bumped by a constant
on entry to each frame-owning routine and restored on every return. The
bump pointer is one thread-local; every offset is a compile-time
constant; and since capacity equals the proof, **arena overflow is
impossible** — no check, no trap. The C stack carries only scalars and
small frames, safely inside any OS default (macOS pthreads: 512 KB).

Consequences: declare 10 MB of scratch arrays in a proc freely —
allocation is a pointer bump, deallocation is the return; successive
calls reuse the same bytes (different types in the same place is fine —
zero-init at declaration means stale bytes are never observable, and
there are no pointers to alias them); untouched arena pages cost address
space, not RAM. Returns of big values never touch the C stack either —
they compile to destination passing (see Routines). Big *by-value
object parameters* and big foreach element copies still use the C
stack — keep those small or pass by `var`. The report prints both
numbers.

## Compilation model

Nifty compiles one module to one portable C file (C99 + pthreads):

| nifty                  | C                                          |
| ---------------------- | ------------------------------------------ |
| global `var`           | `static` global (zero-initialized)         |
| `const`                | `static const int64_t`                     |
| `func` / `proc`        | `static` function                          |
| `thread foo`           | `static void *t_foo(void*)` + `pthread_create`/`join` in generated `main` |
| `object Name =`        | `typedef struct`                           |
| seq/string/set/queue/map | `typedef struct` + tiny `static` op functions per instantiated type |
| `T?`                   | `struct { T m_val; bool m_ok; }` (niche packing planned) |
| `with` on a `Lock`     | `pthread_mutex_t` lock–unlock pair         |
| `with` on other types  | `start(x)` / `end(x)` calls around the block |
| `a[i]`                 | bare C indexing (proven safe, no checks)   |
| `/`, `%`               | bare C `/` and `%` (proven safe, no checks) |
| `lo .. hi` range types | `int64_t` (ranges exist only at compile time) |
| big locals (> 256 B)   | typed pointers into the per-thread arena   |
| effectful statements   | temporaries in source order (defined evaluation) |
| `var` param (scalar/struct) | pointer parameter                     |
| array param            | decayed pointer, `const` in C unless `var` |

Because declare-before-use is required in nifty, the generated C needs
no forward prototypes — definitions appear in call order. The host
compiles; the target only executes. The runtime is libc + pthreads —
there are no trap helpers, because nothing can trap.

## The report

`nifty report file.nifty` prints the program's static resource
footprint — numbers most toolchains can only measure or guess, derived
from properties the checker proves:

- **globals** — the whole heap, byte-exact per global (C layout, with
  struct padding), plus the lock count.
- **stack** — worst case per thread: the call DAG's deepest chain of
  frames, printed with the chain (`consumer -> tryPop`). Small by
  construction: big locals are on the arena.
- **arena** — exact bytes per thread for big locals, allocated up front;
  overflow impossible because the allocation equals the proof.
- **ops** — worst-case abstract operation count per thread pass, from
  the proven loop trip bounds. Container ops priced honestly:
  sparse-map searches ⌈log₂N⌉, map writes and string appends N.
  Multiply by a target's cycles-per-op to approximate WCET.

## Grammar (v0, informal)

```
program     = { importDecl } module
importDecl  = "import" ident NL
module      = { constDecl | globalDecl | objectDecl | routineDecl }
constDecl   = "const" ident "=" constExpr NL
globalDecl  = "var" ident ":" type NL
objectDecl  = "object" ident "=" NL INDENT { fieldDecl } DEDENT
fieldDecl   = ident { "," ident } ":" type NL
routineDecl = ("func" | "proc" | "thread") ident "(" [params] ")" [":" type] "=" body
params      = param { "," param }
param       = ident { "," ident } ":" ["var"] type
type        = baseType ["?"]
baseType    = "int" | "bool" | "Lock"
            | "array" "[" cap "," type "]"
            | "seq" "[" cap "," type "]"
            | "queue" "[" cap "," type "]"
            | "string" "[" cap "]"
            | "set" "[" rangeType "]"
            | "map" "[" rangeType "," type "]"
            | "map" "[" cap "," type "," type "]"
            | objectTypeName | rangeType
rangeType   = constExpr (".." | "..<") constExpr
cap         = int | constIdent
body        = simpleStmt NL | NL INDENT { stmt } DEDENT
stmt        = simpleStmt NL | ifStmt | whileStmt | forStmt | loopStmt | withStmt
whileStmt   = "while" expr ["max" constExpr] ":" body
forStmt     = "for" ident ["," ident] "in" (expr (".." | "..<") expr | expr) ":" body
simpleStmt  = varDecl | assign | callStmt | "return" [expr] | "break"
            | "echo" expr { "," expr } | "discard" expr
expr        = orExpr; standard precedence:
              or < and < not < (== != < <= > >=) < (+ -) < (* / %) < unary - < postfix
postfix     = atom { "[" expr "]" | "." ident | "." ident "(" [args] ")" | "(" [args] ")" }
atom        = int | string | "true" | "false" | "none" | ident | "(" expr ")"
```

Comments run from `#` to end of line. Indentation is spaces only.

## v0 implementation status

Implemented: `const`/`var` globals; range, object, and optional types
with declare-before-use; the containers (`array`, `seq`, `string`,
`set`, `queue`, dense and sorted-sparse `map`) with their proof
contracts; `func`/`proc`/`thread` with the full rights table;
no-recursion; `if`/`while max`/`for`/`for-in`/`loop`/`with` (Lock and
start/end protocol); the five proof-obligation families (division,
indexing, overflow, termination, containment/presence) on one interval-
and-predicate engine; thread ownership and lock inference (data-race
freedom); defined left-to-right evaluation with effects; accumulator
induction; per-thread arenas for big locals; whole-array/container
copies with element-range fit proofs; strategic `var`/`let` (unmodified
`var` is an error); any-size returns via destination passing; generics
via `$` substitution variables (splice-per-instantiation, proven per
binding, `$T.lo`/`$T.hi`, computed return ranges);
smallest-scope enforcement (unused/one-thread/scratch globals,
narrowable locals) and `block:` with sibling-block arena overlay;
lock order (deadlock freedom, lexical + cross-call), pointless-lock
errors, and the report's locks section; hardware types (sized ints
with real storage widths, char, IEEE float32/float64 sealed off from
the proofs, saturating .toInt);
`echo`/`discard`; C output
with zero runtime checks; generated `main` with thread spawn/join;
`nifty report` (globals / stack / arena / ops); splice-once imports with
cycle rejection and file-tagged errors; gold-master test suite.

Not yet implemented: `$T` for scalar (non-container) parameters,
generic `set`/`map` patterns, `index` types, absence reasons
(`T ? codeRange` with a provable `.error` — `none` is deliberately mute),
a `Result`-returning `map.get` (needs absence reasons; `get(k, fallback)`
and proven `m[k]` cover today), tail-call recursion, automatic int width from
ranges (named hardware types size storage today; bare ranges are still
8 bytes), float transcendentals (no libm; base ops only, contraction
off), `fixed[lo .. hi, step]`,
volatile registers and interrupt handlers,
optional niche packing.

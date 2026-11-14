# Nifty — language spec (v0 draft)

Nifty is nimmy's super-static brother. nimmy is a dynamic scripting language;
nifty is a small systems language with statically checked memory access,
threads, stack depth, control flow, and evaluation order. Fixed-capacity
storage remains the default; growable strings and sequences add explicit,
fallible heap allocation with scoped ownership. Nifty compiles to portable C
or native ARM64 and AMD64 code; see [BACKENDS.md](BACKENDS.md).

The design goal is *provability through simplicity*: the compiler proves
access safety and reports static storage, stack depth, and operation bounds
where available. Growable payloads and their operation costs are reported as
runtime-dependent rather than disguised as fixed resource requirements.
Unproven direct access does not compile; allocation failure is a value.

## Core model

- **Static storage plus scoped owners.** Fixed-capacity values keep their
  existing storage and, when they contain no owners, copy semantics.
  `string` and `seq[T]` own growable
  heap storage and begin empty without allocating. Locals release owned
  storage on scope exit; globals release it after all threads finish.
  There is no public `alloc` or `free`. Growth is explicit and fallible.
- **Threads are declared, not created.** Every `thread name() =` declaration
  is one OS thread — and `thread 4 name() =` is four of them running the
  same body: a thread pool is one declaration. All threads start at
  program start. There is no `createThread` or user thread teardown; a program
  is "start once, run until done (or forever)". The program exits when
  every thread returns. Every worker waits for all thread creation and
  startup resources to succeed before entering its body. If startup fails,
  waiting workers exit without running user code, and the process reports
  a startup error after joining them. If a join fails, the process exits
  with an error before releasing storage that a worker might still use.
- **No recursion.** Declare-before-use with no forward declarations makes
  the call graph a DAG by construction; a routine calling itself is
  rejected. Stack use is therefore statically bounded — and big locals
  don't even use the C stack (see Big locals). (Planned: allow self and
  mutual recursion when every call in the cycle is a provable tail call,
  compiled to loops.)
- **No exceptions or implicit traps.** Division by zero, out-of-
  bounds indexing, integer overflow, non-termination of `while` loops, and
  data races are all proven impossible at compile time (see Static proofs).
  Proven direct indexing and arithmetic need no runtime checks. Growable
  operations check allocation requests and report failure without trapping.
  There is no exception unwinding.
- **Fallibility is explicit.** Internal `func` code is total: a
  `func` provably terminates and cannot fail. Fallibility exists only
  where the outside world can say no (sensors, input, hardware, allocation),
  expressed as flow-typed optionals `T?` or a `bool` success result from
  growable operations. No exceptions or implicit termination on failure.
- **Evaluation order is strictly left to right, as written — effects
  included.** C leaves subexpression order unspecified; nifty does not
  inherit that (see Evaluation order).
- **No user pointers.** `var` parameters cover mutable arguments. Owned
  values are borrowed during calls, with exclusive mutable access and no
  escaping references. Long-lived references are array indices.

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

var total: 0 .. 1000       # globals: static, zero-initialized storage
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
| allocate/grow storage  | no     | yes    | yes      |
| return value          | required | optional | none |
| callable              | yes    | yes    | never    |

A `func` is strict: the only things that go in are its parameters, the
only thing that comes out is its return value. Parameters are read-only
(no `var` params, no assignment to params, not even to their fields or
elements). A `func` may only call other `func`s — otherwise it could
reach globals through a `proc`. This makes every `func` referentially
transparent — and, with the termination proof, *total*: same arguments,
same result, always returns, never fails.

A read-only parameter containing growable storage borrows the value for
the call rather than copying its ownership. `var` parameters borrow it
exclusively, including permission to grow or replace its storage. A helper
may forward that borrow to a child call. The original owner keeps its
allocation when the helper returns. Allocation and growth are unavailable
in `func`; pure routines may inspect borrowed growable values.

A `thread` takes no parameters, returns nothing, and cannot be called.
Its body is the life of one OS thread. A count before the name —
`thread 4 worker() =`, an int literal or a `const`, at least 1 —
declares that many identical threads: the whole thread pool in one
line. The instances are honest separate threads: each gets its own
arena, a global used only by a counted thread is still *shared*
between its instances (the ordinary lock rules apply, and the
single-thread scope errors do not fire), and the report prints
`worker x4` with per-instance numbers.

Recursion is rejected in all three: routines must be declared before use,
there are no forward declarations, and a routine may not call itself.

Routines can return non-owning values of any size — arrays, bounded strings,
and objects without owned fields. Values containing growable storage cannot
be returned or implicitly copied; pass a `var` output parameter instead.
C cannot return arrays (and returning a big struct by value
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

## Uniform call syntax and overloading

Three spellings of the same call, chosen for the reader:

```nim
close(clientSocket)        # classic
clientSocket.close()       # uniform: the first argument moves out front
close clientSocket         # command: parens optional as a statement
```

- **Uniform call syntax.** `b.a(c, d)` is `a(b, c, d)` for any
  routine `a` — funcs, procs, generics, and externs alike. The
  rewrite is decided by name alone, before anything is type-checked,
  so nothing is ever checked twice: builtin container methods (`add`,
  `pop`, `find`, `send`, ...) own their names on every type, and a
  routine with such a name is callable only the classic way. Chains
  read left to right (`x.double().half()`), and a big return through
  a dot call still compiles to destination passing. Parens are
  required — a bare `b.a` stays a field access.
- **Command syntax.** When a call is the entire statement, parens are
  optional: `bump counter` is `bump(counter)`. The token after the
  name must begin an argument (a name or a literal), so operators
  keep their meaning: `a - 1` is arithmetic, not a call.
- **Overloading.** Routines may share a name when each can be told
  apart by the *kind* of its first parameter: `close(file: File)` and
  `close(socket: Socket)` are two routines with one good name, and
  `file.close()` picks by what `file` is. Kinds are coarse on
  purpose — int, float, bool, string, array, seq, queue, set, map, or
  a specific object type; ranges, capacities, and widths never take
  part, and two overloads on the same kind are an error at the
  declaration. Resolution happens once at the call site from the
  first argument's checked type, the call is rewritten to the one
  routine picked, and every proof (purity, ownership, locks,
  recursion, declare-before-use) runs on that routine. The ownership
  pre-pass, which runs before types are known, soundly
  over-approximates an overloaded call as "any of them". `start`,
  `end`, threads, and generics cannot be overloaded.

The point is names: without this, every routine drags its type into
its name (`closeSocket`, `closeFile`); with it, the type stays in the
argument where it belongs and the good short word is enough.

## FFI: binary bindings

`extern "lib":` declares C functions the binary way: you write the
shapes yourself in plain sized types, nifty emits its own prototypes,
and the linker resolves the symbols — no headers are ever read, no
vendor type zoo, no unbuildable includes.

```nim
extern "libc":
  proc pipe(fds: var array[2, int32] boundedBy 2): int32
  proc writeFd "write" (fd: int32, buf: string[64] boundedBy n, n: int64): int64
  proc readFd "read" (fd: int32, buf: var string[64] boundedBy cap, cap: int64): int64
```

- The optional string after the name is the C symbol (`writeFd` calls
  `write`). `"libc"` links for free; any other name adds `-lname`.
- `boundedBy` names a count parameter, constant, or literal. At each
  call the checker proves the count fits the writable buffer capacity
  or the readable string length. A mutable string or array extern
  requires this contract. See [foreign buffer contracts](docs/ffi.md).
- **Arguments are proven, returns are not.** Passing into an `int32`
  parameter is the ordinary range-fit proof (a lossy narrowing does
  not compile). A return is trusted only as far as its C type
  physically constrains it — `readFd`'s `int64` comes back full-range,
  so the checker forces the guard before it can become a length:
  `if got >= 0 and got <= 64: buf.setLen(got)`. `setLen` proves the
  new length fits the capacity; any byte C wrote is a valid string
  byte, so nothing unsound can enter.
- A foreign return or writable integer field cannot claim a range
  narrower than its ABI storage permits. In particular, `uint64`
  results cannot be received as nifty `uint64`, because the C value
  may exceed `int64.high`; receive the bits as `int64` if that signed
  interpretation is appropriate for the API.
- Pointers exist only at the boundary: `var` passes the address
  (scalars, objects), strings and arrays pass their data pointers
  (`var` = writable, otherwise `const`). Opaque C pointers are held as
  `int64` handles and never dereferenced. Nifty strings are
  length-exact, not NUL-terminated — byte-count APIs (read, write,
  sockets) fit directly; NUL-expecting APIs need a 0 byte kept in the
  buffer by the caller.
- Extern routines are proc-like (a `func` cannot call them), cannot be
  variadic, and only sized ints, floats, strings, array buffers,
  and `var` objects cross the boundary. Growable strings pass their byte
  pointer just like bounded strings. Other owner-containing values,
  optionals, and sequence descriptors cannot cross the boundary.
- **Growable FFI buffers reserve before reading.** Check `buf.reserve(n)`
  or `buf.resize(n)` before passing a `var string` to an extern that may
  write `n` bytes. The requested write size must fit `buf.cap`. After
  validating the returned byte count, check `buf.setLen(got)` to expose
  the bytes C wrote. `setLen` preserves those bytes; it does not allocate.
  Externs must respect the provided size and must not retain a borrowed
  address after the call. The compiler cannot verify those foreign-code
  promises.
- The honest asterisk: "what compiles cannot trap" now reads "assuming
  externs honor their declared shapes." The declaration file is the
  contract; everything on nifty's side of it stays proven.

### NUL-terminated input: `cstring`

An extern `cstring` parameter passes a borrowed pointer to NUL-terminated
bytes, never the Nifty owner descriptor. The foreign routine must read only
through the first NUL and must neither modify nor retain the address.
Foreign `cstring` returns and writable `var cstring` parameters are rejected.
Bindings must not expose aliases into a scoped C-string owner's bytes through
opaque results, output parameters, or retained global pointers. Use an
offset/copy adapter for APIs returning views until borrowed lifetimes can be
expressed. This non-escape promise is part of the trusted foreign contract.
NUL-free literals can be passed directly to an extern or ordinary `cstring`
parameter with no heap allocation, including the empty literal.

```nifty
extern "libc":
  proc cLength "strlen"(text: cstring): int64

proc inspect(path: string) =
  let converted = path.toCString()
  if converted.ok:
    echo cLength(converted)

thread main() =
  echo cLength("literal")
```

`string.toCString()` returns `cstring?`: it copies into an independent owned
allocation and adds its terminator, or returns `none` for an embedded zero,
allocation failure, or an unrepresentable allocation size. The empty string
also receives a valid one-byte allocation. Changing the source after conversion
does not change the resulting bytes.

A conversion must directly initialize a scoped local in a proc or thread.
The owner is released on scope exit, return, or break. The optional must be
checked before passing it as `cstring`. A cstring cannot be copied, assigned,
returned, stored inside a container or object, indexed, compared, printed,
or changed through string methods. Ordinary parameters borrow it for the
call. These restrictions also prevent an allocating conversion temporary
from escaping cleanup.

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
The restriction includes global locks and the implicit `start`/`end`
calls of a custom `with` block. Hooks that only operate on the resource
passed to them remain valid in generic routines.

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
  nifty values stay within `0 .. int64.high`; raw foreign `uint64`
  returns are rejected because C may return a larger value. There is no wraparound
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
  Arrays without owned elements have value semantics: whole-array
  assignment and initialization copy (a `memcpy` in the generated C), and
  a copy from a differently-ranged source must prove the element ranges
  fit. Arrays containing growable storage inherit its ownership rules.
- `object` — a static struct, exactly like C:

  ```nim
  object Vec2 =
    x: -1000 .. 1000
    y: -1000 .. 1000
  ```

  The struct layout is fixed. Fields may own growable storage. A type can
  only refer to types declared *above* it — declare-before-use for types —
  so recursive layouts and unknown descriptor sizes are impossible by
  construction.
  Objects without owned fields have C value semantics: assignment and
  non-`var` parameters copy (a fixed, compile-time-known cost), `var`
  parameters pass by pointer. Objects with owned fields cannot be copied
  or returned and are borrowed by parameters. Field access `a.b` nests
  freely with indexing (`particles[i].pos.x`). Zero-initialized; no
  constructors or literals
  in v0: declare, then assign fields.
- `Lock` — a mutex. Only allowed as a global; only usable via `with`.
- String literals appear as `echo` arguments and anywhere a `string[N]`
  is expected (they must fit, checked at compile time). They can also be
  borrowed by read-only `string` parameters and passed to growable string
  methods. A growable local starts empty; fill it with a checked operation
  instead of an allocating literal initializer.

### Containers

Containers are zero-init-is-empty and sealed builtins (the compiler owns
their representation, so it can prove their contracts and optimize
freely). Bounded containers without owned elements retain value semantics;
growable containers and aggregates containing them have scoped ownership.
Only the live part of a container
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
  literal syntax: `var s: string[40] = "hello"`, `echo s`, `s[i]`,
  `for b in s:`. Strings are length-exact, never NUL-terminated. The
  method set splits three ways by how each one can fail:

  *Writes — capacity is proven at compile time:* `add(lit or string)`,
  `addByte(b)` (one byte, proven `0 .. 255`), `addNum(v)` (a decimal
  int, priced at its 20-byte worst case), `clear()`, and `setLen(n)`
  (proven `0 .. N` — the FFI's "C filled my buffer" door).

  *Tests and slices — total, no proof needed:* `startsWith(x)`,
  `endsWith(x)`, `contains(x)` (a needle longer than the haystack is
  simply false) and `copyRange(src, lo, hi)`, which clamps its bounds,
  so any indices give a defined (possibly empty) result. Totality is
  what makes parsing hostile input pleasant: no guard per slice.

  *Searches and parses — optional-returning:* `find(x)`, `findByte(b)`
  give the index or `none`; `.toInt` gives the number or `none`. The
  optional forces the caller to consult the answer, and a parsed
  number arrives full-range — untrusted until guarded, like any
  outside value.
- `char` — one byte of text. It is `uint8` with a name and two extra
  affordances: char literals (`'A'`, `'\n'`, `'\0'`) and `echo`
  printing it as a character rather than a number. Everything else is
  ordinary ranged-int behavior, so classification needs no library:
  `if b >= '0' and b <= '9':`.
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
- `channel[N, T]` — a bounded *blocking* queue for handing work
  between threads: `send` blocks while full, `recv` blocks while
  empty, at OS level. Not a container in the value sense (global-only,
  never copied, no iteration) — see Channels below.

### Growable strings and sequences

Omitting the capacity selects scoped heap ownership: `string` and
`seq[T]`. Both begin with length and capacity zero, without an allocation.
Their descriptor has a fixed size; its backing storage is chosen at run
time. `string[N]` and `seq[N, T]` keep their existing bounded behavior.

```nim
proc greeting(output: var string): bool =
  return output.add("hello")

thread main() =
  block:
    var text: string
    if greeting(text):
      echo text
  # The block releases text's allocation.
```

The caller owns `text`; the callee may allocate or grow its storage through
the mutable parameter. No sizing pass or returned pointer is required.
Growth can relocate the payload, but the caller's owner remains the same.

- `.len` gives the live element count; `.cap` gives the allocated capacity.
  Both properties are read-only, including through mutable parameters.
  `reserve(n): bool` ensures capacity for at least `n` elements without
  changing the length. Newly allocated spare storage is zeroed.
- `resize(n): bool` changes the live length, allocating if necessary and
  zero-initializing newly live elements.
- `setLen(n): bool` changes the live length only if `n <= cap`; it does
  not allocate or overwrite newly exposed bytes. This preserves FFI data
  written after `reserve`. Both length-changing methods require an
  element type with a valid zero initial value. Shrinking destroys and
  zeroes removed owned elements. A sequence of a nonzero range can still
  start empty and accept supplied values through `add` or `push`.
- `add(x): bool` and `push(x): bool` append a sequence element, growing as
  necessary. An owned element is copied into independent owned storage;
  allocation failure leaves the destination unchanged.
- On growable strings, `add(text): bool`, `addByte(byte): bool`, and
  `addNum(integer): bool` append, while `copyRange(src, lo, hi): bool`
  replaces the contents with the clamped source range.
- `copyFrom(source): bool` explicitly copies into the receiving growable
  container. String sources may be literals, bounded strings, or growable
  strings; sequence sources may be bounded or growable with compatible
  element types. There is no implicit allocating assignment or shallow
  owner copy.
- `clear()` destroys live owned elements and sets length to zero while
  retaining capacity for reuse. It does not allocate.
- `pop()` requires proven nonempty storage and returns the last element.
  It is available only for element types without owned storage whose value
  size is at most 256 bytes. Shrink or clear a sequence to destroy owned
  elements instead.
- `get(index)` returns an optional copied element, or `none` if out of
  range; it is available only for nonoptional element types without owned
  storage. Large results use destination passing, with the same direct
  initialization, assignment, and return rules as large routine results.
  Use guarded indexing and child procedures to access owned values.
  Direct `s[index]` still requires a proof that the index is in the live
  range. `.len` and read-only string searches do not allocate.

Size arguments to `reserve`, `resize`, and `setLen` must be proven
nonnegative. Allocating operations check request arithmetic and allocation
results.
A `false` result leaves the receiving container's length and contents
unchanged. The caller must consult or explicitly discard the result, as
with every other returned value. No growth failure implicitly exits the
program. Allocating operations are available in `proc` and `thread`, not
in `func`.

Ownership follows the containing value. `seq[string]`, objects with
growable fields, and arrays of those objects release their contents
recursively. Locals clean up on normal scope exit, including `return` and
`break`; a loop-local owner is cleaned up each iteration. A global owner is
cleaned up after all threads join. Existing restrictions against escaping
a `with` block still apply. A nested `block:` is the way to request earlier
cleanup without a public `free` operation.

Owned values cannot be initialized from another owner, assigned, returned,
or sent through a channel. The restriction applies recursively to values
containing owners. For this version, owned values are also excluded from
optionals, queues, and maps. Fixed sequences can contain owners, but their
copying `add`, `push`, and `pop` operations cannot be used on owned elements.
Use dynamic sequences for collections of dynamically allocated values.

Read-only parameters borrow owned values for the duration of the call.
Mutable parameters borrow exclusively: while the borrow is active, the
container and its elements are accessible only through it or a temporary
borrow forwarded to a child call. Two read-only borrows may coexist.
Exclusivity applies to every `var` parameter, including scalars and fixed
arrays. Read-only fixed arrays also participate in borrow conflict checks.
Overlapping arguments are rejected when either permits mutation, including
passing a container alongside a reference to one of its elements. Calls
cannot bypass a borrow through a global alias, and borrowed references
cannot escape into stored values. Iteration cannot mutate its source;
an iteration element containing owned storage is borrowed through a
read-only pointer.

Shared global owners use the ordinary lock rules for all access, reads
included. The caller keeps the lock across the complete borrowed call.
Borrowed access ends before releasing that lock; releasing the lock does
not destroy the global owner's storage.

### Optionals

`T?` is a flow-typed optional: a value that may be absent. Usable
anywhere a regular type is — variables, params, returns, object fields,
container elements and map values; only `set` elements and map *keys*
stay non-optional (domains, not values). Values containing growable storage
cannot be optional in this version.

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
  inside one long, readable routine. Owned growable payloads are freed
  when their block exits.
- `name = expr`, `a[i] = expr`, `o.f = expr`, `m[k] = expr` — assignment.
- `if cond: ... elif cond: ... else: ...`
- `for i in lo ..< hi:` / `for i in lo .. hi:` — bounded by construction;
  `i` is immutable; bounds are evaluated once.
- `for x in c:` — iterate a seq, string, set, or queue; `for k, v in m:`
  (or `for k in m:`) iterates a map. Loop variables are immutable
  copies, except elements containing owned storage, which are borrowed
  read-only. Modifying the container inside is a compile error. Bounded
  containers have a static trip bound; growable containers terminate at
  their runtime length and are reported as runtime-dependent work.
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
  right (hoisted to temporaries in the generated C). If a write or the
  final buffered flush fails, the process prints
  `nifty: stdout write failed` to stderr and exits nonzero. A closed
  POSIX pipe uses this path instead of terminating through SIGPIPE.
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
9 motivated the original static subset (no goto/recursion, proven loop
bounds, no allocation, no preprocessor, no pointers). Explicit growable
storage now relaxes the no-allocation rule and static operation bounds,
while preserving scoped ownership and checked access. Rule 5's assertions
became compile-time proof obligations on every division, index, store, and
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

## Channels: the semaphore system

`var jobs: channel[N, T]` is a bounded blocking queue — nifty's
wakeup primitive. `jobs.send(v)` blocks while the channel is full;
`jobs.recv()` blocks while it is empty. Blocking is a real OS-level
sleep on a condition variable (the generated C embeds a mutex and two
condvars in the channel struct), not a spin: a waiting thread costs
zero CPU until the other side hands it work.

A channel *is* a counting semaphore — but fused with the data it
counts, so the token and the payload cannot drift apart: you cannot
signal without an item, the counter is bounded by `N` (the capacity
IS the backpressure), and `recv` returns the element type with its
declared range intact, feeding the ordinary proofs.

Channels mirror `Lock`'s discipline: only a global, never copied,
never a parameter, field, or element; `send` and `recv` are the whole
interface (no `len`, no iteration — any peek would race). They
synchronize themselves, so they are exempt from the shared-global
lock rule and need no `with`; being internally locked, they work from
the first instruction of every thread — no startup handshake. Two
static rules keep the story provable:

- **Both sides must exist.** Some thread must send and some thread
  must (transitively) receive — a counted thread's instances count
  separately. A channel with one side missing waits forever: compile
  error.
- **Never block while holding a lock.** `send`/`recv` while any lock
  is held — lexically or through any call chain — is a compile error:
  a blocked holder would keep every signaler out of the lock. This
  closes the lock/channel deadlock the same way declaration order
  closes the lock/lock one.

The checker also explores all channel interleavings for closed protocols
whose communication order is independent of data. It models queue capacity,
counted threads, finite constant-count loops, procedure calls, and repeating
thread loops. A reachable state with unfinished threads blocked on empty or
full channels is a compile error. This catches receive-before-send cycles,
send cycles that fill their buffers, and mismatched send/receive counts.

Data-dependent communication, foreign calls, and analyses exceeding the
compiler's state or trace limits are reported as `not proven`. Acceptance
in those cases does not imply channel progress. Reports on every backend
state the result; even a completed protocol analysis assumes runnable
threads eventually execute and establishes no wall-clock deadline.

Foreign routines have unknown blocking behavior. Calling one while a Nifty
lock is held, including through a helper routine, is rejected. Move the
foreign call outside the lock and copy the required state while protected.
This restriction does not make allocator or output latency bounded.

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

Nifty proves direct access and arithmetic safety at compile time instead
of inserting checks that trap. What cannot be proven does not compile,
and the user adds a test the prover can see. Explicit fallible operations
such as growable allocation and optional `get` perform runtime checks and
return an ordinary result.

The engine is interval analysis: every int expression carries a proven
`[lo, hi]` range (plus a nonzero bit, since an interval cannot express
"anything but zero"), and a second kind of fact — **predicates** — for
containment (`m@k`), presence (`r@ok`), and dynamic index/length relations.

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
- dynamic bounds tests: `if i >= 0 and i < s.len:` prove a direct index
  until either the index or the owning container changes. A loop over a
  stable `0 ..< s.len` range supplies the same relationship;
- arithmetic: conservative bounds combine through `+ - * / %`; an
  unrepresentable intermediate bound cannot establish a narrower range.

**What invalidates a fact:** assigning something wider, passing the
variable as a `var` argument, using it as a `with` target, mutating it
through a method, calling a routine that may write it (including a
`with` block's `start`/`end`), releasing the lock that protected it, or
entering a loop whose body modifies it (the loop condition re-proves
what it can on every entry). Ordinary `var` parameters conservatively use
their declared ranges rather than carrying flow facts. Exclusive borrows
of owned storage support the facts needed for growable access. Aliasing
itself is restricted: a global
cannot be passed as a `var` argument to a routine that also touches that global
directly, and a `var` param cannot be forwarded toward a routine
touching a type-compatible global.
All mutable parameters reject overlapping borrows, including aliases
introduced by argument evaluation. For owned storage, this also prevents
accessing an element while another argument reallocates its container.

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
   nonempty; bounded `add` requires proven room (or use the
   `bool`-returning `push`/`put`). Growable `add` instead returns a
   `bool` allocation result.

Stores complete the system: assigning to (or initializing, returning
into, or passing as an argument for) a ranged location must prove the
value fits its declared range. `var` parameters require the exact same
range on both sides, since writes flow both ways.

**The payoff:** proven direct indexing and arithmetic compile without
bounds, division, or overflow checks. `queue[tail]` compiles to
`g_queue[g_tail]`. Growable helpers check sizes and allocation failure,
and optional accessors check membership, without trap-and-exit paths.

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

Growable owners do not reserve their payload in these arenas. Their fixed
descriptors contribute to local storage, while heap payloads are tracked
separately in the report. Aggregates with owned fields can themselves use
the arena; their owned payloads are still destroyed before that storage is
reused.

## Compilation model

The C backend compiles one module to one portable C file (C99 + pthreads).
Native backends lower the same checked module into typed IR and machine code,
with the same ownership, borrowing, and allocation-failure rules.
Checking produces a backend-independent semantic plan with binding identities,
value and borrow modes, lock proofs, and ordered destruction lists for normal
scope exit, return, break, and program exit. Return expressions are evaluated
before their destruction list runs. Generators consume this plan; type,
borrow, range, and other source-language checks finish before backend entry.
Backend validation checks generated IR, target layouts, and serialized images.
The C mapping is:

| nifty                  | C                                          |
| ---------------------- | ------------------------------------------ |
| global `var`           | `static` global (zero-initialized)         |
| `const`                | `static const int64_t`                     |
| `func` / `proc`        | `static` function                          |
| `thread foo`           | `static void *t_foo(void*)` + `pthread_create`/`join` in generated `main` |
| `object Name =`        | `typedef struct`                           |
| seq/string/set/queue/map | `typedef struct` + tiny `static` op functions per instantiated type |
| growable seq/string | length, capacity, and data pointer; checked allocation helpers |
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
| owner-containing param | borrowed descriptor/aggregate; no ownership copy |
| owner scope exit       | recursive cleanup calls, including normal return/break paths |

Because declare-before-use is required in nifty, the generated C needs
no forward prototypes — definitions appear in call order. The host
compiles; the target only executes. The runtime is libc + pthreads —
growable allocation helpers return failure rather than calling trap helpers.

## The undefined-behavior ledger

C is the compilation target, and C's undefined behavior is a contract:
"the compiler may assume X never happens." A language suffers when its
semantics *need* X to happen; nifty instead **proves** X never happens,
so every assumption C's optimizer makes is a theorem we already hold.
The ledger, clause by clause:

| C undefined behavior | Discharged by |
| --- | --- |
| signed overflow | the overflow proofs |
| division by zero, `INT64_MIN / -1` | the division proofs (both cases) |
| out-of-bounds access | the index proofs |
| unsequenced side effects | strict left-to-right lowering |
| integer promotion traps | operands cast-widened to int64 |
| uninitialized reads | zero-initialization everywhere |
| null / dangling pointers | checked allocation, scoped ownership, and nonescaping borrows |
| data races (C11) | the ownership and lock proofs; mutexes are the barriers |
| float-to-int overflow / NaN casts | the saturating `ni_ftoi`, the only cast emitted |
| strict aliasing at the arena | compiled with `-fno-strict-aliasing` (the kernel's choice) |
| FP contraction nondeterminism | compiled with `-ffp-contract=off` |
| effect-free infinite loops assumed to terminate | `while` is proven terminating; `loop` bodies have effects |
| mismatched extern prototypes | the binary FFI's explicit trust boundary — the one asterisk |

Alternatives considered: LLVM IR does not remove undefined behavior
(it has more, explicitly - poison, undef, nsw/nuw); C keeps the three
things nifty needs - a compiler for every microcontroller ever made, a
single readable auditable output file, and cc everywhere.

## The report

`nifty report file.nifty` prints the program's resource footprint, separating
statically known storage from runtime-dependent payloads and work:

- **globals** — byte-exact static storage per global (C layout, with
  struct padding), plus the lock count. Growable descriptors are included;
  their heap payloads are not part of this static byte count.
- **stack** — worst case per thread: the call DAG's deepest chain of
  frames, printed with the chain (`consumer -> tryPop`). Small by
  construction: big locals are on the arena. This language-level estimate
  excludes allocator and runtime-helper frames.
- **arena** — exact bytes per thread for big locals, allocated up front;
  overflow impossible because the allocation equals the proof.
- **ops** — worst-case abstract operation count per thread pass, from
  the proven loop trip bounds. Container ops priced honestly:
  sparse-map searches ⌈log₂N⌉, map writes and string appends N.
  Runtime-sized work and allocation are reported as runtime-dependent,
  including through calls, rather than assigned a false constant bound.
  Allocator latency is not a statically proven time bound.
- **heap** — the `heap (runtime-sized; separate from static storage)`
  section lists owners and their lifetimes. Payload and spare-capacity
  storage have no static upper bound in this mode. A payload byte count
  would not include allocator metadata, fragmentation, or temporary
  growth/copy peaks, so static totals must not
  be read as an exact process-memory bound for a growable program.

## Grammar (v0, informal)

```
program     = { importDecl } module
importDecl  = "import" ident NL
module      = { constDecl | globalDecl | objectDecl | routineDecl }
constDecl   = "const" ident "=" constExpr NL
globalDecl  = "var" ident ":" type NL
objectDecl  = "object" ident "=" NL INDENT { fieldDecl } DEDENT
fieldDecl   = ident { "," ident } ":" type NL
routineDecl = ("func" | "proc" | "thread" [cap]) ident "(" [params] ")" [":" type] "=" body
params      = param { "," param }
param       = ident { "," ident } ":" ["var"] type
type        = baseType ["?"]
baseType    = "int" | "bool" | "Lock"
            | "array" "[" cap "," type "]"
            | "seq" "[" cap "," type "]"
            | "seq" "[" type "]"
            | "queue" "[" cap "," type "]"
            | "channel" "[" cap "," type "]"
            | "string" ["[" cap "]"]
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
simpleStmt  = varDecl | assign | callStmt | commandStmt
            | "return" [expr] | "break"
            | "echo" expr { "," expr } | "discard" expr
commandStmt = ident expr { "," expr }   (next token starts an argument)
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
copies of non-owning values with element-range fit proofs; strategic
`var`/`let` (unmodified `var` is an error); any-size non-owning returns via
destination passing; generics via `$` substitution variables
(splice-per-instantiation, proven per binding, `$T.lo`/`$T.hi`, computed
return ranges);
smallest-scope enforcement (unused/one-thread/scratch globals,
narrowable locals) and `block:` with sibling-block arena overlay;
lock order (deadlock freedom, lexical + cross-call), pointless-lock
errors, and the report's locks section; hardware types (sized ints
with real storage widths, char, IEEE float32/float64 sealed off from
the proofs, saturating .toInt); binary FFI (extern "lib" blocks,
symbol aliases, proven arguments / untrusted returns, string buffers
with setLen, link flags);
`echo`/`discard`; counted threads (`thread 4 worker()` — per-instance
arenas, instance-aware sharing and scope rules, `x4` report lines);
channels (`channel[N, T]` with blocking `send`/`recv` on embedded
condvars; both-sides and no-block-under-lock proofs);
uniform call syntax, command statements, and first-parameter-kind
overloading;
C output with check-free proven indexing and arithmetic; growable `string`
and `seq[T]` with checked allocation, caller-owned growth, exclusive mutable
borrowing, and recursive scope cleanup; generated `main` with thread
spawn/join and global owner cleanup;
`nifty report` (globals / stack / arena / ops / dynamic heap); splice-once
imports with cycle rejection and file-tagged errors; gold-master test suite.

Not yet implemented: `$T` for scalar (non-container) parameters,
generic `set`/`map` patterns, `index` types, absence reasons
(`T ? codeRange` with a provable `.error` — `none` is deliberately mute),
a `Result`-returning `map.get` (needs absence reasons; `get(k, fallback)`
and proven `m[k]` cover today), tail-call recursion, automatic int width from
ranges (named hardware types size storage today; bare ranges are still
8 bytes), float transcendentals (no libm; base ops only, contraction
off), `fixed[lo .. hi, step]`,
volatile registers and interrupt handlers,
optional niche packing, ownership moves/returns, shared ownership, and
owned values inside optionals, queues, maps, or channels.

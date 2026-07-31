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
- **No exceptions.** Errors that the language itself detects (index out of
  bounds) trap with a message in v0. Planned: a per-thread error flag /
  lightweight `Result` values. There is no unwinding, ever. Division by
  zero cannot happen at all — see Static proofs.
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

- `int` — 64-bit signed integer.
- `bool` — `true` / `false`.
- `array[N, T]` — fixed length `N` (an integer literal or `const`), element
  type `T`. Arrays are indexed `a[i]` with a bounds check (traps in v0).
  Whole-array assignment/copy is not allowed; copy elements in a loop.
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
- String literals exist only as `echo` arguments in v0.

Planned types:

- **Range integers** `lo .. hi`, Pascal-subrange style. Narrowing inserts a
  runtime check by default; a prove mode reports every check the compiler
  could not discharge (flow-sensitive narrowing from `if` and loop bounds).
- **Typed indices** `index arr` — an integer bound to one specific global
  array, valid by construction (only produced in-range, nothing is ever
  freed), so indexing needs no check. The out-of-range values encode `none`
  (niche optimization) for free.
- **Fixed strings** `string[N]` — Turbo Pascal style, stored inline.
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
- `while cond:` — v0 accepts any `while`. Planned rule: a `while` must
  either have a compiler-recognizable induction bound or an explicit
  `while cond max N:` clause that traps on overrun. Together with
  no-recursion this gives a static worst-case iteration count per thread
  (static gas / WCET).
- `loop:` — infinite loop, allowed **only at the top level of a `thread`
  body**. This is the event/server loop; everything inside it must
  (eventually) be bounded. `break` is allowed.
- `with x:` — a scoped resource block. `with x:` desugars to
  `start(x)`, the block body, then `end(x)`:
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

Nifty's long-term direction is to prove safety properties at compile time
instead of checking them at run time. The first proof is implemented:

### Division is proven safe

Every `/` and `%` must have a divisor the compiler can prove nonzero:

1. a nonzero constant expression: `x / 4`, `i % QueueSize`, or
2. a local variable (or non-var parameter) with a dominating test:

   ```nim
   if b != 0:
     echo x / b
   ```

Nonzero facts flow through the program:

- `if b != 0:`, `b > 0`, `b < 0`, `b >= 1`, `b == 5`, ... prove `b` in the
  then-branch; `and` conditions prove both sides.
- The else branch of `if b == 0:` proves `b`.
- Guard style works: `if b == 0: return` proves `b` for everything after.
- `while b != 0:` proves `b` inside the loop body (re-tested every entry).
- `var b = 4` (any nonzero constant initializer or assignment) proves `b`.
- Assigning anything unprovable, passing `b` as a `var` argument, using it
  as a `with` target, or entering a loop whose body modifies `b` clears
  the fact.

Globals never carry the fact — another thread could zero a global between
the test and the division. Snapshot into a local first:

```nim
let d = g
if d != 0:
  echo x / d
```

The payoff: because every division is proven, the generated C contains no
runtime division checks — `/` and `%` compile to bare C operators and can
never trap. This is the model for the planned range and index proofs: the
check moves from run time to compile time, then disappears from the binary.

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
| `a[i]`                 | index via bounds-check helper              |
| `/`, `%`               | bare C `/` and `%` (proven safe, no checks) |
| `var` param (scalar)   | pointer parameter                          |
| array param            | decayed pointer (read-only unless `var`)   |

Because declare-before-use is required in nifty, the generated C needs no
forward prototypes — definitions appear in call order.

The host compiles; the target only executes. There is no runtime beyond
libc + pthreads and a few line-tagged trap helpers.

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
            | objectTypeName
body        = simpleStmt NL | NL INDENT { stmt } DEDENT
stmt        = simpleStmt NL | ifStmt | whileStmt | forStmt | loopStmt | withStmt
simpleStmt  = varDecl | assign | callStmt | "return" [expr] | "break"
            | "echo" expr { "," expr } | "discard" expr
expr        = orExpr; standard precedence:
              or < and < not < (== != < <= > >=) < (+ -) < (* / %) < unary - < postfix
postfix     = atom { "[" expr "]" | "." ident | "(" [args] ")" }
```

Comments run from `#` to end of line. Indentation is spaces only.

## v0 implementation status

Implemented: everything above not marked *planned* — `const`/`var` globals,
`object` types with declare-before-use,
`func`/`proc`/`thread` with the full rights table, no-recursion via
declare-before-use, `if`/`while`/`for`/`loop`/`with` (Lock and start/end
protocol), locks, bounds-checked arrays, the division proof (compile-time
nonzero divisors, no runtime division checks), `echo`, `discard`, C output,
generated `main` with thread spawn/join.

Not yet implemented: range types, `index` types, fixed strings, wildcard
generics, tail-call recursion, `while ... max N` bound checking, the
per-thread error flag (v0 traps instead), WCET report.

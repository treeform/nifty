# Embedding Nifty in Nim

Import `nifty` (the complete compiler facade) or `nifty/scripting` (the scripting
API). Add the repository's `src` directory to your Nim import path. No `nifty`
executable, C compiler at runtime, or libffi installation is needed for ordinary
host callbacks.

The API follows [Bassy](https://github.com/treeform/bassy)'s host, program, and
runtime model. These are different languages; Basic source does not run as
Nifty source. See [examples/embedding.nim](../examples/embedding.nim) for a
complete Nim application.

```nim
import nifty/scripting

var host = initHost()
host.addData("score", 21)
host.addFunction("double", 1,
  proc(args: openArray[int64]): int64 = args[0] * 2)

let program = compile("""
var answer: int
thread main() =
  answer = double(score)
  echo answer
""", host)

let context = initRuntime(program)
discard context.run(proc(text: string) = stdout.write(text))
doAssert context.getGlobal("answer").asInt() == 42

context.setData("score", 30)
context.restart()
discard context.run() # No output callback: output is discarded, still charged.
doAssert context.getGlobal("answer").asInt() == 60
```

`newContext(source, host, limits)` combines compilation and runtime creation.
Compilation still applies Nifty's normal type checks, integer range proofs,
ownership rules, and loop checks. One `thread main()` supplies the entry point;
it executes synchronously on the calling Nim thread and creates no OS worker.
Counted/multiple workers, locks, and channels are unavailable in scripting mode.

## Capabilities

Scripts have no automatic file, network, process, environment, or native-library
access. A fresh host exposes no application functions. The synthetic `host`
module contains exactly the registered functions and data and is implicitly
imported by the main script. Normal module qualification and aliasing work:
`host.double(score)`. Supplied modules can explicitly `import host`.

`addData` registers a copied integer, float, bool, or string input. Script code
can read it but cannot assign it, mutate it through a method, or pass it to a
mutable parameter. The host changes an existing input with `setData`. Neither
callback arguments nor results expose VM addresses: strings are copied in both
directions. Safe callback names are unique within a host.

The integer convenience overload above accepts `openArray[int64]` and returns
`int64`. Typed callbacks use `Value`:

```nim
host.addQuery("greet", [StringValue], StringValue,
  proc(args: openArray[Value]): Value =
    value("Hello " & args[0].asString()))

host.addFunction("record", [StringValue, IntValue], VoidValue,
  proc(args: openArray[Value]): Value =
    saveScore(args[0].asString(), args[1].asInt()) # Your Nim implementation.
    Value(), workUnits = 100)
```

Supported kinds are `IntValue`, `FloatValue`, `BoolValue`, `StringValue`, and
`VoidValue` for a procedure without a result. Use `value(x)`, `asInt`, `asFloat`,
`asBool`, and `asString` at the boundary. `addQuery` declares a trusted pure Nifty
`func`; `addFunction` declares a side-effecting `proc`. The host is responsible
for honoring a query's purity and validating script-controlled arguments before
performing application operations. String results construct a fresh owner and must
be stored in a variable before use, following Nifty's large-result rule.

Console output is also host-controlled. `echo` uses internal value callbacks
and the optional `run(print = ...)` callback. It does not import the filesystem
standard library, load a DLL, or touch process stdout automatically. Applications
can expose selected file reads, HTTP requests, or graphics operations as normal
host functions; the Nim implementation decides what names, paths, or objects
the script may access.

## Imports

Imports are disabled by default. Any `import` in a script fails, and
`addModule` raises. Create the host with `initHost(allowImports = true)` to
enable virtual modules.

`host.addModule("maths", source)` provides a virtual `maths.nifty` module.
`host.addModule("game/helpers.nifty", source)` provides a virtual path. Imports
use only this map: no current-directory search, standard-library fallback,
environment lookup, download, cache, or `nifty.lock` write occurs. A supplied
URL can be used as an exact virtual module identity; it is never downloaded.
Virtual relative paths are normalized, so `shared.nifty` and
`./shared.nifty` import one module. Existing cascading imports, ambiguity rules,
and aliases apply. Bare imports prefer a supplied module beside the importing
module, then a supplied module at the virtual root. The `host.nifty` identity is
reserved for the host prelude.

## Programs and persistent state

`compile` snapshots the host schema, callbacks, input defaults, and supplied
source. A `Program` keeps its checked IR private. Only source compilation creates
one; this API does not execute arbitrary serialized IR or native images.

`initRuntime(program)` creates independent globals and owned allocations.
`initRuntime(program, otherHost)` permits different callbacks and input defaults
with the same function/data schema. Closures can deliberately capture shared
Nim state, so their side effects are as independent as the host makes them.
Do not execute one runtime concurrently or reenter it from its callbacks. A
callback may run a different runtime. Serialize compilation, which uses the
compiler's shared diagnostic state.

`run` executes once. `restart` replenishes budgets and keeps globals and host
inputs; `reset` clears script globals and owned allocations while retaining the
latest host inputs and callbacks. `getGlobal` returns a copied scalar/string
`Value`; `setGlobal` checks its declared type, range, and fixed string capacity.
Aggregates and optional globals should be exposed through script accessors or
copied into scalar globals. Host input names use `setData`, not `setGlobal`.
When a script global shadows an input name, `getGlobal("host.name")` explicitly
reads the input; `setData("name", value)` always targets the host input.

Compilation errors raise `ScriptError`. Resource exhaustion raises
`ExecutionLimitError`; other runtime errors and Nim callback exceptions return
to the caller. After a failed invocation, call `reset` before executing again.
Reset frees allocations abandoned by interrupted local scopes. Completed host
side effects are not rolled back.

## Resource limits

Pass a modified `defaultLimits()` to `compile` or `newContext`:

| Limit | Default |
| --- | ---: |
| Total source, including imported modules and host declarations | 1 MiB |
| VM work per invocation | 10,000,000 units |
| Logical VM memory | 64 MiB |
| Output per invocation, including discarded output | 1 MiB |
| Call depth | 64 |
| Live owned allocations | 4,096 |
| Syntax/type depth | 64 |
| Generated IR instructions and blocks | 200,000 |

Source also has limits on expression size, source lines, and imported module
count. Work counts IR instructions and terminators, byte operations, bridge
string copies, allocations, conservative container traversal costs, and each
callback's declared `workUnits`. Callback work is charged before entering Nim.
Memory includes globals, the arena, interpreter frames, allocation records,
owned payloads, and copied callback string inputs. `run` returns `RunStats` with
work, peak logical memory, and output bytes.

These are VM resource limits, not a timer that can interrupt arbitrary Nim or
native code. The compiler's own allocations, callback implementation's memory,
and callback duration remain the host's responsibility. Nifty uses native
floating-point values; it does not promise Bassy's fixed-point determinism.
This is an in-process capability model, not OS process isolation.

## Explicitly unsafe FFI

Every script `extern` declaration is rejected by default, including unused
declarations and declarations inside supplied modules. Registering a safe Nim
callback never enables FFI.

Externs are disabled by default. Any `extern` block fails, and
`allowUnsafeFfi` raises. An application that intentionally trusts native code
creates the host with `initHost(allowExterns = true)` and then calls
`allowUnsafeFfi(library, symbol, address, parameters, returns)` on its host. The
host supplies a non-null resolved address and its exact IR ABI, for example
`[Int64Type]` parameters and `[Int64Type]` results. Both the library/symbol pair
and ABI must match. This does not let a script choose arbitrary DLL paths or
resolve additional symbols. The host must keep the address/library alive.

This escape hatch uses libffi and grants the native target the embedding
process's powers; it can defeat the VM's safety and resource guarantees. Prefer
copied-value callbacks for application scripting. The normal command-line
compiler/interpreter retains its existing unrestricted systems-programming FFI.

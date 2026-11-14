# Foreign buffer contracts

An `extern` declaration describes the C ABI and the maximum span a call may
access. The declaration is a promise about the linked function; nifty checks
that each caller supplies storage for that span.

```nifty
extern "libc":
  proc read(fd: int32, buffer: var string boundedBy count, count: int64): int64
  proc write(fd: int32, buffer: string boundedBy count, count: int64): int64
  proc pipe(fds: var array[2, int32] boundedBy 2): int32
```

`boundedBy` names an integer parameter, a constant, or a literal. For a
mutable string, the checker proves the count is nonnegative and at most the
buffer's capacity. For a read-only string, it proves the count is at most its
current length. For an array, it proves the count is at most its fixed element
count. Mutable foreign string and array parameters require a bound. The bound
uses bytes for strings and elements for arrays.

A growable string starts with zero capacity. Reserve space and check success
before a foreign write:

```nifty
var buffer: string
if buffer.reserve(128):
  let n = read(fd, buffer, 128)
  if n >= 0 and n <= 128:
    discard buffer.setLen(n)
```

The checker also accepts a guarded variable count such as
`if n >= 0 and n <= buffer.cap: read(fd, buffer, n)`, and a successful
`buffer.reserve(n)` proves the same relationship. Changing either value
invalidates that proof. A read-only literal has its known byte length,
so `write(fd, "hello", 5)` is valid with a compatible fixed-string
declaration.

Foreign results and writable integer fields must have ranges guaranteed by
their ABI type. A C result declared `0 .. 0` is rejected because the C
function may return another value. Check a full-range result before using it
as an index or length. Foreign declarations still require an accurate ABI
signature and a truthful maximum-access contract from the programmer.

A top-level string parameter exposes its byte payload, keeping its length
and capacity metadata private. Foreign-writable objects and arrays cannot
contain strings, even fixed strings: their nested layouts include length
metadata that a raw write could invalidate. Pass individual string payloads
through bounded string parameters instead. Plain objects and arrays made
from full-range ABI integers, floats, and opaque handles remain writable. Foreign routines
can return ABI integers, floats, and opaque handles, but no container or
object layouts.


## Opaque handles

Declare each foreign pointer family as a nominal type:

```nifty
type CFile = opaque

extern "libc":
  proc tmpfile(): CFile
  proc fclose(file: CFile): int32

proc openTemporary(): CFile? =
  let file = tmpfile()
  if file.isNull:
    return none
  return file
```

An opaque handle has pointer-sized storage and passes through the C ABI as
`void *`; `var CFile` passes as `void **`. Its default value is null, and
`.isNull` is a pure boolean query. Handles can be copied, stored in ordinary
objects and containers, and compared with `==` or `!=` against the same
opaque type. Distinct declarations remain distinct types even though their
binary representations match.

Nifty code cannot construct non-null handles, convert them to or from
integers, perform pointer arithmetic, dereference them, or compare their
ordering. Foreign declarations remain responsible for the actual pointer
contract, including lifetime and ownership. Handle copies do not automatically
close or free a foreign resource.

A Nifty wrapper can return `CFile?`, using the ordinary payload and presence
flag representation. Optional values cannot cross the foreign ABI directly;
foreign routines return a plain handle, then wrappers test `.isNull`.

## C-string inputs

NUL-terminated inputs use the distinct `cstring` type. NUL-free string
literals pass directly without allocation. For a Nifty string, initialize a
scoped local with `let input = source.toCString()` and check `input.ok`
before passing it to a `cstring` parameter. Conversion returns `none` on an
embedded zero, allocation failure, or size overflow. Its allocation owns a
copy and is released automatically when the local leaves scope.

The ABI receives only the bytes pointer. The foreign function must not
modify the bytes or retain that address after returning. C-string returns
are rejected until a foreign ownership and lifetime contract is available.
The same restriction covers escaping aliases: a binding must not return or
write out an opaque pointer into a scoped C-string owner. Functions such as
`strchr` need a binding that returns an offset or a copy instead. The current
opaque type does not track a pointer's borrowed lifetime. As with the
maximum-access contract, this is a requirement on the foreign declaration;
the compiler cannot inspect a foreign implementation to prove it.
See the [C-string rules](../spec.md#nul-terminated-input-cstring).


## Console output

`import console` provides `write(text: string): bool`, which writes exactly the
string bytes and reports failure. Fixed strings can be passed as readonly
views. Embedded NUL and newline bytes retain their original values, including
when Windows stdout is redirected. One `write` call is atomic with other
console writes and complete `echo` lines.

`echo` remains convenient syntax: it evaluates every argument once, from left
to right, before starting the line. The backends expand it into ordinary Nifty
procedures from `std/_echo.nifty`; those procedures use the same bounded foreign
byte writes as `console`. Integer, character, boolean, and float formatting
use fixed storage. Dynamic strings are borrowed for output. The standard ABI
bridge supplies only stdout synchronization and a format-only float adapter;
it contains no output routine.

Console output uses unbuffered descriptor writes. When mixing it with foreign
buffered stdio such as `printf`, callers must flush the foreign stream before
calling `write` or `echo` to preserve output order. The foreign declaration's
stream lifetime and synchronization contracts remain the caller's responsibility.

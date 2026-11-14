# Foreign buffer contracts

An `extern` declaration describes the C ABI and the maximum span a call may
access. The declaration is a promise about the linked function; nifty checks
that each caller supplies storage for that span.

```nifty
extern "libc":
  proc read(fd: int32, buffer: var string[128] boundedBy count, count: int64): int64
  proc write(fd: int32, buffer: string[128] boundedBy count, count: int64): int64
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

Foreign results and writable integer fields must have ranges guaranteed by
their ABI type. A C result declared `0 .. 0` is rejected because the C
function may return another value. Check a full-range result before using it
as an index or length. Foreign declarations still require an accurate ABI
signature and a truthful maximum-access contract from the programmer.

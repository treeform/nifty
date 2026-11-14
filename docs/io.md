# Console and file bytes

`import io` provides ordinary procedures implemented with C library calls.
`import console` provides console bytes without file operations. The compiler
looks beside the importing source first, then in the standard library. A
distribution can place that library in `std` beside the executable, or in
`lib/nifty` under its installation prefix. `NIFTY_STDLIB` selects another
library directory.

```nifty
import io

thread main() =
  let file = openWrite("message.bin")
  if file.ok:
    let written = writeFile(file, "hello\0world\n")
    let closed = close(file)
    if written and closed:
      discard write("saved\n")
```

`openRead(path: cstring)` and `openWrite(path: cstring)` return `CFile?`.
Check `.ok` before using the handle. Write mode creates or truncates a file.
Both modes are binary. A NUL-free literal can be passed directly. For a dynamic
path, create a scoped owner using `let path = text.toCString()` and check
`path.ok`; conversion rejects embedded NUL and allocation failure.

The caller owns each successful open and must call `close` exactly once, after
all uses of that stream. Handles may be copied; those copies refer to the same
stream and do not create another ownership obligation. `close` returns whether
the stream closed successfully, including flushing buffered data. Closing a
null handle returns false. Reusing a closed handle is invalid.

`readChunk(file, buffer)` replaces a bounded `string[N]` with at most
`min(N, IoChunkSize)` bytes. `readChunkGrow(file, buffer)` replaces a growable
`string` with at most `IoChunkSize` bytes. Both return an optional byte count:
zero means EOF, and `none` means failure. Check `.ok` before reading the count.
The growable version also reports allocation failure and preserves the previous
buffer on EOF, an I/O error, or transactional copy failure. The bounded version clears its buffer
before attempting the read. A read error consumes any bytes already read from
the stream; these functions do not roll back file position.

`writeFile(file, text)` and `write(text)` return a boolean, retry partial writes,
and preserve embedded NUL bytes. `writeFile` flushes before returning success.
Failure can leave a written prefix; callers decide whether to retain or remove
an incomplete file. Close a file even when reading or writing fails. `write`
targets stdout and adds no newline. These functions process strings in
4096-byte chunks and reject lengths above `IoMaxBytes` (`int64.max - 4096`).

All file operations use ordinary `extern "libc"` declarations. The `fread` and
`fwrite` declarations constrain their element size to one, so their checked
`boundedBy count` contracts describe the actual number of accessible bytes.

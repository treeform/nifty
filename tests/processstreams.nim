## Captures process pipes through EOF, including short Windows ReadFile results.
import std/streams
when defined(windows):
  import std/[os, winlean]
else:
  import std/[os, posix]

proc readToEnd*(stream: Stream): string =
  ## A short pipe read can precede another write and does not imply EOF.
  var buffer: array[4096, char]
  while true:
    let count = stream.readData(addr buffer[0], buffer.len)
    if count == 0:
      break
    let previous = result.len
    result.setLen(previous + count)
    copyMem(addr result[previous], addr buffer[0], count)

proc readHandleToEnd*(handle: FileHandle): string =
  ## Drains in a worker without sharing an ORC-managed Stream across threads.
  var buffer: array[4096, char]
  while true:
    var count: int
    when defined(windows):
      var received: int32
      let success = winlean.readFile(Handle(handle), addr buffer[0],
        int32(buffer.len), addr received, nil)
      if success == 0:
        let error = osLastError()
        if error notin [OSErrorCode(109), OSErrorCode(ERROR_HANDLE_EOF)]:
          raiseOSError(error)
        received = 0
      count = int(received)
    else:
      count = posix.read(cint(handle), addr buffer[0], buffer.len)
      if count < 0:
        if osLastError() == OSErrorCode(EINTR):
          continue
        raiseOSError(osLastError())
    if count == 0:
      break
    let previous = result.len
    result.setLen(previous + count)
    copyMem(addr result[previous], addr buffer[0], count)

## Captures process pipes through EOF, including short Windows ReadFile results.
import std/streams

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

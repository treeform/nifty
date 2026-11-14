## A fragmented process pipe must preserve bytes across short reads.
import std/streams
import processstreams

type FragmentedStream = ref object of StreamObj
  data: string
  position: int

proc readFragment(stream: Stream, buffer: pointer, length: int): int =
  ## Simulates a pipe that delivers a complete output in short fragments.
  let fragmented = FragmentedStream(stream)
  result = min(2, min(length, fragmented.data.len - fragmented.position))
  if result > 0:
    copyMem(buffer, addr fragmented.data[fragmented.position], result)
    fragmented.position += result

let expected = "fragmented\0output\r\nlast byte\n"
let stream = FragmentedStream(data: expected, readDataImpl: readFragment)
doAssert stream.readToEnd() == expected
echo "Fragmented process output preserved through EOF"

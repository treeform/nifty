## A fragmented process pipe must preserve bytes across short reads.
import std/[os, osproc, streams]
import processstreams

const
  Expected = "fragmented\0output\r\nlast byte\n"
  ChildExpected = "fragmented\0output\rlast byte"

if paramCount() == 1 and paramStr(1) == "--fragments":
  for value in ChildExpected:
    stdout.write(value)
    stdout.flushFile()
    sleep(1)
  quit(0)

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

let stream = FragmentedStream(data: Expected, readDataImpl: readFragment)
doAssert stream.readToEnd() == Expected

proc drain(input: tuple[handle: FileHandle, output: ptr string]) {.thread.} =
  input.output[] = input.handle.readHandleToEnd()

let process = startProcess(getAppFilename(), args = @["--fragments"],
  options = {poStdErrToStdOut})
var output: string
var reader: Thread[tuple[handle: FileHandle, output: ptr string]]
createThread(reader, drain, (process.outputHandle, addr output))
let status = process.waitForExit(10_000)
if status == -1:
  process.kill()
  discard process.waitForExit()
joinThread(reader)
process.close()
doAssert status == 0
doAssert output == ChildExpected
echo "Fragmented process output preserved through EOF"

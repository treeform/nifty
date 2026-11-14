## Checks channel progress and foreign blocking before backend generation.

import std/strutils
import ../src/nifty/[checker, common, loader, parser, report, types]

proc checked(source: string): Module =
  ## Runs a source fixture through the common semantic checker.
  result = parse(loadTokens(source, "progress.nifty", ""))
  check(result)

proc rejects(source, message: string) =
  ## Requires a concrete source violation and no backend involvement.
  var rejected = false
  try:
    discard checked(source)
  except NiftyError as error:
    doAssert message in error.msg, error.msg
    rejected = true
  doAssert rejected, "Accepted an invalid protocol"

rejects("""
var first: channel[1, int]
var second: channel[1, int]
thread left() =
  let value = second.recv()
  first.send(value)
thread right() =
  let value = first.recv()
  second.send(value)
""", "channel protocol can deadlock")

rejects("""
var jobs: channel[1, int]
thread producer() =
  jobs.send(1)
thread consumer() =
  echo jobs.recv()
  echo jobs.recv()
""", "channel protocol can deadlock")

rejects("""
var first: channel[1, int]
var second: channel[1, int]
thread left() =
  first.send(1)
  first.send(2)
  echo second.recv()
thread right() =
  second.send(1)
  second.send(2)
  echo first.recv()
""", "channel protocol can deadlock")

rejects("""
var jobs: channel[1, int]
proc consume() =
  echo jobs.recv()
  echo jobs.recv()
thread producer() =
  jobs.send(1)
thread consumer() =
  consume()
""", "channel protocol can deadlock")

for call in ["wait()", "indirect()"]:
  rejects("""
extern "libc":
  proc wait()
proc indirect() =
  wait()
var gate: Lock
thread 2 worker() =
  with gate:
    echo 1
    """ & call & "\n", "may block while lock 'gate' is held")

let finite = checked("""
var jobs: channel[1, int]
thread producer() =
  for i in 0 ..< 10:
    jobs.send(i)
thread consumer() =
  for i in 0 ..< 10:
    echo jobs.recv(), i
""")
doAssert "no blocked channel state" in finite.semantics.channelProgress
doAssert "channels:" in buildReport(finite, "finite.nifty")

let counted = checked("""
var jobs: channel[1, int]
thread 2 producer() =
  jobs.send(1)
thread consumer() =
  echo jobs.recv()
  echo jobs.recv()
""")
doAssert "no blocked channel state" in counted.semantics.channelProgress

let cyclic = checked("""
var first: channel[1, int]
var second: channel[1, int]
thread left() =
  loop:
    first.send(1)
    echo second.recv()
thread right() =
  loop:
    let value = first.recv()
    second.send(value)
""")
doAssert "no blocked channel state" in cyclic.semantics.channelProgress

let dependent = checked("""
var jobs: channel[1, int]
thread producer() =
  jobs.send(1)
thread consumer() =
  let value = jobs.recv()
  if value == 1:
    echo jobs.recv()
""")
doAssert dependent.semantics.channelProgress.startsWith("not proven:")

let oversized = checked("""
var jobs: channel[1, int]
thread producer() =
  for i in 0 ..< 100000:
    jobs.send(i)
thread consumer() =
  for i in 0 ..< 100000:
    echo jobs.recv(), i
""")
doAssert oversized.semantics.channelProgress.startsWith("not proven:")

echo "Channel progress and foreign blocking checks passed"

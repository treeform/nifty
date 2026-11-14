## Checks range invariants at optional and aggregate copy boundaries.
import std/strutils
import ../src/nifty

proc verify(source: string) =
  ## Rejects broad payload copies and accepts the corresponding widening.
  var rejected = false
  try:
    discard checkedModule(source, "copy-ranges.nifty")
  except NiftyError as e:
    doAssert "cannot copy: ranges of " in e.msg, e.msg
    rejected = true
  doAssert rejected, source
  discard checkedModule(source.replace("int?", "0 .. 5?").replace(
    "return 42", "return 4"), "copy-ranges.nifty")

const Reading = """func reading(present: bool): int? =
  if present:
    return 42
  return none

"""

for body in [
    "let value: 0 .. 10? = reading(true)\necho value.or(0)",
    "var values: seq[2, 0 .. 10?]\nvalues.add(reading(true))",
    "var values: seq[2, 0 .. 10?]\ndiscard values.push(reading(true))",
    "var values: queue[2, 0 .. 10?]\nvalues.add(reading(true))",
    "var values: seq[0 .. 10?]\ndiscard values.push(reading(true))",
    "var values: map[0 .. 1, 0 .. 10?]\nvalues.put(0, reading(true))",
    "var values: map[0 .. 1, 0 .. 10?]\nvalues[0] = reading(true)",
    "var values: map[2, int, 0 .. 10?]\n" &
      "discard values.put(0, reading(true))",
    "var values: map[0 .. 1, 0 .. 10?]\nvalues.put(0, none)\n" &
      "let value = values.get(1, reading(true))\necho value.or(0)"
  ]:
  verify(Reading & "thread main() =\n" & body.indent(2) & "\n")

verify(Reading & """func narrow(): 0 .. 10? =
  return reading(true)

thread main() =
  echo narrow().or(0)
""")

verify(Reading & """var values: channel[1, 0 .. 10?]

thread producer() =
  values.send(reading(true))

thread consumer() =
  echo values.recv().or(0)
""")

const Broad = """func broad(): array[1, int] =
  var values: array[1, int]
  values[0] = 42
  return values

"""

proc verifyAggregate(source: string) =
  ## Checks recursive ranges without requiring scalar flow facts.
  var rejected = false
  try:
    discard checkedModule(source, "copy-ranges.nifty")
  except NiftyError as e:
    doAssert "cannot copy: ranges of " in e.msg, e.msg
    rejected = true
  doAssert rejected, source
  discard checkedModule(source.replace("array[1, int]", "array[1, 0 .. 50]")
    .replace("seq[1, int]", "seq[1, 0 .. 50]")
    .replace("0 .. 10", "0 .. 100"), "copy-ranges.nifty")

verifyAggregate(Broad & """func narrow(): array[1, 0 .. 10] =
  return broad()

thread main() =
  let value = narrow()
  echo value[0]
""")

const BroadSeq = """func broad(): seq[1, int] =
  var values: seq[1, int]
  values.add(42)
  return values

"""

for body in [
    "var values: seq[2, seq[1, 0 .. 10]]\nvalues.add(broad())",
    "var values: map[0 .. 1, seq[1, 0 .. 10]]\nvalues[0] = broad()",
    "var values: map[0 .. 1, seq[1, 0 .. 10]]\n" &
      "values.put(0, broad())",
    "var values: map[0 .. 1, seq[1, 0 .. 10]]\n" &
      "values.clear()\nlet result = values.get(1, broad())\n" &
      "if result.len > 0:\n  echo result[0]"
  ]:
  verifyAggregate(BroadSeq & "thread main() =\n" & body.indent(2) & "\n")

echo "Optional and aggregate copy ranges passed"

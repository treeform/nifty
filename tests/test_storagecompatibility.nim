## Reject aggregate copies whose integer payload representations differ.
import std/strutils
import ../src/nifty

const NarrowSource = """
func narrow(present: bool): int8? =
  if present:
    return 7
  return none

"""

proc rejects(source, diagnostic: string) =
  ## Require a checker diagnostic before either backend receives the source.
  var rejected = false
  try:
    discard compileToC(source, "storage.nifty")
  except NiftyError as error:
    rejected = true
    doAssert diagnostic in error.msg, error.msg
  doAssert rejected, "Incompatible aggregate storage was accepted"

for (source, diagnostic) in [
  ("""
thread main() =
  let value: int? = narrow(true)
  echo value.or(0)
""", "type mismatch"),
  ("""
thread main() =
  var value: int? = none
  value = narrow(true)
  echo value.or(0)
""", "cannot assign"),
  ("""
func consume(value: int?): int =
  return value.or(0)
thread main() =
  echo consume(narrow(true))
""", "argument 1"),
  ("""
func widen(): int? =
  return narrow(true)
thread main() =
  echo widen().or(0)
""", "return"),
  ("""
thread main() =
  var values: seq[int?]
  discard values.push(narrow(true))
""", "cannot add"),
  ("""
thread main() =
  var values: seq[2, int?]
  discard values.push(narrow(true))
""", "cannot add"),
  ("""
thread main() =
  var values: map[2, int, int?]
  discard values.put(1, narrow(true))
""", "map value must be"),
  ("""
thread main() =
  var values: map[2, int, int?]
  echo values.get(1, narrow(true)).or(0)
""", "fallback must be")
]:
  rejects(NarrowSource & source, diagnostic)

rejects("""
func unsigned(present: bool): uint8? =
  if present:
    return 7
  return none
thread main() =
  let value: int8? = unsigned(true)
  echo value.or(0)
""", "type mismatch")

for (sourceType, targetType) in [
  ("array[2, uint64]", "array[2, int64]"),
  ("seq[2, uint64]", "seq[2, int64]"),
  ("queue[2, uint64]", "queue[2, int64]"),
  ("map[0 .. 1, uint64]", "map[0 .. 1, int64]"),
  ("map[2, uint64, int]", "map[2, int64, int]"),
  ("map[2, int, uint64]", "map[2, int, int64]")
]:
  rejects("""
func consume(value: $2): int =
  return 1
thread main() =
  var source: $1
  echo consume(source)
""" % [sourceType, targetType], "argument 1")

echo "Aggregate integer storage compatibility passed"

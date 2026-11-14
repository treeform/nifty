## Shared interoperability and ownership fixtures.
const CStringSource* = """
extern "libc":
  proc length "strlen"(text: cstring): int64

proc size(text: cstring): int =
  return length(text)

thread main() =
  echo size("literal")
  echo length("")
  var text: string[20] = "hello"
  let value = text.toCString()
  echo value.ok
  text.clear()
  if value.ok:
    echo length(value)
  var zero: string[8]
  zero.addByte(0)
  let invalid = zero.toCString()
  echo invalid.ok
  let empty: string[8] = ""
  let emptyValue = empty.toCString()
  echo emptyValue.ok
  if emptyValue.ok:
    echo length(emptyValue)
  var dynamic: string
  discard dynamic.add("independent")
  let dynamicValue = dynamic.toCString()
  dynamic.clear()
  if dynamicValue.ok:
    echo length(dynamicValue)
"""
const CStringExpected* = "7\n0\ntrue\n5\nfalse\ntrue\n0\n11"

const CStringLiteralSource* = """
extern "libc":
  proc length "strlen"(text: cstring): int64
proc size(text: cstring): int =
  return length(text)
thread main() =
  echo size("literal")
  echo length("")
"""

const CStringFailureSource* = """
extern "libc":
  proc length "strlen"(text: cstring): int64
thread main() =
  let text: string[8] = "retry"
  let first = text.toCString()
  echo first.ok
  let retry = text.toCString()
  echo retry.ok
  if retry.ok:
    echo length(retry)
"""

const CStringScopesSource* = """
extern "libc":
  proc length "strlen"(text: cstring): int64
proc early(): int =
  block:
    let text: string[8] = "owned"
    let value = text.toCString()
    if value.ok:
      return length(value)
  return 0
thread main() =
  echo early()
  for i in 0 ..< 3:
    let text: string[8] = "loop"
    let value = text.toCString()
    if value.ok:
      echo length(value)
  for i in 0 ..< 3:
    let text: string[8] = "break"
    let value = text.toCString()
    if value.ok:
      echo length(value)
      break
"""

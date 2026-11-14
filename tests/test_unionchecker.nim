## Checks that proof-driven type inspection is fixed before optimization.
import std/strutils
import ../src/nifty/[checker, common, loader, parser, types]

const Source = """
object Number =
  value: int
object Flag =
  value: bool
type Value = Number or Flag
func unknown(value: Value): bool =
  return type(value) == Number
thread main() =
  var value: Value = Number(1)
  echo type(value) == Number
  value = Flag(true)
  echo unknown(value)
"""

let module = parse(loadTokens(Source, "union_checker_typeids.nifty", ""))
check(module)
let
  dynamic = module.routines[0].body[0].value.kids[0]
  known = module.routines[^1].body[1].args[0].kids[0]
doAssert dynamic.kind == TypeIdExpr
doAssert dynamic.ival == 0
doAssert dynamic.kids.len == 1
doAssert dynamic.kids[0].typ.kind == UnionType
doAssert known.kind == TypeIdExpr
doAssert known.ival != 0
doAssert known.kids.len == 1
doAssert known.kids[0].typ.kind == UnionType
echo "union checker type IDs passed"

proc rejects(source, message: string) =
  ## Requires the checker to reject a stale union proof.
  try:
    let module = parse(loadTokens(source, "union_checker_stale.nifty", ""))
    check(module)
    doAssert false, "expected rejection"
  except NiftyError as error:
    doAssert message in error.msg, error.msg

const Header = """
object Number =
  number: int
object Flag =
  flag: bool
type Value = Number or Flag
"""

rejects(Header & """
proc replace(value: var Value): Number =
  value = Flag(true)
  return Number(1)
proc inspect(value: var Value) =
  if type(value) == type(replace(value)):
    echo value.number
thread main() =
  var value: Value
  inspect(value)
""", "'.' needs an object")

rejects(Header & """
thread main() =
  var values: array[1, Value]
  let index: 0 .. 0 = 0
  if type(values[0]) == Number:
    values[index] = Flag(true)
    echo values[0].number
""", "'.' needs an object")

rejects(Header & """
object Holder =
  value: Value
var holder: Holder
proc replace() =
  holder.value = Flag(true)
proc touch(value: var Value) =
  if type(value) == Number:
    replace()
    echo value.number
  value = Number(2)
proc forward(value: var Value) =
  touch(value)
thread main() =
  forward(holder.value)
""", "might alias")

let replacements = parse(loadTokens(Header & """
object Holder =
  value: Value
thread main() =
  var values: array[1, Value]
  if type(values[0]) == Number:
    values[0] = Flag(true)
  var holder: Holder
  if type(holder.value) == Number:
    holder.value = Flag(true)
  echo type(values[0]), type(holder.value)
  var dynamic: seq[Value]
  discard dynamic.push(Number(1))
  if dynamic.len > 0:
    let index: 0 .. 0 = 0
    dynamic[index] = Flag(true)
    echo type(dynamic[0])
""", "union_checker_replacements.nifty", ""))
check(replacements)
echo "union checker stale proof regressions passed"

rejects(Header & """
thread main() =
  var values: seq[Value]
  let found = values.get(0)
  echo type(found)
  discard values.push(Number(1))
""", "before proving it has a value")

rejects(Header & """
thread main() =
  var values: seq[Value]
  var found = values.get(0)
  found = Number(1)
  found = none
  echo found.number
  discard values.push(Number(2))
""", "before proving it has a value")

let optionals = parse(loadTokens(readFile("tests/scripts/union_optionals.nifty"),
  "union_optionals.nifty", ""))
check(optionals)
let wrapped = optionals.routines[^1].body[4].rhs
doAssert wrapped.kind == UnionWrapExpr
doAssert wrapped.wrapOpt
doAssert wrapped.typ.opt
doAssert wrapped.wrapSource.kind == UnionType
doAssert not wrapped.wrapSource.opt
echo "union checker optional composition passed"

let optionalBorrow = parse(loadTokens(Header & """
proc clear(value: var Value?) =
  value = none
thread main() =
  var found: Value? = Number(1)
  clear(found)
  echo found.ok
""", "union_checker_optional_borrow.nifty", ""))
check(optionalBorrow)
echo "union checker optional borrow passed"

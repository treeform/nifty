## Checks shared lifetime decisions and the checked-module boundary.
import std/strutils
import ../src/nifty/[checker, codegen, common, loader, lowering,
  nativeplans, nativereports, parser, report, semantics, types]
import ../src/nifty/backend/engine

const
  ScopeSource = """
proc exits(flag: bool): int =
  var outer: string
  discard outer.add("outer")
  block:
    var inner: string
    discard inner.add("inner")
    if flag:
      return inner.len
    var later: string
    discard later.add("later")
  return outer.len

proc loops() =
  var outer: string
  discard outer.add("outer")
  for i in 0 ..< 3:
    var temporary: string
    discard temporary.addNum(i)
    block:
      var inner: string
      discard inner.add("inner")
      if i == 0:
        break
      var later: string
      discard later.add("later")
    echo temporary
  echo outer

thread main() =
  echo exits(true)
  loops()
  block:
    var text: string
    discard text.add("first")
    echo text
  block:
    var text: string
    discard text.add("second")
    echo text
"""
  BorrowSource = """
func size(text: string): int =
  return text.len

func first(numbers: array[2, int]): int =
  return numbers[0]

proc fill(text: var string): bool =
  return text.add("filled")

proc inspect(values: seq[string]) =
  for item in values:
    echo item

thread main() =
  var text: string
  echo fill(text), " ", size(text)
  var numbers: array[2, int]
  numbers[0] = 7
  echo first(numbers)
  var values: seq[string]
  discard values.push(text)
  inspect(values)
"""
  GlobalSource = """
var first: string
var second: string

proc fill() =
  discard first.add("one")
  discard second.add("two")

proc show() =
  echo first
  echo second

thread main() =
  fill()
  show()
"""
  ViewSource = """
func textSize(text: string): int =
  return text.len

func numberSize(values: seq[int]): int =
  return values.len

thread main() =
  let fixedText: string[8] = "ok"
  echo textSize(fixedText)
  var fixedNumbers: seq[4, int]
  fixedNumbers.add(7)
  echo numberSize(fixedNumbers)
  var text: string
  discard text.add("ok")
  echo textSize(text)
  var numbers: seq[int]
  discard numbers.add(7)
  echo numberSize(numbers)
"""
  LockSource = """
var gate: Lock
var text: string

thread 2 worker() =
  with gate:
    discard text.add("x")
    echo text
"""
  PlainSource = """
thread main() =
  echo 1
"""

proc parsed(source: string): Module =
  ## Parses a fixture without preparing semantic metadata.
  parse(loadTokens(source, "semantics.nifty", ""))

proc checked(source: string): Module =
  ## Prepares a fixture through the same checker used by every backend.
  result = parsed(source)
  check(result)
  doAssert result.semantics != nil

proc routine(m: Module, name: string): Routine =
  ## Finds a checked routine without relying on declaration positions.
  for r in m.routines:
    if r.name == name:
      return r
  doAssert false, "Missing test routine: " & name

proc names(m: Module, bindings: seq[BindingId]): seq[string] =
  ## Makes ordered cleanup expectations readable in assertions.
  for binding in bindings:
    result.add(m.semantics.bindings[binding].name)

template rejectsUnchecked(action: untyped) =
  ## Requires consumers to reject a module before doing backend work.
  block:
    var rejected = false
    try:
      action
    except NiftyError as error:
      rejected = true
      doAssert "checking" in error.msg, error.msg
    doAssert rejected, "Unchecked source reached a semantic consumer"

block:
  let
    m = checked(ScopeSource)
    exits = m.routine("exits")
    nested = exits.body[2]
    earlyReturn = nested.body[2].elifs[0].body[0]
  doAssert m.names(earlyReturn.drops) == @["inner", "outer"]
  doAssert earlyReturn.value.kids[0].binding == nested.body[0].binding
  doAssert m.names(m.semantics.scopes[nested.bodyScope].drops) ==
    @["later", "inner"]
  doAssert m.names(exits.body[^1].drops) == @["outer"]
  doAssert m.names(m.semantics.scopes[exits.bodyScope].drops) == @["outer"]

  let
    loops = m.routine("loops")
    loop = loops.body[2]
    loopBlock = loop.body[2]
    leave = loopBlock.body[2].elifs[0].body[0]
  doAssert m.names(leave.drops) == @["inner", "temporary"]
  doAssert m.names(m.semantics.scopes[loop.bodyScope].drops) ==
    @["temporary"]
  doAssert m.names(m.semantics.scopes[loops.bodyScope].drops) == @["outer"]

  let
    main = m.routine("main")
    first = main.body[2]
    second = main.body[3]
    firstId = first.body[0].binding
    secondId = second.body[0].binding
  doAssert firstId != secondId
  doAssert first.body[2].args[0].binding == firstId
  doAssert second.body[2].args[0].binding == secondId
  doAssert m.semantics.scopes[first.bodyScope].drops == @[firstId]
  doAssert m.semantics.scopes[second.bodyScope].drops == @[secondId]
  doAssert m.semantics.usesHeap

  let plan = m.semantics
  discard generate(m, "semantics.nifty")
  discard lowerNative(m, "semantics.nifty")
  discard buildReport(m, "semantics.nifty")
  doAssert m.semantics == plan
  doAssert m.names(earlyReturn.drops) == @["inner", "outer"]
  doAssert m.names(leave.drops) == @["inner", "temporary"]

block:
  let m = checked(BorrowSource)
  for name in ["size", "first", "inspect"]:
    let r = m.routine(name)
    doAssert m.mode(r.params[0].binding) == ReadBorrowMode
    doAssert m.semantics.scopes[r.bodyScope].drops.len == 0
  doAssert m.mode(m.routine("fill").params[0].binding) == MutBorrowMode
  doAssert m.routine("fill").body[0].drops.len == 0
  let iteration = m.routine("inspect").body[0]
  doAssert m.mode(iteration.binding) == ReadBorrowMode
  doAssert iteration.body[0].args[0].binding == iteration.binding
  doAssert m.semantics.scopes[iteration.bodyScope].drops.len == 0
  for binding in m.semantics.bindings:
    if binding.mode == OwnerMode:
      doAssert binding.routine == "main"

block:
  let m = checked(GlobalSource)
  doAssert m.names(m.semantics.globalDrops) == @["second", "first"]
  for id in m.semantics.globalDrops:
    doAssert m.semantics.bindings[id].kind == GlobalSym
    doAssert m.mode(id) == OwnerMode

block:
  let
    m = checked(ViewSource)
    main = m.routine("main")
  var views: seq[bool]
  for statement in main.body:
    if statement.kind == EchoStmt:
      views.add(statement.args[0].kids[0].borrowedView)
  doAssert views == @[true, true, false, false]

block:
  let
    locked = checked(LockSource)
    before = buildReport(locked, "locked.nifty")
  doAssert locked.semantics.locks.len == 1
  doAssert locked.semantics.locks[0].name == "gate"
  doAssert locked.semantics.locks[0].guards == @["text"]
  let plain = checked(PlainSource)
  doAssert plain.semantics.locks.len == 0
  doAssert buildReport(locked, "locked.nifty") == before

block:
  let m = parsed(PlainSource)
  doAssert m.semantics == nil
  rejectsUnchecked:
    discard generate(m, "unchecked.nifty")
  rejectsUnchecked:
    discard lowerNative(m, "unchecked.nifty")
  rejectsUnchecked:
    discard buildReport(m, "unchecked.nifty")
  rejectsUnchecked:
    discard nativeReport(NativePlan(), NativeImage(), "unchecked.nifty", m)

  check(m)
  doAssert not m.semantics.usesHeap
  m.routines[0].body[0].args[0] = Expr(kind: IdentExpr,
    sval: "missing", line: 3)
  var rejected = false
  try:
    check(m)
  except NiftyError:
    rejected = true
  doAssert rejected
  doAssert m.semantics == nil
  rejectsUnchecked:
    discard generate(m, "failed.nifty")
  rejectsUnchecked:
    discard lowerNative(m, "failed.nifty")

echo "Shared semantic plan tests passed"

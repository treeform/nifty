## Verifies union ownership and payload views in the shared lifetime plan.
import std/strutils
import ../src/nifty
import ../src/nifty/[semantics, types]

let
  json = Typ(kind: UnionType, name: "Json")
  array = Typ(kind: ObjectType, name: "JsonArray", fields: @[
    Field(name: "items", typ: Typ(kind: SeqType, dynamic: true,
      elem: json))])
  leaf = Typ(kind: ObjectType, name: "JsonNull")
json.members = @[array, leaf]

let
  reference = Expr(kind: IdentExpr, sval: "value", typ: json)
  projection = Expr(kind: UnionProjectExpr, typ: array, kids: @[reference])
  local = Stmt(kind: VarStmt, name: "local", typ: json)
  routine = Routine(name: "inspect", params: @[
    Param(name: "value", typ: json),
    Param(name: "mutable", typ: json, isVar: true)], body: @[
    local, Stmt(kind: DiscardStmt, value: projection)])
  module = Module(routines: @[routine])
module.prepareSemantics()
doAssert module.mode(routine.params[0].binding) == ReadBorrowMode
doAssert module.mode(routine.params[1].binding) == MutBorrowMode
doAssert module.mode(local.binding) == OwnerMode
doAssert reference.binding == routine.params[0].binding
doAssert module.semantics.scopes[routine.bodyScope].drops == @[local.binding]
doAssert module.semantics.usesHeap

# An owning constructor temporary must activate heap support without a local.
let
  temporary = Expr(kind: UnionWrapExpr, typ: json, kids: @[
    Expr(kind: ObjectExpr, typ: array)])
  temporaryModule = Module(routines: @[Routine(name: "temporary", body: @[
    Stmt(kind: DiscardStmt, value: temporary)])])
temporaryModule.prepareSemantics()
doAssert temporaryModule.semantics.usesHeap
doAssert temporaryModule.semantics.bindings.len == 1
echo "Union semantic lifetime plans passed"

let dispatcherReport = reportFor("""
object Left =
  value: int
object Right =
  value: int
type Choice = Left or Right
proc inspect(value: Left) =
  var text: string
  discard text.add("payload")
  var buffer: array[100, int]
  buffer[0] = 1
  echo text.len, buffer[0], value.value
proc inspect(value: Right) =
  echo value.value
proc route(choice: Choice) =
  inspect(choice)
thread main() =
  let choice: Choice = Left(1)
  route(choice)
""", "union-report.nifty")
doAssert "main: runtime-dependent" in dispatcherReport, dispatcherReport
doAssert "__union_dispatch_" in dispatcherReport, dispatcherReport
doAssert "arena per thread" in dispatcherReport, dispatcherReport
echo "Union dispatcher resource report passed"

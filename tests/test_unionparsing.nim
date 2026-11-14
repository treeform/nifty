## Checks forward named graphs and rejects malformed union declarations.
import std/[os, strutils]
import ../src/nifty/[checker, common, loader, parser, types]

proc parsed(source: string): Module =
  ## Parses one in-memory declaration graph.
  parse(loadTokens(source, "unionparsing.nifty", ""))

proc rejects(source, message: string) =
  ## Requires a parser rejection with the expected diagnostic text.
  try:
    discard parsed(source)
    doAssert false, "accepted invalid source: " & source
  except NiftyError as error:
    doAssert message in error.msg, error.msg

rejects("object Node =\n  next: Node\n", "recursive type requires a growable seq indirection")
rejects("object A =\n  next: B\nobject B =\n  next: A\n",
  "recursive type requires a growable seq indirection")
rejects("object A =\n  next: array[1, A]\n",
  "recursive type requires a growable seq indirection")
rejects("object A =\n  next: seq[1, A]\n",
  "recursive type requires a growable seq indirection")
rejects("object A =\n  next: U\ntype U = A or B\nobject B =\n  discard\n",
  "recursive type requires a growable seq indirection")
rejects("type A = A\n", "recursive type alias")
rejects("type A = B\ntype B = A\n", "recursive type alias")
rejects("type A = seq[A]\n", "recursive type alias")
rejects("type A = seq[B]\ntype B = seq[A]\n", "recursive type alias")
rejects("type A = seq[1, A]\n", "recursive type alias")
rejects("type A = Missing\n", "unknown type: 'Missing'")
rejects("object A =\n  discard\ntype U = A or\n", "expression expected")
rejects("object A =\n  discard\ntype U = A or int\n",
  "union members must be nominal objects")
rejects("object A =\n  discard\ntype U = A or A\n",
  "duplicate union member: 'A'")
rejects("type Alias = A\nobject A =\n  discard\ntype U = A or Alias\n",
  "duplicate union member: 'A'")
rejects("object A =\n  discard\ntype Maybe = A?\ntype U = A or Maybe\n",
  "union members must be nominal objects")
let optionalUnion = parsed("object A =\n  discard\ntype Maybe = U?\ntype U = A or B\nobject B =\n  discard\n")
doAssert optionalUnion.types[1].typ.kind == UnionType
doAssert optionalUnion.types[1].typ.opt
doAssert optionalUnion.types[1].typ.members.len == 2
rejects("object A =\n  discard\nobject B =\n  discard\ntype U = A or B\ntype Maybe = U?\ntype V = A or Maybe\n",
  "union members must be nominal objects")

rejects("object Box =\n  items: seq[Items]\ntype Items = array[2, int]\n",
  "element cannot be a plain array")
rejects("object Box =\n  items: map[2, Keys, int]\ntype Keys = bool\n",
  "map keys must be ints")
rejects("object Box =\n  items: set[Keys]\ntype Keys = bool\n",
  "set needs a range element type")
rejects("object Box =\n  item: Alias\ntype Alias = Lock\n",
  "cannot be a field")

rejects("object Box =\n  items: seq[set[Keys]]\ntype Keys = int\n",
  "set needs a range element type")
rejects("object Box =\n  items: set[int]\n",
  "set needs a range element type")
rejects("var items: set[int]\n", "set needs a range element type")

let aliases = parsed("""
object Containers =
  bits: set[Keys]
  table: map[2, Index, int]
type Keys = 0 .. 3
type Index = int
""")
doAssert aliases.types[0].typ.fields[0].typ.elem.kind == IntType
doAssert aliases.types[0].typ.fields[1].typ.elem.kind == IntType

let graph = parsed("""
type Maybe = Alias?
type Alias = Node
object Node =
  value: int
  children: seq[Value]
object Empty =
  discard
type Value = Node or Empty
thread main() =
  var value: Maybe
""")
doAssert graph.types[0].typ.opt
doAssert graph.types[0].typ.name == "Node"
doAssert graph.types[0].typ.fields.len == 2
doAssert graph.types[1].typ.name == "Node"
doAssert graph.types[4].typ.members[0].name == "Node"

for path in ["tests/scripts/union_defaults.nifty",
    "tests/scripts/union_order.nifty", "tests/scripts/union_overloads.nifty",
    "tests/scripts/union_owners.nifty", "tests/scripts/union_recursive.nifty",
    "tests/scripts/union_values.nifty", "examples/json_union.nifty"]:
  let module = parse(loadTokens(readFile(path), path, path.parentDir))
  if path.endsWith("union_order.nifty") or
      path.endsWith("union_overloads.nifty") or
      path.endsWith("union_owners.nifty") or
      path.endsWith("union_values.nifty"):
    check(module)
    doAssert module.semantics != nil

let generic = parsed("""
proc value(item: $T): Alias =
  return Alias(item)
type Alias = Node
object Node =
  value: int
thread main() =
  let node = value(4)
  echo node.value
""")
check(generic)
doAssert generic.semantics != nil

let directory = getTempDir() / ("nifty-union-parsing-" & $getCurrentProcessId())
createDir(directory)
let imported = directory / "shapes.nifty"
writeFile(imported, """
object Node =
  children: seq[Value]
object Empty =
  discard
type Alias = Node
type Value = Alias or Empty
func count(value: Value): int =
  if type(value) == Node:
    return value.children.len
  return 0
""")
try:
  let module = parse(loadTokens("""
import shapes as graph
Alias = graph.Node
thread main() =
  let node: graph.Value = graph.Empty()
  echo graph.count(node)
""", "main.nifty", directory))
  doAssert module.types[0].typ.fields[0].typ.elem.kind == UnionType
  check(module)
finally:
  removeFile(imported)
  removeDir(directory)

echo "Union parsing passed"

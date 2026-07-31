import std/[os, osproc, strutils]
import ../src/nifty

let root = currentSourcePath().parentDir.parentDir
let work = getTempDir() / "nifty_tests"
createDir(work)

proc buildAndRun(source, name: string): tuple[output: string, code: int] =
  ## Compile nifty source to C, build with cc, run, return output + exit code.
  let cPath = work / name & ".c"
  writeFile(cPath, compileToC(source, name & ".nifty"))
  let bin = work / name
  doAssert execShellCmd("cc -O2 -pthread -o " & quoteShell(bin) & " " &
    quoteShell(cPath)) == 0, "cc failed for " & name
  let (output, code) = execCmdEx(quoteShell(bin))
  (output, code)

proc rejects(source: string): string =
  ## Assert that compilation fails; return the error message.
  try:
    discard compileToC(source, "t.nifty")
    doAssert false, "expected NiftyError, but compilation succeeded"
  except NiftyError as e:
    result = e.msg

block: # examples compile and produce the right output
  let (output, code) = buildAndRun(readFile(root / "examples" / "hello.nifty"), "hello")
  doAssert code == 0
  doAssert output == "total: 90\n", output

block:
  let (output, code) = buildAndRun(readFile(root / "examples" / "sort.nifty"), "sort")
  doAssert code == 0
  doAssert output == "0\n1\n2\n3\n3\n4\n5\n6\n", output

block: # producer/consumer over a bounded queue, real pthreads
  let (output, code) = buildAndRun(readFile(root / "examples" / "queue.nifty"), "queue")
  doAssert code == 0
  doAssert output == "sum: 4950\n", output

block: # object types: structs, nesting, var params, func by value
  let (output, code) = buildAndRun(readFile(root / "examples" / "particles.nifty"),
    "particles")
  doAssert code == 0
  doAssert output == "p0 at 4,0 speed 1\np1 at 8,8 speed 8\np2 at 12,16 speed 25\n",
    output

block: # objects have value semantics: assignment copies
  let (output, code) = buildAndRun("""
type Vec2 = object
  x: int
  y: int

var a: Vec2

thread main() =
  a.x = 1
  var b = a
  b.x = 2
  echo a.x, " ", b.x
""", "objcopy")
  doAssert code == 0
  doAssert output == "1 2\n", output

block: # unknown fields are rejected
  doAssert "has no field" in rejects("""
type Vec2 = object
  x: int
  y: int

var a: Vec2

thread main() =
  echo a.z
""")

block: # recursive types are impossible (declare-before-use)
  doAssert "unknown type" in rejects("""
type Node = object
  next: Node
""")

block: # var parameters
  let (output, code) = buildAndRun("""
var n: int

proc bump(x: var int) =
  x = x + 1

thread main() =
  bump(n)
  bump(n)
  var local = 10
  bump(local)
  echo n, " ", local
""", "varparam")
  doAssert code == 0
  doAssert output == "2 11\n", output

block: # runtime bounds check traps
  let (output, code) = buildAndRun("""
const N = 4

var a: array[N, int]

func bigIndex(x: int): int =
  return x + 10

thread main() =
  a[bigIndex(0)] = 1
  echo a[0]
""", "oob")
  doAssert code != 0
  doAssert "out of bounds" in output, output

block: # recursion is rejected
  doAssert "recursion" in rejects("""
func f(x: int): int =
  return f(x)

thread main() =
  echo f(1)
""")

block: # forward calls are rejected (declare-before-use)
  doAssert "before its declaration" in rejects("""
proc a() =
  b()

proc b() =
  echo 1

thread main() =
  a()
""")

block: # func cannot touch globals
  doAssert "cannot access global" in rejects("""
var g: int

func f(x: int): int =
  return g

thread main() =
  echo f(1)
""")

block: # func cannot call proc
  doAssert "can only call other funcs" in rejects("""
proc p() =
  echo 1

func f(x: int): int =
  p()
  return x

thread main() =
  echo f(1)
""")

block: # func cannot have var params
  doAssert "var parameters are not allowed" in rejects("""
func f(x: var int): int =
  return x

thread main() =
  echo f(1)
""")

block: # threads take no parameters
  doAssert "no parameters" in rejects("""
thread t(x: int) =
  echo x
""")

block: # with on a type with start/end procs
  let (output, code) = buildAndRun("""
var indentLevel: int

proc start(x: var int) =
  x = x + 1

proc end(x: var int) =
  x = x - 1

thread main() =
  with indentLevel:
    echo "inside: ", indentLevel
    with indentLevel:
      echo "nested: ", indentLevel
  echo "after: ", indentLevel
""", "withproto")
  doAssert code == 0
  doAssert output == "inside: 1\nnested: 2\nafter: 0\n", output

block: # with on a type without start/end is rejected
  doAssert "needs a 'start' proc" in rejects("""
var n: int

thread main() =
  with n:
    echo n
""")

block: # return inside a with block is rejected
  doAssert "with block" in rejects("""
var l: Lock

proc p(): int =
  with l:
    return 1

thread main() =
  echo p()
""")

block: # params are immutable
  doAssert "immutable" in rejects("""
proc p(x: int) =
  x = 2

thread main() =
  p(1)
""")

block: # loop only at thread top level
  doAssert "top level of a thread" in rejects("""
thread main() =
  if true:
    loop:
      break
""")

block: # a program needs a thread
  doAssert "at least one thread" in rejects("""
var x: int
""")

block: # discarding a return value silently is an error
  doAssert "discarded" in rejects("""
func f(x: int): int =
  return x

thread main() =
  f(1)
""")

echo "all nifty tests passed"

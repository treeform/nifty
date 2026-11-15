## Run from the repository: nim r examples/embedding.nim
import nifty

var host = initHost()
host.addData("player", "Ada")
host.addData("score", 21)
host.addFunction("double", 1, proc(args: openArray[int64]): int64 =
  args[0] * 2)

# A real application could expose readAsset(name), playSound(id), or move(id,
# x, y) here. Their Nim implementations decide which resources are accessible.
let program = compile("""
var answer: int
thread main() =
  answer = double(score)
  echo "Hello ", player, ": ", answer
""", host)

let context = initRuntime(program)
discard context.run(proc(text: string) = stdout.write(text))
doAssert context.getGlobal("answer").asInt() == 42

context.setData("score", 30)
context.restart()
discard context.run(proc(text: string) = stdout.write(text))
doAssert context.getGlobal("answer").asInt() == 60

## Safe embedding: explicit capabilities, resource limits, persistent contexts.
import std/[unittest, strutils, os]
import ../src/nifty/scripting
import ../src/nifty/common
import ../src/nifty/interpreterffi

proc foreignDouble(number: int64): int64 {.cdecl.} = number * 2

suite "Nim scripting context":
  test "Bassy-style host functions, data and persistent globals":
    var host = initHost()
    host.addData("delta", 3)
    host.addFunction("advance", 2, proc(args: openArray[int64]): int64 = (args[0] + args[1]) * 2)
    let program = compile("""
var answer: int
thread main() =
  answer = advance(answer, delta)
  echo answer
""", host)
    let runtime = initRuntime(program)
    var output = ""
    let stats = runtime.run(proc(text: string) = output.add text)
    check output == "6\n"
    check runtime.getGlobal("answer").asInt() == 6
    check stats.work > 0
    check stats.outputBytes == 2
    runtime.setData("delta", value(5))
    runtime.restart()
    discard runtime.run()
    check runtime.getGlobal("answer").asInt() == 22
    runtime.reset()
    discard runtime.run()
    check runtime.getGlobal("answer").asInt() == 10
    let second = initRuntime(program)
    discard second.run()
    check second.getGlobal("answer").asInt() == 6

  test "typed queries and copied string results need no libffi":
    var host = initHost()
    host.addData("greeting", "hello")
    host.addData("enabled", true)
    host.addData("weight", 1.25)
    host.addQuery("decorate", [StringValue, BoolValue, FloatValue], StringValue,
      proc(args: openArray[Value]): Value =
        check args[1].asBool()
        check args[2].asFloat() == 1.25
        value("<" & args[0].asString() & ">"))
    let program = compile("""
var answer: string
thread main() =
  answer = decorate(greeting, enabled, weight)
  let letter: char = 'A'
  echo answer, " ", true, " ", 1.25, " ", letter
""", host)
    let runtime = initRuntime(program)
    var output = ""
    discard runtime.run(proc(text: string) = output.add text)
    check output == "<hello> true 1.25 A\n"
    check runtime.getGlobal("answer").asString() == "<hello>"
    runtime.setData("greeting", value("bye"))
    runtime.restart()
    discard runtime.run()
    check runtime.getGlobal("answer").asString() == "<bye>"
    for i in 0 ..< 50:
      runtime.restart()
      discard runtime.run()
    runtime.reset()
    check runtime.getGlobal("greeting").asString() == "bye"
    let literal = initRuntime(compile("""
thread main() =
  let text = decorate("literal", true, 1.25)
  echo text
""", host))
    output = ""
    discard literal.run(proc(text: string) = output.add text)
    check output == "<literal>\n"

  test "isolated hosts disable imports and externs by default":
    const
      ImportScripts = [
        "import maths\nthread main() =\n  discard 0\n",
        "import \"maths.nifty\"\nthread main() =\n  discard 0\n"
      ]
      ExternScript = "extern \"libc\":\n  proc getpid(): int32\nthread main() =\n  discard 0\n"
    for host in [initHost(), initHost(allowExterns = true)]:
      for source in ImportScripts:
        try:
          discard compile(source, host)
          fail()
        except ScriptError as error:
          check "imports are disabled" in error.msg
    for host in [initHost(), initHost(allowImports = true)]:
      try:
        discard compile(ExternScript, host)
        fail()
      except ScriptError as error:
        check "externs are disabled" in error.msg
    try:
      discard compile(ExternScript)
      fail()
    except ScriptError as error:
      check "externs are disabled" in error.msg
    var locked = initHost()
    expect ScriptError: locked.addModule("maths", "const amount = 7\n")
    expect ScriptError:
      locked.allowUnsafeFfi("app", "twice", cast[pointer](foreignDouble),
        [Int64Type], [Int64Type])
    var modules = initHost(allowImports = true)
    modules.addModule("maths", "const amount = 7\n")
    modules.addModule("bad", "extern \"libc\":\n  proc getpid(): int32\n")
    let runtime = newContext("import maths\nthread main() =\n  echo amount\n", modules)
    var output = ""
    discard runtime.run(proc(text: string) = output.add text)
    check output == "7\n"
    expect ScriptError: discard compile("import bad\nthread main() =\n  discard 0\n", modules)
    var foreign = initHost(allowExterns = true)
    foreign.allowUnsafeFfi("app", "twice", cast[pointer](foreignDouble),
      [Int64Type], [Int64Type])
    discard compile("extern \"app\":\n  proc twice(x: int): int\nthread main() =\n  echo twice(21)\n", foreign)

  test "FFI is rejected even when unused, renamed or in supplied modules":
    for source in [
      "extern \"libc\":\n  proc exit(code: int32)\nthread main() =\n  discard 0\n",
      "extern \"nifty\":\n  proc kill \"nifty_stdout_stream\"(): int\nthread main() =\n  discard 0\n",
      "extern \"nifty.host\":\n  proc escape(): int\nthread main() =\n  discard 0\n"]:
      expect ScriptError: discard compile(source)
    var host = initHost(allowImports = true)
    host.addModule("bad", "extern \"libc\":\n  proc getpid(): int32\n")
    expect ScriptError: discard compile("import bad\nthread main() =\n  discard 0\n", host)

  test "imports never consult disk, standard library, environment or URLs":
    for request in ["io", "\"https://example.invalid/script.nifty\"",
        "\"C:/Windows/win.ini\"", "\"../secret.nifty\""]:
      expect NiftyError: discard compile("import " & request & "\nthread main() =\n  discard 0\n")
    var host = initHost(allowImports = true)
    host.addModule("shared", "const amount = 7\n")
    host.addModule("one", "import shared\n")
    host.addModule("two", "import \"./shared.nifty\"\n")
    let runtime = initRuntime(compile("import one\nimport two\nthread main() =\n  echo amount\n", host))
    var output = ""
    discard runtime.run(proc(text: string) = output.add text)
    check output == "7\n"
    host.addModule("game/helper.nifty", "const localAmount = 9\n")
    host.addModule("helper", "const localAmount = 1\n")
    host.addModule("game/entry.nifty", "import helper\n")
    let nested = newContext("import \"game/entry.nifty\"\nthread main() =\n  echo localAmount\n", host)
    output = ""
    discard nested.run(proc(text: string) = output.add text)
    check output == "9\n"

  test "scripts only run source supplied by the host":
    # Plant real code on disk, in the standard library override, and next
    # to the working directory. None of it may reach the script.
    let
      planted = getTempDir() / "nifty_planted_code"
      previousDir = getCurrentDir()
      previousStdlib = getEnv("NIFTY_STDLIB")
      evil = "const amount = 666\n"
    createDir(planted)
    writeFile(planted / "evil.nifty", evil)
    writeFile(planted / "io.nifty", evil)
    writeFile(planted / "_echo.nifty",
      "proc echoText(value: string) =\n  discard 0\n")
    putEnv("NIFTY_STDLIB", planted)
    setCurrentDir(planted)
    defer:
      setCurrentDir(previousDir)
      if previousStdlib.len > 0: putEnv("NIFTY_STDLIB", previousStdlib)
      else: delEnv("NIFTY_STDLIB")
      removeDir(planted)
    var host = initHost(allowImports = true)
    host.addModule("shared", "const amount = 7\n")
    for request in ["evil", "io", "console", "\"evil.nifty\"",
        "\"./evil.nifty\"", "\"" & planted / "evil.nifty" & "\"",
        "\"" & previousDir / "std" / "io.nifty" & "\"",
        "\"https://example.invalid/evil.nifty\"",
        "\"github.com/evil/evil.nifty\""]:
      try:
        discard compile(
          "import " & request & "\nthread main() =\n  echo amount\n", host)
        fail()
      except NiftyError as error:
        check "not provided by the host" in error.msg
    # Supplied modules cannot reach past the host either.
    host.addModule("relay", "import evil\n")
    expect NiftyError:
      discard compile("import relay\nthread main() =\n  discard 0\n", host)
    # Echo uses the built-in callbacks, not a planted standard library.
    let runtime = newContext(
      "import shared\nthread main() =\n  echo \"amount \", amount\n", host)
    var output = ""
    discard runtime.run(proc(text: string) = output.add text)
    check output == "amount 7\n"

  test "host inputs reject direct and indirect mutation":
    var host = initHost()
    host.addData("number", 3)
    host.addData("text", "abc")
    for body in ["number = 9", "discard text.add(\"x\")", "text = \"x\"",
        "if text.len > 0:\n    text[0] = 'A'", "mutate(number)"]:
      expect ScriptError:
        discard compile("proc mutate(x: var int) =\n  x = 8\nthread main() =\n  " & body & "\n", host)
    let runtime = initRuntime(compile("thread main() =\n  if text.len > 0:\n    echo text[0], text.len\n", host))
    discard runtime.run()
    expect ScriptError: runtime.setGlobal("number", value(8))

  test "work and output limits return control and reset recovers":
    var limits = defaultLimits()
    limits.maxWork = 1000
    let runtime = initRuntime(compile("thread main() =\n  for i in 0 ..< 1000000:\n    discard i\n", limits = limits))
    expect ExecutionLimitError: discard runtime.run()
    expect ScriptError: runtime.restart()
    runtime.reset()
    expect ExecutionLimitError: discard runtime.run()
    limits = defaultLimits()
    limits.maxOutputBytes = 2
    let noisy = initRuntime(compile("thread main() =\n  echo \"hello\"\n", limits = limits))
    expect ExecutionLimitError: discard noisy.run()

  test "memory, source and depth limits are enforced":
    var limits = defaultLimits()
    limits.maxMemoryBytes = 128 * 1024
    let hungry = initRuntime(compile("thread main() =\n  var text: string\n  discard text.reserve(1000000)\n", limits = limits))
    expect ExecutionLimitError: discard hungry.run()
    hungry.reset()
    expect ExecutionLimitError: discard hungry.run()
    expect ScriptError:
      discard compile("var huge: array[1000000, int]\nthread main() =\n  discard huge\n", limits = limits)
    limits = defaultLimits()
    limits.maxSourceBytes = 8
    expect ScriptError: discard compile("thread main() =\n  discard 0\n", limits = limits)
    limits = defaultLimits()
    limits.maxCallDepth = 1
    let deep = initRuntime(compile("proc inner() =\n  echo 1\nthread main() =\n  inner()\n", limits = limits))
    expect ExecutionLimitError: discard deep.run()

  test "declaration and token counts are capped":
    proc rejects(source: string, limits: Limits, text: string) =
      ## Checks that compiling fails with the named limit.
      var message = ""
      try:
        discard compile(source, limits = limits)
      except ScriptError as e:
        message = e.msg
      check text in message
    proc globals(n: int): string =
      ## Builds a script that declares n globals.
      for i in 0 ..< n:
        result.add "var g" & $i & ": int\n"
      result.add "thread main() =\n  echo 1\n"
    let defaults = defaultLimits()
    check defaults.maxSourceBytes == 1024 * 1024
    check defaults.maxGlobals == 10_000
    check defaults.maxRoutines == 10_000
    check defaults.maxTypes == 10_000
    check defaults.maxConsts == 10_000
    check defaults.maxTokens == 250_000
    rejects(globals(10_001), defaults, "script global limit exceeded")
    var limits = defaultLimits()
    limits.maxGlobals = 3
    discard compile(globals(3), limits = limits)
    rejects(globals(4), limits, "script global limit exceeded")
    limits = defaultLimits()
    limits.maxRoutines = 2
    discard compile("func a(): int =\n  return 1\n" &
      "thread main() =\n  echo a()\n", limits = limits)
    rejects("func a(): int =\n  return 1\nfunc b(): int =\n  return 2\n" &
      "thread main() =\n  echo a(), b()\n", limits,
      "script routine limit exceeded")
    # Generic instances replace their template after checking, so a
    # template with two instances passes the parse count but not this one.
    limits.maxRoutines = 2
    rejects("func g(x: $T): int =\n  return 1\n" &
      "thread main() =\n  echo g(1), g(true)\n", limits,
      "script routine limit exceeded")
    limits = defaultLimits()
    limits.maxTypes = 1
    discard compile("object A =\n  x: int\nvar a: A\n" &
      "thread main() =\n  echo a.x\n", limits = limits)
    rejects("object A =\n  x: int\nobject B =\n  y: int\n" &
      "var a: A\nvar b: B\nthread main() =\n  echo a.x, b.y\n", limits,
      "script type limit exceeded")
    limits = defaultLimits()
    limits.maxConsts = 1
    discard compile("const A = 1\nthread main() =\n  echo A\n",
      limits = limits)
    rejects("const A = 1\nconst B = 2\nthread main() =\n  echo A, B\n",
      limits, "script const limit exceeded")
    limits = defaultLimits()
    limits.maxTokens = 20
    discard compile("thread main() =\n  echo 1\n", limits = limits)
    rejects(globals(4), limits, "script token limit exceeded")
    # Host functions and data are trusted and do not use the script budget.
    var host = initHost()
    for i in 0 ..< 5:
      host.addData("d" & $i, i)
      host.addFunction("f" & $i, 1,
        proc(args: openArray[int64]): int64 = args[0])
    limits = defaultLimits()
    limits.maxGlobals = 1
    limits.maxRoutines = 1
    discard compile("var g: int\nthread main() =\n  echo f0(d1)\n",
      host, limits)
    for bad in [0, 100_001]:
      limits = defaultLimits()
      limits.maxGlobals = bad
      rejects("thread main() =\n  echo 1\n", limits,
        "invalid scripting limits")

  test "callbacks cannot reenter the same runtime; exceptions recover":
    var host = initHost()
    var runtime: Runtime
    var throw = true
    host.addFunction("callback", [], VoidValue, proc(args: openArray[Value]): Value =
      expect ScriptError: discard runtime.run()
      expect ScriptError: runtime.reset()
      if throw: raise newException(ValueError, "host failure")
      Value())
    runtime = initRuntime(compile("thread main() =\n  callback()\n", host))
    expect ValueError: discard runtime.run()
    throw = false
    runtime.reset()
    discard runtime.run()

  test "multiple workers and OS synchronization are unavailable":
    expect ScriptError: discard compile("thread 2 main() =\n  discard 0\n")
    expect ScriptError: discard compile("var lock: Lock\nthread main() =\n  discard 0\n")

  test "explicit unsafe FFI requires an exact symbol and ABI":
    var host = initHost(allowExterns = true)
    host.allowUnsafeFfi("app", "twice", cast[pointer](foreignDouble),
      [Int64Type], [Int64Type])
    expect ScriptError:
      discard compile("extern \"app\":\n  proc other(x: int): int\nthread main() =\n  discard 0\n", host)
    let wrongAbi = compile("extern \"app\":\n  proc twice(x: int32): int\nthread main() =\n  echo twice(21)\n", host)
    expect ScriptError: discard initRuntime(wrongAbi)
    if foreignAvailable():
      let runtime = initRuntime(compile("extern \"app\":\n  proc twice(x: int): int\nthread main() =\n  echo twice(21)\n", host))
      var output = ""
      discard runtime.run(proc(text: string) = output.add text)
      check output == "42\n"
    else:
      skip()

  test "a program supports schema-compatible hosts and nested runtimes":
    var first = initHost()
    first.addData("input", 2)
    first.addFunction("calculate", 1, proc(args: openArray[int64]): int64 = args[0] * 2)
    let program = compile("thread main() =\n  echo calculate(input)\n", first)
    var second = initHost()
    second.addData("input", 3)
    second.addFunction("calculate", 1, proc(args: openArray[int64]): int64 = args[0] * 3)
    let runtime = initRuntime(program, second)
    var output = ""
    discard runtime.run(proc(text: string) = output.add text)
    check output == "9\n"
    var wrong = initHost()
    wrong.addData("input", 3)
    wrong.addFunction("calculate", 2, proc(args: openArray[int64]): int64 = 0)
    expect ScriptError: discard initRuntime(program, wrong)
    let nested = newContext("thread main() =\n  var text: string\n  discard text.add(\"inner\")\n")
    var outer = initHost()
    outer.addFunction("nested", [], VoidValue, proc(args: openArray[Value]): Value =
      nested.restart()
      discard nested.run()
      Value())
    let context = newContext("thread main() =\n  var text: string\n  discard text.add(\"outer\")\n  nested()\n  echo text\n", outer)
    output = ""
    discard context.run(proc(text: string) = output.add text)
    check output == "outer\n"

  test "host work is charged before entering a callback":
    var host = initHost()
    var called = false
    host.addFunction("expensive", [], VoidValue, proc(args: openArray[Value]): Value =
      called = true
      Value(), workUnits = 10000)
    var limits = defaultLimits()
    limits.maxWork = 1000
    let runtime = newContext("thread main() =\n  expensive()\n", host, limits)
    expect ExecutionLimitError: discard runtime.run()
    check not called

  test "source positions cannot forge the trusted host module":
    expect ScriptError:
      discard compile(repeat('\n', fileLineBase) & "thread main() =\n  discard 0\n")

  test "script names may shadow host names without changing host data":
    var host = initHost()
    host.addData("score", 21)
    let runtime = newContext("var score: int\nthread main() =\n  score = host.score\n  echo score\n", host)
    check runtime.getGlobal("score").asInt() == 0
    check runtime.getGlobal("host.score").asInt() == 21
    runtime.setData("score", 30)
    discard runtime.run()
    check runtime.getGlobal("score").asInt() == 30
    runtime.setGlobal("score", 5)
    check runtime.getGlobal("host.score").asInt() == 30
    runtime.reset()
    check runtime.getGlobal("score").asInt() == 0
    check runtime.getGlobal("host.score").asInt() == 30

  test "safe execution works with an unavailable foreign-call runtime":
    let previous = getEnv("NIFTY_LIBFFI")
    let existed = existsEnv("NIFTY_LIBFFI")
    putEnv("NIFTY_LIBFFI", "nifty-deliberately-missing-libffi")
    try:
      var host = initHost()
      host.addFunction("double", 1, proc(args: openArray[int64]): int64 = args[0] * 2)
      let runtime = newContext("thread main() =\n  echo double(21), \" \", 1.0\n", host)
      var output = ""
      discard runtime.run(proc(text: string) = output.add text)
      check output == "42 1\n"
    finally:
      if existed: putEnv("NIFTY_LIBFFI", previous)
      else: delEnv("NIFTY_LIBFFI")

  test "callback type errors unwind to the host and reset recovers":
    var host = initHost()
    var wrong = true
    host.addFunction("result", [], IntValue, proc(args: openArray[Value]): Value =
      if wrong: value("wrong") else: value(1))
    let runtime = newContext("thread main() =\n  echo result()\n", host)
    expect ScriptError: discard runtime.run()
    expect ScriptError: runtime.restart()
    runtime.reset()
    wrong = false
    discard runtime.run()

  test "host updates and globals are type checked, snapshots stay independent":
    var host = initHost()
    host.addData("input", 4)
    let program = compile("var score: 0 .. 10\nthread main() =\n  echo score, input\n", host)
    host.setData("input", 8)
    let first = initRuntime(program)
    let second = initRuntime(program, host)
    check first.getGlobal("input").asInt() == 4
    check second.getGlobal("input").asInt() == 8
    first.setGlobal("score", 9)
    check first.getGlobal("score").asInt() == 9
    check second.getGlobal("score").asInt() == 0
    expect ScriptError: first.setGlobal("score", 11)
    expect ScriptError: first.setData("input", "wrong")
    check first.getGlobal("score").asInt() == 9
    check first.getGlobal("input").asInt() == 4

## Nifty — nimmy's super-static brother.
## A small systems language with Nim-flavored syntax that
## compiles to C, ARM64, or AMD64. See spec.md for the language definition.
##
## Pipeline: parser -> checker + semantics -> C, or lowering -> IR -> native.

import nifty/[common, parser, checker, codegen, report, loader, types]

export common

var lastExternLibs*: seq[string] ## non-libc libs of the last compile

proc checkedModule*(src, moduleName: string, dir = ""): Module =
  ## Checks imports and prepares shared semantics before backend selection.
  result = parse(loadTokens(src, moduleName, dir))
  check(result)

proc compileToC*(src: string, moduleName: string, dir = ""): string =
  ## Compile nifty source text (plus its imports) to a C translation unit.
  let m = checkedModule(src, moduleName, dir)
  lastExternLibs = @[]
  for lib in m.externLibs:
    if lib != "libc":
      lastExternLibs.add lib
  generate(m, moduleName)

proc reportFor*(src: string, moduleName: string, dir = ""): string =
  ## Report static storage and distinguish runtime heap and work costs.
  let m = checkedModule(src, moduleName, dir)
  buildReport(m, moduleName)

when isMainModule:
  import std/[os, strutils]
  import nifty/[lowering, nativeruntime, nativereports, nativeunroll]

  try:
    if tryRunEmbedded():
      quit(0)
  except CatchableError as e:
    quit("nifty: " & e.msg, 1)

  const usage = """
nifty - a checked language with C, ARM64, and AMD64 backends

usage:
  nifty [run] file.nifty [options]   build and, if there are no errors, run (default)
  nifty build file.nifty [options]   build only
  nifty report file.nifty          backend report (static RAM, heap, ops)

options:
  --backend:c|arm64|amd64          backend (default: native host architecture)
  --opt:none|speed                native optimization (default: speed)
  -o path                         output path
  --emit-c                        write reference C from the checked AST
  --emit-ir                       write selected native IR without running
  --emit-native                   write a native image without running
"""
  var cmd = "run"
  var sawCmd = false
  var srcPath = ""
  var outPath = ""
  var emission = ""
  var backend = when defined(arm64): "arm64" else: "amd64"
  var optimization = SpeedOptimization
  let params = commandLineParams()
  var i = 0
  while i < params.len:
    let a = params[i]
    case a
    of "run", "build", "report":
      if sawCmd or srcPath.len > 0: quit(usage, 1)
      cmd = a
      sawCmd = true
    of "-o":
      inc i
      if i >= params.len: quit(usage, 1)
      outPath = params[i]
    of "--emit-c", "-c", "--emit-ir", "--emit-native":
      if emission.len > 0:
        quit("nifty: choose one output format", 1)
      emission = if a == "-c": "--emit-c" else: a
    of "--backend":
      inc i
      if i >= params.len: quit(usage, 1)
      backend = params[i]
    of "-h", "--help":
      echo usage
      quit(0)
    else:
      if a.startsWith("--backend:") or a.startsWith("--backend="):
        backend = a[10 .. ^1]
      elif a.startsWith("--opt:") or a.startsWith("--opt="):
        case a[6 .. ^1]
        of "none": optimization = NoOptimization
        of "speed": optimization = SpeedOptimization
        else: quit("nifty: unknown optimization " & a[6 .. ^1], 1)
      elif a.startsWith("-"):
        quit("nifty: unknown option " & a, 1)
      else:
        if srcPath.len > 0: quit(usage, 1)
        srcPath = a
    inc i
  if srcPath == "":
    quit(usage, 1)
  if backend notin ["c", "arm64", "amd64"]:
    quit("nifty: unknown backend " & backend, 1)
  if emission == "--emit-c":
    backend = "c"
  if backend == "c" and emission in ["--emit-ir", "--emit-native"]:
    quit("nifty: select arm64 or amd64 for native output", 1)
  let modName = srcPath # complete path: errors are openable as printed
  if cmd == "report":
    try:
      let source = readFile(srcPath)
      if backend == "c":
        stdout.write reportFor(source, modName, srcPath.parentDir)
      else:
        let target = if backend == "arm64": Arm64Target else: Amd64Target
        var checked = checkedModule(source, modName, srcPath.parentDir)
        if optimization == SpeedOptimization:
          checked = unrollNative(checked)
        let plan = lowerNative(checked, modName)
        let program = buildNativeProgram(plan, target,
          optimization = optimization)
        stdout.write nativeReport(program.plan, program.image, modName, checked)
    except CatchableError as e:
      quit("nifty: " & e.msg, 1)
    quit(0)
  let base = srcPath.changeFileExt("")
  let bin = if outPath.len > 0: outPath else: base
  try:
    let source = readFile(srcPath)
    if backend == "c":
      let cCode = compileToC(source, modName, srcPath.parentDir)
      let cPath = if emission == "--emit-c" and outPath.len > 0:
          outPath
        else: base & ".c"
      writeFile(cPath, cCode)
      if emission == "--emit-c":
        echo cPath
        quit(0)
      var link = ""
      for lib in lastExternLibs:
        link.add " " & quoteShell("-l" & lib)
      if execShellCmd("cc -O2 -pthread -fno-strict-aliasing " &
          "-ffp-contract=off -o " & quoteShell(bin) & " " &
          quoteShell(cPath) & link) != 0:
        quit("nifty: C compilation failed", 1)
    else:
      let target = if backend == "arm64": Arm64Target else: Amd64Target
      var checked = checkedModule(source, modName, srcPath.parentDir)
      if optimization == SpeedOptimization:
        checked = unrollNative(checked)
      let plan = lowerNative(checked, modName)
      if emission == "--emit-ir":
        let path = if outPath.len > 0: outPath else: base & ".ir"
        writeFile(path, optimizeNative(plan, optimization).module.dumpModule())
        echo path
        quit(0)
      let program = buildNativeProgram(plan, target,
        optimization = optimization)
      if emission == "--emit-native":
        let path = if outPath.len > 0: outPath else: base & ".niftybin"
        writeNativeFile(program, path)
        echo path
        quit(0)
      writeStandalone(program, bin)
    echo "built ", bin
    if cmd == "run":
      let exe = bin.absolutePath()
      when defined(macosx) and defined(arm64):
        if backend == "amd64":
          quit(execShellCmd("/usr/bin/arch -x86_64 " & quoteShell(exe)))
      quit(execShellCmd(quoteShell(exe)))
  except CatchableError as e:
    quit("nifty: " & e.msg, 1)

## Nifty — nimmy's super-static brother.
## A small systems language with Nim-flavored syntax that
## compiles to C, ARM64, AMD64, or memory64 WebAssembly.
##
## Pipeline: parser -> checker + semantics -> C, or lowering -> IR -> native.

import nifty/[common, parser, checker, codegen, report, loader, types]
import nifty/[lowering, nativeunroll, wasmfiles]

export common

var lastExternLibs*: seq[string] ## non-libc libs of the last compile

proc checkedModule*(src, moduleName: string, dir = "",
    portableIo = false): Module =
  ## Checks imports and prepares shared semantics before backend selection.
  result = parse(loadTokens(src, moduleName, dir, portableIo))
  check(result)

proc compileToC*(src: string, moduleName: string, dir = ""): string =
  ## Compile nifty source text (plus its imports) to a C translation unit.
  let m = checkedModule(src, moduleName, dir)
  lastExternLibs = @[]
  for lib in m.externLibs:
    if lib notin ["libc", "nifty"]:
      lastExternLibs.add lib
  generate(m, moduleName)

proc reportFor*(src: string, moduleName: string, dir = ""): string =
  ## Report static storage and distinguish runtime heap and work costs.
  let m = checkedModule(src, moduleName, dir)
  buildReport(m, moduleName)

proc compileToWasm*(src: string, moduleName = "input", dir = "",
    optimization = SpeedOptimization): string =
  ## Compiles checked source to a complete memory64 module without tools.
  var checked = checkedModule(src, moduleName, dir, portableIo = true)
  if optimization == SpeedOptimization:
    checked = unrollNative(checked)
  buildWasmProgram(lowerNative(checked, moduleName, portableIo = true),
    optimization).bytes

when isMainModule:
  import std/[os, osproc, strutils]
  import nifty/[nativeruntime, nativereports, ctoolchains]

  try:
    if tryRunEmbedded():
      quit(0)
  except CatchableError as e:
    quit("nifty: " & e.msg, 1)

  const usage = """
nifty - a checked language with C, ARM64, AMD64, and WASM64 backends

usage:
  nifty [run] file.nifty [options]   build and, if there are no errors, run (default)
  nifty build file.nifty [options]   build only
  nifty report file.nifty          backend report (static RAM, heap, ops)

options:
  --offline                       use cached URL imports without network access
  --update-imports                refresh URL imports and update nifty.lock
  --backend:c|arm64|amd64|wasm64   backend (wasm aliases wasm64)
  --opt:none|speed                IR optimization (default: speed)
  -o path                         output path
  --emit-c                        write reference C from the checked AST
  --emit-ir                       write selected native IR without running
  --emit-native                   write a native image without running
  --emit-wasm                     write a memory64 module without running
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
    of "--emit-c", "-c", "--emit-ir", "--emit-native", "--emit-wasm":
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
    of "--offline":
      putEnv("NIFTY_OFFLINE", "1")
    of "--update-imports":
      putEnv("NIFTY_UPDATE_IMPORTS", "1")
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
  if backend == "wasm":
    backend = "wasm64"
  if backend notin ["c", "arm64", "amd64", "wasm64"]:
    quit("nifty: unknown backend " & backend, 1)
  if emission == "--emit-c":
    backend = "c"
  elif emission == "--emit-wasm":
    backend = "wasm64"
  if backend == "c" and emission in ["--emit-ir", "--emit-native"]:
    quit("nifty: select arm64 or amd64 for native output", 1)
  if backend == "wasm64" and emission == "--emit-native":
    quit("nifty: wasm64 uses --emit-wasm; --emit-native requires arm64 or amd64", 1)
  let modName = srcPath # complete path: errors are openable as printed
  if cmd == "report":
    try:
      let source = readFile(srcPath)
      if backend == "c":
        stdout.write reportFor(source, modName, srcPath.parentDir)
      else:
        var checked = checkedModule(source, modName, srcPath.parentDir,
          portableIo = backend == "wasm64")
        if optimization == SpeedOptimization:
          checked = unrollNative(checked)
        let plan = lowerNative(checked, modName, portableIo = backend == "wasm64")
        if backend == "wasm64":
          stdout.write wasmReport(buildWasmProgram(plan, optimization), modName)
        else:
          let target = if backend == "arm64": Arm64Target else: Amd64Target
          let program = buildNativeProgram(plan, target,
            optimization = optimization)
          stdout.write nativeReport(program.plan, program.image, modName, checked)
    except CatchableError as e:
      quit("nifty: " & e.msg, 1)
    quit(0)
  let base = srcPath.changeFileExt("")
  let selected = if outPath.len > 0: outPath
    elif backend == "wasm64": base & ".wasm"
    else: base
  let bin = when defined(windows):
      if backend != "wasm64" and selected.splitFile.ext.len == 0:
        selected & ".exe"
      else: selected
    else: selected
  try:
    let source = readFile(srcPath)
    if backend == "wasm64":
      validateWasmOutput(bin, srcPath)
    if backend == "c":
      let cCode = compileToC(source, modName, srcPath.parentDir)
      let cPath = if emission == "--emit-c" and outPath.len > 0:
          outPath
        else: base & ".c"
      writeFile(cPath, cCode)
      if emission == "--emit-c":
        echo cPath
        quit(0)
      if execShellCmd(cCompileCommand(cPath, bin, lastExternLibs)) != 0:
        quit("nifty: C compilation failed", 1)
    else:
      var checked = checkedModule(source, modName, srcPath.parentDir,
        portableIo = backend == "wasm64")
      if optimization == SpeedOptimization:
        checked = unrollNative(checked)
      let plan = lowerNative(checked, modName, portableIo = backend == "wasm64")
      if emission == "--emit-ir":
        let path = if outPath.len > 0: outPath else: base & ".ir"
        if backend == "wasm64":
          validateWasmOutput(path, srcPath)
        writeFile(path, optimizeNative(plan, optimization,
          specializeMath = backend != "wasm64").module.dumpModule())
        echo path
        quit(0)
      if backend == "wasm64":
        writeWasmFile(buildWasmProgram(plan, optimization), bin, srcPath)
        if emission == "--emit-wasm":
          echo bin
          quit(0)
      else:
        let target = if backend == "arm64": Arm64Target else: Amd64Target
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
      if backend == "wasm64":
        let engine = getEnv("NIFTY_WASMTIME", findExe("wasmtime"))
        if engine.len == 0:
          quit("nifty: running wasm64 requires Wasmtime; set NIFTY_WASMTIME " &
            "or run the module with tools/wasm/run.mjs", 1)
        let child = startProcess(engine, args = @[exe],
          options = {poParentStreams})
        let status = child.waitForExit()
        child.close()
        quit(status)
      when defined(macosx) and defined(arm64):
        if backend == "amd64":
          quit(execShellCmd("/usr/bin/arch -x86_64 " & quoteShell(exe)))
      when defined(windows):
        let child = startProcess(exe, options = {poParentStreams})
        let status = child.waitForExit()
        child.close()
        quit(status)
      else:
        quit(execShellCmd(quoteShell(exe)))
  except CatchableError as e:
    quit("nifty: " & e.msg, 1)

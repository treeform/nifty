## Nifty — nimmy's super-static brother.
## A tiny fixed-everything systems language with Nim-flavored syntax that
## compiles to portable C. See spec.md for the language definition.
##
## Pipeline: lexer -> parser -> checker -> codegen.

import nifty/[common, lexer, parser, checker, codegen]

export common

proc compileToC*(src: string, moduleName: string): string =
  ## Compile nifty source text to a C translation unit.
  let m = parse(tokenize(src))
  check(m)
  generate(m, moduleName)

when isMainModule:
  import std/os

  const usage = """
nifty - compile a .nifty file to C and build it with cc

usage:
  nifty [run] file.nifty [options]   build and, if there are no errors, run (default)
  nifty build file.nifty [options]   build only

options:
  -o binary   output binary path (default: source path without extension)
  --emit-c    only write the .c file, do not run cc
"""
  var cmd = "run"
  var sawCmd = false
  var srcPath = ""
  var outPath = ""
  var emitOnly = false
  let params = commandLineParams()
  var i = 0
  while i < params.len:
    let a = params[i]
    case a
    of "run", "build":
      if sawCmd or srcPath.len > 0: quit(usage, 1)
      cmd = a
      sawCmd = true
    of "-o":
      inc i
      if i >= params.len: quit(usage, 1)
      outPath = params[i]
    of "--emit-c", "-c":
      emitOnly = true
    of "-h", "--help":
      echo usage
      quit(0)
    else:
      if srcPath.len > 0: quit(usage, 1)
      srcPath = a
    inc i
  if srcPath == "":
    quit(usage, 1)
  let modName = srcPath.extractFilename
  var cCode = ""
  try:
    cCode = compileToC(readFile(srcPath), modName)
  except NiftyError as e:
    quit("nifty: " & srcPath & ": " & e.msg, 1)
  let base = srcPath.changeFileExt("")
  let cPath = base & ".c"
  writeFile(cPath, cCode)
  if emitOnly:
    echo cPath
    quit(0)
  let bin = if outPath.len > 0: outPath else: base
  if execShellCmd("cc -O2 -pthread -o " & quoteShell(bin) & " " & quoteShell(cPath)) != 0:
    quit("nifty: C compilation failed", 1)
  echo "built ", bin
  if cmd == "run":
    let exe = if '/' in bin: bin else: "./" & bin
    quit(execShellCmd(quoteShell(exe)))

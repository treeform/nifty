## Imports: `import name` at the top of a file splices name.nifty into
## the token stream, once per file (splice-once by canonical path).
## The import graph must be a DAG - a cycle is a compile error, the same
## principle as no-recursion, one level up. Because splicing follows the
## import order, declare-before-use holds across files and every
## whole-program proof works unchanged. One program, one namespace.

import std/[os, sets, strutils]
import common, lexer

type
  Loader = object
    dir: string              # imports resolve next to the importing file
    standardDirs: seq[string] # executable-relative distribution, then development
    portableIo: bool         # WASI uses the portable write adapter on every host
    seen: HashSet[string]    # canonical paths already spliced
    stack: seq[string]       # canonical import chain, for cycle detection
    names: seq[string]       # display names matching the stack

proc atIdent(toks: seq[Token], i: int, s: string): bool =
  i < toks.len and toks[i].kind == IdentToken and toks[i].text == s

proc processImports(ld: var Loader, toks: seq[Token]): seq[Token]

proc standardLibraryDirs(): seq[string] =
  ## A distribution can put std beside nifty or under prefix/lib/nifty.
  ## The source-tree fallback also supports embedding the compiler in tests.
  let override = getEnv("NIFTY_STDLIB")
  if override.len > 0:
    result.add override
  let executableDir = getAppDir()
  result.add executableDir / "std"
  result.add executableDir / "lib" / "nifty"
  result.add executableDir.parentDir / "lib" / "nifty"
  result.add executableDir.parentDir / "std"
  result.add currentSourcePath().parentDir.parentDir.parentDir / "std"

proc importPath(ld: Loader, name: string, line: int): string =
  let moduleName =
    if name == "_io_platform":
      if ld.portableIo: "_io_posix"
      else:
        when defined(windows): "_io_windows"
        else: "_io_posix"
    else: name
  result = ld.dir / moduleName & ".nifty"
  if fileExists(result):
    return
  for directory in ld.standardDirs:
    let candidate = directory / moduleName & ".nifty"
    if fileExists(candidate):
      return candidate
  err(line, "cannot find import '" & name & "' (" &
    result & " does not exist)")

proc spliceImport(ld: var Loader, name: string, line: int): seq[Token] =
  # Display names keep the full path as the compiler sees it, so errors
  # are directly openable from where the compiler ran.
  let path = ld.importPath(name, line)
  let display = path
  let canon =
    try: expandFilename(path)
    except OSError: err(line, "cannot find import '" & name & "' (" &
      path & " does not exist)")
  if canon in ld.stack:
    err(line, "import cycle: " & ld.names.join(" -> ") & " -> " & display)
  if canon in ld.seen:
    return @[] # already spliced once; that is all a program needs
  ld.seen.incl canon
  ld.stack.add canon
  ld.names.add display
  srcFiles.add display
  let base = (srcFiles.len - 1) * fileLineBase
  var sub = tokenize(readFile(canon), base)
  if sub.len > 0 and sub[^1].kind == EofToken:
    sub.setLen(sub.len - 1)
  let parentDir = ld.dir
  ld.dir = canon.parentDir
  result = ld.processImports(sub)
  ld.dir = parentDir
  discard ld.stack.pop
  discard ld.names.pop

proc processImports(ld: var Loader, toks: seq[Token]): seq[Token] =
  ## Handle the leading `import name` lines, splicing each target in
  ## place; everything after the imports passes through untouched.
  var i = 0
  while atIdent(toks, i, "import"):
    if i + 1 >= toks.len or toks[i + 1].kind notin {IdentToken, StrToken}:
      err(toks[i].line, "import needs a module name (import mathmod)")
    let name = toks[i + 1].text
    let line = toks[i].line
    var j = i + 2
    if j < toks.len and toks[j].kind == NewlineToken:
      inc j
    result.add ld.spliceImport(name, line)
    i = j
  result.add toks[i .. ^1]

proc loadTokens*(mainSrc, mainName, dir: string,
    portableIo = false): seq[Token] =
  ## Tokenize a whole program: the main source plus every import,
  ## spliced once each, in import order.
  srcFiles = @[mainName]
  var ld = Loader(dir: dir, standardDirs: standardLibraryDirs(),
    portableIo: portableIo)
  var toks = tokenize(mainSrc, 0)
  ld.processImports(toks)


proc loadStandardTokens*(name: string, portableIo = false): seq[Token] =
  ## Loads an implicit support module without resetting user source locations.
  let directories = standardLibraryDirs()
  for directory in directories:
    if fileExists(directory / name & ".nifty"):
      var ld = Loader(dir: directory, standardDirs: directories,
        portableIo: portableIo)
      result = ld.spliceImport(name, 1)
      result.add(Token(kind: EofToken, line: 1))
      return
  err(1, "cannot find standard library support module '" & name & "'")

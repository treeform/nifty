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
    seen: HashSet[string]    # canonical paths already spliced
    stack: seq[string]       # canonical import chain, for cycle detection
    names: seq[string]       # display names matching the stack

proc atIdent(toks: seq[Token], i: int, s: string): bool =
  i < toks.len and toks[i].kind == IdentToken and toks[i].text == s

proc processImports(ld: var Loader, toks: seq[Token]): seq[Token]

proc spliceImport(ld: var Loader, name: string, line: int): seq[Token] =
  let path = ld.dir / name & ".nifty"
  let display = name & ".nifty"
  let canon =
    try: expandFilename(path)
    except OSError: err(line, "cannot find import '" & name & "' (no " &
      display & " next to the importing file)")
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
  result = ld.processImports(sub)
  discard ld.stack.pop
  discard ld.names.pop

proc processImports(ld: var Loader, toks: seq[Token]): seq[Token] =
  ## Handle the leading `import name` lines, splicing each target in
  ## place; everything after the imports passes through untouched.
  var i = 0
  while atIdent(toks, i, "import"):
    if i + 1 >= toks.len or toks[i + 1].kind != IdentToken:
      err(toks[i].line, "import needs a module name (import mathmod)")
    let name = toks[i + 1].text
    let line = toks[i].line
    var j = i + 2
    if j < toks.len and toks[j].kind == NewlineToken:
      inc j
    result.add ld.spliceImport(name, line)
    i = j
  result.add toks[i .. ^1]

proc loadTokens*(mainSrc, mainName, dir: string): seq[Token] =
  ## Tokenize a whole program: the main source plus every import,
  ## spliced once each, in import order.
  srcFiles = @[mainName]
  var ld = Loader(dir: dir)
  var toks = tokenize(mainSrc, 0)
  ld.processImports(toks)

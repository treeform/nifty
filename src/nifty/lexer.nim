## Tokenizer: source text -> tokens, including indent/dedent tokens.

import std/strutils
import common

type
  TokKind* = enum
    IdentToken, IntToken, StrToken, OpToken, NewlineToken, IndentToken, DedentToken, EofToken
  Token* = object
    kind*: TokKind
    text*: string
    line*: int

const multiOps = ["..<", "..", "==", "!=", "<=", ">="]
const singleOps = {'+', '-', '*', '/', '%', '(', ')', '[', ']', ':', ',', '=', '<', '>', '.', '?'}

proc tokenize*(src: string, baseLine = 0): seq[Token] =
  ## Turn source text into tokens, including indent/dedent tokens.
  ## baseLine is the file-id encoding offset (see common.fileLineBase).
  var indents = @[0]
  var lineNo = baseLine
  for rawLine in src.splitLines:
    inc lineNo
    # Cut off comments (a '#' outside a string literal).
    var line = rawLine
    var inStr = false
    var i = 0
    while i < line.len:
      let c = line[i]
      if inStr:
        if c == '\\': inc i
        elif c == '"': inStr = false
      else:
        if c == '"': inStr = true
        elif c == '#':
          line = line[0 ..< i]
          break
      inc i
    if line.strip.len == 0:
      continue
    # Indentation.
    var ind = 0
    while ind < line.len and line[ind] == ' ':
      inc ind
    if line[ind] == '\t':
      err(lineNo, "tabs are not allowed; indent with spaces")
    if ind > indents[^1]:
      indents.add ind
      result.add Token(kind: IndentToken, line: lineNo)
    else:
      while ind < indents[^1]:
        discard indents.pop
        result.add Token(kind: DedentToken, line: lineNo)
      if ind != indents[^1]:
        err(lineNo, "inconsistent indentation")
    # Tokens on the line.
    var p = ind
    while p < line.len:
      let c = line[p]
      if c == ' ':
        inc p
      elif c.isDigit:
        let s = p
        while p < line.len and (line[p].isDigit or line[p] == '_'):
          inc p
        result.add Token(kind: IntToken, text: line[s ..< p].replace("_", ""), line: lineNo)
      elif c.isAlphaAscii or c == '_':
        let s = p
        while p < line.len and (line[p].isAlphaNumeric or line[p] == '_'):
          inc p
        result.add Token(kind: IdentToken, text: line[s ..< p], line: lineNo)
      elif c == '"':
        inc p
        var s = ""
        while p < line.len and line[p] != '"':
          if line[p] == '\\':
            inc p
            if p >= line.len:
              err(lineNo, "unterminated string escape")
            case line[p]
            of 'n': s.add '\n'
            of 't': s.add '\t'
            of '"': s.add '"'
            of '\\': s.add '\\'
            else: err(lineNo, "unknown escape: \\" & line[p])
          else:
            s.add line[p]
          inc p
        if p >= line.len:
          err(lineNo, "unterminated string")
        inc p
        result.add Token(kind: StrToken, text: s, line: lineNo)
      else:
        var op = ""
        for m in multiOps:
          if line.len - p >= m.len and line[p ..< p + m.len] == m:
            op = m
            break
        if op == "":
          if c in singleOps:
            op = $c
          else:
            err(lineNo, "unexpected character: '" & $c & "'")
        result.add Token(kind: OpToken, text: op, line: lineNo)
        p += op.len
    result.add Token(kind: NewlineToken, line: lineNo)
  while indents.len > 1:
    discard indents.pop
    result.add Token(kind: DedentToken, line: lineNo)
  result.add Token(kind: EofToken, line: lineNo)

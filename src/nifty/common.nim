## Shared error handling for all nifty compiler stages.
##
## Every token line number encodes its source file: file index times
## fileLineBase plus the 1-based line. err decodes it back to name:line.

import std/[tables, strutils]

type
  NiftyError* = object of CatchableError

const fileLineBase* = 1_000_000

var srcFiles*: seq[string] ## display names, indexed by file id
var symbolNames*: Table[string, string] ## Internal module bindings -> source spelling.

proc locOf*(line: int): string =
  if srcFiles.len > 0:
    let f = line div fileLineBase
    let l = line mod fileLineBase
    let name = if f < srcFiles.len: srcFiles[f] else: "?"
    return name & ":" & $l
  "line " & $line

proc err*(line: int, msg: string) {.noreturn.} =
  var display = ""
  var index = 0
  while index < msg.len:
    if msg[index].isAlphaAscii or msg[index] == '_':
      let start = index
      while index < msg.len and (msg[index].isAlphaNumeric or msg[index] == '_'):
        inc index
      let word = msg[start ..< index]
      display.add symbolNames.getOrDefault(word, word)
    else:
      display.add msg[index]
      inc index
  raise newException(NiftyError, locOf(line) & ": " & display)

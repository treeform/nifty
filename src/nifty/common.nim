## Shared error handling for all nifty compiler stages.
##
## Every token line number encodes its source file: file index times
## fileLineBase plus the 1-based line. err decodes it back to name:line.

type
  NiftyError* = object of CatchableError

const fileLineBase* = 1_000_000

var srcFiles*: seq[string] ## display names, indexed by file id

proc locOf*(line: int): string =
  if srcFiles.len > 0:
    let f = line div fileLineBase
    let l = line mod fileLineBase
    let name = if f < srcFiles.len: srcFiles[f] else: "?"
    return name & ":" & $l
  "line " & $line

proc err*(line: int, msg: string) {.noreturn.} =
  raise newException(NiftyError, locOf(line) & ": " & msg)

## Shared error handling for all nifty compiler stages.

type
  NiftyError* = object of CatchableError

proc err*(line: int, msg: string) {.noreturn.} =
  raise newException(NiftyError, "line " & $line & ": " & msg)

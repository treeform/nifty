## Checks literal delimiters, escapes, comments, and lexical diagnostics.
import ../src/nifty/[common, lexer]

const LiteralSource = """'#' '"' '\'' '\\' "#\"#" "\\#" # ' " \
"""

block:
  let tokens = tokenize(LiteralSource)
  doAssert tokens == @[
    Token(kind: IntToken, text: "35", line: 1),
    Token(kind: IntToken, text: "34", line: 1),
    Token(kind: IntToken, text: "39", line: 1),
    Token(kind: IntToken, text: "92", line: 1),
    Token(kind: StrToken, text: "#\"#", line: 1),
    Token(kind: StrToken, text: "\\#", line: 1),
    Token(kind: NewlineToken, line: 1),
    Token(kind: EofToken, line: 2)
  ]

block:
  let tokens = tokenize("""# ' " \
item
  # ' " \
  '#'
# ' " \
next
""")
  doAssert tokens == @[
    Token(kind: IdentToken, text: "item", line: 2),
    Token(kind: NewlineToken, line: 2),
    Token(kind: IndentToken, line: 4),
    Token(kind: IntToken, text: "35", line: 4),
    Token(kind: NewlineToken, line: 4),
    Token(kind: DedentToken, line: 6),
    Token(kind: IdentToken, text: "next", line: 6),
    Token(kind: NewlineToken, line: 6),
    Token(kind: EofToken, line: 7)
  ]

proc rejects(source, message: string) =
  ## Requires the exact diagnostic at the encoded source location.
  try:
    discard tokenize(source, fileLineBase)
  except NiftyError as error:
    doAssert error.msg == "lexer.nifty:1: " & message, error.msg
    return
  doAssert false, "Expected a lexer error for: " & source

srcFiles = @["unused.nifty", "lexer.nifty"]
rejects("'", "unterminated char literal")
rejects("'\\", "unterminated char escape")
rejects("'ab#'", "a char literal holds exactly one byte ('A', '\\n')")
rejects("'#", "a char literal holds exactly one byte ('A', '\\n')")
rejects("'\\#'", "unknown escape: \\#")
rejects("\"#", "unterminated string")
rejects("\"#\\", "unterminated string escape")
rejects("\"\\#\"", "unknown escape: \\#")

echo "Lexer literal and comment tests passed"

# JSON parser

`lib/json.nifty` parses a Nifty string into an owned JSON tree. It also
accepts bounded strings and string literals through read-only borrowing.
For a program saved under `examples/`, import the library by its relative
path:

```nifty
import "../lib/json"

thread main() =
  var text: string
  if text.add("{\"answer\":42}"):
    var node: JsonNode
    var error: JsonError
    if parseJson(text, node, error):
      echo "Parsed JSON"
    else:
      echo error.offset
```

`parseJson(text, output, error)` returns `true` when the entire input is
one JSON value, allowing JSON whitespace before and after it. It returns
`false` for malformed input, allocation failure, or excessive nesting.
Failure clears `output` to `NullNode`. `error.offset` is a zero-based byte
offset, including the end-of-input position. `error.code` identifies the
number, syntax, Unicode, allocation, or depth failure; `error.message`
contains a fixed-capacity diagnostic. The input is borrowed
and remains available to the caller. The output owns its decoded strings
and child nodes and is released automatically when its scope ends.

`JsonNode` is a union of `NumNode`, `StrNode`, `ArrNode`, `ObjNode`,
`BoolNode`, and `NullNode`. Narrow with `type(node) == StrNode` before
reading a variant's fields. Numbers retain their exact decimal spelling
in `text`, including integers and exponents beyond machine numeric limits.
`jsonInt(node)` returns an optional integer for integer spellings that fit
Nifty's `int`; fractional or exponent spellings return `none`. Arrays hold child
nodes in `items`. Objects hold ordered `JsonField` entries in `fields`,
with `name` and `value` fields, preserving duplicate keys.

Strings decode the JSON escapes, including UTF-16 surrogate pairs, into
UTF-8. Embedded zero bytes remain part of the decoded string. Raw control
bytes, malformed UTF-8, and unpaired surrogate escapes are rejected.
Numbers follow the [RFC 8259 JSON grammar](https://www.rfc-editor.org/rfc/rfc8259).
Comments, trailing commas, non-string object keys, a leading UTF-8 BOM,
and extra input after the root value are rejected.

Parsing uses an explicit stack rather than recursive procedure calls.
`parseJson` limits nesting to 512 containers. Use
`parseJsonWithDepth(text, output, error, maxDepth)` to choose another limit.
Zero permits scalar roots only; a negative limit reports a depth error.
Input and tree sizes are constrained by available memory. All growth is
fallible. Completed subtrees are copied into their parent because Nifty
does not yet support ownership moves; deeply nested inputs can therefore
require quadratic work.

Run the example and parser regression suites from the repository root:

```sh
./nifty run examples/json_parser.nifty
nim r tests/test_json.nim
nim r tests/test_jsonnative.nim
```

The suite compares complete parsed trees with Nim's standard JSON parser,
checks malformed syntax and Unicode, and runs generated C with address and
undefined behavior sanitizers on supported platforms. Allocation tracking
checks that parsed trees and rejected inputs release their storage.

The implementation also passed the
[JSONTestSuite corpus](https://github.com/nst/JSONTestSuite/tree/1ef36fa01286573e846ac449e8683f8833c5b26a):
all 95 required-valid files were accepted and all 188 required-invalid
files were rejected. All 318 corpus files, including the 35 cases with
implementation-dependent behavior, ran without sanitizer diagnostics.

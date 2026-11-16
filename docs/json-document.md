# Document-based JSON

`lib/jsondoc.nifty` parses strict JSON into a document that owns a node pool
and a byte pool. It is an alternative to the existing recursive owning tree in
`lib/json.nifty`. This implementation uses ordinary Nifty code and requires no
new language semantics.

```nim
import "../lib/jsondoc"

proc example(input: string) =
  var doc: JsonDocument
  var error: JsonError
  if not parseJsonDocument(input, doc, error):
    echo error.offset, ": ", error.message
    return
  # doc.root identifies the root; node IDs remain stable as pools grow.
  let first = jsonDocumentFirst(doc, doc.root)
  if first.ok:
    var value: string
    if jsonDocumentText(doc, first.or(-1), value):
      echo value
  # Ordinary scope exit frees the complete document.
```

See [the complete example](../examples/json_document.nifty).

## Representation and lifetime

`JsonDocument.nodes` is a growable `seq[JsonDocNode]`. Nodes have no owning
fields: they contain a kind, Boolean payload, text/name ranges, and an `after`
index. They are stored in preorder, so a container's descendants occupy the
interval immediately after its ID and before its `after` index. A leaf's
`after` is its ID plus one. Appending and closing a container never clones its
children.

`JsonDocument.bytes` retains the input once at its beginning. Number spelling
refers to that prefix, preserving large integers and arbitrary valid exponents.
Decoded strings and object keys append to the same buffer. Text is addressed
by `[offset, limit)` and names by `[nameOffset, nameLimit)`. A zero name offset
means the node has no object key; even an empty object key has a positive offset.
Duplicate keys retain their original order.

IDs and ranges belong to one document. Reallocation does not invalidate them;
clearing, reparsing, or releasing that document invalidates them. The input
argument can be released after parsing because the document retains its bytes.

`clearJsonDocument(doc)` empties the document and retains capacity for reuse.
`releaseJsonDocument(doc)` frees both pools immediately. Automatic destruction
at scope exit also frees both pools, without recursively destroying each node.
A failed parse leaves `root == -1` and both lengths zero; retained capacity is
still owned and is freed normally.

## API

- `parseJsonDocument(input, doc, error)` uses a maximum container depth of 512.
- `parseJsonDocumentWithDepth(input, doc, error, maxDepth)` selects a limit;
  zero permits scalar roots, and negative limits fail.
- `jsonDocumentFirst(doc, parent)` returns the first child ID or `none`.
- `jsonDocumentNext(doc, parent, child)` advances a known direct-child cursor,
  skipping the child's complete subtree, or returns `none`.
- `jsonDocumentText(doc, id, output)` copies a string or number into `output`.
- `jsonDocumentName(doc, id, output)` copies its object key into `output`.

The copying accessors return false for invalid IDs, unavailable payloads, or
allocation failure. A root or array element has no object key; an empty object
key is present and copies successfully.
Code that needs no copy can read the documented pool ranges with normal Nifty
bounds checks. Kinds are `JsonDocNull`, `JsonDocBool`, `JsonDocNumber`,
`JsonDocString`, `JsonDocArray`, and `JsonDocObject`.

The byte buffer retains raw input as well as decoded strings, and nodes are
fixed records. This favors allocation count, linear construction, and grouped
cleanup over the smallest possible representation. Individual nodes cannot
outlive their document.

## Run the main JSON benchmark

Build Nifty, then run:

```text
python benchmarks/run_json.py --records 128 --repeat 50 --samples 7
```

The runner selects Hand C, Nifty C, and the physical host's native backend.
Select a subset with `--backend c` or `--backend c,amd64` / `--backend c,arm64`. Windows uses
QueryPerformanceCounter; Linux/macOS use clock_gettime. `--cc` selects the C
compiler, and `--output` selects the result directory.
The handwritten C document reference uses the same two-pool representation
and bounded recursive traversal in C. Only the document model is built and
reported by default, under `benchmarks/output/jsondoc`.

All backends receive identical input. Each timed cycle creates a fresh
document, hashes every decoded value and ordered key, and frees all its
storage. Input setup and output are excluded. Measured variants rotate across
samples, and every checksum must match Python's independent JSON oracle.

The runner records raw timing samples, one observed build time per variant,
source/compiler hashes, and separate allocation probes. Allocation counters
are never enabled in timed binaries. Requested bytes measure cumulative
allocation traffic, not peak memory. The document has its own preorder digest
traversal, so measured differences include traversal and cleanup improvements.
See the [benchmark guide](../benchmarks/JSON.md) for commands and output files.

Tests cover independent values and structure, Unicode and embedded NUL, exact
numbers, duplicate keys, depth limits, moving reallocations, every allocation
failure in a representative parse, and C/native/interpreter execution in both
optimization modes.

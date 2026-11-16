## Executes the document API and Unicode/range values on each host backend.
import std/[os, osproc, strutils, sequtils]

let root = currentSourcePath().parentDir.parentDir
let directory = getTempDir() / ("nifty-json-doc-backends-" & $getCurrentProcessId())
createDir(directory)
let suffix = when defined(windows): ".exe" else: ""
let compiler = root / ("nifty" & suffix)
let source = directory / "document.nifty"
let importPath = (root / "lib/jsondoc.nifty").replace('\\', '/')
writeFile(source, "import \"" & importPath & "\"\n" & """
proc run() =
  var input: string
  discard input.add("{\"\":[{\"x\":\"a\\u0000b\\u00e9\\ud83d\\ude03\"},true],\"n\":9007199254740993}")
  var doc: JsonDocument
  var error: JsonError
  echo parseJsonDocument(input, doc, error)
  echo doc.root == 0 and doc.nodes.len == 6
  let first = jsonDocumentFirst(doc, doc.root).or(-1)
  var key: string
  echo jsonDocumentName(doc, first, key) and key.len == 0 and not jsonDocumentName(doc, doc.root, key)
  let last = jsonDocumentNext(doc, doc.root, first).or(-1)
  echo last == 5 and not jsonDocumentNext(doc, doc.root, last).ok
  var number: string
  echo jsonDocumentText(doc, last, number) and number.startsWith("9007199254740993")
  if first >= 0 and first < doc.nodes.len:
    echo doc.nodes[first].after == 5
  let objectId = jsonDocumentFirst(doc, first).or(-1)
  let stringId = jsonDocumentFirst(doc, objectId).or(-1)
  var text: string
  echo jsonDocumentText(doc, stringId, text)
  echo text.len == 9 and text.get(1).or(255) == 0 and text.get(3).or(0) == 195
  echo not jsonDocumentFirst(doc, -1).ok and not jsonDocumentNext(doc, 0, -1).ok
  echo not jsonDocumentText(doc, -1, text)
  input.clear()
  discard input.add("[1,]")
  echo not parseJsonDocument(input, doc, error)
  echo doc.root == -1 and doc.nodes.len == 0 and doc.bytes.len == 0
  input.clear()
  discard input.add("true")
  echo parseJsonDocument(input, doc, error)
  releaseJsonDocument(doc)
  echo doc.root == -1 and doc.nodes.len == 0 and doc.bytes.len == 0

thread main() =
  run()
""")
try:
  for backend in ["c", when defined(arm64): "arm64" else: "amd64", "interp"]:
    for optimization in ["none", "speed"]:
      let arguments = if backend == "interp":
          " interpret " & quoteShell(source)
        else:
          " " & quoteShell(source) & " -o " & quoteShell(directory / ("document" & suffix))
      let response = execCmdEx(quoteShell(compiler) & arguments &
        " --backend:" & backend & " --opt:" & optimization)
      doAssert response.exitCode == 0, backend & ": " & response.output
      var output = response.output.replace("\r\n", "\n").splitLines()
      output.keepItIf(it.len > 0 and not it.startsWith("built "))
      doAssert output.len == 14, $output
      for line in output: doAssert line == "true", backend & ": " & $output
      echo "JSON document backend passed: ", backend, "/", optimization
finally:
  removeDir(directory)

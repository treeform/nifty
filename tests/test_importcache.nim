## Fetch a real local HTTP import graph, then rebuild offline and check pins.
import std/[os, osproc, strutils, json, net]
import ../src/nifty
import ../src/nifty/[importcache, types]

const Leaf = "type Tag = opaque\nfunc value(): int =\n  return 7\n"
const Api = "import \"leaf.nifty\"\nfunc result(): int =\n  return value()\n"

proc serve(events: ptr Channel[string]) {.thread.} =
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  events[].send($server.getLocalAddr()[1].uint16)
  while true:
    var client: Socket
    server.accept(client)
    let request = client.recvLine(timeout = 5000).splitWhitespace()
    var header = client.recvLine(timeout = 5000)
    while header.strip().len > 0: header = client.recvLine(timeout = 5000)
    let path = if request.len > 1: request[1] else: ""
    let body = if path == "/pkg/api.nifty": Api else: Leaf
    client.send("HTTP/1.1 200 OK\r\nContent-Length: " & $body.len &
      "\r\nConnection: close\r\n\r\n" & body)
    client.close()
    events[].send(path)
    if path == "/stop": break
  server.close()

doAssert sourceHash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
doAssert sourceHash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
doAssert sourceHash(repeat('a', 1000000)) ==
  "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

let directory = getTempDir() / ("nifty-import-cache-" & $getCurrentProcessId())
createDir(directory)
let previousCache = getEnv("NIFTY_IMPORT_CACHE")
let previousOffline = getEnv("NIFTY_OFFLINE")
let previousUpdate = getEnv("NIFTY_UPDATE_IMPORTS")
putEnv("NIFTY_IMPORT_CACHE", directory / "cache")
putEnv("NIFTY_OFFLINE", "")
putEnv("NIFTY_UPDATE_IMPORTS", "")
var events: Channel[string]
events.open()
var worker: Thread[ptr Channel[string]]
createThread(worker, serve, addr events)
let port = events.recv()
let base = "http://127.0.0.1:" & port
let api = base & "/pkg/api.nifty"
let leaf = base & "/pkg/leaf.nifty"
let other = base & "/copy/leaf.nifty"
let text = "import \"" & api & "\" as api\n" &
  "import \"" & api & "\" as again\n" &
  "import \"" & other & "\" as other\n" &
  "thread main() =\n  echo api.result(), \" \", again.value(), \" \", other.value()\n"
proc checked() =
  let module = checkedModule(text, directory / "main.nifty", directory)
  var tags: seq[Typ]
  for definition in module.types:
    if definition.name.endsWith("_s_Tag"): tags.add definition.typ
  doAssert tags.len == 2, "distinct URLs must have distinct nominal types"
  doAssert not typeEq(tags[0], tags[1])
proc expectError(source, message: string) =
  var rejected = false
  try: discard checkedModule(source, directory / "main.nifty", directory)
  except NiftyError as error:
    rejected = message in error.msg
    doAssert rejected, error.msg
  doAssert rejected, message
try:
  checked()
  doAssert events.recv() == "/pkg/api.nifty"
  doAssert events.recv() == "/pkg/leaf.nifty"
  doAssert events.recv() == "/copy/leaf.nifty"
  let lockPath = directory / "nifty.lock"
  let lockText = readFile(lockPath)
  let lock = parseJson(lockText)
  doAssert lock["imports"].len == 3
  doAssert lock["imports"][leaf].getStr == sourceHash(Leaf)
  putEnv("NIFTY_OFFLINE", "1")
  checked()
  doAssert not events.tryRecv().dataAvailable, "a cached import made a network request"
  expectError("import \"" & base & "/missing.nifty\"\nthread main() =\n  discard 0\n",
    "not cached in offline mode")
  let leafIndex = directory / "cache" / (sourceHash(leaf) & ".nifty")
  let cachedLeaf = directory / "cache" / "sources" / (sourceHash(Leaf) & ".nifty")
  # Simulate another project's update while the first project keeps its pin.
  let revision = Leaf & "# newer revision\n"
  writeFile(leafIndex, revision)
  writeFile(directory / "cache" / "sources" / (sourceHash(revision) & ".nifty"), revision)
  checked()
  doAssert not events.tryRecv().dataAvailable
  let otherProject = directory / "other-project"
  createDir(otherProject)
  discard checkedModule("import \"" & leaf & "\" as leaf\nthread main() =\n  echo leaf.value()\n",
    otherProject / "main.nifty", otherProject)
  doAssert parseFile(otherProject / "nifty.lock")["imports"][leaf].getStr == sourceHash(revision)
  checked()
  writeFile(cachedLeaf, Leaf & "# corruption\n")
  expectError(text, "cached module content differs from nifty.lock")
  writeFile(cachedLeaf, Leaf)
  putEnv("NIFTY_OFFLINE", "")
  var changed = parseJson(lockText)
  changed["imports"][leaf] = %repeat('0', 64)
  writeFile(lockPath, $changed)
  removeFile(cachedLeaf)
  removeFile(leafIndex)
  expectError(text, "module content differs from nifty.lock")
  doAssert events.recv() == "/pkg/leaf.nifty"
  doAssert not fileExists(cachedLeaf), "unverified source entered the cache"
  writeFile(lockPath, lockText)
  checked()
  doAssert events.recv() == "/pkg/leaf.nifty"
  writeFile(lockPath, $changed)
  putEnv("NIFTY_UPDATE_IMPORTS", "1")
  checked()
  doAssert events.recv() == "/pkg/api.nifty"
  doAssert events.recv() == "/pkg/leaf.nifty"
  doAssert events.recv() == "/copy/leaf.nifty"
  doAssert parseFile(lockPath)["imports"][leaf].getStr == sourceHash(Leaf)
  putEnv("NIFTY_UPDATE_IMPORTS", "")
  writeFile(directory / "main.nifty", text)
  putEnv("NIFTY_OFFLINE", "1")
  let compiler = currentSourcePath().parentDir.parentDir / "nifty" &
    (when defined(windows): ".exe" else: "")
  for backend in ["c", when defined(arm64): "arm64" else: "amd64"]:
    let binary = directory / ("cached-" & backend &
      (when defined(windows): ".exe" else: ""))
    let built = execCmdEx(quoteShellCommand(@[compiler, "build",
      directory / "main.nifty", "--backend:" & backend, "-o", binary]))
    doAssert built.exitCode == 0, built.output
    let ran = execCmdEx(quoteShell(binary))
    doAssert ran.exitCode == 0 and ran.output.replace("\r\n", "\n") == "7 7 7\n", ran.output
  doAssert not events.tryRecv().dataAvailable
finally:
  let client = newSocket()
  client.connect("127.0.0.1", Port(parseInt(port)))
  client.send("GET /stop HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  discard client.recv(4096)
  client.close()
  joinThread(worker)
  events.close()
  putEnv("NIFTY_IMPORT_CACHE", previousCache)
  putEnv("NIFTY_OFFLINE", previousOffline)
  putEnv("NIFTY_UPDATE_IMPORTS", previousUpdate)
  removeDir(directory)
echo "URL import download, offline cache and content pins passed"

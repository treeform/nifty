## Immutable source downloads. Module identity remains the requested URL.
import std/[os, osproc, streams, strutils, tables, json, uri, tempfiles, algorithm]
import common

proc sourceHash*(data: string): string =
  ## SHA-256, used for lockfile pins and cache integrity.
  const constants = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
    0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
    0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
    0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
    0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
    0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
    0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
    0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
    0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
    0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
    0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
    0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
    0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]
  proc rotate(value: uint32, bits: int): uint32 =
    (value shr bits) or (value shl (32 - bits))
  var state = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var padded = data
  padded.add '\x80'
  while padded.len mod 64 != 56: padded.add '\0'
  let bits = uint64(data.len) * 8
  for shift in countdown(56, 0, 8):
    padded.add char((bits shr shift) and 255)
  for blockIndex in 0 ..< padded.len div 64:
    var words: array[64, uint32]
    for i in 0 ..< 16:
      for j in 0 ..< 4:
        words[i] = (words[i] shl 8) or uint32(byte(padded[blockIndex * 64 + i * 4 + j]))
    for i in 16 ..< 64:
      let x = words[i - 15]
      let y = words[i - 2]
      words[i] = words[i - 16] +
        (rotate(x, 7) xor rotate(x, 18) xor (x shr 3)) +
        words[i - 7] + (rotate(y, 17) xor rotate(y, 19) xor (y shr 10))
    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    var f = state[5]
    var g = state[6]
    var h = state[7]
    for i in 0 ..< 64:
      let first = h + (rotate(e, 6) xor rotate(e, 11) xor rotate(e, 25)) +
        ((e and f) xor ((not e) and g)) + constants[i] + words[i]
      let second = (rotate(a, 2) xor rotate(a, 13) xor rotate(a, 22)) +
        ((a and b) xor (a and c) xor (b and c))
      h = g; g = f; f = e; e = d + first
      d = c; c = b; b = a; a = first + second
    for i, value in [a, b, c, d, e, f, g, h]:
      state[i] = state[i] + value
  for value in state: result.add toHex(value, 8).toLowerAscii()

type ImportCache* = object
  directory, lockFile: string
  pins: Table[string, string]
  dirty: bool

proc validHash(value: string): bool =
  if value.len != 64: return false
  for c in value:
    if c notin {'0' .. '9', 'a' .. 'f'}: return false
  true

proc initImportCache*(root: string): ImportCache =
  result.directory = getEnv("NIFTY_IMPORT_CACHE")
  if result.directory.len == 0:
    when defined(windows):
      result.directory = getEnv("LOCALAPPDATA", getHomeDir()) / "Nifty" / "imports"
    elif defined(macosx):
      result.directory = getHomeDir() / "Library" / "Caches" / "nifty" / "imports"
    else:
      result.directory = getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / "nifty" / "imports"
  result.lockFile = absolutePath(root) / "nifty.lock"
  if fileExists(result.lockFile):
    try:
      let lock = parseFile(result.lockFile)
      if lock.kind != JObject or lock["version"].getInt != 1 or lock["imports"].kind != JObject:
        raise newException(ValueError, "expected version 1 import lock")
      for url, pin in lock["imports"]:
        if pin.kind != JString or not validHash(pin.getStr):
          raise newException(ValueError, "invalid SHA-256 pin")
        result.pins[url] = pin.getStr
    except CatchableError as error:
      err(1, "cannot read " & result.lockFile & ": " & error.msg)

proc atomicWrite(path, data: string) =
  createDir(path.parentDir)
  let temporary = createTempFile("nifty-", ".tmp", path.parentDir)
  try:
    temporary.cfile.write(data)
    temporary.cfile.close()
    moveFile(temporary.path, path)
  finally:
    if fileExists(temporary.path): removeFile(temporary.path)

proc readRemote*(cache: var ImportCache, url: string, line: int): string =
  let parsed = parseUri(url)
  if parsed.scheme notin ["http", "https"] or parsed.hostname.len == 0 or parsed.anchor.len > 0:
    err(line, "module URL must be an HTTP(S) URL without a fragment: " & url)
  let path = cache.directory / (sourceHash(url) & ".nifty")
  let update = getEnv("NIFTY_UPDATE_IMPORTS").toLowerAscii in ["1", "true", "yes"]
  let offline = getEnv("NIFTY_OFFLINE").toLowerAscii in ["1", "true", "yes"]
  if update and offline: err(line, "cannot update URL imports in offline mode")
  var loaded = false
  # Preserve every pinned revision. Updating one project must not invalidate
  # another project's offline build of the same URL.
  if not update and url in cache.pins:
    let pinned = cache.directory / "sources" / (cache.pins[url] & ".nifty")
    if fileExists(pinned):
      result = readFile(pinned)
      loaded = true
  if not update and not loaded and fileExists(path):
    let latest = readFile(path)
    if url notin cache.pins or sourceHash(latest) == cache.pins[url]:
      result = latest
      loaded = true
  if not loaded:
    if offline:
      err(line, "module is not cached in offline mode: " & url)
    let curl = findExe("curl")
    if curl.len == 0:
      err(line, "downloading URL imports requires curl; module is not cached: " & url)
    createDir(cache.directory)
    let temporary = createTempFile("download-", ".nifty", cache.directory)
    temporary.cfile.close()
    try:
      let process = startProcess(curl, args = @["--fail", "--location",
        "--silent", "--show-error", "--max-time", "30",
        "--max-filesize", "16777216", "--proto", "=http,https",
        "--output", temporary.path, "--url", url], options = {poStdErrToStdOut})
      let output = process.outputStream.readAll()
      let status = process.waitForExit()
      process.close()
      if status != 0:
        err(line, "cannot download module " & url & ": " & output.strip())
      result = readFile(temporary.path)
      let hash = sourceHash(result)
      if not update and url in cache.pins and cache.pins[url] != hash:
        err(line, "module content differs from nifty.lock: " & url)
      atomicWrite(path, result)
    finally:
      if fileExists(temporary.path): removeFile(temporary.path)
  let hash = sourceHash(result)
  if url in cache.pins and not update:
    if cache.pins[url] != hash:
      err(line, "cached module content differs from nifty.lock: " & url)
  elif url notin cache.pins or cache.pins[url] != hash:
    cache.pins[url] = hash
    cache.dirty = true
  let pinned = cache.directory / "sources" / (hash & ".nifty")
  if update or not fileExists(pinned): atomicWrite(pinned, result)

proc saveImportLock*(cache: var ImportCache) =
  if not cache.dirty: return
  var imports = newJObject()
  var urls: seq[string]
  for url in cache.pins.keys: urls.add url
  urls.sort()
  for url in urls: imports[url] = %cache.pins[url]
  atomicWrite(cache.lockFile, $(%*{"version": 1, "imports": imports}) & "\n")
  cache.dirty = false

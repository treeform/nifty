## Rebuilds the embedded runtime with a real memory64 C toolchain.
import
  std/[compilesettings, json, os, osproc, streams, tempfiles],
  ../src/nifty/[wasmtemplates, wasmexterns, backend/wasmmodules]

const
  Root = currentSourcePath().parentDir.parentDir
  NimLibrary = querySetting(libPath)
  RuntimeSource = staticRead("runtime_wasm.nim")

proc execute(path: string, arguments: seq[string]) =
  ## Runs a development compiler with captured actionable diagnostics.
  let process = startProcess(path, args = arguments,
    options = {poStdErrToStdOut})
  try:
    var output, line: string
    while process.outputStream.readLine(line):
      output.add(line & "\n")
    if process.waitForExit() != 0:
      raise newException(IOError, "Runtime build failed:\n" & output)
  finally:
    process.close()

when not defined(niftyBuildWasmRuntime):
  {.error: "Build with -d:niftyBuildWasmRuntime".}

let
  directory = createTempDir("nifty-wasm-runtime-", "")
  nim = findExe("nim")
  emcc = getEnv("NIFTY_EMCC", findExe("emcc"))
if nim.len == 0 or emcc.len == 0:
  raise newException(IOError, "Runtime development requires Nim and Emscripten")
try:
  let
    path = directory / "runtime.nim"
    cache = directory / "cache"
  writeFile(path, RuntimeSource)
  execute(nim, @[
    "c", "--compileOnly", "--noMain", "--cpu:amd64", "--os:linux",
    "-d:emscripten", "-d:niftyWasmRuntime", "-d:release",
    "--mm:orc", "-d:nimAllocPagesViaMalloc",
    "--skipParentCfg", "--skipProjCfg", "--path:" & Root / "src",
    "--nimcache:" & cache, path
  ])
  let recipe = parseJson(readFile(cache / "runtime.json"))
  var arguments = @[
    "-O2", "-sMEMORY64=1", "-sSTANDALONE_WASM=1",
    "-sALLOW_MEMORY_GROWTH=1", "-sINITIAL_MEMORY=16777216",
    "-sMAXIMUM_MEMORY=2147483648", "-sSTACK_SIZE=1048576", "--no-entry",
    "-I" & NimLibrary, "-Wl,--export=nifty_entry",
    "-Wl,--export=nifty_metadata", "-Wl,--export=nifty_stack",
    "-Wl,--export=nifty_dispatch", "-Wl,--export=nifty_stack_failure",
    "-Wl,--export=_start", "-Wl,--strip-debug", "-Wl,--fatal-warnings"
  ]
  for symbol in WasmExternNames:
    arguments.add("-Wl,--export=nf_ext_" & symbol)
  for item in recipe["compile"]:
    arguments.add(item[0].getStr())
  arguments.add(Root / "tools/runtime_wasm.c")
  arguments.add("-o")
  arguments.add(directory / "runtime.wasm")
  execute(emcc, arguments)
  let bytes = readFile(directory / "runtime.wasm")
  discard parseModule(bytes)
  let asset = WasmRuntimeMagic & WasmRuntimeStamp & bytes
  discard runtimeAsset(asset)
  createDir(Root / "src/nifty/assets")
  writeFile(Root / "src/nifty/assets/wasm64.bin", asset)
  echo "Wrote memory64 runtime (", bytes.len, " bytes)"
finally:
  removeDir(directory)

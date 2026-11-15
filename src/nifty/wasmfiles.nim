## Builds and publishes memory64 modules from the shared checked IR.
import std/[os, strutils, tempfiles]
import common, types, nativeplans, nativeoptimizations,
  wasmmetadata, wasmexterns, wasmtemplates
import backend/[irs, irwasms, wasmmodules]

export nativeplans, nativeoptimizations

const WasmStackBytes* = 4 * 1024 * 1024

type WasmProgram* = object
  plan*: NativePlan
  bytes*: string
  codeBytes*: int

proc validateWasmPlan(plan: NativePlan): int =
  ## Selects the single executable root without changing thread semantics.
  if plan.threads.len != 1 or plan.threads[0].count != 1:
    raise newException(NiftyError,
      "wasm64 supports exactly one thread instance; concurrent threads " &
      "are not supported")
  result = plan.threads[0].functionIndex
  if result <= 0 or result >= plan.module.functions.len:
    raise newException(NiftyError, "wasm64 has an invalid thread entry")
  for layout in plan.layouts:
    if layout.kind == ChannelType:
      raise newException(NiftyError, "wasm64 channels are not supported")
  if plan.hosts.len != plan.module.hosts.len:
    raise newException(NiftyError, "wasm64 host metadata does not match IR")

proc buildWasmProgram*(plan: NativePlan,
    optimization = SpeedOptimization): WasmProgram =
  ## Emits memory64 instructions with the precompiled portable runtime.
  let entry = validateWasmPlan(plan)
  result.plan = optimizeNative(plan, optimization, specializeMath = false)
  var symbols: seq[string]
  for i, host in result.plan.hosts:
    case host.kind
    of ContainerHost, LockHost:
      symbols.add("nifty_dispatch")
    of ExternHost:
      symbols.add(wasmExternSymbol(host,
        result.plan.module.hosts[i].signature))
    of EmbeddedHost:
      raise newException(NiftyError, "embedding callbacks require a scripting runtime")
    of ReservedHost:
      raise newException(NiftyError, "wasm64 unsupported legacy host service")
  let
    runtime = parseModule(wasmRuntime())
    image = emitWasmIr(result.plan.module, runtime, entry, symbols,
      stackBytes = WasmStackBytes)
    metadata = serializeWasmMetadata(result.plan)
  result.bytes = filledModule(runtime, image.bodies, metadata,
    image.types, image.indirectTypes)
  result.codeBytes = image.codeBytes

when not defined(windows):
  proc renameFile(source, destination: cstring): cint
      {.importc: "rename", header: "<stdio.h>".}
    ## Atomically replaces a completed output on its destination filesystem.

proc validateWasmOutput*(path, source: string) =
  ## Preserves source files even when the destination aliases through a link.
  if path.len == 0:
    raise newException(NiftyError, "wasm64 output path is empty")
  if source.len == 0:
    return
  let
    output = path.absolutePath().normalizedPath()
    input = source.absolutePath().normalizedPath()
  if output == input or
      (fileExists(output) and fileExists(input) and sameFile(output, input)):
    raise newException(NiftyError, "wasm64 output would replace its source")

proc writeWasmFile*(program: WasmProgram, path: string, source = "") =
  ## Publishes complete bytes without invoking a compiler or linker.
  validateWasmOutput(path, source)
  if program.bytes.len < 8 or program.bytes[0 .. 7] != "\0asm\x01\0\0\0":
    raise newException(NiftyError, "wasm64 module header is invalid")
  var directory = ""
  try:
    let output = path.absolutePath()
    if dirExists(output):
      raise newException(NiftyError, "wasm64 output path is a directory")
    directory = createTempDir("nifty-wasm-", "", output.parentDir)
    let temporary = directory / "program.wasm"
    writeFile(temporary, program.bytes)
    when defined(windows):
      moveFile(temporary, output)
    else:
      if renameFile(temporary.cstring, output.cstring) != 0:
        raise newException(NiftyError,
          "cannot publish wasm64 module: " & osErrorMsg(osLastError()))
  except OSError, IOError, ValueError:
    raise newException(NiftyError,
      "cannot write wasm64 module: " & getCurrentExceptionMsg())
  finally:
    if directory.len > 0:
      removeDir(directory)

proc wasmReport*(program: WasmProgram, source: string): string =
  ## Distinguishes generated code and reserved storage from dynamic heap use.
  let thread = program.plan.threads[0]
  result = [
    "nifty wasm64 report: " & source,
    "  complete module: " & $program.bytes.len & " bytes",
    "  compiled script code: " & $program.codeBytes & " bytes",
    "  global storage: " & $program.plan.globalBytes & " bytes",
    "  thread arena: " & $thread.arenaBytes & " bytes",
    "  reserved linear stack: " & $WasmStackBytes & " bytes",
    "  owned globals: " & $program.plan.ownedGlobals.len,
    "  owned payloads grow dynamically; no static heap bound inferred",
    "  engine stack and runtime allocator overhead are separate"
  ].join("\n") & "\n"

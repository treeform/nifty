## Exercise standalone WASM64 artifacts in Node and Wasmtime.
## Run: nim r tests/test_wasm.nim /absolute/path/to/nifty [--opt:none|speed].
import std/[algorithm, os, osproc, strtabs, strutils, times]

type Result = tuple[output: string, code: int]

var
  serial = 0
  passed = 0
  failed = 0

proc run(executable: string, args: seq[string], isolated = false): Result =
  ## Capture binary output without filling a pipe while enforcing a deadline.
  inc serial
  let output = getTempDir() / ("nifty_wasm_output_" &
    $getCurrentProcessId() & "_" & $serial)
  var environment = newStringTable(
    when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for key, value in envPairs():
    environment[key] = value
  if isolated:
    environment["PATH"] = "/nifty-test-no-compilers"
  environment["NIFTY_WASM_TEST_OUTPUT"] = output
  let process = startProcess("/bin/sh", args = @[
    "-c", "exec \"$@\" > \"$NIFTY_WASM_TEST_OUTPUT\" 2>&1",
    "nifty-wasm-test", executable] & args, env = environment)
  result.code = process.waitForExit(60_000)
  if result.code == -1:
    process.kill()
    discard process.waitForExit()
  process.close()
  if fileExists(output):
    result.output = readFile(output)
    removeFile(output)

proc normalized(value: string): string =
  ## Match the existing golden suite's newline and trailing whitespace rules.
  value.replace("\r\n", "\n").strip()

proc verify(condition: bool, label: string, detail = "") =
  ## Accumulate failures so one unsupported regression cannot hide the others.
  if condition:
    inc passed
  else:
    inc failed
    echo "FAIL ", label
    if detail.len > 0:
      echo detail

proc fixturePaths(directory: string): seq[string] =
  ## Discover every fixture so newly added failures are never silently skipped.
  for kind, path in walkDir(directory):
    if kind == pcFile and path.endsWith(".nifty") and
        not path.extractFilename.startsWith("_"):
      result.add path
  result.sort()

proc copyFixtures(source, destination: string) =
  ## Keep build products and source mutation tests outside the repository.
  createDir(destination)
  for kind, path in walkDir(source):
    if kind == pcFile and
        (path.endsWith(".nifty") or path.endsWith(".txt")):
      copyFile(path, destination / path.extractFilename)

proc exclusion(directory, name: string): string =
  ## Record the specific unsupported OS interfaces in the shared corpus.
  if directory == "scripts":
    case name
    of "channels", "locks", "queue", "thread_count", "ffi_net":
      return "requires multiple thread instances or channels"
    of "ffi":
      return "requires process, pipe, and sleep host interfaces"
    of "opaque_handles":
      return "requires host FILE handles and strtod pointer results"
    else:
      discard
  if directory == "native":
    case name
    of "windows_ffi":
      return "requires Windows host APIs and libc process calls"
    else:
      discard

proc raySource(root: string, size: int): string =
  ## Remove host timing calls while preserving the renderer and all pixels.
  result = readFile(root / "benchmarks" / "raytracer.nifty")
    .replace("const ImageSize = 64", "const ImageSize = " & $size)
    .replace("extern \"libc\":\n  proc clock_gettime(clock: int32, " &
      "value: var Timespec): int32\n", "")
    .replace("let startStatus = clock_gettime(ClockId, started)",
      "let startStatus = 0")
    .replace("let finishStatus = clock_gettime(ClockId, finished)",
      "let finishStatus = 0")
    .replace("  var started: Timespec\n", "")
    .replace("  var finished: Timespec\n", "")
    .replace("started.sec", "0").replace("started.nsec", "0")
    .replace("finished.sec", "0").replace("finished.nsec", "0")

proc pixels(output: string): string =
  ## Decode RGB lines and reject malformed or out of range channel values.
  for line in output.splitLines():
    if line.startsWith("rgb "):
      let fields = line.splitWhitespace()
      doAssert fields.len == 4, line
      for field in fields[1 .. 3]:
        let value = parseInt(field)
        doAssert value in 0 .. 255, line
        result.add char(value)

proc main() =
  ## Verify both optimization pipelines and independent execution engines.
  const Usage = "Usage: test_wasm /absolute/path/to/nifty " &
    "[--opt:none|speed]"
  if paramCount() notin 1 .. 2:
    quit(Usage, 1)
  var modes = @["none", "speed"]
  if paramCount() == 2:
    if paramStr(2) notin ["--opt:none", "--opt:speed"]:
      quit(Usage, 1)
    modes = @[paramStr(2)[6 .. ^1]]
  let
    compiler = absolutePath(paramStr(1))
    root = currentSourcePath().parentDir.parentDir
    node = findExe("node")
    wasmtime = findExe("wasmtime")
    runner = root / "tools" / "wasm" / "run.mjs"
    probe = root / "tests" / "wasm" / "probe.mjs"
    work = getTempDir() / ("nifty_wasm_tests_" &
      $getCurrentProcessId() & "_" & $int(epochTime()))
  doAssert fileExists(compiler), "Compiler does not exist: " & compiler
  doAssert node.len > 0, "Node with memory64 support is required"
  doAssert wasmtime.len > 0, "Wasmtime with memory64 support is required"
  echo "Node: ", normalized(run(node, @["--version"]).output)
  echo "Wasmtime: ", normalized(run(wasmtime, @["--version"]).output)
  createDir(work)
  for directory in ["scripts", "native", "wasm"]:
    copyFixtures(root / "tests" / directory, work / directory)

  proc build(source, output, mode: string, backend = "wasm64"): Result =
    ## Compile with an empty compiler search path to enforce embedded emission.
    run(compiler, @["build", source, "--backend:" & backend,
      "--opt:" & mode, "-o", output], isolated = true)

  proc execute(path: string, engine: int): Result =
    ## Use preview1 in two independent implementations without source access.
    if engine == 0:
      run(node, @[runner, path], isolated = true)
    else:
      run(wasmtime, @["run", "-W", "memory64=y", path], isolated = true)

  var excluded = 0
  for mode in modes:
    echo "Testing WASM64 optimization: ", mode
    for directory in ["scripts", "native", "wasm"]:
      for source in fixturePaths(work / directory):
        let
          name = source.extractFilename.changeFileExt("")
          label = mode & "/" & directory & "/" & name
          reason = exclusion(directory, name)
          output = source.changeFileExt("." & mode & ".wasm")
        if reason.len > 0:
          echo "EXCLUDE ", label, ": ", reason
          inc excluded
          continue
        let built = build(source, output, mode)
        verify(built.code == 0 and fileExists(output), label & "/build",
          built.output)
        if built.code != 0 or not fileExists(output):
          continue
        let expected = normalized(readFile(source.changeFileExt(".txt")))
        for engine in 0 .. 1:
          let
            actual = execute(output, engine)
            engineName = if engine == 0: "node" else: "wasmtime"
          verify(actual.code == 0 and normalized(actual.output) == expected,
            label & "/" & engineName,
            "Exit: " & $actual.code & "\nExpected:\n" & expected &
              "\nActual:\n" & actual.output)
        if directory == "wasm" and name == "managed_reuse":
          let cleanup = run(node, @[probe, output, "--cleanup"], isolated = true)
          verify(cleanup.code == 0, label & "/bounded-owner-storage",
            cleanup.output)

    let sample = work / "scripts" / "helloworld.nifty"
    let first = work / ("deterministic_" & mode & ".wasm")
    let second = work / ("deterministic_again_" & mode & ".wasm")
    let initial = build(sample, first, mode)
    let repeated = build(sample, second, mode, "wasm")
    verify(initial.code == 0 and repeated.code == 0 and
      fileExists(first) and fileExists(second) and
      readFile(first) == readFile(second), mode & "/deterministic-alias",
      initial.output & repeated.output)
    if fileExists(first):
      let checked = run(node, @[probe, first], isolated = true)
      verify(checked.code == 0, mode & "/memory64-high-address", checked.output)

    let removable = work / ("removed_" & mode & ".nifty")
    let standalone = removable.changeFileExt(".wasm")
    copyFile(sample, removable)
    let removedBuild = build(removable, standalone, mode)
    removeFile(removable)
    for engine in 0 .. 1:
      if removedBuild.code == 0:
        let actual = execute(standalone, engine)
        verify(actual.code == 0 and normalized(actual.output) ==
          normalized(readFile(sample.changeFileExt(".txt"))),
          mode & "/source-removed/" & $engine, actual.output)
      else:
        verify(false, mode & "/source-removed/build", removedBuild.output)

    let defaultSource = work / ("default_" & mode & ".nifty")
    copyFile(sample, defaultSource)
    let defaultBuild = run(compiler, @["build", defaultSource,
      "--backend:wasm64", "--opt:" & mode], isolated = true)
    verify(defaultBuild.code == 0 and
      fileExists(defaultSource.changeFileExt(".wasm")),
      mode & "/default-wasm-suffix", defaultBuild.output)

    let binarySource = work / ("binary_" & mode & ".nifty")
    let binaryOutput = binarySource.changeFileExt(".wasm")
    writeFile(binarySource,
      "thread main() =\n  echo \"a\\0b\\r\\nc\\nd\"\n")
    let binaryBuild = build(binarySource, binaryOutput, mode)
    verify(binaryBuild.code == 0, mode & "/binary-output/build",
      binaryBuild.output)
    if binaryBuild.code == 0:
      for engine in 0 .. 1:
        let actual = execute(binaryOutput, engine)
        verify(actual.code == 0 and actual.output == "a\0b\r\nc\nd\n",
          mode & "/binary-output/" & $engine, actual.output.escape())
      let boundary = run(node, @[probe, binaryOutput, "--io-boundary"],
        isolated = true)
      verify(boundary.code == 0, mode & "/partial-and-failed-writes",
        boundary.output)

    let savedSource = readFile(sample)
    let alias = build(sample, sample, mode)
    verify(alias.code != 0 and readFile(sample) == savedSource,
      mode & "/preserve-source-alias", alias.output)
    for linked in [false, true]:
      let aliasPath = work / ((if linked: "hardlink_" else: "symlink_") &
        mode & ".wasm")
      if linked:
        createHardlink(sample, aliasPath)
      else:
        createSymlink(sample, aliasPath)
      let aliased = build(sample, aliasPath, mode)
      verify(aliased.code != 0 and readFile(sample) == savedSource and
        readFile(aliasPath) == savedSource,
        mode & "/preserve-linked-source/" & $linked, aliased.output)
      removeFile(aliasPath)

    let broken = work / ("broken_" & mode & ".nifty")
    let preserved = broken.changeFileExt(".wasm")
    writeFile(broken, "thread main() =\n  echo unknownIdentifier\n")
    writeFile(preserved, "previous successful output\0")
    let rejected = build(broken, preserved, mode)
    verify(rejected.code != 0 and
      readFile(preserved) == "previous successful output\0",
      mode & "/preserve-output-on-error", rejected.output)

    for item in [
      ("threads", "thread first() =\n  echo 1\n" &
        "thread second() =\n  echo 2\n", "thread"),
      ("counted", "thread 2 worker() =\n  echo 1\n", "thread"),
      ("channel", "var jobs: channel[1, int]\n" &
        "thread main() =\n  jobs.send(1)\n", "channel"),
      ("foreign-symbol", "extern \"libc\":\n" &
        "  proc getpid(): int32\nthread main() =\n  echo getpid()\n", "getpid"),
      ("foreign-signature", "extern \"m\":\n" &
        "  proc sqrt(value: int64): int64\n" &
        "thread main() =\n  echo sqrt(4)\n", "sqrt"),
      ("foreign-library", "extern \"unknown\":\n" &
        "  proc sqrt(value: float64): float64\n" &
        "thread main() =\n  echo sqrt(4.0)\n", "sqrt")]:
      let source = work / (item[0] & "_" & mode & ".nifty")
      let output = source.changeFileExt(".wasm")
      writeFile(source, item[1])
      writeFile(output, "keep this artifact")
      let rejection = build(source, output, mode)
      verify(rejection.code notin [0, -1] and
        item[2] in rejection.output.toLowerAscii() and
        readFile(output) == "keep this artifact",
        mode & "/reject-" & item[0], rejection.output)

    for size in [4, 16, 64]:
      let source = work / ("ray_" & $size & "_" & mode & ".nifty")
      let output = source.changeFileExt(".wasm")
      writeFile(source, raySource(root, size))
      let built = build(source, output, mode)
      verify(built.code == 0, mode & "/ray-" & $size & "/build", built.output)
      if built.code != 0:
        continue
      let expected = readFile(root / "benchmarks" / "reference" / ($size & ".rgb"))
      for engine in 0 .. 1:
        let actual = execute(output, engine)
        verify(actual.code == 0 and pixels(actual.output) == expected,
          mode & "/ray-" & $size & "/" & $engine,
          "Exit: " & $actual.code & "\n" &
            (if actual.code == 0: "RGB reference mismatch" else: actual.output))

  echo "WASM64 tests: ", passed, " passed, ", failed, " failed, ",
    excluded, " explicit corpus exclusions"
  if failed > 0:
    echo "Artifacts retained at ", work
    quit(1)
  removeDir(work)

main()

## Compare every backend against unchanged language golden files.
## Run: nim r tests/test_native.nim /path/to/nifty [--opt:none|speed].
import
  std/[algorithm, json, os, osproc, streams, strtabs, strutils, times]
import fixtures

type
  Result = tuple[output: string, code: int]
  Mode = enum
    Run, Trap, Reject

proc run(executable: string, args: seq[string], isolated = false): Result =
  ## Run with a deadline, optionally removing compilers from PATH.
  var environment = newStringTable(
    when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for key, value in envPairs():
    environment[key] = value
  if isolated:
    environment["PATH"] = "/nifty-test-no-compilers"
  let process = startProcess(executable, args = args, env = environment,
    options = {poUsePath, poStdErrToStdOut})
  let code = process.waitForExit(30_000)
  if code == -1:
    process.kill()
    discard process.waitForExit()
  let output = process.outputStream.readAll()
  process.close()
  (output, code)

proc normalized(output: string): string =
  ## Normalize line endings and trailing output whitespace as the gold suite does.
  output.replace("\r\n", "\n").strip()

proc fixtures(directory: string): seq[string] =
  ## Find runnable fixtures, preserving helper modules for imports.
  if not dirExists(directory):
    return
  for kind, path in walkDir(directory):
    if kind == pcFile and path.endsWith(".nifty") and
        not path.extractFilename.startsWith("_"):
      result.add path
  result.sort()

proc copyFixtures(source, destination: string) =
  ## Copy sources and golds so compiler artifacts cannot change repository files.
  createDir(destination)
  for kind, path in walkDir(source):
    if kind == pcFile and
        (path.endsWith(".nifty") or path.endsWith(".txt")):
      copyFile(path, destination / path.extractFilename)

proc executableTarget(path, target: string): bool =
  ## Confirms emitted Mach-O, ELF, or PE executables have the requested CPU.
  let bytes = readFile(path)
  if bytes.len < 8:
    return false
  if bytes[0 .. 3] == "\xcf\xfa\xed\xfe":
    let cpu = if target == "arm64": '\x0c' else: '\x07'
    return bytes[4] == cpu and bytes[5 .. 7] == "\x00\x00\x01"
  when defined(linux):
    if bytes[0 .. 3] == "\x7fELF" and bytes.len >= 20:
      let cpu = if target == "arm64": '\xb7' else: '\x3e'
      return bytes[18] == cpu and bytes[19] == '\x00'
  when defined(windows):
    if bytes.len >= 64 and bytes[0 ..< 2] == "MZ":
      var pe = 0'u64
      for i in 0 ..< 4:
        pe = pe or (uint64(byte(bytes[60 + i])) shl (8 * i))
      if pe <= uint64(bytes.len - 26):
        let offset = int(pe)
        let machine = if target == "arm64": "\x64\xaa" else: "\x64\x86"
        return bytes[offset ..< offset + 4] == "PE\0\0" and
          bytes[offset + 4 ..< offset + 6] == machine and
          bytes[offset + 24 ..< offset + 26] == "\x0b\x02"
  false

proc imageTarget(path, target: string): bool =
  ## Inspect the target metadata of a versioned native image artifact.
  let bytes = readFile(path)
  if bytes.len < 40 or bytes[0 ..< 8] != "NIFTYN03":
    return false
  var metadataSize = 0'u64
  for i in 0 ..< 8:
    metadataSize = metadataSize or (uint64(byte(bytes[8 + i])) shl (8 * i))
  if metadataSize == 0 or metadataSize > uint64(bytes.len - 40):
    return false
  let
    metadata = parseJson(bytes[40 ..< 40 + int(metadataSize)])
    expected = if target == "arm64": 0 else: 1
  metadata["target"].getInt() == expected and
    metadata["offsets"].len > 0 and bytes.len > 40 + int(metadataSize)

proc executionArgs(binary, target: string): tuple[exe: string, args: seq[string]] =
  ## Use Rosetta explicitly when testing AMD64 on Apple silicon.
  when defined(macosx) and defined(arm64):
    if target == "amd64":
      return ("/usr/bin/arch", @["-x86_64", binary])
  (binary, @[])

proc canExecute(target: string): bool =
  ## Determine which native architecture can actually run on this machine.
  when defined(arm64):
    if target == "arm64":
      return true
    when defined(macosx):
      return run("/usr/bin/arch", @["-x86_64", "/usr/bin/true"]).code == 0
  elif defined(amd64):
    return target == "amd64"
  else:
    false

proc main() =
  ## Build, inspect, and execute the full golden corpus for each backend.
  const Usage = "Usage: test_native /absolute/path/to/nifty " &
    "[--opt:none|speed]"
  if paramCount() notin 1 .. 2:
    quit(Usage, 1)
  var optimizationArgs: seq[string]
  if paramCount() == 2:
    if paramStr(2) notin ["--opt:none", "--opt:speed"]:
      quit(Usage, 1)
    optimizationArgs.add paramStr(2)
  let optimization = if optimizationArgs.len == 0: "compiler default"
    else: paramStr(2)[6 .. ^1]
  echo "Native optimization: ", optimization
  let
    compiler = absolutePath(paramStr(1))
    root = currentSourcePath().parentDir
    work = getTempDir() / ("nifty_native_tests_" & $getCurrentProcessId() &
      "_" & $int(epochTime()))
  doAssert fileExists(compiler), "Compiler does not exist: " & compiler
  createDir(work)
  var passed, failed, emitted, images, skipped = 0
  for name in ["scripts", "runtime", "errors", "syntax", "native"]:
    if dirExists(root / name):
      copyFixtures(root / name, work / name)

  for target in ["c", "arm64", "amd64"]:
    let runnable = target == "c" or canExecute(target)
    echo "Testing ", target, " (execute=", runnable, ")"
    for name in ["scripts", "native", "runtime", "errors", "syntax"]:
      let mode = if name in ["errors", "syntax"]: Reject
        elif name == "runtime": Trap
        else: Run
      for path in fixtures(work / name):
        if not supportsFixture(path):
          echo "SKIP ", target, "/", name, "/", path.extractFilename,
            ": fixture requires another operating system"
          inc skipped
          continue
        let
          label = target & "/" & name & "/" & path.extractFilename
          expectedPath = path.changeFileExt(".txt")
        doAssert fileExists(expectedPath), "Missing golden: " & expectedPath
        let
          expected = normalized(readFile(expectedPath))
          imageOnly = target != "c" and not runnable
          binary = path.changeFileExt("." & target &
            (if imageOnly: ".niftybin"
             else: (when defined(windows): ".exe" else: ".bin")))
        var arguments = @["build", path, "--backend:" & target, "-o", binary]
        if imageOnly:
          arguments.add "--emit-native"
        if target != "c":
          arguments.add optimizationArgs
        let built = run(compiler, arguments, isolated = target != "c")
        if mode == Reject:
          var actual = normalized(built.output)
            .replace(path.parentDir & DirSep, "")
          actual.removePrefix("nifty: ")
          if built.code notin [0, -1] and actual == expected:
            inc passed
          else:
            echo "FAIL ", label, ": expected rejection: ", expected
            echo "Actual (", built.code, "): ", actual
            inc failed
          continue
        if built.code != 0 or not fileExists(binary):
          echo "FAIL ", label, ": build (", built.code, ")\n", built.output
          inc failed
          continue
        if target != "c":
          if imageOnly:
            if imageTarget(binary, target):
              inc images
            else:
              echo "FAIL ", label, ": wrong native image architecture"
              inc failed
            continue
          if not executableTarget(binary, target):
            echo "FAIL ", label, ": wrong executable architecture"
            inc failed
            continue
          inc emitted
        if not runnable:
          continue
        let
          command = executionArgs(binary, target)
          executed = run(command.exe, command.args, isolated = true)
          actual = normalized(executed.output)
          matches = if mode == Trap:
              executed.code notin [0, -1] and expected in actual
            else:
              executed.code == 0 and actual == expected
        if matches:
          inc passed
        else:
          echo "FAIL ", label, ": execution (", executed.code, ")"
          echo "Expected:\n", expected, "\nActual:\n", actual
          inc failed

  # Check the CLI artifact paths separately from build/run behavior.
  let sample = work / "scripts" / "helloworld.nifty"
  let cArtifact = sample.changeFileExt(".c")
  if fileExists(cArtifact):
    removeFile(cArtifact)
  let c = run(compiler, @[sample, "--emit-c"])
  if c.code == 0 and fileExists(cArtifact) and readFile(cArtifact).len > 0:
    inc passed
  else:
    echo "FAIL --emit-c: ", c.output
    inc failed
  let ir = run(compiler, @[sample, "--emit-ir"] & optimizationArgs)
  if ir.code == 0 and fileExists(sample.changeFileExt(".ir")) and
      readFile(sample.changeFileExt(".ir")).len > 0:
    inc passed
  else:
    echo "FAIL --emit-ir: ", ir.output
    inc failed
  for target in ["arm64", "amd64"]:
    let artifact = sample.changeFileExt(".niftybin")
    if fileExists(artifact):
      removeFile(artifact)
    let native = run(compiler, @[sample, "--backend:" & target,
      "--emit-native"] & optimizationArgs, isolated = true)
    if native.code == 0 and fileExists(artifact) and
        imageTarget(artifact, target):
      inc passed
    else:
      echo "FAIL --emit-native/", target, ": ", native.output
      inc failed
    let reported = run(compiler, @["report", sample, "--backend:" & target] &
      optimizationArgs, isolated = true)
    if reported.code == 0 and "nifty native report:" in reported.output and
        "(" & target & ")" in reported.output:
      inc passed
    else:
      echo "FAIL report/", target, ": ", reported.output
      inc failed

  # Do not normalize this output: CR, LF, and zero bytes are language data.
  let binarySource = work / "binary_output.nifty"
  writeFile(binarySource, "thread main() =\n  echo \"a\\0b\\r\\nc\\nd\"\n")
  for target in ["c", "arm64", "amd64"]:
    if target != "c" and not canExecute(target):
      continue
    let binary = work / ("binary_output_" & target &
      (when defined(windows): ".exe" else: ".bin"))
    var arguments = @["build", binarySource, "--backend:" & target,
      "-o", binary]
    if target != "c":
      arguments.add optimizationArgs
    let built = run(compiler, arguments, isolated = target != "c")
    if built.code == 0:
      let command = executionArgs(binary, target)
      let executed = run(command.exe, command.args, isolated = true)
      if executed.code == 0 and executed.output == "a\0b\r\nc\nd\n":
        inc passed
        continue
    echo "FAIL ", target, "/binary_output: bytes were not preserved"
    inc failed

  echo "Native backend tests (opt=", optimization, "): ",
    passed, " passed, ", failed,
    " failed, ", emitted, " native executables inspected, ", images,
    " cross-target images inspected, ", skipped, " platform skips"
  if failed > 0:
    echo "Artifacts retained at ", work
    quit(1)
  removeDir(work)

main()

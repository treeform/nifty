#!/usr/bin/env python3
"""Validate Snappy benchmark framing, snapshots, and sample orchestration."""

from contextlib import redirect_stderr
import hashlib
import io
from pathlib import Path
from types import SimpleNamespace
import tempfile
from unittest.mock import patch

import run_snappy as run


def rejects(action, exception=run.BenchmarkError):
  """Require malformed or unavailable configurations to fail."""
  try:
    action()
  except exception:
    return
  raise AssertionError("Invalid benchmark input accepted")


def response(size=100, repeat=2):
  """Produce independently encoded literal-only blocks with known clocks."""
  oracle = run.load("snappy_reference", run.Root / "tests/snappy_reference.py")
  expected = run.expectedWorkloads(size)
  lines = []
  for kind, fixture in enumerate(expected):
    data = oracle.literalBlock(fixture["input"])
    lines += ["NIFTY_SNAPPY_V1", f"kind {kind}", f"size {size}", f"repeat {repeat}",
              "compressed_hex " + data.hex()]
    for index in range(repeat):
      lines += [f"iteration {index} 10 999999990 11 30 12 10 12 60 0 0 0 0 {len(data)} {run.digest(data)} {fixture['checksum']}"]
  return ("\n".join(lines) + "\n").encode(), expected


def testOracle():
  """Lock fixture byte formulas and cross-fragment deterministic hashes."""
  fixtures = run.expectedWorkloads(262144)
  assert fixtures[0]["input"][:45] == b"The quick brown fox jumps over the lazy dog.\n"
  assert fixtures[1]["input"][:14] == b"ABCDEFGABCDEFG"
  assert fixtures[2]["input"][:8] == bytes([143, 226, 70, 125, 241, 35, 81, 89])
  assert len(set(fixtures[2]["input"])) == 256
  for fixture in fixtures:
    assert len(fixture["input"]) == 262144
    assert fixture["input_sha256"] == hashlib.sha256(fixture["input"]).hexdigest()


def testProtocol():
  """Reject corruption, clock failures, truncation, and iteration mismatches."""
  valid, expected = response()
  parsed = run.parseOutput(valid, 100, 2, expected)
  assert len(parsed) == 3
  for block in parsed:
    assert len(block["iterations"]) == 2
    assert block["iterations"][0]["compress_ns"] == 40
    assert block["iterations"][0]["decompress_ns"] == 50
  invalid = [valid[:-1], valid + b"extra\n", valid.replace(b"\n", b"\r\n"),
             valid.replace(b"NIFTY_SNAPPY_V1", b"NIFTY_SNAPPY_V2"),
             valid.replace(b"kind 1", b"kind 0"), valid.replace(b"size 100", b"size 99"),
             valid.replace(b"repeat 2", b"repeat 1"),
             valid.replace(b"iteration 1 ", b"iteration 0 "),
             valid.replace(b" 12 60 0 0 0 0 ", b" 12 60 0 0 0 1 "),
             valid.replace(b" 11 30 ", b" 9 30 "),
             valid.replace(b" 11 30 ", b" 11 1000000000 "),
             valid.replace(b"iteration 0 10", b"iteration 0 010"),
             valid.replace(b"iteration 0 10", b"iteration 0 -1"),
             valid.replace(b"compressed_hex 64", b"compressed_hex 63"),
             valid.replace(b"compressed_hex ", b"compressed_hex ff"),
             valid.replace(b"NIFTY_SNAPPY_V1", b"NIFTY_SNAPPY_V1\xff")]
  lines = valid.splitlines()
  row = lines[5].split()
  for index in (14, 15, 16):
    changed = row.copy()
    changed[index] = str(int(changed[index]) + 1).encode()
    invalid.append(valid.replace(lines[5], b" ".join(changed), 1))
  for data in invalid:
    rejects(lambda: run.parseOutput(data, 100, 2, expected))
  wrong = [dict(item) for item in expected]
  wrong[0]["input"] = b"x" * 100
  rejects(lambda: run.parseOutput(valid, 100, 2, wrong))


def testArguments():
  """Require unique substitutions and sensible finite CLI bounds."""
  source = 'import "../lib/snappy"\nconst Size = 262144\nconst Repetitions = 10\nconst ClockId = 6\n'
  with patch.object(run.time, "CLOCK_MONOTONIC", 1, create=True):
    changed = run.configuredSource(source, 4, 3)
    assert 'import "lib/snappy"' in changed and 'const Size = 4' in changed
    rejects(lambda: run.configuredSource(source + source, 1, 1))
    rejects(lambda: run.configuredSource('', 1, 1))
  assert run.parseArguments(["--backend", "c,arm64,c", "--backend", "amd64"]).backend == ["c", "arm64", "amd64"]
  for args in (["--size", "0"], ["--size", "4194305"], ["--repeat", "0"],
               ["--repeat", "1001"], ["--samples", "4"], ["--warmups", "0"],
               ["--timeout", "nan"], ["--timeout", "inf"], ["--timeout", "0"],
               ["--opt", "fast"], ["--backend", "invalid"]):
    with redirect_stderr(io.StringIO()):
      rejects(lambda: run.parseArguments(args), SystemExit)


def testSnapshot():
  """Build UTF-8 snapshots, remove stale binaries, and use Rosetta explicitly."""
  with tempfile.TemporaryDirectory() as temporary:
    output = Path(temporary)
    source = 'import "../lib/snappy"\nconst Size = 262144\nconst Repetitions = 10\nconst ClockId = 6\n# Café.\n'
    options = SimpleNamespace(output=output, size=100, repeat=2,
                              library_files={"snappy.nifty": b"snapshot\n"},
                              source_text=source, compiler=Path("test-nifty"),
                              opt="none", timeout=1,
                              host={"physical_architecture": "arm64"})
    stale = output / "build/n100-r2/amd64/snappy"
    stale.parent.mkdir(parents=True)
    stale.write_bytes(b"stale")
    calls = []
    def build(command, timeout, env):
      """Observe stale removal before returning a synthetic executable."""
      assert not stale.exists()
      calls.append(command)
      stale.write_bytes(b"fresh")
      return SimpleNamespace(stdout=b"built", stderr=b"diagnostic"), 99
    with patch.object(run.Ray, "runCommand", side_effect=build), \
         patch.object(run.Ray, "binaryArchitectures", return_value=["amd64"]), \
         patch.object(run.time, "CLOCK_MONOTONIC", 1, create=True):
      result = run.buildBackend("amd64", options, {})
      expectedSource = run.configuredSource(source, 100, 2).encode("utf-8")
    assert len(calls) == 1 and "--opt:none" in calls[0]
    assert result["compile_wall_ns"] == 99
    assert result["execution_command"] == ["/usr/bin/arch", "-x86_64", str(stale)]
    assert Path(result["source"]).read_bytes() == expectedSource
    assert (stale.parent / "lib/snappy.nifty").read_bytes() == b"snapshot\n"
    assert result["executable_sha256"] == hashlib.sha256(b"fresh").hexdigest()


def testSampling():
  """Compile once, rotate order, validate warmups, and retain all raw clocks."""
  valid, expected = response()
  calls = []
  def build(backend, options, env):
    """Produce empty sample state for one backend."""
    calls.append(("build", backend))
    return {"backend": backend, "execution_command": [backend], "raw_samples": [],
            "warmups": [], "process_wall_ns": []}
  def execute(command, timeout, env):
    """Record process order while returning valid independently encoded data."""
    calls.append(("run", command[0]))
    return SimpleNamespace(stdout=valid, stderr=b""), 123
  with tempfile.TemporaryDirectory() as temporary:
    options = SimpleNamespace(output=Path(temporary), size=100, repeat=2,
                              samples=5, warmups=1, timeout=1)
    with patch.object(run, "buildBackend", side_effect=build), \
         patch.object(run.Ray, "runCommand", side_effect=execute):
      result = run.benchmark(options, ["c", "arm64", "amd64"], {}, {})
    assert calls[:3] == [("build", backend) for backend in ("c", "arm64", "amd64")]
    assert result["sample_order"][:3] == [["c", "arm64", "amd64"], ["arm64", "amd64", "c"], ["amd64", "c", "arm64"]]
    assert len(calls) == 21
    for backend in result["backends"]:
      assert len(backend["raw_samples"]) == 5 and len(backend["warmups"]) == 1
      assert backend["workloads"][0]["compress_ns"]["median"] == 40
      assert backend["workloads"][0]["decompress_ns"]["median"] == 50
    baseline = run.parseOutput(valid, 100, 2, expected)
    changed = [dict(item) for item in baseline]
    changed[0]["compressed_sha256"] = "0" * 64
    with patch.object(run, "buildBackend", side_effect=build), \
         patch.object(run.Ray, "runCommand", side_effect=execute), \
         patch.object(run, "parseOutput", side_effect=[baseline, changed]):
      rejects(lambda: run.benchmark(options, ["c"], {}, {}))
    for stderr, stdout in ((b"failure", valid), (b"", valid[:-1])):
      with patch.object(run, "buildBackend", side_effect=build), \
           patch.object(run.Ray, "runCommand", return_value=(SimpleNamespace(stdout=stdout, stderr=stderr), 123)) as executeMock:
        rejects(lambda: run.benchmark(options, ["c"], {}, {}))
        assert executeMock.call_count == 1


def testUnavailableAndStaleReports():
  """Remove old reports before failed discovery and reject unavailable targets."""
  with tempfile.TemporaryDirectory() as temporary:
    output = Path(temporary)
    for name in ("results.json", "results.md"):
      (output / name).write_bytes(b"stale")
    with patch.object(run.Ray, "hostInfo", return_value={"system": "Windows"}):
      rejects(lambda: run.main(["--output", temporary]))
    assert not (output / "results.json").exists() and not (output / "results.md").exists()
    with patch.object(run.Ray, "hostInfo", return_value={"system": "Darwin"}), \
         patch.object(run.Ray, "availableBackends", return_value=["c"]), \
         patch.object(run.time, "CLOCK_MONOTONIC", 1, create=True):
      rejects(lambda: run.main(["--backend", "amd64", "--output", temporary]))
    with patch.object(run.Ray, "hostInfo", return_value={"system": "Darwin"}), \
         patch.object(run.time, "CLOCK_MONOTONIC", None, create=True), \
         patch.object(run.Ray, "availableBackends", side_effect=AssertionError("Discovery must follow clock validation")):
      rejects(lambda: run.main(["--output", temporary]))


def testStandalone():
  """Snapshot standalone inputs and reject mismatched assembly binaries."""
  darwin = {"system": "Darwin", "physical_architecture": "arm64"}
  assert run.parseArguments(["--backend", "amd64,hand-c,c,hand-asm,arm64,wasm"]).backend == list(run.Backends)
  with patch.object(run.Ray, "availableBackends", side_effect=AssertionError("No Nifty discovery")):
    assert run.availableBackends(darwin, None, "cc", False) == ["hand-asm", "c-straight"]
    assert run.availableBackends({"system": "Linux", "physical_architecture": "arm64"}, None, "cc", False) == ["c-straight"]
    assert run.availableBackends(darwin, None, None, False) == []
  with patch.object(run.Ray, "availableBackends", return_value=["arm64"]):
    assert run.availableBackends(darwin, None, "custom-cc") == ["hand-asm", "c-straight", "c", "arm64"]
  with tempfile.TemporaryDirectory() as temporary:
    options = SimpleNamespace(output=Path(temporary), size=100, repeat=2,
      straight_c_bytes=b"/* Frozen C. */", hand_asm_bytes=b"// Frozen ASM.",
      hand_asm_manifest_bytes=b'{"origin":"test"}', cc="test-cc",
      timeout=1, host=darwin)
    def build(command, timeout, env):
      """Write a fixture binary without invoking either compiler."""
      Path(command[-1]).write_bytes(b"binary")
      assert "-DSNAPPY_SIZE=100" in command
      return SimpleNamespace(stdout=b"", stderr=b""), 1
    with patch.object(run.time, "CLOCK_MONOTONIC", 1, create=True), patch.object(run.Ray, "runCommand", side_effect=build), patch.object(run.Ray, "binaryArchitectures", return_value=["arm64"]):
      result = run.buildBackend("hand-asm", options, {})
      assert result["source_sha256"] == hashlib.sha256(options.straight_c_bytes).hexdigest()
      assert result["assembly_sha256"] == hashlib.sha256(options.hand_asm_bytes).hexdigest()
      assert result["provenance_sha256"] == hashlib.sha256(options.hand_asm_manifest_bytes).hexdigest()
      assert (Path(result["source"]).parent / "snappy_manifest.json").read_bytes() == options.hand_asm_manifest_bytes
      assert "-DSNAPPY_HAND_ASM" in result["compile_command"]
      run.buildBackend("c-straight", options, {})
    with patch.object(run.time, "CLOCK_MONOTONIC", 1, create=True), patch.object(run.Ray, "runCommand", side_effect=build), patch.object(run.Ray, "binaryArchitectures", return_value=["amd64"]):
      rejects(lambda: run.buildBackend("hand-asm", options, {}))


def testStandaloneMain():
  """Run standalone selection with absent Nifty inputs and record hashes."""
  import json
  from contextlib import redirect_stdout
  with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    source = directory / "codec.c"
    source.write_bytes(b"/* Snapshot. */")
    cc = directory / "cc"
    cc.write_bytes(b"compiler")
    assembly = directory / "snappy_hand.S"
    assembly.write_bytes(b"// Assembly.")
    manifest = directory / "snappy_manifest.json"
    manifest.write_bytes(b'{"origin":"fixture"}')
    args = ["--backend", "hand-asm,hand-c", "--compiler", str(directory / "missing"),
      "--source", str(directory / "missing.nifty"), "--hand-c-source", str(source),
      "--hand-asm-source", str(assembly), "--output", str(directory / "out")]
    def benchmark(options, backends, host, env):
      """Check immutable inputs before returning an empty report fixture."""
      assert options.source_text is None and options.library_files == {}
      assert options.straight_c_bytes == source.read_bytes()
      assert backends == ["hand-asm", "c-straight"]
      return {"backends": [], "correctness": "Validated"}
    host = {"system": "Darwin", "physical_architecture": "arm64"}
    with patch.object(run.time, "CLOCK_MONOTONIC", 1, create=True), patch.object(run.Ray, "hostInfo", return_value=host), patch.object(run.shutil, "which", return_value=str(cc.resolve())), patch.object(run.Ray, "availableBackends", side_effect=AssertionError("No Nifty discovery")), patch.object(run.Ray, "optionalCommand", return_value="fixture"), patch.object(run, "benchmark", side_effect=benchmark), redirect_stdout(io.StringIO()):
      assert run.main(args) == 0
    report = json.loads((directory / "out/results.json").read_bytes())
    for path in (source, assembly, manifest, cc):
      assert report["inputs_sha256"][str(path.resolve())] == hashlib.sha256(path.read_bytes()).hexdigest()
    assert report["toolchain"]["compiler"] is None
    with patch.object(run.Ray, "hostInfo", return_value={"system": "Linux", "physical_architecture": "arm64"}):
      rejects(lambda: run.main(args))


def testCombined():
  """Sum paired iterations before means and medians across processes."""
  valid, expected = response()
  baseline = run.parseOutput(valid, 100, 2, expected)
  datasets = []
  for compress, decompress in [(1, 100), (50, 50), (100, 1)]:
    datasets.append([{**block, "iterations": [
      {"compress_ns": compress, "decompress_ns": decompress,
       "roundtrip_ns": compress + decompress} for unused in range(2)]}
      for block in baseline])
  def build(backend, options, env):
    """Supply sample state for aggregation only."""
    return {"backend": backend, "execution_command": [backend],
      "raw_samples": [], "warmups": [], "process_wall_ns": []}
  with tempfile.TemporaryDirectory() as temporary:
    options = SimpleNamespace(output=Path(temporary), size=100, repeat=2,
      samples=3, warmups=0, timeout=1)
    with patch.object(run, "buildBackend", side_effect=build), patch.object(run.Ray, "runCommand", return_value=(SimpleNamespace(stdout=valid, stderr=b""), 1)), patch.object(run, "parseOutput", side_effect=datasets):
      workload = run.benchmark(options, ["c"], {}, {})["backends"][0]["workloads"][0]
    assert workload["compress_ns"]["median"] == 50
    assert workload["decompress_ns"]["median"] == 50
    assert workload["roundtrip_ns"]["median"] == 101


testStandalone()
testStandaloneMain()
testCombined()

testOracle()
testProtocol()
testArguments()
testSnapshot()
testSampling()
testUnavailableAndStaleReports()
print("Snappy benchmark oracle, protocol, snapshot, availability, and sampling checks passed")


def testWasmBuild():
  """Require WASI clocks, memory64 artifacts, and engine execution commands."""
  assert run.parseArguments(["--backend", "wasm,wasm64"]).backend == ["wasm64"]
  host = {"system": "Darwin", "physical_architecture": "arm64", "rosetta_available": True}
  with patch.object(run.Ray, "availableBackends", return_value=["c", "arm64", "amd64", "wasm64"]):
    assert run.availableBackends(host, Path("nifty"), "cc") == list(run.Backends)
  with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    options = SimpleNamespace(output=directory, compiler=directory / "nifty", timeout=1,
                              opt="speed", emit_ir=False, host=host, library_files={},
                              size=4, repeat=2,
                              source_text=(run.Root / "benchmarks/snappy.nifty").read_text())
    commands = []
    def build(command, timeout, env):
      """Write a bounded memory64 module only at the compiler output path."""
      commands.append(command)
      Path(command[command.index("-o") + 1]).write_bytes(b"\0asm\x01\0\0\0\x05\x04\x01\x05\x01\x02")
      return SimpleNamespace(stdout=b"", stderr=b""), 1
    with patch.object(run.Ray, "runCommand", side_effect=build), patch.object(
        run.Ray, "wasmtimeExecutable", return_value="/engine/wasmtime"), patch.object(
        run.time, "CLOCK_MONOTONIC", 6, create=True):
      result = run.buildBackend("wasm64", options, {})
      assert result["executable"].endswith(".wasm")
      assert result["execution_command"] == ["/engine/wasmtime", "run", "-W", "memory64=y", result["executable"]]
      assert "const ClockId = 1\n" in Path(result["source"]).read_text()
      assert "--backend:wasm64" in commands[0]
    def nativeBuild(command, timeout, env):
      """Simulate an incompatible native artifact returned for WASM."""
      Path(command[command.index("-o") + 1]).write_bytes(b"\xcf\xfa\xed\xfe\x0c\0\0\x01")
      return SimpleNamespace(stdout=b"", stderr=b""), 1
    with patch.object(run.Ray, "runCommand", side_effect=nativeBuild):
      try:
        run.buildBackend("wasm64", options, {})
      except run.BenchmarkError:
        pass
      else:
        raise AssertionError("Native executable accepted for WASM")

testWasmBuild()

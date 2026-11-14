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
               ["--opt", "fast"], ["--backend", "hand-asm"]):
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


testOracle()
testProtocol()
testArguments()
testSnapshot()
testSampling()
testUnavailableAndStaleReports()
print("Snappy benchmark oracle, protocol, snapshot, availability, and sampling checks passed")

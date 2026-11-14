#!/usr/bin/env python3
"""Check the JSON benchmark oracle and protocol without compiler builds."""

from contextlib import redirect_stderr
from unittest.mock import patch
import hashlib
import io
from pathlib import Path
from types import SimpleNamespace
import tempfile

import run_json as run


def expectError(action, exception=run.BenchmarkError):
  """Require rejection of malformed benchmark data."""
  try:
    action()
  except exception:
    return
  raise AssertionError("Invalid benchmark data was accepted")


def taggedChecksum(data):
  """Reduce explicit expected bytes without reproducing tree traversal."""
  checksum = 0
  for byte in data:
    checksum = (checksum * 257 + byte) % 1_000_000_007
  return checksum


def testOracle():
  """Check explicit tagged-byte vectors and independently observed fixtures."""
  expectedText = r'{"name":"Nifty\nJSON","unicode":"\u00e9\uD83D\uDE03","nul":"a\u0000b","integer":9007199254740993,"fraction":-12.50e+2,"enabled":true,"disabled":false,"nothing":null,"nested":[1,"x",{"k":false},[]],"empty":{}}'
  assert run.RecordText == expectedText
  for records, checksum in ((1, 258032830), (128, 25086498)):
    expectedInput = ("[" + ",".join([expectedText] * records) + "]").encode()
    expected = run.expectedWorkload(records)
    assert expected["input"] == expectedInput
    assert expected["input_bytes"] == len(expectedInput)
    assert expected["input_sha256"] == hashlib.sha256(expectedInput).hexdigest()
    assert expected["checksum"] == checksum
  vectors = [
    (None, b"\x01"), (False, b"\x02\x00"), (True, b"\x02\x01"),
    (run.Number("1"), b"\x031\x00"),
    (run.Number("1.0"), b"\x031.0\x00"),
    (run.Number("-12.50e+2"), b"\x03-12.50e+2\x00"),
    ("é😃", b"\x04\xc3\xa9\xf0\x9f\x98\x83\x00"),
    ("a\x00b", b"\x04a\x00b\x00"),
    ([], b"\x05\xff"), (run.Object(), b"\x06\xff"),
    (run.Object([("k", None), ("k", True)]),
     b"\x06k\x00\x01k\x00\x02\x01\xff"),
    (run.Object([("k", True), ("k", None)]),
     b"\x06k\x00\x02\x01k\x00\x01\xff"),
    ([run.Object([("a", [False, run.Number("2")])])],
     b"\x05\x06a\x00\x05\x02\x00\x032\x00\xff\xff\xff"),
  ]
  for tree, encoded in vectors:
    assert run.digest(tree) == taggedChecksum(encoded)


def response(records=1, repeat=2):
  """Build a valid response crossing a monotonic second boundary."""
  expected = run.expectedWorkload(records)
  checksum = expected["checksum"]
  lines = ["NIFTY_JSON_V1", f"records {records}", f"repeat {repeat}",
           f"input_bytes {expected['input_bytes']}", "start_sec 10",
           "start_nsec 999999990", "end_sec 11", "end_nsec 30",
           "clock_status 0 0", f"successes {repeat}"]
  lines += [f"parse_checksum {index} {checksum}" for index in range(repeat)]
  lines += [f"batch_checksum {checksum * repeat}"]
  return ("\n".join(lines) + "\n").encode(), expected


def testProtocol():
  """Reject framing, clock, cardinality, and independent oracle mismatches."""
  valid, expected = response()
  parsed = run.parseOutput(valid, 1, 2, expected)
  assert parsed["elapsed_ns"] == 40
  assert parsed["checksums"] == [expected["checksum"]] * 2
  assert parsed["batch_checksum"] == expected["checksum"] * 2
  invalid = [valid[:-1], valid + b"extra\n", valid.replace(b"\n", b"\r\n"),
             valid.replace(b"NIFTY_JSON_V1", b"wrong"),
             valid.replace(b"records 1", b"records 2"),
             valid.replace(b"repeat 2", b"repeat 1"),
             valid.replace(b"successes 2", b"successes 1"),
             valid.replace(b"clock_status 0 0", b"clock_status 0 1"),
             valid.replace(b"end_sec 11", b"end_sec 9"),
             valid.replace(b"end_sec 11\nend_nsec 30", b"end_sec 10\nend_nsec 999999990"),
             valid.replace(b"end_nsec 30", b"end_nsec 1000000000"),
             valid.replace(b"parse_checksum 1 ", b"parse_checksum 0 "),
             valid.replace(b"start_sec 10", b"start_sec 010"),
             valid.replace(b"start_sec 10", b"start_sec -1"),
             valid.replace(b"NIFTY_JSON_V1", b"NIFTY_JSON_V1\xff")]
  for name in ("input_bytes", "batch_checksum"):
    value = expected["input_bytes"] if name == "input_bytes" else expected["checksum"] * 2
    invalid.append(valid.replace(f"{name} {value}".encode(), f"{name} {value + 1}".encode()))
  checksum = expected["checksum"]
  invalid.append(valid.replace(f"parse_checksum 0 {checksum}".encode(),
                               f"parse_checksum 0 {checksum + 1}".encode()))
  for data in invalid:
    expectError(lambda: run.parseOutput(data, 1, 2, expected))
  wrong = dict(expected, checksum=checksum + 1)
  expectError(lambda: run.parseOutput(valid, 1, 2, wrong))


def testConfiguration():
  """Require exact unique source constants and bounded CLI arguments."""
  source = ('import "../lib/json"\nconst Records = 128\n'
            'const Repetitions = 10\nconst ClockId = 6\n')
  with patch.object(run.time, "CLOCK_MONOTONIC",
                    getattr(run.time, "CLOCK_MONOTONIC", 1), create=True):
    changed = run.configuredSource(source, 4, 3)
    assert changed == ('import "lib/json"\nconst Records = 4\n'
                       'const Repetitions = 3\n'
                       f'const ClockId = {run.time.CLOCK_MONOTONIC}\n')
    expectError(lambda: run.configuredSource(source + source, 4, 3))
    expectError(lambda: run.configuredSource("const Records = 128\n", 4, 3))
  options = run.parseArguments(["--backend", "c,amd64", "--backend", "c"])
  assert options.backend == ["c", "amd64"]
  assert (options.records, options.repeat, options.samples, options.warmups) == (128, 10, 5, 1)
  for arguments in (["--records", "0"], ["--records", "4097"],
                    ["--repeat", "0"], ["--repeat", "1001"],
                    ["--samples", "4"], ["--samples", "1001"],
                    ["--warmups", "0"], ["--warmups", "1001"],
                    ["--backend", "unknown"], ["--opt", "fast"],
                    ["--timeout", "nan"], ["--timeout", "inf"],
                    ["--timeout", "0"], ["--timeout", "3601"]):
    with redirect_stderr(io.StringIO()):
      expectError(lambda: run.parseArguments(arguments), SystemExit)


def testSampling():
  """Check compilation scope, rotation, raw samples, and failed warmups."""
  valid, expected = response()
  calls = []

  def build(backend, options, env):
    """Return fresh backend state without invoking a compiler."""
    calls.append(("build", backend))
    return {"backend": backend, "execution_command": [backend],
            "cycle_ns_per_parse": [], "process_wall_ns": [],
            "raw_samples": [], "warmup_checksums": []}

  def execute(command, timeout, env):
    """Record process order and return an oracle-validated response."""
    calls.append(("run", command[0]))
    return SimpleNamespace(stdout=valid, stderr=b""), 1000 + len(calls)

  with tempfile.TemporaryDirectory() as temporary:
    options = SimpleNamespace(records=1, repeat=2, samples=5, warmups=1,
                              timeout=1, output=Path(temporary))
    backends = ["c", "arm64", "amd64"]
    with patch.object(run, "buildBackend", side_effect=build), \
         patch.object(run.Ray, "runCommand", side_effect=execute):
      result = run.benchmark(options, backends, {}, {})
    assert calls[:3] == [("build", backend) for backend in backends]
    orders = [backends[index % 3:] + backends[:index % 3] for index in range(6)]
    assert result["sample_order"] == orders
    assert calls[3:] == [("run", backend) for order in orders for backend in order]
    assert (options.output / "input.json").read_bytes() == expected["input"]
    for backend in result["backends"]:
      assert backend["warmup_checksums"] == [expected["checksum"] * 2]
      assert len(backend["raw_samples"]) == 5
      assert backend["cycle_ns_per_parse"]["median"] == 20
      for sample in backend["raw_samples"]:
        assert sample["elapsed_ns"] == 40
        assert sample["checksums"] == [expected["checksum"]] * 2
        assert sample["process_wall_ns"] > 1000
        assert sample["clock_fields"]["start_sec"] == 10
    invalid = valid.replace(b"successes 2", b"successes 1")
    calls.clear()
    with patch.object(run, "buildBackend", side_effect=build), \
         patch.object(run.Ray, "runCommand", return_value=(
           SimpleNamespace(stdout=invalid, stderr=b""), 1000)) as executeMock:
      expectError(lambda: run.benchmark(options, backends, {}, {}))
      assert executeMock.call_count == 1
    with patch.object(run, "buildBackend", side_effect=build), \
         patch.object(run.Ray, "runCommand", return_value=(
           SimpleNamespace(stdout=valid, stderr=b"unexpected"), 1000)):
      expectError(lambda: run.benchmark(options, backends, {}, {}))


testOracle()
testProtocol()
testConfiguration()
testSampling()
print("JSON benchmark oracle, protocol, configuration, and sampling checks passed")

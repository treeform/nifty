#!/usr/bin/env python3
"""Check the JSON benchmark oracle and protocol without compiler builds."""

from contextlib import redirect_stderr, redirect_stdout
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
  options = run.parseArguments(["--backend", "hand-asm,c-straight,c,amd64",
                                "--backend", "c-straight"])
  assert options.backend == ["hand-asm", "c-straight", "c", "amd64"]
  assert options.hand_asm_source == run.Root / "benchmarks/arm64/json_parser_hand.S"
  assert options.straight_c_source == run.Root / "benchmarks/json_parser_straight.c"
  with patch.dict(run.os.environ, {"CC": "test-json-cc"}):
    assert run.parseArguments([]).cc == "test-json-cc"
    assert run.parseArguments(["--cc", "explicit-cc"]).cc == "explicit-cc"
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


def testStraightC():
  """Build snapshot C once without accessing Nifty compiler or sources."""
  with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    source = directory / "standalone.c"
    sourceText = "int main(void) { return 0; }\n"
    source.write_text("changed after snapshot\n", encoding="utf-8")
    for backend, architecture in (("c-straight", "arm64"),
                                  ("c-straight", "amd64"), ("hand-asm", "arm64")):
      options = SimpleNamespace(
        output=directory / backend / architecture, records=4, repeat=3,
        hand_asm_bytes=b"assembly snapshot\n",
        hand_asm_manifest_bytes=b'{"origin": "clang baseline"}\n',
        straight_c_source=source, straight_c_text=sourceText,
        cc="test-json-cc", timeout=1, emit_ir=True,
        host={"system": "Darwin", "physical_architecture": "arm64"})
      commands = []
      environment = {"JSON_TEST": "snapshot"}

      def build(command, timeout, env):
        """Capture the direct C invocation and synthesize its executable."""
        assert timeout == 1 and env is environment
        commands.append(command)
        Path(command[command.index("-o") + 1]).write_bytes(b"C executable")
        return SimpleNamespace(stdout=b"built", stderr=b"diagnostic"), 123

      with patch.object(run.Ray, "runCommand", side_effect=build), \
           patch.object(run.Ray, "binaryArchitectures", return_value=[architecture]), \
           patch.object(run.time, "CLOCK_MONOTONIC", 1, create=True):
        result = run.buildBackend(backend, options, environment)
      assert len(commands) == 1
      command = commands[0]
      assert command[:1 + len(run.Ray.StraightCFlags)] == [
        "test-json-cc"] + run.Ray.StraightCFlags
      for flag in ("-DRECORDS=4", "-DREPETITIONS=3", "-DCLOCK_ID=1"):
        assert flag in command
      snapshot = Path(result["source"])
      assert str(snapshot) in command
      assert snapshot != source and snapshot.read_text() == sourceText
      assert result["source_sha256"] == hashlib.sha256(sourceText.encode()).hexdigest()
      assert result["executable_sha256"] == hashlib.sha256(b"C executable").hexdigest()
      assert result["compile_wall_ns"] == 123 and result["inspection"] is None
      assert result["execution_architecture"] == architecture
      if backend == "hand-asm":
        assert result["label"] == "Hand ASM (ARM64)"
        assert command[command.index("-arch") + 1] == "arm64"
        assert "-DJSON_HAND_ASM" in command
        assembly = Path(result["assembly"])
        assert str(assembly) in command
        assert assembly.read_bytes() == options.hand_asm_bytes
        assert result["assembly_sha256"] == hashlib.sha256(options.hand_asm_bytes).hexdigest()
        assert Path(result["assembly_provenance"]).read_bytes() == options.hand_asm_manifest_bytes
      else:
        assert "C straight" in result["label"]
        assert result["assembly"] is None
      assert ("Rosetta translated" in result["label"]) == (architecture == "amd64")
      prefix = ["/usr/bin/arch", "-x86_64"] if architecture == "amd64" else []
      assert result["execution_command"] == prefix + [result["executable"]]
      assert (snapshot.parent / "build.stdout").read_bytes() == b"built"
      assert (snapshot.parent / "build.stderr").read_bytes() == b"diagnostic"


def testStandaloneMain():
  """Run standalone orchestration with missing Nifty inputs and libraries."""
  with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    source = directory / "parser.c"
    source.write_text("standalone snapshot\n", encoding="utf-8")
    compiler = directory / "test-cc"
    compiler.write_bytes(b"compiler")
    output = directory / "output"
    assembly = directory / "parser.S"
    assembly.write_bytes(b"assembly snapshot\n")
    (directory / "json_parser_manifest.json").write_text('{"origin": "clang"}')
    host = {"system": "Darwin", "physical_architecture": "arm64"}

    def benchmark(options, backends, machine, env):
      """Inspect the selected standalone inputs before report publication."""
      assert backends == selected and machine == host
      if "hand-asm" in backends:
        assert options.hand_asm_bytes == assembly.read_bytes()
      assert options.source_text is None and options.library_files == {}
      assert options.straight_c_text == "standalone snapshot\n"
      assert options.cc == str(compiler) and env["CC"] == str(compiler)
      return {}

    with patch.object(run, "Root", directory / "missing-repository"), \
         patch.object(run.Ray, "hostInfo", return_value=host), \
         patch.object(run.shutil, "which", return_value=str(compiler)), \
         patch.object(run.Ray, "availableBackends", side_effect=AssertionError("Nifty discovery")), \
         patch.object(run.Ray, "binaryArchitectures", side_effect=AssertionError("Nifty inspection")), \
         patch.object(run.Ray, "optionalCommand", return_value="C version"), \
         patch.object(run, "benchmark", side_effect=benchmark), \
         patch.object(run, "markdownReport", return_value="standalone report"), \
         patch.object(run.time, "CLOCK_MONOTONIC", 1, create=True), \
         redirect_stdout(io.StringIO()):
      for selected in (["c-straight"], ["hand-asm"], ["hand-asm", "c-straight"]):
        assert run.main(["--backend", ",".join(selected),
                         "--straight-c-source", str(source),
                         "--hand-asm-source", str(assembly),
                         "--output", str(output)]) == 0
    report = run.json.loads((output / "results.json").read_text())
    assert report["toolchain"]["compiler"] is None
    assert report["toolchain"]["compiler_architectures"] == []
    assert report["settings"]["hand_asm_sha256"] == hashlib.sha256(assembly.read_bytes()).hexdigest()
    assert report["settings"]["hand_asm_provenance"] == {"origin": "clang"}
    assert report["settings"]["source"] is None
    assert report["settings"]["library_sha256"] == {}
    assert report["settings"]["straight_c_sha256"] == hashlib.sha256(source.read_bytes()).hexdigest()


def testAvailability():
  """Keep assembly host selection separate from the shared ray registry."""
  apple = {"system": "Darwin", "physical_architecture": "arm64"}
  intel = {"system": "Darwin", "physical_architecture": "amd64"}
  linux = {"system": "Linux", "physical_architecture": "arm64"}
  with patch.object(run.Ray, "availableBackends", return_value=["arm64", "c"]):
    assert run.availableBackends(apple, Path("nifty"), "cc") == [
      "c-straight", "hand-asm", "arm64", "c"]
    assert run.availableBackends(apple, Path("nifty"), None) == ["arm64"]
    for host in (intel, linux):
      assert "hand-asm" not in run.availableBackends(host, Path("nifty"), "cc")
    assert run.availableBackends(apple, Path("missing"), "cc", False) == [
      "c-straight", "hand-asm"]
  assert "hand-asm" not in run.Ray.Backends
  with patch.object(run.Ray, "hostInfo", return_value=linux), \
       patch.object(run.time, "CLOCK_MONOTONIC", 1, create=True):
    expectError(lambda: run.main(["--backend", "hand-asm"]))
  with patch.object(run.Ray, "hostInfo", return_value=apple), \
       patch.object(run.shutil, "which", return_value=None), \
       patch.object(run.time, "CLOCK_MONOTONIC", 1, create=True):
    expectError(lambda: run.main(["--backend", "hand-asm"]))
  with patch.object(run.Ray, "hostInfo", return_value=apple), \
       patch.object(run.time, "CLOCK_MONOTONIC", None, create=True):
    expectError(lambda: run.main(["--backend", "hand-asm"]))
  with patch.object(run.Ray, "hostInfo", return_value={"system": "Windows"}):
    expectError(lambda: run.main(["--backend", "hand-asm"]))


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
    backends = ["c-straight", "hand-asm", "c", "arm64", "amd64"]
    with patch.object(run, "buildBackend", side_effect=build), \
         patch.object(run.Ray, "runCommand", side_effect=execute):
      result = run.benchmark(options, backends, {}, {})
    assert calls[:5] == [("build", backend) for backend in backends]
    orders = [backends[index % 5:] + backends[:index % 5] for index in range(6)]
    assert result["sample_order"] == orders
    assert calls[5:] == [("run", backend) for order in orders for backend in order]
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
testStraightC()
testStandaloneMain()
testAvailability()
testSampling()
print("JSON benchmark oracle, protocol, configuration, and sampling checks passed")

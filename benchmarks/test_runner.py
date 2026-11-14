#!/usr/bin/env python3
"""Exercise benchmark protocol and artifact correctness without compiler builds."""

from contextlib import redirect_stderr
from unittest.mock import patch
import io
import hashlib
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import zlib

import run


def expectError(action, exception=run.BenchmarkError):
  """Require the expected rejection instead of accepting invalid benchmark data."""
  try:
    action()
  except exception:
    return
  raise AssertionError("Invalid benchmark data was accepted")


def response():
  """Return a one-pixel protocol sample crossing a monotonic second boundary."""
  return (b"NIFTY_RAY_V1\nsize 1\nrepeat 2\nstart_sec 10\n"
          b"start_nsec 999999990\nend_sec 11\nend_nsec 30\n"
          b"clock_status 0 0\nchecksum 261\nbatch_checksum 522\nrgb 1 5 255\n")


def testProtocol():
  """Check strict framing, clock errors, dimensions, pixel values, and sums."""
  valid = response()
  result = run.parseOutput(valid, 1, 2)
  assert result["elapsed_ns"] == 40
  assert result["pixels"] == bytes((1, 5, 255))
  assert result["checksum"] == 261
  invalid = [valid[:-1], valid + b"extra\n", valid.replace(b"\n", b"\r\n"),
             valid.replace(b"clock_status 0 0", b"clock_status 0 1"),
             valid.replace(b"checksum 261", b"checksum 260"),
             valid.replace(b"batch_checksum 522", b"batch_checksum 261"),
             valid.replace(b"rgb 1 5 255", b"rgb 1 5 256"),
             valid.replace(b"rgb 1 5 255", b"rgb 01 5 255"),
             valid.replace(b"end_sec 11", b"end_sec 9"),
             valid.replace(b"end_nsec 30", b"end_nsec 1000000000"),
             valid.replace(b"NIFTY_RAY_V1", b"wrong"),
             valid.replace(b"size 1", b"size 2")]
  for data in invalid:
    expectError(lambda: run.parseOutput(data, 1, 2))
  expectError(lambda: run.parseOutput(valid, 1, 1))


def testConfiguration():
  """Require unique explicit constants and bounded command-line inputs."""
  source = "const ImageSize = 64\nconst Repetitions = 1\nconst EmitPixels = 0\nconst ClockId = 6\n"
  # Validate POSIX source substitution even when the tests run on Windows.
  with patch.object(run.time, "CLOCK_MONOTONIC",
                    getattr(run.time, "CLOCK_MONOTONIC", 1), create=True):
    changed = run.configuredSource(source, 4, 3)
    assert changed == ("const ImageSize = 4\nconst Repetitions = 3\n"
                       "const EmitPixels = 1\n"
                       f"const ClockId = {run.time.CLOCK_MONOTONIC}\n")
    assert source.startswith("const ImageSize = 64\n")
    expectError(lambda: run.configuredSource(source + source, 4, 3))
    expectError(lambda: run.configuredSource("const ImageSize = 64\n", 4, 3))
  options = run.parseArguments(["--backend", "c,amd64", "--backend", "c"])
  assert options.backend == ["c", "amd64"]
  assert options.samples == 5 and options.warmups == 1 and options.size == 64
  options = run.parseArguments(["--backend", "c-straight,c", "--backend", "c-straight"])
  assert options.backend == ["c-straight", "c"]
  assert "c-straight" not in run.Backends
  options = run.parseArguments(["--backend", "amd64,hand-c,hand-asm,c-straight,c,arm64,wasm"])
  assert options.backend == list(run.RayBackends)
  assert run.Backends == ("c", "arm64", "amd64", "wasm64")
  for arguments in (["--size", "0"], ["--size", "513"], ["--samples", "4"],
                    ["--warmups", "0"], ["--repeat", "1001"],
                    ["--backend", "unknown"], ["--timeout", "nan"]):
    with redirect_stderr(io.StringIO()):
      expectError(lambda: run.parseArguments(arguments), SystemExit)


def testPng():
  """Decode PNG chunks and verify CRCs and exact lossless RGB scanlines."""
  pixels = bytes(range(12))
  with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "render.png"
    run.writePng(path, 2, pixels)
    data = path.read_bytes()
  assert data[:8] == b"\x89PNG\r\n\x1a\n"
  position = 8
  chunks = {}
  while position < len(data):
    length = struct.unpack(">I", data[position:position + 4])[0]
    kind = data[position + 4:position + 8]
    payload = data[position + 8:position + 8 + length]
    crc = struct.unpack(">I", data[position + 8 + length:position + 12 + length])[0]
    assert zlib.crc32(kind + payload) & 0xffffffff == crc
    chunks[kind] = payload
    position += 12 + length
  assert struct.unpack(">IIBBBBB", chunks[b"IHDR"]) == (2, 2, 8, 2, 0, 0, 0)
  assert zlib.decompress(chunks[b"IDAT"]) == b"\0" + pixels[:6] + b"\0" + pixels[6:]
  assert chunks[b"IEND"] == b""


def testReferences():
  """Reject corrupted or unrecorded independent reference bytes."""
  with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    assert run.loadReference(directory, 1) is None
    pixels = bytes((1, 5, 255))
    (directory / "1.rgb").write_bytes(pixels)
    expectError(lambda: run.loadReference(directory, 1))
    manifest = {"images": {"1": {"file": "1.rgb", "width": 1, "height": 1,
                                "bytes": 3, "checksum": 261,
                                "sha256": hashlib.sha256(pixels).hexdigest()}}}
    (directory / "manifest.json").write_text(json.dumps(manifest))
    assert run.loadReference(directory, 1) == pixels
    (directory / "1.rgb").write_bytes(bytes((2, 4, 255)))
    expectError(lambda: run.loadReference(directory, 1))
    (directory / "1.rgb").unlink()
    expectError(lambda: run.loadReference(directory, 1))


def testArchitectures():
  """Read compiler architecture separately from the Python process CPU."""
  with tempfile.TemporaryDirectory() as temporary:
    path = Path(temporary) / "executable"
    for cpu, architecture in ((0x01000007, "amd64"), (0x0100000c, "arm64")):
      path.write_bytes(b"\xcf\xfa\xed\xfe" + struct.pack("<I", cpu) + bytes(24))
      assert run.binaryArchitectures(path) == [architecture]
    fat = b"\xca\xfe\xba\xbe" + struct.pack(">I", 2)
    for cpu in (0x01000007, 0x0100000c):
      fat += struct.pack(">IIIII", cpu, 0, 0, 0, 0)
    path.write_bytes(fat)
    assert run.binaryArchitectures(path) == ["amd64", "arm64"]
    for machine, architecture in ((62, "amd64"), (183, "arm64")):
      path.write_bytes(b"\x7fELF\x02\x01" + bytes(12) + struct.pack("<H", machine))
      assert run.binaryArchitectures(path) == [architecture]
    path.write_bytes(b"#!/bin/sh\n")
    assert run.binaryArchitectures(path) == []
  host = {"physical_architecture": "arm64"}
  assert "Rosetta translated" in run.backendLabel("c", host, "amd64")
  assert "Rosetta" not in run.backendLabel("c", host, "arm64")
  assert "Hand C" in run.backendLabel("c-straight", host, "arm64")
  assert "Rosetta translated" in run.backendLabel("c-straight", host, "amd64")


def testStraightC():
  """Compile handwritten C directly without a Nifty source or compiler."""
  with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    source = directory / "standalone.c"
    source.write_text("int main(void) { return 0; }\n")
    options = SimpleNamespace(output=directory / "output", straight_c_source=source,
                              source=directory / "missing.nifty", compiler=directory / "missing-nifty",
                              cc="test-cc", timeout=1, emit_ir=True)
    commands = []

    def build(command, timeout, env):
      """Record the actual compilation route and synthesize its artifact."""
      commands.append(command)
      Path(command[command.index("-o") + 1]).write_bytes(b"standalone executable")
      return SimpleNamespace(stdout=b"", stderr=b""), 123

    with patch.object(run, "runCommand", side_effect=build), patch.object(
        run.time, "CLOCK_MONOTONIC", 1, create=True):
      result = run.buildBackend("c-straight", 16, 3, options, {})
    assert len(commands) == 1
    command = commands[0]
    assert command[:1 + len(run.StraightCFlags)] == ["test-cc"] + run.StraightCFlags
    for option in ("-DIMAGE_SIZE=16", "-DREPETITIONS=3", "-DCLOCK_ID=1", "-DEMIT_PIXELS=1", "-lm"):
      assert option in command
    assert "missing-nifty" not in " ".join(command)
    assert Path(result["source"]).read_bytes() == source.read_bytes()
    assert result["compile_wall_ns"] == 123 and result["inspection"] is None


def testNiftySnapshot():
  """Snapshot exact original bytes and configure deterministic UTF-8 output."""
  with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    source = directory / "input.nifty"
    original = (b"const ImageSize = 64\r\nconst Repetitions = 1\r\n"
                b"const EmitPixels = 0\r\nconst ClockId = 6\r\n")
    source.write_bytes(original)
    options = SimpleNamespace(output=directory / "output", source=source,
                              compiler=directory / "nifty", timeout=1, emit_ir=False)

    def build(command, timeout, env):
      """Create only the executable that this command requests."""
      Path(command[command.index("-o") + 1]).write_bytes(b"executable")
      return SimpleNamespace(stdout=b"", stderr=b""), 1

    with patch.object(run, "runCommand", side_effect=build), patch.object(
        run.time, "CLOCK_MONOTONIC", 1, create=True):
      result = run.buildBackend("c", 4, 2, options, {})
    configured = Path(result["source"])
    assert b"\r" not in configured.read_bytes()
    assert b"const ImageSize = 4\n" in configured.read_bytes()
    assert (configured.parent / "raytracer.original.nifty").read_bytes() == original
    assert result["source_snapshots_sha256"]["raytracer.original.nifty"] == hashlib.sha256(original).hexdigest()


def testHandAsm():
  """Preserve ASM inputs and use only the standalone driver and compiler."""
  with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    source = directory / "driver.c"
    source.write_bytes(b"/* driver */\r\n")
    assembly = directory / "input.S"
    assembly.write_bytes(b".text\r\n")
    manifest = directory / "raytracer_manifest.json"
    manifest.write_bytes(b'{"source": "handwritten"}\n')
    options = SimpleNamespace(output=directory / "output", straight_c_source=source,
                              hand_asm_source=assembly, cc="test-cc", timeout=1,
                              emit_ir=True)
    commands = []

    def build(command, timeout, env):
      """Reject stale outputs before synthesizing a successful compilation."""
      executable = Path(command[command.index("-o") + 1])
      assert not executable.exists()
      executable.write_bytes(b"executable")
      commands.append(command)
      return SimpleNamespace(stdout=b"", stderr=b""), 123

    executable = options.output / "build" / "4x4-r2" / "hand-asm" / "raytracer"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"stale")
    with patch.object(run, "runCommand", side_effect=build), patch.object(
        run.time, "CLOCK_MONOTONIC", 1, create=True):
      result = run.buildBackend("hand-asm", 4, 2, options, {})
    assert len(commands) == 1
    assert "-DRAY_HAND_ASM" in commands[0]
    index = commands[0].index("-arch")
    assert commands[0][index + 1] == "arm64"
    assert Path(result["source"]).read_bytes() == source.read_bytes()
    snapshots = result["source_snapshots_sha256"]
    for name, original in (("raytracer_straight.c", source),
                           ("raytracer_hand.S", assembly),
                           ("raytracer_manifest.json", manifest)):
      assert (executable.parent / name).read_bytes() == original.read_bytes()
      assert snapshots[name] == hashlib.sha256(original.read_bytes()).hexdigest()
    assert result["inspection"] is None
  host = {"physical_architecture": "amd64", "system": "Linux"}
  with patch.object(run, "hostInfo", return_value=host), patch.object(
      run.shutil, "which", return_value="cc"), patch.object(
      run.time, "CLOCK_MONOTONIC", 1, create=True):
    expectError(lambda: run.main(["--backend", "hand-asm", "--compiler", "/missing"]))
  assert run.backendLabel("hand-asm", host, "arm64") == "Hand ASM (ARM64)"
  assert run.backendLabel("c", host, "amd64").startswith("Nifty C backend")


testNiftySnapshot()
testHandAsm()
def unsigned(value):
  """Encode unsigned LEB128 fields for focused binary architecture fixtures."""
  result = bytearray()
  while value >= 128:
    result.append((value & 127) | 128)
    value >>= 7
  result.append(value)
  return bytes(result)


def wasmModule(flags=5, minimum=1, maximum=65536, padding=0):
  """Construct the minimal sections needed to inspect a WASM memory ABI."""
  memory = b"\x01" + unsigned(flags) + unsigned(minimum) + unsigned(maximum)
  custom = b"\0" + unsigned(padding) + bytes(padding) if padding else b""
  return b"\0asm\x01\0\0\0" + custom + b"\x05" + unsigned(len(memory)) + memory


def testWasm():
  """Validate memory64 binaries, WASI clocks, command construction, and builds."""
  source = ("const ImageSize = 64\nconst Repetitions = 1\n"
            "const EmitPixels = 0\nconst ClockId = 6\n")
  with patch.object(run.time, "CLOCK_MONOTONIC", 6, create=True):
    for backend in (None, "c", "arm64", "amd64"):
      assert "const ClockId = 6\n" in run.configuredSource(source, 4, 3, backend)
    assert "const ClockId = 1\n" in run.configuredSource(source, 4, 3, "wasm64")
  options = run.parseArguments(["--backend", "wasm,c,wasm64"])
  assert options.backend == ["c", "wasm64"]
  assert run.parseArguments([]).backend == []
  host = {"physical_architecture": "arm64", "rosetta_available": True}
  assert run.executionCommand("arm64", "raytracer", host) == ["raytracer"]
  assert run.executionCommand("amd64", "raytracer", host) == [
    "/usr/bin/arch", "-x86_64", "raytracer"]
  assert run.executionCommand("c", "raytracer", host) == ["raytracer"]
  environment = {"NIFTY_WASMTIME": "/custom/wasmtime", "PATH": "/custom"}
  with patch.object(run.shutil, "which", return_value="/custom/wasmtime") as which:
    assert run.executionCommand("wasm64", "raytracer.wasm", host, environment) == [
      "/custom/wasmtime", "run", "-W", "memory64=y", "raytracer.wasm"]
    which.assert_called_once_with("/custom/wasmtime", path="/custom")
  with patch.object(run.shutil, "which", return_value=None):
    expectError(lambda: run.executionCommand("wasm64", "raytracer.wasm", host))
  assert run.backendLabel("wasm64", host, "wasm64") == "WASM64 (Wasmtime WASI)"
  with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    path = directory / "module.wasm"
    for data in (wasmModule(), wasmModule(padding=5000)):
      path.write_bytes(data)
      assert run.binaryArchitectures(path) == ["wasm64"]
    for data in (wasmModule(flags=1), wasmModule(flags=4),
                 wasmModule(minimum=2, maximum=1), wasmModule()[:-1],
                 b"\0asm\x02\0\0\0", b"\0asm\x01\0\0\0",
                 wasmModule() + b"\x05\x04\x01\x05\x01\x01",
                 b"\0asm\x01\0\0\0\x05\xff\xff\xff\xff\x7f"):
      path.write_bytes(data)
      expectError(lambda: run.binaryArchitectures(path))
    compiler = directory / "nifty"
    compiler.write_bytes(b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x0100000c))
    with patch.object(run.shutil, "which", return_value="/bin/tool"):
      assert run.availableBackends(host, compiler) == ["c", "arm64"]
      assert run.availableBackends(host, compiler, includeWasm=True) == [
        "c", "arm64", "wasm64"]
    sourcePath = directory / "raytracer.nifty"
    sourcePath.write_text(source)
    settings = SimpleNamespace(output=directory / "output", source=sourcePath,
      compiler=compiler, timeout=30, emit_ir=False)
    commands = []

    def compileModule(command, timeout, env):
      """Capture the build command and supply a real memory64 header."""
      commands.append(command)
      Path(command[-1]).write_bytes(wasmModule())
      return SimpleNamespace(stdout=b"", stderr=b""), 10

    with patch.object(run, "runCommand", side_effect=compileModule):
      with patch.object(run.time, "CLOCK_MONOTONIC", 6, create=True):
        built = run.buildBackend("wasm64", 4, 3, settings, environment)
    assert commands == [[str(compiler), "build", built["source"],
                         "--backend:wasm64", "-o", built["executable"]]]
    assert built["executable"].endswith("raytracer.wasm")
    assert "const ClockId = 1\n" in Path(built["source"]).read_text()
    assert "const ClockId = 6\n" in sourcePath.read_text()


testProtocol()
testConfiguration()
testPng()
testReferences()
testArchitectures()
testStraightC()
print("Benchmark protocol, configuration, PNG, reference, architecture, and standalone C checks passed")
testWasm()
print("Benchmark runner protocol, configuration, PNG, reference, architecture, and WASM checks passed")

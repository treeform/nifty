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
  assert options.backend == ["wasm64", "c"]
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
testWasm()
print("Benchmark runner protocol, configuration, PNG, reference, architecture, and WASM checks passed")

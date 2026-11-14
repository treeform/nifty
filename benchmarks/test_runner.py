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


testProtocol()
testConfiguration()
testPng()
testReferences()
testArchitectures()
print("Benchmark runner protocol, configuration, PNG, reference, and architecture checks passed")

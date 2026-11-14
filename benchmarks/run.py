#!/usr/bin/env python3
"""Compile, validate, and measure the Nifty raytracer using only Python's stdlib."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import struct
import subprocess
import sys
import time
import zlib

Backends = ("c", "arm64", "amd64")
RayBackends = ("hand-asm", "c-straight") + Backends
StraightCFlags = ["-O2", "-pthread", "-fno-strict-aliasing", "-ffp-contract=off"]
Root = Path(__file__).resolve().parent.parent


class BenchmarkError(Exception):
  """A benchmark configuration, build, or correctness check failed."""


def runCommand(command, timeout, env=None):
  """Run one bounded command and return output and wall duration."""
  started = time.perf_counter_ns()
  try:
    result = subprocess.run(command, capture_output=True, timeout=timeout,
                            env=env, check=False)
  except (OSError, subprocess.TimeoutExpired) as error:
    raise BenchmarkError(f"Cannot run {command[0]}: {error}") from error
  wallNs = time.perf_counter_ns() - started
  if result.returncode:
    detail = (result.stderr + result.stdout).decode("utf-8", "replace")[-8000:]
    raise BenchmarkError(
      f"Command failed ({result.returncode}): {' '.join(map(str, command))}\n"
      f"{detail.strip()}")
  return result, wallNs


def optionalCommand(command):
  """Read optional machine metadata without requiring another tool."""
  try:
    result, _ = runCommand(command, 10)
    return result.stdout.decode("utf-8", "replace").strip()
  except BenchmarkError:
    return None


def hostInfo():
  """Identify physical architecture and any Rosetta translation."""
  system = platform.system()
  processArch = platform.machine().lower()
  translated = False
  physicalArch = processArch
  if system == "Darwin":
    translated = optionalCommand(
      ["/usr/sbin/sysctl", "-n", "sysctl.proc_translated"]) == "1"
    if optionalCommand(
        ["/usr/sbin/sysctl", "-n", "hw.optional.arm64"]) == "1":
      physicalArch = "arm64"
  if physicalArch in ("aarch64", "arm64"):
    physicalArch = "arm64"
  elif physicalArch in ("x86_64", "amd64"):
    physicalArch = "amd64"
  rosetta = False
  if system == "Darwin" and physicalArch == "arm64":
    rosetta = optionalCommand(
      ["/usr/bin/arch", "-x86_64", "/usr/bin/true"]) is not None
  info = {
    "system": system, "release": platform.release(),
    "version": platform.version(), "process_architecture": processArch,
    "physical_architecture": physicalArch,
    "runner_translated": translated, "rosetta_available": rosetta,
    "python": platform.python_version(),
  }
  if system == "Darwin":
    for key, name in (("cpu", "machdep.cpu.brand_string"),
                      ("model", "hw.model"), ("memory_bytes", "hw.memsize")):
      info[key] = optionalCommand(["/usr/sbin/sysctl", "-n", name])
  else:
    info["cpu"] = platform.processor()
  return info


def binaryArchitectures(path):
  """Read Mach-O or ELF CPU metadata without invoking platform tools."""
  with path.open("rb") as binary:
    header = binary.read(4096)
  cpus = []
  macho = {b"\xcf\xfa\xed\xfe": "<", b"\xce\xfa\xed\xfe": "<",
           b"\xfe\xed\xfa\xcf": ">", b"\xfe\xed\xfa\xce": ">"}
  if header[:4] in macho and len(header) >= 8:
    cpus = [struct.unpack(macho[header[:4]] + "I", header[4:8])[0]]
  elif header[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf") and len(header) >= 8:
    count = struct.unpack(">I", header[4:8])[0]
    stride = 32 if header[:4] == b"\xca\xfe\xba\xbf" else 20
    for index in range(min(count, 64)):
      offset = 8 + index * stride
      if offset + stride > len(header):
        raise BenchmarkError(f"Truncated universal executable header: {path}")
      cpus.append(struct.unpack(">I", header[offset:offset + 4])[0])
  elif header[:4] == b"\x7fELF" and len(header) >= 20:
    byteOrder = {1: "<", 2: ">"}.get(header[5])
    if byteOrder:
      machine = struct.unpack(byteOrder + "H", header[18:20])[0]
      return {62: ["amd64"], 183: ["arm64"]}.get(machine, [])
  return list(dict.fromkeys(
    {0x01000007: "amd64", 0x0100000c: "arm64"}[cpu]
    for cpu in cpus if cpu in (0x01000007, 0x0100000c)))


def availableBackends(host, compiler):
  """List targets executable on this host with available runtime templates."""
  result = []
  if shutil.which("cc"):
    result.append("c")
  arch = host["physical_architecture"]
  compilerArches = binaryArchitectures(compiler)
  for backend in ("arm64", "amd64"):
    template = compiler.parent / f"nifty-runtime-{backend}"
    runtime = os.environ.get(f"NIFTY_RUNTIME_{backend.upper()}")
    runnable = backend == arch or (
      backend == "amd64" and host["rosetta_available"])
    if runnable and (backend in compilerArches or template.is_file() or
                     (runtime and Path(runtime).is_file())):
      result.append(backend)
  return result


def backendLabel(backend, host, architecture):
  """Describe native execution and translated AMD64 results explicitly."""
  if backend == "hand-asm":
    return "Hand ASM (ARM64)"
  if backend == "amd64" and host["physical_architecture"] == "arm64":
    return "AMD64 (Rosetta translated)"
  if backend in ("c", "c-straight"):
    suffix = ", Rosetta translated" if (
      architecture == "amd64" and host["physical_architecture"] == "arm64") else ""
    name = "Hand C" if backend == "c-straight" else "Nifty C backend"
    return f"{name} (-O2, {architecture}{suffix})"
  return f"{backend.upper()} (native)"


def parseOutput(output, size, repeat):
  """Strictly decode one renderer response and independently check its sum."""
  if len(output) > 1024 + size * size * 16 or not output.endswith(b"\n") or b"\r" in output:
    raise BenchmarkError("Renderer output has invalid framing or excessive length")
  try:
    lines = output.decode("ascii").splitlines()
  except UnicodeDecodeError as error:
    raise BenchmarkError("Renderer emitted non-ASCII output") from error
  if not lines or lines[0] != "NIFTY_RAY_V1":
    raise BenchmarkError("Renderer did not emit the NIFTY_RAY_V1 protocol")
  fields = {}
  position = 1
  names = ("size", "repeat", "start_sec", "start_nsec", "end_sec",
           "end_nsec")
  for name in names:
    if position >= len(lines) or not re.fullmatch(
        rf"{name} (0|[1-9][0-9]{{0,18}})", lines[position]):
      raise BenchmarkError(f"Invalid or missing renderer field: {name}")
    fields[name] = int(lines[position].split(" ")[1])
    position += 1
  if fields["size"] != size or fields["repeat"] != repeat:
    raise BenchmarkError("Renderer dimensions or repeat count do not match build")
  if position >= len(lines) or lines[position] != "clock_status 0 0":
    raise BenchmarkError("Renderer monotonic clock call failed or is missing")
  position += 1
  if position >= len(lines) or not re.fullmatch(
      r"checksum (0|[1-9][0-9]{0,18})", lines[position]):
    raise BenchmarkError("Invalid or missing renderer checksum")
  fields["checksum"] = int(lines[position].split(" ")[1])
  position += 1
  if fields["start_nsec"] >= 1_000_000_000 or \
      fields["end_nsec"] >= 1_000_000_000:
    raise BenchmarkError("Invalid monotonic nanosecond field")
  elapsedNs = ((fields["end_sec"] - fields["start_sec"]) * 1_000_000_000 +
               fields["end_nsec"] - fields["start_nsec"])
  if elapsedNs <= 0:
    raise BenchmarkError("Renderer monotonic clock did not advance")
  if position >= len(lines) or not re.fullmatch(
      r"batch_checksum (0|[1-9][0-9]{0,18})", lines[position]):
    raise BenchmarkError("Invalid or missing renderer batch checksum")
  fields["batch_checksum"] = int(lines[position].split(" ")[1])
  position += 1
  if fields["batch_checksum"] != repeat * fields["checksum"]:
    raise BenchmarkError("Renderer batch checksum does not match repeated frames")
  if len(lines) != position + size * size:
    raise BenchmarkError(f"Expected exactly {size * size} RGB pixel lines")
  pixels = bytearray()
  for line in lines[position:]:
    if not re.fullmatch(r"rgb (0|[1-9][0-9]{0,2}) (0|[1-9][0-9]{0,2}) (0|[1-9][0-9]{0,2})", line):
      raise BenchmarkError("Invalid RGB pixel line")
    channels = [int(value) for value in line.split(" ")[1:]]
    if any(value > 255 for value in channels):
      raise BenchmarkError("RGB channel is outside 0..255")
    pixels.extend(channels)
  if sum(pixels) != fields["checksum"]:
    raise BenchmarkError("Renderer checksum does not match its RGB pixels")
  return {"elapsed_ns": elapsedNs, "checksum": fields["checksum"],
          "pixels": bytes(pixels), "clock_fields": fields}


def configuredSource(source, size, repeat):
  """Substitute only exact configuration constants in a generated copy."""
  for name, value in (("ImageSize", size), ("Repetitions", repeat),
                      ("EmitPixels", 1), ("ClockId", time.CLOCK_MONOTONIC)):
    pattern = rf"(?m)^(const {name} = )[0-9]+$"
    source, count = re.subn(pattern, lambda match: match[1] + str(value), source)
    if count != 1:
      raise BenchmarkError(f"Expected exactly one source constant: {name}")
  return source


def writePng(path, size, pixels):
  """Write lossless RGB PNG bytes with Python's standard library."""
  def chunk(name, data):
    """Encode one PNG chunk and its CRC."""
    return (struct.pack(">I", len(data)) + name + data +
            struct.pack(">I", zlib.crc32(name + data) & 0xffffffff))
  rows = b"".join(b"\0" + pixels[row * size * 3:(row + 1) * size * 3]
                  for row in range(size))
  header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
  path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
                   chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def summarize(values):
  """Summarize one set of measured durations without hiding raw samples."""
  return {"median": statistics.median(values), "min": min(values),
          "max": max(values), "samples": values}


def buildBackend(backend, size, repeat, options, env):
  """Build once per backend and configuration, preserving all artifacts."""
  directory = options.output / "build" / f"{size}x{size}-r{repeat}" / backend
  directory.mkdir(parents=True, exist_ok=True)
  executable = directory / "raytracer"
  executable.unlink(missing_ok=True)
  snapshots = {}
  if backend in ("c-straight", "hand-asm"):
    sourcePath = directory / "raytracer_straight.c"
    sourcePath.write_bytes(options.straight_c_source.read_bytes())
    snapshots[sourcePath.name] = hashlib.sha256(sourcePath.read_bytes()).hexdigest()
    command = [options.cc] + StraightCFlags + [
      f"-DIMAGE_SIZE={size}", f"-DREPETITIONS={repeat}",
      f"-DCLOCK_ID={time.CLOCK_MONOTONIC}", "-DEMIT_PIXELS=1",
      "-o", str(executable), str(sourcePath), "-lm"]
    if backend == "hand-asm":
      assemblyPath = directory / "raytracer_hand.S"
      assemblyPath.write_bytes(options.hand_asm_source.read_bytes())
      snapshots[assemblyPath.name] = hashlib.sha256(assemblyPath.read_bytes()).hexdigest()
      command += ["-DRAY_HAND_ASM", "-arch", "arm64", str(assemblyPath)]
      manifestPath = options.hand_asm_source.with_name("raytracer_manifest.json")
      if manifestPath.is_file():
        manifestCopy = directory / manifestPath.name
        manifestCopy.write_bytes(manifestPath.read_bytes())
        snapshots[manifestCopy.name] = hashlib.sha256(manifestCopy.read_bytes()).hexdigest()
  else:
    sourcePath = directory / "raytracer.nifty"
    originalPath = directory / "raytracer.original.nifty"
    originalPath.write_bytes(options.source.read_bytes())
    snapshots[originalPath.name] = hashlib.sha256(originalPath.read_bytes()).hexdigest()
    sourcePath.write_bytes(configuredSource(
      originalPath.read_bytes().decode("utf-8").replace("\r\n", "\n"),
      size, repeat).encode("utf-8"))
    command = [str(options.compiler), "build", str(sourcePath),
               f"--backend:{backend}", "-o", str(executable)]
  result, compileNs = runCommand(command, options.timeout, env)
  (directory / "build.stdout").write_bytes(result.stdout)
  (directory / "build.stderr").write_bytes(result.stderr)
  inspection = None
  if options.emit_ir and backend not in ("c", "c-straight", "hand-asm"):
    irPath = directory / "raytracer.ir"
    inspectCommand = [str(options.compiler), str(sourcePath),
                      f"--backend:{backend}", "--emit-ir", "-o", str(irPath)]
    _, inspectNs = runCommand(inspectCommand, options.timeout, env)
    inspection = {"path": str(irPath), "wall_ns": inspectNs}
  return {"backend": backend, "executable": str(executable),
          "source": str(sourcePath), "source_snapshots_sha256": snapshots,
          "compile_wall_ns": compileNs,
          "source_sha256": hashlib.sha256(sourcePath.read_bytes()).hexdigest(),
          "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
          "compile_command": command, "inspection": inspection,
          "render_ns_per_frame": [], "process_wall_ns": [],
          "clock_fields": [], "warmup_checksums": []}


def loadReference(directory, size):
  """Verify independent reference bytes against their provenance manifest."""
  path = directory / f"{size}.rgb"
  manifestPath = directory / "manifest.json"
  manifest = json.loads(manifestPath.read_text()) if manifestPath.is_file() else None
  entry = manifest.get("images", {}).get(str(size)) if manifest else None
  if not path.is_file():
    if entry:
      raise BenchmarkError(f"Independent reference is missing: {path}")
    return None
  if not entry:
    raise BenchmarkError(f"Reference lacks provenance manifest entry: {path}")
  pixels = path.read_bytes()
  expected = {"file": path.name, "width": size, "height": size,
              "bytes": size * size * 3, "checksum": sum(pixels),
              "sha256": hashlib.sha256(pixels).hexdigest()}
  if len(pixels) != size * size * 3 or any(
      entry.get(key) != value for key, value in expected.items()):
    raise BenchmarkError(f"Independent reference failed manifest validation: {path}")
  return pixels


def benchmark(size, repeat, options, backends, host, env):
  """Validate every response before retaining comparable render samples."""
  referencePath = Root / "benchmarks" / "reference" / f"{size}.rgb"
  golden = loadReference(referencePath.parent, size)
  expected = golden
  results = {backend: buildBackend(backend, size, repeat, options, env)
             for backend in backends}
  for backend, result in results.items():
    architectures = binaryArchitectures(Path(result["executable"]))
    if len(architectures) != 1 or (
        backend in ("arm64", "amd64", "hand-asm") and
        architectures != ["arm64" if backend == "hand-asm" else backend]):
      raise BenchmarkError(f"Wrong executable architecture for {backend}: {architectures}")
    architecture = architectures[0]
    result["execution_architecture"] = architecture
    result["label"] = backendLabel(backend, host, architecture)
    command = [result["executable"]]
    if architecture == "amd64" and host["physical_architecture"] == "arm64":
      command = ["/usr/bin/arch", "-x86_64"] + command
    result["execution_command"] = command
  rounds = []
  for roundIndex in range(options.warmups + options.samples):
    offset = roundIndex % len(backends)
    order = backends[offset:] + backends[:offset]
    rounds.append(order)
    for backend in order:
      result = results[backend]
      response, wallNs = runCommand(result["execution_command"], options.timeout, env)
      parsed = parseOutput(response.stdout, size, repeat)
      if response.stderr:
        raise BenchmarkError(f"Unexpected renderer stderr ({backend}): " +
                             response.stderr.decode("utf-8", "replace")[:2000])
      pixels = parsed["pixels"]
      if expected is None:
        expected = pixels
      if pixels != expected:
        kind = "independent golden" if golden is not None else "other backends"
        raise BenchmarkError(
          f"RGB correctness mismatch: {backend} at size {size}, "
          f"round {roundIndex + 1}, compared with {kind}")
      if roundIndex < options.warmups:
        result["warmup_checksums"].append(parsed["checksum"])
      else:
        result["render_ns_per_frame"].append(parsed["elapsed_ns"] / repeat)
        result["process_wall_ns"].append(wallNs)
        result["clock_fields"].append(parsed["clock_fields"])
  for backend, result in results.items():
    result["render_ns_per_frame"] = summarize(result["render_ns_per_frame"])
    result["process_wall_ns"] = summarize(result["process_wall_ns"])
    result["checksum"] = sum(expected)
    result["pixel_sha256"] = hashlib.sha256(expected).hexdigest()
  return {"size": size, "repeat": repeat, "round_order": rounds,
          "independent_golden": str(referencePath) if golden is not None else None,
          "correctness": "independent golden and exact cross-run RGB" if golden
                         is not None else "exact cross-run RGB; no independent golden",
          "backends": list(results.values())}, expected


def parseArguments(arguments=None):
  """Validate bounded configuration before invoking any compiler."""
  parser = argparse.ArgumentParser(description=__doc__,
      epilog="Standalone C baseline details: benchmarks/C_STRAIGHT.md")
  parser.add_argument("--backend", action="append", default=[],
                      help="Repeat or use comma-separated hand-asm,hand-c,c,arm64,amd64 (c-straight aliases hand-c)")
  parser.add_argument("--size", type=int, default=64)
  parser.add_argument("--samples", type=int, default=5)
  parser.add_argument("--warmups", type=int, default=1)
  parser.add_argument("--repeat", type=int, default=1,
                      help="Frames rendered per timed process invocation")
  parser.add_argument("--output", type=Path, default=Root / "benchmarks" / "output")
  parser.add_argument("--compiler", type=Path, default=Root / "nifty")
  parser.add_argument("--source", type=Path,
                      default=Root / "benchmarks" / "raytracer.nifty")
  parser.add_argument("--hand-c-source", "--straight-c-source", dest="straight_c_source", type=Path,
                      default=Root / "benchmarks" / "raytracer_straight.c")
  parser.add_argument("--hand-asm-source", type=Path,
                      default=Root / "benchmarks" / "arm64" / "raytracer_hand.S")
  parser.add_argument("--cc", default=os.environ.get("CC", "cc"),
                      help="C compiler for standalone and Nifty-generated C")
  parser.add_argument("--timeout", type=float, default=300,
                      help="Seconds allowed for each build or process")
  parser.add_argument("--emit-ir", action="store_true",
                      help="Preserve native IR through separate untimed compiler calls")
  parser.add_argument("--wall", action="store_true",
                      help="Also display whole-process wall duration")
  parser.add_argument("--check", action="store_true",
                      help="Additionally validate independent goldens at sizes 4 and 16")
  options = parser.parse_args(arguments)
  for name, low, high in (("size", 1, 512), ("samples", 5, 1000),
                          ("warmups", 1, 1000), ("repeat", 1, 1000)):
    if not low <= getattr(options, name) <= high:
      parser.error(f"--{name} must be in {low}..{high}")
  if not 0 < options.timeout <= 3600:
    parser.error("--timeout must be greater than zero and at most 3600")
  selected = []
  for entry in options.backend:
    for backend in entry.split(","):
      backend = "c-straight" if backend == "hand-c" else backend
      if backend not in RayBackends:
        parser.error(f"unknown backend: {backend}")
      if backend not in selected:
        selected.append(backend)
  options.backend = [backend for backend in RayBackends if backend in selected]
  for name in ("compiler", "source", "straight_c_source", "hand_asm_source", "output"):
    setattr(options, name, getattr(options, name).expanduser().resolve())
  return options


def markdownReport(report, wall):
  """Format validated results and state the scope of timing explicitly."""
  benchmarkResult = report["benchmark"]
  lines = [f"Nifty raytracer: {benchmarkResult['size']} x {benchmarkResult['size']}",
           "", f"Correctness: {benchmarkResult['correctness']}.", "",
           "Render times use the renderer's monotonic clock and exclude startup, "
           "final checksum, RGB formatting, and PNG writing. Values are per frame. "
           "Each timed frame includes an RGB checksum reduction to keep every "
           "repetition observable. Each sample starts a fresh process; first-use "
           "execution and translation within the loop remain timed.", "",
           "| Backend | Compile (ms) | Render median (ms) | Min (ms) | Max (ms) |",
           "| --- | ---: | ---: | ---: | ---: |"]
  for result in benchmarkResult["backends"]:
    times = result["render_ns_per_frame"]
    lines.append(f"| {result['label']} | {result['compile_wall_ns'] / 1e6:.3f} | "
                 f"{times['median'] / 1e6:.3f} | {times['min'] / 1e6:.3f} | "
                 f"{times['max'] / 1e6:.3f} |")
  if wall:
    lines += ["", "Whole-process wall medians include runtime loading and RGB output:"]
    for result in benchmarkResult["backends"]:
      lines.append(f"- {result['label']}: "
                   f"{result['process_wall_ns']['median'] / 1e6:.3f} ms")
  lines += ["", f"RGB SHA-256: `{benchmarkResult['backends'][0]['pixel_sha256']}`",
            "", f"PNG: {report['image']}", ""]
  return "\n".join(lines)


def main(arguments=None):
  """Publish timing artifacts only after every correctness check succeeds."""
  options = parseArguments(arguments)
  host = hostInfo()
  if host["system"] not in ("Darwin", "Linux") or getattr(time, "CLOCK_MONOTONIC", None) is None:
    raise BenchmarkError("Ray timing requires POSIX clock_gettime on macOS or Linux")
  options.cc = shutil.which(options.cc)
  handAsmSupported = (host["system"] == "Darwin" and
                      host["physical_architecture"] == "arm64" and options.cc)
  if "hand-asm" in options.backend and not handAsmSupported:
    raise BenchmarkError("Hand ASM requires macOS on physical ARM64 and a C compiler")
  needsNifty = not options.backend or any(
    backend in Backends for backend in options.backend)
  if needsNifty:
    if not options.compiler.is_file() or not os.access(options.compiler, os.X_OK):
      raise BenchmarkError(f"Compiler is not executable: {options.compiler}")
    if not options.source.is_file():
      raise BenchmarkError(f"Renderer source does not exist: {options.source}")
  available = availableBackends(host, options.compiler) if needsNifty else []
  if options.cc:
    available.insert(0, "c-straight")
    if handAsmSupported:
      available.insert(0, "hand-asm")
    if needsNifty and "c" not in available:
      available.append("c")
  else:
    available = [backend for backend in available if backend != "c"]
  backends = options.backend or [backend for backend in RayBackends if backend in available]
  if not backends:
    raise BenchmarkError("No executable backend is available on this host")
  for backend in backends:
    if backend not in available:
      raise BenchmarkError(f"Backend {backend} is unsupported on this host or its "
                           "runtime template is unavailable; available: " +
                           ", ".join(available))
  standalone = any(backend in ("hand-asm", "c-straight") for backend in backends)
  if standalone and not options.straight_c_source.is_file():
    raise BenchmarkError(f"Standalone C source does not exist: {options.straight_c_source}")
  inputs = ([options.compiler, options.source] if needsNifty else [])
  if standalone:
    inputs.append(options.straight_c_source)
  if "hand-asm" in backends:
    if not options.hand_asm_source.is_file():
      raise BenchmarkError(f"Hand ASM source does not exist: {options.hand_asm_source}")
    inputs.append(options.hand_asm_source)
    assemblyManifest = options.hand_asm_source.with_name("raytracer_manifest.json")
    if assemblyManifest.is_file():
      inputs.append(assemblyManifest)
  if options.cc and any(backend in ("c", "c-straight", "hand-asm") for backend in backends):
    inputs.append(Path(options.cc))
  fingerprints = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
  options.output.mkdir(parents=True, exist_ok=True)
  for name in ("results.json", "results.md", "raytracer.png"):
    (options.output / name).unlink(missing_ok=True)
  env = os.environ.copy()
  if options.cc:
    env["CC"] = options.cc
  for backend in ("arm64", "amd64"):
    template = options.compiler.parent / f"nifty-runtime-{backend}"
    if template.is_file():
      env.setdefault(f"NIFTY_RUNTIME_{backend.upper()}", str(template))
  checks = []
  if options.check:
    for size in (4, 16):
      if not (Root / "benchmarks" / "reference" / f"{size}.rgb").is_file():
        raise BenchmarkError(f"--check requires independent golden {size}.rgb")
      if size != options.size:
        checked, _ = benchmark(size, 1, options, backends, host, env)
        checks.append(checked)
  result, pixels = benchmark(options.size, options.repeat, options, backends,
                             host, env)
  if any(hashlib.sha256(path.read_bytes()).hexdigest() != value
         for path, value in fingerprints.items()):
    raise BenchmarkError("Compiler or renderer source changed during benchmark")
  imagePath = options.output / "raytracer.png"
  writePng(imagePath, options.size, pixels)
  manifest = Root / "benchmarks" / "reference" / "manifest.json"
  provenance = Root / "benchmarks" / "reference" / "c_straight.json"
  report = {
    "schema": "nifty-ray-benchmark-v1", "machine": host,
    "toolchain": {"compiler": str(options.compiler) if needsNifty else None,
                  "compiler_architectures": binaryArchitectures(options.compiler) if needsNifty else [],
                  "compiler_sha256": fingerprints.get(options.compiler),
                  "compiler_help": optionalCommand([str(options.compiler), "--help"]) if needsNifty else None,
                  "cc": optionalCommand([options.cc, "--version"]) if options.cc else None,
                  "cc_path": options.cc,
                  "straight_c_flags": StraightCFlags if standalone else None,
                  "hand_asm_flags": StraightCFlags + ["-DRAY_HAND_ASM", "-arch", "arm64"] if "hand-asm" in backends else None,
                  "nim": optionalCommand(["nim", "--version"])},
    "settings": {"size": options.size, "samples": options.samples,
                 "warmups": options.warmups, "repeat": options.repeat,
                 "backends": backends, "timeout_seconds": options.timeout,
                 "source": str(options.source) if needsNifty else None,
                 "source_sha256": fingerprints.get(options.source),
                 "straight_c_source": str(options.straight_c_source) if standalone else None,
                 "hand_asm_source": str(options.hand_asm_source) if "hand-asm" in backends else None,
                 "sample_order": "rotate backend order each warmup/sample round",
                 "native_ir": options.emit_ir},
    "reference_manifest": json.loads(manifest.read_text()) if manifest.is_file() else None,
    "inputs_sha256": {str(path): value for path, value in fingerprints.items()},
    "straight_c_provenance": json.loads(provenance.read_text())
        if "c-straight" in backends and provenance.is_file() and
        options.straight_c_source == Root / "benchmarks" / "raytracer_straight.c" else None,
    "checks": checks, "benchmark": result, "image": str(imagePath),
  }
  markdown = markdownReport(report, options.wall)
  (options.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
  (options.output / "results.md").write_text(markdown)
  print(markdown)
  return 0


if __name__ == "__main__":
  try:
    sys.exit(main())
  except (BenchmarkError, OSError, ValueError) as error:
    print(f"Benchmark failed: {error}", file=sys.stderr)
    sys.exit(1)

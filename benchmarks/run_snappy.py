#!/usr/bin/env python3
"""Compile once, independently validate, and measure raw Snappy codecs."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time

Root = Path(__file__).resolve().parent.parent

def load(name, path):
  """Load an existing benchmark helper without modifying module paths."""
  spec = importlib.util.spec_from_file_location(name, path)
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  return module

Ray = load("ray_benchmark", Root / "benchmarks/run.py")
BenchmarkError = Ray.BenchmarkError
LibraryNames = ("snappy.nifty", "snappytypes.nifty", "snappycompress.nifty", "snappydecompress.nifty")
StandaloneBackends = ("hand-asm", "c-straight")
Backends = StandaloneBackends + Ray.Backends
Kinds = ("repetitive", "mixed", "random")
TimingScope = ("Compression and decompression calls are timed separately with monotonic clocks. "
               "Input generation, hex output, checksums and exact roundtrip comparisons are untimed. "
               "Each process prewarms both output buffers and reuses their capacities; any codec "
               "internal allocation remains timed. Clock-call overhead remains included. "
               "Every sample is a fresh process. Snappy timing sums compression and decompression "
               "within each iteration, averages those sums per process, then reports their median. "
               "MiB/s uses uncompressed input bytes once per roundtrip.")


def digest(data):
  """Compute the bounded byte hash used for untimed iteration validation."""
  value = 0
  for byte in data:
    value = (value * 257 + byte) % 1000000007
  return value


def expectedWorkloads(size):
  """Generate deterministic byte fixtures independently of Nifty execution."""
  text = b"The quick brown fox jumps over the lazy dog.\n"
  random = bytearray()
  state = 1
  for index in range(size):
    state = state * 48271 % 2147483647
    random.append(state % 256)
  data = [bytes(text[index % len(text)] for index in range(size)),
          bytes(65 + index % 7 if index % 97 < 70 else
                32 + (index // 97 + index % 13) % 95 for index in range(size)),
          bytes(random)]
  return [{"kind": kind, "input": value, "input_bytes": size,
           "checksum": digest(value), "input_sha256": hashlib.sha256(value).hexdigest()}
          for kind, value in zip(Kinds, data)]


def parseOutput(output, size, repeat, expected):
  """Validate strict framing, independent decoding, and every operation clock."""
  if len(output) > 12 * size + 2048 + repeat * 1200 or not output.endswith(b"\n") or b"\r" in output:
    raise BenchmarkError("Invalid Snappy output framing or excessive length")
  try:
    lines = output.decode("ascii").splitlines()
  except UnicodeDecodeError as error:
    raise BenchmarkError("Non-ASCII Snappy protocol") from error
  if len(lines) != 3 * (5 + repeat):
    raise BenchmarkError("Incomplete Snappy protocol")
  oracle = load("snappy_reference", Root / "tests/snappy_reference.py")
  parsed = []
  for kind, fixture in enumerate(expected):
    block = lines[kind * (5 + repeat):(kind + 1) * (5 + repeat)]
    if block[:4] != ["NIFTY_SNAPPY_V1", f"kind {kind}", f"size {size}", f"repeat {repeat}"]:
      raise BenchmarkError("Snappy workload header mismatch")
    match = re.fullmatch(r"compressed_hex ((?:[0-9a-f]{2})+)", block[4])
    if not match:
      raise BenchmarkError("Invalid compressed hex")
    compressed = bytes.fromhex(match[1])
    try:
      decoded = oracle.decode(compressed, maxOutput=size)
    except (ValueError, IndexError) as error:
      raise BenchmarkError("Independent Snappy decode failed") from error
    if decoded != fixture["input"]:
      raise BenchmarkError("Independent Snappy payload mismatch")
    compressedChecksum = digest(compressed)
    samples = []
    for index, line in enumerate(block[5:]):
      if not re.fullmatch(r"iteration (?:0|[1-9][0-9]{0,18})(?: (?:0|[1-9][0-9]{0,18})){15}", line):
        raise BenchmarkError("Malformed Snappy iteration")
      values = list(map(int, line.split()[1:]))
      if values[0] != index or values[9:13] != [0] * 4:
        raise BenchmarkError("Snappy iteration or clock failure")
      if values[13:] != [len(compressed), compressedChecksum, fixture["checksum"]]:
        raise BenchmarkError("Snappy iteration checksum or length mismatch")
      elapsed = []
      for offset in (1, 5):
        start, startNs, end, endNs = values[offset:offset + 4]
        duration = (end - start) * 1000000000 + endNs - startNs
        if startNs >= 1000000000 or endNs >= 1000000000 or duration <= 0:
          raise BenchmarkError("Invalid Snappy monotonic interval")
        elapsed.append(duration)
      samples.append({"compress_ns": elapsed[0], "decompress_ns": elapsed[1],
                      "roundtrip_ns": sum(elapsed),
                      "clock_fields": values[1:13], "compressed_bytes": values[13],
                      "compressed_checksum": values[14], "decoded_checksum": values[15]})
    parsed.append({"kind": fixture["kind"], "compressed_bytes": len(compressed),
                   "compressed_sha256": hashlib.sha256(compressed).hexdigest(), "iterations": samples})
  return parsed


def configuredSource(source, size, repeat, backend=None):
  """Substitute exactly one occurrence of each build configuration constant."""
  for name, value in (("Size", size), ("Repetitions", repeat), ("ClockId", 1 if backend == "wasm64" else time.CLOCK_MONOTONIC)):
    source, count = re.subn(rf"(?m)^(const {name} = )[0-9]+$", lambda match: match[1] + str(value), source)
    if count != 1:
      raise BenchmarkError(f"Expected unique constant {name}")
  source, count = re.subn(r'(?m)^import "\.\./lib/snappy"$', 'import "lib/snappy"', source)
  if count != 1:
    raise BenchmarkError("Expected unique Snappy import")
  return source


def buildBackend(backend, options, env):
  """Compile deterministic source snapshots once and preserve diagnostics."""
  directory = options.output / "build" / f"n{options.size}-r{options.repeat}" / backend
  directory.mkdir(parents=True, exist_ok=True)
  executable = directory / ("snappy.wasm" if backend == "wasm64" else "snappy")
  executable.unlink(missing_ok=True)
  assembly = None
  provenance = None
  if backend in StandaloneBackends:
    source = directory / "snappy_straight.c"
    source.write_bytes(options.straight_c_bytes)
    flags = Ray.StraightCFlags.copy()
    if backend == "hand-asm":
      flags += ["-arch", "arm64", "-DSNAPPY_HAND_ASM"]
      assembly = directory / "snappy_hand.S"
      assembly.write_bytes(options.hand_asm_bytes)
      provenance = directory / "snappy_manifest.json"
      provenance.write_bytes(options.hand_asm_manifest_bytes)
    command = [options.cc] + flags + [
      f"-DSNAPPY_SIZE={options.size}",
      f"-DSNAPPY_REPETITIONS={options.repeat}",
      f"-DSNAPPY_CLOCK_ID={time.CLOCK_MONOTONIC}", str(source)]
    if assembly is not None:
      command.append(str(assembly))
    command += ["-o", str(executable)]
  else:
    (directory / "lib").mkdir(parents=True, exist_ok=True)
    for name, data in options.library_files.items():
      (directory / "lib" / name).write_bytes(data)
    source = directory / "snappy.nifty"
    source.write_bytes(configuredSource(options.source_text, options.size, options.repeat, backend).encode("utf-8"))
    if backend == "interp":
      return Ray.interpreterResult(source, options.compiler, options.host, env,
                                   options.opt)
    command = [str(options.compiler), "build", str(source), f"--backend:{backend}", f"--opt:{options.opt}", "-o", str(executable)]
  response, elapsed = Ray.runCommand(command, options.timeout, env)
  (directory / "build.stdout").write_bytes(response.stdout)
  (directory / "build.stderr").write_bytes(response.stderr)
  architectures = Ray.binaryArchitectures(executable)
  if len(architectures) != 1 or (backend in ("arm64", "amd64", "wasm64", "hand-asm") and
      architectures != ["arm64" if backend == "hand-asm" else backend]):
    raise BenchmarkError("Unexpected Snappy executable architecture")
  if (backend == "wasm64") != (architectures == ["wasm64"]):
    raise BenchmarkError(f"Wrong module ABI for {backend}: {architectures}")
  execution = Ray.executionCommand(architectures[0], executable, options.host, env)
  return {"backend": backend, "label": Ray.backendLabel(backend, options.host, architectures[0]),
          "assembly_sha256": hashlib.sha256(assembly.read_bytes()).hexdigest() if assembly else None,
          "provenance_sha256": hashlib.sha256(provenance.read_bytes()).hexdigest() if provenance else None,
          "source": str(source), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
          "executable": str(executable), "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
          "execution_architecture": architectures[0], "compile_command": command,
          "compile_wall_ns": elapsed, "execution_command": execution,
          "raw_samples": [], "warmups": [], "process_wall_ns": []}


def benchmark(options, backends, host, env):
  """Rotate fresh process samples after compiling each backend exactly once."""
  options.host = host
  expected = expectedWorkloads(options.size)
  results = [buildBackend(backend, options, env) for backend in backends]
  orders = []
  compressedIdentity = {}
  for index in range(options.warmups + options.samples):
    offset = index % len(results)
    ordered = results[offset:] + results[:offset]
    orders.append([result["backend"] for result in ordered])
    for result in ordered:
      response, wall = Ray.runCommand(result["execution_command"], options.timeout, env)
      if response.stderr:
        raise BenchmarkError("Unexpected Snappy stderr: " + response.stderr.decode("utf-8", "replace")[:2000])
      parsed = parseOutput(response.stdout, options.size, options.repeat, expected)
      for workload in parsed:
        identity = (workload["compressed_bytes"], workload["compressed_sha256"])
        previous = compressedIdentity.setdefault(workload["kind"], identity)
        if identity != previous:
          raise BenchmarkError("Compressed bytes differ across samples or backends")
      sample = {"workloads": parsed, "process_wall_ns": wall}
      result["warmups" if index < options.warmups else "raw_samples"].append(sample)
      if index >= options.warmups:
        result["process_wall_ns"].append(wall)
  for result in results:
    result["process_wall_ns"] = Ray.summarize(result["process_wall_ns"])
    result["workloads"] = []
    for kind, fixture in enumerate(expected):
      summary = {key: value for key, value in fixture.items() if key != "input"}
      summary["compressed_bytes"] = result["raw_samples"][0]["workloads"][kind]["compressed_bytes"]
      for operation in ("compress", "decompress", "roundtrip"):
        values = [sum(row[operation + "_ns"] for row in sample["workloads"][kind]["iterations"]) / options.repeat for sample in result["raw_samples"]]
        summary[operation + "_ns"] = Ray.summarize(values)
        summary[operation + "_mib_per_second"] = options.size * 1e9 / 1048576 / summary[operation + "_ns"]["median"]
      result["workloads"].append(summary)
  for fixture in expected:
    (options.output / (fixture["kind"] + ".bin")).write_bytes(fixture["input"])
  return {"sample_order": orders, "backends": results,
          "correctness": "Every baseline decoded independently in Python; every timed roundtrip compared byte for byte by each codec; every iteration checksum and length validated in Python"}


def parseArguments(arguments=None):
  """Bound workload parameters and reject unsupported backend selections."""
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--backend", action="append", default=[])
  for name, default in (("size", 262144), ("repeat", 10), ("samples", 5), ("warmups", 1)):
    parser.add_argument("--" + name, type=int, default=default)
  parser.add_argument("--opt", choices=("none", "speed"), default="speed")
  parser.add_argument("--compiler", type=Path, default=Root / "nifty")
  parser.add_argument("--source", type=Path, default=Root / "benchmarks/snappy.nifty")
  parser.add_argument("--hand-c-source", "--straight-c-source", dest="straight_c_source", type=Path, default=Root / "benchmarks/snappy_straight.c")
  parser.add_argument("--hand-asm-source", type=Path, default=Root / "benchmarks/arm64/snappy_hand.S")
  parser.add_argument("--output", type=Path, default=Root / "benchmarks/output/snappy")
  parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
  parser.add_argument("--timeout", type=float, default=300)
  parser.add_argument("--wall", action="store_true")
  options = parser.parse_args(arguments)
  for name, low, high in (("size", 1, 4194304), ("repeat", 1, 1000), ("samples", 5, 1000), ("warmups", 1, 1000)):
    if not low <= getattr(options, name) <= high:
      parser.error(f"--{name} must be in {low}..{high}")
  if not 0 < options.timeout <= 3600:
    parser.error("Invalid timeout")
  selected = []
  for entry in options.backend:
    for backend in entry.split(","):
      backend = "c-straight" if backend == "hand-c" else backend
      backend = {"wasm": "wasm64", "interpret": "interp", "interpreter": "interp"}.get(backend, backend)
      if backend not in Backends:
        parser.error(f"Unknown backend: {backend}")
      if backend not in selected:
        selected.append(backend)
  options.backend = [backend for backend in Backends if backend in selected]
  for name in ("compiler", "source", "straight_c_source", "hand_asm_source", "output"):
    setattr(options, name, getattr(options, name).expanduser().resolve())
  return options


def markdownReport(report, wall=False):
  """Present paired roundtrip timing and explicit timing boundaries."""
  settings = report["settings"]
  lines = [f"Nifty raw Snappy benchmark: {settings['size']} bytes per workload, {settings['repeat']} repetitions, {settings['samples']} samples, {settings['warmups']} warmups.", "", f"Native optimization: {settings['opt']}. C uses -O2.", "", TimingScope, "", report["benchmark"]["correctness"] + ".", "",
           "| Backend | Compile ms | Workload | Compressed bytes | Snappy ms | Snappy MiB/s |",
           "| --- | ---: | --- | ---: | ---: | ---: |"]
  for backend in report["benchmark"]["backends"]:
    for workload in backend["workloads"]:
      lines.append(f"| {backend['label']} | {Ray.compileMilliseconds(backend['compile_wall_ns'])} | {workload['kind']} | {workload['compressed_bytes']} | {workload['roundtrip_ns']['median']/1e6:.3f} | {workload['roundtrip_mib_per_second']:.3f} |")
  if wall:
    lines += ["", "Whole-process wall medians include input generation, validation and output:"]
    for backend in report["benchmark"]["backends"]:
      lines += [f"- {backend['label']}: {backend['process_wall_ns']['median']/1e6:.3f} ms."]
  if any(backend["backend"] == "interp" for backend in report["benchmark"]["backends"]):
    lines += ["", "Interpreter compilation is N/A: source snapshots are prepared outside processes; parsing and optimization precede guest timers in each fresh process."]
  return "\n".join(lines) + "\n"


def handAsmSupported(host):
  """Restrict frozen Mach-O assembly to physical Apple ARM64 hosts."""
  return host["system"] == "Darwin" and host.get("physical_architecture") == "arm64"


def availableBackends(host, compiler, cc, needsNifty=True):
  """Discover standalone backends without requiring a Nifty compiler."""
  available = list(Ray.availableBackends(host, compiler, includeWasm=True)) if needsNifty else []
  if cc:
    available += ["c-straight"]
    if needsNifty and "c" not in available:
      available.append("c")
    if handAsmSupported(host):
      available += ["hand-asm"]
  else:
    available = [backend for backend in available if backend != "c"]
  return [backend for backend in Backends if backend in available]


def main(arguments=None):
  """Publish results only after validation and stable toolchain checks."""
  options = parseArguments(arguments)
  options.output.mkdir(parents=True, exist_ok=True)
  for name in ("results.json", "results.md"):
    (options.output / name).unlink(missing_ok=True)
  host = Ray.hostInfo()
  if host["system"] not in ("Darwin", "Linux") or getattr(time, "CLOCK_MONOTONIC", None) is None:
    raise BenchmarkError("Snappy timing requires POSIX clock_gettime")
  if "hand-asm" in options.backend and not handAsmSupported(host):
    raise BenchmarkError("Hand ASM requires macOS on physical ARM64")
  needsNifty = not options.backend or any(backend not in StandaloneBackends for backend in options.backend)
  options.source_text = None
  options.library_files = {}
  if needsNifty:
    if not options.compiler.is_file() or not os.access(options.compiler, os.X_OK):
      raise BenchmarkError("Compiler is not executable")
    options.source_text = options.source.read_bytes().decode("utf-8")
    options.library_files = {name: (Root / "lib" / name).read_bytes() for name in LibraryNames}
  options.cc = shutil.which(options.cc)
  available = availableBackends(host, options.compiler, options.cc, needsNifty)
  backends = options.backend or available
  if not backends or any(backend not in available for backend in backends):
    raise BenchmarkError("Requested backend unavailable; available: " + ", ".join(available))
  standalone = any(backend in StandaloneBackends for backend in backends)
  options.straight_c_bytes = options.straight_c_source.read_bytes() if standalone else None
  options.hand_asm_bytes = options.hand_asm_source.read_bytes() if "hand-asm" in backends else None
  manifest = options.hand_asm_source.with_name("snappy_manifest.json")
  options.hand_asm_manifest_bytes = manifest.read_bytes() if "hand-asm" in backends else None
  inputs = [options.compiler] if needsNifty else []
  if "wasm64" in backends:
    inputs.append(Path(Ray.wasmtimeExecutable()))
  if options.cc and any(backend in ("c",) + StandaloneBackends for backend in backends):
    inputs.append(Path(options.cc))
  if standalone:
    inputs.append(options.straight_c_source)
  if "hand-asm" in backends:
    inputs += [options.hand_asm_source, manifest]
  hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
  env = os.environ.copy()
  if options.cc:
    env["CC"] = options.cc
  for backend in ("arm64", "amd64"):
    runtime = options.compiler.parent / f"nifty-runtime-{backend}"
    if runtime.is_file():
      env.setdefault(f"NIFTY_RUNTIME_{backend.upper()}", str(runtime))
  result = benchmark(options, backends, host, env)
  if any(hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest for path, digest in hashes.items()):
    raise BenchmarkError("Compiler changed during benchmark")
  report = {"schema": "nifty-snappy-benchmark-v1", "machine": host, "timing_scope": TimingScope,
            "inputs_sha256": hashes, "toolchain": {"wasmtime": Ray.engineMetadata(backends), "compiler": str(options.compiler) if needsNifty else None, "cc": options.cc,
            "compiler_help": Ray.optionalCommand([str(options.compiler), "--help"]) if needsNifty else None,
            "cc_version": Ray.optionalCommand([options.cc, "--version"]) if options.cc else None},
            "settings": {"size": options.size, "repeat": options.repeat, "samples": options.samples,
            "warmups": options.warmups, "opt": options.opt, "backends": backends,
            "source_sha256": hashlib.sha256(options.source_text.encode("utf-8")).hexdigest() if needsNifty else None,
            "straight_c_sha256": hashlib.sha256(options.straight_c_bytes).hexdigest() if standalone else None,
            "hand_asm_sha256": hashlib.sha256(options.hand_asm_bytes).hexdigest() if options.hand_asm_bytes is not None else None,
            "hand_asm_provenance": json.loads(options.hand_asm_manifest_bytes) if options.hand_asm_manifest_bytes is not None else None,
            "hand_asm_provenance_sha256": hashlib.sha256(options.hand_asm_manifest_bytes).hexdigest() if options.hand_asm_manifest_bytes is not None else None,
            "library_sha256": {name: hashlib.sha256(data).hexdigest() for name, data in options.library_files.items()}},
            "benchmark": result}
  markdown = markdownReport(report, options.wall)
  (options.output / "results.json").write_bytes((json.dumps(report, indent=2) + "\n").encode("utf-8"))
  (options.output / "results.md").write_bytes(markdown.encode("utf-8"))
  print(markdown)
  return 0

if __name__ == "__main__":
  try:
    sys.exit(main())
  except (BenchmarkError, OSError, ValueError) as error:
    print(f"Benchmark failed: {error}", file=sys.stderr)
    sys.exit(1)

#!/usr/bin/env python3
"""Compile, validate, and measure Nifty's JSON tree parser."""

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
Spec = importlib.util.spec_from_file_location("ray_benchmark", Root / "benchmarks/run.py")
Ray = importlib.util.module_from_spec(Spec)
Spec.loader.exec_module(Ray)
BenchmarkError = Ray.BenchmarkError
StandaloneBackends = ("c-straight", "hand-asm")
Backends = StandaloneBackends + Ray.Backends
RecordText = (r'{"name":"Nifty\nJSON","unicode":"\u00e9\uD83D\uDE03",'
              r'"nul":"a\u0000b","integer":9007199254740993,'
              r'"fraction":-12.50e+2,"enabled":true,"disabled":false,'
              r'"nothing":null,"nested":[1,"x",{"k":false},[]],"empty":{}}')
LibraryNames = ("json.nifty", "jsontypes.nifty", "jsonstrings.nifty", "jsonnumbers.nifty")
TimingScope = ("Each timed cycle parses the complete input, consumes the decoded "
               "tree into a checksum, and releases every tree allocation. Input "
               "construction, process startup, and output are outside the interval. "
               "Throughput includes consumption and cleanup, not just tokenization. "
               "Each sample starts a fresh process; first-use execution and "
               "translation within the loop remain timed.")
ComparisonScope = ("C straight is an independent handwritten parser that builds "
                   "an owned tree and transfers children into their parents. "
                   "Nifty's parser currently copies completed subtrees. Timing "
                   "differences reflect parser implementation and ownership "
                   "costs as well as code generation. Hand ASM starts from Clang-generated "
                   "C parser assembly with manually tuned string and checksum code.")


class Number(str):
  """Preserve the exact number spelling used by the Nifty tree."""


class Object(list):
  """Preserve object member order separately from JSON arrays."""


def digest(value):
  """Hash every typed value, decoded string, and ordered key independently."""
  checksum = 0

  def feed(byte):
    """Append one byte using a bounded rolling hash."""
    nonlocal checksum
    checksum = (checksum * 257 + byte) % 1000000007

  def text(value):
    """Append UTF-8 bytes and a string terminator."""
    for byte in value.encode("utf-8"):
      feed(byte)
    feed(0)

  def visit(node):
    """Walk the shallow fixture with Python's independent JSON values."""
    if node is None:
      feed(1)
    elif isinstance(node, bool):
      feed(2)
      feed(int(node))
    elif isinstance(node, Number):
      feed(3)
      text(node)
    elif isinstance(node, str):
      feed(4)
      text(node)
    elif isinstance(node, Object):
      feed(6)
      for key, child in node:
        text(key)
        visit(child)
      feed(255)
    elif isinstance(node, list):
      feed(5)
      for child in node:
        visit(child)
      feed(255)
    else:
      raise BenchmarkError(f"Unsupported oracle value: {type(node).__name__}")

  visit(value)
  return checksum


def expectedWorkload(records):
  """Construct the exact input and its independently parsed tree checksum."""
  data = ("[" + ",".join([RecordText] * records) + "]").encode("utf-8")
  tree = json.loads(data, parse_int=Number, parse_float=Number,
                    object_pairs_hook=Object)
  return {"input": data, "input_bytes": len(data), "checksum": digest(tree),
          "input_sha256": hashlib.sha256(data).hexdigest()}


def parseOutput(output, records, repeat, expected):
  """Reject any timing sample without correct framing and tree checksums."""
  if len(output) > 1024 + repeat * 64 or not output.endswith(b"\n") or b"\r" in output:
    raise BenchmarkError("Parser output has invalid framing or excessive length")
  try:
    lines = output.decode("ascii").splitlines()
  except UnicodeDecodeError as error:
    raise BenchmarkError("Parser emitted non-ASCII output") from error
  if len(lines) != 11 + repeat or lines[0] != "NIFTY_JSON_V1":
    raise BenchmarkError("Parser did not emit the complete NIFTY_JSON_V1 protocol")
  fields = {}
  names = ("records", "repeat", "input_bytes", "start_sec", "start_nsec",
           "end_sec", "end_nsec")
  for line, name in zip(lines[1:8], names):
    match = re.fullmatch(name + r" (0|[1-9][0-9]{0,18})", line)
    if not match:
      raise BenchmarkError(f"Invalid or missing parser field: {name}")
    fields[name] = int(match[1])
  if (fields["records"], fields["repeat"], fields["input_bytes"]) != (
      records, repeat, expected["input_bytes"]):
    raise BenchmarkError("Parser workload does not match the requested build")
  if lines[8] != "clock_status 0 0" or lines[9] != f"successes {repeat}":
    raise BenchmarkError("Parser or monotonic clock failed")
  if any(fields[name] >= 1000000000 for name in ("start_nsec", "end_nsec")):
    raise BenchmarkError("Invalid monotonic nanosecond field")
  elapsed = ((fields["end_sec"] - fields["start_sec"]) * 1000000000 +
             fields["end_nsec"] - fields["start_nsec"])
  if elapsed <= 0:
    raise BenchmarkError("Parser monotonic clock did not advance")
  checksums = []
  for index, line in enumerate(lines[10:10 + repeat]):
    match = re.fullmatch(rf"parse_checksum {index} (0|[1-9][0-9]{{0,18}})", line)
    if not match or int(match[1]) != expected["checksum"]:
      raise BenchmarkError(f"Independent tree checksum mismatch at parse {index}")
    checksums.append(int(match[1]))
  match = re.fullmatch(r"batch_checksum (0|[1-9][0-9]{0,18})", lines[-1])
  if not match or int(match[1]) != sum(checksums):
    raise BenchmarkError("Batch checksum does not match every repeated parse")
  return {"elapsed_ns": elapsed, "checksums": checksums,
          "batch_checksum": int(match[1]),
          "clock_fields": {key: fields[key] for key in names[3:]}}


def configuredSource(source, records, repeat):
  """Change only workload constants and the generated copy's library path."""
  for name, value in (("Records", records), ("Repetitions", repeat),
                      ("ClockId", time.CLOCK_MONOTONIC)):
    source, count = re.subn(rf"(?m)^(const {name} = )[0-9]+$",
                            lambda match: match[1] + str(value), source)
    if count != 1:
      raise BenchmarkError(f"Expected exactly one source constant: {name}")
  source, count = re.subn(r'(?m)^import "\.\./lib/json"$', 'import "lib/json"', source)
  if count != 1:
    raise BenchmarkError("Expected exactly one parser library import")
  return source


def buildBackend(backend, options, env):
  """Build a self-contained snapshot and preserve commands and diagnostics."""
  directory = options.output / "build" / f"n{options.records}-r{options.repeat}" / backend
  directory.mkdir(parents=True, exist_ok=True)
  executable = directory / "json_parser"
  assembly = None
  provenance = None
  if backend in StandaloneBackends:
    source = directory / "json_parser_straight.c"
    source.write_text(options.straight_c_text, encoding="utf-8")
    flags = Ray.StraightCFlags.copy()
    if backend == "hand-asm":
      flags += ["-arch", "arm64", "-DJSON_HAND_ASM"]
      assembly = directory / "json_parser_hand.S"
      assembly.write_bytes(options.hand_asm_bytes)
      if getattr(options, "hand_asm_manifest_bytes", None) is not None:
        provenance = directory / "json_parser_manifest.json"
        provenance.write_bytes(options.hand_asm_manifest_bytes)
    command = [options.cc] + flags + [
      f"-DRECORDS={options.records}", f"-DREPETITIONS={options.repeat}",
      f"-DCLOCK_ID={time.CLOCK_MONOTONIC}", str(source)]
    if assembly is not None:
      command.append(str(assembly))
    command += ["-o", str(executable)]
  else:
    (directory / "lib").mkdir(parents=True, exist_ok=True)
    for name, data in options.library_files.items():
      (directory / "lib" / name).write_bytes(data)
    source = directory / "json_parser.nifty"
    source.write_text(configuredSource(options.source_text, options.records,
                                      options.repeat), encoding="utf-8")
    command = [str(options.compiler), "build", str(source), f"--backend:{backend}",
               f"--opt:{options.opt}", "-o", str(executable)]
  response, elapsed = Ray.runCommand(command, options.timeout, env)
  (directory / "build.stdout").write_bytes(response.stdout)
  (directory / "build.stderr").write_bytes(response.stderr)
  architectures = Ray.binaryArchitectures(executable)
  if len(architectures) != 1 or (
      backend in ("arm64", "amd64", "hand-asm") and
      architectures != ["arm64" if backend == "hand-asm" else backend]):
    raise BenchmarkError(f"Unexpected executable architecture for {backend}: {architectures}")
  architecture = architectures[0]
  execution = [str(executable)]
  if architecture == "amd64" and options.host["physical_architecture"] == "arm64":
    execution = ["/usr/bin/arch", "-x86_64"] + execution
  inspection = None
  if options.emit_ir and backend not in ("c",) + StandaloneBackends:
    ir = directory / "json_parser.ir"
    inspectCommand = [str(options.compiler), str(source), f"--backend:{backend}",
                      f"--opt:{options.opt}", "--emit-ir", "-o", str(ir)]
    _, inspectionNs = Ray.runCommand(inspectCommand, options.timeout, env)
    inspection = {"path": str(ir), "command": inspectCommand, "wall_ns": inspectionNs}
  label = "Hand ASM (ARM64)" if backend == "hand-asm" else Ray.backendLabel(
    backend, options.host, architecture)
  if backend == "c":
    label = label.replace("C (", "Nifty C backend (", 1)
  return {"backend": backend, "label": label,
          "execution_architecture": architecture, "executable": str(executable),
          "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
          "source": str(source), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
          "assembly": str(assembly) if assembly else None,
          "assembly_sha256": hashlib.sha256(assembly.read_bytes()).hexdigest() if assembly else None,
          "assembly_provenance": str(provenance) if provenance else None,
          "assembly_provenance_sha256": hashlib.sha256(provenance.read_bytes()).hexdigest() if provenance else None,
          "compile_command": command, "compile_wall_ns": elapsed,
          "execution_command": execution, "inspection": inspection,
          "cycle_ns_per_parse": [], "process_wall_ns": [], "raw_samples": [],
          "warmup_checksums": []}


def benchmark(options, backends, host, env):
  """Rotate process samples and validate every parse against the Python oracle."""
  expected = expectedWorkload(options.records)
  options.host = host
  results = [buildBackend(backend, options, env) for backend in backends]
  rounds = []
  for index in range(options.warmups + options.samples):
    offset = index % len(results)
    ordered = results[offset:] + results[:offset]
    rounds.append([result["backend"] for result in ordered])
    for result in ordered:
      response, wallNs = Ray.runCommand(result["execution_command"], options.timeout, env)
      if response.stderr:
        raise BenchmarkError(f"Unexpected parser stderr from {result['backend']}: " +
                             response.stderr.decode("utf-8", "replace")[:2000])
      parsed = parseOutput(response.stdout, options.records, options.repeat, expected)
      if index < options.warmups:
        result["warmup_checksums"].append(parsed["batch_checksum"])
      else:
        result["cycle_ns_per_parse"].append(parsed["elapsed_ns"] / options.repeat)
        result["process_wall_ns"].append(wallNs)
        result["raw_samples"].append(dict(parsed, process_wall_ns=wallNs))
  for result in results:
    result["cycle_ns_per_parse"] = Ray.summarize(result["cycle_ns_per_parse"])
    result["process_wall_ns"] = Ray.summarize(result["process_wall_ns"])
    result["mib_per_second"] = (expected["input_bytes"] * 1e9 / 1048576 /
                                result["cycle_ns_per_parse"]["median"])
  (options.output / "input.json").write_bytes(expected["input"])
  return {"records": options.records, "repeat": options.repeat,
          "input_bytes": expected["input_bytes"], "input_sha256": expected["input_sha256"],
          "checksum": expected["checksum"], "sample_order": rounds,
          "correctness": "every tree checksum matches Python stdlib json",
          "backends": results}


def parseArguments(arguments=None):
  """Reject unbounded or unsupported configuration before building."""
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--backend", action="append", default=[],
                      help="Repeat or use comma-separated c-straight,hand-asm,c,arm64,amd64")
  parser.add_argument("--records", type=int, default=128)
  parser.add_argument("--repeat", type=int, default=10)
  parser.add_argument("--samples", type=int, default=5)
  parser.add_argument("--warmups", type=int, default=1)
  parser.add_argument("--opt", choices=("none", "speed"), default="speed")
  parser.add_argument("--compiler", type=Path, default=Root / "nifty")
  parser.add_argument("--source", type=Path, default=Root / "benchmarks/json_parser.nifty")
  parser.add_argument("--straight-c-source", type=Path,
                      default=Root / "benchmarks/json_parser_straight.c")
  parser.add_argument("--hand-asm-source", type=Path,
                      default=Root / "benchmarks/arm64/json_parser_hand.S")
  parser.add_argument("--cc", default=os.environ.get("CC", "cc"),
                      help="C compiler for standalone and Nifty-generated C")
  parser.add_argument("--output", type=Path, default=Root / "benchmarks/output/json")
  parser.add_argument("--timeout", type=float, default=300)
  parser.add_argument("--emit-ir", action="store_true")
  parser.add_argument("--wall", action="store_true")
  options = parser.parse_args(arguments)
  for name, low, high in (("records", 1, 4096), ("repeat", 1, 1000),
                          ("samples", 5, 1000), ("warmups", 1, 1000)):
    if not low <= getattr(options, name) <= high:
      parser.error(f"--{name} must be in {low}..{high}")
  if not 0 < options.timeout <= 3600:
    parser.error("--timeout must be greater than zero and at most 3600")
  selected = []
  for entry in options.backend:
    for backend in entry.split(","):
      if backend not in Backends:
        parser.error(f"unknown backend: {backend}")
      if backend not in selected:
        selected.append(backend)
  options.backend = selected
  for name in ("compiler", "source", "straight_c_source", "hand_asm_source", "output"):
    setattr(options, name, getattr(options, name).expanduser().resolve())
  return options


def markdownReport(report, wall):
  """Show validated per-parse timings with explicit measurement boundaries."""
  result = report["benchmark"]
  lines = [f"Nifty JSON parser: {result['records']} records, {result['input_bytes']} input bytes",
           "", TimingScope]
  if any(backend["backend"] in StandaloneBackends for backend in result["backends"]):
    lines += ["", ComparisonScope]
  lines += ["", f"Correctness: {result['correctness']}.", "",
           f"Native optimization: {report['settings']['opt']}. C uses -O2.", "",
           "| Backend | Compile (ms) | Cycle median (ms) | Min (ms) | Max (ms) | MiB/s |",
           "| --- | ---: | ---: | ---: | ---: | ---: |"]
  for backend in result["backends"]:
    timing = backend["cycle_ns_per_parse"]
    lines.append(f"| {backend['label']} | {backend['compile_wall_ns'] / 1e6:.3f} | "
                 f"{timing['median'] / 1e6:.3f} | {timing['min'] / 1e6:.3f} | "
                 f"{timing['max'] / 1e6:.3f} | {backend['mib_per_second']:.3f} |")
  if wall:
    lines += ["", "Whole-process wall medians include setup and output:"]
    for backend in result["backends"]:
      lines.append(f"- {backend['label']}: {backend['process_wall_ns']['median'] / 1e6:.3f} ms")
  lines += ["", f"Input SHA-256: `{result['input_sha256']}`",
            f"Tree checksum: `{result['checksum']}`", ""]
  return "\n".join(lines)


def handAsmSupported(host):
  """Restrict the persisted Mach-O assembly to physical Apple ARM64 hosts."""
  return host["system"] == "Darwin" and host["physical_architecture"] == "arm64"


def availableBackends(host, compiler, cc, needsNifty=True):
  """Select JSON backends without changing the shared ray backend registry."""
  available = list(Ray.availableBackends(host, compiler)) if needsNifty else []
  if cc:
    available.insert(0, "c-straight")
    if handAsmSupported(host):
      available.insert(1, "hand-asm")
    if needsNifty and "c" not in available:
      available.append("c")
  else:
    available = [backend for backend in available if backend != "c"]
  return available


def main(arguments=None):
  """Publish reproducible results after every backend passes validation."""
  options = parseArguments(arguments)
  host = Ray.hostInfo()
  if host["system"] not in ("Darwin", "Linux") or getattr(time, "CLOCK_MONOTONIC", None) is None:
    raise BenchmarkError("JSON timing requires POSIX clock_gettime on macOS or Linux")
  if "hand-asm" in options.backend and not handAsmSupported(host):
    raise BenchmarkError("Hand ASM requires macOS on physical ARM64 with a C compiler")
  needsNifty = not options.backend or any(
    backend not in StandaloneBackends for backend in options.backend)
  options.source_text = None
  options.library_files = {}
  if needsNifty:
    if not options.compiler.is_file() or not os.access(options.compiler, os.X_OK):
      raise BenchmarkError(f"Compiler is not executable: {options.compiler}")
    options.source_text = options.source.read_text(encoding="utf-8")
    options.library_files = {name: (Root / "lib" / name).read_bytes() for name in LibraryNames}
  options.cc = shutil.which(options.cc)
  if "hand-asm" in options.backend and not options.cc:
    raise BenchmarkError("Hand ASM requires an available C compiler (--cc or CC)")
  available = availableBackends(host, options.compiler, options.cc, needsNifty)
  backends = options.backend or available
  if not backends or any(backend not in available for backend in backends):
    raise BenchmarkError("Requested backend or runtime is unavailable; available: " +
                         ", ".join(available))
  options.straight_c_text = options.straight_c_source.read_text(encoding="utf-8") \
      if any(backend in StandaloneBackends for backend in backends) else None
  options.hand_asm_bytes = options.hand_asm_source.read_bytes() if "hand-asm" in backends else None
  manifest = options.hand_asm_source.parent / "json_parser_manifest.json"
  options.hand_asm_manifest_bytes = manifest.read_bytes() \
      if "hand-asm" in backends and manifest.is_file() else None
  options.output.mkdir(parents=True, exist_ok=True)
  for name in ("results.json", "results.md"):
    (options.output / name).unlink(missing_ok=True)
  inputs = [options.compiler] if needsNifty else []
  if options.cc and any(backend in ("c",) + StandaloneBackends for backend in backends):
    inputs.append(Path(options.cc))
  fingerprints = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
  env = os.environ.copy()
  if options.cc:
    env["CC"] = options.cc
  for backend in ("arm64", "amd64"):
    template = options.compiler.parent / f"nifty-runtime-{backend}"
    if template.is_file():
      env.setdefault(f"NIFTY_RUNTIME_{backend.upper()}", str(template))
  result = benchmark(options, backends, host, env)
  if any(hashlib.sha256(path.read_bytes()).hexdigest() != value
         for path, value in fingerprints.items()):
    raise BenchmarkError("Compiler changed during benchmark")
  report = {"schema": "nifty-json-benchmark-v1", "machine": host,
            "timing_scope": TimingScope,
            "comparison_scope": ComparisonScope if any(backend in StandaloneBackends for backend in backends) else None,
            "toolchain": {"compiler": str(options.compiler) if needsNifty else None,
                          "compiler_sha256": fingerprints.get(options.compiler),
                          "compiler_architectures": Ray.binaryArchitectures(options.compiler) if needsNifty else [],
                          "compiler_help": Ray.optionalCommand([str(options.compiler), "--help"]) if needsNifty else None,
                          "cc": Ray.optionalCommand([options.cc, "--version"]) if options.cc else None,
                          "cc_path": options.cc,
                          "c_flags": Ray.StraightCFlags,
                          "hand_asm_flags": Ray.StraightCFlags + ["-arch", "arm64", "-DJSON_HAND_ASM"]
                              if "hand-asm" in backends else None},
            "inputs_sha256": {str(path): value for path, value in fingerprints.items()},
            "settings": {"records": options.records, "repeat": options.repeat,
                         "samples": options.samples, "warmups": options.warmups,
                         "opt": options.opt, "backends": backends,
                         "timeout_seconds": options.timeout,
                         "source": str(options.source) if needsNifty else None,
                         "source_sha256": hashlib.sha256(options.source_text.encode()).hexdigest() if needsNifty else None,
                         "straight_c_source": str(options.straight_c_source) if options.straight_c_text is not None else None,
                         "straight_c_sha256": hashlib.sha256(options.straight_c_text.encode()).hexdigest()
                             if options.straight_c_text is not None else None,
                         "hand_asm_source": str(options.hand_asm_source) if options.hand_asm_bytes is not None else None,
                         "hand_asm_sha256": hashlib.sha256(options.hand_asm_bytes).hexdigest()
                             if options.hand_asm_bytes is not None else None,
                         "hand_asm_provenance": json.loads(options.hand_asm_manifest_bytes)
                             if options.hand_asm_manifest_bytes is not None else None,
                         "hand_asm_provenance_sha256": hashlib.sha256(options.hand_asm_manifest_bytes).hexdigest()
                             if options.hand_asm_manifest_bytes is not None else None,
                         "library_sha256": {name: hashlib.sha256(data).hexdigest()
                                            for name, data in options.library_files.items()}},
            "benchmark": result}
  markdown = markdownReport(report, options.wall)
  (options.output / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
  (options.output / "results.md").write_text(markdown, encoding="utf-8")
  print(markdown)
  return 0


if __name__ == "__main__":
  try:
    sys.exit(main())
  except (BenchmarkError, OSError, ValueError) as error:
    print(f"Benchmark failed: {error}", file=sys.stderr)
    sys.exit(1)

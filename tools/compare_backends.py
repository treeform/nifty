#!/usr/bin/env python3
"""Compare frozen and candidate native compilers against architecture-matched C.

Builds finish before execution. Warmup/sample rounds rotate all executables.
Only the four existing workload configuration constants may change. Every
response must match exact RGB, and available independent goldens are mandatory.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import time

Root = Path(__file__).resolve().parent.parent
Spec = importlib.util.spec_from_file_location("ray_benchmark", Root / "benchmarks/run.py")
Ray = importlib.util.module_from_spec(Spec)
Spec.loader.exec_module(Ray)
CFlags = ["-O2", "-pthread", "-fno-strict-aliasing", "-ffp-contract=off"]


def sha256(path):
  """Fingerprint each input without modifying it."""
  return hashlib.sha256(path.read_bytes()).hexdigest()


def compilerEnvironment(compiler):
  """Use each compiler's own runtime templates when present."""
  environment = os.environ.copy()
  for architecture in ("arm64", "amd64"):
    template = compiler.parent / f"nifty-runtime-{architecture}"
    if template.is_file():
      environment[f"NIFTY_RUNTIME_{architecture.upper()}"] = str(template)
  return environment


def executionCommand(executable, architecture, host):
  """Run every AMD64 executable through the same Rosetta entry point."""
  command = [str(executable)]
  if architecture == "amd64" and host["physical_architecture"] == "arm64":
    command = ["/usr/bin/arch", "-x86_64"] + command
  return command


def cCommand(cc, architecture, host, source, executable):
  """Keep the reference backend's optimization flags while selecting its CPU."""
  command = [cc] + CFlags
  if host["system"] == "Darwin":
    command += ["-arch", "x86_64" if architecture == "amd64" else "arm64"]
  elif architecture != host["physical_architecture"]:
    raise Ray.BenchmarkError("Cross-architecture C requires a Darwin -arch toolchain")
  return command + ["-o", str(executable), str(source), "-lm"]


def build(variant, architecture, compiler, size, repeat, options, host):
  """Build and inspect one variant, preserving commands and generated source."""
  label = f"{variant}-{architecture}"
  directory = options.output / "build" / f"{size}-r{repeat}" / label
  directory.mkdir(parents=True, exist_ok=True)
  source = directory / "raytracer.nifty"
  source.write_text(Ray.configuredSource(options.source.read_text(), size, repeat))
  executable = directory / "raytracer"
  environment = compilerEnvironment(compiler)
  commands = []
  started = time.perf_counter_ns()
  if variant == "c":
    generated = source.with_suffix(".c")
    commands.append([str(compiler), str(source), "--emit-c", "-o", str(generated)])
    response, _ = Ray.runCommand(commands[-1], options.timeout, environment)
    (directory / "emit.stdout").write_bytes(response.stdout)
    (directory / "emit.stderr").write_bytes(response.stderr)
    commands.append(cCommand(options.cc, architecture, host, generated, executable))
  else:
    commands.append([str(compiler), "build", str(source),
                     f"--backend:{architecture}", "-o", str(executable)])
  response, _ = Ray.runCommand(commands[-1], options.timeout, environment)
  compileNs = time.perf_counter_ns() - started
  (directory / "build.stdout").write_bytes(response.stdout)
  (directory / "build.stderr").write_bytes(response.stderr)
  architectures = Ray.binaryArchitectures(executable)
  if architectures != [architecture]:
    raise Ray.BenchmarkError(f"Wrong executable architecture for {label}: {architectures}")
  return {"label": label, "architecture": architecture,
          "compiler": str(compiler), "compiler_sha256": sha256(compiler),
          "source": str(source), "source_sha256": sha256(source),
          "executable": str(executable), "executable_sha256": sha256(executable),
          "execution_command": executionCommand(executable, architecture, host),
          "compile_commands": commands, "compile_wall_ns": compileNs,
          "render_ns_per_frame": [], "process_wall_ns": [], "clock_fields": []}


def measure(size, repeat, options, host, variants, warmups, samples):
  """Retain samples only after strict protocol and exact image validation."""
  results = [build(*variant, size, repeat, options, host) for variant in variants]
  reference = Ray.loadReference(Root / "benchmarks/reference", size)
  if size in (4, 16, 64) and reference is None:
    raise Ray.BenchmarkError(f"Required independent golden is missing: {size}.rgb")
  expected = reference
  rounds = []
  for index in range(warmups + samples):
    offset = index % len(results)
    order = results[offset:] + results[:offset]
    rounds.append([result["label"] for result in order])
    for result in order:
      response, wallNs = Ray.runCommand(result["execution_command"], options.timeout)
      if response.stderr:
        raise Ray.BenchmarkError(f"Unexpected stderr from {result['label']}")
      parsed = Ray.parseOutput(response.stdout, size, repeat)
      if expected is None:
        expected = parsed["pixels"]
      if parsed["pixels"] != expected:
        raise Ray.BenchmarkError(
          f"Exact RGB mismatch for {result['label']}, size {size}, round {index + 1}")
      if index >= warmups:
        result["render_ns_per_frame"].append(parsed["elapsed_ns"] / repeat)
        result["process_wall_ns"].append(wallNs)
        result["clock_fields"].append(parsed["clock_fields"])
  for result in results:
    result["render_ns_per_frame"] = Ray.summarize(result["render_ns_per_frame"])
    result["process_wall_ns"] = Ray.summarize(result["process_wall_ns"])
  (options.output / f"{size}.rgb").write_bytes(expected)
  return {"size": size, "repeat": repeat, "warmups": warmups, "samples": samples,
          "correctness": "independent golden and exact RGB" if reference is not None
                         else "exact RGB across all variants; independent golden unavailable",
          "independent_sha256": hashlib.sha256(reference).hexdigest()
                                if reference is not None else None,
          "pixel_sha256": hashlib.sha256(expected).hexdigest(),
          "round_order": rounds, "variants": results}


def parseArguments(arguments=None):
  """Require explicit compiler identities and bound every measured workload."""
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--baseline", required=True, type=Path)
  parser.add_argument("--candidate", required=True, type=Path)
  parser.add_argument("--backend", choices=("arm64", "amd64"), action="append")
  parser.add_argument("--c-architecture", choices=("auto", "arm64", "amd64"), default="auto",
                      help="auto builds one C baseline per selected native CPU")
  parser.add_argument("--cc", default="cc")
  parser.add_argument("--size", type=int, action="append", help="Repeat; default 64 and 256")
  parser.add_argument("--repeat", type=int, default=1)
  parser.add_argument("--warmups", type=int, default=1)
  parser.add_argument("--samples", type=int, default=5)
  parser.add_argument("--timeout", type=float, default=300)
  parser.add_argument("--source", type=Path, default=Root / "benchmarks/raytracer.nifty")
  parser.add_argument("--output", type=Path, required=True)
  options = parser.parse_args(arguments)
  options.size = list(dict.fromkeys(options.size or [64, 256]))
  for name, values, low, high in (
      ("size", options.size, 1, 512), ("repeat", [options.repeat], 1, 1000),
      ("warmups", [options.warmups], 1, 1000), ("samples", [options.samples], 5, 1000)):
    if any(not low <= value <= high for value in values):
      parser.error(f"--{name} must be in {low}..{high}")
  if not 0 < options.timeout <= 3600:
    parser.error("--timeout must be greater than zero and at most 3600")
  for name in ("baseline", "candidate", "source", "output"):
    setattr(options, name, getattr(options, name).expanduser().resolve())
  for compiler in (options.baseline, options.candidate):
    if not compiler.is_file() or not os.access(compiler, os.X_OK):
      parser.error(f"Compiler is not executable: {compiler}")
  options.cc = shutil.which(options.cc)
  if not options.cc:
    parser.error("C compiler is unavailable")
  return options


def main(arguments=None):
  """Publish comparison evidence only when all validation and timing succeeds."""
  options = parseArguments(arguments)
  host = Ray.hostInfo()
  architectures = options.backend or [host["physical_architecture"]]
  architectures = list(dict.fromkeys(architectures))
  for compiler in (options.baseline, options.candidate):
    available = Ray.availableBackends(host, compiler)
    if any(architecture not in available for architecture in architectures):
      raise Ray.BenchmarkError(f"Requested native runtime unavailable for {compiler}: {available}")
  cArchitectures = architectures if options.c_architecture == "auto" else [options.c_architecture]
  for architecture in cArchitectures:
    if architecture not in architectures:
      raise Ray.BenchmarkError("C architecture must match a selected native backend")
  variants = [(kind, architecture, compiler) for architecture in architectures
              for kind, compiler in (("baseline", options.baseline),
                                     ("candidate", options.candidate))]
  variants += [("c", architecture, options.baseline) for architecture in cArchitectures]
  fingerprints = {path: sha256(path) for path in
                  (options.baseline, options.candidate, options.source)}
  for compiler in (options.baseline, options.candidate):
    environment = compilerEnvironment(compiler)
    for architecture in architectures:
      runtime = environment.get(f"NIFTY_RUNTIME_{architecture.upper()}")
      if runtime:
        path = Path(runtime).resolve()
        fingerprints[path] = sha256(path)
  options.output.mkdir(parents=True, exist_ok=True)
  (options.output / "results.json").unlink(missing_ok=True)
  checks = [measure(size, 1, options, host, variants, 1, 1) for size in (4, 16)]
  measurements = [measure(size, options.repeat, options, host, variants,
                          options.warmups, options.samples) for size in options.size]
  if any(sha256(path) != fingerprint for path, fingerprint in fingerprints.items()):
    raise Ray.BenchmarkError("Compiler or renderer source changed during comparison")
  report = {"schema": "nifty-native-comparison-v1", "host": host,
            "inputs_sha256": {str(path): value for path, value in fingerprints.items()},
            "cc": Ray.optionalCommand([options.cc, "--version"]),
            "c_flags": CFlags, "reference_manifest": json.loads(
              (Root / "benchmarks/reference/manifest.json").read_text()),
            "checks": checks, "measurements": measurements}
  (options.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
  for measured in measurements:
    print(f"{measured['size']}x{measured['size']}: {measured['correctness']}")
    for result in measured["variants"]:
      print(f"  {result['label']}: {result['render_ns_per_frame']['median'] / 1e6:.3f} ms/frame")
  print(f"Raw samples, exact build commands, hashes: {options.output / 'results.json'}")
  return 0


if __name__ == "__main__":
  try:
    sys.exit(main())
  except (Ray.BenchmarkError, OSError, ValueError) as error:
    print(f"Comparison failed: {error}", file=sys.stderr)
    sys.exit(1)

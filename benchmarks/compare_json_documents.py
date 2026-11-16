#!/usr/bin/env python3
"""Compare JSON tree/document parsing with identical input and checked digests."""
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
Spec = importlib.util.spec_from_file_location("json_benchmark", Root / "benchmarks/run_json.py")
Json = importlib.util.module_from_spec(Spec)
Spec.loader.exec_module(Json)
Ray = Json.Ray

WindowsClock = """extern "kernel32":
  proc QueryPerformanceCounter(value: var int64): int32
  proc QueryPerformanceFrequency(value: var int64): int32

proc jsonBenchmarkClock(value: var Timespec): int32 =
  var frequency: int64
  var counter: int64
  if QueryPerformanceFrequency(frequency) == 0:
    return -1
  if QueryPerformanceCounter(counter) == 0:
    return -1
  if frequency <= 0 or counter < 0:
    return -1
  let remainder = counter % frequency
  if remainder < 0 or remainder > 9223372036:
    return -1
  value.sec = counter / frequency
  value.nsec = (remainder * 1000000000) / frequency
  return 0
"""

AllocationHooks = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static uint64_t alloc_calls, alloc_bytes;
static int count_allocations;
static void *json_probe_realloc(void *p, size_t n) {
  if(count_allocations) { ++alloc_calls; alloc_bytes += n; }
  return realloc(p,n);
}
static void json_probe_free(void *p) { free(p); }
void jsonAllocationStart(void) { alloc_calls=alloc_bytes=0; count_allocations=1; }
void jsonAllocationFinish(void) {
  count_allocations=0;
  printf("ALLOCATIONS %llu %llu\n",(unsigned long long)alloc_calls,
         (unsigned long long)alloc_bytes);
}
#define NIFTY_REALLOC json_probe_realloc
#define NIFTY_FREE json_probe_free
"""


def prepareSource(source, model, records, repeat, system, allocations=False):
    """Only select the workload, import location, and host monotonic clock."""
    library = "jsondoc" if model == "document" else "json"
    old = f'import "../lib/{library}"'
    if source.count(old) != 1:
        raise Ray.BenchmarkError("Expected exactly one benchmark library import")
    source = source.replace(old, f'import "lib/{library}"')
    for name, number in (("Records", records), ("Repetitions", repeat),
                         ("ClockId", getattr(time, "CLOCK_MONOTONIC", 1))):
        source, count = re.subn(rf"(?m)^const {name} = [0-9]+$",
                                f"const {name} = {number}", source)
        if count != 1:
            raise Ray.BenchmarkError("Missing or repeated workload constant: " + name)
    if system == "Windows":
        old = 'extern "libc":\n  proc clock_gettime(clock: int32, value: var Timespec): int32'
        if source.count(old) != 1:
            raise Ray.BenchmarkError("Expected exactly one POSIX clock declaration")
        source = source.replace(old, WindowsClock)
        source = source.replace("clock_gettime(ClockId, started)", "jsonBenchmarkClock(started)")
        source = source.replace("clock_gettime(ClockId, finished)", "jsonBenchmarkClock(finished)")
    if allocations:
        source = source.replace("func feed(", 'extern "probe":\n  proc jsonAllocationStart()\n  proc jsonAllocationFinish()\n\nfunc feed(', 1)
        source = source.replace("  for repetition in 0 ..< Repetitions:\n    results[repetition] = parseAndConsume(input)",
                                "  jsonAllocationStart()\n  for repetition in 0 ..< Repetitions:\n    results[repetition] = parseAndConsume(input)\n  jsonAllocationFinish()", 1)
    return source


def snapshot(directory):
    (directory / "lib").mkdir(parents=True, exist_ok=True)
    for name in Json.LibraryNames:
        (directory / "lib" / name).write_bytes((Root / "lib" / name).read_bytes())


def build(options, model, backend, host, env):
    directory = options.output / "build" / model / backend
    snapshot(directory)
    if backend == "hand-c":
        for name in ("json_parser_straight.c", "json_document_hand.c"):
            (directory / name).write_bytes((Root / "benchmarks" / name).read_bytes())
        source = directory / ("json_document_hand.c" if model == "document" else "json_parser_straight.c")
        executable = directory / ("benchmark.exe" if host["system"] == "Windows" else "benchmark")
        command = [options.cc] + Ray.StraightCFlags + [
            f"-DRECORDS={options.records}", f"-DREPETITIONS={options.repeat}",
            f"-DCLOCK_ID={getattr(time, 'CLOCK_MONOTONIC', 1)}", str(source), "-o", str(executable)]
        if host["system"] == "Windows": command.append("-static")
        response, elapsed = Ray.runCommand(command, options.timeout, env)
        (directory / "build.stdout").write_bytes(response.stdout)
        (directory / "build.stderr").write_bytes(response.stderr)
        print(f"Built {model}/{backend} in {elapsed / 1e9:.3f}s", flush=True)
        return dict(model=model, backend=backend, compile_wall_ns=elapsed,
                    build_command=command, executable=str(executable),
                    executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                    source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                    execution_command=[str(executable)], samples=[], warmups=[])
    original = Root / "benchmarks" / ("json_document.nifty" if model == "document" else "json_parser.nifty")
    source = directory / "benchmark.nifty"
    source.write_bytes(prepareSource(original.read_text(encoding="utf-8"), model,
                                    options.records, options.repeat, host["system"]).encode())
    executable = directory / ("benchmark.exe" if host["system"] == "Windows" else "benchmark")
    executable.unlink(missing_ok=True)
    command = [str(options.compiler), "build", str(source), "--backend:" + backend,
               "--opt:" + options.opt, "-o", str(executable)]
    result, elapsed = Ray.runCommand(command, options.timeout, env)
    (directory / "build.stdout").write_bytes(result.stdout)
    (directory / "build.stderr").write_bytes(result.stderr)
    print(f"Built {model}/{backend} in {elapsed / 1e9:.3f}s", flush=True)
    return dict(model=model, backend=backend, compile_wall_ns=elapsed,
                build_command=command, executable=str(executable),
                executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                execution_command=Ray.executionCommand(backend if backend != "c" else host["physical_architecture"],
                                                       executable, host, env), samples=[], warmups=[])


def allocations(options, model, host, env, expected):
    """Separate instrumented C execution; counters never affect timed binaries."""
    directory = options.output / "allocations" / model
    snapshot(directory)
    original = Root / "benchmarks" / ("json_document.nifty" if model == "document" else "json_parser.nifty")
    source, generated = directory / "probe.nifty", directory / "probe.c"
    source.write_bytes(prepareSource(original.read_text(encoding="utf-8"), model,
                                    options.records, 1, host["system"], allocations=True).encode())
    Ray.runCommand([str(options.compiler), str(source), "--emit-c", "-o", str(generated)],
                   options.timeout, env)
    generated.write_bytes(AllocationHooks.encode() + generated.read_bytes())
    executable = directory / ("probe.exe" if host["system"] == "Windows" else "probe")
    command = [options.cc] + Ray.StraightCFlags + [str(generated), "-o", str(executable)]
    if host["system"] == "Windows":
        command += ["-static", "-lkernel32"]
    Ray.runCommand(command, options.timeout, env)
    result, _ = Ray.runCommand([str(executable)], options.timeout, env)
    lines = result.stdout.splitlines(keepends=True)
    counts = [line for line in lines if line.startswith(b"ALLOCATIONS ")]
    if len(counts) != 1:
        raise Ray.BenchmarkError("Missing allocation counter result")
    match = re.fullmatch(rb"ALLOCATIONS ([0-9]+) ([0-9]+)\r?\n", counts[0])
    if match is None:
        raise Ray.BenchmarkError("Invalid allocation counter result")
    Json.parseOutput(b"".join(line for line in lines if line not in counts),
                     options.records, 1, expected)
    return dict(calls=int(match[1]), requested_bytes=int(match[2]),
                scope="one C-backend parse, checksum and complete cleanup; input setup excluded")


def markdown(report):
    lines = ["# JSON tree versus document", "",
             f"{report['machine']['system']} {report['machine']['physical_architecture']}; "
             f"{report['records']} records, {report['input_bytes']:,} input bytes.", "",
             Json.TimingScope, "",
             f"{report['samples']} measured samples and {report['warmups']} warmups per variant; "
             f"{report['repeat']} fresh parses per process. Variants rotate within each round.", "",
             f"Native optimization: {report['opt']}. C: -O2. Build time is one observed build, not a median.", "",
             "| Model | Backend | Build (s) | Median cycle (ms) | Min (ms) | Max (ms) | MiB/s |",
             "| --- | --- | ---: | ---: | ---: | ---: | ---: |"]
    for result in report["results"]:
        timing = result["timing"]
        lines.append(f"| {result['model']} | {result['backend']} | {result['compile_wall_ns']/1e9:.3f} | "
                     f"{timing['median']/1e6:.3f} | {timing['min']/1e6:.3f} | {timing['max']/1e6:.3f} | "
                     f"{report['input_bytes']*1e9/1048576/timing['median']:.3f} |")
    lines += ["", "Allocation traffic from separate, untimed C builds:", "",
              "| Model | Allocation/reallocation calls | Total requested bytes |",
              "| --- | ---: | ---: |"]
    for model, counter in report["allocations"].items():
        lines.append(f"| {model} | {counter['calls']:,} | {counter['requested_bytes']:,} |")
    lines += ["", "Requested bytes are cumulative allocation traffic, not peak live memory.",
              f"Every repeated checksum matches Python's independent JSON oracle: `{report['checksum']}`.",
              f"Input SHA-256: `{report['input_sha256']}`", ""]
    return "\n".join(lines)


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, default=Root / ("nifty.exe" if os.name == "nt" else "nifty"))
    parser.add_argument("--backend", default=None, help="comma-separated hand-c, c and the host native backend")
    parser.add_argument("--records", type=int, default=128)
    parser.add_argument("--repeat", type=int, default=50)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--opt", choices=("none", "speed"), default="speed")
    parser.add_argument("--cc", default=os.environ.get("CC", "gcc" if os.name == "nt" else "cc"))
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--output", type=Path, default=Root / "benchmarks/output/json-document")
    options = parser.parse_args(arguments)
    for name, low, high in (("records", 1, 4096), ("repeat", 1, 1000),
                            ("samples", 5, 1000), ("warmups", 1, 1000)):
        if not low <= getattr(options, name) <= high:
            parser.error(f"--{name} must be in {low}..{high}")
    if not 0 < options.timeout <= 3600:
        parser.error("--timeout must be in (0,3600]")
    host = Ray.hostInfo()
    if host["system"] not in ("Windows", "Darwin", "Linux"):
        parser.error("Unsupported benchmark host")
    options.compiler = options.compiler.expanduser().resolve()
    if not options.compiler.is_file():
        parser.error("Compiler does not exist")
    options.output = options.output.expanduser().resolve()
    options.cc = shutil.which(options.cc)
    if not options.cc:
        parser.error("A C compiler is required for the allocation probe")
    backends = (options.backend or "c," + host["physical_architecture"]).split(",")
    if any(backend not in ("hand-c", "c", host["physical_architecture"]) for backend in backends):
        parser.error("Select hand-c, c or the physical host native backend")
    backends = list(dict.fromkeys(backends))
    options.output.mkdir(parents=True, exist_ok=True)
    for name in ("results.json", "results.md"):
        (options.output / name).unlink(missing_ok=True)
    env = dict(os.environ, CC=options.cc)
    expected = Json.expectedWorkload(options.records)
    inputs = [options.compiler, Root / "benchmarks/json_parser.nifty",
              Root / "benchmarks/json_document.nifty"]
    if "hand-c" in backends:
        inputs += [Root / "benchmarks/json_parser_straight.c", Root / "benchmarks/json_document_hand.c"]
    inputs += [Root / "lib" / name for name in Json.LibraryNames]
    fingerprints = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    variants = [build(options, model, backend, host, env)
                for backend in backends for model in ("tree", "document")]
    rounds = []
    for index in range(options.warmups + options.samples):
        offset = index % len(variants)
        ordered = variants[offset:] + variants[:offset]
        rounds.append([result["model"] + "/" + result["backend"] for result in ordered])
        for result in ordered:
            response, wall = Ray.runCommand(result["execution_command"], options.timeout, env)
            if response.stderr:
                raise Ray.BenchmarkError(response.stderr.decode("utf-8", "replace"))
            data = response.stdout.replace(b"\r\n", b"\n") if result["backend"] == "hand-c" else response.stdout
            parsed = Json.parseOutput(data, options.records, options.repeat, expected)
            parsed["wall_ns"] = wall
            result["warmups" if index < options.warmups else "samples"].append(parsed)
    for result in variants:
        result["timing"] = Ray.summarize([sample["elapsed_ns"] / options.repeat for sample in result["samples"]])
    counters = {model: allocations(options, model, host, env, expected) for model in ("tree", "document")}
    if any(hashlib.sha256(path.read_bytes()).hexdigest() != digest for path, digest in fingerprints.items()):
        raise Ray.BenchmarkError("Compiler or input sources changed during the comparison")
    report = dict(schema="nifty-json-document-comparison-v1", machine=host,
                  records=options.records, repeat=options.repeat, samples=options.samples,
                  warmups=options.warmups, opt=options.opt, input_bytes=expected["input_bytes"],
                  input_sha256=expected["input_sha256"], checksum=expected["checksum"],
                  compiler_sha256=hashlib.sha256(options.compiler.read_bytes()).hexdigest(),
                  compiler=str(options.compiler), cc=Ray.optionalCommand([options.cc, "--version"]),
                  source_sha256={str(path.relative_to(Root)): hashlib.sha256(path.read_bytes()).hexdigest()
                                 for path in [Root / "lib" / name for name in Json.LibraryNames]},
                  timing_scope=Json.TimingScope, sample_order=rounds, results=variants, allocations=counters)
    (options.output / "input.json").write_bytes(expected["input"])
    (options.output / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
    text = markdown(report)
    (options.output / "results.md").write_text(text, encoding="utf-8", newline="\n")
    print(text)
    return report


if __name__ == "__main__":
    try:
        main()
    except Ray.BenchmarkError as error:
        print("json comparison: " + str(error), file=sys.stderr)
        raise SystemExit(1)

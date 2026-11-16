#!/usr/bin/env python3
"""Benchmark a hardcoded line-only A with even-odd, 4x4 coverage filling."""
import argparse
from array import array
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time

import run as Bench

Root = Path(__file__).resolve().parent.parent
TimingScope = ("Each timed fill clears a reused coverage buffer, intersects and sorts "
               "line edges, fills even-odd spans at 4x4 sample centers, and reads every "
               "pixel into a position-weighted checksum. Sixteen quarter-pixel translations "
               "cycle through the workload. Outline setup, allocation, process startup, "
               "exact pixel validation, and image/text output are outside the timer.")
Contours = (
    ((4, 60), (25, 4), (39, 4), (60, 60), (47, 60), (42, 46), (22, 46), (17, 60)),
    ((26, 35), (32, 17), (38, 35)),
)
WindowsClock = '''extern "kernel32":
  proc QueryPerformanceCounter(value: var int64): int32
  proc QueryPerformanceFrequency(value: var int64): int32

proc pathBenchmarkClock(value: var Timespec): int32 =
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
'''


def reference(size):
    """Independent point-in-polygon oracle, without sorted intersections or spans."""
    subsize = size * 4
    stride = subsize + 1
    prefix = array("I", [0]) * (stride * stride)
    edges = []
    for contour in Contours:
        for a, b in zip(contour, contour[1:] + contour[:1]):
            if a[1] == b[1]:
                continue
            if a[1] > b[1]:
                a, b = b, a
            edges.append((a[0] * size, a[1] * size,
                          (b[0] - a[0]) * size, (b[1] - a[1]) * size))
    for y in range(subsize):
        py = y * 16 + 8
        active = [edge for edge in edges if edge[1] <= py < edge[1] + edge[3]]
        row_sum = 0
        previous, current = y * stride, (y + 1) * stride
        for x in range(subsize):
            px = x * 16 + 8
            inside = False
            for ex, ey, dx, dy in active:
                if (ex - px) * dy + (py - ey) * dx > 0:
                    inside = not inside
            row_sum += inside
            prefix[current + x + 1] = prefix[previous + x + 1] + row_sum
    masks = []
    for phase in range(16):
        shift_x, shift_y = phase % 4, phase // 4
        mask = bytearray()
        for y in range(size):
            top = max(0, y * 4 - shift_y) * stride
            bottom = (y * 4 + 4 - shift_y) * stride
            for x in range(size):
                left, right = max(0, x * 4 - shift_x), x * 4 + 4 - shift_x
                mask.append(prefix[bottom + right] - prefix[top + right] -
                            prefix[bottom + left] + prefix[top + left])
        masks.append(bytes(mask))
    return masks


def configuredSource(text, size, repeat, system, backend):
    for name, number in (("ImageSize", size), ("Repetitions", repeat),
                         ("ClockId", 1 if backend == "wasm64" else getattr(time, "CLOCK_MONOTONIC", 1))):
        text, count = re.subn(rf"(?m)^const {name} = [0-9]+$", f"const {name} = {number}", text)
        if count != 1:
            raise Bench.BenchmarkError("Expected unique constant: " + name)
    if system == "Windows" and backend != "wasm64":
        old = 'extern "libc":\n  proc clock_gettime(clock: int32, value: var Timespec): int32'
        if text.count(old) != 1:
            raise Bench.BenchmarkError("Expected one POSIX clock declaration")
        text = text.replace(old, WindowsClock)
        text = text.replace("clock_gettime(ClockId,", "pathBenchmarkClock(")
    return text


def build(backend, options, host, env):
    directory = options.output / "build" / f"{options.size}-r{options.repeat}" / backend
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / ("path_fill.c" if backend == "hand-c" else "path_fill.nifty")
    original = Root / "benchmarks" / ("path_fill_hand.c" if backend == "hand-c" else "path_fill.nifty")
    text = original.read_text(encoding="utf-8")
    if backend != "hand-c":
        text = configuredSource(text, options.size, options.repeat, host["system"], backend)
    source.write_text(text, encoding="utf-8", newline="\n")
    result = dict(backend=backend, source=str(source),
                  source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), samples=[])
    if backend == "interp":
        return dict(result, compile_wall_ns=None, build_command=None, executable_sha256=None,
                    execution_command=Bench.executionCommand(backend, source, host, env,
                                                            options.compiler, options.opt))
    executable = directory / ("path_fill.wasm" if backend == "wasm64" else
                              "path_fill.exe" if host["system"] == "Windows" else "path_fill")
    executable.unlink(missing_ok=True)
    if backend == "hand-c":
        command = [options.cc] + Bench.StraightCFlags + [
            f"-DIMAGE_SIZE={options.size}", f"-DREPETITIONS={options.repeat}",
            f"-DCLOCK_ID={getattr(time, 'CLOCK_MONOTONIC', 1)}", str(source), "-o", str(executable)]
        if host["system"] == "Windows":
            command.append("-static")
    else:
        command = [str(options.compiler), "build", str(source), "--backend:" + backend,
                   "--opt:" + options.opt, "-o", str(executable)]
    response, elapsed = Bench.runCommand(command, options.timeout, env)
    (directory / "build.stdout").write_bytes(response.stdout)
    (directory / "build.stderr").write_bytes(response.stderr)
    print(f"Built {backend} in {elapsed / 1e9:.3f}s", flush=True)
    execution_backend = host["physical_architecture"] if backend in ("hand-c", "c") else backend
    return dict(result, compile_wall_ns=elapsed, build_command=command,
                executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                execution_command=Bench.executionCommand(execution_backend, executable, host, env))


def parseOutput(output, size, repeat, masks, checksums):
    output = output.replace(b"\r\n", b"\n")
    if len(output) > 16 * size * size + repeat * 80 + 4096 or not output.endswith(b"\n"):
        raise Bench.BenchmarkError("Invalid path-fill output size or framing")
    lines = output.splitlines()
    if len(lines) != 8 + repeat + 16 or lines[0] != b"NIFTY_PATH_FILL_V1":
        raise Bench.BenchmarkError("Incomplete path-fill protocol")
    fields = {}
    for line, name in zip(lines[1:7], ("size", "repeat", "start_sec", "start_nsec", "end_sec", "end_nsec")):
        match = re.fullmatch(name.encode() + rb" (0|[1-9][0-9]{0,18})", line)
        if not match:
            raise Bench.BenchmarkError("Invalid path-fill field: " + name)
        fields[name] = int(match[1])
    if fields["size"] != size or fields["repeat"] != repeat or lines[7] != b"clock_status 0 0":
        raise Bench.BenchmarkError("Path-fill workload or clock failure")
    elapsed = ((fields["end_sec"] - fields["start_sec"]) * 1000000000 +
               fields["end_nsec"] - fields["start_nsec"])
    if elapsed <= 0 or fields["start_nsec"] >= 1000000000 or fields["end_nsec"] >= 1000000000:
        raise Bench.BenchmarkError("Invalid path-fill monotonic interval")
    for index, line in enumerate(lines[8:8 + repeat]):
        if line != f"fill_checksum {index} {checksums[index % 16]}".encode():
            raise Bench.BenchmarkError(f"Fill checksum mismatch at repetition {index}")
    for phase, line in enumerate(lines[8 + repeat:]):
        expected = f"coverage {phase} ".encode() + bytes(value + 97 for value in masks[phase])
        if line != expected:
            raise Bench.BenchmarkError(f"Exact coverage differs from point-in-polygon oracle at phase {phase}")
    return dict(elapsed_ns=elapsed, ns_per_fill=elapsed / repeat, clock_fields=fields)


def markdown(report):
    lines = ["# Line-only A path filling", "",
             f"{report['machine']['system']} {report['machine']['physical_architecture']}; "
             f"{report['size']} x {report['size']} pixels, 11 line segments, two contours, even-odd fill, 4x4 sampling.", "",
             TimingScope, "",
             f"{report['samples']} samples, {report['warmups']} warmups, {report['repeat']} fills per process. "
             f"Native optimization: {report['opt']}; C: -O2.", "",
             "| Backend | Build (ms) | Median (us/fill) | Min (us) | Max (us) | Fills/s |",
             "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for result in report["results"]:
        timing = result["timing"]
        backend = result["backend"]
        label = {"hand-c": "Hand C", "c": "Nifty C", "interp": "Interpreter", "wasm64": "WASM64"}.get(backend, backend.upper())
        if backend == "amd64" and report["machine"]["physical_architecture"] == "arm64":
            label += " (Rosetta translated)"
        lines.append(f"| {label} | {Bench.compileMilliseconds(result['compile_wall_ns'])} | "
                     f"{timing['median']/1000:.3f} | {timing['min']/1000:.3f} | "
                     f"{timing['max']/1000:.3f} | {1e9/timing['median']:.0f} |")
    lines += ["", "Every coverage value in all 16 phases matches an independent integer point-in-polygon oracle; "
              "every timed fill matches its phase checksum.",
              "This measures one small fixed outline, not curves, font loading, shaping, stroking, or GPU rendering.", ""]
    return "\n".join(lines)


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", help="comma-separated hand-c,c,amd64,arm64,wasm64,interp")
    parser.add_argument("--size", type=int, default=128)
    parser.add_argument("--repeat", type=int, default=256)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--opt", choices=("none", "speed"), default="speed")
    parser.add_argument("--compiler", type=Path, default=Root / ("nifty.exe" if os.name == "nt" else "nifty"))
    parser.add_argument("--cc", default=os.environ.get("CC", "gcc" if os.name == "nt" else "cc"))
    parser.add_argument("--output", type=Path, default=Root / "benchmarks/output/path-fill")
    parser.add_argument("--timeout", type=float, default=300)
    options = parser.parse_args(arguments)
    for name, low, high in (("size", 16, 512), ("repeat", 1, 10000), ("samples", 1, 1000), ("warmups", 0, 1000)):
        if not low <= getattr(options, name) <= high:
            parser.error(f"--{name} must be in {low}..{high}")
    if not 0 < options.timeout <= 3600:
        parser.error("--timeout must be in (0,3600]")
    host = Bench.hostInfo()
    if host["system"] not in ("Windows", "Darwin", "Linux"):
        parser.error("Unsupported host")
    options.compiler = options.compiler.expanduser().resolve()
    options.output = options.output.expanduser().resolve()
    options.cc = shutil.which(options.cc)
    backends = list(dict.fromkeys((options.backend or "hand-c,c," + host["physical_architecture"]).split(",")))
    if any(backend not in ("hand-c",) + Bench.Backends for backend in backends):
        parser.error("Unknown backend")
    for backend in backends:
        if backend in ("arm64", "amd64") and backend != host["physical_architecture"] and not (
                backend == "amd64" and host["rosetta_available"]):
            parser.error("Native backend cannot execute on this host: " + backend)
    if any(backend != "hand-c" for backend in backends) and not options.compiler.is_file():
        parser.error("Build the Nifty compiler first")
    if any(backend in ("hand-c", "c") for backend in backends) and not options.cc:
        parser.error("A C compiler is required")
    if "wasm64" in backends and not Bench.wasmtimeExecutable():
        parser.error("wasm64 requires Wasmtime; set NIFTY_WASMTIME")
    options.output.mkdir(parents=True, exist_ok=True)
    for name in ("results.json", "results.md", "path_fill.png"):
        (options.output / name).unlink(missing_ok=True)
    inputs = [Root / "benchmarks/path_fill.nifty", Root / "benchmarks/path_fill_hand.c"]
    if any(backend != "hand-c" for backend in backends):
        inputs.append(options.compiler)
    fingerprints = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    print(f"Checking independent coverage oracle at {options.size} x {options.size}...", flush=True)
    masks = reference(options.size)
    checksums = [sum(value * (index + 1) for index, value in enumerate(mask)) for mask in masks]
    env = dict(os.environ)
    if options.cc:
        env["CC"] = options.cc
    results = [build(backend, options, host, env) for backend in backends]
    order = []
    for index in range(options.warmups + options.samples):
        offset = index % len(results)
        rotated = results[offset:] + results[:offset]
        order.append([result["backend"] for result in rotated])
        for result in rotated:
            response, wall = Bench.runCommand(result["execution_command"], options.timeout, env)
            if response.stderr:
                raise Bench.BenchmarkError(response.stderr.decode("utf-8", "replace"))
            sample = parseOutput(response.stdout, options.size, options.repeat, masks, checksums)
            if index >= options.warmups:
                result["samples"].append(dict(sample, process_wall_ns=wall))
    for result in results:
        result["timing"] = Bench.summarize([sample["ns_per_fill"] for sample in result["samples"]])
    if any(hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest for path, digest in fingerprints.items()):
        raise Bench.BenchmarkError("Input sources or compiler changed during the benchmark")
    report = dict(schema="nifty-path-fill-v1", machine=host, size=options.size, repeat=options.repeat,
                  samples=options.samples, warmups=options.warmups, opt=options.opt, timing_scope=TimingScope,
                  source_sha256=fingerprints, phase_checksums=checksums,
                  coverage_sha256=[hashlib.sha256(mask).hexdigest() for mask in masks],
                  cc=Bench.optionalCommand([options.cc, "--version"]) if options.cc else None,
                  sample_order=order, results=results)
    # Black glyph on white; PNG conversion is outside all measured processes.
    rgb = bytes(channel for coverage in masks[0] for channel in [255 - (coverage * 255 + 8) // 16] * 3)
    Bench.writePng(options.output / "path_fill.png", options.size, rgb)
    text = markdown(report)
    (options.output / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
    (options.output / "results.md").write_text(text, encoding="utf-8", newline="\n")
    print(text)
    return report


if __name__ == "__main__":
    try:
        main()
    except Bench.BenchmarkError as error:
        print("path-fill benchmark: " + str(error), file=sys.stderr)
        raise SystemExit(1)

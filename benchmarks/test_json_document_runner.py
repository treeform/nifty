#!/usr/bin/env python3
"""Check portable clocks, backend dispatch, and document comparison output."""
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import struct
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

Root = Path(__file__).resolve().parent.parent
Spec = importlib.util.spec_from_file_location("comparison", Root / "benchmarks/compare_json_documents.py")
Compare = importlib.util.module_from_spec(Spec)
Spec.loader.exec_module(Compare)


def expectError(action, exception=Compare.Ray.BenchmarkError):
    """Require invalid artifacts and benchmark output to be rejected."""
    try:
        action()
    except exception:
        return
    raise AssertionError("Invalid benchmark data was accepted")


def nativeImage(architecture):
    """Provide a minimal native header for architecture inspection."""
    machine = {"arm64": 0x0100000c, "amd64": 0x01000007}[architecture]
    return b"\xcf\xfa\xed\xfe" + struct.pack("<I", machine)


def wasmImage():
    """Provide a bounded memory64 module for architecture inspection."""
    return b"\0asm\x01\0\0\0\x05\x04\x01\x05\x01\x01"


def response(records=1, repeat=2):
    """Construct an oracle-checked response with a positive elapsed interval."""
    expected = Compare.Json.expectedWorkload(records)
    checksum = expected["checksum"]
    lines = ["NIFTY_JSON_V1", f"records {records}", f"repeat {repeat}",
             f"input_bytes {expected['input_bytes']}", "start_sec 10",
             "start_nsec 0", "end_sec 10", "end_nsec 1000",
             "clock_status 0 0", f"successes {repeat}"]
    lines += [f"parse_checksum {index} {checksum}" for index in range(repeat)]
    lines += [f"batch_checksum {checksum * repeat}"]
    return ("\n".join(lines) + "\n").encode()


def testSource():
    """Select host clocks for native code and the WASI clock for memory64."""
    for model, name in (("tree", "json_parser.nifty"), ("document", "json_document.nifty")):
        source = (Root / "benchmarks" / name).read_text(encoding="utf-8")
        for system in ("Windows", "Linux", "Darwin"):
            changed = Compare.prepareSource(source, model, 3, 2, system)
            assert "const Records = 3\n" in changed
            assert "const Repetitions = 2\n" in changed
            assert "../lib/" not in changed
            if system == "Windows":
                assert "clock_gettime" not in changed
                assert "QueryPerformanceCounter" in changed
                assert "jsonBenchmarkClock(started)" in changed
            else:
                assert "clock_gettime(ClockId, started)" in changed
                assert "QueryPerformanceCounter" not in changed
        with patch.object(Compare.time, "CLOCK_MONOTONIC", 6, create=True):
            for system in ("Windows", "Darwin", "Linux"):
                changed = Compare.prepareSource(
                    source, model, 3, 2, system, backend="wasm64")
                assert "const ClockId = 1\n" in changed
                assert 'extern "libc":' in changed
                assert "clock_gettime(ClockId, started)" in changed
                assert "clock_gettime(ClockId, finished)" in changed
                assert "QueryPerformanceCounter" not in changed
            native = Compare.prepareSource(
                source, model, 3, 2, "Darwin", backend="interp")
            assert "const ClockId = 6\n" in native
        counter = Compare.prepareSource(source, model, 3, 1, "Windows", allocations=True)
        assert counter.count("  jsonAllocationStart()\n") == 1
        assert counter.count("  jsonAllocationFinish()\n") == 1
        assert counter.index("input.add(") < counter.index("  jsonAllocationStart()\n")
        assert counter.index("parseAndConsume(input)\n") < counter.index("  jsonAllocationFinish()\n")
    expectError(lambda: Compare.prepareSource("", "tree", 1, 1, "Windows"))


def testBuild():
    """Inspect translated, memory64, and interpreter execution commands."""
    host = {"system": "Darwin", "physical_architecture": "arm64",
            "rosetta_available": True}
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        compiler = directory / "nifty"
        compiler.write_bytes(nativeImage("arm64"))
        options = SimpleNamespace(output=directory, compiler=compiler,
                                  records=1, repeat=2, timeout=1, opt="none", cc="cc")
        commands = []
        invalid = None

        def compileArtifact(command, timeout, env):
            """Capture compilation and synthesize the requested architecture."""
            commands.append(command)
            artifact = wasmImage() if "--backend:wasm64" in command else nativeImage("amd64")
            Path(command[-1]).write_bytes(artifact if invalid is None else invalid)
            return SimpleNamespace(stdout=b"compiled", stderr=b""), 123

        with patch.object(Compare.Ray, "runCommand", side_effect=compileArtifact), \
             patch.object(Compare.Ray, "wasmtimeExecutable", return_value="/test/wasmtime"), \
             redirect_stdout(io.StringIO()):
            for model in ("tree", "document"):
                for backend in ("amd64", "wasm64", "interp"):
                    before = len(commands)
                    result = Compare.build(options, model, backend, host, {})
                    source = directory / "build" / model / backend / "benchmark.nifty"
                    assert result["source_sha256"] == hashlib.sha256(source.read_bytes()).hexdigest()
                    if backend == "interp":
                        assert len(commands) == before
                        assert result["build_command"] is None
                        assert result["compile_wall_ns"] is None
                        assert result["executable"] is None
                        assert result["executable_sha256"] is None
                        assert result["execution_architecture"] == "arm64"
                        assert result["label"] == "Interpreter (IR)"
                        assert result["execution_command"] == [
                            str(compiler), "interpret", str(source), "--opt:none"]
                        assert not (source.parent / "build.stdout").exists()
                    else:
                        assert len(commands) == before + 1
                        assert result["compile_wall_ns"] == 123
                        assert result["execution_architecture"] == backend
                        assert result["build_command"] == commands[-1]
                        executable = Path(result["executable"])
                        assert result["executable_sha256"] == hashlib.sha256(executable.read_bytes()).hexdigest()
                        if backend == "wasm64":
                            assert executable.suffix == ".wasm"
                            assert result["label"] == "WASM64 (Wasmtime WASI)"
                            assert result["execution_command"] == [
                                "/test/wasmtime", "run", "-W", "memory64=y", str(executable)]
                            assert "const ClockId = 1\n" in source.read_text()
                        else:
                            assert "Rosetta translated" in result["label"]
                            assert result["execution_command"] == [
                                "/usr/bin/arch", "-x86_64", str(executable)]
            for backend, invalid in (("amd64", nativeImage("arm64")),
                                     ("wasm64", nativeImage("amd64")),
                                     ("c", wasmImage()), ("hand-c", wasmImage()),
                                     ("arm64", b"not an executable")):
                expectError(lambda: Compare.build(options, "document", backend, host, {}))


def testBackendReport():
    """Validate added backends through the CLI and refuse corrupt warmups."""
    host = {"system": "Darwin", "physical_architecture": "arm64",
            "rosetta_available": True}
    engine = {"path": "/test/wasmtime", "version": "test engine", "sha256": "test hash"}
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        compiler = directory / "nifty"
        compiler.write_bytes(nativeImage("arm64"))
        compiler.chmod(0o755)
        output = directory / "output"
        arguments = ["--model", "both", "--backend", "amd64,wasm64,interp",
                     "--records", "1", "--repeat", "2", "--samples", "5",
                     "--compiler", str(compiler), "--output", str(output)]
        valid = response()
        emitted = valid
        executed = []

        def execute(command, timeout, env):
            """Compile synthetic artifacts and return deterministic protocol data."""
            if command[1] == "build":
                artifact = wasmImage() if "--backend:wasm64" in command else nativeImage("amd64")
                Path(command[-1]).write_bytes(artifact)
                return SimpleNamespace(stdout=b"", stderr=b""), 100
            executed.append(command)
            return SimpleNamespace(stdout=emitted, stderr=b""), 2000

        with patch.object(Compare.Ray, "hostInfo", return_value=host), \
             patch.object(Compare.shutil, "which", return_value=str(compiler)), \
             patch.object(Compare.Ray, "wasmtimeExecutable", return_value=engine["path"]), \
             patch.object(Compare.Ray, "engineMetadata", return_value=engine), \
             patch.object(Compare.Ray, "optionalCommand", return_value="test compiler interpret"), \
             patch.object(Compare.Ray, "runCommand", side_effect=execute), \
             patch.object(Compare, "allocations", return_value={"calls": 1, "requested_bytes": 2}), \
             redirect_stdout(io.StringIO()):
            report = Compare.main(arguments)
            assert len(executed) == 36
            assert len(report["results"]) == 6
            assert report["wasm_engine"] == engine
            expected = Compare.Json.expectedWorkload(1)
            for result in report["results"]:
                assert len(result["samples"]) == 5 and len(result["warmups"]) == 1
                assert result["execution_command"] in executed
                for sample in result["samples"] + result["warmups"]:
                    assert sample["checksums"] == [expected["checksum"]] * 2
            saved = json.loads((output / "results.json").read_text())
            assert saved == report
            text = (output / "results.md").read_text()
            assert "Interpreter (IR) | N/A" in text
            assert "Rosetta translated" in text and "WASM64 (Wasmtime WASI)" in text
            assert "IR preparation" in text and "before the workload timer" in text
            emitted = valid.replace(b"successes 2", b"successes 1")
            expectError(lambda: Compare.main(arguments))
            assert not (output / "results.json").exists()
            assert not (output / "results.md").exists()


def testUnavailableBackends():
    """Reject unavailable execution targets before compiling any workload."""
    with tempfile.TemporaryDirectory() as temporary:
        compiler = Path(temporary) / "nifty"
        compiler.write_bytes(nativeImage("arm64"))
        host = {"system": "Darwin", "physical_architecture": "arm64",
                "rosetta_available": False}
        with patch.object(Compare.Ray, "hostInfo", return_value=host), \
             patch.object(Compare.shutil, "which", return_value=str(compiler)), \
             patch.object(Compare.Ray, "wasmtimeExecutable", return_value=None), \
             patch.object(Compare, "build", side_effect=AssertionError("Unexpected build")), \
             redirect_stderr(io.StringIO()):
            for backend in ("amd64", "wasm64", "unknown"):
                expectError(lambda: Compare.main([
                    "--backend", backend, "--compiler", str(compiler)]), SystemExit)
            host.update(system="Linux", rosetta_available=True)
            expectError(lambda: Compare.main([
                "--backend", "amd64", "--compiler", str(compiler)]), SystemExit)


def testWindowsArtifacts():
    """Recognize PE32+ targets and reject truncated or invalid PE headers."""
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "benchmark.exe"
        for architecture, machine in (("amd64", 0x8664), ("arm64", 0xaa64)):
            for offset in (64, 5000):
                data = bytearray(offset + 26)
                data[:2] = b"MZ"
                struct.pack_into("<I", data, 60, offset)
                data[offset:offset + 4] = b"PE\0\0"
                struct.pack_into("<H", data, offset + 4, machine)
                data[offset + 24:] = b"\x0b\x02"
                path.write_bytes(data)
                host = {"system": "Windows", "physical_architecture": architecture}
                assert Compare.artifactArchitecture(path, "c", host) == architecture
                path.write_bytes(data[:-1])
                expectError(lambda: Compare.artifactArchitecture(path, "c", host))
                data[offset + 24:] = b"\x0b\x01"
                path.write_bytes(data)
                expectError(lambda: Compare.artifactArchitecture(path, "c", host))


def testAddedBackends():
    """Run each available added backend once per model against the JSON oracle."""
    compiler = Root / ("nifty.exe" if Compare.os.name == "nt" else "nifty")
    if not compiler.is_file():
        print("SKIP added JSON backends: compiler unavailable")
        return
    host = Compare.Ray.hostInfo()
    available = Compare.Ray.availableBackends(host, compiler, includeWasm=True)
    selected = [backend for backend in ("amd64", "wasm64", "interp") if backend in available]
    if not selected:
        print("SKIP added JSON backends: runtimes unavailable")
        return
    expected = Compare.Json.expectedWorkload(1)
    with tempfile.TemporaryDirectory(prefix="nifty-json-document-backends-") as temporary:
        options = SimpleNamespace(output=Path(temporary), compiler=compiler,
                                  records=1, repeat=2, timeout=120, opt="speed")
        env = dict(Compare.os.environ)
        for backend in selected:
            for model in ("tree", "document"):
                result = Compare.build(options, model, backend, host, env)
                process, _ = Compare.Ray.runCommand(result["execution_command"], options.timeout, env)
                assert not process.stderr
                parsed = Compare.Json.parseOutput(process.stdout, 1, 2, expected)
                assert parsed["checksums"] == [expected["checksum"]] * 2


def testComparison():
    """Preserve the existing C comparison and allocation report checks."""
    compiler = Root / ("nifty.exe" if Compare.os.name == "nt" else "nifty")
    cc = shutil.which("gcc") or shutil.which("cc")
    if not compiler.is_file() or not cc:
        print("SKIP real JSON comparison: compiler or C toolchain unavailable")
        return
    with tempfile.TemporaryDirectory(prefix="nifty-json-document-runner-") as temporary:
        output = Path(temporary)
        report = Compare.main(["--model", "both", "--backend", "c", "--records", "2", "--repeat", "2",
                               "--samples", "5", "--compiler", str(compiler), "--cc", cc,
                               "--output", str(output)])
        expected = Compare.Json.expectedWorkload(2)
        assert report["checksum"] == expected["checksum"]
        assert len(report["results"]) == 2
        for result in report["results"]:
            assert len(result["samples"]) == 5 and len(result["warmups"]) == 1
            assert result["timing"]["median"] > 0
            assert result["compile_wall_ns"] > 0
            assert result["executable_sha256"]
        assert report["sample_order"][0] != report["sample_order"][1]
        assert report["allocations"]["document"]["calls"] < report["allocations"]["tree"]["calls"]
        saved = json.loads((output / "results.json").read_text(encoding="utf-8"))
        assert saved["checksum"] == expected["checksum"]
        assert (output / "input.json").read_bytes() == expected["input"]
        assert "not peak live memory" in (output / "results.md").read_text(encoding="utf-8")


if __name__ == "__main__":
    testSource()
    testBuild()
    testBackendReport()
    testUnavailableBackends()
    testWindowsArtifacts()
    testAddedBackends()
    testComparison()
    print("JSON document source, clocks, backends, oracle and reports passed")

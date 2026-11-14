#!/usr/bin/env python3
"""Check comparison fairness and fail-closed validation without timing renders."""

from contextlib import redirect_stderr
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

Root = Path(__file__).resolve().parent.parent
Spec = importlib.util.spec_from_file_location("comparison", Root / "tools/compare_backends.py")
Comparison = importlib.util.module_from_spec(Spec)
Spec.loader.exec_module(Comparison)


def response(red=1):
  """Produce a strict single-pixel renderer response with one-nanosecond time."""
  return (f"NIFTY_RAY_V1\nsize 1\nrepeat 1\nstart_sec 10\nstart_nsec 0\n"
          f"end_sec 10\nend_nsec 1\nclock_status 0 0\nchecksum {red}\n"
          f"batch_checksum {red}\nrgb {red} 0 0\n").encode()


def expectError(action):
  """Require a validation failure for inconsistent or unavailable evidence."""
  try:
    action()
  except Comparison.Ray.BenchmarkError:
    return
  raise AssertionError("Invalid comparison evidence was accepted")


def fakeBuild(variant, architecture, compiler, *unused):
  """Provide the fields needed to validate ordering without invoking compilers."""
  label = f"{variant}-{architecture}"
  return {"label": label, "execution_command": [label],
          "render_ns_per_frame": [], "process_wall_ns": [], "clock_fields": []}


def testArchitecture():
  """Give both C and native AMD64 the same explicit Rosetta invocation."""
  host = {"system": "Darwin", "physical_architecture": "arm64"}
  command = Comparison.cCommand("/usr/bin/cc", "amd64", host, "source.c", "binary")
  assert command == (["/usr/bin/cc"] + Comparison.CFlags +
                     ["-arch", "x86_64", "-o", "binary", "source.c", "-lm"])
  assert Comparison.executionCommand("binary", "amd64", host) == [
    "/usr/bin/arch", "-x86_64", "binary"]
  assert Comparison.executionCommand("binary", "arm64", host) == ["binary"]
  host["system"] = "Linux"
  expectError(lambda: Comparison.cCommand("cc", "amd64", host, "s.c", "binary"))


def testMeasurements():
  """Rotate every sample and reject an incorrect image after valid warmups."""
  variants = [("baseline", "arm64", None), ("candidate", "arm64", None),
              ("c", "arm64", None), ("c-straight", "arm64", None)]
  with tempfile.TemporaryDirectory() as directory:
    options = SimpleNamespace(output=Path(directory), timeout=1)
    with patch.object(Comparison, "build", side_effect=fakeBuild), patch.object(
        Comparison.Ray, "loadReference", return_value=bytes((1, 0, 0))):
      with patch.object(Comparison.Ray, "runCommand", return_value=(
          SimpleNamespace(stdout=response(), stderr=b""), 10)) as command:
        result = Comparison.measure(1, 1, options, {}, variants, 1, 5)
        assert command.call_count == 24
      assert result["independent_sha256"] == result["pixel_sha256"]
      assert "fresh process" in result["render_timing_scope"]
      assert "first-use" in result["render_timing_scope"]
      labels = ["baseline-arm64", "candidate-arm64", "c-arm64",
                "c-straight-arm64"]
      assert result["round_order"] == [
        labels[index % 4:] + labels[:index % 4] for index in range(6)]
      for variant in result["variants"]:
        assert variant["render_ns_per_frame"]["samples"] == [1] * 5
        assert variant["process_wall_ns"]["samples"] == [10] * 5
      responses = [(SimpleNamespace(stdout=response(), stderr=b""), 10)] * 4
      responses.append((SimpleNamespace(stdout=response(2), stderr=b""), 10))
      with patch.object(Comparison.Ray, "runCommand", side_effect=responses):
        expectError(lambda: Comparison.measure(1, 1, options, {}, variants, 1, 5))
    with patch.object(Comparison, "build", side_effect=fakeBuild), patch.object(
        Comparison.Ray, "loadReference", return_value=None):
      expectError(lambda: Comparison.measure(64, 1, options, {}, variants, 1, 5))


def testCCompiler():
  """Select and fingerprint a separate C emitter without running renderers."""
  with tempfile.TemporaryDirectory() as directory:
    root = Path(directory).resolve()
    baseline, candidate, emitter = [root / name for name in
                                    ("baseline", "candidate", "emitter")]
    for compiler in (baseline, candidate, emitter):
      compiler.write_text(compiler.name)
      compiler.chmod(0o700)
    straight = root / "straight.c"
    straight.write_text("int main(void) { return 0; }\n")
    arguments = ["--baseline", str(baseline), "--candidate", str(candidate),
                 "--output", str(root / "results"), "--size", "1",
                 "--straight-c-source", str(straight)]
    with patch.object(Comparison.shutil, "which", return_value=__file__):
      defaults = Comparison.parseArguments(arguments)
      assert defaults.c_compiler == baseline
      assert defaults.straight_c_source == straight
      selected = Comparison.parseArguments(arguments + ["--c-compiler", str(emitter)])
      assert selected.c_compiler == emitter
      invalidPaths = [root / "missing", root / "directory"]
      invalidPaths[1].mkdir()
      # Windows does not implement POSIX executable permission bits.
      if Comparison.os.name != "nt":
        notExecutable = root / "not-executable"
        notExecutable.write_text("invalid")
        notExecutable.chmod(0o600)
        invalidPaths.append(notExecutable)
      for invalid in invalidPaths:
        with redirect_stderr(io.StringIO()):
          try:
            Comparison.parseArguments(arguments + ["--c-compiler", str(invalid)])
          except SystemExit as error:
            assert error.code == 2
          else:
            raise AssertionError("Invalid C emitter was accepted")

    def measured(size, repeat, options, host, variants, *unused):
      """Inspect compiler routing while replacing every timed workload."""
      assert variants == [("baseline", "arm64", baseline),
                          ("candidate", "arm64", candidate),
                          ("c", "arm64", options.c_compiler),
                          ("c-straight", "arm64", Path(options.cc))]
      return {"size": size, "repeat": repeat, "correctness": "mock", "variants": []}

    with patch.object(Comparison.Ray, "hostInfo", return_value={
        "physical_architecture": "arm64"}), patch.object(
        Comparison.Ray, "availableBackends", return_value=["arm64"]), patch.object(
        Comparison.Ray, "optionalCommand", return_value="cc"), patch.object(
        Comparison, "measure", side_effect=measured):
      for options in (defaults, selected):
        with patch.object(Comparison, "parseArguments", return_value=options), patch(
            "builtins.print"):
          assert Comparison.main() == 0
        report = json.loads((options.output / "results.json").read_text())
        assert report["inputs_sha256"][str(options.c_compiler)] == (
          Comparison.sha256(options.c_compiler))

      assert report["inputs_sha256"][str(selected.straight_c_source)] == (
        Comparison.sha256(selected.straight_c_source))

      for changedPath in (emitter, selected.straight_c_source):
        def changed(*args):
          """Mutate each independently fingerprinted input during measurement."""
          result = measured(*args)
          changedPath.write_text("changed")
          return result

        with patch.object(Comparison, "parseArguments", return_value=selected), patch.object(
            Comparison, "measure", side_effect=changed):
          expectError(Comparison.main)
        assert not (selected.output / "results.json").exists()


def testStraightBuild():
  """Compile standalone C directly with architecture-matched flags and identity."""
  with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    source = root / "straight.c"
    source.write_text("int main(void) { return 0; }\n")
    cc = root / "cc"
    cc.write_text("C compiler identity")
    options = SimpleNamespace(output=root, straight_c_source=source,
                              cc=str(cc), timeout=1)
    host = {"system": "Darwin", "physical_architecture": "arm64"}
    def compiled(command, *unused):
      """Simulate a C compiler creating its requested binary."""
      Path(command[command.index("-o") + 1]).write_bytes(b"binary")
      return SimpleNamespace(stdout=b"", stderr=b""), 1
    with patch.object(Comparison.Ray, "runCommand", side_effect=compiled) as run, patch.object(
        Comparison.Ray, "binaryArchitectures", return_value=["amd64"]), patch.object(
        Comparison, "compilerEnvironment", side_effect=AssertionError("Nifty invoked")), patch.object(
        Comparison.time, "CLOCK_MONOTONIC", 6, create=True):
      result = Comparison.build("c-straight", "amd64", None, 16, 3, options, host)
    assert run.call_count == 1
    command = result["compile_commands"][0]
    assert command == ([str(cc), "-DIMAGE_SIZE=16", "-DREPETITIONS=3",
                        "-DCLOCK_ID=6", "-DEMIT_PIXELS=1"] +
                       Comparison.CFlags + ["-arch", "x86_64", "-o",
                       result["executable"], result["source"], "-lm"])
    assert result["compiler"] == str(cc)
    assert result["compiler_sha256"] == Comparison.sha256(cc)
    assert Path(result["source"]).read_bytes() == source.read_bytes()
    assert result["execution_command"][:2] == ["/usr/bin/arch", "-x86_64"]


testArchitecture()
testStraightBuild()
testMeasurements()
testCCompiler()
print("Optimization benchmark architecture, sample rotation, compiler selection, and validation checks passed")

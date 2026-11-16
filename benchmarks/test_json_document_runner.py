#!/usr/bin/env python3
"""Check portable clocks, workload identity, and a real document comparison."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

Root = Path(__file__).resolve().parent.parent
Spec = importlib.util.spec_from_file_location("comparison", Root / "benchmarks/compare_json_documents.py")
Compare = importlib.util.module_from_spec(Spec)
Spec.loader.exec_module(Compare)


def testSource():
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
        counter = Compare.prepareSource(source, model, 3, 1, "Windows", allocations=True)
        assert counter.count("  jsonAllocationStart()\n") == 1
        assert counter.count("  jsonAllocationFinish()\n") == 1
        assert counter.index("input.add(") < counter.index("  jsonAllocationStart()\n")
        assert counter.index("parseAndConsume(input)\n") < counter.index("  jsonAllocationFinish()\n")
    try:
        Compare.prepareSource("", "tree", 1, 1, "Windows")
    except Compare.Ray.BenchmarkError:
        pass
    else:
        raise AssertionError("missing fixture accepted")


def testComparison():
    compiler = Root / ("nifty.exe" if Compare.os.name == "nt" else "nifty")
    cc = shutil.which("gcc") or shutil.which("cc")
    if not compiler.is_file() or not cc:
        print("SKIP real JSON comparison: compiler or C toolchain unavailable")
        return
    with tempfile.TemporaryDirectory(prefix="nifty-json-document-runner-") as temporary:
        output = Path(temporary)
        report = Compare.main(["--backend", "c", "--records", "2", "--repeat", "2",
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
    testComparison()
    print("JSON document comparison source, clocks, oracle and reports passed")

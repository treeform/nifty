# Benchmark comparison

Apple M4 Pro, macOS 15.1, November 14, 2026. Median milliseconds;
lower is better. Each column measures the same work across implementations.

| Implementation | raytrace | JSON | snappy |
| --- | ---: | ---: | ---: |
| Hand ASM | 6.263 | 0.190 | 0.192 |
| Hand C | 6.760 | 0.252 | 0.211 |
| Nifty C backend | 7.321 | 1.237 | 0.522 |
| ARM64 backend | 7.468 | 3.801 | 1.672 |
| AMD64 via Rosetta | 10.839 | 6.331 | 1.681 |
| WASM64 (Wasmtime) | 43.691 | 8.223 | 15.214 |
| Interpreter (IR) | 543.807 | 21.670 | 148.047 |

Only the interpreter row was measured for this update. The first five rows
retain their measurements from commit `7bb1cbf`. The WASM row retains its
measurement from the union branch combined with the memory64 backend from
`main` at `fd5a79c`. Hand ASM runs on ARM64. Hand C is compiled
with Clang `-O2`; Nifty uses its normal C flags and native `speed` mode.
AMD64 runs through Rosetta. WASM64 runs in native ARM64 Wasmtime 49.0.0
with memory64 enabled. Its engine compilation and process startup are
outside the guest timers; first-use work inside each timer remains included.
The interpreter runs on ARM64 and executes the same optimized typed IR
directly, with libffi for foreign calls. Source checking, optimization,
and interpreter preparation occur before the guest timers in each fresh
process. No program executable or separate bytecode is generated.
All rows use one warmup process before the seven measured processes.

- Raytrace: 256 by 256 pixels, seven processes with twenty frames each.
- JSON: 128 records (26,753 bytes), seven processes with one hundred
  parse/consume/cleanup cycles each.
- Snappy: 256 KiB mixed fixture, seven processes with one hundred paired
  compression/decompression operations each. Buffers are retained.

Snappy uses the median of process means of paired operation sums, not
separately calculated compression and decompression medians. Input
creation and byte verification remain untimed. All seven implementations
produce identical compressed bytes and restore the complete input.

The raw local reports are `benchmarks/output/results.json`,
`benchmarks/output/json/results.json`, and
`benchmarks/output/snappy-hand/results.json`. These output directories
are ignored by Git. The new WASM reports are
`benchmarks/output/wasm-raytrace/results.json`,
`benchmarks/output/wasm-json/results.json`, and
`benchmarks/output/wasm-snappy/results.json`. The runners retain commands, source snapshots,
hashes, architecture, and raw timings in each report directory.
The interpreter reports are `benchmarks/output/interp-raytrace/results.json`,
`benchmarks/output/interp-json/results.json`, and
`benchmarks/output/interp-snappy/results.json`. Their outputs match the
previous pixel hash, JSON tree checksum, and compressed byte hashes.

See [raytrace](RAY_HAND_ASM.md), [JSON](HAND_ASM.md), and
[Snappy](SNAPPY_HAND_ASM.md) for implementation and validation details.

Reproduce the WASM row without rerunning the other implementations:

```sh
python3 benchmarks/run.py --backend wasm64 --size 256 --samples 7 --repeat 20 --check --output benchmarks/output/wasm-raytrace
python3 benchmarks/run_json_tree.py --backend wasm64 --records 128 --samples 7 --repeat 100 --output benchmarks/output/wasm-json
python3 benchmarks/run_snappy.py --backend wasm64 --size 262144 --samples 7 --repeat 100 --output benchmarks/output/wasm-snappy
```

The WASM integration passed 568 checks across Node and Wasmtime in both
optimization modes, including JSON/Snappy example parity and recursive
union ownership. Native parity passed 819 cases per optimization mode;
276 C golden/integration checks passed with memory sanitizers enabled.

Reproduce the interpreter row without rerunning other implementations:

```sh
python3 benchmarks/run.py --backend interp --size 256 --samples 7 --repeat 20 --check --timeout 3600 --output benchmarks/output/interp-raytrace
python3 benchmarks/run_json_tree.py --backend interp --records 128 --samples 7 --repeat 100 --timeout 3600 --output benchmarks/output/interp-json
python3 benchmarks/run_snappy.py --backend interp --size 262144 --samples 7 --repeat 100 --timeout 3600 --output benchmarks/output/interp-snappy
```

The interpreter passed 562 conformance checks on ARM64 and 562 under Rosetta,
each covering both optimization modes. Direct IR tests passed with memory
and undefined-behavior sanitizers. FFI tests exercised scalar types and mixed
register/stack arguments on both architectures. Native parity remained green
at 819 checks per optimization mode after the shared runtime changes.

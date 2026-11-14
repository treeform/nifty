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

Raytrace and JSON retain the previous measurements; only Snappy was
remeasured for this update. Hand ASM runs on ARM64. Hand C is compiled
with Clang `-O2`; Nifty uses its normal C flags and native `speed` mode.
AMD64 runs through Rosetta.

- Raytrace: 256 by 256 pixels, seven processes with twenty frames each.
- JSON: 128 records (26,753 bytes), seven processes with one hundred
  parse/consume/cleanup cycles each.
- Snappy: 256 KiB mixed fixture, seven processes with one hundred paired
  compression/decompression operations each. Buffers are retained.

Snappy uses the median of process means of paired operation sums, not
separately calculated compression and decompression medians. Input
creation and byte verification remain untimed. All five implementations
produce identical compressed bytes and restore the complete input.

The raw local reports are `benchmarks/output/results.json`,
`benchmarks/output/json/results.json`, and
`benchmarks/output/snappy-hand/results.json`. These output directories
are ignored by Git. The runners retain commands, source snapshots,
hashes, architecture, and raw timings in each report directory.

See [raytrace](RAY_HAND_ASM.md), [JSON](HAND_ASM.md), and
[Snappy](SNAPPY_HAND_ASM.md) for implementation and validation details.

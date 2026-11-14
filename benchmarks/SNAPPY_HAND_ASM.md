# Hand C and Hand ASM Snappy

[snappy_straight.c](snappy_straight.c) ports Supersnappy to standalone C.
It compresses and decompresses raw Snappy blocks without invoking Nifty.
The original MIT license is retained in [SNAPPY_LICENSE](../lib/SNAPPY_LICENSE).
The compressor preserves the Nifty port's compressed bytes, including
fragment boundaries, hash probes, literal lengths, and copy splitting.

Hand ASM uses the same C workload, timer, checksums, and byte comparisons.
Only the codec is replaced by [snappy_hand.S](arm64/snappy_hand.S).
It handles arbitrary supported input, all three copy tags, overlapping
copies, and malformed streams. It has no fixture-specific shortcuts.

## Run

```sh
python3 benchmarks/run_snappy.py --backend hand-asm,hand-c
python3 benchmarks/run_snappy.py --samples 7 --repeat 10
```

Both output buffers are warmed and retained. The measured Snappy time
adds the compression and decompression intervals within each iteration,
averages those pairs within each process, then takes the median across
processes. Setup, checksums, formatting, and exact byte comparisons are
untimed. The report retains separate codec times in its JSON data.

The Hand C core uses a 32 KiB stack hash table, unaligned word loads via
`memcpy`, and eight-byte matching with trailing-zero counting. Its
decoder validates lengths and offsets before copying, and expands short
overlaps by doubling already initialized spans. Neither implementation
relies on input padding or uninitialized output bytes.

## Assembly provenance

[snappy_clang.s](arm64/snappy_clang.s) is the frozen compiler output.
[snappy_manifest.json](arm64/snappy_manifest.json) records source and
assembly hashes, compiler version, generation command, ABI, and manual
changes. Generate the baseline with:

```sh
cc -O2 -pthread -fno-strict-aliasing -ffp-contract=off \
  -DSNAPPY_NO_MAIN -S benchmarks/snappy_straight.c \
  -o /tmp/snappy_clang.s
diff -u benchmarks/arm64/snappy_clang.s benchmarks/arm64/snappy_hand.S
```

This is compiler-derived assembly with manual optimization. The ABI uses
a 24-byte buffer containing a pointer, length, and capacity. The codec
returns zero on success and clears the output length on failure. Error
codes distinguish malformed input, allocation failure, and size limits.
The standalone C API uses an unsigned output limit; Nifty's signed API
also rejects negative limits.

The selected manual changes are:

- Scaled hash-table addressing and a shorter eight-byte match loop.
- Moving invariant vector register setup outside long-copy emission.
- Bounded byte, halfword, and word loads for copy offsets.
- Small copy and fill helpers that touch exactly the requested bytes.
  Larger literals continue through libc's bulk `memcpy`.

The short-copy helper keeps the C decoder's initialized-span doubling
rule for overlaps. Screening also tried forward overlap loops, a SIMD
table for short repeating patterns, and fully inline large literals.
Those alternatives were slower on one or more workloads and were not
selected. The checked-in manifest records these decisions.

## Validation

```sh
python3 benchmarks/test_snappy_runner.py
python3 benchmarks/test_snappy_hand.py --require-asm --require-sanitizers
python3 benchmarks/test_snappy_hand.py --supersnappy /path/to/supersnappy
```

The tests use an independent Python decoder, the shared malformed and
boundary corpus, and optional original Nim interoperability. They require
exact compressed bytes across C and assembly. C runs with AddressSanitizer
and UndefinedBehaviorSanitizer. Assembly additionally runs with protected
input and output boundaries, read-only inputs, allocation canaries, and
checks for preserved ARM64 integer and SIMD registers and stack state.
Fresh allocation failures and retained-buffer reuse are covered.

Assembly accesses are not instrumented by sanitizers, so the protected
memory tests are separate from the C sanitizer checks. Results and source
snapshots are saved under `benchmarks/output/snappy` by default.

The selected implementation passed 10,880 cases for each of C `-O0`,
C `-O2`, and ARM64 assembly, including every short repeating period and
copy tail. All 58 interoperability inputs produced byte-identical
compressed blocks to Supersnappy.

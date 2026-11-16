# Hand ASM JSON benchmark

`Hand ASM (ARM64)` runs the JSON benchmark through a persisted, manually
tuned assembly implementation on Apple Silicon Macs. It uses the same C
driver, input, owned tree representation, allocator, and cleanup as
`hand-c` (`c-straight` is also accepted). It does not invoke Nifty or regenerate assembly during a run.

```sh
python3 benchmarks/run_json_tree.py --backend hand-asm,hand-c --repeat 100
python3 benchmarks/run_json_tree.py --samples 7 --repeat 100 --wall
python3 benchmarks/test_json_hand_asm.py
python3 benchmarks/test_json_hand_asm.py --suite /path/to/JSONTestSuite/test_parsing
```

The first command compares standalone C with Hand ASM. The second includes
all available backends, including Nifty C, ARM64, and AMD64 via Rosetta.
The raytracer also has a [Hand ASM implementation](RAY_HAND_ASM.md).
Both runners list Hand ASM first, followed by Hand C and the Nifty backends.

## Origin and changes

[json_parser_clang.s](arm64/json_parser_clang.s) preserves the original
Apple Clang 16 `-O2` assembly for the standalone C parser, without its
benchmark driver. [json_parser_hand.S](arm64/json_parser_hand.S) is the
version used by the runner. [json_parser_manifest.json](arm64/json_parser_manifest.json)
records the original source revision, source hash, compiler, generation
command, assembly hashes, and ABI assumptions. Generate the original
listing from that source revision with:

```sh
cc -O2 -pthread -fno-strict-aliasing -ffp-contract=off \
  -DJSON_STRAIGHT_NO_MAIN -S benchmarks/json_parser_straight.c \
  -o /tmp/json_parser_clang.s
diff -u benchmarks/arm64/json_parser_clang.s benchmarks/arm64/json_parser_hand.S
```

The tracked baseline remains frozen for review. The current C source also
supports that generation command; toolchain changes can change the output.
The Hand ASM listing sets its Mach-O deployment marker to macOS 11, using
baseline ARM64 instructions and libc calls. Measurements and tests use the
current host, not every supported macOS release.

Two functions were changed:

- `jsonString` appends ASCII runs directly while the existing allocation
  has room. Every input read and output write is bounded. Quotes, escapes,
  control characters, high bytes, and capacity boundaries return to the
  original paths. UTF-8 validation, surrogate decoding, allocation sizes,
  and allocation-failure positions remain unchanged.
- `jsonVisit` combines four string or key bytes before reducing the
  checksum modulo `1000000007`. It uses reciprocal multiplication instead
  of division in those loops and the final reduction. Its jump table uses
  signed 32-bit offsets to accommodate the larger function.

The byte recurrence is `h = (h * 257 + byte) % 1000000007`. With a reduced
starting hash and four bytes at most 255, the largest intermediate is
`4362470431520251906`, below `2^63`. Reducing once per four bytes therefore
preserves the exact checksum. `umulh` with `0x89705f3112a28fe5`, followed by
a right shift of 29, computes the exact unsigned quotient; `msub` computes
the remainder. Tail bytes, embedded NULs, and container delimiters retain
their original order. Four-byte groups use four bounded byte loads.

The rest of the parser, number handling, Unicode decoding, depth checks,
and cleanup retain Clang's code. A separate cleanup candidate was tested
but omitted because its standalone timing difference was below 1 percent.
This is compiler-derived assembly with focused manual changes, not an
entirely handwritten parser. The improvements are scalar; no speculative
SIMD reads are used.

## Measurement and validation

The benchmark measures a complete parse, checksum traversal, and tree
destruction. The checksum optimization contributes to the total gain, so
the reported change is not a parsing-only speedup. Input construction and
process startup are outside the timed interval. C uses the same existing
`-O2` flags as before. See [JSON.md](JSON.md) for the workload and sampling.

On an Apple M4 Pro running macOS 15.1, the November 14, 2026 run of the
second command above measured these median milliseconds per cycle:

| Implementation | JSON cycle (ms) |
| --- | ---: |
| Hand ASM (ARM64) | 0.18972 |
| Hand C | 0.25215 |
| Nifty C backend | 1.23705 |
| Nifty ARM64 backend | 3.80056 |
| Nifty AMD64 backend via Rosetta | 6.33067 |

This uses 128 records (26,753 input bytes), seven measured processes per
backend, and 100 cycles per process, with rotated backend order. Hand ASM
took 24.8 percent less time than standalone C, a 1.33x speedup. Results are
specific to this fixture and machine. The much larger Nifty differences
also include its parser's ownership and subtree-copying costs.

The assembly shares the C parser's API and layout, checked with static
assertions when building the driver. Its conformance harness uses an
independent Python tree checksum, a C differential oracle, deterministic
random inputs, malformed strings and Unicode, nesting boundaries, and
allocation-failure injection. It also checks input ownership, output
replacement, and cleanup after failure.

ASan and UBSan instrument the C harness and oracle. They do not instrument
raw assembly accesses, so assembly tests additionally place input against
protected pages, surround owned allocations with checked canaries, and
force successful reallocations to move. Unsupported platforms explicitly
skip assembly execution; runner tests still check availability rules.

The final listing passed 701 conformance/corpus cases, 5,187 injected
allocation failures, and 100,000 differential random inputs. A test-only
assembly trampoline also checks callee-saved integer registers, the low
halves of SIMD registers, frame-pointer preservation, and stack restoration
across parsing, checksumming, and cleanup.

Results are written under `benchmarks/output/jsontree`. Each report preserves
the input, raw samples, exact build commands, C driver and assembly
snapshots, provenance manifest, hashes, and execution architecture. Use a
separate `--output` directory when comparing an alternate listing.

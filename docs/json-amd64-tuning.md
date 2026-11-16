# Hand-C documents and AMD64 append tuning

Focused Windows AMD64 experiment, 128 records / 26,753 input bytes. Each cycle
parses, hashes every decoded value and ordered key, and releases all storage.
Five measured samples follow one warmup; each process parses 100 times.
Variants rotate within each round. Every checksum matches the Python oracle.

| Backend | Owning tree (ms) | Document (ms) |
| --- | ---: | ---: |
| Hand C, -O2 | 0.372 | 0.172 |
| Nifty C, -O2 | 1.477 | 0.218 |
| Nifty AMD64, speed | 11.515 | 0.436 |

The new `benchmarks/json_document_hand.c` retains input once, appends decoded
text to one byte pool, and stores fixed nodes in preorder with subtree-end IDs.
It uses the existing hand-C Unicode rules and checksum, and transfers no
individually owned child allocations. This makes the hand-C document cycle
about 2.2 times faster than its original tree cycle on this fixture.

Before compiler changes, the Nifty AMD64 document cycle measured 1.264 ms in
the same session. The optimized cycle is about 2.9 times faster at 0.436 ms.
The gap to Nifty's C document backend falls from about 6 times to 2 times.

The compiler changes are general operations, with no JSON-specific handling:

- Reserved-capacity byte appends and appends of nonowning sequence elements
  directly store the payload and increment the length. Growth and owned
  elements retain the existing runtime path and allocation-failure behavior.
- Checked nonnegative integer division/remainder preserves unsigned semantics
  in IR. Signed expressions that need signed semantics are unchanged.
- AMD64 unsigned constant division uses a full multiply and exact residual
  correction. The correction handles the complete uint64 domain, including
  values near the maximum; no floating-point approximation is used.

That division transformation now lives in shared IR rather than the AMD64
emitter. AMD64 and ARM64 select their native unsigned multiply-high instruction;
WASM and the interpreter keep non-power-of-two division by default. The timing
table above records the original experiment, before this refactoring.

A focused Windows check of the shared-IR and checked-AST changes used the
document benchmark only: 128 records, 30 parses per process, one warmup and
five measured samples. Compared with commit `8922b00`, median cycles were:

| Backend | Before (ms) | After (ms) |
| --- | ---: | ---: |
| Nifty C | 0.232 | 0.210 |
| Nifty AMD64 | 0.486 | 0.447 |

These short runs indicate no regression, rather than a stable speedup claim.
Every checksum matched; allocation traffic remained 14 calls and 557,264
requested bytes per document. Raw local results are in
`benchmarks/output/lift-before/` and `benchmarks/output/lift-after/`.

The remaining AMD64/C gap is still visible. These measurements establish an
improvement on this JSON workload, not a general performance guarantee.

Only focused validation was run: this benchmark's independent checksums, one
arithmetic boundary/random-vector check, and one reserved-capacity append
fixture covering byte, record, narrow-integer and float payloads. No full
regression suite was run.

Reproduce:

```text
python benchmarks/compare_json_documents.py --model both --backend hand-c,c,amd64 --records 128 --repeat 100 --samples 5 --output benchmarks/output/json-tuning
```

Raw samples, source/compiler hashes and exact commands are written to that
directory. Input construction, process startup and output are outside timing.

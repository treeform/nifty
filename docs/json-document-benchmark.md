# Document JSON comparison: Windows AMD64

Measured on 2026-11-16, Windows 11 AMD64, GCC 11.1.0. The workload contains
128 records / 26,753 bytes, including nested containers, exact number spelling,
Unicode escapes, surrogate pairs, and embedded NUL. Nine measured process
samples follow one warmup per variant; each process performs 100 fresh parses.
Variants rotate within each round.

Every timed cycle parses, checksums all decoded values and ordered keys, and
destroys its complete tree/document. Input construction, startup, and output
are excluded. All checksums matched the independent Python oracle (`25086498`).

| Representation | Backend | Median cycle | Min–max | Build time |
| --- | --- | ---: | ---: | ---: |
| Owning tree | C, -O2 | 1.552 ms | 1.520–1.562 ms | 0.804 s |
| Document | C, -O2 | 0.234 ms | 0.229–0.247 ms | 0.604 s |
| Owning tree | AMD64, speed | 12.755 ms | 12.635–12.992 ms | 6.382 s |
| Document | AMD64, speed | 1.344 ms | 1.329–1.428 ms | 5.598 s |

The document cycle is approximately **6.6× faster through C** and **9.5× faster
through native AMD64**. Build times are single observations, not sampled
medians; they were lower in this run, but establish less than the runtime data.
The document's preorder traversal also differs from the tree's traversal, so
these results measure the full representation change, not parser-only speed.

Separate, untimed C allocation probes measured:

| Representation | Allocation/reallocation calls | Cumulative requested bytes |
| --- | ---: | ---: |
| Owning tree | 26,507 | 1,597,504 |
| Document | 14 | 557,264 |

These bytes are allocation traffic, not peak live memory. The document keeps
the raw input prefix and decoded text in one pool, and all nodes in another;
nodes contain only values, IDs, and ranges. No language changes were required.
Native AMD64 still trails C on the same document representation, so this does
not eliminate the remaining backend optimization work.

Reproduce with:

```text
python benchmarks/compare_json_documents.py --model both --backend c,amd64 --records 128 --repeat 100 --samples 9
```

The default output directory is `benchmarks/output/json-document`; it contains
raw samples, exact build commands, source/compiler hashes, input bytes, and the
generated binaries. See the [document API guide](json-document.md).

Validation passed: 276 existing language/memory tests, old JSON C conformance,
old native JSON tests in both optimization modes, new document conformance
including 100 deterministic randomized trees and injected allocation failures,
and document API execution through C, AMD64, and the interpreter in both modes.

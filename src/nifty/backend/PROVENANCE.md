# Native backend provenance

The IR model, verifier, builders, register allocator, instruction encoders,
ARM64 and AMD64 emitters, and executable memory support are adapted from
[treeform/nimkey](https://github.com/treeform/nimkey), revision adcacefce18748630dccde5943bd3314dfcb422b.
The upstream MIT license is preserved in LICENSE.nimkey.

Frontend, packed runtime, and layout dependencies were replaced by the Nifty
error boundary, a power-of-two alignment helper, and RuntimeContext.

The optimizer and its generic analysis and rewriting modules are also adapted
from that revision. Default passes preserve floating point evaluation order and
do not vectorize or prune procedure bodies. Large aggregate operations remain
bounded emitter operations instead of expanding into scalar instruction pools.
The emitters retain upstream register allocation and instruction selection.
Externally callable Nifty routines accept four pointers and return through
caller-owned storage.
`NativeImage.offsets` addresses routine entries; offset zero is a separate
convenience wrapper that clears the argument, return, and reserved pointers.

Host bindings are a contiguous table of C function pointers selected by
`IrHost.binding`, loaded through `RuntimeContext.hosts`. Host signatures support
scalar integer, address, float32, and float64 values with at most one scalar
return. ARM64 host calls use eight registers per argument bank and native stack
slots for excess arguments, including Darwin's compact scalar stack slots.
Aggregate C values and C variadics are outside this contract. AMD64 uses the
build host platform's C calling convention.

`frameBytes` contains the finalized stack bytes for every routine, including
locals, outgoing argument storage, preserved registers, and (on AMD64) its
incoming return address. `wrapperFrameBytes` reports the separate wrapper's
occupancy using the same convention.

The memory64 WebAssembly binary encoders, runtime module composer, and shared IR
selector (`wasmbinaries.nim`, `wasmmodules.nim`, and `irwasms.nim`) are adapted
from the same Nimkey revision. They consume Nifty's verified IR and
`RuntimeContext`, select the requested thread entry, and preserve native scalar
host signatures through explicit runtime export mappings. Runtime storage and
function signatures are checked before composition. The module requires bounded
memory64 and table64, uses i64 addresses throughout, and preserves its runtime
memory budget. Private direct floating result bundles, SIMD values, bulk memory
operations, and float32/float64 rounding retain the shared IR contract. Failure
continuations are rejected explicitly. No Nimkey packed runtime is included.

The runtime composition workflow, low-memory WASI output bridge, and Node host
adapter also follow that Nimkey revision. Nifty supplies its own serialized
metadata, shared container runtime, typed foreign-call exports, ownership
cleanup, and source/ABI fingerprint. These adaptations are covered by the same
preserved MIT license. Runtime page allocation and memory-growth notification
use the standalone memory64 Emscripten ABI.

The direct IR interpreter follows Nimkey's instruction-dispatch approach,
but executes Nifty's existing `IrModule` rather than porting Nimkey's separate
high-level bytecode format. Its frames, storage, and instruction execution
are implemented for the shared typed IR contract. It does not emit machine
code or introduce another serialized instruction representation.

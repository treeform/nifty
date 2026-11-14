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

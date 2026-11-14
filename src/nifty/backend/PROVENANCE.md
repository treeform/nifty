# Native backend provenance

The IR model, verifier, builders, register allocator, instruction encoders,
ARM64 and AMD64 emitters, and executable memory support are adapted from
[treeform/nimkey](https://github.com/treeform/nimkey), revision adcacefce18748630dccde5943bd3314dfcb422b.
The upstream MIT license is preserved in LICENSE.nimkey.

Frontend, packed runtime, and layout dependencies were replaced by the Nifty
error boundary, a power-of-two alignment helper, and RuntimeContext.

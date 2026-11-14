## Verifies deep union trees release with bounded stack and no allocations.
import ../src/nifty/[types, nativeplans, nativecontainers]

proc malloc(bytes: csize_t): pointer
  {.importc, header: "<stdlib.h>", raises: [].}
proc free(address: pointer)
  {.importc, header: "<stdlib.h>", raises: [].}

var releases = 0
proc release(address: pointer) {.cdecl, raises: [].} =
  ## Counts tree allocations released during destruction.
  inc releases
  free(address)

let layouts = @[
  NativeLayout(kind: UnionType, bytes: 32, align: 8, owned: true,
    typeId: 1, dataOffset: 8, members: @[1, 2]),
  NativeLayout(kind: SeqType, bytes: 24, align: 8, owned: true,
    typeId: 2, dynamic: true, elem: 0, dataOffset: 16),
  NativeLayout(kind: IntType, bytes: 8, align: 8, typeId: 3)
]
var root: array[4, int64]
var node = cast[pointer](addr root[0])
const Depth = 100000
for i in 0 ..< Depth:
  cast[ptr int64](node)[] = 2
  let descriptor = at(node, 8)
  cast[ptr int64](descriptor)[] = 1
  cast[ptr int64](at(descriptor, 8))[] = 1
  let allocation = malloc(56)
  doAssert allocation != nil
  zeroMem(allocation, 56)
  cast[ptr pointer](at(descriptor, 16))[] = allocation
  node = allocation
cast[ptr int64](node)[] = 3
var copied: array[4, int64]
doAssert copyOwned(layouts, 0, addr copied[0], addr root[0])
dropOwned(layouts, 0, addr copied[0], NativeMemory(release: release))
doAssert releases == Depth
releases = 0
dropOwned(layouts, 0, addr root[0], NativeMemory(release: release))
doAssert releases == Depth
doAssert root == [0'i64, 0, 0, 0]
echo "Native deep union copy and destruction passed"

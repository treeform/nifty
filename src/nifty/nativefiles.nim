## Versioned native images with fixed runtime metadata.
import std/[json, jsonutils, os]
import common, types, nativeplans, nativeoptimizations, backend/engine
export nativeplans, nativeoptimizations, engine

const
  NativeMagic = "NIFTYN01"
  NativeHeader = 40
  MaxNativeFile = 128 * 1024 * 1024
  MaxNativeStorage = 1024 * 1024 * 1024

type
  NativePlatform* = enum
    MacosPlatform, LinuxPlatform
  NativeProgram* = object
    image*: NativeImage
    plan*: NativePlan
    platform*: NativePlatform
  NativeMetadata = object
    target: NativeTarget
    platform: NativePlatform
    offsets: seq[int]
    globalBytes: int
    initialData: seq[byte]
    threads: seq[ThreadPlan]
    hosts: seq[NativeHost]
    layouts: seq[NativeLayout]
    lockOffsets, channelOffsets: seq[int]

const NativeHostPlatform* = when defined(macosx): MacosPlatform
  elif defined(linux): LinuxPlatform
  else: {.error: "Native runtime supports macOS and Linux".}

proc putNumber(data: var string, number: uint64) =
  ## Appends one unsigned little endian integer.
  for shift in countup(0, 56, 8):
    data.add char((number shr shift) and 255)

proc getNumber(data: string, offset: int): uint64 =
  ## Reads one bounds checked unsigned little endian integer.
  if offset < 0 or offset > data.len - 8:
    raise newException(NiftyError, "truncated native image")
  for i in 0 ..< 8:
    result = result or (uint64(byte(data[offset + i])) shl (i * 8))

proc fingerprint(data: string): uint64 =
  ## Detects damaged image payloads without platform specific libraries.
  result = 14695981039346656037'u64
  for value in data:
    result = (result xor uint64(byte(value))) * 1099511628211'u64

proc validateNative*(program: NativeProgram) =
  ## Rejects invalid sizes, offsets, and unsupported runtime descriptors.
  let plan = program.plan
  if program.image.bytes.len == 0 or
      program.image.bytes.len > 64 * 1024 * 1024 or
      program.image.offsets.len == 0:
    raise newException(NiftyError, "invalid native instruction image")
  for offset in program.image.offsets:
    if offset < 0 or offset >= program.image.bytes.len:
      raise newException(NiftyError, "native function outside image")
    if program.image.target == Arm64Target and offset mod 4 != 0:
      raise newException(NiftyError, "unaligned ARM64 function")
  if plan.globalBytes < 0 or plan.globalBytes > MaxNativeStorage or
      plan.initialData.len > plan.globalBytes:
    raise newException(NiftyError, "invalid native global allocation")
  var totalArena = int64(plan.globalBytes)
  var totalThreads = 0
  for thread in plan.threads:
    if thread.functionIndex <= 0 or
        thread.functionIndex >= program.image.offsets.len or
        thread.count <= 0 or thread.count > 65536 or
        thread.arenaBytes < 0 or thread.arenaBytes > MaxNativeStorage:
      raise newException(NiftyError, "invalid native thread descriptor")
    totalThreads += thread.count
    totalArena += int64(thread.count) * int64(thread.arenaBytes)
  if totalThreads > 65536 or totalArena > MaxNativeStorage:
    raise newException(NiftyError, "native startup storage exceeds limit")
  for offset in plan.lockOffsets & plan.channelOffsets:
    if offset < 0 or offset > plan.globalBytes - 8:
      raise newException(NiftyError, "native synchronization outside globals")
  for layout in plan.layouts:
    if layout.bytes < 0 or layout.bytes > MaxNativeStorage or
        layout.align <= 0 or layout.align > 16 or layout.capacity < 0:
      raise newException(NiftyError, "invalid native type layout")
    if layout.kind in {ArrayType, SeqType, QueueType, ChannelType} and
        (layout.elem < 0 or layout.elem >= plan.layouts.len):
      raise newException(NiftyError, "invalid native element layout")
  for host in plan.hosts:
    if host.paramTypes.len != host.paramOffsets.len:
      raise newException(NiftyError, "invalid native host parameters")
    for i, typ in host.paramTypes:
      if typ < 0 or typ >= plan.layouts.len or host.paramOffsets[i] < 0:
        raise newException(NiftyError, "invalid native host argument")

proc buildNativeProgram*(plan: NativePlan,
    target: NativeTarget,
    platform = NativeHostPlatform,
    optimization = SpeedOptimization): NativeProgram =
  ## Compiles checked native IR while retaining runtime descriptors.
  if platform != NativeHostPlatform:
    raise newException(NiftyError,
      "native compilation requires the host operating system ABI")
  result.platform = platform
  result.plan = optimizeNative(plan, optimization)
  result.image = emitNative(result.plan.module, target)
  result.validateNative()

proc encodeNative*(program: NativeProgram): string =
  ## Encodes an image deterministically without compiler process state.
  program.validateNative()
  let metadata = NativeMetadata(
    target: program.image.target, platform: program.platform,
    offsets: program.image.offsets,
    globalBytes: program.plan.globalBytes,
    initialData: program.plan.initialData, threads: program.plan.threads,
    hosts: program.plan.hosts, layouts: program.plan.layouts,
    lockOffsets: program.plan.lockOffsets,
    channelOffsets: program.plan.channelOffsets)
  let text = $metadata.toJson()
  var code = newString(program.image.bytes.len)
  copyMem(addr code[0], unsafeAddr program.image.bytes[0], code.len)
  result = NativeMagic
  result.putNumber(uint64(text.len))
  result.putNumber(uint64(code.len))
  result.putNumber(fingerprint(text))
  result.putNumber(fingerprint(code))
  result.add text
  result.add code

proc decodeNative*(data: string): NativeProgram =
  ## Decodes and validates a complete version one native image.
  if data.len < NativeHeader or data.len > MaxNativeFile or
      data[0 ..< 8] != NativeMagic:
    raise newException(NiftyError, "unrecognized or truncated native image")
  let
    metadataSize = data.getNumber(8)
    codeSize = data.getNumber(16)
  if metadataSize > uint64(MaxNativeFile) or codeSize > 67108864 or
      metadataSize + codeSize != uint64(data.len - NativeHeader):
    raise newException(NiftyError, "invalid native image lengths")
  let
    split = NativeHeader + int(metadataSize)
    metadataText = data[NativeHeader ..< split]
    code = data[split ..< data.len]
  if fingerprint(metadataText) != data.getNumber(24) or
      fingerprint(code) != data.getNumber(32):
    raise newException(NiftyError, "damaged native image checksum")
  var metadata: NativeMetadata
  try:
    metadata = parseJson(metadataText).jsonTo(NativeMetadata)
  except CatchableError as error:
    raise newException(NiftyError, "invalid native metadata: " & error.msg)
  result.platform = metadata.platform
  result.image.target = metadata.target
  result.image.offsets = metadata.offsets
  result.image.bytes = newSeq[byte](code.len)
  if code.len > 0:
    copyMem(addr result.image.bytes[0], unsafeAddr code[0], code.len)
  result.plan = NativePlan(globalBytes: metadata.globalBytes,
    initialData: metadata.initialData, threads: metadata.threads,
    hosts: metadata.hosts, layouts: metadata.layouts,
    lockOffsets: metadata.lockOffsets, channelOffsets: metadata.channelOffsets)
  result.validateNative()

proc writeNativeFile*(program: NativeProgram, path: string) =
  ## Writes one portable native image for either supported target.
  try:
    writeFile(path, program.encodeNative())
  except IOError as error:
    raise newException(NiftyError, "cannot write native image: " & error.msg)

proc readNativeFile*(path: string): NativeProgram =
  ## Reads one size bounded native image from disk.
  try:
    if getFileSize(path) > MaxNativeFile:
      raise newException(NiftyError, "native image exceeds file size limit")
    result = decodeNative(readFile(path))
  except IOError as error:
    raise newException(NiftyError, "cannot read native image: " & error.msg)

## Fixed native storage layouts and runtime metadata.
import types, backend/irs

type
  NativeField* = object
    name*: string
    typ*, offset*: int
  NativeLayout* = object
    kind*: TypKind
    bytes*, align*, capacity*: int64
    dynamic*, owned*: bool
    typeId*: int64
    members*: seq[int]
    elem*, key*, val*: int
    lower*, upper*: int64
    dataOffset*, keyOffset*, valOffset*, okOffset*: int
    optional*: bool
    display*: string
    fields*: seq[NativeField]
  NativeHostKind* = enum
    ContainerHost, EchoHost, ExternHost, LockHost
  NativeHost* = object
    kind*: NativeHostKind
    operation*, symbol*, library*: string
    receiverType*, resultType*: int
    paramTypes*, paramOffsets*: seq[int]
    paramVars*: seq[bool]
  ThreadPlan* = object
    name*: string
    count*, functionIndex*, arenaBytes*: int
  OwnedGlobal* = object
    offset*, layout*: int
  NativePlan* = object
    module*: IrModule
    globalBytes*: int
    initialData*: seq[byte]
    threads*: seq[ThreadPlan]
    hosts*: seq[NativeHost]
    layouts*: seq[NativeLayout]
    lockOffsets*, channelOffsets*: seq[int]
    ownedGlobals*: seq[OwnedGlobal]

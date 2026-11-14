import std/[bitops, strutils], irs

type
  IrLiveRange* = object
    first*: int32
    last*: int32

  IrLiveness* = object
    words*: int
    liveIn*: seq[uint64]
    liveOut*: seq[uint64]
    starts*: seq[int32]
    ends*: seq[int32]
    ranges*: seq[IrLiveRange]

proc contains*(analysis: IrLiveness, owner: int, value: ValueId,
    outgoing = false): bool =
  ## Tests a value in a block boundary set without allocating a collection.
  let
    index = owner * analysis.words + int(int32(value)) div 64
    bit = 1'u64 shl (int32(value) mod 64)
  if outgoing:
    (analysis.liveOut[index] and bit) != 0
  else:
    (analysis.liveIn[index] and bit) != 0

proc analyzeLiveness*(function: IrFunction): IrLiveness =
  ## Computes fixed-point CFG liveness and conservative linear SSA intervals.
  var analysis: IrLiveness
  analysis.words = (function.values.len + 63) div 64
  let size = analysis.words * function.blocks.len
  var
    definitions = newSeq[uint64](size)
    uses = newSeq[uint64](size)
    position = 0'i32
  analysis.liveIn = newSeq[uint64](size)
  analysis.liveOut = newSeq[uint64](size)
  analysis.ranges = newSeq[IrLiveRange](function.values.len)
  for item in analysis.ranges.mitems:
    item.first = -1
    item.last = -1
  proc define(span: Span, owner: int, position: int32) =
    ## Marks definitions before computing upwards-exposed uses.
    for i in span.indices:
      let index = owner * analysis.words + i div 64
      definitions[index] = definitions[index] or (1'u64 shl (i mod 64))
  proc use(span: Span, owner: int) =
    ## Collects local reads not already supplied by a definition in this block.
    for i in span.indices:
      let
        value = int(int32(function.operands[i]))
        index = owner * analysis.words + value div 64
        bit = 1'u64 shl (value mod 64)
      if (definitions[index] and bit) == 0:
        uses[index] = uses[index] or bit
  for owner, data in function.blocks:
    analysis.starts.add(position)
    define(data.parameters, owner, position)
    for i in data.instructions.indices:
      use(function.instructions[i].arguments, owner)
      define(function.instructions[i].results, owner, position)
      position += 2
    use(data.terminator.arguments, owner)
    define(data.terminator.results, owner, position)
    for i in data.terminator.edges.indices:
      use(function.edges[i].arguments, owner)
    position += 2
    analysis.ends.add(position)
    inc position
  var changed = true
  while changed:
    changed = false
    for owner in countdown(function.blocks.high, 0):
      let data = function.blocks[owner]
      for word in 0 ..< analysis.words:
        let index = owner * analysis.words + word
        var outgoing = 0'u64
        for i in data.terminator.edges.indices:
          outgoing = outgoing or analysis.liveIn[
            int(int32(function.edges[i].target)) * analysis.words + word]
        let incoming = uses[index] or (outgoing and not definitions[index])
        if outgoing != analysis.liveOut[index] or incoming != analysis.liveIn[index]:
          changed = true
          analysis.liveOut[index] = outgoing
          analysis.liveIn[index] = incoming
  proc touch(value: int, position: int32) =
    ## Extends a value across every program point where it must survive.
    let old = analysis.ranges[value]
    analysis.ranges[value].first = if old.first < 0: position
      else: min(old.first, position)
    analysis.ranges[value].last = max(old.last, position)
  proc touchOperands(span: Span, position: int32) =
    ## Extends intervals through instruction, terminator, and edge reads.
    for i in span.indices:
      touch(int(int32(function.operands[i])), position)
  for owner, data in function.blocks:
    let start = analysis.starts[owner]
    for value in 0 ..< function.values.len:
      if analysis.contains(owner, ValueId(value)):
        touch(value, start)
      if analysis.contains(owner, ValueId(value), outgoing = true):
        touch(value, analysis.ends[owner])
    for value in data.parameters.indices:
      touch(value, start)
    var cursor = start + 1
    for i in data.instructions.indices:
      touchOperands(function.instructions[i].arguments, cursor)
      for value in function.instructions[i].results.indices:
        touch(value, cursor + 1)
      cursor += 2
    touchOperands(data.terminator.arguments, cursor)
    for value in data.terminator.results.indices:
      touch(value, cursor + 1)
    for i in data.terminator.edges.indices:
      touchOperands(function.edges[i].arguments, cursor + 1)
  result = move(analysis)

proc dumpLiveness*(function: IrFunction): string =
  ## Prints real block boundary sets and linear ranges for allocation review.
  let analysis = analyzeLiveness(function)
  for owner in 0 ..< function.blocks.len:
    result.add("b" & $owner & ":")
    for outgoing in [false, true]:
      result.add(if outgoing: " out [" else: " in [")
      var values: seq[string]
      for value in 0 ..< function.values.len:
        if analysis.contains(owner, ValueId(value), outgoing):
          values.add("r" & $value)
      result.add(values.join(", ") & "]")
    result.add("\n")
  for value, interval in analysis.ranges:
    if interval.first >= 0:
      result.add("r" & $value & ": " & $interval.first & " .. " &
        $interval.last & "\n")

proc liveAcrossCalls*(function: IrFunction, analysis: IrLiveness): seq[bool] =
  ## Finds payloads needed after a call on an actual control-flow path.
  var crossing = newSeq[bool](function.values.len)
  for owner, data in function.blocks:
    var live = newSeq[uint64](analysis.words)
    for word in 0 ..< analysis.words:
      live[word] = analysis.liveOut[owner * analysis.words + word]
    proc reads(span: Span) =
      ## Adds operands only after recording the values that survive a call.
      for i in span.indices:
        let value = int32(function.operands[i])
        live[value div 64] = live[value div 64] or (1'u64 shl (value mod 64))
    proc kills(span: Span) =
      ## Excludes values produced by the current instruction or invoke.
      for value in span.indices:
        live[value div 64] = live[value div 64] and
          not (1'u64 shl (value mod 64))
    proc record() =
      ## Accumulates live-through values across all calls in this function.
      for word, active in live:
        var bits = active
        while bits != 0:
          crossing[word * 64 + countTrailingZeroBits(bits)] = true
          bits = bits and (bits - 1)
    for i in data.terminator.edges.indices:
      reads(function.edges[i].arguments)
    kills(data.terminator.results)
    if data.terminator.kind in {InvokeTerminator, InvokeHostTerminator}:
      record()
    reads(data.terminator.arguments)
    for i in countdown(int(data.instructions.first + data.instructions.count) - 1,
        int(data.instructions.first)):
      let item = function.instructions[i]
      kills(item.results)
      if item.op in {CallOp, HostCallOp, IndirectCallOp}:
        record()
      reads(item.arguments)
  result = move(crossing)

proc liveThroughCalls*(function: IrFunction,
    analysis: IrLiveness): seq[seq[ValueId]] =
  ## Lists exact live-through payloads at each ordinary call instruction.
  result = newSeq[seq[ValueId]](function.instructions.len)
  for owner, data in function.blocks:
    var live = newSeq[uint64](analysis.words)
    for word in 0 ..< analysis.words:
      live[word] = analysis.liveOut[owner * analysis.words + word]
    proc reads(span: Span) =
      ## Adds local reads to the backwards control-flow live set.
      for i in span.indices:
        let value = int32(function.operands[i])
        live[value div 64] = live[value div 64] or
          (1'u64 shl (value mod 64))
    proc kills(span: Span) =
      ## Excludes results which do not exist before the current instruction.
      for value in span.indices:
        live[value div 64] = live[value div 64] and
          not (1'u64 shl (value mod 64))
    for i in data.terminator.edges.indices:
      reads(function.edges[i].arguments)
    kills(data.terminator.results)
    reads(data.terminator.arguments)
    for i in countdown(int(data.instructions.first + data.instructions.count) - 1,
        int(data.instructions.first)):
      let item = function.instructions[i]
      kills(item.results)
      if item.op in {CallOp, HostCallOp, IndirectCallOp}:
        for word, active in live:
          var bits = active
          while bits != 0:
            result[i].add(ValueId(word * 64 + countTrailingZeroBits(bits)))
            bits = bits and (bits - 1)
      reads(item.arguments)

proc interference*(function: IrFunction, analysis: IrLiveness): seq[uint64] =
  ## Builds exact SSA conflicts from backwards instruction-level live sets.
  let
    count = function.values.len
    words = analysis.words
  var graph = newSeq[uint64](count * words)
  proc connect(a, b: int) =
    ## Records a symmetric conflict between simultaneously occupied values.
    if a != b:
      graph[a * words + b div 64] = graph[a * words + b div 64] or
        (1'u64 shl (b mod 64))
      graph[b * words + a div 64] = graph[b * words + a div 64] or
        (1'u64 shl (a mod 64))
  for owner, data in function.blocks:
    var live = newSeq[uint64](words)
    for word in 0 ..< words:
      live[word] = analysis.liveOut[owner * words + word]
    proc reads(span: Span) =
      ## Adds reads before the definition that supplies their current payload.
      for i in span.indices:
        let value = int(int32(function.operands[i]))
        live[value div 64] = live[value div 64] or
          (1'u64 shl (value mod 64))
    proc defines(span: Span) =
      ## Conflicts definitions with live payloads, then kills their old ranges.
      for value in span.indices:
        for word in 0 ..< words:
          var bits = live[word]
          while bits != 0:
            connect(value, word * 64 + countTrailingZeroBits(bits))
            bits = bits and (bits - 1)
        for other in span.indices:
          connect(value, other)
      for value in span.indices:
        live[value div 64] = live[value div 64] and
          not (1'u64 shl (value mod 64))
    for i in data.terminator.edges.indices:
      reads(function.edges[i].arguments)
    defines(data.terminator.results)
    reads(data.terminator.arguments)
    for i in countdown(int(data.instructions.first + data.instructions.count) - 1,
        int(data.instructions.first)):
      defines(function.instructions[i].results)
      reads(function.instructions[i].arguments)
    defines(data.parameters)
  result = move(graph)

proc interference*(function: IrFunction): seq[uint64] =
  ## Computes liveness before building exact instruction-level conflicts.
  interference(function, analyzeLiveness(function))

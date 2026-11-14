import irs

proc orderBlocks*(function: var IrFunction): bool =
  ## Places reachable blocks in reverse postorder without changing their work.
  if function.blocks.len < 2:
    return
  var
    visited = newSeq[bool](function.blocks.len)
    pending = @[(0, false)]
    postorder: seq[int]
    order: seq[int]
  while pending.len > 0:
    let (owner, finished) = pending.pop()
    if finished:
      postorder.add(owner)
    elif not visited[owner]:
      visited[owner] = true
      pending.add((owner, true))
      # Visiting later edges first places true successors earlier on reversal.
      for i in function.blocks[owner].terminator.edges.indices:
        pending.add((int(function.edges[i].target), false))
  for i in countdown(postorder.high, 0):
    order.add(postorder[i])
  for owner in 0 ..< function.blocks.len:
    if not visited[owner]:
      order.add(owner)
  for index, owner in order:
    result = result or index != owner
  if not result:
    return
  var
    mapping = newSeq[BlockId](order.len)
    blocks: seq[IrBlock]
    remapped = newSeq[bool](function.edges.len)
  for index, owner in order:
    mapping[owner] = BlockId(index)
    blocks.add(function.blocks[owner])
  # Shared edges are remapped once; unused pool records stay untouched.
  for data in blocks:
    for i in data.terminator.edges.indices:
      if not remapped[i]:
        remapped[i] = true
        function.edges[i].target = mapping[int(function.edges[i].target)]
  function.blocks = move(blocks)

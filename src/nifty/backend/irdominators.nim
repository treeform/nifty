import irs

type IrDominance* = object
  parents*, order*: seq[int]
  predecessors*, children*: seq[seq[int]]

proc dominance*(function: IrFunction): IrDominance =
  ## Builds reachable immediate dominators and preserves duplicate CFG edges.
  let count = function.blocks.len
  result.parents = newSeq[int](count)
  result.predecessors = newSeq[seq[int]](count)
  result.children = newSeq[seq[int]](count)
  for parent in result.parents.mitems:
    parent = -1
  if count == 0:
    return
  var
    visited = newSeq[bool](count)
    pending = @[(0, false)]
    order: seq[int]
  for owner, data in function.blocks:
    for i in data.terminator.edges.indices:
      result.predecessors[int32(function.edges[i].target)].add(owner)
  while pending.len > 0:
    let (owner, finished) = pending.pop()
    if finished:
      order.add(owner)
    elif not visited[owner]:
      visited[owner] = true
      pending.add((owner, true))
      for i in function.blocks[owner].terminator.edges.indices:
        pending.add((int(int32(function.edges[i].target)), false))
  var
    ranks = newSeq[int](count)
    parents = result.parents
  for i in 0 ..< order.len:
    ranks[order[order.high - i]] = i
  parents[0] = 0
  proc intersect(a, b: int): int =
    ## Finds a common ancestor in the current immediate dominator tree.
    var
      left = a
      right = b
    while left != right:
      if ranks[left] > ranks[right]:
        left = parents[left]
      else:
        right = parents[right]
    left
  var changed = true
  while changed:
    changed = false
    for i in countdown(order.len - 2, 0):
      let owner = order[i]
      var parent = -1
      for predecessor in result.predecessors[owner]:
        if parents[predecessor] >= 0:
          parent = if parent < 0: predecessor
            else: intersect(parent, predecessor)
      if parents[owner] != parent:
        parents[owner] = parent
        changed = true
  result.parents = move(parents)
  result.order = move(order)
  for owner in 1 ..< count:
    if result.parents[owner] >= 0:
      result.children[result.parents[owner]].add(owner)

## glyphes — label membership (STORAGE.md §4.3)
##
## The label index: for each dictionary code, the ids of the nodes
## carrying it. This is what makes `MATCH (p:Person)` a scan over one
## contiguous array instead of a sweep of the whole node table, and it is
## built in rather than opt-in because a graph store without it cannot
## answer its most common query.
##
## Removal is O(1) by swap-remove, with the node's position kept in a
## parallel array on the store (`GraphStore.labelPos`) rather than in the
## record. This was a linear scan in the first M1 draft, and it is
## quadratic in the obvious workload: deleting 100 000 nodes from a
## 50 000-member label is 2.5 x 10^9 comparisons, which is why the degree
## -churn test took 1m48s. The record stays 48 bytes — the position lives
## in a store-level array, so the pinned layout and the snapshot's node
## section are unaffected.
##
## Swap-remove reorders the tail into the hole. Label order is
## unspecified (STORAGE.md S7), so nothing may depend on it.

type
  LabelIndex* = object
    members*: seq[seq[int64]]

proc initLabels*(li: var LabelIndex, codes: int) =
  li.members = newSeq[seq[int64]](codes)

proc ensureCode*(li: var LabelIndex, code: int32) =
  ## The dictionary can gain a code after the index is built (a
  ## transaction interns a new label), so the index grows with it.
  let want = code.int
  if want <= 0:
    return
  if li.members.len < want:
    li.members.setLen(want)

proc cloneMembers(s: seq[int64]): seq[int64] =
  ## A real buffer copy, not `var copy = s`: a Nim seq assignment shares
  ## the buffer, and `add` on the copy writes *into that shared buffer*
  ## whenever there is spare capacity — which is precisely the mutation a
  ## reader is not supposed to see.
  result = newSeq[int64](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len * sizeof(int64))

proc add*(li: var LabelIndex, code: int32, id: int64;
          copyOnWrite = false): int32 =
  ## Appends and returns the member's position, which the caller records
  ## in `labelPos` so removal is O(1).
  ##
  ## `copyOnWrite` publishes a *new* member list rather than growing the
  ## existing one, so a reader holding the old list keeps a consistent
  ## view of its own generation. It costs O(label size) per append, which
  ## is why the store only asks for it while a read snapshot is
  ## outstanding: with nobody reading, in-place append is unobservable.
  if code <= 0:
    return -1
  li.ensureCode(code)
  result = int32(li.members[code.int - 1].len)
  if copyOnWrite:
    var fresh = cloneMembers(li.members[code.int - 1])
    fresh.add id
    li.members[code.int - 1] = fresh
  else:
    li.members[code.int - 1].add id

proc remove*(li: var LabelIndex, code: int32, pos: int32,
             movedId: var int64; copyOnWrite = false): bool =
  ## Swap-remove at `pos`. `movedId` receives the member that was shifted
  ## into the hole, so the caller can fix its recorded position; it is 0
  ## when nothing moved.
  ##
  ## Swap-remove *reorders*, so mutating in place here can leave a reader
  ## mid-iteration on a member list that never existed at any single
  ## commit. `copyOnWrite` builds the replacement instead.
  movedId = 0
  if code <= 0 or code.int > li.members.len:
    return false
  if pos < 0 or pos.int >= li.members[code.int - 1].len:
    return false
  if copyOnWrite:
    var fresh = cloneMembers(li.members[code.int - 1])
    let last = fresh.high
    if pos.int != last:
      movedId = fresh[last]
      fresh[pos.int] = movedId
    fresh.setLen(last)
    li.members[code.int - 1] = fresh
    return true
  let arr = addr li.members[code.int - 1]
  let last = arr[].high
  if pos.int != last:
    movedId = arr[][last]
    arr[][pos.int] = movedId
  arr[].setLen(last)
  true

proc contains*(li: LabelIndex, code: int32, id: int64): bool =
  if code <= 0 or code.int > li.members.len:
    return false
  for x in li.members[code.int - 1]:
    if x == id:
      return true
  false

proc members*(li: LabelIndex, code: int32): seq[int64] =
  ## A copy, not the live array. The planner iterates this while a write
  ## transaction may be appending to the same code, and a live reference
  ## would be a data race on a seq that can reallocate.
  if code <= 0 or code.int > li.members.len:
    return @[]
  li.members[code.int - 1]

proc count*(li: LabelIndex, code: int32): int =
  if code <= 0 or code.int > li.members.len:
    return 0
  li.members[code.int - 1].len

proc total*(li: LabelIndex): int =
  for m in li.members:
    result += m.len

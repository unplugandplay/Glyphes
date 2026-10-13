## glyphes — dense id allocation (STORAGE.md §1, S2)
##
## Ids start at 1: 0 is the "no record" sentinel that appears in
## `out_head`, `next_out`, and every arena offset, so it can never name a
## real object.
##
## Ids are stable for the life of an object and are NOT reused within a
## generation (STORAGE.md S2). Freed ids go on a free list, which
## `vacuum` drains when it compacts and renumbers. Reusing immediately
## would be faster and would break any host holding a `Glyphes::Node`
## across a delete — `WAL.md` §4.2 makes compaction the renumbering
## point, and that is the answer.

type
  IdAllocator* = object
    next*: int64         ## the next never-issued id
    free*: seq[int64]    ## released ids, LIFO
    issued*: int64       ## total ever issued, for accounting

proc initIds*(a: var IdAllocator) =
  ## next = 1, so the first id is 1 and 0 stays reserved.
  a.next = 1
  a.free = @[]
  a.issued = 0

proc alloc*(a: var IdAllocator): int64 =
  ## Never draws from the free list. STORAGE.md S2: an id is stable for
  ## its object's lifetime and is not recycled within a generation, so a
  ## host holding a Glyphes::Node across a delete is not silently
  ## repointed at whatever node later lands in that slot. Reclamation
  ## happens in `reclaim`, which compaction calls after renumbering.
  ##
  ## This costs array length in a create/delete-heavy workload, which is
  ## exactly why compaction exists (WAL.md §4.2) and why `free` is kept:
  ## it is the queue `reclaim` drains.
  result = a.next
  inc a.next
  inc a.issued

proc release*(a: var IdAllocator, id: int64) =
  ## Idempotent-ish: releasing an id twice pushes it twice, which the
  ## compaction pass tolerates but the invariant check reports. Silent
  ## tolerance here would hide a caller bug in the delete path.
  if id <= 0:
    return
  a.free.add id

proc liveCount*(a: IdAllocator): int64 {.inline.} =
  ## Ids currently in use. Equals the highest id issued minus the number
  ## released and not yet reclaimed.
  a.next - 1 - int64(a.free.len)

proc highestIssued*(a: IdAllocator): int64 {.inline.} = a.next - 1

proc advancePast*(a: var IdAllocator, last: int64) =
  ## Guarantee every id up to and including `last` will never be issued
  ## again. A transaction allocates ids from its own counter and calls
  ## this at commit *and* at rollback: a rolled-back transaction burns its
  ## ids, which STORAGE.md S2 permits and which is what keeps a rolled
  ## back id from colliding with a later commit's.
  if last >= a.next:
    a.next = last + 1

proc reclaim*(a: var IdAllocator, renumberedTo: int64) =
  ## Called by compaction after it has renumbered every live record
  ## densely. Every previously-issued id is now either reused by the new
  ## numbering or dead, so the free list is emptied and the counter
  ## rewound.
  a.free.setLen(0)
  a.next = renumberedTo + 1

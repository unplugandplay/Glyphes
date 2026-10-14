## glyphes — the range index (M6.1, INDEX.md §2).
##
## Sorted block array with chained leaves, an in-memory delta in front of
## it, and no global ordering. The shape is the one INDEX.md argues for:
## a block scan is one sequential read of one page, a point lookup touches
## one page, and a write is O(1) amortised because it appends to the delta
## rather than re-sorting anything.
##
## Sortedness is *per block*, not global — which is what makes writes cheap
## and range scans pay one extra indirection per block. That is the same
## trade the adjacency lists make (STORAGE.md §5), and taking it twice in
## one engine is worth saying out loud: both are the price of never doing an
## O(n) rebuild on the write path.
##
## ## The block size is arithmetic, not taste
##
## INDEX.md §2 says "4 KB, up to 512 entries". Those disagree for a
## numeric key: an entry is a `f64` key and an `int64` id — 16 bytes — so
## 4 KB holds 256 of them, and 512 entries would be 8 KB and two pages.
## The page size is the load-bearing half of the argument (a block scan is
## *one* miss, and a lookup is *one* page), so the block is sized to the
## page: `BlockEntries = 4096 / 16`. A string block is entries plus the
## strings themselves and so is larger than a page; its entry cap is the
## same because the cap exists to bound the binary search, not the read.
##
## ## What a lookup returns, and what it must never return
##
## `seek` hands back node (or relationship) ids in key order. It must never
## hand back a tombstoned id — pin I11, and the reason an approximate index
## is dangerous at all. Deletion therefore removes from the delta and, at
## merge time, drops the entry from its block rather than marking it: a
## tombstone in a block array costs a branch per comparison forever, and a
## merge is where the array is being rewritten anyway.

import std/[algorithm, sets, tables]
import ../store/prop

const
  ## Entries per block: 4096 bytes / (8-byte key + 8-byte id). See the
  ## header on why this is not 512.
  BlockEntries* = 256

type
  Block* = ref object
    ## One leaf. Sorted by key, `ids` parallel to `nums` or to `strs`.
    ##
    ## Two arrays rather than one variant array because a block is *mostly*
    ## one key type and a `seq[Value]` per entry would put a tag and a
    ## variant header on the hot comparison path for the sake of a mixed
    ## column that is rare enough to answer with two blocks.
    nums*: seq[float64]
    strs*: seq[string]
    ids*: seq[int64]
    next*: int64            ## next leaf's block id; **-1** = end of chain.
                            ## Not 0: block 0 is the head, so 0 cannot also
                            ## mean "no next" without a walk that returns to
                            ## the start forever — which is exactly what the
                            ## first merge did.
    stringKeys*: bool       ## which array holds the key

  RangeIndex* = ref object
    name*: string
    label*: string          ## "" = global (relationships)
    ## The indexed property's *name*. It was called `propType` through two
    ## drafts — the field holds "age", not "int" — and two call sites read
    ## it as a type before the name gave the game away.
    property*: string
    kind*: uint8            ## GLY_IDX_RANGE
    constraint*: uint8      ## none | unique | exists | not_null; TXN.md §5 makes
                           ## the constraint a client of this structure
    generation*: uint64
    blocks*: seq[Block]     ## id → block; block 0 is the chain head
    ## The write path lands here and nowhere else. `keys` is parallel to
    ## `ids`; a `vkNull` key means "this id is deleted", which is how a
    ## delete avoids a search and why the merge has to look at the key type
    ## rather than trust the value.
    ids*: seq[int64]
    keys*: seq[Value]
    ## Ids whose key was deleted, so a delete of an id that never had a key
    ## (a node without the property) still removes nothing and costs
    ## nothing.
    seen*: HashSet[int64]
    ## The key kind, decided by the first keyable value the index sees, and
    ## *kept*: a merge that has only deletions in its delta must not
    ## re-decide it. The first version derived the kind from the delta
    ## alone, so a delete-only merge on a string index rewrote every block
    ## as numeric — every surviving key became `0.0`, and the index went on
    ## answering with nothing. Silent, total, and found only by a review
    ## probe, because no test deleted from a string index.
    keyIsString*: bool
    keyDecided*: bool
    ## False once the column has shown a value this index cannot hold — a
    ## bool, a list, a map, a vector — or two kinds at once. A key that
    ## cannot be built is *omitted*, and an omitted row is a query that
    ## returns fewer rows with the index than without: the one failure the
    ## predicate-above-the-seek design cannot catch, because it guards
    ## against extra rows and never against missing ones. The planner skips
    ## an unusable index, which costs a scan and costs no answers.
    ## `index_rebuild` is the way back: it refills from live records and
    ## resets this.
    usable*: bool
    ## Position of each id in the delta, so an update to a value already
    ## there is O(1) instead of a walk of everything written since the last
    ## merge. The linear version was dead code in practice — `applyDelta`
    ## feeds ids from a Table — and a landmine for every caller after it.
    deltaPos: Table[int64, int]
    liveCount*: int64
    ## How many seeks this index has answered. Not a statistic anybody asks
    ## for; it is how a test asserts that the planner *used* the index
    ## rather than that the query happened to return the right rows. An
    ## index that is never read and a query that is fast look identical
    ## from outside, and only this tells them apart.
    probes*: int64

proc keyLess(a: Value, b: Value): bool =
  ## Total order for the two key kinds a range index holds, plus the
  ## deleted marker. `null` sorts last — a node that lost its property must
  ## not appear in a range scan that starts at a number.
  ##
  ## Both arguments must already be *normalised* (ints as floats, per
  ## `keyOf`). The API boundary does that once per lookup rather than here,
  ## because this runs once per comparison and the conversion is not free.
  if a.kind == vkNull: return false
  if b.kind == vkNull: return true
  if a.kind == vkString or b.kind == vkString:
    ## A mixed column: numbers before strings, as `cmpValues` orders them
    ## (CYPHER.md §6). Consistent rather than canonical: the two only meet
    ## in a property that changed type, and refusing that is a later slice.
    if a.kind != b.kind:
      return a.kind != vkString
    return a.s < b.s
  return a.f < b.f

proc keyOf*(v: Value): Value =
  ## Numbers are keyed as float64 whatever their width, so an int64 column
  ## and a float64 column of the same magnitude share one order. Exactness
  ## above 2^53 is the documented cost; i64 keys would need a tagged
  ## comparison on every merge.
  case v.kind
  of vkInt: Value(kind: vkFloat, f: float64(v.i))
  of vkFloat: v
  of vkString: v
  else: Value(kind: vkNull)

# --------------------------------------------- hashing normalised keys

proc keyHash*(v: Value): uint64 =
  ## A hash of the *normalised* key, so two values this index treats as the
  ## same key hash to the same bucket. The transaction's delta-side seek
  ## index uses it to find uncommitted rows without walking them.
  ##
  ## Normalisation first, always: an int64 `5` and a float64 `5.0` are the
  ## same key to this index (`keyOf`), so they must be the same bucket, or
  ## the lookup would miss a row the scan would have found.
  let k = keyOf(v)
  case k.kind
  of vkFloat:
    var bits = cast[uint64](k.f)
    bits
  of vkString:
    ## FNV-1a over the bytes, so the result depends only on the string's
    ## content and not on where it was allocated. `hash` from `hashes` is
    ## process-seeded and would make an index's bucket assignment differ
    ## between runs, which is harmless for a delta but would be a bad habit
    ## to copy into the committed index later.
    var h = 0xcbf29ce484222325'u64
    for ch in k.s:
      h = (h xor cast[uint64](ord(ch))) * 0x100000001b3'u64
    h
  else:
    0'u64

proc keySame*(a, b: Value): bool =
  ## Exact key equality — the tie-break a hash bucket needs. A collision
  ## must cost a comparison, never a wrong answer, so every candidate from
  ## a bucket is confirmed here before it is used.
  not keyLess(a, b) and not keyLess(b, a)

# ------------------------------------------------------------- block level

proc newBlock(stringKeys: bool): Block =
  Block(nums: @[], strs: @[], ids: @[], next: -1, stringKeys: stringKeys)

proc blockLen*(b: Block): int = b.ids.len

proc blockAt*(b: Block, i: int): Value =
  if b.stringKeys: Value(kind: vkString, s: b.strs[i])
  else: Value(kind: vkFloat, f: b.nums[i])

proc blockInsert(b: Block, key: Value, id: int64) =
  ## Append. Blocks are built already sorted (the merge writes them that
  ## way), so an insert into the middle is a shift — which is fine because
  ## the merge writes each entry exactly once.
  if b.stringKeys:
    b.strs.add (if key.kind == vkString: key.s else: "")
  else:
    b.nums.add (if key.kind == vkFloat: key.f else: 0.0)
  b.ids.add id

proc lowerBound(b: Block, key: Value): int =
  ## First index whose key is ≥ `key`. Binary search, because the block is
  ## sorted and a linear scan of 256 entries per lookup is the difference
  ## between one page touch and a page walk.
  var lo = 0
  var hi = b.ids.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if keyLess(blockAt(b, mid), key):
      lo = mid + 1
    else:
      hi = mid
  lo

# ---------------------------------------------------------------- the index

proc newRange*(name, label, property: string): RangeIndex =
  ## `label` empty means a global index over relationships; the range index
  ## does not care, and the distinction lives in the registry so that one
  ## code path serves both.
  result = RangeIndex(name: name, label: label, property: property,
                      kind: 0'u8, blocks: @[], ids: @[], keys: @[],
                      seen: initHashSet[int64](), usable: true,
                      deltaPos: initTable[int64, int]())

proc keyable*(v: Value): bool =
  ## The kinds a range index can hold. Everything else — bool, list, map,
  ## vector, bytes — has an order in `cmpValues` but no *place* in a block
  ## array, and pretending otherwise is how a column with one bool in it
  ## makes every query over the index lie by omission.
  v.kind == vkInt or v.kind == vkFloat or v.kind == vkString

proc putDelta(ix: RangeIndex, id: int64, key: Value) =
  ## One delta slot per id, replaced in place when it is already there: the
  ## merge would otherwise emit the id twice, and a lookup would return it
  ## twice.
  if ix.deltaPos.hasKey(id):
    let at = ix.deltaPos[id]
    ix.ids[at] = id
    ix.keys[at] = key
  else:
    ix.deltaPos[id] = ix.ids.len
    ix.ids.add id
    ix.keys.add key
  ix.seen.incl id

proc insert*(ix: RangeIndex, id: int64, value: Value) =
  ## One write's worth of work: append to the delta. Amortised O(1), and
  ## the merge is the only place that sorts anything.
  let k = keyOf(value)
  if not keyable(value):
    ## A stored `null` is an absent key — the ordinary case, and a delete
    ## of whatever the index held. Any *other* unkeyable kind means the
    ## column holds something this structure cannot order, and an index
    ## that silently omits it returns fewer rows than the scan does. That
    ## is the one wrong answer this design cannot catch from above, so the
    ## index disqualifies itself and the planner goes back to scanning.
    if value.kind != vkNull:
      ix.usable = false
    ix.putDelta(id, Value(kind: vkNull))
    return
  if ix.keyDecided and (k.kind == vkString) != ix.keyIsString:
    ## Two kinds in one column. A block is homogeneous, so the second kind
    ## cannot be stored — and storing it as the first kind's zero value is
    ## not "a documented cost", it is a key that compares as 0.0 or ""
    ## forever. Same answer as above: the index stands down.
    ix.usable = false
    ix.putDelta(id, Value(kind: vkNull))
    return
  if not ix.keyDecided:
    ix.keyDecided = true
    ix.keyIsString = k.kind == vkString
  ix.putDelta(id, k)

proc delete*(ix: RangeIndex, id: int64) =
  ## A `vkNull` key marks the deletion. The merge drops the entry from its
  ## block; until then a lookup skips it by way of the pending-delete set.
  ix.putDelta(id, Value(kind: vkNull))

proc has*(ix: RangeIndex, id: int64): bool =
  id in ix.seen

proc reset*(ix: RangeIndex) =
  ## Empty the index and un-decide everything a refill is allowed to
  ## re-decide. `rebuild` is the caller: it reads the records again, so the
  ## key kind and the usability verdict are made again — which is also the
  ## way back from a disqualification, because a column that has since been
  ## cleaned up indexes again. The first version reset the blocks from the
  ## registry and left `keyDecided`/`usable`/`deltaPos` behind: a rebuilt
  ## index inherited a decision its own refill then contradicted, and the
  ## `deltaPos` entries pointed at ids that no longer existed.
  ix.blocks = @[]
  ix.ids = @[]
  ix.keys = @[]
  ix.seen = initHashSet[int64]()
  ix.deltaPos = initTable[int64, int]()
  ix.liveCount = 0
  ix.keyDecided = false
  ix.usable = true

proc merge*(ix: RangeIndex) =
  ## Fold the delta into the block chain: sort the delta by key, then walk
  ## it and the existing chain together, writing new blocks as they fill.
  ## Every entry is written exactly once, so no id is duplicated and no
  ## block is patched after the fact.
  if ix.ids.len == 0:
    return
  var order = newSeq[int](ix.ids.len)
  for i in 0 ..< order.len:
    order[i] = i
  order.sort(proc (a, b: int): int =
    let ka = ix.keys[a]
    let kb = ix.keys[b]
    if keyLess(ka, kb): -1
    elif keyLess(kb, ka): 1
    else: 0)

  ## One key kind per merge, and it is the *index's* kind, decided when the
  ## first keyable value arrived — never re-derived from the delta. A merge
  ## whose delta is all deletions has no live key to ask, and deriving the
  ## kind from `vkNull` entries made every block numeric: the delete-only
  ## merge on a string index rewrote nine surviving keys as 0.0 and kept
  ## answering with nothing.
  let stringKeys =
    (if ix.keyDecided: ix.keyIsString
     elif ix.blocks.len > 0: ix.blocks[0].stringKeys
     else: false)

  ## Ids the delta mentions. The delta *overrides* the chain: without this
  ## an update emits both the old entry and the new one, and a delete emits
  ## the old entry and comes back from the dead. Both were wrong answers
  ## rather than crashes, which is the kind that survives a test written
  ## against the code rather than against the rule.
  var touched = initHashSet[int64]()
  for id in ix.ids:
    touched.incl id

  var newBlocks: seq[Block] = @[]
  var leaf = newBlock(stringKeys)

  proc emit(key: Value, id: int64) =
    if key.kind == vkNull:
      ## Deleted in the delta: never indexed, and whatever the chain still
      ## holds for this id is skipped by construction because the delta
      ## entry carries the deletion.
      return
    blockInsert(leaf, key, id)
    if blockLen(leaf) >= BlockEntries:
      leaf.next = int64(newBlocks.len + 1)
      newBlocks.add leaf
      leaf = newBlock(stringKeys)

  var oldId = 0'i64
  var oldPos = 0
  var di = 0
  while true:
    var haveOld = false
    var oldKey = Value(kind: vkNull)
    if oldId >= 0 and oldId < ix.blocks.len and oldPos < blockLen(ix.blocks[oldId]):
      haveOld = true
      oldKey = blockAt(ix.blocks[oldId], oldPos)
    let haveDel = di < order.len
    if not haveOld and not haveDel:
      break
    if haveDel and ix.keys[order[di]].kind == vkNull:
      inc di
      continue
    let takeDelta =
      if not haveOld: true
      elif not haveDel: false
      else: keyLess(ix.keys[order[di]], oldKey)
    if takeDelta:
      emit(ix.keys[order[di]], ix.ids[order[di]])
      inc di
    else:
      let oldIdValue = ix.blocks[oldId].ids[oldPos]
      if oldIdValue notin touched:
        emit(oldKey, oldIdValue)
      inc oldPos
      if oldPos >= blockLen(ix.blocks[oldId]):
        oldId = ix.blocks[oldId].next
        oldPos = 0
  if blockLen(leaf) > 0:
    leaf.next = -1
    newBlocks.add leaf

  ix.blocks = newBlocks
  ix.ids = @[]
  ix.keys = @[]
  ix.seen = initHashSet[int64]()
  ix.deltaPos = initTable[int64, int]()
  ix.liveCount = 0
  for b in ix.blocks:
    ix.liveCount += int64(blockLen(b))

proc entryCount*(ix: RangeIndex): int64 =
  ## Live entries, delta included. Counted from the blocks rather than
  ## cached: the first version kept `liveCount` and it drifted the moment
  ## anything touched the blocks without going through `merge`, which is
  ## how `index_list` reported 100 entries for an index with none.
  var n = 0'i64
  for b in ix.blocks:
    n += int64(blockLen(b))
  for i in 0 ..< ix.ids.len:
    if ix.keys[i].kind != vkNull:
      inc n
  n

proc pendingDeletes(ix: RangeIndex): HashSet[int64] =
  ## The ids the delta currently holds as deleted, built once per seek.
  ##
  ## A seek walks blocks that were written before the delete landed, so
  ## without this the entry survives until the next merge — pin I11 says a
  ## deleted node is *never* returned, and "until the next merge" is a
  ## return. Built once rather than tested per candidate because a range
  ## scan asks the question for every entry it touches, and the first
  ## version did a linear walk of the delta each time — O(matches ×
  ## delta), which is the kind of cost that only shows on a big delete.
  result = initHashSet[int64]()
  for i in 0 ..< ix.ids.len:
    if ix.keys[i].kind == vkNull:
      result.incl ix.ids[i]

proc inRange(k, lo, hi: Value, inclusiveHi: bool): bool =
  ## `lo` or `hi` of `null` means *unbounded on that side* — and that has to
  ## be tested, not left to `keyLess`. `null` sorts above everything, so
  ## `keyLess(k, null)` is true for every k: an unbounded lower bound would
  ## exclude every row and an unbounded upper bound would exclude nothing.
  if k.kind == vkNull:
    return false
  if lo.kind != vkNull and keyLess(k, lo):
    return false
  if hi.kind == vkNull:
    return true
  (if inclusiveHi: not keyLess(hi, k) else: keyLess(k, hi))

proc collect*(ix: RangeIndex, loKey, hiKey: Value, inclusiveHi: bool): seq[int64] =
  let lo = keyOf(loKey)
  let hi = keyOf(hiKey)
  ## Ids with `lo <= key <= hi` (or `< hi` when `inclusiveHi` is false).
  ##
  ## The delta is scanned and the chain is walked once. The delta's rows are
  ## not sorted: a *read* that sorted them would mutate the index, and a
  ## reader that reorders a structure is how a concurrent reader sees a
  ## half-built one. Cypher leaves row order unspecified without an
  ## `ORDER BY`, and the planner's sort sits above either path.
  inc ix.probes
  result = @[]
  for i in 0 ..< ix.ids.len:
    if inRange(ix.keys[i], lo, hi, inclusiveHi):
      result.add ix.ids[i]
  let gone = pendingDeletes(ix)
  for b in ix.blocks:
    ## An unbounded lower bound starts at the head. `lowerBound(null)` is
    ## the *end* of the block — that is what "first key ≥ null" means — so
    ## asking for it returned nothing at all.
    var i = (if lo.kind == vkNull: 0 else: lowerBound(b, lo))
    while i < blockLen(b):
      let k = blockAt(b, i)
      ## The same null rule as `inRange`, not a second copy of it. The walk
      ## computed `not keyLess(k, null)` — true for every k, since null
      ## sorts above everything — and so treated *every* entry as past an
      ## unbounded exclusive end, while `inRange` accepted them all. The two
      ## halves of one query disagreed about what "unbounded" means.
      let past = (if hi.kind == vkNull: false
                  elif inclusiveHi: keyLess(hi, k)
                  else: not keyLess(k, hi))
      if past:
        break
      if b.ids[i] notin gone:
        result.add b.ids[i]
      inc i

proc seekEq*(ix: RangeIndex, rawKey: Value): seq[int64] =
  let key = keyOf(rawKey)
  ## Every id whose key equals `key` — all of them, since a column with
  ## duplicates is the normal case and a `= ` that returns one row is a
  ## silent data loss.
  inc ix.probes
  result = @[]
  for i in 0 ..< ix.ids.len:
    let k = ix.keys[i]
    if k.kind != vkNull and not keyLess(k, key) and not keyLess(key, k):
      result.add ix.ids[i]
  let gone = pendingDeletes(ix)
  for b in ix.blocks:
    let lo = lowerBound(b, key)
    var i = lo
    while i < blockLen(b):
      let k = blockAt(b, i)
      if keyLess(key, k):
        break
      if not keyLess(k, key) and b.ids[i] notin gone:
        result.add b.ids[i]
      inc i

proc ids*(ix: RangeIndex): seq[int64] =
  ## Every *live* indexed id, in key order — a deleted id is not indexed,
  ## whether the deletion is still in the delta or already folded away.
  ## What a rebuild uses to fill a fresh index, and what a diagnostic
  ## prints.
  result = @[]
  let gone = pendingDeletes(ix)
  for b in ix.blocks:
    for id in b.ids:
      if id notin gone:
        result.add id
  for i in 0 ..< ix.ids.len:
    if ix.keys[i].kind != vkNull:
      result.add ix.ids[i]

proc blockStats*(ix: RangeIndex): (int, int, int) =
  ## (blocks, entries, largest block) — the shape an operator reading a
  ## query plan wants, and what the tests assert a split on.
  var largest = 0
  for b in ix.blocks:
    largest = max(largest, blockLen(b))
  (ix.blocks.len, entryCount(ix).int, largest)
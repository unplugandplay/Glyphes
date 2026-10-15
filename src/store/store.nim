## glyphes — the graph store (STORAGE.md)
##
## M1 scope: dense ids, the two record types, threaded adjacency in both
## directions, three dictionaries, property slots over an arena, and the
## label index. No WAL — durability is M2 (WAL.md) and this is the
## structure it will log.
##
## The invariant this file exists to maintain is S4: `out_count` and
## `in_count` are maintained eagerly on every edge create and delete, and
## must equal a brute-force recount. A drift there corrupts the planner's
## hub detection silently, which is the worst kind of bug, so the degree
## recount is its own test rather than a consequence of the others.

import std/[strutils, tables, atomics, locks]
import ./arena
import ./ids
import ./dict
import ./prop
import ./node
import ./edge
import ./label
import ./revision
import ./vhist

export Value, ValueKind, GlyType, SlotInline
export NodeRec, EdgeRec, PropSlot, PropView, newNode, newEdge
export NodeFlag, EdgeFlag, setFlag, clearFlag
export propType, elementCount, fitsInline, packInline, encodeValue,
  decodeValue, SlotNull, SlotDirty, SlotInline, InitialSlotCapacity
export IdAllocator, initIds, alloc, release, advancePast, reclaim,
  highestIssued, liveCount
export Dictionary, initDict, intern, lookup, nameOf
export LabelIndex, initLabels, add, remove, contains, count, members, total
export live, degree, outDegree, inDegree, propView, setPropView, hasFlag
export Arena, initArena, alloc, ptrAt, putBlob, getBlob, copyIn, read, used,
  ArenaFirstOffset, ArenaAlign
export setProp, removeProp, clearProps, readSlots, decodeInlineValue

type
  Published* = ref object
    ## The four arrays a reader needs, published as **one** value.
    ##
    ## They were separate fields on the store and committed assigned each
    ## in turn, which is four stores and therefore four generations from a
    ## reader's point of view: a reader that loaded `nodes` between the
    ## first assignment and the third saw a new record array beside an old
    ## `labelPos`. The soak found exactly that — a node reporting
    ## `outCount 139264`, a value assembled from two generations.
    ##
    ## Publishing one reference makes the whole set atomic, which is the
    ## only thing that actually delivers pin X3. Splitting them back out
    ## for the sake of the `s.nodes` field name is not worth a torn read.
    generation*: uint64
    nodes*: seq[NodeRec]
    edges*: seq[EdgeRec]
    labelPos*: seq[int32]
    members*: seq[seq[int64]]

type
  GraphStore* = ref object
    nodes*: seq[NodeRec]
    edges*: seq[EdgeRec]
    ## Non-zero while a write transaction holds the single writer claim
    ## (TXN.md §1). The claim lives on the store rather than in a module
    ## global so it cannot outlive or precede the store it protects.
    writer*: uint32
    ## Monotonic from 1 (TXN.md X4). Bumped once per commit. A statement
    ## captures it at prepare and holds it until close; 0 is reserved so
    ## a zeroed GlyStat never reads as a valid generation.
    generation*: uint64
    arena*: Arena
    ## The version history (VERSIONING-PLAN V0.2). In-memory only until V1
    ## gives it the `.vhist` sidecar; the shape is the same either way, which
    ## is the point of proving it without a file behind it.
    ##
    ## On the store rather than the transaction because history outlives any
    ## one transaction and because the revision store is single-writer, the
    ## same way this store is: `commit` opens, fills and seals one revision
    ## commit inside the write exclusion, so the two writers cannot drift.
    history*: Revisions
    ## The open `<db>.vhist` sidecar, or nil for a memory database and for
    ## a read-only open. Written inside the transaction's fsync (PRD §4.1),
    ## before the log's COMMIT frame, so history is never behind the graph.
    vhistFile*: VhistFile
    ## The path history is sidecar'd to, or "" when there is none.
    vhistPath*: string
    ## The generation the last committed history frame was written against.
    ## A replay stops at the first frame above it, which is what repairs a
    ## crash between the history append and the log's COMMIT frame.
    histGeneration*: uint64
    nodeIds*: IdAllocator
    edgeIds*: IdAllocator
    labels*: Dictionary
    relTypes*: Dictionary
    propKeys*: Dictionary
    labelIndex*: LabelIndex
    labelPos*: seq[int32]
    ## Index of each node within its label's member list, or -1. Kept
    ## here rather than in NodeRec so the pinned 48-byte layout and the
    ## snapshot's node section are untouched; it costs 4 bytes per node
    ## and buys O(1) label removal (label.nim's header explains why the
    ## alternative is quadratic).
    ## Read snapshots currently outstanding. A commit that finds this
    ## non-zero cannot mutate the published arrays in place, so it copies
    ## and swaps (TXN.md §3.1 step 7).
    ## Read-side lock, shared by every reader and held for the whole
    ## snapshot's life. The write-side lock is `pubLock`.
    ##
    ## These replace a reader *counter* and the copy-on-write path it
    ## gated. The counter version was wrong three ways over, all of them
    ## check-then-act: the writer sampled `activeReaders == 0` and began
    ## mutating the published arrays in place, and a reader could register
    ## in the window between that sample and the mutation — and then read
    ## the arrays while they were being rewritten. A lock removes the
    ## window by construction.
    ##
    ## It also removes the copy. With no reader able to run during a merge,
    ## an in-place mutation is unobservable, so there is nothing to copy
    ## for — which matters, because at 10⁶ nodes the copy was 48 MB per
    ## commit and would have made bulk import unusable.
    ##
    ## A reader gate: a counter and a condition, not a mutex.
    ##
    ## It replaced a single mutex held for a reader's whole snapshot and for
    ## a writer's whole merge. That mutex guaranteed what it was built to
    ## guarantee — a reader and a merge can never overlap, so no copy is
    ## needed — but it also made readers serialise against *each other*,
    ## and worse: a non-reentrant mutex means a *second* `beginRead` on the
    ## same thread deadlocks rather than waits. One statement at a time is
    ## not a limitation the API can hide, because `db.query` returns a lazy
    ## result set: a caller who consumes half of it and asks another query
    ## blocks the engine forever.
    ##
    ## So: `beginRead` increments and returns without waiting, so readers
    ## are concurrent (TXN.md §1's "unbounded, lock-free against each
    ## other", restored), and `beginWrite` waits for the count to reach zero
    ## before touching the arrays. The guarantee that matters — a merge
    ## never overlaps a reader, so the arena cannot move under a snapshot —
    ## is unchanged, because a writer still has all of them out.
    pubLock*: Lock        ## guards the four fields below, nothing else
    readers*: int         ## snapshots currently open
    writerInside*: bool   ## a merge is mutating the arrays
    writerWaiting*: bool  ## a merge wants in; new readers queue behind it
    readerDone*: Cond     ## signalled when the count reaches zero
    ## point: a `if writer != 0` followed by `writer = id` is a
    ## check-then-act race, and two writers both passed it. The loser must
    ## see `GLY_ERR_BUSY`; the soak caught the alternative, where both
    ## entered and one committed on a base the other had already replaced.
    writerClaim*: Atomic[uint32]
    ## Commits that took the copy-on-write path. Not needed for
    ## correctness; it exists so a test can assert that the no-reader case
    ## really does skip the copy, which is otherwise invisible from the
    ## outside and is the difference between a viable bulk import and an
    ## unusable one.
    cowCopies*: int
    ## The published bundle. Everything a reader observes, swapped as one
    ## reference.
    published*: Published
    ## "A direct write has moved the arrays since the last publish."
    ##
    ## This exists because there are two writers. The transactional path
    ## merges and publishes at the end of the commit, so its bundle is
    ## always current. The *direct* path — `createNode`, `deleteNode`,
    ## `setNodeProp`, everything the tests and the benchmark use — mutates
    ## the arrays in place and has no commit to publish at, so without a
    ## flag the bundle drifts: `beginRead` hands a reader a bundle whose
    ## array is not even the array the store is writing to any more, and the
    ## reader silently misses every write since the last growth.
    ##
    ## Publishing on every direct write instead would cost a `Published`
    ## object plus five sequence copies per insert — about 100 bytes per
    ## node, which at 10^6 nodes is 100 MB of garbage the M1 budget has to
    ## pay for. Setting a flag per write and publishing once per *statement*
    ## moves that cost from the write path to the read path, where there is
    ## one publish per query rather than per node.
    dirty*: bool
    ## (The lock and its rationale are documented with the reader gate
    ## above; `pubLock` guards `published` and the three gate fields, and is
    ## never held across real work.)

## deleteNode needs deleteEdge (a cascading delete takes the edges
## first), and deleteEdge needs the node tables, so one of the two must be
## forward-declared. Forward-declaring rather than reordering keeps the
## file readable in dependency order: nodes, then edges, then traversal.
proc deleteEdge*(s: GraphStore, id: int64): bool

proc publishImpl(s: GraphStore) =
  ## The bundle is built separately and then assigned to the field.
  ## Publish the current arrays and generation as one value. This single
  ## assignment is the commit's visibility point (TXN.md §3.1 step 8).
  ##
  ## Rather than allocated in place with `new(s.published)`: filling a field
  ## in place is a series of stores, and a reader that loaded the field
  ## during it would see a half-built bundle.
  var p: Published
  new(p)
  p.generation = s.generation
  p.nodes = s.nodes
  p.edges = s.edges
  p.labelPos = s.labelPos
  p.members = s.labelIndex.members
  ## No lock taken here, and that is load-bearing: `ensureNodeSlots` calls
  ## this from inside the merge, which already holds the lock, and the
  ## mutex is not reentrant. Constructing the bundle outside and assigning
  ## it is what makes the publish atomic — filling the field in place
  ## would be a run of stores a reader could observe halfway.
  s.published = p
  ## Every array in the bundle now matches the store's, so a reader that
  ## arrives before the next write needs no publish of its own.
  s.dirty = false

proc newStore*(arenaCapacity: int = 1 shl 20): GraphStore =
  ## One database per process (PRD pin P1), so the store *is* the
  ## database's state rather than one of several.
  new(result)
  initLock(result.pubLock)
  initCond(result.readerDone)
  result.readers = 0
  result.writerInside = false
  result.writerWaiting = false
  initArena(result.arena, arenaCapacity)
  result.history = initRevisions()
  initIds(result.nodeIds)
  initIds(result.edgeIds)
  initDict(result.labels)
  initDict(result.relTypes)
  initDict(result.propKeys)
  initLabels(result.labelIndex, 1)
  # Ids are 1-based and array index is id - 1 (STORAGE.md S2), so slot 0
  # of both arrays is a permanently dead placeholder. Keeping it means
  # the hot path is `nodes[id.int - 1]` with no branch for id == 0, and
  # a zeroed slot can never be mistaken for a live record.
  result.nodes.setLen(1)
  result.edges.setLen(1)
  result.labelPos = @[-1]
  result.generation = 1
  # The lock exists but is not held: this is construction, single-threaded
  # by definition. `publishImpl` takes no lock of its own precisely so that
  # `ensureNodeSlots` can call it from inside a merge that already holds
  # one.
  publishImpl(result)

# ---------------------------------------------------------- read snapshots

type
  ReadSnapshot* = ref object
    ## A reader's pinned view of one generation (TXN.md §2). Holds the
    ## published bundle by reference, so the store can move on.
    pub*: Published
    store*: GraphStore
    generation*: uint64
    released*: bool

## `lent` on all four is not a style choice and dropping it costs a copy of
## the whole array on every access. A `seq` returned by value from a proc is
## copied, and the C the accessor generated without `lent` was
## `eqcopy(&result, r.pub.nodes)` — a full `memmove` of the node array. The
## M4 query benchmark found it: one `nodes[i]` lookup at 2*10^4 nodes cost
## 77 us, which made a 64-row label scan take 10 ms and the query path
## ~300x slower than the work actually in it. `snap.nodes[5].live` has to
## compile to a bounds check and a load, which is what `lent` is for.
proc nodes*(r: ReadSnapshot): lent seq[NodeRec] {.inline.} = r.pub.nodes
proc edges*(r: ReadSnapshot): lent seq[EdgeRec] {.inline.} = r.pub.edges
proc labelPos*(r: ReadSnapshot): lent seq[int32] {.inline.} = r.pub.labelPos
proc members*(r: ReadSnapshot): lent seq[seq[int64]] {.inline.} = r.pub.members

proc beginRead*(s: GraphStore): ReadSnapshot =
  ## Open a read snapshot, registered until `endRead`. Never waits.
  ##
  ## A snapshot and a merge cannot overlap because a writer waits for the
  ## reader count to reach zero, not because a reader holds a lock. The
  ## earlier design did the opposite — one mutex for both — and the M3
  ## version before that sampled a reader *counter* and copied the arrays
  ## when it read zero; a reader could register in the window between that
  ## sample and the merge, and then read the arrays while they were being
  ## rewritten. A counter that a writer *waits on* has no such window.
  s.pubLock.acquire()
  ## Wait out a merge, and queue behind one that is *waiting*.
  ##
  ## Waiting for `writerInside` alone is the half that is easy to forget when
  ## the reader side stops taking a lock: `beginWrite` waits for readers to
  ## leave, and this has to wait for the writer to finish, or a reader
  ## barges into arrays the merge is rewriting in place.
  ##
  ## `writerWaiting` is the other half, and it is why this is a
  ## writer-priority gate rather than a plain counter. Without it, six
  ## readers in a loop keep `readers` above zero forever — each arrives
  ## before the last has left — and the writer never gets in at all. The
  ## sample of the first hung soak showed both writers parked in
  ## `beginWrite` while every reader sailed straight through. Once a writer
  ## is waiting, new readers wait for it; readers already inside finish
  ## normally, so a long snapshot delays the writer by its own length and
  ## no further.
  while s.writerInside or s.writerWaiting:
    wait(s.readerDone, s.pubLock)
  ## Republish if a direct write has moved the arrays since the last publish.
  ## Without this a reader gets the bundle as it was, and "as it was" can be
  ## one growth step ago — which is how a query over five nodes returned
  ## three.
  if s.dirty:
    publishImpl(s)
  inc s.readers
  new(result)
  result.store = s
  result.pub = s.published
  result.generation = s.published.generation
  s.pubLock.release()

proc endRead*(snap: ReadSnapshot) =
  ## Idempotent on purpose. A statement closed twice — an error path that
  ## closes, then a `defer` that closes again — would otherwise decrement
  ## the reader count twice, and the count would reach zero while another
  ## reader was still inside the arrays; the next merge would then mutate
  ## them under it.
  if snap.isNil or snap.released:
    return
  snap.released = true
  ## `snap.store` is used inline rather than bound to a local, and that is
  ## not a style choice. Binding it would write the store's refcount —
  ## which ORC does not make atomic — from every reader thread at once,
  ## before this proc has taken any lock. ThreadSanitizer pinned exactly
  ## that: `endRead`'s `let s = snap.store` racing another reader's
  ## `beginRead` on the header word. Field access chains (`snap.store.x`)
  ## borrow rather than copy, so they touch nothing.
  snap.store.pubLock.acquire()
  ## Drop the bundle *inside* the gate. A Nim `ref` refcount is not atomic
  ## and a snapshot's is decremented when the collector gets to it, which
  ## would be after this unlock and therefore concurrent with a writer
  ## publishing — two threads moving one refcount corrupts it, the bundle
  ## is freed while still published, and the next allocation anywhere
  ## segfaults. Clearing the field here settles the count where nothing else
  ## can be touching it.
  snap.pub = nil
  dec snap.store.readers
  if snap.store.readers == 0:
    ## Broadcast, not signal — and this is the subtle one. Three kinds of
    ## thread wait on this condition: a writer waiting to merge, a reader
    ## queued behind that writer, and another writer. A single `signal` can
    ## wake the *wrong* one: the queued reader re-checks its predicate,
    ## sees `writerWaiting` still set, and goes back to sleep — and the
    ## writer, never woken, sleeps forever with the reader count at zero.
    ## That is a permanent three-way deadlock that looks exactly like
    ## writer starvation from the outside. Every waiter re-checks its own
    ## predicate, so waking them all is always safe and occasionally
    ## necessary.
    broadcast(snap.store.readerDone)
  snap.store.pubLock.release()

proc claimWriter*(s: GraphStore, id: uint32): bool =
  ## Take the single-writer claim, or report that someone else has it.
  ## One compare-and-swap, so there is no window between the test and the
  ## write — and the result is *returned*, because discarding it made every
  ## claim succeed, which is the same bug in the other direction.
  ##
  ## The compare-and-swap runs on `s.writerClaim` itself. `Atomic[T]` is a
  ## value type, so the obvious `var loc = s.writerClaim` would perform the
  ## exchange on a *copy* — which always succeeds, and made two writers
  ## believe they both held the claim.
  var expected = 0'u32
  s.writerClaim.compareExchange(expected, id)

proc releaseWriter*(s: GraphStore) =
  s.writerClaim.store(0'u32)

proc publish*(s: GraphStore) =
  ## Publish the current arrays and generation as one value: the commit's
  ## visibility point (TXN.md §3.1 step 8).
  ##
  ## Takes the gate lock itself, because under the reader gate the merge is
  ## *not* holding it: `beginWrite` sets `writerInside` and releases, so
  ## readers are excluded from the arrays but `beginRead` is still free to
  ## read the `published` field this proc replaces. The first soak run after
  ## the gate landed died exactly there — a reader capturing a bundle while
  ## the merge was mid-assignment. `publishImpl` stays lock-free because
  ## `beginRead` calls it with the lock already held, and a non-reentrant
  ## lock means one of the two callers has to be the naked one.
  s.pubLock.acquire()
  publishImpl(s)
  s.pubLock.release()

proc beginWrite*(s: GraphStore) =
  ## Exclude every reader for the duration of a merge.
  ##
  ## Waits on the *predicate*, not on a lock: readers that arrive while a
  ## writer waits must not be able to sneak in, which is the difference
  ## between a counter with a condition and a counter with a poll. The
  ## writer claim has already guaranteed a single writer, but the
  ## `writerInside` check is kept because it costs a compare and turns a
  ## logic error into a wait rather than two writers inside the arrays.
  s.pubLock.acquire()
  ## `wait` re-acquires the lock around each sleep, so the predicate is
  ## re-checked on every wake-up: a reader that arrives while the writer is
  ## asleep increments the count and the writer keeps waiting. That is the
  ## whole difference between a condition and a poll.
  while s.readers > 0 or s.writerInside:
    wait(s.readerDone, s.pubLock)
  s.writerInside = true
  s.pubLock.release()

proc endWrite*(s: GraphStore) =
  s.pubLock.acquire()
  s.writerInside = false
  ## Broadcast, not signal: readers *and* the next writer both wait on this
  ## condition, and a single signal could wake a reader, which would then
  ## wait again for a writer that was never woken. The predicate re-check
  ## makes the extra wakeups harmless.
  broadcast(s.readerDone)
  s.pubLock.release()

proc prepareForWrite*(s: GraphStore) {.inline.} =
  ## Kept as a name because the merge's shape reads better with it, and
  ## because it is where the copy used to live. It now does nothing: with
  ## `beginWrite` excluding readers for the whole merge, an in-place
  ## mutation cannot be observed, so there is nothing to copy.
  discard

proc ensureNodeSlots*(s: GraphStore, id: int64) =
  ## Both arrays are indexed by id, so they grow together. Kept as one
  ## proc because a node id past the end of one and inside the other is
  ## exactly the kind of half-updated state that shows up as a mystery.
  if s.nodes.len > id.int:
    return
  let firstNew = max(1, s.nodes.len)
  let want = max(id.int + 1, s.nodes.len * 2)
  s.nodes.setLen(want)
  if s.labelPos.len < want:
    s.labelPos.setLen(want)
    for i in firstNew ..< s.labelPos.len:
      # New slots start at -1 ("not in any label"), not 0, because 0 is a
      # valid position.
      s.labelPos[i] = -1
  s.publish()

proc nodeExists*(s: GraphStore, id: int64): bool =
  id > 0 and id.int < s.nodes.len and s.nodes[id.int].live

proc edgeExists*(s: GraphStore, id: int64): bool =
  id > 0 and id.int < s.edges.len and s.edges[id.int].live

proc detachFromLabel*(s: GraphStore, nodeId: int64, code: int32) =
  ## O(1) removal plus a fixup for whichever member was shifted into the
  ## hole. `code == 0` means unlabelled, which is never in the index.
  ##
  ## `dirty` for the same reason as `attachToLabel`: the member list and
  ## `labelPos` are both in the published bundle.
  if code == 0 or nodeId <= 0 or nodeId.int >= s.labelPos.len:
    return
  var moved: int64 = 0
  if s.labelIndex.remove(code, s.labelPos[nodeId.int], moved) and moved != 0:
    if moved.int < s.labelPos.len:
      s.labelPos[moved.int] = s.labelPos[nodeId.int]
  if nodeId.int < s.labelPos.len:
    s.labelPos[nodeId.int] = -1
  ## The member list and `labelPos` are both in the bundle.
  s.dirty = true

proc attachToLabel*(s: GraphStore, nodeId: int64, code: int32) =
  ## Appends to the label's member list, which is inside the published
  ## bundle — so every caller marks the store dirty. Marked here rather than
  ## only in the callers so a new call site cannot forget.
  if code == 0 or nodeId <= 0:
    return
  s.labelIndex.ensureCode code
  if nodeId.int >= s.labelPos.len:
    return
  s.labelPos[nodeId.int] = s.labelIndex.add(code, nodeId)
  s.dirty = true

proc createNode*(s: GraphStore, labelName: string): int64 =
  ## Creates and returns the new node's id. The label is interned here so
  ## callers pass a name, not a code: no caller has a reason to hold a
  ## code, and a caller that could would be one more place to forget that
  ## codes are dictionary-scoped.
  let id = s.nodeIds.alloc()
  s.ensureNodeSlots id
  let code = if labelName.len == 0: 0'i32 else: s.labels.intern(labelName)
  s.nodes[id.int] = newNode(id, code)
  s.attachToLabel id, code
  ## The record was written *after* `ensureNodeSlots` published, so the
  ## bundle is stale again — and its array is the pre-growth buffer, which
  ## does not even contain this record.
  s.dirty = true
  id

proc setLabel*(s: GraphStore, nodeId: int64, labelName: string): bool =
  ## Replaces a node's label. One label per node (CYPHER.md C13).
  if nodeId <= 0 or nodeId.int >= s.nodes.len:
    return false
  if not s.nodeExists(nodeId):
    return false
  s.detachFromLabel nodeId, s.nodes[nodeId.int].label
  let code = if labelName.len == 0: 0'i32 else: s.labels.intern(labelName)
  s.nodes[nodeId.int].label = code
  s.attachToLabel nodeId, code
  true

proc node*(s: GraphStore, id: int64): NodeRec =
  ## A *copy*. Handing out a pointer into `nodes` would dangle the moment
  ## the array reallocates on the next create, and STORAGE.md S11 makes
  ## "operators hold ids, never pointers" the rule for exactly this
  ## reason. Reads are array subscripts; a copy is 48 bytes and the
  ## caller writes it back through a mutating proc.
  ##
  ## A tombstoned node reads back as the zeroed record, not as its
  ## former contents. Returning a dead record would let a caller that
  ## forgot to check `nodeExists` keep reading a node's old properties
  ## and get plausible-looking answers; id 0 fails loudly instead.
  ## `nodeExists` remains the honest test for existence.
  if id <= 0 or id.int >= s.nodes.len or not s.nodes[id.int].live:
    return NodeRec(id: 0)
  s.nodes[id.int]

proc nodeCount*(s: GraphStore): int64 =
  ## Counts live records rather than subtracting tombstones from the array
  ## length, because array doubling leaves zeroed tail slots that are
  ## neither live nor tombstones. O(V); `stat` is a diagnostic, and M3's
  ## generation counter makes the cheap version possible if this ever
  ## shows up in a profile.
  var n: int64 = 0
  for i in 1 ..< s.nodes.len:
    if s.nodes[i].live:
      inc n
  n

proc deleteNode*(s: GraphStore, id: int64, cascade: bool): bool =
  ## Without `cascade`, a node that still has edges is refused and the
  ## caller reports DETACH DELETE (CYPHER.md §3.3). With it, the edges
  ## go first — always, so no reader can observe a half-detached node
  ## (STORAGE.md S2.3: tombstone unlinks immediately).
  if id <= 0 or id.int >= s.nodes.len:
    return false
  if not s.nodes[id.int].live:
    return false
  let n = s.nodes[id.int]
  if n.degree != 0 and not cascade:
    return false
  if cascade:
    var e = n.outHead
    while e != 0:
      let rec = s.edges[e.int]
      let nxt = rec.nextOut
      discard s.deleteEdge(e)
      e = nxt
    e = n.inHead
    while e != 0:
      let rec = s.edges[e.int]
      let nxt = rec.nextIn
      discard s.deleteEdge(e)
      e = nxt
  var dead = n
  var pv = dead.propView
  s.arena.clearProps pv
  dead.setPropView pv
  dead.clearFlag nfHasProps
  dead.setFlag nfTombstone
  s.nodes[id.int] = dead
  ## The tombstone is a node-array write.
  s.dirty = true
  s.detachFromLabel id, n.label
  s.nodeIds.release id
  true

# ------------------------------------------------------------------ edges

proc createEdge*(s: GraphStore, src, dst: int64, typeName: string): int64 =
  ## Returns 0 when either endpoint is missing or dead. Both endpoints
  ## are validated *before* the id is allocated, so a refused create does
  ## not burn an id.
  if not s.nodeExists(src) or not s.nodeExists(dst):
    return 0
  let id = s.edgeIds.alloc()
  # Doubling, not `setLen(id + 1)`. Nim's setLen allocates *exactly* the
  # requested length, so creating N records one at a time reallocates and
  # copies the whole array N times -- O(N^2) bytes moved, which is what
  # made the first degree-churn run take a minute.
  if s.edges.len <= id.int:
    s.edges.setLen(max(id.int + 1, s.edges.len * 2))
  let code = if typeName.len == 0: 0'i32 else: s.relTypes.intern(typeName)
  var e = newEdge(id, src, dst, code)
  e.nextOut = s.nodes[src.int].outHead
  e.nextIn = s.nodes[dst.int].inHead
  s.edges[id.int] = e
  s.nodes[src.int].outHead = id
  s.nodes[src.int].outCount += 1
  s.nodes[dst.int].inHead = id
  s.nodes[dst.int].inCount += 1
  ## The edge record and both endpoints' chains are in the bundle.
  s.dirty = true
  id

proc edge*(s: GraphStore, id: int64): EdgeRec =
  ## Zeroed for a tombstone, for the reason given on `node`.
  if id <= 0 or id.int >= s.edges.len or not s.edges[id.int].live:
    return EdgeRec(id: 0)
  s.edges[id.int]

proc edgeCount*(s: GraphStore): int64 =
  var n: int64 = 0
  for i in 1 ..< s.edges.len:
    if s.edges[i].live:
      inc n
  n

proc rebuildChains*(s: GraphStore, nodeId: int64) =
  ## Re-link both adjacency lists of a node, dropping tombstones and
  ## recounting the degrees.
  ##
  ## Needed because `unlinkEdge` is only correct for removing *one* edge
  ## from a chain. A transaction that deletes several edges from the same
  ## chain is order-dependent: every record's `nextOut`/`nextIn` names the
  ## successor as it stood when the edge was created, so removing the
  ## earlier one first leaves the later one linking to a tombstone that is
  ## no longer in the chain — which is exactly the S4 degree mismatch and
  ## S9b tombstone-still-linked pair, and it depends on the iteration
  ## order of a hash table.
  ##
  ## Marking the whole set dead and re-splicing each affected endpoint once
  ## is order-independent and costs O(degree) per touched node, the same
  ## order `unlinkEdge` already pays.
  if nodeId <= 0 or nodeId.int >= s.nodes.len:
    return
  var n = s.nodes[nodeId.int]

  ## Zero the heads first: a chain that ends up with no live edges must
  ## report an empty head, and leaving the old value here leaves the
  ## deleted edge still linked (S9b) while the recount says zero (S4).
  n.outHead = 0
  n.inHead = 0
  var kept: seq[int64] = @[]
  var cur = s.nodes[nodeId.int].outHead
  ## A step budget, not a `seen` set: a chain through distinct edges can
  ## never be longer than the edge array, so exceeding it means the links
  ## form a cycle. Stopping would silently drop the chain's tail, which is
  ## the failure this proc exists to prevent, so a cycle is raised instead
  ## of absorbed.
  var steps = 0
  while cur != 0:
    if cur.int >= s.edges.len:
      break
    inc steps
    if steps > s.edges.len:
      raise newException(ValueError,
        "rebuildChains: out-chain of node " & $nodeId &
        " is cyclic after " & $steps & " steps")
    let e = s.edges[cur.int]
    let nxt = e.nextOut
    if e.live:
      kept.add cur
    cur = nxt
  for i, id in kept:
    if i == 0: n.outHead = id
    else: s.edges[kept[i - 1].int].nextOut = id
  if kept.len > 0:
    s.edges[kept[^1].int].nextOut = 0
  n.outCount = int32(kept.len)

  kept.setLen(0)
  cur = s.nodes[nodeId.int].inHead
  steps = 0
  while cur != 0:
    if cur.int >= s.edges.len:
      break
    inc steps
    if steps > s.edges.len:
      raise newException(ValueError,
        "rebuildChains: in-chain of node " & $nodeId &
        " is cyclic after " & $steps & " steps")
    let e = s.edges[cur.int]
    let nxt = e.nextIn
    if e.live:
      kept.add cur
    cur = nxt
  for i, id in kept:
    if i == 0: n.inHead = id
    else: s.edges[kept[i - 1].int].nextIn = id
  if kept.len > 0:
    s.edges[kept[^1].int].nextIn = 0

  n.inCount = int32(kept.len)
  s.nodes[nodeId.int] = n

proc unlinkEdge*(s: GraphStore, e: EdgeRec) =
  ## Remove from both adjacency lists, O(1) each given a predecessor.
  ## Walks from the list head, which is O(degree) — the honest cost of
  ## threaded lists (STORAGE.md §5) and the reason deletion of a
  ## high-degree node is not the O(1) it looks like from the record
  ## alone. The unlink itself is O(1) once the predecessor is known.
  var prev = 0'i64
  var cur = s.nodes[e.src.int].outHead
  while cur != 0:
    if cur == e.id:
      if prev == 0: s.nodes[e.src.int].outHead = e.nextOut
      else: s.edges[prev.int].nextOut = e.nextOut
      s.nodes[e.src.int].outCount -= 1
      break
    prev = cur
    cur = s.edges[cur.int].nextOut

  prev = 0
  cur = s.nodes[e.dst.int].inHead
  while cur != 0:
    if cur == e.id:
      if prev == 0: s.nodes[e.dst.int].inHead = e.nextIn
      else: s.edges[prev.int].nextIn = e.nextIn
      s.nodes[e.dst.int].inCount -= 1
      break
    prev = cur
    cur = s.edges[cur.int].nextIn

proc deleteEdge*(s: GraphStore, id: int64): bool =
  if id <= 0 or id.int >= s.edges.len:
    return false
  if not s.edges[id.int].live:
    return false
  var e = s.edges[id.int]
  s.unlinkEdge e
  var pv = e.propView
  s.arena.clearProps pv
  e.setPropView pv
  e.setFlag efTombstone
  s.edges[id.int] = e
  s.edgeIds.release id
  ## The tombstone and the unlinked chain are both in the bundle.
  s.dirty = true
  true

## Chain accessors.
##
## These read one field and return one field, with no record copy and no
## liveness check. `edge(id)` copies 56 bytes and calls `live()`, which
## is the right thing for a *caller* that wants an edge and the wrong
## thing for a traversal that wants the next hop: walking every edge in
## the M1 fixture costs 4 x 10^6 record copies, and that alone was enough
## to miss the 400 ms traversal gate (466 ms measured, ~180 ms of it
## copies).
##
## The safety argument is unchanged. These are only for following a chain
## that a previous call in the same loop established, tombstones are
## unlinked at delete (STORAGE.md §2.3), and `check()`'s S8/S9 walk is
## the oracle that proves no chain is cyclic. A caller with an arbitrary
## id wants `edge`.
proc outHeadOf*(s: GraphStore, nodeId: int64): int64 =
  if nodeId <= 0 or nodeId.int >= s.nodes.len: return 0
  s.nodes[nodeId.int].outHead

proc inHeadOf*(s: GraphStore, nodeId: int64): int64 =
  if nodeId <= 0 or nodeId.int >= s.nodes.len: return 0
  s.nodes[nodeId.int].inHead

proc nextOutOf*(s: GraphStore, edgeId: int64): int64 =
  if edgeId <= 0 or edgeId.int >= s.edges.len: return 0
  s.edges[edgeId.int].nextOut

proc nextInOf*(s: GraphStore, edgeId: int64): int64 =
  if edgeId <= 0 or edgeId.int >= s.edges.len: return 0
  s.edges[edgeId.int].nextIn

type
  EdgeEnds* = object
    ## A named object rather than a tuple: Nim forbids `src` as a tuple
    ## field name (it is a keyword), and the error is unhelpfully
    ## "undeclared identifier: srcId" when the fields are renamed.
    srcId*, dstId*: int64
    typeCode*: int32

proc edgeEnds*(s: GraphStore, edgeId: int64): EdgeEnds =
  if edgeId <= 0 or edgeId.int >= s.edges.len:
    return EdgeEnds()
  let e = s.edges[edgeId.int]
  EdgeEnds(srcId: e.src, dstId: e.dst, typeCode: e.etype)

# -------------------------------------------------------------- adjacency

proc outEdges*(s: GraphStore, nodeId: int64): seq[int64] =
  ## Edge ids out of a node, in unspecified order (S7). A copy: a caller
  ## traversing while a write appends must not see a reallocating seq.
  if not s.nodeExists(nodeId):
    return @[]
  result = @[]
  var e = s.outHeadOf(nodeId)
  while e != 0:
    result.add e
    e = s.nextOutOf(e)

proc inEdges*(s: GraphStore, nodeId: int64): seq[int64] =
  if not s.nodeExists(nodeId):
    return @[]
  result = @[]
  var e = s.inHeadOf(nodeId)
  while e != 0:
    result.add e
    e = s.nextInOf(e)

proc allEdgeIds*(s: GraphStore): seq[int64] =
  ## Every live edge, for compaction and for the invariant check.
  result = @[]
  for i in 1 ..< s.edges.len:
    if s.edges[i].live:
      result.add s.edges[i].id

proc allNodeIds*(s: GraphStore): seq[int64] =
  result = @[]
  for i in 1 ..< s.nodes.len:
    if s.nodes[i].live:
      result.add s.nodes[i].id

# -------------------------------------------------------------- properties

proc setNodeProp*(s: GraphStore, nodeId: int64, key: string, v: Value): bool =
  ## Mutates the arena **without taking `pubLock`**, so it is not safe
  ## beside a live read snapshot. That is a contract, not an oversight:
  ## this is the single-threaded path the tests and the benchmark use, and
  ## the transactional path (`txn.setNodeProp`) is the one a real write
  ## goes through, which stages into a delta and merges under the lock.
  ## The read path reads properties through a `ReadSnapshot`, which holds
  ## the lock for its whole life, so no offset can go stale underneath it.
  if not s.nodeExists(nodeId):
    return false
  let code = s.propKeys.intern key
  var n = addr s.nodes[nodeId.int]
  var pv = n[].propView
  discard s.arena.setProp(pv, code, v)
  n[].setPropView pv
  true

proc removeNodeProp*(s: GraphStore, nodeId: int64, key: string): bool =
  ## The REMOVE half of a property write, with the same contract as
  ## `setNodeProp`: arena mutation without the lock, for tests and the
  ## benchmark. A missing key is not an error — removing what is not there
  ## leaves the node exactly as it was, which is what Cypher means.
  if not s.nodeExists(nodeId):
    return false
  let code = s.propKeys.lookup key
  if code == 0:
    return false
  var n = addr s.nodes[nodeId.int]
  var pv = n[].propView
  discard s.arena.removeProp(pv, code)
  n[].setPropView pv
  true

proc removeEdgeProp*(s: GraphStore, edgeId: int64, key: string): bool =
  if not s.edgeExists(edgeId):
    return false
  let code = s.propKeys.lookup key
  if code == 0:
    return false
  var e = addr s.edges[edgeId.int]
  var pv = e[].propView
  discard s.arena.removeProp(pv, code)
  e[].setPropView pv
  true

proc getNodeProp*(s: GraphStore, nodeId: int64, key: string,
                  value: var Value): bool =
  if not s.nodeExists(nodeId):
    return false
  let code = s.propKeys.lookup key
  if code == 0:
    return false
  s.arena.getProp(s.nodes[nodeId.int].propView, code, value)

proc nodePropKeys*(s: GraphStore, nodeId: int64): seq[string] =
  result = @[]
  if not s.nodeExists(nodeId):
    return
  let slots = s.arena.readSlots(s.nodes[nodeId.int].propView)
  for slot in slots:
    if (slot.sflags and SlotNull) == 0:
      result.add s.propKeys.nameOf(slot.key)

proc edgePropKeys*(s: GraphStore, edgeId: int64): seq[string] =
  ## The edge-side twin of `nodePropKeys`. It did not exist because nothing
  ## read edge keys back — the crash harness's oracle now does, and a
  ## missing accessor is not a reason for the oracle to compare fewer
  ## bytes than a reader can observe.
  result = @[]
  if not s.edgeExists(edgeId):
    return
  let slots = s.arena.readSlots(s.edges[edgeId.int].propView)
  for slot in slots:
    if (slot.sflags and SlotNull) == 0:
      result.add s.propKeys.nameOf(slot.key)

proc setEdgeProp*(s: GraphStore, edgeId: int64, key: string, v: Value): bool =
  ## The edge-side twin of `setNodeProp`, lock contract included.
  if not s.edgeExists(edgeId):
    return false
  let code = s.propKeys.intern key
  var e = addr s.edges[edgeId.int]
  var pv = e[].propView
  discard s.arena.setProp(pv, code, v)
  e[].setPropView pv
  true

proc getEdgeProp*(s: GraphStore, edgeId: int64, key: string,
                  value: var Value): bool =
  if not s.edgeExists(edgeId):
    return false
  let code = s.propKeys.lookup key
  if code == 0:
    return false
  s.arena.getProp(s.edges[edgeId.int].propView, code, value)

# ------------------------------------------------------------------ stats

type
  StoreStats* = object
    ## A named object rather than a tuple, because the tuple's field
    ## names shadow `nodes`/`edges` inside the proc body — which is a
    ## confusing way to learn that `s.nodes` is unreachable.
    nodes*, edges*, labels*, relTypes*, properties*, arenaBytes*: int64

proc stats*(s: GraphStore): StoreStats =
  StoreStats(nodes: s.nodeCount, edges: s.edgeCount,
             labels: int64(s.labels.count), relTypes: int64(s.relTypes.count),
             properties: int64(s.propKeys.count),
             arenaBytes: int64(s.arena.used()))

# ---------------------------------------------------------- invariant check

type
  Invariant* = object
    code*: string        ## "S2", "S4", ...
    ok*: bool
    detail*: string

proc check*(s: GraphStore): seq[Invariant] =
  ## STORAGE.md §8. S1-S10. Runs in a debug build or on demand; not on
  ## any hot path, because it is O(V + E) and the whole point of the
  ## eagerly-maintained degrees is that nothing needs this in production.
  ## Collected into a local and returned, rather than accumulating into
  ## `result` through a closure: `result` is a seq, and a nested proc
  ## capturing it is a memory-safety error Nim rightly refuses.
  var findings: seq[Invariant] = @[]
  proc note(c: string, ok: bool, detail: string = "") =
    findings.add Invariant(code: c, ok: ok, detail: detail)

  var liveIds = initTable[int64, int]()
  var liveEdgeIds = initTable[int64, int]()

  # S1: ids unique and >= 1
  var dupes = 0
  for i in 1 ..< s.nodes.len:
    let n = s.nodes[i]
    if n.id == 0: continue
    if n.id.int != i:
      dupes += 1
    else:
      if liveIds.hasKey(n.id): dupes += 1
      liveIds[n.id] = 0
  for i in 1 ..< s.edges.len:
    let e = s.edges[i]
    if e.id == 0: continue
    if e.id.int != i:
      dupes += 1
    else:
      if liveEdgeIds.hasKey(e.id): dupes += 1
      liveEdgeIds[e.id] = 0
  note("S1", dupes == 0, "id/index mismatches: " & $dupes)

  # S2 / S3 / S8: adjacency chains reach only their own edges, degrees exact
  ## One `seen` table, cleared per node, rather than one per node. A
  ## fresh Table per node allocated a hash table for every node in the
  ## store, which made the invariant check — the oracle for every mutating
  ## suite — the slowest thing in the test run. Clearing keeps the
  ## capacity, so the check is linear again.
  var seen = initTable[int64, int]()
  var outBad = 0
  var inBad = 0
  var degreeBad = 0
  var chainBad = 0
  for i in 1 ..< s.nodes.len:
    let n = s.nodes[i]
    if not n.live: continue
    seen.clear()
    var cur = n.outHead
    var walked = 0
    while cur != 0:
      if cur.int >= s.edges.len:
        chainBad += 1
        break
      let e = s.edges[cur.int]
      if e.src != n.id: outBad += 1
      if seen.hasKey(cur):
        chainBad += 1
        break
      seen[cur] = 0
      walked += 1
      cur = e.nextOut
    if walked != n.outCount.int: degreeBad += 1

    seen.clear()
    cur = n.inHead
    walked = 0
    while cur != 0:
      if cur.int >= s.edges.len:
        chainBad += 1
        break
      let e = s.edges[cur.int]
      if e.dst != n.id: inBad += 1
      if seen.hasKey(cur):
        chainBad += 1
        break
      seen[cur] = 0
      walked += 1
      cur = e.nextIn
    if walked != n.inCount.int: degreeBad += 1
  note("S2", outBad == 0, "out-edges pointing elsewhere: " & $outBad)
  note("S3", inBad == 0, "in-edges pointing elsewhere: " & $inBad)
  note("S4", degreeBad == 0, "degree mismatches: " & $degreeBad)
  note("S8", chainBad == 0, "broken or cyclic chains: " & $chainBad)

  # S5 / S6 / S7: dictionary codes resolve, offsets are in range
  var badCode = 0
  var badOffset = 0
  for i in 1 ..< s.nodes.len:
    let n = s.nodes[i]
    if not n.live: continue
    if n.label != 0 and s.labels.nameOf(n.label).len == 0: inc badCode
    if n.propSlots != 0 and
        s.arena.ptrAt(n.propSlots, n.propCount.int * sizeof(PropSlot)) == nil:
      inc badOffset
  for i in 1 ..< s.edges.len:
    let e = s.edges[i]
    if not e.live: continue
    if e.etype != 0 and s.relTypes.nameOf(e.etype).len == 0: inc badCode
    if e.props != 0 and
        s.arena.ptrAt(e.props, e.propCount.int * sizeof(PropSlot)) == nil:
      inc badOffset
  note("S5", badCode == 0, "unresolvable codes: " & $badCode)
  note("S6", badOffset == 0, "slot offsets out of range: " & $badOffset)

  # S9: a tombstoned record is unreachable from any adjacency list.
  #
  # Cycle- and bounds-guarded like S2/S3, for a reason that is not
  # theoretical: this walk had neither guard, and it hung the whole test
  # suite on exactly the state it exists to diagnose. A checker must be
  # more robust than the thing it checks, because a checker that hangs or
  # reads out of bounds tells you nothing and takes the run with it.
  ##
  ## The cycle test is a step count bounded by the edge count, *not* a
  ## global seen-set. An edge legitimately appears once in its source's
  ## out-list and once in its target's in-list, so a global set flags
  ## every edge in the store as a repeat — which is how this check first
  ## "found" 200 cycles in a perfectly good 400-edge graph.
  var reachable = initTable[int64, int]()
  let maxWalk = s.edges.len + 1
  var walkGuard = 0
  var s9WalkBad = 0
  for i in 1 ..< s.nodes.len:
    let n = s.nodes[i]
    if not n.live: continue
    walkGuard = 0
    var cur = n.outHead
    while cur != 0:
      if cur.int >= s.edges.len or walkGuard > maxWalk:
        inc s9WalkBad
        break
      reachable[cur] = 0
      inc walkGuard
      cur = s.edges[cur.int].nextOut
    walkGuard = 0
    cur = n.inHead
    while cur != 0:
      if cur.int >= s.edges.len or walkGuard > maxWalk:
        inc s9WalkBad
        break
      reachable[cur] = 0
      inc walkGuard
      cur = s.edges[cur.int].nextIn
  note("S9", s9WalkBad == 0, "cyclic or out-of-range adjacency walks: " & $s9WalkBad)

  var tombReachable = 0
  for eid in reachable.keys:
    if not s.edgeExists(eid): inc tombReachable
  note("S9b", tombReachable == 0, "tombstones still linked: " & $tombReachable)

  # S10: label membership holds only live nodes with that label
  ## labelIndex.members is 0-based, so slot i holds dictionary code i+1.
  var labelBad = 0
  for slot in 0 ..< s.labelIndex.members.len:
    let code = slot + 1
    for id in s.labelIndex.members[slot]:
      if not s.nodeExists(id) or s.nodes[id.int].label.int != code:
        inc labelBad
  note("S10", labelBad == 0, "label index disagreements: " & $labelBad)

  result = findings

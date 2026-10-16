## glyphes — the write transaction (TXN.md §3, WAL.md §3)
##
## Writes never touch the published arrays. They go to per-transaction
## deltas, and a commit merges them. That is what makes rollback free —
## drop the delta, and the base was never touched — and it is why M2
## implements TXN.md's design rather than a shortcut: the shortcut is to
## write through and undo, and then M3 has to replace the undo with
## copy-on-write anyway.
##
## Scope at M2: single writer, merge at commit, no readers to isolate
## (there is no query layer yet). `generation` is bumped per commit so M3
## has something to hang reader snapshots on.
##
## ##1 Atomicity is one ordering, not four properties
##
##   1. validate every id in the deltas
##   2. write every frame; one write() per frame
##   3. fdatasync
##   4. merge deltas into the published arrays
##   5. bump `generation`
##
## A crash before 4 is invisible: the frames are either durable-and-
## committed (replayed) or absent (discarded). A crash during 4 is also
## invisible, for the same reason — recovery reconstructs what the merge
## was doing. A reader can never see a partial merge because the merge is
## not a read-visible event until `generation` moves.
##
## ##2 The log carries logical mutations, not physical records
##
## A `PropSlot` in the log would reference an arena byte offset, and
## replay has no arena to resolve it against — the arena is snapshot
## state, rebuilt by the very replay that would need the offset. So a
## `SetProp` frame carries the value's *type, aux and inline word or
## blob bytes*, and replay pushes it back through the same encoder.
##
## That is safe because the encoder is a pure function of the value: the
## bytes it writes for a given value are the same bytes every time, on
## every machine. The unit tests assert it by round-tripping a store
## through a WAL and comparing the state hash, which is the only claim
## worth making.
##
## `WAL.md` §3 said "slot 16 B" for this opcode. That was wrong in a way
## only implementing it revealed, and the spec has been amended.

import std/[tables, sets, algorithm]
import ../store/prop
import ../store/revision
import ../store/vhist
import ../store/shm
import ../wal/wal
import ../store/store
import ../index/index
import ../index/range

type
  ## Which ABI status a failure becomes. The numbers match `GlyStatus` in
  ## src/glyphes.h; the FFI layer copies them straight through, so an
  ## internal code that does not match the header would surface to Ruby
  ## as a different error than intended.
  TxCode* = enum
    tcGeneric = -1   ## GLY_ERR
    tcBusy = -8       ## GLY_ERR_BUSY
    tcConstraint = -5 ## GLY_ERR_CONSTRAINT
    tcLimit = -9      ## GLY_ERR_LIMIT
    txStale = -3      ## GLY_ERR_STALE

  WriteTransaction* = ref object
    store*: GraphStore
    wal*: Wal
    id*: uint32
    ## Set by the Database when the transaction begins. If present, the
    ## commit updates that index registry inside the write exclusion, after
    ## the store is published and before readers are let back in.
    ##
    ## An index update reads the *published* arrays (so it has to be after
    ## `publish`) and mutates structures a reader may be mid-seek on (so it
    ## has to be before `endWrite`). The first version ran it from the
    ## Database after `commit` returned — after `releaseWriter` — which put
    ## a mutating index and a seeking reader in the same window the reader
    ## gate exists to close.
    ##
    ## A field rather than a closure on purpose: the closure made `commit`
    ## GC-unsafe — an indirect call the compiler cannot look through — and
    ## the soak's thread procs refuse to build. There is exactly one
    ## post-merge step in this engine, and naming it is worth more than the
    ## generality of a hook.
    indicesToUpdate*: Indexes
    sync*: bool
    ## Captured at `begin`. Commit refuses if the store has moved on
    ## (TXN.md §2).
    baseGeneration*: uint64
    ## Operations applied, and the WAL bytes they cost, checked at
    ## operation boundaries (TXN.md §6).
    ops*: int
    walBytes*: int64
    maxOps*: int64
    maxWalBytes*: int64
    frames*: seq[Frame]
    ## The deltas. A `seq` indexed by id would be O(n) to probe for
    ## presence, which makes MERGE quadratic (TXN.md §3.2).
    nodeDelta*: Table[int64, NodeRec]
    edgeDelta*: Table[int64, EdgeRec]
    ## The read path's delta indexes, maintained *as the transaction
    ## writes* rather than rebuilt when a statement asks for them.
    ##
    ## The read path used to derive all three by walking `nodeDelta` and
    ## `edgeDelta` on first use, and did that per statement. A bulk load is
    ## many statements over one transaction whose delta grows to the size
    ## of the load, so every statement paid O(load) for three passes:
    ## O(N^2) for N edges. Measured on 3·10^3 nodes, node CREATE — which
    ## mutates the delta and never reads it — ran at 76 832/s while a
    ## MATCH read inside the same growing transaction ran at 1 421/s.
    ##
    ## The transaction already knows exactly what it created and deleted, so
    ## it maintains these as it goes and `buildDelta` becomes three
    ## assignments.
    ##
    ## `deltaNodesIdx` keeps deleted ids rather than dropping them: every
    ## reader of it checks liveness afterwards. The edge indexes cannot do
    ## that — `outEdges` trusts `deltaOutIdx` to hold live edges and
    ## `okExpand` checks the *other node's* liveness but never the edge's —
    ## so `deleteEdge` unlists explicitly.
    deltaNodesIdx*: seq[int64]
    ## The same ids as `deltaNodesIdx`, as a set. The seq is for ordered
    ## iteration; membership is asked on every seek, and a walk of the seq
    ## made one indexed lookup inside a transaction cost O(delta).
    deltaNodeSet*: HashSet[int64]
    deltaOutIdx*: Table[int64, seq[int64]]
    deltaInIdx*: Table[int64, seq[int64]]
    ## Delta-side seek index: index name -> hash of the normalised key ->
    ## the uncommitted nodes carrying that key. Maintained as `setNodeProp`
    ## runs, so a seek over nodes this transaction has written but not
    ## committed is a hash lookup instead of a walk of the whole delta.
    ##
    ## The commit-time index update (`applyDelta`) is too late for this:
    ## between the `CREATE` and the `COMMIT` a read in the same transaction
    ## has to see the row, and the committed index cannot know about it. The
    ## read path used to fall back to scanning every delta node per seek,
    ## which is O(delta) per statement and O(N^2) for a bulk load.
    ##
    ## Each bucket stores the normalised key alongside the id, because a
    ## hash collision must cost a comparison (`keySame`) and never a wrong
    ## answer. Rollback clears the whole structure, so a rolled-back write
    ## cannot be found by a later read — that is the one hard requirement.
    deltaSeekIdx*: Table[(int32, string, uint64), seq[(Value, int64)]]
    nodeProps*: Table[int64, PropView]
    edgeProps*: Table[int64, PropView]
    nextNodeId*: int64
    nextEdgeId*: int64
    nextLsn*: uint64
    closed*: bool
    ## The version-history commit this transaction is building, opened at
    ## `begin` and sealed at `commit`. Revisions are noted *as the writes
    ## happen* rather than re-read at commit: the plan makes this the one
    ## design decision of V0.2, because re-reading would make a revision's
    ## contents depend on when it was written, and V0.4's differential test
    ## exists to catch exactly that.
    ##
    ## Per-node accumulator, because a transaction may set, remove and delete
    ## the same node, and the revision is one row that has to describe the
    ## transaction's net effect — not one row per operation. 0 until `begin`
    ## opens one; the field exists so a transaction that touches nothing does
    ## not create an empty commit.
    histCommit*: uint64
    ## nodeId -> the keys it set and the keys it removed, in this
    ## transaction. Ordered on purpose: the revision records what the
    ## transaction did in the order it did it, so two transactions that reach
    ## the same end state still read differently if they got there
    ## differently — which is what makes "diff these two commits" a question
    ## about the transactions rather than about their endpoints.
    histSet*: Table[int64, seq[(int32, Value)]]
    histRemoved*: Table[int64, seq[int32]]
    ## Nodes whose liveness this transaction changed, as (nodeId, nowLive).
    ## Separate from the property tables because a delete with no property
    ## change is still a revision — a tombstone is a revision, not an erasure.
    histLiveness*: Table[int64, bool]

  TxError* = ref object of CatchableError
    ## Internal. Crosses to the ABI as a status code, never as itself.
    code*: TxCode

proc failTxCode(code: TxCode, msg: string) {.noreturn.} =
  ## Constructed by hand rather than with `newException`, which cannot
  ## build a `ref object of CatchableError`.
  var e: TxError
  new(e)
  e.msg = msg
  e.code = code
  raise e

proc failTx(msg: string) {.noreturn.} =
  failTxCode(tcGeneric, msg)

# ------------------------------------------------------------- encoding aid

proc putI64(buf: var string, v: int64) =
  for i in 0 ..< 8:
    buf.add char(uint8((cast[uint64](v) shr (i * 8)) and 0xFF'u64))

proc putI32(buf: var string, v: int32) =
  for i in 0 ..< 4:
    buf.add char(uint8((cast[uint32](v) shr (i * 8)) and 0xFF'u32))

proc putU16(buf: var string, v: uint16) =
  buf.add char(uint8(v and 0xFF'u16))
  buf.add char(uint8((v shr 8) and 0xFF'u16))

proc putU64(buf: var string, v: uint64) =
  for i in 0 ..< 8:
    buf.add char(uint8((v shr (i * 8)) and 0xFF'u64))

proc encodeValuePayload(buf: var string, v: Value) =
  ## vtype, aux, inline flag, then either the inline word or the arena
  ## blob. Both come from prop.nim's pure encoder, so replay reproduces
  ## identical bytes — the property the recovery tests assert.
  buf.add char(uint8(propType(v.kind)))
  ## `aux` is uint16 in PropSlot, so it is written two bytes wide. One
  ## byte here shifted the value body by a byte and every replayed string
  ## or container failed to decode.
  putU16 buf, elementCount(v)
  if fitsInline(v):
    buf.add char(SlotInline)
    var slot: PropSlot
    slot.aux = elementCount(v)
    packInline(slot, v)
    putU64 buf, slot.payload
  else:
    buf.add '\x00'
    buf.add encodeValue(v)

const
  ## TXN.md §6. The other three budgets bound results and sorts, which do
  ## not exist until the query milestone.
  DefaultMaxTxnOps* = 10_000_000'i64
  DefaultMaxTxnWalBytes* = 1 shl 30

proc begin*(store: GraphStore, w: Wal; id: uint32; doSync = true;
            maxOps: int64 = DefaultMaxTxnOps;
            maxWalBytes: int64 = DefaultMaxTxnWalBytes): WriteTransaction =
  ## One writer at a time (TXN.md §1). The claim lives on the store so the
  ## check and the claim cannot be separated by another thread, and it
  ## raises `GLY_ERR_BUSY` rather than blocking: the embedded caller is a
  ## Ruby thread that would rather raise than silently stall a request.
  ## One compare-and-swap, not a test followed by a store: the soak found
  ## both writers entering through a check-then-act window and one of
  ## them committing on a base the other had already replaced.
  if not store.claimWriter(id):
    failTxCode(tcBusy,
      "a write transaction is already active on this database")
  new(result)
  result.store = store
  result.wal = w
  result.id = id
  result.sync = doSync
  result.baseGeneration = store.generation
  result.ops = 0
  result.walBytes = 0
  result.maxOps = maxOps
  result.maxWalBytes = maxWalBytes
  result.nodeDelta = initTable[int64, NodeRec]()
  result.edgeDelta = initTable[int64, EdgeRec]()
  result.deltaNodesIdx = @[]
  result.deltaNodeSet = initHashSet[int64]()
  result.deltaOutIdx = initTable[int64, seq[int64]]()
  result.deltaInIdx = initTable[int64, seq[int64]]()
  result.deltaSeekIdx = initTable[(int32, string, uint64), seq[(Value, int64)]]()
  result.nodeProps = initTable[int64, PropView]()
  result.edgeProps = initTable[int64, PropView]()
  result.histCommit = 0
  result.histSet = initTable[int64, seq[(int32, Value)]]()
  result.histRemoved = initTable[int64, seq[int32]]()
  result.histLiveness = initTable[int64, bool]()
  result.frames = @[]
  # Ids continue past everything the store has issued, so a transaction
  # can never collide with a live record. The store's allocator is
  # advanced at commit; a rolled-back transaction simply burns ids, which
  # S2 permits.
  result.nextNodeId = store.nodeIds.highestIssued() + 1
  result.nextEdgeId = store.edgeIds.highestIssued() + 1
  ## A nil log is legal and means exactly what it says: a memory database
  ## (GLY_OPEN_MEMORY is documented in the header as ":memory:, no WAL")
  ## commits into memory and is lost at close. SQLite's `:memory:` behaves
  ## the same way and the alternative — refusing transactions there — turns
  ## every test and every scratch database into a special case. Everything
  ## else that touches `wal` in this module is guarded on nil for that one
  ## reason and no other.
  result.nextLsn = if w == nil: 0'u64 else: w.nextLsn

proc assertOpen(tx: WriteTransaction) =
  if tx.closed:
    failTx("transaction " & $tx.id & " is already finished")

proc histNoteSet(tx: WriteTransaction; nodeId: int64; code: int32; v: Value) =
  ## Note "this node had `code` set to `v` in this transaction". Opens the
  ## revision commit on first use, so a transaction that writes nothing never
  ## creates an empty one.
  if tx.histCommit == 0:
    tx.histCommit = tx.store.history.openCommit("main", @[],
                                                 tx.nextLsn)
  tx.histSet.mgetOrPut(nodeId, @[]).add((code, v))
  ## A set after a remove in the same transaction cancels the removal: the
  ## node's net effect is that the key holds a value, which is what the
  ## revision has to say. The revision records the operations in order and
  ## the fold applies them in order, so the last word on a key wins either
  ## way — but dropping a now-false `removed` keeps the recorded delta equal
  ## to the transaction's net effect rather than to its history of attempts.
  var rm = tx.histRemoved.getOrDefault(nodeId, @[])
  for i, k in rm:
    if k == code:
      rm.delete(i)
      break
  if rm.len > 0: tx.histRemoved[nodeId] = rm
  else: tx.histRemoved.del(nodeId)
  tx.histLiveness[nodeId] = true

proc histNoteRemoved(tx: WriteTransaction; nodeId: int64; code: int32) =
  ## Note "this node had `code` removed in this transaction".
  if tx.histCommit == 0:
    tx.histCommit = tx.store.history.openCommit("main", @[],
                                                 tx.nextLsn)
  tx.histRemoved.mgetOrPut(nodeId, @[]).add(code)
  var st = tx.histSet.getOrDefault(nodeId, @[])
  for i, kv in st:
    if kv[0] == code:
      st.delete(i)
      break
  if st.len > 0: tx.histSet[nodeId] = st
  else: tx.histSet.del(nodeId)
  tx.histLiveness[nodeId] = true

proc histNoteLive(tx: WriteTransaction; nodeId: int64; live: bool) =
  ## Note a create or a delete. A tombstone is a revision, not an erasure,
  ## so liveness is its own axis of a node's state and is tracked here even
  ## when the transaction touched no property.
  if tx.histCommit == 0:
    tx.histCommit = tx.store.history.openCommit("main", @[],
                                                 tx.nextLsn)
  tx.histLiveness[nodeId] = live

proc chargeOp(tx: WriteTransaction, bytes: int) =
  ## Budgets are checked here — once per operation — rather than per row,
  ## because per-row checking costs more than the operation it guards.
  ## Exceeding a budget returns the error and leaves the transaction open:
  ## the caller decides whether to roll back, matching sqlite3 and every
  ## embedded store (TXN.md §6).
  inc tx.ops
  tx.walBytes += int64(bytes)
  if tx.maxOps > 0 and int64(tx.ops) > tx.maxOps:
    failTxCode(tcLimit, "transaction exceeded max_txn_ops (" &
      $tx.maxOps & ") at operation " & $tx.ops)
  if tx.maxWalBytes > 0 and tx.walBytes > tx.maxWalBytes:
    failTxCode(tcLimit, "transaction exceeded max_txn_wal_bytes (" &
      $tx.maxWalBytes & ") at " & $tx.walBytes & " bytes")

proc emit(tx: WriteTransaction, op: Opcode, payload: string) =
  tx.frames.add Frame(lsn: tx.nextLsn, txnId: tx.id, op: op,
                      txnFlags: 0, payload: payload)
  inc tx.nextLsn
  tx.chargeOp(payload.len + FrameHeaderSize)

# ------------------------------------------------------------- dictionaries

proc labelCode*(tx: WriteTransaction, name: string): int32 =
  ## Interns, and logs a `NewLabel` frame the first time a name is seen in
  ## this database. The dictionary is append-only and first-seen order, so
  ## replaying `NewLabel` in write order reproduces the same codes. That
  ## equivalence is what lets a frame carry a code instead of a string.
  if name.len == 0:
    return 0
  let existing = tx.store.labels.lookup(name)
  if existing != 0:
    return existing
  let code = tx.store.labels.intern(name)
  var payload = ""
  putI32(payload, code)
  payload.add name
  tx.emit(opNewLabel, payload)
  code

proc relTypeCode*(tx: WriteTransaction, name: string): int32 =
  if name.len == 0:
    return 0
  let existing = tx.store.relTypes.lookup(name)
  if existing != 0:
    return existing
  let code = tx.store.relTypes.intern(name)
  var payload = ""
  putI32(payload, code)
  payload.add name
  tx.emit(opNewRelType, payload)
  code

proc propKeyCode*(tx: WriteTransaction, name: string): int32  {.gcsafe.} =
  let existing = tx.store.propKeys.lookup(name)
  if existing != 0:
    return existing
  let code = tx.store.propKeys.intern(name)
  var payload = ""
  putI32(payload, code)
  payload.add name
  tx.emit(opNewPropKey, payload)
  code

# ------------------------------------------------------------------- reads

proc peekNode*(tx: WriteTransaction, id: int64): NodeRec  {.gcsafe.} =
  ## The transactional read: delta first, then base. Nothing may consult
  ## the store without going through this.
  if tx.nodeDelta.hasKey(id):
    return tx.nodeDelta[id]
  tx.store.node(id)

proc peekEdge*(tx: WriteTransaction, id: int64): EdgeRec =
  if tx.edgeDelta.hasKey(id):
    return tx.edgeDelta[id]
  tx.store.edge(id)

proc nodeExistsTx*(tx: WriteTransaction, id: int64): bool =
  ## `live`, not `id != 0`: id 0 is the no-record sentinel, but a
  ## tombstone carries its id too, and answering "exists" for a deleted
  ## node let an edge be created pointing at it — which the commit
  ## validation then had to admit as a dangling edge.
  peekNode(tx, id).live

proc edgeExistsTx*(tx: WriteTransaction, id: int64): bool =
  peekEdge(tx, id).live

# ------------------------------------------------------------------- nodes

proc createNode*(tx: WriteTransaction, labelName: string): int64 =
  tx.assertOpen
  let id = tx.nextNodeId
  inc tx.nextNodeId
  let code = tx.labelCode(labelName)
  tx.nodeDelta[id] = newNode(id, code)
  tx.deltaNodesIdx.add id
  tx.deltaNodeSet.incl id
  var payload = ""
  putI64(payload, id)
  putI32(payload, code)
  tx.emit(opCreateNode, payload)
  ## A create is a revision, not just a property change — this node's first
  ## appearance in the history is itself something `diff` has to be able to
  ## report, and the fold needs `live` to start true for it.
  tx.histNoteLive(id, true)
  id

proc deleteEdge*(tx: WriteTransaction, id: int64): bool {.gcsafe.}

proc incidentEdges*(tx: WriteTransaction, id: int64): seq[int64] =
  ## Every edge a reader inside this transaction can see touching `id`.
  ##
  ## The base store's `outHead`/`inHead` chains are not the whole answer:
  ## `createEdge` links into the delta, not into the committed chains, so
  ## an edge made earlier in *this* transaction is invisible to a walk
  ## over the base lists. Walking only those lists left live edges
  ## pointing at a tombstone (S9b) and the endpoints' degree counts
  ## disagreeing with the edges actually attached (S4). The delta is
  ## scanned as well, so the cascade sees what the transaction has built.
  var seen = initHashSet[int64]()
  var e = tx.store.outHeadOf(id)
  while e != 0:
    let nxt = tx.store.nextOutOf(e)
    ## `live`, not `id != 0`: a tombstone keeps its id (S8 leaves the chain
    ## alone for the compactor), so an id test counts an edge this
    ## transaction already deleted. DETACH DELETE then reported an edge per
    ## endpoint, and a cascade tried to delete the same edge twice.
    if tx.peekEdge(e).live and e notin seen:
      result.add e
      seen.incl e
    e = nxt
  e = tx.store.inHeadOf(id)
  while e != 0:
    let nxt = tx.store.nextInOf(e)
    ## `live`, not `id != 0`: a tombstone keeps its id (S8 leaves the chain
    ## alone for the compactor), so an id test counts an edge this
    ## transaction already deleted. DETACH DELETE then reported an edge per
    ## endpoint, and a cascade tried to delete the same edge twice.
    if tx.peekEdge(e).live and e notin seen:
      result.add e
      seen.incl e
    e = nxt
  for eid, rec in tx.edgeDelta:
    if rec.live and eid notin seen and (rec.src == id or rec.dst == id):
      result.add eid
      seen.incl eid

proc degreeTx(tx: WriteTransaction, id: int64): int =
  ## The committed degree plus the edges this transaction added. A node
  ## created here reports 0 in the base store forever, so this is the wrong
  ## number for "may this node be deleted without a cascade": it counts
  ## edges this transaction has *already deleted*. Use `incidentEdges`,
  ## which walks what a reader inside the transaction can see.
  result = tx.peekNode(id).degree
  for eid, rec in tx.edgeDelta:
    if rec.live and (rec.src == id or rec.dst == id):
      inc result

proc forgetSeekKey(tx: WriteTransaction, nodeId: int64) =
  ## Retire a node from every delta seek bucket. A tombstoned node must not
  ## be found by a seek: the read side does re-check `rec.live`, so this is
  ## belt-and-braces like the edge unlist — but a bucket that accumulated
  ## every deleted node would grow without bound inside a long transaction.
  var drop: seq[(int32, string, uint64)] = @[]
  for key in tx.deltaSeekIdx.keys:
    var keep: seq[(Value, int64)] = @[]
    for e in tx.deltaSeekIdx[key]:
      if e[1] != nodeId:
        keep.add e
    if keep.len != tx.deltaSeekIdx[key].len:
      drop.add key
    tx.deltaSeekIdx[key] = keep
  for key in drop:
    tx.deltaSeekIdx.del key

proc deleteNode*(tx: WriteTransaction, id: int64; cascade: bool): bool {.gcsafe.} =
  tx.assertOpen
  var n = tx.peekNode(id)
  if n.id == 0:
    return false
  ## The guard reads the *live* incident edges, not the committed degree: a
  ## node whose only relationship was deleted earlier in this same
  ## transaction has no live edges left and is deletable without DETACH.
  ## Reading the degree here refused it — a DELETE that fails because of
  ## something the same query already removed.
  if incidentEdges(tx, id).len != 0 and not cascade:
    return false
  if cascade:
    # Always edges first, so no reader can observe a half-detached node
    # even inside the transaction (STORAGE.md §2.3).
    for e in incidentEdges(tx, id):
      discard tx.deleteEdge(e)
    ## A tombstoned node has no incident edges by construction, so its
    ## heads and degree counts are zero. They cannot be read back from the
    ## store: the cascade has only marked the edges in the delta, and the
    ## base store is not unlinked until commit. Carrying the pre-cascade
    ## values forward is what left the endpoints' degree disagreeing with
    ## the edges actually attached (S4) and a tombstone still reachable in
    ## a neighbour's chain (S9b).
    n = tx.peekNode(id)
    n.outHead = 0
    n.inHead = 0
    n.outCount = 0
    n.inCount = 0
  n.setFlag nfTombstone
  tx.nodeDelta[id] = n
  tx.forgetSeekKey(id)
  ## A delete is a revision. This is the case that makes liveness a first-class
  ## axis rather than a detail of the property delta: the node loses no key
  ## here, it just stops existing, and a revision that could not say that
  ## would report the node as unchanged.
  tx.histNoteLive(id, false)
  var payload = ""
  putI64(payload, id)
  tx.emit(opDeleteNode, payload)
  true

# ------------------------------------------------------------------- edges

proc unlistEdge(index: var Table[int64, seq[int64]], endpoint, edgeId: int64) =
  ## Drop one edge id from one endpoint's list, in place. A delete is rare
  ## next to a create, so the list is rebuilt rather than spliced; the
  ## splice would cost the same and read worse.
  if not index.hasKey(endpoint):
    return
  var keep: seq[int64] = @[]
  for id in index[endpoint]:
    if id != edgeId:
      keep.add id
  index[endpoint] = keep

proc createEdge*(tx: WriteTransaction, src, dst: int64,
                 typeName: string): int64 =
  tx.assertOpen
  if not tx.nodeExistsTx(src) or not tx.nodeExistsTx(dst):
    return 0
  let id = tx.nextEdgeId
  inc tx.nextEdgeId
  let code = tx.relTypeCode(typeName)
  var e = newEdge(id, src, dst, code)
  e.nextOut = tx.store.outHeadOf(src)
  e.nextIn = tx.store.inHeadOf(dst)
  tx.edgeDelta[id] = e
  tx.deltaOutIdx.mgetOrPut(src, @[]).add id
  tx.deltaInIdx.mgetOrPut(dst, @[]).add id
  var payload = ""
  putI64(payload, id)
  putI32(payload, code)
  putI64(payload, src)
  putI64(payload, dst)
  tx.emit(opCreateEdge, payload)
  id

proc deleteEdge*(tx: WriteTransaction, id: int64): bool {.gcsafe.} =
  tx.assertOpen
  var e = tx.peekEdge(id)
  if e.id == 0:
    return false
  ## The links are left exactly as they were read. Repairing them here —
  ## splicing the chain to drop this edge eagerly — was tried and was
  ## wrong: the delta record's links then diverge from the store's, and
  ## the next delete in the same transaction walks a chain that is half
  ## one and half the other, so it stops in the middle and misses edges
  ## that are still in it. The store's own links are always a consistent
  ## chain by S8, tombstones included, so the right move is to leave them
  ## alone and let commit's `rebuildChains` re-splice each touched
  ## endpoint once, against links that were never rewritten.
  e.setFlag efTombstone
  tx.edgeDelta[id] = e
  ## Unlisted, because nothing downstream re-checks an edge's liveness:
  ## `outEdges` hands its list straight to the Expand, which filters on
  ## type and on the far node's liveness. A tombstoned edge left in the
  ## index would be walked.
  unlistEdge(tx.deltaOutIdx, e.src, id)
  unlistEdge(tx.deltaInIdx, e.dst, id)
  var payload = ""
  putI64(payload, id)
  tx.emit(opDeleteEdge, payload)
  true

# -------------------------------------------------------------- properties

proc noteSeekKey(tx: WriteTransaction, nodeId: int64, prop: string, v: Value) =
  ## Record `nodeId` under its (label, property), so a seek for that pair in
  ## this same transaction can find it without walking the delta.
  ##
  ## Keyed by *label code and property name*, not by index name, and that is
  ## the whole design. An index name would need the writer to consult the
  ## registry that the reader may not be using — two sources of truth for
  ## "which index", which is how this first version silently recorded
  ## nothing: `tx.indicesToUpdate` is the database's registry and `ctx.indices`
  ## is whatever `prepare` was handed, and a test that builds its own
  ## registry recorded zero entries and then believed the seek. The label
  ## and the property are what both sides agree on, and they are also what
  ## the filter above the seek will confirm.
  ##
  ## A value the index cannot hold normalises to `vkNull` and is skipped —
  ## the committed index would have stood down on it too.
  if prop.len == 0:
    return
  let rec = tx.peekNode(nodeId)
  if not rec.live:
    return
  let k = keyOf(v)
  if k.kind == vkNull:
    return
  let h = keyHash(v)
  tx.deltaSeekIdx.mgetOrPut((rec.label, prop, h), @[]).add((k, nodeId))

proc setPropCommon(tx: WriteTransaction; target: char; id: int64;
                   key: string; v: Value; isNode: bool): bool  {.gcsafe.} =
  tx.assertOpen
  if isNode and not tx.nodeExistsTx(id): return false
  if not isNode and not tx.edgeExistsTx(id): return false

  let code = tx.propKeyCode(key)
  var pv =
    if isNode:
      if tx.nodeProps.hasKey(id): tx.nodeProps[id]
      else: tx.peekNode(id).propView
    else:
      if tx.edgeProps.hasKey(id): tx.edgeProps[id]
      else: tx.peekEdge(id).propView
  discard tx.store.arena.setProp(pv, code, v)

  ## target is the first byte, then the id: a SetProp frame addresses a
  ## node or an edge, and the discriminator is part of the frame rather
  ## than a second opcode.
  var payload = newStringOfCap(32)
  payload.add target
  putI64(payload, id)
  putI32(payload, code)
  encodeValuePayload payload, v
  tx.emit(opSetProp, payload)

  # The delta's record is updated too, so a later read in this transaction
  # sees the property and the commit merge writes it back.
  if isNode:
    tx.nodeProps[id] = pv
    var rec = tx.peekNode(id)
    rec.setPropView pv
    tx.nodeDelta[id] = rec
    tx.noteSeekKey(id, key, v)
    ## Node property history only. Edge history is a separate document
    ## (PRD §7), and recording edges here would put keys in the node revision
    ## store that the diff contract does not describe.
    tx.histNoteSet(id, code, v)
  else:
    tx.edgeProps[id] = pv
    var rec = tx.peekEdge(id)
    rec.setPropView pv
    tx.edgeDelta[id] = rec
  true

proc setNodeProp*(tx: WriteTransaction, nodeId: int64, key: string, v: Value): bool {.gcsafe.} =
  setPropCommon(tx, '\x00', nodeId, key, v, true)

proc setEdgeProp*(tx: WriteTransaction, edgeId: int64, key: string, v: Value): bool =
  setPropCommon(tx, '\x01', edgeId, key, v, false)

proc removePropCommon(tx: WriteTransaction, target: char, id: int64, key: string,
                      isNode: bool): bool =
  ## REMOVE, transactionally. Same shape as `setPropCommon` with no value
  ## in the payload — the frame says *which key is gone*, and replay removes
  ## it rather than setting a null, because a stored null and an absent
  ## property are different states (CYPHER.md §3.2 pins that difference as
  ## silent data loss when confused).
  tx.assertOpen
  if isNode and not tx.nodeExistsTx(id): return false
  if not isNode and not tx.edgeExistsTx(id): return false

  let code = tx.propKeyCode(key)
  if code == 0:
    ## Never written under this key: nothing to remove, and nothing to log.
    return true
  var pv =
    if isNode:
      if tx.nodeProps.hasKey(id): tx.nodeProps[id]
      else: tx.peekNode(id).propView
    else:
      if tx.edgeProps.hasKey(id): tx.edgeProps[id]
      else: tx.peekEdge(id).propView
  if not tx.store.arena.removeProp(pv, code):
    return true        ## absent already; removing it again is a no-op

  var payload = newStringOfCap(16)
  payload.add target
  putI64(payload, id)
  putI32(payload, code)
  tx.emit(opRemoveProp, payload)

  if isNode:
    tx.nodeProps[id] = pv
    var rec = tx.peekNode(id)
    rec.setPropView pv
    tx.nodeDelta[id] = rec
    ## The property is gone, so the key this node answered to before must
    ## stop answering for it. `vkNull` is skipped by the read side, which is
    ## how the entry is retired — and the seek filter above still confirms
    ## against the real property, so an entry that outlives its removal
    ## costs a candidate, never a row.
    tx.noteSeekKey(id, key, Value(kind: vkNull))
    ## The key is gone, and the revision has to say so as an absence rather
    ## than as a null — a removed property and a property set to null are
    ## different states, and `Revision.removed` is how the two stay apart.
    tx.histNoteRemoved(id, code)
  else:
    tx.edgeProps[id] = pv
    var rec = tx.peekEdge(id)
    rec.setPropView pv
    tx.edgeDelta[id] = rec
  true

proc clearNodeProps*(tx: WriteTransaction, nodeId: int64): bool =
  ## `SET a = {…}` — the replace form. Every existing key goes, then the
  ## map's keys go on. Removing first (rather than diffing) is what makes
  ## replace and merge *different operations* rather than the same one with
  ## a flag: CYPHER.md §3.2 pins the pair because confusing them loses data
  ## silently.
  ##
  ## One RemoveProp frame per key, not a "clear" frame: the log then says
  ## exactly what happened, and a reader that only understands SetProp still
  ## replays a prefix of it correctly rather than seeing a frame it cannot
  ## interpret.
  tx.assertOpen
  if not tx.nodeExistsTx(nodeId):
    return false
  var pv =
    if tx.nodeProps.hasKey(nodeId): tx.nodeProps[nodeId]
    else: tx.peekNode(nodeId).propView
  let slots = tx.store.arena.readSlots(pv)
  for slot in slots:
    discard removePropCommon(tx, '\x00', nodeId, tx.store.propKeys.nameOf(slot.key), true)
  true

proc removeNodeProp*(tx: WriteTransaction, nodeId: int64, key: string): bool =
  removePropCommon(tx, '\x00', nodeId, key, true)

proc removeEdgeProp*(tx: WriteTransaction, edgeId: int64, key: string): bool =
  removePropCommon(tx, '\x01', edgeId, key, false)

# ------------------------------------------------------------------ commit

proc histSeal(tx: WriteTransaction): uint64 =
  ## Turn the transaction's per-node accumulators into revisions on its open
  ## revision commit, then seal it. Returns the commit id it sealed, or 0 if
  ## there was nothing to seal (a transaction that touched nothing). Called
  ## from `commit` before the sidecar write, inside the write exclusion, so
  ## the revision store's single-writer claim and this transaction's
  ## single-writer claim are the same writer and cannot drift.
  if tx.histCommit == 0:
    return 0'u64
  let cid = tx.histCommit
  ## Deterministic order over the touched nodes — the accumulators are tables,
  ## and a revision set written in hash order would make two identical
  ## transactions produce different `changed` orderings.
  var ids: seq[int64] = @[]
  for nid in tx.histSet.keys: ids.add nid
  for nid in tx.histRemoved.keys: ids.add nid
  for nid in tx.histLiveness.keys: ids.add nid
  ids.sort()
  var seen = initHashSet[int64]()
  for nid in ids:
    if nid in seen: continue
    seen.incl nid
    let liveNow = tx.histLiveness.getOrDefault(nid, true)
    tx.store.history.noteRevision(cid, nid,
                                  tx.histSet.getOrDefault(nid, @[]),
                                  liveNow,
                                  tx.histRemoved.getOrDefault(nid, @[]))
  ## Stamp the commit's WAL position to where the log actually stands now,
  ## not where it stood when the first revision opened it. V1 replays the
  ## history from these positions, so a commit claiming the LSN of an
  ## operation in the middle of its own transaction would put the replay
  ## pointer inside the transaction it describes.
  if cid.int - 1 < tx.store.history.commits.len:
    tx.store.history.commits[cid.int - 1].lsn = tx.nextLsn
  tx.store.history.sealCommit(cid)
  tx.histCommit = 0
  cid

proc histAbort(tx: WriteTransaction) =
  ## Drop the revision commit a rolled-back transaction opened. `abortCommit`
  ## erases it and every revision it recorded, so a failed transaction leaves
  ## no trace in the history — the same guarantee the base arrays get for free
  ## from never being touched.
  if tx.histCommit == 0:
    return
  tx.store.history.abortCommit(tx.histCommit)
  tx.histCommit = 0

proc histWriteAndSync(tx: WriteTransaction; sealed: uint64) =
  ## Append a *sealed* revision commit to the `.vhist` sidecar and make it
  ## durable, before the log's COMMIT frame. Does nothing for a memory
  ## database, an open with no sidecar, or a transaction that touched nothing
  ## (`sealed == 0`).
  ##
  ## The frame is stamped with the generation the graph is *about to* have
  ## (`store.generation + 1`, because the merge that bumps it has not run yet).
  ## If a crash loses the log's COMMIT frame, the history's frame is above a
  ## generation the graph never reached and replay drops it — the ordering
  ## that keeps history from being *behind* the graph at the cost of it
  ## briefly being ahead, which the stamp repairs.
  if sealed == 0 or tx.store.vhistFile == nil:
    return
  let rec = tx.store.history.commits[sealed.int - 1]
  let payload = encodeCommitPayload(tx.store.history, rec)
  appendCommit(tx.store.vhistFile, sealed, tx.store.generation + 1, payload)
  ## Synced unconditionally, unlike the log's `sync` flag which a caller can
  ## trade away: the history's durability claim is per-commit, and a batched
  ## load that skipped it would have a history whose last frame is not durable
  ## when the log's is.
  syncVhist(tx.store.vhistFile)
  tx.store.histGeneration = tx.store.generation + 1

proc commit*(tx: WriteTransaction): bool =
  ## Returns false when the transaction was already finished.
  ##
  ## Raises rather than returning false on a stale base or a validation
  ## failure: a false return reads as "committed but nothing to do", and
  ## silently dropping a transaction's writes is the one outcome worse
  ## than a loud error.
  if tx.closed:
    return false
  let s0 = tx.store

  # 0. The base must still be the base. Captured at `begin` and rechecked
  #    here: with one writer this can only move through a bug or a
  #    re-entrant commit, and the check is nearly free while converting a
  #    whole class of silent corruption into a `GLY_ERR_STALE` (TXN.md §2).
  if s0.generation != tx.baseGeneration:
    failTxCode(txStale, "transaction base generation " & $tx.baseGeneration &
      " is stale; store is at " & $s0.generation)

  # 1. Validate. Every referenced id must exist in base or delta; a
  #    transaction that would produce a dangling edge is refused before
  #    anything is durable, so the log never contains one.
  for id, rec in tx.nodeDelta:
    if id != rec.id:
      failTx("node delta id " & $id & " holds record " & $rec.id)
  for id, rec in tx.edgeDelta:
    if id != rec.id:
      failTx("edge delta id " & $id & " holds record " & $rec.id)
    ## Live edges only. A cascade delete puts the node's tombstone and its
    ## edges' tombstones in the same delta, and an edge that is itself
    ## being removed may legitimately name a node that is going away with
    ## it — requiring existence there would make a cascading delete of a
    ## node with edges impossible.
    if rec.live and (not tx.nodeExistsTx(rec.src) or
                     not tx.nodeExistsTx(rec.dst)):
      failTx("edge " & $id & " references a node that does not exist")

  ## 1b. Constraints (TXN.md §3.1 step 3, §5). Still before the log: a
  ##     violation must never become durable, and a rolled-back transaction
  ##     must never have paid for validation. The delta records' propViews
  ##     already hold the new values, so this sees the transaction as it
  ##     would commit, not as the store was.
  if tx.indicesToUpdate != nil:
    validateConstraints(tx.indicesToUpdate, s0, tx.nodeDelta)

  # 2-3. Durable first. The COMMIT frame is written last, so its presence
  #       is what makes the transaction real; a crash before it leaves
  #       frames that recovery discards as uncommitted. Skipped whole for a
  #       memory database, which has no log and nothing to recover.
  #
  #       The version-history append goes *before* the log's COMMIT frame and
  #       inside the same fsync discipline (PRD §4.1, V1.3). Inside, not
  #       after: if the history were synced after the graph, a crash in
  #       between would leave a commit the graph has and the history does
  #       not, and a history that silently omits a commit the graph accepted
  #       is the one incoherence this feature cannot have. The reverse
  #       ordering — history ahead of the graph — is possible and is repaired
  #       by the generation stamp on replay, which is a better failure than
  #       an omission nobody notices.
  let sealedHistory = tx.histSeal()
  tx.histWriteAndSync(sealedHistory)
  if tx.wal != nil:
    var batch = tx.frames
    batch.add Frame(lsn: tx.nextLsn, txnId: tx.id, op: opNoop,
                   txnFlags: TxnCommit, payload: "")
    discard tx.wal.appendFrames(batch)
    if tx.sync:
      tx.wal.sync()
    tx.wal.nextLsn = tx.nextLsn + 1

  # 4. Merge. Past this point the frames are durable, so a crash here is
  #    recoverable rather than lost.
  let s = tx.store
  ## TXN.md §3.1 step 7: copy the arrays, mutate the copies, swap. Only
  ## when a read snapshot is outstanding — see prepareForWrite for why the
  ## no-reader case skips the copy.
  s.prepareForWrite()
  ## Exclude readers for the whole merge. This is what makes an in-place
  ## merge safe: no reader can be inside the published arrays while this
  ## runs, so there is nothing to copy for.
  s.beginWrite()

  # 4a. Reserve slots and label membership, but do not write the records
  #     yet. A node's adjacency is rebuilt by the edge merge below, so
  #     writing the record first would let the edge merge's head updates be
  #     overwritten by a delta record captured before them — `setProp` on
  #     an endpoint puts the *base* record into the delta, stale heads and
  #     all, which is what made the degree counts drift (S4) and left
  #     tombstones reachable in a neighbour's chain (S9b).
  for id, rec in tx.nodeDelta:
    if s.nodes.len <= id.int:
      let firstNew = max(1, s.nodes.len)
      s.nodes.setLen(max(id.int + 1, s.nodes.len * 2))
      s.labelPos.setLen(s.nodes.len)
      ## Only the new slots. Resetting the whole array would wipe every
      ## position a live node already had, and the next label delete would
      ## then remove an arbitrary member.
      for i in firstNew ..< s.labelPos.len:
        s.labelPos[i] = -1

  ## Deletions are applied first and the touched chains rebuilt once at
  ## the end, rather than unlinked one at a time. `unlinkEdge` splices
  ## through `nextOut`/`nextIn`, which are the links the edges had when
  ## they were created, so removing several edges of one chain in place
  ## makes the result depend on hash-table iteration order.
  var deletedEdges: seq[EdgeRec] = @[]
  for id, rec in tx.edgeDelta:
    if s.edges.len <= id.int:
      s.edges.setLen(max(id.int + 1, s.edges.len * 2))
    let wasLive = s.edgeExists(id)
    if rec.live:
      if not wasLive:
        ## Splice, do not overwrite. `createEdge` recorded a `nextOut`
        ## pointing at whatever the endpoint's head was *at creation
        ## time*, which is stale by the time the merge runs: two edges
        ## created in one transaction from the same node both recorded
        ## the same base head, and setting `outHead` for each left the
        ## first one orphaned in no chain while its endpoint's degree
        ## count had already been bumped (S4).
        var e = rec
        e.nextOut = s.nodes[rec.src.int].outHead
        e.nextIn = s.nodes[rec.dst.int].inHead
        s.edges[id.int] = e
        s.nodes[rec.src.int].outHead = id
        s.nodes[rec.src.int].outCount += 1
        s.nodes[rec.dst.int].inHead = id
        s.nodes[rec.dst.int].inCount += 1
      else:
        s.edges[id.int] = rec
    else:
      if wasLive:
        deletedEdges.add rec
      s.edges[id.int] = rec

  var touched = initHashSet[int64]()
  for e in deletedEdges:
    touched.incl e.src
    touched.incl e.dst
  for nid in touched:
    s.rebuildChains nid

  # 4b. Node records last, keeping the adjacency the edge merge just
  #     established. A tombstoned node has no incident edges left, so its
  #     adjacency is zeroed outright.
  for id, rec in tx.nodeDelta:
    let wasLive = s.nodeExists(id)
    var merged = rec
    if rec.live:
      if not wasLive and s.labelPos.len > id.int:
        s.attachToLabel(id, rec.label)
      merged.outHead = s.nodes[id.int].outHead
      merged.inHead = s.nodes[id.int].inHead
      merged.outCount = s.nodes[id.int].outCount
      merged.inCount = s.nodes[id.int].inCount
    else:
      if wasLive:
        s.detachFromLabel(id, s.nodes[id.int].label)
      merged.outHead = 0
      merged.inHead = 0
      merged.outCount = 0
      merged.inCount = 0
    s.nodes[id.int] = merged

  ## The last LSN this store now holds durably. Stamped after the WAL
  ## frames are fsynced and after the history sidecar is synced, so it names
  ## a commit that reached the disk. S3 replays from here.
  if tx.nextLsn > s.lastLsn:
    s.lastLsn = tx.nextLsn

  # The allocators must never hand out an id a live record holds, so they
  # advance past everything this transaction issued even on rollback.
  s.nodeIds.advancePast(tx.nextNodeId - 1)
  s.edgeIds.advancePast(tx.nextEdgeId - 1)

  # 5. Publish. One reference assignment makes the whole committed set
  #    visible at once (TXN.md §3.1 step 8, pin X3).
  inc s.generation
  s.publish()
  ## The cross-process visibility announcement (PRD-SHARED S2.3). Published
  ## *here*: after the WAL is fsynced (step 2-3) and after the `.vhist`
  ## sidecar is synced (step 2b), so "a generation is announced" means "its
  ## frames are on the disk", and before the cross-process write lock is
  ## released, so another writer cannot slip a generation in between.
  ##
  ## `s.lastLsn` rather than `tx.nextLsn`: it is the LSN this store has
  ## durably applied, which is what a reader must replay *to* in S3, and the
  ## two agree here because this transaction is the only thing that moved it.
  if s.shm != nil:
    ## Named `publishCommitted`, not `publish`: `GraphStore` already has a
    ## `publish` (the in-process array swap, two lines up), and a same-named
    ## proc on the shared block is the kind of collision that compiles into
    ## the wrong call rather than an error.
    s.shm.publishCommitted(s.generation, s.lastLsn)
  ## The revision commit was already sealed above, next to the log's COMMIT
  ## frame — it has to be, because the file write needs the sealed record to
  ## encode and the seal needs nothing from the merge. `histSeal` is a no-op
  ## the second time (it clears `histCommit`), so this call is the belt to
  ## that braces: a commit whose file write was skipped still seals here.
  discard tx.histSeal()
  if tx.indicesToUpdate != nil:
    applyDelta(tx.indicesToUpdate, s, tx.nodeDelta, tx.edgeDelta)
  s.endWrite()
  s.releaseWriter()
  true

proc rollback*(tx: WriteTransaction): bool =
  ## Drop the deltas. The base was never touched, so there is nothing to
  ## undo — that is the whole point of the design (TXN.md §3).
  if tx.closed:
    return false
  tx.closed = true
  ## The history erases what this transaction recorded. It has to be explicit:
  ## the revision store is outside the base arrays, so the "the base was never
  ## touched, so there is nothing to undo" argument that makes rollback free
  ## here does not reach it, and a revision written by a transaction that then
  ## failed would be a commit that never happened.
  tx.histAbort()
  tx.deltaNodesIdx = @[]
  tx.deltaNodeSet.clear()
  tx.deltaOutIdx.clear()
  tx.deltaInIdx.clear()
  tx.deltaSeekIdx.clear()
  ## The rollback marker is what tells recovery the transaction ended
  ## rather than died; a memory database has no log to write it to.
  if tx.wal != nil:
    var marker = Frame(lsn: tx.nextLsn, txnId: tx.id, op: opNoop,
                       txnFlags: TxnRollback, payload: "")
    discard tx.wal.appendFrames([marker])
    tx.wal.nextLsn = tx.nextLsn + 1
  tx.store.nodeIds.advancePast(tx.nextNodeId - 1)
  tx.store.edgeIds.advancePast(tx.nextEdgeId - 1)
  tx.store.releaseWriter()
  true

proc frameCount*(tx: WriteTransaction): int {.inline.} = tx.frames.len

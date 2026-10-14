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

import std/[tables, sets]
import ../store/prop
import ../wal/wal
import ../store/store
import ../index/index

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
    deltaOutIdx*: Table[int64, seq[int64]]
    deltaInIdx*: Table[int64, seq[int64]]
    nodeProps*: Table[int64, PropView]
    edgeProps*: Table[int64, PropView]
    nextNodeId*: int64
    nextEdgeId*: int64
    nextLsn*: uint64
    closed*: bool

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
  result.deltaOutIdx = initTable[int64, seq[int64]]()
  result.deltaInIdx = initTable[int64, seq[int64]]()
  result.nodeProps = initTable[int64, PropView]()
  result.edgeProps = initTable[int64, PropView]()
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
  var payload = ""
  putI64(payload, id)
  putI32(payload, code)
  tx.emit(opCreateNode, payload)
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

  # The allocators must never hand out an id a live record holds, so they
  # advance past everything this transaction issued even on rollback.
  s.nodeIds.advancePast(tx.nextNodeId - 1)
  s.edgeIds.advancePast(tx.nextEdgeId - 1)

  # 5. Publish. One reference assignment makes the whole committed set
  #    visible at once (TXN.md §3.1 step 8, pin X3).
  inc s.generation
  s.publish()
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
  tx.deltaNodesIdx = @[]
  tx.deltaOutIdx.clear()
  tx.deltaInIdx.clear()
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

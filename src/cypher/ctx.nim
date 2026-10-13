## glyphes — the execution context and the row (EXEC.md §1)
##
## These two live in their own module because of an import cycle that is a
## fact about the operator set rather than about taste: `Filter` and
## `Project` evaluate expressions, and expressions read the current row.
## Putting `QueryCtx` and `Row` here lets `expr.nim` depend on the context
## without the operators depending on the evaluator's evaluator.
##
## **One `ReadSnapshot` per statement, held for its whole life** (TXN.md
## §2). That single decision is what makes property reads safe: the merge
## takes the store mutex, `beginRead` holds the same mutex until `endRead`,
## so the arena cannot be mutated while a snapshot is open and a
## `PropView`'s arena offsets cannot go stale underneath a reader. It is
## also the price TXN.md §4 records — readers serialise — and the reason
## nothing here is allowed to call `endRead` early.

import std/[tables, atomics]
import ../index/index
import ../store/store
import ../txn/txn
import ../store/prop

type
  QueryCtx* = ref object
    ## Everything an operator needs that is not the plan.
    store*: GraphStore
    ## The index registry, nil for a statement that was not prepared through
    ## a `Database` (the unit tests build contexts by hand). Nil means "no
    ## indexes", which is a plan that scans — the M4 behaviour, and the
    ## reason a missing registry is a slowdown rather than a wrong answer.
    indices*: Indexes
    snap*: ReadSnapshot
    params*: Table[string, Value]
    ## Named parameters only (ABI.md B5). A missing parameter is an error
    ## at evaluation time rather than at prepare time, because a parameter
    ## may legitimately be absent from a JSON object and default to null
    ## — Cypher's rule, not a silent substitution.
    maxResultRows*: int64      ## TXN.md §6; 0 = unbounded
    rowsEmitted*: int64
    ## Identity of this statement, and the memory budget for a sort that
    ## outgrows RAM.
    ##
    ## `stmtId` names the statement's spilled runs on disk: two sorts in one
    ## process must not share a run file, and a collision would merge one
    ## query's rows into another's answer — the only failure in the spill
    ## path that produces no error.
    stmtId*: uint64
    ##
    ## Rows a sort may hold before it spills, and where the runs go. Zero
    ## means "buffer everything", which is what a database with no memory
    ## budget chooses. `spillDir` empty means the OS temp directory.
    sortSpillRows*: int
    spillDir*: string
    ## M5: the write side. `writer` is nil for a read statement, and a
    ## query containing a write clause is refused at plan time when it is
    ## nil — a write with nowhere to go is not a read that happens to
    ## ignore its writes (pin C1's "never a wrong answer", applied to
    ## writes). The transaction resolves label, relationship-type and
    ## property-key names itself, so the query layer never needs the
    ## Database — which also keeps `database → cypher` (glyphes_exec) and
    ## `cypher → database` from becoming a cycle.
    ## A ref, so nil *is* the no-writer case; a `ptr` would have meant the
    ## same thing with a deref at every call site.
    writer*: WriteTransaction
    rowsAffected*: int64       ## TXN.md §3: entities created/deleted/updated
    ## The transaction's own writes, as the statement sees them.
    ##
    ## Without this, `CREATE (n:P)` followed by `MATCH (n:P) SET n.v = 1` in
    ## the same transaction finds nothing: reads go to the published
    ## snapshot, and an uncommitted transaction has published nothing. Cypher
    ## gives a transaction its own writes ("read your writes"), and so must
    ## this — the alternative is a write language where the second statement
    ## of a transaction cannot see the first, and `MERGE` (M5.3), which is
    ## defined as match-then-create, would be untestable inside a
    ## transaction.
    ##
    ## Built lazily on a statement's first read and then frozen. Frozen
    ## because this is *earlier* statements' writes: a statement never sees
    ## its own (pin C4), and in every clause order the slice accepts, the
    ## first store access is the leading MATCH, which runs before the
    ## statement's own CREATE/SET.
    deltaReady*: bool
    deltaNodes*: seq[int64]
    deltaOut*: Table[int64, seq[int64]]
    deltaIn*: Table[int64, seq[int64]]

  Row* = object
    ## One row's bindings. A linear array rather than a hash table: a query
    ## row holds a handful of variables (`a`, `b`, `r`, and whatever the
    ## caller aliased), and a scan on four to eight elements beats a hash
    ## lookup's pointer chase on every single row of a traversal — which is
    ## the hot path C9 measures.
    slots*: seq[(string, Value)]

proc initRow*(n = 8): Row =
  result.slots = newSeqOfCap[(string, Value)](n)

proc lookup*(r: Row, name: string): (bool, Value) =
  ## `(found, value)`. Two results rather than a default because `null` is
  ## a legitimate binding and "bound to null" must not read as "unbound".
  for s in r.slots:
    if s[0] == name:
      return (true, s[1])
  (false, Value(kind: vkNull))

proc set*(r: var Row, name: string, v: Value) =
  for i in 0 ..< r.slots.len:
    if r.slots[i][0] == name:
      r.slots[i] = (name, v)
      return
  r.slots.add (name, v)

proc has*(r: Row, name: string): bool {.inline.} =
  for s in r.slots:
    if s[0] == name:
      return true
  false

proc clear*(r: var Row) = r.slots.setLen(0)

proc copyRow*(src: Row): Row =
  ## A snapshot of a row for an operator that must not see its child move
  ## on. Only `Sort` and `Distinct` need this in 0.1, and both buffer, so
  ## the cost lands where a buffer already exists.
  result.slots = newSeqOfCap[(string, Value)](src.slots.len)
  result.slots = src.slots

var stmtCounter: Atomic[uint64]

proc nextStmtId*(): uint64 =
  ## Monotonic, never reused. Reuse would let a *previous* statement's run
  ## files still sitting in the directory be mistaken for this one's — a
  ## sort that silently merges another query's rows into its answer.
  stmtCounter.fetchAdd(1'u64) + 1'u64

proc buildDelta*(ctx: QueryCtx) =
  ## One pass over the transaction's delta, turned into the three indexes
  ## the read path asks for: which nodes exist beyond the snapshot, and
  ## which edges leave and enter each one.
  if ctx.deltaReady:
    return
  ctx.deltaReady = true
  if ctx.writer == nil:
    return
  for id, rec in ctx.writer.nodeDelta:
    if rec.live:
      ctx.deltaNodes.add id
  for id, rec in ctx.writer.edgeDelta:
    if not rec.live:
      continue
    ctx.deltaOut.mgetOrPut(rec.src, @[]).add id
    ctx.deltaIn.mgetOrPut(rec.dst, @[]).add id

proc nodeRecOf*(ctx: QueryCtx, id: int64): (bool, NodeRec) =
  ## The node's record as *this statement* may see it: the snapshot first,
  ## then the transaction's delta. Two sources, one answer — which is what
  ## stops every read site from growing its own "and if it is new?" branch.
  buildDelta(ctx)
  if id > 0 and id.int < ctx.snap.nodes.len:
    let rec = ctx.snap.nodes[id.int]
    if rec.live:
      return (true, rec)
  if ctx.writer != nil:
    let rec = ctx.writer.peekNode(id)
    if rec.live:
      return (true, rec)
  (false, NodeRec())

proc liveDelta*(ctx: QueryCtx, id: int64): bool =
  ## True when the node exists *only* in the transaction's delta — the case
  ## the snapshot's arrays cannot answer, because the id is past their end.
  buildDelta(ctx)
  result = false
  if ctx.writer == nil:
    return
  for did in ctx.deltaNodes:
    if did == id:
      return true

# ------------------------------------------------- reads through a snapshot

proc readNodePropFrom*(ctx: QueryCtx, rec: NodeRec, key: string,
                       v: var Value): bool =
  ## The record's `propView` resolves against the store's arena, which the
  ## read lock makes immutable for the snapshot's lifetime — that is the
  ## whole answer to "a PropView holds arena offsets, so how is a read
  ## safe?" (see `store.setNodeProp`'s comment for the other half).
  let code = ctx.store.propKeys.lookup(key)
  if code == 0:
    return false
  ## A node this statement created has no snapshot record, so its properties
  ## come from the transaction's staged view. `txn.setPropCommon` keeps that
  ## view in `nodeProps` precisely so a read after a write in the same
  ## transaction sees the written value; this is the read side of that pair.
  if ctx.writer != nil and ctx.writer.nodeProps.hasKey(rec.id):
    return ctx.store.arena.getProp(ctx.writer.nodeProps[rec.id], code, v)
  ctx.store.arena.getProp(rec.propView, code, v)

proc readNodeProp*(ctx: QueryCtx, id: int64, key: string, v: var Value): bool =
  ## Through the snapshot's array, not `store.nodes`. Under the read lock the
  ## two are the same bytes, but reading the snapshot is what makes the
  ## intent checkable rather than argued: a statement reads one generation
  ## because it indexes the generation's arrays — plus, for a write
  ## statement, the transaction's own uncommitted nodes.
  let (found, rec) = ctx.nodeRecOf(id)
  if not found:
    return false
  ctx.readNodePropFrom(rec, key, v)

proc readEdgePropFrom*(ctx: QueryCtx, rec: EdgeRec, key: string,
                       v: var Value): bool =
  ## The edge-side twin of `readNodePropFrom`.
  let code = ctx.store.propKeys.lookup(key)
  if code == 0:
    return false
  ctx.store.arena.getProp(rec.propView, code, v)

proc readEdgeProp*(ctx: QueryCtx, id: int64, key: string, v: var Value): bool =
  if id <= 0 or id.int >= ctx.snap.edges.len:
    return false
  let rec = ctx.snap.edges[id.int]
  if not rec.live:
    return false
  ctx.readEdgePropFrom(rec, key, v)

proc nodeAlive*(ctx: QueryCtx, id: int64): bool =
  ## Snapshot, then the transaction's delta. Not `{.inline.}` any more: the
  ## delta half is a call, and a query over a snapshot (no writer) pays a
  ## branch for it — the cheap version of the inline body is kept as
  ## `nodeAliveSnapshot` for the scan loops that cannot see delta nodes.
  if id > 0 and id.int < ctx.snap.nodes.len and ctx.snap.nodes[id.int].live:
    return true
  ctx.liveDelta(id)

proc edgeAlive*(ctx: QueryCtx, id: int64): bool =
  if id > 0 and id.int < ctx.snap.edges.len and ctx.snap.edges[id.int].live:
    return true
  if ctx.writer == nil:
    return false
  ctx.writer.peekEdge(id).live

proc labelOfNode*(ctx: QueryCtx, id: int64): string =
  ## "" for an unlabelled or dead node. Callers that care distinguish the
  ## two with `nodeAlive`; `labels(n)` on a dead node returning [] is
  ## Cypher's answer, not a second error path.
  if not ctx.nodeAlive(id):
    return ""
  ctx.store.labels.nameOf(ctx.snap.nodes[id.int].label)

proc typeOfEdge*(ctx: QueryCtx, id: int64): string =
  if not ctx.edgeAlive(id):
    return ""
  ctx.store.relTypes.nameOf(ctx.snap.edges[id.int].etype)
# ------------------------------------------------------------- traversal

proc outEdges*(ctx: QueryCtx, id: int64): seq[int64] =
  ## Through the snapshot, following `nextOut`. A copy rather than a cursor
  ## because the alternative is an operator that holds three cursors (node
  ## id, edge id, direction) and a degree-ordered walk is what makes the
  ## planner's "expand from the lower-degree side" rule measurable; at
  ## these degrees a list beats the bookkeeping.
  result = @[]
  ## The snapshot half is skipped for a node the snapshot has never heard of
  ## — which is every node this transaction created — but the delta half
  ## still has to run. Guarding the whole walk on the snapshot's range (the
  ## first version) made an edge written and then traversed in the same
  ## transaction invisible, because the new node's id is past the array's
  ## end and the walk returned before reaching the delta.
  if id > 0 and id.int < ctx.snap.nodes.len:
    var e = ctx.snap.nodes[id.int].outHead
    while e != 0 and e.int < ctx.snap.edges.len:
      result.add e
      e = ctx.snap.edges[e.int].nextOut
  ## Edges an earlier statement in this transaction made are only in its
  ## delta — `createEdge` links into the delta, not into the published
  ## chains, so a walk of the committed chain cannot see them.
  buildDelta(ctx)
  if ctx.deltaOut.hasKey(id):
    for eid in ctx.deltaOut[id]:
      result.add eid

proc inEdges*(ctx: QueryCtx, id: int64): seq[int64] =
  result = @[]
  if id > 0 and id.int < ctx.snap.nodes.len:
    var e = ctx.snap.nodes[id.int].inHead
    while e != 0 and e.int < ctx.snap.edges.len:
      result.add e
      e = ctx.snap.edges[e.int].nextIn
  buildDelta(ctx)
  if ctx.deltaIn.hasKey(id):
    for eid in ctx.deltaIn[id]:
      result.add eid

proc degree*(ctx: QueryCtx, id: int64): (int, int) =
  ## `(out, in)` from the eagerly maintained counts (STORAGE.md §2.1).
  ## The planner uses the sum to pick an expand side, and a count that is
  ## maintained on every write is free here and O(degree) if computed.
  if id <= 0 or id.int >= ctx.snap.nodes.len:
    return (0, 0)
  let n = ctx.snap.nodes[id.int]
  (int(n.outCount), int(n.inCount))

proc edgeEnds*(ctx: QueryCtx, edgeId: int64): (int64, int64, int32) =
  ## `(src, dst, typeCode)`. Out-of-range gives zeros, which no live edge
  ## has: ids start at 1 and a dead edge is filtered before this is called.
  ##
  ## Delta-aware, and it has to be: an edge created earlier in this same
  ## transaction has an id past the published array, so the snapshot-only
  ## version answered (0, 0, 0) and every traversal from it silently
  ## produced no rows — a relationship written and then queried for in the
  ## same transaction looked like it did not exist.
  if edgeId > 0 and edgeId.int < ctx.snap.edges.len:
    let e = ctx.snap.edges[edgeId.int]
    if e.live:
      return (e.src, e.dst, e.etype)
  if ctx.writer != nil:
    let e = ctx.writer.peekEdge(edgeId)
    if e.live:
      return (e.src, e.dst, e.etype)
  (0, 0, 0)

## `lent` for the reason in store.nim: without it this copies the whole
## member table on every call.
proc propKeysOf*(ctx: QueryCtx, id: int64; isNode: bool): seq[string] =
  ## The property keys of one node or edge, as *this statement* sees them.
  ##
  ## The committed store is the right answer for a read statement and the
  ## wrong one for a write statement: a node this transaction created has no
  ## record there at all, and a node it has written to has a stale one. So
  ## the transaction's staged view wins when there is one — which is what
  ## makes `keys(n)` agree with `n.x` inside a transaction.
  if ctx.writer != nil:
    ## The two record types are different objects, so the branches cannot be
    ## folded into one `let rec = if …` — Nim picks a type at compile time.
    if isNode:
      let rec = ctx.writer.peekNode(id)
      if rec.live:
        var pv = rec.propView
        if ctx.writer.nodeProps.hasKey(id):
          pv = ctx.writer.nodeProps[id]
        for slot in ctx.store.arena.readSlots(pv):
          result.add ctx.store.propKeys.nameOf(slot.key)
        return
    else:
      let rec = ctx.writer.peekEdge(id)
      if rec.live:
        var pv = rec.propView
        if ctx.writer.edgeProps.hasKey(id):
          pv = ctx.writer.edgeProps[id]
        for slot in ctx.store.arena.readSlots(pv):
          result.add ctx.store.propKeys.nameOf(slot.key)
        return
  result = if isNode: ctx.store.nodePropKeys(id) else: ctx.store.edgePropKeys(id)

proc nodeLabels*(ctx: QueryCtx): lent seq[seq[int64]] {.inline.} = ctx.snap.members

proc maxNodeId*(ctx: QueryCtx): int64 = int64(ctx.snap.nodes.len)

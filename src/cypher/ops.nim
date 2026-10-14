## glyphes — the pull operators (EXEC.md §§1–2)
##
## One type with a `kind` and a `case` in the dispatch, rather than one
## subclass per operator. Nim has no virtual methods and no need for them
## here: the whole operator set is eleven kinds, they share nearly every
## field (`child`, `current`, `columns`, `ctx`), and a `case` costs one
## dispatch per row on a structure that is a cache line. A class hierarchy
## would buy eleven indirect calls to avoid eleven case labels.
##
## **The pull contract, which is what EXEC.md §0 calls irreversible:**
##
##   - `next()` produces one row into `current` and returns whether there
##     was one. It never materialises more than one.
##   - `LIMIT n` therefore pulls n rows and never pulls n+1.
##   - An operator may not retain its child's row after its own `next`
##     returns. The two that must — `Sort` and `Distinct` — buffer a *copy*
##     (`ctx.copyRow`) and say so.
##   - Every operator is single-use: `init`, then `next` until false. There
##     is no rewind, because a query that iterates twice gets two
##     executions.
##
## Property reads go through `QueryCtx`, never through the store directly:
## the snapshot's arrays are the generation, and the read lock they are held
## under is what makes a `PropView`'s arena offsets safe (see ctx.nim).

import std/[sets, algorithm, os, tables, math]
import ../store/store
import ../store/prop
import ../txn/txn
import ../index/index
import ../index/range
import ../index/text
import ../index/analyzer
import ../index/vector
import ./ast
import ./ctx
import ./spill
import ./expr
import ./errors
import ../errors
import ../abi

type
  OpKind* = enum
    okOneRow, okScanAll, okScanByLabel, okExpand, okExpandVar,
    okFilter, okProject, okSkip, okLimit, okSort, okDistinct, okUnwind,
    okCreate,                         ## M5: writes a pattern, per row
    okSet, okRemove, okDelete,         ## …and the clauses that change one
    okMerge,                          ## M5.3: match, else create
    okAggregate,                      ## M5.4: group, then fold
    okVarLen,                         ## M5.5: one path per row, no edge twice
    okInputRow,                       ## M5.5: yields the row it was handed
    okOptional,                       ## M5.5: left-outer, null-filled
    okIndexSeek,                      ## M6.1: ids from a range index
    okTextSearch,                     ## M6.2: scored hits from a text index
    okVectorSearch                    ## M6.3: nearest neighbours from HNSW

  VarPath* = object
    ## One walk of `*minHops..maxHops`: the relationships it crossed, in
    ## order, and the node it ended on. `edges` is what the relationship
    ## variable binds to — a *list*, because Cypher's `-[r*1..3]->` binds
    ## the whole path and not one of its relationships.
    edges*: seq[int64]
    at*: int64

  Group* = object
    ## One distinct key and every input row that had it. `rows` is the whole
    ## group, not a running fold, because `avg` cannot be computed from a
    ## running total and a sum alone.
    key*: string
    keyValues*: seq[Value]
    rows*: seq[Row]

  Operator* = ref object
    kind*: OpKind
    child*: Operator
    ctx*: QueryCtx
    columns*: seq[string]
    current*: Row
    ## Scans. `ids` is non-nil for a label scan and nil for a full scan;
    ## both walk ids in ascending order, which is the store's own order and
    ## therefore its cheapest.
    ##
    ## A scan binds the node it produced to `bindVar`. The scan itself holds
    ## no pattern: the planner already decided *which* nodes this operator
    ## walks, so the scan's only remaining job is to walk them and name
    ## them. An anonymous pattern (`(:Doc)`) has no variable and binds
    ## nothing, which is why `bindVar` may be empty.
    bindVar*: string
    ## Nodes this transaction created and the snapshot therefore cannot
    ## list. Filled once when the scan is built (the scan's set is fixed
    ## before the statement's own writes), so the per-row cost is a cursor,
    ## not a dictionary walk.
    deltaIds*: seq[int64]
    deltaAt*: int
    ## 0 = any label; -1 = a label nothing carries, so the scan yields
    ## nothing. The two are different states and conflating them is how
    ## `MATCH (x:Nonexistent)` returns the whole store: an unknown label
    ## looks up as 0, which is also "no filter".
    ##
    ## The filter lives *here* rather than in a Filter above the scan:
    ## comparing one int32 per row against the record's own field is an
    ## array subscript, and the alternative — `labels(a) = 'X'` evaluated
    ## per row — builds a list and compares a string for every node in the
    ## store.
    labelCode*: int32
    cursor*: int64
    ids*: seq[int64]
    idsAt*: int
    ## Expand.
    boundVar*, relVar*, endVar*: string
    dir*: Direction
    typeCode*: int32
    edgeList*: seq[int64]
    edgeAt*: int
    hop*, hopCount*: int
    ## Filter / Project.
    cond*: Expr
    items*: seq[ReturnItem]
    ## M5.4 grouping. `keyItems` are the projection's non-aggregate items —
    ## the group key; `groups` holds every buffered group in first-seen order
    ## so that two runs of the same query emit the same rows in the same
    ## order without anyone having to ask for an ORDER BY.
    keyItems*: seq[Expr]
    keyNames*: seq[string]
    groups*: seq[Group]
    outRows*: seq[Row]
    outIdx*: int
    built*: bool
    ## M5.5 variable length. `paths` is this input row's walks, enumerated up
    ## front: a walk is only known to be a walk once it has finished, and
    ## the emitter has to hand out one path per call.
    startVar*, relVar2*, endVar2*: string
    minHops*, maxHops2*: int
    dir2*: Direction
    typeCode2*: int32
    paths*: seq[VarPath]
    pathRows*: seq[Row]
    pathAt*: int
    ## M5.5 OPTIONAL MATCH. `vars2` is every variable the pattern binds, and
    ## they are what gets filled with null when the right side finds
    ## nothing.
    vars2*: seq[string]
    fedRow*: Row
    fedArmed*: bool
    optRows*: seq[Row]
    optAt*: int
    ## M5.6 sort spill. `buffered` fills to `spillRows` and is then sorted
    ## and written out as one run; `runs` are the files on disk. A sort that
    ## never reaches `spillRows` spills nothing and is the old in-memory
    ## path, which is the case every ordinary query takes.
    runs*: seq[string]
    spillRows*: int
    spillDir*: string
    runNo*: int
    ## The merge's live state: one buffered row per open run, and the reader
    ## for each. Held together so advancing the merge is one proc that
    ## cannot half-update them.
    mergeReaders*: seq[RunReader]
    mergeHeads*: seq[Row]
    mergeLive*: seq[bool]
    buildSub*: proc (row: Row): Operator {.closure.}
    ## M5 write clauses.
    createPatterns*: seq[Pattern]
    setItems*: seq[SetItem]
    removeItems*: seq[PropRef]
    deleteVars*: seq[string]
    detach*: bool
    ## M5.3 MERGE. The patterns are stored as parsed; the match half is
    ## planned per row from them (see `mergeMatchPlan`), because a plan is a
    ## stateful cursor and this operator needs a fresh one for every row it
    ## passes on.
    mergePatterns*: seq[Pattern]
    onCreateSet*: seq[SetItem]
    onCreateRemove*: seq[PropRef]
    onMatchSet*: seq[SetItem]
    onMatchRemove*: seq[PropRef]
    list*: seq[Value]           ## UNWIND's elements, materialised lazily
    ## Skip / Limit.
    skipped*, taken*: int64
    limit*: int64
    ## M6.1 index seek. `seekIds` comes from the index at plan time (a plan
    ## is built once and the index does not move while it runs); `deltaIds`
    ## are the transaction's own new nodes, which the index has not seen yet
    ## and which a read inside the transaction must still see — pin C4.
    seekIds*: seq[int64]
    seekAt*: int
    ## Named apart from the scan's `deltaIds` because they are different
    ## sets: the scan's is every delta node, this one's is the subset the
    ## seek will hand out.
    seekDeltaIds*: seq[int64]
    seekDeltaAt*: int
    seekLabel*: int32
    indexName*: string
    ## Text search. The hits are computed once at build — the query text is
    ## fixed and the index state is the statement's snapshot — so the
    ## per-row work is a cursor and two bindings, exactly like a seek.
    textHits*: seq[Hit]
    textAt*: int
    scoreVar*: string
    ## Vector search. Same shape as the text search: hits at build, cursor
    ## per row. `vecPushed` is the part of the following WHERE that got
    ## pushed into the walk (only expressions over the yielded node); it is
    ## evaluated per visited candidate, which is what makes ef land on
    ## live rows instead of filtered-out ones (INDEX.md §4.3).
    vecHits*: seq[(int64, float32)]
    vecAt*: int
    vecPushed*: seq[Expr]
    ## Sort / Distinct — the only two that buffer.
    buffered*: seq[Row]
    sortSpec*: SortSpec
    seen*: HashSet[string]
    started*: bool
    exhausted*: bool

proc isTrue(v: Value): bool = v.kind == vkBool and v.b

proc cmpRows(op: Operator, a, b: Row): int
proc rowKey(ctx: QueryCtx, row: Row, columns: seq[string]): string

proc nodeOf(row: Row, name: string): (bool, Value)  ## used by okVarLen
proc next*(op: Operator): bool  ## buildGroups pulls a child cursor
proc buildGroups(op: Operator)
proc spillRun(op: Operator)
proc startMerge(op: Operator)
proc mergeNext(op: Operator, row: var Row): bool
proc finishSort(op: Operator)

# ------------------------------------------------------------- constructors

proc scanDeltaNodes(ctx: QueryCtx): seq[int64] =
  ## The transaction's live new nodes, once. Empty for a read statement, so
  ## the read path pays one nil check per scan and nothing per row.
  if ctx.writer == nil:
    return @[]
  buildDelta(ctx)
  ctx.deltaNodes

proc newScanAll*(ctx: QueryCtx, bindVar: string; labelCode = 0'i32): Operator =
  Operator(kind: okScanAll, ctx: ctx, cursor: 1, bindVar: bindVar,
           labelCode: labelCode, deltaIds: scanDeltaNodes(ctx))

proc newScanByLabel*(ctx: QueryCtx, label: string, bindVar: string): Operator =
  ## An unknown label yields an empty operator rather than an error: a query
  ## against a label nothing has been written with yet has no rows, and
  ## "no such label" is not a Cypher error.
  result = Operator(kind: okScanByLabel, ctx: ctx, bindVar: bindVar)
  let code = ctx.store.labels.lookup(label)
  if code == 0:
    result.exhausted = true
    return
  ## Both reads go through the snapshot directly. Binding `ctx.snap.members`
  ## to a local — even a `let` — copies the table, and a copy of a
  ## `seq[seq[int64]]` is a copy of every label's member list: 128 us per
  ## scan at 2*10^5 nodes, which the M4 benchmark measured as the whole
  ## cost of a query. `lent` says "hand me the sequence"; a `let` says
  ## "give me my own copy", and the two are not the same request.
  if code.int <= ctx.snap.members.len:
    result.ids = ctx.snap.members[code.int - 1]
  result.idsAt = 0
  result.deltaIds = scanDeltaNodes(ctx)

## --- The shared seek machinery -------------------------------------
##
## This lives here rather than in plan.nim because MERGE needs it too,
## and plan.nim imports this module — the reverse import is a cycle.
## `mergeChain` used to build its match half with `scanFor` because the
## seek was unreachable from here, which made every MERGE a full label
## scan: edge load ran at 183/s against 11 600/s for node load. The
## planner's `seekCandidates` and MERGE's head now answer through the
## same two functions, so the two cannot drift into different plans for
## the same predicate.

type SeekKey* = object
  ## What a seek needs: the node variable, the property, the comparison, and
  ## the value. Kept as data rather than as an operator so the planner can
  ## *ask* whether an index exists before it commits to a plan — a plan
  ## that cannot be executed is not a plan.
  varName*: string
  prop*: string
  op*: string
  value*: Value
  values*: seq[Value]        ## `IN`: more than one

proc flipOp*(op: string): string =
  ## The comparator with its operands swapped, for `30 = n.age`.
  case op
  of "=": "="
  of "<": ">"
  of ">": "<"
  of "<=": ">="
  of ">=": "<="
  else: ""

proc seekKeyable*(key: SeekKey): bool =
  ## Whether every value this predicate carries is one the index can hold.
  ## Checked here rather than inside the index so that "should I use the
  ## index" is a planner question with one answer: a bool or a list in the
  ## predicate means the scan answers and the index was never a shortcut
  ## for it.
  if key.op == "IN":
    if key.values.len == 0:
      return false
    for v in key.values:
      if not keyable(v):
        return false
    return true
  keyable(key.value)

proc evalLiteral*(ctx: QueryCtx, e: Expr): Value =
  ## The value side of a seek predicate. A parameter resolves here, so
  ## `WHERE n.age = $age` is seekable — the plan is built after parameters
  ## are bound, which is why this is not a plan-time constant.
  if e.kind == ekParam:
    return ctx.params.getOrDefault(e.name, Value(kind: vkNull))
  evaluate(ctx, initRow(2), e)

proc seekIds*(ctx: QueryCtx, ix: RangeIndex, key: SeekKey): seq[int64] =
  ## The index's answer for one predicate. `IN` is a union of point seeks
  ## rather than a range: the ids are de-duplicated because a list may
  ## repeat a value, and a duplicated id would be a duplicated *row*.
  ## An unbounded side is `null`, which `keyLess` orders above everything, so
  ## it excludes nothing. The first version used ±1e308, and a *string*
  ## index silently returned nothing: `keyLess("p5", 1e308)` is false for
  ## every string, so every entry read as past the upper bound and the walk
  ## stopped on the first one. An infinity of the wrong type is not an
  ## infinity.
  result = @[]
  case key.op
  of "=":
    result = ix.seekEq(key.value)
  of "IN":
    var seen = initHashSet[int64]()
    for v in key.values:
      for id in ix.seekEq(v):
        if id notin seen:
          seen.incl id
          result.add id
  of "<":
    result = ix.collect(Value(kind: vkNull), key.value, false)
  of "<=":
    result = ix.collect(Value(kind: vkNull), key.value, true)
  of ">":
    result = ix.collect(key.value, Value(kind: vkNull), true)
  of ">=":
    result = ix.collect(key.value, Value(kind: vkNull), true)
  else:
    result = @[]

proc scanFor*(ctx: QueryCtx, np: NodePattern): Operator =
  ## EXEC.md §4.1 rules 1 and 5, the two decisions the planner makes about
  ## a node pattern: a label dense enough to be worth its member list gets
  ## the label scan, anything else gets a filtered full scan. Shared with
  ## MERGE's match half so the two cannot drift into different answers for
  ## "how do I enumerate nodes with this label".
  let memberCount =
    if np.label.len == 0: 0
    else:
      let code = ctx.store.labels.lookup(np.label)
      if code == 0 or code.int > ctx.snap.members.len: 0
      else: ctx.snap.members[code.int - 1].len
  if np.label.len > 0 and memberCount >= 32:
    return newScanByLabel(ctx, np.label, np.varName)
  ## An unknown label is -1, not 0: 0 means "any label" to the scan, so a
  ## lookup of 0 would turn `MATCH (x:Nonexistent)` into a full scan.
  var code = 0'i32
  if np.label.len > 0:
    code = ctx.store.labels.lookup(np.label)
    if code == 0:
      code = -1'i32
  newScanAll(ctx, np.varName, code)

proc deltaSeekIds(ctx: QueryCtx, labelCode: int32, prop: string,
                   key: SeekKey): seq[int64] =
  ## The transaction's own rows for this seek key, from the delta seek
  ## index. O(1) in the delta's size for an equality key, which is what
  ## makes a bulk load linear.
  ##
  ## Only `=` is answered from the index. A range key (`<`, `IN`, …) has no
  ## bucket to look in, and — the reason this is not "just equality for
  ## now" — a seek that *misses* a row cannot be repaired by the filter
  ## above it, so an unanswered key must fall back to the full delta walk
  ## rather than answer nothing. Range predicates over uncommitted rows keep
  ## the O(delta) behaviour they have always had; they are not made wrong.
  if ctx.writer == nil or key.op != "=":
    return @[]
  ## One flat lookup keyed by (label, property, key-hash). The first shape
  ## was a table of tables, and `Table`'s `[]` returns its value *by
  ## value* — binding the inner bucket map to a local copied all of it, so
  ## the "O(1) delta seek" was O(buckets). That is the whole lesson of this
  ## change: an accelerator that copies its own index on every lookup is the
  ## quadratic it was written to remove.
  let h = keyHash(key.value)
  if not ctx.writer.deltaSeekIdx.hasKey((labelCode, prop, h)):
    return @[]
  let want = keyOf(key.value)
  var seen = initHashSet[int64]()
  for (k, id) in ctx.writer.deltaSeekIdx[(labelCode, prop, h)]:
    if not keySame(k, want):
      continue                 # a hash collision costs a compare, not a row
    if id in seen:
      continue                 # the same node set twice answers once
    seen.incl id
    result.add id

proc newIndexSeek*(ctx: QueryCtx, bindVar: string, ids: seq[int64],
                   labelCode: int32, indexName: string,
                   key: SeekKey = SeekKey()): Operator =
  ## EXEC.md §4.1 rule 3. `ids` is the index's answer, computed once at plan
  ## time; the operator's job is to hand them out with the liveness and the
  ## transaction's own writes taken into account.
  ##
  ## Liveness is checked here because the id list was built from an index
  ## that a concurrent commit may have made stale, and because a node
  ## tombstoned before the snapshot is still in a label list (STORAGE.md
  ## §4.3 compacts at checkpoint, not at delete). Pin I11: a deleted node is
  ## never returned.
  result = Operator(kind: okIndexSeek, ctx: ctx, bindVar: bindVar,
                    seekIds: ids, seekAt: 0, seekDeltaIds: @[],
                    seekDeltaAt: 0,
                    seekLabel: labelCode, indexName: indexName)
  if ctx.writer != nil:
    ## Equality consults the delta seek index and trusts its answer — the
    ## index is keyed by exactly this predicate, so an empty bucket means
    ## "this transaction wrote no row with that key", which is an answer.
    ## Anything else falls back to walking the whole delta, because a seek
    ## that misses a row cannot be repaired by the filter above it.
    if key.op == "=":
      result.seekDeltaIds = deltaSeekIds(ctx, labelCode, key.prop, key)
    else:
      result.seekDeltaIds = scanDeltaNodes(ctx)

proc newExpand*(ctx: QueryCtx; boundVar, relVar, endVar: string;
                dir: Direction; typeCode: int32): Operator =
  Operator(kind: okExpand, ctx: ctx, boundVar: boundVar, relVar: relVar,
           endVar: endVar, dir: dir, typeCode: typeCode)

proc newFilter*(ctx: QueryCtx, child: Operator, cond: Expr): Operator =
  Operator(kind: okFilter, ctx: ctx, child: child, cond: cond)

proc vecPredicate(ctx: QueryCtx, yieldVar: string,
                  pushed: seq[Expr],
                  ids: seq[int64] = @[]): proc (slot: int32): bool {.gcsafe.} =
  ## The pushed-down filter as one closure: bind the yielded name to a
  ## candidate node, evaluate every pushed conjunct with the engine's own
  ## expression evaluator. No second implementation of WHERE lives here —
  ## comparisons, refusals and type rules are the same code the filter
  ## operator runs, which is the whole reason the pushdown is split at
  ## the conjunct level rather than reimplemented as (key, op, value).
  proc check(slot: int32): bool {.gcsafe.} =
    ## The walk names slots; the predicate speaks in node ids, because the
    ## expression evaluator binds nodes. The mapping is `ids[slot]` — the
    ## slot-parallel array insert keeps in order. Marked gcsafe because the
    ## walk sits under commit's call chain through `insert`, and the soak's
    ## thread procs hold everything under there to the same rule; the
    ## evaluator and `isTrue` already are.
    var row = initRow(4)
    row.set(yieldVar, Value(kind: vkNode, id: ids[slot]))
    for e in pushed:
      if not isTrue(evaluate(ctx, row, e)):
        return false
    true
  return check

proc selectivityEstimate(ctx: QueryCtx, label: string,
                         pushed: seq[Expr]): float =
  ## INDEX.md §4.3: over-fetch is sized by selectivity, estimated from the
  ## property's range index when one exists, 10 % otherwise. This is one
  ## number to size a walk — a wrong estimate costs time, not correctness,
  ## and the estimates here are deliberately coarse: 0.5 when a range
  ## index vouches for the property, 0.1 when nothing does.
  result = 0.10
  if ctx.indices == nil:
    return
  for e in pushed:
    ## A conjunct over exactly one property of the yielded node, with a
    ## range index on that property, is worth a better prior.
    if e.kind == ekCompare and e.items.len >= 1 and
       e.items[0].kind == ekProp and e.items[0].target.kind == ekVar:
      let ix = ctx.indices.find(label, e.items[0].name)
      if ix != nil and ix.usable:
        return 0.5

proc newVectorSearch*(ctx: QueryCtx, indexName: string,
                      qvec: seq[float32], bindVar, scoreVar: string,
                      pushed: seq[Expr] = @[]): Operator =
  ## CYPHER.md §4: the vector retrieval, same source shape as the text
  ## one. Hits are computed once at build; the walk's filter is the
  ## pushed-down WHERE; deleted nodes are tombstoned in the index and
  ## never returned (I8).
  result = Operator(kind: okVectorSearch, ctx: ctx, bindVar: bindVar,
                    scoreVar: scoreVar, vecPushed: pushed)
  if ctx.indices == nil:
    fail(int32(glyErrSql), "no index registry: the database opened without indexes")
  let ix = ctx.indices.vector.getOrDefault(indexName)
  if ix == nil:
    fail(int32(glyErrSql), "no vector index named \"" & indexName & "\"")
  if ix.dim != 0 and qvec.len != ix.dim:
    fail(int32(glyErrSql), "query vector of dimension " & $qvec.len &
                           " does not match the index's " & $ix.dim)
  ## Over-fetch by selectivity (I10): with a pushed filter the walk is
  ## asked for more candidates than the caller will keep, so the ef budget
  ## lands on live rows. Bounded by MaxOverFetch — expensive, not unbounded.
  var k = ix.ef
  if pushed.len > 0:
    let sel = ctx.selectivityEstimate(ix.label, pushed)
    k = min(int(ceil(float(ix.ef) / sel)), MaxOverFetch)
  let pass = (if pushed.len > 0:
                ctx.vecPredicate(bindVar, pushed, ix.ids)
              else: nil)
  var hits = ix.search(qvec, k, pass)
  ## Read-your-writes (pin C4), same trade as the text retrieval: the
  ## transaction's own vectors are not in the graph yet, so they are
  ## scored directly — per-pair distances have no global statistics, so
  ## these scores are exact, not approximations.
  if ctx.writer != nil and ctx.writer.nodeDelta.len > 0:
    let labelCode = (if ix.label.len > 0: ctx.store.labels.lookup(ix.label)
                     else: 0'i32)
    let keyCode = ctx.store.propKeys.lookup(ix.property)
    var byId = initTable[int64, float32]()
    for h in hits:
      byId[h[0]] = h[1]
    for id, rec in ctx.writer.nodeDelta:
      if not rec.live():
        continue
      if ix.label.len > 0 and rec.label != labelCode:
        continue
      var v = Value(kind: vkNull)
      if keyCode == 0 or not ctx.store.arena.getProp(rec.propView, keyCode, v):
        continue
      let f = asFloatVec(v)
      if f.len != qvec.len:
        continue
      if pushed.len > 0:
        var row = initRow(4)
        row.set(bindVar, Value(kind: vkNode, id: id))
        var ok = true
        for e in pushed:
          if not isTrue(evaluate(ctx, row, e)):
            ok = false
            break
        if not ok:
          continue
      byId[id] = ix.scoreVec(qvec, f)
    hits = @[]
    for id, sc in byId:
      discard id
      hits.add (id, sc)
    ## The committed list was ordered; the merge scrambled it, and a
    ## retrieval whose rows come back in table order is a wrong answer
    ## with the right rows.
    hits.sort(proc (a, b: (int64, float32)): int =
      if a[1] != b[1]:
        return (if a[1] > b[1]: -1 else: 1)
      cmp(a[0], b[0]))
  result.vecHits = hits

proc newTextSearch*(ctx: QueryCtx, indexName, queryText: string,
                    bindVar, scoreVar: string): Operator =
  ## CYPHER.md §4: a retrieval is a source. The hits are computed once at
  ## build — the query text is fixed and the index state is the statement's
  ## snapshot — and the operator's whole job is to hand them out one row at
  ## a time, with the scan's liveness discipline (pin I8: a deleted node is
  ## never returned, not even by an approximate structure).
  result = Operator(kind: okTextSearch, ctx: ctx, bindVar: bindVar,
                    scoreVar: scoreVar)
  if ctx.indices == nil:
    fail(int32(glyErrSql), "no index registry: the database opened without indexes")
  let ix = ctx.indices.text.getOrDefault(indexName)
  if ix == nil:
    ## A missing index is a caller mistake, not an unsupported construct:
    ## the name either exists (a typo is findable from `index_list`) or it
    ## was dropped, and both are answerable in the message.
    fail(int32(glyErrSql), "no text index named \"" & indexName & "\"")
  let a = Analyzer(kind: ix.analyzer)
  let queryTerms = a.analyze(queryText)
  var hits = ix.search(ctx.indices.terms, queryTerms, false, @[])
  ## Read-your-writes (pin C4): a statement inside the transaction that
  ## wrote sees its own writes. The committed postings do not hold this
  ## transaction's documents — they fold at commit, inside the write
  ## exclusion — so the transaction's own delta is analyzed here and merged
  ## over the committed hits. Scores for these rows use the committed N and
  ## avgdl; after the commit they are exact, and the difference is bounded
  ## by the transaction's own touched set, the same trade the range seek's
  ## delta half makes.
  if ctx.writer != nil and ctx.writer.nodeDelta.len > 0:
    var overlay = initTable[int64, seq[string]]()
    let labelCode = (if ix.label.len > 0: ctx.store.labels.lookup(ix.label)
                     else: 0'i32)
    let keyCode = ctx.store.propKeys.lookup(ix.property)
    for id, rec in ctx.writer.nodeDelta:
      if not rec.live():
        continue
      if ix.label.len > 0 and rec.label != labelCode:
        continue
      var v = Value(kind: vkNull)
      if keyCode == 0 or not ctx.store.arena.getProp(rec.propView, keyCode, v):
        continue
      if v.kind != vkString:
        continue
      overlay[id] = a.analyze(v.s)
    if overlay.len > 0:
      var byId = initTable[int64, Hit]()
      for h in hits:
        byId[h.nodeId] = h
      for id, doc in overlay:
        var score = 0.0
        var matched = false
        for qt in queryTerms:
          var f = 0
          for t in doc:
            if t == qt:
              inc f
          if f == 0:
            continue
          matched = true
          let code = ctx.indices.terms.getOrDefault(qt, 0'i32)
          if code == 0:
            continue
          let p = Posting(nodeId: id, freq: int32(f), fieldLen: int32(doc.len))
          score += ix.idf(code) * ix.scorePosting(p)
        if matched:
          byId[id] = Hit(nodeId: id, score: score)
      hits = @[]
      for id, h in byId:
        discard id
        hits.add h
      ## The committed list was ordered; the merge scrambled it, and a
      ## retrieval whose rows come back in table order is a wrong answer
      ## with the right rows.
      hits.sort(proc (x, y: Hit): int =
        if x.score != y.score:
          return (if x.score > y.score: -1 else: 1)
        (if x.nodeId < y.nodeId: -1 elif x.nodeId > y.nodeId: 1 else: 0))
  result.textHits = hits

proc newVarLen*(ctx: QueryCtx, child: Operator, startVar, relVar, endVar: string,
                dir: Direction, typeCode: int32, minHops, maxHops: int): Operator =
  ## `-[r*min..max]->`: every walk from the bound node, one row each.
  result = Operator(kind: okVarLen, ctx: ctx, child: child)
  result.startVar = startVar
  result.relVar2 = relVar
  result.endVar2 = endVar
  result.dir2 = dir
  result.typeCode2 = typeCode
  result.minHops = minHops
  result.maxHops2 = maxHops

proc newOptional*(ctx: QueryCtx, child: Operator, vars: seq[string],
                  buildSub: proc (row: Row): Operator {.closure.}): Operator =
  ## `buildSub` is called once per input row rather than once per statement,
  ## and that is the design: a plan is a stateful cursor, so a correlated
  ## right side has to be a *fresh* cursor per row. The alternative —
  ## reusing one plan and hoping every operator in it resets when the row
  ## under it changes — holds for Expand and does not hold for a scan, and
  ## the bug that difference produces is a silently truncated right side.
  result = Operator(kind: okOptional, ctx: ctx, child: child, vars2: vars,
                    buildSub: buildSub)

proc newInputRow*(ctx: QueryCtx): Operator =
  result = Operator(kind: okInputRow, ctx: ctx)

proc feedRow*(op: Operator, row: Row) =
  ## Hand the one row this source will produce on its next pull.
  op.fedRow = row
  op.fedArmed = true

proc relTypeMatches(ctx: QueryCtx, edgeId: int64, typeCode: int32): bool =
  ## 0 means "any type" and -1 means "a type nothing has" — the same
  ## distinction the label filter makes. Without it, `MATCH (a)-[r:Nope]->(b)`
  ## matches every relationship in the store, because an unknown type looks
  ## up as 0.
  if typeCode == 0:
    return true
  if typeCode < 0:
    return false
  let (_, _, et) = ctx.edgeEnds(edgeId)
  et == typeCode

proc enumeratePaths(ctx: QueryCtx, start: int64, dir: Direction, typeCode: int32,
                    minHops, maxHops: int): seq[VarPath] =
  ## Every relationship-simple walk from `start`, iteratively.
  ##
  ## Iterative rather than recursive because the *unbounded* `*` is bounded
  ## only by relationship uniqueness, not by any number in the query: a chain
  ## of a million edges walks a million frames deep, and a recursive walk
  ## would take the stack with it. The stack frame holds the candidates and
  ## the index into them, so backtracking is a pop.
  ##
  ## Relationship uniqueness (CYPHER.md §2.1) is a *relationship* rule, not a
  ## node rule: a path may revisit a node through a different edge, and may
  ## go back along the way it came only by way of a second relationship. That
  ## is why the `used` set holds edges and not nodes — a node set would
  ## quietly forbid the cycles the language allows.
  type Frame = object
    node: int64
    cands: seq[int64]
    at: int
    via: int64

  var used = initHashSet[int64]()
  var frames: seq[Frame] = @[]
  var path: seq[int64] = @[]

  proc candidates(n: int64): seq[int64] =
    var list: seq[int64] = @[]
    case dir
    of dirOut:
      list = ctx.outEdges(n)
    of dirIn:
      list = ctx.inEdges(n)
    of dirBoth:
      list = ctx.outEdges(n)
      for e in ctx.inEdges(n):
        list.add e
    result = list

  frames.add Frame(node: start, cands: candidates(start), at: 0, via: 0)
  while frames.len > 0:
    let top = frames.len - 1
    if frames[top].at >= frames[top].cands.len:
      ## Read `via` *before* the pop: after `setLen` the index that named this
      ## frame is one past the end, and reading it is an IndexDefect that
      ## looks like a corrupt graph rather than a bookkeeping slip.
      let via = frames[top].via
      frames.setLen(top)
      if path.len > 0:
        path.setLen(path.len - 1)
        if via != 0:
          ## Edge ids start at 1, so 0 is "this frame came from the start
          ## node" — the seed frame owns no edge and must not un-claim one.
          used.excl(via)
      continue
    let eid = frames[top].cands[frames[top].at]
    inc frames[top].at
    if eid in used:
      ## The same relationship twice in one path is not a path. Skipping it
      ## here is what makes `*` terminate on a cyclic graph at all.
      continue
    if typeCode != 0 and not relTypeMatches(ctx, eid, typeCode):
      continue
    let (src, dst, _) = ctx.edgeEnds(eid)
    let boundId = frames[top].node
    let other = (if src == boundId: dst else: src)
    if not ctx.nodeAlive(other):
      continue
    used.incl eid
    path.add eid
    if path.len >= minHops:
      ## Copied, not aliased: `path` is the walk's own buffer and the next
      ## branch overwrites it. A VarPath holding the descriptor would keep
      ## the length it was emitted at but read whatever edges the branch
      ## after it wrote underneath — a walk of two reporting the *next*
      ## walk's second edge.
      result.add VarPath(edges: @path, at: other)
    if maxHops == 0 or path.len < maxHops:
      frames.add Frame(node: other, cands: candidates(other), at: 0, via: eid)
    else:
      ## At the limit. The walk is finished with *this* edge, not with this
      ## whole frame: give the edge back, back up one step, and let the same
      ## frame try its next candidate.
      ##
      ## It used to pop the frame instead, which abandoned every remaining
      ## candidate of the node it was standing on — so `*1..2` from a node
      ## with two out-edges reported the children of only the first. It also
      ## released `frames[top].via` rather than the edge just taken, so the
      ## edge stayed in `used` for the rest of the walk and no later path
      ## could cross it. Four nodes, edges 0->1, 0->2, 1->2, 1->3:
      ## `*1..2` from 0 answered [1, 2, 2] instead of [1, 2, 2, 3], and 3
      ## only appeared at `*1..3` — a path reported one hop deeper than it
      ## is, which is the wrong end variable on the wrong length.
      path.setLen(path.len - 1)
      used.excl(eid)

proc newProject*(ctx: QueryCtx, child: Operator, items: seq[ReturnItem],
                 columns: seq[string]): Operator =
  Operator(kind: okProject, ctx: ctx, child: child, items: items,
           columns: columns)

proc buildGroups(op: Operator) =
  ## Buffer the child, key every row, and fold each group into an output row.
  var index = initTable[string, int]()
  while op.child.next():
    let src = op.child.current
    var keyRow = initRow(op.keyNames.len)
    for i, e in op.keyItems:
      keyRow.set(op.keyNames[i], evaluate(op.ctx, src, e))
    let key = rowKey(op.ctx, keyRow, op.keyNames)
    if key in index:
      op.groups[index[key]].rows.add src
      continue
    var group = Group(key: key, rows: @[src])
    for i in 0 ..< op.keyNames.len:
      group.keyValues.add keyRow.lookup(op.keyNames[i])[1]
    index[key] = op.groups.len
    op.groups.add group

  if op.groups.len == 0 and op.keyItems.len == 0:
    ## No key and no rows: the query still has one answer.
    ##
    ## `MATCH (n:Nothing) RETURN count(*)` is 0, not "no rows". A global
    ## aggregation over an empty input is a statement *about* the input, and
    ## a missing row would say nothing could be said about it. With a key
    ## present there is nothing to group, so zero rows is the right answer
    ## — which is why this is conditional on the key being empty.
    op.groups.add Group(key: "", rows: @[])

  for group in op.groups:
    var row = initRow(op.columns.len + 32)
    var keyIdx = 0
    for i, item in op.items:
      if isAggregateExpr(item.expr):
        var calls: seq[Expr] = @[]
        collectAggregates(item.expr, calls)
        var values: seq[Value] = @[]
        for call in calls:
          values.add aggregateValue(op.ctx, call, group.rows)
        var k = 0
        row.set(op.columns[i], evaluate(op.ctx, row, substAggregates(item.expr, values, k)))
      else:
        ## The key was already evaluated for this row while hashing it;
        ## re-evaluating would be a second pass over the expression for a
        ## value already in hand, and for an expression with a side effect
        ## on the context it would be a second *call*.
        row.set(op.columns[i], group.keyValues[keyIdx])
        inc keyIdx
    op.outRows.add row
  ## Set *before* emitting, and never cleared: without it every `next` call
  ## would rebuild the groups, reset the cursor, and emit the first group
  ## forever — a hang that looks like a slow query and not like a mistake.
  op.built = true

proc newAggregate*(ctx: QueryCtx, child: Operator, items: seq[ReturnItem],
                   columns: seq[string]): Operator =
  ## A projection that contains an aggregate is not a projection at all: it is
  ## a *grouping*. Cypher's rule is that the non-aggregated items form the
  ## group key and each distinct key gets one output row — so
  ## `RETURN c.city, count(*)` is one row per city, while `RETURN count(*)`
  ## has no key, hence one group, hence one row.
  ##
  ## Streaming would need the whole input to know the first group's key.
  ## Buffering costs one pass and a row per input, which is the same trade
  ## okSort already makes; the difference is that grouping also has to keep
  ## every row of a group alive until the group closes, since the aggregates
  ## are folded at that point.
  result = Operator(kind: okAggregate, ctx: ctx, child: child, items: items,
                    columns: columns)
  for i in 0 ..< items.len:
    if not isAggregateExpr(items[i].expr):
      result.keyItems.add items[i].expr
      result.keyNames.add "__g" & $i

proc seekFor(ctx: QueryCtx, np: NodePattern): Operator =
  ## The head of a match chain, preferring a seek over a scan.
  ##
  ## The rule is the planner's own: the first inline property of the head
  ## node that (a) names a property an index exists on, and (b) carries a
  ## value the index can hold, is the seek key. Everything else is a scan,
  ## and the property filters still go on top either way, so a seek stays a
  ## candidate generator and cannot change an answer.
  ##
  ## `MERGE`'s match half runs through here, which is the whole point: it
  ## used to call `scanFor` directly because the seek lived in a module it
  ## could not import. Binding a node for `MERGE (b:Person {id: $id})` is
  ## the same question as `MATCH (b:Person {id: $id})`, and it was being
  ## answered two different ways — one of them 40x slower.
  if ctx.indices == nil or np.varName.len == 0:
    return scanFor(ctx, np)
  for (prop, expr) in np.props:
    ## An unbound parameter resolves to null, which is not keyable, so it
    ## falls through to the scan. That direction matters: seeking on null
    ## would answer nothing, and nothing is fewer rows than the scan finds.
    if expr.kind != ekLit and expr.kind != ekParam:
      continue
    let key = SeekKey(varName: np.varName, prop: prop, op: "=",
                      value: evalLiteral(ctx, expr))
    if not seekKeyable(key):
      continue
    let ix = ctx.indices.find(if np.label.len > 0: np.label else: "", prop)
    if ix == nil or not ix.usable:
      continue
    let code = (if np.label.len > 0: ctx.store.labels.lookup(np.label)
                else: 0'i32)
    return newIndexSeek(ctx, np.varName, seekIds(ctx, ix, key), code, ix.name,
                        key)
  scanFor(ctx, np)

proc mergeChain*(ctx: QueryCtx, pat: Pattern,
                 bound: seq[(string, Value)]): Operator =
  ## The match half of a MERGE, built fresh for one row.
  ##
  ## Cypher's rule is all-or-nothing over the whole pattern: if any part of
  ## it does not match, the whole thing is created. So the match is the
  ## pattern read as a MATCH — same grammar, where labels and property maps
  ## become filters — plus one `id(v) = …` constraint per variable the
  ## outer row already bound. Without that constraint, `MATCH (a) MERGE
  ## (a)-[:R]->(b)` would match *any* relationship in the graph and bind
  ## `b` to the wrong node: a merge that finds "a relationship" rather than
  ## "a relationship from this a" is not a merge.
  ##
  ## Built with the same constructors the planner uses (`scanFor` is its
  ## rule-1/rule-5 decision) rather than by calling `plan`, because
  ## `plan.nim` imports this module and the call the other way is a cycle.
  ## A plan is a stateful cursor, so this runs once per row: MERGE costs a
  ## plan per row, which is the price of not caching plans across the
  ## statement (EXEC.md §1, init-once).
  var chain = seekFor(ctx, pat.elems[0].node)
  for i in 1 ..< pat.elems.len:
    if pat.elems[i].isNode:
      continue
    let prev = pat.elems[i - 1]
    let far = pat.elems[i + 1]
    let r = pat.elems[i].rel
    var code = 0'i32
    if r.types.len == 1:
      code = ctx.store.relTypes.lookup(r.types[0])
      if code == 0: code = -1'i32
    var boundVar = prev.node.varName
    var endVar = far.node.varName
    if r.dir == dirBoth and boundVar.len == 0 and endVar.len > 0:
      swap(boundVar, endVar)
    let step = newExpand(ctx, boundVar, r.varName, endVar, r.dir, code)
    step.child = chain
    chain = step
  ## The pattern's own inline properties are filters here, exactly as in a
  ## MATCH — that is what "the pattern matches" mean.
  for el in pat.elems:
    if not el.isNode: continue
    for (key, expr) in el.node.props:
      chain = newFilter(ctx, chain,
                        binary(ekCompare, "=", propExpr(varExpr(el.node.varName), key),
                               expr))
  if bound.len > 0:
    var conds: seq[Expr] = @[]
    for (name, v) in bound:
      if v.kind == vkNode or v.kind == vkEdge:
        conds.add binary(ekCompare, "=",
                         funcCall("id", @[varExpr(name)]),
                         lit Value(kind: vkInt, i: v.id))
    var acc = conds[0]
    for c in conds[1 .. ^1]:
      acc = binary(ekAnd, "AND", acc, c)
    chain = newFilter(ctx, chain, acc)
  chain

proc writeOperator(ctx: QueryCtx, child: Operator, kind: OpKind;
                   clause: string): Operator =
  ## Every write clause's constructor funnels through here for one reason:
  ## a write planned with no transaction is a write nobody would ever see,
  ## so it is refused by name at plan time rather than planned as a filter
  ## that quietly discards itself. The read door (`db.prepare`) hits this
  ## on every write clause, which is the point.
  ##
  ## The refusal names the *clause*, not the operator kind: "CREATE without a
  ## write transaction" is something a caller can act on, "okCreate" is our
  ## internal spelling leaking through the boundary.
  if ctx.writer == nil:
    unsupported(clause & " without a write transaction")
  Operator(kind: kind, ctx: ctx, child: child)

proc newCreate*(ctx: QueryCtx, child: Operator,
                patterns: seq[Pattern]): Operator =
  ## One `CREATE` clause. Like every other write operator it acts on the
  ## rows flowing through it rather than as a separate pass, which is what
  ## makes `MATCH … WHERE … CREATE …` create once per surviving row and
  ## not once per node in the store.
  result = writeOperator(ctx, child, okCreate, "CREATE")
  result.createPatterns = patterns

proc newSet*(ctx: QueryCtx, child: Operator, items: seq[SetItem]): Operator =
  result = writeOperator(ctx, child, okSet, "SET")
  result.setItems = items

proc newRemove*(ctx: QueryCtx, child: Operator, items: seq[PropRef]): Operator =
  result = writeOperator(ctx, child, okRemove, "REMOVE")
  result.removeItems = items

proc newDelete*(ctx: QueryCtx, child: Operator, vars: seq[string];
                detach: bool): Operator =
  result = writeOperator(ctx, child, okDelete, "DELETE")
  result.deleteVars = vars
  result.detach = detach

proc newMerge*(ctx: QueryCtx, child: Operator, part: QueryPart): Operator =
  result = writeOperator(ctx, child, okMerge, "MERGE")
  result.mergePatterns = part.mergePatterns
  result.onCreateSet = part.onCreateSet
  result.onCreateRemove = part.onCreateRemove
  result.onMatchSet = part.onMatchSet
  result.onMatchRemove = part.onMatchRemove

proc newSkip*(ctx: QueryCtx, child: Operator, n: int64): Operator =
  Operator(kind: okSkip, ctx: ctx, child: child, skipped: n)

proc newLimit*(ctx: QueryCtx, child: Operator, n: int64): Operator =
  Operator(kind: okLimit, ctx: ctx, child: child, limit: n)

proc newUnwind*(ctx: QueryCtx, child: Operator, list: Expr,
                varName: string): Operator =
  Operator(kind: okUnwind, ctx: ctx, child: child, list: @[],
           endVar: varName, cond: list)

proc newSort*(ctx: QueryCtx, child: Operator, spec: SortSpec,
              spillRows = 0, spillDir = ""): Operator =
  ## `spillRows` of 0 means "buffer everything", which is what a database
  ## with a memory budget chooses and what a test wants: the spill path
  ## has to be *reachable* to be tested, and it is only reachable by
  ## asking for it.
  result = Operator(kind: okSort, ctx: ctx, child: child, sortSpec: spec)
  result.buffered = @[]
  result.spillRows = spillRows
  result.spillDir = spillDir
  result.cursor = 0
  result.runs = @[]

proc newDistinct*(ctx: QueryCtx, child: Operator, columns: seq[string]): Operator =
  ## `columns` is the *output* schema, because Distinct hashes the projected
  ## row: it sits above the projection, and without the names every row
  ## hashes to the same key and only the first survives.
  Operator(kind: okDistinct, ctx: ctx, child: child,
           columns: columns, seen: initHashSet[string]())

# ------------------------------------------------------- the M5 write path

proc nodeIdOf(ctx: QueryCtx, row: var Row, np: NodePattern): int64 =
  ## The id a node pattern resolves to: the one already bound, or a new one.
  ## Cypher's rule — `MATCH (a) CREATE (a)-[:KNOWS]->(b)` connects the
  ## existing `a` and makes `b` — is the whole reason CREATE takes a row
  ## rather than running as its own pass.
  if np.varName.len > 0:
    let (found, v) = row.lookup(np.varName)
    if found and v.kind == vkNode:
      return v.id
  let tx = ctx.writer
  let id = tx.createNode(np.label)
  if np.varName.len > 0:
    row.set(np.varName, Value(kind: vkNode, id: id))
  ## Properties in a CREATE pattern are values to store (CYPHER.md §3.1),
  ## where in a MATCH pattern they are filters — same grammar, opposite
  ## meaning, and the difference is the milestone.
  for (key, expr) in np.props:
    let v = evaluateAt(ctx, row, expr)
    if not tx.setNodeProp(id, key, v):
      fail(int32(glyErrConstraint), "property " & key & " on node " & $id)
  ## Counted where it happens rather than by re-reading the row afterwards:
  ## an anonymous `CREATE (:X)` binds nothing, so a count that looked the
  ## variable up would miss every node whose pattern had no name — which is
  ## most of them.
  inc ctx.rowsAffected
  id

proc relTypeOf(ctx: QueryCtx, types: seq[string]): string =
  ## A CREATE relationship needs one type; `[:A|B]` is refused rather than
  ## guessed at, for the same reason the read side refuses it.
  if types.len > 1:
    unsupported("relationship type alternation ([:A|B])")
  if types.len == 1: types[0]
  else: ""

proc createRel(ctx: QueryCtx, row: var Row, src: int64, r: RelPattern,
               dst: int64) =
  let tx = ctx.writer
  let kind = relTypeOf(ctx, r.types)
  let e = tx.createEdge(src, dst, kind)
  if e == 0:
    fail(int32(glyErrConstraint), "could not create the relationship")
  if r.varName.len > 0:
    row.set(r.varName, Value(kind: vkEdge, id: e))
  for (key, expr) in r.props:
    let v = evaluateAt(ctx, row, expr)
    if not tx.setEdgeProp(e, key, v):
      fail(int32(glyErrConstraint), "property " & key & " on relationship " & $e)
  inc ctx.rowsAffected

proc targetOf(ctx: QueryCtx, row: Row, target: PropRef): (bool, bool) =
  ## `(found, isNode)` for a write target: the variable must be bound, and
  ## it must be a node or an edge — a number has no properties, and
  ## `SET 3.x = 1` is a type error rather than a no-op. The key is ignored
  ## here; the caller supplies it.
  let (found, v) = row.lookup(target.varName)
  if not found:
    fail(int32(glyErrSql), "SET/REMOVE target " & target.varName & " is not bound")
  if v.kind == vkNode:
    return (true, true)
  if v.kind == vkEdge:
    return (true, false)
  fail(int32(glyErrSql),
       target.varName & " is a " & $v.kind & ", not a node or a relationship")

proc targetId(row: Row, target: PropRef): int64 =
  let (_, v) = row.lookup(target.varName)
  v.id

proc checkStorable(v: Value, target: string) =
  ## A node, an edge or a path has no property encoding. The arena codec
  ## refuses it deep inside the write, and that refusal reached the host as
  ## `GLY_ERR` — which Ruby maps to `InternalError`, i.e. "this is our
  ## bug". It is not: `SET n.copy = otherNode` is a type error in the
  ## caller's query, and it gets a named status here.
  if not storable(v.kind):
    fail(int32(glyErrSql),
         "cannot store " & $v.kind & " as a property of " & target)

proc setPropOn(ctx: QueryCtx, row: Row, target: PropRef, v: Value) =
  checkStorable(v, target.varName & "." & target.key)
  let (_, isNode) = targetOf(ctx, row, target)
  let id = targetId(row, target)
  let ok = if isNode: ctx.writer.setNodeProp(id, target.key, v)
           else: ctx.writer.setEdgeProp(id, target.key, v)
  if not ok:
    fail(int32(glyErrConstraint), "could not set " & target.key)

proc applySetItem(ctx: QueryCtx, row: Row, item: SetItem) =
  ## One assignment, in its three spellings.
  if not item.isMap:
    setPropOn(ctx, row, item.target, evaluateAt(ctx, row, item.expr))
    return

  ## The map forms. `SET a = {…}` replaces every property, `SET a += {…}`
  ## merges. Both apply to a *node* only: a map is a node's property set,
  ## and `SET r = {…}` on a relationship is a type error rather than a
  ## silent merge into nothing.
  let (found, v) = row.lookup(item.target.varName)
  if not found:
    fail(int32(glyErrSql), "SET target " & item.target.varName & " is not bound")
  if v.kind != vkNode:
    fail(int32(glyErrSql),
         "SET " & item.target.varName & " = {…} needs a node, not a relationship; " &
         "set relationship properties with `SET " & item.target.varName & ".key = …`")
  let map = evaluateAt(ctx, row, item.mapValue)
  if map.kind != vkMap:
    fail(int32(glyErrSql), "SET " & item.target.varName & " = … needs a map")
  if not item.merge and not ctx.writer.clearNodeProps(v.id):
    fail(int32(glyErrConstraint), "could not clear the properties of " & $v.id)
  for (key, value) in map.pairs:
    checkStorable(value, item.target.varName & "." & key)
    let ok = ctx.writer.setNodeProp(v.id, key, value)
    if not ok:
      fail(int32(glyErrConstraint), "could not set " & key)

proc mergeActions(ctx: QueryCtx, row: Row, sets: seq[SetItem],
                  removes: seq[PropRef]) =
  ## Counted per action, like `SET`: one assignment is one write. The
  ## counting lives here rather than in the caller because the caller is
  ## MERGE's own branch logic and would have to remember.
  for item in sets:
    applySetItem(ctx, row, item)
    inc ctx.rowsAffected
  for target in removes:
    let (_, isNode) = targetOf(ctx, row, target)
    let id = targetId(row, target)
    let ok = if isNode: ctx.writer.removeNodeProp(id, target.key)
             else: ctx.writer.removeEdgeProp(id, target.key)
    if not ok:
      fail(int32(glyErrConstraint), "could not remove " & target.key)
    inc ctx.rowsAffected

proc createPattern(ctx: QueryCtx, row: var Row, pat: Pattern) =
  ## One chain. Nodes are resolved left to right so a relationship always
  ## has both endpoints: `CREATE (a)-[:R]->(b)` cannot make `b` before it
  ## knows `a`'s id, and making the nodes first is what lets the relationship
  ## carry properties that reference either endpoint.
  var ids = newSeq[int64](pat.elems.len)
  var isNode = newSeq[bool](pat.elems.len)
  for i, el in pat.elems:
    if el.isNode:
      ids[i] = nodeIdOf(ctx, row, el.node)
      isNode[i] = true
    else:
      ids[i] = 0
      isNode[i] = false
  for i, el in pat.elems:
    if el.isNode:
      continue
    if i == 0 or i + 1 >= pat.elems.len:
      ## A pattern cannot start or end with a relationship. The parser
      ## already requires a node at each end, so this is unreachable and
      ## refused rather than assumed.
      fail(int32(glyErrSql), "a pattern must start and end with a node")
    createRel(ctx, row, ids[i - 1], el.rel, ids[i + 1])

# ----------------------------------------------------------------- helpers

proc evalRow(op: Operator, expr: Expr): Value =
  ## Evaluate against the child's *current* row. Every expression in a
  ## filter, project or sort reads the same row the child produced, which is
  ## why `child.current` and not `current` is the source.
  evaluate(op.ctx, op.child.current, expr)

proc nodeOf(row: Row, name: string): (bool, Value) =
  if name.len == 0:
    return (false, Value(kind: vkNull))
  row.lookup(name)

# ------------------------------------------------------------------- next

proc next*(op: Operator): bool =
  ## Pull one row. Returns false at end of stream and, once false, stays
  ## false: a caller that asks again gets `false`, not undefined behaviour
  ## from a cursor that has run off the end.
  if op.exhausted:
    return false
  case op.kind
  of okOneRow:
    ## One empty row, once. `started` is the cursor: there is no state to
    ## corrupt and no array to walk, which is the entire implementation.
    if op.started:
      op.exhausted = true
      return false
    op.started = true
    op.current = initRow(4)
    return true

  of okScanAll:
    ## The array is read through the snapshot each time rather than bound to
    ## a local: a `let` of the lent sequence copies it, which is a memmove
    ## of the whole node array on every row pulled (store.nim, `lent`).
    while op.cursor < op.ctx.snap.nodes.len:
      let id = op.cursor
      inc op.cursor
      if op.ctx.snap.nodes[id.int].live and
         (op.labelCode == 0 or (op.labelCode > 0 and
                                op.ctx.snap.nodes[id.int].label == op.labelCode)):
        op.current = initRow(4)
        if op.bindVar.len > 0:
          op.current.set(op.bindVar, Value(kind: vkNode, id: id))
        return true
    ## Then the transaction's own new nodes, which have no place in the
    ## published array at all.
    while op.deltaAt < op.deltaIds.len:
      let id = op.deltaIds[op.deltaAt]
      inc op.deltaAt
      let rec = op.ctx.writer.peekNode(id)
      if rec.live and (op.labelCode == 0 or rec.label == op.labelCode):
        op.current = initRow(4)
        if op.bindVar.len > 0:
          op.current.set(op.bindVar, Value(kind: vkNode, id: id))
        return true
    op.exhausted = true
    return false

  of okScanByLabel:
    while op.idsAt < op.ids.len:
      let id = op.ids[op.idsAt]
      inc op.idsAt
      ## The list is a snapshot, but a node tombstoned before the snapshot
      ## was taken is still in it; STORAGE.md §4.3 compacts the list at
      ## checkpoint, not at delete.
      if op.ctx.nodeAlive(id):
        op.current = initRow(4)
        if op.bindVar.len > 0:
          op.current.set(op.bindVar, Value(kind: vkNode, id: id))
        return true
    ## And then the nodes this transaction created, matched on their label
    ## here rather than pre-filtered, because the scan is built before the
    ## statement's own writes and the delta is only consulted once.
    while op.deltaAt < op.deltaIds.len:
      let id = op.deltaIds[op.deltaAt]
      inc op.deltaAt
      let rec = op.ctx.writer.peekNode(id)
      if rec.live and rec.label == op.labelCode:
        op.current = initRow(4)
        if op.bindVar.len > 0:
          op.current.set(op.bindVar, Value(kind: vkNode, id: id))
        return true
    op.exhausted = true
    return false

  of okIndexSeek:
    while op.seekAt < op.seekIds.len:
      let id = op.seekIds[op.seekAt]
      inc op.seekAt
      if op.ctx.nodeAlive(id):
        op.current = initRow(4)
        if op.bindVar.len > 0:
          op.current.set(op.bindVar, Value(kind: vkNode, id: id))
        return true
    ## Then the transaction's own new nodes, as the label scan does. An
    ## index that had seen them would double them; an index that has not
    ## seen them at all would hide them from a read in the same transaction
    ## — which is pin C4's half, and it would make `CREATE` followed by
    ## `MATCH … WHERE indexed = …` find nothing.
    while op.seekDeltaAt < op.seekDeltaIds.len:
      let id = op.seekDeltaIds[op.seekDeltaAt]
      inc op.seekDeltaAt
      let rec = op.ctx.writer.peekNode(id)
      if rec.live and rec.label == op.seekLabel:
        op.current = initRow(4)
        if op.bindVar.len > 0:
          op.current.set(op.bindVar, Value(kind: vkNode, id: id))
        return true
    op.exhausted = true
    return false

  of okTextSearch:
    ## One hit per row: the document bound as a node, the score as a float.
    ## Liveness is checked per row for the same reason the seek checks it —
    ## a node tombstoned before the snapshot is still in the postings
    ## (I8/I11), and the deletion is exactly when a caller is least able to
    ## notice that the row should not be there.
    while op.textAt < op.textHits.len:
      let h = op.textHits[op.textAt]
      inc op.textAt
      if not op.ctx.nodeAlive(h.nodeId):
        continue
      op.current = initRow(4)
      if op.bindVar.len > 0:
        op.current.set(op.bindVar, Value(kind: vkNode, id: h.nodeId))
      if op.scoreVar.len > 0:
        op.current.set(op.scoreVar, Value(kind: vkFloat, f: h.score))
      return true
    op.exhausted = true
    return false

  of okVectorSearch:
    ## One hit per row: the document bound as a node, the score as a
    ## float, best first. Liveness per row for the same reason the seek
    ## and the text search check it (I8): the tombstone is exactly when a
    ## caller is least able to notice the row should not be there.
    while op.vecAt < op.vecHits.len:
      let h = op.vecHits[op.vecAt]
      inc op.vecAt
      if not op.ctx.nodeAlive(h[0]):
        continue
      op.current = initRow(4)
      if op.bindVar.len > 0:
        op.current.set(op.bindVar, Value(kind: vkNode, id: h[0]))
      if op.scoreVar.len > 0:
        op.current.set(op.scoreVar, Value(kind: vkFloat, f: h[1]))
      return true
    op.exhausted = true
    return false

  of okExpand:
    ## One relationship per row, and *all* of a bound node's relationships
    ## before moving to the next bound node.
    ##
    ## The state (`edgeList`, `edgeAt`) is what makes a node with three
    ## outgoing edges produce three rows. The first version pulled a fresh
    ## child row on every call and so returned at most one row per bound
    ## node — which quietly dropped every edge after the first, and looked
    ## like a wrong filter rather than a wrong cursor.
    ##
    ## The child's bindings are copied forward and the new ones added, so a
    ## three-hop chain accumulates `a`, `b`, `c` as it goes.
    while true:
      if op.edgeAt >= op.edgeList.len:
        if not op.child.next():
          op.exhausted = true
          return false
        op.current = copyRow(op.child.current)
        let (found, bound) = nodeOf(op.current, op.boundVar)
        if not found or bound.kind != vkNode:
          ## Nothing to expand from — an unbound bound-variable, which is
          ## what a pattern after OPTIONAL MATCH's null side looks like.
          ## The row survives unchanged.
          op.edgeList = @[]
          op.edgeAt = 0
          return true
        case op.dir
        of dirIn:
          op.edgeList = op.ctx.inEdges(bound.id)
        of dirOut:
          op.edgeList = op.ctx.outEdges(bound.id)
        of dirBoth:
          ## Out-then-in: an undirected pattern reports each edge once per
          ## direction, which is what makes `MATCH (a)-[r]-(b)` over three
          ## edges produce six rows.
          op.edgeList = op.ctx.outEdges(bound.id)
          for e in op.ctx.inEdges(bound.id):
            op.edgeList.add e
        op.edgeAt = 0
        ## An undirected pattern with no edge at this node still produces the
        ## row, with the relationship variables unbound — that is what
        ## `-[r]-` means for an isolated node. A *directed* pattern with no
        ## edge produces nothing, and falls through to the next bound node.
        if op.dir == dirBoth and op.edgeList.len == 0:
          return true
      while op.edgeAt < op.edgeList.len:
        let eid = op.edgeList[op.edgeAt]
        inc op.edgeAt
        if not relTypeMatches(op.ctx, eid, op.typeCode):
          continue
        let (src, dst, _) = op.ctx.edgeEnds(eid)
        let boundId = op.current.lookup(op.boundVar)[1].id
        let other = (if src == boundId: dst else: src)
        if not op.ctx.nodeAlive(other):
          continue
        if op.endVar.len > 0:
          op.current.set(op.endVar, Value(kind: vkNode, id: other))
        if op.relVar.len > 0:
          op.current.set(op.relVar, Value(kind: vkEdge, id: eid))
        return true
      ## This bound node's edges are exhausted: loop for the next one.

  of okFilter:
    while op.child.next():
      if isTrue(op.evalRow(op.cond)):
        op.current = op.child.current
        return true
    op.exhausted = true
    return false

  of okProject:
    if not op.child.next():
      op.exhausted = true
      return false
    let src = op.child.current
    op.current = initRow(op.items.len + src.slots.len)
    for i in 0 ..< op.items.len:
      let item = op.items[i]
      op.current.set(op.columns[i], evaluate(op.ctx, src, item.expr))
    ## The source bindings ride along behind the projected columns. ORDER BY
    ## sits above the projection (EXEC.md §4: it has to, `ORDER BY n`
    ## names an alias that only exists there) but may also reference
    ## source variables Cypher's grammar allows — `RETURN n.name AS name
    ## ORDER BY n.age` — and a projection that dropped them would turn
    ## every such key into null and the sort into a no-op. Appending puts
    ## them *after* the columns, so `Row.lookup`'s first match resolves an
    ## alias that shadows a source variable the way Cypher says it must.
    for (name, v) in src.slots:
      if op.current.lookup(name)[0]:
        continue
      op.current.set(name, v)
    return true

  of okAggregate:
    if not op.built:
      buildGroups(op)
    if op.outIdx >= op.outRows.len:
      op.exhausted = true
      return false
    op.current = op.outRows[op.outIdx]
    inc op.outIdx
    return true

  of okVarLen:
    ## All the walks of this input row, then one row per walk. The child's
    ## bindings ride along, so a three-hop chain keeps `a` as well as `b`.
    while true:
      if op.pathAt < op.paths.len:
        let paths = op.pathRows[op.pathAt]
        let path = op.paths[op.pathAt]
        inc op.pathAt
        op.current = copyRow(paths)
        if op.relVar2.len > 0:
          var items: seq[Value] = @[]
          for e in path.edges:
            items.add Value(kind: vkEdge, id: e)
          op.current.set(op.relVar2, Value(kind: vkList, items: items))
        if op.endVar2.len > 0:
          op.current.set(op.endVar2, Value(kind: vkNode, id: path.at))
        return true
      if not op.child.next():
        op.exhausted = true
        return false
      let (found, bound) = nodeOf(op.child.current, op.startVar)
      op.paths = @[]
      op.pathRows = @[]
      op.pathAt = 0
      if not found or bound.kind != vkNode:
        ## An unbound start variable — what the null side of an OPTIONAL
        ## MATCH looks like to the pattern below it. The row survives with
        ## nothing bound, exactly as a one-hop expand would leave it.
        op.pathRows.add copyRow(op.child.current)
        continue
      op.paths = enumeratePaths(op.ctx, bound.id, op.dir2, op.typeCode2,
                                op.minHops, op.maxHops2)
      for i in 0 ..< op.paths.len:
        op.pathRows.add copyRow(op.child.current)

  of okInputRow:
    ## One row, then done. Armed by `feedRow` immediately before the pull,
    ## so a stale arm cannot leak into the next statement: the arm is
    ## consumed here and the flag cleared.
    if not op.fedArmed:
      op.exhausted = true
      return false
    op.fedArmed = false
    op.current = copyRow(op.fedRow)
    return true

  of okOptional:
    ## Left-outer. Every input row produces output: the pattern's rows when
    ## it matched anything, and the input row with the pattern's variables
    ## filled with null when it matched nothing.
    while true:
      if op.optAt < op.optRows.len:
        op.current = op.optRows[op.optAt]
        inc op.optAt
        return true
      if not op.child.next():
        op.exhausted = true
        return false
      let input = copyRow(op.child.current)
      var rows: seq[Row] = @[]
      let sub = op.buildSub(input)
      while sub.next():
        rows.add copyRow(sub.current)
      if rows.len == 0:
        ## The null-extended row is built by *filling in*, not by dropping
        ## bindings: the left side's own variables must survive, or
        ## `OPTIONAL MATCH` would delete the row it promised to keep.
        var row = input
        for name in op.vars2:
          if row.lookup(name)[0]:
            ## A variable the left side already bound is *not* null-filled.
            ## `OPTIONAL MATCH (a)-[:R]->(b)` names `a` in the pattern, and
            ## nulling it would erase the row the left side promised to keep
            ## — the query would answer `null` for the very node it matched.
            continue
          row.set(name, Value(kind: vkNull))
        rows.add row
      op.optRows = rows
      op.optAt = 0

  of okSkip:
    while op.skipped > 0:
      if not op.child.next():
        op.exhausted = true
        return false
      dec op.skipped
    if not op.child.next():
      op.exhausted = true
      return false
    op.current = op.child.current
    return true

  of okLimit:
    if op.taken >= op.limit:
      op.exhausted = true
      return false
    if not op.child.next():
      op.exhausted = true
      return false
    inc op.taken
    op.current = op.child.current
    return true

  of okUnwind:
    ## Lazy over the list: one element per pull, so `UNWIND` over a 10⁷
    ## element list with `LIMIT 10` consumes ten elements (CYPHER.md §2.5).
    ##
    ## The child is pulled only when the current list is drained — once per
    ## list, not once per element. The first version pulled it on every
    ## call, so a one-row child (a constant query's source) was exhausted
    ## after the first element and `UNWIND [1,2,3] … LIMIT 2` returned one
    ## row. Pulling per list is also what makes `UNWIND` after a `MATCH`
    ## unwind once per match rather than once per query.
    while true:
      if not op.started or op.taken >= int64(op.list.len):
        if not op.child.next():
          op.exhausted = true
          return false
        let evaluated = evaluate(op.ctx, op.child.current, op.cond)
        op.list = (if evaluated.kind == vkList: evaluated.items else: @[])
        op.taken = 0
        op.started = true
      if op.taken < int64(op.list.len):
        op.current = initRow(4)
        op.current.set(op.endVar, op.list[op.taken.int])
        inc op.taken
        return true
      ## An empty list produces no row but the child may have more; loop.

  of okSort:
    ## The one operator allowed to buffer (EXEC.md §0). Drained on the first
    ## pull: everything is materialised, ordered, then handed out one row at
    ## a time. `ORDER BY` is a barrier by definition, so the buffering is
    ## the semantics rather than an implementation accident.
    ##
    ## M5.6: when the buffer reaches the budget it is sorted and written out
    ## as a run, and the final answer is a merge of the runs rather than a
    ## single array. Below the budget this is the M4 code path unchanged,
    ## which is deliberate — the fast path is not a special case of the
    ## general one, it is the case every ordinary query takes.
    if not op.started:
      op.started = true
      let budget = op.spillRows
      while op.child.next():
        op.buffered.add copyRow(op.child.current)
        if budget > 0 and op.buffered.len >= budget:
          spillRun(op)
      if op.runs.len == 0:
        op.buffered.sort(proc (a, b: Row): int = cmpRows(op, a, b))
      else:
        ## The tail that never filled a run, plus the merge's first answer.
        ## Sorted in memory because it is under the budget by definition —
        ## everything else is already on disk.
        op.buffered.sort(proc (a, b: Row): int = cmpRows(op, a, b))
        startMerge(op)
    if op.runs.len > 0:
      ## The merge carries the tail as one more sequence, so a `LIMIT 10`
      ## stops after ten comparisons against every head rather than reading
      ## twenty files — the point of spilling at all.
      if mergeNext(op, op.current):
        return true
      finishSort(op)
      op.exhausted = true
      return false
    if op.cursor < int64(op.buffered.len):
      op.current = op.buffered[op.cursor.int]
      inc op.cursor
      return true
    op.exhausted = true
    return false

  of okCreate:
    ## Cypher's CREATE is per row and one row in gives one row out: the
    ## input row plus the variables it just bound. `CREATE (n)` alone
    ## therefore yields exactly one row with `n` bound, which is what makes
    ## `CREATE (n) RETURN n` answer with the node it made.
    if not op.child.next():
      op.exhausted = true
      return false
    op.current = copyRow(op.child.current)
    for pat in op.createPatterns:
      createPattern(op.ctx, op.current, pat)
    return true

  of okMerge:
    ## Per row: try to match the whole pattern; if it matches, bind and pass
    ## on (running ON MATCH); if not, create it (running ON CREATE). Cypher
    ## is explicit that the decision is per pattern and all-or-nothing —
    ## `MERGE (a:X)-[:R]->(b:Y)` with a matching `a` and no matching `R`
    ## creates the relationship rather than matching half of it.
    if not op.child.next():
      op.exhausted = true
      return false
    op.current = copyRow(op.child.current)
    for pat in op.mergePatterns:
      ## The variables this row already carries constrain the match.
      var bound: seq[(string, Value)] = @[]
      for el in pat.elems:
        if el.isNode and el.node.varName.len > 0:
          let (found, v) = op.current.lookup(el.node.varName)
          if found and (v.kind == vkNode or v.kind == vkEdge):
            bound.add (el.node.varName, v)
        elif (not el.isNode) and el.rel.varName.len > 0:
          let (found, v) = op.current.lookup(el.rel.varName)
          if found and (v.kind == vkNode or v.kind == vkEdge):
            bound.add (el.rel.varName, v)

      let matcher = mergeChain(op.ctx, pat, bound)
      var matched = false
      if matcher.next():
        matched = true
        ## Copy the match's bindings into our row: the variables MERGE binds
        ## come from the match, not from the pattern text.
        for el in pat.elems:
          if el.isNode:
            if el.node.varName.len > 0:
              let (found, v) = matcher.current.lookup(el.node.varName)
              if found:
                op.current.set(el.node.varName, v)
          elif el.rel.varName.len > 0:
            let (found, v) = matcher.current.lookup(el.rel.varName)
            if found:
              op.current.set(el.rel.varName, v)
      if matched:
        ## ON MATCH mutates and does not count as a write of its own: the
        ## row existed either way, and an importer asking "how much landed"
        ## means created nodes.
        mergeActions(op.ctx, op.current, op.onMatchSet, op.onMatchRemove)
      else:
        createPattern(op.ctx, op.current, pat)
        mergeActions(op.ctx, op.current, op.onCreateSet, op.onCreateRemove)
    return true

  of okSet, okRemove, okDelete:
    ## The three per-row write clauses share a shape: pull a row, do the
    ## thing to it, pass it on. SET and REMOVE count one per assignment and
    ## one per removal; DELETE counts the entities it removed, cascade
    ## included — which is the number a caller actually wants back from a
    ## write door ("how much did that delete").
    if not op.child.next():
      op.exhausted = true
      return false
    op.current = copyRow(op.child.current)
    case op.kind
    of okSet:
      for item in op.setItems:
        applySetItem(op.ctx, op.current, item)
        inc op.ctx.rowsAffected
    of okRemove:
      for target in op.removeItems:
        let (_, isNode) = targetOf(op.ctx, op.current, target)
        let id = targetId(op.current, target)
        let ok = if isNode: op.ctx.writer.removeNodeProp(id, target.key)
                 else: op.ctx.writer.removeEdgeProp(id, target.key)
        if not ok:
          fail(int32(glyErrConstraint), "could not remove " & target.key)
        inc op.ctx.rowsAffected
    of okDelete:
      for name in op.deleteVars:
        let (found, v) = op.current.lookup(name)
        if not found:
          fail(int32(glyErrSql), "DELETE target " & name & " is not bound")
        if v.kind != vkNode:
          fail(int32(glyErrSql),
               "DELETE " & name & " is a " & $v.kind & ", not a node")
        if op.detach:
          ## The edges go first, then the node: a node with relationships
          ## cannot be deleted without dangling edges, and the commit
          ## validation would (rightly) refuse the whole transaction.
          ## Counted, because "DETACH DELETE took 4 things" is the useful
          ## answer and counting only the node would say 1.
          ## Counted from the transaction's own view of what is attached —
          ## not the committed degree, which still counts an edge this same
          ## statement deleted when two targets share it.
          let edges = op.ctx.writer.incidentEdges(v.id).len
          if not op.ctx.writer.deleteNode(v.id, true):
            fail(int32(glyErrConstraint), "could not delete " & name)
          inc op.ctx.rowsAffected
          op.ctx.rowsAffected += int64(edges)
        else:
          ## The cascade flag is what makes the non-detach case an *error*
          ## rather than a silent cascade — Cypher's rule: deleting a node
          ## that still has relationships must not quietly take them too.
          if not op.ctx.writer.deleteNode(v.id, false):
            fail(int32(glyErrConstraint),
                 "cannot delete a node that still has relationships — use DETACH DELETE")
          inc op.ctx.rowsAffected
    else:
      discard
    return true

  of okExpandVar:
    ## EXEC.md §2.2: one Expand per hop count, concatenated. The plan builds
    ## the chain; this arm exists only so the kind is not silently
    ## untreated, and refuses rather than producing a wrong row count.
    op.exhausted = true
    return false

  of okDistinct:
    ## Hash on the projected row. `RETURN DISTINCT a` where a is a node must
    ## compare by id, so the key is built from values rather than from their
    ## bytes — two nodes with the same label are not the same row.
    ##
    ## A loop rather than a recursive `next()`: a long run of duplicates is
    ## a legitimate input (`UNWIND [1,1,1,…] AS x RETURN DISTINCT x`) and a
    ## recursion would put the row count on the stack.
    while op.child.next():
      let key = rowKey(op.ctx, op.child.current, op.columns)
      if key notin op.seen:
        op.seen.incl key
        op.current = op.child.current
        return true
    op.exhausted = true
    return false

# ------------------------------------------------------------- row keys

proc valueKey(ctx: QueryCtx, v: Value): string =
  ## A hashable rendering of a value, for DISTINCT and for ORDER BY ties.
  ## Types are prefixed so a node 7 never collides with the integer 7.
  case v.kind
  of vkNull:
    result = "n"
  of vkBool:
    result = (if v.b: "bT" else: "bF")
  of vkInt:
    result = "i" & $v.i
  of vkFloat:
    result = "f" & $v.f
  of vkString:
    result = "s" & $v.s.len & ":" & v.s
  of vkBytes:
    result = "y" & $v.s.len & ":" & v.s
  of vkVector:
    result = "e" & $v.dims.len
  of vkList:
    result = "l" & $v.items.len
    for item in v.items:
      result.add valueKey(ctx, item)
      result.add ','
  of vkMap:
    result = "m" & $v.pairs.len
    for (k, pv) in v.pairs:
      result.add "s" & $k.len & ":" & k & "="
      result.add valueKey(ctx, pv)
      result.add ','
  of vkNode:
    result = "N" & $v.id
  of vkEdge:
    result = "E" & $v.id
  of vkPath:
    result = "p" & $v.path.nodes.len
    for id in v.path.nodes: result.add "N" & $id & ','
    for id in v.path.edges: result.add "E" & $id & ','
    for d in v.path.dirs: result.add "D" & $d & ','

proc rowKey(ctx: QueryCtx, row: Row, columns: seq[string]): string =
  for c in columns:
    let (_, v) = row.lookup(c)
    result.add valueKey(ctx, v)
    result.add '|'

# -------------------------------------------------------------- ordering

proc cmpValues(ctx: QueryCtx, a, b: Value): int =
  ## Cypher's ordering: null last, numbers before strings, and no ordering
  ## across kinds beyond that. `ORDER BY` on a mixed column has to be
  ## *somewhere* deterministic, and "nulls last" is what people expect from
  ## a column that is mostly null.
  if a.kind == vkNull and b.kind == vkNull: return 0
  if a.kind == vkNull: return 1
  if b.kind == vkNull: return -1
  if a.kind in {vkInt, vkFloat} and b.kind in {vkInt, vkFloat}:
    let x = (if a.kind == vkInt: float64(a.i) else: a.f)
    let y = (if b.kind == vkInt: float64(b.i) else: b.f)
    return (if x < y: -1 elif x > y: 1 else: 0)
  if a.kind in {vkString, vkBytes} and b.kind in {vkString, vkBytes}:
    return cmp(a.s, b.s)
  if a.kind in {vkBool} and b.kind in {vkBool}:
    return cmp(a.b, b.b)
  if a.kind in {vkNode, vkEdge} and b.kind in {vkNode, vkEdge}:
    return cmp(a.id, b.id)
  ## Mixed kinds: order by the tag so the sort is stable and total. A
  ## different tie-break here would be a different documented behaviour.
  cmp(ord(a.kind), ord(b.kind))

proc spillPath(op: Operator): string =
  ## One file per run, named by statement and run number. The statement id
  ## is in the name because two sorts in one process must not collide, and
  ## a collision would merge one query's rows into another's answer — the
  ## one failure mode here that produces no error at all.
  op.spillDir & "/glyphes-sort-" & $op.ctx.stmtId & "-" & $op.runNo & ".run"

proc spillRun(op: Operator) =
  ## Sort what is buffered, write it out, start empty.
  ##
  ## The in-memory sort happens *before* the write, not after: a run on disk
  ## has to be sorted for the merge to work, and sorting after the write
  ## would need the file back in memory to do it.
  op.buffered.sort(proc (a, b: Row): int = cmpRows(op, a, b))
  let path = spillPath(op)
  let run = openRunWriter(path, int64(op.buffered.len))
  for row in op.buffered:
    writeRow(run.file, row)
  closeRun(run)
  op.runs.add path
  op.runNo += 1
  op.buffered = @[]

proc startMerge(op: Operator) =
  ## Open every run and pull its first row into the head buffer. The merge
  ## is a linear scan for the smallest live head rather than a heap: runs
  ## are the *number of memory buffers*, so there are tens of them and not
  ## thousands, and a scan over tens of rows costs less than maintaining a
  ## heap over the same rows. It would not hold at a thousand runs, which is
  ## what `spillRows` is for.
  op.mergeReaders = @[]
  op.mergeHeads = @[]
  op.mergeLive = @[]
  for path in op.runs:
    let reader = openRunReader(path)
    op.mergeReaders.add reader
    op.mergeHeads.add initRow(8)
    let live = nextRow(reader, op.mergeHeads[^1])
    op.mergeLive.add live

proc mergeNext(op: Operator, row: var Row): bool =
  ## The smallest live head among the runs *and the in-memory tail*, then
  ## refill whatever that was.
  ##
  ## The tail is one more sorted sequence, not a prefix. The first version
  ## emitted it before touching the runs — which reads right ("the rows still
  ## in memory, then the spilled ones") and is wrong: the tail holds
  ## whichever rows arrived last, and after sorting they belong anywhere in
  ## the order. The query answered correctly for one run's worth of data and
  ## scrambled the moment there were two.
  var best = -1
  for i in 0 ..< op.mergeLive.len:
    if not op.mergeLive[i]:
      continue
    if best < 0 or cmpRows(op, op.mergeHeads[i], op.mergeHeads[best]) < 0:
      best = i
  let tailLive = op.cursor < int64(op.buffered.len)
  if tailLive and (best < 0 or
                   cmpRows(op, op.buffered[op.cursor.int],
                           op.mergeHeads[best]) < 0):
    ## -1 is the tail's index in this scan; it cannot collide with a run's,
    ## which are positions in `mergeLive`.
    best = -1
    row = op.buffered[op.cursor.int]
    inc op.cursor
    return true
  if best < 0:
    return false
  row = op.mergeHeads[best]
  ## Refill *after* handing the row over, because `row` aliases the head's
  ## slots: refilling first would overwrite the row being returned.
  op.mergeLive[best] = nextRow(op.mergeReaders[best], op.mergeHeads[best])
  true

proc finishSort(op: Operator) =
  ## Close the runs and delete them. The deletion is not optional: a spilled
  ## query that leaves its runs behind fills the disk by the million, and
  ## the caller has no handle on them to clean up.
  for reader in op.mergeReaders:
    closeRun(reader)
  op.mergeReaders = @[]
  for path in op.runs:
    if fileExists(path):
      removeFile(path)
  op.runs = @[]
  op.buffered = @[]
  op.spillDir = ""

proc releaseSpills*(op: Operator) =
  ## Delete any spilled runs this statement owns. Called from `close` as well
  ## as from the merge's end, because the two ways a sort stops are not the
  ## same: one is finishing, the other is the caller closing early — after
  ## a LIMIT, an error above the sort, or simply giving up. A run left
  ## behind is a file nobody has a handle to.
  if op == nil:
    return
  if op.kind == okSort and op.runs.len > 0:
    finishSort(op)
  releaseSpills(op.child)

proc cmpRows(op: Operator, a, b: Row): int =
  for item in op.sortSpec.items:
    let va = evaluate(op.ctx, a, item.expr)
    let vb = evaluate(op.ctx, b, item.expr)
    let c = cmpValues(op.ctx, va, vb)
    if c != 0:
      return (if item.desc: -c else: c)
  0
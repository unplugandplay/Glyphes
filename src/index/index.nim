## glyphes — the index registry (M6.1, INDEX.md §1).
##
## A registry of named index definitions plus the plumbing that keeps them
## honest: rebuild at open (pin I2), one pass per commit, and one way to
## ask "which index answers this predicate" for the planner.
##
## ## Where the index lives, and when it learns about a write
##
## The registry is owned by the `Database`, not by the `GraphStore`: the
## store is the file format, and an index is not in the file format (pin
## I2 — index state is never in the WAL, it rebuilds from live records at
## open). Putting it on the store would have the format depend on the index
## code.
##
## Writes reach it in **one** place: `applyDelta`, called from inside the
## commit — after the store is published, while readers are still excluded —
## walking the transaction's node and edge deltas. The alternative —
## instrumenting `createNode`, `setNodeProp`, `deleteNode` and the edge
## equivalents — puts the index update in five places, and "an index is
## never stale" is a claim about one place rather than about five.
##
## The *window* is the part the review got wrong first. The first version
## ran `applyDelta` from the Database after `commit` returned, which is
## after `releaseWriter` — so a reader could begin a seek while the delta
## was being folded in: mutating `ix.ids`/`ix.keys` while another thread
## iterated them. The reader gate exists to close exactly that window, and
## the fix was to run the update inside it (`WriteTransaction.
## indicesToUpdate`), not to make the structures thread-safe after the
## fact.

import std/[sets, tables, strutils, os]
import ../store/prop
import ../store/store
import ../errors
import ../abi
import ./range
import ./text
import ./vector
import ./analyzer

type
  IndexDef* = object
    ## One row of the registry. `name` is derived from `target` and
    ## `property`, so a recreate with the same definition is idempotent and
    ## a rename is a different index.
    name*: string
    kind*: uint8                ## GLY_IDX_RANGE | TEXT | VECTOR
    target*: string             ## label, reltype, or "" for global
    property*: string
    constraint*: uint8          ## none | unique | exists | not_null
    generation*: uint64         ## bumped on every rebuild
    analyzer*: uint8            ## akStandard | akKeyword | akWhitespace (text)
    metric*: uint8              ## mtCosine | mtL2 | mtDot (vector)
    m*: int                      ## vector graph degree
    efConstruction*: int        ## vector build breadth
    ## The family settings live here, not only on the index object, because
    ## the sidecar is written from `defs` and a reopen has to rebuild *the
    ## index that was there* — an l2/m32 index recreated as cosine/m16 is a
    ## different index that answers differently, which is the worst kind of
    ## silent. A range index leaves all four at their zero values.

  Indexes* = ref object
    ## The registry. One index per (target, property) per family; the map is
    ## keyed by name because that is the identity the ABI exposes.
    range*: Table[string, RangeIndex]
    text*: Table[string, TextIndex]
    vector*: Table[string, VectorIndex]
    ## The shared term dictionary (INDEX.md §3: one code per term corpus-wide,
    ## so a posting is 4 bytes and the codes are dense and never reused).
    ## Shared across text indexes so that `the` is one code in every field.
    terms*: Table[string, int32]
    dict*: Table[int32, string]
    defs*: seq[IndexDef]

const
  IdxRange* = 0'u8
  IdxText* = 1'u8
  IdxVector* = 2'u8

  ConstraintNone* = 0'u8
  ConstraintUnique* = 1'u8
  ConstraintExists* = 2'u8
  ConstraintNotNull* = 3'u8

proc newIndexes*(): Indexes =
  Indexes(range: initTable[string, RangeIndex](),
                 text: initTable[string, TextIndex](),
                 vector: initTable[string, VectorIndex](),
                 terms: initTable[string, int32](),
                 dict: initTable[int32, string](), defs: @[])

proc find*(reg: Indexes, target, property: string): RangeIndex =
  ## The index that answers `target.property`, or nil. The lookup is by
  ## the derived name because that is the identity: one index per
  ## (target, property) is an invariant, not a convention.
  let name = (if target.len > 0: target & "." & property else: property)
  reg.range.getOrDefault(name)

proc indexKindName*(k: uint8): string =
  case k
  of IdxRange: "a range index"
  of IdxText: "a text index"
  of IdxVector: "a vector index"
  else: "an index"

proc createVector*(reg: Indexes, target, property: string; metric: Metric,
                   m = DefaultM, efConstruction = DefaultEfConstruction): string =
  ## The vector family (INDEX.md §4). Metric, m and ef_construction are
  ## per index and change the graph, so changing any of them means a
  ## rebuild (I13) — the definition is refused rather than silently
  ## re-created, exactly as an unknown analyzer is.
  let name = (if target.len > 0: target & "." & property else: property)
  for d in reg.defs:
    if d.name == name and d.kind != IdxVector:
      fail(int32(glyErrSql), "index " & name & " already exists as " &
            indexKindName(d.kind) & "; one name, one index")
  if reg.vector.hasKey(name):
    ## Same name, same settings: idempotent. Different settings are a
    ## caller mistake that a silent no-op would hide.
    let old = reg.vector[name]
    if old.metric != metric or old.m != m or
       old.efConstruction != efConstruction:
      fail(int32(glyErrSql), "index " & name & " exists with metric " &
            metricName(old.metric) & ", m " & $old.m & ", ef_construction " &
            $old.efConstruction & "; changing them needs a rebuild")
    return name
  reg.vector[name] = newVector(name, target, property, metric, m, efConstruction)
  reg.defs.add IndexDef(name: name, kind: IdxVector, target: target,
                        property: property, constraint: ConstraintNone,
                        generation: 1, metric: uint8(ord(metric)), m: m,
                        efConstruction: efConstruction)
  name

proc createText*(reg: Indexes, target, property, analyzer: string): string =
  ## The text family. Separate from `create` because it interns a term
  ## dictionary and an analyzer and therefore is not the same shape of call;
  ## the registry keeps one entry per name across families.
  let name = (if target.len > 0: target & "." & property else: property)
  ## The name is the identity (INDEX.md §1: one definition per name), and
  ## the identity does not carry the family — `Doc.body` is one name. A
  ## text index created over a name a *range* index already holds used to
  ## make a second definition with the same identity: `index_list` then
  ## reported two indexes both called `User.email`, and `index_drop` by
  ## that name removed whichever it reached first. Same name, different
  ## family is a caller's mistake, named.
  for d in reg.defs:
    if d.name == name:
      if d.kind == IdxText:
        return name
      fail(int32(glyErrSql), "index " & name & " already exists as " &
            indexKindName(d.kind) & "; one name, one index")
  let kind = fromName(analyzer)
  if analyzer.len > 0 and kind == akStandard and analyzer.toLowerAscii != "standard":
    ## An analyzer nobody knows becomes `standard` in `fromName` — and the
    ## index then answers with terms the caller never asked for. Refuse it.
    fail(int32(glyErrSql), "unknown analyzer " & analyzer)
  reg.text[name] = newText(name, target, property, kind)
  reg.defs.add IndexDef(name: name, kind: IdxText, target: target,
                        property: property, constraint: ConstraintNone,
                        generation: 1, analyzer: uint8(ord(kind)))
  name

proc constraintName*(c: uint8): string =
  case c
  of ConstraintUnique: "unique"
  of ConstraintExists: "exists"
  of ConstraintNotNull: "not_null"
  else: ""

proc valueSig*(v: Value): string =
  ## Canonical key bytes for a uniqueness check. Numbers encode as float64
  ## bits — the same decision range.nim's `keyOf` makes for index keys, so
  ## an int 1 and a float 1.0 are one key and a constraint cannot be
  ## slipped past by changing the column's type spelling. Strings are
  ## their bytes; nulls share one sig, because a unique constraint bounds
  ## *values*, and Cypher's null is not a value (MATCH semantics: null
  ## compares to nothing, including null).
  case v.kind
  of vkInt:
    result = "\x02"
    let f = float64(v.i)
    for ch in cast[array[8, char]](f): result.add ch
  of vkFloat:
    result = "\x02"
    for ch in cast[array[8, char]](v.f): result.add ch
  of vkString, vkBytes:
    result = "\x03" & v.s
  of vkBool:
    result = (if v.b: "\x01\x31" else: "\x01\x30")
  else:
    result = "\x00"

proc valueText(v: Value): string =
  ## A readable rendering for constraint messages. Deliberately not `$`:
  ## the generic `$` funnels into `addQuoted`, which is not GC-safe, and
  ## this runs inside commit — whose callers the compiler holds to the
  ## same rule the soak's thread procs are written under.
  case v.kind
  of vkNull: "null"
  of vkBool: (if v.b: "true" else: "false")
  of vkInt: $v.i
  of vkFloat: $v.f
  of vkString, vkBytes: "'" & v.s & "'"
  of vkDate: "'" & dateText(v.d) & "'"
  else: "<value>"

proc valueKindName(k: ValueKind): string =
  case k
  of vkNull: "null"
  of vkBool: "a bool"
  of vkInt: "an integer"
  of vkFloat: "a float"
  of vkString: "a string"
  of vkBytes: "bytes"
  of vkVector: "a vector"
  of vkList: "a list"
  of vkMap: "a map"
  of vkNode: "a node"
  of vkEdge: "an edge"
  of vkPath: "a path"
  of vkDate: "a date"

proc failConstraint(def: IndexDef, detail: string) {.noreturn.} =
  ## TXN.md §5: a violation reports the offending value and the conflicting
  ## key, because a bare "constraint failed" in a 10^6-row import tells you
  ## nothing about which row to fix.
  fail(int32(glyErrConstraint),
       "constraint " & constraintName(def.constraint) & " on " & def.name &
       " violated: " & detail)

proc uniqueKeyable(v: Value): bool =
  ## Exactly the set `seekEq` can look up (range.nim's `keyOf`): numbers and
  ## strings. Anything else — a bool, bytes, a list — has no committed
  ## lookup, and a uniqueness check that cannot look at the committed state
  ## is a check that can be slipped past. Refusing the write is the only
  ## honest answer; allowing it would enforce uniqueness against this
  ## transaction's nodes and none of the store's.
  v.kind in {vkInt, vkFloat, vkString}

proc checkExistingConstraints*(reg: Indexes, store: GraphStore) =
  ## Run once after a constrained index's initial backfill: the store must
  ## already satisfy the constraint, or creating it is refused. Without this
  ## a constraint over dirty data is a no-op that looks like a guarantee.
  for d in reg.defs:
    if d.constraint == ConstraintNone or d.kind != IdxRange:
      continue
    let ix = reg.range.getOrDefault(d.name)
    if ix == nil:
      continue
    let labelCode = (if d.target.len > 0: store.labels.lookup(d.target) else: 0'i32)
    if d.constraint == ConstraintUnique:
      var first = initTable[string, int64]()
      for i in 0 ..< ix.ids.len:
        let sig = valueSig(ix.keys[i])
        if sig == "\x00":
          continue
        if first.hasKey(sig) and first[sig] != ix.ids[i]:
          failConstraint(d, "value " & valueText(ix.keys[i]) & " is held by nodes " &
                         $first[sig] & " and " & $ix.ids[i])
        first[sig] = ix.ids[i]
      for b in ix.blocks:
        for i in 0 ..< blockLen(b):
          let k = blockAt(b, i)
          let sig = valueSig(k)
          if sig == "\x00":
            continue
          if first.hasKey(sig) and first[sig] != b.ids[i]:
            failConstraint(d, "value " & valueText(k) & " is held by nodes " &
                           $first[sig] & " and " & $b.ids[i])
          first[sig] = b.ids[i]
    else:
      ## exists / not_null: every live node of the label holds the
      ## property. `valueSig`'s null case is unreachable here on purpose —
      ## a *stored* null does not exist (prop.nim's setProp removes on
      ## null), so absence is the only failure shape.
      let keyCode = store.propKeys.lookup(d.property)
      for id in 1 ..< store.nodes.len:
        let rec = store.nodes[id]
        if not rec.live():
          continue
        if d.target.len > 0 and rec.label != labelCode:
          continue
        var v = Value(kind: vkNull)
        if keyCode == 0 or not store.arena.getProp(rec.propView, keyCode, v):
          failConstraint(d, "node " & $id & " has no " & d.property)

proc validateConstraints*(reg: Indexes, store: GraphStore,
                          nodeDelta: Table[int64, NodeRec]) =
  ## TXN.md §3.1 step 3, called from commit before anything is durable: a
  ## violation fails the transaction instead of reaching the log, and a
  ## transaction that is later rolled back has paid nothing.
  ##
  ## `nodeDelta` holds the transaction's own view of every node it touched,
  ## and the records' propViews already carry the new values — txn.nim's
  ## setPropCommon writes through the arena immediately, which is what makes
  ## a pre-commit check possible without replaying frames.
  for d in reg.defs:
    if d.constraint == ConstraintNone:
      continue
    if d.kind != IdxRange:
      failConstraint(d, "constraints are the range family; a text or " &
                     "vector index cannot enforce one")
    let ix = reg.range.getOrDefault(d.name)
    if ix == nil:
      continue
    let labelCode = (if d.target.len > 0: store.labels.lookup(d.target) else: 0'i32)
    let keyCode = store.propKeys.lookup(d.property)
    var seen: Table[string, int64]
    for id, rec in nodeDelta:
      if not rec.live():
        continue
      if d.target.len > 0 and rec.label != labelCode:
        continue
      var v = Value(kind: vkNull)
      let have = keyCode != 0 and store.arena.getProp(rec.propView, keyCode, v)
      case d.constraint
      of ConstraintUnique:
        if not have or v.kind == vkNull:
          continue              ## null is not a value; it cannot collide
        if not uniqueKeyable(v):
          failConstraint(d, "a value of " & valueKindName(v.kind) &
                         " on node " & $id & " cannot be keyed, so " &
                         "uniqueness cannot be checked")
        let sig = valueSig(v)
        ## Two nodes of this same transaction: neither is committed, so
        ## neither is in the index, and skipping this check would let a
        ## single INSERT statement create its own duplicate.
        if seen.hasKey(sig) and seen[sig] != id:
          failConstraint(d, "value " & valueText(v) & " is held by nodes " &
                         $seen[sig] & " and " & $id & " in this transaction")
        seen[sig] = id
        ## The committed store. `seekEq` reads the index, which applyDelta
        ## keeps exactly in step with every commit — the same structure the
        ## query path trusts, not a second copy that could disagree (TXN.md
        ## §5: a constraint and a query index are the same structure with
        ## two clients).
        let others = ix.seekEq(v)
        for other in others:
          if other != id:
            failConstraint(d, "value " & valueText(v) & " on node " & $id &
                           " already held by node " & $other)
      else:
        ## exists and not_null are one check with two spellings: the
        ## property must be present, and a stored null is not a presence
        ## (prop.nim removes on null, so `SET n.x = null` fails here the
        ## same as REMOVE does).
        if not have or v.kind == vkNull:
          failConstraint(d, "node " & $id & " has no " & d.property)

proc create*(reg: Indexes, kind: uint8, target, property: string,
             constraint = ConstraintNone): string =
  ## O(1) when the store is empty, backfilling when it is not — the caller
  ## decides by asking `reg.populated` first.
  ##
  ## A constraint is not a second mechanism: it is this index with a second
  ## client (TXN.md §5), and the constraint travels on the definition so
  ## `list` reports it and the commit path finds it.
  if constraint != ConstraintNone and kind != IdxRange:
    fail(int32(glyErrUnsupported),
         "a constraint needs the range family; a text or vector index cannot enforce one")
  let name = (if target.len > 0: target & "." & property else: property)
  for d in reg.defs:
    if d.name == name:
      if d.kind == IdxRange:
        return name                     ## idempotent by construction
      fail(int32(glyErrSql), "index " & name & " already exists as " &
            indexKindName(d.kind) & "; one name, one index")
  if kind == IdxRange:
    reg.range[name] = newRange(name, target, property)
  reg.defs.add IndexDef(name: name, kind: kind, target: target,
                        property: property, constraint: constraint,
                        generation: 1)
  name

proc recreate*(reg: Indexes, def: IndexDef): string =
  ## Recreate an index from its own definition, family settings included.
  ## The open path calls this rather than `create`, because the family
  ## lives on the definition: a text index recreated with the default
  ## analyzer, or a vector index with the default metric, rebuilds a
  ## *different* index — one that answers differently, silently, and only
  ## from the second open onwards.
  if def.kind == IdxText:
    result = reg.createText(def.target, def.property,
                            analyzerName(AnalyzerKind(def.analyzer)))
  elif def.kind == IdxVector:
    result = reg.createVector(def.target, def.property,
                              Metric(def.metric), def.m, def.efConstruction)
  else:
    result = reg.create(def.kind, def.target, def.property, def.constraint)

proc drop*(reg: Indexes, name: string): bool =
  if reg.range.hasKey(name):
    reg.range.del(name)
  if reg.text.hasKey(name):
    reg.text.del(name)
  if reg.vector.hasKey(name):
    reg.vector.del(name)
  var kept: seq[IndexDef] = @[]
  for d in reg.defs:
    if d.name != name:
      kept.add d
  reg.defs = kept
  true

proc list*(reg: Indexes): seq[IndexDef] = reg.defs

proc asFloatVec*(v: Value): seq[float32] =
  ## A property or parameter is a vector when the store says so, or when
  ## it is a list of numbers — the JSON binding hands `[0.1, 0.2, …]` over
  ## as a list, and refusing it here would make the Ruby surface write
  ## vectors it can never search. Anything else is not a vector.
  case v.kind
  of vkVector:
    return v.dims
  of vkList:
    var all = true
    for item in v.items:
      if item.kind != vkInt and item.kind != vkFloat:
        all = false
        break
    if all:
      result = newSeq[float32](v.items.len)
      for i, item in v.items:
        result[i] = (if item.kind == vkInt: float32(item.i) else: item.f)
  else:
    discard

proc rebuild*(reg: Indexes, store: GraphStore, name = "") =
  ## Drop the contents and refill from live records. O(n log n), and the
  ## bulk path: it is what `index_build` and every open do.
  var targets: seq[RangeIndex] = @[]
  for key, ix in reg.range:
    if name.len == 0 or key == name:
      targets.add ix
  for ix in targets:
    let code = (if ix.label.len > 0: store.labels.lookup(ix.label) else: 0'i32)
    ## A label the store has never interned indexes nothing. Reading 0 as
    ## "any label" — which is what a *scan* means by it — put every node in
    ## the store under a label nobody has, which is how an index over an
    ## unused label returned the whole graph.
    if ix.label.len > 0 and code == 0:
      ix.reset()
      for d in reg.defs.mitems:
        if d.name == ix.name:
          inc d.generation
      continue
    ## `reset` rather than five field writes: the registry had its own copy
    ## of the reset and missed the delta table, which is how a rebuilt
    ## index inherited a decision its own refill then contradicted.
    ix.reset()
    for id in 1 ..< store.nodes.len:
      let rec = store.nodes[id]
      if not rec.live:
        continue
      if rec.label != code:
        continue
      var v = Value(kind: vkNull)
      if not store.getNodeProp(int64(id), ix.property, v):
        continue
      ix.insert(int64(id), v)
    ix.merge()
    for d in reg.defs.mitems:
      if d.name == ix.name:
        inc d.generation

  ## The text family refills the same way, except that `merge` takes the
  ## registry's shared dictionary: codes are corpus-wide, so a bulk rebuild
  ## that used a private dictionary would renumber every posting in every
  ## other text index and quietly invalidate all of them.
  var textTargets: seq[TextIndex] = @[]
  for key, ix in reg.text:
    if name.len == 0 or key == name:
      textTargets.add ix
  ## The vector family refills the same way, and the graph comes out
  ## byte-identical for the same vectors in the same order (I11): the
  ## level draw is re-seeded in `reset`.
  var vecTargets: seq[VectorIndex] = @[]
  for key, ix in reg.vector:
    if name.len == 0 or key == name:
      vecTargets.add ix
  for ix in vecTargets:
    let code = (if ix.label.len > 0: store.labels.lookup(ix.label) else: 0'i32)
    ix.reset()
    if ix.label.len > 0 and code == 0:
      for d in reg.defs.mitems:
        if d.name == ix.name:
          inc d.generation
      continue
    for id in 1 ..< store.nodes.len:
      let rec = store.nodes[id]
      if not rec.live() or rec.label != code:
        continue
      var v = Value(kind: vkNull)
      if not store.getNodeProp(int64(id), ix.property, v):
        continue
      let f = asFloatVec(v)
      if f.len > 0:
        ix.insert(int64(id), f)
    for d in reg.defs.mitems:
      if d.name == ix.name:
        inc d.generation

  for ix in textTargets:
    let code = (if ix.label.len > 0: store.labels.lookup(ix.label) else: 0'i32)
    ix.reset()
    if ix.label.len > 0 and code == 0:
      for d in reg.defs.mitems:
        if d.name == ix.name:
          inc d.generation
      continue
    for id in 1 ..< store.nodes.len:
      let rec = store.nodes[id]
      if not rec.live or rec.label != code:
        continue
      var v = Value(kind: vkNull)
      if not store.getNodeProp(int64(id), ix.property, v):
        continue
      if v.kind == vkString:
        ix.update(int64(id), v.s)
    ix.merge(reg.terms, reg.dict)
    for d in reg.defs.mitems:
      if d.name == ix.name:
        inc d.generation

proc applyDelta*(reg: Indexes, store: GraphStore,
                 nodes: Table[int64, NodeRec],
                 edges: Table[int64, EdgeRec]) =
  ## One transaction's worth of writes, applied to every index that cares.
  ##
  ## Called from inside the commit's write exclusion (see the header for
  ## why the window matters as much as the place). The caller passes the
  ## deltas rather than this reaching for them, so that the commit path is
  ## the only thing that decides *when* an index learns about a write.
  for key, ix in reg.range:
    if ix.label.len == 0:
      continue                         ## global index: M6.3
    let code = store.labels.lookup(ix.label)
    for id, rec in nodes:
      let nid = int64(id)
      if not rec.live:
        ## A tombstoned node must leave every index (pin I11). It may never
        ## have had the property, and deleting anyway is what makes the
        ## delete idempotent.
        ix.delete(nid)
        continue
      if rec.label != code:
        continue
      var v = Value(kind: vkNull)
      if store.getNodeProp(nid, ix.property, v):
        ix.insert(nid, v)
      else:
        ## The property went away (`REMOVE n.age`), which is a delete of
        ## this index's entry — the same rule as `SET n.age = null`.
        ix.delete(nid)
    ## Relationship entries land with the global indexes in M6.3; the
    ## parameter is here so the call site does not change shape when it
    ## does.

    ## Relationship entries land with the global indexes in M6.3; the
    ## parameter is here so the call site does not change shape when it
    ## does.
    ## Merging is per commit, not per write: the delta exists to make a
    ## write O(1), and merging on every one of them would undo that.
    if ix.ids.len > 0:
      ix.merge()
    discard edges

  ## Text indexes see the same rule through `update`, which removes the
  ## node's previous terms before adding the new ones — a `SET n.body = ...`
  ## that appended a word would otherwise leave the old word indexed and the
  ## score would count a term the document no longer has. The merge is the
  ## same discipline, folded once per commit.
  for key, ix in reg.text:
    let code = (if ix.label.len > 0: store.labels.lookup(ix.label) else: 0'i32)
    for id, rec in nodes:
      let nid = int64(id)
      if not rec.live or (ix.label.len > 0 and rec.label != code):
        ix.remove(nid)
        continue
      var v = Value(kind: vkNull)
      if store.getNodeProp(nid, ix.property, v) and v.kind == vkString:
        ix.update(nid, v.s)
      else:
        ix.remove(nid)
    if ix.pendingIds.len > 0:
      ix.merge(reg.terms, reg.dict)

  ## Vector indexes see the same rule through `insert`, which tombstones
  ## the node's previous entry before adding the new one — an update is a
  ## different document, and the graph around the old vector is structure
  ## the rebuild owns, not the write path.
  for key, ix in reg.vector:
    let code = (if ix.label.len > 0: store.labels.lookup(ix.label) else: 0'i32)
    for id, rec in nodes:
      let nid = int64(id)
      if not rec.live() or (ix.label.len > 0 and rec.label != code):
        discard ix.remove(nid)
        continue
      var v = Value(kind: vkNull)
      if store.getNodeProp(nid, ix.property, v):
        let f = asFloatVec(v)
        if f.len > 0:
          ix.insert(nid, f)
        else:
          discard ix.remove(nid)
      else:
        discard ix.remove(nid)

proc mergeAll*(reg: Indexes) =
  ## Fold every index's delta at once. The commit folds per index inside
  ## `applyDelta`; this is the checkpoint-shaped entry point for a caller
  ## that wants everything folded without new writes to apply.
  for _, ix in reg.range:
    ix.merge()
  for _, ix in reg.text:
    if ix.pendingIds.len > 0:
      ix.merge(reg.terms, reg.dict)
## The index *definitions* live beside the snapshot in a small sidecar
## (`<path>.indexes`), not in the WAL (pin W5: index state is never in the
## log) and not in the snapshot's frozen header. A definition is the cheap
## thing a caller can afford to make durable — a name, a kind, a target, a
## property, a constraint — while the index *contents* are rebuilt from
## live records at open (WAL.md §5 step 5), which is why no index bytes are
## written anywhere: the file is text, the format is ours, and a corrupt or
## absent one costs the indexes, never the data.

const IndexSidecarSuffix* = ".indexes"
const IndexSidecarMagic* = "GLYIDX01"

proc writeIndexDefs*(reg: Indexes, path: string) =
  ## One line per definition. Written at checkpoint and whenever the
  ## definitions change, so a reopen sees the same registry it closed with.
  if path.len == 0:
    return
  let file = path & IndexSidecarSuffix
  var body = IndexSidecarMagic & "\n"
  for d in reg.defs:
    body.add d.name & "\t" & $ord(d.kind) & "\t" & d.target & "\t" &
            d.property & "\t" & $ord(d.constraint) & "\t" &
            $d.analyzer & "\t" & $d.metric & "\t" & $d.m & "\t" &
            $d.efConstruction & "\n"
  try:
    ## Written through a temporary and renamed, not written in place:
    ## `writeFile` truncates first, so a crash mid-write leaves a torn
    ## sidecar — and a torn sidecar would have made every later open fail
    ## on a database whose data is perfectly intact. A rename in the same
    ## directory is atomic; the worst a crash can leave is the old
    ## definitions, which are a valid previous state.
    let tmp = file & ".tmp"
    writeFile(tmp, body)
    moveFile(tmp, file)
  except IOError as e:
    ## The definitions are lost, not the data: the store is untouched and
    ## the next reopen has no indexes. This raises — a caller who asked for
    ## a checkpoint asked for a durable state, and a sidecar that silently
    ## did not land is a checkpoint that lied.
    fail(int32(glyErrIo), "cannot write " & file & ": " & e.msg)

proc IndexDefs*(store: GraphStore, path: string = ""): seq[IndexDef] =
  ## The definitions to recreate at open. Absent or unreadable sidecar is
  ## the ordinary "no indexes" answer, not an error: an index is
  ## configuration, and a database whose sidecar was lost still opens with
  ## all its data and no indexes — which is the state `index_create` puts
  ## it back from.
  discard store
  result = @[]
  if path.len == 0:
    return
  let file = path & IndexSidecarSuffix
  if not fileExists(file):
    return
  var body: string
  try:
    body = readFile(file)
  except IOError:
    return                        ## unreadable: the ordinary no-indexes answer
  var lines = body.splitLines()
  if lines.len == 0 or lines[0] != IndexSidecarMagic:
    return                        ## a file that is not ours: no indexes
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.len == 0:
      continue
    let parts = line.split('\t')
    if parts.len < 5:
      continue                    ## a torn or foreign line: skip it
    ## A five-field line is a GLYIDX01 sidecar: the family settings did not
    ## exist then, so they read back as the family's defaults. Reading the
    ## old shape is deliberate — a sidecar written by the previous build
    ## must not turn into "no indexes" on the next open.
    var def = IndexDef(name: parts[0], kind: uint8(parseInt(parts[1])),
                       target: parts[2], property: parts[3],
                       constraint: uint8(parseInt(parts[4])), generation: 1)
    if parts.len >= 9:
      try:
        def.analyzer = uint8(parseInt(parts[5]))
        def.metric = uint8(parseInt(parts[6]))
        def.m = parseInt(parts[7])
        def.efConstruction = parseInt(parts[8])
      except ValueError:
        continue                  ## a corrupt number: that line is not ours
    elif def.kind == IdxVector:
      def.metric = uint8(ord(mCosine))
      def.m = DefaultM
      def.efConstruction = DefaultEfConstruction
    result.add def

const TombstoneRebuildThreshold* = 0.20
  ## INDEX.md I14: an approximate index whose tombstones pass a fifth of
  ## its entries is one whose walk pays for them forever — every search
  ## skips a fifth of the graph to reach the other four fifths. The fix is
  ## a rebuild from live records, and the cost is bounded by store size
  ## rather than by the history of deletions.

proc indexesNeedingRebuild*(reg: Indexes): seq[string] =
  ## The vector indexes whose tombstone ratio has passed the threshold.
  ## Only vector: a range index removes the entry outright (pin I11), and a
  ## text index decrements its postings — neither accumulates a tombstone
  ## a walk has to skip.
  for d in reg.defs:
    if d.kind != IdxVector: continue
    let ix = reg.vector.getOrDefault(d.name)
    if ix != nil and ix.tombstoneRatio > TombstoneRebuildThreshold:
      result.add d.name

proc stats*(reg: Indexes): seq[(string, int64, int, int)] =
  ## (name, entries, blocks, generation) — what `index_list` reports and
  ## what the I-gate benchmark prints.
  for d in reg.defs:
    var blocks = 0
    var entries = 0'i64
    if d.kind == IdxText:
      let tix = reg.text.getOrDefault(d.name)
      if tix != nil:
        ## A text index has no blocks — it is postings, not an ordered
        ## array — so the JSON reports the term count, and a caller reading
        ## it as "blocks" would conclude an empty index where there are
        ## entries.
        entries = tix.docCount
        blocks = tix.postings.len
    elif d.kind == IdxVector:
      let vix = reg.vector.getOrDefault(d.name)
      if vix != nil:
        entries = int64(vix.liveCount)
        blocks = vix.maxLevel + 1
    else:
      let ix = reg.range.getOrDefault(d.name)
      if ix != nil:
        let st = ix.blockStats()
        blocks = st[0]
        entries = ix.entryCount
    result.add (d.name, entries, blocks, d.generation.int)

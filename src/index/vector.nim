## glyphes — the vector index: HNSW over f32 (INDEX.md §4)
##
## The part that has to be right, because an HNSW that ignores graph
## context is a worse vector store than a library you already have.
## Three properties this build is held to, in the order a reviewer will
## meet them:
##
##   1. Determinism (pin I11): the same vectors inserted in the same order
##      produce a byte-identical graph at fixed `m`/`ef_construction`/seed.
##      HNSW's only randomness is the level draw, so the PRNG is seeded and
##      advanced strictly in insertion order, and every comparison that
##      could tie is broken by slot (insertion order). A differential test
##      can then compare bytes, not recall distributions.
##   2. Tombstones (pin I8): a deleted node is never returned. Its links
##      stay (removing them needs a rebuild), so the walk still visits it
##      and pays the cost — the cost is the price of not rebuilding.
##   3. The diversity heuristic (INDEX.md §4.1): selecting M neighbours by
##      plain nearest-first collapses the graph into clusters and recall
##      degrades badly at high M. A neighbour is rejected when it is closer
##      to an already-selected neighbour than to the query.
##
## Distances are all "lower is closer" so the walk never branches on the
## metric: cosine is 1 − sim (norms precomputed, the inner loop stays a
## dot), L2 is the squared distance (ordering unchanged, no sqrt), and dot
## is negated. The *scores* handed back are similarity-shaped — higher is
## better (pin I12) — so a caller sorts one way for both families.

import std/[math, tables, sets, heapqueue, strutils, algorithm]
import ../store/prop
import ../abi
import ../errors

const
  DefaultM* = 16
  DefaultEfConstruction* = 200
  DefaultEf* = 64
  MaxLevel* = 32                ## ln(10^9)/ln(16) ≈ 7.5; 32 is headroom
  MaxOverFetch* = 4096          ## worst-case filtered k; bounded, not free

type
  Metric* = enum
    mCosine, mL2, mDot

proc metricFromName*(name: string): Metric =
  ## Unknown names are refused, not defaulted — a metric nobody asked for
  ## is a search that works and is quietly wrong, the same rule the text
  ## analyzer learned at M6.2.
  case name.toLowerAscii()
  of "cosine": mCosine
  of "l2", "euclidean": mL2
  of "dot", "inner": mDot
  else:
    fail(int32(glyErrSql), "unknown metric \"" & name &
                           "\" (cosine, l2, dot)")

proc metricName*(m: Metric): string =
  case m
  of mCosine: "cosine"
  of mL2: "l2"
  of mDot: "dot"

type
  VectorIndex* = ref object
    name*: string
    label*: string
    property*: string
    metric*: Metric
    dim*: int                  ## 0 until the first vector decides it
    m*: int                    ## neighbours per upper layer
    m0*: int                   ## = 2m on layer 0 (INDEX.md §4)
    efConstruction*: int
    ef*: int                   ## default search breadth
    seed*: uint64              ## level-draw PRNG; fixed ⇒ I11
    rngState*: uint64
    ## Slot-parallel arrays; a slot is one node's entry and slots are in
    ## insertion order, which is what makes the level draw reproducible.
    ids*: seq[int64]
    vecs*: seq[float32]        ## stride dim; slot i at i*dim
    norms*: seq[float32]       ## per slot; cosine's inner loop stays a dot
    levels*: seq[int32]
    dead*: seq[bool]           ## tombstones; links remain, results skip
    deadCount*: int
    ## Layer 0: m0 slots per node, -1 padded — one contiguous run per node,
    ## so a neighbour fetch is one read. The docs sketch flat arrays for
    ## the upper layers too; that is a memory optimization, deferred, and
    ## does not change anything observable.
    links0*: seq[int32]
    ## Upper layers: for a node of level l ≥ 1, l runs of m slots, -1
    ## padded and concatenated, so level k of node i starts at
    ## hi[i] + (k-1)*m without per-level bookkeeping.
    hi*: seq[seq[int32]]
    slotOf*: Table[int64, int32]
    entry*: int32              ## -1 when empty
    maxLevel*: int
    probes*: int64

proc newVector*(name, label, property: string; metric: Metric = mCosine;
                m = DefaultM; efConstruction = DefaultEfConstruction): VectorIndex =
  if m < 2:
    fail(int32(glyErrSql), "m must be at least 2")
  if efConstruction < DefaultEfConstruction:
    ## INDEX.md §4.1: ≥ 200 is pinned. Lower values build faster and
    ## recall drops measurably; the default is the quality setting, and
    ## this is the one trade the index refuses to make silently.
    fail(int32(glyErrSql), "ef_construction must be at least 200; lower " &
                           "values trade recall for build time")
  result = VectorIndex(name: name, label: label, property: property,
                       metric: metric, m: m, m0: 2 * m,
                       efConstruction: efConstruction, ef: DefaultEf,
                       seed: 0x9E3779B97F4A7C15'u64, entry: -1'i32,
                       slotOf: initTable[int64, int32]())
  result.rngState = result.seed

proc sameVector(ix: VectorIndex, slot: int32, vec: openArray[float32]): bool =
  ## Exact bitwise equality: an approximate comparison would silently drop
  ## a genuinely changed vector, and this compare is the skip's whole cost
  ## (one pass over the dimensions, against a whole HNSW insert).
  if ix.dim == vec.len:
    let base = int(slot) * ix.dim
    for i in 0 ..< ix.dim:
      if ix.vecs[base + i] != vec[i]:
        return false
    return true
  false

proc nextLevel(ix: VectorIndex): int =
  ## The level draw: xorshift64*, advanced once per insert, in insertion
  ## order — the whole determinism story (I11) in three shifts.
  var x = ix.rngState
  x = x xor (x shr 12)
  x = x xor (x shl 25)
  x = x xor (x shr 27)
  ix.rngState = x
  let u = float64((x * 0x2545F4914F6CDD1D'u64) shr 11) / 9007199254740992.0
  ## Geometric with p = 1/m: the exponential's floor. A u of exactly 0
  ## would send the log to infinity, so it is pushed off the boundary.
  result = int(floor(-ln(max(u, 1e-12)) / ln(float64(ix.m))))
  if result > MaxLevel:
    result = MaxLevel

# ------------------------------------------------------------- distances

proc slotPtr(ix: VectorIndex, slot: int32): ptr float32 {.inline.} =
  addr ix.vecs[int(slot) * ix.dim]

proc distVecs(ix: VectorIndex, a, b: ptr float32, na, nb: float32): float32 =
  ## a/b point at dim floats; na/nb are their norms (only cosine reads
  ## them). Zero vectors: cosine of nothing is defined as maximally far
  ## rather than NaN — a NaN inside the walk poisons every comparison
  ## after it, and a zero vector has no direction to be near.
  ## ptr UncheckedArray indexing: a raw ptr does not subscript.
  let ap = cast[ptr UncheckedArray[float32]](a)
  let bp = cast[ptr UncheckedArray[float32]](b)
  case ix.metric
  of mCosine:
    var dot = 0.0'f32
    for i in 0 ..< ix.dim:
      dot += ap[i] * bp[i]
    if na == 0.0'f32 or nb == 0.0'f32:
      return 1.0'f32
    return 1.0'f32 - dot / (na * nb)
  of mL2:
    var s = 0.0'f32
    for i in 0 ..< ix.dim:
      let t = ap[i] - bp[i]
      s += t * t
    return s
  of mDot:
    var dot = 0.0'f32
    for i in 0 ..< ix.dim:
      dot += ap[i] * bp[i]
    return -dot

proc distSlot(ix: VectorIndex, aSlot, bSlot: int32): float32 {.inline.} =
  ix.distVecs(ix.slotPtr(aSlot), ix.slotPtr(bSlot),
              ix.norms[aSlot], ix.norms[bSlot])

proc normOf(vec: openArray[float32]): float32 =
  var s = 0.0'f32
  for f in vec:
    s += f * f
  sqrt(s)

# --------------------------------------------------------------- layout

proc hiOffset(ix: VectorIndex, slot: int32, layer: int): int {.inline.} =
  ## Start index of node `slot`'s neighbour run at `layer` (≥ 1) inside
  ## hi[slot]. Level 1 run comes first, so the offset is (layer-1)*m.
  int(layer - 1) * ix.m

proc neighborsAt*(ix: VectorIndex, slot: int32, layer: int): seq[int32] =
  ## The live neighbour ids (not node ids — slots) of `slot` at `layer`.
  ## -1 padding terminates. Returns a copy: the walk mutates nothing, but
  ## a prune rewrites the list it is iterating in the insert path, and
  ## sharing that buffer was how a first draft dropped links.
  result = @[]
  if layer == 0:
    let base = int(slot) * ix.m0
    for i in 0 ..< ix.m0:
      let n = ix.links0[base + i]
      if n < 0:
        break
      result.add n
  else:
    if ix.levels[slot] < layer:
      return
    let run = ix.hi[slot]
    let base = ix.hiOffset(slot, layer)
    for i in 0 ..< ix.m:
      let n = run[base + i]
      if n < 0:
        break
      result.add n

proc setNeighbors(ix: VectorIndex, slot: int32, layer: int,
                  ns: seq[int32]) =
  ## Write a (possibly pruned) neighbour list back, -1 padded. Callers
  ## pass at most cap entries; the padding is what makes the next read a
  ## single scan that stops at the first -1.
  if layer == 0:
    let base = int(slot) * ix.m0
    for i in 0 ..< ix.m0:
      ix.links0[base + i] = (if i < ns.len: ns[i] else: -1'i32)
  else:
    ## hi[slot] is the node's own buffer: mutate it in place rather than
    ## copy through a  binding, which would write to a temporary.
    let base = ix.hiOffset(slot, layer)
    for i in 0 ..< ix.m:
      ix.hi[slot][base + i] = (if i < ns.len: ns[i] else: -1'i32)

# -------------------------------------------------------------- heuristic

proc selectDiverse(ix: VectorIndex,
                   cands: seq[(float32, int32)], cap: int): seq[int32] =
  ## The diversity heuristic (INDEX.md §4.1): walk candidates nearest
  ## first; reject a candidate that is closer to an already-selected
  ## neighbour than to the query. Without it the graph collapses into
  ## clusters. Ties are decided by slot order (the sort below is stable
  ## on the tuple), which keeps the build byte-reproducible.
  var cands = cands
  ## Lexicographic tuple order: distance first, slot second — the slot is
  ## the tiebreak that keeps the build byte-reproducible (I11).
  proc byDistThenSlot(a, b: (float32, int32)): int =
    let c = cmp(a[0], b[0])
    if c != 0: return c
    cmp(a[1], b[1])
  cands.sort(byDistThenSlot)
  result = @[]
  for (d, s) in cands:
    if result.len == cap:
      break
    var ok = true
    for r in result:
      if ix.distSlot(s, r) < d:
        ok = false
        break
    if ok:
      result.add s
  ## The nearest leftovers backfill the rest (the paper's
  ## keepPrunedConnections). Without the fill a node whose neighbourhood
  ## the heuristic rejected keeps two or three links, and at 10^5 nodes
  ## the graph starves: one node in 50k became unreachable, the recall
  ## ceiling at ef=512 was 0.94, and the ceiling is the graph's fault —
  ## a walk with unlimited breadth finds everything a connected graph
  ## holds. The fill costs diversity on uniform data at small N (0.83 vs
  ## 0.90 at 20k, ef=128) and buys the graph back at scale; the scale is
  ## the product.
  if result.len < cap:
    for (d, s) in cands:
      if result.len == cap:
        break
      if s notin result:
        result.add s

proc linkOne(ix: VectorIndex, fromSlot, toSlot: int32, layer: int) =
  ## Bidirectional link with prune. The capacity check walks the list
  ## linearly — capacities are 16 or 32, an array subscript each, and the
  ## alternative (a set per node) costs more than it saves.
  let cap = (if layer == 0: ix.m0 else: ix.m)
  var ns = ix.neighborsAt(fromSlot, layer)
  if toSlot in ns:
    return
  ns.add toSlot
  if ns.len > cap:
    ## Over capacity: re-select from this node's own vector. The
    ## candidates include the new link and every old one; the heuristic
    ## decides which cap survive.
    var cands: seq[(float32, int32)] = @[]
    for n in ns:
      cands.add (ix.distSlot(fromSlot, n), n)
    ns = ix.selectDiverse(cands, cap)
  ix.setNeighbors(fromSlot, layer, ns)

# ----------------------------------------------------------------- insert

type
  Cand = tuple[d: float32, s: int32]

proc `<`(a, b: Cand): bool =
  ## HeapQueue is a min-heap. The candidates' frontier wants the *nearest*
  ## on top (min-heap on distance); the results want the *worst* on top
  ## (max-heap on distance) — done by storing -d there. Ties fall through
  ## to the slot, which keeps the walk byte-reproducible (I11).
  if a.d != b.d:
    return a.d < b.d
  a.s < b.s

proc searchLayer(ix: VectorIndex, q: ptr float32, qn: float32,
                 ep: int32, ef: int, layer: int,
                 pass: proc (slot: int32): bool {.gcsafe.} = nil): seq[Cand] {.gcsafe.}
  ## Forward: insert's per-layer walk is searchLayer's, and the reading
  ## order (build first, walk second) is the writing order's problem.

proc insert*(ix: VectorIndex, nodeId: int64, vec: openArray[float32]) {.gcsafe.} =
  ## One node in. An update is not an update — it is a tombstone of the
  ## old entry plus a new one, the same rule the text index learned: the
  ## graph around the old vector is real structure, and rewriting it in
  ## place is a rebuild wearing a cheaper name.
  if ix.dim == 0:
    ix.dim = vec.len
    ix.vecs = newSeq[float32]()
    ix.norms = @[]
  elif vec.len != ix.dim:
    fail(int32(glyErrSql), "vector of dimension " & $vec.len &
                           " does not match the index's " & $ix.dim)
  if ix.slotOf.hasKey(nodeId):
    let old = ix.slotOf[nodeId]
    if not ix.dead[old]:
      ## An identical vector is not a new document: skipping costs one
      ## comparison and saves a full ef_construction insert plus a dead
      ## slot. A transaction that re-SETs the same embedding — an importer's
      ## `ON MATCH SET`, a re-run of a batch — used to pay ~1.3 ms per row
      ## on a 4k-node index and leave a tombstone behind for every one of
      ## them, which is how a walk gets slower without any data changing
      ## (INDEX.md §4.4: tombstones are paid for, so fewer are made).
      if ix.sameVector(old, vec):
        return
      ix.dead[old] = true
      inc ix.deadCount

  let slot = int32(ix.ids.len)
  let level = ix.nextLevel()
  ix.ids.add nodeId
  for f in vec:
    ix.vecs.add f
  ix.norms.add normOf(vec)
  ix.levels.add int32(level)
  ix.dead.add false
  for i in 0 ..< ix.m0:
    ix.links0.add -1'i32
  if level >= 1:
    var run = newSeq[int32](level * ix.m)
    for i in 0 ..< run.len:
      run[i] = -1'i32
    ix.hi.add run
  else:
    ix.hi.add newSeq[int32](0)
  ix.slotOf[nodeId] = slot

  if ix.entry < 0:
    ix.entry = slot
    ix.maxLevel = level
    return

  let q = ix.slotPtr(slot)
  let qn = ix.norms[slot]
  var ep = ix.entry
  ## Top-down greedy descent to level+1 with ef = 1: the standard shape.
  ## The descent's distances compare the *new* vector against slots, so
  ## distSlot works on both ends.
  for l in countdown(ix.maxLevel, level + 1):
    var cur = ep
    var curD = ix.distSlot(slot, ep)
    while true:
      var improved = false
      for n in ix.neighborsAt(cur, l):
        let d = ix.distSlot(slot, n)
        if d < curD:
          curD = d
          cur = n
          improved = true
      if not improved:
        break
    ep = cur
  ## From the node's own level down to 0: efConstruction-breadth walk,
  ## M diverse neighbours selected, bidirectionally linked, then the best
  ## candidate of the layer becomes the next layer's entry. This is the
  ## whole construction cost — one full walk per layer per insert — which
  ## is why INDEX.md §4.2 keeps a bulk path for importers.
  for l in countdown(min(level, ix.maxLevel), 0):
    let cands = ix.searchLayer(q, qn, ep, ix.efConstruction, l, nil)
    if cands.len > 0:
      let picked = ix.selectDiverse(cands, ix.m)
      for pr in picked:
        ix.linkOne(slot, pr, l)
        ix.linkOne(pr, slot, l)
      ep = cands[0].s
  if level > ix.maxLevel:
    ix.maxLevel = level
    ix.entry = slot

# ------------------------------------------------------------------ walk

proc searchLayer(ix: VectorIndex, q: ptr float32, qn: float32,
                 ep: int32, ef: int, layer: int,
                 pass: proc (slot: int32): bool {.gcsafe.} = nil): seq[Cand] =
  ## One layer's ef-breadth walk. Results only count nodes that `pass`
  ## (no predicate means every node passes); a node that fails is still
  ## expanded, because the graph routes through it and pruning the walk
  ## at failures would disconnect regions behind them. Termination needs
  ## `ef` *passing* results, so a tombstone-heavy region costs more —
  ## INDEX.md §4.4 says so on purpose.
  inc ix.probes
  var visited = initHashSet[int32]()
  var frontier = initHeapQueue[Cand]()
  ## Results as a max-heap: nearest-first output, worst-on-top eviction.
  var results = initHeapQueue[Cand]()
  var passing = 0

  ## Tombstones are not a filter the caller opts into — they are the
  ## index's own state, and the unfiltered search is exactly the path a
  ## deleted node would otherwise slip through (I8). A dead slot is
  ## expanded but never counted, the same rule a pushed-down filter
  ## follows.
  visited.incl ep
  let epD = ix.distVecs(q, ix.slotPtr(ep), qn, ix.norms[ep])
  frontier.push (epD, ep)
  if not ix.dead[ep] and (pass == nil or pass(ep)):
    results.push (-epD, ep)
    inc passing

  while frontier.len > 0:
    let c = frontier.pop()
    ## Classic termination: the nearest unexpanded candidate is worse
    ## than the worst result, and the results are full. With a filter or
    ## tombstones the results fill later, so the walk runs longer — the
    ## documented cost of both.
    if passing >= ef and c.d > -results[0].d:
      break
    for n in ix.neighborsAt(c.s, layer):
      if n in visited:
        continue
      visited.incl n
      let d = ix.distVecs(q, ix.slotPtr(n), qn, ix.norms[n])
      if passing < ef or d < -results[0].d:
        frontier.push (d, n)
        if not ix.dead[n] and (pass == nil or pass(n)):
          results.push (-d, n)
          inc passing
          if results.len > ef:
            discard results.pop()
            dec passing
  result = @[]
  while results.len > 0:
    let r = results.pop()
    ## -(-d) is the distance; the heap holds negated distances so the
    ## worst sits on top.
    result.add (-r.d, r.s)
  result.sort(proc (a, b: Cand): int =
    if a.d != b.d:
      return (if a.d < b.d: -1 else: 1)
    cmp(a.s, b.s))

# ---------------------------------------------------------------- search

proc greedyDown*(ix: VectorIndex, q: ptr float32, qn: float32,
                ep: int32, layer: int): int32 =
  ## ef = 1 descent: always sideways to a nearer neighbour, never back.
  ## The upper layers exist to make this short.
  var cur = ep
  var curD = ix.distVecs(q, ix.slotPtr(ep), qn, ix.norms[ep])
  while true:
    var improved = false
    for n in ix.neighborsAt(cur, layer):
      let d = ix.distVecs(q, ix.slotPtr(n), qn, ix.norms[n])
      if d < curD:
        curD = d
        cur = n
        improved = true
    if not improved:
      break
  cur

proc search*(ix: VectorIndex, q: openArray[float32], k: int,
             pass: proc (slot: int32): bool {.gcsafe.} = nil): seq[(int64, float32)] =
  ## k nearest as (nodeId, score), best first. `pass` is the pushed-down
  ## filter: a node failing it is expanded but never counted, so the ef
  ## budget lands only on live candidates (INDEX.md §4.3). Scores are
  ## similarity-shaped (I12): cosine similarity, 1/(1+l2), the dot.
  if ix.dim == 0 or ix.entry < 0 or k <= 0:
    return
  if q.len != ix.dim:
    fail(int32(glyErrSql), "query vector of dimension " & $q.len &
                           " does not match the index's " & $ix.dim)
  var buf = newSeq[float32](ix.dim)
  for i in 0 ..< ix.dim:
    buf[i] = q[i]
  let qn = normOf(buf)
  ## Descend greedily through every upper layer, top to layer 1. The
  ## first version descended at layer 1 only and started there from the
  ## global entry — an early, likely-distant node — and the layer-0 walk
  ## inherited the bad region: recall@10 at ef=128 measured 0.77 on
  ## uniform queries while a clustered probe scored 1.0, the exact
  ## signature of an entry-point problem rather than a graph one.
  var ep = ix.entry
  for l in countdown(ix.maxLevel, 1):
    ep = ix.greedyDown(addr buf[0], qn, ep, l)
  ## The walk breadth is at least the caller's k and never below the
  ## index's ef — a k of 1 still searches ef wide, because the walk's
  ## quality is the breadth, not the take.
  let breadth = max(k, ix.ef)
  let cands = ix.searchLayer(addr buf[0], qn, ep, breadth, 0, pass)
  for c in cands:
    if result.len == k:
      break
    if ix.dead[c.s]:
      continue
    let score = case ix.metric
      of mCosine: 1.0'f32 - c.d
      of mL2: 1.0'f32 / (1.0'f32 + c.d)
      of mDot: -c.d
    result.add (ix.ids[c.s], score)

proc scoreVec*(ix: VectorIndex, a, b: openArray[float32]): float32 =
  ## The similarity-shaped score (I12) for two vectors, without a slot: the
  ## read-your-writes overlay scores the transaction's own vectors, which
  ## have no slot yet.
  ##
  ## Bit-identical to what the walk produces for the same pair, by doing the
  ## same arithmetic in the same order: `distVecs` divides the dot by the
  ## product of the precomputed *lengths* and the score is `1 - (1 - sim)`.
  ## Computing `dot / (sqrt(na) * sqrt(nb))` instead — the obvious spelling —
  ## differs in the last ulp, and a last-ulp difference between an overlay
  ## row and the committed row is a row that changes rank the moment the
  ## transaction commits.
  if a.len != b.len:
    return 0.0'f32
  var dot = 0.0'f32
  for i in 0 ..< a.len:
    dot += a[i] * b[i]
  case ix.metric
  of mCosine:
    let la = normOf(a)
    let lb = normOf(b)
    if la == 0.0'f32 or lb == 0.0'f32:
      return 0.0'f32
    let dist = 1.0'f32 - dot / (la * lb)
    1.0'f32 - dist
  of mL2:
    var sq = 0.0'f32
    for i in 0 ..< a.len:
      let t = a[i] - b[i]
      sq += t * t
    1.0'f32 / (1.0'f32 + sq)
  of mDot:
    -(-dot)            ## the walk's distance is `-dot`; the score un-negates

# -------------------------------------------------------------- lifecycle

proc remove*(ix: VectorIndex, nodeId: int64): bool =
  ## Tombstone only (INDEX.md §4.4). The links stay; the walk still
  ## visits the node and pays the cost, which is what vacuum's rebuild
  ## threshold (I14) exists to bound.
  if not ix.slotOf.hasKey(nodeId):
    return false
  let slot = ix.slotOf[nodeId]
  if ix.dead[slot]:
    return false
  ix.dead[slot] = true
  inc ix.deadCount
  true

proc liveCount*(ix: VectorIndex): int =
  ix.ids.len - ix.deadCount

proc tombstoneRatio*(ix: VectorIndex): float =
  if ix.ids.len == 0: 0.0
  else: float(ix.deadCount) / float(ix.ids.len)

proc reset*(ix: VectorIndex) =
  ## Empty, back to the seeded PRNG state — a rebuild after this produces
  ## the same bytes as the first build (I11), because the level draw is
  ## part of the state and it is restored too.
  ix.dim = 0
  ix.ids = @[]
  ix.vecs = @[]
  ix.norms = @[]
  ix.levels = @[]
  ix.dead = @[]
  ix.deadCount = 0
  ix.links0 = @[]
  ix.hi = @[]
  ix.slotOf = initTable[int64, int32]()
  ix.entry = -1'i32
  ix.maxLevel = 0
  ix.rngState = ix.seed

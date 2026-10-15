## glyphes — durable version history (VERSIONING-PLAN.md V0.1)
##
## The revision store: what a node looked like, what a commit changed, and
## the difference between two commits. No file behind it yet — this is the
## structure, so it can be tested against a slow naive oracle before
## anything is written to disk or hooked into a transaction.
##
## The whole feature rests on one field. `CommitRecord.changed` names the
## nodes a commit touched, so `diff` walks two commit-delta sets and never
## scans the graph. That is the difference between a history you can diff
## in microseconds on a 10^6-node graph and a "before" button that costs
## the same as a full comparison.
##
## Nothing here is durable in V0, and nothing here is reachable from a
## query. The reachability is V3; the file is V1. What V0 has to prove is
## that the claim in the PRD §5.1 is true, because everything above it is
## surface over this.

import std/[tables, sets, algorithm, math]
import ./prop

type
  Revision* = object
    ## One state of one node, as of one commit.
    ##
    ## No `nodeId` field: the id is the key of the `byNode` chain this sits on,
    ## so storing it again is 8 bytes per revision carried only to be read
    ## back from where it came from.
    commit*: uint64               ## when this state became true
    ## Only the properties that changed. A revision is a delta, not a copy
    ## (PRD §4.2): a ten-property node whose `status` changes stores one
    ## property, so history grows with *revisions* rather than with
    ## `revisions x node size`.
    props*: seq[(int32, Value)]
    ## Keys *removed* at this revision, carried beside `props` rather than
    ## inside it.
    ##
    ## A removed property is an absence, and an absence is not a `Value`: a
    ## stored `vkNull` and an absent property are different states (CYPHER.md
    ## §3.2 pins that difference as silent data loss when confused, and
    ## txn.nim's `removePropCommon` says the same thing in a comment). So the
    ## revision says which keys are gone, and a fold removes them rather than
    ## overwriting them with a null that would then compare as a live null.
    removed*: seq[int32]
    live*: bool                    ## a delete is a revision, not an erasure

  CommitRecord* = object
    id*: uint64
    parents*: seq[uint64]          ## 1 normally, 2 for a merge, 0 for the root
    branch*: string
    changed*: seq[int64]           ## the load-bearing field
    ## Reserved for the WAL position this commit sits at (PRD §4.3). Nothing
    ## reads it in V0 because nothing here is durable yet, but the field and
    ## `openCommit`'s parameter are part of the shape V1 replays against, and
    ## adding them later is a breaking change to the ABI this produces.
    lsn*: uint64

  OpenCommit* = object
    ## Write-side state for a commit that has not been sealed yet.
    ##
    ## `changed` is deduplicated through a set while the commit is being
    ## filled, and only materialised into `CommitRecord.changed` on seal. That
    ## is the point: a `if nodeId notin rec.changed` linear scan is quadratic
    ## in the nodes a single commit touched, and it was visible — 0.4 s and
    ## 1.6 s for 50k and 100k nodes in one commit, which is also what the
    ## 10^6-node benchmark build was spending its time on. `changed` stays a
    ## `seq` because it is the field `diff` sizes against and scans linearly.
    id*: uint64
    seen*: HashSet[int64]

  NodeState* = object
    ## A node's folded state at some commit. Props are sorted by code so two
    ## states can be compared without either one's write order leaking in.
    live*: bool
    props*: seq[(int32, Value)]

  DiffEntry* = object
    nodeId*: int64
    before*: NodeState
    after*: NodeState

type Revisions* = ref object
  ## `byNode` chains are **oldest-first**, because they are appended and
  ## a revision chain is append-heavy: a node's history only ever grows at
  ## the head. `stateAt` folds them in that order so the newest applicable
  ## revision wins on liveness and on any property it sets. Storing them
  ## the other way round — prepending to keep the head at index 0 — is a
  ## prepend per write for a read that walks once, and the fold then has to
  ## walk backwards and remember which end it started at.
  commits*: seq[CommitRecord]
  byNode*: Table[int64, seq[Revision]]
  ## True while every commit so far has exactly one parent and that parent
  ## is the commit immediately before it — a straight line. Becomes false
  ## forever at the first fork or merge, because a history that has branched
  ## cannot become un-branched. `isAncestorOf` reads this to skip the walk.
  linear*: bool
  ## Commits that have been opened and not yet sealed, keyed by id. A commit
  ## that rolls back is simply never sealed, so it must never appear in
  ## `commits`' ancestry — which is why this is separate from `commits` and
  ## folded in at seal rather than written live.
  open*: Table[uint64, OpenCommit]
  ## The last resolved ancestry and the commit it was for. Ancestry is
  ## immutable once the commit is sealed and `commits.len` has not moved, so
  ## this stays valid and consecutive lookups at one commit — which is what a
  ## caller rendering one revision of the history does — pay for the walk
  ## once instead of per node.
  ancCache*: tuple[commit: uint64, flags: seq[bool], atLen: int]

proc initRevisions*(): Revisions =
  Revisions(commits: @[], byNode: initTable[int64, seq[Revision]](),
            linear: true, open: initTable[uint64, OpenCommit](),
            ancCache: (0'u64, @[], 0))

proc sameValue(a, b: Value): bool =
  ## Value equality, local to this module.
  ##
  ## `cypher/expr.nim` has one, and reaching for it would invert the
  ## layering: `cypher` depends on `store`, so a `store` module importing
  ## it is a cycle. It also would not be the same function — this one
  ## answers "are these two stored states the same", which is a property
  ## comparison, not a query one.
  ##
  ## Every property-legal kind is covered deliberately, because this is the
  ## comparison the entire correctness of `diff` reduces to — an unhandled
  ## kind is not a missing feature, it is a wrong answer, and two were shipped:
  ## `vkBool` answered `true` unconditionally, so a false→true property change
  ## was invisible to `diff`; and `vkVector`/`vkList`/`vkMap` fell through to
  ## the `else`, so an unchanged 768-dim vector was reported as a diff on every
  ## single comparison — which is every diff, on every vector node.
  ##
  ## The recursive calls need the eventual binding, so no `inline` here: this
  ## runs once per property on each side of an id that `diff` reports, not in
  ## its per-revision hot loop.
  if a.kind != b.kind:
    return false
  case a.kind
  of vkNull: true
  of vkBool: a.b == b.b
  of vkInt: a.i == b.i
  of vkFloat: a.f == b.f or (isNaN(a.f) and isNaN(b.f))
  of vkString, vkBytes: a.s == b.s
  of vkVector:
    ## Length first: a 768-dim compare is 3 KB of every call, and most
    ## comparisons are between a changed node and itself.
    if a.dims.len != b.dims.len: return false
    for i in 0 ..< a.dims.len:
      ## NaN != NaN under IEEE, but `diff` asks "did this stored property
      ## change?" — and a NaN that is still NaN did not. Reporting it changed
      ## would make every diff on a NaN-bearing node noisy forever.
      if a.dims[i] != b.dims[i] and
         not (isNaN(a.dims[i]) and isNaN(b.dims[i])):
        return false
    true
  of vkList:
    if a.items.len != b.items.len: return false
    for i in 0 ..< a.items.len:
      if not sameValue(a.items[i], b.items[i]): return false
    true
  of vkMap:
    if a.pairs.len != b.pairs.len: return false
    ## Key order, not position: the codec writes `pairs` in whatever order the
    ## caller built them (prop.nim:232), so two equal maps may compare unequal
    ## positionally. A table on one side rather than a sort on both, because a
    ## sort would be the expensive half of this for no gain.
    var bv = initTable[string, Value](b.pairs.len)
    for (k, val) in b.pairs: bv[k] = val
    for (k, val) in a.pairs:
      if k notin bv or not sameValue(val, bv[k]):
        return false
    true
  of vkNode, vkEdge: a.id == b.id
  of vkPath:
    a.path.nodes == b.path.nodes and a.path.edges == b.path.edges and
      a.path.dirs == b.path.dirs

proc sameState(a, b: NodeState): bool =
  ## Two folded states, equal or not. The whole correctness of `diff`
  ## reduces to this comparison, which is why it is written out rather than
  ## left to a caller.
  if a.live != b.live:
    return false
  if a.props.len != b.props.len:
    return false
  for i in 0 ..< a.props.len:
    if a.props[i][0] != b.props[i][0]:
      return false
    if not sameValue(a.props[i][1], b.props[i][1]):
      return false
  true

# ------------------------------------------------------------------ writing

proc openCommit*(rv: Revisions, branch: string; parents: seq[uint64] = @[],
                  lsn: uint64 = 0'u64): uint64 =
  ## Start a commit and return its id.
  ##
  ## `parents` defaults to empty, which `sealCommit` fills with the current
  ## head — a linear history needs no caller to know what the previous
  ## commit was, and making the caller track that is a way to get the DAG
  ## wrong on the first merge.
  ##
  ## One open commit at a time. This module is single-writer: two concurrent
  ## opens would be handed the same id (ids are `commits.len + 1`), and a
  ## silent id collision between two live transactions is far worse than an
  ## error. V0.2 hooks this to the transaction's begin; the store's own
  ## single-writer lock is what makes that sound.
  if rv.open.len > 0:
    var openId: uint64
    for k in rv.open.keys:
      openId = k
      break
    raise newException(ValueError,
      "revision store: a commit is already open (id " & $openId &
      "); seal or abort it before opening another")
  let id = rv.commits.len.uint64 + 1'u64
  rv.commits.add CommitRecord(id: id, parents: parents, branch: branch,
                              changed: @[], lsn: lsn)
  rv.open[id] = OpenCommit(id: id, seen: initHashSet[int64]())
  id

proc noteRevision*(rv: Revisions, commit: uint64, nodeId: int64,
                   props: seq[(int32, Value)], live: bool,
                   removed: seq[int32] = @[]) =
  ## Record that `nodeId` changed as of `commit`.
  ##
  ## `props` are the keys this revision *set*; `removed` are the keys it
  ## *removed*. They are kept apart because a removal is an absence, not a
  ## value — see `Revision.removed`. Setting a key to `vkNull` is a different
  ## state from removing it and stays distinguishable through the fold.
  ##
  ## The revision goes on the node's chain, and the node id goes on the
  ## commit's `changed` set — once, even if the transaction touched the node
  ## many times. A duplicate id in `changed` does not make `diff` wrong (the
  ## states still compare equal) but it does make it do the work twice, and
  ## `changed` is the field everything else is sized against.
  if commit == 0 or commit > rv.commits.len.uint64:
    return
  rv.byNode.mgetOrPut(nodeId, @[]).add Revision(commit: commit,
                                               props: props, removed: removed,
                                               live: live)
  if commit in rv.open:
    rv.open[commit].seen.incl nodeId

proc sealCommit*(rv: Revisions, commit: uint64) =
  ## Close a commit, defaulting its parents to the previous commit. Called
  ## once the transaction has committed: a commit that is still open when
  ## its transaction rolls back never becomes visible, and a rolled-back
  ## commit must not be in the chain at all.
  if commit == 0 or commit > rv.commits.len.uint64:
    return
  let rec = addr rv.commits[commit.int - 1]
  if rec.parents.len == 0 and commit > 1:
    rec.parents = @[commit - 1'u64]
  ## Collect the deduplicated ids into the order `diff` will scan them. Sorted
  ## rather than insertion order: `diff` sorts the union of two sides anyway,
  ## and a sorted `changed` makes a per-commit replay deterministic instead
  ## of transactional-write-order dependent.
  if commit in rv.open:
    rec.changed = @[]
    for id in rv.open[commit].seen:
      rec.changed.add id
    rec.changed.sort()
    rv.open.del(commit)
  ## Seal is the point at which the parent list is final, so this is the
  ## first moment `linear` can be judged for this commit. The genesis commit
  ## has no parent at all and is still straight-line; only commits after it
  ## must point at their immediate predecessor. Anything else — a fork, or a
  ## merge's two parents — switches the class of history.
  let bent =
    if commit == 1: rec.parents.len != 0
    else: rec.parents.len != 1 or rec.parents[0] != commit - 1'u64
  if bent:
    rv.linear = false

proc abortCommit*(rv: Revisions, commit: uint64) =
  ## Roll back an open commit: erase it and every revision it recorded, as if
  ## it had never been opened. `sealCommit` promises that a rolled-back
  ## commit "must not be in the chain at all" — this procedure is what keeps
  ## that promise. Without it the promise is words over code that cannot
  ## fulfil it: `openCommit` appends to `commits` and `noteRevision` writes to
  ## `byNode` immediately, so an unsealed commit would otherwise burn its id,
  ## become an extra parentless root, and leak its revisions into every fold
  ## — including the linear `<=` fast path, which would apply them by id.
  ##
  ## Aborts are rare (a failed transaction), so the full cleanup pass is
  ## acceptable; the hot path never pays for it.
  if commit notin rv.open:
    raise newException(ValueError,
      "revision store: commit " & $commit & " is not open; only an open " &
      "commit can be aborted")
  ## Walk the aborted commit's revisions back out of every node chain.
  ## `noteRevision` appends, so the aborted commit's revisions are at the
  ## tails; filtering the whole chain is simpler than tracking positions and
  ## is correct regardless.
  var emptied: seq[int64] = @[]
  for nid, chain in rv.byNode.mpairs:
    var kept: seq[Revision] = @[]
    for rev in chain:
      if rev.commit != commit:
        kept.add rev
    if kept.len == 0 and chain.len > 0:
      emptied.add nid
    chain = kept
  for nid in emptied:
    rv.byNode.del nid
  ## Drop the commit record. It is the tip in practice — the single-open
  ## guard means no commit was opened after it — so truncating restores the
  ## id. The mid-log case (concurrent opens) is guarded against at open, but
  ## blanking rather than dropping keeps the log dense even if it ever fires.
  if commit == rv.commits.len.uint64:
    rv.commits.setLen(rv.commits.len - 1)
  else:
    rv.commits[commit.int - 1] = CommitRecord(id: commit)
  rv.open.del(commit)
  ## `linear` is judged at seal, and the single-open guard means the commit
  ## that bent it is already sealed before this one opened — so under the
  ## current rules `linear` cannot be false here. The re-judgement is kept
  ## anyway, as a guard against judgement ever moving earlier (e.g. to open):
  ## if that happens, abort must still be able to straighten the history.
  rv.linear = true
  for i in 0 ..< rv.commits.len:
    let c = uint64(i + 1)
    let rec = rv.commits[i]
    let bent = if c == 1: rec.parents.len != 0
               else: rec.parents.len != 1 or rec.parents[0] != c - 1'u64
    if bent:
      rv.linear = false
      break
  ## The ancestry cache is anchored to `commits.len`; both just changed.
  rv.ancCache = (0'u64, @[], 0)

# ------------------------------------------------------------------ reading

proc commitAt*(rv: Revisions, id: uint64): CommitRecord =
  ## The commit record, or a zero record for an id this history has not
  ## reached. A zero record rather than an exception: `diff` compares two
  ## caller-supplied ids, and one of them being from another database is a
  ## question with an empty answer, not a crash.
  if id == 0 or id > rv.commits.len.uint64:
    return CommitRecord()
  rv.commits[id.int - 1]
proc ancestorSet(rv: Revisions, commit: uint64): seq[bool] =
  ## A flag per commit id, set for `commit` and every ancestor of it.
  ##
  ## Built once per `diff` and reused, so the per-revision ancestry question
  ## becomes an array read. A flat array rather than a hash set: the ids are
  ## dense and already 1-based sequential, and the point of this is to make
  ## the O(depth) walk cheap enough not to matter — a `HashSet[uint64]` spent
  ## more time hashing than the walk itself.
  result = newSeq[bool](rv.commits.len + 1)
  ## Every parent, not just `parents[0]` — see `isAncestorOf`. The already-set
  ## flag is the visited test, which is what bounds this at O(commits) even
  ## on a tangled DAG, and what makes a cycle in corrupt data terminate.
  var stack: seq[uint64] = @[commit]
  while stack.len > 0:
    let cur = stack[^1]
    setLen(stack, stack.len - 1)
    if cur == 0 or cur.uint64 > rv.commits.len.uint64:
      continue
    if result[cur.int]:
      continue
    result[cur.int] = true
    for p in rv.commits[cur.int - 1].parents:
      stack.add p


proc mergeBase*(rv: Revisions, a, b: uint64): uint64 =
  ## The best common ancestor of two commits, 0 if there is none.
  ##
  ## Written as the general ancestor-intersection rather than `min(a,b)`,
  ## because on a linear history `min` is the same answer and it is the
  ## wrong answer the moment a branch exists. Ancestry is resolved over every
  ## parent of every commit on both sides, not just the first.
  ##
  ## "Best" is approximated: this returns the *highest-id* common ancestor.
  ## The true merge base on a DAG is the one that is not an ancestor of any
  ## other common ancestor, which needs per-commit reachability metadata
  ## (generation numbers) that V0 does not have. What `diff` requires is
  ## only that the answer be *a* common ancestor: a base that is too old
  ## costs extra work, while a base that is not a common ancestor at all
  ## loses commits on one side and silently answers the wrong question. The
  ## high-id choice errs toward newer, so it may over-report, never under.
  if rv.linear:
    return min(a, b)
  let ancA = ancestorSet(rv, a)
  let ancB = ancestorSet(rv, b)
  for i in countdown(min(ancA.len, ancB.len) - 1, 1):
    if ancA[i] and ancB[i]:
      return uint64(i)
  0'u64

proc commitsOnPath*(rv: Revisions, base, head: uint64): seq[CommitRecord] =
  ## The commits reachable from `head` but not from `base`, newest first.
  ##
  ## On a straight-line history this is exactly the commits between them and
  ## costs the distance between them, not the length of the history. On a
  ## merge it is both branches that reach `head` past `base` — a merge brings
  ## in the merged branch's commits, and a diff that reported only one side
  ## would be a diff of a history the repository does not have.
  ##
  ## Newest first by commit id, which is a total order regardless of branch
  ## shape; there is no single path order once a merge exists.
  let ancHead = ancestorSet(rv, head)
  let ancBase = ancestorSet(rv, base)
  for i in countdown(rv.commits.len, 1):
    ## Reachable from the head but not from the base. The length guards are
    ## for a commit id past the end of the log: the walk stops there, so a
    ## shorter array means "not an ancestor", which is the safe answer.
    if i < ancHead.len and ancHead[i] and not (i < ancBase.len and ancBase[i]):
      result.add rv.commits[i - 1]


proc ancestorSetCached(rv: Revisions, commit: uint64): seq[bool] =
  ## `ancestorSet`, memoised on the last commit asked for.
  ##
  ## The single-node read path (`stateAt`) is the one that wants this: without
  ## it each call allocated an array sized to the whole history, so one lookup
  ## on a 100k-commit branched history cost 100 KB and ~5 ms — worse than the
  ## walk it replaced. A caller rendering a whole revision asks for the same
  ## commit over and over, and this makes that one walk.
  if rv.ancCache.commit == commit and rv.ancCache.atLen == rv.commits.len and
     commit <= rv.commits.len.uint64:
    return rv.ancCache.flags
  rv.ancCache = (commit, ancestorSet(rv, commit), rv.commits.len)
  rv.ancCache.flags

proc isAncestor(anc: seq[bool], commit: uint64): bool {.inline.} =
  commit.uint64 < anc.len.uint64 and anc[commit.int]


proc isAncestorOf*(rv: Revisions, maybe, descendant: uint64): bool =
  ## Walk `descendant`'s ancestry looking for `maybe`.
  ##
  ## On a straight-line history the walk is pure overhead: commit ids are
  ## assigned in parent order, so `maybe` is an ancestor exactly when
  ## `maybe <= descendant`. Once a branch exists the two tests genuinely
  ## disagree and only real ancestry is correct, which is why this tests
  ## `linear` rather than optimising unconditionally.
  if rv.linear:
    return maybe <= descendant
  ## Answered through `ancestorSetCached` rather than its own walk, so there
  ## is exactly one ancestry walker in the module: a hand-rolled stack here
  ## had no visited set, which on cyclic (corrupt) data looped forever and on
  ## merge-heavy DAGs revisited shared ancestors without bound. The cached
  ## set is bounded by the history and terminates on a cycle.
  isAncestor(ancestorSetCached(rv, descendant), maybe)

proc foldStateIn(rv: Revisions, nodeId: int64, anc: seq[bool],
                 live: var bool, props: var Table[int32, Value]) {.inline.} =
  ## Fold a node's revision chain into caller-owned buffers, testing
  ## applicability against an already-resolved ancestor set.
  ##
  ## Ancestry on a branched history costs one step per commit in the history,
  ## and `diff` asks the question once per revision per candidate node — that
  ## is O(changed x depth), and it is the difference between a diff that holds
  ## up on a mature history and one that does not (measured at 3588x for a
  ## 50000x deeper history). Resolving each head once makes it O(changed +
  ## depth).
  live = false
  props.clear()
  let chain = rv.byNode.getOrDefault(nodeId, @[])
  for rev in chain:
    if isAncestor(anc, rev.commit):
      live = rev.live
      for (k, v) in rev.props:
        props[k] = v
      for k in rev.removed:
        props.del k

proc foldState(rv: Revisions, nodeId: int64, commit: uint64,
               live: var bool, props: var Table[int32, Value]) {.inline.} =
  ## Single-lookup fold (the `stateAt` path). A straight-line history answers
  ## per-revision with `<=` and never materialises a set; a branched one
  ## resolves the head's ancestry through the cache, so a run of lookups at one
  ## commit pays once — see `ancestorSetCached`.
  ##
  ## An id past the head names a commit this history has not reached, so the
  ## answer is the empty state — the same "empty answer, not a crash" contract
  ## as `commitAt`'s zero record, and the answer the branched path already
  ## gives through its empty ancestor flags. Without this guard the linear
  ## `<=` fast path applied every revision and reported the node's latest
  ## state, so one question had two answers depending on the shape of the
  ## history.
  if commit > rv.commits.len.uint64:
    live = false
    props.clear()
    return
  if rv.linear:
    live = false
    props.clear()
    let chain = rv.byNode.getOrDefault(nodeId, @[])
    for rev in chain:
      if rev.commit <= commit:
        live = rev.live
        for (k, v) in rev.props:
          props[k] = v
        for k in rev.removed:
          props.del k
  else:
    foldStateIn(rv, nodeId, ancestorSetCached(rv, commit), live, props)

proc propsSorted(props: Table[int32, Value]): seq[(int32, Value)] =
  ## Sorted by code so two states compare without write order leaking in.
  result = newSeqOfCap[(int32, Value)](props.len)
  for k, v in props:
    result.add (k, v)
  result.sort(proc (x, y: (int32, Value)): int = cmp(x[0], y[0]))

proc sameStateTables(a, b: Table[int32, Value]): bool =
  ## Equality over the fold buffers, before they are materialised into
  ## sorted seqs. Lets `diff` skip the sort and the two `NodeState`
  ## allocations for every id that did not actually change.
  if a.len != b.len:
    return false
  for k, v in a:
    if k notin b or not sameValue(v, b[k]):
      return false
  true

proc stateAt*(rv: Revisions, nodeId: int64, commit: uint64): NodeState =
  ## The node's state as of `commit`, by folding every revision at or before
  ## it. Cost is the node's chain length — not the graph size, which is the
  ## whole claim (PRD §5.2).
  ##
  ## The fold runs oldest-to-newest, so the newest applicable revision
  ## decides liveness and wins on any property it sets. `live` is carried on
  ## every revision rather than only on deletes so that "recreated after a
  ## delete" is a state the fold can express.
  ##
  ## "Applicable" is ancestry, not `commit <= target`. On a linear history
  ## the two are the same test. On a branched one they are not, and the
  ## difference is the whole point of having branches: a change committed
  ## on `feature` is not part of `main` unless `main` forked after it. A
  ## plain `<=` applies every revision ever written to every later commit,
  ## which makes two branches one history with extra steps — and `main`
  ## would silently acquire `feature`'s work (PRD §3.3).
  result.props = @[]
  var live = false
  var props = initTable[int32, Value]()
  foldState(rv, nodeId, commit, live, props)
  result.live = live
  result.props = propsSorted(props)

proc diff*(rv: Revisions, a, b: uint64): seq[DiffEntry] =
  ## Which nodes differ between commit `a` and commit `b`.
  ##
  ## The ids come from the two `changed` sets between the merge base and each
  ## side; each node's two states come from its revision chain. No label
  ## scan, no traversal, no index — the cost is the commits between them
  ## plus the nodes that differ, which is what G2 asserts on a 10^6-node
  ## graph.
  ##
  ## A node touched on both sides but in the same state at `a` and `b` is
  ## not reported: it was changed and changed back, and a diff of two
  ## commits is a question about those two commits, not about the path
  ## between them.
  let base = mergeBase(rv, a, b)
  ## Resolved once for the whole diff and reused for both the id collection and
  ## the folds: three arrays, not six, and one pair of fold buffers rather than
  ## two tables per `stateAt` call. See `foldStateIn` and `propsSorted`.
  let ancA = ancestorSet(rv, a)
  let ancB = ancestorSet(rv, b)
  let ancBase = ancestorSet(rv, base)
  var ids = initHashSet[int64]()
  for anc in [ancA, ancB]:
    for i in 1 .. rv.commits.len:
      if i < anc.len and anc[i] and not (i < ancBase.len and ancBase[i]):
        for id in rv.commits[i - 1].changed:
          ids.incl id
  var sorted: seq[int64] = @[]
  for id in ids:
    sorted.add id
  sorted.sort()
  var liveA, liveB: bool
  var propsA = initTable[int32, Value]()
  var propsB = initTable[int32, Value]()
  for id in sorted:
    foldStateIn(rv, id, ancA, liveA, propsA)
    foldStateIn(rv, id, ancB, liveB, propsB)
    if liveA == liveB and sameStateTables(propsA, propsB):
      continue
    result.add DiffEntry(nodeId: id,
                         before: NodeState(live: liveA, props: propsSorted(propsA)),
                         after: NodeState(live: liveB, props: propsSorted(propsB)))

export sameValue, sameState
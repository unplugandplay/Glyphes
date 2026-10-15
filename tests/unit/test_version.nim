## glyphes — version history, V0 (VERSIONING-PLAN.md V0.4, gate G1)
##
## The test that decides whether this feature is worth building. `diff`
## walks the commits between two points and reads each node's revision
## chain; the oracle below rebuilds both states the dumb way — walk every
## node, replay every revision — and the two must agree exactly.
##
## The oracle is intentionally the thing the implementation is not allowed
## to be. It shares no code with `revision.nim` beyond the types, and it
## is O(history x nodes) where `diff` is O(nodes changed). If they ever
## disagree, the fast one is wrong, and a fast wrong diff is the worst
## outcome this feature has — it is a tool people trust to tell them what
## changed.

import std/unittest
import std/[random, algorithm, sets, tables, sequtils]
import ../../src/store/prop
import ../../src/store/revision

const
  Nodes = 200

proc sameProps(a, b: seq[(int32, Value)]): bool =
  ## `Value` is a `case` object, so `==` on it is a compile error rather
  ## than a silent identity comparison — the compiler will not synthesise a
  ## comparison across variants. Property lists are therefore compared here,
  ## through the store's own value equality.
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i][0] != b[i][0]:
      return false
    if not sameValue(a[i][1], b[i][1]):
      return false
  true

proc key(code: int32): int32 = code
proc vInt(i: int64): Value = Value(kind: vkInt, i: i)
proc vStr(s: string): Value = Value(kind: vkString, s: s)
proc vBool(b: bool): Value = Value(kind: vkBool, b: b)
proc vFloat(f: float64): Value = Value(kind: vkFloat, f: f)
proc vNull: Value = Value(kind: vkNull)
proc vVector(d: seq[float32]): Value = Value(kind: vkVector, dims: d)
proc vList(d: seq[Value]): Value = Value(kind: vkList, items: d)
proc vMap(p: seq[(string, Value)]): Value = Value(kind: vkMap, pairs: p)
# ------------------------------------------------------------ the oracle

type Oracle = object
  ## Rebuilt from scratch at a commit, with no knowledge of `Revisions`'
  ## indexing. Deliberately naive: for each node it replays that node's
  ## whole revision list from the beginning and keeps the last revision at
  ## or before the commit.
  commits: seq[seq[(int64, seq[(int32, Value)], bool)]]
  order: seq[int64]

proc buildOracle(rv: Revisions): Oracle =
  result.order = @[]
  var nodeIds: seq[int64] = @[]
  for nid, _ in rv.byNode.pairs:
    nodeIds.add nid
  nodeIds.sort()
  result.order = nodeIds
  for i in 0 ..< rv.commits.len:
    result.commits.add @[]

proc oracleState(o: Oracle, commitIdx: int, nodeId: int64,
                 rv: Revisions): NodeState =
  ## Replay from revision 0. `commitIdx` is 0-based because that is how
  ## the oracle indexes commits; the engine's ids are 1-based.
  var props = initTable[int32, Value]()
  var live = false
  var any = false
  let chain = rv.byNode.getOrDefault(nodeId, @[])
  for rev in chain:                      # oldest first in this walk
    if rev.commit <= commitIdx.uint64 + 1:
      any = true
      live = rev.live
      for (k, v) in rev.props:
        props[k] = v
  result.live = live
  var keys: seq[int32] = @[]
  for k in props.keys: keys.add k
  keys.sort()
  for k in keys: result.props.add (k, props[k])

proc oracleDiff(o: Oracle, rv: Revisions, a, b: uint64): seq[int64] =
  ## Every node in the history, compared. No `changed` set, no chain walk
  ## shortcut — if `diff` misses a node, this finds it.
  var seen = initHashSet[int64]()
  for nid in o.order:
    if nid in seen:
      continue
    seen.incl nid
    let sa = o.oracleState(a.int - 1, nid, rv)
    let sb = o.oracleState(b.int - 1, nid, rv)
    if not sameState(sa, sb):
      result.add nid

proc ancestorsByWalk(rv: Revisions, commit: uint64): seq[bool] =
  ## Ancestry computed by the most obvious possible route: start at `commit`
  ## and follow parents to the root. It reads the same commit log the
  ## implementation does and shares no code with `Revisions.ancestorSet`,
  ## which is the point — an oracle that called the implementation would only
  ## be testing that the implementation agrees with itself.
  ##
  ## Every parent, on a stack: the implementation walks all parents of every
  ## commit (that is what makes merges work), so an oracle that followed only
  ## `parents[0]` would share the exact assumption a regression would break,
  ## and would bless it. Slow is fine here; the oracle exists to be trusted.
  result = newSeq[bool](rv.commits.len + 1)
  var stack: seq[uint64] = @[commit]
  while stack.len > 0:
    let cur = stack[^1]
    setLen(stack, stack.len - 1)
    if cur == 0 or cur.uint64 > rv.commits.len.uint64 or result[cur.int]:
      continue
    result[cur.int] = true
    for p in rv.commits[cur.int - 1].parents:
      stack.add p

proc oracleStateAncestry(o: Oracle, rv: Revisions, commit: uint64,
                         nodeId: int64): NodeState =
  ## As `oracleState`, but a revision applies only if its commit is an
  ## ancestor of `commit` — not merely numbered below it.
  let anc = ancestorsByWalk(rv, commit)
  var props = initTable[int32, Value]()
  var live = false
  for rev in rv.byNode.getOrDefault(nodeId, @[]):
    if rev.commit.uint64 < anc.len.uint64 and anc[rev.commit.int]:
      live = rev.live
      for (k, v) in rev.props:
        props[k] = v
      for k in rev.removed:
        props.del k
      for k in rev.removed:
        props.del k
  result.live = live
  var keys: seq[int32] = @[]
  for k in props.keys: keys.add k
  keys.sort()
  for k in keys: result.props.add (k, props[k])

proc oracleDiffAncestry(o: Oracle, rv: Revisions, a, b: uint64): seq[int64] =
  ## Every node in the history, compared, with ancestry-resolved applicability.
  var seen = initHashSet[int64]()
  for nid in o.order:
    if nid in seen:
      continue
    seen.incl nid
    if not sameState(oracleStateAncestry(o, rv, a, nid),
                     oracleStateAncestry(o, rv, b, nid)):
      result.add nid

# ---------------------------------------------------------------- suite

suite "V0 the revision store":
  test "an empty history diffs to nothing":
    let rv = initRevisions()
    let c = rv.openCommit("main")
    rv.sealCommit(c)
    check rv.diff(1, 1).len == 0
    check rv.mergeBase(1, 1) == 1

  test "a property change is a revision, and diff names the node":
    let rv = initRevisions()
    var c = rv.openCommit("main")
    rv.noteRevision(c, 7, @[(key(1), vInt(10))], true)
    rv.sealCommit(c)
    var d = rv.openCommit("main")
    rv.noteRevision(d, 7, @[(key(1), vInt(20))], true)
    rv.sealCommit(d)

    let entries = rv.diff(c, d)
    check entries.len == 1
    check entries[0].nodeId == 7
    check sameProps(entries[0].before.props, @[(key(1), vInt(10))])
    check sameProps(entries[0].after.props, @[(key(1), vInt(20))])

  test "a node changed and changed back is not reported":
    let rv = initRevisions()
    var c = rv.openCommit("main")
    rv.noteRevision(c, 7, @[(key(1), vInt(10))], true)
    rv.sealCommit(c)
    var d = rv.openCommit("main")
    rv.noteRevision(d, 7, @[(key(1), vInt(20))], true)
    rv.sealCommit(d)
    var e = rv.openCommit("main")
    rv.noteRevision(e, 7, @[(key(1), vInt(10))], true)
    rv.sealCommit(e)
    ## c and e agree, so nothing changed between them.
    check rv.diff(c, e).len == 0
    ## c and d do not.
    check rv.diff(c, d).len == 1

  test "a delete is a revision, and history survives it":
    let rv = initRevisions()
    var c = rv.openCommit("main")
    rv.noteRevision(c, 7, @[(key(1), vInt(10))], true)
    rv.sealCommit(c)
    var d = rv.openCommit("main")
    rv.noteRevision(d, 7, @[], false)
    rv.sealCommit(d)

    check rv.stateAt(7, c).live
    check rv.stateAt(7, d).live == false
    let entries = rv.diff(c, d)
    check entries.len == 1
    check entries[0].before.live
    check entries[0].after.live == false
    ## And the node can come back, because the delete was not an erasure.
    var e = rv.openCommit("main")
    rv.noteRevision(e, 7, @[], true)
    rv.sealCommit(e)
    check rv.stateAt(7, e).live
    check sameProps(rv.stateAt(7, e).props, @[(key(1), vInt(10))])

  test "a multi-property revision folds only what it changed":
    let rv = initRevisions()
    var c = rv.openCommit("main")
    rv.noteRevision(c, 7, @[(key(1), vInt(1)), (key(2), vStr("a"))], true)
    rv.sealCommit(c)
    var d = rv.openCommit("main")
    ## Only property 2 changes. Property 1 must survive the fold.
    rv.noteRevision(d, 7, @[(key(2), vStr("b"))], true)
    rv.sealCommit(d)
    let st = rv.stateAt(7, d)
    check sameProps(st.props, @[(key(1), vInt(1)), (key(2), vStr("b"))])

  test "merge base is the fork on a branched history":
    let rv = initRevisions()
    var root = rv.openCommit("main")
    rv.sealCommit(root)
    var a = rv.openCommit("feature", @[root])   # branch off root
    rv.noteRevision(a, 1, @[(key(1), vInt(1))], true)
    rv.sealCommit(a)
    ## `b` continues main, so its parent is root — not the previous
    ## commit, which is `a` and sits on the other branch. `sealCommit`'s
    ## default assumes a linear history, so a fork says where it forks from.
    var b = rv.openCommit("main", @[root])
    rv.noteRevision(b, 2, @[(key(1), vInt(2))], true)
    rv.sealCommit(b)

    ## a's parent defaults to the previous commit, which is root here.
    check rv.mergeBase(a, b) == root
    ## Two nodes differ between the branch heads — node 1 on `feature`,
    ## node 2 on `main`. Node 1 is the interesting one: its change was
    ## committed *before* `b` in id order, and a `<=` test would wrongly
    ## report it as already present on `main`.
    let entries = rv.diff(a, b)
    check entries.len == 2
    check entries[0].nodeId == 1
    check entries[1].nodeId == 2
    ## And `main` does not see `feature`'s work.
    check rv.stateAt(1, b).live == false
    check rv.stateAt(1, a).live

  test "diff notices a change of every property-legal kind":
    ## `sameValue` is what the whole correctness of `diff` reduces to, and it
    ## was wrong on two of these: `vkBool` compared equal to everything (so a
    ## false→true property change was invisible), and `vkVector`/`vkList`/`vkMap`
    ## compared unequal to *themselves* (so an unchanged vector was reported as a
    ## diff every time — which is every diff, on every vector node). Neither was
    ## reachable from the tests above, which only ever write ints and strings.
    ##
    ## Both directions are asserted per kind: equal must compare equal, and
    ## different must compare unequal. A `sameValue` that answered `false` for
    ## everything would pass the second half and report every node as changed
    ## forever, so only the first half catches that.
    let cases: seq[(string, Value, Value)] = @[
      ("bool",   vBool(true),                  vBool(false)),
      ("int",    vInt(7),                      vInt(8)),
      ("float",  vFloat(1.5),                  vFloat(2.5)),
      ("string", vStr("x"),                    vStr("y")),
      ("null",   vNull(),                      vNull()),
      ("vector", vVector(@[1.0'f32, 2.0'f32]), vVector(@[3.0'f32, 2.0'f32])),
      ("list",   vList(@[vInt(1), vInt(2)]),   vList(@[vInt(1), vInt(3)])),
      ("map",    vMap(@[("a", vInt(1)), ("b", vStr("z"))]),
                   vMap(@[("a", vInt(1)), ("b", vStr("q"))])),
    ]

    for entry in cases:
      let name = entry[0]
      let val = entry[1]
      let other = entry[2]
      ## equal → equal
      check sameValue(val, val) == true
      check sameProps(@[(key(1), val)], @[(key(1), val)]) == true
      ## different → unequal, except for `null`, which has only one value
      if name != "null":
        check sameValue(val, other) == false

    ## The two structural kinds need order-independence rather than a
    ## position-by-position check: the codec writes map pairs in caller order
    ## (prop.nim), so the same map can arrive in two shapes.
    check sameValue(vMap(@[("a", vInt(1)), ("b", vInt(2))]),
                    vMap(@[("b", vInt(2)), ("a", vInt(1))])) == true
    check sameValue(vMap(@[("a", vInt(1)), ("b", vInt(2))]),
                    vMap(@[("a", vInt(1)), ("b", vInt(3))])) == false
    ## ...but not so loosely that a different key set compares equal.
    check sameValue(vMap(@[("a", vInt(1)), ("b", vInt(2))]),
                    vMap(@[("c", vInt(1)), ("d", vInt(2))])) == false

  test "diff notices a bool and a vector change end to end":
    ## The same two bugs, exercised through `diff` rather than `sameValue`,
    ## because a test at the comparison layer would pass with the call site
    ## broken. This is the shape the feature was silently getting wrong.
    let rv = initRevisions()
    let c1 = rv.openCommit("main")
    rv.noteRevision(c1, 1, @[(key(1), vBool(true))], true)
    rv.noteRevision(c1, 2, @[(key(1), vVector(@[1.0'f32, 2.0'f32]))], true)
    rv.sealCommit(c1)
    let c2 = rv.openCommit("main")
    rv.noteRevision(c2, 1, @[(key(1), vBool(false))], true)
    rv.sealCommit(c2)
    let c3 = rv.openCommit("main")
    rv.noteRevision(c3, 2, @[(key(1), vVector(@[1.0'f32, 2.0'f32]))], true)
    rv.sealCommit(c3)

    let d = rv.diff(c1, c2)
    check d.len == 1
    check d[0].nodeId == 1                 # the bool flip is visible

    ## And the unchanged vector is *not* re-reported. `c3` rewrites node 2's
    ## vector with the identical value it already held, while `c2` — sitting
    ## between `c1` and `c3` — flips node 1's bool. So this diff must name node
    ## 1 and must not name node 2, which is the whole point: the vector was
    ## written and is unchanged, so it is not a change.
    let d3 = rv.diff(c1, c3)
    check d3.len == 1
    check d3[0].nodeId == 1

  test "a merge sees the merged-in branch":
    ## The defect this exists for: every ancestry walk followed `parents[0]`
    ## only, so a merge commit's second parent was dead data. The merge then
    ## reported the merged branch as *absent* — `stateAt` said its nodes were
    ## deleted, and `diff` across the merge omitted everything it did. Nothing
    ## detected it because the API accepts two parents and silently uses one.
    ##
    ##   main:  1 ─────── 3 ──┐
    ##   feature: └── 2 ──────┘ 4 (merge, parents [3, 2])
    let rv = initRevisions()
    let m1 = rv.openCommit("main")
    rv.noteRevision(m1, 1, @[(key(1), vInt(1))], true)
    rv.sealCommit(m1)

    let f2 = rv.openCommit("feature", @[1'u64])
    rv.noteRevision(f2, 2, @[(key(1), vInt(2))], true)
    rv.sealCommit(f2)

    let m3 = rv.openCommit("main", @[1'u64])
    rv.noteRevision(m3, 3, @[(key(1), vInt(3))], true)
    rv.sealCommit(m3)

    let mg = rv.openCommit("main", @[m3, f2])
    rv.sealCommit(mg)

    check rv.commits[mg.int - 1].parents == @[3'u64, 2'u64]

    ## The merge is the head, so all three nodes are live and readable.
    for n in 1 .. 3:
      check rv.stateAt(n.int64, mg).live == true
    ## ...and node 2's *value* survived the merge, not just its liveness.
    check sameProps(rv.stateAt(2, mg).props, @[(key(1), vInt(2))])

    ## `isAncestorOf` reaches through the second parent.
    check rv.isAncestorOf(f2, mg) == true
    check rv.isAncestorOf(m3, mg) == true
    check rv.isAncestorOf(1, mg) == true

    ## Merge base. `m3` and `f2` fork at 1; the merge is descended from both,
    ## so with either side the base is that side itself. (Not "best" in the
    ## DAG-theoretic sense — this picks the highest common id — but always a
    ## common ancestor, which is all `diff` needs to be correct.)
    check rv.mergeBase(m3, f2) == 1
    check rv.mergeBase(mg, f2) == f2
    check rv.mergeBase(mg, m3) == m3

    ## The assertion the defect failed: the merge brought the feature branch's
    ## work in. Diffing the fork point against the merge must name node 2,
    ## which only exists because `mg`'s *second* parent was followed. With
    ## parents[0]-only, commit 2 was unreachable and this was empty.
    check rv.diff(m3, mg).mapIt(it.nodeId) == @[2'i64]

    ## And the other direction: `feature`'s head versus the merge is only what
    ## `main` did after the fork, not the branch's own work.
    check rv.diff(f2, mg).mapIt(it.nodeId) == @[3'i64]

  test "changed is deduplicated once per node and is sorted":
    ## The dedup used to be `if nodeId notin rec.changed` — a linear scan, so
    ## quadratic in the nodes one commit touched. The set-based path is not
    ## observable in the output, which is why this asserts the output shape:
    ## one entry per node, in sorted order, regardless of write order.
    let rv = initRevisions()
    let c = rv.openCommit("main")
    rv.noteRevision(c, 7, @[(key(1), vInt(1))], true)
    rv.noteRevision(c, 3, @[(key(1), vInt(2))], true)
    rv.noteRevision(c, 7, @[(key(1), vInt(3))], true)
    rv.noteRevision(c, 9, @[(key(1), vInt(4))], true)
    rv.noteRevision(c, 3, @[(key(1), vInt(5))], true)
    rv.sealCommit(c)
    check rv.commits[c.int - 1].changed == @[3'i64, 7'i64, 9'i64]

  test "float and vector equality treats NaN as equal to itself":
    ## IEEE says NaN != NaN, but `diff` asks "did this stored property
    ## change?" — and a NaN that is still NaN did not. Reporting it changed
    ## every time would make every diff on a NaN-bearing node noisy forever.
    check sameValue(vFloat(NaN), vFloat(NaN)) == true
    check sameValue(vFloat(1.0), vFloat(NaN)) == false
    check sameValue(vFloat(NaN), vFloat(1.0)) == false
    check sameValue(vVector(@[float32(NaN)]), vVector(@[float32(NaN)])) == true
    check sameValue(vVector(@[1.0'f32]), vVector(@[float32(NaN)])) == false
    ## NaN is handled inside a list too, through the recursive compare.
    check sameValue(vList(@[vFloat(NaN)]), vList(@[vFloat(NaN)])) == true
    check sameValue(vList(@[vFloat(NaN)]), vList(@[vFloat(1.0)])) == false

  test "an aborted commit leaves no trace":
    ## `sealCommit` documents that "a rolled-back commit must not be in the
    ## chain at all" — and this is the test that the promise is kept, because
    ## `abortCommit` is the code that keeps it. Without this, an unsealed
    ## commit would burn its id, become an extra parentless root, and leak its
    ## revisions into every fold — including the linear `<=` fast path.
    let rv = initRevisions()
    let c1 = rv.openCommit("main")
    rv.noteRevision(c1, 1, @[(key(1), vInt(1))], true)
    rv.sealCommit(c1)

    let fork = rv.openCommit("feature", @[c1])
    rv.noteRevision(fork, 2, @[(key(1), vInt(2))], true)
    ## `linear` is only judged at seal, so the open fork has not bent it yet;
    ## what matters is the state after the abort.

    rv.abortCommit(fork)
    check rv.commits.len == 1    # the commit is gone, its id un-burned
    check rv.linear              # the history is straight
    check rv.stateAt(2, c1).live == false   # its revision leaked nowhere
    check 2'i64 notin rv.byNode             # not even as an empty chain

    ## The log is reusable: the next commit takes the aborted one's id.
    let c2 = rv.openCommit("main")
    check c2 == fork
    rv.noteRevision(c2, 3, @[(key(1), vInt(3))], true)
    rv.sealCommit(c2)
    check rv.linear
    check rv.diff(c1, c2).mapIt(it.nodeId) == @[3'i64]

  test "opening a second commit is an error":
    ## Ids are `commits.len + 1`, so two concurrent opens would collide
    ## silently. A store that corrupts two transactions is worse than one
    ## that refuses, so the second open raises.
    let rv = initRevisions()
    let c1 = rv.openCommit("main")
    expect ValueError:
      discard rv.openCommit("other")
    rv.sealCommit(c1)
    check rv.linear

  test "a commit id past the head answers empty, on any history shape":
    ## `commitAt` treats an unreached id as a question with an empty answer;
    ## `stateAt` must too, whichever path the history's shape selects. Before
    ## the bound went into `foldState`, the linear `<=` fast path applied
    ## every revision for an out-of-range id and reported the node's latest
    ## state, while a branched history answered empty — one question, two
    ## answers, picked by the shape of the history rather than the question.
    for bent in [false, true]:
      let rv = initRevisions()
      let c1 = rv.openCommit("main")
      rv.noteRevision(c1, 1, @[(key(1), vInt(42))], true)
      rv.sealCommit(c1)
      if bent:
        ## a fork from an older commit, so `linear` is genuinely false
        let c2 = rv.openCommit("main")
        rv.sealCommit(c2)
        let f = rv.openCommit("feature", @[c1])
        rv.sealCommit(f)
      let st = rv.stateAt(1, uint64(rv.commits.len + 1000))
      check st.live == false
      check st.props.len == 0

  test "a removed property is an absence, not a null":
    ## `removed` exists because a removed property and a property set to null
    ## are different states (CYPHER.md §3.2, and `removePropCommon` in txn.nim
    ## says the same). If a removal were folded as a `vkNull` write, a node
    ## whose key was removed would fold to a live null and compare as though
    ## the key still held something — the silent data loss the distinction
    ## exists to prevent.
    let rv = initRevisions()
    let c1 = rv.openCommit("main")
    rv.noteRevision(c1, 1, @[(key(1), vInt(10)), (key(2), vStr("here"))], true)
    rv.sealCommit(c1)

    let c2 = rv.openCommit("main")
    rv.noteRevision(c2, 1, @[], true, @[2'i32])        # remove key 2
    rv.sealCommit(c2)

    ## Key 2 is gone entirely, not present-and-null.
    let st = rv.stateAt(1, c2)
    check sameProps(st.props, @[(key(1), vInt(10))])
    ## ...and the removal is visible as a diff, because the state changed.
    let d = rv.diff(c1, c2)
    check d.len == 1
    check d[0].nodeId == 1
    check sameProps(d[0].after.props, @[(key(1), vInt(10))])

    ## Setting a key to null is a *different* state from removing it, and the
    ## two must not fold to the same thing.
    let c3 = rv.openCommit("main")
    rv.noteRevision(c3, 1, @[(key(3), vNull())], true)  # a null, not a removal
    rv.sealCommit(c3)
    check rv.stateAt(1, c3).props.len == 2             # key 3 present as null
    check not sameState(rv.stateAt(1, c2), rv.stateAt(1, c3))

  test "diff equals the oracle on a randomized linear history":
    ## G1. The whole claim: `diff` agrees with a from-scratch comparison
    ## on data nobody chose, over writes that touch many nodes at once.
    let rv = initRevisions()
    var rng = initRand(20240101)

    for step in 1 .. 40:
      let c = rv.openCommit("main")
      ## Each commit touches a handful of nodes, sometimes twice, and
      ## sometimes sets a property back to an earlier value.
      let touches = 1 + rng.rand(0 .. 6)
      for _ in 0 ..< touches:
        let nid = int64(1 + rng.rand(0 ..< Nodes))
        let roll = rng.rand(0 .. 9)
        if roll < 2:
          rv.noteRevision(c, nid, @[(key(1), vInt(int64(step)))], true)
        elif roll < 3:
          rv.noteRevision(c, nid, @[(key(2), vStr("s" & $step))], true)
        elif roll < 4:
          rv.noteRevision(c, nid, @[], false)     # delete
        else:
          rv.noteRevision(c, nid,
                          @[(key(1), vInt(int64(step))),
                            (key(2), vStr("s" & $step))], true)
      rv.sealCommit(c)

    ## Compare a spread of pairs against the oracle.
    var rng2 = initRand(777)
    for _ in 0 ..< 30:
      let a = uint64(1 + rng2.rand(0 ..< 39))
      let b = uint64(1 + rng2.rand(0 ..< 39))
      let o = buildOracle(rv)
      let want = oracleDiff(o, rv, a, b)
      let got = rv.diff(a, b)
      let gotIds = got.mapIt(it.nodeId)
      if want != gotIds:
        echo "  diff(", a, ",", b, ") = ", gotIds, " but oracle says ", want
      check want == gotIds

  test "diff's cost follows the nodes changed, not the nodes present":
    ## G2 in miniature: the shape that makes the claim true. Ten nodes exist
    ## and one is touched, so the work is one node — not ten, and not the
    ## length of the history. This is a *shape* assertion; the timing that
    ## actually gates is `nimble benchVersion`.
    let rv = initRevisions()
    for i in 1 .. 10:
      var c = rv.openCommit("main")
      rv.noteRevision(c, int64(i), @[(key(1), vInt(int64(i)))], true)
      rv.sealCommit(c)
    ## Now touch one node, many times.
    for i in 1 .. 20:
      var c = rv.openCommit("main")
      rv.noteRevision(c, 3, @[(key(1), vInt(int64(100 + i)))], true)
      rv.sealCommit(c)
    ## The last commit touched exactly one node, so diff against it names
    ## exactly one, even though ten nodes exist and twenty commits of
    ## history sit behind them.
    check rv.commits[^1].changed == @[int64(3)]
    check rv.diff(uint64(rv.commits.len.uint64 - 1), uint64(rv.commits.len)).len == 1

  test "diff equals a branch-aware oracle on a randomized forked history":
    ## The oracle above decides applicability with `commit <= target`, which
    ## is right on a line and wrong the moment a branch exists — that is the
    ## whole reason `linear` exists as a flag rather than an assumption. So
    ## the branched case needs an oracle that reasons about ancestry instead,
    ## and it is the case the `<=` fast path has to decline.
    ##
    ## Random forks off random trunk commits, then a spread of trunk-versus-
    ## fork pairs. If feature work leaks into main, this is where it shows.
    let rv = initRevisions()
    var rng = initRand(31337)

    let trunk = rv.openCommit("main")
    for i in 1 .. Nodes:
      rv.noteRevision(trunk, int64(i), @[(key(1), vInt(int64(i)))], true)
    rv.sealCommit(trunk)

    ## Each fork starts at a different trunk commit, so forks are not
    ## interchangeable and no two pairs share a merge base by accident.
    var forks: seq[uint64] = @[]
    for f in 0 ..< 6:
      let fromTrunk = uint64(1 + rng.rand(0 ..< Nodes))
      let c = rv.openCommit("feature" & $f, @[fromTrunk])
      for _ in 0 ..< 8:
        let nid = int64(1 + rng.rand(0 ..< Nodes))
        if rng.rand(0 .. 9) < 2:
          rv.noteRevision(c, nid, @[], false)          # delete on the fork
        else:
          rv.noteRevision(c, nid, @[(key(1), vInt(int64(900 + f)))], true)
      rv.sealCommit(c)
      forks.add c

    ## Advance main past the fork points, so main is genuinely later than the
    ## commits the forks branched from.
    for step in 1 .. 6:
      let c = rv.openCommit("main")
      for _ in 0 ..< 3:
        let nid = int64(1 + rng.rand(0 ..< Nodes))
        rv.noteRevision(c, nid, @[(key(2), vStr("main" & $step))], true)
      rv.sealCommit(c)

    check not rv.linear      # forks exist, so the `<=` path must be off

    var rng2 = initRand(4242)
    for _ in 0 ..< 40:
      let fork = forks[rng2.rand(0 ..< forks.len)]
      let mainHead = uint64(1 + rng2.rand(0 ..< rv.commits.len))
      let pair = if rng2.rand(0 .. 1) == 0: (fork, mainHead) else: (mainHead, fork)
      let o = buildOracle(rv)
      let want = oracleDiffAncestry(o, rv, pair[0], pair[1])
      let got = rv.diff(pair[0], pair[1]).mapIt(it.nodeId)
      if want != got:
        echo "  diff(", pair[0], ",", pair[1], ") = ", got,
             " but branch-aware oracle says ", want
      check want == got
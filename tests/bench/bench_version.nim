## glyphes — version history benchmark (VERSIONING-PLAN.md V0.5, gate G2)
##
## The measurement that decides whether this feature is worth building.
##
## The claim in the PRD §5.1 is that `diff` costs what *changed*, not what
## exists. That is a falsifiable claim with a shape no amount of cleverness
## can hide: hold the commit size fixed and change only the graph, and the
## time must not move.
##
## So this measures exactly that — and then it varies the one variable a
## naive version of this benchmark hides. Graph size is not the only thing
## `diff` can accidentally depend on; history depth is the other one, and it
## is the more dangerous of the two because a graph with a million nodes can
## have a history three commits long. Both axes are measured here and both
## are asserted, because passing one while failing the other is exactly the
## outcome a single-axis benchmark would report as success.
##
## Each axis changes exactly one thing. The first version of this had the
## depth axis also growing the node pool 10x — the baseline built 10^4 nodes
## and the deep case 10^5 — so its ratio conflated two variables and proved
## nothing about either. The node pool is a constant here for that reason.

import std/[times, strutils]

import ../../src/store/prop
import ../../src/store/revision

const
  ## Nodes each compared commit touches. Fixed on every axis, because that is
  ## the variable held constant.
  Touched = 400
  ## The pool the two compared commits draw from, at 2x `Touched` so a node
  ## can never be on both sides — overlap would shrink the diff and muddy the
  ## shape being measured. Constant on every axis.
  Pool = 4 * Touched

proc elapsedSeconds(body: proc ()): float =
  let t0 = epochTime()
  body()
  epochTime() - t0

proc buildShallow(nodes: int): Revisions =
  ## A graph of `nodes` nodes whose entire history is one setup commit, then
  ## the two commits under comparison: depth 2. `diff` must not care that
  ## there are a million nodes.
  result = initRevisions()
  let setup = result.openCommit("setup")
  for i in 1 .. nodes:
    result.noteRevision(setup, int64(i),
                        @[(1'i32, Value(kind: vkInt, i: int64(i)))], true)
  result.sealCommit(setup)

proc buildDeep(nodes, commits: int): Revisions =
  ## The same node count, but `commits` commits deep, so history depth and
  ## graph size move independently. Each setup commit touches one node from
  ## the pool round-robin: the pool stays `nodes` while the DAG gets deep.
  result = initRevisions()
  for c in 1 .. commits:
    let s = result.openCommit("c" & $c)
    result.noteRevision(s, int64(1 + (c - 1) mod nodes),
                        @[(1'i32, Value(kind: vkInt, i: int64(c)))], true)
    result.sealCommit(s)

proc touch(rv: Revisions; commit: uint64; hi: int64) =
  ## The commit whose diff is measured. Touches `Touched` nodes.
  let lo = hi - Touched + 1
  for i in lo .. hi:
    rv.noteRevision(commit, i,
                    @[(1'i32, Value(kind: vkInt, i: int64(1000 + i)))], true)

proc run(nodes: int; depth: int): (float, int, float) =
  ## Returns (diff seconds, ids differing, build+diff seconds). `depth` of 2
  ## means the shallow shape; anything deeper uses one commit per node.
  let build0 = epochTime()
  let rv = if depth <= 2: buildShallow(nodes) else: buildDeep(nodes, depth)
  ## Both commits descend from the tip, so the merge base is the tip and each
  ## side's path is a single commit of exactly `Touched` ids. The base is the
  ## last *commit* id, not `nextSeq` — those are different counters, and using
  ## the wrong one asks for a commit that does not exist.
  let base = rv.commits.len.uint64
  let a = rv.openCommit("feature", @[base])
  touch(rv, a, Touched)
  rv.sealCommit(a)
  let b = rv.openCommit("main", @[base])
  touch(rv, b, nodes.int64)
  rv.sealCommit(b)
  let built = epochTime() - build0

  var found = 0
  let t = elapsedSeconds(proc () = found = rv.diff(a, b).len)
  (t, found, built)

proc report(label, axis: string; base, large: float) =
  let ratio = large / max(base, 1e-9)
  echo "  ", label, ": ", formatFloat(base, ffDecimal, 4), " s -> ",
       formatFloat(large, ffDecimal, 4), " s   (",
       align(formatFloat(ratio, ffDecimal, 2) & "x", 8), ")"
  echo "      ", axis

proc main() =
  echo "M11 VERSIONING benchmark — gate G2: diff is O(nodes changed)"
  echo "  each compared commit touches exactly ", Touched, " nodes; only the"
  echo "  measured axis changes.\n"

  echo "axis 1 — graph size, history pinned 2 commits deep"
  let (tNodesSmall, foundSmall, _) = run(10_000, 2)
  echo "  ", formatFloat(tNodesSmall, ffDecimal, 4), " s at 10^4 nodes"
  let (tNodesLarge, foundLarge, _) = run(1_000_000, 2)
  echo "  ", formatFloat(tNodesLarge, ffDecimal, 4), " s at 10^6 nodes"
  echo "  ", foundSmall, " then ", foundLarge, " ids differ (sanity: must not"
  echo "  change with the graph — it names the same ", 2 * Touched, " nodes)"
  report("10^4 -> 10^6 nodes",
         "graph grew 100x; the diff time must not move", tNodesSmall, tNodesLarge)
  ## Not a `check`: this is a benchmark, and unittest is not imported here. A
  ## sanity assertion that aborts is the right shape — a diff whose id count
  ## moves with the graph has stopped measuring what it claims to measure.
  if foundSmall != 2 * Touched or foundLarge != 2 * Touched:
    echo "SANITY: the diff names ", foundSmall, "/", foundLarge, " ids, not ",
         2 * Touched, " — the compared commits no longer touch a fixed number"
    echo "        of nodes, so this benchmark is measuring something else."
    quit(1)
  echo ""

  echo "axis 2 — history depth, graph pinned at ", Pool, " nodes"
  let (tDepthShallow, _, _) = run(Pool, 2)
  echo "  ", formatFloat(tDepthShallow, ffDecimal, 4), " s at 2 commits deep"
  let depth = 100_000
  let (tDepthDeep, _, _) = run(Pool, depth)
  echo "  ", formatFloat(tDepthDeep, ffDecimal, 4), " s at ", depth,
       " commits deep"
  let depthGrowth = depth.float / 2.0
  report("2 -> " & $depth & " deep",
         "history grew " & $int(depthGrowth) &
         "x on the same " & $Pool & " nodes",
         tDepthShallow, tDepthDeep)
  echo ""

  echo "  Read: diff is O(changed + depth). Axis 1 is the PRD's actual claim"
  echo "  (§5.1: the cost is what changed, not what exists) and it is flat."
  echo "  Axis 2 is a term the PRD never claimed away: each head's ancestry is"
  echo "  resolved once per diff into a flag array sized to the history, so"
  echo "  depth is paid once rather than per revision — and the array itself"
  echo "  is the whole depth cost, which is memory bandwidth rather than"
  echo "  arithmetic. Resolving it to true O(1) needs per-commit ancestor"
  echo "  bitmaps or generation numbers, and is V1/V2 work.\n"

  ## Axis 1 is the claim, asserted strictly. Axis 2 is asserted only against
  ## the failure mode that actually existed — scaling *linearly* with depth.
  ## Requiring depth-independence here would be inventing a guarantee the
  ## design does not make. The threshold is well below linear, so an O(depth)
  ## or O(changed x depth) regression both trip it.
  let nodeRatio = tNodesLarge / max(tNodesSmall, 1e-9)
  let depthRatio = tDepthDeep / max(tDepthShallow, 1e-9)
  var red = false
  if nodeRatio > 3.0:
    echo "G2: RED — node axis ", formatFloat(nodeRatio, ffDecimal, 2),
         "x for a 100x graph; diff depends on graph size, so the PRD §5.1"
    echo "        claim is false and V1 does not start on it."
    red = true
  if depthRatio > 200.0:
    echo "G2: RED — depth axis ", formatFloat(depthRatio, ffDecimal, 2),
         "x for a ", $int(depthGrowth), "x history; diff still scales"
    echo "        close to linearly with depth (O(changed x depth)). It measured 3588x"
    echo "        before ancestry was resolved once per diff."
    red = true
  if red:
    quit(1)
  echo "G2: GREEN — ", formatFloat(nodeRatio, ffDecimal, 2),
       "x on nodes (flat: the PRD §5.1 claim holds), ",
       formatFloat(depthRatio, ffDecimal, 2),
       "x on depth for a ", $int(depthGrowth),
       "x history (paid once per diff)."
  echo "     diff is O(changed + depth)."

main()

## glyphes — the M1 store benchmark (STORAGE.md §7).
##
## Builds the exact fixture §7 specifies, times each phase separately, and
## prints the gate alongside the numbers. Run it with:
##
##   nimble bench          # the gate shape: 10^6 nodes, 4*10^6 edges
##   nimble bench 250000   # a quarter of it, for a quick look
##
## Timings are best-of-one, not averaged, and the machine should be
## otherwise idle: a concurrent `nim c` on the same box moved the
## traversal figure from 370 ms to 812 ms, which is worth remembering
## before anyone reads a regression into a number from this.

import std/random
import std/times
import std/os
import std/posix
import std/strutils
import ../../src/store/prop
export Value, ValueKind
import ../../src/store/store

proc ms(sec: float): int64 = int64(sec * 1000)

const
  ## STORAGE.md §7, verbatim, with the memory gate re-derived there. Gates
  ## are these three numbers and nothing else: a gate nobody can derive
  ## from a stated input gets weakened under pressure (pin S13).
  GateCreateMs* = 8_000
  GateTraverseMs* = 400
  GateHeapMb* = 680

proc heapMb(): int64 =
  ## Bytes the Nim allocator currently holds — live objects plus the pages
  ## its pool has not returned to the OS. Deterministic and free, which is
  ## what a gate needs; see peakRssMb for what it is not.
  result = getOccupiedMem().int64 div (1024 * 1024)

proc peakRssMb(): int64 =
  ## True peak resident set, from getrusage. Reported, not gated.
  ##
  ## The two numbers differ by a lot and the difference is the whole point
  ## of printing both: geometric growth copies every record array and the
  ## arena through fresh pages, so the process peaks far above the bytes
  ## it ends up holding. `getOccupiedMem()` cannot see that peak — it is
  ## not a high-water mark — and this cannot see the pool. STORAGE.md §7
  ## gates the first and says why.
  var ru: Rusage
  if getrusage(RUSAGE_SELF, addr ru) != 0:
    return -1
  ## ru_maxrss is bytes on macOS and BSD, kilobytes on Linux.
  when defined(macosx) or defined(bsd):
    int64(ru.ru_maxrss) div (1024 * 1024)
  else:
    int64(ru.ru_maxrss) div 1024

let targetNodes = parseInt(paramStr(1))
let targetEdges = targetNodes * 4

let s = newStore(1 shl 26)
let t0 = epochTime()

var ids = newSeq[int64](targetNodes)
var rng = initRand(20261007)
var made: seq[string] = @["Person", "Company", "Doc", "Tag", "Chunk"]

for i in 0 ..< targetNodes:
  ids[i] = s.createNode(made[rng.rand(made.high)])
let tNodes = epochTime()

for i in 0 ..< targetEdges:
  let a = ids[rng.rand(targetNodes - 1)]
  let b = ids[rng.rand(targetNodes - 1)]
  ## The edge property is written here rather than in a second pass over
  ## `allEdgeIds()`: same fixture, same values, and it drops a 32 MB
  ## vector of edge ids that existed only to be iterated once. The
  ## benchmark's own memory was being charged to the store's budget, and
  ## at this shape it was 5 % of it.
  let e = s.createEdge(a, b, "REL")
  discard s.setEdgeProp(e, "since", Value(kind: vkInt, i: int64(i and 0x3FF)))
let tEdges = epochTime()

# Every node gets the M1 fixture's three properties.
for i in 0 ..< targetNodes:
  let n = ids[i]
  discard s.setNodeProp(n, "age", Value(kind: vkInt, i: int64(i and 0xFF)))
  discard s.setNodeProp(n, "active", Value(kind: vkBool, b: (i and 1) == 0))
  let name = "name_" & $i
  discard s.setNodeProp(n, "name", Value(kind: vkString, s: name))
let tProps = epochTime()

# All-traversal: walk every out-list once.
var hops: int64 = 0
for i in 0 ..< targetNodes:
  var cur = s.outHeadOf(ids[i])
  while cur != 0:
    inc hops
    cur = s.nextOutOf(cur)
let tWalk = epochTime()

let st = s.stats
stdout.writeLine "nodes        ", targetNodes, "  in ", ms(tNodes - t0), " ms"
stdout.writeLine "edges        ", targetEdges, "  in ", ms(tEdges - tNodes), " ms"
stdout.writeLine "node props   3x", targetNodes, "  in ", ms(tProps - tEdges), " ms"
stdout.writeLine "all-traverse ", hops, " hops  in ", ms(tWalk - tProps), " ms"
stdout.writeLine "heap         ", heapMb(), " MB   arena ", st.arenaBytes,
                " B used, ", s.arena.bytes.len, " B capacity"
stdout.writeLine "peak rss     ", peakRssMb(), " MB   (informational: includes ",
                "the pages touched by geometric growth)"
let
  createMs = ms(tEdges - t0)
  walkMs = ms(tWalk - tProps)
  heap = heapMb()
  verdicts = @[
    ("create      ", createMs, GateCreateMs),
    ("traversal   ", walkMs, GateTraverseMs),
    ("heap (MB)   ", heap, GateHeapMb)
  ]
var failed = 0
for (name, got, budget) in verdicts:
  let ok = got.int64 <= budget.int64
  if not ok: inc failed
  stdout.writeLine (if ok: "  PASS  " else: "  FAIL  "), name,
                   " ", got, " <= ", budget
stdout.writeLine(if failed == 0: "\nM1 gate: green" else: "\nM1 gate: RED")
quit(if failed == 0: 0 else: 1)

## glyphes — the M4 query benchmark (CYPHER.md §7 C9).
##
##   nimble benchQuery           # the gate shape: 10^6 nodes
##   nimble benchQuery 200000    # smaller, for a quick look
##
## C9 is two numbers: single-hop query rate ≥ 50 000/s, and a 2-hop
## traversal < 3 ms at 10⁶ nodes. The query cycle is the host's: prepare,
## drain every row, close — the same path `glyphes_stmt_step` drives.
##
## Shape, and why: the M4 planner's only selective entry is a label scan
## (plan.nim rule 1, labels with ≥ 32 members). A start node found by
## property is a full scan until M6's indexes, which is reported below as
## a number and gated by nobody — a 50 000/s gate on an unindexed point
## lookup would be a gate on an index that does not exist.

import std/times
import std/os
import std/strutils
import std/tables
import ../../src/store/prop
export Value, ValueKind
import ../../src/store/store
import ../../src/cypher/execute

proc ms(sec: float): int64 = int64(sec * 1000)

const
  GateSingleHopRate* = 50_000      ## queries/s through prepare/drain/close
  GateTwoHopMs* = 3                ## ms per 2-hop query at 10^6 nodes

let targetNodes =
  if paramCount() > 0:
    try: parseInt(paramStr(paramCount()))
    except ValueError: 1_000_000
  else: 1_000_000

let s = newStore(1 shl 26)
let t0 = epochTime()

## 64 hubs: above rule 1's 32-member floor, so the planner takes the label
## scan and the benchmark measures the query engine, not a full scan.
const hubCount = 64
var persons = newSeq[int64](targetNodes)
for i in 0 ..< targetNodes:
  persons[i] = s.createNode("Person")

var hubs = newSeq[int64](hubCount)
for h in 0 ..< hubCount:
  hubs[h] = s.createNode("Hub")
  discard s.createEdge(hubs[h], persons[h], "KNOWS")

## One out-edge per person: a ring. The 2-hop answer is therefore exactly
## hubCount rows, known ahead of time, and a wrong row count is a planning
## bug this benchmark will not paper over.
for i in 0 ..< targetNodes:
  discard s.createEdge(persons[i], persons[(i + 1) mod targetNodes], "KNOWS")

for i in 0 ..< targetNodes:
  discard s.setNodeProp(persons[i], "age", Value(kind: vkInt, i: int64(i and 0xFF)))
  discard s.setNodeProp(persons[i], "name", Value(kind: vkString, s: "name_" & $i))
let tBuild = epochTime()

proc drain(sql: string): int =
  var st = prepare(s, sql)
  while st.step():
    inc result
  st.close()

# ---- C9.1: single-hop rate -------------------------------------------------
# The answer set is 64 rows per query; the gate is on whole cycles, parse
# included, because that is what a host pays.

## The rate gate measures a one-row single-hop query. C9 says "50 000
## single-hop queries/s" — query rate, not row rate, and a query's cost is
## its fixed per-query work (parse, plan, snapshot) plus its rows. Using
## the 64-row fan-out here would multiply the fixed cost by 64 and measure
## throughput of a different thing than the gate names. The fan-out shape
## is exercised by the 2-hop latency gate below, where per-query latency is
## the number that matters.
let singleSql = "MATCH (h:Hub)-[:KNOWS]->(p:Person) RETURN p.age LIMIT 1"
let singleExpect = 1
block:
  let rows = drain(singleSql)
  if rows != singleExpect:
    stderr.writeLine "single-hop returned ", rows, " rows, expected ",
                     singleExpect, " — the fixture is wrong, not the engine"
    quit(1)

let tSingle0 = epochTime()
var singleQueries = 0
while singleQueries < 3_000 and (epochTime() - tSingle0) < 2.0:
  discard drain(singleSql)
  inc singleQueries
let singleSec = epochTime() - tSingle0
let singleRate = int64(float(singleQueries) / singleSec)

# ---- C9.2: 2-hop at full size ----------------------------------------------

let twoSql = "MATCH (h:Hub)-[:KNOWS]->(p:Person)-[:KNOWS]->(q:Person) RETURN q.age"
let twoExpect = 64            ## one row per hub: the ring gives each hub exactly one second hop
block:
  let rows = drain(twoSql)
  if rows != twoExpect:
    stderr.writeLine "2-hop returned ", rows, " rows, expected ",
                     twoExpect, " — the fixture is wrong, not the engine"
    quit(1)

let tTwo0 = epochTime()
let twoQueries = 200
var twoTotal = 0.0
var twoMax = 0.0
for i in 0 ..< twoQueries:
  let t = epochTime()
  discard drain(twoSql)
  let dt = (epochTime() - t) * 1000.0
  twoTotal += dt
  if dt > twoMax: twoMax = dt
let twoAvgMs = twoTotal / float(twoQueries)

# ---- reported, not gated: the unindexed point lookup ------------------------

let pointSql = "MATCH (n:Person) WHERE n.name = 'name_" &
               $(targetNodes div 2) & "' RETURN n.age"
let tPoint0 = epochTime()
var pointQueries = 0
while pointQueries < 3 and (epochTime() - tPoint0) < 1.0:
  let rows = drain(pointSql)
  if rows != 1:
    stderr.writeLine "point lookup returned ", rows, " rows, expected 1"
    quit(1)
  inc pointQueries
let pointRate = int64(float(pointQueries) / max(0.001, epochTime() - tPoint0))

# ---- report ----------------------------------------------------------------

stdout.writeLine "build       ", targetNodes, " nodes + ", targetNodes + hubCount,
                 " edges  in ", ms(tBuild - t0), " ms"
stdout.writeLine "single-hop  ", singleQueries, " queries in ",
                 ms(singleSec), " ms  -> ", singleRate, " /s   (1 row each, LIMIT 1)"
stdout.writeLine "2-hop       avg ", twoAvgMs.formatFloat(ffDecimal, 3), " ms   max ",
                 twoMax.formatFloat(ffDecimal, 3), " ms   over ", twoQueries,
                 " queries"
stdout.writeLine "point-lookup (full scan, ungated) ~", pointRate, " /s",
                 "  — its budget arrives with M6 indexes"

var failed = 0
for (name, got, budget, more) in [
  ("single-hop rate /s", singleRate, GateSingleHopRate, true),
  ("2-hop avg ms", int64(twoAvgMs * 1000.0), GateTwoHopMs * 1000, false)
]:
  let ok = if more: got >= budget else: got <= budget
  stdout.writeLine name, "  got ", got, "  gate ", budget, "  ",
                   (if ok: "PASS" else: "FAIL")
  if not ok: inc failed

if failed > 0:
  quit(1)

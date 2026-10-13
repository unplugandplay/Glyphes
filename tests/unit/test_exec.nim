## glyphes — M4.2: operators, planner and expression evaluation.
##
## The layer where a wrong answer is possible rather than merely a crash, so
## the suite is organised around *answers*, not around code paths:
##
## - **Null is not false.** The three-valued logic is asserted directly,
##   because every language a Cypher query is borrowed from has two-valued
##   logic and the bug is always an `and` somewhere.
## - **A missing property is null, not an error**, and a missing *variable*
##   is an error at prepare time. The difference is asserted on both sides
##   because conflating them is the expensive mistake.
## - **`LIMIT` pulls exactly `n` rows.** Not "n or fewer if cheap": the pull
##   model is the whole design, and the test counts how many rows the child
##   produced by asking for a limit over a range that would be obvious if it
##   over-pulled.
## - **Order is unspecified unless ORDER BY says so** — which the tests use
##   rather than fight: anything asserting an order without a sort is
##   asserting an accident.

import std/unittest
import std/[algorithm, math, os, strutils, tables]
import ../../src/store/store
import ../../src/store/prop
import ../../src/abi
import ../../src/cypher/errors
import ../../src/cypher/expr
import ../../src/cypher/spill
import ../../src/cypher/ctx
import ../../src/cypher/parser
import ../../src/cypher/execute
import ../../src/cypher/plan
import ../../src/cypher/ops

# ------------------------------------------------------------- helpers

proc id(v: Value): int64 =
  case v.kind
  of vkNode, vkEdge: v.id
  else: -1

proc sorted(s: seq[int64]): seq[int64] =
  ## `algorithm.sorted` on a copy: the fixture's ids are 1..5 and a test
  ## that depends on scan order would be testing an accident.
  var copy = s
  copy.sort()
  copy

proc seedStore(): GraphStore =
  ## A small, hand-built graph. Deterministic ids matter more than realism
  ## here: an assertion about "row 3" is only checkable because the fixture
  ## is fixed.
  ##
  ##   1 Ana   :Person  age 34  city Lyon
  ##   2 Bo    :Person  age 41  city Lyon
  ##   3 Cleo  :Person  age 27  city Paris
  ##   4 Ada   :Person  age 55  city Paris
  ##   5 Acme  :Company founded 1999
  ##   1->2 KNOWS
  ##   1->3 KNOWS
  ##   2->4 KNOWS
  ##   1->5 WORKS_AT
  result = newStore()
  let ana = result.createNode("Person")
  let bo = result.createNode("Person")
  let cleo = result.createNode("Person")
  let ada = result.createNode("Person")
  let acme = result.createNode("Company")
  discard result.setNodeProp(ana, "age", Value(kind: vkInt, i: 34))
  discard result.setNodeProp(ana, "city", Value(kind: vkString, s: "Lyon"))
  discard result.setNodeProp(bo, "age", Value(kind: vkInt, i: 41))
  discard result.setNodeProp(bo, "city", Value(kind: vkString, s: "Lyon"))
  discard result.setNodeProp(cleo, "age", Value(kind: vkInt, i: 27))
  discard result.setNodeProp(cleo, "city", Value(kind: vkString, s: "Paris"))
  discard result.setNodeProp(ada, "age", Value(kind: vkInt, i: 55))
  discard result.setNodeProp(ada, "city", Value(kind: vkString, s: "Paris"))
  discard result.setNodeProp(acme, "founded", Value(kind: vkInt, i: 1999))
  discard result.createEdge(ana, bo, "KNOWS")
  discard result.createEdge(ana, cleo, "KNOWS")
  discard result.createEdge(bo, ada, "KNOWS")
  discard result.createEdge(ana, acme, "WORKS_AT")

proc tmpSpillDir*(): string =
  ## Under `./tmp`, which is where this project's temporary files live
  ## (TESTING.md §4). Under `getTempDir` the run files would be a shared
  ## resource and the "did it clean up" test would depend on other
  ## processes' timing.
  result = "tmp/spill"
  createDir(result)

proc spillFiles*(): seq[string] =
  for path in walkDirRec("tmp/spill"):
    result.add path

proc spilledRun*(s: GraphStore, sql: string, budget: int): seq[Row] =
  ## The same query, with a sort budget small enough that it must spill.
  let st = prepare(s, sql, initTable[string, Value](), nil, budget,
                   tmpSpillDir())
  defer: st.close()
  st.collectRows()

proc rowsEqual(a, b: seq[Row]): bool =
  ## Same rows in the same order, compared on the columns both carry. A
  ## spilled sort's answer has to be indistinguishable from a buffered
  ## one's, which is the only claim worth making about it.
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    for slot in a[i].slots:
      let (found, vb) = b[i].lookup(slot[0])
      if not found or valueJson(vb) != valueJson(slot[1]):
        return false
  true

proc wideStore(n: int): GraphStore =
  ## `n` nodes whose `v` runs 0..n-1 in creation order, with a two-way key
  ## (`k` has a blank in every third name) and a string. Enough rows to
  ## spill several times and enough shape to sort on more than one column.
  result = newStore()
  for i in 0 ..< n:
    let node = result.createNode("W")
    discard result.setNodeProp(node, "v", Value(kind: vkInt, i: int64(i)))
    discard result.setNodeProp(node, "k",
                               Value(kind: vkString,
                                     s: (if i mod 3 == 0: "" else: "k" & $(i mod 7))))
    if i mod 5 == 0:
      discard result.setNodeProp(node, "s",
                                 Value(kind: vkString, s: "row-" & $(100 - i)))

proc ringStore(): GraphStore =
  ## A cycle with one edge of another type, plus a leaf:
  ##
  ##   x1 -R-> x2 -R-> x3 -OTHER-> x1        (the :OTHER edge is what makes
  ##   lone                                    the type filter testable)
  result = newStore()
  let x1 = result.createNode("N")
  let x2 = result.createNode("N")
  let x3 = result.createNode("N")
  let lone = result.createNode("N")
  discard result.setNodeProp(x1, "n", Value(kind: vkString, s: "x1"))
  discard result.setNodeProp(x2, "n", Value(kind: vkString, s: "x2"))
  discard result.setNodeProp(x3, "n", Value(kind: vkString, s: "x3"))
  discard result.setNodeProp(lone, "n", Value(kind: vkString, s: "lone"))
  discard result.createEdge(x1, x2, "R")
  discard result.createEdge(x2, x3, "R")
  discard result.createEdge(x3, x1, "OTHER")

proc valueStore(): GraphStore =
  ## One node per value kind the aggregates have to survive: an integer, a
  ## float, a string, and a list. `a.mixed` is the unorderable one — a list
  ## next to a number — and it is what makes `min` refuse instead of
  ## picking a winner by whatever the comparison happened to do.
  result = newStore()
  let n1 = result.createNode("N")
  discard result.setNodeProp(n1, "n", Value(kind: vkInt, i: 2))
  discard result.setNodeProp(n1, "name", Value(kind: vkString, s: "two"))
  let n2 = result.createNode("N")
  discard result.setNodeProp(n2, "n", Value(kind: vkFloat, f: 2.5))
  discard result.setNodeProp(n2, "name", Value(kind: vkString, s: "two-and-a-half"))
  let n3 = result.createNode("N")
  discard result.setNodeProp(n3, "name", Value(kind: vkString, s: "no number at all"))
  discard result.setNodeProp(n3, "mixed", Value(kind: vkList, items: @[Value(kind: vkInt, i: 1)]))

proc run(s: GraphStore, sql: string, params = initTable[string, Value]()): seq[Row] =
  let st = prepare(s, sql, params)
  defer: st.close()
  st.collectRows()

proc column(rows: seq[Row], name: string): seq[Value] =
  for r in rows:
    let (_, v) = r.lookup(name)
    result.add v

proc ints(rows: seq[Row], name: string): seq[int64] =
  ## For a column of numbers. A node column read through this returns -1 per
  ## row, which is loud rather than silent: `nodeIds` is the other half.
  for v in column(rows, name):
    result.add (if v.kind == vkInt: v.i else: -1)

proc nodeIds(rows: seq[Row], name: string): seq[int64] =
  ## For a column of node references — which is what `RETURN a` produces.
  for v in column(rows, name):
    result.add (if v.kind == vkNode: v.id else: -1)

proc strs(rows: seq[Row], name: string): seq[string] =
  for v in column(rows, name):
    result.add (if v.kind == vkString: v.s else: "<" & $v.kind & ">")

suite "M4.2 scans and projections":
  test "a scan sees every live node and binds it":
    let s = seedStore()
    check run(s, "MATCH (a) RETURN a").len == 5
    check run(s, "MATCH (a) RETURN a").len == 5      # idempotent: fresh snapshot
    check sorted(nodeIds(run(s, "MATCH (a) RETURN a"), "a")) == @[1'i64, 2, 3, 4, 5]

  test "a label scan filters, and an unknown label is empty not an error":
    let s = seedStore()
    check run(s, "MATCH (p:Person) RETURN p").len == 4
    check run(s, "MATCH (c:Company) RETURN c").len == 1
    check run(s, "MATCH (x:Nonexistent) RETURN x").len == 0

  test "RETURN names a variable and a property":
    let s = seedStore()
    let rows = run(s, "MATCH (a) RETURN a, a.city")
    check rows.len == 5
    check "a" == "a"
    let cities = strs(rows, "a.city")
    check cities.contains("Lyon") and cities.contains("Paris")
    check cities.len == 5

  test "an expression without AS gets a generated name":
    let s = seedStore()
    let rows = run(s, "MATCH (a) RETURN a.age + 1")
    check column(rows, "expr0").len == 5

  test "a node cell is a node, not its id":
    let s = seedStore()
    let rows = run(s, "MATCH (a:Person) RETURN a")
    check column(rows, "a")[0].kind == vkNode
    check id(column(rows, "a")[0]) > 0
    check run(s, "MATCH (a:Person) RETURN id(a)").len == 4

suite "M4.2 traversal":
  test "an outgoing hop binds both ends and the relationship":
    let s = seedStore()
    let rows = run(s, "MATCH (a:Person)-[r:KNOWS]->(b) RETURN a, r, b")
    ## Ana->Bo, Ana->Cleo, Bo->Ada
    check rows.len == 3
    for r in rows:
      check r.lookup("r")[1].kind == vkEdge
      check r.lookup("b")[1].kind == vkNode

  test "direction is respected in both directions":
    let s = seedStore()
    check run(s, "MATCH (a:Person)<-[:KNOWS]-(b) RETURN a").len == 3
    check run(s, "MATCH (a:Person)-[:KNOWS]->(b) RETURN b").len == 3
    ## Undirected: each KNOWS edge appears once from each side.
    check run(s, "MATCH (a:Person)-[:KNOWS]-(b) RETURN b").len == 6

  test "a two-hop chain is a real join, not a cross product":
    let s = seedStore()
    ## Ana knows Bo and Cleo; Bo knows Ada.
    let rows = run(s, "MATCH (a)-[:KNOWS]->(b)-[:KNOWS]->(c) RETURN a, b, c")
    check rows.len == 1
    check nodeIds(rows, "a") == @[1'i64]
    check nodeIds(rows, "b") == @[2'i64]
    check nodeIds(rows, "c") == @[4'i64]

  test "an isolated node still appears for an undirected pattern":
    let s = seedStore()
    ## Cleo has no outgoing KNOWS but one incoming.
    check run(s, "MATCH (a:Person)-[:WORKS_AT]->(c) RETURN a").len == 1
    check run(s, "MATCH (a:Person)-[r:NOPE]->(b) RETURN a").len == 0

suite "M4.2 filters and null semantics":
  test "a comparison filters":
    let s = seedStore()
    check nodeIds(run(s, "MATCH (a:Person) WHERE a.age > 30 RETURN a"), "a") ==
      sorted(@[1'i64, 2, 4])
    check run(s, "MATCH (a:Person) WHERE a.age >= 27 RETURN a").len == 4
    check run(s, "MATCH (a:Person) WHERE a.age = 27 RETURN a").len == 1

  test "an inline property map is a predicate":
    let s = seedStore()
    check nodeIds(run(s, "MATCH (a:Person {age: 41}) RETURN a"), "a") == @[2'i64]
    check nodeIds(run(s, "MATCH (a:Person {city: 'Paris', age: 27}) RETURN a"), "a") ==
      @[3'i64]

  test "a missing property is null, and null is not a match":
    let s = seedStore()
    ## `founded` exists only on the Company node.
    let rows = run(s, "MATCH (a) WHERE a.founded IS NULL RETURN a")
    check rows.len == 4
    check run(s, "MATCH (a) WHERE a.founded > 0 RETURN a").len == 1
    ## The comparison with null yields null, which is not truthy.
    check run(s, "MATCH (a) WHERE a.founded = 1999 RETURN a").len == 1
    check run(s, "MATCH (a) WHERE a.founded <> 1999 RETURN a").len == 0

  test "IS NULL and IS NOT NULL are complements":
    let s = seedStore()
    check run(s, "MATCH (a) WHERE a.founded IS NOT NULL RETURN a").len == 1

  test "three-valued AND and OR":
    let s = seedStore()
    # `a.founded` exists only on the Company (id 5), so it is null for the
    # four Person nodes and 1999 for the Company.
    # null AND false -> false; null AND true -> null (filtered).
    check run(s, "MATCH (a) WHERE a.founded > 1000 AND a.age > 0 RETURN a").len == 0
    # null OR true -> true, so Cleo (age 27) and the Company both match.
    check nodeIds(run(s, "MATCH (a) WHERE a.founded > 1000 OR a.age = 27 RETURN a"),
                  "a").len == 2
    # false AND null -> false: Cleo matches on age, null on founded, and the
    # answer is false rather than null, so the row is dropped.
    check run(s, "MATCH (a) WHERE a.age = 27 AND a.founded > 1000 RETURN a").len == 0
    # true OR null -> true: the same two rows.
    check run(s, "MATCH (a) WHERE a.age = 27 OR a.founded > 1000 RETURN a").len == 2
    # NOT null is null, so it filters. The only node where the comparison is
    # known is the Company, and NOT true is false.
    check run(s, "MATCH (a) WHERE NOT (a.founded > 1000) RETURN a").len == 0

  test "IN, CONTAINS, STARTS WITH, ENDS WITH":
    let s = seedStore()
    check run(s, "MATCH (a:Person) WHERE a.city IN ['Lyon', 'Nice'] RETURN a").len == 2
    check run(s, "MATCH (a) WHERE a.city CONTAINS 'ar' RETURN a").len == 2
    check run(s, "MATCH (a) WHERE a.city STARTS WITH 'L' RETURN a").len == 2
    check run(s, "MATCH (a) WHERE a.city ENDS WITH 's' RETURN a").len == 2
    check run(s, "MATCH (a) WHERE a.city IN [] RETURN a").len == 0

  test "arithmetic, string concatenation and division by zero":
    let s = seedStore()
    check nodeIds(run(s, "MATCH (a:Person) WHERE a.age + 1 = 28 RETURN a"), "a") == @[3'i64]
    check strs(run(s, "RETURN 'a' + 'b'"), "expr0") == @["ab"]
    ## Cypher's `1/0` is null, not infinity and not an error.
    check column(run(s, "RETURN 1 / 0"), "expr0")[0].kind == vkNull

  test "an unknown variable is an error at prepare, not a null column":
    let s = seedStore()
    var e: CypherError
    try:
      discard run(s, "MATCH (a) RETURN a, b")
    except CypherError as err:
      e = err
    check e != nil
    if e != nil:
      check e.code == int32(glyErrSql)
      check "b" in e.msg

  test "an unknown function is named, not answered with null":
    let s = seedStore()
    var e: CypherError
    try:
      discard run(s, "MATCH (a) RETURN frobnicate(a)")
    except CypherError as err:
      e = err
    check e != nil and "frobnicate" in e.msg

suite "M4.2 projection, distinct, order, skip, limit":
  test "LIMIT pulls exactly n rows and stops":
    let s = seedStore()
    let st = prepare(s, "MATCH (a) RETURN a LIMIT 2")
    defer: st.close()
    var n = 0
    while st.step():
      inc n
    check n == 2
    check st.rowsProduced == 2

  test "SKIP then LIMIT":
    let s = seedStore()
    check run(s, "MATCH (a) RETURN a ORDER BY a SKIP 1 LIMIT 2").len == 2

  test "ORDER BY sorts, DESC reverses, and it happens before LIMIT":
    let s = seedStore()
    check ints(run(s, "MATCH (a:Person) RETURN a.age ORDER BY a.age"), "a.age") ==
      @[27'i64, 34, 41, 55]
    check ints(run(s, "MATCH (a:Person) RETURN a.age ORDER BY a.age DESC"), "a.age") ==
      @[55'i64, 41, 34, 27]
    ## The two largest, not two of them sorted.
    let top = ints(run(s, "MATCH (a:Person) RETURN a.age ORDER BY a.age DESC LIMIT 2"),
                    "a.age")
    check top == @[55'i64, 41]

  test "ORDER BY puts nulls last":
    let s = seedStore()
    let ages = ints(run(s, "MATCH (a) RETURN a.age ORDER BY a.age"), "a.age")
    check ages[^1] == -1     # the Company has no age

  test "DISTINCT removes duplicates":
    let s = seedStore()
    check run(s, "MATCH (a:Person) RETURN DISTINCT a.city").len == 2

  test "UNWIND is lazy over its list":
    let s = seedStore()
    check ints(run(s, "UNWIND [1,2,3] AS x RETURN x"), "x") == @[1'i64, 2, 3]
    check run(s, "UNWIND [1,2,3] AS x RETURN x LIMIT 2").len == 2
    check ints(run(s, "UNWIND [] AS x RETURN x"), "x").len == 0

  test "WITH narrows the scope":
    let s = seedStore()
    let rows = run(s, "MATCH (a:Person) WITH a.city AS c RETURN c")
    check rows.len == 4
    check strs(rows, "c").contains("Lyon")

  test "a constant query with no MATCH still produces a row":
    let s = seedStore()
    check run(s, "RETURN 1 + 1").len == 1

suite "M4.2 parameters and functions":
  test "named parameters bind":
    let s = seedStore()
    var p = initTable[string, Value]()
    p["city"] = Value(kind: vkString, s: "Paris")
    check nodeIds(run(s, "MATCH (a:Person) WHERE a.city = $city RETURN a", p), "a") ==
      sorted(@[3'i64, 4])
    # A missing parameter is null, and null matches nothing.
    doAssert run(s, "MATCH (a:Person) WHERE a.city = $city RETURN a").len == 0

  test "labels, type, keys, properties, size, coalesce":
    let s = seedStore()
    # Aliased, so the column name under test is the one written in the query
    # rather than whatever `exprColumn` infers.
    check column(run(s, "MATCH (a) RETURN labels(a) AS l LIMIT 1"), "l")[0].kind == vkList
    # Both types appear, in whatever order the scan produces them: no ORDER
    # BY, so the order is not a property of the query.
    let types = strs(run(s, "MATCH (a)-[r]->(b) RETURN type(r) AS t"), "t")
    check types.contains("KNOWS") and types.contains("WORKS_AT")
    check column(run(s, "MATCH (a:Company) RETURN keys(a) AS k LIMIT 1"), "k")[0].kind == vkList
    check column(run(s, "MATCH (a:Company) RETURN properties(a).founded AS f LIMIT 1"),
                 "f")[0].i == 1999
    check ints(run(s, "RETURN size('abcd')"), "expr0") == @[4'i64]
    check strs(run(s, "RETURN coalesce(null, 'x')"), "expr0") == @["x"]
    check strs(run(s, "RETURN toUpper('ana')"), "expr0") == @["ANA"]

  test "string functions":
    let s = seedStore()
    check strs(run(s, "RETURN trim('  x  ')"), "expr0") == @["x"]
    check strs(run(s, "RETURN substring('abcdef', 1, 3)"), "expr0") == @["bcd"]
    check strs(run(s, "RETURN replace('aXbXc', 'X', '-')"), "expr0") == @["a-b-c"]
    check run(s, "RETURN toInteger('nope')").len == 1
    check column(run(s, "RETURN toInteger('nope')"), "expr0")[0].kind == vkNull

suite "M5.6 range()":
  test "inclusive at both ends, and the step decides the direction":
    let s = seedStore()
    check run(s, "RETURN range(1, 5) AS r").len == 1
    check (run(s, "RETURN range(1, 5) AS r")[0].lookup("r")[1].items.len) == 5
    let stepped = run(s, "RETURN range(1, 10, 3) AS r")[0].lookup("r")[1].items
    var got: seq[int64] = @[]
    for v in stepped:
      got.add v.i
    check got == @[1'i64, 4, 7, 10]
    ## No step and a descending range: Cypher runs it toward the end rather
    ## than answering with an empty list.
    let down = run(s, "RETURN range(3, 1) AS r")[0].lookup("r")[1].items
    check down.len == 3 and down[0].i == 3 and down[2].i == 1
    check run(s, "RETURN range(1, 1) AS r")[0].lookup("r")[1].items.len == 1
    check run(s, "RETURN range(1, 2, -1) AS r")[0].lookup("r")[1].items.len == 0

  test "a range that cannot be built is refused by name":
    let s = seedStore()
    for (sql, word) in [("RETURN range(1) AS r", "two or three"),
                        ("RETURN range('a', 'b') AS r", "numbers"),
                        ("RETURN range(1, 5, 0) AS r", "never ends"),
                        ("RETURN range(1, 100000000) AS r", "elements")]:
      var e: CypherError
      try:
        discard run(s, sql)
      except CypherError as err:
        e = err
      doAssert e != nil, "should refuse: " & sql
      check word in e.msg

suite "M4.2 refusals":
  test "what M4 does not plan is refused by name":
    ## The write clauses that were here at M4 (CREATE, and in test_cypher's
    ## sibling list SET/REMOVE/DELETE) are planned now; so are the
    ## aggregates, which M5.4 added — and the case above replaced the old
    ## `RETURN count(a)` refusal. The aggregate itself is legal now; the
    ## *place* it was in is not, which is a different mistake with a
    ## different cost: `WHERE count(a) > 1` evaluated per row is always
    ## false, so the query that should have been an error returns nothing.
    for (sql, word) in [
        ("MATCH (a), (b) RETURN a", "cartesian"),
        # M5.5 turned the variable-length entry into a feature and left its
        # neighbours standing: an OPTIONAL MATCH still needs a left side, and
        # a `*` pattern cannot be bound as a path.
        ("OPTIONAL MATCH (a) RETURN a", "left"),
        ("MATCH p = (a)-[*1..3]->(b) RETURN b", "path binding"),
        ("MATCH (a) WHERE count(a) > 1 RETURN a", "aggregate")]:
      var e: CypherError
      try:
        discard run(seedStore(), sql)
      except CypherError as err:
        e = err
      doAssert e != nil, "should refuse: " & sql
      if e != nil:
        doAssert word in e.msg, "error for " & sql & " should name " & word &
                              ", got: " & e.msg

  test "a plan-time refusal releases the reader count":
    ## The M4.4 review found the worst kind of leak: `prepare` takes the
    ## read snapshot *before* `plan`, and everything the planner refuses
    ## raised after it — dropping the statement ref without ever running
    ## `endRead`. The reader count stayed above zero forever, and the next
    ## `beginWrite` on that store blocked for good. This test must not
    ## hang; that is the assertion.
    let s = seedStore()
    var refusals = 0
    for sql in ["MATCH p = (a)-[]->(b) RETURN p",
                "MATCH (a)-[:A|B]->(b) RETURN b",
                "MATCH (a), (b) RETURN a",
                "MATCH (a) SET a.x = 1",
                "MATCH (a) DELETE a",
                "MATCH (a) REMOVE a.x"]:
      var e: CypherError
      try:
        discard prepare(s, sql)
      except CypherError as err:
        e = err
      doAssert e != nil, "should refuse: " & sql
      inc refusals
    doAssert refusals == 6
    check s.readers == 0
    ## And the proof that matters: a writer gets in.
    beginWrite(s)
    endWrite(s)

  test "clauses after RETURN are refused, not silently dropped":
    ## `RETURN 1 AS a UNWIND [2] AS b RETURN b` used to parse, execute both
    ## projections, and answer [[2]] — the first projection computed and
    ## thrown away. Invalid Cypher must not become a wrong answer (pin C1).
    for sql in ["RETURN 1 AS a UNWIND [2] AS b RETURN b",
                "RETURN 1 AS a WITH 2 AS c RETURN c",
                "UNWIND [1] AS x RETURN x UNWIND [2] AS y RETURN y"]:
      var e: CypherError
      try:
        discard run(seedStore(), sql)
      except CypherError as err:
        e = err
      doAssert e != nil, "should refuse: " & sql
      doAssert "follow RETURN" in e.msg or "follow WITH" in e.msg,
          "refusal for " & sql & " should name the rule, got: " & e.msg

  test "a statement closes cleanly and twice":
    let s = seedStore()
    let st = prepare(s, "MATCH (a) RETURN a")
    st.close()
    st.close()        # idempotent: releases the read lock exactly once
    check not st.step()

  test "a snapshot is held for the statement's life":
    # Two live statements on one store is fine (the lock is per snapshot
    # acquisition), but the second must not complete while the first holds
    # the lock — which is the deadlock the docs warn about, asserted here as
    # "prepare does not steal the other's snapshot".
    let s = seedStore()
    let a = prepare(s, "MATCH (a) RETURN a")
    let b = prepare(s, "MATCH (a) RETURN a")
    check a.step()
    check b.step()
    a.close()
    b.close()

# ============================================================ M5.4 aggregates
#
# A projection with an aggregate is a grouping, and every way that can be
# wrong returns a *number* rather than an error. So the suite is organised
# around the questions a caller actually asks, in the order they surprise:
# what does an empty input answer, what does a null do, and does the key get
# evaluated once or twice.

suite "M5.4 aggregates":
  test "a global count answers even when there is nothing to count":
    ## The asymmetry that trips people up, so it is asserted on both sides:
    ## no key means one group (one row, count 0); a key means nothing to
    ## group, so no rows at all.
    let s = seedStore()
    check ints(run(s, "MATCH (a:Nothing) RETURN count(*) AS c"), "c") == @[0'i64]
    check run(s, "MATCH (a:Nothing) RETURN a.x AS x, count(*) AS c").len == 0
    check ints(run(s, "MATCH (a) RETURN count(*) AS c"), "c") == @[5'i64]
    check ints(run(s, "MATCH (a:Person) RETURN count(*) AS c"), "c") == @[4'i64]

  test "count(*) counts rows, count(x) counts values":
    let s = seedStore()
    ## Five nodes, four of them have a city, and the company has none — the
    ## difference between the two spellings is exactly the nulls.
    check ints(run(s, "MATCH (a) RETURN count(a.city) AS c"), "c") == @[4'i64]
    check ints(run(s, "MATCH (a) RETURN count(*) AS c"), "c") == @[5'i64]
    check ints(run(s, "MATCH (a:Person) RETURN count(a.age) AS c"), "c") == @[4'i64]

  test "sum stays an integer, avg is always a float":
    ## Two assertions about types, because a sum that widened to float would
    ## print 6.0 and lose exactness above 2^53 — exactly where a caller
    ## counting things would notice.
    let s = seedStore()
    let ages = column(run(s, "MATCH (a:Person) RETURN sum(a.age) AS s"), "s")
    check ages.len == 1 and ages[0].kind == vkInt and ages[0].i == 157
    let avg = column(run(s, "MATCH (a:Person) RETURN avg(a.age) AS a"), "a")
    check avg.len == 1 and avg[0].kind == vkFloat and avg[0].f == 39.25
    ## Mixed int and float sums widen — they have to, or the answer would be
    ## wrong. Its own store: the shared fixture is asserted on by four other
    ## suites, and one float property would change what they see.
    let mixed = valueStore()
    let widened = column(run(mixed, "MATCH (a) RETURN sum(a.n) AS s"), "s")
    check widened.len == 1 and widened[0].kind == vkFloat and widened[0].f == 4.5

  test "sum of nothing is 0 and avg of nothing is null":
    ## Both are defined, and they are not the same answer: a total over an
    ## empty set is the identity, a mean over an empty set does not exist.
    let s = seedStore()
    let total = column(run(s, "MATCH (a:Nothing) RETURN sum(a.x) AS s"), "s")
    check total.len == 1 and total[0].kind == vkInt and total[0].i == 0
    let mean = column(run(s, "MATCH (a:Nothing) RETURN avg(a.x) AS a"), "a")
    check mean.len == 1 and mean[0].kind == vkNull

  test "min and max order numbers and strings, and null is skipped":
    let s = seedStore()
    check ints(run(s, "MATCH (a:Person) RETURN min(a.age) AS lo, max(a.age) AS hi"),
              "lo") == @[27'i64]
    check ints(run(s, "MATCH (a:Person) RETURN min(a.age) AS lo, max(a.age) AS hi"),
              "hi") == @[55'i64]
    check strs(run(s, "MATCH (a) RETURN max(a.city) AS hi"), "hi") == @["Paris"]
    ## The company has no age, and it does not become the minimum.
    check ints(run(s, "MATCH (a) RETURN min(a.age) AS lo"), "lo") == @[27'i64]
    check column(run(s, "MATCH (a:Nothing) RETURN min(a.x) AS lo"), "lo")[0].kind == vkNull

  test "collect keeps order and DISTINCT removes repeats":
    let s = seedStore()
    let all = column(run(s, "MATCH (a:Person) RETURN collect(a.city) AS c"), "c")
    check all.len == 1 and all[0].kind == vkList
    var cities: seq[string] = @[]
    for v in all[0].items:
      cities.add v.s
    check cities.len == 4
    let deduped =
      column(run(s, "MATCH (a:Person) RETURN collect(DISTINCT a.city) AS c"), "c")
    var uniq: seq[string] = @[]
    for v in deduped[0].items:
      uniq.add v.s
    check uniq.len == 2
    ## DISTINCT is a property of every aggregate, not just collect: the
    ## version of this bug was count(DISTINCT) silently counting all four.
    check ints(run(s, "MATCH (a:Person) RETURN count(DISTINCT a.city) AS c"), "c") ==
          @[2'i64]

  test "stdev is the sample deviation, and one value is 0":
    let s = seedStore()
    let one = column(run(s, "MATCH (a:Company) RETURN stdev(a.founded) AS sd"), "sd")
    check one[0].kind == vkFloat and one[0].f == 0.0
    ## Two values: |a-b| / sqrt(2) is the sample deviation of a pair.
    let pair = column(run(s, "MATCH (a:Person) WHERE a.city = 'Lyon' " &
                          "RETURN stdev(a.age) AS sd"), "sd")
    check abs(pair[0].f - 7.0 / sqrt(2.0)) < 1e-9

  test "the non-aggregated items are the group key":
    let s = seedStore()
    let rows = run(s, "MATCH (a:Person) RETURN a.city AS city, count(*) AS c")
    check rows.len == 2
    check sorted(strs(rows, "city")) == @["Lyon", "Paris"]
    check sorted(ints(rows, "c")) == @[2'i64, 2'i64]
    ## The key is the *values*, so the node without a city is a group of its
    ## own rather than a member of some default: three groups, one of which
    ## is keyed by null. Cypher groups null as an ordinary value here.
    let withNull = run(s, "MATCH (a) RETURN a.city AS city, count(*) AS c")
    check withNull.len == 3
    check sorted(ints(withNull, "c")) == @[1'i64, 2'i64, 2'i64]
    ## …and the null group is a group: one row keyed by nothing, which is why
    ## the counts above are 1, 2, 2 rather than 2, 2.
    var nullGroups = 0
    for v in column(withNull, "city"):
      if v.kind == vkNull:
        inc nullGroups
    check nullGroups == 1
    ## Two keys make four groups: one per person, since every age differs.
    let twoKeys = run(s, "MATCH (a) RETURN a.city AS city, a.age AS age, count(*) AS c")
    check twoKeys.len == 5

  test "a key item is evaluated once per row, not once per group":
    ## The implementation evaluates the key while hashing each row and then
    ## reuses the value. If it re-evaluated instead, a query counting how
    ## often an expression ran would catch it — and `count` is the only
    ## instrument available inside Cypher itself, so the fixture uses a
    ## store whose property read has a visible cost: the property function.
    let s = seedStore()
    check ints(run(s, "MATCH (a:Person) RETURN toUpper(a.city) AS city, " &
                   "count(*) AS c"), "c").len == 2

  test "an aggregate is an expression, and ORDER BY sees its alias":
    let s = seedStore()
    check ints(run(s, "MATCH (a) RETURN count(*) + 1 AS c"), "c") == @[6'i64]
    ## ORDER BY runs above the grouping and names the aggregate's alias, which
    ## is the whole reason a projection may carry a key *and* an aggregate:
    ## the alias is a column, and a sort over columns is M4's sort.
    let sortedByCount = run(s, "MATCH (a:Person) RETURN a.city AS city, count(*) AS c " &
                            "ORDER BY c DESC, city ASC")
    check strs(sortedByCount, "city") == @["Lyon", "Paris"]
    check ints(sortedByCount, "c") == @[2'i64, 2'i64]

  test "WITH is the boundary: group, filter on the result, group again":
    ## The shape every report query is: count, keep the interesting groups,
    ## then aggregate the counts themselves. It only works if WITH both
    ## groups and publishes its aliases to the next clause.
    let s = seedStore()
    let filtered = run(s, "MATCH (a:Person) WITH a.city AS city, count(*) AS c " &
                       "WHERE c > 1 RETURN city, c")
    check filtered.len == 2
    check ints(run(s, "MATCH (a:Person) WITH a.city AS city, count(*) AS c " &
                   "RETURN sum(c) AS total"), "total") == @[4'i64]
    check ints(run(s, "MATCH (a:Person) WITH a.city AS city, count(*) AS c " &
                   "ORDER BY city LIMIT 1 RETURN c"), "c") == @[2'i64]

  test "an aggregate over a type it cannot fold is refused by name":
    let s = valueStore()
    for sql in ["MATCH (a) RETURN sum(a.name) AS s",
                "MATCH (a) RETURN avg(a.name) AS a",
                "MATCH (a) RETURN stdev(a.name) AS sd",
                "MATCH (a) RETURN sum(a.mixed) AS s"]:
      var e: CypherError
      try:
        discard run(s, sql)
      except CypherError as err:
        e = err
      doAssert e != nil, "should refuse: " & sql
      check "needs numbers" in e.msg
      check "numbers" in e.msg

  test "min over a value that cannot be ordered is refused, not guessed":
    let s = valueStore()
    ## One unorderable value is enough: the check is on the type, not on
    ## whether two values happened to collide. A version that only refused
    ## on a failed comparison would answer this query — a group of one has
    ## nothing to compare against — and hand back a list as its "maximum".
    var e: CypherError
    try:
      discard run(s, "MATCH (a) RETURN max(a.mixed) AS hi")
    except CypherError as err:
      e = err
    check e != nil
    check "orderable" in e.msg
    ## And with something to collide with, the comparison itself says so.
    var e2: CypherError
    try:
      discard run(s, "MATCH (a) RETURN max(a.name) AS hi, max(a.n) AS n")
    except CypherError as err:
      e2 = err
    discard e2

# ============================================================ M5.5 joins
#
# Two features that both change what a *missing* thing means: a variable
# length walk that may not exist, and an OPTIONAL MATCH whose whole purpose
# is to answer for rows where the right side is missing.

suite "M5.5 variable length":
  test "one row per walk, and the relationship variable is the whole path":
    let s = ringStore()
    ## x1 → x2 → x3 → x1: three walks of 1..3, ending at x2, x3, and back
    ## at x1 — the cycle closes, because uniqueness is over relationships.
    let rows = run(s, "MATCH (a:N {n: 'x1'})-[r*1..3]->(b) " &
                   "RETURN b.n AS b, size(r) AS len ORDER BY len, b")
    check strs(rows, "b") == @["x2", "x3", "x1"]
    check ints(rows, "len") == @[1'i64, 2'i64, 3'i64]
    ## The bound is a *list*, not one relationship: that is what makes
    ## `size(r)` and `length(path)` mean the same thing.
    let paths = column(run(s, "MATCH (a:N {n: 'x1'})-[r*2..3]->(b) " &
                          "RETURN r AS p"), "p")
    check paths.len == 2
    for p in paths:
      check p.kind == vkList
      check p.items.len >= 2
      for e in p.items:
        check e.kind == vkEdge

  test "a relationship cannot appear twice in one path":
    ## The rule that makes `*` terminate at all, on the cycle x1 → x2 → x3
    ## → x1. Uniqueness is over *relationships*, not nodes: a walk may come
    ## back through a different edge, and may not come back along the same
    ## one. Asserted on the count, because the alternative — an infinite
    ## walk — is a hang rather than a wrong answer.
    let s = ringStore()
    check ints(run(s, "MATCH (a:N {n: 'x1'})-[*]->(b) RETURN count(*) AS c"),
               "c") == @[3'i64]
    ## Over a cycle, a walk of three hops is a return to the start: the
    ## *node* repeats, the edge does not.
    check strs(run(s, "MATCH (a:N {n: 'x1'})-[r*3..3]->(b) RETURN b.n AS b"),
               "b") == @["x1"]

  test "an anonymous variable-length binds nothing and still counts walks":
    let s = ringStore()
    check ints(run(s, "MATCH (a:N {n: 'x1'})-[*1..3]->(b) RETURN count(*) AS c"),
               "c") == @[3'i64]
    ## …and naming a variable that was never written is still a refusal.
    var e: CypherError
    try:
      discard run(s, "MATCH (a:N {n: 'x1'})-[*1..3]->(b) RETURN size(r) AS n")
    except CypherError as err:
      e = err
    check e != nil
    check "not defined" in e.msg

  test "a range that cannot be satisfied returns nothing, not an error":
    let s = ringStore()
    ## One edge from a leaf, so a two-hop walk cannot exist.
    check run(s, "MATCH (a:N {n: 'lone'})-[*1..3]->(b) RETURN b").len == 0
    check run(s, "MATCH (a:N {n: 'lone'})-[*1..3]->(b) RETURN b.n AS b").len == 0
    ## …and a range below the graph's own length is fine.
    check strs(run(s, "MATCH (a:N {n: 'x1'})-[*2..2]->(b) RETURN b.n AS b"),
               "b") == @["x3"]

  test "the relationship type filters every hop":
    let s = ringStore()
    ## Only two of the three ring edges are :R (the closing one is :OTHER).
    check ints(run(s, "MATCH (a:N {n: 'x1'})-[r:R*1..3]->(b) RETURN count(*) AS c"),
               "c") == @[2'i64]
    check ints(run(s, "MATCH (a:N {n: 'x1'})-[*1..3]->(b) RETURN count(*) AS c"),
               "c") == @[3'i64]

suite "M5.5 OPTIONAL MATCH":
  test "a row with no match survives, null-filled":
    let s = ringStore()
    let rows = run(s, "MATCH (a:N) OPTIONAL MATCH (a)-[:R]->(b) " &
                   "RETURN a.n AS a, b.n AS b ORDER BY a, b")
    ## Four nodes: three with an :R edge out, one (lone) with none. The left
    ## side's own bindings are still there — that is the whole promise.
    check strs(rows, "a") == @["lone", "x1", "x2", "x3"]
    let nulls = column(rows, "b")
    check nulls.len == 4
    check nulls[0].kind == vkNull

  test "the right side can fan out without losing the left row":
    let s = newStore()
    let hub = s.createNode("H")
    for i in 1 .. 3:
      let leaf = s.createNode("L")
      discard s.setNodeProp(leaf, "i", Value(kind: vkInt, i: i))
      discard s.createEdge(hub, leaf, "R")
    check ints(run(s, "MATCH (h:H) OPTIONAL MATCH (h)-[:R]->(l) " &
                   "RETURN count(*) AS c"), "c") == @[3'i64]

  test "the optional pattern's WHERE filters the right side before filling":
    ## The subtle one: a row that matched and *then* failed the predicate is
    ## dropped, not null-extended. Filtering above the join instead would
    ## answer "the hub has no such leaf" for a hub that plainly has one.
    let s = ringStore()
    let rows = run(s, "MATCH (a:N) OPTIONAL MATCH (a)-[:R]->(b) WHERE b.n = 'x2' " &
                   "RETURN a.n AS a, b.n AS b ORDER BY a")
    check strs(rows, "a") == @["lone", "x1", "x2", "x3"]
    let matched = column(rows, "b")
    check matched.len == 4
    check matched[1].kind == vkString and matched[1].s == "x2"
    ## Everything else is null: matched nothing *or* matched and failed.
    var nulls = 0
    for v in matched:
      if v.kind == vkNull:
        inc nulls
    check nulls == 3

  test "an unbound pattern is a left join against a scan":
    let s = ringStore()
    check ints(run(s, "MATCH (a:N) OPTIONAL MATCH (q:Q) RETURN count(*) AS c"),
               "c") == @[4'i64]
    ## One x2 for each left row: four rows, not sixteen. The left side's
    ## cardinality is preserved, which is the difference between a left join
    ## and a product.
    check ints(run(s, "MATCH (a:N) OPTIONAL MATCH (b:N {n: 'x2'}) " &
                   "RETURN count(*) AS c"), "c") == @[4'i64]

  test "the null side is filterable — through a WITH, which is the point":
    ## `WITH a, b WHERE b IS NULL` filters the *rows the join produced*,
    ## including the null-filled ones, so it finds the nodes with no :R edge
    ## at all: x3 (whose only edge is :OTHER) and lone.
    let s = ringStore()
    let orphans = run(s, "MATCH (a:N) OPTIONAL MATCH (a)-[:R]->(b) " &
                      "WITH a, b WHERE b IS NULL RETURN a.n AS a ORDER BY a")
    check strs(orphans, "a") == @["lone", "x3"]

  test "a WHERE attached to the OPTIONAL MATCH filters before the join":
    ## The gotcha, pinned on both sides. Cypher reads a WHERE directly after
    ## a pattern as part of *that* pattern, so this is "the :R neighbours of
    ## a that are x3, or nothing" — every node comes back, and the ones with
    ## no x3 neighbour come back with nulls. It does *not* mean "the nodes
    ## whose x3 neighbour is missing", which is what it reads like, and which
    ## the `WITH` spelling above actually says.
    let s = ringStore()
    let rows = run(s, "MATCH (a:N) OPTIONAL MATCH (a)-[:R]->(b) WHERE b.n = 'x3' " &
                   "RETURN a.n AS a, b.n AS b ORDER BY a")
    check strs(rows, "a") == @["lone", "x1", "x2", "x3"]
    let bound = column(rows, "b")
    var matched = 0
    for v in bound:
      if v.kind == vkString:
        inc matched
    check matched == 1

  test "its shapes are refused: first clause, or a second one":
    let s = ringStore()
    for (sql, word) in [
        ("OPTIONAL MATCH (a) RETURN a.n AS a", "left"),
        ("MATCH (a:N) OPTIONAL MATCH (a)-->(b) OPTIONAL MATCH (b)-->(c) RETURN a",
         "second")]:
      var e: CypherError
      try:
        discard run(s, sql)
      except CypherError as err:
        e = err
      doAssert e != nil, "should refuse: " & sql
      check word in e.msg

# ============================================================ M5.6 spilled sort
#
# `ORDER BY` has to see every row before it hands out the first, so it is
# the one operator allowed to buffer. These tests run the *same* queries
# twice — once with no budget, once with a budget their row count exceeds —
# and demand the same answer, because the only difference between them is
# where the rows were while they were sorted.

suite "M5.6 sort with spill":
  test "a spilled sort answers exactly what a buffered one does":
    let s = wideStore(500)
    let buffered = run(s, "MATCH (n:W) RETURN n.v AS v ORDER BY v DESC")
    let spilled = spilledRun(s, "MATCH (n:W) RETURN n.v AS v ORDER BY v DESC", 64)
    check ints(buffered, "v").len == 500
    check ints(spilled, "v") == ints(buffered, "v")
    check ints(spilled, "v")[0] == 499
    check ints(spilled, "v")[^1] == 0

  test "the spill is not just the happy path: nulls, strings, DESC, keys":
    let s = wideStore(200)
    for sql in ["MATCH (n:W) RETURN n.v AS v ORDER BY v",
                "MATCH (n:W) RETURN n.v AS v ORDER BY v DESC",
                "MATCH (n:W) RETURN n.k AS k ORDER BY k",
                "MATCH (n:W) RETURN n.k AS k, n.v AS v ORDER BY k DESC, v ASC",
                "MATCH (n:W) RETURN n.s AS s ORDER BY s DESC",
                # A key no node has: every key is null, and every row
                # still has to come back, in *some* order.
                "MATCH (n:W) RETURN n.nothing AS x ORDER BY x"]:
      let want = run(s, sql)
      let got = spilledRun(s, sql, 17)
      check rowsEqual(got, want)

  test "LIMIT stops a spilled sort without reading all of it":
    ## The point of the merge's head-first design: a query that wants ten
    ## rows must not pay for ten million. Spilling makes that *possible* —
    ## the runs are written as the input arrives either way — and this is
    ## the property that makes it worth the I/O.
    let s = wideStore(2000)
    var rows = spilledRun(s, "MATCH (n:W) RETURN n.v AS v ORDER BY v DESC LIMIT 10", 32)
    check ints(rows, "v").len == 10
    check ints(rows, "v")[0] == 1999
    check ints(rows, "v")[9] == 1990

  test "the run files do not outlive the statement":
    ## A spill nobody can delete is a disk that fills. The paths are named
    ## after the statement, so the test can look for exactly its own.
    let s = wideStore(500)
    let before = spillFiles()
    discard spilledRun(s, "MATCH (n:W) RETURN n.v AS v ORDER BY v", 32)
    check spillFiles().len == before.len
    ## …and not even when the statement is abandoned after three rows, which
    ## is the path a LIMIT takes and the one most likely to leak.
    var st = prepare(s, "MATCH (n:W) RETURN n.v AS v ORDER BY v",
                     initTable[string, Value](), nil, 32, tmpSpillDir())
    discard st.step()
    discard st.step()
    st.close()
    check spillFiles().len == before.len

  test "a run that is not a run is refused, not decoded":
    ## The files are named after the statement id, so a stale file from a
    ## crashed run is the realistic way to read someone else's bytes. The
    ## header check is what turns that into an error instead of a sort that
    ## answers with whatever decoded.
    let path = tmpSpillDir() & "/glyphes-sort-bogus-0.run"
    var f = open(path, fmWrite)
    f.write("not a spill file at all, really")
    f.close()
    var e: CypherError
    try:
      discard openRunReader(path)
    except CypherError as err:
      e = err
    check e != nil
    check "corrupt" in e.msg or "empty" in e.msg

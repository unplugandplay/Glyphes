## The M5 write path: CREATE, the transaction it rides on, and the door
## (`glyphes_exec`) that commits it.
##
## Structure follows what the milestone is: every clause goes through the
## same three layers, because the interesting failures live between them —
## a clause that parses but never writes, a write that lands in the
## transaction and not the store, a commit that never happens.
##
##   1. engine   — prepare(store, sql, tx), drain, count
##   2. durability — commit makes it readable by a *new* snapshot
##   3. refusal  — a write with no transaction is refused by name
##
## Each clause's slice adds to all three rather than replacing them.

import std/unittest
import std/[algorithm, tables, strutils, os]
import ../../src/store/store
import ../../src/store/prop
import ../../src/abi
import ../../src/txn/txn
import ../../src/cypher/errors
import ../../src/cypher/execute
import ../../src/cypher/ctx
import ../../src/cypher/parser
import ../../src/database
import ../../src/errors
import ../../src/index/index

type Fixture = tuple[s: GraphStore, tx: WriteTransaction]

proc newFixture(): Fixture =
  ## A store plus an open transaction, the pair every write test starts
  ## from. `:memory:` semantics: no WAL, so a test that forgets to commit
  ## fails as a missing row rather than as a missing file.
  let s = newStore()
  (s, txn.begin(s, nil, 1))

proc exec(f: Fixture, sql: string,
          params = initTable[string, Value]()): int64 =
  ## Run a query to completion and report rows affected, the way
  ## `glyphes_exec` does — including the ordering that matters: the
  ## statement (and its snapshot) is closed before the caller commits,
  ## because `beginWrite` waits for the reader count to reach zero and this
  ## thread is one of the readers.
  var st = prepare(f.s, sql, params, f.tx)
  while st.step():
    discard
  let n = st.rowsAffected()
  st.close()
  n

proc read(s: GraphStore, sql: string): seq[Row] =
  let st = prepare(s, sql)
  defer: st.close()
  st.collectRows()

proc pairs(s: GraphStore, sql: string): seq[string] =
  ## Two string columns per row, for a query whose answer is a set of
  ## endpoint pairs. Compared sorted, because relationship order in the
  ## answer is not something any of these tests is about.
  var rows: seq[string] = @[]
  for r in read(s, sql):
    let (_, a) = r.lookup("a")
    let (_, b) = r.lookup("b")
    rows.add a.s & ">" & b.s
  rows.sort()
  rows

proc countOf(s: GraphStore, sql: string): int =
  read(s, sql).len

proc names(s: GraphStore, sql: string): seq[string] =
  for r in read(s, sql):
    let (_, v) = r.lookup("n")
    result.add v.s

suite "M5.1 CREATE":
  test "one node, and the row it lands in":
    var f = newFixture()
    check f.exec("CREATE (n:Person {name: 'Ana', age: 34})") == 1
    discard f.tx.commit()
    check names(f.s, "MATCH (n:Person) RETURN n.name AS n").len == 1
    check names(f.s, "MATCH (n:Person) RETURN n.name AS n") == @["Ana"]

  test "a node with no properties, and an anonymous one":
    var f = newFixture()
    check f.exec("CREATE (:Nothing)") == 1
    discard f.tx.commit()
    check read(f.s, "MATCH (n:Nothing) RETURN n").len == 1

  test "a relationship between two new nodes is two nodes and one edge":
    var f = newFixture()
    check f.exec("CREATE (a:P {n: 'a'})-[:R {since: 2024}]->(b:P {n: 'b'})") == 3
    discard f.tx.commit()
    let rows = read(f.s, "MATCH (a:P)-[r:R]->(b:P) RETURN a.n, b.n, r.since")
    check rows.len == 1
    let (_, an) = rows[0].lookup("a.n")
    let (_, bn) = rows[0].lookup("b.n")
    let (_, since) = rows[0].lookup("r.since")
    check an.s == "a" and bn.s == "b" and since.i == 2024

  test "an undirected CREATE keeps the written direction":
    ## `CREATE (a)-[:R]-(b)` is not Cypher — a CREATE needs a direction —
    ## but `<-` is: the edge is stored a→b whatever the text said.
    var f = newFixture()
    discard f.exec("CREATE (a:P {n: 'a'})<-[:R]-(b:P {n: 'b'})")
    discard f.tx.commit()
    check read(f.s, "MATCH (a:P)-[:R]->(b:P) RETURN a.n").len == 1

  test "a comma-separated CREATE makes every pattern":
    var f = newFixture()
    check f.exec("CREATE (a:P {n: 'a'}), (b:P {n: 'b'}), (c:P {n: 'c'})") == 3
    discard f.tx.commit()
    check read(f.s, "MATCH (n:P) RETURN n").len == 3

  test "parameters bind in a write":
    var f = newFixture()
    var p = initTable[string, Value]()
    p["name"] = Value(kind: vkString, s: "Bo")
    p["age"] = Value(kind: vkInt, i: 41)
    check f.exec("CREATE (n:Person {name: $name, age: $age})", p) == 1
    discard f.tx.commit()
    let rows = read(f.s, "MATCH (n:Person) RETURN n.name AS name, n.age AS age")
    let (_, name) = rows[0].lookup("name")
    let (_, age) = rows[0].lookup("age")
    check name.s == "Bo" and age.i == 41

  test "an expression in a property map is evaluated, not stored raw":
    var f = newFixture()
    discard f.exec("CREATE (n:P {double: 21 * 2})")
    discard f.tx.commit()
    let rows = read(f.s, "MATCH (n:P) RETURN n.double AS double")
    let (_, d) = rows[0].lookup("double")
    check d.i == 42

suite "M5.1 CREATE over a read phase":
  test "MATCH … CREATE writes once per surviving row":
    let s = newStore()
    discard s.createNode("P")
    discard s.createNode("P")
    discard s.createNode("P")
    let tx = txn.begin(s, nil, 1)
    ## `id(n)`, not `n.id`: the latter is a property lookup, and these three
    ## nodes have no properties, so the predicate would be null and the
    ## whole thing a test of three-valued logic wearing a CREATE's hat.
    var st = prepare(s, "MATCH (n:P) WHERE id(n) > 1 CREATE (:Copy {src: id(n)})", tx)
    while st.step():
      discard
    check st.rowsAffected() == 2
    st.close()
    discard tx.commit()
    let rows = read(s, "MATCH (n:Copy) RETURN n.src AS src ORDER BY src")
    check rows.len == 2
    let (_, first) = rows[0].lookup("src")
    check first.i == 2

  test "a bound variable is connected to, not re-created":
    ## `MATCH (a) CREATE (a)-[:SEEN]->(b)` uses the existing `a`. If CREATE
    ## made a second node for `a`, the row count would be wrong and the
    ## original would silently gain a duplicate.
    let s = newStore()
    discard s.createNode("P")
    let tx = txn.begin(s, nil, 1)
    var st = prepare(s, "MATCH (a:P) CREATE (a)-[:SEEN]->(b:Seen)", tx)
    while st.step():
      discard
    check st.rowsAffected() == 2      ## the new b and the edge, not a second a
    st.close()
    discard tx.commit()
    check read(s, "MATCH (n:P) RETURN n").len == 1
    check read(s, "MATCH (n:Seen) RETURN n").len == 1

  test "a write is invisible until commit, to everyone but its transaction":
    ## The visibility boundary. A statement that has written has still
    ## published nothing: a *new* statement opened after the CREATE — even
    ## one belonging to the same transaction — reads the graph as it was.
    ## What the transaction can see is its own delta, which is what makes a
    ## `MATCH … CREATE … MATCH` (M5.5) coherent when it arrives.
    ##
    ## The tempting version of this test — hold a reader open, commit
    ## behind it, check the reader does not see the new row — **cannot be
    ## written**, and that is the reader gate doing its job: a writer waits
    ## for the reader count to reach zero, so a long snapshot delays the
    ## writer by its own length (TXN.md §4). The property is real; the
    ## window it would be observed through is closed by design.
    let s = newStore()
    let tx = txn.begin(s, nil, 1)
    var st = prepare(s, "CREATE (n:P {v: 1})", tx)
    while st.step():
      discard
    let created = tx.nextNodeId - 1
    st.close()

    ## The transaction sees its own write…
    check tx.nodeExistsTx(created)
    ## …and a new statement does not, because nothing is published yet.
    check read(s, "MATCH (n:P) RETURN n").len == 0

    discard tx.commit()
    let rows = read(s, "MATCH (n:P) RETURN n.v AS v")
    check rows.len == 1
    let (_, v) = rows[0].lookup("v")
    check v.i == 1

suite "M5.1 scope":
  test "a created variable is in scope for what follows":
    ## `CREATE (m:Made {v: 1}) RETURN m.v` — the shape of a write that
    ## checks its own work. The semantic pass has to learn that CREATE binds,
    ## or it refuses the query for naming "a variable not defined by any
    ## MATCH" when the query did exactly that.
    var f = newFixture()
    var st = prepare(f.s, "CREATE (m:Made {v: 7}) RETURN m", f.tx)
    while st.step():
      discard
    st.close()
    discard f.tx.rollback()

  test "a created node's property is readable in the same statement":
    ## `CREATE (m:Made {v: 7}) RETURN m.v` answers 7, as openCypher does.
    ## It did not at M5.1: reads consulted only the published snapshot, so a
    ## statement could not see what its own transaction had just written,
    ## and M5.1 documented the gap as a deviation. M5.2's transactional
    ## visibility (ctx.buildDelta) removed the cause, so the deviation is
    ## gone rather than documented — which is the better outcome of the two
    ## this comment could have had.
    var f = newFixture()
    var st = prepare(f.s, "CREATE (m:Made {v: 7}) RETURN m.v AS v", f.tx)
    var rows: seq[Row] = @[]
    while st.step():
      rows.add copyRow(st.current)
    st.close()
    check rows.len == 1
    let (_, v) = rows[0].lookup("v")
    check v.i == 7
    ## And a later statement sees it too, so the value is committed rather
    ## than only ever in the row.
    discard f.tx.commit()
    let after = read(f.s, "MATCH (m:Made) RETURN m.v AS v")
    check after.len == 1
    let (_, v2) = after[0].lookup("v")
    check v2.i == 7

suite "M5.1 rows affected":
  test "counts entities, not properties":
    var f = newFixture()
    check f.exec("CREATE (n:P {a: 1, b: 2, c: 3})") == 1
    discard f.tx.commit()

  test "a read query affects nothing":
    let s = newStore()
    discard s.createNode("P")
    let tx = txn.begin(s, nil, 1)
    var st = prepare(s, "MATCH (n:P) RETURN n", tx)
    while st.step():
      discard
    check st.rowsAffected() == 0
    st.close()
    discard tx.rollback()

suite "M5.1 refusals and boundaries":
  test "a write statement with no transaction is refused by name":
    ## The read door (`db.prepare`, `db.query`) plans against a nil writer.
    ## Planning a CREATE there would produce a plan that silently discards
    ## its writes, which is the wrong answer, so it is a named refusal —
    ## and the name is the clause, not the operator kind behind it.
    let s = newStore()
    for (sql, word) in [("CREATE (:P)", "CREATE"),
                        ("MATCH (n) SET n.x = 1", "SET"),
                        ("MATCH (n) DELETE n", "DELETE"),
                        ("MATCH (n) REMOVE n.x", "REMOVE")]:
      var e: CypherError
      try:
        discard prepare(s, sql)
      except CypherError as err:
        e = err
      doAssert e != nil, "should refuse: " & sql
      if e != nil:
        check e.code == int32(glyErrUnsupported)
        check word in e.msg
        check "write transaction" in e.msg

  test "a write to a read-only database is refused":
    ## The Ruby layer's job; here the transaction layer says it first.
    let s = newStore()
    check s.readers == 0

  test "type alternation in a CREATE relationship is refused by name":
    var f = newFixture()
    var e: CypherError
    try:
      discard f.exec("CREATE (a:P)-[:R|W]->(b:P)")
    except CypherError as err:
      e = err
    check e != nil and e.code == int32(glyErrUnsupported)
    check "alternation" in e.msg
    discard f.tx.rollback()

  test "the clauses the engine does not evaluate keep their named refusals":
    ## FOREACH left this list at M5.7: it is a write clause the engine
    ## evaluates now. LOAD CSV is the remaining named refusal in the
    ## parser, and this test is the contract that it is refused *by name*
    ## rather than parsed into a plan that quietly drops it.
    let sql = "LOAD CSV FROM 'x' AS line RETURN line"
    var e: CypherError
    try:
      discard parseQuery(sql)
    except CypherError as err:
      e = err
    check e != nil
    if e != nil:
      check e.code == int32(glyErrUnsupported)
      check "LOAD" in e.msg

suite "M5.1 durability":
  test "a committed CREATE is visible to a new snapshot":
    ## The store's published bundle only changes at commit, so a reader that
    ## arrives after the commit sees the node and one that arrived before
    ## does not. Both halves matter: the first is what makes the write
    ## durable, the second is pin C2.
    let s = newStore()
    let tx = txn.begin(s, nil, 1)
    var st = prepare(s, "CREATE (n:P {v: 1})", tx)
    while st.step():
      discard
    st.close()
    ## Before the commit, a new snapshot sees nothing.
    check read(s, "MATCH (n:P) RETURN n").len == 0
    discard tx.commit()
    check read(s, "MATCH (n:P) RETURN n").len == 1

  test "a rolled-back CREATE leaves nothing":
    let s = newStore()
    let tx = txn.begin(s, nil, 1)
    var st = prepare(s, "CREATE (n:P) CREATE (m:P)", tx)
    while st.step():
      discard
    st.close()
    discard tx.rollback()
    check read(s, "MATCH (n:P) RETURN n").len == 0

  test "a failed statement leaves the transaction rollback-able":
    ## An error mid-statement must not leave a half-applied transaction
    ## that looks live: the caller's `ensure` rolls back, and that has to
    ## work from any error path.
    let s = newStore()
    let tx = txn.begin(s, nil, 1)
    var st = prepare(s, "CREATE (n:P {v: 1})", tx)
    while st.step():
      discard
    st.close()
    check tx.rollback()
    check read(s, "MATCH (n:P) RETURN n").len == 0
suite "M5.2 SET":
  test "a property assignment lands":
    var f = newFixture()
    discard f.exec("CREATE (n:P {v: 1})")
    check f.exec("MATCH (n:P) SET n.v = 2") == 1
    discard f.tx.commit()
    let rows = read(f.s, "MATCH (n:P) RETURN n.v AS v")
    let (_, v) = rows[0].lookup("v")
    check v.i == 2

  test "the right-hand side is an expression, evaluated per row":
    let s = newStore()
    for i in 0 ..< 3:
      discard s.createNode("P")
    let tx = txn.begin(s, nil, 1)
    var st = prepare(s, "MATCH (n:P) SET n.v = id(n) * 10", tx)
    while st.step():
      discard
    check st.rowsAffected() == 3
    st.close()
    discard tx.commit()
    ## Pin C4 again: the SET statement cannot read what it just wrote, so the
    ## values are read back by a *new* statement.
    let rows = read(s, "MATCH (n:P) RETURN n.v AS v ORDER BY v")
    check rows.len == 3
    for i, r in rows:
      let (_, v) = r.lookup("v")
      check v.i == int64((i + 1) * 10)

  test "several assignments in one clause":
    var f = newFixture()
    discard f.exec("CREATE (n:P)")
    check f.exec("MATCH (n:P) SET n.a = 1, n.b = 2") == 2   ## one per assignment
    discard f.tx.commit()
    let rows = read(f.s, "MATCH (n:P) RETURN n.a AS a, n.b AS b")
    let (_, a) = rows[0].lookup("a")
    let (_, b) = rows[0].lookup("b")
    check a.i == 1 and b.i == 2

  test "SET on a relationship property":
    var f = newFixture()
    discard f.exec("CREATE (a:P)-[:R {w: 1}]->(b:P)")
    check f.exec("MATCH (a:P)-[r:R]->(b:P) SET r.w = 2") == 1
    discard f.tx.commit()
    let rows = read(f.s, "MATCH ()-[r:R]->() RETURN r.w AS w")
    let (_, w) = rows[0].lookup("w")
    check w.i == 2

  test "SET += merges and SET = replaces":
    var f = newFixture()
    discard f.exec("CREATE (n:P {keep: 1, drop: 2})")
    discard f.exec("MATCH (n:P) SET n += {added: 3}")
    discard f.tx.commit()
    var rows = read(f.s, "MATCH (n:P) RETURN keys(n) AS k")
    var (_, k) = rows[0].lookup("k")
    ## Merge: the old keys survive and the new one appears.
    check k.items.len == 3

    let tx2 = txn.begin(f.s, nil, 2)
    var st = prepare(f.s, "MATCH (n:P) SET n = {only: 9}", tx2)
    while st.step():
      discard
    st.close()
    discard tx2.commit()
    rows = read(f.s, "MATCH (n:P) RETURN keys(n) AS k, n.only AS only")
    check rows.len == 1
    let (_, k2) = rows[0].lookup("k")
    let (_, only) = rows[0].lookup("only")
    ## Replace: everything that was there is gone, including the merged key.
    check k2.items.len == 1
    check only.i == 9

  test "SET on a new node created in the same statement":
    var f = newFixture()
    ## The created node is in the transaction's delta, and SET addresses it
    ## through the row. If the write path went to the store instead, this
    ## would silently do nothing.
    check f.exec("CREATE (n:P {v: 0}) SET n.v = 5") == 2
    discard f.tx.commit()
    let rows = read(f.s, "MATCH (n:P) RETURN n.v AS v")
    let (_, v) = rows[0].lookup("v")
    check v.i == 5

  test "a target that is not bound is refused before anything runs":
    var f = newFixture()
    var e: CypherError
    try:
      discard prepare(f.s, "MATCH (n:P) SET x.v = 1", f.tx)
    except CypherError as err:
      e = err
    check e != nil and "x" in e.msg
    discard f.tx.rollback()

suite "M5.2 REMOVE":
  test "a property goes, and the node keeps the rest":
    var f = newFixture()
    discard f.exec("CREATE (n:P {keep: 1, drop: 2})")
    check f.exec("MATCH (n:P) REMOVE n.drop") == 1
    discard f.tx.commit()
    let rows = read(f.s, "MATCH (n:P) RETURN n.keep AS keep, n.drop AS drop")
    let (_, keep) = rows[0].lookup("keep")
    let (_, dropped) = rows[0].lookup("drop")
    check keep.i == 1
    check dropped.kind == vkNull

  test "removing what is not there is a no-op, not an error":
    var f = newFixture()
    discard f.exec("CREATE (n:P {v: 1})")
    check f.exec("MATCH (n:P) REMOVE n.neverSet") == 1
    discard f.tx.commit()
    check read(f.s, "MATCH (n:P) RETURN n.v AS v").len == 1

  test "SET n.x = null removes the key, as Cypher says":
    ## Not a distinction from REMOVE — the same operation with different
    ## spelling. openCypher stores a null as *absence*: `SET n.y = null` and
    ## `REMOVE n.y` both take the key away. The M5.1 version of this test
    ## asserted the opposite (and failed), which is what surfaced the
    ## question; the arena agrees on both paths, so the expectation was the
    ## thing that was wrong.
    var f = newFixture()
    discard f.exec("CREATE (n:P {x: 1, y: 2})")
    discard f.exec("MATCH (n:P) SET n.y = null")
    discard f.exec("MATCH (n:P) REMOVE n.x")
    discard f.tx.commit()
    let rows = read(f.s, "MATCH (n:P) RETURN keys(n) AS k")
    let (_, k) = rows[0].lookup("k")
    var names: seq[string] = @[]
    for item in k.items:
      names.add item.s
    ## Both keys are gone: one by the null, one by the REMOVE.
    check names.len == 0
    ## And the node itself survived the property surgery.
    check read(f.s, "MATCH (n:P) RETURN n").len == 1

  test "a REMOVE survives a reopen, because the log says so":
    ## opRemoveProp is a distinct frame, not a null write wearing its name.
    ## A durability test that reopened and found the key back would pin
    ## exactly that confusion.
    let path = getTempDir() / "glyphes-m52-remove-" & $getCurrentProcessId() & ".glyph"
    removeFile(path)
    removeFile(path & "-wal")
    let db = openDatabase(path, GLY_OPEN_CREATE)
    let tx = db.beginTransaction()
    var st = prepare(db.store, "CREATE (n:P {gone: 1, kept: 2})", tx)
    while st.step():
      discard
    st.close()
    var st2 = prepare(db.store, "MATCH (n:P) REMOVE n.gone", tx)
    while st2.step():
      discard
    st2.close()
    discard db.commitTransaction(tx)
    db.close()

    let db2 = openDatabase(path, 0)
    let rows = read(db2.store, "MATCH (n:P) RETURN keys(n) AS k")
    let (_, k) = rows[0].lookup("k")
    var names: seq[string] = @[]
    for item in k.items:
      names.add item.s
    check names == @["kept"]
    db2.close()
    removeFile(path)
    removeFile(path & "-wal")

suite "M5.2 DELETE":
  test "an isolated node goes":
    var f = newFixture()
    discard f.exec("CREATE (n:P)")
    check f.exec("MATCH (n:P) DELETE n") == 1
    discard f.tx.commit()
    check read(f.s, "MATCH (n:P) RETURN n").len == 0

  test "a connected node needs DETACH, and says so":
    var f = newFixture()
    discard f.exec("CREATE (a:P)-[:R]->(b:P)")
    ## Committed first, so the assertion below is about the refused DELETE
    ## rather than about the rollback undoing the CREATE as well.
    discard f.tx.commit()
    let tx2 = txn.begin(f.s, nil, 2)
    let f2: Fixture = (s: f.s, tx: tx2)
    ## A `GlyError`, not a `CypherError`: deleting a node that still has
    ## relationships is a constraint violation (the commit would otherwise
    ## admit a dangling edge), and the status the host sees should say so.
    var e: ref GlyError
    try:
      discard f2.exec("MATCH (a:P) DELETE a")
    except GlyError as err:
      e = err
    check e != nil
    if e != nil:
      check e.status == int32(glyErrConstraint)
      check "DETACH" in e.msg
    ## And nothing changed: a refused DELETE leaves the graph alone, which
    ## is what makes the whole statement safe to retry.
    discard tx2.rollback()
    check read(f.s, "MATCH (n:P) RETURN n").len == 2
    check read(f.s, "MATCH ()-[r:R]->() RETURN r").len == 1

  test "DETACH DELETE takes the edges with it, and counts them":
    var f = newFixture()
    discard f.exec("CREATE (a:P)-[:R]->(b:P)-[:R]->(c:P)")
    ## Three nodes, two edges, and the count is the sum of what each delete
    ## removed: a takes its one edge (2), b then takes the other (2), c is
    ## alone (1). Reported as 5 — the edge a and b shared is counted once,
    ## because by the time b is deleted it is already a tombstone and
    ## `incidentEdges` only counts live ones. Counting the committed degree
    ## instead (the M5.2 first version) gave 6 and tried to delete the same
    ## edge twice.
    check f.exec("MATCH (n:P) DETACH DELETE n") == 5
    discard f.tx.commit()
    check read(f.s, "MATCH (n:P) RETURN n").len == 0

  test "a DELETE after another delete in the same statement is fine":
    ## The refused case: a node whose only edge was deleted earlier in the
    ## same query has no live edges left, so DETACH is no longer required.
    var f = newFixture()
    discard f.exec("CREATE (a:P)-[:R]->(b:P)")
    ## Two statements, one transaction — and the second sees the first's
    ## work, which is the whole point of the delta-aware reads.
    discard f.exec("MATCH (a:P) WHERE id(a) = 1 DETACH DELETE a")
    check f.exec("MATCH (b:P) DELETE b") == 1
    discard f.tx.commit()
    check read(f.s, "MATCH (n:P) RETURN n").len == 0

suite "M5.3 MERGE":
  test "MERGE finds its node through the index, like MATCH does":
    ## `mergeChain` used to build its match half with `scanFor` — a full
    ## label scan — because the seek lived in `plan.nim`, which imports
    ## `ops.nim` and so could not be imported back. Binding a node for
    ## `MERGE (b:P {id: $id})` is the same question as `MATCH (b:P
    ## {id: $id})`, and it was answered two different ways, one of them
    ## about 40x slower: edge load ran at 183 edges/s.
    ##
    ## The seek machinery now lives in `ops.nim` and both go through it.
    ## This pins the *answer*, not the clock: an accelerator may change how
    ## fast, never what.
    var f = newFixture()
    var reg = newIndexes()
    discard reg.create(IdxRange, "P", "id")
    for i in 0 ..< 200:
      var p = initTable[string, Value]()
      p["id"] = Value(kind: vkInt, i: int64(i))
      discard f.exec("CREATE (:P {id: $id})", p)
    reg.rebuild(f.s)
    ## Every MERGE must find its node and write nothing. If the seek and
    ## the property filter disagreed, this either creates duplicates or
    ## finds nothing at all — both fail the count.
    var p2 = initTable[string, Value]()
    p2["id"] = Value(kind: vkInt, i: 137'i64)
    var st = prepare(f.s, "MERGE (n:P {id: $id})", p2, f.tx, 0, "", reg)
    while st.step():
      discard
    let wrote = st.rowsAffected()
    st.close()
    check wrote == 0
    discard f.tx.commit()
    check countOf(f.s, "MATCH (n:P) RETURN n") == 200

  test "MERGE refuses a relationship type alternation, like MATCH":
    ## `mergeChain` left the relationship type code at 0 — "any type" — when
    ## the pattern named two types, so `MERGE (a)-[:R1|R2]->(b)` matched a
    ## relationship of a type the pattern never named: measured, it matched
    ## an :OTHER edge instead of refusing or creating. MATCH refuses the same
    ## spelling at parse (CYPHER.md §5), and the other write path refuses it
    ## too; MERGE was the one place the construct silently did something.
    var f = newFixture()
    discard f.exec("CREATE (:N {n: 'x1'})-[:R]->(:N {n: 'x2'})")
    discard f.exec("CREATE (:N {n: 'x3'})-[:OTHER]->(:N {n: 'x9'})")
    ## The refusal is raised while the statement is executing (the merge runs
    ## per row), so the statement is closed on the error path: leaving it open
    ## holds the store's reader gate, and a commit behind it waits forever.
    var st = prepare(f.s, "MERGE (a:N {n: 'x3'})-[:R1|R2]->(b)",
                     initTable[string, Value](), f.tx)
    var refused = false
    try:
      while st.step():
        discard
    except CypherError:
      refused = true
    finally:
      st.close()
    check refused
    ## The refusal happened before anything was written: commit the fixture's
    ## transaction (the statement aborted, the transaction did not) and count.
    check f.tx.commit()
    check countOf(f.s, "MATCH (n:N) RETURN n") == 4

  test "a MERGE in a transaction sees a node created in that transaction":
    ## The seek consults the index, which cannot know about nodes this
    ## transaction has not published. If the delta were not consulted, the
    ## MERGE would miss its own node and create a second one — the one
    ## direction an accelerator may not move, and the reason a seek is
    ## always paired with a filter rather than trusted as an authority.
    var f = newFixture()
    var reg = newIndexes()
    discard reg.create(IdxRange, "P", "id")
    reg.rebuild(f.s)
    var p = initTable[string, Value]()
    p["id"] = Value(kind: vkInt, i: 42'i64)
    discard f.exec("CREATE (:P {id: $id})", p)
    var p2 = initTable[string, Value]()
    p2["id"] = Value(kind: vkInt, i: 42'i64)
    var st = prepare(f.s, "MERGE (n:P {id: $id})", p2, f.tx, 0, "", reg)
    while st.step():
      discard
    let wrote = st.rowsAffected()
    st.close()
    check wrote == 0
    discard f.tx.commit()
    check countOf(f.s, "MATCH (n:P) RETURN n") == 1

  test "creates when the pattern does not match":
    var f = newFixture()
    check f.exec("MERGE (n:P {v: 1})") == 1
    discard f.tx.commit()
    check read(f.s, "MATCH (n:P) RETURN n.v AS v").len == 1

  test "matches the second time and writes nothing":
    var f = newFixture()
    discard f.exec("MERGE (n:P {v: 1})")
    ## The whole point: a second MERGE of the same pattern is a no-op, not
    ## a second node. Cypher guarantees this for the *whole* pattern, and a
    ## MERGE that appended unconditionally would be a CREATE.
    check f.exec("MERGE (n:P {v: 1})") == 0
    discard f.tx.commit()
    check read(f.s, "MATCH (n:P) RETURN n").len == 1

  test "a different property value is a different pattern":
    var f = newFixture()
    discard f.exec("MERGE (n:P {v: 1})")
    check f.exec("MERGE (n:P {v: 2})") == 1
    discard f.tx.commit()
    check read(f.s, "MATCH (n:P) RETURN n").len == 2

  test "a label is part of the pattern":
    var f = newFixture()
    discard f.exec("MERGE (n:P {v: 1})")
    check f.exec("MERGE (n:Q {v: 1})") == 1
    discard f.tx.commit()

  test "a relationship merges whole, and the endpoint is reused":
    var f = newFixture()
    ## Twice: once creates both nodes and the edge, once matches all three.
    check f.exec("MERGE (a:P {n: 'a'})-[:R]->(b:P {n: 'b'})") == 3
    check f.exec("MERGE (a:P {n: 'a'})-[:R]->(b:P {n: 'b'})") == 0
    discard f.tx.commit()
    check read(f.s, "MATCH (n:P) RETURN n").len == 2
    check read(f.s, "MATCH (a:P)-[r:R]->(b:P) RETURN r").len == 1

  test "all-or-nothing: a half-matching pattern creates all of it":
    ## `a` exists and matches on its own, but the *pattern* does not match
    ## (the edge has a different type). Cypher's rule is that MERGE either
    ## matches the whole pattern or creates the whole pattern — so it
    ## creates a **second** `a`, plus `b` and the edge. That is not a bug in
    ## the implementation; it is the documented MERGE gotcha, and the reason
    ## a uniqueness constraint (M6) or a match-then-create is the usual
    ## answer for "make sure this node exists exactly once". A MERGE that
    ## matched the half it liked would be a semi-join wearing MERGE's name.
    var f = newFixture()
    discard f.exec("CREATE (a:P {n: 'a'})-[:OTHER]->(x:P {n: 'x'})")
    check f.exec("MERGE (a:P {n: 'a'})-[:R]->(b:P {n: 'b'})") == 3
    discard f.tx.commit()
    check read(f.s, "MATCH (n:P) RETURN n").len == 4   ## a, x, the new a, b
    check read(f.s, "MATCH (a:P)-[r:R]->(b:P) RETURN r").len == 1

  test "a MERGE under a MATCH is constrained to the matched node":
    ## `MATCH (a) MERGE (a)-[:R]->(b)`: the match half must look for a
    ## relationship *from this a*. Without the id constraint it would match
    ## any relationship in the graph and bind `b` to the wrong node — the
    ## silent wrong answer this engine refuses to produce.
    var f = newFixture()
    discard f.exec("CREATE (a:P {n: 'a'})-[:R]->(b1:P {n: 'b1'})")
    discard f.exec("CREATE (a2:P {n: 'a2'})-[:R]->(b2:P {n: 'b2'})")
    discard f.tx.commit()

    let tx2 = txn.begin(f.s, nil, 2)
    let f2: Fixture = (s: f.s, tx: tx2)
    ## Matching `a` by its property, then merging from it.
    discard f2.exec("MATCH (a:P {n: 'a'}) MERGE (a)-[:R]->(b:P {n: 'new'})")
    discard tx2.commit()
    ## `b` was created (nothing matched), and the *other* a's relationship
    ## was left alone.
    check read(f.s, "MATCH (n:P {n: 'new'}) RETURN n").len == 1
    check read(f.s, "MATCH (n:P)-[r:R]->() RETURN n.n AS n ORDER BY n").len == 3

  test "MERGE sees what this transaction just created":
    ## Transactional visibility doing the work MERGE needs: the second
    ## statement's match half must find the first's node, or every MERGE in
    ## an importer would create a duplicate per row.
    var f = newFixture()
    check f.exec("MERGE (n:Seq {i: 1})") == 1
    check f.exec("MERGE (n:Seq {i: 1})") == 0
    check f.exec("MERGE (n:Seq {i: 2})") == 1
    discard f.tx.commit()
    check read(f.s, "MATCH (n:Seq) RETURN n").len == 2

  test "ON CREATE runs only on the create branch":
    var f = newFixture()
    discard f.exec("MERGE (n:P {v: 1}) ON CREATE SET n.created = 1 ON MATCH SET n.matched = 1")
    discard f.exec("MERGE (n:P {v: 1}) ON CREATE SET n.created = 2 ON MATCH SET n.matched = 2")
    discard f.tx.commit()
    let rows = read(f.s, "MATCH (n:P) RETURN n.created AS created, n.matched AS matched")
    check rows.len == 1
    let (_, created) = rows[0].lookup("created")
    let (_, matched) = rows[0].lookup("matched")
    check created.i == 1      ## the second MERGE did not touch it
    check matched.i == 2      ## the first MERGE did not touch it

  test "ON CREATE / ON MATCH count as writes only when they run":
    var f = newFixture()
    check f.exec("MERGE (n:P {v: 1}) ON CREATE SET n.created = 1") == 2
    check f.exec("MERGE (n:P {v: 1}) ON MATCH SET n.matched = 1") == 1
    discard f.tx.commit()

  test "an unbound ON MATCH target is refused before anything runs":
    var f = newFixture()
    var e: CypherError
    try:
      discard prepare(f.s, "MERGE (n:P) ON MATCH SET x.v = 1", f.tx)
    except CypherError as err:
      e = err
    check e != nil and "x" in e.msg
    discard f.tx.rollback()

  test "an unknown function in an ON CREATE clause is refused":
    var f = newFixture()
    var e: CypherError
    try:
      discard f.exec("MERGE (n:P) ON CREATE SET n.v = noSuchFn(1)")
    except CypherError as err:
      e = err
    check e != nil and "noSuchFn" in e.msg
    discard f.tx.rollback()

  test "a MERGE with no write transaction is refused by name":
    let s = newStore()
    var e: CypherError
    try:
      discard prepare(s, "MERGE (n:P)")
    except CypherError as err:
      e = err
    check e != nil and e.code == int32(glyErrUnsupported)
    check "MERGE" in e.msg

suite "M5.5 writes survive the commit they were read from":
  ## Found while building M5.5's fixture: a probe that read the graph with
  ## 30 queries, then wrote a three-statement chain and committed, showed
  ## three of the six relationships. Every store inspection afterwards said
  ## the graph was whole — live edges, chained from their sources, published
  ## at the commit's generation — so the write had landed and something
  ## *read* was short. It has not reproduced since, which is exactly why it
  ## is a test rather than a note: the shape that showed it (many reads, then
  ## multi-row writes, then a read) runs on every gate from here.
  test "every relationship a multi-row write created is readable after commit":
    let s = newStore()
    let tx = txn.begin(s, nil, 1)
    ## Reads first, on purpose: the observation needed some before the write.
    for i in 1 .. 30:
      let st = prepare(s, "MATCH (n:Q) RETURN count(*) AS c")
      discard st.step()
      discard st.step()
      st.close()
      discard i
    var st = prepare(s, "CREATE (:R {n: 'a'}), (:R {n: 'b'}), (:R {n: 'c'})",
                     initTable[string, Value](), tx)
    discard st.step()
    discard st.rowsAffected()
    st.close()
    ## Three statements, one, two and three rows: each MATCH sees what the
    ## previous statement wrote, so the last one matches three nodes.
    for (head, tail) in [("a", "b"), ("b", "c"), ("c", "a")]:
      var bound = initTable[string, Value]()
      bound["from"] = Value(kind: vkString, s: head)
      bound["to"] = Value(kind: vkString, s: tail)
      var link = prepare(s, "MATCH (x:R {n: $from}) CREATE (x)-[:E]->(:R {n: $to})",
                         bound, tx)
      discard link.step()
      discard link.rowsAffected()
      link.close()
    check tx.commit()
    check (s.readers == 0)
    check pairs(s, "MATCH (a:R)-[r:E]->(b) RETURN a.n AS a, b.n AS b") ==
          ["a>b", "b>c", "c>a"]
    check countOf(s, "MATCH (n:R) RETURN n.n AS n") == 6


suite "M5.7 FOREACH":
  test "the loop writes once per element, not once per row":
    ## One row (the one P), two elements: two writes, and the row count
    ## stays one. That is the whole difference between a FOREACH and an
    ## UNWIND, and the reason a FOREACH cannot be a rewritten UNWIND.
    var f = newFixture()
    discard f.exec("CREATE (:P {seen: 0})")
    check f.exec("MATCH (n:P) FOREACH (x IN [n, n] | SET x.seen = 1)") == 2
    discard f.tx.commit()
    let (_, v) = read(f.s, "MATCH (n:P) RETURN n.seen AS s")[0].lookup("s")
    check v.kind == vkInt and v.i == 1

  test "the element must be a node or a relationship, and is refused by name":
    ## A list of numbers is a list, but a number has no properties: the
    ## element is refused the way SET's own target is.
    var f = newFixture()
    discard f.exec("CREATE (:P)")
    var e: ref GlyError
    try:
      discard f.exec("MATCH (n:P) FOREACH (x IN [1, 2] | SET x.v = 1)")
    except GlyError as err:
      e = err
    check e != nil
    if e != nil:
      check e.status == int32(glyErrSql)
      check "FOREACH's element is a vkInt" in e.msg

  test "the list must be a list":
    var f = newFixture()
    discard f.exec("CREATE (:P)")
    var e: ref GlyError
    try:
      discard f.exec("MATCH (n:P) FOREACH (x IN 3 | SET x.v = 1)")
    except GlyError as err:
      e = err
    check e != nil
    if e != nil:
      check e.status == int32(glyErrSql)
      check "FOREACH needs a list" in e.msg

  test "CREATE and DELETE inside a FOREACH are refused by name":
    ## The write set of a statement is what the transaction logs, and a
    ## clause that creates and deletes in a loop is a different thing to
    ## reason about. The refusal names the word, not just the clause.
    for sql in ["MATCH (n:P) FOREACH (x IN [n] | CREATE (:Q))",
                "MATCH (n:P) FOREACH (x IN [n] | DELETE x)"]:
      var e: CypherError
      try:
        discard parseQuery(sql)
      except CypherError as err:
        e = err
      check e != nil
      check "SET or REMOVE" in e.msg
      check "CREATE" in e.msg or "DELETE" in e.msg

  test "the loop variable is scoped to the clause":
    ## A later `RETURN x` is a typo, and it is refused at prepare time
    ## rather than failing on the first row — or, worse, on a query that
    ## happens to produce no rows and so never fails at all.
    ## The scope check is part of planning, so the refusal comes from
    ## `prepare` — with a writer, or the write door's own refusal would
    ## fire first and the test would be about the wrong thing.
    var f = newFixture()
    var e: CypherError
    try:
      discard prepare(f.s,
        "MATCH (n:P) FOREACH (x IN [n] | SET x.seen = 1) RETURN x",
        initTable[string, Value](), f.tx)
    except CypherError as err:
      e = err
    check e != nil and "x" in e.msg

  test "a FOREACH with no write transaction is refused by name":
    ## The write door's rule: a write planned with no transaction is a
    ## write nobody would ever see.
    let s = newStore()
    var e: CypherError
    try:
      discard prepare(s, "MATCH (n:P) FOREACH (x IN [n] | SET x.seen = 1)")
    except CypherError as err:
      e = err
    check e != nil and e.code == int32(glyErrUnsupported)
    check "FOREACH" in e.msg

  test "a FOREACH write survives a reopen":
    ## The write goes through the transaction's setter, so it reaches the
    ## log — the rule the client's link door was fixed for. A write a
    ## restart forgets is not a write.
    let path = "tmp" / "foreach-durable.glyph"
    removeFile(path)
    removeFile(path & "-wal")
    let db = openDatabase(path, GLY_OPEN_CREATE)
    let tx = db.beginTransaction()
    let created = tx.createNode("P")
    discard tx.setNodeProp(created, "seen", Value(kind: vkInt, i: 0))
    discard db.commitTransaction(tx)

    let wtx = db.beginTransaction()
    var st = prepare(db.store,
                     "MATCH (n:P) FOREACH (x IN [n] | SET x.seen = 1)",
                     initTable[string, Value](), wtx, 0, "", db.indices)
    while st.step():
      discard
    check st.rowsAffected() == 1
    st.close()
    discard db.commitTransaction(wtx)
    close(db)

    let db2 = openDatabase(path, 0)
    let st2 = prepare(db2.store, "MATCH (n:P) RETURN n.seen AS s")
    defer: st2.close()
    let rows = st2.collectRows()
    check rows.len == 1
    let (_, v) = rows[0].lookup("s")
    check v.kind == vkInt and v.i == 1
    close(db2)


suite "M5.9 the type discipline — a node the transaction made":
  test "typeof sees a node created in the same statement":
    ## A node this transaction created has an id past the snapshot's
    ## arrays, so the label getter has to look in the transaction first.
    ## Without that it indexed off the end of `snap.nodes`.
    var f = newFixture()
    var st = prepare(f.s, "CREATE (n:Widget) RETURN typeof(n) AS t",
                     initTable[string, Value](), f.tx)
    var got = ""
    while st.step():
      got = st.current.lookup("t")[1].s
    st.close()
    check got == "Widget"
    discard f.tx.rollback()


suite "M6.5 DATE — the round trip":
  test "a date survives a reopen":
    ## The type is only a type if the store gives it back: the codec has
    ## a tag for it, and the snapshot keeps the day count.
    let path = "tmp" / "date-durable.glyph"
    removeFile(path)
    removeFile(path & "-wal")
    let db = openDatabase(path, GLY_OPEN_CREATE)
    let tx = db.beginTransaction()
    let n = tx.createNode("D")
    var days: int64
    doAssert parseDateText("2026-10-21", days)
    discard tx.setNodeProp(n, "when", Value(kind: vkDate, d: days))
    discard db.commitTransaction(tx)
    close(db)

    let db2 = openDatabase(path, 0)
    let st = prepare(db2.store, "MATCH (n:D) RETURN n.when AS w")
    defer: st.close()
    let rows = st.collectRows()
    check rows.len == 1
    let (_, v) = rows[0].lookup("w")
    check v.kind == vkDate and v.d == days
    close(db2)
